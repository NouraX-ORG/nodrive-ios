// SPDX-FileCopyrightText: 2026 Nourax
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Writes a Gantt task through NoGantt's own API (design 9). NoGantt has no conditional write, so the task is read
/// right before the write and its `updated_at` is compared with the one the person saw (a gap of milliseconds, risk
/// E2). Nothing here ever deletes a task.
struct NCAgendaGanttWriter {
    let http: NCAgendaHTTP
    var root: String { NCAgendaGanttReader.root }

    private func headersJSON() -> [String: String] {
        ["Accept": "application/json", "Content-Type": "application/json"]
    }

    private func send(_ method: NCAgendaMethod, path: String, query: String = "format=json", body: [String: Any]? = nil) async -> (NCAgendaResponse?, NCAgendaWriteOutcome?) {
        do {
            let data = try body.map { try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]) }
            let response = try await http.send(method, path: "ocs/v2.php/" + path, query: query, headers: headersJSON(), body: data, home: "gantt.write")
            return (response, nil)
        } catch let error as NCAgendaHTTPError {
            if error == .network { return (nil, .offline) }
            return (nil, .refused(NCAgendaEditText.t("_nodrive_agenda_edit_refused_local_")))
        } catch {
            return (nil, .offline)
        }
    }

    /// The tasks of the project as the server has them now.
    func freshTask(projectId: Int, taskId: Int) async -> (GanttTask?, [GanttTask], NCAgendaWriteOutcome?) {
        let (response, failure) = await send(.get, path: root + "projects/\(projectId)/tasks")
        if let failure { return (nil, [], failure) }
        guard let response else { return (nil, [], .offline) }
        guard response.status == 200 else { return (nil, [], map(status: response.status, data: response.data)) }
        let rows = NCAgendaJSON.dictionaries(NCAgendaHTTP.ocsData(response.data))
        let tasks = rows.compactMap(NCAgendaGanttReader.decodeTask)
        guard let task = tasks.first(where: { $0.id == taskId }) else { return (nil, tasks, .conflict) }
        return (task, tasks, nil)
    }

    /// The server's own words of a refusal: OCS `meta.message` or an `error` key; never more than 200 characters.
    static func message(_ data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var found: String?
        if let ocs = root["ocs"] as? [String: Any] {
            if let payload = ocs["data"] as? [String: Any] {
                found = NCAgendaJSON.string(payload["message"]) ?? NCAgendaJSON.string(payload["error"])
            }
            if found?.isEmpty ?? true, let meta = ocs["meta"] as? [String: Any] { found = NCAgendaJSON.string(meta["message"]) }
        }
        if found?.isEmpty ?? true { found = NCAgendaJSON.string(root["message"]) ?? NCAgendaJSON.string(root["error"]) }
        guard let text = found?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty, text != "OK" else { return nil }
        return String(text.prefix(200))
    }

    private func map(status: Int, data: Data) -> NCAgendaWriteOutcome {
        switch status {
        case 404: return .conflict
        case 401, 403: return .refused(NCAgendaEditText.t("_nodrive_agenda_edit_gantt_forbidden_"))
        case 400, 422:
            if let text = Self.message(data) { return .refused(NCAgendaEditText.f("_nodrive_agenda_edit_gantt_refused_", text)) }
            return .refused(NCAgendaWriteTexts.refused(status: status))
        case 500..<600: return .serverError
        default: return .refused(NCAgendaWriteTexts.refused(status: status))
        }
    }

    /// The time of day of an old value ("2026-11-02 17:00:00" gives "17:00:00").
    static func timeOfDay(_ text: String?, fallback: String) -> String {
        guard let text else { return fallback }
        let separators = CharacterSet(charactersIn: " T")
        let parts = text.components(separatedBy: separators).filter { !$0.isEmpty }
        guard parts.count >= 2 else { return fallback }
        let time = String(parts[1].prefix(8))
        return time.count == 8 ? time : fallback
    }

    /// The body of a change of dates, % done, status or done, built from the fresh task.
    static func body(for change: GanttChange, fresh: GanttTask) -> [String: Any] {
        var body: [String: Any] = [:]
        if let day = change.startDay { body["start_date"] = day + " " + timeOfDay(fresh.start, fallback: "09:00:00") }
        if let day = change.endDay { body["end_date"] = day + " " + timeOfDay(fresh.end, fallback: "17:00:00") }
        if change.startDay != nil || change.endDay != nil {
            // NoGantt moves the tasks that depend on this one; a linked card is never moved without the person's yes.
            body["adjust_lag"] = true
            body["deck_confirmed"] = false
        }
        if let percent = change.percent {
            body["manual_progress"] = max(0, min(100, percent))
            body["progress_mode"] = "manual"
        }
        if let status = change.status { body["status"] = status }
        if change.done == true {
            body["status"] = "done"
            body["manual_progress"] = 100
            body["progress_mode"] = "manual"
        }
        return body
    }

    private func saved(from response: NCAgendaResponse, tasks: [GanttTask]) -> NCAgendaSaved {
        var result = NCAgendaSaved()
        guard let data = NCAgendaHTTP.ocsData(response.data) as? [String: Any] else { return result }
        if let task = data["task"] as? [String: Any] {
            result.savedStart = NCAgendaJSON.string(task["start_date"])
            result.savedEnd = NCAgendaJSON.string(task["end_date"])
            result.newUpdatedAt = NCAgendaJSON.string(task["updated_at"])
        }
        result.opId = NCAgendaJSON.string(data["op_id"])
        for entry in data["propagated"] as? [Any] ?? [] {
            if let row = entry as? [String: Any] {
                if let title = NCAgendaJSON.string(row["title"]) ?? NCAgendaJSON.string(row["name"]) {
                    result.alsoMoved.append(title)
                } else if let id = NCAgendaJSON.int(row["id"]) ?? NCAgendaJSON.int(row["task_id"]), let task = tasks.first(where: { $0.id == id }) {
                    result.alsoMoved.append(task.title)
                }
            } else if let id = NCAgendaJSON.int(entry), let task = tasks.first(where: { $0.id == id }) {
                result.alsoMoved.append(task.title)
            }
        }
        return result
    }

    /// Dates, % done, status or done.
    func update(projectId: Int, taskId: Int, seenUpdatedAt: String?, change: GanttChange) async -> NCAgendaWriteOutcome {
        let (fresh, tasks, failure) = await freshTask(projectId: projectId, taskId: taskId)
        if let failure { return failure }
        guard let fresh else { return .offline }
        if let seenUpdatedAt, fresh.updatedAt != seenUpdatedAt { return .conflict }
        let body = Self.body(for: change, fresh: fresh)
        guard !body.isEmpty else { return .plainSaved }
        let (response, putFailure) = await send(.put, path: root + "tasks/\(taskId)", body: body)
        if let putFailure { return putFailure }
        guard let response else { return .offline }
        guard response.status == 200 || response.status == 201 else { return map(status: response.status, data: response.data) }
        var result = saved(from: response, tasks: tasks)
        if let wanted = body["start_date"] as? String, let got = result.savedStart, !got.hasPrefix(String(wanted.prefix(10))) { result.datesAdjusted = true }
        if let wanted = body["end_date"] as? String, let got = result.savedEnd, !got.hasPrefix(String(wanted.prefix(10))) { result.datesAdjusted = true }
        return .saved(result)
    }

    /// "My agent" (Self or one of my agents): the new `resources` list from the fresh task; the answer must hold exactly
    /// the list that was sent.
    func changeAgent(projectId: Int, taskId: Int, seenUpdatedAt: String?, choice: AgentChoice, context: GanttAgentContext) async -> NCAgendaWriteOutcome {
        let (fresh, tasks, failure) = await freshTask(projectId: projectId, taskId: taskId)
        if let failure { return failure }
        guard let fresh else { return .offline }
        if let seenUpdatedAt, fresh.updatedAt != seenUpdatedAt { return .conflict }
        // The tasks of the project as they are now tell which planning person belongs to this project.
        var planContext = context
        planContext.projectTasks = tasks
        switch NCAgendaGanttAgentChange.plan(task: fresh, choice: choice, context: planContext) {
        case let .refused(reason):
            return .refused(NCAgendaGanttAgentChange.text(reason))
        case let .rows(rows):
            let payload: [[String: Any]] = rows.map { row in
                var entry: [String: Any] = ["resource_id": row.resourceId]
                entry["work"] = row.work.map { $0 as Any } ?? NSNull()
                return entry
            }
            let (response, putFailure) = await send(.put, path: root + "tasks/\(taskId)", body: ["resources": payload])
            if let putFailure { return putFailure }
            guard let response else { return .offline }
            guard response.status == 200 || response.status == 201 else { return map(status: response.status, data: response.data) }
            // The answer is checked against what was sent (the server drops rows it can't show silently).
            if let data = NCAgendaHTTP.ocsData(response.data) as? [String: Any], let task = data["task"] as? [String: Any],
               let decoded = NCAgendaGanttReader.decodeTask(task) {
                if !NCAgendaGanttAgentChange.sameRows(decoded.resources, rows) {
                    NCAgendaLog.log("gantt-agent-mismatch", home: "gantt", id: taskId)
                    return .refused(NCAgendaEditText.t("_nodrive_agenda_edit_gantt_check_"))
                }
            }
            return .saved(saved(from: response, tasks: []))
        }
    }

    /// The `updated_at` the task has now (a fresh read), for the next change of the same Save when the answer did not say.
    func currentUpdatedAt(projectId: Int, taskId: Int) async -> String? {
        let (task, _, failure) = await freshTask(projectId: projectId, taskId: taskId)
        return failure == nil ? task?.updatedAt : nil
    }

    /// Undo of a move: `POST changes/{op_id}/revert`.
    func undo(opId: String) async -> Bool {
        let encoded = NCAgendaWebLinks.encode(opId)
        let (response, failure) = await send(.post, path: root + "changes/\(encoded)/revert", body: [:])
        guard failure == nil, let response else { return false }
        return response.status == 200 || response.status == 201 || response.status == 204
    }
}
