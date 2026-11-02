// SPDX-FileCopyrightText: 2026 Nourax
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// The texts of the editing step (English; the table is `NoAgendaEdit`).
enum NCAgendaEditText {
    static func t(_ key: String) -> String {
        NSLocalizedString(key, tableName: "NoAgendaEdit", comment: "")
    }

    static func f(_ key: String, _ args: CVarArg...) -> String {
        String(format: t(key), arguments: args)
    }
}

extension AgendaHome {
    /// The product names are not translated.
    var productName: String {
        switch self {
        case .calendar: return "NoCalendar"
        case .tasks: return "NoTasks"
        case .gantt: return "NoGantt"
        case .board: return "NoBoard"
        }
    }
}

/// Who does an item, as a choice in the editor and as a written value. `id` nil is Self.
struct AgentChoice: Codable, Equatable, Identifiable, Sendable {
    var id: String?
    var name: String
    var calendarTag: String?
    var ganttResourceIds: [Int] = []
    var boardLabel: String?
    var status: AgentStatus = .active

    static let selfChoice = AgentChoice(id: nil, name: "Self")

    var isSelf: Bool { id == nil }

    var rowId: String { id ?? "SELF" }

    var title: String {
        isSelf ? "👤 " + NCAgendaText.t("_nodrive_agenda_self_") : "🤖 " + name
    }

    var ref: AgentRef {
        guard let id else { return .selfAgent }
        return .mine(id: id, name: name, status: status)
    }

    var calendarWrite: CalendarChange.AgentWrite {
        CalendarChange.AgentWrite(id: id, tag: calendarTag)
    }

    init(id: String?, name: String, calendarTag: String? = nil, ganttResourceIds: [Int] = [], boardLabel: String? = nil, status: AgentStatus = .active) {
        self.id = id
        self.name = name
        self.calendarTag = calendarTag
        self.ganttResourceIds = ganttResourceIds
        self.boardLabel = boardLabel
        self.status = status
    }

    init(_ agent: RegistryAgent) {
        self.init(id: agent.id, name: agent.name, calendarTag: agent.calendarTag, ganttResourceIds: agent.ganttResourceIds,
                  boardLabel: agent.boardLabel, status: agent.status)
    }
}

/// A change of a Gantt task (design 9): dates as days ("yyyy-MM-dd"; NoGantt keeps the time of day), % done, status, done.
struct GanttChange: Codable, Equatable, Sendable {
    var startDay: String?
    var endDay: String?
    var percent: Int?
    var status: String?
    var done: Bool?

    var isEmpty: Bool { startDay == nil && endDay == nil && percent == nil && status == nil && done == nil }

    func merged(with later: GanttChange) -> GanttChange {
        var result = self
        if let value = later.startDay { result.startDay = value }
        if let value = later.endDay { result.endDay = value }
        if let value = later.percent { result.percent = value }
        if let value = later.status { result.status = value }
        if let value = later.done { result.done = value }
        return result
    }
}

/// A change of a card (design 9): the due date, done.
struct DeckChange: Codable, Equatable, Sendable {
    var due: Date?
    var clearDue = false
    var done: Bool?

    var isEmpty: Bool { due == nil && !clearDue && done == nil }

    func merged(with later: DeckChange) -> DeckChange {
        var result = self
        if let value = later.due { result.due = value; result.clearDue = false }
        if later.clearDue { result.due = nil; result.clearDue = true }
        if let value = later.done { result.done = value }
        return result
    }
}

/// Why a command was not sent (it waits in "Not sent" until the person decides).
struct NCAgendaNotSent: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        /// The item changed somewhere else; the other change won.
        case changedElsewhere
        /// The server (or the rules) said no.
        case refused
    }

    var kind: Kind
    var text: String
}

