// SPDX-FileCopyrightText: 2026 Nourax
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import Nextcloud

/// Builders for the rule tests: a person, a registry, calendars, a Gantt read and a board.
enum AgendaRulesSupport {
    static let now = ISO8601DateFormatter().date(from: "2026-10-30T12:00:00Z")!

    static var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        value.firstWeekday = 2
        return value
    }

    static func date(_ text: String) -> Date {
        ISO8601DateFormatter().date(from: text)!
    }

    static let registryText = """
    {"schema":"nourax-agent-registry","version":1,"agents":[
     {"id":"AG-0001","name":"Writer-Bot","person":"ali","status":"active","organisation":"demo-org","links":{"nogantt_resource_ids":[40],"noboard_label":"🤖 Writer-Bot","calendar_tag":"agent:AG-0001"}},
     {"id":"AG-0002","name":"Design-Bot","person":"sara","status":"active","organisation":"demo-org","links":{"nogantt_resource_ids":[41],"noboard_label":"🤖 Design-Bot","calendar_tag":"agent:AG-0002"}},
     {"id":"AG-0003","name":"Sleep-Bot","person":"ali","status":"paused","organisation":"demo-org","links":{"calendar_tag":"agent:AG-0003"}},
     {"id":"AG-0004","name":"Old-Bot","person":"ali","status":"retired","organisation":"demo-org","links":{"calendar_tag":"agent:AG-0004"}},
     {"id":"AG-0005","name":"Foreign-Bot","person":"olaf","status":"active","organisation":"other-org","links":{"calendar_tag":"agent:AG-0005"}},
     {"id":"AG-0007","name":"Mara-Bot","person":"mara","status":"active","organisation":"demo-org","links":{}}
    ]}
    """

    static var registry: NCAgendaRegistry {
        guard case let .valid(value) = NCAgendaRegistry.parse(Data(registryText.utf8)) else { fatalError("registry fixture") }
        return value
    }

    static let ali = AgendaMe(userId: "ali", displayName: "Ali", addresses: ["ali@example.org"], groups: ["staff"])
    static let mara = AgendaMe(userId: "mara", displayName: "Mara", addresses: ["mara@example.org"], groups: [])

    static func component(_ uid: String, _ summary: String, start: String? = nil, end: String? = nil, kind: String = "VEVENT") -> ICalComponent {
        var value = ICalComponent()
        value.kind = kind
        value.uid = uid
        value.summary = summary
        value.start = start.map(date)
        value.end = end.map(date)
        return value
    }

    static func calendarSource(_ uri: String, name: String? = nil, owner: String? = "ali", components: [String] = ["VEVENT", "VTODO"],
                               subscription: Bool = false, writable: Bool = true, items: [ICalComponent] = []) -> RawCalendar {
        var value = RawCalendar(href: "/remote.php/dav/calendars/ali/\(uri)/", uri: uri, name: name ?? uri.capitalized, components: components)
        value.ownerPrincipal = owner.map { "/remote.php/dav/principals/users/\($0)/" }
        value.isSubscription = subscription
        value.isAppGenerated = uri.hasPrefix("app-generated--")
        value.isBirthday = uri == "contact_birthdays"
        value.writable = writable
        value.objects = items.map { CalObject(href: value.href + $0.uid + ".ics", etag: "\"e\"", components: [$0]) }
        return value
    }

    static func assemble(me: AgendaMe = AgendaRulesSupport.ali, calendars: [RawCalendar] = [], gantt: RawGantt? = nil, deck: RawDeck? = nil,
                         registry: NCAgendaRegistry? = AgendaRulesSupport.registry, settings: AgendaSettings = AgendaSettings()) -> AgendaSnapshot {
        NCAgendaAssembler.assemble(AgendaInputs(me: me, calendars: calendars, gantt: gantt, deck: deck, registry: registry,
                                                settings: settings, now: now, calendar: calendar))
    }

    // MARK: A Gantt read with the cases of the seed

    static func person(_ id: Int, _ name: String, uid: String?) -> GanttResource {
        GanttResource(id: id, name: name, type: "person", uid: uid, uidDisplayName: uid == nil ? nil : name)
    }

    static func task(_ id: Int, _ title: String, start: String = "2026-10-29 09:00:00", end: String = "2026-10-31 17:00:00",
                     resources: [Int], work: Double? = 4, deps: [String] = [], status: String = "in_progress", card: Int? = nil) -> GanttTask {
        GanttTask(id: id, projectId: 1, title: title, start: start, end: end, work: work, updatedAt: "2026-10-28 10:00:00",
                  progressMode: "manual", progress: 10, status: status,
                  dependencies: deps.map { GanttDependency(predecessorId: $0, type: "FS", lagDays: 0) },
                  resources: resources.map { GanttResourceRow(resourceId: $0, work: $0 < 10 ? work : nil) }, deckCardId: card)
    }

    static var gantt: RawGantt {
        var raw = RawGantt()
        raw.linked = true
        raw.timezone = "UTC"
        raw.projects = [GanttProject(id: 1, title: "Website", color: "#0082c9", ownerId: "mara", ownerName: "Mara", permission: "editor")]
        raw.resources = [
            person(1, "Ali", uid: "ali"), person(2, "Sara", uid: "sara"), person(3, "Mara", uid: "mara"),
            person(4, "🤖 Writer-Bot (Ali)", uid: nil), person(5, "🤖 Design-Bot (Sara)", uid: nil),
            person(6, "Temp worker", uid: nil),
            GanttResource(id: 7, name: "Designer", type: "role", uid: nil, uidDisplayName: nil),
            person(40, "Writer planning", uid: nil), person(41, "Design planning", uid: nil),
        ]
        raw.tasks["1"] = [
            task(11, "Write copy", resources: [1, 4], card: 100),
            task(12, "Orphan writing", resources: [40]),
            task(13, "Cross pairing", resources: [1, 41]),
            task(14, "Banner design", start: "2026-10-26 09:00:00", end: "2026-10-28 17:00:00", resources: [2, 5]),
            task(15, "Publish banners", resources: [2], deps: ["t-14"]),
            task(16, "Temp work", resources: [6]),
            task(17, "Review sitemap", resources: [7]),
            task(18, "Finished", resources: [1], status: "done"),
        ]
        raw.milestones["1"] = [GanttMilestone(id: 1, projectId: 1, title: "Launch", date: "2026-11-02", taskId: nil)]
        raw.subprojects["1"] = [GanttSubproject(id: 3, title: "Copy")]
        raw.myTasks = [
            GanttMyTask(id: 11, title: "Write copy", projectId: 1, projectTitle: "Website", start: "2026-10-29 09:00:00", end: "2026-10-31 17:00:00", status: "in_progress"),
            GanttMyTask(id: 13, title: "Cross pairing", projectId: 1, projectTitle: "Website", start: "2026-10-29 09:00:00", end: "2026-10-31 17:00:00", status: "in_progress"),
        ]
        raw.shares["1"] = [GanttShare(type: "user", with: "mara", permission: "admin"), GanttShare(type: "user", with: "ali", permission: "editor")]
        return raw
    }
}

