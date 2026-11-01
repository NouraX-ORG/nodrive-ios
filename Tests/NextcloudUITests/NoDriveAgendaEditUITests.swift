// SPDX-FileCopyrightText: 2026 Nourax
// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

/// NoAgenda editing, end to end, in the simulator (CI job "screens", shard "agenda"). The app signs in to the local
/// stand-in for drive.nourax.org (tools/ci/drive-stand-in.py --agenda), which answers from the real server's recorded
/// answers and takes writes with the real server's rules (tools/ci/agenda_edit_state.py). Environment:
///   NODRIVE_UITEST_ACCOUNT  "server URL|login name|app password"
///   NODRIVE_AGENDA_TODAY    the day the CI server was seeded for, "yyyy-MM-dd"
///   NODRIVE_VARIANT         name of this run, e.g. agenda-edit-light
///   NODRIVE_SHOTS_DIR       host folder; files go to <dir>/<variant>/
/// The conflict and the waiting flow are in two parts each (A, then the stand-in mode changes, then B): the part B opens the
/// app again, which proves that the unsent change survives a restart.
@MainActor
final class NoDriveAgendaEditUITests: XCTestCase {
    private let env = ProcessInfo.processInfo.environment
    private var variant: String { env["NODRIVE_VARIANT"] ?? "agenda-edit" }
    private var springboard: XCUIApplication { XCUIApplication(bundleIdentifier: "com.apple.springboard") }

    override func setUp() async throws {
        continueAfterFailure = true
    }

    // MARK: - Tests

    func test1DayConflictsAndWorkload() throws {
        let app = try openAgenda()
        // Dentist (Personal) and Client call (Work) are both at 10:00 and mine: a clash. "Late call" overlaps the tentative one: soft
        for title in ["Dentist", "Client call"] {
            let row = findRowButton(app, title)
            XCTAssertNotNil(row, "\(title) is missing")
            XCTAssertTrue(row?.label.contains("clash") == true, "\(title) is not marked as a clash: \(row?.label ?? "")")
        }
        let late = findRowButton(app, "Late call")
        XCTAssertTrue(late?.label.contains("clash") == true, "Late call is not marked as a (soft) clash")
        // The workload bar: Big push is 60 hours over two days; the day is overbooked
        let bar = element(app, "agendaWorkloadBar")
        scrollToTop(app)
        XCTAssertTrue(bar.waitForExistence(timeout: 20), "the workload bar is missing")
        XCTAssertTrue(bar.label.contains("h planned") && bar.label.contains("h free"), "the bar says: \(bar.label)")
        XCTAssertTrue(bar.label.contains("overbooked"), "the day is not overbooked: \(bar.label)")
        save("agenda-day-conflicts")
        // An agent of mine is overbooked on its day: the problem names it
        XCTAssertNotNil(findRow(app, "Writer-Bot is overbooked on"), "the problem about the overbooked agent is missing")
        // An agent's item never clashes with mine: the Writer-Bot review (14:00) is not marked
        let review = findRowButton(app, "Writer-Bot review")
        XCTAssertNotNil(review, "the Writer-Bot review row is missing")
        XCTAssertTrue(review?.label.contains("clash") == false, "an agent item is marked as a clash: \(review?.label ?? "")")
        // The Conflicts chip keeps only rows with a mark
        element(app, "agendaChip-conflicts").tap()
        Thread.sleep(forTimeInterval: 1)
        XCTAssertNil(findRowButton(app, "Lunch hold", timeout: 3, absent: true), "Conflicts still shows a row without a mark")
        XCTAssertNotNil(findRowButton(app, "Client call"), "Conflicts hides a clash")
        save("agenda-conflicts-chip")
        element(app, "agendaChip-conflicts").tap()
        // Week: the workload bar per day
        app.segmentedControls["agendaViewPicker"].buttons["Week"].tap()
        Thread.sleep(forTimeInterval: 2)
        scrollToTop(app)
        // Only the days with planned work or busy time have a bar, and the list shows what is on the screen
        XCTAssertTrue(scrollDownUntilExists(app, element(app, "agendaWorkloadBarWeek")), "the week has no workload bar")
        save("agenda-week-workload")
    }