/// One edit of the person, kept until it is sent. It holds the **meaning** of the change and the version of the item
/// the person saw, never a finished request: it is built again from the item as the server has it at send time.
struct NCAgendaEditCommand: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable {
        case calendarPatch, calendarCreate, calendarDelete, ganttUpdate, ganttAgent, deckUpdate, deckAgent
    }

    enum State: Codable, Equatable, Sendable {
        case waiting
        case notSent(NCAgendaNotSent)
    }

    var id: UUID
    var kind: Kind
    var createdAt: Date
    /// The item as the person saw it: its row key, title (kept on the device only), home and the version it had.
    var itemKey: String?
    var title: String
    /// The calendar, project or board it belongs to (a new item is drawn with its name and colour at once).
    var sourceKey: String?
    var link: AgendaLink
    var calendar: CalendarChange?
    var gantt: GanttChange?
    var deck: DeckChange?
    var agent: AgentChoice?
    /// calendarCreate: the path of the new object and its text; the component ("VEVENT" or "VTODO").
    var createPath: String?
    var createText: String?
    var component: String?
    var state: State = .waiting

    var isWaiting: Bool {
        if case .waiting = state { return true }
        return false
    }

    var notSent: NCAgendaNotSent? {
        if case let .notSent(reason) = state { return reason }
        return nil
    }

    var home: AgendaHome { link.home }

    /// Which commands can be folded into one: the same item, the same kind of change.
    func canFold(_ later: NCAgendaEditCommand) -> Bool {
        guard isWaiting, later.isWaiting, kind == later.kind, itemKey != nil, itemKey == later.itemKey else { return false }
        switch kind {
        case .calendarPatch, .ganttUpdate, .ganttAgent, .deckUpdate, .deckAgent: return true
        case .calendarCreate, .calendarDelete: return false
        }
    }

    /// The second change laid over this one. The version the person saw stays the first one.
    func folded(_ later: NCAgendaEditCommand) -> NCAgendaEditCommand {
        var result = self
        switch kind {
        case .calendarPatch:
            if let change = later.calendar { result.calendar = (calendar ?? CalendarChange()).merged(with: change) }
        case .ganttUpdate:
            if let change = later.gantt { result.gantt = (gantt ?? GanttChange()).merged(with: change) }
        case .deckUpdate:
            if let change = later.deck { result.deck = (deck ?? DeckChange()).merged(with: change) }
        case .ganttAgent, .deckAgent:
            result.agent = later.agent
        case .calendarCreate, .calendarDelete:
            break
        }
        return result
    }

    /// A short, plain description of what the command does, for the "Not sent" list.
    var summary: String {
        switch kind {
        case .calendarPatch, .ganttUpdate, .deckUpdate: return NCAgendaEditText.t("_nodrive_agenda_edit_sum_change_")
        case .calendarCreate: return component == "VTODO" ? NCAgendaEditText.t("_nodrive_agenda_edit_sum_new_todo_") : NCAgendaEditText.t("_nodrive_agenda_edit_sum_new_event_")
        case .calendarDelete: return NCAgendaEditText.t("_nodrive_agenda_edit_sum_delete_")
        case .ganttAgent, .deckAgent: return NCAgendaEditText.f("_nodrive_agenda_edit_sum_agent_", agent?.title ?? "")
        }
    }
}

/// What came of sending one command.
struct NCAgendaSaved: Equatable, Sendable {
    /// NoGantt: the dates it saved, "yyyy-MM-dd HH:mm:ss" as the server wrote them.
    var savedStart: String?
    var savedEnd: String?
    /// NoGantt moved these tasks too (names).
    var alsoMoved: [String] = []
    /// The id of the change at NoGantt, for Undo.
    var opId: String?
    var datesAdjusted = false
    /// The version the item has now, when the answer said (NoGantt `updated_at`, Deck `lastModified`). A change of the same
    /// Save that still waits expects this one, not the version the person saw (the queue passes it on).
    var newUpdatedAt: String?
    var newLastModified: Int?
}

enum NCAgendaWriteOutcome: Equatable, Sendable {
    case saved(NCAgendaSaved)
    /// The item changed in the meantime: the other change wins, nothing was written.
    case conflict
    /// The server or a rule said no, in plain words.
    case refused(String)
    /// A 5xx: try again.
    case serverError
    /// No network.
    case offline

    static var plainSaved: NCAgendaWriteOutcome { .saved(NCAgendaSaved()) }
}

enum NCAgendaWriteTexts {
    static func refused(status: Int) -> String {
        switch status {
        case 401, 403: return NCAgendaEditText.t("_nodrive_agenda_edit_refused_forbidden_")
        case 423: return NCAgendaEditText.t("_nodrive_agenda_edit_refused_locked_")
        default: return NCAgendaEditText.f("_nodrive_agenda_edit_refused_generic_", status)
        }
    }

    static func notSent(for outcome: NCAgendaWriteOutcome) -> NCAgendaNotSent? {
        switch outcome {
        case .conflict:
            return NCAgendaNotSent(kind: .changedElsewhere, text: NCAgendaEditText.t("_nodrive_agenda_edit_conflict_"))
        case let .refused(text):
            return NCAgendaNotSent(kind: .refused, text: text)
        case .serverError:
            return NCAgendaNotSent(kind: .refused, text: NCAgendaEditText.t("_nodrive_agenda_edit_server_error_"))
        case .saved, .offline:
            return nil
        }
    }
}
