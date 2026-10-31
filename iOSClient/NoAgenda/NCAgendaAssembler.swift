// SPDX-FileCopyrightText: 2026 Nourax
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

struct AgendaMe: Codable, Equatable, Sendable {
    var userId: String
    var displayName: String
    /// Lower-case addresses of the person (the CalDAV principal's address set, and the e-mail address).
    var addresses: [String] = []
    var groups: [String] = []
}

/// Everything the rules need. The assembler is a plain function of this value: no network, no disk.
struct AgendaInputs {
    var me: AgendaMe
    var calendars: [RawCalendar] = []
    var gantt: RawGantt?
    var deck: RawDeck?
    var registry: NCAgendaRegistry?
    var settings = AgendaSettings()
    var now = Date()
    var calendar = Calendar.current
}

/// Builds the rows of the Day, Week and Month lists, the problems and the Sources from what the readers saw
/// (design sections 4, 6 and 7).
struct NCAgendaAssembler {
    let input: AgendaInputs
    var items: [AgendaItem] = []
    var problems: [AgendaProblem] = []
    var sources: [AgendaSource] = []
    /// Cards that a Gantt task already shows (one row, design 6.2).
    var cardIdsOfGanttTasks: Set<Int> = []

    let myUid: String
    let myAgents: [RegistryAgent]
    let myOrganisations: Set<String>
    private(set) var names: [String: String] = [:]

    init(_ input: AgendaInputs) {
        self.input = input
        myUid = input.me.userId.lowercased()
        myAgents = input.registry?.agents(of: input.me.userId) ?? []
        myOrganisations = input.registry?.organisations(of: input.me.userId) ?? []
        names[myUid] = input.me.displayName
        for resource in input.gantt?.resources ?? [] {
            if let uid = resource.uid, let name = resource.uidDisplayName, !name.isEmpty { names[uid.lowercased()] = name }
        }
        for board in input.deck?.boards ?? [] {
            if let owner = board.owner { names[owner.uid.lowercased()] = names[owner.uid.lowercased()] ?? owner.name }
        }
        for cards in (input.deck?.cards ?? [:]).values {
            for card in cards {
                for person in card.assigned { names[person.uid.lowercased()] = names[person.uid.lowercased()] ?? person.name }
            }
        }
    }

    static func assemble(_ input: AgendaInputs) -> AgendaSnapshot {
        var assembler = NCAgendaAssembler(input)
        assembler.buildGantt()
        assembler.buildCalendars()
        assembler.buildBoards()
        assembler.dedupe()
        var snapshot = AgendaSnapshot()
        snapshot.items = assembler.items
        snapshot.problems = assembler.problems
        snapshot.sources = assembler.sources
        snapshot.notLinked = input.gantt.map { !$0.linked && $0.contractOK } ?? false
        snapshot.agents = assembler.myAgents.map { AgendaAgentInfo(id: $0.id, name: $0.name, status: $0.status, organisation: $0.organisation) }
        return snapshot
    }

    // MARK: Helpers

    func displayName(of uid: String) -> String? {
        names[uid.lowercased()]
    }

    func ref(_ agent: RegistryAgent) -> AgentRef {
        .mine(id: agent.id, name: agent.name, status: agent.status)
    }

    /// Design 4.1: another person's agent is named only when its organisation is one of mine.
    func otherLabel(_ agent: RegistryAgent) -> String {
        if myOrganisations.contains(agent.organisation) { return agent.name }
        if let person = displayName(of: agent.person) { return NCAgendaText.f("_nodrive_agenda_agent_of_", person) }
        return NCAgendaText.t("_nodrive_agenda_other_org_agent_")
    }

    /// Flags a person sees about one of their own agents (design 4.4).
    func agentFlags(_ agent: RegistryAgent) -> [IntegrityFlag] {
        agent.status == .retired ? [IntegrityFlag(kind: .retiredAgent, audience: .person, names: [agent.name])] : []
    }

