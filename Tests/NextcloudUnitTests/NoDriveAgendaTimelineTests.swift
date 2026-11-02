// SPDX-FileCopyrightText: 2026 Nourax
// SPDX-License-Identifier: GPL-3.0-or-later

import CoreGraphics
import Foundation
import Testing
import UIKit
@testable import Nextcloud

/// Builders for the Timeline tests: a calendar in UTC (Monday first), a shown date, items, a scale.
enum AgendaTimelineSupport {
    static let zone = TimeZone(secondsFromGMT: 0)!

    static var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = zone
        value.firstWeekday = 2
        return value
    }

    static func date(_ text: String) -> Date {
        ISO8601DateFormatter().date(from: text.count == 10 ? text + "T00:00:00Z" : text)!
    }

    /// A Monday.
    static let shown = date("2026-11-02")

    static func number(_ text: String) -> Int {
        NCAgendaTimelineDays.number(date(text), calendar: calendar)
    }

    static func scale(_ zoom: TimelineZoom = .weeks, nameWidth: CGFloat = 120) -> TimelineScale {
        TimelineScale(range: TimelineRange.around(shown, calendar: calendar), zoom: zoom, nameWidth: nameWidth)
    }

    static func task(_ id: Int, _ title: String, start: String?, end: String?, project: String = "Website", projectId: Int = 1, phase: String? = nil,
                     percent: Int? = nil, agent: AgentRef = .selfAgent, deps: [AgendaDependency] = []) -> AgendaItem {
        var item = AgendaItem(key: "gantt:\(id)", home: .gantt, kind: .ganttTask, title: title, sourceKey: "project:\(projectId)", sourceName: project,
                              sourceColor: "#2563EB", link: AgendaLink(home: .gantt, projectId: projectId, taskId: id))
        item.start = start.map(date)
        item.end = end.map(date)
        item.percent = percent
        item.projectName = project
        item.phase = phase
        item.agent = agent
        item.dependencies = deps
        return item
    }

    static func milestone(_ id: Int, _ title: String, day: String, project: String = "Website", projectId: Int = 1) -> AgendaItem {
        var item = AgendaItem(key: "milestone:\(id)", home: .gantt, kind: .milestone, title: title, sourceKey: "project:\(projectId)", sourceName: project,
                              sourceColor: "#2563EB", link: AgendaLink(home: .gantt, projectId: projectId))
        item.start = date(day)
        item.end = date(day)
        item.projectName = project
        return item
    }

    static func todo(_ key: String, _ title: String, start: String?, due: String?, list: String = "Personal") -> AgendaItem {
        var item = AgendaItem(key: key, home: .tasks, kind: .todo, title: title, sourceKey: "cal:" + list.lowercased(), sourceName: list,
                              sourceColor: "#2563EB", link: AgendaLink(home: .tasks, path: "/remote.php/dav/calendars/ali/personal/\(key).ics"))
        item.start = start.map(date)
        item.due = due.map(date)
        return item
    }

    static func card(_ id: Int, _ title: String, due: String, board: String = "Team board") -> AgendaItem {
        var item = AgendaItem(key: "board:1:\(id)", home: .board, kind: .card, title: title, sourceKey: "board:1", sourceName: board,
                              sourceColor: "#2563EB", link: AgendaLink(home: .board, boardId: 1, stackId: 2, cardId: id))
        item.due = date(due)
        return item
    }

    static func event(_ title: String, start: String, end: String, allDay: Bool = false, agent: AgentRef = .selfAgent, free: Bool = false) -> AgendaItem {
        var item = AgendaItem(key: "cal:" + title, home: .calendar, kind: .event, title: title, sourceKey: "cal:work", sourceName: "Work",
                              sourceColor: "#2563EB", link: AgendaLink(home: .calendar, path: "/remote.php/dav/calendars/ali/work/x.ics"))
        item.start = date(start)
        item.end = date(end)
        item.allDay = allDay
        item.agent = agent
        item.transparent = free
        return item
    }

    static func build(_ items: [AgendaItem], zoom: TimelineZoom = .weeks) -> TimelineLayout {
        NCAgendaTimelineLayout.build(items: items, scale: scale(zoom), calendar: calendar, ganttZone: zone)
    }

    static func titles(_ layout: TimelineLayout) -> [String] {
        layout.rows.map { row in
            switch row.content {
            case let .group(title, level): return (level == 0 ? "# " : "## ") + title
            case let .item(item): return item.title
            }
        }
    }

    static func dependency(_ id: String, _ title: String, type: String = "FS", lag: Int = 0, person: String? = nil) -> AgendaDependency {
        AgendaDependency(predecessorKey: id, predecessorTitle: title, type: type, lagDays: lag, predecessorPerson: person)
    }
}

// MARK: - Days, x and the range

@Suite("NoDrive NoAgenda Timeline: days, x and range")
struct NoDriveAgendaTimelineScaleTests {
    typealias S = AgendaTimelineSupport

    @Test("A day number is the day since 1970-01-01 and comes back as the same civil date, in any zone")
    func dayNumbers() {
        #expect(S.number("2026-11-02") == 20_759)
        #expect(S.number("1970-01-01") == 0)
        #expect(S.number("2024-02-29") - S.number("2024-02-28") == 1)
        #expect(S.number("2026-01-01") - S.number("2025-12-31") == 1)
        for text in ["1969-12-31", "2000-02-29", "2026-10-25", "2026-12-31", "2100-03-01"] {
            let value = NCAgendaTimelineDays.number(S.date(text), calendar: S.calendar)
            let parts = NCAgendaTimelineDays.parts(of: value)
            #expect(String(format: "%04d-%02d-%02d", parts.year, parts.month, parts.day) == text)
            #expect(NCAgendaTimelineDays.date(value, calendar: S.calendar) == S.date(text))
        }
        // 23:30 in New York is already the next day in UTC: the day number follows the calendar's zone
        var newYork = Calendar(identifier: .gregorian)
        newYork.timeZone = TimeZone(identifier: "America/New_York")!
        let late = S.date("2026-11-03T04:30:00Z")
        #expect(NCAgendaTimelineDays.number(late, calendar: newYork) == S.number("2026-11-02"))
        #expect(NCAgendaTimelineDays.number(late, calendar: S.calendar) == S.number("2026-11-03"))
    }

