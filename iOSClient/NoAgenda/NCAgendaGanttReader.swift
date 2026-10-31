// SPDX-FileCopyrightText: 2026 Nourax
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

// MARK: - What was read

struct GanttProject: Codable, Equatable, Sendable {
    var id: Int
    var title: String
    var color: String?
    var ownerId: String
    var ownerName: String?
    var permission: String
    var rolesOnly = false
}

struct GanttMyTask: Codable, Equatable, Sendable {
    var id: Int
    var title: String
    var projectId: Int
    var projectTitle: String
    var subprojectId: Int?
    var start: String?
    var end: String?
    var progress: Int?
    var status: String
}

struct GanttDependency: Codable, Equatable, Sendable {
    var predecessorId: String
    var type: String
    var lagDays: Int
}

struct GanttResourceRow: Codable, Equatable, Sendable {
    var resourceId: Int
    var work: Double?
}

struct GanttTask: Codable, Equatable, Sendable {
    var id: Int
    var projectId: Int
    var title: String
    var subprojectId: Int?
    var start: String?
    var end: String?
    var work: Double?
    var updatedAt: String?
    var progressMode: String?
    var progress: Int?
    var status: String
    var dependencies: [GanttDependency] = []
    var resources: [GanttResourceRow] = []
    var deckCardId: Int?
}

struct GanttMilestone: Codable, Equatable, Sendable {
    var id: Int
    var projectId: Int
    var title: String
    var date: String?
    var taskId: Int?
}

struct GanttSubproject: Codable, Equatable, Sendable {
    var id: Int
    var title: String
}

struct GanttResource: Codable, Equatable, Sendable {
    var id: Int
    var name: String
    var type: String
    var uid: String?
    var uidDisplayName: String?
}

struct GanttFinding: Codable, Equatable, Sendable {
    var level: String?
    var start: String?
    var end: String?
    var personIds: [Int]
    var deficitHours: Double?
    var taskIds: [Int]
}

struct GanttShare: Codable, Equatable, Sendable {
    /// "user", "group" or something else (a team).
    var type: String
    var with: String
    var permission: String
}

struct RawGantt: Codable, Equatable, Sendable {
    var linked = false
    var myTasks: [GanttMyTask] = []
    var projects: [GanttProject] = []
    var tasks: [String: [GanttTask]] = [:]
    var milestones: [String: [GanttMilestone]] = [:]
    var subprojects: [String: [GanttSubproject]] = [:]
    var resources: [GanttResource] = []
    var timezone: String?
    var findings: [String: [GanttFinding]] = [:]
    var copyEnabled = false
    var copyCalendarUri: String?
    var shares: [String: [GanttShare]] = [:]
    /// False when an answer did not have the shape of NoGantt 2.4.1 (the version guard): read only.
    var contractOK = true
}

/// What NoGantt 2.4.1 answers, as the keys and types the app relies on. Extra keys are allowed. Any other
/// shape turns NoGantt read only (design 5, "version guard").
enum NCAgendaGanttContract {
    enum Kind {
        case int, string, number, bool, array, object
        case stringOrNull, numberOrNull, intOrNull
    }

    static let myTasksWrapper: [String: Kind] = ["has_linked_resource": .bool, "tasks": .array]
    static let myTask: [String: Kind] = ["id": .int, "title": .string, "project_id": .int, "start_date": .stringOrNull,
                                         "end_date": .stringOrNull, "status": .string]
    static let project: [String: Kind] = ["id": .int, "title": .string, "owner_id": .string, "permission": .string]
    static let task: [String: Kind] = ["id": .int, "project_id": .int, "title": .string, "start_date": .stringOrNull,
                                       "end_date": .stringOrNull, "work": .numberOrNull, "updated_at": .stringOrNull,
                                       "status": .string, "dependencies": .array, "resources": .array]
    static let taskResource: [String: Kind] = ["resource_id": .int, "work": .numberOrNull]
    static let milestone: [String: Kind] = ["id": .int, "title": .string, "milestone_date": .stringOrNull]
    static let resource: [String: Kind] = ["id": .int, "name": .string, "type": .string, "uid": .stringOrNull]
    static let settings: [String: Kind] = ["timezone": .string]
    static let capacity: [String: Kind] = ["findings": .array]
    static let taskSync: [String: Kind] = ["enabled": .bool]
    static let share: [String: Kind] = ["principal_id": .string, "principal_type": .string, "permission": .string]

