// SPDX-FileCopyrightText: 2026 Nourax
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import NextcloudKit

/// The database and file work behind the resolver. A protocol, so the tests run it with a fake.
protocol NCConflictStore {
    func policy(account: String) -> NCConflictPolicy
    /// Size in bytes of the file the app will upload (the app's own extracted copy); 0 when it cannot be read.
    func localSize(of metadata: tableMetadata) -> Int64
    /// True when a queued or known item of the app already uses this name in this folder.
    func isNameQueued(_ fileName: String, serverUrl: String, account: String) async -> Bool
    /// The other part of a Live Photo that is waiting in the queue, if any.
    func mate(of metadata: tableMetadata) async -> tableMetadata?
    /// Already in NoDrive: leave the upload queue and enter the upload history (no upload, no notification).
    func markDone(_ metadata: tableMetadata) async
    /// Gives the waiting uploads of one photo (or the two parts of a Live Photo) their new names, all or none: the
    /// app's extracted copies move with them. Returns the updated rows in the order given, or `nil` when a copy
    /// failed (then nothing was changed).
    func rename(_ renames: [NCConflictRename]) async -> [tableMetadata]?
    /// Records a name in the upload history of an Auto upload destination.
    func recordUploaded(account: String, serverUrlBase: String, fileName: String, assetLocalIdentifier: String, date: Date) async
}

/// One waiting upload and the name it gets.
struct NCConflictRename {
    let metadata: tableMetadata
    let newName: String
    let livePhotoFile: String?
}

/// The real store: the app's Realm database and file helpers, existing ones only.
struct NCDatabaseConflictStore: NCConflictStore {
    private let database = NCManageDatabase.shared
    private let utility = NCUtilityFileSystem()
    private let policies = NCConflictPolicyStore()

    func policy(account: String) -> NCConflictPolicy {
        policies.policy(account: account)
    }

    /// The place of a file of the app's extracted copies. Unlike the upstream overload with `fileName`, it never
    /// creates an empty file there.
    private func path(of metadata: tableMetadata, fileName: String) -> String {
        utility.getDirectoryProviderStorageOcId(metadata.ocId, userId: metadata.userId, urlBase: metadata.urlBase) + "/" + fileName
    }

    func localSize(of metadata: tableMetadata) -> Int64 {
        let size = utility.getFileSize(filePath: path(of: metadata, fileName: metadata.fileName))
        return size > 0 ? size : metadata.size
    }

    func isNameQueued(_ fileName: String, serverUrl: String, account: String) async -> Bool {
        await database.getMetadataAsync(predicate: NSPredicate(format: "fileNameView == %@ AND serverUrl == %@ AND account == %@",
                                                               fileName, serverUrl, account)) != nil
    }

    func mate(of metadata: tableMetadata) async -> tableMetadata? {
        let predicate = NSPredicate(format: "account == %@ AND serverUrl == %@ AND assetLocalIdentifier == %@ AND sessionSelector == %@ AND ocId != %@ AND isExtractFile == true AND status == %d AND livePhotoFile != ''",
                                    metadata.account,
                                    metadata.serverUrl,
                                    metadata.assetLocalIdentifier,
                                    NCGlobal.shared.selectorUploadAutoUpload,
                                    metadata.ocId,
                                    NCGlobal.shared.metadataStatusWaitUpload)
        let rows = await database.getMetadatasAsync(predicate: predicate)
        return rows.first { $0.isLivePhotoImage != metadata.isLivePhotoImage }
    }

    func markDone(_ metadata: tableMetadata) async {
        await database.completeExistingAutoUploadAsync(metadata)
    }

    func rename(_ renames: [NCConflictRename]) async -> [tableMetadata]? {
        // 1. Copy the files of every part first. The app's own extracted copy is a temporary file of the upload
        //    queue; the photo in the library is never touched. When a copy fails, the copies made so far are
        //    dropped and nothing else changes, so no part uploads alone under a number its partner never gets.
        var made: [String] = []
        var moves: [(from: String, to: String)] = []
        for rename in renames {
            let oldPath = path(of: rename.metadata, fileName: rename.metadata.fileName)
            let newPath = path(of: rename.metadata, fileName: rename.newName)
            if oldPath != newPath {
                guard utility.copyFile(atPath: oldPath, toPath: newPath) else {
                    for copy in made {
                        utility.removeFile(atPath: copy)
                    }
                    return nil
                }
                made.append(newPath)
            }
            moves.append((oldPath, newPath))
        }

        // 2. The database, 3. drop the old copies.
        var updatedRows: [tableMetadata] = []
        for rename in renames {
            let updated = rename.metadata.detachedCopy()
            updated.fileName = rename.newName
            updated.fileNameView = rename.newName
            updated.serverUrlFileName = utility.createServerUrl(serverUrl: rename.metadata.serverUrl, fileName: rename.newName)
            if let livePhotoFile = rename.livePhotoFile {
                updated.livePhotoFile = livePhotoFile
            }
            await database.addMetadataAsync(updated)
            updatedRows.append(updated)
        }
        for move in moves where move.from != move.to {
            utility.removeFile(atPath: move.from)
        }
        return updatedRows
    }

