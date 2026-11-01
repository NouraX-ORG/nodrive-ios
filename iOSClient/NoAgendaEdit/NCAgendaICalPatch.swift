// SPDX-FileCopyrightText: 2026 Nourax
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// A change of one event or to-do, as the person made it. Nil means "not changed".
struct CalendarChange: Codable, Equatable, Sendable {
    /// Who does it: `id` nil is Self. `tag` is the registry's calendar tag, written to CATEGORIES too.
    struct AgentWrite: Codable, Equatable, Sendable {
        var id: String?
        var tag: String?
    }

    var title: String?
    var allDay: Bool?
    var start: Date?
    /// Event: DTEND (for an all-day event the day after the last day, as in iCalendar).
    var end: Date?
    var due: Date?
    var descriptionText: String?
    var done: Bool?
    var agent: AgentWrite?

    var isEmpty: Bool {
        title == nil && allDay == nil && start == nil && end == nil && due == nil && descriptionText == nil && done == nil && agent == nil
    }

    /// A later change of the same item laid over this one (the waiting command folds the second change into itself).
    func merged(with later: CalendarChange) -> CalendarChange {
        var result = self
        if let value = later.title { result.title = value }
        if let value = later.allDay { result.allDay = value }
        if let value = later.start { result.start = value }
        if let value = later.end { result.end = value }
        if let value = later.due { result.due = value }
        if let value = later.descriptionText { result.descriptionText = value }
        if let value = later.done { result.done = value }
        if let value = later.agent { result.agent = value }
        return result
    }
}

/// Changes one event or to-do in the text of the object **as the server has it now**: only the lines it owns are
/// replaced, and every other line (alarms, attendees, unknown properties, other categories, time zones) stays byte for
/// byte. The object is never parsed and written again, so nothing the app does not know can be lost.
enum NCAgendaICalPatch {
    // MARK: - Text

    static func escape(_ text: String) -> String {
        var result = ""
        for character in text {
            switch character {
            case "\\": result += "\\\\"
            case ";": result += "\\;"
            case ",": result += "\\,"
            case "\n", "\r\n", "\r": result += "\\n"
            default: result.append(character)
            }
        }
        return result
    }

    /// Lines longer than 75 octets are folded (RFC 5545 3.1); a character is never split.
    static func fold(_ line: String) -> [String] {
        guard line.utf8.count > 75 else { return [line] }
        var lines: [String] = []
        var current = ""
        var size = 0
        var limit = 75
        for character in line {
            let width = String(character).utf8.count
            if size + width > limit {
                lines.append(current)
                current = " "
                size = 1
                limit = 75
            }
            current.append(character)
            size += width
        }
        if !current.isEmpty { lines.append(current) }
        return lines
    }

    static func utcStamp(_ date: Date) -> String {
        NCAgendaDAVXML.utcStamp(date)
    }

