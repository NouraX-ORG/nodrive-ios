// SPDX-FileCopyrightText: 2026 Nourax
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import Nextcloud

/// A canned server for the editing tests: every request is logged with its body, and a handler answers it.
final class EditFakeServer: @unchecked Sendable {
    struct Reply {
        var status: Int
        var body: String = ""
        var headers: [String: String] = [:]
    }

    private let lock = NSLock()
    private var log: [URLRequest] = []
    var handler: (URLRequest, String) throws -> Reply

    init(_ handler: @escaping (URLRequest, String) throws -> Reply) {
        self.handler = handler
    }

    var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return log
    }

    func requests(_ method: String) -> [URLRequest] {
        requests.filter { $0.httpMethod == method }
    }

    func body(_ request: URLRequest) -> String {
        String(decoding: request.httpBody ?? Data(), as: UTF8.self)
    }

    func http(user: String = "ali") -> NCAgendaHTTP {
        NCAgendaHTTP(account: "\(user) https://drive.test", base: "https://drive.test", userId: user, authorization: "Basic x",
                     userAgent: "NoDrive-test") { [self] request in
            lock.lock()
            log.append(request)
            lock.unlock()
            let path = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.path } ?? ""
            let reply = try handler(request, path)
            let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
            return (Data(reply.body.utf8), response)
        }
    }
}

enum AgendaEditSupport {
    static let zone = TimeZone(secondsFromGMT: 0)!
    static let now = ISO8601DateFormatter().date(from: "2026-10-30T12:00:00Z")!

    static var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = zone
        return value
    }

    static func date(_ text: String) -> Date {
        ISO8601DateFormatter().date(from: text)!
    }

    /// An event with an alarm, an attendee, an unknown property, other categories and an agent.
    static let eventICS = [
        "BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Test//EN",
        "BEGIN:VEVENT", "UID:ev-1", "DTSTAMP:20261001T080000Z", "SUMMARY:Client call",
        "DTSTART:20261030T100000Z", "DTEND:20261030T110000Z", "DESCRIPTION:Line one\\nLine two",
        "ATTENDEE;CN=Mara;PARTSTAT=ACCEPTED:mailto:mara@example.org", "X-CUSTOM-THING:keep me",
        "CATEGORIES:Work,agent:AG-0001", "X-NOURAX-AGENT-ID:AG-0001",
        "BEGIN:VALARM", "ACTION:DISPLAY", "TRIGGER:-PT15M", "DESCRIPTION:Reminder", "END:VALARM",
        "END:VEVENT", "END:VCALENDAR", ""
    ].joined(separator: "\r\n")

    static let todoICS = [
        "BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Test//EN",
        "BEGIN:VTODO", "UID:todo-1", "DTSTAMP:20261001T080000Z", "SUMMARY:Draft report", "DUE:20261030T150000Z",
        "X-NOURAX-AGENT-ID:AG-0001", "CATEGORIES:agent:AG-0001", "X-KEEP:yes",
        "END:VTODO", "END:VCALENDAR", ""
    ].joined(separator: "\r\n")

    static let tags: Set<String> = ["agent:AG-0001", "agent:AG-0002"]

    static func lines(_ text: String) -> [String] {
        text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    static func patch(_ change: CalendarChange, _ ics: String = eventICS) -> String {
        NCAgendaICalPatch.apply(change, to: ics, agentTags: tags, now: now, zone: zone) ?? ""
    }

    static func agent(_ id: String, _ name: String, resources: [Int] = [], label: String? = nil, status: AgentStatus = .active, person: String = "ali") -> RegistryAgent {
        RegistryAgent(id: id, name: name, person: person, status: status, organisation: "demo-org", ganttResourceIds: resources,
                      boardLabel: label, calendarTag: "agent:" + id)
    }
}

// MARK: - The patcher

@Suite("NoDrive NoAgenda iCalendar patch")
struct NoDriveAgendaICalPatchTests {
    typealias S = AgendaEditSupport

    @Test("A new title changes the title only: alarm, attendee, unknown property and other categories stay byte for byte")
    func titleOnly() {
        var change = CalendarChange()
        change.title = "Client call (moved)"
        let out = S.patch(change)
        let lines = S.lines(out)
        #expect(lines.contains("SUMMARY:Client call (moved)"))
        for kept in ["ATTENDEE;CN=Mara;PARTSTAT=ACCEPTED:mailto:mara@example.org", "X-CUSTOM-THING:keep me", "CATEGORIES:Work,agent:AG-0001",
                     "X-NOURAX-AGENT-ID:AG-0001", "BEGIN:VALARM", "ACTION:DISPLAY", "TRIGGER:-PT15M", "END:VALARM", "DTSTART:20261030T100000Z",
                     "DTEND:20261030T110000Z", "UID:ev-1", "DESCRIPTION:Line one\\nLine two"] {
            #expect(lines.contains(kept), "\(kept) was lost")
        }
        #expect(lines.contains("SEQUENCE:1"))
        #expect(lines.contains("DTSTAMP:20261030T120000Z"))
        #expect(lines.contains("LAST-MODIFIED:20261030T120000Z"))
        #expect(out.contains("\r\n"))
        #expect(!out.replacingOccurrences(of: "\r\n", with: "").contains("\n"))
    }

    @Test("A change of the time writes UTC and keeps the rest; SEQUENCE grows by one")
    func times() {
        var change = CalendarChange()
        change.start = S.date("2026-10-31T09:30:00Z")
        change.end = S.date("2026-10-31T10:15:00Z")
        change.allDay = false
        let lines = S.lines(S.patch(change))
        #expect(lines.contains("DTSTART:20261031T093000Z"))
        #expect(lines.contains("DTEND:20261031T101500Z"))
        #expect(lines.contains("X-CUSTOM-THING:keep me"))
        let again = S.lines(NCAgendaICalPatch.apply(change, to: S.patch(change), agentTags: S.tags, now: S.now, zone: S.zone) ?? "")
        #expect(again.contains("SEQUENCE:2"))
    }

    @Test("A change to all day writes dates, and a DURATION is replaced by DTEND")
    func allDay() {
        var change = CalendarChange()
        change.allDay = true
        change.start = S.date("2026-11-02T00:00:00Z")
        change.end = S.date("2026-11-04T00:00:00Z")
        let lines = S.lines(S.patch(change, S.eventICS.replacingOccurrences(of: "DTEND:20261030T110000Z", with: "DURATION:PT1H")))
        #expect(lines.contains("DTSTART;VALUE=DATE:20261102"))
        #expect(lines.contains("DTEND;VALUE=DATE:20261104"))
        #expect(!lines.contains { $0.hasPrefix("DURATION") })
    }

    @Test("The agent: on, off and changed. Self removes both marks and keeps the other categories")
    func agents() {
        var toSelf = CalendarChange()
        toSelf.agent = .init(id: nil, tag: nil)
        let selfLines = S.lines(S.patch(toSelf))
        #expect(!selfLines.contains { $0.hasPrefix("X-NOURAX-AGENT-ID") })
        #expect(selfLines.contains("CATEGORIES:Work"))

        var toOther = CalendarChange()
        toOther.agent = .init(id: "AG-0002", tag: "agent:AG-0002")
        let otherLines = S.lines(S.patch(toOther))
        #expect(otherLines.contains("X-NOURAX-AGENT-ID:AG-0002"))
        #expect(otherLines.contains("CATEGORIES:Work,agent:AG-0002"))
        #expect(!otherLines.contains("X-NOURAX-AGENT-ID:AG-0001"))

        // From Self to an agent on an object that has neither
        let plain = S.eventICS.replacingOccurrences(of: "X-NOURAX-AGENT-ID:AG-0001\r\n", with: "").replacingOccurrences(of: "CATEGORIES:Work,agent:AG-0001\r\n", with: "")
        let on = S.lines(S.patch(toOther, plain))
        #expect(on.contains("X-NOURAX-AGENT-ID:AG-0002"))
        #expect(on.contains("CATEGORIES:agent:AG-0002"))

        // Only the agent mark of the categories: the line goes when nothing else is left
        let onlyTag = S.todoICS
        let off = S.lines(S.patch(toSelf, onlyTag))
        #expect(!off.contains { $0.hasPrefix("CATEGORIES") })
        #expect(off.contains("X-KEEP:yes"))
    }

    @Test("Done and undone on a to-do")
    func done() {
        var done = CalendarChange()
        done.done = true
        let completed = S.lines(S.patch(done, S.todoICS))
        #expect(completed.contains("STATUS:COMPLETED"))
        #expect(completed.contains("PERCENT-COMPLETE:100"))
        #expect(completed.contains("COMPLETED:20261030T120000Z"))
        #expect(!completed.contains { $0.hasPrefix("SEQUENCE") })
        var undone = CalendarChange()
        undone.done = false
        let open = S.lines(S.patch(undone, S.patch(done, S.todoICS)))
        #expect(open.contains("STATUS:NEEDS-ACTION"))
        #expect(!open.contains { $0.hasPrefix("COMPLETED") || $0.hasPrefix("PERCENT-COMPLETE") })
    }

