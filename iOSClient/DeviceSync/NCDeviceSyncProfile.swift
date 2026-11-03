// SPDX-FileCopyrightText: 2026 Nourax
// SPDX-License-Identifier: GPL-3.0-or-later

import CryptoKit
import Foundation

/// The configuration profile with a CalDAV and a CardDAV account, built by NoDrive itself. The server's own profile
/// has no password and carries the server's theme name, so it is not used. Pure: no network, no UI, no state.
///
/// The keys are Apple's (apple/device-management: `TopLevel`, `com.apple.caldav.account`, `com.apple.carddav.account`).
enum NCDeviceSyncProfile {
    struct Account: Equatable {
        /// The account's server URL (https only), e.g. "https://drive.nourax.org".
        let base: String
        /// The server's user id (the path of the principal).
        let userId: String
        /// The login name the server answered for the new password.
        let loginName: String
        /// The app's account key (user and server), only used to make the stable `PayloadIdentifier`.
        let accountKey: String
    }

    enum BuildError: Error, Equatable {
        case needsHTTPS
        case noHost
    }

    /// `PayloadIdentifier` of the profile: stable per account, so an install replaces the profile installed before.
    static func identifier(accountKey: String, bundleIdentifier: String) -> String {
        let digest = SHA256.hash(data: Data(accountKey.utf8))
        let prefix = digest.map { String(format: "%02x", $0) }.joined().prefix(16)
        return "\(bundleIdentifier).devicesync.\(prefix)"
    }

    /// `https://<host>[:port][/prefix]/remote.php/dav/principals/users/<uid>/`, the user id percent-encoded as one path part.
    static func principalURL(base: String, userId: String) -> String? {
        guard let parts = URLComponents(string: base), let host = parts.host, !host.isEmpty else { return nil }
        var root = parts.percentEncodedPath
        while root.hasSuffix("/") {
            root.removeLast()
        }
        var origin = "https://" + host
        if let port = parts.port, port != 443 {
            origin += ":\(port)"
        }
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let encoded = userId.addingPercentEncoding(withAllowedCharacters: allowed) ?? userId
        return origin + root + "/remote.php/dav/principals/users/" + encoded + "/"
    }

    /// The profile as XML property list data. `password` is the separate app password; the caller keeps it in memory
    /// only and wipes it after the flow.
    static func build(account: Account,
                      password: String,
                      bundleIdentifier: String,
                      newUUID: () -> String = { UUID().uuidString }) throws -> Data {
        guard let parts = URLComponents(string: account.base), let host = parts.host, !host.isEmpty else {
            throw BuildError.noHost
        }
        guard parts.scheme?.lowercased() == "https", let principal = principalURL(base: account.base, userId: account.userId) else {
            throw BuildError.needsHTTPS
        }
        let port = parts.port ?? 443
        let top = identifier(accountKey: account.accountKey, bundleIdentifier: bundleIdentifier)

        func payload(type: String, prefix: String, name: String, suffix: String) -> [String: Any] {
            [
                "PayloadType": type,
                "PayloadVersion": 1,
                "PayloadIdentifier": top + "." + suffix,
                "PayloadUUID": newUUID(),
                "PayloadDisplayName": name,
                prefix + "AccountDescription": "NoDrive",
                prefix + "HostName": host,
                prefix + "Port": port,
                prefix + "UseSSL": true,
                prefix + "Username": account.loginName,
                prefix + "Password": password,
                prefix + "PrincipalURL": principal
            ]
        }

        let profile: [String: Any] = [
            "PayloadType": "Configuration",
            "PayloadVersion": 1,
            "PayloadIdentifier": top,
            "PayloadUUID": newUUID(),
            "PayloadDisplayName": NCDeviceSync.profileName,
            "PayloadOrganization": "Nourax",
            "PayloadDescription": "Adds your NoDrive calendars, reminders and contacts to this iPhone.",
            "PayloadRemovalDisallowed": false,
            "PayloadContent": [
                payload(type: "com.apple.caldav.account", prefix: "CalDAV", name: "NoDrive Calendar", suffix: "caldav"),
                payload(type: "com.apple.carddav.account", prefix: "CardDAV", name: "NoDrive Contacts", suffix: "carddav")
            ]
        ]
        return try PropertyListSerialization.data(fromPropertyList: profile, format: .xml, options: 0)
    }

    /// A copy of a built profile with both passwords replaced, for the UI test's results folder.
    static func redacted(_ data: Data) -> Data? {
        guard var root = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any],
              var content = root["PayloadContent"] as? [[String: Any]] else { return nil }
        for index in content.indices {
            for key in ["CalDAVPassword", "CardDAVPassword"] where content[index][key] != nil {
                content[index][key] = "<redacted>"
            }
        }
        root["PayloadContent"] = content
        return try? PropertyListSerialization.data(fromPropertyList: root, format: .xml, options: 0)
    }
}