// MARK: - Sources and calendar rules

@Suite("NoDrive NoAgenda rules: calendars")
struct NoDriveAgendaCalendarRulesTests {
    typealias S = AgendaRulesSupport

    @Test("Defaults: own is Personal, subscriptions Info, board and copy calendars Hidden with a reason, shared Team")
    func defaults() throws {
        var gantt = S.gantt
        gantt.copyEnabled = true
        gantt.copyCalendarUri = "ganttcopy"
        let snapshot = S.assemble(calendars: [
            S.calendarSource("personal"), S.calendarSource("holidays", subscription: true),
            S.calendarSource("app-generated--deck--board-1"), S.calendarSource("ganttcopy"),
            S.calendarSource("shared", owner: "mara"), S.calendarSource("contact_birthdays"),
        ], gantt: gantt)
        func setting(_ uri: String) -> SourceSetting? { snapshot.sources.first { $0.key == "cal:" + uri }?.setting }
        #expect(setting("personal") == .personal)
        #expect(setting("holidays") == .info)
        #expect(setting("app-generated--deck--board-1") == .hidden)
        #expect(setting("ganttcopy") == .hidden)
        #expect(setting("shared") == .team)
        #expect(snapshot.sources.first { $0.key == "cal:app-generated--deck--board-1" }?.lockedReason != nil)
        #expect(snapshot.sources.first { $0.key == "cal:ganttcopy" }?.note != nil)
        #expect(snapshot.sources.first { $0.key == "cal:personal" }?.lockedReason == nil)
    }

    @Test("A calendar with only VTODO is a list")
    func lists() {
        let snapshot = S.assemble(calendars: [S.calendarSource("tasks", components: ["VTODO"]), S.calendarSource("both")])
        #expect(snapshot.sources.first { $0.key == "cal:tasks" }?.kind == .list)
        #expect(snapshot.sources.first { $0.key == "cal:both" }?.kind == .calendar)
    }

    @Test("The one-time question: chosen calendars are Personal, the others Work; a later calendar is new")
    func question() {
        var settings = AgendaSettings()
        settings.chosen = ["cal:personal": .personal, "cal:work": .work]
        settings.personalQuestionAnswered = true
        let snapshot = S.assemble(calendars: [S.calendarSource("personal"), S.calendarSource("work"), S.calendarSource("later")], settings: settings)
        #expect(snapshot.sources.first { $0.key == "cal:work" }?.setting == .work)
        #expect(snapshot.sources.first { $0.key == "cal:personal" }?.setting == .personal)
        #expect(snapshot.sources.first { $0.key == "cal:later" }?.setting == .personal)
        #expect(snapshot.sources.first { $0.key == "cal:later" }?.isNew == true)
        #expect(snapshot.sources.first { $0.key == "cal:work" }?.isNew == false)
    }

