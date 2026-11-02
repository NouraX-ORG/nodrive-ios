// SPDX-FileCopyrightText: 2026 Nourax
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// A short message at the bottom of the list ("Saved.", "Moved to ... Also moved: ...") with Undo for a NoGantt move.
struct AgendaToast: Identifiable, Equatable {
    var id = UUID()
    var text: String
    var undoOpId: String?
}

/// Can the row be changed here, and if not, why (design 9: read-only items show a lock with the reason).
enum NCAgendaEditAbility: Equatable {
    case editable
    case locked(String)
    /// Nothing to say (a milestone, a team row): no Edit button.
    case notOffered
}

/// One line of the agent picker.
struct AgentOption: Identifiable, Equatable {
    var choice: AgentChoice
    var enabled: Bool
    var note: String?
    /// "Open in NoGantt" next to the note.
    var offersOpen = false
    var id: String { choice.rowId }
}

/// The Conflicts chip: only rows with a clash, a block, a late mark, a day off, or an overbooked agent.
enum NCAgendaEditConflictsFilter {
    static func apply(_ plan: AgendaDayPlan) -> AgendaDayPlan {
        var result = plan
        result.timed = plan.timed.filter(NCAgendaConflicts.hasConflict)
        result.dueToday = plan.dueToday.filter(NCAgendaConflicts.hasConflict)
        result.inProgress = plan.inProgress.filter(NCAgendaConflicts.hasConflict)
        result.late = plan.late.filter(NCAgendaConflicts.hasConflict)
        result.teamItems = []
        result.noDate = []
        result.ownProblems = plan.ownProblems.filter { $0.kind == .overbooked }
        result.teamProblems = []
        return result
    }
}

@MainActor
extension NCAgendaViewModel {
    var queue: NCAgendaEditQueue { NCAgendaEditQueue.shared(for: account) }

    // MARK: State

    /// The waiting edits, the editor's context, and the rows as shown.
    func reloadEditState() async {
        commands = await queue.commands()
        editContext = await store.editContext(status: result.status)
        rebuildDisplay()
    }

    func rebuildDisplay() {
        display = NCAgendaEditPipeline.display(result.snapshot, commands: commands, context: editContext, now: today, calendar: calendar)
        pattern = NCAgendaEditPipeline.pattern(context: editContext)
    }

    var waitingCommands: [NCAgendaEditCommand] { commands.filter { $0.isWaiting } }
    var waitingCount: Int { waitingCommands.count }
    var notSentCommands: [NCAgendaEditCommand] { commands.filter { !$0.isWaiting } }

    /// "Waiting to send 2 changes" and "1 change not sent": the person always sees what has not gone out.
    var editBanners: [AgendaBanner] {
        var list: [AgendaBanner] = []
        if waitingCount > 0 {
            let text = waitingCount == 1 ? NCAgendaEditText.t("_nodrive_agenda_edit_waiting_one_") : NCAgendaEditText.f("_nodrive_agenda_edit_waiting_", waitingCount)
            list.append(AgendaBanner(id: "queueWaiting", text: text, openHome: nil, opensNotSent: true))
        }
        if !notSentCommands.isEmpty {
            let text = notSentCommands.count == 1 ? NCAgendaEditText.t("_nodrive_agenda_edit_not_sent_one_") : NCAgendaEditText.f("_nodrive_agenda_edit_not_sent_", notSentCommands.count)
            list.append(AgendaBanner(id: "queueNotSent", text: text, openHome: nil, opensNotSent: true))
        }
        return list
    }

    /// The workload bar of one day: my own planned hours against my free hours.
    func workload(for date: Date) -> AgendaWorkload? {
        let mine = display.items.filter { $0.relation == .mine }
        return NCAgendaWorkload.day(date, items: mine, pattern: pattern, calendar: calendar)
    }

    var ganttZone: TimeZone {
        editContext.gantt?.timezone.flatMap { TimeZone(identifier: $0) } ?? calendar.timeZone
    }

    // MARK: What can be changed

