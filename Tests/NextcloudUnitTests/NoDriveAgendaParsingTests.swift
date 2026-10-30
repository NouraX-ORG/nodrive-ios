// SPDX-FileCopyrightText: 2026 Nourax
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import Nextcloud

/// A canned server for the NoAgenda tests: each request is answered by a closure that sees its method and path.
final class AgendaFakeServer: @unchecked Sendable {
    typealias Handler = (_ method: String, _ path: String, _ request: URLRequest) -> (Int, String)?

    private let lock = NSLock()
    private var log: [URLRequest] = []
    var handler: Handler

    init(_ handler: @escaping Handler) {
        self.handler = handler
    }

    var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return log
    }

    func http(base: String = "https://drive.test", user: String = "ali", password: String = "pw-planted-9f3") -> NCAgendaHTTP {
        let basic = Data("\(user):\(password)".utf8).base64EncodedString()
        return NCAgendaHTTP(account: "\(user) \(base)", base: base, userId: user, authorization: "Basic " + basic,
                            userAgent: "NoDrive-test") { [self] request in
            lock.lock()
            log.append(request)
            lock.unlock()
            // URLComponents keeps a trailing slash, URL.path drops it
            let path = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.path } ?? ""
            let answer = handler(request.httpMethod ?? "", path, request) ?? (404, "")
            let response = HTTPURLResponse(url: request.url!, statusCode: answer.0, httpVersion: "HTTP/1.1",
                                           headerFields: ["ETag": "\"etag-1\""])!
            return (Data(answer.1.utf8), response)
        }
    }
}

/// Answers shaped like the real server's (the CI job checks that these keep the real shape).
enum AgendaFixtures {
    static let ns = "xmlns:d=\"DAV:\" xmlns:c=\"urn:ietf:params:xml:ns:caldav\" xmlns:cs=\"http://calendarserver.org/ns/\" xmlns:a=\"http://apple.com/ns/ical/\" xmlns:oc=\"http://owncloud.org/ns\" xmlns:nc=\"http://nextcloud.org/ns\""

    static let principal = """
    <?xml version="1.0"?>
    <d:multistatus \(ns)>
     <d:response><d:href>/remote.php/dav/principals/users/ali/</d:href>
      <d:propstat><d:prop><d:displayname>Ali</d:displayname>
       <c:calendar-user-address-set><d:href>mailto:Ali@Example.org</d:href><d:href>/remote.php/dav/principals/users/ali/</d:href></c:calendar-user-address-set>
      </d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
    </d:multistatus>
    """

    private static func calendarResponse(_ uri: String, name: String, color: String?, components: [String], owner: String,
                                         write: Bool = true, subscribed: Bool = false) -> String {
        let comps = components.map { "<c:comp name=\"\($0)\"/>" }.joined()
        let type = subscribed ? "<d:collection/><cs:subscribed/>" : "<d:collection/><c:calendar/>"
        let privilege = write ? "<d:privilege><d:write/></d:privilege><d:privilege><d:read/></d:privilege>" : "<d:privilege><d:read/></d:privilege>"
        let colour = color.map { "<a:calendar-color>\($0)</a:calendar-color>" } ?? ""
        let source = subscribed ? "<cs:source><d:href>https://holidays.example.org/feed.ics</d:href></cs:source>" : ""
        return """
         <d:response><d:href>/remote.php/dav/calendars/ali/\(uri)/</d:href>
          <d:propstat><d:prop><d:resourcetype>\(type)</d:resourcetype><d:displayname>\(name)</d:displayname>\(colour)
           <c:supported-calendar-component-set>\(comps)</c:supported-calendar-component-set>
           <d:sync-token>http://sabre.io/ns/sync/\(uri.count)</d:sync-token><cs:getctag>http://sabre.io/ns/sync/\(uri.count)</cs:getctag>
           <d:current-user-privilege-set>\(privilege)</d:current-user-privilege-set>
           <oc:owner-principal>/remote.php/dav/principals/users/\(owner)/</oc:owner-principal><nc:owner-displayname>\(owner)</nc:owner-displayname>
           \(source)
          </d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat>
          <d:propstat><d:prop><x:unknown xmlns:x="urn:x"/></d:prop><d:status>HTTP/1.1 404 Not Found</d:status></d:propstat></d:response>
        """
    }

