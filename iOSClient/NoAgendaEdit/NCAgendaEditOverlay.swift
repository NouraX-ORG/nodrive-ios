// SPDX-FileCopyrightText: 2026 Nourax
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// What the person sees while edits wait: each waiting command is drawn on its row at once (with a clock mark), a new
/// item is drawn from its command, and a done or deleted item leaves the list. The data itself is never changed.
enum NCAgendaEditOverlay {
    /// "yyyy-MM-dd" as a day in `zone`, at the time of day of `time` (or noon when there is none).
    static func day(_ text: String, keepingTimeOf time: Date?, zone: TimeZone, calendar: Calendar) -> Date? {
        let parts = text.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var zoned = calendar
        zoned.timeZone = zone
        var components = DateComponents()
        components.year = parts[0]
        components.month = parts[1]
        components.day = parts[2]
        if let time {
            let clock = zoned.dateComponents([.hour, .minute, .second], from: time)
            components.hour = clock.hour
            components.minute = clock.minute
            components.second = clock.second
        } else {
            components.hour = 12
        }
        return zoned.date(from: components)
    }

    static func apply(_ commands: [NCAgendaEditCommand], to items: [AgendaItem], sources: [AgendaSource], ganttZone: TimeZone,
                      calendar: Calendar) -> [AgendaItem] {
        var result = items
        for command in commands where command.isWaiting {
            switch command.kind {
            case .calendarCreate:
                result.append(created(command, sources: sources))
            case .calendarDelete:
                result.removeAll { $0.key == command.itemKey }
            default:
                guard let index = result.firstIndex(where: { $0.key == command.itemKey }) else { continue }
                var item = result[index]
                var gone = false
                switch command.kind {
                case .calendarPatch:
                    if let change = command.calendar { gone = apply(change, to: &item) }
                    if command.calendar?.agent != nil, let agent = command.agent { item.agent = agent.ref }
                case .ganttUpdate:
                    if let change = command.gantt { gone = apply(change, to: &item, zone: ganttZone, calendar: calendar) }
                case .deckUpdate:
                    if let change = command.deck { gone = apply(change, to: &item) }
                case .ganttAgent, .deckAgent:
                    if let agent = command.agent { item.agent = agent.ref }
                default:
                    break
                }
                if gone { result.remove(at: index) } else {
                    item.pending = true
                    result[index] = item
                }
            }
        }
        return result
    }

    /// True when the change makes the row leave the list (done).
    private static func apply(_ change: CalendarChange, to item: inout AgendaItem) -> Bool {
        if change.done == true { return true }
        if let title = change.title { item.title = title }
        if let allDay = change.allDay { item.allDay = allDay }
        if let start = change.start { item.start = start }
        if let end = change.end { item.end = end }
        if let due = change.due { item.due = due }
        if let text = change.descriptionText { item.descriptionText = text; item.descriptionLength = text.count }
        return false
    }

    private static func apply(_ change: GanttChange, to item: inout AgendaItem, zone: TimeZone, calendar: Calendar) -> Bool {
        if change.done == true { return true }
        if let day = change.startDay, let date = Self.day(day, keepingTimeOf: item.start, zone: zone, calendar: calendar) { item.start = date }
        if let day = change.endDay, let date = Self.day(day, keepingTimeOf: item.end, zone: zone, calendar: calendar) { item.end = date }
        if let percent = change.percent { item.percent = percent }
        if let status = change.status { item.status = status }
        return false
    }

    private static func apply(_ change: DeckChange, to item: inout AgendaItem) -> Bool {
        if change.done == true { return true }
        if change.clearDue { item.due = nil }
        if let due = change.due { item.due = due }
        return false
    }

    private static func created(_ command: NCAgendaEditCommand, sources: [AgendaSource]) -> AgendaItem {
        let change = command.calendar ?? CalendarChange()
        let isEvent = command.component != "VTODO"
        let source = sources.first { $0.key == command.sourceKey }
        var item = AgendaItem(key: "pending:" + command.id.uuidString, home: isEvent ? .calendar : .tasks, kind: isEvent ? .event : .todo,
                              title: change.title ?? command.title,
                              sourceKey: command.sourceKey ?? "", sourceName: source?.name ?? "", sourceColor: source?.color ?? NCAgendaColors.cobalt,
                              link: command.link)
        item.scope = source.map { $0.setting == .personal ? .personal : .work } ?? .work
        item.allDay = change.allDay ?? false
        item.start = change.start
        if isEvent {
            item.end = change.end ?? change.start.map { $0.addingTimeInterval(item.allDay ? 86_400 : 3_600) }
        } else {
            item.due = change.due
        }
        item.agent = command.agent?.ref ?? .selfAgent
        item.pending = true
        item.lock = .pendingCreate
        return item
    }
}

/// The rows the lists show: waiting edits drawn on them, then the conflict marks, then the agents' own overbooking.
enum NCAgendaEditPipeline {
    static func display(_ snapshot: AgendaSnapshot, commands: [NCAgendaEditCommand], context: AgendaEditContext, now: Date, calendar: Calendar) -> AgendaSnapshot {
        guard let me = context.me else { return snapshot }
        var shown = snapshot
        let zone = context.gantt?.timezone.flatMap { TimeZone(identifier: $0) } ?? calendar.timeZone
        let overlaid = NCAgendaEditOverlay.apply(commands, to: snapshot.items, sources: snapshot.sources, ganttZone: zone, calendar: calendar)
        let pattern = pattern(context: context)
        shown.items = NCAgendaConflicts.mark(overlaid, pattern: pattern, calendar: calendar)
        shown.problems += NCAgendaAgentLoad.problems(registry: context.registry, me: me, gantt: context.gantt, items: shown.items, now: now, calendar: calendar)
        return shown
    }

    static func pattern(context: AgendaEditContext) -> AgendaWorkPattern {
        AgendaWorkPattern.make(settings: context.settings, gantt: context.gantt, userId: context.me?.userId ?? "",
                               everyDayWorks: NCAgendaUITestHooks.everyDayWorks)
    }
}
