// SPDX-FileCopyrightText: 2026 Nourax
// SPDX-License-Identifier: GPL-3.0-or-later

import CoreGraphics
import Foundation

/// The texts of the Timeline (English; the table is `NoAgendaTimeline`).
enum NCAgendaTimelineText {
    static func t(_ key: String) -> String {
        NSLocalizedString(key, tableName: "NoAgendaTimeline", comment: "")
    }

    static func f(_ key: String, _ args: CVarArg...) -> String {
        String(format: t(key), arguments: args)
    }
}

/// Whole calendar days as numbers (days since 1970-01-01 of the calendar day in a time zone), so that the maths of the
/// Timeline never depends on the zone it runs in.
enum NCAgendaTimelineDays {
    static func number(_ date: Date, calendar: Calendar) -> Int {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return civil(year: parts.year ?? 1970, month: parts.month ?? 1, day: parts.day ?? 1)
    }

    /// Days since 1970-01-01 of a civil date (proleptic Gregorian).
    static func civil(year: Int, month: Int, day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = (month + 9) % 12
        let doy = (153 * mp + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    /// The civil date of a day number.
    static func parts(of number: Int) -> (year: Int, month: Int, day: Int) {
        let z = number + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let day = doy - (153 * mp + 2) / 5 + 1
        let month = mp < 10 ? mp + 3 : mp - 9
        let year = yoe + era * 400 + (month <= 2 ? 1 : 0)
        return (year, month, day)
    }

    /// The start of the day with this number in the calendar's zone.
    static func date(_ number: Int, calendar: Calendar) -> Date {
        let value = parts(of: number)
        let components = DateComponents(year: value.year, month: value.month, day: value.day)
        return calendar.date(from: components) ?? Date(timeIntervalSince1970: TimeInterval(number) * 86_400)
    }
}

enum TimelineZoom: String, CaseIterable, Identifiable, Sendable {
    case weeks, days
    var id: String { rawValue }

    var pointsPerDay: CGFloat { self == .weeks ? 12 : 40 }

    var title: String {
        NCAgendaTimelineText.t(self == .weeks ? "_nodrive_agenda_timeline_weeks_" : "_nodrive_agenda_timeline_days_")
    }
}

/// The days the Timeline shows: seven days before the shown date to eight weeks after it.
struct TimelineRange: Equatable, Sendable {
    static let daysBefore = 7
    static let daysAfter = 56

    var firstDay: Int
    var dayCount: Int

    var lastDay: Int { firstDay + dayCount - 1 }

    static func around(_ shown: Date, calendar: Calendar) -> TimelineRange {
        TimelineRange(firstDay: NCAgendaTimelineDays.number(shown, calendar: calendar) - daysBefore, dayCount: daysBefore + daysAfter + 1)
    }

    func contains(day: Int) -> Bool { day >= firstDay && day <= lastDay }
}

/// Date and x: the name column takes the first `nameWidth` points, then one column of `pointsPerDay` for every day.
struct TimelineScale: Equatable, Sendable {
    var range: TimelineRange
    var zoom: TimelineZoom
    var nameWidth: CGFloat
    /// Room after the last day, for the agent text after a bar that ends there.
    var trailing: CGFloat = 160

    var pointsPerDay: CGFloat { zoom.pointsPerDay }
    var chartWidth: CGFloat { CGFloat(range.dayCount) * pointsPerDay }
    var totalWidth: CGFloat { nameWidth + chartWidth + trailing }

    /// The left edge of a day.
    func x(forDay day: Int) -> CGFloat {
        nameWidth + CGFloat(day - range.firstDay) * pointsPerDay
    }

    /// The middle of a day.
    func x(forDayCenter day: Int) -> CGFloat {
        x(forDay: day) + pointsPerDay / 2
    }

    /// The day under an x (the name column and what is left of the first day count as the first day).
    func day(atX x: CGFloat) -> Int {
        range.firstDay + Int(((x - nameWidth) / pointsPerDay).rounded(.down))
    }
}

/// How a dependency of NoGantt joins two bars: finish to start ("FS", NoGantt's German-derived "EA"), start to start
/// ("SS", "AA"), finish to finish ("FF", "EE"), start to finish ("SF", "AE").
enum TimelineDependencyKind: Equatable, Sendable {
    case finishToStart, startToStart, finishToFinish, startToFinish

    init(type: String) {
        switch type.uppercased() {
        case "SS", "AA": self = .startToStart
        case "FF", "EE": self = .finishToFinish
        case "SF", "AE": self = .startToFinish
        default: self = .finishToStart
        }
    }
}

struct TimelineShape: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// A Gantt task: the % done fills it.
        case bar
        /// A to-do with a start and a due date.
        case todoBar
        /// A milestone or a dated card.
        case diamond
    }

