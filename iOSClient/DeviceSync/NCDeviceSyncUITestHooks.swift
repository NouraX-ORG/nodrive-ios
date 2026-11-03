// SPDX-FileCopyrightText: 2026 Nourax
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

// UI tests only. The code exists in Debug builds only: a Release build gets the empty stub in the #else branch
// below, and tools/ci/workspace-check.py --debug-only checks that this file keeps its #if DEBUG wrapper.
#if DEBUG

/// Hooks for the simulator UI test of "Add to iPhone Calendar & Contacts". All of them need the launch argument
/// UI_TESTING.
///   - NODRIVE_DS_POLL_SECONDS: the sign-in polls this often (the test must not wait 5 s per poll);
///   - NODRIVE_DS_OUT: a folder; the profile that was built is written there with both passwords replaced by
///     "<redacted>" (devicesync-profile-redacted.mobileconfig). The real password is never written anywhere;
///   - NODRIVE_DS_REMOVE_ACCOUNT=1: 3 seconds after the section "Calendar and contacts" shows, the account is removed
///     the way Settings does it (`NCAccount().deleteAccount`), so the removal steps can be checked.
enum NCDeviceSyncUITestHooks {
    private static var environment: [String: String]? {
        let info = ProcessInfo.processInfo
        guard info.arguments.contains("UI_TESTING") else { return nil }
        return info.environment
    }

    static var pollInterval: TimeInterval? {
        guard let value = environment?["NODRIVE_DS_POLL_SECONDS"], let seconds = TimeInterval(value), seconds > 0 else { return nil }
        return seconds
    }

    static func profileBuilt(_ data: Data) {
        guard let folder = environment?["NODRIVE_DS_OUT"], !folder.isEmpty,
              let redacted = NCDeviceSyncProfile.redacted(data) else { return }
        let url = URL(fileURLWithPath: folder, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try? redacted.write(to: url.appendingPathComponent("devicesync-profile-redacted.mobileconfig"))
    }

    private static var removalScheduled = false

    @MainActor
    static func scheduleAccountRemovalIfRequested() {
        guard environment?["NODRIVE_DS_REMOVE_ACCOUNT"] == "1", !removalScheduled else { return }
        removalScheduled = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard let account = await NCManageDatabase.shared.getAccountsAsync()?.first else { return }
            await NCAccount().deleteAccount(account)
        }
    }
}

#else

enum NCDeviceSyncUITestHooks {
    static var pollInterval: TimeInterval? { nil }

    static func profileBuilt(_ data: Data) {}

    @MainActor
    static func scheduleAccountRemovalIfRequested() {}
}

#endif