    func test2EditAgentOfTask() throws {
        let app = try openAgenda()
        guard let row = findRowButton(app, "Write homepage copy") else { XCTFail("Write homepage copy is missing"); return }
        XCTAssertTrue(row.label.contains("Writer-Bot"), "the task does not start with Writer-Bot: \(row.label)")
        row.tap()
        XCTAssertTrue(app.buttons["agendaDetailEdit"].waitForExistence(timeout: 20), "the detail sheet has no Edit button")
        app.buttons["agendaDetailEdit"].tap()
        // The agent: Self, then Save
        let selfOption = app.buttons["agendaAgentOption-SELF"]
        XCTAssertTrue(scrollTo(app, selfOption, up: false), "the picker has no Self")
        XCTAssertTrue(app.buttons["agendaAgentOption-AG-0001"].exists, "the picker has no Writer-Bot")
        save("agenda-edit-agent")
        XCTAssertFalse(app.buttons["agendaEditorSave"].isEnabled, "Save is on before a change")
        selfOption.tap()
        XCTAssertTrue(app.buttons["agendaEditorSave"].isEnabled, "Save is off after a change")
        app.buttons["agendaEditorSave"].tap()
        XCTAssertTrue(waitForLabel(app, "Write homepage copy", contains: "done by you"), "after Save the task is still done by the agent")
        // Self back to Writer-Bot
        guard let again = findRowButton(app, "Write homepage copy") else { XCTFail("the task is gone"); return }
        again.tap()
        XCTAssertTrue(app.buttons["agendaDetailEdit"].waitForExistence(timeout: 20))
        app.buttons["agendaDetailEdit"].tap()
        let writer = app.buttons["agendaAgentOption-AG-0001"]
        XCTAssertTrue(scrollTo(app, writer, up: false), "the picker has no Writer-Bot")
        writer.tap()
        app.buttons["agendaEditorSave"].tap()
        XCTAssertTrue(waitForLabel(app, "Write homepage copy", contains: "Writer-Bot"), "after Save the task is not done by Writer-Bot")
        save("agenda-edit-agent-saved")
    }

    func test3CreateEvent() throws {
        let app = try openAgenda()
        element(app, "agendaAdd").tap()
        let title = app.textFields["agendaCreateTitle"]
        XCTAssertTrue(title.waitForExistence(timeout: 20), "the new-event sheet did not open")
        // Self is preselected
        let selfOption = app.buttons["agendaAgentOption-SELF"]
        XCTAssertTrue(scrollTo(app, selfOption, up: false), "the agent picker has no Self")
        XCTAssertTrue(selfOption.isSelected, "Self is not preselected")
        XCTAssertFalse(app.buttons["agendaCreateSave"].isEnabled, "Save is on without a title")
        title.tap()
        title.typeText("UI test event")
        save("agenda-create")
        XCTAssertTrue(app.buttons["agendaCreateSave"].isEnabled)
        app.buttons["agendaCreateSave"].tap()
        XCTAssertNotNil(findRowButton(app, "UI test event"), "the new event is not in the Day list")
        save("agenda-created")
    }

    func test4LockedViewerTask() throws {
        let app = try openAgenda()
        guard let row = findRowButton(app, "Internal sync") else { XCTFail("Internal sync is missing"); return }
        XCTAssertTrue(row.label.contains("can't be changed"), "the row does not say it is locked: \(row.label)")
        row.tap()
        XCTAssertTrue(app.buttons["agendaDetailOpen"].waitForExistence(timeout: 20))
        XCTAssertTrue(element(app, "agendaDetailLock").waitForExistence(timeout: 10), "no lock reason")
        XCTAssertTrue(app.staticTexts["You can only view this project in NoGantt."].exists || element(app, "agendaDetailLock").label.contains("only view"), "wrong lock reason")
        XCTAssertFalse(app.buttons["agendaDetailEdit"].exists, "a viewer task can be edited")
        save("agenda-locked")
    }

