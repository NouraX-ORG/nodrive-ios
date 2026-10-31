// SPDX-FileCopyrightText: 2026 Nourax
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

struct DeckPerson: Codable, Equatable, Sendable {
    var uid: String
    var name: String
}

struct DeckLabel: Codable, Equatable, Sendable {
    var id: Int
    var title: String
}

struct DeckBoard: Codable, Equatable, Sendable {
    var id: Int
    var title: String
    var color: String?
    var owner: DeckPerson?
    var canManage = false
    var labels: [DeckLabel] = []
    var archived = false
}

struct DeckCard: Codable, Equatable, Sendable {
    var id: Int
    var boardId: Int
    var stackId: Int
    var title: String
    var due: Date?
    var done = false
    var archived = false
    var assigned: [DeckPerson] = []
    var labels: [String] = []
    var lastModified: Int?
}

struct RawDeck: Codable, Equatable, Sendable {
    /// `deck.version` of the server's capabilities.
    var version: String?
    var boards: [DeckBoard] = []
    var cards: [String: [DeckCard]] = [:]

    /// Design 5: only the major and minor version that was checked (1.19) may write. Everything else is read only.
    var isReadWrite: Bool {
        guard let version else { return false }
        let parts = version.split(separator: ".")
        return parts.count >= 2 && parts[0] == "1" && parts[1] == "19"
    }
}

enum NCAgendaDeckError: Error, Equatable {
    case refused(Int)
    case notInstalled
}

/// NoBoard (Deck) reads: the capabilities, the boards the person can see, and the cards of each board.
struct NCAgendaDeckReader {
    let http: NCAgendaHTTP

    static let root = "index.php/apps/deck/api/v1.0/"

    func readVersion() async throws -> String? {
        let response = try await http.ocs("cloud/capabilities", home: "deck.capabilities")
        guard response.status == 200 else { throw NCAgendaHTTPError.status(response.status) }
        guard let data = NCAgendaHTTP.ocsData(response.data) as? [String: Any],
              let capabilities = data["capabilities"] as? [String: Any] else { return nil }
        guard let deck = capabilities["deck"] as? [String: Any] else { throw NCAgendaDeckError.notInstalled }
        return NCAgendaJSON.string(deck["version"])
    }

    func read(settings: AgendaSettings, userId: String) async throws -> RawDeck {
        var raw = RawDeck()
        raw.version = try? await readVersion()
        let response = try await http.send(.get, path: Self.root + "boards", query: "details=true",
                                           headers: ["Accept": "application/json"], home: "deck.boards")
        switch response.status {
        case 200: break
        case 401, 403: throw NCAgendaDeckError.refused(response.status)
        case 404: throw NCAgendaDeckError.notInstalled
        default: throw NCAgendaHTTPError.status(response.status)
        }
        let boardRows = (try? JSONSerialization.jsonObject(with: response.data)) as? [Any] ?? []
        raw.boards = boardRows.compactMap { ($0 as? [String: Any]).flatMap(Self.decodeBoard) }
        for board in raw.boards where !board.archived {
            try Task.checkCancellation()
            let setting = NCAgendaSources.boardSetting(board, userId: userId, settings: settings)
            guard setting != .hidden else { continue }
            let stacks = try await http.send(.get, path: Self.root + "boards/\(board.id)/stacks",
                                             headers: ["Accept": "application/json"], home: "deck.stacks")
            guard stacks.status == 200 else {
                if stacks.status == 401 || stacks.status == 403 { throw NCAgendaDeckError.refused(stacks.status) }
                continue
            }
            let stackRows = (try? JSONSerialization.jsonObject(with: stacks.data)) as? [Any] ?? []
            var cards: [DeckCard] = []
            for stack in stackRows.compactMap({ $0 as? [String: Any] }) {
                let stackId = NCAgendaJSON.int(stack["id"]) ?? 0
                for row in NCAgendaJSON.dictionaries(stack["cards"]) {
                    if let card = Self.decodeCard(row, boardId: board.id, stackId: stackId) { cards.append(card) }
                }
            }
            raw.cards[String(board.id)] = cards
        }
        NCAgendaLog.log("deck-read", home: "board", count: raw.boards.count)
        return raw
    }

    static func decodeBoard(_ row: [String: Any]) -> DeckBoard? {
        guard let id = NCAgendaJSON.int(row["id"]) else { return nil }
        var board = DeckBoard(id: id, title: NCAgendaJSON.string(row["title"]) ?? "")
        let color = NCAgendaJSON.string(row["color"])
        board.color = (color?.isEmpty ?? true) ? nil : color
        if let owner = row["owner"] as? [String: Any], let uid = NCAgendaJSON.string(owner["uid"]) {
            board.owner = DeckPerson(uid: uid, name: NCAgendaJSON.string(owner["displayname"]) ?? uid)
        }
        if let permissions = row["permissions"] as? [String: Any] {
            board.canManage = NCAgendaJSON.bool(permissions["PERMISSION_MANAGE"]) ?? false
        }
        board.labels = NCAgendaJSON.dictionaries(row["labels"]).compactMap { item in
            guard let labelId = NCAgendaJSON.int(item["id"]) else { return nil }
            return DeckLabel(id: labelId, title: NCAgendaJSON.string(item["title"]) ?? "")
        }
        board.archived = NCAgendaJSON.bool(row["archived"]) ?? false
        if let deleted = NCAgendaJSON.int(row["deletedAt"]), deleted > 0 { board.archived = true }
        return board
    }

    static func decodeCard(_ row: [String: Any], boardId: Int, stackId: Int) -> DeckCard? {
        guard let id = NCAgendaJSON.int(row["id"]) else { return nil }
        var card = DeckCard(id: id, boardId: boardId, stackId: stackId, title: NCAgendaJSON.string(row["title"]) ?? "")
        if let due = NCAgendaJSON.string(row["duedate"]), !due.isEmpty { card.due = parseDate(due) }
        // Deck 1.19 sends `done` as a date or null; older shapes may send a boolean.
        if let flag = row["done"] as? Bool {
            card.done = flag
        } else if let text = NCAgendaJSON.string(row["done"]) {
            card.done = !text.isEmpty
        }
        card.archived = NCAgendaJSON.bool(row["archived"]) ?? false
        card.assigned = NCAgendaJSON.dictionaries(row["assignedUsers"]).compactMap { item in
            guard let participant = item["participant"] as? [String: Any], let uid = NCAgendaJSON.string(participant["uid"]) else { return nil }
            return DeckPerson(uid: uid, name: NCAgendaJSON.string(participant["displayname"]) ?? uid)
        }
        card.labels = NCAgendaJSON.dictionaries(row["labels"]).compactMap { NCAgendaJSON.string($0["title"]) }
        card.lastModified = NCAgendaJSON.int(row["lastModified"])
        return card
    }

    static func parseDate(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text)
    }
}