    static var home: String {
        """
        <?xml version="1.0"?>
        <d:multistatus \(ns)>
         <d:response><d:href>/remote.php/dav/calendars/ali/</d:href><d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
        \(calendarResponse("personal", name: "Personal", color: "#0082c9", components: ["VEVENT", "VTODO"], owner: "ali"))
        \(calendarResponse("work", name: "Work", color: "#E9322D", components: ["VEVENT"], owner: "ali"))
        \(calendarResponse("app-generated--deck--board-1", name: "Team board", color: nil, components: ["VEVENT", "VTODO"], owner: "ali", write: false))
        \(calendarResponse("holidays", name: "Holidays", color: "#00A000", components: ["VEVENT"], owner: "ali", write: false, subscribed: true))
        \(calendarResponse("team_shared_by_mara", name: "Team", color: nil, components: ["VEVENT"], owner: "mara", write: false))
         <d:response><d:href>/remote.php/dav/calendars/ali/trashbin/</d:href><d:propstat><d:prop><d:resourcetype><d:collection/><x:deleted-calendars xmlns:x="http://nextcloud.org/ns"/></d:resourcetype></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
        </d:multistatus>
        """
    }

    static let dentistICS = "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nBEGIN:VEVENT\r\nUID:dentist-1\r\nSUMMARY:Dentist\r\nDTSTART:20261030T100000Z\r\nDTEND:20261030T110000Z\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n"
    static let draftICS = "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nBEGIN:VTODO\r\nUID:draft-1\r\nSUMMARY:Draft report\r\nDUE:20261030T150000Z\r\nCATEGORIES:agent:AG-0001\r\nX-NOURAX-AGENT-ID:AG-0001\r\nSTATUS:NEEDS-ACTION\r\nEND:VTODO\r\nEND:VCALENDAR\r\n"

    static func report(_ items: [(href: String, ics: String)]) -> String {
        let rows = items.map { item in
            "<d:response><d:href>\(item.href)</d:href><d:propstat><d:prop><d:getetag>\"e-\(item.href.count)\"</d:getetag><c:calendar-data>\(item.ics)</c:calendar-data></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>"
        }.joined()
        return "<?xml version=\"1.0\"?><d:multistatus \(ns)>\(rows)</d:multistatus>"
    }

    // MARK: NoGantt (shapes of nc_gantt 2.4.1)

    static func ocs(_ data: String) -> String {
        "{\"ocs\":{\"meta\":{\"status\":\"ok\",\"statuscode\":200,\"message\":\"OK\"},\"data\":\(data)}}"
    }

    static let myTasks = ocs("""
    {"has_linked_resource":true,"tasks":[{"id":11,"title":"Write homepage copy","project_id":1,"project_title":"Website","project_color":"#0082c9","subproject_id":3,"start_date":"2026-10-28 09:00:00","end_date":"2026-10-30 17:00:00","manual_progress":40,"status":"in_progress","risk_level":"none","overdue":false}]}
    """)
    static let projects = ocs("""
    [{"id":1,"title":"Website","owner_id":"mara","owner_display_name":"Mara","permission":"editor","color":"#0082c9","roles_only_assignment":false}]
    """)
    static let resources = ocs("""
    [{"id":5,"name":"Ali","type":"person","uid":"ali","uid_display_name":"Ali","group_id":null,"unit":"h"},
     {"id":9,"name":"🤖 Writer-Bot (Ali)","type":"person","uid":null,"uid_display_name":null,"unit":"h"}]
    """)
    static let tasks = ocs("""
    [{"id":11,"project_id":1,"title":"Write homepage copy","subproject_id":3,"start_date":"2026-10-28 09:00:00","end_date":"2026-10-30 17:00:00","work":8,"updated_at":"2026-10-28 10:00:00","progress_mode":"manual","manual_progress":40,"status":"in_progress","dependencies":[{"task_id":11,"predecessor_id":"t-10","dependency_type":"FS","lag_days":0}],"resources":[{"id":1,"task_id":11,"resource_id":5,"work":4,"sort_order":0},{"id":2,"task_id":11,"resource_id":9,"work":null,"sort_order":1}],"deck_card_id":null},
     {"id":10,"project_id":1,"title":"Outline","subproject_id":3,"start_date":"2026-10-20 09:00:00","end_date":"2026-10-22 17:00:00","work":2,"updated_at":"2026-10-20 10:00:00","progress_mode":"manual","manual_progress":0,"status":"in_progress","dependencies":[],"resources":[{"id":3,"task_id":10,"resource_id":5,"work":2,"sort_order":0}],"deck_card_id":null}]
    """)
    static let milestones = ocs("""
    [{"id":1,"project_id":1,"subproject_id":null,"task_id":null,"title":"Launch","milestone_date":"2026-11-02","dependency_type":"FS"}]
    """)
    static let subprojects = ocs("""
    [{"id":3,"project_id":1,"parent_id":null,"title":"Copy","color":"#2563EB","sort_order":1,"status":"open","plan_start":null,"plan_end":null}]
    """)
    static let settings = ocs("""
    {"timezone":"UTC","work_start":"09:00","work_end":"17:00","hours_per_pt":8}
    """)
    static let capacity = ocs("""
    {"window_days":30,"findings":[]}
    """)
    static let taskSync = ocs("""
    {"enabled":false,"calendar_uri":null,"calendars":[],"last_run":null,"error":null,"synced_count":0}
    """)

