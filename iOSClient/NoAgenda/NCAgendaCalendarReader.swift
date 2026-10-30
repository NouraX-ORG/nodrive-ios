// SPDX-FileCopyrightText: 2026 Nourax
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

struct RawPrincipal: Codable, Equatable, Sendable {
    var displayName: String = ""
    /// Lower-case addresses without "mailto:".
    var addresses: [String] = []
}

/// One calendar object (one .ics file) as read: its components and ETag. A repeating event that the server
/// expanded has one component per instance in the window.
struct CalObject: Codable, Equatable, Sendable {
    var href: String
    var etag: String?
    var components: [ICalComponent]
}

/// A calendar or to-do list as the server describes it, plus what was last read from it.
struct RawCalendar: Codable, Equatable, Sendable {
    var href: String
    var uri: String
    var name: String
    var color: String?
    var ownerPrincipal: String?
    var ownerName: String?
    var components: [String] = []
    var isSubscription = false
    var isBirthday = false
    var isAppGenerated = false
    var writable = true
    var syncToken: String?
    var ctag: String?
    /// Start of the window the events were read for.
    var windowStart: Date?
    var readAt: Date?
    var failedAt: Date?
    var objects: [CalObject] = []

    var hasEvents: Bool { components.isEmpty || components.contains("VEVENT") }
    var hasTodos: Bool { components.isEmpty || components.contains("VTODO") }
    var onlyTodos: Bool { components == ["VTODO"] }
    var changeMarker: String { (syncToken ?? "") + "|" + (ctag ?? "") }
}

/// CalDAV reads (NoCalendar events and NoTasks to-dos). Read only.
struct NCAgendaCalendarReader {
    let http: NCAgendaHTTP
    var deviceZone: TimeZone = .current

    static let birthdayUri = "contact_birthdays"
    static let appGeneratedPrefix = "app-generated--"

    /// "remote.php/dav/principals/users/<uid>/"
    var principalPath: String { "remote.php/dav/principals/users/" + http.encodedUser + "/" }
    var homePath: String { "remote.php/dav/calendars/" + http.encodedUser + "/" }

    private func multistatus(_ response: NCAgendaResponse) throws -> [NCAgendaDAVXML.Response] {
        guard response.status == 207, let parsed = NCAgendaDAVXML.parseMultistatus(response.data) else {
            throw NCAgendaHTTPError.status(response.status)
        }
        return parsed
    }

    func readPrincipal() async throws -> RawPrincipal {
        let response = try await http.send(.propfind, path: principalPath, headers: ["Depth": "0"],
                                           body: Data(NCAgendaDAVXML.principalBody.utf8), home: "caldav.principal")
        let responses = try multistatus(response)
        var principal = RawPrincipal()
        for item in responses {
            if let name = item.properties[NCAgendaDAVXML.key(NCAgendaDAVXML.davNS, "displayname")]?.text {
                principal.displayName = name
            }
            if let set = item.properties[NCAgendaDAVXML.key(NCAgendaDAVXML.caldavNS, "calendar-user-address-set")] {
                principal.addresses += set.hrefs.map { NCAgendaICal.address($0) }
            }
        }
        return principal
    }

