// SPDX-FileCopyrightText: 2026 Nourax
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import Nextcloud

enum AgendaConflictSupport {
    typealias S = AgendaEditSupport

    /// 2026-11-02 is a Monday.
    static func at(_ text: String) -> Date { S.date(text) }

    static func item(_ key: String, kind: AgendaKind = .event, start: String? = nil, end: String? = nil, due: String? = nil,
                     agent: AgentRef = .selfAgent, transparent: Bool = false, status: String? = nil, scope: AgendaScope = .work,
                     allDay: Bool = false, work: Double? = nil, relation: AgendaRelation = .mine) -> AgendaItem {
        var row = AgendaItem(key: key, home: kind == .event ? .calendar : .gantt, kind: kind, title: key, sourceKey: "cal:work", sourceName: "Work",
                             sourceColor: "#2563EB", link: AgendaLink(home: kind == .event ? .calendar : .gantt))
        row.start = start.map(at)
        row.end = end.map(at)
        row.due = due.map(at)
        row.agent = agent
        row.transparent = transparent
        row.status = status
        row.scope = scope
        row.allDay = allDay
        row.workShare = work
        row.relation = relation
        return row
    }

    static let writer = AgentRef.mine(id: "AG-0001", name: "Writer-Bot", status: .active)
    static let monday = at("2026-11-02T00:00:00Z")
}

@Suite("NoDrive NoAgenda clashes")
struct NoDriveAgendaClashTests {
    typealias C = AgendaConflictSupport
    typealias S = AgendaEditSupport

    func marks(_ items: [AgendaItem]) -> [String: ClashKind] {
        NCAgendaConflicts.clashes(items, calendar: S.calendar)
    }

    @Test("Two timed events of mine that overlap clash; touching ones do not")
    func hard() {
        let result = marks([C.item("a", start: "2026-11-02T10:00:00Z", end: "2026-11-02T11:00:00Z"),
                            C.item("b", start: "2026-11-02T10:30:00Z", end: "2026-11-02T11:30:00Z"),
                            C.item("c", start: "2026-11-02T11:30:00Z", end: "2026-11-02T12:00:00Z")])
        #expect(result == ["a": .hard, "b": .hard])
    }

    @Test("A tentative item gives a soft clash, and a hard one wins when both exist")
    func soft() {
        let soft = marks([C.item("a", start: "2026-11-02T10:00:00Z", end: "2026-11-02T11:00:00Z"),
                          C.item("b", start: "2026-11-02T10:30:00Z", end: "2026-11-02T11:30:00Z", status: "TENTATIVE")])
        #expect(soft == ["a": .soft, "b": .soft])
        let both = marks([C.item("a", start: "2026-11-02T10:00:00Z", end: "2026-11-02T12:00:00Z"),
                          C.item("b", start: "2026-11-02T10:30:00Z", end: "2026-11-02T11:00:00Z", status: "TENTATIVE"),
                          C.item("c", start: "2026-11-02T11:00:00Z", end: "2026-11-02T11:30:00Z")])
        #expect(both["a"] == .hard && both["c"] == .hard && both["b"] == .soft)
    }

    @Test("Free events, an agent's items, Info calendars, all-day events and other people's rows never clash with mine")
    func excluded() {
        let base = C.item("a", start: "2026-11-02T10:00:00Z", end: "2026-11-02T11:00:00Z")
        let others = [C.item("free", start: "2026-11-02T10:00:00Z", end: "2026-11-02T11:00:00Z", transparent: true),
                      C.item("bot", start: "2026-11-02T10:00:00Z", end: "2026-11-02T11:00:00Z", agent: C.writer),
                      C.item("info", start: "2026-11-02T10:00:00Z", end: "2026-11-02T11:00:00Z", scope: .info),
                      C.item("allday", start: "2026-11-02T00:00:00Z", end: "2026-11-03T00:00:00Z", allDay: true),
                      C.item("team", start: "2026-11-02T10:00:00Z", end: "2026-11-02T11:00:00Z", relation: .team)]
        #expect(marks([base] + others).isEmpty)
    }

