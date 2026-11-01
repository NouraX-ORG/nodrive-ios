// SPDX-FileCopyrightText: 2026 Nourax
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Writes a card through Deck's REST API (design 9). Deck's card update is a full replace: a field that is not sent is
/// cleared. So the card is read right before, every field of it goes back, and only the changed one is replaced. Nothing
/// here ever deletes a card.
struct NCAgendaDeckWriter {
    let http: NCAgendaHTTP
    /// The time a card is marked done (Deck keeps `done` as a date).
    var now: @Sendable () -> Date = { Date() }
    var root: String { NCAgendaDeckReader.root }

    static let labelColor = "2563EB"

    private func send(_ method: NCAgendaMethod, path: String, body: [String: Any]? = nil) async -> (NCAgendaResponse?, NCAgendaWriteOutcome?) {
        do {
            let data = try body.map { try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]) }
            let response = try await http.send(method, path: path, headers: ["Accept": "application/json", "Content-Type": "application/json"],
                                               body: data, home: "deck.write")
            return (response, nil)
        } catch let error as NCAgendaHTTPError {
            if error == .network { return (nil, .offline) }
            return (nil, .refused(NCAgendaEditText.f("_nodrive_agenda_edit_refused_generic_", 0)))
        } catch {
            return (nil, .offline)
        }
    }

    private func map(status: Int) -> NCAgendaWriteOutcome {
        switch status {
        case 404: return .conflict
        case 401, 403: return .refused(NCAgendaEditText.t("_nodrive_agenda_edit_deck_forbidden_"))
        case 500..<600: return .serverError
        default: return .refused(NCAgendaWriteTexts.refused(status: status))
        }
    }

    static func cardPath(_ root: String, board: Int, stack: Int, card: Int) -> String {
        root + "boards/\(board)/stacks/\(stack)/cards/\(card)"
    }

    /// "2026-11-04T12:00:00+00:00", the form Deck itself writes.
    static func isoDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssxxx"
        return formatter.string(from: date)
    }

    /// The full body of the update: every field from the fresh card, the changed one replaced.
    static func body(fresh: [String: Any], change: DeckChange, now: Date = Date()) -> [String: Any] {
        var body: [String: Any] = [:]
        body["title"] = NCAgendaJSON.string(fresh["title"]) ?? ""
        body["type"] = NCAgendaJSON.string(fresh["type"]) ?? "plain"
        if let owner = fresh["owner"] as? [String: Any] {
            body["owner"] = NCAgendaJSON.string(owner["uid"]) ?? NCAgendaJSON.string(owner["primaryKey"]) ?? ""
        } else {
            body["owner"] = NCAgendaJSON.string(fresh["owner"]) ?? ""
        }
        body["description"] = NCAgendaJSON.string(fresh["description"]) ?? ""
        body["order"] = NCAgendaJSON.int(fresh["order"]) ?? 0
        body["archived"] = NCAgendaJSON.bool(fresh["archived"]) ?? false
        if let color = NCAgendaJSON.string(fresh["color"]), !color.isEmpty { body["color"] = color }
        if let start = NCAgendaJSON.string(fresh["startdate"]), !start.isEmpty { body["startdate"] = start } else { body["startdate"] = NSNull() }
        if change.clearDue {
            body["duedate"] = NSNull()
        } else if let due = change.due {
            body["duedate"] = isoDate(due)
        } else if let text = NCAgendaJSON.string(fresh["duedate"]), !text.isEmpty {
            body["duedate"] = text
        } else {
            body["duedate"] = NSNull()
        }
        if let done = change.done {
            // Deck wants the date it was done (a boolean gives an error 500); not done is null
            body["done"] = done ? isoDate(now) : NSNull()
        } else if let text = NCAgendaJSON.string(fresh["done"]), !text.isEmpty, !(fresh["done"] is NSNull) {
            body["done"] = text
        } else if let flag = fresh["done"] as? Bool, flag {
            body["done"] = true
        } else {
            body["done"] = NSNull()
        }
        return body
    }

    func freshCard(board: Int, stack: Int, card: Int) async -> ([String: Any]?, NCAgendaWriteOutcome?) {
        let (response, failure) = await send(.get, path: Self.cardPath(root, board: board, stack: stack, card: card))
        if let failure { return (nil, failure) }
        guard let response else { return (nil, .offline) }
        guard response.status == 200 else { return (nil, map(status: response.status)) }
        guard let object = (try? JSONSerialization.jsonObject(with: response.data)) as? [String: Any] else {
            return (nil, .refused(NCAgendaEditText.f("_nodrive_agenda_edit_refused_generic_", 0)))
        }
        return (object, nil)
    }

    /// Due date or done.
    func update(board: Int, stack: Int, card: Int, seenLastModified: Int?, change: DeckChange) async -> NCAgendaWriteOutcome {
        let (fresh, failure) = await freshCard(board: board, stack: stack, card: card)
        if let failure { return failure }
        guard let fresh else { return .offline }
        if let seenLastModified, NCAgendaJSON.int(fresh["lastModified"]) != seenLastModified { return .conflict }
        let body = Self.body(fresh: fresh, change: change, now: now())
        let (response, putFailure) = await send(.put, path: Self.cardPath(root, board: board, stack: stack, card: card), body: body)
        if let putFailure { return putFailure }
        guard let response else { return .offline }
        guard response.status == 200 || response.status == 201 || response.status == 204 else { return map(status: response.status) }
        return .plainSaved
    }

    /// My agent label: the new one is put on first, then my other agents' labels come off.
    func changeAgent(board: Int, stack: Int, card: Int, seenLastModified: Int?, choice: AgentChoice, myAgents: [RegistryAgent]) async -> NCAgendaWriteOutcome {
        let (fresh, failure) = await freshCard(board: board, stack: stack, card: card)
        if let failure { return failure }
        guard let fresh else { return .offline }
        if let seenLastModified, NCAgendaJSON.int(fresh["lastModified"]) != seenLastModified { return .conflict }
        let current = NCAgendaJSON.dictionaries(fresh["labels"]).compactMap { row -> (Int, String)? in
            guard let id = NCAgendaJSON.int(row["id"]) else { return nil }
            return (id, NCAgendaJSON.string(row["title"]) ?? "")
        }
        let myLabels = Set(myAgents.compactMap { $0.boardLabel })
        let toRemove = current.filter { myLabels.contains($0.1) && $0.1 != choice.boardLabel }
        let cardPath = Self.cardPath(root, board: board, stack: stack, card: card)

        if choice.id != nil {
            guard let title = choice.boardLabel else { return .refused(NCAgendaEditText.f("_nodrive_agenda_edit_deck_no_label_", choice.name)) }
            if !current.contains(where: { $0.1 == title }) {
                // The label of the board: found, or made once where I may manage the board.
                let (boardResponse, boardFailure) = await send(.get, path: root + "boards/\(board)")
                if let boardFailure { return boardFailure }
                guard let boardResponse else { return .offline }
                guard boardResponse.status == 200, let boardObject = (try? JSONSerialization.jsonObject(with: boardResponse.data)) as? [String: Any] else {
                    return map(status: boardResponse.status)
                }
                let labels = NCAgendaJSON.dictionaries(boardObject["labels"])
                var labelId = labels.first { NCAgendaJSON.string($0["title"]) == title }.flatMap { NCAgendaJSON.int($0["id"]) }
                if labelId == nil {
                    let permissions = boardObject["permissions"] as? [String: Any]
                    let canManage = NCAgendaJSON.bool(permissions?["PERMISSION_MANAGE"]) ?? false
                    guard canManage else { return .refused(NCAgendaEditText.f("_nodrive_agenda_edit_deck_ask_manager_", choice.name)) }
                    let (made, madeFailure) = await send(.post, path: root + "boards/\(board)/labels", body: ["title": title, "color": Self.labelColor])
                    if let madeFailure { return madeFailure }
                    guard let made else { return .offline }
                    guard made.status == 200 || made.status == 201,
                          let object = (try? JSONSerialization.jsonObject(with: made.data)) as? [String: Any], let id = NCAgendaJSON.int(object["id"]) else {
                        return map(status: made.status)
                    }
                    labelId = id
                }
                guard let labelId else { return .refused(NCAgendaEditText.f("_nodrive_agenda_edit_refused_generic_", 0)) }
                let (assigned, assignFailure) = await send(.put, path: cardPath + "/assignLabel", body: ["labelId": labelId])
                if let assignFailure { return assignFailure }
                guard let assigned else { return .offline }
                guard assigned.status == 200 || assigned.status == 204 else { return map(status: assigned.status) }
            }
        }
        for (id, _) in toRemove {
            let (removed, removeFailure) = await send(.put, path: cardPath + "/removeLabel", body: ["labelId": id])
            if let removeFailure { return removeFailure }
            guard let removed else { return .offline }
            guard removed.status == 200 || removed.status == 204 else { return map(status: removed.status) }
        }
        return .plainSaved
    }
}
