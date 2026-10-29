// SPDX-FileCopyrightText: 2026 Nourax
// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

/// Problem reports, end to end in the simulator (CI job "screens"), in light and dark mode.
///
/// The app signs in to the local stand-in for drive.nourax.org (tools/ci/drive-stand-in.py --workspace --reports); the
/// real server is never contacted. The stand-in saves every uploaded zip and logs every request; the checks on those
/// (kinds, order, headers, shares, sizes, no secret in a zip) are made afterwards by tools/ci/report-check.py. This test
/// checks what the user sees:
///   run 1  Settings -> Advanced shows the switch "Send problem reports to Nourax", off, and the row "Report a problem";
///          "What's included" lists what is sent; a report with a note goes out (the stand-in refuses the first share,
///          like the real server before the account nourax-support exists), then a second report (the share works).
///   run 2  the app ends while it is on screen (SIGKILL, like a watchdog kill; no normal exit).
///   run 3  switch off: the question "NoDrive closed unexpectedly. Send a problem report?" -> Not now (nothing is sent);
///          then the switch is turned on.
///   run 4  the app ends the same way.
///   run 5  switch on: no question, the report goes out by itself ("Problem report sent").
///   run 6  the exception handler gets an exception, then the app ends.
///   run 7  the crash report goes out by itself.
/// A run that is meant to end normally goes to the home screen first, so the app writes its "background" marker.
///
/// Environment (pass with the TEST_RUNNER_ prefix to xcodebuild):
///   NODRIVE_UITEST_ACCOUNT  "server URL|login name|app password": the account the app creates at launch
///   NODRIVE_VARIANT         name of this run, e.g. reports-light
///   NODRIVE_SHOTS_DIR       host folder; files go to <dir>/<variant>/
@MainActor
final class NoDriveProblemReportsUITests: XCTestCase {
    private let env = ProcessInfo.processInfo.environment
    private var variant: String { env["NODRIVE_VARIANT"] ?? "reports" }
    private var springboard: XCUIApplication { XCUIApplication(bundleIdentifier: "com.apple.springboard") }
    private let denyLabels = ["Don’t Allow", "Don't Allow", "Not Now", "Later"]
    private let continueLabels = ["Allow Full Access", "Continue", "OK", "Allow"]
    private var promptCount = 0

    private let note = "The upload of Photos/Holiday 2026/IMG_0001.HEIC froze. Write to jane.doe@example.com. Bearer ABCDEFGHIJKLMNOPQRSTUVWXYZABCDEFGHIJKLMN"

    override func setUp() async throws {
        continueAfterFailure = true
    }