    @Test("A new due date and a changed description of a to-do; the description is escaped")
    func dueAndDescription() {
        var change = CalendarChange()
        change.due = S.date("2026-11-03T08:00:00Z")
        change.descriptionText = "Plan; then, \"write\"\nsecond line"
        let out = S.lines(S.patch(change, S.todoICS))
        #expect(out.contains("DUE:20261103T080000Z"))
        #expect(out.contains("DESCRIPTION:Plan\\; then\\, \"write\"\\nsecond line"))
        let parsed = NCAgendaICal.parse(S.patch(change, S.todoICS), deviceZone: S.zone)
        #expect(parsed.first?.descriptionText == "Plan; then, \"write\"\nsecond line")
    }

    @Test("A file with LF line endings keeps LF, and a folded line is read as one")
    func lineEndings() {
        let folded = "BEGIN:VCALENDAR\nVERSION:2.0\nBEGIN:VEVENT\nUID:a\nSUMMARY:A very long title that is folded\n  over two lines\nDTSTART:20261030T100000Z\nDTEND:20261030T110000Z\nEND:VEVENT\nEND:VCALENDAR\n"
        var change = CalendarChange()
        change.descriptionText = "Hello"
        let out = S.patch(change, folded)
        #expect(!out.contains("\r"))
        #expect(out.contains("SUMMARY:A very long title that is folded\n  over two lines\n"))
        #expect(out.hasSuffix("END:VCALENDAR\n"))
        var retitle = CalendarChange()
        retitle.title = String(repeating: "Ä", count: 60)
        let long = S.patch(retitle, folded)
        #expect(NCAgendaICal.parse(long, deviceZone: S.zone).first?.summary == String(repeating: "Ä", count: 60))
        #expect(long.split(separator: "\n").allSatisfy { $0.utf8.count <= 75 })
    }

    @Test("Nothing to patch in a file without an event or to-do")
    func noComponent() {
        #expect(NCAgendaICalPatch.apply(CalendarChange(), to: "BEGIN:VCALENDAR\r\nEND:VCALENDAR\r\n", agentTags: [], now: S.now, zone: S.zone) == nil)
    }

    @Test("A new event and a new to-do are in UTC with the Nourax PRODID and read back")
    func newObjects() throws {
        var change = CalendarChange()
        change.title = "Review, plan"
        change.start = S.date("2026-11-02T09:00:00Z")
        change.end = S.date("2026-11-02T10:00:00Z")
        change.agent = .init(id: "AG-0001", tag: "agent:AG-0001")
        let event = NCAgendaICalPatch.make(kind: "VEVENT", uid: "new-1", change: change, now: S.now, zone: S.zone)
        #expect(event.contains("PRODID:-//Nourax//NoAgenda//EN"))
        #expect(event.contains("DTSTART:20261102T090000Z"))
        let parsed = try #require(NCAgendaICal.parse(event, deviceZone: S.zone).first)
        #expect(parsed.uid == "new-1" && parsed.summary == "Review, plan" && parsed.agentId == "AG-0001")
        #expect(parsed.categories == ["agent:AG-0001"])
        #expect(parsed.start == S.date("2026-11-02T09:00:00Z") && parsed.end == S.date("2026-11-02T10:00:00Z"))

        var todo = CalendarChange()
        todo.title = "Call"
        todo.due = S.date("2026-11-03T12:00:00Z")
        let made = NCAgendaICalPatch.make(kind: "VTODO", uid: "new-2", change: todo, now: S.now, zone: S.zone)
        let parsedTodo = try #require(NCAgendaICal.parse(made, deviceZone: S.zone).first)
        #expect(parsedTodo.kind == "VTODO" && parsedTodo.due == S.date("2026-11-03T12:00:00Z") && parsedTodo.agentId == nil)

        var allDay = CalendarChange()
        allDay.title = "Off"
        allDay.allDay = true
        allDay.start = S.date("2026-11-02T00:00:00Z")
        allDay.end = S.date("2026-11-03T00:00:00Z")
        let day = NCAgendaICalPatch.make(kind: "VEVENT", uid: "new-3", change: allDay, now: S.now, zone: S.zone)
        #expect(day.contains("DTSTART;VALUE=DATE:20261102") && day.contains("DTEND;VALUE=DATE:20261103"))
    }

    @Test("The agent survives a web edit that drops X-NOURAX-AGENT-ID (the Tasks page): the tag still names the agent, and the next agent change writes the id again")
    func survivesWebEdit() throws {
        let afterWebEdit = S.todoICS.replacingOccurrences(of: "X-NOURAX-AGENT-ID:AG-0001\r\n", with: "")
        let component = try #require(NCAgendaICal.parse(afterWebEdit, deviceZone: S.zone).first)
        #expect(component.agentId == nil)
        let registry = NCAgendaRegistry(agents: [S.agent("AG-0001", "Writer-Bot")])
        let assembler = NCAgendaAssembler(AgendaInputs(me: AgendaMe(userId: "ali", displayName: "Ali"), registry: registry, calendar: S.calendar))
        let (agent, flags) = assembler.calendarAgent(component)
        #expect(agent.isMine && flags.isEmpty)
        var change = CalendarChange()
        change.agent = .init(id: "AG-0001", tag: "agent:AG-0001")
        let written = S.lines(S.patch(change, afterWebEdit))
        #expect(written.contains("X-NOURAX-AGENT-ID:AG-0001"))
        #expect(written.filter { $0.hasPrefix("CATEGORIES") } == ["CATEGORIES:agent:AG-0001"])
    }

    static let dateOnlyTodo = [
        "BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Test//EN",
        "BEGIN:VTODO", "UID:todo-d", "DTSTAMP:20261001T080000Z", "SUMMARY:Pay rent", "DTSTART;VALUE=DATE:20261029", "DUE;VALUE=DATE:20261030",
        "END:VTODO", "END:VCALENDAR", ""
    ].joined(separator: "\r\n")

    @Test("A date-only to-do (as Reminders writes it) stays date-only when its due date changes: no mix of DATE and DATE-TIME")
    func dateOnlyTodoDue() throws {
        var change = CalendarChange()
        change.due = S.date("2026-11-02T10:00:00Z")
        let lines = S.lines(S.patch(change, Self.dateOnlyTodo))
        #expect(lines.contains("DUE;VALUE=DATE:20261102"))
        #expect(lines.contains("DTSTART;VALUE=DATE:20261029"))
        #expect(!lines.contains { $0.hasPrefix("DUE:") })
        let parsed = try #require(NCAgendaICal.parse(S.patch(change, Self.dateOnlyTodo), deviceZone: S.zone).first)
        #expect(parsed.dueAllDay == true && parsed.startAllDay)
    }

    @Test("A date-only due with no start: a new start is a date too; a timed to-do gets a timed start")
    func startFollowsDue() {
        let dueOnly = Self.dateOnlyTodo.replacingOccurrences(of: "DTSTART;VALUE=DATE:20261029\r\n", with: "")
        var change = CalendarChange()
        change.start = S.date("2026-10-28T09:00:00Z")
        let dateOnly = S.lines(S.patch(change, dueOnly))
        #expect(dateOnly.contains("DTSTART;VALUE=DATE:20261028") && dateOnly.contains("DUE;VALUE=DATE:20261030"))
        // The to-do of the fixtures has a timed DUE: a new start is timed, and the due stays timed when it is changed
        let timed = S.lines(S.patch(change, S.todoICS))
        #expect(timed.contains("DTSTART:20261028T090000Z") && timed.contains("DUE:20261030T150000Z"))
        var due = CalendarChange()
        due.due = S.date("2026-11-04T08:00:00Z")
        #expect(S.lines(S.patch(due, S.todoICS)).contains("DUE:20261104T080000Z"))
        // Nothing to copy the type from: a timed due, as before
        let bare = ["BEGIN:VCALENDAR", "VERSION:2.0", "BEGIN:VTODO", "UID:b", "SUMMARY:Bare", "END:VTODO", "END:VCALENDAR", ""].joined(separator: "\r\n")
        #expect(S.lines(S.patch(due, bare)).contains("DUE:20261104T080000Z"))
    }

    @Test("Changes fold into one: the later value wins")
    func merge() {
        var first = CalendarChange()
        first.title = "A"
        first.done = false
        var second = CalendarChange()
        second.title = "B"
        second.start = S.now
        let merged = first.merged(with: second)
        #expect(merged.title == "B" && merged.start == S.now && merged.done == false)
    }
}

// MARK: - The CalDAV writer

@Suite("NoDrive NoAgenda CalDAV writer")
struct NoDriveAgendaCalDAVWriterTests {
    typealias S = AgendaEditSupport
    static let path = "/remote.php/dav/calendars/ali/work/client-call.ics"

    static func writer(_ server: EditFakeServer) -> NCAgendaCalDAVWriter {
        NCAgendaCalDAVWriter(http: server.http(), agentTags: S.tags, myAddresses: ["ali@example.org"], zone: S.zone, now: { S.now })
    }

    /// A server with one object: GET answers it with its ETag, PUT checks If-Match.
    static func server(etag: String = "\"e1\"", putStatus: Int? = nil, text: String = S.eventICS) -> EditFakeServer {
        EditFakeServer { request, path in
            switch (request.httpMethod ?? "", path) {
            case ("GET", Self.path):
                return .init(status: 200, body: text, headers: ["ETag": etag])
            case ("PUT", Self.path):
                if let putStatus { return .init(status: putStatus) }
                return request.value(forHTTPHeaderField: "If-Match") == etag ? .init(status: 204) : .init(status: 412)
            case ("DELETE", Self.path):
                return request.value(forHTTPHeaderField: "If-Match") == etag ? .init(status: 204) : .init(status: 412)
            default:
                return .init(status: 404)
            }
        }
    }

