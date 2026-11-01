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
                                 project: gantt.projects.first { $0.id == projectId })
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
                report.saved.append(items[index])
                report.savedDetails[command.id] = details
                items.remove(at: index)
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

    /// A NoGantt or Deck command waits until the guard of its home has passed (the app is on a version it was tested with).
    func isHeld(_ command: NCAgendaEditCommand, _ context: AgendaEditContext) -> Bool {
        switch command.home {
        case .gantt: return !context.ganttGuardOK
        case .board: return !context.deckGuardOK
        case .calendar, .tasks: return false
        }
    }

    func send(_ command: NCAgendaEditCommand, http: NCAgendaHTTP, context: AgendaEditContext) async -> NCAgendaWriteOutcome {
        let missing = NCAgendaWriteOutcome.refused(NCAgendaEditText.f("_nodrive_agenda_edit_refused_generic_", 0))
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
