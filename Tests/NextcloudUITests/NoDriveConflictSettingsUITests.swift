// SPDX-FileCopyrightText: 2026 Nourax
// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

/// The Auto upload setting "If a file is already in NoDrive", end to end in the simulator (CI job "screens").
///
/// The app signs in to the local stand-in for drive.nourax.org (tools/ci/drive-stand-in.py --workspace); the real
/// server is never contacted. Photos access is granted before the launch (`simctl privacy grant photos`). The test
/// checks:
///   1. the Auto upload screen shows the row, and it reads "Smart (recommended)" (the default);
///   2. the list has the four choices with their exact texts, Smart's summary, and no "Ask me every time";
///   3. each choice can be selected, the row shows it, and a relaunch of the app keeps it;
///   4. the screen has no "Experimental" section with the PhotoKit background upload switch;
///   5. no visible text mentions the upstream product name.
///
/// Environment (pass with the TEST_RUNNER_ prefix to xcodebuild):
///   NODRIVE_UITEST_ACCOUNT  "server URL|login name|app password": the account the app creates at launch
///   NODRIVE_VARIANT         name of this run, e.g. conflicts-light
///   NODRIVE_SHOTS_DIR       host folder; files go to <dir>/<variant>/
@MainActor
final class NoDriveConflictSettingsUITests: XCTestCase {
    private let env = ProcessInfo.processInfo.environment
    private var variant: String { env["NODRIVE_VARIANT"] ?? "conflicts" }
    private var springboard: XCUIApplication { XCUIApplication(bundleIdentifier: "com.apple.springboard") }
    private let denyLabels = ["Don’t Allow", "Don't Allow", "Not Now", "Later"]
    private let continueLabels = ["Allow Full Access", "Continue", "OK", "Allow"]
    private var promptCount = 0

    /// (stable id, exact title, summary)
    private let choices: [(id: String, title: String, summary: String?)] = [
        ("smart", "Smart (recommended)", "Skip it if it's the same size, otherwise keep both"),
        ("keep-nodrive", "Keep the NoDrive copy", nil),
        ("keep-phone", "Keep the phone copy", nil),
        ("keep-both", "Keep both", nil)
    ]

    override func setUp() async throws {
        continueAfterFailure = true
    }

    func testConflictSetting() throws {
        var app = try launchApp()

        // 1. The Auto upload screen, and the row with the default.
        openAutoUpload(app)
        var row = conflictRow(app)
        XCTAssertTrue(scrollTo(row, in: app), "the Auto upload screen has no \"If a file is already in NoDrive\" row")
        XCTAssertTrue(row.label.contains("If a file is already in NoDrive"), "the row title is wrong: \(row.label)")
        XCTAssertTrue(row.label.contains("Smart (recommended)"), "the default is not Smart: \(row.label)")
        record("row-default", ["label": row.label])
        save("01-auto-upload-row")
        saveTexts(app, "01-auto-upload-row")

        // 4. No Experimental section with the PhotoKit background upload switch (it could replace files).
        XCTAssertFalse(app.staticTexts["Experimental"].exists, "an Experimental section is shown")
        XCTAssertFalse(app.staticTexts["PhotoKit background upload extension"].exists, "the PhotoKit background upload switch is shown")
        XCTAssertFalse(app.switches["PhotoKit background upload extension"].exists, "the PhotoKit background upload switch is shown")

        // 2. The list: four choices with their exact texts.
        row.tap()
        for choice in choices {
            let element = choiceRow(app, choice.id)
            XCTAssertTrue(element.waitForExistence(timeout: 20), "the list has no row for \(choice.id)")
            XCTAssertTrue(element.label.contains(choice.title), "\(choice.id): wrong title: \(element.label)")
            if let summary = choice.summary {
                XCTAssertTrue(element.label.contains(summary), "\(choice.id): wrong summary: \(element.label)")
            }
        }
        XCTAssertFalse(app.staticTexts["Ask me every time"].exists, "an \"Ask me every time\" choice is shown")
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'ask'")).firstMatch.exists, "a choice that asks is shown")
        XCTAssertEqual(choices.filter { choiceRow(app, $0.id).exists }.count, 4, "the list does not have exactly the four choices")
        XCTAssertTrue(choiceRow(app, "smart").isSelected, "Smart is not marked as the chosen row")
        // 5. Nothing names the upstream product.
        assertNoUpstreamName(app, "choice list")
        save("02-choices")
        saveTexts(app, "02-choices")

        // 3. Choose each one; the row of the Auto upload screen shows it.
        for choice in choices {
            choiceRow(app, choice.id).tap()
            XCTAssertTrue(choiceRow(app, choice.id).isSelected, "\(choice.id) was not selected")
            for other in choices where other.id != choice.id {
                XCTAssertFalse(choiceRow(app, other.id).isSelected, "\(other.id) is still selected after \(choice.id)")
            }
            goBack(app)
            row = conflictRow(app)
            XCTAssertTrue(scrollTo(row, in: app), "the row is gone after choosing \(choice.id)")
            XCTAssertTrue(row.label.contains(choice.title), "the row does not show \(choice.id): \(row.label)")
            record("chose", ["choice": choice.id, "label": row.label])
            if choice.id == "keep-both" {
                save("03-keep-both")
                saveTexts(app, "03-keep-both")
            }
            if choice.id != choices.last?.id {
                row.tap()
            }
        }

        // The choice is kept after the app is closed and opened again.
        app.terminate()
        app = try launchApp()
        openAutoUpload(app)
        row = conflictRow(app)
        XCTAssertTrue(scrollTo(row, in: app), "the row is gone after a relaunch")
        XCTAssertTrue(row.label.contains("Keep both"), "the choice was not kept after a relaunch: \(row.label)")
        record("kept-after-relaunch", ["label": row.label])
        save("04-after-relaunch")

        // Back to the default.
        row.tap()
        choiceRow(app, "smart").tap()
        goBack(app)
        row = conflictRow(app)
        XCTAssertTrue(scrollTo(row, in: app), "the row is gone after choosing Smart again")
        XCTAssertTrue(row.label.contains("Smart (recommended)"), "Smart could not be chosen again: \(row.label)")
        assertNoUpstreamName(app, "Auto upload screen")
        save("05-smart-again")
    }

