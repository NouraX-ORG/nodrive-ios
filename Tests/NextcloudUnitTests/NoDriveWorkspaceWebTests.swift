// SPDX-FileCopyrightText: 2026 Nourax
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import SafariServices
import Testing
import UIKit
@preconcurrency import WebKit
@testable import Nextcloud

/// The Workspace web screen's wiring: its user agent, what an account's removal clears and closes, the
/// navigation policy (redirects, new windows, session expiry), and the sidebar and notification routes.
@Suite("NoDrive Workspace web")
@MainActor
struct NoDriveWorkspaceWebTests {
    let base = "https://drive.nourax.org"
    let own = URL(string: "https://drive.nourax.org/apps/mail/")!
    let foreign = URL(string: "https://foreign.nodrive-ci.test/redirected")!

    /// Records what a screen decided to do.
    final class Recorder {
        var loads: [URL] = []
        var signIns: [URL] = []
        var failures = 0
        var panels: [URL] = []
        var system: [URL] = []
        var closes = 0
    }

    private func makeController(account: String = "citest https://drive.nourax.org",
                                url: URL? = nil) -> NCWorkspaceWebViewController {
        NCWorkspaceWebViewController(account: account, url: url ?? own, title: "Mail", base: base)
    }

    private func record(_ controller: NCWorkspaceWebViewController) -> Recorder {
        let recorder = Recorder()
        controller.effects = NCWorkspaceWebViewController.Effects(
            load: { recorder.loads.append($0) },
            signIn: { recorder.signIns.append($0) },
            failure: { recorder.failures += 1 },
            openPanel: { recorder.panels.append($0) },
            openSystem: { recorder.system.append($0) },
            close: { recorder.closes += 1 }
        )
        return recorder
    }

