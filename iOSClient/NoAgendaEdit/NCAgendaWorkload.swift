// SPDX-FileCopyrightText: 2026 Nourax
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// NoGantt counts `work` in the unit of the planning person: hours, or person-days ("PT"). The maths uses hours.
enum NCAgendaWorkUnits {
    static let defaultHoursPerPt = 8.0

    static func hours(_ work: Double, unit: String?, hoursPerPt: Double?) -> Double {
        switch unit?.lowercased() {
        case "pt", "d", "day", "days", "pd": return work * (hoursPerPt ?? defaultHoursPerPt)
        default: return work
        }
    }
}

/// Day keys and weekdays in one calendar. Monday is 0 (NoGantt's bit 0 and the registry's "mon").
enum NCAgendaDays {
    static func key(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    static func weekday(_ date: Date, calendar: Calendar) -> Int {
        (calendar.component(.weekday, from: date) + 5) % 7
    }

    static func minutes(_ text: String?) -> Int? {
        guard let text else { return nil }
        let parts = text.split(separator: ":")
        guard parts.count >= 2, let hour = Int(parts[0]), let minute = Int(parts[1]) else { return nil }
        return hour * 60 + minute
    }

    /// The days from the start day to the end day, both included (at most 400 days, so odd data cannot run away).
    static func days(from start: Date, to end: Date, calendar: Calendar) -> [Date] {
        var result: [Date] = []
        var current = calendar.startOfDay(for: start)
        let last = calendar.startOfDay(for: max(start, end))
        while current <= last, result.count < 400 {
            result.append(current)
            guard let next = calendar.date(byAdding: .day, value: 1, to: current) else { break }
            current = next
        }
        return result
    }
}

/// My working pattern (design 7, plan 2.7.9): the work schedule of my linked planning person with NoGantt's working
/// hours; without one, the days and hours of NoAgenda's own settings (Monday to Friday, 09:00 to 17:00).
struct AgendaWorkPattern: Equatable, Sendable {
    var days: Set<Int> = [0, 1, 2, 3, 4]
    var startMinutes = 9 * 60
    var endMinutes = 17 * 60
    /// "yyyy-MM-dd"
    var holidays: Set<String> = []

    var hours: Double { Double(max(0, endMinutes - startMinutes)) / 60 }

    func isWorkingDay(_ date: Date, calendar: Calendar) -> Bool {
        days.contains(NCAgendaDays.weekday(date, calendar: calendar)) && !holidays.contains(NCAgendaDays.key(date, calendar: calendar))
    }

    static func make(settings: AgendaSettings, gantt: RawGantt?, userId: String, everyDayWorks: Bool = false) -> AgendaWorkPattern {
        var pattern = AgendaWorkPattern()
        pattern.days = Set(settings.workDays)
        pattern.startMinutes = settings.workStartMinutes
        pattern.endMinutes = settings.workEndMinutes
        let mine = gantt?.resources.filter { $0.uid?.lowercased() == userId.lowercased() } ?? []
        if let schedule = gantt?.workSchedules?.first(where: { row in mine.contains { $0.id == row.resourceId } }) {
            pattern.days = Set((0..<7).filter { schedule.workDays & (1 << $0) != 0 })
            if let start = NCAgendaDays.minutes(gantt?.workStart), let end = NCAgendaDays.minutes(gantt?.workEnd), end > start {
                pattern.startMinutes = start
                pattern.endMinutes = end
            }
        }
        let calendarId = mine.first?.calendarId
        pattern.holidays = Set((gantt?.holidays ?? []).filter { $0.calendarId == nil || $0.calendarId == calendarId }.map { $0.date })
        if everyDayWorks { pattern.days = Set(0...6) }
        return pattern
    }
}

struct AgendaWorkload: Equatable, Sendable {
    var planned: Double
    var free: Double
    /// Tasks of the day without a `work` estimate (they add no hours).
    var noEstimate: Int

    var isOver: Bool { planned > free + 0.05 }