    var key: String
    var kind: Kind
    /// The first and the last day of the item (before the range cuts them).
    var firstDay: Int
    var lastDay: Int
    /// What is drawn: the left edge and width of a bar, the middle of a diamond (width 0).
    var x: CGFloat
    var width: CGFloat
    var rowIndex: Int
    var centerY: CGFloat
    /// 0 to 1, the part of the bar the % done fills.
    var fill: Double
    /// A Gantt task that has only an end date: a one-day bar that can't be moved.
    var noDates: Bool

    var isDiamond: Bool { kind == .diamond }
    var trailingX: CGFloat { isDiamond ? x + NCAgendaTimelineLayout.diamondSize / 2 : x + width }

    /// Where an arrow leaves or enters at the start and at the end of the item.
    var startPoint: CGPoint { CGPoint(x: isDiamond ? x - NCAgendaTimelineLayout.diamondSize / 2 : x, y: centerY) }
    var endPoint: CGPoint { CGPoint(x: trailingX, y: centerY) }
}

struct TimelineRow: Identifiable, Equatable, Sendable {
    enum Content: Equatable, Sendable {
        /// A project, a list or a board (level 0) or a phase (level 1).
        case group(title: String, level: Int)
        case item(AgendaItem)
    }

    var id: String
    var content: Content
    var y: CGFloat
    var height: CGFloat
}

struct TimelineArrow: Equatable, Sendable {
    var fromKey: String
    var toKey: String
    var kind: TimelineDependencyKind
    var lagDays: Int
    var points: [CGPoint]
}

struct TimelineLayout: Equatable, Sendable {
    var scale: TimelineScale
    var rows: [TimelineRow]
    var shapes: [String: TimelineShape]
    var arrows: [TimelineArrow]
    /// For an item whose predecessor is not on the screen: "After: Banner design (Sara)".
    var stubs: [String: [String]]
    var contentHeight: CGFloat
    var hasItems: Bool { !shapes.isEmpty }
}

/// One day of the shading behind the bars.
struct TimelineDayShade: Equatable, Sendable {
    var day: Int
    /// 0 to 1: the part of my working hours my own busy events take.
    var share: Double
    /// A day off: not a working day, a holiday, or an all-day busy event.
    var hatched: Bool
}

/// The maths of the Timeline (design 8): plain functions, unit-tested.
enum NCAgendaTimelineLayout {
    static let rowHeight: CGFloat = 44
    static let groupHeight: CGFloat = 30
    static let barHeight: CGFloat = 24
    static let todoBarHeight: CGFloat = 14
    static let diamondSize: CGFloat = 18
    /// The biggest share of the accent colour a busy day is tinted with.
    static let maxTint = 0.35

    // MARK: Which items, which days

    /// Is the item drawn on the Timeline? Mine only; a to-do needs a start and a due date and must not repeat; done
    /// to-dos and cards are left out.
    static func isDrawn(_ item: AgendaItem) -> Bool {
        guard item.relation == .mine, !item.done else { return false }
        switch item.kind {
        case .ganttTask: return item.start != nil || item.end != nil
        case .todo: return item.start != nil && item.due != nil && !item.repeating && item.lock != .repeating
        case .milestone: return item.start != nil || item.end != nil
        case .card: return item.due != nil
        case .event: return false
        }
    }

    /// The first and the last day of an item, its shape and whether it has no dates to move. Nil when it has none.
    static func span(of item: AgendaItem, calendar: Calendar, ganttZone: TimeZone) -> (first: Int, last: Int, kind: TimelineShape.Kind, noDates: Bool)? {
        var zoned = calendar
        zoned.timeZone = ganttZone
        switch item.kind {
        case .ganttTask:
            if let start = item.start, let end = item.end {
                let first = NCAgendaTimelineDays.number(start, calendar: zoned)
                let last = NCAgendaTimelineDays.number(end, calendar: zoned)
                return (min(first, last), max(first, last), .bar, false)
            }
            guard let only = item.end ?? item.start else { return nil }
            let day = NCAgendaTimelineDays.number(only, calendar: zoned)
            return (day, day, .bar, true)
        case .todo:
            guard let start = item.start, let due = item.due else { return nil }
            let first = NCAgendaTimelineDays.number(start, calendar: calendar)
            let last = NCAgendaTimelineDays.number(due, calendar: calendar)
            return (min(first, last), max(first, last), .todoBar, false)
        case .milestone:
            guard let date = item.start ?? item.end else { return nil }
            let day = NCAgendaTimelineDays.number(date, calendar: zoned)
            return (day, day, .diamond, false)
        case .card:
            guard let due = item.due else { return nil }
            let day = NCAgendaTimelineDays.number(due, calendar: calendar)
            return (day, day, .diamond, false)
        case .event:
            return nil
        }
    }

