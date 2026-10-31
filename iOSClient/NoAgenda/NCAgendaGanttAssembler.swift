// SPDX-FileCopyrightText: 2026 Nourax
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

// NoGantt rows, the agent rules of design 4.2 and 4.5, the integrity flags of 4.4 and the team problems of 6.3.

extension NCAgendaAssembler {
    // MARK: Dates

    /// NoGantt stores wall times without a zone ("Y-m-d H:i:s", sometimes only the date), in its own time zone.
    static func ganttDate(_ text: String?, zone: TimeZone) -> Date? {
        guard let text, !text.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        for format in ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ssZZZZZ", "yyyy-MM-dd"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }

    /// NFC, trimmed: the exact-name rule of design 4.5 (b).
    static func normalised(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Recognising planning people

    func linkedPersons(_ task: GanttTask, _ resources: [Int: GanttResource]) -> [GanttResource] {
        task.resources.compactMap { resources[$0.resourceId] }.filter { $0.type == "person" && $0.uid != nil }
    }

    /// An agent's planning person: by the registry id, or (placeholder phase) by the exact name next to its person.
    func agentOf(resource: GanttResource, among agents: [RegistryAgent], personName: String?, personOnTask: Bool) -> RegistryAgent? {
        guard resource.type == "person", resource.uid == nil else { return nil }
        if let byId = agents.first(where: { $0.ganttResourceIds.contains(resource.id) }) { return byId }
        guard personOnTask, let personName else { return nil }
        return agents.first { Self.normalised(resource.name) == Self.normalised("🤖 \($0.name) (\(personName))") }
    }

    /// The agents of `uid` on this task (design 4.5).
    func agentsOnTask(_ task: GanttTask, of uid: String, resources: [Int: GanttResource], persons: [GanttResource]) -> [RegistryAgent] {
        let agents = input.registry?.agents(of: uid) ?? []
        guard !agents.isEmpty else { return [] }
        let onTask = persons.contains { $0.uid?.lowercased() == uid.lowercased() }
        let name = displayName(of: uid)
        var found: [RegistryAgent] = []
        for row in task.resources {
            guard let resource = resources[row.resourceId],
                  let agent = agentOf(resource: resource, among: agents, personName: name, personOnTask: onTask),
                  !found.contains(where: { $0.id == agent.id }) else { continue }
            found.append(agent)
        }
        return found
    }

    /// Every unlinked planning person on the task that is recognised as some registered agent.
    func recognisedAgentResources(_ task: GanttTask, resources: [Int: GanttResource], persons: [GanttResource]) -> [(GanttResource, RegistryAgent)] {
        guard let registry = input.registry else { return [] }
        var result: [(GanttResource, RegistryAgent)] = []
        for row in task.resources {
            guard let resource = resources[row.resourceId], resource.type == "person", resource.uid == nil else { continue }
            for agent in registry.agents {
                let onTask = persons.contains { $0.uid?.lowercased() == agent.person }
                if agentOf(resource: resource, among: [agent], personName: displayName(of: agent.person), personOnTask: onTask) != nil {
                    result.append((resource, agent))
                    break
                }
            }
        }
        return result
    }

    // MARK: Build

    mutating func buildGantt() {
        guard let gantt = input.gantt else { return }
        let zone = gantt.timezone.flatMap { TimeZone(identifier: $0) } ?? input.calendar.timeZone
        let resources = Dictionary(gantt.resources.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let myResourceIds = Set(gantt.resources.filter { $0.uid?.lowercased() == myUid }.map { $0.id })
        let mineByProject = Set(gantt.myTasks.map { $0.projectId })
        var myFindingsHandled = Set<String>()

        for project in gantt.projects {
            let setting = NCAgendaSources.projectSetting(project, hasMyTasks: mineByProject.contains(project.id), settings: input.settings,
                                                         userId: input.me.userId, groups: input.me.groups, shares: gantt.shares[String(project.id)])
            var source = AgendaSource(key: NCAgendaSources.projectKey(project.id), kind: .project, name: project.title,
                                      color: NCAgendaColors.mapped(project.color), setting: setting)
            if project.permission == "viewer" { source.note = NCAgendaText.t("_nodrive_agenda_project_viewer_note_") }
            sources.append(source)
            guard setting != .hidden else { continue }

            let key = String(project.id)
            let tasks = gantt.tasks[key] ?? []
            let phases = Dictionary((gantt.subprojects[key] ?? []).map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
            let color = source.color
            let milestoneById = Dictionary((gantt.milestones[key] ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let taskById = Dictionary(tasks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

            func predecessorTitle(_ id: String) -> String {
                if id.hasPrefix("t-"), let number = Int(id.dropFirst(2)), let task = taskById[number] { return task.title }
                if id.hasPrefix("m-"), let number = Int(id.dropFirst(2)), let milestone = milestoneById[number] { return milestone.title }
                return id
            }
            func predecessorIsLate(_ id: String) -> Bool {
                guard id.hasPrefix("t-"), let number = Int(id.dropFirst(2)), let task = taskById[number] else { return false }
                let end = Self.ganttDate(task.end, zone: zone)
                return isLate(end: end, done: task.status == "done")
            }

            for task in tasks where task.status != "done" {
                let persons = linkedPersons(task, resources)
                let end = Self.ganttDate(task.end, zone: zone)
                let start = Self.ganttDate(task.start, zone: zone)
                let iAmOnTask = persons.contains { $0.uid?.lowercased() == myUid }
                let late = isLate(end: end, done: false)
                let blocked = task.dependencies.contains { predecessorIsLate($0.predecessorId) }
                let recognised = recognisedAgentResources(task, resources: resources, persons: persons)

                func base(key rowKey: String, relation: AgendaRelation, personName: String?, agent: AgentRef, flags: [IntegrityFlag]) -> AgendaItem {
                    var item = AgendaItem(
                        key: rowKey, home: .gantt, kind: .ganttTask, title: task.title,
                        sourceKey: NCAgendaSources.projectKey(project.id), sourceName: project.title, sourceColor: color,
                        link: AgendaLink(home: .gantt, projectId: project.id, taskId: task.id, updatedAt: task.updatedAt, deckCardId: task.deckCardId))
                    item.start = start
                    item.end = end
                    item.percent = task.progress
                    item.relation = relation
                    item.personName = personName
                    item.agent = agent
                    item.flags = flags
                    item.projectName = project.title
                    item.phase = task.subprojectId.flatMap { phases[$0] }
                    item.status = task.status
                    item.late = late
                    item.blocked = blocked
                    item.boardBadge = task.deckCardId != nil
                    item.dependencies = task.dependencies.map {
                        AgendaDependency(predecessorKey: $0.predecessorId, predecessorTitle: predecessorTitle($0.predecessorId), type: $0.type, lagDays: $0.lagDays)
                    }
                    if project.permission == "viewer" {
                        item.lock = .viewerProject
                    } else if !gantt.contractOK {
                        item.lock = .guardReadOnly
                    }
                    return item
                }

                // My row.
                if iAmOnTask, mineByProject.contains(project.id) || setting == .doOversee {
                    let mine = agentsOnTask(task, of: input.me.userId, resources: resources, persons: persons)
                    var flags: [IntegrityFlag] = []
                    var agent: AgentRef = .selfAgent
                    if let first = mine.first {
                        agent = ref(first)
                        flags += agentFlags(first)
                    }
                    if mine.count > 1 {
                        flags.append(IntegrityFlag(kind: .twoAgents, audience: .both, names: [input.me.displayName]))
                    }
                    var item = base(key: "gantt:\(task.id)", relation: .mine, personName: nil, agent: agent, flags: flags)
                    item.workShare = task.resources.first { myResourceIds.contains($0.resourceId) }?.work
                    items.append(item)
                    if let card = task.deckCardId { cardIdsOfGanttTasks.insert(card) }
                    if mine.count > 1 {
                        problems.append(AgendaProblem(key: "mine:two:\(task.id)", kind: .flag, relation: .mine, title: task.title,
                                                      text: flags.last?.text ?? "", link: item.link, home: .gantt))
                    }
                }

                // Mine: an agent of mine on a task I'm not on (design 4.4: "agent with no person").
                if !iAmOnTask {
                    for (_, agent) in recognised where agent.person == myUid {
                        let flag = IntegrityFlag(kind: .agentWithoutPerson, audience: .person, names: [agent.name, task.title])
                        problems.append(AgendaProblem(key: "mine:orphan:\(task.id):\(agent.id)", kind: .flag, relation: .mine, title: task.title,
                                                      text: flag.text, link: AgendaLink(home: .gantt, projectId: project.id, taskId: task.id), home: .gantt))
                    }
                }

                // Team rows and problems: only in projects I run.
                guard setting == .doOversee else { continue }
                var teamFlags: [IntegrityFlag] = []
                for (resource, agent) in recognised {
                    let personOnTask = persons.contains { $0.uid?.lowercased() == agent.person }
                    if personOnTask { continue }
                    // Design 4.1: the sentence names the agent only when its organisation is one of mine.
                    if persons.isEmpty {
                        teamFlags.append(IntegrityFlag(kind: .agentWithoutPerson, audience: .manager, names: [otherLabel(agent), task.title]))
                    } else {
                        let owner = displayName(of: agent.person) ?? NCAgendaText.t("_nodrive_agenda_someone_")
                        // The people the agent is actually paired with on this task.
                        let paired = persons.map { $0.uidDisplayName ?? displayName(of: $0.uid ?? "") ?? NCAgendaText.t("_nodrive_agenda_someone_") }
                            .joined(separator: ", ")
                        teamFlags.append(IntegrityFlag(kind: .agentOfOtherPerson, audience: .manager, names: [otherLabel(agent), owner, paired]))
                    }
                    _ = resource
                }
                let recognisedIds = Set(recognised.map { $0.0.id })
                for row in task.resources {
                    guard let resource = resources[row.resourceId] else { continue }
                    if resource.type == "person", resource.uid == nil, !recognisedIds.contains(resource.id) {
                        if resource.name.hasPrefix("🤖") {
                            // Design 4.5: a robot name that is not recognised is an unknown agent, never guessed.
                            let label = resource.name.dropFirst(1).trimmingCharacters(in: .whitespaces)
                            teamFlags.append(IntegrityFlag(kind: .unknownAgent, audience: .manager, names: [label]))
                        } else {
                            teamFlags.append(IntegrityFlag(kind: .notLinked, audience: .manager, names: [resource.name]))
                        }
                    }
                }
                let resourceTypes = task.resources.compactMap { resources[$0.resourceId]?.type }
                if !resourceTypes.isEmpty, !resourceTypes.contains("person") {
                    teamFlags.append(IntegrityFlag(kind: .notAssigned, audience: .manager))
                }

                let others = persons.filter { $0.uid?.lowercased() != myUid }
                var teamRows: [AgendaItem] = []
                for person in others {
                    guard let uid = person.uid?.lowercased() else { continue }
                    let personName = person.uidDisplayName ?? displayName(of: uid) ?? person.name
                    let theirs = agentsOnTask(task, of: uid, resources: resources, persons: persons)
                    var flags = teamFlags
                    var agent: AgentRef = .selfAgent
                    if let first = theirs.first { agent = .other(label: otherLabel(first)) }
                    if theirs.count > 1 { flags.append(IntegrityFlag(kind: .twoAgents, audience: .both, names: [personName])) }
                    teamRows.append(base(key: "gantt:\(task.id):team:\(uid)", relation: .team, personName: personName, agent: agent, flags: flags))
                }
                if others.isEmpty, !teamFlags.isEmpty {
                    // No other person's row carries the flags: a row of their own, or, when I'm on the task, only the problems.
                    let flagRow = base(key: "gantt:\(task.id):team", relation: .team, personName: nil, agent: .selfAgent, flags: teamFlags)
                    if iAmOnTask {
                        problems += flagProblems(for: flagRow)
                    } else {
                        teamRows.append(flagRow)
                    }
                }
                for row in teamRows {
                    items.append(row)
                    problems += teamProblems(for: row)
                    if let card = task.deckCardId { cardIdsOfGanttTasks.insert(card) }
                }
            }

            // Milestones of projects where I have tasks (the diamond rows).
            if mineByProject.contains(project.id) {
                for milestone in gantt.milestones[key] ?? [] {
                    guard let date = Self.ganttDate(milestone.date, zone: zone) else { continue }
                    var item = AgendaItem(
                        key: "milestone:\(milestone.id)", home: .gantt, kind: .milestone, title: milestone.title,
                        sourceKey: NCAgendaSources.projectKey(project.id), sourceName: project.title, sourceColor: color,
                        link: AgendaLink(home: .gantt, projectId: project.id, taskId: milestone.taskId))
                    item.start = date
                    item.end = date
                    item.projectName = project.title
                    item.late = isLate(end: date, done: false)
                    items.append(item)
                }
            }

            // Not shared: a linked person on tasks of a project whose shares don't include them.
            if setting == .doOversee, let shares = gantt.shares[key], !shares.isEmpty {
                let onlyUsers = shares.allSatisfy { $0.type.lowercased() == "user" || $0.type == "0" }
                if onlyUsers {
                    let shared = Set(shares.map { $0.with.lowercased() })
                    var counts: [String: Int] = [:]
                    for task in tasks where task.status != "done" {
                        for person in linkedPersons(task, resources) {
                            guard let uid = person.uid?.lowercased(), uid != project.ownerId.lowercased(), !shared.contains(uid) else { continue }
                            counts[uid, default: 0] += 1
                        }
                    }
                    for (uid, count) in counts.sorted(by: { $0.key < $1.key }) {
                        let name = displayName(of: uid) ?? NCAgendaText.t("_nodrive_agenda_someone_")
                        let flag = IntegrityFlag(kind: .notShared, audience: .manager, names: [name], count: count)
                        problems.append(AgendaProblem(key: "team:notShared:\(project.id):\(uid)", kind: .flag, relation: .team, title: project.title,
                                                      personName: name, text: "⚠ " + flag.text, link: AgendaLink(home: .gantt, projectId: project.id), home: .gantt))
                    }
                }
            }

            // Overbooked people (NoGantt's own capacity check).
            if setting == .doOversee {
                for finding in gantt.findings["all"] ?? [] {
                    for personId in finding.personIds {
                        guard let person = resources[personId], let uid = person.uid?.lowercased(), uid != myUid else { continue }
                        let handled = "\(uid)|\(finding.start ?? "")"
                        guard myFindingsHandled.insert(handled).inserted else { continue }
                        let name = person.uidDisplayName ?? person.name
                        problems.append(AgendaProblem(key: "team:over:\(uid):\(finding.start ?? "")", kind: .overbooked, relation: .team,
                                                      title: name, personName: name,
                                                      text: "⚠ " + NCAgendaText.f("_nodrive_agenda_overbooked_", name),
                                                      date: Self.ganttDate(finding.start, zone: zone),
                                                      link: AgendaLink(home: .gantt, projectId: project.id), home: .gantt))
                    }
                }
            }
        }
    }

    // MARK: Team problems (design 6.3)

    /// "⏰ Banner design: Sara · 🤖 Design-Bot, 2 days late"
    func teamProblems(for row: AgendaItem) -> [AgendaProblem] {
        var result: [AgendaProblem] = []
        let who: String = {
            var text = row.personName ?? ""
            if !row.agent.isSelf { text += (text.isEmpty ? "" : " · ") + row.agent.displayText }
            return text
        }()
        func make(_ kind: AgendaProblem.Kind, _ icon: String, _ detail: String, days: Int = 0, date: Date? = nil) -> AgendaProblem {
            let lead = who.isEmpty ? row.title : "\(row.title): \(who)"
            return AgendaProblem(key: "team:\(kind.rawValue):\(row.key)", kind: kind, relation: .team, title: row.title, personName: row.personName,
                                 agentText: row.agent.isSelf ? nil : row.agent.displayText, days: days,
                                 text: "\(icon) \(lead), \(detail)", date: date, link: row.link, home: row.home)
        }
        let finish = row.end ?? row.due
        if row.late, let finish {
            let days = daysLate(finish)
            let detail = days == 1 ? NCAgendaText.t("_nodrive_agenda_day_late_") : NCAgendaText.f("_nodrive_agenda_days_late_", days)
            result.append(make(.late, "⏰", detail, days: days, date: finish))
        } else if let finish, input.calendar.isDate(finish, inSameDayAs: input.now) {
            result.append(make(.dueToday, "📅", NCAgendaText.t("_nodrive_agenda_due_today_lower_"), date: finish))
        }
        if row.blocked {
            result.append(make(.blocked, "⛔", NCAgendaText.t("_nodrive_agenda_blocked_by_late_")))
        }
        result += flagProblems(for: row)
        return result
    }

    /// The flags of a row that are for the manager (design 4.4), as problems.
    func flagProblems(for row: AgendaItem) -> [AgendaProblem] {
        flagProblems(row.flags, title: row.title, personName: row.personName, link: row.link, home: row.home, rowKey: row.key)
    }

    func flagProblems(_ flags: [IntegrityFlag], title: String, personName: String?, link: AgendaLink?, home: AgendaHome, rowKey: String) -> [AgendaProblem] {
        flags.filter { $0.audience != .person }.map { flag in
            AgendaProblem(key: "team:flag:\(flag.kind.rawValue):\(rowKey)", kind: .flag, relation: .team, title: title,
                          personName: personName, text: "⚠ \(title): \(flag.text)", link: link, home: home)
        }
    }
}
