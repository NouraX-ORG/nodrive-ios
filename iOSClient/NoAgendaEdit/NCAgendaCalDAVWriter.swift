// SPDX-FileCopyrightText: 2026 Nourax
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Writes events and to-dos through CalDAV (design 9): the object is read **fresh**, patched line by line, and put back
/// with `If-Match`. A new object goes with `If-None-Match: *`. The only DELETE of NoAgenda is here, with `If-Match`.
struct NCAgendaCalDAVWriter {
    let http: NCAgendaHTTP
    /// The calendar tags of every agent of the registry (taken out of CATEGORIES with an agent change).
    var agentTags: Set<String> = []
    /// My addresses: an invitation (the organiser is someone else) can't get an agent.
    var myAddresses: Set<String> = []
    var zone: TimeZone = .current
    var now: @Sendable () -> Date = { Date() }

    /// "W/"abc"" and ""abc"" are the same version.
    static func sameVersion(_ first: String?, _ second: String?) -> Bool {
        func clean(_ text: String?) -> String? {
            guard var value = text?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
            if value.hasPrefix("W/") { value.removeFirst(2) }
            return value.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
        return clean(first) == clean(second)
    }

    private func send(_ method: NCAgendaMethod, path: String, headers: [String: String] = [:], body: Data? = nil) async -> (NCAgendaResponse?, NCAgendaWriteOutcome?) {
        do {
            let response = try await http.send(method, path: path, headers: headers, body: body, home: "caldav.write")
            return (response, nil)
        } catch let error as NCAgendaHTTPError {
            switch error {
            case .network: return (nil, .offline)
            default: return (nil, .refused(NCAgendaEditText.t("_nodrive_agenda_edit_refused_local_")))
            }
        } catch {
            return (nil, .offline)
        }
    }

    private func outcome(for status: Int) -> NCAgendaWriteOutcome {
        switch status {
        case 412, 404, 410: return .conflict
        case 500..<600: return .serverError
        default: return .refused(NCAgendaWriteTexts.refused(status: status))
        }
    }

    /// Changes one existing object. `seenEtag` is the version the person saw; another version means the other change
    /// won and nothing is written.
    func patch(path: String, seenEtag: String?, change: CalendarChange) async -> NCAgendaWriteOutcome {
        let (fresh, failure) = await send(.get, path: path, headers: ["Accept": "text/calendar"])
        if let failure { return failure }
        guard let fresh else { return .offline }
        guard fresh.status == 200 else { return outcome(for: fresh.status) }
        if let seenEtag, !Self.sameVersion(seenEtag, fresh.etag) { return .conflict }
        let text = String(decoding: fresh.data, as: UTF8.self)
        let components = NCAgendaICal.parse(text, deviceZone: zone)
        guard components.count == 1, let component = components.first else {
            return .refused(NCAgendaEditText.t("_nodrive_agenda_edit_refused_repeating_"))
        }
        if component.isRepeating { return .refused(NCAgendaEditText.t("_nodrive_agenda_edit_refused_repeating_")) }
        if change.agent != nil, component.kind == "VEVENT", let organiser = component.organizer, !myAddresses.contains(organiser) {
            return .refused(NCAgendaEditText.t("_nodrive_agenda_edit_invited_"))
        }
        guard let patched = NCAgendaICalPatch.apply(change, to: text, agentTags: agentTags, now: now(), zone: zone) else {
            return .refused(NCAgendaEditText.t("_nodrive_agenda_edit_refused_local_"))
        }
        // No ETag, no write: a PUT without If-Match could overwrite a change made meanwhile (as delete() does).
        guard let etag = fresh.etag else { return .refused(NCAgendaEditText.t("_nodrive_agenda_edit_refused_local_")) }
        let headers = ["Content-Type": "text/calendar; charset=utf-8", "If-Match": etag]
        let (answer, putFailure) = await send(.put, path: path, headers: headers, body: Data(patched.utf8))
        if let putFailure { return putFailure }
        guard let answer else { return .offline }
        if answer.status == 201 || answer.status == 204 || answer.status == 200 { return .plainSaved }
        return outcome(for: answer.status)
    }

    /// Creates a new object. A 412 means the name exists: when it holds our own UID, an earlier try had arrived, so it
    /// counts as saved (a retry after a lost answer must not become a conflict).
    func create(path: String, ics: String) async -> NCAgendaWriteOutcome {
        let headers = ["Content-Type": "text/calendar; charset=utf-8", "If-None-Match": "*"]
        let (answer, failure) = await send(.put, path: path, headers: headers, body: Data(ics.utf8))
        if let failure { return failure }
        guard let answer else { return .offline }
        if answer.status == 201 || answer.status == 204 || answer.status == 200 { return .plainSaved }
        if answer.status == 412 {
            let uid = NCAgendaICal.parse(ics).first?.uid
            let (existing, existingFailure) = await send(.get, path: path, headers: ["Accept": "text/calendar"])
            if existingFailure != nil { return existingFailure ?? .offline }
            if let existing, existing.status == 200, let uid, !uid.isEmpty,
               NCAgendaICal.parse(String(decoding: existing.data, as: UTF8.self)).first?.uid == uid {
                return .plainSaved
            }
            return .conflict
        }
        return outcome(for: answer.status)
    }

    /// Deletes one object of the person's own calendar, with `If-Match` (the trash bin keeps it).
    func delete(path: String, seenEtag: String?) async -> NCAgendaWriteOutcome {
        let (fresh, failure) = await send(.get, path: path, headers: ["Accept": "text/calendar"])
        if let failure { return failure }
        guard let fresh else { return .offline }
        guard fresh.status == 200 else { return fresh.status == 404 ? .plainSaved : outcome(for: fresh.status) }
        if let seenEtag, !Self.sameVersion(seenEtag, fresh.etag) { return .conflict }
        guard let etag = fresh.etag else { return .refused(NCAgendaEditText.t("_nodrive_agenda_edit_refused_local_")) }
        let (answer, deleteFailure) = await send(.delete, path: path, headers: ["If-Match": etag])
        if let deleteFailure { return deleteFailure }
        guard let answer else { return .offline }
        if answer.status == 204 || answer.status == 200 || answer.status == 404 { return .plainSaved }
        return outcome(for: answer.status)
    }
}
