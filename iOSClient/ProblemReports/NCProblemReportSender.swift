// SPDX-FileCopyrightText: 2026 Nourax
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import NextcloudKit

/// The four requests a report needs, all to the signed-in account's own server. Results are HTTP status codes
/// (201 for "done", the server's code otherwise, a negative number when no answer came).
protocol NCProblemReportTransport {
    /// The host the requests go to (the account's server).
    var host: String { get }
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

/// Uploads reports and keeps the ones that could not be sent. Nothing here talks to any host but the transport's.
struct NCProblemReportSender {
    /// The folder in the user's files, and the account that gets read access to it.
    static let folderName = "Problem reports"
    static let supportUser = "nourax-support"
    static let keepPending = 5

    let transport: NCProblemReportTransport?
    /// Where unsent reports wait (the app's own folder).
    let pendingDirectory: URL
    /// Where the zip is written while it is uploaded.
    let workDirectory: URL

    // MARK: A new report

    /// Sends the zip, or keeps it for later. `fileName` is the name the report has in the Drive.
    func send(zip: Data, fileName: String) async -> NCProblemReportOutcome {
        guard let transport else {
            keep(zip, as: fileName)
            return .noAccount
        }
        var shareTried = false
        let outcome = await upload(zip: zip, fileName: fileName, transport: transport, shareTried: &shareTried)
        if outcome == .keptForLater {
            keep(zip, as: fileName)
        }
        return outcome
    }

    /// Tries the reports kept on the phone, oldest first. Returns nil when there was nothing to send, and the
    /// outcome of the last one otherwise. A failure stops the round (the next report or sign-in tries again).
    func sendPending() async -> NCProblemReportOutcome? {
        guard let transport else { return nil }
        var last: NCProblemReportOutcome?
        var shareTried = false
        for url in pendingFiles() {
            guard let zip = try? Data(contentsOf: url) else { continue }
            let outcome = await upload(zip: zip, fileName: url.lastPathComponent, transport: transport, shareTried: &shareTried)
            last = outcome
            if outcome == .keptForLater {
                break
            }
            try? FileManager.default.removeItem(at: url)
        }
        return last
    }

    var hasPending: Bool {
        !pendingFiles().isEmpty
    }

    // MARK: Steps

    /// MKCOL, PUT (never over an existing file), then the share to Support, at most once for this round.
    private func upload(zip: Data, fileName: String, transport: NCProblemReportTransport, shareTried: inout Bool) async -> NCProblemReportOutcome {
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

        // The share is tried once per round and report, never in a loop. Failing quietly is the normal case until
        // the Workspace has created the account.
        if shareTried {
            return .savedNotShared
        }
        shareTried = true
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

    private func keep(_ zip: Data, as fileName: String) {
        try? FileManager.default.createDirectory(at: pendingDirectory, withIntermediateDirectories: true)
        try? zip.write(to: pendingDirectory.appendingPathComponent(fileName), options: .atomic)
        // Names start with a UTC timestamp: sorted by name is sorted by time. Older ones beyond five go.
        let files = pendingFiles()
        if files.count > Self.keepPending {
            for url in files.prefix(files.count - Self.keepPending) {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    /// Oldest first.
    func pendingFiles() -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: pendingDirectory, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension == "zip" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