    @Test("An object that comes without an ETag is not written (a PUT without If-Match could overwrite a change made meanwhile)")
    func noEtagNoPut() async {
        let server = EditFakeServer { request, _ in request.httpMethod == "GET" ? .init(status: 200, body: S.eventICS) : .init(status: 204) }
        var change = CalendarChange()
        change.title = "Moved call"
        let outcome = await Self.writer(server).patch(path: Self.path, seenEtag: nil, change: change)
        #expect(outcome == .refused(NCAgendaEditText.t("_nodrive_agenda_edit_refused_local_")))
        #expect(server.requests("PUT").isEmpty)
        // A local failure is said in plain words, without a code
        #expect(!NCAgendaEditText.t("_nodrive_agenda_edit_refused_local_").contains("("))
    }

    @Test("An edit reads the object fresh, patches it, and puts it with If-Match of the fresh version")
    func patch() async throws {
        let server = Self.server()
        var change = CalendarChange()
        change.title = "Moved call"
        let outcome = await Self.writer(server).patch(path: Self.path, seenEtag: "\"e1\"", change: change)
        #expect(outcome == .plainSaved)
        #expect(server.requests.map { $0.httpMethod ?? "" } == ["GET", "PUT"])
        let put = try #require(server.requests("PUT").first)
        #expect(put.value(forHTTPHeaderField: "If-Match") == "\"e1\"")
        #expect(put.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("text/calendar") == true)
        #expect(put.value(forHTTPHeaderField: "OCS-APIRequest") == "true")
        let body = server.body(put)
        #expect(body.contains("SUMMARY:Moved call") && body.contains("BEGIN:VALARM"))
    }

    @Test("Another version than the one the person saw: the other change wins, nothing is written")
    func conflictOnRead() async {
        let server = Self.server(etag: "\"e2\"")
        var change = CalendarChange()
        change.title = "X"
        let outcome = await Self.writer(server).patch(path: Self.path, seenEtag: "\"e1\"", change: change)
        #expect(outcome == .conflict)
        #expect(server.requests(("PUT")).isEmpty)
    }

    @Test("A weak and a quoted ETag are the same version")
    func weakTag() {
        #expect(NCAgendaCalDAVWriter.sameVersion("W/\"abc\"", "\"abc\""))
        #expect(!NCAgendaCalDAVWriter.sameVersion("\"abc\"", "\"abd\""))
    }

    @Test("A 412 on the put (changed between the read and the write) is a conflict; a 403 is a refusal in words")
    func putStatuses() async {
        var change = CalendarChange()
        change.title = "X"
        let late = await Self.writer(Self.server(putStatus: 412)).patch(path: Self.path, seenEtag: nil, change: change)
        #expect(late == .conflict)
        let forbidden = await Self.writer(Self.server(putStatus: 403)).patch(path: Self.path, seenEtag: nil, change: change)
        #expect(forbidden == .refused(NCAgendaEditText.t("_nodrive_agenda_edit_refused_forbidden_")))
        let broken = await Self.writer(Self.server(putStatus: 503)).patch(path: Self.path, seenEtag: nil, change: change)
        #expect(broken == .serverError)
    }

    @Test("A repeating object and an invitation get no change here")
    func refused() async {
        var change = CalendarChange()
        change.title = "X"
        let repeating = S.eventICS.replacingOccurrences(of: "UID:ev-1", with: "UID:ev-1\r\nRRULE:FREQ=DAILY")
        let one = await Self.writer(Self.server(text: repeating)).patch(path: Self.path, seenEtag: nil, change: change)
        #expect(one == .refused(NCAgendaEditText.t("_nodrive_agenda_edit_refused_repeating_")))
        let invited = S.eventICS.replacingOccurrences(of: "UID:ev-1", with: "UID:ev-1\r\nORGANIZER:mailto:mara@example.org")
        var agent = CalendarChange()
        agent.agent = .init(id: nil, tag: nil)
        let two = await Self.writer(Self.server(text: invited)).patch(path: Self.path, seenEtag: nil, change: agent)
        #expect(two == .refused(NCAgendaEditText.t("_nodrive_agenda_edit_invited_")))
    }

    @Test("A deleted object (404 on the read) is a conflict; no network is offline")
    func gone() async {
        let missing = EditFakeServer { _, _ in .init(status: 404) }
        var change = CalendarChange()
        change.title = "X"
        #expect(await Self.writer(missing).patch(path: Self.path, seenEtag: nil, change: change) == .conflict)
        let offline = EditFakeServer { _, _ in throw URLError(.notConnectedToInternet) }
        #expect(await Self.writer(offline).patch(path: Self.path, seenEtag: nil, change: change) == .offline)
    }

    @Test("A new object goes with If-None-Match: *; a 412 whose object holds our own UID is a try that had arrived")
    func create() async throws {
        var change = CalendarChange()
        change.title = "New"
        change.start = S.now
        change.end = S.now.addingTimeInterval(3600)
        let text = NCAgendaICalPatch.make(kind: "VEVENT", uid: "uid-9", change: change, now: S.now, zone: S.zone)
        let target = "/remote.php/dav/calendars/ali/work/uid-9.ics"
        let fresh = EditFakeServer { _, _ in .init(status: 201) }
        #expect(await Self.writer(fresh).create(path: target, ics: text) == .plainSaved)
        let put = try #require(fresh.requests.first)
        #expect(put.httpMethod == "PUT" && put.value(forHTTPHeaderField: "If-None-Match") == "*")
        #expect(put.value(forHTTPHeaderField: "If-Match") == nil)

        let arrived = EditFakeServer { request, _ in request.httpMethod == "PUT" ? .init(status: 412) : .init(status: 200, body: text, headers: ["ETag": "\"x\""]) }
        #expect(await Self.writer(arrived).create(path: target, ics: text) == .plainSaved)
        let other = EditFakeServer { request, _ in request.httpMethod == "PUT" ? .init(status: 412) : .init(status: 200, body: S.eventICS, headers: ["ETag": "\"x\""]) }
        #expect(await Self.writer(other).create(path: target, ics: text) == .conflict)
    }

    @Test("A delete reads the object, checks the version and sends DELETE with If-Match; it is the only DELETE")
    func delete() async throws {
        let server = Self.server()
        #expect(await Self.writer(server).delete(path: Self.path, seenEtag: "\"e1\"") == .plainSaved)
        let request = try #require(server.requests(("DELETE")).first)
        #expect(request.value(forHTTPHeaderField: "If-Match") == "\"e1\"")
        let changed = Self.server(etag: "\"e2\"")
        #expect(await Self.writer(changed).delete(path: Self.path, seenEtag: "\"e1\"") == .conflict)
        #expect(changed.requests(("DELETE")).isEmpty)
    }
}

// MARK: - "My agent" on a Gantt task

@Suite("NoDrive NoAgenda my agent on a task")
struct NoDriveAgendaGanttAgentTests {
    static let ali = GanttResource(id: 1, name: "Ali", type: "person", uid: "ali", uidDisplayName: "Ali")
    static let sara = GanttResource(id: 2, name: "Sara", type: "person", uid: "sara", uidDisplayName: "Sara")
    // The agents' planning people live in the pool of the project's owner (Mara), as the CI seed has them.
    static let writer = GanttResource(id: 10, name: "🤖 Writer-Bot (Ali)", type: "person", uid: nil, uidDisplayName: nil, ownerId: "mara")
    static let research = GanttResource(id: 11, name: "🤖 Research-Bot (Ali)", type: "person", uid: nil, uidDisplayName: nil, ownerId: "mara")
    static let design = GanttResource(id: 12, name: "🤖 Design-Bot (Sara)", type: "person", uid: nil, uidDisplayName: nil, ownerId: "mara")
    static let role = GanttResource(id: 20, name: "Designer", type: "role", uid: nil, uidDisplayName: nil)
    static let agents = [AgendaEditSupport.agent("AG-0001", "Writer-Bot", resources: [10]), AgendaEditSupport.agent("AG-0003", "Research-Bot")]

    static func context(resources: [GanttResource] = [ali, sara, writer, research, design, role], permission: String = "editor", rolesOnly: Bool = false) -> GanttAgentContext {
        GanttAgentContext(myUid: "ali", myName: "Ali", myAgents: agents,
                          resources: Dictionary(uniqueKeysWithValues: resources.map { ($0.id, $0) }),
                          project: GanttProject(id: 5, title: "Website", color: nil, ownerId: "mara", ownerName: nil, permission: permission, rolesOnly: rolesOnly))
    }

    static func task(_ rows: [(Int, Double?)]) -> GanttTask {
        GanttTask(id: 501, projectId: 5, title: "Write homepage copy", start: "2026-10-29 09:00:00", end: "2026-10-31 17:00:00", work: 8,
                  updatedAt: "2026-10-30 08:00:00", progressMode: "manual", progress: 40, status: "in_progress",
                  resources: rows.map { GanttResourceRow(resourceId: $0.0, work: $0.1) })
    }

    func plan(_ rows: [(Int, Double?)], _ choice: AgentChoice, _ context: GanttAgentContext = NoDriveAgendaGanttAgentTests.context()) -> NCAgendaGanttAgentChange.Plan {
        NCAgendaGanttAgentChange.plan(task: Self.task(rows), choice: choice, context: context)
    }