    // MARK: Groups and rows

    private struct Entry {
        var item: AgendaItem
        var first: Int
        var last: Int
        var kind: TimelineShape.Kind
        var noDates: Bool
    }

    private static func ordered(_ entries: [Entry]) -> [Entry] {
        entries.sorted { lhs, rhs in
            if lhs.first != rhs.first { return lhs.first < rhs.first }
            if lhs.last != rhs.last { return lhs.last < rhs.last }
            let titles = lhs.item.title.localizedCaseInsensitiveCompare(rhs.item.title)
            if titles != .orderedSame { return titles == .orderedAscending }
            return lhs.item.key < rhs.item.key
        }
    }

    /// Builds the rows, the shapes, the arrows and the stubs. `items` are the items to draw (the chips and the switch are
    /// applied by the caller); what is not drawn or lies outside the range is left out.
    static func build(items: [AgendaItem], scale: TimelineScale, calendar: Calendar, ganttZone: TimeZone) -> TimelineLayout {
        // The items that are in the range
        var gantt: [String: (title: String, entries: [Entry])] = [:]
        var lists: [String: (title: String, entries: [Entry])] = [:]
        var boards: [String: (title: String, entries: [Entry])] = [:]
        for item in items where isDrawn(item) {
            guard let found = span(of: item, calendar: calendar, ganttZone: ganttZone),
                  found.last >= scale.range.firstDay, found.first <= scale.range.lastDay else { continue }
            let entry = Entry(item: item, first: found.first, last: found.last, kind: found.kind, noDates: found.noDates)
            switch item.kind {
            case .ganttTask, .milestone:
                let title = item.projectName ?? item.sourceName
                gantt[item.sourceKey, default: (title, [])].entries.append(entry)
            case .todo:
                lists[item.sourceKey, default: (NCAgendaTimelineText.f("_nodrive_agenda_timeline_group_tasks_", item.sourceName), [])].entries.append(entry)
            case .card:
                boards[item.sourceKey, default: (NCAgendaTimelineText.f("_nodrive_agenda_timeline_group_board_", item.sourceName), [])].entries.append(entry)
            case .event:
                break
            }
        }

        var rows: [TimelineRow] = []
        var shapes: [String: TimelineShape] = [:]
        var y: CGFloat = 0

        func addGroup(_ id: String, _ title: String, level: Int) {
            rows.append(TimelineRow(id: id, content: .group(title: title, level: level), y: y, height: groupHeight))
            y += groupHeight
        }

        func addItem(_ entry: Entry) {
            let index = rows.count
            rows.append(TimelineRow(id: "item:" + entry.item.key, content: .item(entry.item), y: y, height: rowHeight))
            let first = max(entry.first, scale.range.firstDay)
            let last = min(entry.last, scale.range.lastDay)
            let shape: TimelineShape
            switch entry.kind {
            case .diamond:
                shape = TimelineShape(key: entry.item.key, kind: .diamond, firstDay: entry.first, lastDay: entry.last,
                                      x: scale.x(forDayCenter: first), width: 0, rowIndex: index, centerY: y + rowHeight / 2,
                                      fill: 0, noDates: false)
            case .bar, .todoBar:
                let width = CGFloat(last - first + 1) * scale.pointsPerDay
                let percent = Double(max(0, min(100, entry.item.percent ?? 0))) / 100
                shape = TimelineShape(key: entry.item.key, kind: entry.kind, firstDay: entry.first, lastDay: entry.last,
                                      x: scale.x(forDay: first), width: width, rowIndex: index, centerY: y + rowHeight / 2,
                                      fill: entry.kind == .bar ? percent : 0, noDates: entry.noDates)
            }
            shapes[entry.item.key] = shape
            y += rowHeight
        }

        // Projects first (by name), then the lists of to-dos, then the boards
        let projectKeys = gantt.keys.sorted { lhs, rhs in
            let order = gantt[lhs]!.title.localizedCaseInsensitiveCompare(gantt[rhs]!.title)
            return order == .orderedSame ? lhs < rhs : order == .orderedAscending
        }
        for key in projectKeys {
            guard let group = gantt[key] else { continue }
            addGroup("group:" + key, group.title, level: 0)
            // No phase first (by start), then the phases by their first start
            for entry in ordered(group.entries.filter { $0.item.phase == nil }) { addItem(entry) }
            let phases = Dictionary(grouping: group.entries.filter { $0.item.phase != nil }, by: { $0.item.phase ?? "" })
            let phaseNames = phases.keys.sorted { lhs, rhs in
                let left = phases[lhs]!.map { $0.first }.min() ?? 0
                let right = phases[rhs]!.map { $0.first }.min() ?? 0
                return left == right ? lhs < rhs : left < right
            }
            for name in phaseNames {
                addGroup("phase:" + key + ":" + name, name, level: 1)
                for entry in ordered(phases[name] ?? []) { addItem(entry) }
            }
        }
        for (prefix, groups) in [("list:", lists), ("board:", boards)] {
            let keys = groups.keys.sorted { lhs, rhs in
                let order = groups[lhs]!.title.localizedCaseInsensitiveCompare(groups[rhs]!.title)
                return order == .orderedSame ? lhs < rhs : order == .orderedAscending
            }
            for key in keys {
                guard let group = groups[key] else { continue }
                addGroup("group:" + prefix + key, group.title, level: 0)
                for entry in ordered(group.entries) { addItem(entry) }
            }
        }

        // Arrows and stubs
        var arrows: [TimelineArrow] = []
        var stubs: [String: [String]] = [:]
        for row in rows {
            guard case let .item(item) = row.content, let shape = shapes[item.key] else { continue }
            for dependency in item.dependencies {
                if let predecessorKey = itemKey(ofPredecessor: dependency.predecessorKey), let predecessor = shapes[predecessorKey] {
                    let kind = TimelineDependencyKind(type: dependency.type)
                    arrows.append(TimelineArrow(fromKey: predecessorKey, toKey: item.key, kind: kind, lagDays: dependency.lagDays,
                                                points: route(from: predecessor, to: shape, kind: kind)))
                } else {
                    stubs[item.key, default: []].append(stubText(dependency))
                }
            }
        }
        return TimelineLayout(scale: scale, rows: rows, shapes: shapes, arrows: arrows, stubs: stubs, contentHeight: y)
    }