    func recordUploaded(account: String, serverUrlBase: String, fileName: String, assetLocalIdentifier: String, date: Date) async {
        await database.addAutoUploadTransferAsync(account: account,
                                                  serverUrlBase: serverUrlBase,
                                                  fileName: fileName,
                                                  assetLocalIdentifier: assetLocalIdentifier,
                                                  date: date)
    }
}

/// Applies the setting "If a file is already in NoDrive" to a group of Auto upload items.
///
/// `resolve` runs one call at a time. A Swift actor alone does not give that (it lets another call in whenever one
/// waits for the server or the database), so the calls queue on a small lock: two upload passes that overlap (the
/// foreground and the background one) cannot pick the same new number for two different photos.
///
/// Never in any choice: a DELETE, a MOVE onto an existing name, or touching an existing file on the Drive except
/// under "Keep the phone copy". A server answer that is not clear is "retry later", never a guess.
actor NCConflictResolver {
    private let store: NCConflictStore
    private let probe: NCRemoteProbe
    private let ledger: NCConflictRenameLedger

    private var busy = false
    private var queue: [CheckedContinuation<Void, Never>] = []

    init(store: NCConflictStore, probe: NCRemoteProbe, ledger: NCConflictRenameLedger) {
        self.store = store
        self.probe = probe
        self.ledger = ledger
    }

    /// The lock is handed on to the next waiting call without ever being free in between.
    private func acquire() async {
        if busy {
            await withCheckedContinuation { queue.append($0) }
        } else {
            busy = true
        }
    }

    private func release() {
        if queue.isEmpty {
            busy = false
        } else {
            queue.removeFirst().resume()
        }
    }

    /// Takes the items of Auto upload that were just read from the library and returns those that must be uploaded
    /// now, with their (possibly new) names. The others were marked as done or wait for the next pass. Items that
    /// are not Auto upload items come back unchanged.
    func resolve(_ extracted: [tableMetadata]) async -> [tableMetadata] {
        await acquire()
        defer { release() }
        var result: [tableMetadata] = []
        var seen = Set<String>()
        let listed = Set(extracted.map(\.ocId))

        for row in extracted where !seen.contains(row.ocId) {
            seen.insert(row.ocId)
            guard row.sessionSelector == NCGlobal.shared.selectorUploadAutoUpload else {
                result.append(row)
                continue
            }
            var unit = [row]
            if row.isLivePhoto {
                if let mate = extracted.first(where: { !seen.contains($0.ocId) && isMate($0, of: row) }) {
                    seen.insert(mate.ocId)
                    unit.append(mate)
                } else if let mate = await store.mate(of: row) {
                    unit.append(mate)
                }
            }
            // The photo first, then its video.
            unit.sort { $0.isLivePhotoImage && !$1.isLivePhotoImage }
            let upload = await resolveUnit(unit)
            result.append(contentsOf: upload.filter { listed.contains($0.ocId) })
        }
        return result
    }

    private func isMate(_ other: tableMetadata, of row: tableMetadata) -> Bool {
        other.isLivePhoto
            && other.account == row.account
            && other.serverUrl == row.serverUrl
            && other.assetLocalIdentifier == row.assetLocalIdentifier
            && other.isLivePhotoImage != row.isLivePhotoImage
    }

    // MARK: - One file or one Live Photo

    private func resolveUnit(_ unit: [tableMetadata]) async -> [tableMetadata] {
        let account = unit[0].account
        let policy = store.policy(account: account)

        // A second queue item of a photo whose renamed copy is already waiting or uploaded.
        var allSecondItems = true
        for part in unit where allSecondItems {
            allSecondItems = await isSecondItem(part)
        }
        if allSecondItems {
            for part in unit {
                await store.markDone(part)
            }
            return []
        }

        var parts: [NCConflictPart] = []
        for part in unit {
            // "Keep the phone copy" needs no answer from the server.
            let remote: NCConflictRemoteState = policy == .keepPhone
                ? .missing
                : await probe.state(of: part.serverUrlFileName, account: account)
            parts.append(NCConflictPart(name: part.fileName, localSize: store.localSize(of: part), remote: remote))
        }

        switch NCConflictDecision.decide(policy: policy, parts: parts) {
        case .retryLater:
            return []

        case .upload(let skipping):
            var upload: [tableMetadata] = []
            for (index, part) in unit.enumerated() {
                if skipping.contains(index) {
                    await store.markDone(part)
                    if let base = part.autoUploadServerUrlBase {
                        await uploaded(account: part.account, serverUrlBase: base, fileName: part.fileName)
                    }
                } else {
                    upload.append(part)
                }
            }
            return upload

        case .renameAll:
            return await rename(unit)
        }
    }

    private func isSecondItem(_ part: tableMetadata) async -> Bool {
        guard let base = part.autoUploadServerUrlBase,
              !part.assetLocalIdentifier.isEmpty,
              let entry = await ledger.entry(account: part.account,
                                             serverUrlBase: base,
                                             originalName: part.fileName,
                                             assetLocalIdentifier: part.assetLocalIdentifier) else { return false }
        // Only while the renamed copy is still in the queue; a stale entry never hides a photo.
        return await store.isNameQueued(entry.newName, serverUrl: part.serverUrl, account: part.account)
    }

    private func rename(_ unit: [tableMetadata]) async -> [tableMetadata] {
        let serverUrl = unit[0].serverUrl
        let account = unit[0].account
        let store = self.store
        guard let newNames = await NCConflictNaming.freeNames(for: unit.map(\.fileName),
                                                              serverUrl: serverUrl,
                                                              account: account,
                                                              probe: probe,
                                                              isQueued: { await store.isNameQueued($0, serverUrl: serverUrl, account: account) }) else {
            return []
        }

        let renames = unit.enumerated().map { index, part in
            NCConflictRename(metadata: part,
                             newName: newNames[index],
                             livePhotoFile: unit.count == 2 ? newNames[1 - index] : nil)
        }
        // All parts or none: a failed copy means retry later.
        guard let updatedRows = await store.rename(renames), updatedRows.count == unit.count else { return [] }

        for (index, part) in unit.enumerated() {
            guard let base = part.autoUploadServerUrlBase else { continue }
            // A part that was renamed before keeps its first original name.
            let earlier = await ledger.entry(account: part.account, serverUrlBase: base, newName: part.fileName)
            await ledger.record(account: part.account,
                                serverUrlBase: base,
                                newName: newNames[index],
                                originalName: earlier?.originalName ?? part.fileName,
                                assetLocalIdentifier: part.assetLocalIdentifier,
                                date: part.creationDate as Date)
            if earlier != nil {
                await ledger.remove(account: part.account, serverUrlBase: base, newName: part.fileName)
            }
        }
        return updatedRows
    }

    // MARK: - History

    /// A name is in NoDrive (uploaded, or found there): when it was a renamed copy, the original name of the photo
    /// also enters the upload history, so the next library scan does not queue the photo again.
    func uploaded(account: String, serverUrlBase: String, fileName: String) async {
        guard let entry = await ledger.entry(account: account, serverUrlBase: serverUrlBase, newName: fileName) else { return }
        await store.recordUploaded(account: account,
                                   serverUrlBase: serverUrlBase,
                                   fileName: entry.originalName,
                                   assetLocalIdentifier: entry.assetLocalIdentifier,
                                   date: entry.date)
        await ledger.remove(account: account, serverUrlBase: serverUrlBase, newName: fileName)
    }
}

