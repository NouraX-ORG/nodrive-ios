// SPDX-FileCopyrightText: 2026 Nourax
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// WebDAV and CalDAV request bodies, and a parser for the "multistatus" answers.
///
/// The bodies sit between `AGENDA-BODY-BEGIN` and `AGENDA-BODY-END` markers: the CI check sends exactly these
/// texts to the real server (tools/ci/server_agenda_check.py), so what the app asks is what the server was
/// tested with. `{{START}}` and `{{END}}` are replaced by the sync window at run time.
enum NCAgendaDAVXML {
    static let davNS = "DAV:"
    static let caldavNS = "urn:ietf:params:xml:ns:caldav"
    static let csNS = "http://calendarserver.org/ns/"
    static let appleNS = "http://apple.com/ns/ical/"
    static let ocNS = "http://owncloud.org/ns"

    // AGENDA-BODY-BEGIN principal
    static let principalBody = #"""
    <?xml version="1.0" encoding="utf-8"?>
    <d:propfind xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
      <d:prop>
        <d:displayname/>
        <c:calendar-user-address-set/>
      </d:prop>
    </d:propfind>
    """#
    // AGENDA-BODY-END principal

    // AGENDA-BODY-BEGIN home
    static let homeBody = #"""
    <?xml version="1.0" encoding="utf-8"?>
    <d:propfind xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav" xmlns:cs="http://calendarserver.org/ns/" xmlns:a="http://apple.com/ns/ical/" xmlns:oc="http://owncloud.org/ns">
      <d:prop>
        <d:resourcetype/>
        <d:displayname/>
        <a:calendar-color/>
        <c:supported-calendar-component-set/>
        <d:sync-token/>
        <cs:getctag/>
        <d:current-user-privilege-set/>
        <oc:owner-principal/>
        <cs:source/>
      </d:prop>
    </d:propfind>
    """#
    // AGENDA-BODY-END home

    // AGENDA-BODY-BEGIN events
    static let eventsBody = #"""
    <?xml version="1.0" encoding="utf-8"?>
    <c:calendar-query xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
      <d:prop>
        <d:getetag/>
        <c:calendar-data>
          <c:expand start="{{START}}" end="{{END}}"/>
        </c:calendar-data>
      </d:prop>
      <c:filter>
        <c:comp-filter name="VCALENDAR">
          <c:comp-filter name="VEVENT">
            <c:time-range start="{{START}}" end="{{END}}"/>
          </c:comp-filter>
        </c:comp-filter>
      </c:filter>
    </c:calendar-query>
    """#
    // AGENDA-BODY-END events

    // AGENDA-BODY-BEGIN todos
    static let todosBody = #"""
    <?xml version="1.0" encoding="utf-8"?>
    <c:calendar-query xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
      <d:prop>
        <d:getetag/>
        <c:calendar-data/>
      </d:prop>
      <c:filter>
        <c:comp-filter name="VCALENDAR">
          <c:comp-filter name="VTODO">
            <c:prop-filter name="COMPLETED">
              <c:is-not-defined/>
            </c:prop-filter>
          </c:comp-filter>
        </c:comp-filter>
      </c:filter>
    </c:calendar-query>
    """#
    // AGENDA-BODY-END todos

    /// The sync window as the CalDAV UTC form "20261001T000000Z".
    static func utcStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter.string(from: date)
    }

    static func eventsRequestBody(start: Date, end: Date) -> Data {
        let text = eventsBody
            .replacingOccurrences(of: "{{START}}", with: utcStamp(start))
            .replacingOccurrences(of: "{{END}}", with: utcStamp(end))
        return Data(text.utf8)
    }

    // MARK: - Multistatus

    /// One property of a response: its text, the names below it, the attribute `name` of the elements below it
    /// and every `href` below it.
    struct Property: Equatable {
        var text = ""
        var descendants: Set<String> = []
        var names: [String] = []
        var hrefs: [String] = []
    }

    struct Response: Equatable {
        var href = ""
        /// Properties that the server answered with status 200, keyed "namespace|local-name".
        var properties: [String: Property] = [:]
    }

    static func key(_ namespace: String, _ local: String) -> String {
        namespace + "|" + local
    }

    static func parseMultistatus(_ data: Data) -> [Response]? {
        let delegate = MultistatusParser()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = delegate
        guard parser.parse(), delegate.sawMultistatus else { return nil }
        return delegate.responses
    }

    private final class MultistatusParser: NSObject, XMLParserDelegate {
        var responses: [Response] = []
        var sawMultistatus = false

        private var path: [String] = []
        private var current: Response?
        private var propstat: [String: Property] = [:]
        private var propstatStatus = 0
        private var currentProperty: (key: String, value: Property)?
        private var text = ""
        private var hrefText = ""
        private var statusText = ""

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            let ns = namespaceURI ?? ""
            let qualified = NCAgendaDAVXML.key(ns, elementName)
            path.append(qualified)
            let depth = path.count
            text = ""
            if qualified == NCAgendaDAVXML.key(NCAgendaDAVXML.davNS, "multistatus") { sawMultistatus = true }
            if qualified == NCAgendaDAVXML.key(NCAgendaDAVXML.davNS, "response"), depth == 2 { current = Response() }
            if qualified == NCAgendaDAVXML.key(NCAgendaDAVXML.davNS, "propstat"), depth == 3 {
                propstat = [:]
                propstatStatus = 0
            }
            if depth == 5, path[3] == NCAgendaDAVXML.key(NCAgendaDAVXML.davNS, "prop") {
                currentProperty = (qualified, Property())
            } else if depth > 5, currentProperty != nil {
                currentProperty?.value.descendants.insert(qualified)
                if let name = attributeDict["name"] { currentProperty?.value.names.append(name) }
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            text += string
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            let ns = namespaceURI ?? ""
            let qualified = NCAgendaDAVXML.key(ns, elementName)
            let depth = path.count
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let isHref = qualified == NCAgendaDAVXML.key(NCAgendaDAVXML.davNS, "href")
            if isHref {
                if depth == 3 {
                    current?.href = trimmed
                } else if depth > 5, currentProperty != nil {
                    currentProperty?.value.hrefs.append(trimmed)
                }
            }
            if qualified == NCAgendaDAVXML.key(NCAgendaDAVXML.davNS, "status"), depth == 4, path.count >= 2,
               path[2] == NCAgendaDAVXML.key(NCAgendaDAVXML.davNS, "propstat") {
                let parts = trimmed.split(separator: " ")
                propstatStatus = parts.count >= 2 ? Int(parts[1]) ?? 0 : 0
            }
            if depth == 5, var property = currentProperty, property.key == qualified {
                property.value.text = trimmed
                propstat[qualified] = property.value
                currentProperty = nil
            }
            if qualified == NCAgendaDAVXML.key(NCAgendaDAVXML.davNS, "propstat"), depth == 3 {
                if propstatStatus == 200 {
                    for (name, value) in propstat { current?.properties[name] = value }
                }
                propstat = [:]
            }
            if qualified == NCAgendaDAVXML.key(NCAgendaDAVXML.davNS, "response"), depth == 2, let finished = current {
                responses.append(finished)
                current = nil
            }
            text = ""
            path.removeLast()
        }
    }
}