    let writerChoice = AgentChoice(AgendaEditSupport.agent("AG-0001", "Writer-Bot", resources: [10]))

    @Test("Self to an agent: the agent's planning person is added at the end with no work; every other row stays")
    func selfToAgent() {
        let result = plan([(1, 4), (2, 4)], writerChoice)
        #expect(result == .rows([GanttResourceRow(resourceId: 1, work: 4), GanttResourceRow(resourceId: 2, work: 4), GanttResourceRow(resourceId: 10, work: nil)]))
    }

    @Test("An agent to Self: only my agents' rows go; other people's rows and their agents stay")
    func agentToSelf() {
        let result = plan([(1, 4), (10, nil), (2, 4), (12, nil)], .selfChoice)
        #expect(result == .rows([GanttResourceRow(resourceId: 1, work: 4), GanttResourceRow(resourceId: 2, work: 4), GanttResourceRow(resourceId: 12, work: nil)]))
    }

    @Test("An agent to another agent of mine, by registry id and by exact name")
    func agentToAgent() {
        let research = AgentChoice(Self.agents[1])
        // Research-Bot is found by its exact name next to my planning person
        let result = plan([(1, 4), (10, nil)], research)
        #expect(result == .rows([GanttResourceRow(resourceId: 1, work: 4), GanttResourceRow(resourceId: 11, work: nil)]))
    }

    @Test("The refusals: nothing is sent")
    func refusals() {
        #expect(plan([(1, 4), (2, 1), (20, 1), (12, nil)], writerChoice) == .refused(.tooMany))
        #expect(plan([(2, 4)], writerChoice) == .refused(.notOnTask))
        #expect(plan([(1, 4), (99, 2)], writerChoice) == .refused(.hiddenRow))
        #expect(plan([(1, 4)], writerChoice, Self.context(rolesOnly: true)) == .refused(.rolesOnly))
        #expect(plan([(1, 4)], writerChoice, Self.context(permission: "viewer")) == .refused(.viewer))
        #expect(plan([(1, 4), (10, nil)], writerChoice) == .refused(.noChange))
        // Taking away an agent row that holds work would change the total
        #expect(plan([(1, 4), (10, 2)], .selfChoice) == .refused(.workWouldChange))
        // The agent's planning person is not visible to me
        let hidden = Self.context(resources: [Self.ali, Self.sara, Self.research])
        #expect(plan([(1, 4)], writerChoice, hidden) == .refused(.agentNotVisible(name: "Writer-Bot")))
        #expect(NCAgendaGanttAgentChange.text(.agentNotVisible(name: "Writer-Bot")) == "Ask your project manager to add 🤖 Writer-Bot to this project")
    }

    @Test("Two same-named planning people in two pools: the one of this project is taken, never the other manager's")
    func twoPools() {
        // Research-Bot is known by its exact name only; the same name exists in Zed's pool (lower id) and in Mara's.
        let zedsResearch = GanttResource(id: 9, name: "🤖 Research-Bot (Ali)", type: "person", uid: nil, uidDisplayName: nil, ownerId: "zed")
        let both = Self.context(resources: [Self.ali, Self.sara, Self.writer, zedsResearch, Self.research, Self.design])
        let research = AgentChoice(Self.agents[1])
        #expect(plan([(1, 4)], research, both) == .rows([GanttResourceRow(resourceId: 1, work: 4), GanttResourceRow(resourceId: 11, work: nil)]))
        // The one already on the task wins over the pool
        #expect(plan([(1, 4), (9, nil)], research, both) == .refused(.noChange))
        // One that sits on another task of the project is taken before the owner's pool
        var other = both
        other.projectTasks = [GanttTask(id: 502, projectId: 5, title: "Other", status: "in_progress",
                                        resources: [GanttResourceRow(resourceId: 1, work: 2), GanttResourceRow(resourceId: 9, work: nil)])]
        #expect(plan([(1, 4)], research, other) == .rows([GanttResourceRow(resourceId: 1, work: 4), GanttResourceRow(resourceId: 9, work: nil)]))
        // Only Zed's person exists: the manager of this project does not have it, so nothing is sent
        let foreign = Self.context(resources: [Self.ali, Self.sara, zedsResearch])
        #expect(plan([(1, 4)], research, foreign) == .refused(.agentNotVisible(name: "Research-Bot")))
        // The picker offers an agent only when its planning person belongs to the project
        #expect(NCAgendaGanttAgentChange.isOffered(Self.agents[1], context: both))
        #expect(!NCAgendaGanttAgentChange.isOffered(Self.agents[1], context: foreign))
    }

    @Test("The row list that the server answered must be the one that was sent")
    func sameRows() {
        let sent = [GanttResourceRow(resourceId: 1, work: 4), GanttResourceRow(resourceId: 10, work: nil)]
        #expect(NCAgendaGanttAgentChange.sameRows(sent, sent))
        #expect(!NCAgendaGanttAgentChange.sameRows(sent, [sent[0]]))
        #expect(!NCAgendaGanttAgentChange.sameRows(sent, [sent[0], GanttResourceRow(resourceId: 10, work: 1)]))
    }
}

// MARK: - The Gantt and Deck writers

@Suite("NoDrive NoAgenda NoGantt and Deck writers")
struct NoDriveAgendaGanttDeckWriterTests {
    static let root = "/ocs/v2.php/apps/nc_gantt/api/v1/"

    static func tasksJSON(updatedAt: String = "2026-10-30 08:00:00", rows: String = "[{\"resource_id\":1,\"work\":4}]") -> String {
        """
        {"ocs":{"meta":{"status":"ok","statuscode":200,"message":"OK"},"data":[
        {"id":501,"project_id":5,"title":"Write homepage copy","start_date":"2026-10-29 09:00:00","end_date":"2026-10-31 17:00:00","work":8,
         "updated_at":"\(updatedAt)","status":"in_progress","dependencies":[],"resources":\(rows),"progress_mode":"manual","manual_progress":40},
        {"id":502,"project_id":5,"title":"Publish banners","start_date":"2026-11-02 09:00:00","end_date":"2026-11-03 17:00:00","work":4,
         "updated_at":"2026-10-30 08:00:00","status":"not_started","dependencies":[],"resources":[]}]}}
        """
    }

    @Test("A date change sends only the dates plus adjust_lag and deck_confirmed false, keeps the time of day, and reports who moved too")
    func move() async throws {
        let server = EditFakeServer { request, path in
            if request.httpMethod == "GET" { return .init(status: 200, body: Self.tasksJSON()) }
            return .init(status: 200, body: """
            {"ocs":{"meta":{"statuscode":200},"data":{"task":{"id":501,"start_date":"2026-11-02 09:00:00","end_date":"2026-11-04 17:00:00"},
             "propagated":[{"id":502,"title":"Publish banners"}],"op_id":"op-77","deck":null}}}
            """)
        }
        var change = GanttChange()
        change.startDay = "2026-11-02"
        change.endDay = "2026-11-04"
        let outcome = await NCAgendaGanttWriter(http: server.http()).update(projectId: 5, taskId: 501, seenUpdatedAt: "2026-10-30 08:00:00", change: change)
        guard case let .saved(saved) = outcome else { Issue.record("not saved: \(outcome)"); return }
        #expect(saved.alsoMoved == ["Publish banners"] && saved.opId == "op-77" && !saved.datesAdjusted)
        let put = try #require(server.requests("PUT").first)
        #expect(put.url?.path == Self.root + "tasks/501")
        let body = try #require(try JSONSerialization.jsonObject(with: put.httpBody ?? Data()) as? [String: Any])
        #expect(body["start_date"] as? String == "2026-11-02 09:00:00")
        #expect(body["end_date"] as? String == "2026-11-04 17:00:00")
        #expect(body["adjust_lag"] as? Bool == true && body["deck_confirmed"] as? Bool == false)
        #expect(Set(body.keys) == ["start_date", "end_date", "adjust_lag", "deck_confirmed"])
    }

    @Test("NoGantt saved other dates than asked: the toast says it adjusted them")
    func adjusted() async {
        let server = EditFakeServer { request, _ in
            request.httpMethod == "GET" ? .init(status: 200, body: Self.tasksJSON()) :
                .init(status: 200, body: "{\"ocs\":{\"data\":{\"task\":{\"id\":501,\"start_date\":\"2026-11-02 09:00:00\",\"end_date\":\"2026-11-02 17:00:00\"},\"propagated\":[],\"op_id\":\"op-1\"}}}")
        }
        var change = GanttChange()
        change.endDay = "2026-11-01"   // a Sunday
        guard case let .saved(saved) = await NCAgendaGanttWriter(http: server.http()).update(projectId: 5, taskId: 501, seenUpdatedAt: nil, change: change) else {
            Issue.record("not saved")
            return
        }
        #expect(saved.datesAdjusted)
    }