    func test5RepeatingEvent() throws {
        let app = try openAgenda()
        guard let row = findRowButton(app, "Stand-up") else { XCTFail("Stand-up is missing"); return }
        row.tap()
        XCTAssertTrue(app.buttons["agendaDetailOpen"].waitForExistence(timeout: 20))
        XCTAssertEqual(app.buttons["agendaDetailOpen"].label, "Open in NoCalendar")
        XCTAssertTrue(element(app, "agendaDetailLock").waitForExistence(timeout: 10))
        XCTAssertTrue(element(app, "agendaDetailLock").label.contains("This repeats"), "wrong reason: \(element(app, "agendaDetailLock").label)")
        XCTAssertFalse(app.buttons["agendaDetailEdit"].exists, "a repeating event can be edited")
        save("agenda-repeating")
    }

    func test6TodoDone() throws {
        let app = try openAgenda()
        guard let row = findRowButton(app, "Draft report") else { XCTFail("Draft report is missing"); return }
        row.tap()
        XCTAssertTrue(app.buttons["agendaDetailEdit"].waitForExistence(timeout: 20))
        app.buttons["agendaDetailEdit"].tap()
        let done = app.switches["agendaEditorDone"]
        XCTAssertTrue(scrollTo(app, done, up: false), "the to-do has no Done switch")
        done.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        app.buttons["agendaEditorSave"].tap()
        XCTAssertNil(findRowButton(app, "Draft report", timeout: 20, absent: true), "a done to-do is still listed")
        save("agenda-todo-done")
    }

    // The edit conflict: the stand-in is switched to "touch" before part A (tools/ci/screens.sh)

    func testConflictA() throws {
        let app = try openAgenda()
        guard let row = findRowButton(app, "Client call") else { XCTFail("Client call is missing"); return }
        row.tap()
        XCTAssertTrue(app.buttons["agendaDetailEdit"].waitForExistence(timeout: 20))
        app.buttons["agendaDetailEdit"].tap()
        let title = app.textFields["agendaEditorTitle"]
        XCTAssertTrue(title.waitForExistence(timeout: 20))
        title.tap()
        title.typeText(" moved")
        app.buttons["agendaEditorSave"].tap()
        let banner = element(app, "agendaBanner-queueNotSent")
        XCTAssertTrue(waitForBanner(banner, in: app, timeout: 60), "no 'not sent' banner after the item changed meanwhile")
        XCTAssertTrue(banner.label.contains("1 change not sent"), "the banner says: \(banner.label)")
        element(app, "agendaBannerReview").tap()
        let list = element(app, "agendaNotSentList")
        XCTAssertTrue(list.waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["This changed somewhere else while you were editing. NoAgenda kept the other change."].waitForExistence(timeout: 10), "the reason is not shown")
        XCTAssertTrue(app.buttons["agendaApplyAgain"].exists && app.buttons["agendaKeepOther"].exists, "the buttons are missing")
        save("agenda-not-sent")
    }

    func testConflictB() throws {
        let app = try openAgenda()
        let banner = element(app, "agendaBanner-queueNotSent")
        XCTAssertTrue(waitForBanner(banner, in: app, timeout: 60), "the unsent change did not survive the restart")
        element(app, "agendaBannerReview").tap()
        let apply = app.buttons["agendaApplyAgain"]
        XCTAssertTrue(apply.waitForExistence(timeout: 20))
        apply.tap()
        // Sent on top of the new version: the banner goes and the row has the new title
        XCTAssertTrue(app.staticTexts["Everything was sent."].waitForExistence(timeout: 60) || !app.buttons["agendaApplyAgain"].exists,
                      "the list still holds the change after Apply my change again")
        if app.buttons["agendaNotSentDone"].waitForExistence(timeout: 10) { app.buttons["agendaNotSentDone"].tap() }
        XCTAssertTrue(waitBannerGone(banner, in: app, timeout: 60), "the banner is still there after Apply my change again")
        XCTAssertNotNil(findRowButton(app, "Client call moved"), "the change was not applied")
        save("agenda-applied-again")
    }

    // Waiting offline: the stand-in drops every connection before part A

