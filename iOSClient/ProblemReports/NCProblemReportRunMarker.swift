// SPDX-FileCopyrightText: 2026 Nourax
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// The run marker: one small file that says what the app was doing when it last wrote it.
///
/// `didBecomeActive` writes `foreground` (and the build number), `didEnterBackground` writes `background`,
/// `willTerminate` removes the file. At the next launch a marker that still says `foreground` for the same
/// build means the app ended while it was on screen without a normal exit (crash, watchdog, memory, power).
/// iOS ends a suspended app in the background all the time: that is not counted. A marker of another build
/// (an update) is ignored.
struct NCProblemReportRunMarker {
    enum State: String, Codable {
        case foreground
        case background
    }

    struct Record: Codable, Equatable {
        var state: State
        var build: String
    }

    let url: URL

    func read() -> Record? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Record.self, from: data)
    }

    func write(_ state: State, build: String) {
        guard let data = try? JSONEncoder().encode(Record(state: state, build: build)) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }

    /// True when the previous run ended on screen without a normal exit. Call once per launch, before this
    /// run writes its own state.
    func previousRunEndedUncleanly(currentBuild: String) -> Bool {
        guard let record = read() else { return false }
        return record.state == .foreground && record.build == currentBuild
    }
}