    /// The calendars and lists of the person's calendar home (own and shared with them), without their objects.
    func readCalendars() async throws -> [RawCalendar] {
        let response = try await http.send(.propfind, path: homePath, headers: ["Depth": "1"],
                                           body: Data(NCAgendaDAVXML.homeBody.utf8), home: "caldav.home")
        let davNS = NCAgendaDAVXML.davNS
        let caldavNS = NCAgendaDAVXML.caldavNS
        let csNS = NCAgendaDAVXML.csNS
        var result: [RawCalendar] = []
        for item in try multistatus(response) {
            guard let type = item.properties[NCAgendaDAVXML.key(davNS, "resourcetype")] else { continue }
            let isCalendar = type.descendants.contains(NCAgendaDAVXML.key(caldavNS, "calendar"))
            let isSubscribed = type.descendants.contains(NCAgendaDAVXML.key(csNS, "subscribed"))
            guard isCalendar || isSubscribed else { continue }
            let uri = Self.lastPathPart(item.href)
            var calendar = RawCalendar(href: item.href, uri: uri,
                                       name: item.properties[NCAgendaDAVXML.key(davNS, "displayname")]?.text ?? uri)
            if calendar.name.isEmpty { calendar.name = uri }
            let color = item.properties[NCAgendaDAVXML.key(NCAgendaDAVXML.appleNS, "calendar-color")]?.text
            calendar.color = (color?.isEmpty ?? true) ? nil : color
            calendar.ownerPrincipal = item.properties[NCAgendaDAVXML.key(NCAgendaDAVXML.ocNS, "owner-principal")]?.text
            let ownerName = item.properties[NCAgendaDAVXML.key(NCAgendaDAVXML.ncNS, "owner-displayname")]?.text
            calendar.ownerName = (ownerName?.isEmpty ?? true) ? nil : ownerName
            calendar.components = item.properties[NCAgendaDAVXML.key(caldavNS, "supported-calendar-component-set")]?.names.map { $0.uppercased() } ?? []
            calendar.isSubscription = isSubscribed || item.properties[NCAgendaDAVXML.key(csNS, "source")] != nil
            calendar.isBirthday = uri == Self.birthdayUri
            calendar.isAppGenerated = uri.hasPrefix(Self.appGeneratedPrefix)
            if let privileges = item.properties[NCAgendaDAVXML.key(davNS, "current-user-privilege-set")] {
                let writes = [NCAgendaDAVXML.key(davNS, "write"), NCAgendaDAVXML.key(davNS, "write-content"), NCAgendaDAVXML.key(davNS, "all")]
                calendar.writable = writes.contains { privileges.descendants.contains($0) }
            }
            let token = item.properties[NCAgendaDAVXML.key(davNS, "sync-token")]?.text
            calendar.syncToken = (token?.isEmpty ?? true) ? nil : token
            let ctag = item.properties[NCAgendaDAVXML.key(csNS, "getctag")]?.text
            calendar.ctag = (ctag?.isEmpty ?? true) ? nil : ctag
            result.append(calendar)
        }
        return result
    }

    /// Events (expanded by the server, in UTC) and open to-dos of one calendar.
    func readObjects(of calendar: RawCalendar, windowStart: Date, windowEnd: Date) async throws -> [CalObject] {
        var objects: [CalObject] = []
        if calendar.hasEvents {
            objects += try await report(calendar, body: NCAgendaDAVXML.eventsRequestBody(start: windowStart, end: windowEnd), home: "caldav.events")
        }
        if calendar.hasTodos {
            objects += try await report(calendar, body: Data(NCAgendaDAVXML.todosBody.utf8), home: "caldav.todos")
        }
        return objects
    }

    private func report(_ calendar: RawCalendar, body: Data, home: String) async throws -> [CalObject] {
        let response = try await http.send(.report, path: calendar.href, headers: ["Depth": "1"], body: body, home: home)
        var objects: [CalObject] = []
        for item in try multistatus(response) {
            guard let data = item.properties[NCAgendaDAVXML.key(NCAgendaDAVXML.caldavNS, "calendar-data")]?.text, !data.isEmpty else { continue }
            let components = NCAgendaICal.parse(data, deviceZone: deviceZone)
            guard !components.isEmpty else { continue }
            let etag = item.properties[NCAgendaDAVXML.key(NCAgendaDAVXML.davNS, "getetag")]?.text
            objects.append(CalObject(href: item.href, etag: etag, components: components))
        }
        NCAgendaLog.log("objects", home: home, count: objects.count)
        return objects
    }

    /// The last part of a path, decoded ("/a/b/personal/" -> "personal").
    static func lastPathPart(_ href: String) -> String {
        var parts = href.split(separator: "/", omittingEmptySubsequences: true)
        guard let last = parts.popLast() else { return "" }
        return String(last).removingPercentEncoding ?? String(last)
    }
}
