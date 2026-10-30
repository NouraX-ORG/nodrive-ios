// SPDX-FileCopyrightText: 2026 Nourax
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

struct ICalAttendee: Codable, Equatable, Sendable {
    var address: String
    var partstat: String?
}

/// One VEVENT or VTODO (one instance, when the server expanded a repeating event).
struct ICalComponent: Codable, Equatable, Sendable {
    var kind: String = "VEVENT"
    var uid: String = ""
    var summary: String = ""
    var start: Date?
    var startAllDay = false
    var end: Date?
    var endAllDay = false
    var due: Date?
    var durationSeconds: Int?
    var status: String?
    var transparency: String?
    var hasRRule = false
    var recurrenceId: Date?
    var organizer: String?
    var attendees: [ICalAttendee] = []
    var categories: [String] = []
    var agentId: String?
    var completed: Date?
    var percent: Int?
    var descriptionLength = 0
    /// A TZID the phone doesn't know: shown in the device's time zone, and the sheet says so.
    var unknownZone: String?

    var isRepeating: Bool { hasRRule || recurrenceId != nil }
}

/// A small RFC 5545 reader: line unfolding, parameters, text escapes, DATE / DATE-TIME / UTC / TZID.
/// It reads VEVENT and VTODO; VALARM, VTIMEZONE and unknown parts are skipped.
enum NCAgendaICal {
    struct Line {
        var name: String
        var params: [String: String]
        var value: String
    }

    // MARK: - Lines

    static func unfold(_ text: String) -> [String] {
        var lines: [String] = []
        let normalised = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        for raw in normalised.split(separator: "\n", omittingEmptySubsequences: false) {
            if let first = raw.first, first == " " || first == "\t", !lines.isEmpty {
                lines[lines.count - 1] += String(raw.dropFirst())
            } else {
                lines.append(String(raw))
            }
        }
        return lines.filter { !$0.isEmpty }
    }

