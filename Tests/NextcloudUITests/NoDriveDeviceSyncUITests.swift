// SPDX-FileCopyrightText: 2026 Nourax
// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

/// "Add to iPhone Calendar & Contacts", end to end in the simulator (CI job "screens", shard device-sync), in light and
/// dark mode.
///
/// The app signs in to the local stand-in for drive.nourax.org (tools/ci/drive-stand-in.py --workspace --device-sync); the
/// real server is never contacted. The stand-in's Login Flow v2 grants on the second poll after its flow page was opened and
/// hands out a fresh throwaway password (NODRIVE_DS_APP_PASSWORD in its environment; it is never shown, logged or saved).
///   test1  Settings shows the section, step 1 explains, Continue opens the sign-in sheet, the grant builds the profile and
///          opens Safari. Where possible (Apple's own screens; reported, never failing): Safari's "trying to download a
///          configuration profile" prompt -> Allow, the Settings app shows "Profile Downloaded", its install screen names
///          "NoDrive Calendar & Contacts", Install. Back in the app: the install steps, then Installed -> the done text.
///   test2  the same sign-in again, then "It didn't work": the stand-in must see the DELETE of the new password.
///   test3  the account is removed (debug hook): the steps to remove the profile are shown.
/// The redacted copy of the profile (passwords replaced) is written by the app to <shots>/<variant>/ and read back here.
///
/// Environment (pass with the TEST_RUNNER_ prefix to xcodebuild):
///   NODRIVE_UITEST_ACCOUNT  "server URL|login name|app password": the account the app creates at launch
///   NODRIVE_VARIANT         name of this run, e.g. devicesync-light
///   NODRIVE_SHOTS_DIR       host folder; files go to <dir>/<variant>/
@MainActor
final class NoDriveDeviceSyncUITests: XCTestCase {
    private let env = ProcessInfo.processInfo.environment
    private var variant: String { env["NODRIVE_VARIANT"] ?? "devicesync" }
    private var springboard: XCUIApplication { XCUIApplication(bundleIdentifier: "com.apple.springboard") }
    private let denyLabels = ["Don’t Allow", "Don't Allow", "Not Now", "Later"]
    private let continueLabels = ["Allow Full Access", "Continue", "OK", "Allow"]
    private var promptCount = 0
    private var apple: [String: String] = [:]

    override func setUp() async throws {
        continueAfterFailure = true
    }

    // MARK: - Tests