    func ability(of item: AgendaItem) -> NCAgendaEditAbility {
        if item.relation == .team || item.kind == .milestone { return .notOffered }
        if item.pending { return .locked(NCAgendaEditText.t("_nodrive_agenda_edit_lock_pending_")) }
        if item.lock == .repeating { return .locked(NCAgendaText.f("_nodrive_agenda_lock_repeating_", item.home.productName)) }
        if item.lock == .readOnlyCalendar { return .locked(NCAgendaText.t("_nodrive_agenda_lock_read_only_")) }
        if item.lock == .viewerProject { return .locked(NCAgendaText.t("_nodrive_agenda_lock_viewer_")) }
        if item.lock == .guardReadOnly { return .locked(NCAgendaText.t("_nodrive_agenda_lock_guard_")) }
        // NoGantt or NoBoard that refuses this app, is read only or is not installed takes no change, so the row is locked
        // (its saved copy is still shown); the sheet has "Open in ..." (design 5). Offline or unreachable only waits.
        if let text = homeLock(of: item.home) { return .locked(text) }
        if item.home == .calendar || item.home == .tasks {
            if item.invited { return .locked(NCAgendaText.t("_nodrive_agenda_invited_")) }
            let source = display.sources.first { $0.key == item.sourceKey }
            if source?.setting == .team, !item.iAmOrganiser { return .locked(NCAgendaEditText.t("_nodrive_agenda_edit_lock_team_")) }
            if source?.setting == .info { return .locked(NCAgendaText.t("_nodrive_agenda_lock_read_only_")) }
        }
        return .editable
    }

    private func homeLock(of home: AgendaHome) -> String? {
        let state: AgendaHomeState
        switch home {
        case .gantt: state = result.status.gantt
        case .board: state = result.status.board
        case .calendar, .tasks: return nil
        }
        switch state {
        case .refused: return NCAgendaEditText.f("_nodrive_agenda_edit_lock_refused_", home.productName)
        case .readOnly: return NCAgendaText.t("_nodrive_agenda_lock_guard_")
        case .notInstalled: return NCAgendaEditText.f("_nodrive_agenda_edit_lock_not_installed_", home.productName)
        case .unknown, .fresh, .unreachable: return nil
        }
    }

    /// The choices of "Who does it?": Self and my agents (paused ones greyed, retired ones not offered), and the current
    /// agent when it is none of those (shown, not selectable).
    func agentOptions(for item: AgendaItem?, project: GanttProject? = nil) -> [AgentOption] {
        var options = [AgentOption(choice: .selfChoice, enabled: true)]
        let ganttContext: GanttAgentContext? = {
            guard item?.home == .gantt, let projectId = item?.link.projectId else { return nil }
            return editContext.ganttContext(projectId: projectId)
        }()
        let currentTask = ganttContext?.projectTasks.first(where: { $0.id == item?.link.taskId })
        for agent in editContext.myAgents {
            let choice = AgentChoice(agent)
            switch agent.status {
            case .retired:
                continue
            case .paused:
                options.append(AgentOption(choice: choice, enabled: false, note: NCAgendaText.t("_nodrive_agenda_agent_status_paused_")))
            case .active:
                if let ganttContext, !NCAgendaGanttAgentChange.isOffered(agent, context: ganttContext, task: currentTask) {
                    options.append(AgentOption(choice: choice, enabled: false,
                                               note: NCAgendaGanttAgentChange.text(.agentNotVisible(name: agent.name)), offersOpen: true))
                } else {
                    options.append(AgentOption(choice: choice, enabled: true))
                }
            }
        }
        if let item, case let .mine(id, name, status) = item.agent, !options.contains(where: { $0.choice.id == id }) {
            options.append(AgentOption(choice: AgentChoice(id: id, name: name, status: status), enabled: false))
        }
        return options
    }

    /// My own calendars and lists a new item can go to (Personal and Work; never a shared team calendar).
    func creatableCalendars(todo: Bool) -> [RawCalendar] {
        guard let me = editContext.me else { return [] }
        let hidden = editContext.gantt.flatMap { $0.copyEnabled ? $0.copyCalendarUri : nil }
        return editContext.calendars.filter { calendar in
            guard !calendar.isSubscription, !calendar.isBirthday, !calendar.isAppGenerated, calendar.writable, calendar.uri != hidden else { return false }
            let owner = calendar.ownerPrincipal.map { NCAgendaCalendarReader.lastPathPart($0).lowercased() }
            guard owner == nil || owner == me.userId.lowercased() else { return false }
            guard todo ? calendar.hasTodos : calendar.hasEvents else { return false }
            let setting = display.sources.first { $0.key == NCAgendaSources.calendarKey(calendar.uri) }?.setting
            return setting == .personal || setting == .work
        }
    }

    // MARK: Saving

    func submit(_ list: [NCAgendaEditCommand]) async {
        guard !list.isEmpty else { return }
        for command in list { await queue.enqueue(command) }
        commands = await queue.commands()
        rebuildDisplay()
        await sendWaiting()
    }

