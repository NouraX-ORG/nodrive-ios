// SPDX-FileCopyrightText: 2026 Nourax
// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

/// The Workspace apps menu, end to end, in the simulator (CI job "screens").
///
/// The app signs in to a local stand-in for drive.nourax.org (tools/ci/drive-stand-in.py --workspace); the real
/// server is never contacted. The tests check:
///   1. the menu (the server's apps in order, no Files, Activity or Photos, NoMail as an outside entry), a list that
///      arrives after the sidebar opened, Mail signed in with no login page, a link to another host, and NoMail
///      opening in the browser panel;
///   2. every route to another host from a Workspace page (server redirect, new window, window.open) and an expired
///      session that the app renews by itself;
///   3. a second launch of the app, which must sign in again by itself (tools/ci/workspace-check.py checks the
///      sessions in the stand-in's log);
///   4. a notification link of the account's own server, which opens in the app, signed in.
///
/// Environment (pass with the TEST_RUNNER_ prefix to xcodebuild):
///   NODRIVE_UITEST_ACCOUNT  "server URL|login name|app password": the account the app creates at launch
///   NODRIVE_VARIANT         name of this run, e.g. workspace-light
///   NODRIVE_SHOTS_DIR       host folder; files go to <dir>/<variant>/
@MainActor
final class NoDriveWorkspaceUITests: XCTestCase {
    private let env = ProcessInfo.processInfo.environment
    private var variant: String { env["NODRIVE_VARIANT"] ?? "workspace" }
    private var springboard: XCUIApplication { XCUIApplication(bundleIdentifier: "com.apple.springboard") }
    private var safariViewService: XCUIApplication { XCUIApplication(bundleIdentifier: "com.apple.SafariViewService") }
    private let denyLabels = ["Don’t Allow", "Don't Allow", "Not Now", "Later"]
    private let continueLabels = ["Continue", "OK", "Allow"]
    private let doneLabels = ["Done", "Close"]
    private let expectedMenu = ["Dashboard", "Mail", "NoMail", "Calendar", "Talk", "Contacts"]
    private var promptCount = 0

    override func setUp() async throws {
        continueAfterFailure = true
    }

    // MARK: - 1. Menu, signed-in page, link to another host, NoMail