    @Test("The range is seven days before the shown date to eight weeks after it")
    func range() {
        let range = TimelineRange.around(S.shown, calendar: S.calendar)
        #expect(range.firstDay == S.number("2026-10-26"))
        #expect(range.lastDay == S.number("2026-12-28"))
        #expect(range.dayCount == 64)
        #expect(range.contains(day: S.number("2026-11-02")))
        #expect(!range.contains(day: S.number("2026-10-25")))
        #expect(!range.contains(day: S.number("2026-12-29")))
    }

    @Test("Date to x and back at the Weeks zoom (12 points a day) and the Days zoom (40 points a day)")
    func xAtBothZooms() {
        let weeks = S.scale(.weeks)
        let first = weeks.range.firstDay
        #expect(weeks.pointsPerDay == 12)
        #expect(weeks.x(forDay: first) == 120)
        #expect(weeks.x(forDay: first + 7) == 120 + 84)
        #expect(weeks.x(forDayCenter: first) == 126)
        #expect(weeks.chartWidth == 64 * 12)
        #expect(weeks.totalWidth == 120 + 64 * 12 + 160)
        #expect(weeks.day(atX: 120 + 84 + 5) == first + 7)
        #expect(weeks.day(atX: 120 + 84 - 1) == first + 6)
        let days = S.scale(.days)
        #expect(days.pointsPerDay == 40)
        #expect(days.x(forDay: first + 3) == 120 + 120)
        #expect(days.x(forDayCenter: first + 3) == 120 + 120 + 20)
        #expect(days.chartWidth == 64 * 40)
        for offset in [0, 1, 17, 63] {
            #expect(days.day(atX: days.x(forDay: first + offset)) == first + offset)
            #expect(weeks.day(atX: weeks.x(forDayCenter: first + offset)) == first + offset)
        }
        // The name column is the same in both zooms and folds to 120 points on a phone, 160 on a tablet
        #expect(S.scale(.weeks, nameWidth: 160).x(forDay: first) == 160)
    }

    @Test("The title above the Timeline is the first and the last day of the range")
    func headerTitle() {
        let first = NCAgendaTimelineDays.date(S.number("2026-10-26"), calendar: S.calendar)
        let last = NCAgendaTimelineDays.date(S.number("2026-12-28"), calendar: S.calendar)
        let expected = NCAgendaTimelineText.f("_nodrive_agenda_timeline_range_", NCAgendaFormat.shortDay(first), NCAgendaFormat.shortDay(last))
        #expect(NCAgendaTimelineHeader.title(shown: S.shown, calendar: S.calendar) == expected)
    }

    @Test("Monday to Sunday of a day number, and which day a week starts on")
    func weekdays() {
        #expect(NCAgendaTimelineDays.weekdayIndex(S.number("2026-11-02")) == 0)
        #expect(NCAgendaTimelineDays.weekdayIndex(S.number("2026-11-08")) == 6)
        #expect(NCAgendaTimelineDays.weekdayIndex(S.number("1969-12-31")) == 2)
        #expect(NCAgendaTimelineDays.isWeekStart(S.number("2026-11-02"), calendar: S.calendar))
        #expect(!NCAgendaTimelineDays.isWeekStart(S.number("2026-11-03"), calendar: S.calendar))
        var sunday = S.calendar
        sunday.firstWeekday = 1
        #expect(NCAgendaTimelineDays.isWeekStart(S.number("2026-11-01"), calendar: sunday))
    }

    @Test("The dependency types of NoGantt, in English and in its own letters")
    func dependencyKinds() {
        #expect(TimelineDependencyKind(type: "FS") == .finishToStart)
        #expect(TimelineDependencyKind(type: "EA") == .finishToStart)
        #expect(TimelineDependencyKind(type: "ss") == .startToStart)
        #expect(TimelineDependencyKind(type: "AA") == .startToStart)
        #expect(TimelineDependencyKind(type: "FF") == .finishToFinish)
        #expect(TimelineDependencyKind(type: "EE") == .finishToFinish)
        #expect(TimelineDependencyKind(type: "SF") == .startToFinish)
        #expect(TimelineDependencyKind(type: "AE") == .startToFinish)
        #expect(TimelineDependencyKind(type: "") == .finishToStart)
    }
}

// MARK: - Groups, rows and shapes

@Suite("NoDrive NoAgenda Timeline: groups, rows and shapes")
struct NoDriveAgendaTimelineRowsTests {
    typealias S = AgendaTimelineSupport

