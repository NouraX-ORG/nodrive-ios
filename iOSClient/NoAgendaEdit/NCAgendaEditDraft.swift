// SPDX-FileCopyrightText: 2026 Nourax
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// What the person typed in the editor. It becomes the commands of the fields that really changed.
struct NCAgendaEditDraft: Equatable {
    var title = ""
    var allDay = false
    var start = Date()
    /// Event: the end (for an all-day event the last day, as the person reads it).
    var end = Date()
    var hasStart = false
    var hasDue = false
    var due = Date()
    var descriptionText = ""
    var done = false
    var percent = 0
    var status = ""
    var agent: AgentChoice = .selfChoice

    /// The editor starts from the row as it is.
    init(item: AgendaItem, calendar: Calendar) {
        title = item.title
        allDay = item.allDay
        descriptionText = item.descriptionText ?? ""
        done = false
        percent = item.percent ?? 0
        status = item.status ?? ""
        switch item.kind {
        case .event:
            start = item.start ?? Date()
            let rawEnd = item.end ?? start.addingTimeInterval(3_600)
            end = item.allDay ? (calendar.date(byAdding: .day, value: -1, to: rawEnd) ?? rawEnd) : rawEnd
        case .todo:
            hasStart = item.start != nil
            start = item.start ?? Date()
            hasDue = item.due != nil
            due = item.due ?? item.start ?? Date()
        case .ganttTask:
            start = item.start ?? item.end ?? Date()
            end = item.end ?? item.start ?? Date()
        case .card:
            hasDue = item.due != nil
            due = item.due ?? Date()
        case .milestone:
            break
        }
        switch item.agent {
        case let .mine(id, name, status): agent = AgentChoice(id: id, name: name, status: status)
        default: agent = .selfChoice
        }
    }

    init() {}

    /// "yyyy-MM-dd" of a moment in a zone (NoGantt dates are days).
    static func dayText(_ date: Date, zone: TimeZone, calendar: Calendar) -> String {
        var zoned = calendar
        zoned.timeZone = zone
        return NCAgendaDays.key(date, calendar: zoned)
    }

    /// The commands of what changed, from the row `item`. `agentChoice` is the picked agent (with its registry
    /// fields); nothing is made for a field that was not touched.
    func commands(for item: AgendaItem, calendar: Calendar, ganttZone: TimeZone, now: Date) -> [NCAgendaEditCommand] {
        let original = NCAgendaEditDraft(item: item, calendar: calendar)
        var result: [NCAgendaEditCommand] = []
        func make(_ kind: NCAgendaEditCommand.Kind) -> NCAgendaEditCommand {
            NCAgendaEditCommand(id: UUID(), kind: kind, createdAt: now, itemKey: item.key, title: title.isEmpty ? item.title : title,
                                sourceKey: item.sourceKey, link: item.link)
        }
        let agentChanged = agent.id != original.agent.id
        switch item.kind {
        case .event, .todo:
            var change = CalendarChange()
            if title != original.title { change.title = title }
            if descriptionText != original.descriptionText, item.descriptionLength <= 2000 { change.descriptionText = descriptionText }
            if item.kind == .event {
                if allDay != original.allDay { change.allDay = allDay }
                if allDay != original.allDay || start != original.start || end != original.end {
                    change.allDay = allDay
                    change.start = start
                    // An all-day event ends the day after the last day (iCalendar's exclusive DTEND).
                    change.end = allDay ? (calendar.date(byAdding: .day, value: 1, to: end) ?? end) : end
                }
            } else {
                if hasStart, start != original.start || !original.hasStart { change.start = start }
                if hasDue, due != original.due || !original.hasDue { change.due = due }
                if done { change.done = true }
            }
            if agentChanged { change.agent = agent.calendarWrite }
            if !change.isEmpty {
                var command = make(.calendarPatch)
                command.calendar = change
                if agentChanged { command.agent = agent }
                result.append(command)
            }
        case .ganttTask:
            var change = GanttChange()
            let zoneDay = { (date: Date) in Self.dayText(date, zone: ganttZone, calendar: calendar) }
            if zoneDay(start) != zoneDay(original.start) { change.startDay = zoneDay(start) }
            if zoneDay(end) != zoneDay(original.end) { change.endDay = zoneDay(end) }
            if percent != original.percent { change.percent = percent }
            if status != original.status, !status.isEmpty { change.status = status }
            if done { change.done = true }
            if !change.isEmpty {
                var command = make(.ganttUpdate)
                command.gantt = change
                result.append(command)
            }
            if agentChanged {
                var command = make(.ganttAgent)
                command.agent = agent
                result.append(command)
            }
        case .card:
            var change = DeckChange()
            if hasDue, due != original.due || !original.hasDue { change.due = due }
            if done { change.done = true }
            if !change.isEmpty {
                var command = make(.deckUpdate)
                command.deck = change
                result.append(command)
            }
            if agentChanged {
                var command = make(.deckAgent)
                command.agent = agent
                result.append(command)
            }
        case .milestone:
            break
        }
        return result
    }

    var hasChanges: Bool { true }
}
