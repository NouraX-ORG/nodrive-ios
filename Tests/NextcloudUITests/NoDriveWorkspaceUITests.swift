// SPDX-FileCopyrightText: 2026 Nourax
// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

/// The Workspace apps menu, end to end, in the simulator (CI job "screens").
///
/// The app signs in to a local stand-in for drive.nourax.org (tools/ci/drive-stand-in.py --workspace); the real
/// server is never contacted. The test then opens the sidebar, checks that the server's apps are listed (and
/// Files is not), opens Mail (the page must show the signed-in user, never a login page), and follows a link to
/// another host (it must open in the in-app browser panel, not in the Workspace screen).
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
    private var promptCount = 0

    override func setUp() async throws {
        continueAfterFailure = true
    }

    func test1MenuSignedInPageAndForeignLink() throws {
        guard let account = env["NODRIVE_UITEST_ACCOUNT"], !account.isEmpty else {
            throw XCTSkip("NODRIVE_UITEST_ACCOUNT is not set")
        }
        let app = XCUIApplication()
        app.launchArguments += ["UI_TESTING", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment["NODRIVE_UITEST_ACCOUNT"] = account
        app.launch()
        record("launch", ["state": app.state.rawValue])

        // 1. The app signs the account in at launch and shows the main screen.
        let sidebarButton = app.buttons["openSidebar"]
        XCTAssertTrue(waitFor(sidebarButton, in: app, timeout: 300, hittable: true), "the main screen with the sidebar button never came up")
        settle(app, seconds: 6)
        save("01-main-screen")

        // 2. The sidebar lists the server's apps, and no entry for Files.
        // The bar's buttons move while the avatar loads, so a tap can miss: tap again until the sidebar is open.
        let sidebarOpen = app.descendants(matching: .any)["sidebarFiles"]
        for attempt in 1...5 where !sidebarOpen.exists {
            if sidebarButton.exists, sidebarButton.isHittable {
                sidebarButton.tap()
            }
            record("sidebar-tap", ["attempt": attempt])
            _ = waitFor(sidebarOpen, in: app, timeout: 10)
        }
        let mail = app.descendants(matching: .any)["sidebarWorkspaceApp-mail"]
        let appeared = waitFor(mail, in: app, timeout: 90)
        XCTAssertTrue(appeared, "the sidebar has no Mail entry (the app list was not read from the server)")
        // Scroll so that the whole Apps section is in view (the last app is Contacts)
        scrollSidebar(until: app.descendants(matching: .any)["sidebarWorkspaceApp-contacts"], in: app)
        scrollSidebar(until: mail, in: app)
        Thread.sleep(forTimeInterval: 1)
        let files = app.descendants(matching: .any)["sidebarWorkspaceApp-files"]
        XCTAssertFalse(files.exists, "the apps menu lists Files")
        for other in ["sidebarWorkspaceApp-external_index1", "sidebarWorkspaceApp-evil"] {
            XCTAssertFalse(app.descendants(matching: .any)[other].exists, "\(other) is listed")
        }
        let appNames = app.buttons.allElementsBoundByIndex.filter { $0.identifier.hasPrefix("sidebarWorkspaceApp-") }.map(\.label)
        record("sidebar-apps", ["names": appNames])
        save("02-workspace-menu")
        saveTexts(app, "02-workspace-menu")
        XCTAssertTrue(appNames.contains("Mail"), "the menu shows the server's name Mail")

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
        let foreign = app.webViews.links.matching(NSPredicate(format: "label CONTAINS[c] 'foreign'")).firstMatch
        if foreign.waitForExistence(timeout: 20) {
            foreign.tap()
            let opened = safariViewService.wait(for: .runningForeground, timeout: 60)
            XCTAssertTrue(opened, "the link to another host did not open in the in-app browser panel")
            let loaded = safariViewService.staticTexts["Another host"].waitForExistence(timeout: 40)
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

    private func closeBrowserPanel(_ app: XCUIApplication) {
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            for root in [safariViewService, app] {
                let done = root.buttons.matching(NSPredicate(format: "label IN %@ OR identifier IN %@", doneLabels, doneLabels)).firstMatch
                if done.exists {
                    // The panel's Close button overlaps its address field, so isHittable can be false: tap its centre.
                    done.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
                    Thread.sleep(forTimeInterval: 3)
                    return
                }
            }
            Thread.sleep(forTimeInterval: 1)
        }
        // Without a Done button: the panel's top-left corner
        safariViewService.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.06)).tap()
        Thread.sleep(forTimeInterval: 2)
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