/// The hooks of the upstream upload code call this (`// NoDrive: ... (iOSClient/SmartConflicts)`).
final class NCAutoUploadConflicts {
    static let shared = NCAutoUploadConflicts()

    private let policies = NCConflictPolicyStore()
    private let resolver = NCConflictResolver(store: NCDatabaseConflictStore(),
                                              probe: NCWebDAVProbe(),
                                              ledger: NCConflictRenameLedger())

    /// True only for "Keep the NoDrive copy": the cheap check of upstream (is the name there? then skip it) may run
    /// before the photo is read from the library. Every other choice needs the size of the extracted file.
    func upstreamPrecheck(_ account: tableAccount) -> Bool {
        policies.policy(account: account.account) == .keepNoDrive
    }

    /// True for the Auto upload items NoDrive decides: upstream's own "does the name exist" check skips them.
    /// Items that belong to a PhotoKit background upload keep upstream's check, which never overwrites.
    func handles(_ metadata: tableMetadata, backgroundResource: Bool) -> Bool {
        !backgroundResource && metadata.sessionSelector == NCGlobal.shared.selectorUploadAutoUpload
    }

    /// The items to upload now (see `NCConflictResolver.resolve`).
    func resolve(_ extracted: [tableMetadata], backgroundResource: Bool) async -> [tableMetadata] {
        guard !backgroundResource else { return extracted }
        return await resolver.resolve(extracted)
    }

    /// After an Auto upload succeeded: a renamed copy also records the photo's original name.
    func didUpload(_ rows: [tableAutoUploadTransfer]) async {
        for row in rows {
            await resolver.uploaded(account: row.account, serverUrlBase: row.serverUrlBase, fileName: row.fileName)
        }
    }
}
