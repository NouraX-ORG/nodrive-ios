// SPDX-FileCopyrightText: 2026 Nourax
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import Nextcloud

/// End-to-end proof of the Swift request builders. The real writers are driven on fixtures that copy the CI seed
/// (tools/ci/agenda-seed.py), and every request they build is written to
/// `$NODRIVE_EXPORT_DIR/agenda-requests.json`: method, path with symbolic ids such as `{task:Banner design}`, the names
/// of the headers that matter, and the body (no credential). The CI job `agenda-replay` sends exactly these requests to a
/// real throwaway server (tools/ci/agenda-replay.py) and reads the result back.
final class AgendaExportRecorder: @unchecked Sendable {
    struct Entry {
        var method: String
        var path: String
        var headers: [String: String]
        var body: String
    }

    private let lock = NSLock()
    private var entries: [Entry] = []
    var scenarios: [[String: Any]] = []

    static let tasks: [Int: String] = [501: "Write homepage copy", 502: "Publish banners", 503: "Banner design"]
    static let resources: [Int: String] = [1: "ali", 10: "writer", 11: "research"]
    static let labels: [Int: String] = [7: "Writer-Bot", 8: "Research-Bot"]
    static let cards: [Int: String] = [21: "Plain card"]

    func record(_ request: URLRequest) {
        lock.lock()
        defer { lock.unlock() }
        guard let method = request.httpMethod, method != "GET" else { return }
        var headers: [String: String] = [:]
        if let type = request.value(forHTTPHeaderField: "Content-Type") { headers["Content-Type"] = type }
        if request.value(forHTTPHeaderField: "If-Match") != nil { headers["If-Match"] = "{etag}" }
        if let none = request.value(forHTTPHeaderField: "If-None-Match") { headers["If-None-Match"] = none }
        headers["OCS-APIRequest"] = request.value(forHTTPHeaderField: "OCS-APIRequest") ?? ""
        var path = request.url?.path ?? ""
        path = Self.symbolic(path)
        var body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
        if headers["Content-Type"]?.contains("json") == true, let data = request.httpBody,
           let object = try? JSONSerialization.jsonObject(with: data) {
            var walked = Self.walk(object, key: nil)
            // A card update is a full replace: what was passed through from the fresh card is a token; the replay fills
            // it from the real fresh card.
            if var card = walked as? [String: Any], card["owner"] != nil, card["title"] != nil {
                for key in ["title", "description", "type", "owner", "order", "startdate", "archived", "color"] where card[key] != nil && !(card[key] is NSNull) {
                    card[key] = "{fresh:\(key)}"
                }
                if card["duedate"] as? String == "2026-11-01T12:00:00+00:00" { card["duedate"] = "{fresh:duedate}" }
                walked = card
            }
            if let out = try? JSONSerialization.data(withJSONObject: walked, options: [.sortedKeys]) { body = String(decoding: out, as: UTF8.self) }
        }
        entries.append(Entry(method: method, path: path, headers: headers, body: body))
    }

    /// The requests since the last call, as a scenario.
    func finish(_ name: String) {
        lock.lock()
        let taken = entries
        entries = []
        lock.unlock()
        scenarios.append(["name": name, "requests": taken.map { entry in
            ["method": entry.method, "path": entry.path, "headers": entry.headers, "body": entry.body] as [String: Any]
        }])
    }

    static func symbolic(_ path: String) -> String {
        var result = path
        for (id, name) in tasks { result = result.replacingOccurrences(of: "/tasks/\(id)", with: "/tasks/{task:\(name)}") }
        result = result.replacingOccurrences(of: "/boards/1/stacks/2/cards/21", with: "/boards/{board}/stacks/{stack}/cards/{card:Plain card}")
        result = result.replacingOccurrences(of: "/boards/1/labels", with: "/boards/{board}/labels")
        return result
    }

    static func walk(_ value: Any, key: String?) -> Any {
        if let dictionary = value as? [String: Any] {
            return dictionary.reduce(into: [String: Any]()) { $0[$1.key] = walk($1.value, key: $1.key) }
        }
        if let list = value as? [Any] { return list.map { walk($0, key: key) } }
        if let number = value as? Int {
            if key == "resource_id", let name = resources[number] { return "{resource:\(name)}" }
            if key == "labelId", let name = labels[number] { return "{label:\(name)}" }
        }
        return value
    }

    func write() throws {
        guard let directory = ProcessInfo.processInfo.environment["NODRIVE_EXPORT_DIR"], !directory.isEmpty else { return }
        let folder = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let payload: [String: Any] = ["version": 1, "base_day": "2026-10-30", "scenarios": scenarios]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: folder.appendingPathComponent("agenda-requests.json"))
    }
}