    // MARK: NoBoard (Deck 1.19.1)

    static let capabilities = ocs("""
    {"version":{"major":35},"capabilities":{"deck":{"version":"1.19.1","canCreateBoards":true,"apiVersions":["1.0","1.1"]}}}
    """)
    static let boards = """
    [{"id":1,"title":"Team board","color":"0082c9","owner":{"uid":"mara","displayname":"Mara"},"permissions":{"PERMISSION_READ":true,"PERMISSION_EDIT":true,"PERMISSION_MANAGE":false,"PERMISSION_SHARE":false},"labels":[{"id":7,"title":"🤖 Writer-Bot"}],"archived":false,"deletedAt":0}]
    """
    static let stacks = """
    [{"id":2,"title":"To do","boardId":1,"cards":[{"id":21,"title":"Review sitemap","stackId":2,"duedate":"2026-10-30T12:00:00+00:00","done":null,"archived":false,"lastModified":1761800000,"labels":[{"id":7,"title":"🤖 Writer-Bot"}],"assignedUsers":[{"id":1,"participant":{"uid":"ali","displayname":"Ali","type":0}}]}]}]
    """
    static let registry = """
    {"schema":"nourax-agent-registry","version":1,"updated_utc":"2026-10-28T18:00:00Z","source":"PLACEHOLDER",
     "agents":[
      {"id":"AG-0001","name":"Writer-Bot","person":"ALI","status":"active","organisation":"demo-org","skills":["writing"],
       "availability":{"timezone":"Europe/London","weekly":[],"capacity_hours_per_week":40,"days_off":[]},
       "links":{"nogantt_resource_ids":[],"noboard_label":"🤖 Writer-Bot","calendar_tag":"agent:AG-0001"}},
      {"id":"AG-0002","name":"Design-Bot","person":"sara","status":"paused","organisation":"demo-org","skills":[],
       "links":{"nogantt_resource_ids":[12],"noboard_label":"🤖 Design-Bot","calendar_tag":"agent:AG-0002"}},
      {"id":"AG-0003","name":"Old-Bot","person":"ali","status":"retired","organisation":"other-org","extra":"ignored","links":{}}
     ]}
    """

    /// A server with every home, for the store and log tests. Counts every request.
    static func server(gantt: Bool = true, deck: Bool = true, registryText: String? = registry) -> AgendaFakeServer {
        AgendaFakeServer { method, path, request in
            switch (method, path) {
            case ("GET", "/ocs/v2.php/cloud/user"):
                return (200, ocs("{\"id\":\"ali\",\"display-name\":\"Ali\",\"email\":\"ali-secret@example.org\",\"groups\":[\"staff\"]}"))
            case ("PROPFIND", "/remote.php/dav/principals/users/ali/"): return (207, principal)
            case ("PROPFIND", "/remote.php/dav/calendars/ali/"): return (207, home)
            case ("REPORT", "/remote.php/dav/calendars/ali/personal/"):
                let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
                if body.contains("name=\"VTODO\"") {
                    return (207, report([("/remote.php/dav/calendars/ali/personal/draft.ics", draftICS)]))
                }
                return (207, report([("/remote.php/dav/calendars/ali/personal/dentist.ics", dentistICS)]))
            case ("REPORT", _): return (207, report([]))
            case ("GET", "/remote.php/dav/files/ali/NoAgenda/agent-registry.json"):
                return registryText.map { (200, $0) } ?? (404, "")
            case ("GET", "/ocs/v2.php/cloud/capabilities"): return (200, capabilities)
            case ("GET", "/index.php/apps/deck/api/v1.0/boards"): return deck ? (200, boards) : (404, "")
            case ("GET", "/index.php/apps/deck/api/v1.0/boards/1/stacks"): return (200, stacks)
            default: break
            }
            guard path.hasPrefix("/ocs/v2.php/apps/nc_gantt/api/v1/") else { return nil }
            guard gantt else { return (404, "") }
            switch String(path.dropFirst("/ocs/v2.php/apps/nc_gantt/api/v1/".count)) {
            case "my-tasks": return (200, myTasks)
            case "projects": return (200, projects)
            case "resources": return (200, resources)
            case "settings": return (200, settings)
            case "task-sync": return (200, taskSync)
            case "capacity-check": return (200, capacity)
            case "projects/1/tasks": return (200, tasks)
            case "projects/1/milestones": return (200, milestones)
            case "projects/1/subprojects": return (200, subprojects)
            default: return (404, "")
            }
        }
    }
}

// MARK: - Registry