    static func dayStamp(_ date: Date, zone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d%02d%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    private static func property(_ name: String, params: String = "", _ value: String) -> [String] {
        fold(name + params + ":" + value)
    }

    // MARK: - Chunks (one property with its continuation lines)

    private struct Chunk {
        var lines: [String]
        var name: String
        var value: String
        var logical: String
    }

    private static func chunks(of physical: [String]) -> [Chunk] {
        var groups: [[String]] = []
        for line in physical {
            if let first = line.first, first == " " || first == "\t", !groups.isEmpty {
                groups[groups.count - 1].append(line)
            } else {
                groups.append([line])
            }
        }
        return groups.map { lines in
            let logical = lines.enumerated().map { $0.offset == 0 ? $0.element : String($0.element.dropFirst()) }.joined()
            let parsed = NCAgendaICal.parseLine(logical)
            return Chunk(lines: lines, name: parsed?.name ?? "", value: parsed?.value ?? "", logical: logical)
        }
    }

    // MARK: - Patch

    /// The new text of the object, or nil when it has no VEVENT or VTODO to change.
    /// `agentTags` are the calendar tags of every agent in the registry: with an agent change they are taken out of
    /// CATEGORIES (and so is every value that starts with "agent:").
    static func apply(_ change: CalendarChange, to ics: String, agentTags: Set<String>, now: Date, zone: TimeZone) -> String? {
        let eol = ics.contains("\r\n") ? "\r\n" : "\n"
        let physical = ics.components(separatedBy: eol)
        let all = chunks(of: physical)

        var beginIndex: Int?
        var endIndex: Int?
        var kind = "VEVENT"
        var depth = 0
        var properties: [String: [Int]] = [:]
        for (index, chunk) in all.enumerated() {
            if beginIndex == nil {
                if chunk.name == "BEGIN", chunk.value.uppercased() == "VEVENT" || chunk.value.uppercased() == "VTODO" {
                    beginIndex = index
                    kind = chunk.value.uppercased()
                }
                continue
            }
            if chunk.name == "BEGIN" { depth += 1; continue }
            if chunk.name == "END" {
                if depth == 0 { endIndex = index; break }
                depth -= 1
                continue
            }
            if depth == 0 { properties[chunk.name, default: []].append(index) }
        }
        guard let endIndex else { return nil }

        let current = NCAgendaICal.parse(ics, deviceZone: zone).first { $0.kind == kind }
        var replacements: [Int: [String]] = [:]
        var removals = Set<Int>()
        var insertions: [String] = []

        func set(_ name: String, _ lines: [String]) {
            let found = properties[name] ?? []
            if let first = found.first {
                replacements[first] = lines
                for extra in found.dropFirst() { removals.insert(extra) }
            } else {
                insertions += lines
            }
        }
        func remove(_ name: String) {
            for index in properties[name] ?? [] { removals.insert(index) }
        }

        if let title = change.title { set("SUMMARY", property("SUMMARY", escape(title))) }
        if let text = change.descriptionText {
            if text.isEmpty { remove("DESCRIPTION") } else { set("DESCRIPTION", property("DESCRIPTION", escape(text))) }
        }

        if kind == "VEVENT" {
            if change.start != nil || change.end != nil || change.allDay != nil {
                let allDay = change.allDay ?? current?.startAllDay ?? false
                let start = change.start ?? current?.start ?? now
                var end = change.end ?? current?.end ?? current?.durationSeconds.map { start.addingTimeInterval(TimeInterval($0)) }
                if end == nil { end = start.addingTimeInterval(allDay ? 86_400 : 3_600) }
                if allDay {
                    var finish = end ?? start
                    if finish <= start { finish = start.addingTimeInterval(86_400) }
                    set("DTSTART", property("DTSTART", params: ";VALUE=DATE", dayStamp(start, zone: zone)))
                    set("DTEND", property("DTEND", params: ";VALUE=DATE", dayStamp(finish, zone: zone)))
                } else {
                    var finish = end ?? start
                    if finish <= start { finish = start.addingTimeInterval(3_600) }
                    set("DTSTART", property("DTSTART", utcStamp(start)))
                    set("DTEND", property("DTEND", utcStamp(finish)))
                }
                remove("DURATION")
            }
        } else {
            if let start = change.start {
                if change.allDay == true || (change.allDay == nil && current?.startAllDay == true) {
                    set("DTSTART", property("DTSTART", params: ";VALUE=DATE", dayStamp(start, zone: zone)))
                } else {
                    set("DTSTART", property("DTSTART", utcStamp(start)))
                }
            }
            if let due = change.due {
                if change.allDay == true {
                    set("DUE", property("DUE", params: ";VALUE=DATE", dayStamp(due, zone: zone)))
                } else {
                    set("DUE", property("DUE", utcStamp(due)))
                }
                remove("DURATION")
            }
            if let done = change.done {
                if done {
                    set("STATUS", property("STATUS", "COMPLETED"))
                    set("COMPLETED", property("COMPLETED", utcStamp(now)))
                    set("PERCENT-COMPLETE", property("PERCENT-COMPLETE", "100"))
                } else {
                    set("STATUS", property("STATUS", "NEEDS-ACTION"))
                    remove("COMPLETED")
                    remove("PERCENT-COMPLETE")
                }
            }
        }

        if let agent = change.agent {
            if let id = agent.id {
                set("X-NOURAX-AGENT-ID", property("X-NOURAX-AGENT-ID", id))
            } else {
                remove("X-NOURAX-AGENT-ID")
            }
            var kept: [String] = []
            for index in properties["CATEGORIES"] ?? [] {
                for value in NCAgendaICal.splitList(all[index].value) where !agentTags.contains(value) && !value.hasPrefix("agent:") {
                    kept.append(value)
                }
            }
            if let tag = agent.tag, !kept.contains(tag) { kept.append(tag) }
            if kept.isEmpty {
                remove("CATEGORIES")
            } else {
                set("CATEGORIES", property("CATEGORIES", kept.map { escape($0) }.joined(separator: ",")))
            }
        }

        set("DTSTAMP", property("DTSTAMP", utcStamp(now)))
        set("LAST-MODIFIED", property("LAST-MODIFIED", utcStamp(now)))
        if kind == "VEVENT" {
            let sequence = properties["SEQUENCE"]?.first.flatMap { Int(all[$0].value.trimmingCharacters(in: .whitespaces)) } ?? 0
            set("SEQUENCE", property("SEQUENCE", String(sequence + 1)))
        }

        // A removal of a line that is also replaced (a duplicate) is fine; the replaced index is never in `removals`.
        var output: [String] = []
        for (index, chunk) in all.enumerated() {
            if index == endIndex { output += insertions }
            if removals.contains(index) { continue }
            if let replacement = replacements[index] { output += replacement } else { output += chunk.lines }
        }
        return output.joined(separator: eol)
    }

    // MARK: - New objects

    /// A new event or to-do in UTC, with PRODID `-//Nourax//NoAgenda//EN`.
    static func make(kind: String, uid: String, change: CalendarChange, now: Date, zone: TimeZone) -> String {
        var lines = ["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Nourax//NoAgenda//EN", "BEGIN:" + kind]
        lines += property("UID", uid)
        lines += property("DTSTAMP", utcStamp(now))
        lines += property("LAST-MODIFIED", utcStamp(now))
        lines += property("SUMMARY", escape(change.title ?? ""))
        let allDay = change.allDay ?? false
        if kind == "VEVENT" {
            let start = change.start ?? now
            var end = change.end ?? start.addingTimeInterval(allDay ? 86_400 : 3_600)
            if end <= start { end = start.addingTimeInterval(allDay ? 86_400 : 3_600) }
            lines += property("SEQUENCE", "0")
            if allDay {
                lines += property("DTSTART", params: ";VALUE=DATE", dayStamp(start, zone: zone))
                lines += property("DTEND", params: ";VALUE=DATE", dayStamp(end, zone: zone))
            } else {
                lines += property("DTSTART", utcStamp(start))
                lines += property("DTEND", utcStamp(end))
            }
        } else {
            if let start = change.start { lines += property("DTSTART", utcStamp(start)) }
            if let due = change.due { lines += property("DUE", utcStamp(due)) }
            lines += property("STATUS", "NEEDS-ACTION")
        }
        if let text = change.descriptionText, !text.isEmpty { lines += property("DESCRIPTION", escape(text)) }
        if let agent = change.agent {
            if let id = agent.id { lines += property("X-NOURAX-AGENT-ID", id) }
            if let tag = agent.tag { lines += property("CATEGORIES", escape(tag)) }
        }
        lines += ["END:" + kind, "END:VCALENDAR"]
        return lines.joined(separator: "\r\n") + "\r\n"
    }
}