    func scope(of setting: SourceSetting) -> AgendaScope {
        switch setting {
        case .personal: return .personal
        case .info: return .info
        default: return .work
        }
    }

    func startOfToday() -> Date {
        input.calendar.startOfDay(for: input.now)
    }

    func isLate(end: Date?, done: Bool) -> Bool {
        guard !done, let end else { return false }
        return input.calendar.startOfDay(for: end) < startOfToday()
    }

    func daysLate(_ end: Date) -> Int {
        max(1, input.calendar.dateComponents([.day], from: input.calendar.startOfDay(for: end), to: startOfToday()).day ?? 1)
    }

    // MARK: Calendars and lists (NoCalendar, NoTasks)

    struct CalendarClass {
        var setting: SourceSetting
        var locked: String?
        var note: String?
        var isNew = false
        var isOwn = true
    }

    func classify(_ calendar: RawCalendar) -> CalendarClass {
        let key = NCAgendaSources.calendarKey(calendar.uri)
        let chosen = input.settings.chosen[key]
        if calendar.isAppGenerated {
            return CalendarClass(setting: .hidden, locked: NCAgendaText.t("_nodrive_agenda_locked_board_calendar_"), isOwn: false)
        }
        if let gantt = input.gantt, gantt.copyEnabled, gantt.copyCalendarUri == calendar.uri {
            return CalendarClass(setting: .hidden, locked: NCAgendaText.t("_nodrive_agenda_locked_gantt_copy_"),
                                 note: NCAgendaText.t("_nodrive_agenda_gantt_copy_note_"), isOwn: false)
        }
        if calendar.isSubscription || calendar.isBirthday {
            return CalendarClass(setting: chosen ?? .info, isOwn: false)
        }
        let ownerPart = calendar.ownerPrincipal.map { NCAgendaCalendarReader.lastPathPart($0).lowercased() }
        let own = ownerPart == nil || ownerPart == myUid
        if own {
            return CalendarClass(setting: chosen ?? .personal, isNew: input.settings.personalQuestionAnswered && chosen == nil)
        }
        return CalendarClass(setting: chosen ?? .team, isOwn: false)
    }

    mutating func buildCalendars() {
        var newItems: [AgendaItem] = []
        for calendar in input.calendars {
            let cls = classify(calendar)
            let color = NCAgendaColors.mapped(calendar.color)
            var source = AgendaSource(key: NCAgendaSources.calendarKey(calendar.uri), kind: calendar.onlyTodos && !calendar.isAppGenerated ? .list : .calendar,
                                      name: calendar.name, color: color, setting: cls.setting)
            if calendar.isAppGenerated { source.name = NCAgendaText.t("_nodrive_agenda_board_calendar_") }
            source.lockedReason = cls.locked
            source.isNew = cls.isNew
            source.note = cls.note
            sources.append(source)
            guard cls.setting != .hidden else { continue }
            for object in calendar.objects {
                for component in object.components {
                    if let item = calendarItem(component, object: object, calendar: calendar, setting: cls.setting, color: color) {
                        newItems.append(item)
                    }
                }
            }
        }
        items += newItems
    }