@Suite("NoDrive NoAgenda registry")
struct NoDriveAgendaRegistryTests {
    @Test("A valid file gives its agents; person ids are lower case; unknown fields are ignored")
    func valid() throws {
        guard case let .valid(registry) = NCAgendaRegistry.parse(Data(AgendaFixtures.registry.utf8)) else {
            Issue.record("expected a valid registry")
            return
        }
        #expect(registry.agents.count == 3)
        #expect(registry.agent(id: "AG-0001")?.person == "ali")
        #expect(registry.agent(id: "AG-0001")?.boardLabel == "🤖 Writer-Bot")
        #expect(registry.agent(id: "AG-0002")?.ganttResourceIds == [12])
        #expect(registry.agent(id: "AG-0002")?.status == .paused)
        #expect(registry.agent(id: "AG-0003")?.status == .retired)
        #expect(registry.agents(of: "ALI").map(\.id) == ["AG-0001", "AG-0003"])
    }

    @Test("The organisations of a person are those of their own agents")
    func organisations() throws {
        guard case let .valid(registry) = NCAgendaRegistry.parse(Data(AgendaFixtures.registry.utf8)) else { return }
        #expect(registry.organisations(of: "ali") == ["demo-org", "other-org"])
        #expect(registry.organisations(of: "nobody").isEmpty)
    }

    @Test("Bad JSON, another schema, another version and a repeated id are invalid")
    func invalid() {
        #expect(NCAgendaRegistry.parse(Data("not json".utf8)) == .invalid)
        #expect(NCAgendaRegistry.parse(Data("{\"schema\":\"other\",\"version\":1,\"agents\":[]}".utf8)) == .invalid)
        #expect(NCAgendaRegistry.parse(Data("{\"schema\":\"nourax-agent-registry\",\"version\":2,\"agents\":[]}".utf8)) == .invalid)
        #expect(NCAgendaRegistry.parse(Data("{\"schema\":\"nourax-agent-registry\",\"version\":1}".utf8)) == .invalid)
        let duplicate = """
        {"schema":"nourax-agent-registry","version":1,"agents":[
         {"id":"AG-1","name":"A","person":"p","status":"active"},{"id":"AG-1","name":"B","person":"p","status":"active"}]}
        """
        #expect(NCAgendaRegistry.parse(Data(duplicate.utf8)) == .invalid)
    }

    @Test("An agent without a name, a person or a known status is left out")
    func incompleteAgents() throws {
        let text = """
        {"schema":"nourax-agent-registry","version":1,"agents":[
         {"id":"AG-1","name":"","person":"p","status":"active"},
         {"id":"AG-2","name":"B","person":"","status":"active"},
         {"id":"AG-3","name":"C","person":"p","status":"sleeping"},
         {"id":"AG-4","name":"D","person":"p","status":"active"}]}
        """
        guard case let .valid(registry) = NCAgendaRegistry.parse(Data(text.utf8)) else {
            Issue.record("expected valid")
            return
        }
        #expect(registry.agents.map(\.id) == ["AG-4"])
    }

    @Test("The registry is read from the person's own NoDrive file while the agents app has no address")
    func sourceSwitch() {
        #expect(NCAgendaRegistrySources.agentsAppRegistryURL == nil)
        #expect(NCAgendaRegistrySources.current is NCAgendaDriveFileRegistrySource)
        #expect(NCAgendaDriveFileRegistrySource.relativePath == "NoAgenda/agent-registry.json")
    }

    @Test("The Drive file source sends If-None-Match and tells missing, unchanged and data apart")
    func driveSource() async throws {
        let server = AgendaFakeServer { _, _, request in
            switch request.value(forHTTPHeaderField: "If-None-Match") {
            case "\"same\"": return (304, "")
            case "\"gone\"": return (404, "")
            default: return (200, "{}")
            }
        }
        let source = NCAgendaDriveFileRegistrySource()
        #expect(try await source.load(http: server.http(), etag: "\"same\"") == .notModified)
        #expect(try await source.load(http: server.http(), etag: "\"gone\"") == .missing)
        if case .data = try await source.load(http: server.http(), etag: nil) {} else { Issue.record("expected data") }
        #expect(server.requests.allSatisfy { $0.url?.path == "/remote.php/dav/files/ali/NoAgenda/agent-registry.json" })
    }
}

// MARK: - iCalendar

@Suite("NoDrive NoAgenda iCalendar")
struct NoDriveAgendaICalTests {
    let utc = TimeZone(secondsFromGMT: 0)!

    func date(_ text: String) -> Date {
        ISO8601DateFormatter().date(from: text)!
    }