    /// NoGantt names a predecessor "t-<task id>" or "m-<milestone id>"; the rows of NoAgenda are "gantt:<id>" and
    /// "milestone:<id>".
    static func itemKey(ofPredecessor id: String) -> String? {
        if id.hasPrefix("t-"), Int(id.dropFirst(2)) != nil { return "gantt:" + String(id.dropFirst(2)) }
        if id.hasPrefix("m-"), Int(id.dropFirst(2)) != nil { return "milestone:" + String(id.dropFirst(2)) }
        return nil
    }

    /// "After: Banner design (Sara)", or "After: Banner design" when nobody is on that task.
    static func stubText(_ dependency: AgendaDependency) -> String {
        if let person = dependency.predecessorPerson, !person.isEmpty {
            return NCAgendaTimelineText.f("_nodrive_agenda_timeline_after_", dependency.predecessorTitle, person)
        }
        return NCAgendaTimelineText.f("_nodrive_agenda_timeline_after_nobody_", dependency.predecessorTitle)
    }

    // MARK: Arrows

    /// The corners of an arrow from the predecessor to the successor. Each end is at the start or the end of the bar
    /// (a diamond has both at its sides); the line leaves and enters sideways, and goes round through the gap between
    /// two rows when the bars lie the wrong way round.
    static func route(from predecessor: TimelineShape, to successor: TimelineShape, kind: TimelineDependencyKind) -> [CGPoint] {
        let gap: CGFloat = 8
        let from: CGPoint
        let to: CGPoint
        switch kind {
        case .finishToStart: from = predecessor.endPoint; to = successor.startPoint
        case .startToStart: from = predecessor.startPoint; to = successor.startPoint
        case .finishToFinish: from = predecessor.endPoint; to = successor.endPoint
        case .startToFinish: from = predecessor.startPoint; to = successor.endPoint
        }
        // The edge between the rows, on the side of the successor
        let edgeY = from.y + (to.y >= from.y ? 1 : -1) * rowHeight / 2
        switch kind {
        case .finishToStart:
            if to.x >= from.x + gap {
                // Room for two corners: the line turns after at most `gap` points, in the middle of a small space
                let turn = from.x + min(gap, (to.x - from.x) / 2)
                return [from, CGPoint(x: turn, y: from.y), CGPoint(x: turn, y: to.y), to]
            }
            return [from, CGPoint(x: from.x + gap, y: from.y), CGPoint(x: from.x + gap, y: edgeY),
                    CGPoint(x: to.x - gap, y: edgeY), CGPoint(x: to.x - gap, y: to.y), to]
        case .startToStart:
            let left = min(from.x, to.x) - gap
            return [from, CGPoint(x: left, y: from.y), CGPoint(x: left, y: to.y), to]
        case .finishToFinish:
            let right = max(from.x, to.x) + gap
            return [from, CGPoint(x: right, y: from.y), CGPoint(x: right, y: to.y), to]
        case .startToFinish:
            return [from, CGPoint(x: from.x - gap, y: from.y), CGPoint(x: from.x - gap, y: edgeY),
                    CGPoint(x: to.x + gap, y: edgeY), CGPoint(x: to.x + gap, y: to.y), to]
        }
    }