    @Test("Rows: projects by name; inside a project the items without a phase first by start (the milestone with them), then the phases by their first start; then NoTasks lists, then NoBoard boards; one row per item")
    func groupOrder() {
        let items = [
            S.task(1, "Write copy", start: "2026-11-03", end: "2026-11-06", phase: "Copy"),
            S.task(2, "Plan", start: "2026-11-04", end: "2026-11-05"),
            S.task(3, "Setup", start: "2026-11-01", end: "2026-11-03"),
            S.task(4, "Build page", start: "2026-11-10", end: "2026-11-12", phase: "Build"),
            S.task(5, "Research", start: "2026-10-28", end: "2026-10-30", phase: "Alpha"),
            S.milestone(1, "Launch", day: "2026-11-07"),
            S.task(6, "Sync", start: "2026-11-02", end: "2026-11-02", project: "Internal", projectId: 2),
            S.todo("t1", "Prepare notes", start: "2026-11-03", due: "2026-11-05"),
            S.card(7, "Call supplier", due: "2026-11-06")
        ]
        let layout = S.build(items)
        #expect(S.titles(layout) == [
            "# Internal", "Sync",
            "# Website", "Setup", "Plan", "Launch", "## Alpha", "Research", "## Copy", "Write copy", "## Build", "Build page",
            "# NoTasks > Personal", "Prepare notes",
            "# NoBoard > Team board", "Call supplier"
        ])
        let itemRows = layout.rows.filter { if case .item = $0.content { return true } else { return false } }
        #expect(itemRows.count == items.count)
        #expect(layout.shapes.count == items.count)
        // Rows follow each other without a gap: 30 for a group, 44 for an item
        var y: CGFloat = 0
        for row in layout.rows {
            #expect(row.y == y)
            if case .group = row.content { #expect(row.height == 30) } else { #expect(row.height == 44) }
            y += row.height
        }
        #expect(layout.contentHeight == y)
        // Every item is as high as a tap target
        #expect(NCAgendaTimelineLayout.rowHeight >= 44)
    }

    @Test("Only what belongs on the Timeline is drawn: mine, dated, not repeating, not done, in the range")
    func whatIsDrawn() {
        var team = S.task(1, "Team task", start: "2026-11-03", end: "2026-11-04")
        team.relation = .team
        var repeating = S.todo("t2", "Weekly", start: "2026-11-03", due: "2026-11-05")
        repeating.repeating = true
        var done = S.todo("t3", "Done to-do", start: "2026-11-03", due: "2026-11-05")
        done.done = true
        let items = [
            team, repeating, done,
            S.todo("t4", "No start", start: nil, due: "2026-11-05"),
            S.todo("t5", "No due", start: "2026-11-03", due: nil),
            S.event("Meeting", start: "2026-11-03T10:00:00Z", end: "2026-11-03T11:00:00Z"),
            S.task(2, "Too early", start: "2026-09-01", end: "2026-09-10"),
            S.task(3, "Too late", start: "2027-02-01", end: "2027-02-10"),
            S.task(4, "Undated", start: nil, end: nil),
            S.task(5, "Kept", start: "2026-11-03", end: "2026-11-04")
        ]
        let layout = S.build(items)
        #expect(S.titles(layout) == ["# Website", "Kept"])
        #expect(!NCAgendaTimelineLayout.isDrawn(team))
        #expect(!NCAgendaTimelineLayout.isDrawn(items[3]))
        #expect(!NCAgendaTimelineLayout.isDrawn(items[4]))
    }

    @Test("No items: no rows, and the screen says there is no dated work")
    func empty() {
        let layout = S.build([])
        #expect(!layout.hasItems)
        #expect(layout.rows.isEmpty)
        #expect(layout.contentHeight == 0)
        #expect(NCAgendaTimelineText.t("_nodrive_agenda_timeline_empty_") == "No dated work in this range.")
    }

    @Test("A bar starts at its first day and is as wide as its days at both zooms, filled by the % done; a diamond is in the middle of its day")
    func shapes() throws {
        let items = [
            S.task(1, "Write copy", start: "2026-11-03T09:00:00Z", end: "2026-11-06T17:00:00Z", percent: 40),
            S.milestone(1, "Launch", day: "2026-11-07"),
            S.todo("t1", "Prepare notes", start: "2026-11-03", due: "2026-11-05", list: "Personal"),
            S.card(7, "Call supplier", due: "2026-11-06")
        ]
        for zoom in [TimelineZoom.weeks, .days] {
            let layout = S.build(items, zoom: zoom)
            let scale = layout.scale
            let bar = try #require(layout.shapes["gantt:1"])
            #expect(bar.kind == .bar)
            #expect(bar.x == scale.x(forDay: S.number("2026-11-03")))
            #expect(bar.width == 4 * scale.pointsPerDay)
            #expect(bar.fill == 0.4)
            #expect(!bar.noDates)
            let diamond = try #require(layout.shapes["milestone:1"])
            #expect(diamond.isDiamond)
            #expect(diamond.x == scale.x(forDayCenter: S.number("2026-11-07")))
            #expect(diamond.width == 0)
            let todo = try #require(layout.shapes["t1"])
            #expect(todo.kind == .todoBar)
            #expect(todo.width == 3 * scale.pointsPerDay)
            #expect(todo.fill == 0)
            let card = try #require(layout.shapes["board:1:7"])
            #expect(card.isDiamond && card.x == scale.x(forDayCenter: S.number("2026-11-06")))
            // The line of a bar is the middle of its row
            let row = try #require(layout.rows.first { $0.id == "item:gantt:1" })
            #expect(bar.centerY == row.y + 22)
            #expect(layout.rows[bar.rowIndex].id == row.id)
        }
    }

    @Test("A bar that starts before the range is cut at the first day, and keeps its real first day")
    func cutAtTheRange() throws {
        let layout = S.build([S.task(1, "Long", start: "2026-10-01", end: "2026-11-03")])
        let bar = try #require(layout.shapes["gantt:1"])
        let first = layout.scale.range.firstDay
        #expect(bar.x == layout.scale.x(forDay: first))
        #expect(bar.width == CGFloat(S.number("2026-11-03") - first + 1) * 12)
        #expect(bar.firstDay == S.number("2026-10-01"))
    }

    @Test("A Gantt task with only an end date is a one-day bar that can't be moved")
    func endOnly() throws {
        let layout = S.build([S.task(1, "Deadline", start: nil, end: "2026-11-05")])
        let bar = try #require(layout.shapes["gantt:1"])
        #expect(bar.noDates)
        #expect(bar.width == 12)
        #expect(bar.x == layout.scale.x(forDay: S.number("2026-11-05")))
        #expect(NCAgendaTimelineText.t("_nodrive_agenda_timeline_no_dates_") == "This task has no dates to move.")
    }

    @Test("A task of NoGantt keeps its day in NoGantt's own zone, a to-do and a card in the phone's")
    func zones() throws {
        // 23:00 UTC on the 4th is the 5th in Berlin
        let late = S.date("2026-11-04T23:00:00Z")
        var task = S.task(1, "Late hour", start: nil, end: nil)
        task.start = late
        task.end = late
        let berlin = TimeZone(identifier: "Europe/Berlin")!
        let layout = NCAgendaTimelineLayout.build(items: [task], scale: S.scale(), calendar: S.calendar, ganttZone: berlin)
        let bar = try #require(layout.shapes["gantt:1"])
        #expect(bar.firstDay == S.number("2026-11-05"))
        let same = NCAgendaTimelineLayout.build(items: [task], scale: S.scale(), calendar: S.calendar, ganttZone: S.zone)
        #expect(same.shapes["gantt:1"]?.firstDay == S.number("2026-11-04"))
    }
}