    static func parseLine(_ line: String) -> Line? {
        // The first colon outside double quotes ends the name and parameters.
        var inQuotes = false
        var colon: String.Index?
        var index = line.startIndex
        while index < line.endIndex {
            let character = line[index]
            if character == "\"" { inQuotes.toggle() }
            if character == ":" && !inQuotes { colon = index; break }
            index = line.index(after: index)
        }
        guard let colon else { return nil }
        let head = String(line[line.startIndex..<colon])
        let value = String(line[line.index(after: colon)...])
        var parts: [String] = []
        var current = ""
        inQuotes = false
        for character in head {
            if character == "\"" { inQuotes.toggle() }
            if character == ";" && !inQuotes {
                parts.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        parts.append(current)
        guard let name = parts.first?.uppercased(), !name.isEmpty else { return nil }
        var params: [String: String] = [:]
        for part in parts.dropFirst() {
            guard let equals = part.firstIndex(of: "=") else { continue }
            let key = String(part[part.startIndex..<equals]).uppercased()
            var parameterValue = String(part[part.index(after: equals)...])
            if parameterValue.hasPrefix("\""), parameterValue.hasSuffix("\""), parameterValue.count >= 2 {
                parameterValue = String(parameterValue.dropFirst().dropLast())
            }
            params[key] = parameterValue
        }
        return Line(name: name, params: params, value: value)
    }

    /// "\n", "\,", "\;" and "\\" in a TEXT value.
    static func unescape(_ value: String) -> String {
        guard value.contains("\\") else { return value }
        var result = ""
        var iterator = value.makeIterator()
        while let character = iterator.next() {
            if character == "\\", let next = iterator.next() {
                switch next {
                case "n", "N": result.append("\n")
                case ",", ";", "\\": result.append(next)
                default: result.append(next)
                }
            } else {
                result.append(character)
            }
        }
        return result
    }

    /// A list of text values (CATEGORIES): split at commas that are not escaped.
    static func splitList(_ value: String) -> [String] {
        var items: [String] = []
        var current = ""
        var escaped = false
        for character in value {
            if escaped {
                current.append("\\")
                current.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "," {
                items.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        if escaped { current.append("\\") }
        items.append(current)
        return items.map { unescape($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    // MARK: - Dates

    struct ParsedDate {
        var date: Date
        var allDay: Bool
        var unknownZone: String?
    }

    static func parseDate(_ value: String, params: [String: String], deviceZone: TimeZone = .current) -> ParsedDate? {
        let text = value.trimmingCharacters(in: .whitespaces)
        let digits = text.filter { $0.isNumber }
        if params["VALUE"]?.uppercased() == "DATE" || (text.count == 8 && digits.count == 8) {
            guard let date = make(text, zone: deviceZone, withTime: false) else { return nil }
            return ParsedDate(date: date, allDay: true, unknownZone: nil)
        }
        if text.hasSuffix("Z") || text.hasSuffix("z") {
            guard let date = make(String(text.dropLast()), zone: TimeZone(secondsFromGMT: 0)!, withTime: true) else { return nil }
            return ParsedDate(date: date, allDay: false, unknownZone: nil)
        }
        var zone = deviceZone
        var unknown: String?
        if let tzid = params["TZID"], !tzid.isEmpty {
            if let known = TimeZone(identifier: tzid) {
                zone = known
            } else {
                unknown = tzid
            }
        }
        guard let date = make(text, zone: zone, withTime: true) else { return nil }
        return ParsedDate(date: date, allDay: false, unknownZone: unknown)
    }

    private static func make(_ text: String, zone: TimeZone, withTime: Bool) -> Date? {
        let scalars = Array(text.unicodeScalars)
        func number(_ from: Int, _ count: Int) -> Int? {
            guard from + count <= scalars.count else { return nil }
            var result = 0
            for scalar in scalars[from..<(from + count)] {
                guard let digit = Int(String(scalar)) else { return nil }
                result = result * 10 + digit
            }
            return result
        }
        guard let year = number(0, 4), let month = number(4, 2), let day = number(6, 2) else { return nil }
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        if withTime {
            guard scalars.count >= 15, scalars[8] == "T" || scalars[8] == "t",
                  let hour = number(9, 2), let minute = number(11, 2), let second = number(13, 2) else { return nil }
            components.hour = hour
            components.minute = minute
            components.second = second
        } else {
            components.hour = 0
            components.minute = 0
            components.second = 0
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar.date(from: components)
    }

    /// "PT1H30M", "P1D", "P1W" in seconds.
    static func parseDuration(_ value: String) -> Int? {
        var text = value.trimmingCharacters(in: .whitespaces)
        var sign = 1
        if text.hasPrefix("-") { sign = -1; text.removeFirst() } else if text.hasPrefix("+") { text.removeFirst() }
        guard text.hasPrefix("P") else { return nil }
        text.removeFirst()
        var seconds = 0
        var number = ""
        var inTime = false
        for character in text {
            if character == "T" { inTime = true; continue }
            if character.isNumber { number.append(character); continue }
            guard let amount = Int(number) else { return nil }
            number = ""
            switch character {
            case "W": seconds += amount * 7 * 86_400
            case "D": seconds += amount * 86_400
            case "H" where inTime: seconds += amount * 3_600
            case "M" where inTime: seconds += amount * 60
            case "S" where inTime: seconds += amount
            default: return nil
            }
        }
        return sign * seconds
    }

    // MARK: - Components

    /// All VEVENT and VTODO of one calendar object.
    static func parse(_ text: String, deviceZone: TimeZone = .current) -> [ICalComponent] {
        var result: [ICalComponent] = []
        var current: ICalComponent?
        var depth = 0          // nesting inside the current VEVENT / VTODO (VALARM and so on)
        var skipDepth = 0      // nesting inside a skipped top-level part (VTIMEZONE)
        for raw in unfold(text) {
            guard let line = parseLine(raw) else { continue }
            if line.name == "BEGIN" {
                let part = line.value.uppercased()
                if current != nil {
                    depth += 1
                } else if part == "VEVENT" || part == "VTODO" {
                    current = ICalComponent()
                    current?.kind = part
                } else if part != "VCALENDAR" {
                    skipDepth += 1
                }
                continue
            }
            if line.name == "END" {
                let part = line.value.uppercased()
                if current != nil {
                    if depth > 0 {
                        depth -= 1
                    } else if part == "VEVENT" || part == "VTODO" {
                        if let finished = current { result.append(finished) }
                        current = nil
                    }
                } else if part != "VCALENDAR", skipDepth > 0 {
                    skipDepth -= 1
                }
                continue
            }
            guard current != nil, depth == 0, skipDepth == 0 else { continue }
            apply(line, to: &current!, deviceZone: deviceZone)
        }
        return result
    }

    private static func apply(_ line: Line, to component: inout ICalComponent, deviceZone: TimeZone) {
        switch line.name {
        case "UID":
            component.uid = line.value
        case "SUMMARY":
            component.summary = unescape(line.value)
        case "DTSTART":
            if let parsed = parseDate(line.value, params: line.params, deviceZone: deviceZone) {
                component.start = parsed.date
                component.startAllDay = parsed.allDay
                component.unknownZone = component.unknownZone ?? parsed.unknownZone
            }
        case "DTEND":
            if let parsed = parseDate(line.value, params: line.params, deviceZone: deviceZone) {
                component.end = parsed.date
                component.endAllDay = parsed.allDay
                component.unknownZone = component.unknownZone ?? parsed.unknownZone
            }
        case "DUE":
            if let parsed = parseDate(line.value, params: line.params, deviceZone: deviceZone) {
                component.due = parsed.date
                component.unknownZone = component.unknownZone ?? parsed.unknownZone
            }
        case "DURATION":
            component.durationSeconds = parseDuration(line.value)
        case "STATUS":
            component.status = line.value.uppercased()
        case "TRANSP":
            component.transparency = line.value.uppercased()
        case "RRULE":
            component.hasRRule = true
        case "RECURRENCE-ID":
            component.recurrenceId = parseDate(line.value, params: line.params, deviceZone: deviceZone)?.date
        case "ORGANIZER":
            component.organizer = address(line.value)
        case "ATTENDEE":
            component.attendees.append(ICalAttendee(address: address(line.value), partstat: line.params["PARTSTAT"]?.uppercased()))
        case "CATEGORIES":
            component.categories += splitList(line.value)
        case "X-NOURAX-AGENT-ID":
            let id = line.value.trimmingCharacters(in: .whitespaces)
            component.agentId = id.isEmpty ? nil : id
        case "COMPLETED":
            component.completed = parseDate(line.value, params: line.params, deviceZone: deviceZone)?.date
        case "PERCENT-COMPLETE":
            component.percent = Int(line.value.trimmingCharacters(in: .whitespaces))
        case "DESCRIPTION":
            component.descriptionLength = unescape(line.value).count
        default:
            break
        }
    }

    /// "mailto:Ali@example.org" -> "ali@example.org".
    static func address(_ value: String) -> String {
        var text = value.trimmingCharacters(in: .whitespaces)
        if text.lowercased().hasPrefix("mailto:") { text = String(text.dropFirst(7)) }
        return text.lowercased()
    }
}
