// SPDX-FileCopyrightText: 2026 Nourax
// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

/// The NoAgenda Timeline, end to end, in the simulator (CI job "screens", shards "agenda-timeline" and "agenda-timeline-dark").
/// The app signs in to the local stand-in for drive.nourax.org (tools/ci/drive-stand-in.py --agenda), which answers from the real
/// server's recorded answers and takes writes with the real server's rules. Environment:
///   NODRIVE_UITEST_ACCOUNT  "server URL|login name|app password"
///   NODRIVE_AGENDA_TODAY    the day the CI server was seeded for, "yyyy-MM-dd"
///   NODRIVE_VARIANT         name of this run, e.g. agenda-timeline-light
///   NODRIVE_SHOTS_DIR       host folder; files go to <dir>/<variant>/
/// The tests run in the order of their numbers; the last one moves a task (the stand-in keeps the change for the next test only).
@MainActor
final class NoDriveAgendaTimelineUITests: XCTestCase {
    private let env = ProcessInfo.processInfo.environment
    private var variant: String { env["NODRIVE_VARIANT"] ?? "agenda-timeline" }
    private var springboard: XCUIApplication { XCUIApplication(bundleIdentifier: "com.apple.springboard") }

    override func setUp() async throws {
        continueAfterFailure = true
    }

    // MARK: - Tests

    func test1TimelineWeeks() throws {
        let app = try openTimeline()
        // The groups: the project, its phase, the list of to-dos and the board
        XCTAssertNotNil(findElement(app, id: "agendaTimelineGroup-Website"), "the project group is missing")
        // My Gantt task in its phase: 40 % filled, done by Writer-Bot
        guard let write = findBar(app, "Write homepage copy") else { XCTFail("Write homepage copy is not on the Timeline"); return }
        XCTAssertTrue(write.label.hasPrefix("Gantt task, Write homepage copy"), "the bar says: \(write.label)")
        XCTAssertTrue(write.label.contains("40 % done"), "the bar says: \(write.label)")
        XCTAssertTrue(write.label.contains("Writer-Bot"), "the bar says: \(write.label)")
        XCTAssertNotNil(findElement(app, id: "agendaTimelineGroup-Copy"), "the phase group is missing")
        save("agenda-timeline-top")
        // The arrow from Write homepage copy to Review banners, and the stub of Publish banners (Sara's task, not on this screen)
        guard let review = findBar(app, "Review banners") else { XCTFail("Review banners is not on the Timeline"); return }
        XCTAssertTrue(review.label.hasPrefix("Gantt task, Review banners"), "the bar says: \(review.label)")
        let arrows = element(app, "agendaTimelineArrows")
        XCTAssertTrue(arrows.exists, "the dependency arrows are missing")
        XCTAssertTrue(arrows.label.contains("Review banners comes after Write homepage copy"), "the arrows say: \(arrows.label)")
        XCTAssertFalse(arrows.label.contains("Publish banners"), "an arrow comes from a task that is not on the screen: \(arrows.label)")
        let stub = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'agendaTimelineStub-'")).firstMatch
        XCTAssertTrue(stub.waitForExistence(timeout: 20), "the stub of the task that is not on the screen is missing")
        XCTAssertEqual(stub.label, "After: Publish banners (Sara)")
        stub.tap()
        XCTAssertTrue(waitForText(app, "After: Publish banners (Sara)", identifier: "agendaToastText", timeout: 20), "the stub does not say which task it follows")
        save("agenda-timeline-stub")
        // The diamonds: the milestone and a dated card
        XCTAssertNotNil(findBar(app, "Launch"), "the milestone is missing")
        XCTAssertTrue(findBar(app, "Launch")?.label.hasPrefix("Milestone, Launch") == true)
        XCTAssertNotNil(findBar(app, "Plain card"), "the dated card is missing")
        XCTAssertTrue(findBar(app, "Plain card")?.label.hasPrefix("Card, Plain card") == true)
        // A to-do with a start and a due date is a bar
        XCTAssertNotNil(findBar(app, "Prepare launch notes"), "the to-do with two dates is missing")
        XCTAssertTrue(findBar(app, "Prepare launch notes")?.label.hasPrefix("To-do, Prepare launch notes") == true)
        // A to-do with only a due date is not on the Timeline
        XCTAssertNil(findBar(app, "Draft report", timeout: 3, absent: true), "a to-do without a start is drawn")
        // The agent after the bar: a task done by Self has no robot
        XCTAssertTrue(findBar(app, "Big push")?.label.contains("Self") == true, "the agent of a task done by hand is not Self")
        scrollChart(app, up: false, times: 6)
        save("agenda-timeline")
    }