    @Test("% done and done: manual progress, and done is status done with 100 %")
    func progress() throws {
        let fresh = try #require(NCAgendaGanttReader.decodeTask(["id": 501, "project_id": 5, "title": "T", "start_date": "2026-10-29 09:00:00", "end_date": "2026-10-31 17:00:00", "status": "in_progress"]))
        var percent = GanttChange()
        percent.percent = 70
        #expect(NCAgendaGanttWriter.body(for: percent, fresh: fresh) as NSDictionary == ["manual_progress": 70, "progress_mode": "manual"] as NSDictionary)
        var done = GanttChange()
        done.done = true
        #expect(NCAgendaGanttWriter.body(for: done, fresh: fresh) as NSDictionary == ["status": "done", "manual_progress": 100, "progress_mode": "manual"] as NSDictionary)
        #expect(NCAgendaGanttWriter.timeOfDay("2026-10-29T17:30:00+00:00", fallback: "09:00:00") == "17:30:00")
        #expect(NCAgendaGanttWriter.timeOfDay("2026-10-29", fallback: "09:00:00") == "09:00:00")
    }

    @Test("Another updated_at than the one the person saw: conflict, nothing is written. A 400 is shown in the server's words, a 403 as a refusal")
    func conflictAndRefusals() async {
        var change = GanttChange()
        change.percent = 10
        let changed = EditFakeServer { _, _ in .init(status: 200, body: Self.tasksJSON(updatedAt: "2026-10-30 09:30:00")) }
        #expect(await NCAgendaGanttWriter(http: changed.http()).update(projectId: 5, taskId: 501, seenUpdatedAt: "2026-10-30 08:00:00", change: change) == .conflict)
        #expect(changed.requests("PUT").isEmpty)

        let invalid = EditFakeServer { request, _ in
            request.httpMethod == "GET" ? .init(status: 200, body: Self.tasksJSON()) : .init(status: 400, body: "{\"ocs\":{\"meta\":{\"message\":\"invalid_date\"},\"data\":[]}}")
        }
        #expect(await NCAgendaGanttWriter(http: invalid.http()).update(projectId: 5, taskId: 501, seenUpdatedAt: nil, change: change)
                == .refused(NCAgendaEditText.f("_nodrive_agenda_edit_gantt_refused_", "invalid_date")))
        let viewer = EditFakeServer { request, _ in request.httpMethod == "GET" ? .init(status: 200, body: Self.tasksJSON()) : .init(status: 403) }
        #expect(await NCAgendaGanttWriter(http: viewer.http()).update(projectId: 5, taskId: 501, seenUpdatedAt: nil, change: change)
                == .refused(NCAgendaEditText.t("_nodrive_agenda_edit_gantt_forbidden_")))
    }

    @Test("My agent sends the whole new list; the answer is checked against it")
    func agentRows() async throws {
        let context = NoDriveAgendaGanttAgentTests.context()
        let choice = AgentChoice(AgendaEditSupport.agent("AG-0001", "Writer-Bot", resources: [10]))
        let echo = EditFakeServer { request, _ in
            if request.httpMethod == "GET" { return .init(status: 200, body: Self.tasksJSON()) }
            return .init(status: 200, body: "{\"ocs\":{\"data\":{\"task\":{\"id\":501,\"resources\":[{\"resource_id\":1,\"work\":4},{\"resource_id\":10,\"work\":null}]},\"propagated\":[]}}}")
        }
        let outcome = await NCAgendaGanttWriter(http: echo.http()).changeAgent(projectId: 5, taskId: 501, seenUpdatedAt: nil, choice: choice, context: context)
        #expect(outcome == .plainSaved || { if case .saved = outcome { return true } else { return false } }())
        let put = try #require(echo.requests("PUT").first)
        let body = try #require(try JSONSerialization.jsonObject(with: put.httpBody ?? Data()) as? [String: Any])
        let rows = try #require(body["resources"] as? [[String: Any]])
        #expect(rows.count == 2 && rows[0]["resource_id"] as? Int == 1 && rows[1]["resource_id"] as? Int == 10)
        #expect(Set(body.keys) == ["resources"])

        // The server dropped the agent's row silently: "Check this task in NoGantt"
        let dropped = EditFakeServer { request, _ in
            request.httpMethod == "GET" ? .init(status: 200, body: Self.tasksJSON()) :
                .init(status: 200, body: "{\"ocs\":{\"data\":{\"task\":{\"id\":501,\"resources\":[{\"resource_id\":1,\"work\":4}]}}}}")
        }
        #expect(await NCAgendaGanttWriter(http: dropped.http()).changeAgent(projectId: 5, taskId: 501, seenUpdatedAt: nil, choice: choice, context: context)
                == .refused(NCAgendaEditText.t("_nodrive_agenda_edit_gantt_check_")))
        // A refusal of the rules sends nothing
        let tooMany = EditFakeServer { _, _ in .init(status: 200, body: Self.tasksJSON(rows: "[{\"resource_id\":1,\"work\":1},{\"resource_id\":2,\"work\":1},{\"resource_id\":20,\"work\":1},{\"resource_id\":12,\"work\":null}]")) }
        _ = await NCAgendaGanttWriter(http: tooMany.http()).changeAgent(projectId: 5, taskId: 501, seenUpdatedAt: nil, choice: choice, context: context)
        #expect(tooMany.requests("PUT").isEmpty)
    }

    // MARK: Deck

    static let boardRoot = "/index.php/apps/deck/api/v1.0/boards/1/stacks/2/cards/21"
    static let card = """
    {"id":21,"title":"Review sitemap","description":"Keep this text","stackId":2,"type":"plain","lastModified":1761800000,"order":3,
     "duedate":"2026-10-30T12:00:00+00:00","startdate":"2026-10-28T09:00:00+00:00","done":"2026-10-29T10:00:00+00:00","archived":false,"color":"ff0000",
     "owner":{"primaryKey":"mara","uid":"mara","displayname":"Mara","type":0},
     "labels":[{"id":7,"title":"🤖 Writer-Bot"},{"id":9,"title":"plain label"}]}
    """

    @Test("A card update is a full replace: every field of the fresh card goes back, only the changed one is replaced")
    func deckFullReplace() async throws {
        let server = EditFakeServer { request, path in
            request.httpMethod == "GET" ? .init(status: 200, body: Self.card) : .init(status: 200, body: Self.card)
        }
        var change = DeckChange()
        change.due = AgendaEditSupport.date("2026-11-04T12:00:00Z")
        // Deck answers with the saved card: its version is passed on to the next change of the same Save
        #expect(await NCAgendaDeckWriter(http: server.http()).update(board: 1, stack: 2, card: 21, seenLastModified: 1_761_800_000, change: change)
                == .saved(NCAgendaSaved(newLastModified: 1_761_800_000)))
        let put = try #require(server.requests("PUT").first)
        #expect(put.url?.path == Self.boardRoot)
        let body = try #require(try JSONSerialization.jsonObject(with: put.httpBody ?? Data()) as? [String: Any])
        #expect(body["title"] as? String == "Review sitemap")
        #expect(body["description"] as? String == "Keep this text")
        #expect(body["startdate"] as? String == "2026-10-28T09:00:00+00:00")
        #expect(body["owner"] as? String == "mara")
        #expect(body["order"] as? Int == 3)
        #expect(body["type"] as? String == "plain")
        #expect(body["duedate"] as? String == "2026-11-04T12:00:00+00:00")
        #expect(body["done"] as? String == "2026-10-29T10:00:00+00:00")
        #expect(body["color"] as? String == "ff0000")
        #expect(body["archived"] as? Bool == false)
        // Every field is there, also those that are empty
        let bare = NCAgendaDeckWriter.body(fresh: ["id": 1, "title": "T", "owner": "mara"], change: DeckChange())
        for key in ["title", "type", "owner", "description", "order", "duedate", "startdate", "archived", "done"] {
            #expect(bare.keys.contains(key), "\(key) is missing from the body")
        }
        // Done is the date it was done (a boolean gives an error 500 on the real Deck); not done is null
        let doneBody = NCAgendaDeckWriter.body(fresh: ["title": "T", "owner": "mara"], change: DeckChange(done: true), now: AgendaEditSupport.date("2026-10-30T12:00:00Z"))
        #expect(doneBody["done"] as? String == "2026-10-30T12:00:00+00:00")
        #expect(NCAgendaDeckWriter.body(fresh: ["title": "T", "owner": "mara", "done": "2026-10-29T10:00:00+00:00"], change: DeckChange(done: false))["done"] is NSNull)
        #expect(NCAgendaDeckWriter.isoDate(AgendaEditSupport.date("2026-11-04T12:00:00Z")) == "2026-11-04T12:00:00+00:00")
    }

    @Test("Another lastModified than the one the person saw is a conflict, and nothing is written")
    func deckConflict() async {
        let server = EditFakeServer { _, _ in .init(status: 200, body: Self.card) }
        var change = DeckChange()
        change.done = true
        #expect(await NCAgendaDeckWriter(http: server.http()).update(board: 1, stack: 2, card: 21, seenLastModified: 1_761_700_000, change: change) == .conflict)
        #expect(server.requests("PUT").isEmpty)
    }

    static func labelServer(canManage: Bool, labels: String = "[{\"id\":7,\"title\":\"🤖 Writer-Bot\"},{\"id\":8,\"title\":\"🤖 Research-Bot\"}]") -> EditFakeServer {
        EditFakeServer { request, path in
            switch (request.httpMethod ?? "", path) {
            case ("GET", Self.boardRoot): return .init(status: 200, body: Self.card)
            case ("GET", "/index.php/apps/deck/api/v1.0/boards/1"):
                return .init(status: 200, body: "{\"id\":1,\"labels\":\(labels),\"permissions\":{\"PERMISSION_MANAGE\":\(canManage)}}")
            case ("POST", "/index.php/apps/deck/api/v1.0/boards/1/labels"): return .init(status: 200, body: "{\"id\":55,\"title\":\"x\"}")
            case ("PUT", _): return .init(status: 200, body: "{}")
            default: return .init(status: 404)
            }
        }
    }

    @Test("A label switch puts the new label on first and then takes my other agent's label off; no other label is touched")
    func labelSwitch() async throws {
        let server = Self.labelServer(canManage: false)
        let research = AgendaEditSupport.agent("AG-0003", "Research-Bot", label: "🤖 Research-Bot")
        let writer = AgendaEditSupport.agent("AG-0001", "Writer-Bot", label: "🤖 Writer-Bot")
        let outcome = await NCAgendaDeckWriter(http: server.http()).changeAgent(board: 1, stack: 2, card: 21, seenLastModified: nil, choice: AgentChoice(research), myAgents: [writer, research])
        #expect(outcome == .plainSaved)
        let puts = server.requests("PUT")
        #expect(puts.map { $0.url?.lastPathComponent } == ["assignLabel", "removeLabel"])
        let assign = try #require(try JSONSerialization.jsonObject(with: puts[0].httpBody ?? Data()) as? [String: Any])
        let remove = try #require(try JSONSerialization.jsonObject(with: puts[1].httpBody ?? Data()) as? [String: Any])
        #expect(assign["labelId"] as? Int == 8 && remove["labelId"] as? Int == 7)
        // To Self: only the removal
        let toSelf = Self.labelServer(canManage: false)
        #expect(await NCAgendaDeckWriter(http: toSelf.http()).changeAgent(board: 1, stack: 2, card: 21, seenLastModified: nil, choice: .selfChoice, myAgents: [writer, research]) == .plainSaved)
        #expect(toSelf.requests("PUT").map { $0.url?.lastPathComponent } == ["removeLabel"])
    }

    @Test("A missing label is made only where I may manage the board, in cobalt; otherwise the person is told")
    func labelCreate() async throws {
        let research = AgendaEditSupport.agent("AG-0003", "Research-Bot", label: "🤖 Research-Bot")
        let noLabels = "[{\"id\":7,\"title\":\"🤖 Writer-Bot\"}]"
        let manager = Self.labelServer(canManage: true, labels: noLabels)
        #expect(await NCAgendaDeckWriter(http: manager.http()).changeAgent(board: 1, stack: 2, card: 21, seenLastModified: nil, choice: AgentChoice(research), myAgents: [research]) == .plainSaved)
        let made = try #require(manager.requests("POST").first)
        let body = try #require(try JSONSerialization.jsonObject(with: made.httpBody ?? Data()) as? [String: Any])
        #expect(body["title"] as? String == "🤖 Research-Bot" && body["color"] as? String == "2563EB")
        let member = Self.labelServer(canManage: false, labels: noLabels)
        let outcome = await NCAgendaDeckWriter(http: member.http()).changeAgent(board: 1, stack: 2, card: 21, seenLastModified: nil, choice: AgentChoice(research), myAgents: [research])
        #expect(outcome == .refused(NCAgendaEditText.f("_nodrive_agenda_edit_deck_ask_manager_", "Research-Bot")))
        #expect(member.requests("POST").isEmpty && member.requests("PUT").isEmpty)
    }
}