    /// A JSON true or false (an NSNumber that is a CFBoolean). A number such as 1 is not a boolean here.
    static func isBool(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    static func isNumber(_ value: Any?) -> Bool {
        value is NSNumber && !isBool(value)
    }

    static func isInteger(_ value: Any?) -> Bool {
        guard isNumber(value), let number = value as? NSNumber else { return false }
        return number.doubleValue == number.doubleValue.rounded()
    }

    static func matches(_ value: Any?, _ kind: Kind) -> Bool {
        switch kind {
        case .int: return isInteger(value)
        case .string: return value is String
        case .number: return isNumber(value)
        case .bool: return isBool(value) || isNumber(value)
        case .array: return value is [Any]
        case .object: return value is [String: Any]
        case .stringOrNull: return value is String || value is NSNull || value == nil
        case .numberOrNull: return isNumber(value) || value is NSNull || value == nil
        case .intOrNull: return isInteger(value) || value is NSNull || value == nil
        }
    }

    /// True when `object` has every key of `shape` with the right type. A nullable key may hold null, but it must be
    /// there: a NoGantt that drops `updated_at` (the edit-conflict marker) is not the one that was checked.
    static func conforms(_ object: [String: Any], to shape: [String: Kind]) -> Bool {
        for (key, kind) in shape {
            guard object.keys.contains(key) else { return false }
            if !matches(object[key], kind) { return false }
        }
        return true
    }

    static func allConform(_ rows: [[String: Any]], to shape: [String: Kind]) -> Bool {
        rows.allSatisfy { conforms($0, to: shape) }
    }
}

// MARK: - Reader

enum NCAgendaGanttError: Error, Equatable {
    case notInstalled
    case refused(Int)
    case unreachable
}

/// NoGantt reads (OCS routes of nc_gantt, `ocs/v2.php/apps/nc_gantt/api/v1/...`). Read only.
struct NCAgendaGanttReader {
    let http: NCAgendaHTTP

    static let root = "apps/nc_gantt/api/v1/"

    private func get(_ path: String, query: String? = nil) async throws -> Any? {
        let response = try await http.ocs(Self.root + path, home: "gantt", extraQuery: query)
        switch response.status {
        case 200: return NCAgendaHTTP.ocsData(response.data)
        case 404 where path == "my-tasks": throw NCAgendaGanttError.notInstalled
        case 401, 403: throw NCAgendaGanttError.refused(response.status)
        default: throw NCAgendaHTTPError.status(response.status)
        }
    }

