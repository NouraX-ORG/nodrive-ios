// SPDX-FileCopyrightText: 2026 Nourax
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// What the queue needs to know to send a command: the registry, what NoGantt and Deck showed, and whether their
/// guards have passed since the last reconnection (a NoGantt or Deck command is held until then).
struct AgendaEditContext: Sendable {
    var me: AgendaMe?
    var registry: NCAgendaRegistry?
    var gantt: RawGantt?
    var deck: RawDeck?
    var calendars: [RawCalendar] = []
    var settings = AgendaSettings()
    var ganttGuardOK = false
    var deckGuardOK = false
    /// How the last read of NoGantt and Deck went. A home that is refused, read only or not installed takes no change (the
    /// waiting ones go to Not sent); one that is offline or unreachable holds them until it is back.
    var ganttState: AgendaHomeState = .unknown
    var boardState: AgendaHomeState = .unknown
    /// The account was signed out (a read answered 401 or 403): every command waits until the person signs in again.
    var signedOut = false

    var agentTags: Set<String> {
        Set((registry?.agents ?? []).compactMap { $0.calendarTag })
    }

    var myAgents: [RegistryAgent] {
        guard let me else { return [] }
        return registry?.agents(of: me.userId) ?? []
    }

    func ganttContext(projectId: Int) -> GanttAgentContext? {
        guard let me, let gantt else { return nil }
        let resources = Dictionary(gantt.resources.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return GanttAgentContext(myUid: me.userId, myName: me.displayName, myAgents: myAgents, resources: resources,
                                 project: gantt.projects.first { $0.id == projectId }, projectTasks: gantt.tasks[String(projectId)] ?? [])
    }
}

struct NCAgendaQueueReport: Equatable, Sendable {
    var saved: [NCAgendaEditCommand] = []
    var savedDetails: [UUID: NCAgendaSaved] = [:]
    var notSent = 0
    var offline = false

    var didSendAnything: Bool { !saved.isEmpty }
}

/// The offline queue (design 9): every edit is a command in `editqueue.json` of the account's cache folder. Commands go
/// out oldest first, one at a time. A 5xx or a network error is tried again; a conflict or a refusal stays in "Not
/// sent" until the person decides. Nothing is dropped without a tap.
actor NCAgendaEditQueue {
    typealias HTTPFactory = @Sendable (String) -> NCAgendaHTTP?

    private final class Registry: @unchecked Sendable {
        private let lock = NSLock()
        private var queues: [String: NCAgendaEditQueue] = [:]

        func queue(for account: String) -> NCAgendaEditQueue {
            lock.lock()
            defer { lock.unlock() }
            if let existing = queues[account] { return existing }
            let created = NCAgendaEditQueue(account: account)
            queues[account] = created
            return created
        }

        func take(_ account: String) -> NCAgendaEditQueue? {
            lock.lock()
            defer { lock.unlock() }
            return queues.removeValue(forKey: account)
        }
    }

    private static let registry = Registry()
    static let fileName = "editqueue"
    static let maxTries = 3

    static func shared(for account: String) -> NCAgendaEditQueue {
        registry.queue(for: account)
    }

    /// Account removal: the unsent commands go with the account (they can't be sent without it).
    static func forget(account: String) async {
        await registry.take(account)?.forget()
    }

    let account: String
    private let cache: NCAgendaCache
    private let makeHTTP: HTTPFactory
    private let clock: @Sendable () -> Date
    private let zone: TimeZone
    private let retryDelay: UInt64
    private var items: [NCAgendaEditCommand]
    private var running = false
    private var forgotten = false

    init(account: String,
         cacheRoot: URL = NCAgendaCache.defaultRoot(),
         zone: TimeZone = .current,
         retryDelay: UInt64 = 500_000_000,
         clock: @escaping @Sendable () -> Date = { Date() },
         makeHTTP: @escaping HTTPFactory = { NCAgendaHTTP.live(account: $0) }) {
        self.account = account
        let store = NCAgendaCache(account: account, root: cacheRoot)
        self.cache = store
        self.zone = zone
        self.retryDelay = retryDelay
        self.clock = clock
        self.makeHTTP = makeHTTP
        self.items = store.load([NCAgendaEditCommand].self, name: NCAgendaEditQueue.fileName) ?? []
    }

    // MARK: Commands

    func commands() -> [NCAgendaEditCommand] {
        items
    }

    private func persist() {
        guard !forgotten else { return }
        if items.isEmpty { cache.remove(name: Self.fileName) } else { cache.save(items, name: Self.fileName) }
    }

    func forget() {
        forgotten = true
        items = []
        cache.remove(name: Self.fileName)
    }

    /// Adds a command. A second change of an item that still waits is folded into the waiting command.
    @discardableResult
    func enqueue(_ command: NCAgendaEditCommand) -> [NCAgendaEditCommand] {
        if let index = items.firstIndex(where: { $0.canFold(command) }) {
            items[index] = items[index].folded(command)
        } else {
            items.append(command)
        }
        persist()
        return items
    }

    /// "Apply my change again": the item is read again and the same change goes on top of the new version.
    func applyAgain(id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].link.etag = nil
        items[index].link.updatedAt = nil
        items[index].link.lastModified = nil
        items[index].state = .waiting
        persist()
    }