    private func sessionCookie(host: String = "drive.nourax.org") throws -> HTTPCookie {
        try #require(HTTPCookie(properties: [
            .name: "oc_sessionPassphrase", .value: "x", .path: "/", .domain: host, .secure: "TRUE"
        ]))
    }

    @Test("The web view adds NoDrive to the system's user agent")
    func userAgentName() {
        #expect(NCWorkspaceWebViewController.applicationName == "Mobile/15E148 NoDrive")
    }

    // MARK: - Removing an account

    @Test("Removing an account clears the server's web data from the default store")
    func forgetClearsDefaultStore() async throws {
        let host = "drive.nourax.org"
        let store = WKWebsiteDataStore.default()
        let cookie = try sessionCookie(host: host)
        await store.httpCookieStore.setCookie(cookie)
        let before = await store.httpCookieStore.allCookies().filter { $0.domain == host }
        #expect(!before.isEmpty)

        await NCWorkspaceWeb.shared.forget(account: "citest-default https://\(host)", urlBase: "https://\(host)")

        let after = await store.httpCookieStore.allCookies().filter { $0.domain == host }
        #expect(after.isEmpty)
    }

    @Test("Removing an account forgets its app list (only NCWorkspaceWeb.forget is called)")
    func forgetRemovesTheAppList() async throws {
        let account = "citest-list \(UUID().uuidString) https://drive.nourax.org"
        let apps = NCWorkspaceAppsStore.shared
        let transport = NoDriveWorkspaceAppsTests.Transport()
        transport.answers = [(200, NoDriveWorkspaceAppsTests.fixture, nil)]
        let request = URLRequest(url: URL(string: "https://drive.nourax.org/ocs/v2.php/core/navigation/apps?format=json")!)
        _ = await apps.refresh(account: account, base: base, request: request, force: true, now: Date(), fetch: transport.fetch)
        #expect(!apps.cached(account: account).isEmpty)

        await NCWorkspaceWeb.shared.forget(account: account, urlBase: base)

        #expect(apps.cached(account: account).isEmpty)
    }

    @Test("Removing an account closes its Workspace screen, empties the store that screen really uses and ends its use")
    func forgetClosesTheScreenAndClearsItsStore() async throws {
        let account = "citest-screen https://drive.nourax.org"
        let controller = makeController(account: account)
        controller.loadViewIfNeeded()
        let store = try #require(controller.websiteDataStore)
        // The screen has its own, in-memory store (not the default one)
        #expect(!store.isPersistent)
        #expect(store !== WKWebsiteDataStore.default())

        let cookie = try sessionCookie()
        await store.httpCookieStore.setCookie(cookie)
        #expect(await store.httpCookieStore.allCookies().count == 1)
        var left = 0
        controller.leaveHandler = { left += 1 }
        #expect(!controller.isInvalidated)

        await NCWorkspaceWeb.shared.forget(account: account, urlBase: base)

        // Closed, empty, and unusable
        #expect(left == 1)
        #expect(controller.isInvalidated)
        #expect(await store.httpCookieStore.allCookies().isEmpty)
        #expect(controller.view.subviews.allSatisfy { !($0 is WKWebView) })
        let recorder = record(controller)
        #expect(controller.policy(forMainFrameNavigationTo: own) == .cancel)
        controller.handleNewWindow(to: own)
        #expect(recorder.loads.isEmpty && recorder.signIns.isEmpty)

        // A second removal does not close it again
        await NCWorkspaceWeb.shared.forget(account: account, urlBase: base)
        #expect(left == 1)
    }

    @Test("Every open screen of the account closes, a screen of another account stays")
    func forgetClosesAllScreensOfTheAccountOnly() async throws {
        let account = "citest-many https://drive.nourax.org"
        let first = makeController(account: account)
        let second = makeController(account: account, url: URL(string: "https://drive.nourax.org/apps/calendar/")!)
        let other = makeController(account: "other-user https://drive.nourax.org")
        for controller in [first, second, other] {
            controller.loadViewIfNeeded()
        }
        var closed: [String] = []
        first.leaveHandler = { closed.append("first") }
        second.leaveHandler = { closed.append("second") }
        other.leaveHandler = { closed.append("other") }
        let otherStore = try #require(other.websiteDataStore)
        let cookie = try sessionCookie()
        await otherStore.httpCookieStore.setCookie(cookie)

        await NCWorkspaceWeb.shared.forget(account: account, urlBase: base)

        #expect(closed.sorted() == ["first", "second"])
        #expect(first.isInvalidated && second.isInvalidated)
        #expect(!other.isInvalidated)
        #expect(await otherStore.httpCookieStore.allCookies().count == 1)
        // Clean up the other screen
        await NCWorkspaceWeb.shared.forget(account: "other-user https://drive.nourax.org", urlBase: base)
        #expect(other.isInvalidated)
    }

    @Test("Each screen has its own data store, so a later sign-in starts with nothing")
    func screensDoNotShareStores() async throws {
        let account = "citest-fresh https://drive.nourax.org"
        let old = makeController(account: account)
        old.loadViewIfNeeded()
        let oldStore = try #require(old.websiteDataStore)
        let cookie = try sessionCookie()
        await oldStore.httpCookieStore.setCookie(cookie)
        await NCWorkspaceWeb.shared.forget(account: account, urlBase: base)

        let fresh = makeController(account: account)
        fresh.loadViewIfNeeded()
        let freshStore = try #require(fresh.websiteDataStore)
        #expect(freshStore !== oldStore)
        #expect(await freshStore.httpCookieStore.allCookies().isEmpty)
        await NCWorkspaceWeb.shared.forget(account: account, urlBase: base)
    }

    // MARK: - Redirects, new windows, session expiry

    @Test("A server redirect to another host opens the browser panel and never loads in the Workspace view")
    func redirectToAnotherHost() {
        let controller = makeController()
        let recorder = record(controller)
        #expect(controller.policy(forMainFrameNavigationTo: foreign) == .cancel)
        #expect(recorder.panels == [foreign])
        #expect(recorder.loads.isEmpty && recorder.signIns.isEmpty)
        // The page to come back to stays the account's own page
        #expect(controller.lastPageURL == own)
        // The same for the look-alikes
        for text in ["https://drive.nourax.org@evil.example/", "http://drive.nourax.org/apps/mail/",
                     "https://drive.nourax.org:8443/apps/mail/", "https://drive.nourax.org.evil.example/"] {
            let url = URL(string: text)!
            #expect(controller.policy(forMainFrameNavigationTo: url) == .cancel, "\(text)")
            #expect(recorder.panels.last == url, "\(text)")
        }
    }

    @Test("window.open and target=_blank: another host goes to the browser panel, never to a second web view")
    func newWindows() {
        let controller = makeController()
        let recorder = record(controller)

        controller.handleNewWindow(to: URL(string: "https://foreign.nodrive-ci.test/window-open")!)
        #expect(recorder.panels.map(\.path) == ["/window-open"])

        // The account's own page loads in this view
        let calendar = URL(string: "https://drive.nourax.org/apps/calendar/")!
        controller.handleNewWindow(to: calendar)
        #expect(recorder.loads == [calendar])
        #expect(recorder.panels.count == 1)

        // mailto: and tel: go to the system; other schemes nowhere
        controller.handleNewWindow(to: URL(string: "mailto:someone@example.org")!)
        controller.handleNewWindow(to: URL(string: "tel:+4912345")!)
        #expect(recorder.system.count == 2)
        for text in ["javascript:alert(1)", "data:text/html,x", "file:///etc/hosts", "blob:https://drive.nourax.org/x", "about:srcdoc"] {
            controller.handleNewWindow(to: URL(string: text)!)
        }
        #expect(recorder.loads == [calendar])
        #expect(recorder.panels.count == 1)
        #expect(recorder.system.count == 2)
    }

    @Test("A new window to the login page signs in again; to the log-out page closes the screen")
    func newWindowToLoginAndLogout() {
        let controller = makeController()
        let recorder = record(controller)
        controller.handleNewWindow(to: URL(string: "https://drive.nourax.org/login")!)
        #expect(recorder.signIns == [own])
        controller.handleNewWindow(to: URL(string: "https://drive.nourax.org/logout?requesttoken=x")!)
        #expect(recorder.closes == 1)
    }

    @Test("Session expiry: a login page signs in again by itself and returns to the last page; a second one inside a minute shows the error")
    func sessionExpiry() {
        let controller = makeController()
        let recorder = record(controller)

        // The user moves to the calendar; that is the page to come back to
        let calendar = URL(string: "https://drive.nourax.org/index.php/apps/calendar/")!
        #expect(controller.policy(forMainFrameNavigationTo: calendar) == .allow)
        #expect(controller.lastPageURL == calendar)

        // The server answers the next page with its login page: the web view must not show it
        let login = URL(string: "https://drive.nourax.org/login?redirect_url=%2Fapps%2Fcalendar")!
        #expect(controller.policy(forMainFrameNavigationTo: login) == .cancel)
        #expect(recorder.signIns == [calendar])
        #expect(recorder.failures == 0)
        #expect(recorder.loads.isEmpty)

        // The single-sign-on login page is caught the same way, but not twice within a minute
        let oidc = URL(string: "https://drive.nourax.org/apps/user_oidc/login/1")!
        #expect(controller.policy(forMainFrameNavigationTo: oidc) == .cancel)
        #expect(recorder.signIns.count == 1)
        #expect(recorder.failures == 1)
    }

    @Test("about:blank and other non-pages are not remembered as the page to come back to")
    func lastPageIsARealPage() {
        let controller = makeController()
        _ = record(controller)
        #expect(controller.policy(forMainFrameNavigationTo: URL(string: "about:blank")!) == .allow)
        #expect(controller.lastPageURL == own)
        #expect(controller.policy(forMainFrameNavigationTo: URL(string: "https://drive.nourax.org/apps/talk/")!) == .allow)
        #expect(controller.lastPageURL.path == "/apps/talk/")
    }

    @Test("The log-out page closes the screen and keeps the account")
    func logoutPage() {
        let controller = makeController()
        let recorder = record(controller)
        #expect(controller.policy(forMainFrameNavigationTo: URL(string: "https://drive.nourax.org/logout")!) == .cancel)
        #expect(recorder.closes == 1)
        #expect(recorder.signIns.isEmpty)
    }

    // MARK: - Menu and notification routes

    @Test("An outside menu entry opens the browser panel, never the signed-in Workspace view")
    func outsideEntryOpensThePanel() throws {
        let presenter = UIViewController()
        var presented: UIViewController?
        let nomail = URL(string: "https://mail.nourax.org/")!
        let opened = NCWorkspaceWeb.shared.openOutside(nomail, from: presenter) { panel, from in
            presented = panel
            #expect(from === presenter)
        }
        #expect(opened)
        let panel = try #require(presented as? SFSafariViewController)
        #expect(!(panel is UINavigationController))
        // Nothing but plain https opens
        for text in ["http://mail.nourax.org/", "javascript:alert(1)", "https://drive.nourax.org@evil.example/", "mailto:a@b.example"] {
            presented = nil
            let result = NCWorkspaceWeb.shared.openOutside(URL(string: text)!, from: presenter, present: { panel, _ in presented = panel })
            #expect(!result, "\(text)")
            #expect(presented == nil, "\(text)")
        }
    }

    @Test("A notification link of the account's own server opens the Workspace screen with a Close button")
    func notificationLinkOpensInApp() async throws {
        let session = NCSession.Session(account: "citest https://drive.nourax.org", urlBase: base, user: "citest", userId: "citest")
        let presenter = UIViewController()
        var presented: UINavigationController?
        let link = URL(string: "https://drive.nourax.org/apps/spreed/call/abc")!

        let opened = NCWorkspaceWeb.shared.openLink(link, session: session, from: presenter) { navigation, from in
            presented = navigation
            #expect(from === presenter)
        }

        #expect(opened)
        let navigation = try #require(presented)
        #expect(navigation.modalPresentationStyle == .fullScreen)
        let screen = try #require(navigation.topViewController as? NCWorkspaceWebViewController)
        #expect(screen.showsCloseButton)
        #expect(screen.account == session.account)
        #expect(screen.lastPageURL == link)
        // Clean up
        await NCWorkspaceWeb.shared.forget(account: session.account, urlBase: base)
    }

    @Test("Notification links of another server are not taken in")
    func foreignLinksAreNotOpened() {
        let session = NCSession.Session(account: "citest https://drive.nourax.org", urlBase: "https://drive.nourax.org",
                                        user: "citest", userId: "citest")
        let presenter = UIViewController()
        var presentedAny = false
        let capture: (UINavigationController, UIViewController) -> Void = { _, _ in presentedAny = true }
        let foreign = URL(string: "https://evil.example/apps/spreed")!
        #expect(!NCWorkspaceWeb.shared.openLink(foreign, session: session, from: presenter, present: capture))
        let lookalike = URL(string: "https://drive.nourax.org@evil.example/")!
        #expect(!NCWorkspaceWeb.shared.openLink(lookalike, session: session, from: presenter, present: capture))
        let otherPort = URL(string: "https://drive.nourax.org:8443/apps/spreed")!
        #expect(!NCWorkspaceWeb.shared.openLink(otherPort, session: session, from: presenter, present: capture))
        let signedOut = NCSession.Session(account: "", urlBase: "", user: "", userId: "")
        let own = URL(string: "https://drive.nourax.org/apps/spreed")!
        #expect(!NCWorkspaceWeb.shared.openLink(own, session: signedOut, from: presenter, present: capture))
        #expect(!presentedAny)
    }
}
