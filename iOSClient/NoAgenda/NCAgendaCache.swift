// SPDX-FileCopyrightText: 2026 Nourax
// SPDX-License-Identifier: GPL-3.0-or-later

import CryptoKit
import Foundation

/// What is remembered about the last reads.
struct AgendaMeta: Codable, Equatable, Sendable {
    var me: AgendaMe?
    var calendarsSavedAt: Date?
    var ganttSavedAt: Date?
    var deckSavedAt: Date?
    var registrySavedAt: Date?
    var registryEtag: String?
    var ganttContractOK = true
    var deckReadWrite = true
}

/// The offline cache: JSON files in the app's own Application Support folder, one folder per account. It holds
/// what was read (calendars, NoGantt, NoBoard, the registry) and the settings. It never holds a password, a
/// token, a cookie or a header: only the decoded answers.
struct NCAgendaCache {
    let folder: URL

    static func defaultRoot() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("NoAgenda", isDirectory: true)
    }

    /// The account name is hashed so no user or server name is used as a file name.
    static func folderName(for account: String) -> String {
        SHA256.hash(data: Data(account.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    init(account: String, root: URL = NCAgendaCache.defaultRoot()) {
        folder = root.appendingPathComponent(Self.folderName(for: account), isDirectory: true)
    }

    func load<T: Decodable>(_ type: T.Type, name: String) -> T? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(name + ".json")) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    @discardableResult
    func save<T: Encodable>(_ value: T, name: String) -> Bool {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var mutableFolder = folder
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? mutableFolder.setResourceValues(values)
            let data = try JSONEncoder().encode(value)
            try data.write(to: folder.appendingPathComponent(name + ".json"),
                           options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            return true
        } catch {
            NCAgendaLog.log("cache-write-failed")
            return false
        }
    }

    func remove(name: String) {
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(name + ".json"))
    }

    /// Removes this account's whole folder.
    func removeAll() {
        try? FileManager.default.removeItem(at: folder)
    }

    /// Removes the cache of one account and nothing else.
    static func forget(account: String, root: URL = NCAgendaCache.defaultRoot()) {
        let folder = root.appendingPathComponent(folderName(for: account), isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
    }
}