@Suite("NoDrive NoAgenda request export", .serialized)
struct NoDriveAgendaRequestExportTests {
    typealias S = AgendaEditSupport

    /// The seed's objects, as the CI seed writes them (the day is 2026-10-30; the replay moves it to the run's day).
    static func seedEvent(_ uid: String, _ summary: String, extra: [String] = []) -> String {
        (["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Nourax//NoAgenda CI//EN", "BEGIN:VEVENT", "UID:" + uid, "DTSTAMP:20261030T090000Z",
          "SUMMARY:" + summary, "DTSTART:20261030T100000Z", "DTEND:20261030T110000Z"] + extra + ["END:VEVENT", "END:VCALENDAR", ""]).joined(separator: "\r\n")
    }

    static let keepLines = ["BEGIN:VALARM", "ACTION:DISPLAY", "TRIGGER:-PT15M", "DESCRIPTION:Reminder", "END:VALARM", "X-CI-UNKNOWN:keep-me"]
    static let tags: Set<String> = ["agent:AG-0001"]
    static let writerWrite = CalendarChange.AgentWrite(id: "AG-0001", tag: "agent:AG-0001")

    static func calendarHTTP(_ recorder: AgendaExportRecorder, text: String, putStatus: Int = 204) -> NCAgendaHTTP {
        EditFakeServer { request, _ in
            recorder.record(request)
            if request.httpMethod == "GET" { return .init(status: 200, body: text, headers: ["ETag": "\"e1\""]) }
            return .init(status: putStatus)
        }.http()
    }

    static func writer(_ http: NCAgendaHTTP) -> NCAgendaCalDAVWriter {
        NCAgendaCalDAVWriter(http: http, agentTags: tags, myAddresses: ["ali@example.org"], zone: S.zone, now: { S.now })
    }