// MARK: - Arrows and stubs

@Suite("NoDrive NoAgenda Timeline: dependency arrows and stubs")
struct NoDriveAgendaTimelineArrowTests {
    typealias S = AgendaTimelineSupport

    private func pair(type: String, lag: Int = 0, successor: (String, String) = ("2026-11-09", "2026-11-11")) -> TimelineLayout {
        S.build([
            S.task(1, "Pred", start: "2026-11-02", end: "2026-11-04"),
            S.task(2, "Succ", start: successor.0, end: successor.1, deps: [S.dependency("t-1", "Pred", type: type, lag: lag)])
        ])
    }

    @Test("Finish to start: from the end of the predecessor to the start of the successor, with two corners when there is room")
    func finishToStart() throws {
        let layout = pair(type: "FS")
        let arrow = try #require(layout.arrows.first)
        let pred = try #require(layout.shapes["gantt:1"])
        let succ = try #require(layout.shapes["gantt:2"])
        #expect(layout.arrows.count == 1 && arrow.fromKey == "gantt:1" && arrow.toKey == "gantt:2" && arrow.kind == .finishToStart)
        #expect(arrow.points.count == 4)
        #expect(arrow.points.first == pred.endPoint)
        #expect(arrow.points.last == succ.startPoint)
        #expect(arrow.points[1] == CGPoint(x: pred.endPoint.x + 8, y: pred.centerY))
        #expect(arrow.points[2] == CGPoint(x: pred.endPoint.x + 8, y: succ.centerY))
        #expect(layout.stubs.isEmpty)
    }

    @Test("Finish to start on the next day (12 points at the Weeks zoom): the line turns half way, still with two corners")
    func nextDay() throws {
        let layout = pair(type: "FS", successor: ("2026-11-05", "2026-11-06"))
        let arrow = try #require(layout.arrows.first)
        let pred = try #require(layout.shapes["gantt:1"])
        let succ = try #require(layout.shapes["gantt:2"])
        #expect(succ.startPoint.x - pred.endPoint.x == 12)
        #expect(arrow.points.count == 4)
        #expect(arrow.points[1] == CGPoint(x: pred.endPoint.x + 6, y: pred.centerY))
        #expect(arrow.points.last == succ.startPoint)
        // Starting before the predecessor ends (no room for a corner): round through the gap between the rows
        let touching = S.build([
            S.task(1, "Pred", start: "2026-11-02", end: "2026-11-04"),
            S.task(2, "Succ", start: "2026-11-04", end: "2026-11-06", deps: [S.dependency("t-1", "Pred")])
        ])
        #expect(touching.arrows.first?.points.count == 6)
    }

    @Test("Finish to start with a lag keeps its end points and its lag; with a negative lag the bars overlap and the line goes round through the gap between the rows")
    func lags() throws {
        let later = pair(type: "FS", lag: 2, successor: ("2026-11-08", "2026-11-10"))
        let arrow = try #require(later.arrows.first)
        #expect(arrow.lagDays == 2)
        #expect(arrow.points.count == 4)
        #expect(arrow.points.first == later.shapes["gantt:1"]?.endPoint)
        #expect(arrow.points.last == later.shapes["gantt:2"]?.startPoint)
        let overlap = pair(type: "FS", lag: -2, successor: ("2026-11-03", "2026-11-06"))
        let back = try #require(overlap.arrows.first)
        let pred = try #require(overlap.shapes["gantt:1"])
        let succ = try #require(overlap.shapes["gantt:2"])
        #expect(back.lagDays == -2)
        #expect(back.points.count == 6)
        #expect(back.points.first == pred.endPoint && back.points.last == succ.startPoint)
        // The way back runs on the edge between the two rows
        #expect(back.points[2].y == pred.centerY + 22 && back.points[3].y == pred.centerY + 22)
        #expect(back.points[4] == CGPoint(x: succ.startPoint.x - 8, y: succ.centerY))
    }

    @Test("Start to start, finish to finish and start to finish join the right ends")
    func otherTypes() throws {
        let ss = try #require(pair(type: "SS").arrows.first)
        let layoutSS = pair(type: "SS")
        #expect(ss.kind == .startToStart)
        #expect(ss.points.first == layoutSS.shapes["gantt:1"]?.startPoint)
        #expect(ss.points.last == layoutSS.shapes["gantt:2"]?.startPoint)
        #expect(ss.points.count == 4)
        #expect(ss.points[1].x == min(layoutSS.shapes["gantt:1"]!.startPoint.x, layoutSS.shapes["gantt:2"]!.startPoint.x) - 8)
        let layoutFF = pair(type: "EE")
        let ff = try #require(layoutFF.arrows.first)
        #expect(ff.kind == .finishToFinish)
        #expect(ff.points.first == layoutFF.shapes["gantt:1"]?.endPoint)
        #expect(ff.points.last == layoutFF.shapes["gantt:2"]?.endPoint)
        #expect(ff.points[1].x == max(layoutFF.shapes["gantt:1"]!.endPoint.x, layoutFF.shapes["gantt:2"]!.endPoint.x) + 8)
        let layoutSF = pair(type: "AE")
        let sf = try #require(layoutSF.arrows.first)
        #expect(sf.kind == .startToFinish)
        #expect(sf.points.first == layoutSF.shapes["gantt:1"]?.startPoint)
        #expect(sf.points.last == layoutSF.shapes["gantt:2"]?.endPoint)
        #expect(sf.points.count == 6)
    }