    @Test("A Gantt task with real times on one day clashes with an event; a multi-day task does not")
    func gantt() {
        let event = C.item("e", start: "2026-11-02T10:00:00Z", end: "2026-11-02T11:00:00Z")
        let oneDay = C.item("g", kind: .ganttTask, start: "2026-11-02T09:00:00Z", end: "2026-11-02T12:00:00Z")
        let spread = C.item("m", kind: .ganttTask, start: "2026-11-02T09:00:00Z", end: "2026-11-04T17:00:00Z")
        #expect(marks([event, oneDay, spread]) == ["e": .hard, "g": .hard])
    }

    @Test("The Conflicts chip keeps a clash, a block, a late mark and a day off")
    func chip() {
        var row = C.item("a", start: "2026-11-02T10:00:00Z", end: "2026-11-02T11:00:00Z")
        #expect(!NCAgendaConflicts.hasConflict(row))
        row.clash = .soft
        #expect(NCAgendaConflicts.hasConflict(row))
        var blocked = row
        blocked.clash = nil
        blocked.blocked = true
        #expect(NCAgendaConflicts.hasConflict(blocked))
        var off = blocked
        off.blocked = false
        off.dayOff = true
        #expect(NCAgendaConflicts.hasConflict(off))
    }
}

@Suite("NoDrive NoAgenda workload")
struct NoDriveAgendaWorkloadTests {
    typealias C = AgendaConflictSupport
    typealias S = AgendaEditSupport
    let pattern = AgendaWorkPattern()

    func day(_ text: String, _ items: [AgendaItem], _ pattern: AgendaWorkPattern? = nil) -> AgendaWorkload? {
        NCAgendaWorkload.day(C.at(text), items: items, pattern: pattern ?? self.pattern, calendar: S.calendar)
    }

    @Test("Work is spread evenly over the working days of the task: 10 hours over Monday to Friday is 2 hours a day")
    func spread() {
        let task = C.item("t", kind: .ganttTask, start: "2026-11-02T09:00:00Z", end: "2026-11-06T17:00:00Z", work: 10)
        for text in ["2026-11-02T00:00:00Z", "2026-11-04T00:00:00Z", "2026-11-06T00:00:00Z"] {
            #expect(day(text, [task])?.planned == 2)
        }
        #expect(day("2026-11-09T00:00:00Z", [task]) == nil)
    }

    @Test("A weekend inside the task has no hours; a NoGantt holiday is not a working day either")
    func weekendAndHoliday() {
        let task = C.item("t", kind: .ganttTask, start: "2026-11-06T09:00:00Z", end: "2026-11-09T17:00:00Z", work: 10)
        #expect(day("2026-11-06T00:00:00Z", [task])?.planned == 5)
        #expect(day("2026-11-07T00:00:00Z", [task]) == nil)
        #expect(day("2026-11-09T00:00:00Z", [task])?.planned == 5)
        var withHoliday = pattern
        withHoliday.holidays = ["2026-11-09"]
        #expect(day("2026-11-06T00:00:00Z", [task], withHoliday)?.planned == 10)
        #expect(day("2026-11-09T00:00:00Z", [task], withHoliday) == nil)
    }

    @Test("Free is the working hours minus my busy events; tentative counts as busy; overlapping events count once")
    func free() {
        let task = C.item("t", kind: .ganttTask, start: "2026-11-02T09:00:00Z", end: "2026-11-02T17:00:00Z", work: 6)
        let events = [C.item("a", start: "2026-11-02T10:00:00Z", end: "2026-11-02T11:30:00Z"),
                      C.item("b", start: "2026-11-02T11:00:00Z", end: "2026-11-02T12:00:00Z", status: "TENTATIVE"),
                      C.item("outside", start: "2026-11-02T18:00:00Z", end: "2026-11-02T19:00:00Z")]
        let load = day("2026-11-02T00:00:00Z", [task] + events)
        #expect(load?.planned == 6 && load?.free == 6)
        #expect(load?.isOver == false)
        #expect(load?.text == "6 h planned / 6 h free")
    }