    @Test("Declined and cancelled events are hidden; a free event is marked; Self needs no registry")
    func eventRules() throws {
        var declined = S.component("d", "Declined", start: "2026-10-30T10:00:00Z", end: "2026-10-30T11:00:00Z")
        declined.attendees = [ICalAttendee(address: "ali@example.org", partstat: "DECLINED")]
        var cancelled = S.component("c", "Cancelled", start: "2026-10-30T10:00:00Z", end: "2026-10-30T11:00:00Z")
        cancelled.status = "CANCELLED"
        var free = S.component("f", "Free", start: "2026-10-30T10:00:00Z", end: "2026-10-30T11:00:00Z")
        free.transparency = "TRANSPARENT"
        let normal = S.component("n", "Normal", start: "2026-10-30T10:00:00Z", end: "2026-10-30T11:00:00Z")
        let snapshot = S.assemble(calendars: [S.calendarSource("personal", items: [declined, cancelled, free, normal])], registry: nil)
        let titles = snapshot.items.map(\.title).sorted()
        #expect(titles == ["Free", "Normal"])
        #expect(snapshot.items.first { $0.title == "Free" }?.transparent == true)
        #expect(snapshot.items.allSatisfy { $0.agent.isSelf })
    }

    @Test("A team calendar shows only events where I'm the organiser or an attendee; an invitation is Self and marked")
    func teamCalendar() {
        var invitation = S.component("i", "Planning", start: "2026-10-30T09:00:00Z", end: "2026-10-30T10:00:00Z")
        invitation.organizer = "mara@example.org"
        invitation.attendees = [ICalAttendee(address: "ali@example.org", partstat: "NEEDS-ACTION")]
        invitation.agentId = "AG-0001"
        var mine = S.component("m", "I organise", start: "2026-10-30T13:00:00Z", end: "2026-10-30T14:00:00Z")
        mine.organizer = "ali@example.org"
        let other = S.component("o", "Without Ali", start: "2026-10-30T15:00:00Z", end: "2026-10-30T16:00:00Z")
        let snapshot = S.assemble(calendars: [S.calendarSource("team", owner: "mara", items: [invitation, mine, other])])
        #expect(snapshot.items.map(\.title).sorted() == ["I organise", "Planning"])
        let planning = snapshot.items.first { $0.title == "Planning" }
        #expect(planning?.invited == true)
        #expect(planning?.agent.isSelf == true)
        #expect(snapshot.items.first { $0.title == "I organise" }?.iAmOrganiser == true)
    }

    @Test("The same event in my calendar and a team calendar is one row; mine wins")
    func dedupe() {
        var invitation = S.component("same", "Planning", start: "2026-10-30T09:00:00Z", end: "2026-10-30T10:00:00Z")
        invitation.organizer = "mara@example.org"
        invitation.attendees = [ICalAttendee(address: "ali@example.org", partstat: "ACCEPTED")]
        let snapshot = S.assemble(calendars: [
            S.calendarSource("personal", items: [invitation]), S.calendarSource("team", owner: "mara", items: [invitation]),
        ])
        #expect(snapshot.items.count == 1)
        #expect(snapshot.items.first?.sourceKey == "cal:personal")
    }

    @Test("Hidden calendars give no rows")
    func hiddenCalendars() {
        let event = S.component("e", "Board thing", start: "2026-10-30T09:00:00Z", end: "2026-10-30T10:00:00Z")
        let snapshot = S.assemble(calendars: [S.calendarSource("app-generated--deck--board-1", items: [event])])
        #expect(snapshot.items.isEmpty)
    }