    func test1MenuSignedInPageAndForeignLink() throws {
        let app = try launchApp()

        // 1. The app signs the account in at launch and shows the main screen.
        let sidebarButton = app.buttons["openSidebar"]
        XCTAssertTrue(waitFor(sidebarButton, in: app, timeout: 300, hittable: true), "the main screen with the sidebar button never came up")
        save("01-main-screen")

        // 2. The sidebar opens at once; the stand-in sends the apps list late, so it has to arrive in the open sidebar.
        openSidebar(app)
        let mail = app.descendants(matching: .any)["sidebarWorkspaceApp-mail"]
        record("sidebar-open", ["apps_listed_at_open": mail.exists])
        let appeared = waitFor(mail, in: app, timeout: 90)
        XCTAssertTrue(appeared, "the sidebar has no Mail entry (the app list was not read from the server)")
        // Scroll so that the whole Apps section is in view (the last app is Contacts)
        scrollSidebar(until: app.descendants(matching: .any)["sidebarWorkspaceApp-contacts"], in: app)
        scrollSidebar(until: mail, in: app)
        Thread.sleep(forTimeInterval: 1)
        for hidden in ["files", "activity", "photos", "external_index1", "plainhttp", "userinfo"] {
            XCTAssertFalse(app.descendants(matching: .any)["sidebarWorkspaceApp-\(hidden)"].exists, "\(hidden) is listed")
        }
        let appNames = app.buttons.allElementsBoundByIndex.filter { $0.identifier.hasPrefix("sidebarWorkspaceApp-") }.map(\.label)
        record("sidebar-apps", ["names": appNames])
        save("02-workspace-menu")
        saveTexts(app, "02-workspace-menu")
        XCTAssertEqual(appNames, expectedMenu, "the menu shows the server's apps in the server's order")

        // 3. Mail opens inside the app, signed in; no login page at any time.
        XCTAssertTrue(mail.isHittable, "the Mail entry cannot be tapped")
        mail.tap()
        let signedIn = app.webViews.staticTexts["signed-in:Mail"]
        let shown = waitFor(signedIn, in: app, timeout: 120)
        XCTAssertTrue(shown, "the Mail page did not show the signed-in user")
        XCTAssertFalse(app.webViews.staticTexts["LOGIN"].exists, "a login page was shown")
        settle(app, seconds: 2)
        save("03-workspace-page")
        saveTexts(app, "03-workspace-page")
        record("page", ["signed_in": shown, "web_views": app.webViews.count])

        // 4. A link to another host leaves the Workspace screen: it opens in the browser panel.
        let foreign = app.webViews.links["Open the foreign test site"]
        if foreign.waitForExistence(timeout: 20) {
            foreign.tap()
            let opened = safariViewService.wait(for: .runningForeground, timeout: 60)
            XCTAssertTrue(opened, "the link to another host did not open in the in-app browser panel")
            let loaded = safariViewService.staticTexts["Another host"].waitForExistence(timeout: 60)
            XCTAssertTrue(loaded, "the other host's page never loaded in the browser panel")
            Thread.sleep(forTimeInterval: 2)
            save("04-foreign-link-panel")
            saveTexts(safariViewService, "04-foreign-link-panel")
            record("foreign-page", ["loaded": loaded])
            record("foreign", ["panel_opened": opened])
            closeBrowserPanel(app)
            save("05-after-panel")
            XCTAssertTrue(waitFor(signedIn, in: app, timeout: 30), "the Workspace page is gone after the panel closed")
        } else {
            XCTFail("the page has no link to another host")
        }

        // 5. NoMail (another origin) opens in the browser panel, never in the signed-in Workspace view.
        openSidebar(app)
        let nomail = app.descendants(matching: .any)["sidebarWorkspaceApp-nourax_nomail"]
        XCTAssertTrue(waitFor(nomail, in: app, timeout: 30), "the sidebar has no NoMail entry")
        scrollSidebar(until: nomail, in: app)
        XCTAssertTrue(nomail.isHittable, "the NoMail entry cannot be tapped")
        nomail.tap()
        let nomailOpened = safariViewService.wait(for: .runningForeground, timeout: 60)
        XCTAssertTrue(nomailOpened, "NoMail did not open in the in-app browser panel")
        let nomailLoaded = safariViewService.staticTexts["NoMail stand-in"].waitForExistence(timeout: 60)
        XCTAssertTrue(nomailLoaded, "the NoMail page never loaded in the browser panel")
        Thread.sleep(forTimeInterval: 2)
        save("06-nomail-panel")
        saveTexts(safariViewService, "06-nomail-panel")
        record("nomail", ["panel_opened": nomailOpened, "loaded": nomailLoaded])
        closeBrowserPanel(app)
        // The Workspace page that was open stays; NoMail never replaced it
        XCTAssertTrue(waitFor(signedIn, in: app, timeout: 30), "the Workspace page changed after NoMail")
        XCTAssertFalse(app.webViews.staticTexts["NoMail stand-in"].exists, "NoMail was shown in the Workspace view")
    }

    // MARK: - 2. Redirect, new windows, window.open, session expiry