    /// "Keep the other change": the command is dropped (the only way out besides sending).
    func drop(id: UUID) {
        items.removeAll { $0.id == id }
        persist()
    }

    // MARK: Sending

    /// Sends what waits, oldest first. Stops at the first network error (the commands stay waiting).
    func process(context: AgendaEditContext) async -> NCAgendaQueueReport {
        var report = NCAgendaQueueReport()
        guard !running, !forgotten else { return report }
        running = true
        defer { running = false }
        // A home that refuses this app, is read only or is not installed takes no change: what waits for it is Not sent,
        // with the reason and an Open in button, instead of waiting for good (design 5).
        for index in items.indices where items[index].isWaiting {
            if let reason = Self.blockedReason(items[index], context) {
                items[index].state = .notSent(reason)
                report.notSent += 1
            }
        }
        if report.notSent > 0 { persist() }
        guard let http = makeHTTP(account) else { return report }
        var tried = Set<UUID>()
        while let command = items.first(where: { $0.isWaiting && !tried.contains($0.id) && !isHeld($0, context) }) {
            tried.insert(command.id)
            var outcome = await send(command, http: http, context: context)
            var attempt = 1
            while outcome == .serverError, attempt < Self.maxTries {
                attempt += 1
                if retryDelay > 0 { try? await Task.sleep(nanoseconds: retryDelay) }
                outcome = await send(command, http: http, context: context)
            }
            guard !forgotten else { return report }
            guard let index = items.firstIndex(where: { $0.id == command.id }) else { continue }
            switch outcome {
            case let .saved(details):
                let savedCommand = items[index]
                report.saved.append(savedCommand)
                report.savedDetails[command.id] = details
                items.remove(at: index)
                await passVersionOn(from: savedCommand, details: details, http: http)
            case .offline:
                report.offline = true
                persist()
                return report
            default:
                if let reason = NCAgendaWriteTexts.notSent(for: outcome) {
                    items[index].state = .notSent(reason)
                    report.notSent += 1
                }
            }
            persist()
        }
        return report
    }

    /// Why a waiting command can never be sent to its home as things are: the home refuses this app, is read only here or is
    /// not installed. Nil when it can be sent, or when it only has to wait (offline, unreachable, not read yet).
    static func blockedReason(_ command: NCAgendaEditCommand, _ context: AgendaEditContext) -> NCAgendaNotSent? {
        let state: AgendaHomeState
        switch command.home {
        case .gantt: state = context.ganttState
        case .board: state = context.boardState
        case .calendar, .tasks: return nil
        }
        let name = command.home.productName
        switch state {
        case .refused: return NCAgendaNotSent(kind: .refused, text: NCAgendaEditText.f("_nodrive_agenda_edit_held_refused_", name, name))
        case .readOnly: return NCAgendaNotSent(kind: .refused, text: NCAgendaEditText.f("_nodrive_agenda_edit_held_read_only_", name, name))
        case .notInstalled: return NCAgendaNotSent(kind: .refused, text: NCAgendaEditText.f("_nodrive_agenda_edit_held_not_installed_", name, name))
        case .unknown, .fresh, .unreachable: return nil
        }
    }