    @Test("The requests of every edit of design section 9 are built and exported for the replay on a real server")
    func export() async throws {
        let recorder = AgendaExportRecorder()
        let work = "/remote.php/dav/calendars/ali/work/"
        let personal = "/remote.php/dav/calendars/ali/personal/"

        // Events and to-dos (CalDAV)
        var move = CalendarChange()
        move.title = "Dentist (moved)"
        move.start = S.date("2026-10-30T11:00:00Z")
        move.end = S.date("2026-10-30T12:00:00Z")
        let dentist = Self.seedEvent("ci-dentist", "Dentist", extra: Self.keepLines)
        #expect(await Self.writer(Self.calendarHTTP(recorder, text: dentist)).patch(path: personal + "dentist.ics", seenEtag: nil, change: move) == .plainSaved)
        recorder.finish("event-edit")

        var on = CalendarChange()
        on.agent = Self.writerWrite
        let onText = Self.seedEvent("ci-dentist", "Dentist (moved)", extra: Self.keepLines)
        #expect(await Self.writer(Self.calendarHTTP(recorder, text: onText)).patch(path: personal + "dentist.ics", seenEtag: nil, change: on) == .plainSaved)
        recorder.finish("event-agent-on")

        var off = CalendarChange()
        off.agent = .init(id: nil, tag: nil)
        let tagged = Self.seedEvent("ci-dentist", "Dentist (moved)", extra: Self.keepLines + ["X-NOURAX-AGENT-ID:AG-0001", "CATEGORIES:agent:AG-0001"])
        #expect(await Self.writer(Self.calendarHTTP(recorder, text: tagged)).patch(path: personal + "dentist.ics", seenEtag: nil, change: off) == .plainSaved)
        recorder.finish("event-agent-off")

        var done = CalendarChange()
        done.done = true
        let draft = ["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Nourax//NoAgenda CI//EN", "BEGIN:VTODO", "UID:ci-draft", "DTSTAMP:20261030T090000Z",
                     "SUMMARY:Draft report", "DUE:20261030T150000Z", "X-NOURAX-AGENT-ID:AG-0001", "CATEGORIES:agent:AG-0001", "END:VTODO", "END:VCALENDAR", ""].joined(separator: "\r\n")
        #expect(await Self.writer(Self.calendarHTTP(recorder, text: draft)).patch(path: personal + "draft-report.ics", seenEtag: nil, change: done) == .plainSaved)
        recorder.finish("todo-done")

        // An all-day event (days, with the exclusive DTEND): its title and day change and it stays all-day, with the alarm and the
        // unknown property
        let allDayText = ["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Nourax//NoAgenda CI//EN", "BEGIN:VEVENT", "UID:ci-replay-allday", "DTSTAMP:20261030T090000Z",
                          "SUMMARY:Open day", "DTSTART;VALUE=DATE:20261029", "DTEND;VALUE=DATE:20261030", "X-CI-UNKNOWN:keep-me",
                          "END:VEVENT", "END:VCALENDAR", ""].joined(separator: "
")
        var allDay = CalendarChange()
        allDay.title = "Open day (moved)"
        allDay.allDay = true
        allDay.start = S.date("2026-11-02T00:00:00Z")
        allDay.end = S.date("2026-11-03T00:00:00Z")
        #expect(await Self.writer(Self.calendarHTTP(recorder, text: allDayText)).patch(path: personal + "ci-replay-allday.ics", seenEtag: nil, change: allDay) == .plainSaved)
        recorder.finish("event-all-day")

        // A date-only to-do (as Reminders writes it): its due date moves and it stays date-only (a mix of DATE and DATE-TIME gives 415)
        let reminder = ["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Nourax//NoAgenda CI//EN", "BEGIN:VTODO", "UID:ci-replay-todo", "DTSTAMP:20261030T090000Z",
                        "SUMMARY:Pay rent", "DTSTART;VALUE=DATE:20261029", "DUE;VALUE=DATE:20261030", "END:VTODO", "END:VCALENDAR", ""].joined(separator: "\r\n")
        var reminderDue = CalendarChange()
        reminderDue.due = S.date("2026-11-01T10:00:00Z")
        #expect(await Self.writer(Self.calendarHTTP(recorder, text: reminder)).patch(path: personal + "ci-replay-todo.ics", seenEtag: nil, change: reminderDue) == .plainSaved)
        recorder.finish("todo-date-only")

        var created = CalendarChange()
        created.title = "Replay event"
        created.start = S.date("2026-10-30T13:00:00Z")
        created.end = S.date("2026-10-30T14:00:00Z")
        created.agent = Self.writerWrite
        let newText = NCAgendaICalPatch.make(kind: "VEVENT", uid: "ci-replay-event", change: created, now: S.now, zone: S.zone)
        #expect(await Self.writer(Self.calendarHTTP(recorder, text: "", putStatus: 201)).create(path: work + "ci-replay-event.ics", ics: newText) == .plainSaved)
        recorder.finish("event-create")
        #expect(await Self.writer(Self.calendarHTTP(recorder, text: newText)).delete(path: work + "ci-replay-event.ics", seenEtag: "\"e1\"") == .plainSaved)
        recorder.finish("event-delete")

        // NoGantt
        func tasksJSON(_ rows: String) -> String {
            """
            {"ocs":{"data":[{"id":503,"project_id":5,"title":"Banner design","start_date":"2026-10-26 09:00:00","end_date":"2026-10-28 17:00:00","work":8,
             "updated_at":"2026-10-30 08:00:00","status":"not_started","dependencies":[],"resources":[]},
             {"id":501,"project_id":5,"title":"Write homepage copy","start_date":"2026-10-28 09:00:00","end_date":"2026-10-31 17:00:00","work":8,
             "updated_at":"2026-10-30 08:00:00","status":"in_progress","dependencies":[],"resources":\(rows)}]}}
            """
        }
        func ganttHTTP(_ rows: String, answer: String) -> NCAgendaHTTP {
            EditFakeServer { request, _ in
                recorder.record(request)
                return request.httpMethod == "GET" ? .init(status: 200, body: tasksJSON(rows)) : .init(status: 200, body: answer)
            }.http()
        }
        let answer = "{\"ocs\":{\"data\":{\"task\":{\"id\":503,\"start_date\":\"2026-10-26 09:00:00\",\"end_date\":\"2026-10-31 17:00:00\"},\"propagated\":[],\"op_id\":\"op-1\"}}}"
        var movedEnd = GanttChange()
        movedEnd.endDay = "2026-10-31"
        guard case .saved = await NCAgendaGanttWriter(http: ganttHTTP("[{\"resource_id\":1,\"work\":4}]", answer: answer)).update(projectId: 5, taskId: 503, seenUpdatedAt: nil, change: movedEnd) else {
            Issue.record("the move was not built")
            return
        }
        recorder.finish("gantt-move")
        _ = await NCAgendaGanttWriter(http: ganttHTTP("[{\"resource_id\":1,\"work\":4}]", answer: answer)).undo(opId: "{op}")
        recorder.finish("gantt-undo")
        var percent = GanttChange()
        percent.percent = 70
        _ = await NCAgendaGanttWriter(http: ganttHTTP("[{\"resource_id\":1,\"work\":4}]", answer: answer)).update(projectId: 5, taskId: 501, seenUpdatedAt: nil, change: percent)
        recorder.finish("gantt-percent")
        // A status the editor offers (NoGantt accepts not_started, in_progress, blocked and done)
        var status = GanttChange()
        status.status = "in_progress"
        _ = await NCAgendaGanttWriter(http: ganttHTTP("[{\"resource_id\":1,\"work\":4}]", answer: answer)).update(projectId: 5, taskId: 503, seenUpdatedAt: nil, change: status)
        recorder.finish("gantt-status")

        // "My agent": Writer-Bot to Self, then Self to Writer-Bot. The answer echoes what was sent.
        let context = NoDriveAgendaGanttAgentTests.context()
        let writerChoice = AgentChoice(AgendaEditSupport.agent("AG-0001", "Writer-Bot", resources: [10]))
        let toSelf = "{\"ocs\":{\"data\":{\"task\":{\"id\":501,\"resources\":[{\"resource_id\":1,\"work\":4}]}}}}"
        _ = await NCAgendaGanttWriter(http: ganttHTTP("[{\"resource_id\":1,\"work\":4},{\"resource_id\":10,\"work\":null}]", answer: toSelf))
            .changeAgent(projectId: 5, taskId: 501, seenUpdatedAt: nil, choice: .selfChoice, context: context)
        recorder.finish("gantt-agent-to-self")
        let toWriter = "{\"ocs\":{\"data\":{\"task\":{\"id\":501,\"resources\":[{\"resource_id\":1,\"work\":4},{\"resource_id\":10,\"work\":null}]}}}}"
        _ = await NCAgendaGanttWriter(http: ganttHTTP("[{\"resource_id\":1,\"work\":4}]", answer: toWriter))
            .changeAgent(projectId: 5, taskId: 501, seenUpdatedAt: nil, choice: writerChoice, context: context)
        recorder.finish("gantt-agent-to-writer")

        // NoBoard (Deck): the due date and the label. A fresh card with a description and a start date.
        let boardPath = "/index.php/apps/deck/api/v1.0/boards/1"
        func deckHTTP(labels: String) -> NCAgendaHTTP {
            let card = """
            {"id":21,"title":"Plain card","description":"FRESH","type":"plain","order":1,"duedate":"2026-11-01T12:00:00+00:00","startdate":"2026-10-28T09:00:00+00:00",
             "archived":false,"done":null,"owner":{"uid":"mara"},"lastModified":1,"labels":\(labels)}
            """
            return EditFakeServer { request, path in
                recorder.record(request)
                if path == boardPath {
                    return .init(status: 200, body: "{\"id\":1,\"labels\":[{\"id\":7,\"title\":\"🤖 Writer-Bot\"},{\"id\":8,\"title\":\"🤖 Research-Bot\"}],\"permissions\":{\"PERMISSION_MANAGE\":false}}")
                }
                return .init(status: 200, body: request.httpMethod == "GET" ? card : "{}")
            }.http()
        }
        var due = DeckChange()
        due.due = S.date("2026-11-03T12:00:00Z")
        _ = await NCAgendaDeckWriter(http: deckHTTP(labels: "[]")).update(board: 1, stack: 2, card: 21, seenLastModified: nil, change: due)
        recorder.finish("deck-due")
        let writerAgent = AgendaEditSupport.agent("AG-0001", "Writer-Bot", label: "🤖 Writer-Bot")
        _ = await NCAgendaDeckWriter(http: deckHTTP(labels: "[]")).changeAgent(board: 1, stack: 2, card: 21, seenLastModified: nil, choice: AgentChoice(writerAgent), myAgents: [writerAgent])
        recorder.finish("deck-agent-assign")
        _ = await NCAgendaDeckWriter(http: deckHTTP(labels: "[{\"id\":7,\"title\":\"🤖 Writer-Bot\"}]")).changeAgent(board: 1, stack: 2, card: 21, seenLastModified: nil, choice: .selfChoice, myAgents: [writerAgent])
        recorder.finish("deck-agent-remove")

        // What was built is what the replay expects
        let names = recorder.scenarios.compactMap { $0["name"] as? String }
        #expect(names.count == 17)
        for scenario in recorder.scenarios {
            let requests = scenario["requests"] as? [[String: Any]] ?? []
            let name = scenario["name"] as? String ?? ""
            if name == "gantt-agent-to-self" || name == "gantt-agent-to-writer" || name == "gantt-undo" || name == "todo-date-only" || name == "gantt-status" || name.hasPrefix("event") || name.hasPrefix("todo") || name.hasPrefix("gantt") {
                #expect(!requests.isEmpty, "\(name) built no request")
            }
        }
        // Reading a repeating event or an invitation builds no request at all
        let guardRecorder = AgendaExportRecorder()
        let repeating = Self.seedEvent("ci-standup", "Stand-up", extra: ["RRULE:FREQ=DAILY"])
        _ = await Self.writer(Self.calendarHTTP(guardRecorder, text: repeating)).patch(path: work + "standup.ics", seenEtag: nil, change: move)
        guardRecorder.finish("repeating")
        #expect((guardRecorder.scenarios.first?["requests"] as? [[String: Any]])?.isEmpty == true)
        try recorder.write()
    }
}
