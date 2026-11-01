// SPDX-FileCopyrightText: 2026 Nourax
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// The four conflict kinds of design 7, computed on the phone from rows the person can already see.
/// Blocked and late are set by the assembler; this sets the clash and the day off.
enum NCAgendaConflicts {
    static func isTentative(_ item: AgendaItem) -> Bool {
        item.status == "TENTATIVE" || item.partstat == "TENTATIVE"
    }

    /// The interval a row occupies when it is a timed item of mine: an event, a card with a start and a due time, or a
    /// Gantt task that starts and ends on one day with real times. Nil for every other row.
    static func timedInterval(_ item: AgendaItem, calendar: Calendar) -> (Date, Date)? {
        guard item.relation == .mine, item.agent.isSelf, !item.transparent, item.scope != .info, !item.allDay else { return nil }
        switch item.kind {
        case .event:
            guard let start = item.start, let end = item.end, end > start else { return nil }
            return (start, end)
        case .card:
            guard let start = item.start, let end = item.due, end > start else { return nil }
            return (start, end)
        case .ganttTask:
            guard let start = item.start, let end = item.end, end > start, calendar.isDate(start, inSameDayAs: end) else { return nil }
            return (start, end)
        case .todo, .milestone:
            return nil
        }
    }

    /// Clash: two timed items of mine overlap. A tentative one gives a soft clash (dashed). Free events, declined
    /// invitations, Info calendars and every item that an agent does never clash with mine.
    static func clashes(_ items: [AgendaItem], calendar: Calendar) -> [String: ClashKind] {
        struct Timed {
            var key: String
            var start: Date
            var end: Date
            var tentative: Bool
        }
        var timed: [Timed] = []
        for item in items {
            guard let interval = timedInterval(item, calendar: calendar) else { continue }
            timed.append(Timed(key: item.key, start: interval.0, end: interval.1, tentative: isTentative(item)))
        }
        timed.sort { $0.start < $1.start }
        var result: [String: ClashKind] = [:]
        func raise(_ key: String, _ kind: ClashKind) {
            if result[key] == .hard { return }
            result[key] = kind
        }
        for (index, first) in timed.enumerated() {
            var next = index + 1
            while next < timed.count, timed[next].start < first.end {
                let second = timed[next]
                let kind: ClashKind = (first.tentative || second.tentative) ? .soft : .hard
                raise(first.key, kind)
                raise(second.key, kind)
                next += 1
            }
        }
        return result
    }

    /// The days an all-day busy event of mine covers ("yyyy-MM-dd").
    static func busyAllDayDays(_ items: [AgendaItem], calendar: Calendar) -> Set<String> {
        var days = Set<String>()
        for item in items where NCAgendaWorkload.isBusyEvent(item) && item.allDay {
            guard let start = item.start else { continue }
            let end = item.end ?? start
            for day in NCAgendaDays.days(from: start, to: max(start, end.addingTimeInterval(-1)), calendar: calendar) {
                days.insert(NCAgendaDays.key(day, calendar: calendar))
            }
        }
        return days
    }

    /// Deadline on a day off: a due or end date of one of my own rows on a non-working day, a NoGantt holiday (both in
    /// the pattern), or an all-day busy event.
    static func isOnDayOff(_ item: AgendaItem, pattern: AgendaWorkPattern, busyDays: Set<String>, calendar: Calendar) -> Bool {
        guard item.relation == .mine, item.agent.isSelf, item.scope != .info else { return false }
        let date: Date?
        switch item.kind {
        case .todo, .card: date = item.due
        case .ganttTask, .milestone: date = item.end ?? item.start
        case .event: date = nil
        }
        guard let date else { return false }
        return !pattern.isWorkingDay(date, calendar: calendar) || busyDays.contains(NCAgendaDays.key(date, calendar: calendar))
    }

    /// The rows with their clash and day-off marks.
    static func mark(_ items: [AgendaItem], pattern: AgendaWorkPattern, calendar: Calendar) -> [AgendaItem] {
        let clash = clashes(items, calendar: calendar)
        let busyDays = busyAllDayDays(items, calendar: calendar)
        return items.map { item in
            var row = item
            row.clash = clash[item.key]
            row.dayOff = isOnDayOff(item, pattern: pattern, busyDays: busyDays, calendar: calendar)
            return row
        }
    }

    /// The Conflicts chip: only rows with a clash, a block, a late mark, a day off.
    static func hasConflict(_ item: AgendaItem) -> Bool {
        item.clash != nil || item.blocked || item.late || item.dayOff
    }
}
