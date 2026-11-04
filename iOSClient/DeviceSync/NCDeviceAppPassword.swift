// SPDX-FileCopyrightText: 2026 Nourax
// SPDX-License-Identifier: GPL-3.0-or-later

import AuthenticationServices
import Foundation
import UIKit

enum NCDeviceAppPasswordError: Error, Equatable {
    case wrongOrigin
    /// The server did not start the sign-in, or refused it ("Ask your administrator").
    case refused
    case timedOut
    case cancelled
    /// The answer named another server; the new password was revoked.
    case wrongServer
    case badAnswer
    case network
}

/// Login Flow v2 for one thing: a separate app password for the iPhone's Calendar, Reminders and Contacts.
///
/// It runs on its own ephemeral session (no NextcloudKit, no logger, no cookies, no redirects, only the account's own
/// origin). Nothing it receives is logged: not the poll token, not the password. The server names the new app
/// password after the User-Agent of the first request, so the person finds it in the web security settings under
/// "NoDrive Calendar & Contacts (iPhone)".
struct NCDeviceAppPasswordClient {
    typealias Transport = (URLRequest) async throws -> (Data, HTTPURLResponse)

    /// The account's server URL.
    let base: String
    var transport: Transport
    var userAgent: String = NCDeviceSync.deviceUserAgent

    /// The live transport: the Workspace session's ephemeral, no-redirect, trust-checked fetch.
    static func live(base: String) -> NCDeviceAppPasswordClient {
        NCDeviceAppPasswordClient(base: base, transport: { request in try await NCWorkspaceSession.fetch(request) })
    }

    struct Flow: CustomStringConvertible, CustomDebugStringConvertible {
        let loginURL: URL
        let pollURL: URL
        fileprivate let token: String
        var description: String { "Flow(login: \(loginURL.host ?? "?"))" }
        var debugDescription: String { description }
    }

    struct Grant {
        let loginName: String
        let secret: NCDeviceSyncSecret
    }

