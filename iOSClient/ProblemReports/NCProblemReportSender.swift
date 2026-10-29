// SPDX-FileCopyrightText: 2026 Nourax
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import NextcloudKit

/// The four requests a report needs, all to the signed-in account's own server. Results are HTTP status codes
/// (201 for "done", the server's code otherwise, a negative number when no answer came).
protocol NCProblemReportTransport {
    /// The host the requests go to (the account's server).
    var host: String { get }
    /// Names the signed-in account (user and server). Reports kept on the phone are tied to it.
    var accountId: String { get }
    /// MKCOL of a folder in the user's files: 201 created, 405 already there.
    func makeFolder(_ name: String) async -> Int
    /// PUT of a local file into the user's files with the headers; 201 created, 412 when the name exists.
    func upload(localPath: String, remotePath: String, headers: [String: String]) async -> Int
    /// The user names this folder is shared with (share type 0); nil when the list could not be read.
    func usersSharedWith(path: String) async -> [String]?
    /// A read-only share of the folder with the user; true when the server accepted it.
    func shareReadOnly(path: String, with user: String) async -> Bool
}

/// Sends through the app's own NextcloudKit session of the signed-in account.
struct NCNextcloudKitReportTransport: NCProblemReportTransport {
    let account: String
    let urlBase: String
    let userId: String

    var host: String { URL(string: urlBase)?.host ?? "" }

    var accountId: String { account }

    private var filesBase: String { "\(urlBase)/remote.php/dav/files/\(userId)" }

    func makeFolder(_ name: String) async -> Int {
        let result = await NextcloudKit.shared.createFolderAsync(serverUrlFileName: "\(filesBase)/\(name)", account: account)
        return result.error.errorCode == 0 ? 201 : result.error.errorCode
    }

    func upload(localPath: String, remotePath: String, headers: [String: String]) async -> Int {
        let result = await NextcloudKit.shared.uploadAsync(serverUrlFileName: "\(filesBase)/\(remotePath)",
                                                           fileNameLocalPath: localPath,
                                                           account: account,
                                                           options: NKRequestOptions(customHeader: headers))
        return result.error.errorCode == 0 ? 201 : result.error.errorCode
    }

    func usersSharedWith(path: String) async -> [String]? {
        let result = await NextcloudKit.shared.readSharesAsync(parameters: NKShareParameter(path: path), account: account)
        guard result.error.errorCode == 0 else { return nil }
        return (result.shares ?? []).filter { $0.shareType == 0 }.map { $0.shareWith }
    }

    func shareReadOnly(path: String, with user: String) async -> Bool {
        let result = await NextcloudKit.shared.createShareAsync(path: path, shareType: 0, shareWith: user,
                                                                permissions: 1, account: account)
        return result.error.errorCode == 0
    }
}

/// What happened to a report.
enum NCProblemReportOutcome: Equatable {
    /// Uploaded and shared with Nourax Support (or it was already shared).
    case sent
    /// Uploaded; the share to Support failed (the account may not exist yet). The report is saved in the Drive.
    case savedNotShared
    /// Not uploaded (offline, server error): kept on the phone and tried again later.
    case keptForLater
    /// There is no signed-in account: kept on the phone, sent after the next sign-in.
    case noAccount
}

/// What the share step found, remembered for the rest of one round of sends: the share is looked at once, and
/// every later report of the round gets the same answer ("sent" when the folder is shared, otherwise "saved").
final class NCProblemReportShareRound {
    var outcome: NCProblemReportOutcome?
}

/// Uploads reports and keeps the ones that could not be sent. Nothing here talks to any host but the transport's.
struct NCProblemReportSender {
    /// The folder in the user's files, and the account that gets read access to it.
    static let folderName = "Problem reports"
    static let supportUser = "nourax-support"
    static let keepPending = 5
    /// A kept report names the account it was made for in a file next to it (`<name>.zip.account`).
    private static let accountSuffix = ".account"

    let transport: NCProblemReportTransport?
    /// Where unsent reports wait (the app's own folder).
    let pendingDirectory: URL
    /// Where the zip is written while it is uploaded.
    let workDirectory: URL
    /// The other waiting room; the newest five reports are kept over both.
    var otherPendingDirectory: URL?

    // MARK: A new report

    /// Sends the zip, or keeps it for later. `fileName` is the name the report has in the Drive.
    func send(zip: Data, fileName: String) async -> NCProblemReportOutcome {
        guard let transport else {
            keep(zip, as: fileName)
            return .noAccount
        }
        let outcome = await upload(zip: zip, fileName: fileName, transport: transport, round: NCProblemReportShareRound())
        if outcome == .keptForLater {
            keep(zip, as: fileName, accountId: transport.accountId)
        }
        return outcome
    }