    func test2TimelineDays() throws {
        let app = try openTimeline()
        let zoom = app.segmentedControls["agendaTimelineZoom"]
        XCTAssertTrue(zoom.waitForExistence(timeout: 20), "the zoom control is missing")
        zoom.buttons["Days"].tap()
        Thread.sleep(forTimeInterval: 2)
        XCTAssertNotNil(findBar(app, "Write homepage copy"), "the task is gone at the Days zoom")
        XCTAssertTrue(element(app, "agendaTimelineScale").exists, "the scale is missing")
        save("agenda-timeline-days")
        zoom.buttons["Weeks"].tap()
        Thread.sleep(forTimeInterval: 1)
        XCTAssertNotNil(findBar(app, "Write homepage copy"), "the task is gone after going back to Weeks")
    }

    func test3LockedAndTheTeamChip() throws {
        let app = try openTimeline()
        // My team is not drawn here: its chip is dimmed
        let team = element(app, "agendaChip-team")
        XCTAssertTrue(team.exists)
        XCTAssertFalse(team.isEnabled, "the team chip is on in the Timeline")
        // A task of a project I may only view: a lock, and the sheet says why
        guard let bar = findBar(app, "Internal sync") else { XCTFail("Internal sync is missing"); return }
        XCTAssertTrue(bar.label.contains("can't be changed"), "the bar does not say it is locked: \(bar.label)")
        bar.tap()
        XCTAssertTrue(app.buttons["agendaDetailOpen"].waitForExistence(timeout: 20), "the detail sheet did not open")
        XCTAssertTrue(element(app, "agendaDetailLock").waitForExistence(timeout: 10), "the sheet gives no reason")
        XCTAssertTrue(element(app, "agendaDetailLock").label.contains("only view"), "wrong reason: \(element(app, "agendaDetailLock").label)")
        XCTAssertFalse(app.buttons["agendaDetailEdit"].exists, "a viewer task has a date editor")
        save("agenda-timeline-locked")
    }

    func test4LegendAndTheArrows() throws {
        let app = try openTimeline()
        let legend = element(app, "agendaTimelineLegend")
        XCTAssertTrue(legend.waitForExistence(timeout: 20), "the legend button is missing")
        legend.tap()
        XCTAssertTrue(app.staticTexts["What the Timeline shows"].waitForExistence(timeout: 20), "the legend did not open")
        XCTAssertTrue(app.staticTexts["Bar: a NoGantt task. The filled part is how much is done."].exists, "the legend has no line for the bars")
        save("agenda-timeline-legend")
        element(app, "agendaTimelineLegendDone").tap()
        // The four weeks of the arrows: the title changes by 28 days, Today brings it back
        let title = element(app, "agendaHeaderTitle")
        let first = title.label
        element(app, "agendaNext").tap()
        Thread.sleep(forTimeInterval: 1)
        XCTAssertNotEqual(title.label, first, "the range did not move")
        element(app, "agendaToday").tap()
        Thread.sleep(forTimeInterval: 1)
        XCTAssertEqual(title.label, first, "Today did not bring the range back")
    }

    func test5NoDragButAnEditor() throws {
        let app = try openTimeline()
        guard let bar = findBar(app, "Write homepage copy") else { XCTFail("Write homepage copy is missing"); return }
        bar.tap()
        XCTAssertTrue(app.buttons["agendaDetailEdit"].waitForExistence(timeout: 20), "the task has no date editor")
        app.buttons["agendaDetailEdit"].tap()
        XCTAssertTrue(element(app, "agendaEditorStart").waitForExistence(timeout: 20), "the editor has no start date")
        XCTAssertTrue(element(app, "agendaEditorEnd").exists, "the editor has no end date")
        for id in ["agendaMoveByMinus7", "agendaMoveByMinus1", "agendaMoveByPlus1", "agendaMoveByPlus7"] {
            XCTAssertTrue(scrollTo(app, app.buttons[id], up: false), "the editor has no button \(id)")
        }
        XCTAssertFalse(app.buttons["agendaEditorSave"].isEnabled, "Save is on before a change")
        app.buttons["agendaMoveByPlus1"].tap()
        XCTAssertTrue(app.buttons["agendaEditorSave"].isEnabled, "Save is off after Move by +1")
        app.buttons["agendaMoveByMinus1"].tap()
        XCTAssertFalse(app.buttons["agendaEditorSave"].isEnabled, "+1 and -1 is a change")
        save("agenda-timeline-move-by")
    }