    @Test("Agents: the id first, then the registry tag; an unknown id or agent: tag is flagged; paused and retired")
    func agents() throws {
        var byId = S.component("1", "By id", start: "2026-10-30T09:00:00Z", end: "2026-10-30T10:00:00Z")
        byId.agentId = "AG-0001"
        var byTag = S.component("2", "By tag", start: "2026-10-30T09:00:00Z", end: "2026-10-30T10:00:00Z")
        byTag.categories = ["Work", "agent:AG-0001"]
        var unknownId = S.component("3", "Unknown id", start: "2026-10-30T09:00:00Z", end: "2026-10-30T10:00:00Z")
        unknownId.agentId = "AG-0009"
        var unknownTag = S.component("4", "Unknown tag", start: "2026-10-30T09:00:00Z", end: "2026-10-30T10:00:00Z")
        unknownTag.categories = ["agent:AG-0010"]
        var paused = S.component("5", "Paused", start: "2026-10-30T09:00:00Z", end: "2026-10-30T10:00:00Z")
        paused.agentId = "AG-0003"
        var retired = S.component("6", "Retired", start: "2026-10-30T09:00:00Z", end: "2026-10-30T10:00:00Z")
        retired.agentId = "AG-0004"
        var foreign = S.component("7", "Foreign", start: "2026-10-30T09:00:00Z", end: "2026-10-30T10:00:00Z")
        foreign.agentId = "AG-0005"
        var colleague = S.component("8", "Colleague", start: "2026-10-30T09:00:00Z", end: "2026-10-30T10:00:00Z")
        colleague.agentId = "AG-0002"
        let none = S.component("9", "Plain", start: "2026-10-30T09:00:00Z", end: "2026-10-30T10:00:00Z")
        let snapshot = S.assemble(calendars: [S.calendarSource("personal", items: [byId, byTag, unknownId, unknownTag, paused, retired, foreign, colleague, none])])
        func item(_ title: String) throws -> AgendaItem { try #require(snapshot.items.first { $0.title == title }) }
        #expect(try item("By id").agent == .mine(id: "AG-0001", name: "Writer-Bot", status: .active))
        #expect(try item("By tag").agent == .mine(id: "AG-0001", name: "Writer-Bot", status: .active))
        #expect(try item("Unknown id").agent == .unknown(label: "AG-0009"))
        #expect(try item("Unknown id").flags.map(\.kind) == [.unknownAgent])
        #expect(try item("Unknown tag").agent == .unknown(label: "AG-0010"))
        #expect(try item("Paused").agent.isPaused)
        #expect(try item("Retired").flags.map(\.kind) == [.retiredAgent])
        #expect(try item("Retired").agent.displayText.contains(NCAgendaText.f("_nodrive_agenda_retired_", "Old-Bot")))
        #expect(try item("Plain").agent.isSelf)
        // Another person's agent: named only when its organisation is one of mine (Ali's agents are in demo-org)
        #expect(try item("Colleague").agent == .other(label: "Design-Bot"))
        #expect(try item("Foreign").agent == .other(label: NCAgendaText.t("_nodrive_agenda_other_org_agent_")))
    }

    @Test("A to-do is shown with its due date; completed ones are not; a repeating one is locked")
    func todos() {
        var open = S.component("t1", "Draft report", start: nil, end: nil, kind: "VTODO")
        open.due = S.date("2026-10-30T15:00:00Z")
        var done = S.component("t2", "Done already", kind: "VTODO")
        done.status = "COMPLETED"
        var repeating = S.component("t3", "Weekly", kind: "VTODO")
        repeating.hasRRule = true
        repeating.due = S.date("2026-10-31T09:00:00Z")
        let snapshot = S.assemble(calendars: [S.calendarSource("tasks", components: ["VTODO"], items: [open, done, repeating])])
        #expect(snapshot.items.map(\.title).sorted() == ["Draft report", "Weekly"])
        #expect(snapshot.items.first { $0.title == "Weekly" }?.lock == .repeating)
        #expect(snapshot.items.first { $0.title == "Draft report" }?.home == .tasks)
    }
}

// MARK: - NoGantt and NoBoard rules

@Suite("NoDrive NoAgenda rules: projects, agents, integrity, team")
struct NoDriveAgendaGanttRulesTests {
    typealias S = AgendaRulesSupport

    func project(_ owner: String, _ permission: String, tasks: Bool, shares: [GanttShare]? = nil, me: String = "ali", groups: [String] = []) -> SourceSetting {
        let value = GanttProject(id: 9, title: "P", color: nil, ownerId: owner, ownerName: nil, permission: permission)
        return NCAgendaSources.projectSetting(value, hasMyTasks: tasks, settings: AgendaSettings(), userId: me, groups: groups, shares: shares)
    }

    @Test("Project defaults: owner and admin share Do + Oversee; with tasks Do; without Hidden; server admin only Hidden")
    func projectDefaults() {
        #expect(project("ali", "admin", tasks: false) == .doOversee)
        #expect(project("mara", "admin", tasks: false, shares: [GanttShare(type: "user", with: "ali", permission: "admin")]) == .doOversee)
        #expect(project("mara", "admin", tasks: false, shares: [GanttShare(type: "group", with: "staff", permission: "admin")], groups: ["staff"]) == .doOversee)
        #expect(project("mara", "editor", tasks: true) == .doIt)
        #expect(project("mara", "viewer", tasks: true) == .doIt)
        #expect(project("mara", "editor", tasks: false) == .hidden)
        // seen only as a server admin: no share for me
        #expect(project("mara", "admin", tasks: false, shares: [GanttShare(type: "user", with: "sara", permission: "admin")]) == .hidden)
        #expect(project("mara", "admin", tasks: false, shares: nil) == .hidden)
        // a team share can't be resolved and is never guessed
        #expect(project("mara", "admin", tasks: false, shares: [GanttShare(type: "circle", with: "team1", permission: "admin")]) == .hidden)
        #expect(project("mara", "admin", tasks: true) == .doIt)
    }