    @Test("A predecessor that is not on the screen is a stub with its title and person; no arrow is drawn")
    func stubs() throws {
        let off = S.task(2, "Publish", start: "2026-11-05", end: "2026-11-06", deps: [
            S.dependency("t-99", "Banner design", person: "Sara"),
            S.dependency("t-98", "Old task", person: nil)
        ])
        let layout = S.build([off])
        #expect(layout.arrows.isEmpty)
        #expect(layout.stubs["gantt:2"] == ["After: Banner design (Sara)", "After: Old task"])
        // A predecessor that is a drawn row but outside the range is a stub too
        let early = S.task(1, "Early", start: "2026-08-01", end: "2026-08-05")
        let later = S.task(2, "Later", start: "2026-11-05", end: "2026-11-06", deps: [S.dependency("t-1", "Early", person: "Ali")])
        let outside = S.build([early, later])
        #expect(outside.arrows.isEmpty)
        #expect(outside.stubs["gantt:2"] == ["After: Early (Ali)"])
        // A predecessor the filter hides (not in the items) is a stub as well
        #expect(S.build([later]).stubs["gantt:2"] == ["After: Early (Ali)"])
    }

    @Test("A milestone can be a predecessor (\"m-5\"), and a diamond is joined at its sides")
    func milestonePredecessor() throws {
        let layout = S.build([
            S.milestone(5, "Kickoff", day: "2026-11-03"),
            S.task(2, "Start work", start: "2026-11-06", end: "2026-11-09", deps: [S.dependency("m-5", "Kickoff")])
        ])
        let arrow = try #require(layout.arrows.first)
        let diamond = try #require(layout.shapes["milestone:5"])
        #expect(arrow.fromKey == "milestone:5")
        #expect(arrow.points.first == CGPoint(x: diamond.x + 9, y: diamond.centerY))
        #expect(NCAgendaTimelineLayout.itemKey(ofPredecessor: "t-12") == "gantt:12")
        #expect(NCAgendaTimelineLayout.itemKey(ofPredecessor: "m-3") == "milestone:3")
        #expect(NCAgendaTimelineLayout.itemKey(ofPredecessor: "x-3") == nil)
        #expect(NCAgendaTimelineLayout.itemKey(ofPredecessor: "t-abc") == nil)
    }

    @Test("The words of the arrows for a screen reader")
    func spokenArrows() {
        let layout = pair(type: "FS")
        #expect(NCAgendaTimelineLayout.spokenArrows(layout) == "Succ comes after Pred")
        #expect(NCAgendaTimelineLayout.spokenArrows(S.build([])).isEmpty)
    }

    @Test("The arrow head is a triangle on the last point, pointing the way the line goes")
    func arrowHead() {
        let head = NCAgendaTimelineArrowsView.head(of: [CGPoint(x: 0, y: 0), CGPoint(x: 20, y: 0)])
        #expect(head.boundingRect.maxX == 20)
        #expect(head.boundingRect.minX == 14)
        #expect(NCAgendaTimelineArrowsView.head(of: [CGPoint(x: 1, y: 1)]).isEmpty)
    }
}

// MARK: - Shading

@Suite("NoDrive NoAgenda Timeline: busy time and days off")
struct NoDriveAgendaTimelineShadingTests {
    typealias S = AgendaTimelineSupport

    private func shades(_ events: [AgendaItem], pattern: AgendaWorkPattern = AgendaWorkPattern()) -> [Int: TimelineDayShade] {
        let list = NCAgendaTimelineLayout.shading(range: S.scale().range, events: events, pattern: pattern, calendar: S.calendar)
        return Dictionary(uniqueKeysWithValues: list.map { ($0.day, $0) })
    }

    @Test("A day is tinted by the share of the working hours (09:00 to 17:00) my own busy events take; overlapping events count once")
    func shares() throws {
        let day = S.number("2026-11-02")
        let result = shades([
            S.event("Call", start: "2026-11-02T10:00:00Z", end: "2026-11-02T12:00:00Z"),
            S.event("Overlap", start: "2026-11-02T11:00:00Z", end: "2026-11-02T13:00:00Z"),
            S.event("Evening", start: "2026-11-03T18:00:00Z", end: "2026-11-03T20:00:00Z")
        ])
        let monday = try #require(result[day])
        #expect(monday.share == 3.0 / 8.0)
        #expect(!monday.hatched)
        // Outside the working hours nothing counts
        #expect(result[day + 1]?.share == 0)
        // The strongest tint is a share of the accent colour, 0.35 at most
        #expect(NCAgendaTimelineLayout.maxTint == 0.35)
        let full = shades([S.event("All hours", start: "2026-11-02T08:00:00Z", end: "2026-11-02T18:00:00Z")])
        #expect(full[day]?.share == 1)
    }

    @Test("An agent's event, a free event and an event of a calendar kept for information never shade")
    func notBusy() {
        let day = S.number("2026-11-02")
        let agent = AgentRef.mine(id: "AG-0001", name: "Writer-Bot", status: .active)
        var info = S.event("Holiday feed", start: "2026-11-02T09:00:00Z", end: "2026-11-02T17:00:00Z")
        info.scope = .info
        var team = S.event("Their call", start: "2026-11-02T09:00:00Z", end: "2026-11-02T17:00:00Z")
        team.relation = .team
        let result = shades([
            S.event("Bot work", start: "2026-11-02T09:00:00Z", end: "2026-11-02T17:00:00Z", agent: agent),
            S.event("Lunch hold", start: "2026-11-02T09:00:00Z", end: "2026-11-02T17:00:00Z", free: true),
            info, team
        ])
        #expect(result[day]?.share == 0)
        #expect(result[day]?.hatched == false)
    }

