// SPDX-FileCopyrightText: 2026 Nourax
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Observation
import UIKit

/// The steps of "Add to iPhone Calendar & Contacts" (design 10): a separate app password through Login Flow v2, the
/// profile built from it, a one-time loopback server and Safari to hand it to iOS, then the install steps.
///
/// The password and the profile bytes live in memory for the length of the flow only; every way out wipes them.
@MainActor
@Observable
final class NCDeviceSyncFlow {
    enum Phase: Equatable {
        /// Step 1: the explanation.
        case intro
        /// Step 2: waiting for the person to allow access on the sign-in page.
        case waiting
        case timedOut
        /// The server did not create a password.
        case refused
        case failed
        /// Step 3: handing the profile to Safari.
        case opening
        /// The install steps, with Installed / It didn't work / Open Safari again.
        case installSteps
        case done
        /// "It didn't work": the separate password was removed.
        case undone
        /// Apple deletes a profile that is not installed within 8 minutes; the flow forgot it too.
        case expired
    }

    /// Everything the flow touches outside itself, so the unit tests run it with fakes.
    struct Dependencies {
        var account: String
        var client: () -> NCDeviceAppPasswordClient?
        var profileAccount: (_ loginName: String) -> NCDeviceSyncProfile.Account?
        var bundleIdentifier: String
        var presentSignIn: (_ url: URL, _ onClosedByPerson: @escaping () -> Void) -> Void
        var dismissSignIn: () -> Void
        var startServer: (_ profile: NCDeviceSyncSecret) async throws -> (url: URL, server: NCDeviceSyncProfileServer)
        var openInSafari: (_ url: URL) async -> Bool
        var state: NCDeviceSyncState
        var pollInterval: TimeInterval
        var pollTimeout: TimeInterval
        /// Apple deletes a profile that is not installed within 8 minutes.
        var installWindow: TimeInterval
        var sleep: (TimeInterval) async throws -> Void
        var profileBuilt: (Data) -> Void

