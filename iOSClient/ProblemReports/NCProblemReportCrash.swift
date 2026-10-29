// SPDX-FileCopyrightText: 2026 Nourax
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import MetricKit

// Crash capture without a third-party SDK. Two sources:
//  1. an uncaught-exception handler that writes name, reason and call stack to a file (the file is read at the
//     next start; the handler chains the handler that was there before it);
//  2. Apple's MetricKit, which hands the app the crash diagnostics of an earlier run (Swift traps, signals,
//     watchdog kills) after the next launch. MetricKit sends nothing to anyone: the system delivers the data to
//     the app, and the app decides whether a report is sent.

// The handler is a C function pointer: it cannot capture anything, so its state lives in these globals.
private var nodriveCrashFileURL: URL?
private var nodrivePreviousExceptionHandler: (@convention(c) (NSException) -> Void)?
private var nodriveExceptionHandlerInstalled = false

enum NCProblemReportCrash {
    // MARK: Uncaught exceptions

    /// Installs the handler (once). `url` is the file the next start reads. Calling it again only moves the file.
    static func installExceptionHandler(writingTo url: URL) {
        nodriveCrashFileURL = url
        guard !nodriveExceptionHandlerInstalled else { return }
        nodriveExceptionHandlerInstalled = true
        nodrivePreviousExceptionHandler = NSGetUncaughtExceptionHandler()
        NSSetUncaughtExceptionHandler { exception in
            if let url = nodriveCrashFileURL {
                NCProblemReportCrash.write(NCProblemReportCrash.exceptionText(exception), to: url)
            }
            // Whoever was there before still gets the exception; then the app ends as it would have.
            nodrivePreviousExceptionHandler?(exception)
        }
    }

    /// Puts the previous handler back. For tests only.
    static func removeExceptionHandlerForTests() {
        guard nodriveExceptionHandlerInstalled else { return }
        NSSetUncaughtExceptionHandler(nodrivePreviousExceptionHandler)
        nodrivePreviousExceptionHandler = nil
        nodriveCrashFileURL = nil
        nodriveExceptionHandlerInstalled = false
    }

    static func exceptionText(_ exception: NSException) -> String {
        var lines = ["Uncaught exception",
                     "Name: \(exception.name.rawValue)",
                     "Reason: \(exception.reason ?? "")",
                     "Time: \(ISO8601DateFormatter().string(from: Date()))",
                     "Call stack:"]
        lines.append(contentsOf: exception.callStackSymbols)
        return lines.joined(separator: "\n") + "\n"
    }

    private static func write(_ text: String, to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(text.utf8).write(to: url, options: .atomic)
    }

    /// The text the handler wrote, and the file is removed; nil when the last run ended without an exception.
    static func takePendingException(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        try? FileManager.default.removeItem(at: url)
        let text = String(decoding: data, as: UTF8.self)
        return text.isEmpty ? nil : text
    }

    // MARK: MetricKit diagnostics -> text

    private static let summaryKeys = ["exceptionType", "exceptionCode", "signal", "terminationReason", "applicationVersion",
                                      "appBuildVersion", "osVersion", "deviceType"]

    /// `crash.txt` text for one crash diagnostic given as JSON (the old `jsonRepresentation()` shape or the
    /// encoded iOS 27 diagnostic): a few readable lines first, then the whole JSON with the call stacks.
    static func crashText(fromDiagnosticJSON data: Data) -> String {
        var lines = ["MetricKit crash diagnostic"]
        guard let object = try? JSONSerialization.jsonObject(with: data) else {
            lines.append(String(decoding: data, as: UTF8.self))
            return lines.joined(separator: "\n") + "\n"
        }
        for key in summaryKeys {
            if let value = find(key, in: object, depth: 0) {
                lines.append("\(key): \(value)")
            }
        }
        if let pretty = try? JSONSerialization.data(withJSONObject: object,
                                                    options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) {
            lines.append("")
            lines.append("Diagnostic JSON:")
            lines.append(String(decoding: pretty, as: UTF8.self))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// The first scalar value stored under `key`, looking at most four levels deep and never inside call stacks.
    private static func find(_ key: String, in object: Any, depth: Int) -> String? {
        guard depth < 4, let dictionary = object as? [String: Any] else { return nil }
        if let value = dictionary[key], !(value is [String: Any]), !(value is [Any]) {
            return "\(value)"
        }
        for (name, value) in dictionary.sorted(by: { $0.key < $1.key }) where name != "callStackTree" {
            if let found = find(key, in: value, depth: depth + 1) {
                return found
            }
        }
        return nil
    }
}

/// Crash diagnostics that MetricKit delivered, waiting for the next report. One small JSON file each.
struct NCMetricKitStore {
    let directory: URL

    private struct Stored: Codable {
        var version: String
        var text: String
    }

    func save(text: String, version: String) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(UUID().uuidString + ".json")
        if let data = try? JSONEncoder().encode(Stored(version: version, text: text)) {
            try? data.write(to: url, options: .atomic)
        }
    }

    var hasDiagnostics: Bool {
        !files().isEmpty
    }

    /// Every stored diagnostic, and the files are removed.
    func takeAll() -> [String] {
        var texts: [String] = []
        for url in files() {
            if let data = try? Data(contentsOf: url), let stored = try? JSONDecoder().decode(Stored.self, from: data) {
                texts.append(stored.text)
            }
            try? FileManager.default.removeItem(at: url)
        }
        return texts
    }

    private func files() -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}

/// Receives MetricKit's crash diagnostics. iOS 27 has the new `MetricManager` with an async sequence; iOS 17 to 26
/// use `MXMetricManager` and its subscriber. Either way a diagnostic of another app build is ignored.
final class NCMetricKitCollector: NSObject, MXMetricManagerSubscriber {
    private let store: NCMetricKitStore
    private let build: String
    private let shortVersion: String
    private var modernTask: Task<Void, Never>?
    /// Called after a diagnostic was stored (on any thread).
    var onSaved: (@Sendable () -> Void)?

    init(store: NCMetricKitStore, build: String, shortVersion: String) {
        self.store = store
        self.build = build
        self.shortVersion = shortVersion
        super.init()
    }

    func start() {
        if #available(iOS 27.0, *) {
            startModern()
        } else {
            MXMetricManager.shared.add(self)
        }
    }

    // iOS 17 to 26
    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            for diagnostic in payload.crashDiagnostics ?? [] {
                let version = diagnostic.metaData.applicationBuildVersion
                guard version.isEmpty || version == build else { continue }
                store.save(text: NCProblemReportCrash.crashText(fromDiagnosticJSON: diagnostic.jsonRepresentation()),
                           version: version)
                onSaved?()
            }
        }
    }

    // iOS 27
    @available(iOS 27.0, *)
    private func startModern() {
        let manager = MetricManager(enabledStateReportingDomains: [])
        let store = self.store
        let build = self.build
        let shortVersion = self.shortVersion
        let onSaved = self.onSaved
        modernTask = Task.detached {
            for await report in manager.diagnosticReports {
                guard case .crash = report.result else { continue }
                // The environment names the build that crashed; "contains" because the type may be optional.
                let version = "\(report.environment.applicationVersion)"
                guard version.isEmpty || version.contains(shortVersion) || version.contains(build) else { continue }
                guard let data = try? JSONEncoder().encode(report) else { continue }
                store.save(text: NCProblemReportCrash.crashText(fromDiagnosticJSON: data), version: version)
                onSaved?()
            }
        }
    }
}