    /// Tries the reports kept on the phone, oldest first. Returns nil when there was nothing to send, the outcome
    /// of the last report that went out otherwise, and `.keptForLater` when the first one already failed. A
    /// failure stops the round (the next report or sign-in tries again). Reports made for another account are
    /// dropped, not sent: they would put the old user's file names into the new user's Drive.
    func sendPending(round: NCProblemReportShareRound = NCProblemReportShareRound()) async -> NCProblemReportOutcome? {
        guard let transport else { return nil }
        var delivered: NCProblemReportOutcome?
        var failed = false
        for url in pendingFiles() {
            if let owner = accountOfPending(url), owner != transport.accountId {
                discard(url)
                continue
            }
            guard let zip = try? Data(contentsOf: url) else { continue }
            let outcome = await upload(zip: zip, fileName: url.lastPathComponent, transport: transport, round: round)
            if outcome == .keptForLater {
                failed = true
                break
            }
            delivered = outcome
            discard(url)
        }
        return delivered ?? (failed ? .keptForLater : nil)
    }

    var hasPending: Bool {
        !pendingFiles().isEmpty
    }

    // MARK: Steps

    /// MKCOL, PUT (never over an existing file), then the share to Support, looked at once for the round.
    private func upload(zip: Data, fileName: String, transport: NCProblemReportTransport, round: NCProblemReportShareRound) async -> NCProblemReportOutcome {
        let folder = await transport.makeFolder(Self.folderName)
        guard folder == 201 || folder == 405 else { return .keptForLater }

        try? FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        var uploaded = false
        var name = fileName
        for attempt in 0..<4 {
            if attempt > 0 {
                // 412: a file with this name is there already. A new name from the current second; never replace.
                name = Self.shiftedName(fileName, seconds: attempt)
            }
            let local = workDirectory.appendingPathComponent(UUID().uuidString + ".zip")
            guard (try? zip.write(to: local, options: .atomic)) != nil else { return .keptForLater }
            let status = await transport.upload(localPath: local.path,
                                                remotePath: "\(Self.folderName)/\(name)",
                                                headers: ["If-None-Match": "*"])
            try? FileManager.default.removeItem(at: local)
            if status == 201 {
                uploaded = true
                break
            }
            if status != 412 {
                return .keptForLater
            }
        }
        guard uploaded else { return .keptForLater }

        // The share is tried once per round, never in a loop, and the answer holds for every report of the round.
        // Failing quietly is the normal case until the Workspace has created the account.
        if let known = round.outcome {
            return known
        }
        let outcome = await shareWithSupport(transport: transport)
        round.outcome = outcome
        return outcome
    }

    private func shareWithSupport(transport: NCProblemReportTransport) async -> NCProblemReportOutcome {
        let path = "/\(Self.folderName)"
        guard let sharedWith = await transport.usersSharedWith(path: path) else {
            return .savedNotShared
        }
        if sharedWith.contains(Self.supportUser) {
            return .sent
        }
        return await transport.shareReadOnly(path: path, with: Self.supportUser) ? .sent : .savedNotShared
    }

    /// `2026-10-28_11-44-03_ios_1.zip` -> the same name `seconds` later (the timestamp is the part before `_ios_`).
    static func shiftedName(_ fileName: String, seconds: Int) -> String {
        guard let range = fileName.range(of: "_ios_") else { return "\(seconds)_" + fileName }
        let stamp = String(fileName[..<range.lowerBound])
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        guard let date = formatter.date(from: stamp) else { return "\(seconds)_" + fileName }
        return formatter.string(from: date.addingTimeInterval(TimeInterval(seconds))) + String(fileName[range.lowerBound...])
    }

    // MARK: Pending reports (the app's own files; the newest five are kept)

    /// `accountId` is nil when there was no account: such a report goes to whoever signs in next.
    private func keep(_ zip: Data, as fileName: String, accountId: String? = nil) {
        try? FileManager.default.createDirectory(at: pendingDirectory, withIntermediateDirectories: true)
        let url = pendingDirectory.appendingPathComponent(fileName)
        try? zip.write(to: url, options: .atomic)
        if let accountId {
            try? Data(accountId.utf8).write(to: Self.accountFile(of: url), options: .atomic)
        }
        // Names start with a UTC timestamp: sorted by name is sorted by time. Older ones beyond five go, counted
        // over both waiting rooms.
        let files = (pendingFiles() + otherPendingFiles()).sorted { $0.lastPathComponent < $1.lastPathComponent }
        if files.count > Self.keepPending {
            for old in files.prefix(files.count - Self.keepPending) {
                discard(old)
            }
        }
    }

    /// Oldest first.
    func pendingFiles() -> [URL] {
        Self.zips(in: pendingDirectory)
    }

    private func otherPendingFiles() -> [URL] {
        otherPendingDirectory.map { Self.zips(in: $0) } ?? []
    }

    private static func zips(in directory: URL) -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension == "zip" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static func accountFile(of zip: URL) -> URL {
        zip.deletingLastPathComponent().appendingPathComponent(zip.lastPathComponent + accountSuffix)
    }

    private func accountOfPending(_ zip: URL) -> String? {
        guard let data = try? Data(contentsOf: Self.accountFile(of: zip)) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// Removes a kept report (the app's own file) with its account note.
    private func discard(_ zip: URL) {
        try? FileManager.default.removeItem(at: zip)
        try? FileManager.default.removeItem(at: Self.accountFile(of: zip))
    }

    /// Removes every report kept here.
    func discardPending() {
        for url in pendingFiles() { discard(url) }
    }
}