    @Test("6 planned against 4 free is overbooked, with the sentence of the bar")
    func overbooked() {
        let task = C.item("t", kind: .ganttTask, start: "2026-11-03T09:00:00Z", end: "2026-11-03T17:00:00Z", work: 6)
        let busy = C.item("e", start: "2026-11-03T09:00:00Z", end: "2026-11-03T13:00:00Z")
        let load = day("2026-11-03T00:00:00Z", [task, busy])
        #expect(load?.isOver == true)
        #expect(load?.text == "6 h planned / 4 h free")
        #expect(AgendaWorkload.number(3.5) == "3.5" && AgendaWorkload.number(3.04) == "3")
    }

    @Test("An agent's items never take my time: its event does not lower my free hours")
    func agentEvents() {
        let mine = C.item("e", start: "2026-11-02T09:00:00Z", end: "2026-11-02T10:00:00Z")
        let bot = C.item("bot", start: "2026-11-02T10:00:00Z", end: "2026-11-02T16:00:00Z", agent: C.writer)
        #expect(day("2026-11-02T00:00:00Z", [mine, bot])?.free == 7)
        #expect(day("2026-11-02T00:00:00Z", [bot]) == nil)
    }

    @Test("A task without work is counted as no estimate and adds no hours; the share of a task an agent does is mine")
    func noEstimate() {
        let none = C.item("t", kind: .ganttTask, start: "2026-11-02T09:00:00Z", end: "2026-11-02T17:00:00Z")
        let load = day("2026-11-02T00:00:00Z", [none])
        #expect(load?.planned == 0 && load?.noEstimate == 1)
        let supervised = C.item("s", kind: .ganttTask, start: "2026-11-02T09:00:00Z", end: "2026-11-02T17:00:00Z", agent: C.writer, work: 1)
        #expect(day("2026-11-02T00:00:00Z", [supervised])?.planned == 1)
    }

    @Test("An all-day busy event is a day off: nothing is free")
    func allDayBusy() {
        let off = C.item("off", start: "2026-11-02T00:00:00Z", end: "2026-11-03T00:00:00Z", allDay: true)
        let task = C.item("t", kind: .ganttTask, start: "2026-11-02T09:00:00Z", end: "2026-11-02T17:00:00Z", work: 2)
        let load = day("2026-11-02T00:00:00Z", [off, task])
        #expect(load?.free == 0 && load?.isOver == true)
        #expect(day("2026-11-03T00:00:00Z", [off, task]) == nil)
    }

    @Test("Work in person-days is counted in hours of one person-day")
    func units() {
        #expect(NCAgendaWorkUnits.hours(2, unit: "pt", hoursPerPt: 7.5) == 15)
        #expect(NCAgendaWorkUnits.hours(2, unit: "pt", hoursPerPt: nil) == 16)
        #expect(NCAgendaWorkUnits.hours(3, unit: "h", hoursPerPt: 7.5) == 3)
        #expect(NCAgendaWorkUnits.hours(3, unit: nil, hoursPerPt: 7.5) == 3)
    }

    @Test("My pattern: the schedule of my planning person and NoGantt's hours; else the settings; holidays of my calendar")
    func patterns() {
        var gantt = RawGantt()
        gantt.resources = [GanttResource(id: 1, name: "Ali", type: "person", uid: "ali", uidDisplayName: "Ali", unit: "h", calendarId: 3)]
        gantt.workSchedules = [GanttWorkSchedule(resourceId: 1, workDays: 0b0011110)]
        gantt.workStart = "08:30"
        gantt.workEnd = "16:30"
        gantt.holidays = [GanttHoliday(date: "2026-12-25", calendarId: 3), GanttHoliday(date: "2026-12-26", calendarId: 9)]
        let pattern = AgendaWorkPattern.make(settings: AgendaSettings(), gantt: gantt, userId: "ali")
        #expect(pattern.days == [1, 2, 3, 4])
        #expect(pattern.startMinutes == 8 * 60 + 30 && pattern.endMinutes == 16 * 60 + 30 && pattern.hours == 8)
        #expect(pattern.holidays == ["2026-12-25"])
        let plain = AgendaWorkPattern.make(settings: AgendaSettings(), gantt: nil, userId: "ali")
        #expect(plain.days == [0, 1, 2, 3, 4] && plain.hours == 8)
        #expect(AgendaWorkPattern.make(settings: AgendaSettings(), gantt: nil, userId: "ali", everyDayWorks: true).days == Set(0...6))
    }
}

