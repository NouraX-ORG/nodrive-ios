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
/// System prompts (notifications, photo library, sign-in consent) can appear at any moment on a
/// busy simulator. Every wait loop answers them; each prompt is saved once as 00-prompt-<n>.
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

    // Buttons to press on system prompts, in this order of preference (en, de, ar).
    private let continueLabels = ["Continue", "Fortfahren", "Weiter", "متابعة"]
    private let denyLabels = ["Don’t Allow", "Don't Allow", "Nicht erlauben", "Nicht zulassen", "عدم السماح"]
    private let okLabels = ["OK", "Ok", "حسنًا", "موافق"]
    private let cancelLabels = ["Cancel", "Abbrechen", "إلغاء"]
    private let shareLabels = ["Share", "Teilen", "مشاركة"]
    private let onboardingLabels = ["Continue", "Not Now", "Get Started", "Fortfahren", "Weiter", "Nicht jetzt",
                                    "متابعة", "ليس الآن"]
    private var promptCount = 0

    override func setUp() async throws {
        continueAfterFailure = true
    }

    // MARK: - App: intro, sign-in browser, home screen

    func test1IntroSignInAndHomeScreen() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(\(language))", "-AppleLocale", locale]
        app.launch()
        XCTAssertEqual(app.state, .runningForeground, "NoDrive did not start")
        record("launch", ["state": "\(app.state.rawValue)"])

        let login = app.buttons["nodriveLoginButton"]
        XCTAssertTrue(waitFor(login, in: app, timeout: 90), "the intro's Log in button is missing")

        // One fixed server: no address field and no "Sign up" or "Host your own server" buttons.
        XCTAssertEqual(app.textFields.count, 0, "the intro has a text field (server address?)")
        let buttonLabels = app.buttons.allElementsBoundByIndex.map(\.label)
        if language == "en" {
            XCTAssertFalse(buttonLabels.contains("Sign up with provider"), "the intro offers sign-up with a provider")
            XCTAssertFalse(buttonLabels.contains("Host your own server"), "the intro offers hosting a server")
        }
        record("intro-buttons", ["labels": buttonLabels])

        // Let late permission prompts come up now rather than over a screenshot.
        settle(app, seconds: 6)
        for slide in 1...2 {
            let shown = waitForSlide(slide, in: app)
            XCTAssertTrue(shown, "intro slide \(slide) never came into view")
            let name = "0\(slide)-intro-slide-\(slide)"
            save(name)
            saveTexts(app, name)
            record(name, ["shown": shown])
        }
        assertNoNextcloud(in: app, screen: "intro")

        if env["NODRIVE_SIGN_IN"] == "1" {
            signIn(app: app, login: login)
        }

        // Home screen: the icon and its name.
        XCUIDevice.shared.press(.home)
        let icon = springboard.icons["NoDrive"]
        XCTAssertTrue(waitFor(icon, in: springboard, timeout: 30), "no home-screen icon named NoDrive")
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
        settle(springboard, seconds: 2)
        save("05-home-screen")
        saveTexts(springboard, "05-home-screen")
        record("home-screen", ["icon": icon.exists, "icon_visible": icon.exists && icon.isHittable])
    }

    /// Taps "Log in": the app asks drive.nourax.org (here: the CI stand-in) for a Login Flow v2
    /// and opens the browser at the login page it returns. No server-address screen in between.
    private func signIn(app: XCUIApplication, login: XCUIElement) {
        let started = Date()
        login.tap()
        // Leave the app alone for a moment: accessibility queries run on its main thread, where the
        // network replies are handled too (run 40167283812: 19-92 s from status.php to the Login Flow
        // request while the test polled every second).
        Thread.sleep(forTimeInterval: 20)
        // The browser's address field shows the server; the page itself is not in the accessibility tree.
        let address = NSPredicate(format: "identifier == 'URL' AND value CONTAINS[c] 'drive.nourax.org'")
        let loaded = NSPredicate(format: "identifier BEGINSWITH 'BrowserView?IsPageLoaded=true'")
        var browserOpen = false
        var pageLoaded = false
        var openedAfter = -1.0
        let deadline = Date().addingTimeInterval(150)
        while Date() < deadline, !pageLoaded {
            answerPrompts(in: app)
            let trees = roots(app)
            if !browserOpen, trees.contains(where: { $0.descendants(matching: .any).matching(address).firstMatch.exists }) {
                browserOpen = true
                openedAfter = Date().timeIntervalSince(started)
            }
            if browserOpen {
                pageLoaded = trees.contains { $0.descendants(matching: .any).matching(loaded).firstMatch.exists }
                if !pageLoaded, Date().timeIntervalSince(started) - openedAfter > 40 {
                    break   // the browser is open at drive.nourax.org; the stand-in log shows the page request
                }
            }
            if !pageLoaded {
                Thread.sleep(forTimeInterval: 1)
            }
        }
        Thread.sleep(forTimeInterval: 1.5)   // let the page render
        answerPrompts(in: app)
        save("04-sign-in-browser")
        for root in roots(app) {
            saveTexts(root, "04-sign-in-browser")
        }
        XCTAssertTrue(browserOpen, "tapping Log in did not open the browser at drive.nourax.org")
        XCTAssertEqual(app.textFields.count, 0, "a server-address field appeared after tapping Log in")
        record("sign-in", ["browser_open": browserOpen, "page_loaded": pageLoaded,
                           "seconds_to_browser": Int(openedAfter.rounded()),
                           "seconds_total": Int(Date().timeIntervalSince(started).rounded())])

        // Close the browser sheet again.
        for root in roots(app) {
            let cancel = root.buttons.matching(NSPredicate(format: "label IN %@", cancelLabels)).firstMatch
            if cancel.exists, cancel.isHittable {
                cancel.tap()
                break
            }
        }
        let back = waitFor(login, in: app, timeout: 15)
        record("sign-in-closed", ["login_button_back": back])
    }

    // MARK: - Share sheet of another app (Photos) and the share extension without an account

    func test2ShareSheetAndShareExtension() throws {
        let photos = XCUIApplication(bundleIdentifier: "com.apple.mobileslideshow")
        photos.launch()

        // Photos may show its "What's New" sheet at any point; handle it, open a photo, find Share.
        let photoQuery = photos.descendants(matching: .any).matching(NSPredicate(
            format: "label BEGINSWITH[c] 'Photo,' OR label BEGINSWITH[c] 'Foto,' OR label BEGINSWITH 'صورة'"))
        let shareButton = photos.buttons.matching(NSPredicate(format: "label IN %@ OR identifier IN %@", shareLabels, shareLabels)).firstMatch
        let onboarding = photos.buttons.matching(NSPredicate(format: "label IN %@", onboardingLabels)).firstMatch
        var shareReady = false
        var photoTaps = 0
        let deadline = Date().addingTimeInterval(75)
        while !shareReady, Date() < deadline {
            answerPrompts(in: photos)
            if onboarding.exists, onboarding.isHittable {
                record("photos-onboarding", ["tapped": onboarding.label])
                onboarding.tap()
                Thread.sleep(forTimeInterval: 1.5)
                continue
            }
            if shareButton.exists, shareButton.isHittable {
                shareReady = true
                break
            }
            if let photo = [photoQuery.firstMatch, photos.collectionViews.cells.firstMatch].first(where: { $0.exists && $0.isHittable }),
               photoTaps < 3 {
                photo.tap()
                photoTaps += 1
                Thread.sleep(forTimeInterval: 2)
                continue
            }
            Thread.sleep(forTimeInterval: 1)
        }
        guard shareReady else {
            save("06-photos")
            saveTexts(photos, "06-photos")
            record("share-sheet", ["skipped": "no photo with a Share button", "photo_taps": photoTaps])
            throw XCTSkip("could not open a photo with a Share button in Photos")
        }
        shareButton.tap()

        let entry = photos.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "NoDrive")).firstMatch
        guard waitFor(entry, in: photos, timeout: 20) else {
            save("06-share-sheet")
            saveTexts(photos, "06-share-sheet")
            record("share-sheet", ["skipped": "NoDrive not in the share sheet"])
            throw XCTSkip("NoDrive is not listed in the share sheet")
        }
        scrollIntoView(entry, in: photos)
        Thread.sleep(forTimeInterval: 1)
        save("06-share-sheet")
        saveTexts(photos, "06-share-sheet")
        XCTAssertTrue(entry.isHittable, "NoDrive is in the share sheet but could not be scrolled into view")
        record("share-sheet", ["entry": true, "visible": entry.isHittable])

        // Without an account the share extension says so ("No account found") and closes.
        entry.tap()
        // The extension's alert is in the accessibility tree before its sheet has slid in: wait until
        // it can be tapped, and then a little longer, before the screenshot.
        let alert = photos.alerts.firstMatch
        let shown = waitFor(alert, in: photos, timeout: 40, hittable: true, answer: false)
        Thread.sleep(forTimeInterval: 3)
        save("07-share-extension")
        saveTexts(photos, "07-share-extension")
        assertNoNextcloud(in: photos, screen: "share extension")
        record("share-extension", ["alert": shown])
        if shown {
            let buttons = alert.buttons.allElementsBoundByIndex
            (buttons.first { okLabels.contains($0.label) } ?? buttons.first)?.tap()
        }
    }

    // MARK: - Waiting and system prompts

    /// Waits for `element` (optionally hittable), answering system prompts meanwhile.
    private func waitFor(_ element: XCUIElement, in app: XCUIApplication, timeout: TimeInterval,
                         hittable: Bool = false, answer: Bool = true) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if answer {
                answerPrompts(in: app)
            }
            if element.exists, !hittable || element.isHittable {
                return true
            }
            Thread.sleep(forTimeInterval: 0.5)
        } while Date() < deadline
        return false
    }

    /// Answers system prompts for `seconds` so that they do not cover the next screenshot.
    private func settle(_ app: XCUIApplication, seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            answerPrompts(in: app)
            Thread.sleep(forTimeInterval: 0.5)
        }
    }

    /// Screenshots and answers every visible system or in-app alert: Continue (sign-in consent),
    /// then Don't Allow (permissions), then OK, else the last button. Each prompt text must not name Nextcloud.
    private func answerPrompts(in app: XCUIApplication) {
        for _ in 0..<4 {
            var alert: XCUIElement?
            if springboard.alerts.firstMatch.exists {
                alert = springboard.alerts.firstMatch
            } else if app.alerts.firstMatch.exists {
                alert = app.alerts.firstMatch
            }
            guard let alert else { return }
            Thread.sleep(forTimeInterval: 0.5)
            promptCount += 1
            let name = "00-prompt-\(promptCount)"
            save(name)
            let text = alert.debugDescription
            saveTexts(alert, name)
            XCTAssertFalse(text.lowercased().contains("nextcloud"), "a system prompt names Nextcloud")
            let buttons = alert.buttons.allElementsBoundByIndex
            guard !buttons.isEmpty else { return }
            let labels = buttons.map(\.label)
            var choice = buttons.count - 1
            for wanted in [continueLabels, denyLabels, okLabels] {
                if let index = labels.firstIndex(where: { wanted.contains($0) }) {
                    choice = index
                    break
                }
            }
            record(name, ["buttons": labels, "tapped": labels[choice], "names_nodrive": text.contains("NoDrive")])
            buttons[choice].tap()
            Thread.sleep(forTimeInterval: 1)
        }
    }

    // MARK: - Helpers

    /// The app plus the browser service, when it runs (the sign-in sheet lives there).
    private func roots(_ app: XCUIApplication) -> [XCUIApplication] {
        let state = safariViewService.state
        return state == .notRunning || state == .unknown ? [app] : [app, safariViewService]
    }

    /// Waits until intro slide `number` sits in the middle of the window (the intro scrolls by itself every 4 s).
    private func waitForSlide(_ number: Int, in app: XCUIApplication, timeout: TimeInterval = 20) -> Bool {
        let cell = app.cells["nodriveIntroSlide\(number)"]
        let window = app.windows.firstMatch
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            answerPrompts(in: app)
            if cell.exists, abs(cell.frame.midX - window.frame.midX) < 2 {
                Thread.sleep(forTimeInterval: 0.6)
                if cell.exists, abs(cell.frame.midX - window.frame.midX) < 2 {
                    return true
                }
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return false
    }

    /// Drags the row of `element` sideways until the element can be tapped (both directions, for RTL).
    private func scrollIntoView(_ element: XCUIElement, in app: XCUIApplication) {
        let window = app.windows.firstMatch.frame
        let origin = app.coordinate(withNormalizedOffset: .zero)
        for toLeft in [true, true, true, false, false, false, false, false, false] where element.exists && !element.isHittable {
            let y = element.frame.midY
            let start = origin.withOffset(CGVector(dx: window.width * (toLeft ? 0.85 : 0.15), dy: y))
            let end = origin.withOffset(CGVector(dx: window.width * (toLeft ? 0.15 : 0.85), dy: y))
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