    func test2RedirectNewWindowAndExpiredSession() throws {
        let app = try launchApp()
        try openMail(app)
        let signedIn = app.webViews.staticTexts["signed-in:Mail"]

        // A server redirect to another host, a new window (target=_blank) and window.open: each opens the browser
        // panel, none of them loads in the Workspace view, and the Workspace page stays.
        let routes: [(String, XCUIElement, String)] = [
            ("redirect", app.webViews.links["Redirect to the other host"], "Redirect target"),
            ("new-window", app.webViews.links["New window to the other host"], "New window target"),
            ("window-open", app.webViews.buttons["window.open to the other host"], "window.open target")
        ]
        for (name, element, pageText) in routes {
            XCTAssertTrue(element.waitForExistence(timeout: 20), "the page has no \(name) element")
            element.tap()
            let opened = safariViewService.wait(for: .runningForeground, timeout: 60)
            XCTAssertTrue(opened, "\(name): the other host did not open in the browser panel")
            // The panel must show the other host's page (the stand-in logs the request; no cookie may come with it)
            let loaded = safariViewService.staticTexts[pageText].waitForExistence(timeout: 60)
            XCTAssertTrue(loaded, "\(name): the other host's page never loaded in the browser panel")
            Thread.sleep(forTimeInterval: 1)
            save("10-\(name)-panel")
            record("route-\(name)", ["panel_opened": opened, "loaded": loaded])
            closeBrowserPanel(app)
            XCTAssertTrue(waitFor(signedIn, in: app, timeout: 30), "\(name): the Workspace page is gone")
            XCTAssertFalse(app.webViews.staticTexts["LOGIN"].exists, "\(name): a login page was shown")
        }

        // The session ends on the server: the next page would be the login page. The app signs in again by itself,
        // loads the page again, and the user never sees a login page.
        let expire = app.webViews.links["Expire the session"]
        XCTAssertTrue(expire.waitForExistence(timeout: 20), "the page has no expiry link")
        expire.tap()
        let renewed = app.webViews.staticTexts["session-renewed"]
        let renewedShown = waitFor(renewed, in: app, timeout: 120)
        XCTAssertTrue(renewedShown, "the page did not come back after the session ended")
        XCTAssertFalse(app.webViews.staticTexts["LOGIN"].exists, "a login page was shown after the session ended")
        settle(app, seconds: 2)
        save("11-session-renewed")
        record("session-renewed", ["shown": renewedShown])
    }

    // MARK: - 3. A second launch signs in again by itself

    func test3SecondLaunchSignsInAgain() throws {
        let app = try launchApp()
        try openMail(app)
        record("first-launch-page", ["ok": true])
        app.terminate()

        // The same app launches again: no web data of the first launch may be used, the Workspace page signs in by itself
        record("launch-begin", [:])
        app.launch()
        record("launch", ["state": app.state.rawValue])
        try openMail(app)
        save("12-second-launch-page")
        record("second-launch-page", ["ok": true])
    }

    // MARK: - 4. A notification link of the account's own server

    func test4NotificationLinkOpensInTheApp() throws {
        let app = try launchApp()
        let sidebarButton = app.buttons["openSidebar"]
        XCTAssertTrue(waitFor(sidebarButton, in: app, timeout: 300, hittable: true), "the main screen with the sidebar button never came up")
        settle(app, seconds: 4)
        let bell = app.buttons["sidebarNotifications"]
        openSidebar(app, until: bell)
        XCTAssertTrue(waitFor(bell, in: app, timeout: 30, hittable: true), "the sidebar has no Notifications button")
        bell.tap()

        let action = app.buttons["Open mail"]
        let listed = waitFor(action, in: app, timeout: 90)
        XCTAssertTrue(listed, "the notification list has no Open mail button")
        save("13-notifications")
        record("notifications", ["listed": listed])
        action.tap()

        let signedIn = app.webViews.staticTexts["signed-in:Mail"]
        let shown = waitFor(signedIn, in: app, timeout: 120)
        XCTAssertTrue(shown, "the notification link did not open the signed-in page inside the app")
        XCTAssertFalse(app.webViews.staticTexts["LOGIN"].exists, "a login page was shown")
        XCTAssertFalse(safariViewService.state == .runningForeground, "the link opened in the browser")
        save("14-notification-page")
        record("notification-page", ["signed_in": shown])

        // The Close button brings the notification list back
        var close = app.buttons["workspaceClose"]
        if !close.exists {
            close = app.navigationBars.buttons["Close"].firstMatch
        }
        XCTAssertTrue(close.waitForExistence(timeout: 20), "the Workspace screen has no Close button")
        close.tap()
        XCTAssertTrue(waitFor(action, in: app, timeout: 30), "the notification list is not back after Close")
        XCTAssertEqual(app.webViews.count, 0, "the Workspace web view is still open after Close")
    }