@Suite("NoDrive NoAgenda days off and blocked")
struct NoDriveAgendaDayOffTests {
    typealias C = AgendaConflictSupport
    typealias S = AgendaEditSupport

    func marked(_ items: [AgendaItem], _ pattern: AgendaWorkPattern = AgendaWorkPattern()) -> [AgendaItem] {
        NCAgendaConflicts.mark(items, pattern: pattern, calendar: S.calendar)
    }

    @Test("A deadline on a Saturday is on a day off; a Wednesday one is not")
    func weekend() {
        let rows = marked([C.item("sat", kind: .todo, due: "2026-11-07T10:00:00Z"), C.item("wed", kind: .todo, due: "2026-11-04T10:00:00Z"),
                           C.item("end", kind: .ganttTask, start: "2026-11-05T09:00:00Z", end: "2026-11-08T17:00:00Z")])
        #expect(rows.map(\.dayOff) == [true, false, true])
    }

    @Test("A NoGantt holiday and an all-day busy event are days off too")
    func holidayAndAllDay() {
        var pattern = AgendaWorkPattern()
        pattern.holidays = ["2026-11-04"]
        let off = C.item("off", start: "2026-11-05T00:00:00Z", end: "2026-11-06T00:00:00Z", allDay: true)
        let rows = marked([C.item("holiday", kind: .todo, due: "2026-11-04T10:00:00Z"), C.item("busy", kind: .todo, due: "2026-11-05T10:00:00Z"),
                           C.item("free", kind: .todo, due: "2026-11-03T10:00:00Z"), off], pattern)
        #expect(rows.prefix(3).map(\.dayOff) == [true, true, false])
        // A free all-day event is not a day off
        var transparent = off
        transparent.transparent = true
        #expect(marked([C.item("busy", kind: .todo, due: "2026-11-05T10:00:00Z"), transparent]).first?.dayOff == false)
    }

    @Test("Agent items and other people's rows have no day-off mark of mine")
    func notMine() {
        let rows = marked([C.item("bot", kind: .todo, due: "2026-11-07T10:00:00Z", agent: C.writer),
                           C.item("team", kind: .todo, due: "2026-11-07T10:00:00Z", relation: .team)])
        #expect(rows.allSatisfy { !$0.dayOff })
    }

    @Test("Blocked: a task with a late predecessor is blocked; the assembler sets it (design 7)")
    func blocked() {
        var gantt = RawGantt()
        gantt.linked = true
        gantt.projects = [GanttProject(id: 1, title: "P", color: nil, ownerId: "mara", ownerName: nil, permission: "editor")]
        gantt.resources = [GanttResource(id: 1, name: "Ali", type: "person", uid: "ali", uidDisplayName: "Ali")]
        gantt.myTasks = [GanttMyTask(id: 2, title: "B", projectId: 1, projectTitle: "P", start: nil, end: nil, progress: nil, status: "not_started")]
        let late = GanttTask(id: 1, projectId: 1, title: "A", start: "2026-10-20 09:00:00", end: "2026-10-22 17:00:00", status: "in_progress",
                             resources: [GanttResourceRow(resourceId: 1, work: 1)])
        let next = GanttTask(id: 2, projectId: 1, title: "B", start: "2026-10-30 09:00:00", end: "2026-10-31 17:00:00", status: "not_started",
                             dependencies: [GanttDependency(predecessorId: "t-1", type: "FS", lagDays: 0)],
                             resources: [GanttResourceRow(resourceId: 1, work: 1)])
        gantt.tasks = ["1": [late, next]]
        let snapshot = NCAgendaAssembler.assemble(AgendaInputs(me: AgendaMe(userId: "ali", displayName: "Ali"), gantt: gantt, now: S.now, calendar: S.calendar))
        #expect(snapshot.items.first { $0.title == "B" }?.blocked == true)
        #expect(snapshot.items.first { $0.title == "B" }.map(NCAgendaConflicts.hasConflict) == true)
    }
}

