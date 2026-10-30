// SPDX-FileCopyrightText: 2026 Nourax
// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

/// NoAgenda, end to end, in the simulator (CI job "screens", shard "agenda").
///
/// The app signs in to a local stand-in for drive.nourax.org (tools/ci/drive-stand-in.py --agenda), which answers
/// the app's reads with the real server's recorded answers (tools/ci/agenda-snapshot.py). The real server is never
/// contacted. Environment (pass with the TEST_RUNNER_ prefix to xcodebuild):
///   NODRIVE_UITEST_ACCOUNT  "server URL|login name|app password"
///   NODRIVE_AGENDA_TODAY    the day the CI server was seeded for, "yyyy-MM-dd"
///   NODRIVE_AGENDA_USER     "ali", "mara" or "olaf": who the shard signed in as (decides the checks)
///   NODRIVE_VARIANT         name of this run, e.g. agenda-light
///   NODRIVE_SHOTS_DIR       host folder; files go to <dir>/<variant>/
@MainActor
final class NoDriveAgendaUITests: XCTestCase {
    private let env = ProcessInfo.processInfo.environment
    private var variant: String { env["NODRIVE_VARIANT"] ?? "agenda" }
    private var user: String { env["NODRIVE_AGENDA_USER"] ?? "ali" }
    private var springboard: XCUIApplication { XCUIApplication(bundleIdentifier: "com.apple.springboard") }

    override func setUp() async throws {
        continueAfterFailure = true
    }

    // MARK: - Tests

    func test1SidebarAndFirstOpen() throws {
        guard user == "ali" else { throw XCTSkip("this check runs for ali") }
        let app = try launchApp()
        openSidebar(app)
        let entry = app.descendants(matching: .any)["sidebarNoAgenda"]
        XCTAssertTrue(waitFor(entry, in: app, timeout: 60), "the sidebar has no NoAgenda entry")
        // NoAgenda is the first item under Apps, above the server's apps
        let appsHeader = app.staticTexts["Apps"]
        if appsHeader.exists, entry.exists {
            XCTAssertLessThan(appsHeader.frame.minY, entry.frame.minY, "NoAgenda is above the Apps heading")
        }
        let firstWorkspaceApp = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'sidebarWorkspaceApp-'")).firstMatch
        if firstWorkspaceApp.waitForExistence(timeout: 30) {
            XCTAssertLessThan(entry.frame.minY, firstWorkspaceApp.frame.minY, "NoAgenda is above the Workspace apps")
        }
        save("agenda-sidebar")
        XCTAssertTrue(entry.isHittable, "the NoAgenda entry cannot be tapped")
        entry.tap()

        // The one-time question, once
        let question = app.descendants(matching: .any)["agendaPersonalQuestion"]
        XCTAssertTrue(waitFor(question, in: app, timeout: 90), "the question about personal calendars never appeared")
        save("agenda-personal-question")
        let toggles = app.switches.matching(NSPredicate(format: "identifier BEGINSWITH 'agendaPersonalToggle-'"))
        XCTAssertGreaterThan(toggles.count, 0, "the question lists no calendars")
        chooseWorkCalendar(app)
        let done = app.buttons["agendaPersonalDone"]
        XCTAssertTrue(done.waitForExistence(timeout: 10))
        done.tap()
        XCTAssertTrue(waitFor(app.descendants(matching: .any)["agendaList"], in: app, timeout: 30))
        save("agenda-after-question")
    }

