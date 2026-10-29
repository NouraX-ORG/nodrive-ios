// SPDX-FileCopyrightText: 2026 Nourax
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import UIKit

enum NCProblemReportKind: String {
    case crash
    case manual
    case uncleanExit = "unclean-exit"
}

/// The facts about the app and the device that go into `report.json`.
struct NCProblemReportInfo {
    var appVersion: String
    var build: String
    var osVersion: String
    var deviceModel: String
    var locale: String
    /// The host of the signed-in account's server; empty without an account.
    var serverHost: String

    @MainActor
    static func current(serverHost: String) -> NCProblemReportInfo {
        NCProblemReportInfo(appVersion: nouraxVersion,
                            build: (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "",
                            osVersion: UIDevice.current.systemVersion,
                            deviceModel: deviceModelIdentifier(),
                            locale: Locale.current.identifier,
                            serverHost: serverHost)
    }

    /// `iPhone17,1` on a device; the simulated model in the Simulator.
    static func deviceModelIdentifier() -> String {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"], !simulated.isEmpty {
            return simulated
        }
        var system = utsname()
        uname(&system)
        return withUnsafeBytes(of: &system.machine) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }
}

/// One log file as read from disk: its name, its modification time, and its newest bytes.
struct NCProblemReportLogFile {
    let name: String
    let modified: Date
    let data: Data
}

/// Builds the report zip: `report.json`, `crash.txt` (a crash only) and `logs/`. Everything that is text goes
/// through the scrubber first. The zip is at most 5,000,000 bytes: the oldest log lines are dropped first.
enum NCProblemReportBuilder {
    /// 5 MB as the contract counts it.
    static let maxZipBytes = 5_000_000
    /// The crash text is cut after this many bytes.
    static let maxCrashBytes = 512 * 1024
    /// At most this many bytes of log text are even looked at (newest first).
    static let maxLogBytes = 8_000_000
    static let maxNoteCharacters = 4_000

    // MARK: Names

    /// `2026-10-28_11-44-03_ios_35.2.1-nourax.1.zip` (UTC).
    static func fileName(date: Date, appVersion: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-")
        let version = String(appVersion.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
        return "\(formatter.string(from: date))_ios_\(version.isEmpty ? "unknown" : version).zip"
    }

    // MARK: report.json

    static func reportJSON(kind: NCProblemReportKind, info: NCProblemReportInfo, date: Date, note: String) -> Data {
        let iso = ISO8601DateFormatter()
        iso.timeZone = TimeZone(identifier: "UTC")
        iso.formatOptions = [.withInternetDateTime]
        let fields: [(String, String)] = [
            ("schema", "1"),
            ("kind", json(kind.rawValue)),
            ("app", json("NoDrive iOS")),
            ("app_version", json(info.appVersion)),
            ("build", json(info.build)),
            ("platform", json("ios")),
            ("os_version", json(info.osVersion)),
            ("device_model", json(info.deviceModel)),
            ("locale", json(info.locale)),
            ("created_utc", json(iso.string(from: date))),
            ("server_host", json(info.serverHost)),
            ("user_note", json(NCProblemReportScrubber.scrub(String(note.prefix(maxNoteCharacters)))))
        ]
        let body = fields.map { "  \(json($0.0)): \($0.1)" }.joined(separator: ",\n")
        return Data("{\n\(body)\n}\n".utf8)
    }

    private static func json(_ text: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard let data = try? encoder.encode(text), let string = String(data: data, encoding: .utf8) else { return "\"\"" }
        return string
    }

    // MARK: The zip

    /// The finished zip. `logs` may be in any order; the newest are kept when there is not enough room.
    static func build(kind: NCProblemReportKind,
                      note: String,
                      crashText: String?,
                      logs: [NCProblemReportLogFile],
                      info: NCProblemReportInfo,
                      date: Date) -> Data {
        let reportData = reportJSON(kind: kind, info: info, date: date, note: note)
        var fixed = [NCProblemReportZip.Entry(name: "report.json", data: reportData)]
        if let crashText {
            let scrubbed = NCProblemReportScrubber.scrub(crashText)
            fixed.append(.init(name: "crash.txt", data: Data(Data(scrubbed.utf8).prefix(maxCrashBytes))))
        }

        // Newest first; look at no more than maxLogBytes, cut at a line start, and scrub what is left.
        var remaining = maxLogBytes
        var scrubbed: [(name: String, data: Data)] = []
        for log in logs.sorted(by: { $0.modified > $1.modified }) where remaining > 0 {
            let kept = newestLines(of: log.data, atMost: remaining)
            remaining -= kept.count
            guard !kept.isEmpty else { continue }
            let text = NCProblemReportScrubber.scrub(String(decoding: kept, as: UTF8.self))
            scrubbed.append((safeLogName(log.name), Data(text.utf8)))
        }

        var budget = scrubbed.reduce(0) { $0 + $1.data.count }
        while true {
            var entries = fixed
            var left = budget
            for log in scrubbed where left > 0 {
                let kept = newestLines(of: log.data, atMost: left)
                left -= kept.count
                if !kept.isEmpty {
                    entries.append(.init(name: "logs/\(log.name)", data: kept))
                }
            }
            let zip = NCProblemReportZip.archive(entries, date: date)
            if zip.count <= maxZipBytes || budget == 0 {
                return zip
            }
            // Drop the oldest lines: keep a share of the log text that should fit, with a margin.
            let share = Double(maxZipBytes) / Double(zip.count) * 0.85
            budget = min(Int(Double(budget) * share), max(budget - 1, 0))
        }
    }

    /// The last `limit` bytes of `data`, starting at the beginning of a line (a cut line is dropped).
    static func newestLines(of data: Data, atMost limit: Int) -> Data {
        guard data.count > limit else { return data }
        guard limit > 0 else { return Data() }
        var tail = data.suffix(limit)
        if let newline = tail.firstIndex(of: 0x0A) {
            tail = tail[tail.index(after: newline)...]
            return Data(tail)
        }
        return Data()
    }

    private static func safeLogName(_ name: String) -> String {
        let base = (name as NSString).lastPathComponent
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        let cleaned = String(base.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
        return cleaned.isEmpty ? "log.txt" : cleaned
    }

    // MARK: Reading the app's log folder

    /// The log files of NextcloudKit's logger (`log.txt`, `log-<date>.txt`), each as its newest bytes.
    static func readLogs(in directory: URL?, maxBytes: Int = maxLogBytes) -> [NCProblemReportLogFile] {
        guard let directory,
              let urls = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey], options: [.skipsHiddenFiles])
        else { return [] }
        var result: [NCProblemReportLogFile] = []
        for url in urls {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey])
            guard values?.isRegularFile == true else { continue }
            guard let handle = try? FileHandle(forReadingFrom: url) else { continue }
            defer { try? handle.close() }
            let size = (try? handle.seekToEnd()) ?? 0
            let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
            try? handle.seek(toOffset: start)
            let data = (try? handle.readToEnd()) ?? Data()
            result.append(NCProblemReportLogFile(name: url.lastPathComponent,
                                                 modified: values?.contentModificationDate ?? .distantPast,
                                                 data: data))
        }
        return result
    }
}