// MARK: - The queue

@Suite("NoDrive NoAgenda edit queue")
struct NoDriveAgendaEditQueueTests {
    typealias S = AgendaEditSupport

    static func command(_ key: String, path: String, title: String = "T", kind: NCAgendaEditCommand.Kind = .calendarPatch) -> NCAgendaEditCommand {
        var command = NCAgendaEditCommand(id: UUID(), kind: kind, createdAt: S.now, itemKey: key, title: title, sourceKey: nil,
                                          link: AgendaLink(home: .calendar, path: path, etag: "\"e1\""))
        var change = CalendarChange()
        change.title = title
        command.calendar = change
        return command
    }

    static func root() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("agenda-queue-" + UUID().uuidString, isDirectory: true)
    }

    static func queue(_ server: EditFakeServer, root: URL, retryDelay: UInt64 = 0) -> NCAgendaEditQueue {
        NCAgendaEditQueue(account: "ali https://drive.test", cacheRoot: root, zone: S.zone, retryDelay: retryDelay, clock: { S.now }) { _ in server.http() }
    }

    /// Every .ics path answers its object with the ETag "e1" and accepts a put.
    static func calendarServer(putStatus: Int = 204) -> EditFakeServer {
        EditFakeServer { request, path in
            guard path.hasSuffix(".ics") else { return .init(status: 404) }
            if request.httpMethod == "GET" { return .init(status: 200, body: S.eventICS, headers: ["ETag": "\"e1\""]) }
            return .init(status: putStatus)
        }
    }

    static var context: AgendaEditContext {
        var value = AgendaEditContext()
        value.me = AgendaMe(userId: "ali", displayName: "Ali", addresses: ["ali@example.org"])
        value.ganttGuardOK = true
        value.deckGuardOK = true
        return value
    }

    @Test("Commands go out oldest first, one at a time, and a sent command leaves the queue")
    func order() async {
        let root = Self.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let server = Self.calendarServer()
        let queue = Self.queue(server, root: root)
        await queue.enqueue(Self.command("a", path: "/remote.php/dav/calendars/ali/work/a.ics"))
        await queue.enqueue(Self.command("b", path: "/remote.php/dav/calendars/ali/work/b.ics"))
        let report = await queue.process(context: Self.context)
        #expect(report.saved.count == 2 && !report.offline)
        #expect(server.requests("PUT").compactMap { $0.url?.lastPathComponent } == ["a.ics", "b.ics"])
        // GET and PUT of one command come before the next command starts
        #expect(server.requests.compactMap { $0.httpMethod } == ["GET", "PUT", "GET", "PUT"])
        #expect(await queue.commands().isEmpty)
    }

    @Test("A second change of an item that waits is folded into the waiting command; the version seen stays the first one")
    func folding() async {
        let root = Self.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let queue = Self.queue(Self.calendarServer(), root: root)
        var first = Self.command("a", path: "/remote.php/dav/calendars/ali/work/a.ics", title: "One")
        first.link.etag = "\"seen\""
        var second = Self.command("a", path: "/remote.php/dav/calendars/ali/work/a.ics", title: "Two")
        second.calendar?.done = false
        second.link.etag = "\"later\""
        await queue.enqueue(first)
        let list = await queue.enqueue(second)
        #expect(list.count == 1)
        #expect(list[0].calendar?.title == "Two" && list[0].calendar?.done == false && list[0].link.etag == "\"seen\"")
        let other = await queue.enqueue(Self.command("b", path: "/remote.php/dav/calendars/ali/work/b.ics"))
        #expect(other.count == 2)
    }

    @Test("The queue survives a restart: a new instance reads the same commands")
    func persistence() async {
        let root = Self.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let offline = EditFakeServer { _, _ in throw URLError(.notConnectedToInternet) }
        let first = Self.queue(offline, root: root)
        await first.enqueue(Self.command("a", path: "/remote.php/dav/calendars/ali/work/a.ics"))
        let report = await first.process(context: Self.context)
        #expect(report.offline && report.saved.isEmpty)
        let second = Self.queue(Self.calendarServer(), root: root)
        let loaded = await second.commands()
        #expect(loaded.count == 1 && loaded[0].isWaiting)
        let sent = await second.process(context: Self.context)
        #expect(sent.saved.count == 1)
    }

    @Test("A 5xx is tried three times and then it is Not sent; the others still go")
    func serverErrors() async {
        let root = Self.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let server = EditFakeServer { request, path in
            if request.httpMethod == "GET" { return .init(status: 200, body: S.eventICS, headers: ["ETag": "\"e1\""]) }
            return path.hasSuffix("bad.ics") ? .init(status: 500) : .init(status: 204)
        }
        let queue = Self.queue(server, root: root)
        await queue.enqueue(Self.command("a", path: "/remote.php/dav/calendars/ali/work/bad.ics"))
        await queue.enqueue(Self.command("b", path: "/remote.php/dav/calendars/ali/work/good.ics"))
        let report = await queue.process(context: Self.context)
        #expect(report.saved.count == 1 && report.notSent == 1)
        #expect(server.requests("PUT").filter { $0.url?.lastPathComponent == "bad.ics" }.count == 3)
        let left = await queue.commands()
        #expect(left.count == 1 && left[0].notSent?.kind == .refused)
    }

    @Test("A conflict stays in Not sent until a tap; Apply my change again reads the item again and sends it")
    func conflictAndApplyAgain() async {
        let root = Self.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let changedMeanwhile = EditFakeServer { request, _ in
            request.httpMethod == "GET" ? .init(status: 200, body: S.eventICS, headers: ["ETag": "\"e2\""]) : .init(status: 204)
        }
        let queue = Self.queue(changedMeanwhile, root: root)
        await queue.enqueue(Self.command("a", path: "/remote.php/dav/calendars/ali/work/a.ics"))
        let report = await queue.process(context: Self.context)
        #expect(report.notSent == 1 && changedMeanwhile.requests("PUT").isEmpty)
        var list = await queue.commands()
        #expect(list[0].notSent?.kind == .changedElsewhere)
        // Nothing sends it again by itself
        _ = await queue.process(context: Self.context)
        #expect(changedMeanwhile.requests("PUT").isEmpty)
        await queue.applyAgain(id: list[0].id)
        list = await queue.commands()
        #expect(list[0].isWaiting && list[0].link.etag == nil)
        let again = await queue.process(context: Self.context)
        #expect(again.saved.count == 1)
        #expect(changedMeanwhile.requests("PUT").first?.value(forHTTPHeaderField: "If-Match") == "\"e2\"")
        #expect(await queue.commands().isEmpty)
    }

    @Test("Keep the other change drops the command, and only then")
    func keepOther() async {
        let root = Self.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let server = EditFakeServer { request, _ in request.httpMethod == "GET" ? .init(status: 404) : .init(status: 204) }
        let queue = Self.queue(server, root: root)
        let command = Self.command("a", path: "/remote.php/dav/calendars/ali/work/a.ics")
        await queue.enqueue(command)
        _ = await queue.process(context: Self.context)
        #expect(await queue.commands().count == 1)
        await queue.drop(id: command.id)
        #expect(await queue.commands().isEmpty)
    }

    @Test("A refusal of NoGantt or Deck (403) is a refusal by that app: Not sent; the calendar commands go on")
    func appRefusals() async {
        let root = Self.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let server = EditFakeServer { request, path in
            if path.hasPrefix("/ocs/v2.php/apps/nc_gantt") {
                return request.httpMethod == "GET" ? .init(status: 200, body: NoDriveAgendaGanttDeckWriterTests.tasksJSON()) : .init(status: 403)
            }
            if path.hasPrefix("/index.php/apps/deck") { return .init(status: 403) }
            if request.httpMethod == "GET" { return .init(status: 200, body: S.eventICS, headers: ["ETag": "\"e1\""]) }
            return .init(status: 204)
        }
        let queue = Self.queue(server, root: root)
        var gantt = NCAgendaEditCommand(id: UUID(), kind: .ganttUpdate, createdAt: S.now, itemKey: "gantt:501", title: "G", sourceKey: nil,
                                        link: AgendaLink(home: .gantt, projectId: 5, taskId: 501))
        gantt.gantt = GanttChange(percent: 50)
        var deck = NCAgendaEditCommand(id: UUID(), kind: .deckUpdate, createdAt: S.now, itemKey: "board:1:21", title: "D", sourceKey: nil,
                                       link: AgendaLink(home: .board, boardId: 1, stackId: 2, cardId: 21))
        deck.deck = DeckChange(done: true)
        await queue.enqueue(gantt)
        await queue.enqueue(deck)
        await queue.enqueue(Self.command("a", path: "/remote.php/dav/calendars/ali/work/a.ics"))
        let report = await queue.process(context: Self.context)
        #expect(report.saved.count == 1 && report.notSent == 2)
        let left = await queue.commands()
        #expect(left.allSatisfy { $0.notSent?.kind == .refused })
    }

    @Test("A NoGantt or Deck command is held until the guard of its home has passed; calendar commands are not")
    func guardHold() async {
        let root = Self.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let server = Self.calendarServer()
        let queue = Self.queue(server, root: root)
        var gantt = NCAgendaEditCommand(id: UUID(), kind: .ganttUpdate, createdAt: S.now, itemKey: "gantt:501", title: "G", sourceKey: nil,
                                        link: AgendaLink(home: .gantt, projectId: 5, taskId: 501))
        gantt.gantt = GanttChange(percent: 50)
        await queue.enqueue(gantt)
        await queue.enqueue(Self.command("a", path: "/remote.php/dav/calendars/ali/work/a.ics"))
        var held = Self.context
        held.ganttGuardOK = false
        let report = await queue.process(context: held)
        #expect(report.saved.count == 1)
        #expect(server.requests.allSatisfy { $0.url?.path.hasPrefix("/ocs/") == false })
        let left = await queue.commands()
        #expect(left.count == 1 && left[0].isWaiting && left[0].kind == .ganttUpdate)
    }

    // MARK: One Save, two commands

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var number: Int
        init(_ start: Int) { number = start }
        var value: Int { lock.lock(); defer { lock.unlock() }; return number }
        func next() -> Int { lock.lock(); defer { lock.unlock() }; number += 1; return number }
    }

    static var ganttContext: AgendaEditContext {
        var value = context
        var gantt = RawGantt()
        gantt.projects = [GanttProject(id: 5, title: "Website", color: nil, ownerId: "mara", ownerName: nil, permission: "editor")]
        gantt.resources = [NoDriveAgendaGanttAgentTests.ali, NoDriveAgendaGanttAgentTests.writer]
        value.gantt = gantt
        value.registry = NCAgendaRegistry(agents: [S.agent("AG-0001", "Writer-Bot", resources: [10], label: "🤖 Writer-Bot"),
                                                   S.agent("AG-0003", "Research-Bot", label: "🤖 Research-Bot")])
        return value
    }

    /// NoGantt as the writers see it: every PUT gives the task a new `updated_at`, and the answer holds it (or not).
    static func ganttServer(_ version: Counter, answerHasVersion: Bool) -> EditFakeServer {
        func stamp(_ number: Int) -> String { String(format: "2026-10-30 10:00:%02d", number) }
        return EditFakeServer { request, path in
            guard path.hasPrefix("/ocs/v2.php/apps/nc_gantt") else { return .init(status: 404) }
            if request.httpMethod == "GET" {
                return .init(status: 200, body: NoDriveAgendaGanttDeckWriterTests.tasksJSON(updatedAt: version.value == 0 ? "2026-10-30 08:00:00" : stamp(version.value)))
            }
            let sent = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
            let now = stamp(version.next())
            let stampField = answerHasVersion ? ",\"updated_at\":\"\(now)\"" : ""
            if sent.contains("\"resources\"") {
                return .init(status: 200, body: "{\"ocs\":{\"data\":{\"task\":{\"id\":501\(stampField),\"resources\":[{\"resource_id\":1,\"work\":4},{\"resource_id\":10,\"work\":null}]},\"propagated\":[]}}}")
            }
            return .init(status: 200, body: "{\"ocs\":{\"data\":{\"task\":{\"id\":501,\"start_date\":\"2026-11-02 09:00:00\",\"end_date\":\"2026-11-04 17:00:00\"\(stampField)},\"propagated\":[],\"op_id\":\"op-1\"}}}")
        }
    }

    static func ganttSave() -> [NCAgendaEditCommand] {
        let link = AgendaLink(home: .gantt, projectId: 5, taskId: 501, updatedAt: "2026-10-30 08:00:00")
        var dates = NCAgendaEditCommand(id: UUID(), kind: .ganttUpdate, createdAt: S.now, itemKey: "gantt:501", title: "Write homepage copy", sourceKey: nil, link: link)
        dates.gantt = GanttChange(startDay: "2026-11-02", endDay: "2026-11-04")
        var agent = NCAgendaEditCommand(id: UUID(), kind: .ganttAgent, createdAt: S.now, itemKey: "gantt:501", title: "Write homepage copy", sourceKey: nil, link: link)
        agent.agent = AgentChoice(S.agent("AG-0001", "Writer-Bot", resources: [10], label: "🤖 Writer-Bot"))
        return [dates, agent]
    }

    @Test("One Save that changes the dates and the agent of a Gantt task sends both: the second expects the version the first made")
    func ganttSaveWithTwoChanges() async {
        for answerHasVersion in [true, false] {
            let root = Self.root()
            defer { try? FileManager.default.removeItem(at: root) }
            let version = Counter(0)
            let server = Self.ganttServer(version, answerHasVersion: answerHasVersion)
            let queue = Self.queue(server, root: root)
            for command in Self.ganttSave() { await queue.enqueue(command) }
            let report = await queue.process(context: Self.ganttContext)
            #expect(report.saved.count == 2 && report.notSent == 0, "answer has a version: \(answerHasVersion)")
            #expect(await queue.commands().isEmpty)
            let puts = server.requests("PUT")
            #expect(puts.count == 2 && server.body(puts[0]).contains("start_date") && server.body(puts[1]).contains("\"resources\""))
        }
    }

    @Test("One Save that changes the due date and the agent of a card sends both: the second expects the version the first made")
    func cardSaveWithTwoChanges() async {
        let root = Self.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let version = Counter(1_761_800_000)
        let server = EditFakeServer { request, path in
            func card() -> String {
                NoDriveAgendaGanttDeckWriterTests.card.replacingOccurrences(of: "1761800000", with: String(version.value))
            }
            switch (request.httpMethod ?? "", path) {
            case ("GET", NoDriveAgendaGanttDeckWriterTests.boardRoot): return .init(status: 200, body: card())
            case ("PUT", NoDriveAgendaGanttDeckWriterTests.boardRoot):
                _ = version.next()
                return .init(status: 200, body: card())
            case ("GET", "/index.php/apps/deck/api/v1.0/boards/1"):
                return .init(status: 200, body: "{\"id\":1,\"labels\":[{\"id\":7,\"title\":\"🤖 Writer-Bot\"},{\"id\":8,\"title\":\"🤖 Research-Bot\"}],\"permissions\":{\"PERMISSION_MANAGE\":false}}")
            case ("PUT", _):
                _ = version.next()
                return .init(status: 200, body: "{}")
            default: return .init(status: 404)
            }
        }
        let queue = Self.queue(server, root: root)
        let link = AgendaLink(home: .board, boardId: 1, stackId: 2, cardId: 21, lastModified: 1_761_800_000)
        var due = NCAgendaEditCommand(id: UUID(), kind: .deckUpdate, createdAt: S.now, itemKey: "board:21", title: "Review sitemap", sourceKey: nil, link: link)
        due.deck = DeckChange(due: S.date("2026-11-04T12:00:00Z"))
        var agent = NCAgendaEditCommand(id: UUID(), kind: .deckAgent, createdAt: S.now, itemKey: "board:21", title: "Review sitemap", sourceKey: nil, link: link)
        agent.agent = AgentChoice(S.agent("AG-0003", "Research-Bot", label: "🤖 Research-Bot"))
        await queue.enqueue(due)
        await queue.enqueue(agent)
        let report = await queue.process(context: Self.ganttContext)
        #expect(report.saved.count == 2 && report.notSent == 0)
        #expect(await queue.commands().isEmpty)
        let verbs = server.requests("PUT").compactMap { $0.url?.lastPathComponent }
        #expect(verbs.contains("assignLabel"))
    }

    @Test("A task that really changed before the first save is still a conflict for both changes: only the version of our own save is passed on")
    func conflictStaysAConflict() async {
        let root = Self.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let server = EditFakeServer { request, path in
            guard path.hasPrefix("/ocs/v2.php/apps/nc_gantt") else { return .init(status: 404) }
            // Someone else changed the task: its updated_at is not the one the person saw
            if request.httpMethod == "GET" { return .init(status: 200, body: NoDriveAgendaGanttDeckWriterTests.tasksJSON(updatedAt: "2026-10-30 09:30:00")) }
            return .init(status: 200, body: "{\"ocs\":{\"data\":{\"task\":{\"id\":501},\"propagated\":[]}}}")
        }
        let queue = Self.queue(server, root: root)
        for command in Self.ganttSave() { await queue.enqueue(command) }
        let report = await queue.process(context: Self.ganttContext)
        #expect(report.saved.isEmpty && report.notSent == 2 && server.requests("PUT").isEmpty)
        #expect(await queue.commands().allSatisfy { $0.notSent?.kind == .changedElsewhere })
    }

    // MARK: A home that takes no change

    @Test("A home that refuses this app, is read only or is not installed: what waits for it is Not sent with the reason; the calendar goes on")
    func blockedHomes() async {
        for (state, word) in [(AgendaHomeState.refused(403), "sign-in"), (.readOnly, "checked"), (.notInstalled, "installed")] {
            let root = Self.root()
            defer { try? FileManager.default.removeItem(at: root) }
            let server = Self.calendarServer()
            let queue = Self.queue(server, root: root)
            for command in Self.ganttSave() { await queue.enqueue(command) }
            var deck = NCAgendaEditCommand(id: UUID(), kind: .deckUpdate, createdAt: S.now, itemKey: "board:21", title: "D", sourceKey: nil,
                                           link: AgendaLink(home: .board, boardId: 1, stackId: 2, cardId: 21))
            deck.deck = DeckChange(done: true)
            await queue.enqueue(deck)
            await queue.enqueue(Self.command("a", path: "/remote.php/dav/calendars/ali/work/a.ics"))
            var blocked = Self.context
            blocked.ganttState = state
            blocked.boardState = state
            let report = await queue.process(context: blocked)
            #expect(report.saved.count == 1 && report.notSent == 3, "\(state)")
            #expect(server.requests.allSatisfy { $0.url?.path.hasSuffix(".ics") == true })
            let left = await queue.commands()
            #expect(left.count == 3 && left.allSatisfy { $0.notSent?.kind == .refused && $0.notSent?.text.contains(word) == true && $0.notSent?.text.contains("Open") == true })
        }
    }

    @Test("A home that is only offline or unreachable holds what waits for it, and nothing is moved to Not sent")
    func unreachableHomesWait() async {
        let root = Self.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let queue = Self.queue(Self.calendarServer(), root: root)
        for command in Self.ganttSave() { await queue.enqueue(command) }
        var waiting = Self.context
        waiting.ganttGuardOK = false
        waiting.ganttState = .unreachable(savedAt: S.now)
        let report = await queue.process(context: waiting)
        #expect(report.saved.isEmpty && report.notSent == 0)
        #expect(await queue.commands().allSatisfy { $0.isWaiting })
    }

    @Test("The log of a whole send holds no title, address or password")
    func logIsClean() async {
        let root = Self.root()
        defer { try? FileManager.default.removeItem(at: root) }
        var lines: [String] = []
        let lock = NSLock()
        NCAgendaLog.sink = { line in lock.lock(); lines.append(line); lock.unlock() }
        defer { NCAgendaLog.sink = { _ in } }
        let queue = Self.queue(Self.calendarServer(), root: root)
        await queue.enqueue(Self.command("a", path: "/remote.php/dav/calendars/ali/work/a.ics", title: "SecretPlan"))
        _ = await queue.process(context: Self.context)
        lock.lock()
        let text = lines.joined(separator: "\n")
        lock.unlock()
        #expect(!text.contains("SecretPlan") && !text.contains("mara@example.org") && !text.contains("a.ics"))
    }
}