    /// Reads what the person needs. `isDoProject` / `isOverseeProject` decide which projects' tasks are read:
    /// the answer of `my-tasks` and `projects` comes first, then the tasks of the projects that count.
    func read(settings: AgendaSettings, userId: String, groups: [String], previous: RawGantt?) async throws -> RawGantt {
        var raw = RawGantt()
        let mine = try await get("my-tasks")
        guard let wrapper = mine as? [String: Any] else { throw NCAgendaGanttError.notInstalled }
        if !NCAgendaGanttContract.conforms(wrapper, to: NCAgendaGanttContract.myTasksWrapper) { raw.contractOK = false }
        raw.linked = NCAgendaJSON.bool(wrapper["has_linked_resource"]) ?? false
        let myRows = NCAgendaJSON.dictionaries(wrapper["tasks"])
        if !NCAgendaGanttContract.allConform(myRows, to: NCAgendaGanttContract.myTask) { raw.contractOK = false }
        raw.myTasks = myRows.compactMap(Self.decodeMyTask)

        let projectRows = NCAgendaJSON.dictionaries(try await get("projects"))
        if !NCAgendaGanttContract.allConform(projectRows, to: NCAgendaGanttContract.project) { raw.contractOK = false }
        raw.projects = projectRows.compactMap(Self.decodeProject)

        let resourceRows = NCAgendaJSON.dictionaries(try await get("resources"))
        if !NCAgendaGanttContract.allConform(resourceRows, to: NCAgendaGanttContract.resource) { raw.contractOK = false }
        raw.resources = resourceRows.compactMap(Self.decodeResource)

        if let settingsObject = try await get("settings") as? [String: Any] {
            if !NCAgendaGanttContract.conforms(settingsObject, to: NCAgendaGanttContract.settings) { raw.contractOK = false }
            raw.timezone = NCAgendaJSON.string(settingsObject["timezone"])
        } else {
            raw.contractOK = false
        }

        if let sync = try? await get("task-sync") as? [String: Any] {
            if !NCAgendaGanttContract.conforms(sync, to: NCAgendaGanttContract.taskSync) { raw.contractOK = false }
            raw.copyEnabled = NCAgendaJSON.bool(sync["enabled"]) ?? false
            let uri = NCAgendaJSON.string(sync["calendar_uri"])
            raw.copyCalendarUri = (uri?.isEmpty ?? true) ? nil : uri
        }

        let mineByProject = Set(raw.myTasks.map { $0.projectId })
        var capacityRead = false
        for project in raw.projects {
            try Task.checkCancellation()
            // Shares only to decide the "server admin only" relation, and only for a project that needs it.
            if project.permission == "admin" {
                if let shares = try? await get("projects/\(project.id)/shares") {
                    if !(shares is [Any]) || !NCAgendaGanttContract.allConform(NCAgendaJSON.dictionaries(shares), to: NCAgendaGanttContract.share) {
                        raw.contractOK = false
                    }
                    raw.shares[String(project.id)] = Self.decodeShares(shares)
                }
            }
            let finalSetting = NCAgendaSources.projectSetting(project, hasMyTasks: mineByProject.contains(project.id),
                                                              settings: settings, userId: userId, groups: groups,
                                                              shares: raw.shares[String(project.id)] ?? previous?.shares[String(project.id)])
            guard finalSetting != .hidden else { continue }
            let key = String(project.id)
            let taskRows = NCAgendaJSON.dictionaries(try await get("projects/\(project.id)/tasks"))
            if !NCAgendaGanttContract.allConform(taskRows, to: NCAgendaGanttContract.task) { raw.contractOK = false }
            for row in taskRows where !NCAgendaGanttContract.allConform(NCAgendaJSON.dictionaries(row["resources"]), to: NCAgendaGanttContract.taskResource) {
                raw.contractOK = false
            }
            raw.tasks[key] = taskRows.compactMap(Self.decodeTask)
            let milestoneRows = NCAgendaJSON.dictionaries(try await get("projects/\(project.id)/milestones"))
            if !NCAgendaGanttContract.allConform(milestoneRows, to: NCAgendaGanttContract.milestone) { raw.contractOK = false }
            raw.milestones[key] = milestoneRows.compactMap { Self.decodeMilestone($0, projectId: project.id) }
            raw.subprojects[key] = NCAgendaJSON.dictionaries(try await get("projects/\(project.id)/subprojects")).compactMap(Self.decodeSubproject)
            if finalSetting == .doOversee, !capacityRead {
                // NoGantt's capacity check is one answer for the whole account: read it once per refresh.
                capacityRead = true
                if let capacity = try? await get("capacity-check") as? [String: Any] {
                    if !NCAgendaGanttContract.conforms(capacity, to: NCAgendaGanttContract.capacity) { raw.contractOK = false }
                    raw.findings["all"] = NCAgendaJSON.dictionaries(capacity["findings"]).compactMap(Self.decodeFinding)
                }
            }
        }
        NCAgendaLog.log("gantt-read", home: "gantt", count: raw.myTasks.count)
        return raw
    }

    // MARK: Decoding (tolerant; a row without its id is skipped)

    static func decodeMyTask(_ row: [String: Any]) -> GanttMyTask? {
        guard let id = NCAgendaJSON.int(row["id"]), let projectId = NCAgendaJSON.int(row["project_id"]) else { return nil }
        return GanttMyTask(id: id, title: NCAgendaJSON.string(row["title"]) ?? "", projectId: projectId,
                           projectTitle: NCAgendaJSON.string(row["project_title"]) ?? "",
                           subprojectId: NCAgendaJSON.int(row["subproject_id"]),
                           start: NCAgendaJSON.string(row["start_date"]), end: NCAgendaJSON.string(row["end_date"]),
                           progress: NCAgendaJSON.int(row["manual_progress"]),
                           status: NCAgendaJSON.string(row["status"]) ?? "")
    }

    static func decodeProject(_ row: [String: Any]) -> GanttProject? {
        guard let id = NCAgendaJSON.int(row["id"]) else { return nil }
        return GanttProject(id: id, title: NCAgendaJSON.string(row["title"]) ?? "", color: NCAgendaJSON.string(row["color"]),
                            ownerId: NCAgendaJSON.string(row["owner_id"]) ?? "",
                            ownerName: NCAgendaJSON.string(row["owner_display_name"]),
                            permission: NCAgendaJSON.string(row["permission"]) ?? "viewer",
                            rolesOnly: NCAgendaJSON.bool(row["roles_only_assignment"]) ?? false)
    }