    func calendarItem(_ component: ICalComponent, object: CalObject, calendar: RawCalendar, setting: SourceSetting, color: String) -> AgendaItem? {
        if component.status == "CANCELLED" { return nil }
        let isEvent = component.kind == "VEVENT"
        let me = Set(input.me.addresses)
        let myAttendee = component.attendees.first { me.contains($0.address) }
        if isEvent, myAttendee?.partstat == "DECLINED" { return nil }
        let iAmOrganiser = component.organizer.map { me.contains($0) } ?? false
        let invited = isEvent && component.organizer != nil && !iAmOrganiser && myAttendee != nil
        if setting == .team, !(iAmOrganiser || myAttendee != nil) { return nil }
        if !isEvent, component.status == "COMPLETED" || component.completed != nil { return nil }

        var agent: AgentRef = .selfAgent
        var flags: [IntegrityFlag] = []
        if !invited {
            (agent, flags) = calendarAgent(component)
        }
        let recurrence = component.recurrenceId ?? (component.isRepeating ? component.start : nil)
        let stamp = Int((component.recurrenceId ?? component.start ?? .distantPast).timeIntervalSince1970)
        let fileName = NCAgendaCalendarReader.lastPathPart(object.href)
        var item = AgendaItem(
            key: "cal:\(calendar.uri):\(component.uid):\(stamp)",
            home: isEvent ? .calendar : .tasks,
            kind: isEvent ? .event : .todo,
            title: component.summary,
            sourceKey: NCAgendaSources.calendarKey(calendar.uri), sourceName: calendar.name, sourceColor: color,
            link: AgendaLink(home: isEvent ? .calendar : .tasks, path: object.href, calendarUri: calendar.uri, fileName: fileName,
                             recurrence: recurrence, etag: object.etag))
        item.scope = scope(of: setting)
        item.agent = agent
        item.flags = flags
        item.partstat = myAttendee?.partstat
        item.iAmOrganiser = iAmOrganiser
        item.invited = invited
        item.repeating = component.isRepeating
        item.transparent = component.transparency == "TRANSPARENT"
        item.status = component.status
        item.percent = component.percent
        item.timeZoneNote = component.unknownZone.map { NCAgendaText.f("_nodrive_agenda_zone_note_", $0) }
        if component.isRepeating { item.lock = .repeating } else if !calendar.writable { item.lock = .readOnlyCalendar }
        if isEvent {
            item.start = component.start
            item.allDay = component.startAllDay
            if let end = component.end {
                item.end = end
            } else if let start = component.start {
                if component.startAllDay {
                    item.end = input.calendar.date(byAdding: .day, value: 1, to: start)
                } else {
                    item.end = start.addingTimeInterval(TimeInterval(component.durationSeconds ?? 0))
                }
            }
        } else {
            item.start = component.start
            item.due = component.due ?? (component.durationSeconds.flatMap { seconds in component.start.map { $0.addingTimeInterval(TimeInterval(seconds)) } })
            item.allDay = component.startAllDay
            item.late = isLate(end: item.due, done: false)
        }
        return item
    }

    /// Design 4.2: `X-NOURAX-AGENT-ID` first, then the registry's calendar tag in CATEGORIES.
    func calendarAgent(_ component: ICalComponent) -> (AgentRef, [IntegrityFlag]) {
        if let id = component.agentId {
            if let agent = input.registry?.agent(id: id) {
                if agent.person == myUid { return (ref(agent), agentFlags(agent)) }
                return (.other(label: otherLabel(agent)), [])
            }
            return (.unknown(label: id), [IntegrityFlag(kind: .unknownAgent, audience: .person, names: [id])])
        }
        for category in component.categories {
            if let agent = myAgents.first(where: { $0.calendarTag == category }) { return (ref(agent), agentFlags(agent)) }
        }
        if let category = component.categories.first(where: { $0.hasPrefix("agent:") }) {
            if let agent = input.registry?.agents.first(where: { $0.calendarTag == category }) {
                return (.other(label: otherLabel(agent)), [])
            }
            let label = String(category.dropFirst("agent:".count))
            return (.unknown(label: label), [IntegrityFlag(kind: .unknownAgent, audience: .person, names: [label])])
        }
        return (.selfAgent, [])
    }

    // MARK: Boards (NoBoard)