    @Test("Days off are hatched: the weekend, a holiday and a day with an all-day busy event of mine; a free all-day event is not")
    func daysOff() {
        var pattern = AgendaWorkPattern()
        pattern.holidays = ["2026-11-03"]
        let result = shades([
            S.event("Day off", start: "2026-11-04", end: "2026-11-05", allDay: true),
            S.event("Birthday", start: "2026-11-05", end: "2026-11-06", allDay: true, free: true)
        ], pattern: pattern)
        #expect(result[S.number("2026-11-02")]?.hatched == false)
        #expect(result[S.number("2026-11-03")]?.hatched == true)
        #expect(result[S.number("2026-11-04")]?.hatched == true)
        #expect(result[S.number("2026-11-05")]?.hatched == false)
        #expect(result[S.number("2026-11-07")]?.hatched == true)
        #expect(result[S.number("2026-11-08")]?.hatched == true)
        #expect(result[S.number("2026-11-09")]?.hatched == false)
        // An all-day event of mine takes no share of the hours (the day is hatched instead)
        #expect(result[S.number("2026-11-04")]?.share == 0)
        #expect(result.count == 64)
    }
}

// MARK: - Move by, locks and the words

@Suite("NoDrive NoAgenda Timeline: Move by")
struct NoDriveAgendaTimelineMoveTests {
    typealias S = AgendaTimelineSupport

    private func commands(_ item: AgendaItem, _ edit: (inout NCAgendaEditDraft) -> Void, zone: TimeZone = S.zone, calendar: Calendar = S.calendar) -> [NCAgendaEditCommand] {
        var draft = NCAgendaEditDraft(item: item, calendar: calendar)
        edit(&draft)
        return draft.commands(for: item, calendar: calendar, ganttZone: zone, now: S.date("2026-11-02T12:00:00Z"))
    }

    @Test("Move by +1 day on a Gantt task is the same command as setting both dates by hand: one ganttUpdate with the two days")
    func ganttSameAsTheSheet() throws {
        let item = S.task(1, "Write copy", start: "2026-11-03T09:00:00Z", end: "2026-11-06T17:00:00Z")
        let moved = commands(item) { $0.moveBy(days: 1, calendar: S.calendar, zone: S.zone) }
        let byHand = commands(item) { draft in
            draft.start = S.date("2026-11-04T09:00:00Z")
            draft.end = S.date("2026-11-07T17:00:00Z")
        }
        let command = try #require(moved.first)
        #expect(moved.count == 1 && command.kind == .ganttUpdate)
        #expect(command.gantt == GanttChange(startDay: "2026-11-04", endDay: "2026-11-07"))
        #expect(command.gantt == byHand.first?.gantt)
        #expect(command.itemKey == "gantt:1" && command.link == item.link)
        for (days, start, end) in [(-7, "2026-10-27", "2026-10-30"), (-1, "2026-11-02", "2026-11-05"), (7, "2026-11-10", "2026-11-13")] {
            let list = commands(item) { $0.moveBy(days: days, calendar: S.calendar, zone: S.zone) }
            #expect(list.first?.gantt == GanttChange(startDay: start, endDay: end))
        }
        // +1 and then -1 is no change at all
        #expect(commands(item) { $0.moveBy(days: 1, calendar: S.calendar, zone: S.zone); $0.moveBy(days: -1, calendar: S.calendar, zone: S.zone) }.isEmpty)
    }

    @Test("The request of a move asks NoGantt to move the tasks that follow (adjust_lag) and never moves a linked card without a yes")
    func requestBody() throws {
        let fresh = GanttTask(id: 1, projectId: 1, title: "Write copy", start: "2026-11-03 09:00:00", end: "2026-11-06 17:00:00", work: nil,
                              updatedAt: "2026-11-01 10:00:00", progressMode: "manual", progress: 10, status: "in_progress", dependencies: [], resources: [], deckCardId: nil)
        let body = NCAgendaGanttWriter.body(for: GanttChange(startDay: "2026-11-04", endDay: "2026-11-07"), fresh: fresh)
        #expect(body["start_date"] as? String == "2026-11-04 09:00:00")
        #expect(body["end_date"] as? String == "2026-11-07 17:00:00")
        #expect(body["adjust_lag"] as? Bool == true)
        #expect(body["deck_confirmed"] as? Bool == false)
    }

    @Test("Across the end of summer time the day count stays right in the zone of NoGantt")
    func summerTime() throws {
        let berlin = TimeZone(identifier: "Europe/Berlin")!
        var local = Calendar(identifier: .gregorian)
        local.timeZone = berlin
        let start = try #require(local.date(from: DateComponents(year: 2026, month: 10, day: 24, hour: 9)))
        let end = try #require(local.date(from: DateComponents(year: 2026, month: 10, day: 26, hour: 17)))
        var item = S.task(1, "Across", start: nil, end: nil)
        item.start = start
        item.end = end
        let list = commands(item, { $0.moveBy(days: 7, calendar: local, zone: berlin) }, zone: berlin, calendar: local)
        #expect(list.first?.gantt == GanttChange(startDay: "2026-10-31", endDay: "2026-11-02"))
    }

    @Test("A to-do moves its start and its due date and keeps their times; the command is a calendar change")
    func todo() throws {
        var item = S.todo("t1", "Prepare notes", start: "2026-11-03T09:00:00Z", due: "2026-11-05T17:00:00Z")
        item.home = .tasks
        let list = commands(item) { $0.moveBy(days: 2, calendar: S.calendar, zone: S.zone) }
        let command = try #require(list.first)
        #expect(list.count == 1 && command.kind == .calendarPatch)
        #expect(command.calendar?.start == S.date("2026-11-05T09:00:00Z"))
        #expect(command.calendar?.due == S.date("2026-11-07T17:00:00Z"))
        #expect(command.calendar?.title == nil && command.calendar?.done == nil)
    }