    func testProblemReports() throws {
        // run 1: the settings, a report with a note, a second report
        var app = try launchApp(mode: "1")
        openAdvanced(app)
        let switchElement = reportsSwitch(app)
        XCTAssertTrue(scrollTo(switchElement, in: app), "Settings > Advanced has no problem-report switch")
        XCTAssertEqual(switchElement.value as? String, "0", "the switch is not off by default")
        XCTAssertTrue(switchElement.label.contains("Send problem reports to Nourax"), "the switch title is wrong: \(switchElement.label)")
        let summary = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'never include passwords'")).firstMatch
        XCTAssertTrue(summary.exists, "the summary under the switch is missing")
        XCTAssertTrue(summary.label.contains("If the app has a problem, send a report to Nourax Support so we can fix it."), "wrong summary: \(summary.label)")
        record("switch-default", ["value": switchElement.value as? String ?? "", "label": switchElement.label])
        assertNoUpstreamName(app, "Advanced")
        save("01-advanced-section")
        saveTexts(app, "01-advanced-section")

        let reportRow = reportProblemRow(app)
        XCTAssertTrue(scrollTo(reportRow, in: app), "no \"Report a problem\" row")
        reportRow.tap()
        let noteField = noteBox(app)
        XCTAssertTrue(noteField.waitForExistence(timeout: 30), "the report screen has no note box")
        XCTAssertTrue(app.staticTexts["What went wrong?"].exists || noteField.placeholderValue == "What went wrong?" || noteField.label.contains("What went wrong?")
                      || noteField.debugDescription.contains("What went wrong?"),
                      "the note box does not ask \"What went wrong?\"")
        XCTAssertTrue(sendButton(app).exists, "no Send button")
        XCTAssertTrue(app.buttons["Cancel"].exists, "no Cancel button")

        let included = includedLink(app)
        XCTAssertTrue(included.waitForExistence(timeout: 20), "no \"What's included\" link")
        included.tap()
        let header = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'a problem report contains'")).firstMatch
        XCTAssertTrue(header.waitForExistence(timeout: 20), "the \"What's included\" screen has no list")
        for text in ["the app version and build", "your device model, iOS version and language",
                     "the time of the report and the address of your NoDrive server", "your note, if you wrote one",
                     "what the app was doing when it stopped, if it crashed",
                     "They include the names of your files and folders, because we need them to find the problem.",
                     "Passwords, tokens and cookies are always removed, and email addresses are replaced."] {
            let found = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", text)).firstMatch
            XCTAssertTrue(found.exists, "\"What's included\" does not say: \(text)")
        }
        assertNoUpstreamName(app, "What's included")
        save("02-whats-included")
        saveTexts(app, "02-whats-included")
        goBack(app)

        XCTAssertTrue(noteField.waitForExistence(timeout: 20))
        noteField.tap()
        noteField.typeText(note)
        settle(app, seconds: 1)
        sendButton(app).tap()
        // The first share is refused by the stand-in (the account nourax-support does not exist yet).
        let saved = app.staticTexts["Saved in your NoDrive › Problem reports."]
        let sawSaved = saved.waitForExistence(timeout: 60)
        record("banner-saved", ["seen": sawSaved])
        if sawSaved { save("03-saved") }
        XCTAssertTrue(waitFor(reportProblemRow(app), in: app, timeout: 60), "the screen did not return to Advanced after Send")

        scrollToReportRow(app)
        reportProblemRow(app).tap()
        XCTAssertTrue(sendButton(app).waitForExistence(timeout: 30))
        sendButton(app).tap()
        let sent = app.staticTexts["Problem report sent"]
        let sawSent = sent.waitForExistence(timeout: 60)
        record("banner-sent", ["seen": sawSent])
        if sawSent { save("04-sent") }
        XCTAssertTrue(waitFor(reportProblemRow(app), in: app, timeout: 60), "the screen did not return to Advanced after the second Send")
        endNormally(app)

        // run 2: the app ends while on screen
        app = try launchApp(mode: "kill")
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 120), "the app did not end by itself")
        record("run-2-ended", [:])

        // run 3: switch off -> the question
        app = try launchApp(mode: "1")
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 180), "no question after the app ended on screen")
        XCTAssertTrue(alert.staticTexts["NoDrive closed unexpectedly. Send a problem report?"].exists || alert.label.contains("NoDrive closed unexpectedly"),
                      "wrong question: \(alert.debugDescription)")
        XCTAssertTrue(alert.buttons["Send"].exists, "the question has no Send button")
        XCTAssertTrue(alert.buttons["Not now"].exists, "the question has no Not now button")
        save("05-closed-unexpectedly")
        saveTexts(app, "05-closed-unexpectedly")
        record("question", ["buttons": alert.buttons.allElementsBoundByIndex.map(\.label)])
        alert.buttons["Not now"].tap()
        settle(app, seconds: 3)
        XCTAssertFalse(app.alerts.firstMatch.exists, "the question came back")
        // turn the switch on
        openAdvanced(app)
        let toggle = reportsSwitch(app)
        XCTAssertTrue(scrollTo(toggle, in: app), "the switch is gone")
        XCTAssertEqual(toggle.value as? String, "0", "the switch changed by itself")
        // The element is the whole row: a tap in its middle hits the title, so tap where the switch is.
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        settle(app, seconds: 1)
        XCTAssertEqual(toggle.value as? String, "1", "the switch could not be turned on")
        save("06-switch-on")
        endNormally(app)

        // run 4: the app ends while on screen; the switch is on
        app = try launchApp(mode: "kill")
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 120), "the app did not end by itself (second time)")

        // run 5: no question, the report goes by itself
        app = try launchApp(mode: "1")
        let autoSent = app.staticTexts["Problem report sent"]
        let sawAuto = autoSent.waitForExistence(timeout: 180)
        record("banner-auto", ["seen": sawAuto])
        if sawAuto { save("07-sent-by-itself") }
        XCTAssertFalse(app.alerts.firstMatch.exists, "a question was asked although the switch is on")
        settle(app, seconds: 25)   // the upload needs a moment even when the banner could not be seen
        endNormally(app)

        // run 6: an exception reaches the exception handler, then the app ends
        app = try launchApp(mode: "raise")
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 120), "the app did not end by itself (exception)")

        // run 7: the crash report goes by itself
        app = try launchApp(mode: "1")
        let crashSent = app.staticTexts["Problem report sent"]
        let sawCrash = crashSent.waitForExistence(timeout: 120)
        record("banner-crash", ["seen": sawCrash])
        if sawCrash { save("08-crash-sent") }
        XCTAssertFalse(app.alerts.firstMatch.exists, "a question was asked although the switch is on (crash)")
        settle(app, seconds: 25)
        endNormally(app)
    }

    // MARK: - Steps

    private func launchApp(mode: String) throws -> XCUIApplication {
        guard let account = env["NODRIVE_UITEST_ACCOUNT"], !account.isEmpty else {
            throw XCTSkip("NODRIVE_UITEST_ACCOUNT is not set")
        }
        let app = XCUIApplication()
        app.launchArguments += ["UI_TESTING", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment["NODRIVE_UITEST_ACCOUNT"] = account
        app.launchEnvironment["NODRIVE_UITEST_REPORTS"] = mode
        record("launch-begin", ["mode": mode])
        app.launch()
        record("launch", ["mode": mode, "state": app.state.rawValue])
        return app
    }

    /// The home screen first (the app writes its "background" marker), then the app is ended.
    private func endNormally(_ app: XCUIApplication) {
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 3)
        app.terminate()
        record("ended-normally", [:])
    }

    /// The main screen, the sidebar, Settings, and Advanced.
    private func openAdvanced(_ app: XCUIApplication) {
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
        let advanced = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Advanced'")).firstMatch
        XCTAssertTrue(scrollTo(advanced, in: app), "Settings has no Advanced row")
        advanced.tap()
        settle(app, seconds: 2)
    }

    private func reportsSwitch(_ app: XCUIApplication) -> XCUIElement {
        let byId = app.switches["nodriveReportsSwitch"]
        return byId.exists ? byId : app.switches["Send problem reports to Nourax"]
    }

    private func reportProblemRow(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["nodriveReportProblem"].firstMatch
    }

    private func noteBox(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["nodriveReportNote"].firstMatch
    }

    private func includedLink(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["nodriveReportIncluded"].firstMatch
    }

    private func sendButton(_ app: XCUIApplication) -> XCUIElement {
        let byId = app.buttons["nodriveReportSend"]
        return byId.exists ? byId : app.navigationBars.buttons["Send"]
    }

    private func scrollToReportRow(_ app: XCUIApplication) {
        let row = reportProblemRow(app)
        XCTAssertTrue(scrollTo(row, in: app), "no \"Report a problem\" row")
    }

    private func goBack(_ app: XCUIApplication) {
        let back = app.navigationBars.buttons.element(boundBy: 0)
        XCTAssertTrue(back.waitForExistence(timeout: 20), "no back button")
        back.tap()
        settle(app, seconds: 1)
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

    /// System prompts (notifications, photo library) can come up at any moment; each is saved once and answered.
    /// Only the system's own alerts: the app's question is answered by the test itself.
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