    private func request(_ method: String, _ url: URL) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = method
        request.httpShouldHandleCookies = false
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    /// `POST <base>/index.php/login/v2` -> the page to open and the endpoint to poll. Both must be of the account's origin.
    func start() async throws -> Flow {
        guard let url = URL(string: base.trimmingSlashes + "/index.php/login/v2"),
              NCWorkspaceOrigin.isSameOrigin(url.absoluteString, base: base) else { throw NCDeviceAppPasswordError.wrongOrigin }
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport(request("POST", url))
        } catch {
            throw NCDeviceAppPasswordError.network
        }
        NCDeviceSyncLog.log("signin-start", status: response.statusCode)
        guard response.statusCode == 200 else { throw NCDeviceAppPasswordError.refused }
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let poll = root["poll"] as? [String: Any],
              let token = poll["token"] as? String, !token.isEmpty,
              let endpoint = poll["endpoint"] as? String,
              let login = root["login"] as? String else { throw NCDeviceAppPasswordError.badAnswer }
        guard NCWorkspaceOrigin.isSameOrigin(endpoint, base: base), NCWorkspaceOrigin.isSameOrigin(login, base: base),
              let pollURL = URL(string: endpoint), let loginURL = URL(string: login) else { throw NCDeviceAppPasswordError.wrongOrigin }
        return Flow(loginURL: loginURL, pollURL: pollURL, token: token)
    }

    /// One poll. Nil while the person has not allowed access yet (the server answers 404).
    func poll(_ flow: Flow) async throws -> Grant? {
        var poll = request("POST", flow.pollURL)
        poll.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        poll.httpBody = Data(("token=" + (flow.token.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")).utf8)
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport(poll)
        } catch {
            throw NCDeviceAppPasswordError.network
        }
        switch response.statusCode {
        case 200:
            break
        case 404, 408, 425, 429, 500...599:
            return nil
        default:
            throw NCDeviceAppPasswordError.refused
        }
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let server = root["server"] as? String, !server.isEmpty,
              let loginName = root["loginName"] as? String, !loginName.isEmpty,
              let password = root["appPassword"] as? String, !password.isEmpty else { throw NCDeviceAppPasswordError.badAnswer }
        let grant = Grant(loginName: loginName, secret: NCDeviceSyncSecret(password))
        guard Self.sameServer(server, base) else {
            NCDeviceSyncLog.log("signin-wrong-server")
            await revoke(grant)
            grant.secret.wipe()
            throw NCDeviceAppPasswordError.wrongServer
        }
        NCDeviceSyncLog.log("signin-granted")
        return grant
    }

    /// Polls until the person allows access. `interval` and `timeout` are in seconds; `sleep` is replaced in tests.
    func waitForGrant(_ flow: Flow,
                      interval: TimeInterval,
                      timeout: TimeInterval,
                      sleep: (TimeInterval) async throws -> Void) async throws -> Grant {
        let polls = max(1, Int((timeout / max(interval, 0.001)).rounded(.up)))
        var failures = 0
        for _ in 0..<polls {
            try Task.checkCancellation()
            do {
                if let grant = try await poll(flow) { return grant }
                failures = 0
            } catch NCDeviceAppPasswordError.network {
                failures += 1
                if failures >= 6 { throw NCDeviceAppPasswordError.network }
            }
            do {
                try await sleep(interval)
            } catch {
                throw NCDeviceAppPasswordError.cancelled
            }
        }
        NCDeviceSyncLog.log("signin-timeout")
        throw NCDeviceAppPasswordError.timedOut
    }

    /// `GET <base>/ocs/v2.php/cloud/user?format=json` with the new password: the id of the user the password belongs to, or
    /// nil when that cannot be told (offline, refused, another kind of answer). The sign-in sheet is not tied to the
    /// account, so the person may have allowed access as someone else: the flow compares this id with the account's.
    func ownerId(of grant: Grant) async -> String? {
        guard let password = grant.secret.string(),
              let url = URL(string: base.trimmingSlashes + "/ocs/v2.php/cloud/user?format=json"),
              NCWorkspaceOrigin.isSameOrigin(url.absoluteString, base: base),
              let basic = "\(grant.loginName):\(password)".data(using: .utf8) else { return nil }
        var identity = request("GET", url)
        identity.setValue("Basic " + basic.base64EncodedString(), forHTTPHeaderField: "Authorization")
        identity.setValue("true", forHTTPHeaderField: "OCS-APIRequest")
        let result = try? await transport(identity)
        NCDeviceSyncLog.log("identity", status: result?.1.statusCode)
        guard let (data, response) = result, response.statusCode == 200,
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let ocs = root["ocs"] as? [String: Any],
              let user = ocs["data"] as? [String: Any],
              let id = user["id"] as? String, !id.isEmpty else { return nil }
        return id
    }

    /// `DELETE <base>/ocs/v2.php/core/apppassword` with the new password: the server revokes the password the request was
    /// made with, so it removes itself. Always sent to the account's own server, never to a server a reply named.
    /// True only when the server said so: HTTP 200 and, when there is an answer body, an OCS status of 100 or 200.
    @discardableResult
    func revoke(_ grant: Grant) async -> Bool {
        guard let password = grant.secret.string(),
              let url = URL(string: base.trimmingSlashes + "/ocs/v2.php/core/apppassword"),
              NCWorkspaceOrigin.isSameOrigin(url.absoluteString, base: base),
              let basic = "\(grant.loginName):\(password)".data(using: .utf8) else { return false }
        var revoke = request("DELETE", url)
        revoke.setValue("Basic " + basic.base64EncodedString(), forHTTPHeaderField: "Authorization")
        revoke.setValue("true", forHTTPHeaderField: "OCS-APIRequest")
        let result = try? await transport(revoke)
        NCDeviceSyncLog.log("revoke", status: result?.1.statusCode)
        guard let (data, response) = result, response.statusCode == 200 else { return false }
        return Self.ocsSucceeded(data)
    }

    /// An empty answer is fine (the HTTP status said 200); otherwise the OCS status must be 100 or 200.
    static func ocsSucceeded(_ data: Data) -> Bool {
        guard !data.isEmpty else { return true }
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let ocs = root["ocs"] as? [String: Any],
              let meta = ocs["meta"] as? [String: Any],
              let code = meta["statuscode"] as? Int else { return false }
        return code == 100 || code == 200
    }

    /// The answer's `server` is the account's own server: same origin and the same path, case of the host ignored.
    static func sameServer(_ server: String, _ base: String) -> Bool {
        guard NCWorkspaceOrigin.isSameOrigin(server, base: base),
              let a = URLComponents(string: server), let b = URLComponents(string: base) else { return false }
        return a.percentEncodedPath.trimmingSlashes == b.percentEncodedPath.trimmingSlashes
    }
}

extension String {
    fileprivate var trimmingSlashes: String {
        var text = self
        while text.hasSuffix("/") { text.removeLast() }
        return text
    }
}

/// Opens the sign-in page in the system's sign-in sheet (no shared cookies, like the app's own sign-in). The sheet
/// ends when the flow gets its password and calls `dismiss()`; a person who closes it can open it again.
final class NCDeviceSyncSignIn: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?
    private var dismissedByUs = false

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.mainAppWindow ?? ASPresentationAnchor()
    }

    @MainActor
    func present(_ url: URL, onClosedByPerson: @escaping () -> Void) {
        dismiss()
        dismissedByUs = false
        let scheme = NCBrandOptions.shared.webLoginAutenticationProtocol.replacingOccurrences(of: "://", with: "")
        let created = ASWebAuthenticationSession(url: url, callbackURLScheme: scheme) { [weak self] _, _ in
            DispatchQueue.main.async {
                guard let self, !self.dismissedByUs else { return }
                self.session = nil
                onClosedByPerson()
            }
        }
        created.presentationContextProvider = self
        created.prefersEphemeralWebBrowserSession = true
        session = created
        if !created.start() {
            session = nil
            onClosedByPerson()
        }
    }

    @MainActor
    func dismiss() {
        guard let session else { return }
        dismissedByUs = true
        self.session = nil
        session.cancel()
    }
}