    // MARK: Shading

    /// The tint and the hatching of every day of the range. Only my own busy events count: an event of an agent, a free
    /// event (transparent), an event of a calendar kept for information and every event of another person never shade.
    static func shading(range: TimelineRange, events: [AgendaItem], pattern: AgendaWorkPattern, calendar: Calendar) -> [TimelineDayShade] {
        let busy = events.filter { NCAgendaWorkload.isBusyEvent($0) }
        let allDay = busy.filter { $0.allDay }
        var shades: [TimelineDayShade] = []
        for offset in 0..<max(0, range.dayCount) {
            let day = range.firstDay + offset
            let date = NCAgendaTimelineDays.date(day, calendar: calendar)
            let hours = pattern.hours
            let share = hours > 0 ? min(1, NCAgendaWorkload.busyHours(on: date, items: busy, pattern: pattern, calendar: calendar) / hours) : 0
            let off = !pattern.isWorkingDay(date, calendar: calendar) || allDay.contains { NCAgendaWorkload.covers($0, day: date, calendar: calendar) }
            shades.append(TimelineDayShade(day: day, share: share, hatched: off))
        }
        return shades
    }

    // MARK: Words

    /// What a screen reader says of a bar or a diamond: "Gantt task Write homepage copy, 28 Oct to 1 Nov, 40 % done, Writer-Bot".
    static func spoken(_ item: AgendaItem, shape: TimelineShape, calendar: Calendar, locked: Bool, notSent: Bool) -> String {
        var parts: [String] = []
        switch item.kind {
        case .ganttTask: parts.append(NCAgendaTimelineText.t("_nodrive_agenda_timeline_kind_task_"))
        default: parts.append(item.kind.spokenName)
        }
        parts.append(item.title)
        let first = NCAgendaTimelineDays.date(shape.firstDay, calendar: calendar)
        let last = NCAgendaTimelineDays.date(shape.lastDay, calendar: calendar)
        if shape.firstDay == shape.lastDay {
            parts.append(NCAgendaFormat.shortDay(first))
        } else {
            parts.append(NCAgendaTimelineText.f("_nodrive_agenda_timeline_spoken_range_", NCAgendaFormat.shortDay(first), NCAgendaFormat.shortDay(last)))
        }
        if item.kind == .ganttTask, let percent = item.percent {
            parts.append(NCAgendaTimelineText.f("_nodrive_agenda_timeline_spoken_percent_", percent))
        }
        parts.append(agentName(item.agent))
        if item.late { parts.append(NCAgendaText.t("_nodrive_agenda_late_")) }
        if item.blocked { parts.append(NCAgendaText.t("_nodrive_agenda_blocked_")) }
        if locked { parts.append(NCAgendaText.t("_nodrive_agenda_spoken_locked_")) }
        if item.pending { parts.append(NCAgendaEditText.t("_nodrive_agenda_edit_waiting_spoken_")) }
        if notSent { parts.append(NCAgendaTimelineText.t("_nodrive_agenda_timeline_spoken_not_sent_")) }
        return parts.joined(separator: ", ")
    }

    /// "Writer-Bot" or "Self": the agent text without the emoji mark.
    static func agentName(_ agent: AgentRef) -> String {
        agent.displayText.drop(while: { !($0.isLetter || $0.isNumber) }).trimmingCharacters(in: .whitespaces)
    }

    /// The spoken list of the arrows: "Review banners comes after Write homepage copy".
    static func spokenArrows(_ layout: TimelineLayout) -> String {
        var titles: [String: String] = [:]
        for row in layout.rows {
            if case let .item(item) = row.content { titles[item.key] = item.title }
        }
        let lines = layout.arrows.compactMap { arrow -> String? in
            guard let from = titles[arrow.fromKey], let to = titles[arrow.toKey] else { return nil }
            return NCAgendaTimelineText.f("_nodrive_agenda_timeline_spoken_after_", to, from)
        }
        return lines.joined(separator: ". ")
    }
}
