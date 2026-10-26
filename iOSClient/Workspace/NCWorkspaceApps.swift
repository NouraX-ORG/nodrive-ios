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
    /// The page, absolute and of the account's own origin.
    let href: String
    let icon: String?

    var symbolName: String {
        Self.symbolName(appId: appId, id: id)
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

    /// Keeps links only, leaves out Files (NoDrive already shows files) and the external-site entries (they are
    /// listed under external sites), drops entries without a name and entries whose page is not of the
    /// account's own origin, and keeps the server's order.
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
                  let id = entry["id"] as? String, !id.isEmpty, id != "files",
                  let name = (entry["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty,
                  let reference = entry["href"] as? String,
                  let href = NCWorkspaceOrigin.resolve(reference, base: base),
                  NCWorkspaceOrigin.isSameOrigin(href, base: base) else { continue }
            let appId = (entry["app"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? id
            if appId == "external" { continue }
            var icon: String?
            if let iconReference = entry["icon"] as? String,
               let resolved = NCWorkspaceOrigin.resolve(iconReference, base: base),
               NCWorkspaceOrigin.isSameOrigin(resolved, base: base) {
                icon = resolved
            }
            apps.append(NCWorkspaceApp(id: id, appId: appId, name: name, href: href, icon: icon))
        }
        return apps
    }
}

/// The list per account: shown at once from the cache, refreshed with If-None-Match at most every 10 minutes.
final class NCWorkspaceAppsStore {
    static let shared = NCWorkspaceAppsStore()

    enum RefreshResult: Equatable {
        case updated, notModified, cleared, kept, throttled
    }

    private struct Cache: Codable {
        var etag: String?
        var apps: [NCWorkspaceApp]
        var fetchedAt: Date
    }

    typealias Fetch = (URLRequest) async throws -> (Data, HTTPURLResponse)

    static let minimumInterval: TimeInterval = 600

    private let defaults: UserDefaults

    init(defaults: UserDefaults? = nil) {
        self.defaults = defaults ?? UserDefaults(suiteName: NCBrandOptions.shared.capabilitiesGroup) ?? .standard
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
        defaults.removeObject(forKey: key(account))
    }

    /// Asks the account's own server for the list (the app's normal sign-in header, no redirects).
    func refresh(account: String, force: Bool = false) async {
        guard let credentials = NCWorkspaceSession.credentials(account: account) else { return }
        guard let request = NCWorkspaceSession.apiRequest(path: "ocs/v2.php/core/navigation/apps",
                                                         query: "absolute=false&format=json",
                                                         credentials: credentials) else { return }
        _ = await refresh(account: account, base: credentials.base, request: request, force: force,
                          now: Date(), fetch: NCWorkspaceSession.fetch)
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