    func save(draft: NCAgendaEditDraft, for item: AgendaItem) async {
        let list = draft.commands(for: item, calendar: calendar, ganttZone: ganttZone, now: Date())
        selectedItem = nil
        await submit(list)
    }

    func create(_ draft: NCAgendaCreateDraft) async {
        guard let command = draft.command(calendars: editContext.calendars, registry: editContext.registry, calendar: calendar, now: Date()) else { return }
        showCreate = false
        await submit([command])
    }

    /// Sends what waits. Back from the server: the new state is read, and the toast says what happened.
    func sendWaiting() async {
        guard !isSending, waitingCount > 0 else { return }
        isSending = true
        let report = await queue.process(context: editContext)
        isSending = false
        commands = await queue.commands()
        if report.didSendAnything {
            result = await store.refresh()
            editContext = await store.editContext(status: result.status)
            toastFor(report)
        }
        rebuildDisplay()
    }

    private func toastFor(_ report: NCAgendaQueueReport) {
        // The last move of dates in this send (a Save with dates and an agent sends two commands; the move is the one to tell).
        if let command = report.saved.last(where: { $0.kind == .ganttUpdate && ($0.gantt?.startDay != nil || $0.gantt?.endDay != nil) }),
           let details = report.savedDetails[command.id], details.savedStart != nil || details.savedEnd != nil {
            var text = movedText(details)
            if !details.alsoMoved.isEmpty { text += " " + NCAgendaEditText.f("_nodrive_agenda_edit_also_moved_", details.alsoMoved.joined(separator: ", ")) }
            if details.datesAdjusted { text += " " + NCAgendaEditText.t("_nodrive_agenda_edit_adjusted_") }
            showToast(text, undoOpId: details.opId)
        } else {
            showToast(NCAgendaEditText.t("_nodrive_agenda_edit_saved_"))
        }
    }

    /// "Moved to 2 Nov - 4 Nov." with the dates NoGantt saved.
    private func movedText(_ details: NCAgendaSaved) -> String {
        let zone = ganttZone
        func short(_ text: String?) -> String? {
            NCAgendaAssembler.ganttDate(text, zone: zone).map { date in
                var zoned = calendar
                zoned.timeZone = zone
                return date.formatted(Date.FormatStyle(calendar: zoned, timeZone: zone).day().month(.abbreviated))
            }
        }
        guard let start = short(details.savedStart), let end = short(details.savedEnd) else { return NCAgendaEditText.t("_nodrive_agenda_edit_saved_") }
        return NCAgendaEditText.f("_nodrive_agenda_edit_moved_", start, end)
    }

    // MARK: Toast

    func showToast(_ text: String, undoOpId: String? = nil) {
        let toast = AgendaToast(text: text, undoOpId: undoOpId)
        self.toast = toast
        let seconds: UInt64 = undoOpId == nil ? 4 : 10
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            if self?.toast?.id == toast.id { self?.toast = nil }
        }
    }

    /// Undo of a NoGantt move. "Undone." only after NoGantt answered.
    func undo(_ toast: AgendaToast) async {
        guard let opId = toast.undoOpId else { return }
        self.toast = nil
        let done = await queue.undo(opId: opId)
        if done {
            result = await store.refresh()
            await reloadEditState()
            showToast(NCAgendaEditText.t("_nodrive_agenda_edit_undone_"))
        } else {
            showToast(NCAgendaEditText.t("_nodrive_agenda_edit_undo_failed_"))
        }
    }

    // MARK: Not sent

    func applyAgain(_ command: NCAgendaEditCommand) async {
        await queue.applyAgain(id: command.id)
        commands = await queue.commands()
        rebuildDisplay()
        await sendWaiting()
    }

    func keepOtherChange(_ command: NCAgendaEditCommand) async {
        await queue.drop(id: command.id)
        commands = await queue.commands()
        rebuildDisplay()
        if notSentCommands.isEmpty { showNotSent = false }
    }

    func openHome(of command: NCAgendaEditCommand) {
        open(command.link, title: command.home.openTitle)
        showNotSent = false
    }

    /// The network is back (or the app is in front again): what waits goes out after a fresh read, so the NoGantt and
    /// Deck guards are checked first.
    func networkMayBeBack() async {
        guard waitingCount > 0, !isLoading else { return }
        await refresh()
        await sendWaiting()
    }
}
