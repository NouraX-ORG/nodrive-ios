// SPDX-FileCopyrightText: 2026 Nourax
// SPDX-License-Identifier: GPL-3.0-or-later

import Combine
import Foundation

/// The apps the sidebar shows for one account. It follows the store: when the list arrives or changes while the
/// sidebar is already open (or the account's list is forgotten), `apps` updates by itself, with no reopening.
@MainActor
final class NCWorkspaceAppsModel: ObservableObject {
    @Published private(set) var apps: [NCWorkspaceApp] = []

    private(set) var account = ""
    private let store: NCWorkspaceAppsStore
    private var observer: AnyCancellable?

    init(store: NCWorkspaceAppsStore = .shared, center: NotificationCenter = .default) {
        self.store = store
        observer = center.publisher(for: NCWorkspaceAppsStore.didChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                let changed = notification.userInfo?["account"] as? String
                MainActor.assumeIsolated {
                    self?.storeChanged(account: changed)
                }
            }
    }

    /// Shows the cached list of `account` (an empty menu until one is known).
    func show(account: String) {
        self.account = account
        reload()
    }

    /// Hides the list, for example while another account's list is being loaded.
    func clear() {
        account = ""
        reload()
    }

    private func storeChanged(account changed: String?) {
        guard !account.isEmpty, changed == account else { return }
        reload()
    }

    private func reload() {
        let list = account.isEmpty ? [] : store.cached(account: account)
        if list != apps {
            apps = list
        }
    }
}