    mutating func buildBoards() {
        guard let deck = input.deck else { return }
        for board in deck.boards where !board.archived {
            let setting = NCAgendaSources.boardSetting(board, userId: input.me.userId, settings: input.settings)
            let color = NCAgendaColors.mapped(board.color.map { $0.hasPrefix("#") ? $0 : "#" + $0 })
            sources.append(AgendaSource(key: NCAgendaSources.boardKey(board.id), kind: .board, name: board.title, color: color, setting: setting))
            guard setting != .hidden else { continue }
            for card in deck.cards[String(board.id)] ?? [] where !card.done && !card.archived {
                if cardIdsOfGanttTasks.contains(card.id) { continue }
                let assigned = Set(card.assigned.map { $0.uid.lowercased() })
                let labels = cardAgentLabels(card, assigned: assigned)
                let others = card.assigned.filter { $0.uid.lowercased() != myUid }
                // Design 4.4: an agent of mine on a card that I'm not on is a problem for me.
                if !assigned.contains(myUid) {
                    for agent in labels.strays where agent.person == myUid {
                        let flag = IntegrityFlag(kind: .agentWithoutPerson, audience: .person, names: [agent.name, card.title])
                        problems.append(AgendaProblem(key: "mine:orphan:board:\(board.id):\(card.id):\(agent.id)", kind: .flag, relation: .mine,
                                                      title: card.title, text: flag.text,
                                                      link: AgendaLink(home: .board, boardId: board.id, stackId: card.stackId, cardId: card.id, lastModified: card.lastModified),
                                                      home: .board))
                    }
                }
                if assigned.contains(myUid) {
                    let row = cardItem(card, board: board, color: color, team: false, people: [], labels: labels)
                    items.append(row)
                    if setting == .doOversee {
                        // The manager's flags about the others on a card that I'm on too. No second row: it shows once, as mine.
                        let flags = managerCardFlags(labels, title: card.title, assigned: others)
                        problems += flagProblems(flags, title: card.title, personName: nil, link: row.link, home: .board, rowKey: "board:\(board.id):\(card.id):team")
                    }
                } else if setting == .doOversee {
                    var row = cardItem(card, board: board, color: color, team: true, people: others, labels: labels)
                    if others.isEmpty {
                        row.flags.append(IntegrityFlag(kind: .notAssigned, audience: .manager))
                    }
                    items.append(row)
                    problems += teamProblems(for: row)
                }
            }
        }
    }

    /// What the 🤖 labels of one card mean (design 4.2). Every label is matched to the whole registry, not only to the
    /// agents of the people that one row looks at.
    struct CardAgentLabels {
        /// Agents of the people on the card, in label order.
        var ofAssigned: [RegistryAgent] = []
        /// Registry agents whose person is not on the card.
        var strays: [RegistryAgent] = []
        /// Labels that are not in the registry (the text after the robot).
        var unknown: [String] = []
    }

    func cardAgentLabels(_ card: DeckCard, assigned: Set<String>) -> CardAgentLabels {
        var result = CardAgentLabels()
        let agents = input.registry?.agents ?? []
        for label in card.labels {
            let matches = agents.filter { $0.boardLabel == label }
            if matches.isEmpty {
                if label.hasPrefix("🤖") { result.unknown.append(label.dropFirst(1).trimmingCharacters(in: .whitespaces)) }
            } else if let agent = matches.first(where: { assigned.contains($0.person) }) {
                if !result.ofAssigned.contains(where: { $0.id == agent.id }) { result.ofAssigned.append(agent) }
            } else if let stray = matches.first, !result.strays.contains(where: { $0.id == stray.id }) {
                result.strays.append(stray)
            }
        }
        return result
    }

    /// Flags for the board manager (design 4.4): two agents for one person, an agent with no person on the card, an
    /// agent that belongs to someone who is not on the card. `others` are the people on the card besides me.
    func managerCardFlags(_ labels: CardAgentLabels, title: String, assigned others: [DeckPerson]) -> [IntegrityFlag] {
        var flags: [IntegrityFlag] = []
        for person in others {
            let uid = person.uid.lowercased()
            if labels.ofAssigned.filter({ $0.person == uid }).count > 1 {
                flags.append(IntegrityFlag(kind: .twoAgents, audience: .both, names: [displayName(of: uid) ?? person.name]))
            }
        }
        for agent in labels.strays {
            if others.isEmpty {
                flags.append(IntegrityFlag(kind: .agentWithoutPerson, audience: .manager, names: [otherLabel(agent), title]))
            } else {
                let owner = displayName(of: agent.person) ?? NCAgendaText.t("_nodrive_agenda_someone_")
                flags.append(IntegrityFlag(kind: .agentOfOtherPerson, audience: .manager,
                                           names: [otherLabel(agent), owner, others.map { $0.name }.joined(separator: ", ")]))
            }
        }
        return flags
    }

