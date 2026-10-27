// SPDX-FileCopyrightText: 2026 Nourax
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// The session cookies the server sends to the app's one sign-in request, made ready for the in-app web view.
///
/// Rules: every cookie of the answer is kept, in order; expired ones (the server's deletion cookies) are
/// dropped; a name sent twice keeps the last one (PHP sends one at session start and one after the new
/// session id); every cookie becomes host-only (no Domain attribute) for the account's host; Path, HttpOnly,
/// SameSite and the expiry stay; a cookie is Secure when the server sent it so or when the server is https
/// (cookies are scoped by host, not scheme, so this keeps them off a plain http request to the same host).
enum NCWorkspaceCookies {
    static let passphraseName = "oc_sessionPassphrase"

    /// - Parameters:
    ///   - fields: the header fields of the sign-in answer (several Set-Cookie lines arrive joined by commas).
    ///   - url: the URL the answer came from; its host becomes the cookies' host.
    static func cookies(fromHeaderFields fields: [String: String], url: URL, now: Date = Date()) -> [HTTPCookie] {
        guard let host = url.host?.lowercased(), !host.isEmpty else { return [] }
        var result: [HTTPCookie] = []
        for cookie in HTTPCookie.cookies(withResponseHeaderFields: fields, for: url) {
            // A later cookie of the same name and path replaces the earlier one, and a deletion removes it.
            result.removeAll { $0.name == cookie.name && $0.path == cookie.path }
            if let expires = cookie.expiresDate, expires <= now { continue }
            if let hostOnly = hostOnlyCopy(of: cookie, host: host, secure: url.scheme?.lowercased() == "https") {
                result.append(hostOnly)
            }
        }
        return result
    }

    /// The sign-in is only complete when the server sent the session's passphrase cookie and the session cookie.
    static func isCompleteSession(_ cookies: [HTTPCookie]) -> Bool {
        cookies.contains { $0.name == passphraseName }
            && cookies.contains { $0.name.hasPrefix("oc") && $0.name != passphraseName }
    }

    private static func hostOnlyCopy(of cookie: HTTPCookie, host: String, secure: Bool) -> HTTPCookie? {
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: cookie.name,
            .value: cookie.value,
            .path: cookie.path.isEmpty ? "/" : cookie.path,
            .domain: host
        ]
        if cookie.isSecure || secure {
            properties[.secure] = "TRUE"
        }
        if let expires = cookie.expiresDate {
            properties[.expires] = expires
        }
        if cookie.isHTTPOnly {
            properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE"
        }
        if let sameSite = cookie.sameSitePolicy {
            properties[.sameSitePolicy] = sameSite.rawValue
        }
        return HTTPCookie(properties: properties)
    }
}
