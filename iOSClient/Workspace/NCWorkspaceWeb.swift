// SPDX-FileCopyrightText: 2026 Nourax
// SPDX-License-Identifier: GPL-3.0-or-later

import UIKit
@preconcurrency import WebKit

/// Keeps track of the open Workspace web screens, clears their data when an account goes, and routes links.
@MainActor
final class NCWorkspaceWeb {
    static let shared = NCWorkspaceWeb()

    private struct WeakController {
        weak var controller: NCWorkspaceWebViewController?
    }

    private var controllers: [WeakController] = []

    func register(_ controller: NCWorkspaceWebViewController) {
        controllers.removeAll { $0.controller == nil }
        controllers.append(WeakController(controller: controller))
    }

    /// Notification links (design rule 9): a link to the account's own server opens inside the app, already
    /// signed in. Returns false for every other link; the caller keeps today's behaviour for those.
    func openLink(_ url: URL, session: NCSession.Session, from presenter: UIViewController) -> Bool {
        guard !session.account.isEmpty,
              NCWorkspaceOrigin.route(link: url.absoluteString, base: session.urlBase) == .inApp else { return false }
        let controller = NCWorkspaceWebViewController(account: session.account, url: url, title: "", showsCloseButton: true)
        let navigationController = UINavigationController(rootViewController: controller)
        navigationController.setNavigationBarAppearance()
        navigationController.modalPresentationStyle = .fullScreen
        presenter.present(navigationController, animated: true)
        return true
    }

    /// Signing out or removing an account: closes the open screens of that account, forgets the app list, and
    /// removes everything the system's default web data store holds for the server (the screens themselves use
    /// a non-persistent store, so nothing of theirs was ever written to disk).
    func forget(account: String, urlBase: String) async {
        for entry in controllers {
            if let controller = entry.controller, controller.account == account {
                controller.invalidate()
            }
        }
        controllers.removeAll { $0.controller == nil || $0.controller?.account == account }
        NCWorkspaceAppsStore.shared.forget(account: account)

        guard let host = URL(string: urlBase)?.host?.lowercased(), !host.isEmpty else { return }
        let store = WKWebsiteDataStore.default()
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        let records = await store.dataRecords(ofTypes: types)
        // A record's display name is the registrable domain ("nourax.org" for "drive.nourax.org").
        let matching = records.filter { record in
            let name = record.displayName.lowercased()
            return name == host || host.hasSuffix("." + name)
        }
        if !matching.isEmpty {
            await store.removeData(ofTypes: types, for: matching)
        }
    }
}