    func test6EditorMovesATask() throws {
        let app = try openTimeline()
        guard let bar = findBar(app, "Review banners") else { XCTFail("Review banners is missing"); return }
        let before = bar.label
        bar.tap()
        XCTAssertTrue(app.buttons["agendaDetailEdit"].waitForExistence(timeout: 20), "the task has no date editor")
        app.buttons["agendaDetailEdit"].tap()
        let plus = app.buttons["agendaMoveByPlus1"]
        XCTAssertTrue(scrollTo(app, plus, up: false), "the editor has no Move by +1")
        plus.tap()
        save("agenda-timeline-editor")
        XCTAssertTrue(app.buttons["agendaEditorSave"].isEnabled, "Save is off after Move by +1")
        app.buttons["agendaEditorSave"].tap()
        // The toast shows the dates NoGantt saved
        XCTAssertTrue(waitForText(app, "Moved to", identifier: "agendaToastText", timeout: 60), "no 'Moved to' toast after Save")
        save("agenda-timeline-moved")
        // The bar moved
        guard let moved = findBar(app, "Review banners") else { XCTFail("Review banners is gone after the move"); return }
        XCTAssertNotEqual(moved.label, before, "the bar still says the same dates")
        XCTAssertFalse(element(app, "agendaBanner-queueWaiting").exists, "the change still waits")
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
        app.launchEnvironment["NODRIVE_AGENDA_WORKDAYS"] = "all"
        app.launchEnvironment["TZ"] = "UTC"
        app.launch()
        let sidebarButton = app.buttons["openSidebar"]
        XCTAssertTrue(waitFor(sidebarButton, in: app, timeout: 300, hittable: true), "the main screen with the sidebar button never came up")
        return app
    }

    private func openTimeline() throws -> XCUIApplication {
        let app = try launchApp()
        Thread.sleep(forTimeInterval: 8)
        showAgenda(app)
        // The first test finds the Day view and waits for its data; a later one finds the Timeline chosen already (the view is kept)
        if !element(app, "agendaTimelineScale").waitForExistence(timeout: 5) { _ = waitForText(app, "Dentist", identifier: nil, timeout: 120) }
        showTimeline(app)
        return app
    }

    /// Picks "Timeline" in the view picker (the view is kept, so a later test may find it chosen already).
    private func showTimeline(_ app: XCUIApplication) {
        let scale = element(app, "agendaTimelineScale")
        for _ in 0..<4 where !scale.exists {
            ensureAgenda(app)
            let picker = app.segmentedControls["agendaViewPicker"]
            if picker.waitForExistence(timeout: 20) { picker.buttons["Timeline"].tap() }
            _ = scale.waitForExistence(timeout: 20)
        }
        XCTAssertTrue(scale.exists, "the Timeline did not open")
        Thread.sleep(forTimeInterval: 2)
    }

    private func showAgenda(_ app: XCUIApplication) {
        let list = app.descendants(matching: .any)["agendaList"]
        openSidebar(app)
        let entry = app.descendants(matching: .any)["sidebarNoAgenda"]
        XCTAssertTrue(waitFor(entry, in: app, timeout: 60, hittable: true), "the sidebar has no NoAgenda entry")
        entry.tap()
        answerPersonalQuestion(app, wait: 40)
        // The Timeline has no list: the view picker is the sign that NoAgenda is open
        XCTAssertTrue(waitFor(list, in: app, timeout: 60) || app.segmentedControls["agendaViewPicker"].waitForExistence(timeout: 30), "NoAgenda did not open")
    }

    private func answerPersonalQuestion(_ app: XCUIApplication, wait: TimeInterval) {
        let question = app.descendants(matching: .any)["agendaPersonalQuestion"]
        guard question.waitForExistence(timeout: wait) else { return }
        var work = app.switches["agendaPersonalToggle-cal:work"]
        if !work.waitForExistence(timeout: 10) { work = app.switches["Work"] }
        if work.exists {
            for _ in 0..<3 where (work.value as? String) != "0" {
                work.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
                Thread.sleep(forTimeInterval: 1)
            }
        }
        app.buttons["agendaPersonalDone"].tap()
    }