    static func decodeTask(_ row: [String: Any]) -> GanttTask? {
        guard let id = NCAgendaJSON.int(row["id"]) else { return nil }
        let dependencies = NCAgendaJSON.dictionaries(row["dependencies"]).compactMap { item -> GanttDependency? in
            guard let predecessor = NCAgendaJSON.string(item["predecessor_id"]) else { return nil }
            return GanttDependency(predecessorId: predecessor, type: NCAgendaJSON.string(item["dependency_type"]) ?? "",
                                   lagDays: NCAgendaJSON.int(item["lag_days"]) ?? 0)
        }
        let resources = NCAgendaJSON.dictionaries(row["resources"]).compactMap { item -> GanttResourceRow? in
            guard let resourceId = NCAgendaJSON.int(item["resource_id"]) else { return nil }
            return GanttResourceRow(resourceId: resourceId, work: NCAgendaJSON.double(item["work"]))
        }
        return GanttTask(id: id, projectId: NCAgendaJSON.int(row["project_id"]) ?? 0, title: NCAgendaJSON.string(row["title"]) ?? "",
                         subprojectId: NCAgendaJSON.int(row["subproject_id"]),
                         start: NCAgendaJSON.string(row["start_date"]), end: NCAgendaJSON.string(row["end_date"]),
                         work: NCAgendaJSON.double(row["work"]), updatedAt: NCAgendaJSON.string(row["updated_at"]),
                         progressMode: NCAgendaJSON.string(row["progress_mode"]),
                         progress: NCAgendaJSON.int(row["manual_progress"]),
                         status: NCAgendaJSON.string(row["status"]) ?? "", dependencies: dependencies,
                         resources: resources, deckCardId: NCAgendaJSON.int(row["deck_card_id"]))
    }

    static func decodeMilestone(_ row: [String: Any], projectId: Int) -> GanttMilestone? {
        guard let id = NCAgendaJSON.int(row["id"]) else { return nil }
        return GanttMilestone(id: id, projectId: projectId, title: NCAgendaJSON.string(row["title"]) ?? "",
                              date: NCAgendaJSON.string(row["milestone_date"]), taskId: NCAgendaJSON.int(row["task_id"]))
    }

    static func decodeSubproject(_ row: [String: Any]) -> GanttSubproject? {
        guard let id = NCAgendaJSON.int(row["id"]) else { return nil }
        return GanttSubproject(id: id, title: NCAgendaJSON.string(row["title"]) ?? "")
    }

    static func decodeResource(_ row: [String: Any]) -> GanttResource? {
        guard let id = NCAgendaJSON.int(row["id"]) else { return nil }
        let uid = NCAgendaJSON.string(row["uid"])
        return GanttResource(id: id, name: NCAgendaJSON.string(row["name"]) ?? "", type: NCAgendaJSON.string(row["type"]) ?? "",
                             uid: (uid?.isEmpty ?? true) ? nil : uid, uidDisplayName: NCAgendaJSON.string(row["uid_display_name"]))
    }

    static func decodeFinding(_ row: [String: Any]) -> GanttFinding? {
        GanttFinding(level: NCAgendaJSON.string(row["level"]), start: NCAgendaJSON.string(row["start"]),
                     end: NCAgendaJSON.string(row["end"]),
                     personIds: (row["person_ids"] as? [Any])?.compactMap { NCAgendaJSON.int($0) } ?? [],
                     deficitHours: NCAgendaJSON.double(row["deficit_hours"]),
                     taskIds: (row["task_ids"] as? [Any])?.compactMap { NCAgendaJSON.int($0) } ?? [])
    }

    /// Project shares, as NoGantt 2.4.1 answers them: `principal_type` ("user", "group" or another kind of
    /// principal), `principal_id` and `permission`. An unknown shape gives no shares, and an unknown share is never
    /// taken as "admin for me".
    static func decodeShares(_ value: Any?) -> [GanttShare] {
        NCAgendaJSON.dictionaries(value).compactMap { row in
            let type = NCAgendaJSON.string(row["principal_type"]) ?? ""
            let with = NCAgendaJSON.string(row["principal_id"]) ?? ""
            let permission = NCAgendaJSON.string(row["permission"]) ?? ""
            guard !with.isEmpty else { return nil }
            return GanttShare(type: type, with: with, permission: permission)
        }
    }
}