    @Test("Folded lines, escapes, parameters, TZID, CATEGORIES with escaped commas, agent id, PARTSTAT, TRANSP; VALARM and VTIMEZONE are skipped")
    func fullEvent() {
        let ics = [
            "BEGIN:VCALENDAR", "VERSION:2.0",
            "BEGIN:VTIMEZONE", "TZID:Europe/Berlin", "BEGIN:STANDARD", "DTSTART:19701025T030000", "TZOFFSETFROM:+0200", "END:STANDARD", "END:VTIMEZONE",
            "BEGIN:VEVENT", "UID:abc-1",
            "SUMMARY:Planning\\, weekly\\; re",
            " view",
            "DTSTART;TZID=Europe/Berlin:20261030T100000",
            "DTEND;TZID=Europe/Berlin:20261030T110000",
            "CATEGORIES:agent:AG-0001,Work\\, team",
            "X-NOURAX-AGENT-ID:AG-0001",
            "ORGANIZER;CN=\"Mara: Boss\":mailto:Mara@example.org",
            "ATTENDEE;PARTSTAT=ACCEPTED;CN=Ali:mailto:Ali@Example.org",
            "TRANSP:TRANSPARENT",
            "DESCRIPTION:one\\ntwo",
            "BEGIN:VALARM", "TRIGGER:-PT15M", "ACTION:DISPLAY", "SUMMARY:alarm text", "END:VALARM",
            "END:VEVENT", "END:VCALENDAR",
        ].joined(separator: "\r\n")
        let parsed = NCAgendaICal.parse(ics, deviceZone: utc)
        #expect(parsed.count == 1)
        let event = parsed[0]
        #expect(event.kind == "VEVENT")
        #expect(event.summary == "Planning, weekly; review")
        #expect(event.start == date("2026-10-30T09:00:00Z"))
        #expect(event.end == date("2026-10-30T10:00:00Z"))
        #expect(event.categories == ["agent:AG-0001", "Work, team"])
        #expect(event.agentId == "AG-0001")
        #expect(event.organizer == "mara@example.org")
        #expect(event.attendees == [ICalAttendee(address: "ali@example.org", partstat: "ACCEPTED")])
        #expect(event.transparency == "TRANSPARENT")
        #expect(event.descriptionLength == 7)
        #expect(event.unknownZone == nil)
        #expect(!event.isRepeating)
    }

    @Test("DATE is all-day, a trailing Z is UTC, a floating time is the device's, an unknown TZID falls back and is noted")
    func dates() {
        let allDay = NCAgendaICal.parseDate("20261030", params: ["VALUE": "DATE"], deviceZone: utc)
        #expect(allDay?.allDay == true)
        #expect(allDay?.date == date("2026-10-30T00:00:00Z"))
        #expect(NCAgendaICal.parseDate("20261030T093000Z", params: [:], deviceZone: TimeZone(identifier: "Asia/Tokyo")!)?.date == date("2026-10-30T09:30:00Z"))
        #expect(NCAgendaICal.parseDate("20261030T093000", params: [:], deviceZone: utc)?.date == date("2026-10-30T09:30:00Z"))
        let unknown = NCAgendaICal.parseDate("20261030T093000", params: ["TZID": "W. Europe Standard Time"], deviceZone: utc)
        #expect(unknown?.date == date("2026-10-30T09:30:00Z"))
        #expect(unknown?.unknownZone == "W. Europe Standard Time")
        #expect(NCAgendaICal.parseDate("garbage", params: [:], deviceZone: utc) == nil)
    }

    @Test("Durations")
    func durations() {
        #expect(NCAgendaICal.parseDuration("PT1H30M") == 5400)
        #expect(NCAgendaICal.parseDuration("P1D") == 86_400)
        #expect(NCAgendaICal.parseDuration("P1W") == 604_800)
        #expect(NCAgendaICal.parseDuration("-PT15M") == -900)
        #expect(NCAgendaICal.parseDuration("1H") == nil)
    }

    @Test("A to-do: due, percent, status, completed; repeating marks")
    func todo() {
        let ics = "BEGIN:VCALENDAR\r\nBEGIN:VTODO\r\nUID:t1\r\nSUMMARY:Draft\r\nDUE:20261031T120000Z\r\nPERCENT-COMPLETE:40\r\nSTATUS:IN-PROCESS\r\nRRULE:FREQ=WEEKLY\r\nEND:VTODO\r\nBEGIN:VTODO\r\nUID:t2\r\nSUMMARY:Done\r\nSTATUS:COMPLETED\r\nCOMPLETED:20261029T100000Z\r\nEND:VTODO\r\nEND:VCALENDAR"
        let parsed = NCAgendaICal.parse(ics, deviceZone: utc)
        #expect(parsed.count == 2)
        #expect(parsed[0].kind == "VTODO")
        #expect(parsed[0].due == date("2026-10-31T12:00:00Z"))
        #expect(parsed[0].percent == 40)
        #expect(parsed[0].hasRRule)
        #expect(parsed[0].isRepeating)
        #expect(parsed[1].status == "COMPLETED")
        #expect(parsed[1].completed == date("2026-10-29T10:00:00Z"))
    }