    private func ensureAgenda(_ app: XCUIApplication) {
        answerPersonalQuestion(app, wait: 1)
        for _ in 0..<3 where !app.segmentedControls["agendaViewPicker"].exists {
            showAgenda(app)
            Thread.sleep(forTimeInterval: 3)
        }
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    /// A bar or diamond of the Timeline (a button with an `agendaTimelineBar-` identifier) whose label holds `text`; the chart is
    /// scrolled up and down to find it.
    private func findBar(_ app: XCUIApplication, _ text: String, timeout: TimeInterval = 60, absent: Bool = false) -> XCUIElement? {
        let target = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'agendaTimelineBar-' AND label CONTAINS %@", text)).firstMatch
        return findElement(app, target, text: text, timeout: timeout, absent: absent)
    }

    private func findElement(_ app: XCUIApplication, id: String, timeout: TimeInterval = 60) -> XCUIElement? {
        findElement(app, element(app, id), text: id, timeout: timeout, absent: false)
    }

    private func findElement(_ app: XCUIApplication, _ target: XCUIElement, text: String, timeout: TimeInterval, absent: Bool) -> XCUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            ensureAgenda(app)
            if target.exists { return target }
            scrollChart(app, up: false, times: 8)
            if target.exists { return target }
            for _ in 0..<8 {
                scrollChart(app, up: true, times: 1)
                if target.exists { return target }
            }
            Thread.sleep(forTimeInterval: 2)
        } while Date() < deadline
        if !absent { saveFailure(app, looking: text) }
        return nil
    }

    /// Drags the chart. `up` moves the rows up (shows what is further down); otherwise back to the top.
    private func scrollChart(_ app: XCUIApplication, up: Bool, times: Int) {
        for _ in 0..<times {
            let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: up ? 0.85 : 0.5))
            let to = app.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: up ? 0.5 : 0.9))
            from.press(forDuration: 0.05, thenDragTo: to, withVelocity: .default, thenHoldForDuration: 0)
        }
    }

    /// Scrolls a form until the element is there and can be tapped.
    private func scrollTo(_ app: XCUIApplication, _ target: XCUIElement, up: Bool) -> Bool {
        for _ in 0..<14 {
            if target.exists, target.isHittable { return true }
            let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: up ? 0.8 : 0.7))
            let to = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: up ? 0.35 : 0.3))
            from.press(forDuration: 0.05, thenDragTo: to, withVelocity: .default, thenHoldForDuration: 0)
        }
        if target.exists, target.isHittable { return true }
        for _ in 0..<14 {
            if target.exists, target.isHittable { return true }
            let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
            let to = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
            from.press(forDuration: 0.05, thenDragTo: to, withVelocity: .default, thenHoldForDuration: 0)
        }
        return target.exists && target.isHittable
    }

    private func openSidebar(_ app: XCUIApplication) {
        let sidebarButton = app.buttons["openSidebar"]
        let sidebarOpen = app.descendants(matching: .any)["sidebarFiles"]
        for _ in 1...5 where !sidebarOpen.exists {
            if sidebarButton.exists, sidebarButton.isHittable { sidebarButton.tap() }
            _ = waitFor(sidebarOpen, in: app, timeout: 10)
        }
    }

    /// Waits for an element whose label holds `text` (with the identifier when one is given).
    private func waitForText(_ app: XCUIApplication, _ text: String, identifier: String?, timeout: TimeInterval = 90) -> Bool {
        let format = identifier == nil ? "label CONTAINS %@" : "label CONTAINS %@ AND identifier == '\(identifier ?? "")'"
        let target = app.descendants(matching: .any).matching(NSPredicate(format: format, text)).firstMatch
        return waitFor(target, in: app, timeout: timeout)
    }

    private func waitFor(_ element: XCUIElement, in app: XCUIApplication, timeout: TimeInterval, hittable: Bool = false) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            answerPrompts(in: app)
            if element.exists, !hittable || element.isHittable { return true }
            Thread.sleep(forTimeInterval: 1)
        } while Date() < deadline
        return false
    }

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

    private func saveFailure(_ app: XCUIApplication, looking text: String) {
        let safe = String(text.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "-" }.prefix(40))
        let visible = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'agendaTimelineBar-'")).allElementsBoundByIndex.prefix(10).map(\.label).joined(separator: " | ")
        print("NoAgenda Timeline UI: did not find \"\(text)\"; scale exists: \(element(app, "agendaTimelineScale").exists); bars on screen: \(visible)")
        save("finder-failed-" + safe)
    }

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