@Suite("NoDrive NoAgenda agent load")
struct NoDriveAgendaAgentLoadTests {
    typealias C = AgendaConflictSupport
    typealias S = AgendaEditSupport

    static func agent(capacity: Double = 40, days: [Int] = [0, 1, 2, 3, 4], daysOff: [String] = [], zone: String? = nil) -> RegistryAgent {
        var agent = S.agent("AG-0001", "Writer-Bot", resources: [10])
        agent.availability = AgentAvailability(timezone: zone, days: days, capacityHoursPerWeek: capacity, daysOff: daysOff)
        return agent
    }

    static func gantt(work: Double, start: String = "2026-11-04 09:00:00", end: String = "2026-11-04 17:00:00") -> RawGantt {
        var gantt = RawGantt()
        gantt.timezone = "UTC"
        gantt.resources = [GanttResource(id: 1, name: "Ali", type: "person", uid: "ali", uidDisplayName: "Ali"),
                           GanttResource(id: 10, name: "🤖 Writer-Bot (Ali)", type: "person", uid: nil, uidDisplayName: nil)]
        gantt.tasks = ["1": [GanttTask(id: 1, projectId: 1, title: "Copy", start: start, end: end, status: "in_progress",
                                       resources: [GanttResourceRow(resourceId: 1, work: 1), GanttResourceRow(resourceId: 10, work: work)])]]
        return gantt
    }

    func problems(_ agent: RegistryAgent, _ gantt: RawGantt, items: [AgendaItem] = []) -> [AgendaProblem] {
        NCAgendaAgentLoad.problems(registry: NCAgendaRegistry(agents: [agent]), me: AgendaMe(userId: "ali", displayName: "Ali"), gantt: gantt,
                                   items: items, now: S.now, calendar: S.calendar)
    }

    @Test("Over its daily capacity (40 h a week over five days is 8 h) an agent is overbooked on that day: 'Writer-Bot is overbooked on Wednesday'")
    func overbooked() {
        let found = problems(Self.agent(), Self.gantt(work: 12))
        #expect(found.count == 1)
        #expect(found.first?.text.contains("Writer-Bot is overbooked on Wednesday") == true)
        #expect(found.first?.relation == .mine && found.first?.kind == .overbooked)
        #expect(problems(Self.agent(), Self.gantt(work: 8)).isEmpty)
    }

    @Test("Work is spread over the days of the agent's pattern, and its days off take no work")
    func spreadAndDaysOff() {
        let week = Self.gantt(work: 20, start: "2026-11-02 09:00:00", end: "2026-11-06 17:00:00")
        #expect(problems(Self.agent(), week).isEmpty)   // 4 h a day
        let shortWeek = Self.agent(daysOff: ["2026-11-04", "2026-11-05", "2026-11-06"])
        #expect(problems(shortWeek, week).count == 2)   // 20 h on Monday and Tuesday only: 10 h a day against 8
        #expect(problems(Self.agent(days: [0, 1, 2, 3, 4]), Self.gantt(work: 12, start: "2026-11-07 09:00:00", end: "2026-11-08 17:00:00")).isEmpty)   // a weekend: no working day
    }

    @Test("The agent's own timed events count for the agent, and no capacity in the registry means no report")
    func eventsAndMissingCapacity() {
        let long = C.item("e", start: "2026-11-04T08:00:00Z", end: "2026-11-04T18:00:00Z", agent: C.writer)
        #expect(problems(Self.agent(), RawGantt(), items: [long]).count == 1)
        var noCapacity = Self.agent()
        noCapacity.availability = AgentAvailability(timezone: nil, days: [], capacityHoursPerWeek: nil, daysOff: [])
        #expect(problems(noCapacity, Self.gantt(work: 99)).isEmpty)
        var retired = Self.agent()
        retired.status = .retired
        #expect(problems(retired, Self.gantt(work: 99)).isEmpty)
    }

