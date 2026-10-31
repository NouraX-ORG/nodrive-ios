// SPDX-FileCopyrightText: 2026 Nourax
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import UIKit

/// Background refresh of NoAgenda. It shares the app's one refresh task (hook A7 of `NCAgendaBackground`): no new
/// background identifier. iOS decides how often it runs; NoAgenda never relies on it for correctness.
enum NCAgendaBackground {
    /// Called from the shared app-refresh task. Nothing happens for an account whose NoAgenda was never opened.
    static func refresh() async {
        guard let account = await NCManageDatabase.shared.getActiveTableAccountAsync()?.account else { return }
        _ = await refresh(store: NCAgendaStore.shared(for: account))
    }

    /// True when a refresh was done.
    @discardableResult
    static func refresh(store: NCAgendaStore) async -> Bool {
        guard await store.settings().openedOnce, !Task.isCancelled else { return false }
        let result = await store.refresh(cancellable: true)
        NCAgendaLog.log("background-refresh", count: result.snapshot.items.count)
        return true
    }

    /// For the Sources screen: is Background App Refresh switched off for the app?
    @MainActor
    static var isRefreshOff: Bool {
        UIApplication.shared.backgroundRefreshStatus != .available
    }
}
