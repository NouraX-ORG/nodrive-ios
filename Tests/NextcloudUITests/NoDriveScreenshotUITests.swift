// SPDX-FileCopyrightText: 2026 Nourax
// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

/// Walks every NoDrive screen that is reachable before sign-in and saves a screenshot of each,
/// with the accessibility texts of the screen next to it (for the no-Nextcloud check).
///
/// CI never contacts the real drive.nourax.org. The screenshot job answers for it with a local
/// stand-in (tools/ci/drive-stand-in.py, /etc/hosts and a throw-away root certificate that only
/// the CI simulator trusts), so tapping "Log in" runs the app's real Login Flow v2 code up to the
/// browser page.
///
/// Environment (pass with the TEST_RUNNER_ prefix to xcodebuild):
///   NODRIVE_LANG       language code, e.g. en, de, ar (default en)
///   NODRIVE_LOCALE     locale, e.g. en_US, de_DE, ar_SA (default derived from the language)
///   NODRIVE_VARIANT    name of this run, e.g. en-light (default: the language)
///   NODRIVE_SHOTS_DIR  host folder; files go to <dir>/<variant>/ (screenshots are attachments too)
///   NODRIVE_SIGN_IN    "1": tap "Log in" (needs the stand-in); anything else: skip that step
@MainActor
final class NoDriveScreenshotUITests: XCTestCase {
    private let env = ProcessInfo.processInfo.environment
    private var language: String { env["NODRIVE_LANG"] ?? "en" }
    private var locale: String {
        if let locale = env["NODRIVE_LOCALE"] { return locale }
        switch language {
        case "de": return "de_DE"
        case "ar": return "ar_SA"
        default: return "en_US"
        }
    }
    private var variant: String { env["NODRIVE_VARIANT"] ?? language }
    private var springboard: XCUIApplication { XCUIApplication(bundleIdentifier: "com.apple.springboard") }
    private var safariViewService: XCUIApplication { XCUIApplication(bundleIdentifier: "com.apple.SafariViewService") }

    private let continueLabels = ["Continue", "Fortfahren", "Weiter", "متابعة"]
    private let cancelLabels = ["Cancel", "Abbrechen", "إلغاء"]
    private let shareLabels = ["Share", "Teilen", "مشاركة"]
    private let onboardingLabels = ["Continue", "Not Now", "OK", "Get Started", "Fortfahren", "Weiter", "Nicht jetzt",
                                    "متابعة", "ليس الآن", "حسنًا", "موافق"]

    override func setUp() async throws {
        continueAfterFailure = true
    }

    // MARK: - App: permission prompt, intro, sign-in browser, home screen

    func test1IntroSignInAndHomeScreen() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(\(language))", "-AppleLocale", locale]
        app.launch()
        XCTAssertEqual(app.state, .runningForeground, "NoDrive did not start")
        record("launch", ["state": "\(app.state.rawValue)"])

        // The first start asks for notification permission. The system prompt must name NoDrive.
        let prompts = handleAlerts("00-permission-prompt", in: app, prefer: [], timeout: 15) { text in
            XCTAssertTrue(text.contains("NoDrive"), "the permission prompt does not name NoDrive")
        }
        record("permission-prompt", ["count": prompts])

        let login = app.buttons["nodriveLoginButton"]
        XCTAssertTrue(login.waitForExistence(timeout: 60), "the intro's Log in button is missing")
        handleAlerts("00-permission-prompt-late", in: app, prefer: [], timeout: 2)

        // One fixed server: no address field and no "Sign up" or "Host your own server" buttons.
        XCTAssertEqual(app.textFields.count, 0, "the intro has a text field (server address?)")
        let buttonLabels = app.buttons.allElementsBoundByIndex.map(\.label)
        if language == "en" {
            XCTAssertFalse(buttonLabels.contains("Sign up with provider"), "the intro offers sign-up with a provider")
            XCTAssertFalse(buttonLabels.contains("Host your own server"), "the intro offers hosting a server")
        }
        record("intro-buttons", ["labels": buttonLabels, "login_label": login.label])

        for slide in 1...2 {
            let shown = waitForSlide(slide, in: app)
            XCTAssertTrue(shown, "intro slide \(slide) never came into view")
            let name = "0\(slide)-intro-slide-\(slide)"
            save(name)
            saveTexts(app, name)
            let title = app.cells["nodriveIntroSlide\(slide)"].staticTexts.firstMatch
            record(name, ["shown": shown, "title": title.exists ? title.label : ""])
        }
        assertNoNextcloud(in: app, screen: "intro")

        if env["NODRIVE_SIGN_IN"] == "1" {
            signIn(app: app, login: login)
        }