    func test2DayWeekMonthAndDetail() throws {
        guard user == "ali" else { throw XCTSkip("this check runs for ali") }
        let app = try openAgenda()
        XCTAssertTrue(waitForText(app, "Dentist"), "the Day list has no Dentist")
        XCTAssertTrue(app.staticTexts["Dentist"].exists || app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Dentist'")).firstMatch.exists)
        let writer = findRow(app, "Writer-Bot review")
        XCTAssertNotNil(writer, "the Writer-Bot review is missing")
        XCTAssertTrue(writer?.label.contains("Writer-Bot") == true, "the row does not name its agent")
        XCTAssertFalse(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Budget talk'")).firstMatch.exists, "a declined invitation is shown")
        save("agenda-day")

        app.segmentedControls["agendaViewPicker"].buttons["Week"].tap()
        Thread.sleep(forTimeInterval: 2)
        save("agenda-week")
        app.segmentedControls["agendaViewPicker"].buttons["Month"].tap()
        Thread.sleep(forTimeInterval: 2)
        save("agenda-month")
        app.segmentedControls["agendaViewPicker"].buttons["Day"].tap()

        // Detail sheet of a Gantt task
        guard let task = findRow(app, "Write homepage copy") else {
            XCTFail("Write homepage copy is missing")
            return
        }
        task.tap()
        let open = app.buttons["agendaDetailOpen"]
        XCTAssertTrue(open.waitForExistence(timeout: 20), "the detail sheet has no Open in NoGantt button")
        XCTAssertEqual(open.label, "Open in NoGantt")
        save("agenda-detail")
        app.buttons["agendaDetailDone"].tap()
    }

    func test3ChipsAndSwitch() throws {
        guard user == "ali" else { throw XCTSkip("this check runs for ali") }
        let app = try openAgenda()
        XCTAssertNotNil(findRow(app, "Writer-Bot review"))
        element(app, "agendaChip-agents").tap()
        Thread.sleep(forTimeInterval: 1)
        XCTAssertNil(findRow(app, "Writer-Bot review", timeout: 3), "turning off My agents still shows the Writer-Bot review")
        element(app, "agendaChip-agents").tap()
        app.segmentedControls["agendaScope"].buttons["Personal"].tap()
        Thread.sleep(forTimeInterval: 1)
        XCTAssertNil(findRow(app, "Client call", timeout: 3), "Personal still shows Work events")
        save("agenda-personal-only")
        app.segmentedControls["agendaScope"].buttons["All"].tap()
    }

    func test4Sources() throws {
        guard user == "ali" else { throw XCTSkip("this check runs for ali") }
        let app = try openAgenda()
        app.buttons["agendaSources"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["agendaSourcesList"].waitForExistence(timeout: 30))
        Thread.sleep(forTimeInterval: 1)
        save("agenda-sources")
        app.buttons["agendaSourcesDone"].tap()
    }

    func test5TeamAsManager() throws {
        guard user == "mara" else { throw XCTSkip("this check runs for mara") }
        let app = try openAgenda()
        let problem = findRow(app, "Banner design", timeout: 90)
        XCTAssertNotNil(problem, "the team problem for Banner design is missing")
        XCTAssertTrue(problem?.label.contains("Sara") == true)
        save("agenda-team")
        let showAll = element(app, "agendaShowAllTeam")
        if showAll.waitForExistence(timeout: 10) {
            showAll.tap()
            Thread.sleep(forTimeInterval: 1)
            save("agenda-team-all")
        }
    }

    func test6NotLinked() throws {
        guard user == "olaf" else { throw XCTSkip("this check runs for olaf") }
        let app = try openAgenda()
        let banner = app.descendants(matching: .any)["agendaBanner-notLinked"]
        XCTAssertTrue(banner.waitForExistence(timeout: 90), "the not-linked state is not shown")
        save("agenda-not-linked")
    }

    // MARK: - Helpers

    private func launchApp() throws -> XCUIApplication {
        guard let account = env["NODRIVE_UITEST_ACCOUNT"], !account.isEmpty else {
            throw XCTSkip("NODRIVE_UITEST_ACCOUNT is not set")
        }
        let app = XCUIApplication()
        app.launchArguments += ["UI_TESTING", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment["NODRIVE_UITEST_ACCOUNT"] = account
        if let today = env["NODRIVE_AGENDA_TODAY"] { app.launchEnvironment["NODRIVE_AGENDA_TODAY"] = today }
        app.launchEnvironment["TZ"] = "UTC"
        app.launch()
        let sidebarButton = app.buttons["openSidebar"]
        XCTAssertTrue(waitFor(sidebarButton, in: app, timeout: 300, hittable: true), "the main screen with the sidebar button never came up")
        return app
    }

    /// Opens NoAgenda from the sidebar and answers the one-time question if it comes. After a change of account
    /// the app may rebuild its main screen a little later and drop the screen: open it again until it stays.
    private func openAgenda() throws -> XCUIApplication {
        let app = try launchApp()
        let list = app.descendants(matching: .any)["agendaList"]
        for attempt in 1...4 {
            Thread.sleep(forTimeInterval: attempt == 1 ? 6 : 2)
            openSidebar(app)
            let entry = app.descendants(matching: .any)["sidebarNoAgenda"]
            XCTAssertTrue(waitFor(entry, in: app, timeout: 60, hittable: true), "the sidebar has no NoAgenda entry")
            entry.tap()
            let question = app.descendants(matching: .any)["agendaPersonalQuestion"]
            if question.waitForExistence(timeout: 40) {
                chooseWorkCalendar(app)
                app.buttons["agendaPersonalDone"].tap()
            }
            XCTAssertTrue(waitFor(list, in: app, timeout: 60), "NoAgenda did not open")
            Thread.sleep(forTimeInterval: 8)
            if list.exists { break }
        }
        return app
    }

    /// A row (or problem) whose label holds `text`; the list is scrolled to find it.
    private func findRow(_ app: XCUIApplication, _ text: String, timeout: TimeInterval = 60) -> XCUIElement? {
        let element = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
        let list = app.descendants(matching: .any)["agendaList"]
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if element.exists { return element }
            for _ in 0..<8 {
                list.swipeUp()
                if element.exists { return element }
            }
            for _ in 0..<8 { list.swipeDown() }
            Thread.sleep(forTimeInterval: 2)
        } while Date() < deadline
        return nil
    }

    /// The Work calendar is not personal: its switch goes off (the Personal calendar stays on).
    private func chooseWorkCalendar(_ app: XCUIApplication) {
        let work = app.switches["agendaPersonalToggle-cal:work"]
        if work.waitForExistence(timeout: 10), (work.value as? String) == "1" {
            work.tap()
        }
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    private func openSidebar(_ app: XCUIApplication) {
        let sidebarButton = app.buttons["openSidebar"]
        let sidebarOpen = app.descendants(matching: .any)["sidebarFiles"]
        for _ in 1...5 where !sidebarOpen.exists {
            if sidebarButton.exists, sidebarButton.isHittable {
                sidebarButton.tap()
            }
            _ = waitFor(sidebarOpen, in: app, timeout: 10)
        }
    }

    private func waitForText(_ app: XCUIApplication, _ text: String, timeout: TimeInterval = 90) -> Bool {
        let element = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
        return waitFor(element, in: app, timeout: timeout)
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

    /// System prompts (notifications, photo library) are answered with "not now" or "don't allow".
    private func answerPrompts(in app: XCUIApplication) {
        let deny = ["Don’t Allow", "Don't Allow", "Not Now", "Later", "OK", "Allow"]
        for _ in 0..<3 {
            let alert = springboard.alerts.firstMatch.exists ? springboard.alerts.firstMatch : app.alerts.firstMatch
            guard alert.exists else { return }
            let buttons = alert.buttons.allElementsBoundByIndex
            guard !buttons.isEmpty else { return }
            let labels = buttons.map(\.label)
            let index = labels.firstIndex(where: { deny.contains($0) }) ?? buttons.count - 1
            buttons[index].tap()
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
}