    @Test("The person can change a project's setting")
    func chosenProject() {
        var settings = AgendaSettings()
        settings.chosen["project:9"] = .hidden
        let value = GanttProject(id: 9, title: "P", color: nil, ownerId: "ali", ownerName: nil, permission: "admin")
        #expect(NCAgendaSources.projectSetting(value, hasMyTasks: true, settings: settings, userId: "ali", groups: [], shares: nil) == .hidden)
    }

    @Test("Board defaults: owner or manage Do + Oversee, a member Do")
    func boardDefaults() {
        let owned = DeckBoard(id: 1, title: "B", owner: DeckPerson(uid: "ali", name: "Ali"))
        let managed = DeckBoard(id: 2, title: "B", owner: DeckPerson(uid: "mara", name: "Mara"), canManage: true)
        let member = DeckBoard(id: 3, title: "B", owner: DeckPerson(uid: "mara", name: "Mara"))
        #expect(NCAgendaSources.boardSetting(owned, userId: "ali", settings: AgendaSettings()) == .doOversee)
        #expect(NCAgendaSources.boardSetting(managed, userId: "ali", settings: AgendaSettings()) == .doOversee)
        #expect(NCAgendaSources.boardSetting(member, userId: "ali", settings: AgendaSettings()) == .doIt)
    }

    @Test("Ali's rows: his tasks with the agent by exact name next to him, Self when none; a done task and others' tasks are absent")
    func aliRows() throws {
        let snapshot = S.assemble(gantt: S.gantt)
        let rows = snapshot.items.filter { $0.home == .gantt && $0.kind == .ganttTask }
        #expect(rows.map(\.title).sorted() == ["Cross pairing", "Write copy"])
        let write = try #require(rows.first { $0.title == "Write copy" })
        #expect(write.agent == .mine(id: "AG-0001", name: "Writer-Bot", status: .active))
        #expect(write.workShare == 4)
        #expect(write.phase == nil)
        #expect(write.relation == .mine)
        #expect(write.boardBadge)
        #expect(write.sourceColor == NCAgendaColors.cobalt)
        let cross = try #require(rows.first { $0.title == "Cross pairing" })
        #expect(cross.agent.isSelf)
        #expect(snapshot.items.contains { $0.kind == .milestone && $0.title == "Launch" })
        #expect(snapshot.items.allSatisfy { $0.relation == .mine })
    }

    @Test("An agent of mine on a task without me is a problem for me: \"Writer-Bot is on ... without you\"")
    func orphanForPerson() throws {
        let snapshot = S.assemble(gantt: S.gantt)
        let problem = try #require(snapshot.problems.first { $0.key.hasPrefix("mine:orphan:12") })
        #expect(problem.relation == .mine)
        #expect(problem.text == NCAgendaText.f("_nodrive_agenda_flag_agent_no_person_", "Writer-Bot", "Orphan writing"))
    }

    @Test("A name that matches but is not next to the person is not an agent (never guessed)")
    func nameNeedsPerson() throws {
        var gantt = S.gantt
        gantt.tasks["1"] = [S.task(20, "Lonely", resources: [4])]
        let snapshot = S.assemble(gantt: gantt)
        #expect(snapshot.problems.isEmpty)
        #expect(snapshot.items.filter { $0.kind == .ganttTask }.isEmpty)
    }

    @Test("Two agents of mine on one task: flagged for the person, the first is shown")
    func twoAgents() throws {
        var gantt = S.gantt
        gantt.resources.append(S.person(50, "🤖 Sleep-Bot (Ali)", uid: nil))
        gantt.tasks["1"] = [S.task(11, "Write copy", resources: [1, 4, 50])]
        let snapshot = S.assemble(gantt: gantt)
        let row = try #require(snapshot.items.first { $0.title == "Write copy" })
        #expect(row.flags.contains { $0.kind == .twoAgents })
        #expect(snapshot.problems.contains { $0.key == "mine:two:11" })
    }

