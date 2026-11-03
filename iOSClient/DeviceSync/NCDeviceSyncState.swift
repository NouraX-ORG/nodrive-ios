// SPDX-FileCopyrightText: 2026 Nourax
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import NextcloudKit

/// What "Add to iPhone Calendar & Contacts" writes to the app's log. Only fixed words and numbers can be passed in,
/// so the separate password, the sign-in token and the profile can never get into the log (the app's logs go into
/// problem reports).
enum NCDeviceSyncLog {
    /// Where the lines go. The tests replace it.
    static var sink: (String) -> Void = { line in
        nkLog(debug: line)
    }

    static func log(_ event: String, status: Int? = nil, count: Int? = nil) {
        var line = "devicesync " + event
        if let status { line += " status=\(status)" }
        if let count { line += " count=\(count)" }
        sink(line)
    }
}

enum NCDeviceSync {
    /// The user agent of the sign-in. The server names the new app password after it, so this is the name the person
    /// sees in the web security settings.
    static let deviceUserAgent = "NoDrive Calendar & Contacts (iPhone)"
    /// The name of the profile in Settings > General > VPN & Device Management.
    static let profileName = "NoDrive Calendar & Contacts"

    static func text(_ key: String) -> String {
        NSLocalizedString(key, tableName: "DeviceSync", comment: "")
    }
}

/// The only thing kept per account: that a profile was offered to this iPhone (no secret). It decides whether
/// removing the account shows the steps to remove the profile.
struct NCDeviceSyncState {
    var defaults: UserDefaults = .standard

    private func key(_ account: String) -> String {
        "NoDriveDeviceSyncProfileOffered " + account
    }

    func profileOffered(account: String) -> Bool {
        defaults.bool(forKey: key(account))
    }

    func setProfileOffered(_ value: Bool, account: String) {
        if value {
            defaults.set(true, forKey: key(account))
        } else {
            defaults.removeObject(forKey: key(account))
        }
    }
}

/// A secret held as bytes, for the length of the flow only. `wipe()` overwrites them with zeros; after that nothing
/// can be read. The bytes are never put in Keychain, a file, a log or a default.
final class NCDeviceSyncSecret: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: [UInt8]

    init(_ string: String) {
        bytes = Array(string.utf8)
    }

    init(data: Data) {
        bytes = [UInt8](data)
    }

    var isWiped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return bytes.isEmpty
    }

    /// A copy of the bytes for the moment of use, or nil after `wipe()`.
    func data() -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return bytes.isEmpty ? nil : Data(bytes)
    }

    func string() -> String? {
        guard let data = data() else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func wipe() {
        lock.lock()
        defer { lock.unlock() }
        bytes.withUnsafeMutableBytes { buffer in
            if let base = buffer.baseAddress, buffer.count > 0 {
                memset_s(base, buffer.count, 0, buffer.count)
            }
        }
        bytes.removeAll()
    }

    deinit {
        wipe()
    }
}
