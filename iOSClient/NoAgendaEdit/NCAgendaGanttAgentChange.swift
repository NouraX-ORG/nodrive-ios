// SPDX-FileCopyrightText: 2026 Nourax
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Everything the "my agent" change of a Gantt task needs to know (design 4.5 and 9).
struct GanttAgentContext: Sendable {
    var myUid: String
    var myName: String
    var myAgents: [RegistryAgent]
    /// The planning people visible to me (NoGantt drops a row it can't show me, silently).
    var resources: [Int: GanttResource]
    var project: GanttProject?
    /// The tasks of the project (the cached ones in the editor, the fresh ones at send time). They show which planning
    /// people belong to this project.
    var projectTasks: [GanttTask] = []
}

/// "My agent" on a Gantt task: the new `resources` list, built from the **fresh** task, and the reasons to send nothing.
/// NoAgenda never creates planning people.
enum NCAgendaGanttAgentChange {
    static let maxRows = 4

    enum Refusal: Equatable, Sendable {
        case tooMany, notOnTask, hiddenRow, workWouldChange, firstWouldChange, rolesOnly, viewer, noChange
        case agentNotVisible(name: String)
    }

    enum Plan: Equatable, Sendable {
        case rows([GanttResourceRow])
        case refused(Refusal)
    }

    static func text(_ refusal: Refusal) -> String {
        switch refusal {
        case .tooMany: return NCAgendaEditText.t("_nodrive_agenda_edit_gantt_too_many_")
        case .notOnTask, .hiddenRow, .firstWouldChange: return NCAgendaEditText.t("_nodrive_agenda_edit_gantt_check_")
        case .workWouldChange: return NCAgendaEditText.t("_nodrive_agenda_edit_gantt_work_")
        case .rolesOnly: return NCAgendaEditText.t("_nodrive_agenda_edit_gantt_roles_only_")
        case .viewer: return NCAgendaText.t("_nodrive_agenda_lock_viewer_")
        case .noChange: return NCAgendaEditText.t("_nodrive_agenda_edit_gantt_no_change_")
        case let .agentNotVisible(name): return NCAgendaEditText.f("_nodrive_agenda_edit_gantt_add_agent_", name)
        }
    }

    /// The registry agent of a planning person of mine (by id, or by the exact name next to my planning person on the task).
    static func agent(of resource: GanttResource, among agents: [RegistryAgent], personName: String, personOnTask: Bool) -> RegistryAgent? {
        agents.first { NCAgendaAgentLoad.isPlanningPerson(resource, of: $0, personName: personName, personOnTask: personOnTask) }
    }

    /// The planning person that stands for the chosen agent **in this project** (design 4.5, plan 3.4), in this order: the
    /// one already on the task, one that sits on another task of the project, one in the pool of the project's owner.
    /// A same-named person of another manager's pool is never taken: NoGantt would drop a row the manager can't see.
    static func planningPerson(of agent: RegistryAgent, context: GanttAgentContext, task: GanttTask?) -> GanttResource? {
        let mine = Set(context.resources.values.filter { $0.uid?.lowercased() == context.myUid.lowercased() }.map { $0.id })
        func found(on other: GanttTask) -> GanttResource? {
            let personOnTask = other.resources.contains { mine.contains($0.resourceId) }
            return other.resources.compactMap { context.resources[$0.resourceId] }
                .filter { NCAgendaAgentLoad.isPlanningPerson($0, of: agent, personName: context.myName, personOnTask: personOnTask) }
                .min { $0.id < $1.id }
        }
        if let task, let onTask = found(on: task) { return onTask }
        for other in context.projectTasks.sorted(by: { $0.id < $1.id }) where other.id != task?.id {
            if let onProject = found(on: other) { return onProject }
        }
        guard let owner = context.project?.ownerId.lowercased(), !owner.isEmpty else { return nil }
        return context.resources.values
            .filter { $0.ownerId?.lowercased() == owner
                && NCAgendaAgentLoad.isPlanningPerson($0, of: agent, personName: context.myName, personOnTask: true) }
            .min { $0.id < $1.id }
    }

    /// Can this agent be chosen on tasks of the project? Its planning person must belong to the project.
    static func isOffered(_ agent: RegistryAgent, context: GanttAgentContext, task: GanttTask? = nil) -> Bool {
        planningPerson(of: agent, context: context, task: task) != nil
    }

    /// The new list for "my agent" = `choice` (nil id: Self) on the fresh `task`.
    static func plan(task: GanttTask, choice: AgentChoice, context: GanttAgentContext) -> Plan {
        if let project = context.project, project.permission == "viewer" { return .refused(.viewer) }
        let old = task.resources
        let myIds = Set(context.resources.values.filter { $0.uid?.lowercased() == context.myUid.lowercased() }.map { $0.id })
        guard old.contains(where: { myIds.contains($0.resourceId) }) else { return .refused(.notOnTask) }
        // A row that is not visible to me would be dropped by the server without a word.
        guard old.allSatisfy({ context.resources[$0.resourceId] != nil }) else { return .refused(.hiddenRow) }

        var rows = old.filter { row in
            guard let resource = context.resources[row.resourceId] else { return true }
            // I am on this task (checked above), so a name match next to my planning person counts.
            return agent(of: resource, among: context.myAgents, personName: context.myName, personOnTask: true) == nil
        }
        if let id = choice.id {
            guard let registryAgent = context.myAgents.first(where: { $0.id == id }) else { return .refused(.agentNotVisible(name: choice.name)) }
            guard let planning = planningPerson(of: registryAgent, context: context, task: task) else { return .refused(.agentNotVisible(name: registryAgent.name)) }
            if !rows.contains(where: { $0.resourceId == planning.id }) {
                if context.project?.rolesOnly == true { return .refused(.rolesOnly) }
                rows.append(GanttResourceRow(resourceId: planning.id, work: nil))
            }
        }
        if rows.count > maxRows { return .refused(.tooMany) }
        // Nothing to do when the list stays as it is.
        if rows == old { return .refused(.noChange) }
        // The total work and the first row (the main person) must stay as they are.
        let oldWork = old.reduce(0.0) { $0 + ($1.work ?? 0) }
        let newWork = rows.reduce(0.0) { $0 + ($1.work ?? 0) }
        if abs(oldWork - newWork) > 0.0001 { return .refused(.workWouldChange) }
        if let first = old.first, rows.first?.resourceId != first.resourceId { return .refused(.firstWouldChange) }
        return .rows(rows)
    }

    /// The same list as the server answered: ids and work, in order.
    static func sameRows(_ first: [GanttResourceRow], _ second: [GanttResourceRow]) -> Bool {
        first.count == second.count && zip(first, second).allSatisfy { $0.resourceId == $1.resourceId && ($0.work ?? 0) == ($1.work ?? 0) }
    }
}