    @Test("Mara runs the project: team rows with the person and the agent, late, blocked and the integrity problems")
    func teamAsManager() throws {
        let snapshot = S.assemble(me: S.mara, gantt: S.gantt)
        let team = snapshot.items.filter { $0.relation == .team }
        let banner = try #require(team.first { $0.title == "Banner design" })
        #expect(banner.personName == "Sara")
        #expect(banner.agent == .other(label: "Design-Bot"))
        #expect(banner.late)
        let late = try #require(snapshot.problems.first { $0.key == "team:late:gantt:14:team:sara" })
        #expect(late.text == "⏰ Banner design: Sara · 🤖 Design-Bot, " + NCAgendaText.f("_nodrive_agenda_days_late_", 2))
        #expect(late.days == 2)
        #expect(snapshot.problems.contains { $0.key == "team:blocked:gantt:15:team:sara" })
        let kinds = Set(team.flatMap { $0.flags.map(\.kind) })
        #expect(kinds.isSuperset(of: [.notLinked, .notAssigned, .agentWithoutPerson, .agentOfOtherPerson]))
        let cross = try #require(team.first { $0.title == "Cross pairing" }?.flags.first { $0.kind == .agentOfOtherPerson })
        #expect(cross.names == ["Design-Bot", "Sara", "Ali"])
        #expect(cross.text == NCAgendaText.f("_nodrive_agenda_flag_agent_belongs_", "Design-Bot", "Sara", "Ali"))
        #expect(!snapshot.problems.contains { $0.text.contains("Finished") })
    }

    @Test("A person on tasks of a project that is not shared with them: \"Sara has 2 tasks ...\"")
    func notShared() throws {
        let snapshot = S.assemble(me: S.mara, gantt: S.gantt)
        let flag = IntegrityFlag(kind: .notShared, audience: .manager, names: ["Sara"], count: 2)
        let problem = try #require(snapshot.problems.first { $0.key == "team:notShared:1:sara" })
        #expect(problem.text == "⚠ " + flag.text)
        // A team share can't be resolved: nothing is flagged
        var gantt = S.gantt
        gantt.shares["1"] = [GanttShare(type: "user", with: "mara", permission: "admin"), GanttShare(type: "circle", with: "team", permission: "editor")]
        #expect(!S.assemble(me: S.mara, gantt: gantt).problems.contains { $0.key.hasPrefix("team:notShared") })
    }

    @Test("Overbooked people come from NoGantt's capacity check")
    func overbooked() throws {
        var gantt = S.gantt
        gantt.findings["all"] = [GanttFinding(level: "error", start: "2026-10-30", end: "2026-10-31", personIds: [2], deficitHours: 3, taskIds: [])]
        let snapshot = S.assemble(me: S.mara, gantt: gantt)
        let problem = try #require(snapshot.problems.first { $0.kind == .overbooked })
        #expect(problem.text == "⚠ " + NCAgendaText.f("_nodrive_agenda_overbooked_", "Sara"))
    }

    @Test("Without the oversee setting there are no team rows")
    func noTeamForDoProjects() {
        let snapshot = S.assemble(gantt: S.gantt)
        #expect(!snapshot.problems.contains { $0.relation == .team })
    }

    @Test("A person who is not linked in NoGantt gets the not-linked state")
    func notLinked() {
        var gantt = S.gantt
        gantt.linked = false
        gantt.myTasks = []
        #expect(S.assemble(gantt: gantt).notLinked)
        #expect(!S.assemble(gantt: S.gantt).notLinked)
        gantt.contractOK = false
        #expect(!S.assemble(gantt: gantt).notLinked)
    }

    @Test("Another organisation's agent is named \"Agent of ...\", never by a user id")
    func privacy() {
        var gantt = S.gantt
        gantt.resources.append(S.person(60, "Foreign planning", uid: nil))
        var registry = S.registry
        registry.agents.append(RegistryAgent(id: "AG-0008", name: "Out-Bot", person: "sara", status: .active, organisation: "other-org", ganttResourceIds: [60]))
        gantt.tasks["1"] = [S.task(30, "Mixed", resources: [2, 60])]
        let snapshot = S.assemble(me: S.mara, gantt: gantt, registry: registry)
        let row = snapshot.items.first { $0.title == "Mixed" }
        #expect(row?.agent == .other(label: NCAgendaText.f("_nodrive_agenda_agent_of_", "Sara")))
    }
}

@Suite("NoDrive NoAgenda rules: boards and dedupe")
struct NoDriveAgendaBoardRulesTests {
    typealias S = AgendaRulesSupport

    func deck(cards: [DeckCard], owner: String = "mara") -> RawDeck {
        var raw = RawDeck(version: "1.19.1")
        raw.boards = [DeckBoard(id: 1, title: "Team board", color: "0082c9", owner: DeckPerson(uid: owner, name: owner.capitalized))]
        raw.cards["1"] = cards
        return raw
    }

    func card(_ id: Int, _ title: String, assigned: [String], labels: [String] = [], due: String? = "2026-10-30T12:00:00Z", done: Bool = false) -> DeckCard {
        DeckCard(id: id, boardId: 1, stackId: 2, title: title, due: due.map(S.date), done: done,
                 assigned: assigned.map { DeckPerson(uid: $0, name: $0.capitalized) }, labels: labels, lastModified: 1)
    }

