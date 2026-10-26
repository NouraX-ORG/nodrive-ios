// SPDX-FileCopyrightText: 2026 Nourax
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import NextcloudKit

enum NCWorkspaceSessionError: Error, Equatable {
    case noSession
    case redirected
    case badResponse(Int)
    case wrongUser
    case incompleteSession
}

/// Native hand-off of the signed-in session to the in-app web view.
///
/// The app's own HTTP client sends one request with the account's app password (the header the app already
/// sends on every API call) to its own server and reads the session cookies from the answer. Only those cookies
/// go into the web view; the app password never enters the web view, a URL or a log.
enum NCWorkspaceSession {
    struct Credentials {
        let account: String
        /// The account's server URL without a trailing slash; the only origin the credential is ever sent to.
        let base: String
        let userId: String
        /// "Basic ..."; never logged.
        let authorization: String
        let userAgent: String
    }

    /// Redirects are never followed (a credential must not follow a redirect), and certificates go through the
    /// app's own trust check.
    private final class Delegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession,
                        didReceive challenge: URLAuthenticationChallenge,
                        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            NCNetworking.shared.checkTrustedChallenge(session, didReceive: challenge, completionHandler: completionHandler)
        }

        func urlSession(_ session: URLSession,
                        task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    static func credentials(account: String) -> Credentials? {
        guard let session = NextcloudKit.shared.nkCommonInstance.nksessions.session(forAccount: account),
              NCWorkspaceOrigin.origin(of: session.urlBase) != nil,
              !session.user.isEmpty, !session.password.isEmpty,
              let basic = "\(session.user):\(session.password)".data(using: .utf8) else { return nil }
        var base = session.urlBase
        while base.hasSuffix("/") {
            base.removeLast()
        }
        return Credentials(account: account,
                           base: base,
                           userId: session.userId,
                           authorization: "Basic " + basic.base64EncodedString(),
                           userAgent: session.userAgent)
    }

    /// A GET request to the account's own server with the app's usual API headers. Nil unless the URL is of the
    /// account's own origin, so the credential cannot be put on a request to anywhere else.
    static func apiRequest(path: String, query: String, credentials: Credentials) -> URLRequest? {
        guard let url = URL(string: "\(credentials.base)/\(path)?\(query)"),
              NCWorkspaceOrigin.isSameOrigin(url.absoluteString, base: credentials.base) else { return nil }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        request.setValue(credentials.authorization, forHTTPHeaderField: "Authorization")
        request.setValue("true", forHTTPHeaderField: "OCS-APIRequest")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(credentials.userAgent, forHTTPHeaderField: "User-Agent")
        return request
    }

    /// One request on an ephemeral session: no cookie storage, no cache, no redirects.
    static func fetch(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        let session = URLSession(configuration: configuration, delegate: Delegate(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }

    /// The sign-in request (section 1.5 of the design): `GET {base}/ocs/v2.php/cloud/user?format=json` with the
    /// app's Basic header. Returns the server's session cookies, host-only, ready for the web view.
    static func bootstrap(account: String) async throws -> (base: String, cookies: [HTTPCookie]) {
        guard let signedIn = Self.credentials(account: account),
              let request = apiRequest(path: "ocs/v2.php/cloud/user", query: "format=json", credentials: signedIn),
              let url = request.url else { throw NCWorkspaceSessionError.noSession }
        let (data, response) = try await fetch(request)
        let cookies = try sessionCookies(data: data, response: response, url: url, userId: signedIn.userId)
        return (signedIn.base, cookies)
    }

    /// Accepts only HTTP 200 for the account's user id with a complete set of session cookies.
    static func sessionCookies(data: Data, response: HTTPURLResponse, url: URL, userId: String, now: Date = Date()) throws -> [HTTPCookie] {
        if (300..<400).contains(response.statusCode) {
            throw NCWorkspaceSessionError.redirected
        }
        guard response.statusCode == 200 else {
            throw NCWorkspaceSessionError.badResponse(response.statusCode)
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ocs = root["ocs"] as? [String: Any],
              let payload = ocs["data"] as? [String: Any],
              let id = payload["id"] as? String, id == userId else {
            throw NCWorkspaceSessionError.wrongUser
        }
        var fields: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            if let key = key as? String, let value = value as? String, key.lowercased() == "set-cookie" {
                fields["Set-Cookie"] = value
            }
        }
        let cookies = NCWorkspaceCookies.cookies(fromHeaderFields: fields, url: url, now: now)
        guard NCWorkspaceCookies.isCompleteSession(cookies) else {
            throw NCWorkspaceSessionError.incompleteSession
        }
        return cookies
    }
}