    func cardItem(_ card: DeckCard, board: DeckBoard, color: String, team: Bool, people: [DeckPerson], labels: CardAgentLabels) -> AgendaItem {
        var item = AgendaItem(
            key: "board:\(board.id):\(card.id)" + (team ? ":team" : ""),
            home: .board, kind: .card, title: card.title,
            sourceKey: NCAgendaSources.boardKey(board.id), sourceName: board.title, sourceColor: color,
            link: AgendaLink(home: .board, boardId: board.id, stackId: card.stackId, cardId: card.id, lastModified: card.lastModified))
        item.due = card.due
        if let deck = input.deck, !deck.isReadWrite { item.lock = .guardReadOnly }
        item.relation = team ? .team : .mine
        item.personName = people.isEmpty ? nil : people.map { $0.name }.joined(separator: ", ")
        item.late = isLate(end: card.due, done: false)
        if team {
            // The agents of the people on the card; the first one is shown.
            if let first = labels.ofAssigned.first {
                item.agent = .other(label: otherLabel(first))
            } else if let unknown = labels.unknown.first {
                item.agent = .unknown(label: unknown)
            }
            item.flags += managerCardFlags(labels, title: card.title, assigned: people)
        } else {
            // My row: my own agent is mine; another person's label leaves my row as Self (design 4.2).
            let mine = labels.ofAssigned.filter { $0.person == myUid }
            if let first = mine.first {
                item.agent = ref(first)
                item.flags += agentFlags(first)
            } else if let unknown = labels.unknown.first {
                item.agent = .unknown(label: unknown)
            }
            for unknown in labels.unknown {
                item.flags.append(IntegrityFlag(kind: .unknownAgent, audience: .person, names: [unknown]))
            }
            if mine.count > 1 {
                item.flags.append(IntegrityFlag(kind: .twoAgents, audience: .both,
                                                names: [displayName(of: myUid) ?? NCAgendaText.t("_nodrive_agenda_someone_")]))
            }
        }
        return item
    }

    // MARK: Dedupe (design 6.2)

    mutating func dedupe() {
        // The same event (UID and instance) in my own calendar and in a team calendar: mine wins.
        // The key is "cal:<calendar uri>:<uid>:<instance>"; the calendar uri may hold a colon, so it is cut off by its
        // length, not by splitting.
        func signature(_ item: AgendaItem) -> String? {
            guard item.home == .calendar || item.home == .tasks, let uri = item.link.calendarUri else { return nil }
            let prefix = "cal:\(uri):"
            guard item.key.hasPrefix(prefix) else { return nil }
            return String(item.key.dropFirst(prefix.count))
        }
        let teamSources = Set(sources.filter { $0.setting == .team }.map { $0.key })
        var ownSignatures = Set<String>()
        for item in items where !teamSources.contains(item.sourceKey) {
            if let signature = signature(item) { ownSignatures.insert(signature) }
        }
        items.removeAll { item in
            guard teamSources.contains(item.sourceKey), let signature = signature(item) else { return false }
            return ownSignatures.contains(signature)
        }
        // A card shown for a Gantt task is not shown again, and a card that is both mine and a team row shows once as mine.
        let mineCards = Set(items.filter { $0.home == .board && $0.relation == .mine }.compactMap { $0.link.cardId })
        items.removeAll { $0.home == .board && $0.relation == .team && mineCards.contains($0.link.cardId ?? -1) }
        problems.removeAll { problem in
            guard problem.relation == .team, problem.home == .board, problem.kind != .flag, let cardId = problem.link?.cardId else { return false }
            return mineCards.contains(cardId)
        }
    }
}