    @Test("Only a task with a start and an end, and a to-do with a start and a due date, can be moved; a milestone, a card and an event are left as they are")
    func whatCanMove() {
        #expect(NCAgendaEditDraft.canMoveDates(S.task(1, "A", start: "2026-11-03", end: "2026-11-04")))
        #expect(!NCAgendaEditDraft.canMoveDates(S.task(2, "B", start: nil, end: "2026-11-04")))
        #expect(NCAgendaEditDraft.canMoveDates(S.todo("t", "T", start: "2026-11-03", due: "2026-11-04")))
        #expect(!NCAgendaEditDraft.canMoveDates(S.todo("t", "T", start: nil, due: "2026-11-04")))
        #expect(!NCAgendaEditDraft.canMoveDates(S.milestone(1, "M", day: "2026-11-03")))
        #expect(!NCAgendaEditDraft.canMoveDates(S.card(1, "C", due: "2026-11-03")))
        for item in [S.milestone(1, "M", day: "2026-11-03"), S.card(1, "C", due: "2026-11-03"), S.event("E", start: "2026-11-03T10:00:00Z", end: "2026-11-03T11:00:00Z")] {
            #expect(commands(item) { $0.moveBy(days: 1, calendar: S.calendar, zone: S.zone) }.isEmpty)
        }
        #expect(NCAgendaEditDraft.moveSteps == [-7, -1, 1, 7])
    }

    @MainActor
    @Test("A locked bar builds no command: the sheet has no Edit button for it, so there is no date editor and no Move by")
    func lockedBar() async {
        let root = AgendaRuntimeSupport.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = NCAgendaViewModel(account: AgendaRuntimeSupport.account, store: AgendaRuntimeSupport.store(AgendaFixtures.server(), root: root),
                                      now: { AgendaRuntimeSupport.now })
        var viewer = S.task(1, "Internal sync", start: "2026-11-03", end: "2026-11-04")
        viewer.lock = .viewerProject
        #expect(model.ability(of: viewer) == .locked("You can only view this project in NoGantt."))
        var waiting = S.task(2, "Waiting", start: "2026-11-03", end: "2026-11-04")
        waiting.pending = true
        if case .locked = model.ability(of: waiting) {} else { Issue.record("a task with a change waiting is not locked") }
        let open = S.task(3, "Open", start: "2026-11-03", end: "2026-11-04")
        #expect(model.ability(of: open) == .editable)
        // The Timeline shows no team rows and no milestone is editable
        #expect(model.ability(of: S.milestone(1, "M", day: "2026-11-03")) == .notOffered)
    }

    @Test("The spoken form of the four buttons")
    func spokenSteps() {
        #expect(NCAgendaMoveByView.spoken(-7) == "Earlier by 7 days")
        #expect(NCAgendaMoveByView.spoken(-1) == "Earlier by 1 day")
        #expect(NCAgendaMoveByView.spoken(1) == "Later by 1 day")
        #expect(NCAgendaMoveByView.spoken(7) == "Later by 7 days")
    }
}

@Suite("NoDrive NoAgenda Timeline: words and marks")
struct NoDriveAgendaTimelineWordsTests {
    typealias S = AgendaTimelineSupport

    @Test("A bar is read as kind, title, dates, % done and agent; marks follow")
    func spoken() throws {
        var item = S.task(1, "Write homepage copy", start: "2026-11-03", end: "2026-11-06", percent: 40,
                          agent: .mine(id: "AG-0001", name: "Writer-Bot", status: .active))
        item.late = true
        let layout = S.build([item])
        let shape = try #require(layout.shapes["gantt:1"])
        let first = NCAgendaFormat.shortDay(NCAgendaTimelineDays.date(S.number("2026-11-03"), calendar: S.calendar))
        let last = NCAgendaFormat.shortDay(NCAgendaTimelineDays.date(S.number("2026-11-06"), calendar: S.calendar))
        #expect(NCAgendaTimelineLayout.spoken(item, shape: shape, calendar: S.calendar, locked: false, notSent: false)
                == "Gantt task, Write homepage copy, \(first) to \(last), 40 % done, Writer-Bot, Late")
        let locked = NCAgendaTimelineLayout.spoken(item, shape: shape, calendar: S.calendar, locked: true, notSent: true)
        #expect(locked.hasSuffix(", " + NCAgendaText.t("_nodrive_agenda_spoken_locked_") + ", " + NCAgendaTimelineText.t("_nodrive_agenda_timeline_spoken_not_sent_")))
        // A diamond has one day and no %
        let diamond = S.milestone(1, "Launch", day: "2026-11-07")
        let shapeD = try #require(S.build([diamond]).shapes["milestone:1"])
        let day = NCAgendaFormat.shortDay(NCAgendaTimelineDays.date(S.number("2026-11-07"), calendar: S.calendar))
        #expect(NCAgendaTimelineLayout.spoken(diamond, shape: shapeD, calendar: S.calendar, locked: false, notSent: false) == "Milestone, Launch, \(day), Self")
    }

    @Test("The agent without its emoji: Self, a name, a retired agent, an unknown one")
    func agentNames() {
        #expect(NCAgendaTimelineLayout.agentName(.selfAgent) == "Self")
        #expect(NCAgendaTimelineLayout.agentName(.mine(id: "AG-0001", name: "Writer-Bot", status: .active)) == "Writer-Bot")
        #expect(NCAgendaTimelineLayout.agentName(.other(label: "Agent of Sara")) == "Agent of Sara")
    }

    @Test("The texts are in the table, in English, without the old name of the server software; the symbols exist")
    func textsAndSymbols() {
        let keys = [
            "_nodrive_agenda_timeline_", "_nodrive_agenda_timeline_weeks_", "_nodrive_agenda_timeline_days_", "_nodrive_agenda_timeline_zoom_",
            "_nodrive_agenda_timeline_after_", "_nodrive_agenda_timeline_after_nobody_", "_nodrive_agenda_timeline_empty_",
            "_nodrive_agenda_timeline_no_dates_", "_nodrive_agenda_timeline_move_by_", "_nodrive_agenda_timeline_earlier_",
            "_nodrive_agenda_timeline_earlier_one_", "_nodrive_agenda_timeline_later_", "_nodrive_agenda_timeline_later_one_",
            "_nodrive_agenda_timeline_group_tasks_", "_nodrive_agenda_timeline_group_board_", "_nodrive_agenda_timeline_kind_task_",
            "_nodrive_agenda_timeline_spoken_range_", "_nodrive_agenda_timeline_spoken_percent_", "_nodrive_agenda_timeline_spoken_after_",
            "_nodrive_agenda_timeline_spoken_not_sent_", "_nodrive_agenda_timeline_spoken_stub_", "_nodrive_agenda_timeline_scale_",
            "_nodrive_agenda_timeline_range_", "_nodrive_agenda_timeline_legend_", "_nodrive_agenda_timeline_legend_info_",
            "_nodrive_agenda_timeline_legend_bar_", "_nodrive_agenda_timeline_legend_todo_", "_nodrive_agenda_timeline_legend_diamond_",
            "_nodrive_agenda_timeline_legend_arrow_", "_nodrive_agenda_timeline_legend_stub_", "_nodrive_agenda_timeline_legend_shade_",
            "_nodrive_agenda_timeline_legend_hatch_", "_nodrive_agenda_timeline_legend_today_", "_nodrive_agenda_timeline_legend_agent_",
            "_nodrive_agenda_timeline_legend_marks_", "_nodrive_agenda_timeline_legend_phone_"
        ]
        for key in keys {
            let text = NCAgendaTimelineText.t(key)
            #expect(text != key, "\(key) has no text")
            #expect(!text.localizedCaseInsensitiveContains("nextcloud"), "\(key) names the old product")
        }
        #expect(NCAgendaTimelineText.t("_nodrive_agenda_timeline_") == "Timeline")
        #expect(TimelineZoom.weeks.title == "Weeks" && TimelineZoom.days.title == "Days")
        #expect(AgendaViewKind.timeline.title == "Timeline")
        #expect(AgendaViewKind.allCases.map(\.rawValue) == ["day", "week", "month", "timeline"])
        for symbol in ["diamond", "diamond.fill", "alarm", "nosign", "lock.fill", "clock", "exclamationmark.triangle.fill", "arrowtriangle.right.fill",
                       "info.circle", "chart.bar.xaxis", "checklist", "arrow.right", "square.fill", "slash.circle", "minus", "person.crop.circle",
                       "exclamationmark.triangle", "hand.tap"] {
            #expect(UIImage(systemName: symbol) != nil, "the symbol \(symbol) does not exist")
        }
    }
}