    @Test("An agent's hours never count for the person: the person's own share is all that is planned")
    func notForThePerson() {
        let task = C.item("t", kind: .ganttTask, start: "2026-11-04T09:00:00Z", end: "2026-11-04T17:00:00Z", agent: C.writer, work: 1)
        let load = NCAgendaWorkload.day(C.at("2026-11-04T00:00:00Z"), items: [task], pattern: AgendaWorkPattern(), calendar: S.calendar)
        #expect(load?.planned == 1 && load?.isOver == false)
    }

    @Test("Days are looked at from today for 28 days")
    func horizon() {
        let far = Self.gantt(work: 99, start: "2026-12-30 09:00:00", end: "2026-12-30 17:00:00")
        #expect(problems(Self.agent(), far).isEmpty)
        let near = Self.gantt(work: 99, start: "2026-11-26 09:00:00", end: "2026-11-26 17:00:00")
        #expect(problems(Self.agent(), near).count == 1)
    }

    @Test("The registry's availability is read: weekly days, capacity, days off, time zone")
    func registryAvailability() throws {
        let json = """
        {"schema":"nourax-agent-registry","version":1,"agents":[{"id":"AG-1","name":"B","person":"ali","status":"active","organisation":"o",
         "availability":{"timezone":"Europe/London","weekly":[{"days":["mon","tue","fri"],"from":"09:00","to":"17:00"}],"capacity_hours_per_week":30,"days_off":["2026-12-25"]}}]}
        """
        guard case let .valid(registry) = NCAgendaRegistry.parse(Data(json.utf8)) else { Issue.record("invalid"); return }
        let availability = try #require(registry.agents.first?.availability)
        #expect(availability.days == [0, 1, 4] && availability.capacityHoursPerWeek == 30 && availability.daysOff == ["2026-12-25"])
        #expect(availability.timezone == "Europe/London" && availability.dailyCapacity == 10)
        #expect(AgentAvailability().workDays == Set(0...6))
    }
}

@Suite("NoDrive NoAgenda waiting edits on the rows")
struct NoDriveAgendaOverlayTests {
    typealias C = AgendaConflictSupport
    typealias S = AgendaEditSupport

    static func command(_ kind: NCAgendaEditCommand.Kind, key: String?) -> NCAgendaEditCommand {
        NCAgendaEditCommand(id: UUID(), kind: kind, createdAt: S.now, itemKey: key, title: "T", sourceKey: "cal:work",
                            link: AgendaLink(home: .calendar))
    }

    func overlay(_ commands: [NCAgendaEditCommand], _ items: [AgendaItem]) -> [AgendaItem] {
        NCAgendaEditOverlay.apply(commands, to: items, sources: [AgendaSource(key: "cal:work", kind: .calendar, name: "Work", color: "#112233", setting: .work)],
                                  ganttZone: S.zone, calendar: S.calendar)
    }

    @Test("A waiting change is drawn on its row with the clock mark; the data itself is not changed")
    func draws() {
        let original = C.item("a", start: "2026-11-02T10:00:00Z", end: "2026-11-02T11:00:00Z")
        var command = Self.command(.calendarPatch, key: "a")
        var change = CalendarChange()
        change.title = "Renamed"
        change.start = S.date("2026-11-02T12:00:00Z")
        change.end = S.date("2026-11-02T13:00:00Z")
        command.calendar = change
        let rows = overlay([command], [original])
        #expect(rows.first?.title == "Renamed" && rows.first?.pending == true && rows.first?.start == S.date("2026-11-02T12:00:00Z"))
        #expect(original.title == "a" && original.pending == false)
        // A change that is Not sent is not drawn
        var unsent = command
        unsent.state = .notSent(NCAgendaNotSent(kind: .refused, text: "x"))
        #expect(overlay([unsent], [original]).first?.title == "a")
    }