    @Test("An expanded instance has a RECURRENCE-ID and counts as repeating")
    func instance() {
        let ics = "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:s\r\nSUMMARY:Stand-up\r\nDTSTART:20261030T080000Z\r\nDTEND:20261030T081500Z\r\nRECURRENCE-ID:20261030T080000Z\r\nEND:VEVENT\r\nEND:VCALENDAR"
        let parsed = NCAgendaICal.parse(ics, deviceZone: utc)
        #expect(parsed[0].recurrenceId == date("2026-10-30T08:00:00Z"))
        #expect(parsed[0].isRepeating)
    }

    @Test("Text without any component gives nothing")
    func nothing() {
        #expect(NCAgendaICal.parse("", deviceZone: utc).isEmpty)
        #expect(NCAgendaICal.parse("BEGIN:VCALENDAR\r\nEND:VCALENDAR", deviceZone: utc).isEmpty)
    }
}

// MARK: - WebDAV and CalDAV

@Suite("NoDrive NoAgenda CalDAV")
struct NoDriveAgendaDAVTests {
    @Test("The request bodies are well-formed XML")
    func bodiesAreXML() {
        let now = Date(timeIntervalSince1970: 1_761_800_000)
        let bodies = [NCAgendaDAVXML.principalBody, NCAgendaDAVXML.homeBody, NCAgendaDAVXML.todosBody,
                      String(decoding: NCAgendaDAVXML.eventsRequestBody(start: now, end: now.addingTimeInterval(86_400)), as: UTF8.self)]
        for body in bodies {
            let parser = XMLParser(data: Data(body.utf8))
            #expect(parser.parse(), "\(body.prefix(60))")
        }
        #expect(!NCAgendaDAVXML.eventsRequestBody(start: now, end: now).isEmpty)
        #expect(!String(decoding: NCAgendaDAVXML.eventsRequestBody(start: now, end: now), as: UTF8.self).contains("{{"))
    }

    @Test("The events body asks for expanded repeats; the to-do body does not expand and skips completed ones")
    func queryShapes() {
        #expect(NCAgendaDAVXML.eventsBody.contains("c:expand"))
        #expect(NCAgendaDAVXML.eventsBody.contains("VEVENT"))
        #expect(!NCAgendaDAVXML.todosBody.contains("expand"))
        #expect(NCAgendaDAVXML.todosBody.contains("VTODO"))
        #expect(NCAgendaDAVXML.todosBody.contains("is-not-defined"))
    }

    @Test("The principal: display name and the address set")
    func principal() async throws {
        let server = AgendaFakeServer { _, _, _ in (207, AgendaFixtures.principal) }
        let principal = try await NCAgendaCalendarReader(http: server.http()).readPrincipal()
        #expect(principal.displayName == "Ali")
        #expect(principal.addresses.contains("ali@example.org"))
        #expect(server.requests.first?.value(forHTTPHeaderField: "Depth") == "0")
    }

    @Test("The calendar home: calendars, subscriptions, board calendars, owners and privileges; the home and the trash are skipped")
    func calendars() async throws {
        let server = AgendaFakeServer { _, _, _ in (207, AgendaFixtures.home) }
        let calendars = try await NCAgendaCalendarReader(http: server.http()).readCalendars()
        #expect(calendars.map(\.uri) == ["personal", "work", "app-generated--deck--board-1", "holidays", "team_shared_by_mara"])
        let personal = try #require(calendars.first { $0.uri == "personal" })
        #expect(personal.name == "Personal")
        #expect(personal.color == "#0082c9")
        #expect(personal.components == ["VEVENT", "VTODO"])
        #expect(personal.writable)
        #expect(personal.ownerPrincipal?.hasSuffix("/users/ali/") == true)
        #expect(personal.syncToken != nil && personal.ctag != nil)
        #expect(calendars.first { $0.uri == "app-generated--deck--board-1" }?.isAppGenerated == true)
        #expect(calendars.first { $0.uri == "holidays" }?.isSubscription == true)
        #expect(calendars.first { $0.uri == "team_shared_by_mara" }?.writable == false)
        #expect(calendars.first { $0.uri == "work" }?.onlyTodos == false)
    }