    // MARK: - Steps

    private func launchApp() throws -> XCUIApplication {
        guard let account = env["NODRIVE_UITEST_ACCOUNT"], !account.isEmpty else {
            throw XCTSkip("NODRIVE_UITEST_ACCOUNT is not set")
        }
        let app = XCUIApplication()
        app.launchArguments += ["UI_TESTING", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment["NODRIVE_UITEST_ACCOUNT"] = account
        record("launch-begin", [:])
        app.launch()
        record("launch", ["state": app.state.rawValue])
        return app
    }

    /// The main screen, the sidebar, and the Auto upload screen.
    private func openAutoUpload(_ app: XCUIApplication) {
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
        let entry = app.descendants(matching: .any)["sidebarAutoUpload"]
        XCTAssertTrue(waitFor(entry, in: app, timeout: 60), "the sidebar has no Auto upload entry")
        scrollSidebar(until: entry, in: app)
        XCTAssertTrue(entry.isHittable, "the Auto upload entry cannot be tapped")
        entry.tap()
        settle(app, seconds: 3)
    }

    private func conflictRow(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["nodriveConflictRow"].firstMatch
    }

    private func choiceRow(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)["nodriveConflict-\(id)"].firstMatch
    }

    private func goBack(_ app: XCUIApplication) {
        let back = app.navigationBars.buttons.element(boundBy: 0)
        XCTAssertTrue(back.waitForExistence(timeout: 20), "the list has no back button")
        back.tap()
        settle(app, seconds: 1)
    }

    private func assertNoUpstreamName(_ app: XCUIApplication, _ where_: String) {
        let texts = app.staticTexts.allElementsBoundByIndex.map(\.label) + app.buttons.allElementsBoundByIndex.map(\.label)
        for text in texts where text.range(of: "nextcloud", options: .caseInsensitive) != nil {
            XCTFail("\(where_): the text \"\(text)\" names the upstream product")
        }
    }

    // MARK: - Helpers

    private func scrollTo(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        let deadline = Date().addingTimeInterval(60)
        var swipes = 0
        while Date() < deadline {
            answerPrompts(in: app)
            if element.exists, element.isHittable {
                return true
            }
            let list = app.collectionViews.firstMatch.exists ? app.collectionViews.firstMatch : app.tables.firstMatch
            if list.exists, swipes < 8 {
                list.swipeUp()
                swipes += 1
            }
            Thread.sleep(forTimeInterval: 0.7)
        }
        return false
    }

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
