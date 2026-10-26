// SPDX-FileCopyrightText: 2026 Nourax
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// The pure rules of the Workspace web view (no UI, no network, no state).
///
/// The app's credential and its session cookies belong to one origin only: the account's own server
/// (same scheme, host and port as the account's server URL). Everything else is sent to the system browser.
enum NCWorkspaceOrigin {
    struct Origin: Equatable {
        let scheme: String
        let host: String
        let port: Int
    }

    /// Where a link from the server's notification list goes.
    enum Route: Equatable {
        case inApp      // the account's own server: the in-app web view, signed in
        case external   // anything else: today's behaviour (the system opens it)
        case ignore     // empty or not a URL
    }

    /// What the web view does with a main-frame navigation.
    enum NavigationDecision: Equatable {
        case allow              // own origin: load in place
        case reauthenticate     // own origin, a login page: the session ended; sign in again natively
        case close              // own origin, the log-out page: close the screen (the account stays)
        case openExternally     // another http(s) origin: in-app browser panel with its own cookie jar
        case openSystem         // mailto: and tel:
        case cancel             // everything else
    }

    // MARK: - Parsing

    /// URL components of a string, or nil when it is empty or holds characters no URL may hold in front of
    /// the host (white space, control characters, a backslash: the system parser and the web engine could
    /// read such a string differently).
    private static func components(_ string: String) -> URLComponents? {
        guard !string.isEmpty else { return nil }
        for scalar in string.unicodeScalars where scalar.value <= 0x20 || scalar.value == 0x7F || scalar == "\\" {
            return nil
        }
        return URLComponents(string: string)
    }

    /// The origin of an http(s) URL, or nil: not http(s), no host, user info present, or a non-ASCII host.
    static func origin(of string: String) -> Origin? {
        guard let parts = components(string),
              let scheme = parts.scheme?.lowercased(), scheme == "http" || scheme == "https",
              parts.user == nil, parts.password == nil,
              let host = parts.host?.lowercased(), !host.isEmpty,
              host.unicodeScalars.allSatisfy({ $0.isASCII }) else { return nil }
        return Origin(scheme: scheme, host: host, port: parts.port ?? (scheme == "https" ? 443 : 80))
    }

    /// True when both are http(s) URLs of the same scheme, the same host (exact, no suffix match) and the same
    /// effective port.
    static func isSameOrigin(_ candidate: String, base: String) -> Bool {
        guard let candidateOrigin = origin(of: candidate), let baseOrigin = origin(of: base) else { return false }
        return candidateOrigin == baseOrigin
    }

    /// A reference from the server (a path such as "/apps/mail/", or an absolute URL) made absolute against the
    /// account's server URL. The result is not checked: callers still test `isSameOrigin`.
    static func resolve(_ reference: String, base: String) -> String? {
        guard !reference.isEmpty, let parts = components(base),
              let scheme = parts.scheme?.lowercased(), let host = parts.host, !host.isEmpty else { return nil }
        if reference.hasPrefix("//") {
            return scheme + ":" + reference
        }
        if reference.contains("://") || reference.contains(":") && !reference.hasPrefix("/") {
            return reference
        }
        var origin = "\(scheme)://\(host)"
        if let port = parts.port {
            origin += ":\(port)"
        }
        if reference.hasPrefix("/") {
            return origin + reference
        }
        var root = parts.percentEncodedPath
        while root.hasSuffix("/") {
            root.removeLast()
        }
        return origin + root + "/" + reference
    }

    // MARK: - Paths

    /// The path of an own-origin URL relative to the account's web root ("/" when it is the root itself), with a
    /// leading "/index.php" removed. Nil when the URL is not of the own origin or lies outside the web root.
    private static func relativePath(of url: String, base: String) -> String? {
        guard isSameOrigin(url, base: base), let parts = components(url), let baseParts = components(base) else { return nil }
        var root = baseParts.percentEncodedPath
        while root.hasSuffix("/") {
            root.removeLast()
        }
        let path = parts.percentEncodedPath
        var rest: String
        if root.isEmpty {
            rest = path
        } else {
            guard path == root || path.hasPrefix(root + "/") else { return nil }
            rest = String(path.dropFirst(root.count))
        }
        if rest == "/index.php" {
            rest = "/"
        } else if rest.hasPrefix("/index.php/") {
            rest = String(rest.dropFirst("/index.php".count))
        }
        return rest.isEmpty ? "/" : rest
    }

    private static func path(_ path: String, startsWith prefix: String) -> Bool {
        path == prefix || path.hasPrefix(prefix + "/")
    }

    /// A page of the server's own login: /login, /index.php/login and the Log in with Nourax entry (user_oidc).
    static func isLoginPath(_ url: String, base: String) -> Bool {
        guard let rest = relativePath(of: url, base: base) else { return false }
        return path(rest, startsWith: "/login") || path(rest, startsWith: "/apps/user_oidc/login")
    }

    static func isLogoutPath(_ url: String, base: String) -> Bool {
        relativePath(of: url, base: base) == "/logout"
    }

    // MARK: - Decisions

    /// The web view's policy for a main-frame navigation (sub-frames and sub-resources are left to the engine).
    static func navigationDecision(for url: String, base: String) -> NavigationDecision {
        guard let parts = components(url), let scheme = parts.scheme?.lowercased() else { return .cancel }
        switch scheme {
        case "http", "https":
            if isSameOrigin(url, base: base) {
                if isLogoutPath(url, base: base) { return .close }
                if isLoginPath(url, base: base) { return .reauthenticate }
                return .allow
            }
            return origin(of: url) == nil && parts.host == nil ? .cancel : .openExternally
        case "mailto", "tel":
            return .openSystem
        case "about":
            return url == "about:blank" ? .allow : .cancel
        default:
            return .cancel
        }
    }

    /// Notification links: the account's own server opens in the app, signed in; the rest keeps today's behaviour.
    static func route(link: String, base: String) -> Route {
        guard let parts = components(link), let scheme = parts.scheme?.lowercased() else { return .ignore }
        if scheme == "http" || scheme == "https" {
            return isSameOrigin(link, base: base) ? .inApp : .external
        }
        return .external
    }
}