    func testWaitingA() throws {
        let app = try openAgenda(expectData: false)
        let banner = element(app, "agendaBanner-offline")
        XCTAssertTrue(waitFor(banner, in: app, timeout: 90), "the offline banner is not shown")
        guard let row = findRowButton(app, "Lunch hold") else { XCTFail("Lunch hold is missing"); return }
        row.tap()
        XCTAssertTrue(app.buttons["agendaDetailEdit"].waitForExistence(timeout: 20))
        app.buttons["agendaDetailEdit"].tap()
        let title = app.textFields["agendaEditorTitle"]
        XCTAssertTrue(title.waitForExistence(timeout: 20))
        title.tap()
        title.typeText(" waiting")
        app.buttons["agendaEditorSave"].tap()
        let waiting = element(app, "agendaBanner-queueWaiting")
        XCTAssertTrue(waitForBanner(waiting, in: app, timeout: 60), "no 'waiting to send' banner")
        XCTAssertTrue(waiting.label.contains("Waiting to send 1 change"), "the banner says: \(waiting.label)")
        XCTAssertNotNil(findRowButton(app, "Lunch hold waiting"), "the waiting change is not drawn on its row")
        save("agenda-waiting")
    }

    func testWaitingB() throws {
        let app = try openAgenda()
        // The app is back online and the queue is sent after the reads
        let waiting = element(app, "agendaBanner-queueWaiting")
        XCTAssertTrue(waitBannerGone(waiting, in: app, timeout: 90), "the waiting change was not sent when the network was back")
        XCTAssertNotNil(findRowButton(app, "Lunch hold waiting"), "the sent change is not in the list")
        XCTAssertFalse(element(app, "agendaBanner-queueNotSent").exists, "the change ended in 'not sent'")
        save("agenda-sent-after-waiting")
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

    private func openAgenda(expectData: Bool = true) throws -> XCUIApplication {
        let app = try launchApp()
        Thread.sleep(forTimeInterval: 8)
        showAgenda(app)
        if expectData { _ = waitForText(app, "Dentist", timeout: 120) }
        return app
    }

    private func showAgenda(_ app: XCUIApplication) {
        let list = app.descendants(matching: .any)["agendaList"]
        openSidebar(app)
        let entry = app.descendants(matching: .any)["sidebarNoAgenda"]
        XCTAssertTrue(waitFor(entry, in: app, timeout: 60, hittable: true), "the sidebar has no NoAgenda entry")
        entry.tap()
        answerPersonalQuestion(app, wait: 40)
        XCTAssertTrue(waitFor(list, in: app, timeout: 60), "NoAgenda did not open")
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
        for _ in 0..<3 where !app.descendants(matching: .any)["agendaList"].exists {
            showAgenda(app)
            Thread.sleep(forTimeInterval: 3)
        }
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    /// A row of the list (a button with an `agendaRow-` identifier) whose label holds `text`; the list is scrolled to find it.
    private func findRowButton(_ app: XCUIApplication, _ text: String, timeout: TimeInterval = 60, absent: Bool = false) -> XCUIElement? {
        findElement(app, app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'agendaRow-' AND label CONTAINS %@", text)).firstMatch,
                    text: text, timeout: timeout, absent: absent)
    }

    /// A row or problem whose label holds `text`.
    private func findRow(_ app: XCUIApplication, _ text: String, timeout: TimeInterval = 60) -> XCUIElement? {
        findElement(app, app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch, text: text, timeout: timeout, absent: false)
    }

    private func findElement(_ app: XCUIApplication, _ target: XCUIElement, text: String, timeout: TimeInterval, absent: Bool) -> XCUIElement? {
        let list = app.descendants(matching: .any)["agendaList"]
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            ensureAgenda(app)
            if target.exists { return target }
            for _ in 0..<14 {
                if list.exists { scrollList(app, up: true, slow: true) }
                if target.exists { return target }
            }
            for _ in 0..<14 where list.exists {
                scrollList(app, up: false, slow: true)
                if target.exists { return target }
            }
            Thread.sleep(forTimeInterval: 2)
        } while Date() < deadline
        if !absent { saveFailure(app, looking: text) }
        return nil
    }

    private func waitForLabel(_ app: XCUIApplication, _ title: String, contains text: String, timeout: TimeInterval = 60) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            ensureAgenda(app)
            let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'agendaRow-' AND label CONTAINS %@ AND label CONTAINS %@", title, text)).firstMatch
            if row.exists { return true }
            for _ in 0..<10 { scrollList(app, up: true, slow: true); if row.exists { return true } }
            for _ in 0..<10 { scrollList(app, up: false, slow: true); if row.exists { return true } }
            Thread.sleep(forTimeInterval: 2)
        } while Date() < deadline
        saveFailure(app, looking: title + " / " + text)
        return false
    }

    private func scrollList(_ app: XCUIApplication, up: Bool, slow: Bool = false) {
        let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: up ? 0.8 : 0.35))
        let to = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: up ? 0.35 : 0.8))
        from.press(forDuration: 0.05, thenDragTo: to, withVelocity: slow ? .slow : .default, thenHoldForDuration: 0)
    }

    /// Scrolls (the list or a form) until the element is there and can be tapped. `up` moves the content up.
    private func scrollTo(_ app: XCUIApplication, _ target: XCUIElement, up: Bool) -> Bool {
        for _ in 0..<14 {
            if target.exists, target.isHittable { return true }
            let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: up ? 0.8 : 0.7))
            let to = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: up ? 0.35 : 0.3))
            from.press(forDuration: 0.05, thenDragTo: to, withVelocity: .default, thenHoldForDuration: 0)
        }
        if target.exists, target.isHittable { return true }
        // The list is above the target: try the other way, from the top
        for _ in 0..<14 {
            if target.exists, target.isHittable { return true }
            let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
            let to = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
            from.press(forDuration: 0.05, thenDragTo: to, withVelocity: .default, thenHoldForDuration: 0)
        }
        return target.exists && target.isHittable
    }

    /// From the top of the list, slowly downwards, until the element is there.
    private func scrollDownUntilExists(_ app: XCUIApplication, _ target: XCUIElement) -> Bool {
        scrollToTop(app)
        if target.exists { return true }
        for _ in 0..<14 {
            scrollList(app, up: true, slow: true)
            if target.exists { return true }
        }
        return false
    }

    /// Scrolls the list back to its first row (the banners and the workload bar are there).
    private func scrollToTop(_ app: XCUIApplication) {
        for _ in 0..<12 {
            let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
            let to = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9))
            from.press(forDuration: 0.05, thenDragTo: to, withVelocity: .fast, thenHoldForDuration: 0)
        }
        Thread.sleep(forTimeInterval: 1)
    }

    /// A banner sits at the top of the list: the list is scrolled there before it is looked for.
    private func waitForBanner(_ banner: XCUIElement, in app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            ensureAgenda(app)
            if banner.exists { return true }
            scrollToTop(app)
            if banner.waitForExistence(timeout: 3) { return true }
        } while Date() < deadline
        return false
    }

    private func waitBannerGone(_ banner: XCUIElement, in app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            ensureAgenda(app)
            scrollToTop(app)
            if !banner.exists { return true }
            Thread.sleep(forTimeInterval: 2)
        } while Date() < deadline
        return false
    }

    private func openSidebar(_ app: XCUIApplication) {
        let sidebarButton = app.buttons["openSidebar"]
        let sidebarOpen = app.descendants(matching: .any)["sidebarFiles"]
        for _ in 1...5 where !sidebarOpen.exists {
            if sidebarButton.exists, sidebarButton.isHittable { sidebarButton.tap() }
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
            if element.exists, !hittable || element.isHittable { return true }
            Thread.sleep(forTimeInterval: 1)
        } while Date() < deadline
        return false
    }

    private func waitUntilGone(_ element: XCUIElement, in app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            answerPrompts(in: app)
            if !element.exists { return true }
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
        let visible = app.staticTexts.allElementsBoundByIndex.prefix(8).map(\.label).joined(separator: " | ")
        print("NoAgenda edit UI: did not find \"\(text)\"; agendaList exists: \(app.descendants(matching: .any)["agendaList"].exists); on screen: \(visible)")
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