    func test1Flow() throws {
        let app = try launchApp()
        openSettings(app)
        let button = deviceSyncButton(app)
        XCTAssertTrue(scrollTo(button, in: app), "Settings has no \"Add to iPhone Calendar & Contacts\" button")
        XCTAssertTrue(button.label.contains("Add to iPhone Calendar & Contacts"), "wrong button text: \(button.label)")
        XCTAssertTrue(button.isEnabled, "the button is disabled although an account is signed in")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Safari as your default browser'")).firstMatch.exists,
                      "the footer does not say that Safari must be the default browser")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label == 'Calendar and contacts' OR label == 'CALENDAR AND CONTACTS'")).firstMatch.exists,
                      "no \"Calendar and contacts\" header")
        // upstream's entry (the server's profile without a password) is switched off
        XCTAssertFalse(app.buttons["Download the configuration profile"].exists, "upstream's profile entry is still shown")
        XCTAssertFalse(app.staticTexts["Download the configuration profile"].exists, "upstream's profile entry is still shown")
        assertNoUpstreamName(app, "Settings")
        save("01-settings")
        saveTexts(app, "01-settings")
        record("settings", ["button": button.label])

        button.tap()
        let step1 = app.descendants(matching: .any)["devicesyncStep1"].firstMatch
        XCTAssertTrue(waitFor(step1, in: app, timeout: 30), "the first step did not open")
        XCTAssertTrue(step1.label.contains("separate password"), "step 1 does not explain the separate password: \(step1.label)")
        XCTAssertTrue(step1.label.contains("You won't see it, and NoDrive doesn't keep it."), "step 1 text is wrong: \(step1.label)")
        XCTAssertTrue(app.buttons["devicesyncContinue"].exists, "step 1 has no Continue button")
        XCTAssertTrue(app.buttons["devicesyncCancel"].exists, "step 1 has no Cancel button")
        assertNoUpstreamName(app, "step 1")
        save("02-step1")
        saveTexts(app, "02-step1")

        app.buttons["devicesyncContinue"].tap()
        let waiting = app.descendants(matching: .any)["devicesyncWaiting"].firstMatch
        let sawWaiting = waitFor(waiting, in: app, timeout: 30)
        record("waiting", ["seen": sawWaiting])
        XCTAssertTrue(sawWaiting, "the waiting step did not show")
        if sawWaiting {
            XCTAssertTrue(app.buttons["devicesyncReopen"].exists, "the waiting step has no \"Open the sign-in page again\" button")
            save("03-waiting")
            saveTexts(app, "03-waiting")
        }

        // The sign-in sheet (the system's) covers the app; the stand-in grants on the second poll. Then the app
        // builds the profile and opens Safari, so the app leaves the foreground.
        XCTAssertTrue(waitForSafari(app, timeout: 240), "the app did not hand the profile to Safari")
        appleScreens()
        app.activate()
        let steps = app.descendants(matching: .any)["devicesyncInstallSteps"].firstMatch
        XCTAssertTrue(waitFor(steps, in: app, timeout: 90), "the install steps did not show after Safari")
        XCTAssertTrue(steps.label.contains("Open Settings, tap Profile Downloaded, then Install."), "wrong install steps: \(steps.label)")
        XCTAssertTrue(steps.label.contains("within 8 minutes"), "the 8 minutes are not mentioned: \(steps.label)")
        XCTAssertTrue(steps.label.contains("Stolen Device Protection"), "Stolen Device Protection is not mentioned: \(steps.label)")
        for id in ["devicesyncInstalled", "devicesyncDidntWork", "devicesyncOpenSafari"] {
            XCTAssertTrue(app.buttons[id].exists, "the install steps have no \(id) button")
        }
        assertNoUpstreamName(app, "install steps")
        save("04-install-steps")
        saveTexts(app, "04-install-steps")

        checkRedactedProfile()

        app.buttons["devicesyncInstalled"].tap()
        let done = app.descendants(matching: .any)["devicesyncDone"].firstMatch
        XCTAssertTrue(waitFor(done, in: app, timeout: 30), "the done text did not show")
        XCTAssertTrue(done.label.contains("will appear in Calendar, Reminders and Contacts in a few minutes"), "wrong done text: \(done.label)")
        save("05-done")
        saveTexts(app, "05-done")
        app.buttons["devicesyncClose"].tap()
        writeApple()
    }

    func test2DidntWork() throws {
        let app = try launchApp()
        openSettings(app)
        let button = deviceSyncButton(app)
        XCTAssertTrue(scrollTo(button, in: app), "Settings has no \"Add to iPhone Calendar & Contacts\" button")
        button.tap()
        let cont = app.buttons["devicesyncContinue"]
        XCTAssertTrue(waitFor(cont, in: app, timeout: 30), "no Continue button")
        cont.tap()
        XCTAssertTrue(waitForSafari(app, timeout: 240), "the app did not hand the profile to Safari")
        app.activate()
        let didnt = app.buttons["devicesyncDidntWork"]
        XCTAssertTrue(waitFor(didnt, in: app, timeout: 90), "the install steps did not show after Safari")
        didnt.tap()
        let undone = app.descendants(matching: .any)["devicesyncUndone"].firstMatch
        XCTAssertTrue(waitFor(undone, in: app, timeout: 60), "the \"password removed\" text did not show")
        XCTAssertTrue(undone.label.contains("the separate password was removed"), "wrong text: \(undone.label)")
        save("06-didnt-work")
        saveTexts(app, "06-didnt-work")
        record("didnt-work", [:])
        XCTAssertTrue(app.buttons["devicesyncTryAgain"].exists, "no Try again button")
        app.buttons["devicesyncCancel"].tap()
    }

    func test3Removal() throws {
        let app = try launchApp(removeAccount: true)
        openSettings(app)
        // the debug hook removes the account three seconds after the section shows
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 180), "no message after the account was removed")
        let texts = alert.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " | ")
        XCTAssertTrue(texts.contains("Remove NoDrive from this iPhone"), "wrong title: \(texts)")
        XCTAssertTrue(texts.contains("Settings › General › VPN & Device Management"), "the message does not name the place: \(texts)")
        XCTAssertTrue(texts.contains("NoDrive Calendar & Contacts"), "the message does not name the profile: \(texts)")
        XCTAssertTrue(texts.contains("Remove Profile"), "the message does not name Remove Profile: \(texts)")
        XCTAssertTrue(texts.contains("security settings on the web"), "the message does not name the web settings: \(texts)")
        XCTAssertFalse(texts.lowercased().contains("nextcloud"), "the message names the upstream product")
        save("07-removal")
        saveTexts(app, "07-removal")
        record("removal", ["shown": true])
        alert.buttons.firstMatch.tap()
    }

    // MARK: - Apple's own screens (reported, never failing)

    /// True when the app is not in the foreground any more (it opened Safari), false after the timeout.
    private func waitForSafari(_ app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            answerPrompts(in: app)
            if app.state != .runningForeground {
                record("app-left-foreground", ["state": app.state.rawValue])
                return true
            }
            if app.descendants(matching: .any)["devicesyncInstallSteps"].firstMatch.exists {
                // The app reached the install steps without leaving (Safari could not be opened in front).
                return true
            }
            Thread.sleep(forTimeInterval: 1)
        }
        return false
    }

    private func appleScreens() {
        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        if safari.wait(for: .runningForeground, timeout: 30) {
            apple["safari-foreground"] = "PASS"
            save("10-safari")
            var found = safari.alerts.firstMatch.waitForExistence(timeout: 30)
            var alert = safari.alerts.firstMatch
            if !found, springboard.alerts.firstMatch.exists {
                found = true
                alert = springboard.alerts.firstMatch
            }
            if found {
                let text = alert.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " | ")
                apple["safari-prompt"] = text.range(of: "configuration profile", options: .caseInsensitive) != nil ? "PASS" : "NOT VERIFIED (other prompt)"
                save("11-safari-prompt")
                let allow = alert.buttons.matching(NSPredicate(format: "label == 'Allow'")).firstMatch
                if allow.exists {
                    allow.tap()
                    apple["safari-allow"] = "PASS"
                } else {
                    apple["safari-allow"] = "NOT VERIFIED (no Allow button)"
                }
            } else {
                apple["safari-prompt"] = "NOT VERIFIED (no prompt seen)"
            }
        } else {
            apple["safari-foreground"] = "NOT VERIFIED (Safari did not come to the front)"
        }

        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        settings.activate()
        Thread.sleep(forTimeInterval: 3)
        let downloaded = settings.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'Profile Downloaded'")).firstMatch
        if downloaded.waitForExistence(timeout: 25) {
            apple["settings-profile-downloaded"] = "PASS"
            save("12-settings-profile-downloaded")
            downloaded.tap()
            let name = settings.staticTexts.matching(NSPredicate(format: "label CONTAINS 'NoDrive Calendar & Contacts'")).firstMatch
            if name.waitForExistence(timeout: 20) {
                apple["settings-install-screen"] = "PASS"
                save("13-settings-install-screen")
                let install = settings.buttons.matching(NSPredicate(format: "label == 'Install'")).firstMatch
                if install.waitForExistence(timeout: 10) {
                    install.tap()
                    apple["settings-install-tapped"] = "PASS"
                    Thread.sleep(forTimeInterval: 2)
                    save("14-settings-after-install")
                } else {
                    apple["settings-install-tapped"] = "NOT VERIFIED (no Install button)"
                }
            } else {
                apple["settings-install-screen"] = "NOT VERIFIED (the screen did not name the profile)"
            }
        } else {
            apple["settings-profile-downloaded"] = "NOT VERIFIED (no Profile Downloaded row)"
        }
        record("apple-screens", apple)
    }

    private func writeApple() {
        guard let dir = outputDir,
              let data = try? JSONSerialization.data(withJSONObject: apple, options: [.sortedKeys, .prettyPrinted]) else { return }
        try? data.write(to: dir.appendingPathComponent("apple-screens.json"))
    }

    // MARK: - The profile the app built (passwords replaced)

    private func checkRedactedProfile() {
        guard let dir = outputDir else {
            XCTFail("no output folder")
            return
        }
        let file = dir.appendingPathComponent("devicesync-profile-redacted.mobileconfig")
        guard let data = try? Data(contentsOf: file),
              let root = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any] else {
            XCTFail("the app did not write the redacted profile")
            return
        }
        XCTAssertEqual(root["PayloadType"] as? String, "Configuration")
        XCTAssertEqual(root["PayloadDisplayName"] as? String, "NoDrive Calendar & Contacts")
        let content = (root["PayloadContent"] as? [[String: Any]]) ?? []
        XCTAssertEqual(content.map { $0["PayloadType"] as? String }, ["com.apple.caldav.account", "com.apple.carddav.account"])
        XCTAssertEqual(content.first?["CalDAVPassword"] as? String, "<redacted>")
        XCTAssertEqual(content.last?["CardDAVPassword"] as? String, "<redacted>")
        XCTAssertEqual(content.first?["CalDAVHostName"] as? String, "drive.nourax.org")
        XCTAssertEqual(content.first?["CalDAVUseSSL"] as? Bool, true)
        XCTAssertEqual(content.first?["CalDAVPort"] as? Int, 443)
        XCTAssertTrue(((content.first?["CalDAVPrincipalURL"] as? String) ?? "").hasPrefix("https://drive.nourax.org/remote.php/dav/principals/users/"))
        XCTAssertNil(String(decoding: data, as: UTF8.self).range(of: "nextcloud", options: .caseInsensitive), "the profile names the upstream product")
        record("profile-checked", ["payloads": content.count])
    }

    // MARK: - Steps

    private func launchApp(removeAccount: Bool = false) throws -> XCUIApplication {
        guard let account = env["NODRIVE_UITEST_ACCOUNT"], !account.isEmpty else {
            throw XCTSkip("NODRIVE_UITEST_ACCOUNT is not set")
        }
        let app = XCUIApplication()
        app.launchArguments += ["UI_TESTING", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment["NODRIVE_UITEST_ACCOUNT"] = account
        app.launchEnvironment["NODRIVE_DS_POLL_SECONDS"] = "1"
        if let dir = outputDir {
            app.launchEnvironment["NODRIVE_DS_OUT"] = dir.path
        }
        if removeAccount {
            app.launchEnvironment["NODRIVE_DS_REMOVE_ACCOUNT"] = "1"
        }
        record("launch-begin", [:])
        app.launch()
        record("launch", ["state": app.state.rawValue])
        return app
    }

    /// The main screen, the sidebar, and Settings.
    private func openSettings(_ app: XCUIApplication) {
        let sidebarButton = app.buttons["openSidebar"]
        XCTAssertTrue(waitFor(sidebarButton, in: app, timeout: 300, hittable: true), "the main screen with the sidebar button never came up")
        settle(app, seconds: 4)
        let sidebarOpen = app.descendants(matching: .any)["sidebarFiles"]
        for attempt in 1...5 where !sidebarOpen.exists {
            if sidebarButton.exists, sidebarButton.isHittable {
                sidebarButton.tap()
            }
            record("sidebar-tap", ["attempt": attempt])
            _ = waitFor(sidebarOpen, in: app, timeout: 10)
        }
        let settings = app.descendants(matching: .any)["sidebarSettings"]
        XCTAssertTrue(waitFor(settings, in: app, timeout: 60, hittable: true), "the sidebar has no Settings button")
        settings.tap()
        settle(app, seconds: 3)
    }

    private func deviceSyncButton(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["devicesyncButton"].firstMatch
    }

    private func assertNoUpstreamName(_ app: XCUIApplication, _ place: String) {
        let texts = app.staticTexts.allElementsBoundByIndex.map(\.label) + app.buttons.allElementsBoundByIndex.map(\.label)
        for text in texts where text.range(of: "nextcloud", options: .caseInsensitive) != nil {
            XCTFail("\(place): the text \"\(text)\" names the upstream product")
        }
    }

    // MARK: - Helpers

    private func scrollTo(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        let deadline = Date().addingTimeInterval(90)
        var swipes = 0
        while Date() < deadline {
            answerPrompts(in: app)
            if element.exists, element.isHittable {
                return true
            }
            let list = app.collectionViews.firstMatch.exists ? app.collectionViews.firstMatch : app.tables.firstMatch
            if list.exists, swipes < 12 {
                list.swipeUp()
                swipes += 1
            }
            Thread.sleep(forTimeInterval: 0.7)
        }
        return false
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

    /// System prompts (notifications, "Wants to Use drive.nourax.org to Sign In") can come up at any moment; each is saved
    /// once and answered. Only the system's own alerts: the app's own message is answered by the test itself.
    private func answerPrompts(in app: XCUIApplication) {
        for _ in 0..<3 {
            guard springboard.alerts.firstMatch.exists else { return }
            let alert = springboard.alerts.firstMatch
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
            // the sign-in prompt must be allowed to go on: "Continue" before any deny label
            if let index = labels.firstIndex(of: "Continue") { choice = index }
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