    @Test("A done or deleted item leaves the list; a new item is drawn from its command with its source")
    func doneAndNew() {
        let todo = C.item("t", kind: .todo, due: "2026-11-02T10:00:00Z")
        var done = Self.command(.calendarPatch, key: "t")
        done.calendar = CalendarChange(done: true)
        #expect(overlay([done], [todo]).isEmpty)
        let delete = Self.command(.calendarDelete, key: "t")
        #expect(overlay([delete], [todo]).isEmpty)
        var create = Self.command(.calendarCreate, key: nil)
        var change = CalendarChange()
        change.title = "Brand new"
        change.start = S.date("2026-11-02T09:00:00Z")
        create.calendar = change
        create.component = "VEVENT"
        create.agent = AgentChoice(id: "AG-0001", name: "Writer-Bot")
        let rows = overlay([create], [])
        #expect(rows.count == 1 && rows[0].title == "Brand new" && rows[0].pending && rows[0].sourceName == "Work" && rows[0].agent.isMine)
        #expect(rows[0].key.hasPrefix("pending:"))
    }

    @Test("The agent of a Gantt task and a card is drawn at once, and dates keep the time of day")
    func ganttAndCards() {
        var task = C.item("gantt:1", kind: .ganttTask, start: "2026-11-02T09:00:00Z", end: "2026-11-04T17:00:00Z")
        task.home = .gantt
        var move = Self.command(.ganttUpdate, key: "gantt:1")
        move.gantt = GanttChange(startDay: "2026-11-03", endDay: "2026-11-05", percent: 60)
        var agent = Self.command(.ganttAgent, key: "gantt:1")
        agent.agent = AgentChoice(id: "AG-0001", name: "Writer-Bot")
        let rows = overlay([move, agent], [task])
        #expect(rows.first?.start == S.date("2026-11-03T09:00:00Z") && rows.first?.end == S.date("2026-11-05T17:00:00Z"))
        #expect(rows.first?.percent == 60 && rows.first?.agent.isMine == true)
    }

    @Test("The pipeline marks clashes on the shown rows and adds the agent's overbooking as a problem")
    func pipeline() {
        var snapshot = AgendaSnapshot()
        snapshot.items = [C.item("a", start: "2026-11-04T10:00:00Z", end: "2026-11-04T11:00:00Z"), C.item("b", start: "2026-11-04T10:30:00Z", end: "2026-11-04T11:30:00Z")]
        var context = AgendaEditContext()
        context.me = AgendaMe(userId: "ali", displayName: "Ali")
        context.gantt = NoDriveAgendaAgentLoadTests.gantt(work: 12)
        context.registry = NCAgendaRegistry(agents: [NoDriveAgendaAgentLoadTests.agent()])
        let shown = NCAgendaEditPipeline.display(snapshot, commands: [], context: context, now: S.now, calendar: S.calendar)
        #expect(shown.items.map(\.clash) == [.hard, .hard])
        #expect(shown.problems.contains { $0.kind == .overbooked && $0.text.contains("Writer-Bot is overbooked") })
        // Without a person nothing is changed
        #expect(NCAgendaEditPipeline.display(snapshot, commands: [], context: AgendaEditContext(), now: S.now, calendar: S.calendar) == snapshot)
    }

    @Test("A problem of an overbooked agent shows on its own day, and only there")
    func plannerShowsOnItsDay() {
        var snapshot = AgendaSnapshot()
        let day = S.date("2026-11-04T00:00:00Z")
        snapshot.problems = [AgendaProblem(key: "mine:agent-over:AG-0001:2026-11-04", kind: .overbooked, relation: .mine, title: "Writer-Bot", text: "x", date: day, link: nil, home: .gantt)]
        let there = NCAgendaPlanner.plan(day: day, snapshot: snapshot, filter: AgendaFilter(), showAllTeam: false, now: S.now, calendar: S.calendar)
        let elsewhere = NCAgendaPlanner.plan(day: S.date("2026-11-05T00:00:00Z"), snapshot: snapshot, filter: AgendaFilter(), showAllTeam: false, now: S.now, calendar: S.calendar)
        let today = NCAgendaPlanner.plan(day: S.now, snapshot: snapshot, filter: AgendaFilter(), showAllTeam: false, now: S.now, calendar: S.calendar)
        #expect(there.ownProblems.count == 1 && elsewhere.ownProblems.isEmpty && today.ownProblems.isEmpty)
        #expect(NCAgendaEditConflictsFilter.apply(there).ownProblems.count == 1)
    }
}
