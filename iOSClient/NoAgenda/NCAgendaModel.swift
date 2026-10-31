// SPDX-FileCopyrightText: 2026 Nourax
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// The texts of NoAgenda (English; the table is `NoAgenda`).
enum NCAgendaText {
    static func t(_ key: String) -> String {
        NSLocalizedString(key, tableName: "NoAgenda", comment: "")
    }

    static func f(_ key: String, _ args: CVarArg...) -> String {
        String(format: t(key), arguments: args)
    }
}

/// The app an item lives in (design section 3: "home").
enum AgendaHome: String, Codable, Sendable {
    case calendar, tasks, gantt, board

    /// "Open in NoCalendar" and the others.
    var openTitle: String {
        switch self {
        case .calendar: return NCAgendaText.t("_nodrive_agenda_open_calendar_")
        case .tasks: return NCAgendaText.t("_nodrive_agenda_open_tasks_")
        case .gantt: return NCAgendaText.t("_nodrive_agenda_open_gantt_")
        case .board: return NCAgendaText.t("_nodrive_agenda_open_board_")
        }
    }
}

enum AgendaKind: String, Codable, Sendable {
    case event, todo, ganttTask, milestone, card

    var symbolName: String {
        switch self {
        case .event: return "calendar"
        case .todo: return "checklist"
        case .ganttTask: return "chart.bar.xaxis"
        case .milestone: return "diamond.fill"
        case .card: return "rectangle.split.3x1"
        }
    }

    var spokenName: String {
        switch self {
        case .event: return NCAgendaText.t("_nodrive_agenda_kind_event_")
        case .todo: return NCAgendaText.t("_nodrive_agenda_kind_todo_")
        case .ganttTask: return NCAgendaText.t("_nodrive_agenda_kind_task_")
        case .milestone: return NCAgendaText.t("_nodrive_agenda_kind_milestone_")
        case .card: return NCAgendaText.t("_nodrive_agenda_kind_card_")
        }
    }
}

enum AgentStatus: String, Codable, Sendable {
    case active, paused, retired
}

/// Who does an item (design 4.2): the person by hand ("Self"), one of the person's agents, someone else's agent.
enum AgentRef: Codable, Equatable, Sendable {
    case selfAgent
    case mine(id: String, name: String, status: AgentStatus)
    /// An agent of another person; the text is already privacy-checked ("Writer-Bot" or "Agent of Sara").
    case other(label: String)
    /// An id or label that is not in the registry (design 4.1).
    case unknown(label: String)

    var isSelf: Bool {
        if case .selfAgent = self { return true }
        return false
    }

    var isMine: Bool {
        if case .mine = self { return true }
        return false
    }

    /// "Self", "Writer-Bot", "Design-Bot (retired)", "AG-0009 (unknown agent)" with the emoji mark in front.
    var displayText: String {
        switch self {
        case .selfAgent:
            return "👤 " + NCAgendaText.t("_nodrive_agenda_self_")
        case let .mine(_, name, status):
            return status == .retired ? "🤖 " + NCAgendaText.f("_nodrive_agenda_retired_", name) : "🤖 " + name
        case let .other(label):
            return "🤖 " + label
        case let .unknown(label):
            return "🤖 " + NCAgendaText.f("_nodrive_agenda_unknown_agent_", label)
        }
    }

    var isPaused: Bool {
        if case let .mine(_, _, status) = self { return status == .paused }
        return false
    }
}

/// One problem of design 4.4, as data. The sentence is made on demand (it follows the language).
struct IntegrityFlag: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case agentWithoutPerson, agentOfOtherPerson, twoAgents, unknownAgent, retiredAgent
        case notLinked, notAssigned, notShared
    }

    enum Audience: String, Codable, Sendable {
        case person, manager, both
    }

    var kind: Kind
    var audience: Audience
    /// Agent name, person name and so on, in the order the sentence uses them.
    var names: [String] = []
    var count: Int = 0

    var text: String {
        let first = names.first ?? ""
        switch kind {
        case .agentWithoutPerson:
            let task = names.count > 1 ? names[1] : ""
            return audience == .person
                ? NCAgendaText.f("_nodrive_agenda_flag_agent_no_person_", first, task)
                : NCAgendaText.f("_nodrive_agenda_flag_agent_no_person_team_", first, task)
        case .agentOfOtherPerson:
            let owner = names.count > 1 ? names[1] : ""
            let other = names.count > 2 ? names[2] : ""
            return NCAgendaText.f("_nodrive_agenda_flag_agent_belongs_", first, owner, other)
        case .twoAgents:
            return NCAgendaText.f("_nodrive_agenda_flag_two_agents_", first)
        case .unknownAgent:
            return NCAgendaText.f("_nodrive_agenda_unknown_agent_", first)
        case .retiredAgent:
            return NCAgendaText.f("_nodrive_agenda_retired_", first)
        case .notLinked:
            return NCAgendaText.t("_nodrive_agenda_flag_not_linked_")
        case .notAssigned:
            return NCAgendaText.t("_nodrive_agenda_flag_not_assigned_")
        case .notShared:
            return count == 1
                ? NCAgendaText.f("_nodrive_agenda_flag_not_shared_one_", first)
                : NCAgendaText.f("_nodrive_agenda_flag_not_shared_", first, count)
        }
    }
}

enum LockReason: String, Codable, Sendable {
    case readOnlyCalendar, viewerProject, guardReadOnly, repeating
}

/// How a calendar, list, project or board is used (design 6.1).
enum SourceSetting: String, Codable, Sendable, CaseIterable {
    case personal, work, team, info, hidden       // calendars and lists
    case doIt, doOversee                          // projects and boards ("Do", "Do + Oversee")