    // MARK: - Steps

    private func launchApp() throws -> XCUIApplication {
        guard let account = env["NODRIVE_UITEST_ACCOUNT"], !account.isEmpty else {
            throw XCTSkip("NODRIVE_UITEST_ACCOUNT is not set")
        }
        let app = XCUIApplication()
        app.launchArguments += ["UI_TESTING", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment["NODRIVE_UITEST_ACCOUNT"] = account
        // tools/ci/workspace-check.py compares the sessions the pages used with the time of every launch
        record("launch-begin", [:])
        app.launch()
        record("launch", ["state": app.state.rawValue])
        return app
    }

    /// The main screen, the sidebar, and the Mail page, signed in.
    private func openMail(_ app: XCUIApplication) throws {
        let sidebarButton = app.buttons["openSidebar"]
        XCTAssertTrue(waitFor(sidebarButton, in: app, timeout: 300, hittable: true), "the main screen with the sidebar button never came up")
        settle(app, seconds: 4)
        let mail = app.descendants(matching: .any)["sidebarWorkspaceApp-mail"]
        openSidebar(app, until: mail)
        XCTAssertTrue(mail.exists, "the sidebar has no Mail entry (the app list was not read from the server)")
        scrollSidebar(until: mail, in: app)
        XCTAssertTrue(mail.isHittable, "the Mail entry cannot be tapped")
        mail.tap()
        let signedIn = app.webViews.staticTexts["signed-in:Mail"]
        let shown = waitFor(signedIn, in: app, timeout: 120)
        XCTAssertTrue(shown, "the Mail page did not show the signed-in user")
        XCTAssertFalse(app.webViews.staticTexts["LOGIN"].exists, "a login page was shown")
        settle(app, seconds: 2)
    }

    /// A launch that restores the main screen of an earlier launch replaces it a few seconds later with the one of
    /// the new account, and an open sidebar goes with it: open the sidebar again until `element` is in it.
    private func openSidebar(_ app: XCUIApplication, until element: XCUIElement) {
        for _ in 1...4 {
            openSidebar(app)
            if waitFor(element, in: app, timeout: 40) {
                return
            }
        }
    }

    /// The bar's buttons move while the avatar loads, so a tap can miss: tap again until the sidebar is open.
    private func openSidebar(_ app: XCUIApplication) {
        let sidebarButton = app.buttons["openSidebar"]
        let sidebarOpen = app.descendants(matching: .any)["sidebarFiles"]
        for attempt in 1...5 where !sidebarOpen.exists {
            if sidebarButton.exists, sidebarButton.isHittable {
                sidebarButton.tap()
            }
            record("sidebar-tap", ["attempt": attempt])
            _ = waitFor(sidebarOpen, in: app, timeout: 10)
        }
    }

    // MARK: - Helpers

    private func scrollSidebar(until element: XCUIElement, in app: XCUIApplication) {
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let window = app.windows.firstMatch.frame
        for _ in 0..<6 where element.exists && !element.isHittable {
            let start = origin.withOffset(CGVector(dx: window.width * 0.35, dy: window.height * 0.75))
            let end = origin.withOffset(CGVector(dx: window.width * 0.35, dy: window.height * 0.25))
            start.press(forDuration: 0.05, thenDragTo: end)
            Thread.sleep(forTimeInterval: 0.8)
        }
    }

    /// Closes the browser panel and waits until the Workspace page is in front again; when the first tap did not
    /// close it, taps again (the panel's Close button, then the Close button of its bottom bar).
    private func closeBrowserPanel(_ app: XCUIApplication) {
        let page = app.webViews.firstMatch
        let corners = [CGVector(dx: 0.09, dy: 0.10), CGVector(dx: 0.74, dy: 0.95), CGVector(dx: 0.09, dy: 0.10)]
        for attempt in 0..<4 {
            let deadline = Date().addingTimeInterval(20)
            var tapped = false
            while Date() < deadline, !tapped {
                for root in [safariViewService, app] {
                    let done = root.buttons.matching(NSPredicate(format: "label IN %@ OR identifier IN %@", doneLabels, doneLabels)).firstMatch
                    if done.exists {
                        // The panel's Close button overlaps its address field, so isHittable can be false: tap its centre.
                        done.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
                        tapped = true
                        break
                    }
                }
                if !tapped {
                    Thread.sleep(forTimeInterval: 1)
                }
            }
            if !tapped {
                safariViewService.coordinate(withNormalizedOffset: corners[attempt % corners.count]).tap()
            }
            Thread.sleep(forTimeInterval: 3)
            if page.waitForExistence(timeout: 8), page.isHittable {
                return
            }
        }
    }

    private func waitFor(_ element: XCUIElement, in app: XCUIApplication, timeout: TimeInterval, hittable: Bool = false) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            answerPrompts(in: app)
            if element.exists, !hittable || element.isHittable {
                return true
            }
            Thread.sleep(forTimeInterval: 1)
        } while Date() < deadline
        return false
    }

    private func settle(_ app: XCUIApplication, seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            answerPrompts(in: app)
            Thread.sleep(forTimeInterval: 0.5)
        }
    }

    /// System prompts (notifications, photo library) can come up at any moment; each is saved once and answered.
    private func answerPrompts(in app: XCUIApplication) {
        for _ in 0..<3 {
            var alert: XCUIElement?
            if springboard.alerts.firstMatch.exists {
                alert = springboard.alerts.firstMatch
            } else if app.alerts.firstMatch.exists {
                alert = app.alerts.firstMatch
            }
            guard let alert else { return }
            promptCount += 1
            save("00-prompt-\(promptCount)")
            let buttons = alert.buttons.allElementsBoundByIndex
            guard !buttons.isEmpty else { return }
            let labels = buttons.map(\.label)
            var choice = buttons.count - 1
            for wanted in [denyLabels, continueLabels] {
                if let index = labels.firstIndex(where: { wanted.contains($0) }) {
                    choice = index
                    break
                }
            }
            record("prompt-\(promptCount)", ["buttons": labels, "tapped": labels[choice]])
            buttons[choice].tap()
            Thread.sleep(forTimeInterval: 1)
        }
    }

    // MARK: - Output

    private var outputDir: URL? {
        guard let dir = env["NODRIVE_SHOTS_DIR"], !dir.isEmpty else { return nil }
        let url = URL(fileURLWithPath: dir).appendingPathComponent(variant, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func save(_ name: String) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = "\(variant)-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
        if let dir = outputDir {
            try? shot.pngRepresentation.write(to: dir.appendingPathComponent("\(name).png"))
        }
    }

    private func saveTexts(_ element: XCUIElement, _ name: String) {
        guard let dir = outputDir else { return }
        append(element.debugDescription + "\n", to: dir.appendingPathComponent("\(name).txt"))
    }

    private func record(_ step: String, _ fields: [String: Any]) {
        guard let dir = outputDir else { return }
        var entry = fields
        entry["variant"] = variant
        entry["step"] = step
        entry["t"] = Date().timeIntervalSince1970
        guard let data = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]),
              let line = String(data: data, encoding: .utf8) else { return }
        append(line + "\n", to: dir.appendingPathComponent("walk.jsonl"))
    }

    private func append(_ text: String, to url: URL) {
        let data = Data(text.utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            handle.closeFile()
        } else {
            try? data.write(to: url)
        }
    }
}