// MARK: - The editor's draft

@Suite("NoDrive NoAgenda edit draft")
struct NoDriveAgendaEditDraftTests {
    typealias S = AgendaEditSupport

    static func item(_ kind: AgendaKind, home: AgendaHome = .tasks) -> AgendaItem {
        AgendaItem(key: "k", home: home, kind: kind, title: "Pay rent", sourceKey: "s", sourceName: "S", sourceColor: "#2563EB", link: AgendaLink(home: home))
    }

    static func validate(_ draft: NCAgendaEditDraft, _ original: NCAgendaEditDraft) -> String? {
        draft.validationMessage(original: original, calendar: S.calendar, ganttZone: S.zone)
    }

    @Test("A to-do whose dates are days asks for days; an event or a to-do that ends before it starts is not saved")
    func validation() {
        var todo = Self.item(.todo)
        todo.start = S.date("2026-10-29T00:00:00Z")
        todo.due = S.date("2026-10-30T00:00:00Z")
        todo.allDay = true
        todo.dueAllDay = true
        let original = NCAgendaEditDraft(item: todo, calendar: S.calendar)
        #expect(original.dateOnly)
        var draft = original
        #expect(Self.validate(draft, original) == nil)
        draft.due = S.date("2026-10-28T00:00:00Z")
        #expect(Self.validate(draft, original) == NCAgendaEditText.t("_nodrive_agenda_edit_invalid_due_"))
        // The same day is fine for a date-only to-do
        draft.due = S.date("2026-10-29T18:00:00Z")
        #expect(Self.validate(draft, original) == nil)
        // An old item that is odd already can still get a new title
        var odd = Self.item(.todo)
        odd.start = S.date("2026-10-31T10:00:00Z")
        odd.due = S.date("2026-10-30T10:00:00Z")
        let oddOriginal = NCAgendaEditDraft(item: odd, calendar: S.calendar)
        var retitled = oddOriginal
        retitled.title = "New title"
        #expect(Self.validate(retitled, oddOriginal) == nil)

        var event = Self.item(.event, home: .calendar)
        event.start = S.date("2026-10-30T10:00:00Z")
        event.end = S.date("2026-10-30T11:00:00Z")
        let eventOriginal = NCAgendaEditDraft(item: event, calendar: S.calendar)
        var later = eventOriginal
        later.end = S.date("2026-10-30T09:00:00Z")
        #expect(Self.validate(later, eventOriginal) == NCAgendaEditText.t("_nodrive_agenda_edit_invalid_end_"))
        later.end = S.date("2026-10-30T10:00:00Z")
        #expect(Self.validate(later, eventOriginal) == NCAgendaEditText.t("_nodrive_agenda_edit_invalid_end_"))
        later.end = S.date("2026-10-30T12:00:00Z")
        #expect(Self.validate(later, eventOriginal) == nil)
    }