    @Test("Events and to-dos come from the two reports; objects keep their ETag")
    func objects() async throws {
        let server = AgendaFakeServer { method, path, _ in
            guard method == "REPORT" else { return nil }
            return (207, AgendaFixtures.report([("\(path)x.ics", AgendaFixtures.dentistICS)]))
        }
        let calendar = RawCalendar(href: "/remote.php/dav/calendars/ali/personal/", uri: "personal", name: "Personal", components: ["VEVENT", "VTODO"])
        let objects = try await NCAgendaCalendarReader(http: server.http()).readObjects(of: calendar, windowStart: Date(), windowEnd: Date().addingTimeInterval(86_400))
        #expect(objects.count == 2)
        #expect(objects[0].components.first?.summary == "Dentist")
        #expect(objects[0].etag != nil)
        #expect(server.requests.count == 2)
    }

    @Test("A calendar's last path part is decoded")
    func lastPart() {
        #expect(NCAgendaCalendarReader.lastPathPart("/remote.php/dav/calendars/ali/my%20cal/") == "my cal")
        #expect(NCAgendaCalendarReader.lastPathPart("") == "")
    }
}

// MARK: - NoGantt and Deck

@Suite("NoDrive NoAgenda NoGantt")
struct NoDriveAgendaGanttTests {
    @Test("The 2.4.1 answers decode: my tasks, tasks with resources and t- dependencies, projects, resources, milestones")
    func decoding() throws {
        let wrapper = try #require(NCAgendaHTTP.ocsData(Data(AgendaFixtures.myTasks.utf8)) as? [String: Any])
        #expect(NCAgendaJSON.bool(wrapper["has_linked_resource"]) == true)
        let mine = NCAgendaJSON.dictionaries(wrapper["tasks"]).compactMap(NCAgendaGanttReader.decodeMyTask)
        #expect(mine.count == 1)
        #expect(mine[0].projectId == 1)
        #expect(mine[0].progress == 40)
        let rows = NCAgendaJSON.dictionaries(NCAgendaHTTP.ocsData(Data(AgendaFixtures.tasks.utf8)))
        let task = try #require(rows.compactMap(NCAgendaGanttReader.decodeTask).first)
        #expect(task.resources.map(\.resourceId) == [5, 9])
        #expect(task.resources[0].work == 4)
        #expect(task.dependencies.first?.predecessorId == "t-10")
        #expect(task.updatedAt == "2026-10-28 10:00:00")
        let resources = NCAgendaJSON.dictionaries(NCAgendaHTTP.ocsData(Data(AgendaFixtures.resources.utf8))).compactMap(NCAgendaGanttReader.decodeResource)
        #expect(resources.first { $0.id == 5 }?.uid == "ali")
        #expect(resources.first { $0.id == 9 }?.uid == nil)
        let project = try #require(NCAgendaJSON.dictionaries(NCAgendaHTTP.ocsData(Data(AgendaFixtures.projects.utf8))).compactMap(NCAgendaGanttReader.decodeProject).first)
        #expect(project.permission == "editor")
        #expect(project.ownerId == "mara")
    }

    @Test("The contract passes the 2.4.1 fixtures and fails a missing key or another type; extra keys are fine")
    func contract() throws {
        let tasks = NCAgendaJSON.dictionaries(NCAgendaHTTP.ocsData(Data(AgendaFixtures.tasks.utf8)))
        #expect(NCAgendaGanttContract.allConform(tasks, to: NCAgendaGanttContract.task))
        var missing = tasks[0]
        missing["resources"] = nil
        #expect(!NCAgendaGanttContract.conforms(missing, to: NCAgendaGanttContract.task))
        var wrongType = tasks[0]
        wrongType["id"] = "11"
        #expect(!NCAgendaGanttContract.conforms(wrongType, to: NCAgendaGanttContract.task))
        var extra = tasks[0]
        extra["brand_new_field"] = [1, 2]
        #expect(NCAgendaGanttContract.conforms(extra, to: NCAgendaGanttContract.task))
        var nullDate = tasks[0]
        nullDate["start_date"] = NSNull()
        #expect(NCAgendaGanttContract.conforms(nullDate, to: NCAgendaGanttContract.task))
    }

    @Test("A full read over the canned server gives rows and passes the guard")
    func fullRead() async throws {
        let server = AgendaFixtures.server()
        let raw = try await NCAgendaGanttReader(http: server.http()).read(settings: AgendaSettings(), userId: "ali", groups: [], previous: nil)
        #expect(raw.contractOK)
        #expect(raw.linked)
        #expect(raw.myTasks.count == 1)
        #expect(raw.projects.map(\.id) == [1])
        #expect(raw.tasks["1"]?.count == 2)
        #expect(raw.milestones["1"]?.first?.title == "Launch")
        #expect(raw.timezone == "UTC")
        #expect(raw.copyEnabled == false)
        // Every request carries the CSRF pass and the OCS path
        #expect(server.requests.allSatisfy { $0.value(forHTTPHeaderField: "OCS-APIRequest") == "true" })
        #expect(server.requests.allSatisfy { $0.url?.path.hasPrefix("/ocs/v2.php/apps/nc_gantt/api/v1/") == true })
    }

