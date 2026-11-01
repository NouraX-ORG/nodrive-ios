// SPDX-FileCopyrightText: 2026 Nourax
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// An agent's own availability (design 4.1), as far as the conflict maths needs it.
struct AgentAvailability: Codable, Equatable, Sendable {
    var timezone: String?
    /// 0 = Monday ... 6 = Sunday; every day of the weekly pattern. Empty: the registry gave none (all seven days).
    var days: [Int] = []
    var capacityHoursPerWeek: Double?
    /// "yyyy-MM-dd"
    var daysOff: [String] = []

    /// The days the agent works. No pattern in the registry means every day.
    var workDays: Set<Int> { days.isEmpty ? Set(0...6) : Set(days) }

    /// Hours the agent can do on one working day: the weekly capacity over the working days.
    var dailyCapacity: Double? {
        guard let capacityHoursPerWeek, !workDays.isEmpty else { return nil }
        return capacityHoursPerWeek / Double(workDays.count)
    }

    static let dayNames = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"]

    static func parse(_ value: Any?) -> AgentAvailability? {
        guard let object = value as? [String: Any] else { return nil }
        var result = AgentAvailability()
        result.timezone = NCAgendaJSON.string(object["timezone"])
        for case let block as [String: Any] in object["weekly"] as? [Any] ?? [] {
            for case let name as String in block["days"] as? [Any] ?? [] {
                if let index = dayNames.firstIndex(of: name.lowercased().prefix(3).description), !result.days.contains(index) { result.days.append(index) }
            }
        }
        result.capacityHoursPerWeek = NCAgendaJSON.double(object["capacity_hours_per_week"])
        result.daysOff = (object["days_off"] as? [Any])?.compactMap { NCAgendaJSON.string($0) } ?? []
        return result
    }
}

struct RegistryAgent: Codable, Equatable, Sendable {
    var id: String
    var name: String
    var person: String
    var status: AgentStatus
    var organisation: String
    var ganttResourceIds: [Int] = []
    var boardLabel: String?
    var calendarTag: String?
    var availability: AgentAvailability?
}

struct NCAgendaRegistry: Codable, Equatable, Sendable {
    var agents: [RegistryAgent] = []

    enum Outcome: Equatable {
        case valid(NCAgendaRegistry)
        /// Bad JSON, another schema or version, or an id used twice.
        case invalid
    }

    static let schema = "nourax-agent-registry"
    static let version = 1

    /// Design 4.1. Unknown fields are ignored; an agent without id, name, person or a known status is left out.
    static func parse(_ data: Data) -> Outcome {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              NCAgendaJSON.string(root["schema"]) == schema,
              NCAgendaJSON.int(root["version"]) == version,
              let rows = root["agents"] as? [Any] else { return .invalid }
        var agents: [RegistryAgent] = []
        var seen = Set<String>()
        for case let row as [String: Any] in rows {
            guard let id = NCAgendaJSON.string(row["id"]), !id.isEmpty,
                  let name = NCAgendaJSON.string(row["name"]), !name.isEmpty,
                  let person = NCAgendaJSON.string(row["person"]), !person.isEmpty,
                  let statusText = NCAgendaJSON.string(row["status"]),
                  let status = AgentStatus(rawValue: statusText) else { continue }
            if !seen.insert(id).inserted { return .invalid }
            let links = row["links"] as? [String: Any] ?? [:]
            let resourceIds = (links["nogantt_resource_ids"] as? [Any])?.compactMap { NCAgendaJSON.int($0) } ?? []
            let label = NCAgendaJSON.string(links["noboard_label"])
            let tag = NCAgendaJSON.string(links["calendar_tag"])
            agents.append(RegistryAgent(id: id, name: name, person: person.lowercased(), status: status,
                                        organisation: NCAgendaJSON.string(row["organisation"]) ?? "",
                                        ganttResourceIds: resourceIds,
                                        boardLabel: (label?.isEmpty ?? true) ? nil : label,
                                        calendarTag: (tag?.isEmpty ?? true) ? nil : tag,
                                        availability: AgentAvailability.parse(row["availability"])))
        }
        return .valid(NCAgendaRegistry(agents: agents))
    }

    func agent(id: String) -> RegistryAgent? {
        agents.first { $0.id == id }
    }

    func agents(of person: String) -> [RegistryAgent] {
        let lower = person.lowercased()
        return agents.filter { $0.person == lower }
    }

    /// The organisations of a person's own agents (design 4.1 privacy).
    func organisations(of person: String) -> Set<String> {
        Set(agents(of: person).map { $0.organisation })
    }
}

/// What a registry source can answer.
enum RegistryLoad: Equatable {
    case data(Data, etag: String?)
    case notModified
    case missing
}

/// Where the registry comes from. One protocol, so the switch from the placeholder file to the Nourax agents
/// app is one change in `NCAgendaRegistrySources.current`.
protocol NCAgendaRegistrySource {
    func load(http: NCAgendaHTTP, etag: String?) async throws -> RegistryLoad
}

/// The placeholder phase: the signed-in person's own file `/NoAgenda/agent-registry.json` in their NoDrive.
struct NCAgendaDriveFileRegistrySource: NCAgendaRegistrySource {
    static let relativePath = "NoAgenda/agent-registry.json"

    func load(http: NCAgendaHTTP, etag: String?) async throws -> RegistryLoad {
        var headers: [String: String] = ["Accept": "application/json"]
        if let etag { headers["If-None-Match"] = etag }
        let response = try await http.send(.get, path: "remote.php/dav/files/" + http.encodedUser + "/" + Self.relativePath,
                                           headers: headers, home: "registry")
        switch response.status {
        case 200: return .data(response.data, etag: response.etag)
        case 304: return .notModified
        case 404: return .missing
        default: throw NCAgendaHTTPError.status(response.status)
        }
    }
}

/// The Nourax agents app, once its address is known (a Workspace-session item). Not used yet.
struct NCAgendaAgentsAppRegistrySource: NCAgendaRegistrySource {
    let url: URL

    func load(http: NCAgendaHTTP, etag: String?) async throws -> RegistryLoad {
        .missing
    }
}

enum NCAgendaRegistrySources {
    /// The address of the Nourax agents app's registry. Nil until the Workspace session gives it.
    static let agentsAppRegistryURL: URL? = nil

    /// The one place that decides where the registry is read from.
    static var current: NCAgendaRegistrySource {
        if let url = agentsAppRegistryURL {
            return NCAgendaAgentsAppRegistrySource(url: url)
        }
        return NCAgendaDriveFileRegistrySource()
    }
}