// MARK: - The person on the predecessor, and the view model

@Suite("NoDrive NoAgenda Timeline: data and screen state")
struct NoDriveAgendaTimelineDataTests {
    typealias S = AgendaRulesSupport

    @Test("A dependency knows the person on its predecessor task (nobody when only an unlinked person or a role is on it)")
    func predecessorPerson() throws {
        var gantt = S.gantt
        // "Temp work" (16) has an unlinked planning person only
        gantt.tasks["1"] = [
            S.task(14, "Banner design", start: "2026-10-26 09:00:00", end: "2026-10-28 17:00:00", resources: [2, 5]),
            S.task(15, "Publish banners", resources: [2], deps: ["t-14", "t-16", "t-99"]),
            S.task(16, "Temp work", resources: [6])
        ]
        let snapshot = S.assemble(me: S.mara, gantt: gantt)
        let publish = try #require(snapshot.items.first { $0.title == "Publish banners" })
        #expect(publish.dependencies.count == 3)
        #expect(publish.dependencies[0].predecessorKey == "t-14" && publish.dependencies[0].predecessorPerson == "Sara")
        #expect(publish.dependencies[1].predecessorTitle == "Temp work" && publish.dependencies[1].predecessorPerson == nil)
        #expect(publish.dependencies[2].predecessorTitle == "t-99" && publish.dependencies[2].predecessorPerson == nil)
        #expect(NCAgendaTimelineLayout.stubText(publish.dependencies[0]) == "After: Banner design (Sara)")
        #expect(NCAgendaTimelineLayout.stubText(publish.dependencies[1]) == "After: Temp work")
    }

    @Test("A cached row from before this step has no person on its dependency, and still reads")
    func oldCache() throws {
        let json = #"{"predecessorKey":"t-1","predecessorTitle":"Old","type":"FS","lagDays":0}"#
        let value = try JSONDecoder().decode(AgendaDependency.self, from: Data(json.utf8))
        #expect(value.predecessorPerson == nil && value.predecessorTitle == "Old")
        let again = try JSONDecoder().decode(AgendaDependency.self, from: JSONEncoder().encode(AgendaDependency(predecessorKey: "t-2", predecessorTitle: "New", type: "SS", lagDays: 1, predecessorPerson: "Sara")))
        #expect(again.predecessorPerson == "Sara")
    }

    @MainActor
    @Test("The Timeline moves four weeks with the arrows, Today counts up for the scroll, and the view is kept like the others")
    func viewModel() async {
        let root = AgendaRuntimeSupport.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = NCAgendaViewModel(account: AgendaRuntimeSupport.account, store: AgendaRuntimeSupport.store(AgendaFixtures.server(), root: root),
                                      now: { AgendaRuntimeSupport.now })
        model.calendar = AgendaRuntimeSupport.calendar
        model.setView(.timeline)
        #expect(model.view == .timeline)
        let start = model.day
        model.step(1)
        #expect(model.calendar.dateComponents([.day], from: start, to: model.day).day == 28)
        model.step(-1)
        model.step(-1)
        #expect(model.calendar.dateComponents([.day], from: model.day, to: start).day == 28)
        let tick = model.timelineTodayTick
        model.goToToday()
        #expect(model.timelineTodayTick == tick + 1)
        #expect(model.day == model.calendar.startOfDay(for: model.today))
        let expected = NCAgendaTimelineHeader.title(shown: model.day, calendar: model.calendar)
        #expect(model.headerTitle == expected)
        // The other views still step by a day, a week and a month
        model.setView(.week)
        let before = model.day
        model.step(1)
        #expect(model.calendar.dateComponents([.day], from: before, to: model.day).day == 7)
    }
}
