// SPDX-FileCopyrightText: 2026 Nourax
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// An agent's own load against its own capacity (design 4.3 and 7): "Writer-Bot is overbooked on Thursday".
/// An agent's hours never count for its person; they are measured here, against the registry's availability.
enum NCAgendaAgentLoad {
    /// Days looked at, from today (plan 3.6, the same as desktop).
    static let daysAhead = 28

    /// A planning person that stands for the agent: its NoGantt id is in the registry, or (placeholder phase) its name
    /// is exactly "🤖 <agent name> (<person's display name>)" **and** it sits on a task next to that person's linked
    /// planning person (`personOnTask`; design 4.5 b, the same rule as the core assembler's `agentOf`).
    static func isPlanningPerson(_ resource: GanttResource, of agent: RegistryAgent, personName: String?, personOnTask: Bool) -> Bool {
        guard resource.type == "person", resource.uid == nil else { return false }
        if agent.ganttResourceIds.contains(resource.id) { return true }
        guard personOnTask, let personName else { return false }
        return NCAgendaAssembler.normalised(resource.name) == NCAgendaAssembler.normalised("🤖 \(agent.name) (\(personName))")
    }

    /// The hours of the agent per day ("yyyy-MM-dd"), from the work on tasks of the projects the person can see plus the
    /// timed events and cards that name the agent.
    static func load(of agent: RegistryAgent, personName: String?, personUid: String?, gantt: RawGantt?, items: [AgendaItem], calendar: Calendar) -> [String: Double] {
        var hours: [String: Double] = [:]
        let availability = agent.availability ?? AgentAvailability()
        let workDays = availability.workDays
        let off = Set(availability.daysOff)
        let zone = gantt?.timezone.flatMap { TimeZone(identifier: $0) } ?? calendar.timeZone
        var ganttCalendar = calendar
        ganttCalendar.timeZone = zone
        if let gantt {
            let resources = Dictionary(gantt.resources.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            for tasks in gantt.tasks.values {
                for task in tasks where task.status != "done" {
                    // A name match counts only next to my own linked planning person on the same task.
                    let personOnTask = personUid.map { uid in
                        task.resources.contains { resources[$0.resourceId]?.uid?.lowercased() == uid.lowercased() }
                    } ?? false
                    for row in task.resources {
                        guard let resource = resources[row.resourceId],
                              isPlanningPerson(resource, of: agent, personName: personName, personOnTask: personOnTask),
                              let work = row.work, work > 0 else { continue }
                        guard let start = NCAgendaAssembler.ganttDate(task.start ?? task.end, zone: zone),
                              let end = NCAgendaAssembler.ganttDate(task.end ?? task.start, zone: zone) else { continue }
                        let taskDays = NCAgendaDays.days(from: start, to: end, calendar: ganttCalendar).filter { day in
                            workDays.contains(NCAgendaDays.weekday(day, calendar: ganttCalendar))
                                && !off.contains(NCAgendaDays.key(day, calendar: ganttCalendar))
                        }
                        guard !taskDays.isEmpty else { continue }
                        let perDay = NCAgendaWorkUnits.hours(work, unit: resource.unit, hoursPerPt: gantt.hoursPerPt) / Double(taskDays.count)
                        for day in taskDays { hours[NCAgendaDays.key(day, calendar: ganttCalendar), default: 0] += perDay }
                    }
                }
            }
        }
        // Timed events and cards of the agent.
        var agentCalendar = calendar
        if let zoneName = availability.timezone, let zone = TimeZone(identifier: zoneName) { agentCalendar.timeZone = zone }
        for item in items where item.relation == .mine && !item.allDay && (item.kind == .event || item.kind == .card) {
            guard case let .mine(id, _, _) = item.agent, id == agent.id else { continue }
            let start = item.start
            let end = item.kind == .card ? item.due : item.end
            guard let start, let end, end > start else { continue }
            hours[NCAgendaDays.key(start, calendar: agentCalendar), default: 0] += end.timeIntervalSince(start) / 3600
        }
        return hours
    }

    /// One problem row per agent and day over capacity, from today for 28 days. An agent with no capacity in the
    /// registry is never reported.
    static func problems(registry: NCAgendaRegistry?, me: AgendaMe, gantt: RawGantt?, items: [AgendaItem], now: Date, calendar: Calendar) -> [AgendaProblem] {
        guard let registry else { return [] }
        var result: [AgendaProblem] = []
        for agent in registry.agents(of: me.userId) where agent.status != .retired {
            let availability = agent.availability ?? AgentAvailability()
            guard let capacity = availability.dailyCapacity else { continue }
            var agentCalendar = calendar
            if let zoneName = availability.timezone, let zone = TimeZone(identifier: zoneName) { agentCalendar.timeZone = zone }
            let hours = load(of: agent, personName: me.displayName, personUid: me.userId, gantt: gantt, items: items, calendar: calendar)
            // One zone for the walk, the day keys and the weekday: the agent's own (its events are keyed in it; the days of a
            // NoGantt task are dates, which read the same in any zone).
            let first = agentCalendar.startOfDay(for: now)
            for offset in 0..<daysAhead {
                guard let day = agentCalendar.date(byAdding: .day, value: offset, to: first) else { continue }
                let key = NCAgendaDays.key(day, calendar: agentCalendar)
                guard availability.workDays.contains(NCAgendaDays.weekday(day, calendar: agentCalendar)), !availability.daysOff.contains(key),
                      let load = hours[key], load > capacity + 0.05 else { continue }
                // The row sits on that date in the person's own zone.
                let parts = agentCalendar.dateComponents([.year, .month, .day], from: day)
                let shown = calendar.date(from: parts) ?? day
                let weekday = shown.formatted(Date.FormatStyle(calendar: calendar, timeZone: calendar.timeZone).weekday(.wide))
                result.append(AgendaProblem(key: "mine:agent-over:\(agent.id):\(key)", kind: .overbooked, relation: .mine,
                                            title: agent.name, agentText: "🤖 " + agent.name,
                                            text: "⚠ 🤖 " + NCAgendaEditText.f("_nodrive_agenda_edit_agent_overbooked_", agent.name, weekday),
                                            date: shown, link: nil, home: .gantt))
            }
        }
        return result
    }
}
