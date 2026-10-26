// SPDX-FileCopyrightText: 2026 Nourax
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
import UIKit
@preconcurrency import WebKit
@testable import Nextcloud

/// The Workspace web screen's wiring: its user agent, what an account's removal clears, and the sidebar and
/// notification routes.
@Suite("NoDrive Workspace web")
@MainActor
struct NoDriveWorkspaceWebTests {
    @Test("The web view adds NoDrive to the system's user agent")
    func userAgentName() {
        #expect(NCWorkspaceWebViewController.applicationName == "Mobile/15E148 NoDrive")
    }

    @Test("Removing an account clears the server's web data from the default store and forgets its app list")
    func forgetClearsWebData() async throws {
        let host = "drive.nourax.org"
        let store = WKWebsiteDataStore.default()
        let cookie = try #require(HTTPCookie(properties: [
            .name: "oc_sessionPassphrase", .value: "x", .path: "/", .domain: host, .secure: "TRUE"
        ]))
        await store.httpCookieStore.setCookie(cookie)
        let before = await store.httpCookieStore.allCookies().filter { $0.domain == host }
        #expect(!before.isEmpty)

        let account = "citest https://\(host)"
        let apps = NCWorkspaceAppsStore.shared
        // The account's list sits in the shared store; forgetting removes it
        apps.forget(account: account)
        #expect(apps.cached(account: account).isEmpty)

        await NCWorkspaceWeb.shared.forget(account: account, urlBase: "https://\(host)")

        let after = await store.httpCookieStore.allCookies().filter { $0.domain == host }
        #expect(after.isEmpty)
    }

    @Test("Notification links of another server are not taken in")
    func foreignLinksAreNotOpened() {
        let session = NCSession.Session(account: "citest https://drive.nourax.org", urlBase: "https://drive.nourax.org",
                                        user: "citest", userId: "citest")
        let presenter = UIViewController()
        let foreign = URL(string: "https://evil.example/apps/spreed")!
        #expect(!NCWorkspaceWeb.shared.openLink(foreign, session: session, from: presenter))
        let lookalike = URL(string: "https://drive.nourax.org@evil.example/")!
        #expect(!NCWorkspaceWeb.shared.openLink(lookalike, session: session, from: presenter))
        let signedOut = NCSession.Session(account: "", urlBase: "", user: "", userId: "")
        let own = URL(string: "https://drive.nourax.org/apps/spreed")!
        #expect(!NCWorkspaceWeb.shared.openLink(own, session: signedOut, from: presenter))
    }
}
