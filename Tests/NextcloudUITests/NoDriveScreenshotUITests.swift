// SPDX-FileCopyrightText: 2026 Nourax
// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

/// Walks the screens NoDrive shows before sign-in and attaches a screenshot of each.
/// Needs no server: CI never taps "Log in" (that would open drive.nourax.org).
///
/// Environment (pass with the TEST_RUNNER_ prefix to xcodebuild):
///   NODRIVE_LANG    language code, e.g. en, de, ar (default en)
///   NODRIVE_LOCALE  locale, e.g. en_US, de_DE, ar_SA (default derived from the language)
@MainActor
final class NoDriveScreenshotUITests: XCTestCase {
    private var language: String { ProcessInfo.processInfo.environment["NODRIVE_LANG"] ?? "en" }
    private var locale: String {
        if let locale = ProcessInfo.processInfo.environment["NODRIVE_LOCALE"] { return locale }
        switch language {
        case "de": return "de_DE"
        case "ar": return "ar_SA"
        default: return "en_US"
        }
    }

    override func setUp() async throws {
        continueAfterFailure = true
    }

    func testIntroScreensAndHomeScreen() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(\(language))", "-AppleLocale", locale]
        app.launch()

        dismissSystemAlerts()

        let login = app.buttons["nodriveLoginButton"]
        XCTAssertTrue(login.waitForExistence(timeout: 60), "the intro's Log in button is missing")
        dismissSystemAlerts()

        attachScreenshot(named: "01-intro-slide-1", of: app)
        app.swipeLeft()
        sleep(2)
        attachScreenshot(named: "02-intro-slide-2", of: app)

        // No visible text may name Nextcloud.
        let leaked = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] 'nextcloud'"))
        XCTAssertEqual(leaked.count, 0, "a visible label contains 'Nextcloud'")

        // One fixed server: no "Sign up with provider" or "Host your own server".
        if language == "en" {
            XCTAssertFalse(app.buttons["Sign up with provider"].exists)
            XCTAssertFalse(app.buttons["Host your own server"].exists)
        }

        XCUIDevice.shared.press(.home)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        XCTAssertTrue(springboard.icons["NoDrive"].waitForExistence(timeout: 20), "no home-screen icon named NoDrive")
        attachScreenshot(named: "03-home-screen", screen: true)
    }

    /// Answers permission prompts (for example notifications) so they do not cover the screenshots.
    private func dismissSystemAlerts() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for _ in 0..<3 {
            let alert = springboard.alerts.firstMatch
            guard alert.waitForExistence(timeout: 3), alert.buttons.count > 0 else { return }
            alert.buttons.element(boundBy: 0).tap()
        }
    }

    private func attachScreenshot(named name: String, of app: XCUIApplication? = nil, screen: Bool = false) {
        let shot = screen || app == nil ? XCUIScreen.main.screenshot() : app!.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = "\(language)-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
