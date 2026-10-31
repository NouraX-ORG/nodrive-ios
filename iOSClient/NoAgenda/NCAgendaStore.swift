// SPDX-FileCopyrightText: 2026 Nourax
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

enum AgendaHomeState: Equatable, Sendable {
    case unknown
    case fresh
    /// Read before, but not now: the saved rows are shown.
    case unreachable(savedAt: Date?)
    /// The server answered 401 or 403 to this app's sign-in (design 5 fallback).
    case refused(Int)
    case notInstalled
    /// Shown, but not written to: an untested version of the app (design 5 version guard).
    case readOnly
}

enum AgendaRegistryState: Equatable, Sendable {
    case unknown
    case loaded(Int)
    case missing
    case invalid
}

struct AgendaStatus: Equatable, Sendable {
    var updatedAt: Date?
    var offline = false
    var signedOut = false
    var calendarsFailed = false
    var gantt: AgendaHomeState = .unknown
    var board: AgendaHomeState = .unknown
    var registry: AgendaRegistryState = .unknown
}

struct AgendaRefreshResult: Equatable, Sendable {
    var snapshot = AgendaSnapshot()
    var status = AgendaStatus()
    var settings = AgendaSettings()
}

/// One store per account. It reads the four homes and the registry, keeps the offline cache, and gives the
/// assembled rows. One refresh at a time: a second caller joins the running one.
actor NCAgendaStore {
    typealias HTTPFactory = @Sendable (String) -> NCAgendaHTTP?

    private final class Registry: @unchecked Sendable {
        private let lock = NSLock()
        private var stores: [String: NCAgendaStore] = [:]

        func store(for account: String) -> NCAgendaStore {
            lock.lock()
            defer { lock.unlock() }
            if let existing = stores[account] { return existing }
            let created = NCAgendaStore(account: account)
            stores[account] = created
            return created
        }

        /// Takes the store of the account out of the registry and gives it back.
        func take(_ account: String) -> NCAgendaStore? {
            lock.lock()
            defer { lock.unlock() }
            return stores.removeValue(forKey: account)
        }
    }

    private static let registry = Registry()

    static func shared(for account: String) -> NCAgendaStore {
        registry.store(for: account)
    }

    /// Account removal: the cache and settings of that account go (design 2.3, hook A6).
    static func forget(account: String) async {
        // The store stops and deletes its own folder, so a refresh that is running cannot write it back.
        await registry.take(account)?.forget()
        NCAgendaCache.forget(account: account)
    }

    let account: String
    private let cache: NCAgendaCache
    private let makeHTTP: HTTPFactory
    private let clock: @Sendable () -> Date
    private var inFlight: Task<AgendaRefreshResult, Never>?
    private var calendar: Calendar
    /// Set by `forget()`: nothing is saved or read after the account's data was removed.
    private var forgotten = false

    init(account: String,
         cacheRoot: URL = NCAgendaCache.defaultRoot(),
         calendar: Calendar = .current,
         clock: @escaping @Sendable () -> Date = { NCAgendaUITestHooks.today ?? Date() },
         makeHTTP: @escaping HTTPFactory = { NCAgendaHTTP.live(account: $0) }) {
        self.account = account
        self.cache = NCAgendaCache(account: account, root: cacheRoot)
        self.calendar = calendar
        self.clock = clock
        self.makeHTTP = makeHTTP
    }

    // MARK: Settings

    func settings() -> AgendaSettings {
        cache.load(AgendaSettings.self, name: "settings") ?? AgendaSettings()
    }

    func updateSettings(_ change: (inout AgendaSettings) -> Void) -> AgendaSettings {
        var value = settings()
        change(&value)
        save(value, name: "settings")
        return value
    }

    /// Every write of the store goes through here, so none happens after `forget()`.
    private func save<T: Encodable>(_ value: T, name: String) {
        guard !forgotten else { return }
        cache.save(value, name: name)
    }

    private func removeSaved(name: String) {
        guard !forgotten else { return }
        cache.remove(name: name)
    }

    /// Account removal: stops a running refresh, waits until it ended, then deletes this account's folder. After
    /// that the store saves nothing and answers with empty rows.
    func forget() async {
        forgotten = true
        if let running = inFlight {
            running.cancel()
            _ = await running.value
        }
        cache.removeAll()
    }

    // MARK: Reading

    /// Whatever the cache holds, with no network.
    func cached() -> AgendaRefreshResult {
        let meta = cache.load(AgendaMeta.self, name: "meta") ?? AgendaMeta()
        let calendars = cache.load([RawCalendar].self, name: "calendars") ?? []
        let gantt = cache.load(RawGantt.self, name: "gantt")
        let deck = cache.load(RawDeck.self, name: "deck")
        let registry = cache.load(NCAgendaRegistry.self, name: "registry")
        var status = AgendaStatus()
        status.updatedAt = meta.calendarsSavedAt
        return assemble(meta: meta, calendars: calendars, gantt: gantt, deck: deck, registry: registry, status: status)
    }

    private func assemble(meta: AgendaMeta, calendars: [RawCalendar], gantt: RawGantt?, deck: RawDeck?,
                          registry: NCAgendaRegistry?, status: AgendaStatus) -> AgendaRefreshResult {
        let current = settings()
        var result = AgendaRefreshResult(snapshot: AgendaSnapshot(), status: status, settings: current)
        guard let me = meta.me else { return result }
        let inputs = AgendaInputs(me: me, calendars: calendars, gantt: gantt, deck: deck, registry: registry,
                                  settings: current, now: clock(), calendar: calendar)
        result.snapshot = NCAgendaAssembler.assemble(inputs)
        return result
    }

    /// One refresh at a time: a caller that comes while one runs waits for that one.
    /// A cancelled caller cancels the run it started (for the shared background task: iOS ended the time), and the
    /// run then stops at its next check and gives the saved rows. A caller that only joined a running refresh
    /// waits for that run, which belongs to the screen.
    func refresh() async -> AgendaRefreshResult {
        if forgotten { return AgendaRefreshResult() }
        if let running = inFlight { return await running.value }
        let task = Task { await self.performRefresh() }
        inFlight = task
        let result = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        inFlight = nil
        return result
    }

    /// A calendar whose sync token and tag are the same as at the last full read, for the same window.
    static func isUnchanged(known: RawCalendar?, item: RawCalendar, windowStart: Date) -> Bool {
        guard let known, known.failedAt == nil, known.readAt != nil, known.windowStart == windowStart else { return false }
        guard item.syncToken != nil || item.ctag != nil else { return false }
        return known.syncToken == item.syncToken && known.ctag == item.ctag
    }

    /// The sync window (design 2.5.2): from the first day of the previous month to 12 months ahead.
    func window(now: Date) -> (Date, Date) {
        let startOfMonth = calendar.dateInterval(of: .month, for: now)?.start ?? calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .month, value: -1, to: startOfMonth) ?? startOfMonth
        let end = calendar.date(byAdding: .month, value: 12, to: startOfMonth) ?? now
        return (start, end)
    }

    private func readMe(_ http: NCAgendaHTTP) async throws -> AgendaMe {
        let response = try await http.ocs("cloud/user", home: "user")
        guard response.status == 200 else { throw NCAgendaHTTPError.status(response.status) }
        guard let data = NCAgendaHTTP.ocsData(response.data) as? [String: Any],
              let id = NCAgendaJSON.string(data["id"]) else { throw NCAgendaHTTPError.invalid }
        var me = AgendaMe(userId: id,
                          displayName: NCAgendaJSON.string(data["display-name"] ?? data["displayname"]) ?? id)
        if let email = NCAgendaJSON.string(data["email"]), !email.isEmpty { me.addresses.append(email.lowercased()) }
        me.groups = (data["groups"] as? [Any])?.compactMap { NCAgendaJSON.string($0) } ?? []
        return me
    }

    private func performRefresh() async -> AgendaRefreshResult {
        let now = clock()
        var status = AgendaStatus()
        var meta = cache.load(AgendaMeta.self, name: "meta") ?? AgendaMeta()
        var calendars = cache.load([RawCalendar].self, name: "calendars") ?? []
        var gantt = cache.load(RawGantt.self, name: "gantt")
        var deck = cache.load(RawDeck.self, name: "deck")
        var registry = cache.load(NCAgendaRegistry.self, name: "registry")
        status.updatedAt = meta.calendarsSavedAt
        let current = settings()

        guard let http = makeHTTP(account) else {
            status.signedOut = true
            return assemble(meta: meta, calendars: calendars, gantt: gantt, deck: deck, registry: registry, status: status)
        }

        // The person.
        do {
            meta.me = try await readMe(http)
        } catch let error as NCAgendaHTTPError {
            switch error {
            case .network: status.offline = true
            case .status(let code) where code == 401 || code == 403: status.signedOut = true
            default: break
            }
        } catch {
            status.offline = true
        }
        if Task.isCancelled { return cached() }
        guard !status.offline, !status.signedOut, var me = meta.me else {
            return assemble(meta: meta, calendars: calendars, gantt: gantt, deck: deck, registry: registry, status: status)
        }

        // NoCalendar and NoTasks.
        let reader = NCAgendaCalendarReader(http: http, deviceZone: calendar.timeZone)
        do {
            let principal = try await reader.readPrincipal()
            me.addresses = Array(Set(me.addresses + principal.addresses))
            meta.me = me
            let listed = try await reader.readCalendars()
            let (windowStart, windowEnd) = window(now: now)
            let classifier = NCAgendaAssembler(AgendaInputs(me: me, gantt: gantt, registry: registry, settings: current, now: now, calendar: calendar))
            var merged: [RawCalendar] = []
            for var item in listed {
                // Cancelled (the background time is over): stop here; the saved calendars stay as they were.
                if Task.isCancelled { return cached() }
                let known = calendars.first { $0.uri == item.uri }
                item.objects = known?.objects ?? []
                item.readAt = known?.readAt
                item.windowStart = known?.windowStart
                if classifier.classify(item).setting == .hidden {
                    // Nothing is kept of a hidden calendar. Without readAt it is read again when it is shown again.
                    item.objects = []
                    item.readAt = nil
                    item.windowStart = nil
                    merged.append(item)
                    continue
                }
                let unchanged = Self.isUnchanged(known: known, item: item, windowStart: windowStart)
                if unchanged { merged.append(item); continue }
                do {
                    item.objects = try await reader.readObjects(of: item, windowStart: windowStart, windowEnd: windowEnd)
                    item.windowStart = windowStart
                    item.readAt = now
                    item.failedAt = nil
                } catch let error as NCAgendaHTTPError where error == .network {
                    throw error
                } catch {
                    item.failedAt = now
                    status.calendarsFailed = true
                    NCAgendaLog.log("calendar-read-failed", home: "caldav")
                }
                merged.append(item)
            }
            calendars = merged
            meta.calendarsSavedAt = now
            status.updatedAt = now
            save(calendars, name: "calendars")
        } catch let error as NCAgendaHTTPError {
            switch error {
            case .network: status.offline = true
            case .status(let code) where code == 401 || code == 403: status.signedOut = true
            default: status.calendarsFailed = true
            }
        } catch {
            status.calendarsFailed = true
        }
        if Task.isCancelled { return cached() }
        if status.offline || status.signedOut {
            return assemble(meta: meta, calendars: calendars, gantt: gantt, deck: deck, registry: registry, status: status)
        }

        // NoGantt.
        do {
            let raw = try await NCAgendaGanttReader(http: http).read(settings: current, userId: me.userId, groups: me.groups, previous: gantt)
            gantt = raw
            meta.ganttSavedAt = now
            meta.ganttContractOK = raw.contractOK
            status.gantt = raw.contractOK ? .fresh : .readOnly
            save(raw, name: "gantt")
        } catch NCAgendaGanttError.notInstalled {
            gantt = nil
            status.gantt = .notInstalled
            removeSaved(name: "gantt")
        } catch NCAgendaGanttError.refused(let code) {
            status.gantt = .refused(code)
            NCAgendaLog.log("gantt-refused", home: "gantt", status: code)
        } catch {
            status.gantt = .unreachable(savedAt: meta.ganttSavedAt)
        }

        if Task.isCancelled { return cached() }

        // NoBoard.
        do {
            let raw = try await NCAgendaDeckReader(http: http).read(settings: current, userId: me.userId)
            deck = raw
            meta.deckSavedAt = now
            meta.deckReadWrite = raw.isReadWrite
            status.board = raw.isReadWrite ? .fresh : .readOnly
            save(raw, name: "deck")
        } catch NCAgendaDeckError.notInstalled {
            deck = nil
            status.board = .notInstalled
            removeSaved(name: "deck")
        } catch NCAgendaDeckError.refused(let code) {
            status.board = .refused(code)
            NCAgendaLog.log("deck-refused", home: "board", status: code)
        } catch {
            status.board = .unreachable(savedAt: meta.deckSavedAt)
        }

        if Task.isCancelled { return cached() }

        // The registry, last. Without it Self still works (design 4.1).
        do {
            let loaded = try await NCAgendaRegistrySources.current.load(http: http, etag: registry == nil ? nil : meta.registryEtag)
            switch loaded {
            case .data(let data, let etag):
                switch NCAgendaRegistry.parse(data) {
                case .valid(let parsed):
                    registry = parsed
                    meta.registryEtag = etag
                    meta.registrySavedAt = now
                    save(parsed, name: "registry")
                    status.registry = .loaded(parsed.agents.count)
                case .invalid:
                    registry = nil
                    meta.registryEtag = nil
                    removeSaved(name: "registry")
                    status.registry = .invalid
                }
            case .notModified:
                status.registry = registry.map { .loaded($0.agents.count) } ?? .missing
            case .missing:
                registry = nil
                meta.registryEtag = nil
                removeSaved(name: "registry")
                status.registry = .missing
            }
        } catch {
            status.registry = registry.map { .loaded($0.agents.count) } ?? .unknown
        }

        save(meta, name: "meta")
        return assemble(meta: meta, calendars: calendars, gantt: gantt, deck: deck, registry: registry, status: status)
    }
}
