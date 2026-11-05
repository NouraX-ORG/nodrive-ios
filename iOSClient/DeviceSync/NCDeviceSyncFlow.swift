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
        /// "It didn't work": the server confirmed that the separate password was removed.
        case undone
        /// Apple deletes a profile that is not installed within 8 minutes; the flow forgot it too.
        case expired
        /// The person allowed access as another user than the signed-in account: the new password was removed again.
        case otherUser
        /// Waiting for the server to remove the separate password.
        case removing
        /// The server did not confirm the removal. The flow still holds the password, so "Try again" can retry.
        case notRemoved
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
                        NCDeviceSyncUITestHooks.serverRecord("profile-server-closed")
                        Task { @MainActor in
                            background.end()
                        }
                    }
                    server.onRequest = { method, status, bytes in
                        NCDeviceSyncUITestHooks.profileRequest(method: method, status: status, bytes: bytes)
                    }
                    do {
                        let url = try await server.start()
                        NCDeviceSyncUITestHooks.serverRecord("profile-server-listening")
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
    /// True once Cancel or Close ended the flow and the sheet may close (after a removal that it waited for).
    private(set) var closed = false
    let dependencies: Dependencies

    private var flow: NCDeviceAppPasswordClient.Flow?
    private var grant: NCDeviceAppPasswordClient.Grant?
    private var profile: NCDeviceSyncSecret?
    private var server: NCDeviceSyncProfileServer?
    private var signInTask: Task<Void, Never>?
    private var installTimer: Task<Void, Never>?
    /// True once the profile was handed to Safari: from then on the password may be in use on the phone.
    private var offered = false
    /// Counts the runs of the flow. `begin()` and `cancel()` start a new one, so a step that was in flight when the person
    /// cancelled (a poll answer, the loopback server starting) sees that it is out of date and stops.
    private var generation = 0
    /// Where the flow goes once a removal that failed worked on a retry: a phase, or nil to close the sheet.
    private var afterRemoval: Phase?

    init(dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    // MARK: Step 1 and 2

    /// "Continue": starts the sign-in.
    func begin() {
        guard phase == .intro || phase == .timedOut || phase == .refused || phase == .failed || phase == .undone
                || phase == .expired || phase == .otherUser else { return }
        generation += 1
        closed = false
        phase = .waiting
        signInTask?.cancel()
        let mine = generation
        signInTask = Task { [weak self] in
            await self?.signIn(mine)
        }
    }

    private func signIn(_ mine: Int) async {
        guard let client = dependencies.client() else {
            phase = .failed
            return
        }
        do {
            let started = try await client.start()
            guard mine == generation else { return }
            flow = started
            dependencies.presentSignIn(started.loginURL) { }
            let granted = try await client.waitForGrant(started, interval: dependencies.pollInterval,
                                                        timeout: dependencies.pollTimeout, sleep: dependencies.sleep)
            guard mine == generation else {
                // Cancelled while the answer was on its way: the password exists on the server, so it goes again. This task
                // was cancelled by cancel(), and URLSession fails a request of a cancelled task at once: the removal runs in
                // a task of its own, which does not inherit the cancellation.
                discardInFreshTask(granted)
                return
            }
            dependencies.dismissSignIn()
            grant = granted
            // A new password has not been offered yet, whatever an earlier run of this flow did.
            offered = false
            await hand(granted, mine)
        } catch let error as NCDeviceAppPasswordError {
            guard mine == generation else { return }
            dependencies.dismissSignIn()
            switch error {
            case .timedOut: phase = .timedOut
            case .refused: phase = .refused
            case .cancelled: break
            default: phase = .failed
            }
        } catch {
            guard mine == generation else { return }
            dependencies.dismissSignIn()
            phase = .failed
        }
    }

    /// "Open the sign-in page again".
    func reopenSignIn() {
        guard phase == .waiting, let flow else { return }
        dependencies.presentSignIn(flow.loginURL) { }
    }

    // MARK: Step 3

    private func hand(_ granted: NCDeviceAppPasswordClient.Grant, _ mine: Int) async {
        phase = .opening
        guard let account = dependencies.profileAccount(granted.loginName),
              let password = granted.secret.string() else {
            await removeGrant(then: .failed)
            return
        }
        // The sign-in sheet is not tied to this account: prove whose password this is before it goes into a profile.
        let owner = await dependencies.client()?.ownerId(of: granted)
        guard mine == generation else { return }
        guard owner == account.userId else {
            NCDeviceSyncLog.log(owner == nil ? "identity-unknown" : "identity-other-user")
            await removeGrant(then: owner == nil ? .failed : .otherUser)
            return
        }
        do {
            var data = try NCDeviceSyncProfile.build(account: account, password: password, bundleIdentifier: dependencies.bundleIdentifier)
            dependencies.profileBuilt(data)
            profile = NCDeviceSyncSecret(data: data)
            // Best effort: the plist dictionary and the String above are copies this code cannot reach.
            data.withUnsafeMutableBytes { buffer in
                if let base = buffer.baseAddress, buffer.count > 0 {
                    memset_s(base, buffer.count, 0, buffer.count)
                }
            }
            data.removeAll()
        } catch {
            NCDeviceSyncLog.log("profile-build-failed")
            await removeGrant(then: .failed)
            return
        }
        await openSafari()
    }

    /// Starts a new one-time server for the profile in memory and opens it in Safari. Also "Open Safari again".
    func openSafari() async {
        guard let profile, !profile.isWiped else { return }
        let mine = generation
        server?.cancel()
        server = nil
        phase = .opening
        do {
            let started = try await dependencies.startServer(profile)
            // Cancelled meanwhile: no Safari, and nothing of the flow is touched (cancel() did its work already).
            guard mine == generation else {
                started.server.cancel()
                return
            }
            server = started.server
            let opened = await dependencies.openInSafari(started.url)
            guard mine == generation else { return }
            NCDeviceSyncLog.log("safari-open", status: opened ? 1 : 0)
            guard opened else {
                // Nothing reached Safari, so the password was never used: remove it again.
                await removeGrant(then: .failed)
                return
            }
            offered = true
            dependencies.state.setProfileOffered(true, account: dependencies.account)
            phase = .installSteps
            startInstallTimer()
        } catch {
            guard mine == generation else { return }
            NCDeviceSyncLog.log("profile-server-failed")
            await removeGrant(then: .failed)
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

    /// "It didn't work": the separate password is removed on the server. Only when the server confirms is it forgotten and
    /// the "removed" text shown; otherwise the flow keeps it and offers "Try again".
    func didntWork() {
        guard phase == .installSteps else { return }
        forget(keepGrant: true)
        phase = .removing
        Task { [weak self] in
            await self?.removeGrant(then: .undone)
        }
    }

    /// "Try again" after the removal failed.
    func retryRemoval() {
        guard phase == .notRemoved else { return }
        let next = afterRemoval
        phase = .removing
        Task { [weak self] in
            await self?.removeGrant(then: next)
        }
    }

    /// Cancel or closing the sheet. Before the profile was offered the password was never used, so it is removed on the
    /// server too (the sheet waits for the server's answer); after that it may be in use on the phone, so it stays.
    func cancel() {
        guard phase != .removing else { return }
        generation += 1
        signInTask?.cancel()
        dependencies.dismissSignIn()
        // The server creates the password when the person allows access, not when the app polls: a Cancel in the
        // seconds before the next poll would leave a password the app never sees. One more poll in a task of its own
        // (the sign-in task is cancelled) picks it up and removes it. The flow is read here, before forget() drops it.
        if phase == .waiting, grant == nil, let flow {
            Task { await self.pollOnceAndDiscard(flow) }
        }
        if grant != nil, !offered, phase != .notRemoved {
            forget(keepGrant: true)
            phase = .removing
            Task { [weak self] in
                await self?.removeGrant(then: nil)
            }
            return
        }
        forget()
        phase = .intro
        closed = true
    }

    /// Removes the new password on the server. Success: it is wiped and the flow goes on to `next` (nil: the sheet closes).
    /// Anything else (offline, 401, 5xx, a client that is gone, an OCS error): `.notRemoved`, still holding the password.
    private func removeGrant(then next: Phase?) async {
        afterRemoval = next
        // The profile and the server are not needed any more; only the password stays until the server confirmed.
        forget(keepGrant: true)
        guard let granted = grant else {
            finishRemoval(next)
            return
        }
        phase = .removing
        let removed = await dependencies.client()?.revoke(granted) ?? false
        guard grant?.secret === granted.secret else {
            granted.secret.wipe()
            return
        }
        if removed {
            granted.secret.wipe()
            grant = nil
            finishRemoval(next)
        } else {
            phase = .notRemoved
        }
    }

    private func finishRemoval(_ next: Phase?) {
        afterRemoval = nil
        if let next {
            phase = next
        } else {
            phase = .intro
            closed = true
        }
    }

    /// A password nobody looks at any more (the person cancelled while the answer was on its way): a few tries, then wiped.
    /// Starts in a task that does not inherit the cancellation of the sign-in task.
    private func discardInFreshTask(_ granted: NCDeviceAppPasswordClient.Grant) {
        Task { await self.discard(granted) }
    }

    /// The last poll after Cancel in `.waiting`: a password the person allowed meanwhile is removed at once.
    private func pollOnceAndDiscard(_ flow: NCDeviceAppPasswordClient.Flow) async {
        guard let client = dependencies.client(), let granted = try? await client.poll(flow) else { return }
        await discard(granted)
    }

    private func discard(_ granted: NCDeviceAppPasswordClient.Grant) async {
        var removed = false
        if let client = dependencies.client() {
            for attempt in 0..<3 where !removed {
                if attempt > 0 { try? await dependencies.sleep(2) }
                removed = await client.revoke(granted)
            }
        }
        if !removed { NCDeviceSyncLog.log("revoke-gave-up") }
        granted.secret.wipe()
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
