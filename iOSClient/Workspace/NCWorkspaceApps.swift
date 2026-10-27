// SPDX-FileCopyrightText: 2026 Nourax
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// One Workspace web app of the signed-in user (Mail, Calendar, Talk, ...), read from the server's navigation list.
struct NCWorkspaceApp: Codable, Equatable, Identifiable {
    /// The navigation entry's id ("mail", "calendar", ...).
    let id: String
    /// The server app behind the entry ("mail"); the entry id when the server names none.
    let appId: String
    /// The name the server shows for the user's language.
    let name: String
    /// The page, absolute: of the account's own origin, or an https page of another origin when `outside` is set.
    let href: String
    let icon: String?
    /// True for an entry whose page lies on another origin (NoMail on mail.nourax.org). It opens in the in-app
    /// browser panel with no NoDrive credential, cookie or session, never in the signed-in Workspace web view.
    let outside: Bool

    init(id: String, appId: String, name: String, href: String, icon: String?, outside: Bool = false) {
        self.id = id
        self.appId = appId
        self.name = name
        self.href = href
        self.icon = icon
        self.outside = outside
    }

    /// Lists cached by an earlier version have no `outside` key: they are all own-origin entries.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        appId = try container.decode(String.self, forKey: .appId)
        name = try container.decode(String.self, forKey: .name)
        href = try container.decode(String.self, forKey: .href)
        icon = try container.decodeIfPresent(String.self, forKey: .icon)
        outside = try container.decodeIfPresent(Bool.self, forKey: .outside) ?? false
    }

    var symbolName: String {
        outside ? Self.outsideSymbolName(id: id) : Self.symbolName(appId: appId, id: id)
    }

    /// The server entry NoMail (app nourax_branding) gets the envelope; any other outside entry a link symbol.
    static func outsideSymbolName(id: String) -> String {
        id == "nourax_nomail" ? "envelope" : "link"
    }

    /// iOS has no SVG renderer for the server's icons, so each app gets an SF Symbol (they follow light and dark).
    static func symbolName(appId: String, id: String) -> String {
        let symbols = [
            "dashboard": "square.grid.2x2", "mail": "envelope", "calendar": "calendar",
            "spreed": "bubble.left.and.bubble.right", "contacts": "person.2", "deck": "rectangle.split.3x1",
            "notes": "note.text", "tasks": "checklist", "photos": "photo.on.rectangle", "activity": "bolt",
            "forms": "list.bullet.clipboard", "tables": "tablecells"
        ]
        return symbols[appId] ?? symbols[id] ?? "app"
    }
}

/// Reads the server's answer of `GET /ocs/v2.php/core/navigation/apps?absolute=false`.
enum NCWorkspaceAppsParser {
    enum ParseError: Error {
        case malformed
    }

    /// Entries the menu leaves out: NoDrive already shows files, and has its own Activity and Photos screens
    /// (the same set as Android's HIDDEN_APPS). Checked against the entry id and the server app.
    static let hiddenApps: Set<String> = ["files", "activity", "photos"]