    @Test("A Gantt task offers only the statuses NoGantt 2.4.1 accepts; done is the Done switch")
    func ganttStatuses() {
        #expect(NCAgendaEditDraft.ganttStatuses == ["not_started", "in_progress", "blocked"])
        #expect(!NCAgendaEditDraft.ganttStatuses.contains("on_hold") && !NCAgendaEditDraft.ganttStatuses.contains("cancelled"))
        var task = Self.item(.ganttTask, home: .gantt)
        task.link = AgendaLink(home: .gantt, projectId: 5, taskId: 501, updatedAt: "2026-10-30 08:00:00")
        task.start = S.date("2026-10-29T09:00:00Z")
        task.end = S.date("2026-10-31T17:00:00Z")
        task.status = "in_progress"
        var draft = NCAgendaEditDraft(item: task, calendar: S.calendar)
        draft.status = "blocked"
        draft.end = S.date("2026-11-03T17:00:00Z")
        draft.agent = AgentChoice(S.agent("AG-0001", "Writer-Bot", resources: [10]))
        let commands = draft.commands(for: task, calendar: S.calendar, ganttZone: S.zone, now: S.now)
        // One Save with a change and an agent makes two commands, both for the version the person saw
        #expect(commands.map(\.kind) == [.ganttUpdate, .ganttAgent])
        #expect(commands.allSatisfy { $0.link.updatedAt == "2026-10-30 08:00:00" && $0.itemKey == "k" })
        #expect(commands[0].gantt?.status == "blocked" && commands[0].gantt?.endDay == "2026-11-03")
    }
}
