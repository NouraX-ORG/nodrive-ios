// SPDX-FileCopyrightText: 2026 Nourax
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Which photo a renamed upload stands for.
///
/// When a photo is uploaded as `IMG_0001 1.HEIC`, the upload history records that name only, and the next library
/// scan looks for `IMG_0001.HEIC`: it would queue the photo again and make yet another copy on every scan. The
/// ledger keeps "new name -> original name" until the renamed upload has succeeded; the history then also records
/// the original name. It is a small JSON file in the app's own Application Support folder (only the app process
/// completes uploads), written atomically.
actor NCConflictRenameLedger {
    struct Entry: Codable, Equatable {
        let account: String
        let serverUrlBase: String
        let newName: String
        let originalName: String
        let assetLocalIdentifier: String
        let date: Date
        let created: Date
    }

    /// Entries are dropped after 90 days.
    static let maxAge: TimeInterval = 90 * 24 * 3600

    private let url: URL
    private let now: () -> Date
    private var entries: [String: Entry] = [:]
    private var loaded = false

    init(url: URL? = nil, now: @escaping () -> Date = { Date() }) {
        self.url = url ?? Self.defaultUrl()
        self.now = now
    }

    private static func defaultUrl() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("NoDrive", isDirectory: true).appendingPathComponent("auto-upload-renames.json")
    }

    private static func key(account: String, serverUrlBase: String, name: String) -> String {
        account + "\u{1F}" + serverUrlBase + "\u{1F}" + name
    }

    // MARK: - Reading and writing

    func record(account: String, serverUrlBase: String, newName: String, originalName: String,
                assetLocalIdentifier: String, date: Date) {
        load()
        let entry = Entry(account: account, serverUrlBase: serverUrlBase, newName: newName, originalName: originalName,
                          assetLocalIdentifier: assetLocalIdentifier, date: date, created: now())
        entries[Self.key(account: account, serverUrlBase: serverUrlBase, name: newName)] = entry
        save()
    }

    /// The entry of a renamed upload, by its new name.
    func entry(account: String, serverUrlBase: String, newName: String) -> Entry? {
        load()
        return entries[Self.key(account: account, serverUrlBase: serverUrlBase, name: newName)]
    }

    /// The entry of an upload that was renamed away from `originalName` (a second queue item of the same photo).
    func entry(account: String, serverUrlBase: String, originalName: String, assetLocalIdentifier: String) -> Entry? {
        load()
        return entries.values.first {
            $0.account == account && $0.serverUrlBase == serverUrlBase
                && $0.originalName == originalName && $0.assetLocalIdentifier == assetLocalIdentifier
        }
    }

    func remove(account: String, serverUrlBase: String, newName: String) {
        load()
        if entries.removeValue(forKey: Self.key(account: account, serverUrlBase: serverUrlBase, name: newName)) != nil {
            save()
        }
    }

    var count: Int {
        load()
        return entries.count
    }

    // MARK: - File

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: url) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let list = try? decoder.decode([Entry].self, from: data) else { return }
        let limit = now().addingTimeInterval(-Self.maxAge)
        var pruned = false
        for entry in list {
            if entry.created < limit {
                pruned = true
                continue
            }
            entries[Self.key(account: entry.account, serverUrlBase: entry.serverUrlBase, name: entry.newName)] = entry
        }
        if pruned { save() }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(Array(entries.values)) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