    static func number(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        if rounded == rounded.rounded() { return String(Int(rounded)) }
        return String(format: "%.1f", rounded)
    }

    /// "6 h planned / 4 h free"
    var text: String {
        NCAgendaEditText.f("_nodrive_agenda_edit_workload_", Self.number(planned), Self.number(free))
    }
}

/// The workload bar (design 7, "Overbooked"): per working day, planned against free.
enum NCAgendaWorkload {
    /// My own busy time of a day inside the working window, in hours. Only my Self events count: an agent's event
    /// never takes the person's time. Tentative counts as busy (the warning errs on the safe side).
    static func busyHours(on day: Date, items: [AgendaItem], pattern: AgendaWorkPattern, calendar: Calendar) -> Double {
        let dayStart = calendar.startOfDay(for: day)
        guard let windowStart = calendar.date(byAdding: .minute, value: pattern.startMinutes, to: dayStart),
              let windowEnd = calendar.date(byAdding: .minute, value: pattern.endMinutes, to: dayStart) else { return 0 }
        var intervals: [(Date, Date)] = []
        for item in items where isBusyEvent(item) && !item.allDay {
            guard let start = item.start, let end = item.end, end > start else { continue }
            let from = max(start, windowStart)
            let to = min(end, windowEnd)
            if to > from { intervals.append((from, to)) }
        }
        intervals.sort { $0.0 < $1.0 }
        var total = 0.0
        var current: (Date, Date)?
        for interval in intervals {
            if let open = current, interval.0 <= open.1 {
                current = (open.0, max(open.1, interval.1))
            } else {
                if let open = current { total += open.1.timeIntervalSince(open.0) }
                current = interval
            }
        }
        if let open = current { total += open.1.timeIntervalSince(open.0) }
        return total / 3600
    }

    static func isBusyEvent(_ item: AgendaItem) -> Bool {
        item.kind == .event && item.relation == .mine && item.agent.isSelf && !item.transparent && item.scope != .info
    }

    /// Nil on a day that is not a working day, and on a day with nothing planned and nothing busy.
    static func day(_ date: Date, items: [AgendaItem], pattern: AgendaWorkPattern, calendar: Calendar) -> AgendaWorkload? {
        guard pattern.isWorkingDay(date, calendar: calendar) else { return nil }
        let dayStart = calendar.startOfDay(for: date)
        var planned = 0.0
        var noEstimate = 0
        for item in items where item.kind == .ganttTask && item.relation == .mine {
            guard let start = item.start ?? item.end, let end = item.end ?? item.start else { continue }
            let taskDays = NCAgendaDays.days(from: start, to: end, calendar: calendar)
            guard taskDays.contains(dayStart) else { continue }
            guard let work = item.workShare else { noEstimate += 1; continue }
            let working = taskDays.filter { pattern.isWorkingDay($0, calendar: calendar) }.count
            if working > 0 { planned += work / Double(working) }
        }
        // An all-day busy event is a day off: nothing is free.
        let allDayBusy = items.contains { isBusyEvent($0) && $0.allDay && covers($0, day: dayStart, calendar: calendar) }
        let busy = busyHours(on: date, items: items, pattern: pattern, calendar: calendar)
        let free = allDayBusy ? 0 : max(0, pattern.hours - busy)
        if planned == 0, busy == 0, !allDayBusy, noEstimate == 0 { return nil }
        return AgendaWorkload(planned: planned, free: free, noEstimate: noEstimate)
    }

    /// Does an all-day event cover the day? (DTEND of an all-day event is the day after the last one.)
    static func covers(_ item: AgendaItem, day: Date, calendar: Calendar) -> Bool {
        guard let start = item.start else { return false }
        let first = calendar.startOfDay(for: start)
        let after = item.end.map { calendar.startOfDay(for: $0) } ?? calendar.date(byAdding: .day, value: 1, to: first) ?? first
        return day >= first && day < max(after, first.addingTimeInterval(1))
    }
}