    @Test("My cards: with an agent label, unknown label flagged, done and archived hidden; the board colour is mapped")
    func cards() throws {
        let snapshot = S.assemble(deck: deck(cards: [
            card(1, "Mine", assigned: ["ali"]), card(2, "With agent", assigned: ["ali"], labels: ["🤖 Writer-Bot"]),
            card(3, "Ghost", assigned: ["ali"], labels: ["🤖 Ghost-Bot"]), card(4, "Finished", assigned: ["ali"], done: true),
            card(5, "No date", assigned: ["ali"], due: nil), card(6, "Not mine", assigned: ["sara"]),
        ]))
        #expect(snapshot.items.map(\.title).sorted() == ["Ghost", "Mine", "No date", "With agent"])
        #expect(snapshot.items.first { $0.title == "With agent" }?.agent == .mine(id: "AG-0001", name: "Writer-Bot", status: .active))
        #expect(snapshot.items.first { $0.title == "Ghost" }?.agent == .unknown(label: "Ghost-Bot"))
        #expect(snapshot.items.first { $0.title == "Mine" }?.sourceColor == NCAgendaColors.cobalt)
        #expect(snapshot.sources.first { $0.key == "board:1" }?.setting == .doIt)
    }

    @Test("A card linked from a Gantt task shows once, as the Gantt task with a board badge")
    func linkedCard() {
        let snapshot = S.assemble(gantt: S.gantt, deck: deck(cards: [card(100, "Landing page build", assigned: ["ali"])]))
        #expect(!snapshot.items.contains { $0.home == .board })
        #expect(snapshot.items.first { $0.title == "Write copy" }?.boardBadge == true)
    }

    @Test("The board manager sees team cards of others as team rows with problems; an unassigned card is flagged")
    func teamCards() throws {
        let snapshot = S.assemble(me: S.mara, deck: deck(cards: [
            card(1, "Late card", assigned: ["sara"], labels: ["🤖 Design-Bot"], due: "2026-10-28T12:00:00Z"),
            card(2, "Nobody", assigned: [], due: "2026-11-05T12:00:00Z"),
            card(3, "Mara's own", assigned: ["mara"]),
        ]))
        #expect(snapshot.sources.first { $0.key == "board:1" }?.setting == .doOversee)
        let late = try #require(snapshot.items.first { $0.title == "Late card" })
        #expect(late.relation == .team)
        #expect(late.personName == "Sara")
        #expect(late.agent == .other(label: "Design-Bot"))
        #expect(snapshot.problems.contains { $0.key.hasPrefix("team:late:") && $0.text.contains("Late card") })
        #expect(snapshot.items.first { $0.title == "Nobody" }?.flags.map(\.kind) == [.notAssigned])
        #expect(snapshot.items.first { $0.title == "Mara's own" }?.relation == .mine)
    }

    @Test("A card with several assignees names all of them")
    func severalAssignees() {
        let snapshot = S.assemble(me: S.mara, deck: deck(cards: [card(1, "Pair", assigned: ["sara", "olaf"])]))
        #expect(snapshot.items.first?.personName == "Sara, Olaf")
    }
}

// MARK: - Filters, day plan, colours

@Suite("NoDrive NoAgenda lists")
struct NoDriveAgendaPlannerTests {
    typealias S = AgendaRulesSupport

    func snapshot() -> AgendaSnapshot {
        var dentist = S.component("d", "Dentist", start: "2026-10-30T10:00:00Z", end: "2026-10-30T11:00:00Z")
        dentist.categories = []
        var review = S.component("r", "Writer-Bot review", start: "2026-10-30T14:00:00Z", end: "2026-10-30T15:00:00Z")
        review.agentId = "AG-0001"
        var allDay = S.component("a", "Day off", start: "2026-10-30T00:00:00Z", end: "2026-10-31T00:00:00Z")
        allDay.startAllDay = true
        var draft = S.component("t", "Draft report", kind: "VTODO")
        draft.due = S.date("2026-10-30T15:00:00Z")
        let undated = S.component("u", "Someday", kind: "VTODO")
        var lateTodo = S.component("l", "Old to-do", kind: "VTODO")
        lateTodo.due = S.date("2026-10-27T09:00:00Z")
        var settings = AgendaSettings()
        settings.chosen["cal:work"] = .work
        settings.personalQuestionAnswered = true
        return S.assemble(calendars: [
            S.calendarSource("personal", items: [dentist, allDay, draft, undated, lateTodo]),
            S.calendarSource("work", items: [review]),
        ], gantt: S.gantt, settings: settings)
    }

    func plan(_ day: String = "2026-10-30T09:00:00Z", filter: AgendaFilter = AgendaFilter(), snapshot: AgendaSnapshot? = nil, all: Bool = false) -> AgendaDayPlan {
        NCAgendaPlanner.plan(day: S.date(day), snapshot: snapshot ?? self.snapshot(), filter: filter, showAllTeam: all, now: S.now, calendar: S.calendar)
    }