    @Test("A changed shape makes the read answer not conform (read only)")
    func guardFails() async throws {
        let server = AgendaFakeServer { _, path, _ in
            if path.hasSuffix("/my-tasks") { return (200, AgendaFixtures.ocs("{\"has_linked_resource\":true,\"tasks\":[{\"id\":\"x\",\"title\":1}]}")) }
            if path.hasSuffix("/projects") { return (200, AgendaFixtures.ocs("[]")) }
            if path.hasSuffix("/resources") { return (200, AgendaFixtures.ocs("[]")) }
            if path.hasSuffix("/settings") { return (200, AgendaFixtures.ocs("{\"timezone\":\"UTC\"}")) }
            return (404, "")
        }
        let raw = try await NCAgendaGanttReader(http: server.http()).read(settings: AgendaSettings(), userId: "ali", groups: [], previous: nil)
        #expect(!raw.contractOK)
    }

    @Test("404 on my tasks means NoGantt is not installed; 403 means refused")
    func notInstalledAndRefused() async {
        let missing = AgendaFakeServer { _, _, _ in (404, "") }
        await #expect(throws: NCAgendaGanttError.notInstalled) {
            _ = try await NCAgendaGanttReader(http: missing.http()).read(settings: AgendaSettings(), userId: "ali", groups: [], previous: nil)
        }
        let refused = AgendaFakeServer { _, _, _ in (403, "") }
        await #expect(throws: NCAgendaGanttError.refused(403)) {
            _ = try await NCAgendaGanttReader(http: refused.http()).read(settings: AgendaSettings(), userId: "ali", groups: [], previous: nil)
        }
    }

    @Test("Dates are wall times in NoGantt's zone")
    func ganttDates() {
        let berlin = TimeZone(identifier: "Europe/Berlin")!
        let date = NCAgendaAssembler.ganttDate("2026-10-30 09:00:00", zone: berlin)
        #expect(date == ISO8601DateFormatter().date(from: "2026-10-30T08:00:00Z"))
        #expect(NCAgendaAssembler.ganttDate("2026-10-30", zone: berlin) != nil)
        #expect(NCAgendaAssembler.ganttDate(nil, zone: berlin) == nil)
        #expect(NCAgendaAssembler.ganttDate("soon", zone: berlin) == nil)
    }
}

@Suite("NoDrive NoAgenda NoBoard")
struct NoDriveAgendaDeckTests {
    @Test("Only the checked major and minor version may write")
    func versionGuard() {
        #expect(RawDeck(version: "1.19.1").isReadWrite)
        #expect(RawDeck(version: "1.19.9").isReadWrite)
        #expect(!RawDeck(version: "1.20.0").isReadWrite)
        #expect(!RawDeck(version: "1.18.6").isReadWrite)
        #expect(!RawDeck(version: "2.19.0").isReadWrite)
        #expect(!RawDeck(version: nil).isReadWrite)
    }

    @Test("A full read: version, boards, cards with assigned users, labels and a due date")
    func read() async throws {
        let server = AgendaFixtures.server()
        let raw = try await NCAgendaDeckReader(http: server.http()).read(settings: AgendaSettings(), userId: "ali")
        #expect(raw.version == "1.19.1")
        #expect(raw.isReadWrite)
        #expect(raw.boards.map(\.id) == [1])
        #expect(raw.boards[0].labels.first?.title == "🤖 Writer-Bot")
        let card = try #require(raw.cards["1"]?.first)
        #expect(card.title == "Review sitemap")
        #expect(card.assigned.map(\.uid) == ["ali"])
        #expect(card.labels == ["🤖 Writer-Bot"])
        #expect(card.done == false)
        #expect(card.due == ISO8601DateFormatter().date(from: "2026-10-30T12:00:00Z"))
        #expect(server.requests.allSatisfy { $0.value(forHTTPHeaderField: "OCS-APIRequest") == "true" })
    }

    @Test("Other versions read, and are read only; 403 is refused; a done date means done")
    func otherCases() async throws {
        let refused = AgendaFakeServer { _, path, _ in path.hasSuffix("/capabilities") ? (200, AgendaFixtures.capabilities) : (403, "") }
        await #expect(throws: NCAgendaDeckError.refused(403)) {
            _ = try await NCAgendaDeckReader(http: refused.http()).read(settings: AgendaSettings(), userId: "ali")
        }
        let card = NCAgendaDeckReader.decodeCard(["id": 5, "title": "x", "done": "2026-10-29T10:00:00+00:00"], boardId: 1, stackId: 2)
        #expect(card?.done == true)
        let open = NCAgendaDeckReader.decodeCard(["id": 6, "title": "y", "done": NSNull()], boardId: 1, stackId: 2)
        #expect(open?.done == false)
    }
}