        @MainActor
        static func live(account: String) -> Dependencies {
            let signIn = NCDeviceSyncSignIn()
            return Dependencies(
                account: account,
                client: {
                    guard let credentials = NCWorkspaceSession.credentials(account: account) else { return nil }
                    return NCDeviceAppPasswordClient.live(base: credentials.base)
                },
                profileAccount: { loginName in
                    guard let credentials = NCWorkspaceSession.credentials(account: account) else { return nil }
                    return NCDeviceSyncProfile.Account(base: credentials.base, userId: credentials.userId,
                                                       loginName: loginName, accountKey: account)
                },
                bundleIdentifier: Bundle.main.bundleIdentifier ?? "org.nourax.nodrive",
                presentSignIn: { url, onClosed in signIn.present(url, onClosedByPerson: onClosed) },
                dismissSignIn: { signIn.dismiss() },
                startServer: { profile in
                    let server = NCDeviceSyncProfileServer(profile: profile)
                    // iOS may suspend the app while Safari is in front: ask for time until the server closes.
                    let background = BackgroundTask()
                    background.identifier = UIApplication.shared.beginBackgroundTask(withName: "NoDriveDeviceSyncProfile") {
                        server.cancel()
                    }
                    server.onClosed = {
                        Task { @MainActor in
                            background.end()
                        }
                    }
                    do {
                        let url = try await server.start()
                        return (url, server)
                    } catch {
                        server.cancel()
                        throw error
                    }
                },
                openInSafari: { url in
                    await withCheckedContinuation { continuation in
                        UIApplication.shared.open(url, options: [:]) { ok in continuation.resume(returning: ok) }
                    }
                },
                state: NCDeviceSyncState(),
                pollInterval: NCDeviceSyncUITestHooks.pollInterval ?? 5,
                pollTimeout: 20 * 60,
                installWindow: 10 * 60,
                sleep: { seconds in try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) },
                profileBuilt: { NCDeviceSyncUITestHooks.profileBuilt($0) })
        }
    }

    /// The time iOS gives the loopback server while Safari is in front.
    @MainActor
    final class BackgroundTask: @unchecked Sendable {
        var identifier = UIBackgroundTaskIdentifier.invalid

        func end() {
            guard identifier != .invalid else { return }
            UIApplication.shared.endBackgroundTask(identifier)
            identifier = .invalid
        }
    }

    private(set) var phase: Phase = .intro
    let dependencies: Dependencies

    private var flow: NCDeviceAppPasswordClient.Flow?
    private var grant: NCDeviceAppPasswordClient.Grant?
    private var profile: NCDeviceSyncSecret?
    private var server: NCDeviceSyncProfileServer?
    private var signInTask: Task<Void, Never>?
    private var installTimer: Task<Void, Never>?
    /// True once the profile was handed to Safari: from then on the password may be in use on the phone.
    private var offered = false

    init(dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    // MARK: Step 1 and 2

    /// "Continue": starts the sign-in.
    func begin() {
        guard phase == .intro || phase == .timedOut || phase == .refused || phase == .failed || phase == .undone || phase == .expired else { return }
        phase = .waiting
        signInTask?.cancel()
        signInTask = Task { [weak self] in
            await self?.signIn()
        }
    }

    private func signIn() async {
        guard let client = dependencies.client() else {
            phase = .failed
            return
        }
        do {
            let started = try await client.start()
            flow = started
            dependencies.presentSignIn(started.loginURL) { }
            let granted = try await client.waitForGrant(started, interval: dependencies.pollInterval,
                                                        timeout: dependencies.pollTimeout, sleep: dependencies.sleep)
            dependencies.dismissSignIn()
            grant = granted
            await hand(granted)
        } catch let error as NCDeviceAppPasswordError {
            dependencies.dismissSignIn()
            switch error {
            case .timedOut: phase = .timedOut
            case .refused: phase = .refused
            case .cancelled: break
            default: phase = .failed
            }
        } catch {
            dependencies.dismissSignIn()
            if !Task.isCancelled { phase = .failed }
        }
    }

    /// "Open the sign-in page again".
    func reopenSignIn() {
        guard phase == .waiting, let flow else { return }
        dependencies.presentSignIn(flow.loginURL) { }
    }

    // MARK: Step 3

    private func hand(_ granted: NCDeviceAppPasswordClient.Grant) async {
        phase = .opening
        guard let account = dependencies.profileAccount(granted.loginName),
              let password = granted.secret.string() else {
            phase = .failed
            await withdraw()
            return
        }
        do {
            var data = try NCDeviceSyncProfile.build(account: account, password: password, bundleIdentifier: dependencies.bundleIdentifier)
            dependencies.profileBuilt(data)
            profile = NCDeviceSyncSecret(data: data)
            data.removeAll()
        } catch {
            NCDeviceSyncLog.log("profile-build-failed")
            phase = .failed
            await withdraw()
            return
        }
        await openSafari()
    }

    /// Starts a new one-time server for the profile in memory and opens it in Safari. Also "Open Safari again".
    func openSafari() async {
        guard let profile, !profile.isWiped else { return }
        server?.cancel()
        server = nil
        phase = .opening
        do {
            let started = try await dependencies.startServer(profile)
            server = started.server
            let opened = await dependencies.openInSafari(started.url)
            NCDeviceSyncLog.log("safari-open", status: opened ? 1 : 0)
            guard opened else {
                // Nothing reached Safari, so the password was never used: remove it again.
                phase = .failed
                await withdraw()
                return
            }
            offered = true
            dependencies.state.setProfileOffered(true, account: dependencies.account)
            phase = .installSteps
            startInstallTimer()
        } catch {
            NCDeviceSyncLog.log("profile-server-failed")
            phase = .failed
            await withdraw()
        }
    }

    private func startInstallTimer() {
        installTimer?.cancel()
        installTimer = Task { [weak self] in
            guard let self else { return }
            try? await self.dependencies.sleep(self.dependencies.installWindow)
            guard !Task.isCancelled, self.phase == .installSteps else { return }
            self.forget()
            self.phase = .expired
        }
    }

    // MARK: The way out

    /// "Installed".
    func installed() {
        forget()
        phase = .done
    }

    /// "It didn't work": the separate password is removed on the server, then forgotten.
    func didntWork() {
        let client = dependencies.client()
        let granted = grant
        forget(keepGrant: true)
        phase = .undone
        Task { [weak self] in
            if let client, let granted {
                await client.revoke(granted)
            }
            granted?.secret.wipe()
            self?.grant = nil
        }
    }

    /// Cancel or closing the sheet. Before the profile was offered the password was never used, so it is removed on the
    /// server too; after that it may be in use on the phone, so it stays.
    func cancel() {
        guard phase != .done, phase != .undone else {
            forget()
            return
        }
        signInTask?.cancel()
        dependencies.dismissSignIn()
        let client = dependencies.client()
        let granted = grant
        let unused = !offered
        forget(keepGrant: unused)
        if unused, let client, let granted {
            Task { [weak self] in
                await client.revoke(granted)
                granted.secret.wipe()
                self?.grant = nil
            }
        }
        if phase != .intro { phase = .intro }
    }

    private func withdraw() async {
        if let client = dependencies.client(), let granted = grant {
            await client.revoke(granted)
        }
        forget()
    }

    /// Wipes the profile bytes and the password and stops the server and the timers.
    private func forget(keepGrant: Bool = false) {
        installTimer?.cancel()
        installTimer = nil
        server?.cancel()
        server = nil
        profile?.wipe()
        profile = nil
        flow = nil
        if !keepGrant {
            grant?.secret.wipe()
            grant = nil
        }
    }

    // MARK: For tests

    var holdsSecret: Bool {
        (grant.map { !$0.secret.isWiped } ?? false) || (profile.map { !$0.isWiped } ?? false)
    }
}