    /// Keeps links only, leaves out the hidden apps and the external-site entries (they are listed under
    /// external sites), drops entries without a name, and keeps the server's order. A page of the account's own
    /// origin is a normal entry. A page of another origin is kept as an "outside" entry only when it is https
    /// with a plain host (no user info, no empty host); every other scheme or address is dropped.
    static func parse(data: Data, base: String) throws -> [NCWorkspaceApp] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ocs = root["ocs"] as? [String: Any] else { throw ParseError.malformed }
        var entries: [[String: Any]] = []
        if let list = ocs["data"] as? [Any] {
            entries = list.compactMap { $0 as? [String: Any] }
        } else if let map = ocs["data"] as? [String: Any] {
            // PHP encodes an array with gaps as an object; the keys are the positions.
            entries = map.sorted { (Int($0.key) ?? 0) < (Int($1.key) ?? 0) }.compactMap { $0.value as? [String: Any] }
        } else {
            throw ParseError.malformed
        }
        var apps: [NCWorkspaceApp] = []
        for entry in entries {
            guard (entry["type"] as? String) == "link",
                  let id = entry["id"] as? String, !id.isEmpty,
                  let name = (entry["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty,
                  let reference = entry["href"] as? String,
                  let href = NCWorkspaceOrigin.resolve(reference, base: base) else { continue }
            let appId = (entry["app"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? id
            if appId == "external" || hiddenApps.contains(id) || hiddenApps.contains(appId) { continue }
            let outside: Bool
            if NCWorkspaceOrigin.isSameOrigin(href, base: base) {
                outside = false
            } else if NCWorkspaceOrigin.isOutsideLink(href) {
                outside = true
            } else {
                continue
            }
            var icon: String?
            if let iconReference = entry["icon"] as? String,
               let resolved = NCWorkspaceOrigin.resolve(iconReference, base: base),
               NCWorkspaceOrigin.isSameOrigin(resolved, base: base) {
                icon = resolved
            }
            apps.append(NCWorkspaceApp(id: id, appId: appId, name: name, href: href, icon: icon, outside: outside))
        }
        return apps
    }
}

/// The list per account: shown at once from the cache, refreshed with If-None-Match at most every 10 minutes.
///
/// One read runs at a time per account, and every caller that asks meanwhile joins it (none is turned away): the
/// read does not belong to the screen that started it, so a sidebar or a main screen that goes away while the
/// answer is on its way does not cancel it. A read that fails (no session yet, no network) is tried again a few
/// times, so the list shows by itself as soon as the server answers.
final class NCWorkspaceAppsStore: @unchecked Sendable {
    static let shared = NCWorkspaceAppsStore()

    enum RefreshResult: Equatable {
        case updated, notModified, cleared, kept, throttled
    }

    /// What one read tells the caller: done, or worth trying again.
    enum Outcome: Equatable {
        case done, retry
    }

    private struct Cache: Codable {
        var etag: String?
        var apps: [NCWorkspaceApp]
        var fetchedAt: Date
    }

    private struct Running {
        let id: UUID
        let task: Task<Outcome, Never>
    }

    typealias Fetch = (URLRequest) async throws -> (Data, HTTPURLResponse)

    static let minimumInterval: TimeInterval = 600

    /// Seconds to wait before the 1st, 2nd and 3rd new try of a failed read.
    static let defaultRetryDelays: [TimeInterval] = [5, 20, 60]

    /// Posted (on any thread) when an account's list changed or was forgotten; userInfo["account"] names it.
    /// An open sidebar listens, so a list that arrives late shows without reopening the menu.
    static let didChange = Notification.Name("NoDriveWorkspaceAppsDidChange")

    private let defaults: UserDefaults
    private let center: NotificationCenter
    private let retryDelays: [TimeInterval]
    private let lock = NSLock()
    private var running: [String: Running] = [:]
    private var retrying: [String: Running] = [:]

    init(defaults: UserDefaults? = nil, center: NotificationCenter = .default, retryDelays: [TimeInterval] = NCWorkspaceAppsStore.defaultRetryDelays) {
        self.defaults = defaults ?? UserDefaults(suiteName: NCBrandOptions.shared.capabilitiesGroup) ?? .standard
        self.center = center
        self.retryDelays = retryDelays
    }

    /// Runs `perform` for `account`, or joins the run that is already going. A failed run schedules a new try
    /// (`attempt` counts them) until the delays are used up.
    @discardableResult
    func coalesced(account: String, attempt: Int = 0, perform: @escaping @Sendable () async -> Outcome) async -> Outcome {
        let task = startOrJoin(account: account, attempt: attempt, perform: perform)
        return await task.value
    }

    private func startOrJoin(account: String, attempt: Int, perform: @escaping @Sendable () async -> Outcome) -> Task<Outcome, Never> {
        lock.lock()
        defer { lock.unlock() }
        if let current = running[account] {
            return current.task
        }
        let id = UUID()
        let task = Task { [self] () -> Outcome in
            let outcome = await perform()
            finish(account: account, id: id)
            if outcome == .retry, !Task.isCancelled {
                scheduleRetry(account: account, attempt: attempt, perform: perform)
            }
            return outcome
        }
        running[account] = Running(id: id, task: task)
        return task
    }

    private func finish(account: String, id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        if running[account]?.id == id {
            running[account] = nil
        }
    }

    private func scheduleRetry(account: String, attempt: Int, perform: @escaping @Sendable () async -> Outcome) {
        guard attempt < retryDelays.count else { return }
        let delay = retryDelays[attempt]
        lock.lock()
        defer { lock.unlock() }
        guard retrying[account] == nil else { return }
        let id = UUID()
        let task = Task { [self] () -> Outcome in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return .done }
            clearRetry(account: account, id: id)
            return await coalesced(account: account, attempt: attempt + 1, perform: perform)
        }
        retrying[account] = Running(id: id, task: task)
    }

    private func clearRetry(account: String, id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        if retrying[account]?.id == id {
            retrying[account] = nil
        }
    }

    /// The account goes: a read on its way and a planned new try stop, and neither can write the list back.
    private func cancelWork(account: String) {
        lock.lock()
        defer { lock.unlock() }
        running.removeValue(forKey: account)?.task.cancel()
        retrying.removeValue(forKey: account)?.task.cancel()
    }

    private func announceChange(account: String) {
        center.post(name: Self.didChange, object: nil, userInfo: ["account": account])
    }

    private func key(_ account: String) -> String {
        "nodrive.workspaceApps.\(account)"
    }

    private func load(_ account: String) -> Cache? {
        guard let data = defaults.data(forKey: key(account)) else { return nil }
        return try? JSONDecoder().decode(Cache.self, from: data)
    }

    private func save(_ cache: Cache, account: String) {
        if let data = try? JSONEncoder().encode(cache) {
            defaults.set(data, forKey: key(account))
        }
    }

    func cached(account: String) -> [NCWorkspaceApp] {
        load(account)?.apps ?? []
    }

    func forget(account: String) {
        cancelWork(account: account)
        defaults.removeObject(forKey: key(account))
        announceChange(account: account)
    }

    /// Asks the account's own server for the list (the app's normal sign-in header, no redirects). Joins a read
    /// that is already going for the account; tries again by itself when the read fails.
    func refresh(account: String, force: Bool = false) async {
        await coalesced(account: account) { [self] in
            await readFromServer(account: account, force: force)
        }
    }

    private func readFromServer(account: String, force: Bool) async -> Outcome {
        // No session yet (the account is still being set up): try again shortly
        guard let credentials = NCWorkspaceSession.credentials(account: account) else { return .retry }
        guard let request = NCWorkspaceSession.apiRequest(path: "ocs/v2.php/core/navigation/apps",
                                                         query: "absolute=false&format=json",
                                                         credentials: credentials) else { return .done }
        let result = await refresh(account: account, base: credentials.base, request: request, force: force,
                                   now: Date(), fetch: NCWorkspaceSession.fetch)
        return result == .kept ? .retry : .done
    }

    /// The testable core: `request` is built by the caller; `fetch` is the transport.
    func refresh(account: String, base: String, request: URLRequest, force: Bool, now: Date, fetch: Fetch) async -> RefreshResult {
        let cache = load(account)
        if !force, let cache, now.timeIntervalSince(cache.fetchedAt) < Self.minimumInterval {
            return .throttled
        }
        var request = request
        if let etag = cache?.etag, !etag.isEmpty {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        let answer: (Data, HTTPURLResponse)
        do {
            answer = try await fetch(request)
        } catch {
            return .kept
        }
        // The account was removed (or the read stopped) while the answer was on its way: write nothing
        if Task.isCancelled {
            return .kept
        }
        let (data, response) = answer
        switch response.statusCode {
        case 304:
            if var cache {
                cache.fetchedAt = now
                save(cache, account: account)
            }
            return .notModified
        case 200:
            guard let apps = try? NCWorkspaceAppsParser.parse(data: data, base: base) else { return .kept }
            let etag = response.value(forHTTPHeaderField: "ETag")
            save(Cache(etag: etag, apps: apps, fetchedAt: now), account: account)
            if apps != cache?.apps {
                announceChange(account: account)
            }
            return .updated
        case 404:
            // An older server without the list: show nothing.
            forget(account: account)
            return .cleared
        default:
            return .kept
        }
    }
}
