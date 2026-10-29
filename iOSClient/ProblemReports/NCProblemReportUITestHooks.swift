// SPDX-FileCopyrightText: 2026 Nourax
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

// UI tests only. The code exists in Debug builds only: a Release build gets the empty stub in the #else branch
// below, and tools/ci/workspace-check.py --debug-only checks that this file keeps its #if DEBUG wrapper.
#if DEBUG

/// Hooks for the simulator UI test of the problem reports.
///
/// With the launch argument UI_TESTING:
///   - without the environment variable NODRIVE_UITEST_REPORTS, crash and unclean-exit detection is off, so the
///     other UI tests, which relaunch the app many times, are never interrupted by the question;
///   - NODRIVE_UITEST_REPORTS=kill ends the app 25 seconds after the launch the way a crash or a watchdog does
///     (SIGKILL, no `willTerminate`), which leaves the run marker saying "foreground";
///   - NODRIVE_UITEST_REPORTS=raise first hands an exception to the exception handler that the app installed (the
///     handler writes the exception file and chains the previous handler), then ends the app the same way. The
///     process is not left to abort by itself, so the test runner does not see a crashed app.
enum NCProblemReportUITestHooks {
    private static var requested: String? {
        let info = ProcessInfo.processInfo
        guard info.arguments.contains("UI_TESTING") else { return nil }
        return info.environment["NODRIVE_UITEST_REPORTS"]
    }

    static var detectionSuppressed: Bool {
        ProcessInfo.processInfo.arguments.contains("UI_TESTING") && requested == nil
    }

    @MainActor
    static func scheduleIfRequested() {
        guard let mode = requested, mode == "kill" || mode == "raise" else { return }
        Task {
            try? await Task.sleep(for: .seconds(25))
            if mode == "raise" {
                let exception = NSException(name: NSExceptionName("NoDriveUITestException"),
                                            reason: "Raised by the UI test of the problem reports",
                                            userInfo: nil)
                NSGetUncaughtExceptionHandler()?(exception)
            }
            kill(getpid(), SIGKILL)
        }
    }
}

#else

enum NCProblemReportUITestHooks {
    static var detectionSuppressed: Bool { false }

    @MainActor
    static func scheduleIfRequested() {}
}

#endif
