// SPDX-FileCopyrightText: 2026 Nourax
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// The sections of one day (design 8, "Day view contents").
struct AgendaDayPlan: Equatable {
    var day: Date
    /// Events (by start; all-day first).
    var timed: [AgendaItem] = []
    var dueToday: [AgendaItem] = []
    var inProgress: [AgendaItem] = []
    var late: [AgendaItem] = []
    /// "Problems with your agents".
    var ownProblems: [AgendaProblem] = []
    /// "My team": problems only.
    var teamProblems: [AgendaProblem] = []
    /// "My team" with "Show all team tasks".
    var teamItems: [AgendaItem] = []
    var noDate: [AgendaItem] = []

    var isEmpty: Bool {
        timed.isEmpty && dueToday.isEmpty && inProgress.isEmpty && late.isEmpty && ownProblems.isEmpty
            && teamProblems.isEmpty && teamItems.isEmpty && noDate.isEmpty
    }

    var itemCount: Int {
        timed.count + dueToday.count + inProgress.count + late.count + teamItems.count
    }
}

/// Which rows go on which day. Plain functions of the snapshot, the filter and the calendar.
enum NCAgendaPlanner {
    /// Does the item fall on this day?
    enum Placement {
        case timed, dueToday, inProgress, noDate, none
    }

    static func placement(of item: AgendaItem, on day: Date, calendar: Calendar) -> Placement {
        let dayStart = calendar.startOfDay(for: day)
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { return .none }
        switch item.kind {
        case .event:
            guard let start = item.start else { return .none }
            let end = max(item.end ?? start, start)
            if end == start { return start >= dayStart && start < dayEnd ? .timed : .none }
            return start < dayEnd && end > dayStart ? .timed : .none
        case .todo:
            if let due = item.due {
                if calendar.isDate(due, inSameDayAs: dayStart) { return .dueToday }
                if let start = item.start, start < dayStart || calendar.isDate(start, inSameDayAs: dayStart), due >= dayEnd { return .inProgress }
                return .none
            }
            if let start = item.start { return calendar.isDate(start, inSameDayAs: dayStart) ? .inProgress : .none }
            return .noDate
        case .ganttTask:
            guard let start = item.start ?? item.end, let end = item.end ?? item.start else { return .noDate }
            let endDay = calendar.startOfDay(for: end)
            let startDay = calendar.startOfDay(for: start)
            if endDay == dayStart { return .dueToday }
            if startDay <= dayStart && dayStart < endDay { return .inProgress }
            return .none
        case .milestone:
            guard let date = item.end ?? item.start else { return .none }
            return calendar.isDate(date, inSameDayAs: dayStart) ? .dueToday : .none
        case .card:
            guard let due = item.due else { return .noDate }
            return calendar.isDate(due, inSameDayAs: dayStart) ? .dueToday : .none
        }
    }

    private static func ordered(_ items: [AgendaItem]) -> [AgendaItem] {
        items.sorted { lhs, rhs in
            let l = lhs.start ?? lhs.due ?? lhs.end ?? .distantFuture
            let r = rhs.start ?? rhs.due ?? rhs.end ?? .distantFuture
            if lhs.allDay != rhs.allDay { return lhs.allDay }
            if l != r { return l < r }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }

    static func plan(day: Date, snapshot: AgendaSnapshot, filter: AgendaFilter, showAllTeam: Bool, now: Date, calendar: Calendar) -> AgendaDayPlan {
        var plan = AgendaDayPlan(day: calendar.startOfDay(for: day))
        let isToday = calendar.isDate(day, inSameDayAs: now)
        for item in snapshot.items where filter.allows(item) {
            let place = placement(of: item, on: day, calendar: calendar)
            if item.relation == .team {
                // Team rows are shown only when asked for; the problems are the default.
                if showAllTeam, place == .timed || place == .dueToday || place == .inProgress {
                    plan.teamItems.append(item)
                }
                continue
            }
            switch place {
            case .timed: plan.timed.append(item)
            case .dueToday: plan.dueToday.append(item)
            case .inProgress: plan.inProgress.append(item)
            case .noDate: plan.noDate.append(item)
            case .none: break
            }
            if isToday, item.late, place == .none {
                plan.late.append(item)
            }
        }
        if isToday {
            plan.ownProblems = snapshot.problems.filter { $0.relation == .mine && filter.allows($0) }
            plan.teamProblems = snapshot.problems.filter { $0.relation == .team && filter.allows($0) }
        }
        plan.timed = ordered(plan.timed)
        plan.dueToday = ordered(plan.dueToday)
        plan.inProgress = ordered(plan.inProgress)
        plan.late = ordered(plan.late)
        plan.teamItems = ordered(plan.teamItems)
        plan.noDate = ordered(plan.noDate)
        return plan
    }

    /// The days of the week that contains `day` (the calendar's first weekday first).
    static func weekDays(of day: Date, calendar: Calendar) -> [Date] {
        guard let interval = calendar.dateInterval(of: .weekOfYear, for: day) else { return [calendar.startOfDay(for: day)] }
        return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: interval.start) }
    }

    /// The days of the month grid: leading days of the previous month are nil.
    static func monthGrid(of day: Date, calendar: Calendar) -> [Date?] {
        guard let interval = calendar.dateInterval(of: .month, for: day) else { return [] }
        let firstWeekday = calendar.component(.weekday, from: interval.start)
        let leading = (firstWeekday - calendar.firstWeekday + 7) % 7
        var cells: [Date?] = Array(repeating: nil, count: leading)
        var current = interval.start
        while current < interval.end {
            cells.append(current)
            guard let next = calendar.date(byAdding: .day, value: 1, to: current) else { break }
            current = next
        }
        return cells
    }

    /// Does the day have anything for the dot of the month grid?
    static func hasItems(on day: Date, snapshot: AgendaSnapshot, filter: AgendaFilter, calendar: Calendar) -> Bool {
        snapshot.items.contains { item in
            guard item.relation == .mine, filter.allows(item) else { return false }
            let place = placement(of: item, on: day, calendar: calendar)
            return place == .timed || place == .dueToday || place == .inProgress
        }
    }
}
