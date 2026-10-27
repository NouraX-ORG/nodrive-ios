// SPDX-FileCopyrightText: 2026 Nourax
// SPDX-License-Identifier: GPL-3.0-or-later

import UIKit
@preconcurrency import WebKit
import SafariServices

/// Keeps track of the open Workspace web screens, clears their data when an account goes, and routes links.
@MainActor
final class NCWorkspaceWeb {
    static let shared = NCWorkspaceWeb()

    private struct WeakController {
        weak var controller: NCWorkspaceWebViewController?
    }

    private var controllers: [WeakController] = []

    /// Everything a site can keep, except the browsing history: asking for the history makes the system query
    /// Screen Time, which can stall for minutes (seen in the simulator: 3 minutes per call). The Workspace
    /// screens never write history, so nothing is missed.
    static let websiteDataTypes: Set<String> = [
        WKWebsiteDataTypeCookies, WKWebsiteDataTypeLocalStorage, WKWebsiteDataTypeSessionStorage,
        WKWebsiteDataTypeIndexedDBDatabases, WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache,
        WKWebsiteDataTypeServiceWorkerRegistrations, WKWebsiteDataTypeFetchCache
    ]

    func register(_ controller: NCWorkspaceWebViewController) {
        controllers.removeAll { $0.controller == nil }
        controllers.append(WeakController(controller: controller))
    }

    /// Notification links (design rule 9): a link to the account's own server opens inside the app, already
    /// signed in. Returns false for every other link; the caller keeps today's behaviour for those.
    /// - Parameter present: how the screen is put on top of `presenter`; nil presents it full screen (tests pass
    ///   their own to see what would be shown).
    func openLink(_ url: URL,
                  session: NCSession.Session,
                  from presenter: UIViewController,
                  present: ((UINavigationController, UIViewController) -> Void)? = nil) -> Bool {
        guard !session.account.isEmpty,
              NCWorkspaceOrigin.route(link: url.absoluteString, base: session.urlBase) == .inApp else { return false }
        let controller = NCWorkspaceWebViewController(account: session.account, url: url, title: "",
                                                      showsCloseButton: true, base: session.urlBase)
        let navigationController = UINavigationController(rootViewController: controller)
        navigationController.setNavigationBarAppearance()
        navigationController.modalPresentationStyle = .fullScreen
        if let present {
            present(navigationController, presenter)
        } else {
            presenter.present(navigationController, animated: true)
        }
        return true
    }

    /// A menu entry of another origin (NoMail): the in-app browser panel, which has its own cookie jar and holds
    /// no NoDrive credential, cookie or session. Only plain https addresses open; the signed-in Workspace web
    /// view is never used for them.
    func openOutside(_ url: URL,
                     from presenter: UIViewController,
                     present: ((UIViewController, UIViewController) -> Void)? = nil) -> Bool {
        guard NCWorkspaceOrigin.isOutsideLink(url.absoluteString) else { return false }
        let panel = SFSafariViewController(url: url)
        if let present {
            present(panel, presenter)
        } else {
            presenter.present(panel, animated: true)
        }
        return true
    }

    /// Signing out or removing an account (also a remote wipe): closes every open screen of that account, the one
    /// in the main view included, and drops their data stores and sessions; forgets the app list, and
    /// removes everything the system's default web data store holds for the server (the screens themselves use
    /// a non-persistent store, so nothing of theirs was ever written to disk).
    func forget(account: String, urlBase: String) async {
        let closing = controllers.compactMap { $0.controller }.filter { $0.account == account }
        controllers.removeAll { $0.controller == nil || $0.controller?.account == account }
        for controller in closing {
            await controller.invalidate()
        }
        NCWorkspaceAppsStore.shared.forget(account: account)

        guard let host = URL(string: urlBase)?.host?.lowercased(), !host.isEmpty else { return }
        let store = WKWebsiteDataStore.default()
        let types = Self.websiteDataTypes
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