    var title: String {
        switch self {
        case .personal: return NCAgendaText.t("_nodrive_agenda_personal_")
        case .work: return NCAgendaText.t("_nodrive_agenda_work_")
        case .team: return NCAgendaText.t("_nodrive_agenda_setting_team_")
        case .info: return NCAgendaText.t("_nodrive_agenda_setting_info_")
        case .hidden: return NCAgendaText.t("_nodrive_agenda_setting_hidden_")
        case .doIt: return NCAgendaText.t("_nodrive_agenda_setting_do_")
        case .doOversee: return NCAgendaText.t("_nodrive_agenda_setting_do_oversee_")
        }
    }
}

enum AgendaSourceKind: String, Codable, Sendable {
    case calendar, list, project, board
}

/// What a source is, for the Sources screen.
struct AgendaSource: Codable, Equatable, Identifiable, Sendable {
    var key: String
    var kind: AgendaSourceKind
    var name: String
    /// The colour as shown (already mapped, "#RRGGBB").
    var color: String
    var setting: SourceSetting
    /// Why the setting can't be changed, in words; nil when it can.
    var lockedReason: String?
    var isNew: Bool = false
    var note: String?
    var id: String { key }
}

/// Which view-filter group an item belongs to (design 6.0 "All / Work / Personal").
enum AgendaScope: String, Codable, Sendable {
    case personal, work, info
}

enum AgendaRelation: String, Codable, Sendable {
    case mine, team
}

struct AgendaDependency: Codable, Equatable, Sendable {
    var predecessorKey: String
    var predecessorTitle: String
    var type: String
    var lagDays: Int
}

/// What is needed to open the item's page and (later) to write to it.
struct AgendaLink: Codable, Equatable, Sendable {
    var home: AgendaHome
    var path: String?          // CalDAV object path
    var calendarUri: String?
    var fileName: String?
    var recurrence: Date?
    var etag: String?
    var projectId: Int?
    var taskId: Int?
    var updatedAt: String?
    var boardId: Int?
    var stackId: Int?
    var cardId: Int?
    var lastModified: Int?
    var deckCardId: Int?
}

/// A row of the Day, Week and Month lists. Everything a row, the detail sheet and (later) an edit need.
struct AgendaItem: Codable, Equatable, Identifiable, Sendable {
    var key: String
    var home: AgendaHome
    var kind: AgendaKind
    var title: String
    var start: Date?
    var end: Date?
    var allDay: Bool = false
    var due: Date?
    var done: Bool = false
    var percent: Int?
    var sourceKey: String
    var sourceName: String
    var sourceColor: String
    var scope: AgendaScope = .work
    var relation: AgendaRelation = .mine
    var agent: AgentRef = .selfAgent
    /// The person of a team row.
    var personName: String?
    /// My own hours on a Gantt task.
    var workShare: Double?
    var transparent: Bool = false
    var partstat: String?
    var iAmOrganiser: Bool = false
    var invited: Bool = false
    var repeating: Bool = false
    var projectName: String?
    var phase: String?
    var status: String?
    var dependencies: [AgendaDependency] = []
    var late: Bool = false
    var blocked: Bool = false
    var boardBadge: Bool = false
    var flags: [IntegrityFlag] = []
    var lock: LockReason?
    var timeZoneNote: String?
    var link: AgendaLink
    var id: String { key }
}

/// A problem row: "Problems with your agents" (mine) and "My team".
struct AgendaProblem: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable {
        case late, dueToday, blocked, overbooked, flag
    }

    var key: String
    var kind: Kind
    var relation: AgendaRelation
    var title: String
    var personName: String?
    var agentText: String?
    var days: Int = 0
    var text: String
    var date: Date?
    var link: AgendaLink?
    var home: AgendaHome
    var id: String { key }
}

struct AgendaAgentInfo: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var status: AgentStatus
    var organisation: String
}

/// The result of a refresh, ready to show.
struct AgendaSnapshot: Equatable, Sendable {
    var items: [AgendaItem] = []
    var problems: [AgendaProblem] = []
    var sources: [AgendaSource] = []
    var agents: [AgendaAgentInfo] = []
    var notLinked = false
}

/// The chips and the switch of the header (design 6.0, 8).
struct AgendaFilter: Codable, Equatable, Sendable {
    enum Scope: String, Codable, Sendable, CaseIterable {
        case all, work, personal
    }

    var me = true
    var agents = true
    var team = true
    var scope: Scope = .all

    func allows(_ item: AgendaItem) -> Bool {
        let kindOK: Bool
        if item.relation == .team {
            kindOK = team
        } else if item.agent.isSelf {
            kindOK = me
        } else {
            kindOK = agents
        }
        guard kindOK else { return false }
        switch scope {
        case .all: return true
        case .work: return item.scope == .work
        case .personal: return item.scope == .personal
        }
    }

    /// Problems follow the chips of their kind (own-agent problems the agent chip, team problems the team chip).
    func allows(_ problem: AgendaProblem) -> Bool {
        problem.relation == .team ? team : agents
    }
}

/// Per account settings, on the device (design 6.1).
struct AgendaSettings: Codable, Equatable, Sendable {
    /// sourceKey -> setting, only what the person or the question chose.
    var chosen: [String: SourceSetting] = [:]
    var personalQuestionAnswered = false
    var knownOwnCalendars: [String] = []
    var filter = AgendaFilter()
    var view: String = "day"
    var openedOnce = false
    /// 0 = Monday ... 6 = Sunday; the working pattern when NoGantt gives none.
    var workDays: [Int] = [0, 1, 2, 3, 4]
    var workStartMinutes = 9 * 60
    var workEndMinutes = 17 * 60
}