        // Home screen: the icon and its name.
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 1.5)
        let icon = springboard.icons["NoDrive"]
        XCTAssertTrue(icon.waitForExistence(timeout: 20), "no home-screen icon named NoDrive")
        if icon.exists {
            for _ in 0..<3 where !icon.isHittable {
                springboard.swipeLeft()
                Thread.sleep(forTimeInterval: 1)
            }
            for _ in 0..<6 where !icon.isHittable {
                springboard.swipeRight()
                Thread.sleep(forTimeInterval: 1)
            }
        }
        save("05-home-screen")
        saveTexts(springboard, "05-home-screen")
        record("home-screen", ["icon": icon.exists, "icon_visible": icon.exists && icon.isHittable])
    }

    /// Taps "Log in": the app asks drive.nourax.org (here: the CI stand-in) for a Login Flow v2
    /// and opens the browser at the login page it returns. No server-address screen in between.
    private func signIn(app: XCUIApplication, login: XCUIElement) {
        login.tap()
        let marker = NSPredicate(format: "label CONTAINS[c] %@", "CI stand-in")
        var consent = 0
        var pageFound = false
        let deadline = Date().addingTimeInterval(45)
        while Date() < deadline, !pageFound {
            if consent == 0, springboard.alerts.firstMatch.exists || app.alerts.firstMatch.exists {
                consent = handleAlerts("03-sign-in-consent", in: app, prefer: continueLabels, timeout: 1)
            }
            pageFound = roots(app).contains { $0.descendants(matching: .any).matching(marker).firstMatch.exists }
            if !pageFound {
                Thread.sleep(forTimeInterval: 1)
            }
        }
        Thread.sleep(forTimeInterval: 2)   // let the sheet finish its animation and the page render
        save("04-sign-in-browser")
        for root in roots(app) {
            saveTexts(root, "04-sign-in-browser")
        }
        XCTAssertTrue(pageFound, "tapping Log in did not open the browser at the drive.nourax.org login page")
        XCTAssertEqual(app.textFields.count, 0, "a server-address field appeared after tapping Log in")
        let domainShown = roots(app).contains {
            $0.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] %@", "nourax.org")).firstMatch.exists
        }
        record("sign-in", ["browser_page": pageFound, "domain_label_shown": domainShown, "consent_prompts": consent])

        // Close the browser sheet again.
        for root in roots(app) {
            let cancel = root.buttons.matching(NSPredicate(format: "label IN %@", cancelLabels)).firstMatch
            if cancel.exists, cancel.isHittable {
                cancel.tap()
                break
            }
        }
        Thread.sleep(forTimeInterval: 2)
        record("sign-in-closed", ["login_button_back": login.exists && login.isHittable])
    }

    // MARK: - Share sheet of another app (Photos) and the share extension without an account

    func test2ShareSheetAndShareExtension() throws {
        let photos = XCUIApplication(bundleIdentifier: "com.apple.mobileslideshow")
        photos.launch()
        Thread.sleep(forTimeInterval: 3)
        dismissOnboarding(photos)

        let photoCandidates = [
            photos.descendants(matching: .any).matching(NSPredicate(
                format: "label BEGINSWITH[c] 'Photo,' OR label BEGINSWITH[c] 'Foto,' OR label BEGINSWITH 'صورة'")).firstMatch,
            photos.collectionViews.cells.firstMatch,
            photos.cells.firstMatch
        ]
        guard let photo = firstHittable(photoCandidates, timeout: 20) else {
            save("06-photos")
            saveTexts(photos, "06-photos")
            record("share-sheet", ["skipped": "no photo to open"])
            throw XCTSkip("Photos shows no photo to share")
        }
        photo.tap()
        Thread.sleep(forTimeInterval: 2)

        let shareButton = photos.buttons.matching(NSPredicate(format: "label IN %@ OR identifier IN %@", shareLabels, shareLabels)).firstMatch
        guard let share = firstHittable([shareButton], timeout: 10) else {
            save("06-photo")
            saveTexts(photos, "06-photo")
            record("share-sheet", ["skipped": "no Share button"])
            throw XCTSkip("no Share button in Photos")
        }
        share.tap()
        Thread.sleep(forTimeInterval: 3)

        let entry = photos.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "NoDrive")).firstMatch
        guard entry.waitForExistence(timeout: 15) else {
            save("06-share-sheet")
            saveTexts(photos, "06-share-sheet")
            record("share-sheet", ["skipped": "NoDrive not in the share sheet"])
            throw XCTSkip("NoDrive is not listed in the share sheet")
        }
        scrollIntoView(entry, in: photos)
        save("06-share-sheet")
        saveTexts(photos, "06-share-sheet")
        XCTAssertTrue(entry.isHittable, "NoDrive is in the share sheet but could not be scrolled into view")
        record("share-sheet", ["entry": true, "visible": entry.isHittable])

        entry.tap()
        Thread.sleep(forTimeInterval: 4)
        save("07-share-extension")
        saveTexts(photos, "07-share-extension")
        assertNoNextcloud(in: photos, screen: "share extension")
        let alert = photos.alerts.firstMatch
        record("share-extension", ["alert": alert.exists ? alert.label : ""])
        if alert.exists, alert.buttons.count > 0 {
            alert.buttons.element(boundBy: 0).tap()
        }
    }

    // MARK: - Helpers

    /// The app plus the browser service, when it runs (the sign-in sheet lives there).
    private func roots(_ app: XCUIApplication) -> [XCUIApplication] {
        let state = safariViewService.state
        return state == .notRunning || state == .unknown ? [app] : [app, safariViewService]
    }

    /// Waits until intro slide `number` sits in the middle of the window (the intro scrolls by itself every 4 s).
    private func waitForSlide(_ number: Int, in app: XCUIApplication, timeout: TimeInterval = 14) -> Bool {
        let cell = app.cells["nodriveIntroSlide\(number)"]
        let window = app.windows.firstMatch
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if cell.exists, abs(cell.frame.midX - window.frame.midX) < 2 {
                Thread.sleep(forTimeInterval: 0.6)
                if abs(cell.frame.midX - window.frame.midX) < 2 {
                    return true
                }
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return false
    }

    /// Screenshots, records and answers system or in-app alerts. Returns how many were handled.
    @discardableResult
    private func handleAlerts(_ name: String, in app: XCUIApplication, prefer labels: [String], timeout: TimeInterval,
                              check: ((String) -> Void)? = nil) -> Int {
        var handled = 0
        while handled < 3 {
            let deadline = Date().addingTimeInterval(handled == 0 ? timeout : 2)
            var alert: XCUIElement?
            while alert == nil, Date() < deadline {
                if springboard.alerts.firstMatch.exists {
                    alert = springboard.alerts.firstMatch
                } else if app.alerts.firstMatch.exists {
                    alert = app.alerts.firstMatch
                } else {
                    Thread.sleep(forTimeInterval: 0.5)
                }
            }
            guard let alert else { break }
            handled += 1
            let shot = handled == 1 ? name : "\(name)-\(handled)"
            Thread.sleep(forTimeInterval: 0.5)
            save(shot)
            let text = alert.debugDescription
            saveTexts(alert, shot)
            check?(text)
            let buttons = alert.buttons.allElementsBoundByIndex
            guard !buttons.isEmpty else { break }
            let target = buttons.first(where: { labels.contains($0.label) }) ?? buttons[0]
            record(shot, ["alert": alert.label, "buttons": buttons.map(\.label), "tapped": target.label])
            target.tap()
            Thread.sleep(forTimeInterval: 1)
        }
        return handled
    }

    private func dismissOnboarding(_ app: XCUIApplication) {
        for _ in 0..<4 {
            let button = app.buttons.matching(NSPredicate(format: "label IN %@", onboardingLabels)).firstMatch
            guard button.waitForExistence(timeout: 3), button.isHittable else { return }
            record("onboarding", ["tapped": button.label])
            button.tap()
            Thread.sleep(forTimeInterval: 1.5)
        }
    }

    private func firstHittable(_ candidates: [XCUIElement], timeout: TimeInterval) -> XCUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let hit = candidates.first(where: { $0.exists && $0.isHittable }) {
                return hit
            }
            Thread.sleep(forTimeInterval: 0.5)
        } while Date() < deadline
        return nil
    }

    /// Drags the row of `element` sideways until the element can be tapped (both directions, for RTL).
    private func scrollIntoView(_ element: XCUIElement, in app: XCUIApplication) {
        let window = app.windows.firstMatch.frame
        let origin = app.coordinate(withNormalizedOffset: .zero)
        for dx in [-0.7, -0.7, -0.7, 0.7, 0.7, 0.7, 0.7, 0.7, 0.7] where !element.isHittable {
            let y = element.frame.midY
            let start = origin.withOffset(CGVector(dx: window.width * (dx < 0 ? 0.85 : 0.15), dy: y))
            let end = origin.withOffset(CGVector(dx: window.width * (dx < 0 ? 0.15 : 0.85), dy: y))
            start.press(forDuration: 0.05, thenDragTo: end)
            Thread.sleep(forTimeInterval: 1)
        }
    }

    private func assertNoNextcloud(in app: XCUIApplication, screen: String) {
        let leaked = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] 'nextcloud' OR value CONTAINS[c] 'nextcloud'"))
        XCTAssertEqual(leaked.count, 0, "a visible text on the \(screen) screen contains 'Nextcloud'")
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

    /// Saves the accessibility tree (labels and values) of a screen as <name>.txt.
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