    /// One Save can make two commands for one item (the dates and the agent). The first one changed the item's version, so
    /// the second must expect the new one, not the one the person saw: otherwise the person's own change would come back as
    /// "changed somewhere else". The version is taken from the answer of the save, or read when the answer did not say.
    /// When it can't be learned the second command no longer checks the version (its own save moved it).
    private func passVersionOn(from saved: NCAgendaEditCommand, details: NCAgendaSaved, http: NCAgendaHTTP) async {
        guard let key = saved.itemKey, saved.home == .gantt || saved.home == .board else { return }
        func waiting() -> [Int] {
            items.indices.filter { items[$0].isWaiting && items[$0].itemKey == key && items[$0].home == saved.home && items[$0].id != saved.id }
        }
        guard !waiting().isEmpty else { return }
        switch saved.home {
        case .gantt:
            guard let project = saved.link.projectId, let task = saved.link.taskId else { return }
            var version = details.newUpdatedAt
            if version == nil { version = await NCAgendaGanttWriter(http: http).currentUpdatedAt(projectId: project, taskId: task) }
            for index in waiting() where items[index].link.updatedAt == saved.link.updatedAt { items[index].link.updatedAt = version }
        case .board:
            guard let board = saved.link.boardId, let stack = saved.link.stackId, let card = saved.link.cardId else { return }
            var version = details.newLastModified
            if version == nil { version = await NCAgendaDeckWriter(http: http, now: clock).currentLastModified(board: board, stack: stack, card: card) }
            for index in waiting() where items[index].link.lastModified == saved.link.lastModified { items[index].link.lastModified = version }
        case .calendar, .tasks:
            return
        }
    }

    /// A NoGantt or Deck command waits until the guard of its home has passed (the app is on a version it was tested with).
    func isHeld(_ command: NCAgendaEditCommand, _ context: AgendaEditContext) -> Bool {
        if context.signedOut { return true }
        switch command.home {
        case .gantt: return !context.ganttGuardOK
        case .board: return !context.deckGuardOK
        case .calendar, .tasks: return false
        }
    }

    func send(_ command: NCAgendaEditCommand, http: NCAgendaHTTP, context: AgendaEditContext) async -> NCAgendaWriteOutcome {
        let missing = NCAgendaWriteOutcome.refused(NCAgendaEditText.t("_nodrive_agenda_edit_refused_local_"))
        switch command.kind {
        case .calendarPatch, .calendarCreate, .calendarDelete:
            let writer = NCAgendaCalDAVWriter(http: http, agentTags: context.agentTags, myAddresses: Set(context.me?.addresses ?? []),
                                              zone: zone, now: clock)
            switch command.kind {
            case .calendarPatch:
                guard let path = command.link.path, let change = command.calendar else { return missing }
                return await writer.patch(path: path, seenEtag: command.link.etag, change: change)
            case .calendarCreate:
                guard let path = command.createPath, let text = command.createText else { return missing }
                return await writer.create(path: path, ics: text)
            default:
                guard let path = command.link.path else { return missing }
                return await writer.delete(path: path, seenEtag: command.link.etag)
            }
        case .ganttUpdate, .ganttAgent:
            guard let project = command.link.projectId, let task = command.link.taskId else { return missing }
            let writer = NCAgendaGanttWriter(http: http)
            if command.kind == .ganttUpdate {
                guard let change = command.gantt else { return missing }
                return await writer.update(projectId: project, taskId: task, seenUpdatedAt: command.link.updatedAt, change: change)
            }
            guard let choice = command.agent, let ganttContext = context.ganttContext(projectId: project) else { return missing }
            return await writer.changeAgent(projectId: project, taskId: task, seenUpdatedAt: command.link.updatedAt, choice: choice, context: ganttContext)
        case .deckUpdate, .deckAgent:
            guard let board = command.link.boardId, let stack = command.link.stackId, let card = command.link.cardId else { return missing }
            let writer = NCAgendaDeckWriter(http: http, now: clock)
            if command.kind == .deckUpdate {
                guard let change = command.deck else { return missing }
                return await writer.update(board: board, stack: stack, card: card, seenLastModified: command.link.lastModified, change: change)
            }
            guard let choice = command.agent else { return missing }
            return await writer.changeAgent(board: board, stack: stack, card: card, seenLastModified: command.link.lastModified,
                                            choice: choice, myAgents: context.myAgents)
        }
    }

    /// Undo of a NoGantt move; only while NoGantt knows the change.
    func undo(opId: String) async -> Bool {
        guard let http = makeHTTP(account) else { return false }
        return await NCAgendaGanttWriter(http: http).undo(opId: opId)
    }
}