    @Test("Today: timed items by start with all-day first, due today, in progress, late, no date")
    func sections() {
        let value = plan()
        #expect(value.timed.map(\.title) == ["Day off", "Dentist", "Writer-Bot review"])
        #expect(value.dueToday.map(\.title).contains("Draft report"))
        #expect(value.inProgress.map(\.title).contains("Write copy"))
        #expect(value.late.map(\.title) == ["Old to-do"])
        #expect(value.noDate.map(\.title) == ["Someday"])
    }

    @Test("Late items and problems show on today only")
    func todayOnly() {
        let value = plan("2026-10-31T09:00:00Z")
        #expect(value.late.isEmpty)
        #expect(value.ownProblems.isEmpty)
        #expect(!plan().ownProblems.isEmpty)
    }

    @Test("The chips: Me hides Self rows, My agents hides agent rows")
    func chips() {
        var filter = AgendaFilter()
        filter.me = false
        #expect(!plan(filter: filter).timed.contains { $0.title == "Dentist" })
        #expect(plan(filter: filter).timed.contains { $0.title == "Writer-Bot review" })
        filter = AgendaFilter()
        filter.agents = false
        #expect(plan(filter: filter).timed.contains { $0.title == "Dentist" })
        #expect(!plan(filter: filter).timed.contains { $0.title == "Writer-Bot review" })
    }

    @Test("All, Work and Personal; Gantt rows count as Work")
    func scopes() {
        var filter = AgendaFilter()
        filter.scope = .personal
        let personal = plan(filter: filter)
        #expect(personal.timed.map(\.title) == ["Day off", "Dentist"])
        #expect(personal.inProgress.isEmpty)
        filter.scope = .work
        let work = plan(filter: filter)
        #expect(work.timed.map(\.title) == ["Writer-Bot review"])
        #expect(work.inProgress.map(\.title).contains("Write copy"))
    }

    @Test("Team rows only with \"Show all team tasks\"; problems always (today)")
    func team() {
        let managed = S.assemble(me: S.mara, gantt: S.gantt)
        let normal = NCAgendaPlanner.plan(day: S.now, snapshot: managed, filter: AgendaFilter(), showAllTeam: false, now: S.now, calendar: S.calendar)
        #expect(normal.teamItems.isEmpty)
        #expect(!normal.teamProblems.isEmpty)
        let all = NCAgendaPlanner.plan(day: S.now, snapshot: managed, filter: AgendaFilter(), showAllTeam: true, now: S.now, calendar: S.calendar)
        #expect(!all.teamItems.isEmpty)
        var filter = AgendaFilter()
        filter.team = false
        let off = NCAgendaPlanner.plan(day: S.now, snapshot: managed, filter: filter, showAllTeam: true, now: S.now, calendar: S.calendar)
        #expect(off.teamItems.isEmpty && off.teamProblems.isEmpty)
    }

    @Test("The week has seven days from the first weekday; the month grid starts on the right column")
    func weekAndMonth() {
        let days = NCAgendaPlanner.weekDays(of: S.date("2026-10-30T09:00:00Z"), calendar: S.calendar)
        #expect(days.count == 7)
        #expect(S.calendar.component(.weekday, from: days[0]) == 2)
        let grid = NCAgendaPlanner.monthGrid(of: S.date("2026-10-15T09:00:00Z"), calendar: S.calendar)
        #expect(grid.compactMap { $0 }.count == 31)
        // 1 Oct 2026 is a Thursday: Monday-first leaves three empty cells
        #expect(grid.prefix(3).allSatisfy { $0 == nil })
        #expect(grid[3] != nil)
        #expect(NCAgendaPlanner.hasItems(on: S.now, snapshot: snapshot(), filter: AgendaFilter(), calendar: S.calendar))
        #expect(!NCAgendaPlanner.hasItems(on: S.date("2026-12-24T09:00:00Z"), snapshot: snapshot(), filter: AgendaFilter(), calendar: S.calendar))
    }

    @Test("Server blues become cobalt; other colours stay; nothing becomes the server blue")
    func colours() {
        #expect(NCAgendaColors.mapped("#0082c9") == NCAgendaColors.cobalt)
        #expect(NCAgendaColors.mapped("#0082C9FF") == NCAgendaColors.cobalt)
        #expect(NCAgendaColors.mapped("#00679e") == NCAgendaColors.cobalt)
        #expect(NCAgendaColors.mapped("#49abea") == NCAgendaColors.cobalt)
        #expect(NCAgendaColors.mapped(nil) == NCAgendaColors.cobalt)
        #expect(NCAgendaColors.mapped("nonsense") == NCAgendaColors.cobalt)
        #expect(NCAgendaColors.mapped("#e9322d") == "#E9322D")
        #expect(NCAgendaColors.mapped("f00") == "#FF0000")
    }
}
