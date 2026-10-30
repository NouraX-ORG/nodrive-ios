// SPDX-FileCopyrightText: 2026 Nourax
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
import UIKit
@testable import Nextcloud

/// Helpers for the tests of the transport, the store, the cache and the log.
enum AgendaRuntimeSupport {
    static let now = ISO8601DateFormatter().date(from: "2026-10-30T12:00:00Z")!
    static let account = "ali https://drive.test"
    static let password = "pw-planted-9f3"

    static var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }

    static func tempRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("agenda-tests-" + UUID().uuidString, isDirectory: true)
    }

    static func store(_ server: AgendaFakeServer, root: URL, delay: Bool = false) -> NCAgendaStore {
        NCAgendaStore(account: account, cacheRoot: root, calendar: calendar, clock: { now }) { _ in
            var http = server.http(password: password)
            if delay {
                let inner = http.fetch
                http.fetch = { request in
                    try await Task.sleep(nanoseconds: 30_000_000)
                    return try await inner(request)
                }
            }
            return http
        }
    }

    static func offlineStore(root: URL) -> NCAgendaStore {
        NCAgendaStore(account: account, cacheRoot: root, calendar: calendar, clock: { now }) { _ in
            NCAgendaHTTP(account: account, base: "https://drive.test", userId: "ali", authorization: "Basic x", userAgent: "t") { _ in
                throw URLError(.notConnectedToInternet)
            }
        }
    }

    /// The canned server, with the answers of some paths replaced.
    static func server(replacing replacement: @escaping (String, String) -> (Int, String)?) -> AgendaFakeServer {
        let base = AgendaFixtures.server()
        return AgendaFakeServer { method, path, request in
            replacement(method, path) ?? base.handler(method, path, request)
        }
    }
}

// MARK: - Transport

@Suite("NoDrive NoAgenda transport")
struct NoDriveAgendaTransportTests {
    @Test("Another origin is refused before any header is set")
    func otherOrigin() {
        let http = AgendaFakeServer { _, _, _ in nil }.http()
        for path in ["https://evil.example/x", "//evil.example/x", "http://drive.test/x", "https://drive.test.evil.example/x"] {
            #expect(throws: NCAgendaHTTPError.wrongOrigin, "\(path)") {
                _ = try http.makeRequest(.get, path: path)
            }
        }
    }

    @Test("A redirect is an error and is not followed")
    func redirect() async {
        let server = AgendaFakeServer { _, _, _ in (302, "") }
        await #expect(throws: NCAgendaHTTPError.redirected(302)) {
            _ = try await server.http().send(.get, path: "remote.php/dav/", home: "test")
        }
        #expect(server.requests.count == 1)
    }

    @Test("Every request has the CSRF pass, the account's credential in a header only, no cookies, and the user agent")
    func headers() throws {
        let http = AgendaFakeServer { _, _, _ in nil }.http()
        let request = try http.makeRequest(.report, path: "/remote.php/dav/calendars/ali/work/", headers: ["Depth": "1"], body: Data("<x/>".utf8))
        #expect(request.value(forHTTPHeaderField: "OCS-APIRequest") == "true")
        #expect(request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Basic ") == true)
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "NoDrive-test")
        #expect(request.value(forHTTPHeaderField: "Depth") == "1")
        #expect(request.httpShouldHandleCookies == false)
        #expect(request.httpMethod == "REPORT")
        let url = request.url?.absoluteString ?? ""
        #expect(!url.contains(AgendaRuntimeSupport.password))
        #expect(!url.contains("ali:"))
        #expect(url == "https://drive.test/remote.php/dav/calendars/ali/work/")
    }

    @Test("The OCS path and the query")
    func ocs() throws {
        let http = AgendaFakeServer { _, _, _ in nil }.http()
        let request = try http.makeRequest(.get, path: "ocs/v2.php/apps/nc_gantt/api/v1/my-tasks", query: "format=json")
        #expect(request.url?.absoluteString == "https://drive.test/ocs/v2.php/apps/nc_gantt/api/v1/my-tasks?format=json")
    }

    @Test("A user id is one path part")
    func userPath() {
        let http = NCAgendaHTTP(account: "a", base: "https://drive.test", userId: "a/b c", authorization: "Basic x", userAgent: "t") { _ in throw URLError(.badURL) }
        #expect(!http.encodedUser.contains("/"))
        #expect(http.encodedUser.contains("%20"))
    }

    @Test("Only reads: a whole refresh uses GET, PROPFIND and REPORT and nothing else; nothing is changed on the server")
    func onlyReads() async {
        let server = AgendaFixtures.server()
        let root = AgendaRuntimeSupport.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = await AgendaRuntimeSupport.store(server, root: root).refresh()
        let methods = Set(server.requests.compactMap(\.httpMethod))
        #expect(methods.isSubset(of: ["GET", "PROPFIND", "REPORT"]))
        #expect(methods.contains("GET") && methods.contains("PROPFIND") && methods.contains("REPORT"))
        #expect(server.requests.allSatisfy { $0.value(forHTTPHeaderField: "OCS-APIRequest") == "true" })
        #expect(server.requests.allSatisfy { $0.url?.host == "drive.test" })
        // The board calendar is never asked
        #expect(!server.requests.contains { $0.url?.path.contains("app-generated") == true })
    }
}

// MARK: - Store

@Suite("NoDrive NoAgenda store")
struct NoDriveAgendaStoreTests {
    typealias R = AgendaRuntimeSupport

    @Test("A refresh reads all four homes and the registry")
    func fullRefresh() async throws {
        let root = R.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let result = await R.store(AgendaFixtures.server(), root: root).refresh()
        let titles = Set(result.snapshot.items.map(\.title))
        #expect(titles.isSuperset(of: ["Dentist", "Draft report", "Write homepage copy", "Review sitemap", "Launch"]))
        #expect(result.status.gantt == .fresh)
        #expect(result.status.board == .fresh)
        #expect(result.status.registry == .loaded(3))
        #expect(result.status.updatedAt == R.now)
        #expect(!result.status.offline && !result.status.signedOut)
        let draft = try #require(result.snapshot.items.first { $0.title == "Draft report" })
        #expect(draft.agent == .mine(id: "AG-0001", name: "Writer-Bot", status: .active))
        #expect(draft.home == .tasks)
        let sources = result.snapshot.sources
        #expect(sources.first { $0.key == "cal:personal" }?.setting == .personal)
        #expect(sources.first { $0.key == "cal:team_shared_by_mara" }?.setting == .team)
        #expect(sources.first { $0.key == "cal:app-generated--deck--board-1" }?.setting == .hidden)
        #expect(sources.first { $0.key == "cal:holidays" }?.setting == .info)
        #expect(sources.first { $0.key == "project:1" }?.setting == .doIt)
        #expect(sources.first { $0.key == "board:1" }?.setting == .doIt)
        #expect(result.snapshot.agents.map(\.name).sorted() == ["Old-Bot", "Writer-Bot"])
    }

    @Test("A calendar that did not change is not read again")
    func unchangedCalendars() async {
        let root = R.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let server = AgendaFixtures.server()
        let store = R.store(server, root: root)
        _ = await store.refresh()
        let first = server.requests.filter { $0.httpMethod == "REPORT" }.count
        #expect(first > 0)
        let second = await store.refresh()
        #expect(server.requests.filter { $0.httpMethod == "REPORT" }.count == first)
        #expect(second.snapshot.items.contains { $0.title == "Dentist" })
    }

    @Test("Offline: the saved rows stay, marked offline, with the time they were saved")
    func offline() async {
        let root = R.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = await R.store(AgendaFixtures.server(), root: root).refresh()
        let result = await R.offlineStore(root: root).refresh()
        #expect(result.status.offline)
        #expect(result.status.updatedAt == R.now)
        #expect(result.snapshot.items.contains { $0.title == "Dentist" })
        #expect(result.snapshot.items.contains { $0.title == "Write homepage copy" })
    }

    @Test("Signed out: no account session gives the sign-in state and the saved rows")
    func signedOut() async {
        let root = R.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = await R.store(AgendaFixtures.server(), root: root).refresh()
        let store = NCAgendaStore(account: R.account, cacheRoot: root, calendar: R.calendar, clock: { R.now }) { _ in nil }
        let result = await store.refresh()
        #expect(result.status.signedOut)
        #expect(result.snapshot.items.contains { $0.title == "Dentist" })
        let unauthorised = R.server { _, path in path == "/ocs/v2.php/cloud/user" ? (401, "") : nil }
        #expect(await R.store(unauthorised, root: root).refresh().status.signedOut)
    }

    @Test("NoGantt and NoBoard refused: the other homes still show, the status says refused")
    func refused() async {
        let root = R.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let server = R.server { _, path in
            if path.contains("nc_gantt") || path.contains("apps/deck") { return (403, "") }
            return nil
        }
        let result = await R.store(server, root: root).refresh()
        #expect(result.status.gantt == .refused(403))
        #expect(result.status.board == .refused(403))
        #expect(result.snapshot.items.contains { $0.title == "Dentist" })
        #expect(!result.snapshot.items.contains { $0.title == "Write homepage copy" })
    }

    @Test("Refused after a good read: the saved NoGantt rows stay")
    func refusedKeepsSaved() async {
        let root = R.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = await R.store(AgendaFixtures.server(), root: root).refresh()
        let server = R.server { _, path in path.contains("nc_gantt") ? (403, "") : nil }
        let result = await R.store(server, root: root).refresh()
        #expect(result.status.gantt == .refused(403))
        #expect(result.snapshot.items.contains { $0.title == "Write homepage copy" })
    }

    @Test("Unreachable NoGantt: the saved rows stay and the time of saving is kept")
    func unreachable() async {
        let root = R.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = await R.store(AgendaFixtures.server(), root: root).refresh()
        let server = R.server { _, path in path.contains("nc_gantt") ? (503, "") : nil }
        let result = await R.store(server, root: root).refresh()
        #expect(result.status.gantt == .unreachable(savedAt: R.now))
        #expect(result.snapshot.items.contains { $0.title == "Write homepage copy" })
    }

    @Test("The version guard: another Deck version and a changed NoGantt shape are read only; rows still show")
    func guards() async {
        let root = R.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let server = R.server { _, path in
            if path == "/ocs/v2.php/cloud/capabilities" { return (200, AgendaFixtures.capabilities.replacingOccurrences(of: "1.19.1", with: "1.20.0")) }
            if path.hasSuffix("/my-tasks") { return (200, AgendaFixtures.myTasks.replacingOccurrences(of: "\"title\":\"Write homepage copy\"", with: "\"title\":7")) }
            return nil
        }
        let result = await R.store(server, root: root).refresh()
        #expect(result.status.board == .readOnly)
        #expect(result.status.gantt == .readOnly)
        #expect(result.snapshot.items.contains { $0.title == "Review sitemap" })
    }

    @Test("Not installed")
    func notInstalled() async {
        let root = R.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let result = await R.store(AgendaFixtures.server(gantt: false, deck: false), root: root).refresh()
        #expect(result.status.gantt == .notInstalled)
        #expect(result.status.board == .notInstalled)
        #expect(result.snapshot.items.contains { $0.title == "Dentist" })
    }

    @Test("A missing or invalid registry: NoAgenda still works, Self is the agent, an agent id is flagged unknown")
    func registryStates() async throws {
        let root = R.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let missing = await R.store(AgendaFixtures.server(registryText: nil), root: root).refresh()
        #expect(missing.status.registry == .missing)
        #expect(missing.snapshot.items.contains { $0.title == "Dentist" })
        let draft = try #require(missing.snapshot.items.first { $0.title == "Draft report" })
        #expect(draft.agent == .unknown(label: "AG-0001"))
        let invalid = await R.store(AgendaFixtures.server(registryText: "{ not json"), root: root).refresh()
        #expect(invalid.status.registry == .invalid)
        #expect(invalid.snapshot.items.contains { $0.title == "Dentist" })
    }

    @Test("One refresh at a time: two callers share one run")
    func oneAtATime() async {
        let root = R.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let server = AgendaFixtures.server()
        let store = R.store(server, root: root, delay: true)
        async let first = store.refresh()
        async let second = store.refresh()
        let results = await (first, second)
        #expect(results.0 == results.1)
        #expect(server.requests.filter { $0.url?.path == "/ocs/v2.php/cloud/user" }.count == 1)
    }

    @Test("Background refresh only after NoAgenda was opened")
    func background() async {
        let root = R.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let server = AgendaFixtures.server()
        let store = R.store(server, root: root)
        #expect(await NCAgendaBackground.refresh(store: store) == false)
        #expect(server.requests.isEmpty)
        _ = await store.updateSettings { $0.openedOnce = true }
        #expect(await NCAgendaBackground.refresh(store: store) == true)
        #expect(!server.requests.isEmpty)
    }

    @Test("Settings and the one-time question survive; the cache of another account is not touched by forget")
    func settingsAndForget() async {
        let root = R.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = R.store(AgendaFixtures.server(), root: root)
        _ = await store.updateSettings { $0.personalQuestionAnswered = true; $0.chosen["cal:personal"] = .work }
        let other = NCAgendaCache(account: "other https://drive.test", root: root)
        other.save(AgendaSettings(), name: "settings")
        NCAgendaCache.forget(account: R.account, root: root)
        #expect(await store.settings().personalQuestionAnswered == false)
        #expect(other.load(AgendaSettings.self, name: "settings") != nil)
    }

    @MainActor
    @Test("The screen's banners: refused with Open in NoBoard, read only, offline and not linked")
    func banners() async {
        let root = R.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let server = R.server { _, path in
            if path.contains("apps/deck") { return (403, "") }
            if path.hasSuffix("/my-tasks") { return (200, AgendaFixtures.ocs("{\"has_linked_resource\":false,\"tasks\":[]}")) }
            return nil
        }
        let model = NCAgendaViewModel(account: R.account, store: R.store(server, root: root), now: { R.now })
        await model.refresh()
        let banners = model.banners
        #expect(banners.contains { $0.id == "boardRefused" && $0.openHome == .board })
        #expect(banners.contains { $0.id == "notLinked" })
        #expect(model.showPersonalQuestion)
        #expect(model.updatedText != nil)
        let offlineModel = NCAgendaViewModel(account: R.account, store: R.offlineStore(root: root), now: { R.now })
        await offlineModel.refresh()
        #expect(offlineModel.banners.contains { $0.id == "offline" })
        #expect(!offlineModel.showPersonalQuestion)
    }

    @MainActor
    @Test("Answering the question makes the chosen calendars Personal and the others Work, once")
    func question() async {
        let root = R.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = NCAgendaViewModel(account: R.account, store: R.store(AgendaFixtures.server(), root: root), now: { R.now })
        await model.refresh()
        #expect(model.showPersonalQuestion)
        #expect(model.ownCalendars.map(\.key).contains("cal:personal"))
        await model.answerPersonalQuestion(personalKeys: ["cal:personal"])
        #expect(!model.showPersonalQuestion)
        #expect(model.result.settings.personalQuestionAnswered)
        #expect(model.result.snapshot.sources.first { $0.key == "cal:personal" }?.setting == .personal)
        #expect(model.result.snapshot.sources.first { $0.key == "cal:work" }?.setting == .work)
        await model.refresh()
        #expect(!model.showPersonalQuestion)
    }
}

// MARK: - Cache

@Suite("NoDrive NoAgenda cache")
struct NoDriveAgendaCacheTests {
    typealias R = AgendaRuntimeSupport

    @Test("A round trip; the folder is excluded from backup and the files are protected")
    func roundTrip() throws {
        let root = R.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = NCAgendaCache(account: R.account, root: root)
        var calendar = RawCalendar(href: "/a/b/", uri: "b", name: "B", components: ["VEVENT"])
        calendar.objects = [CalObject(href: "/a/b/x.ics", etag: "\"e\"", components: [ICalComponent()])]
        #expect(cache.save([calendar], name: "calendars"))
        #expect(cache.load([RawCalendar].self, name: "calendars") == [calendar])
        #expect(cache.load([RawCalendar].self, name: "missing") == nil)
        let values = try cache.folder.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
        let file = cache.folder.appendingPathComponent("calendars.json").path
        let attributes = try FileManager.default.attributesOfItem(atPath: file)
        if let protection = attributes[.protectionKey] as? FileProtectionType {
            #expect(protection == .completeUntilFirstUserAuthentication)
        }
    }

    @Test("The folder name is a hash, not the account or the server")
    func folderName() {
        let name = NCAgendaCache.folderName(for: R.account)
        #expect(name.count == 64)
        #expect(!name.contains("ali") && !name.contains("drive"))
    }

    @Test("No password, Authorization value or token is in any cached file after a full refresh")
    func noSecrets() async throws {
        let root = R.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = await R.store(AgendaFixtures.server(), root: root).refresh()
        let basic = Data("ali:\(R.password)".utf8).base64EncodedString()
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL }.filter { $0.pathExtension == "json" } ?? []
        #expect(files.count >= 5)
        for file in files {
            let text = String(decoding: try Data(contentsOf: file), as: UTF8.self)
            #expect(!text.contains(R.password), "\(file.lastPathComponent)")
            #expect(!text.contains(basic), "\(file.lastPathComponent)")
            #expect(!text.lowercased().contains("authorization"), "\(file.lastPathComponent)")
            #expect(!text.contains("Basic "), "\(file.lastPathComponent)")
        }
    }

    @Test("Forget removes the folder of that account only")
    func forget() {
        let root = R.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let one = NCAgendaCache(account: "one https://drive.test", root: root)
        let two = NCAgendaCache(account: "two https://drive.test", root: root)
        one.save(AgendaSettings(), name: "settings")
        two.save(AgendaSettings(), name: "settings")
        NCAgendaCache.forget(account: "one https://drive.test", root: root)
        #expect(!FileManager.default.fileExists(atPath: one.folder.path))
        #expect(two.load(AgendaSettings.self, name: "settings") != nil)
    }
}

// MARK: - Log

@Suite("NoDrive NoAgenda log", .serialized)
struct NoDriveAgendaLogTests {
    typealias R = AgendaRuntimeSupport

    final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String] = []
        func add(_ line: String) { lock.lock(); storage.append(line); lock.unlock() }
        var lines: [String] { lock.lock(); defer { lock.unlock() }; return storage }
    }

    @Test("A whole refresh logs no title, address, name, URL or password")
    func nothingPrivate() async {
        let root = R.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let collector = Collector()
        let previous = NCAgendaLog.sink
        NCAgendaLog.sink = { collector.add($0) }
        defer { NCAgendaLog.sink = previous }
        _ = await R.store(AgendaFixtures.server(), root: root).refresh()
        _ = await R.offlineStore(root: root).refresh()
        let text = collector.lines.joined(separator: "\n")
        #expect(!collector.lines.isEmpty)
        let secrets = ["Dentist", "Draft report", "Write homepage copy", "Review sitemap", "Writer-Bot", "ali-secret@example.org", "Ali",
                       R.password, "Authorization", "Basic ", "drive.test", "/remote.php", "personal", "Website", "Mara"]
        for secret in secrets {
            #expect(!text.contains(secret), "\(secret)")
        }
        #expect(collector.lines.allSatisfy { $0.hasPrefix("agenda ") })
    }
}

// MARK: - Entry and links

@Suite("NoDrive NoAgenda entry")
struct NoDriveAgendaEntryTests {
    @Test("The sidebar entry: title, identifier and an existing symbol")
    func entry() {
        #expect(NCAgendaEntry.title == "NoAgenda")
        #expect(NCAgendaEntry.sidebarIdentifier == "sidebarNoAgenda")
        #expect(UIImage(systemName: NCAgendaEntry.symbolName) != nil)
        for kind in [AgendaKind.event, .todo, .ganttTask, .milestone, .card] {
            #expect(UIImage(systemName: kind.symbolName) != nil, "\(kind.symbolName)")
        }
        for name in ["exclamationmark.triangle", "nosign", "alarm", "lock.fill", "slider.horizontal.3"] {
            #expect(UIImage(systemName: name) != nil, "\(name)")
        }
        #expect(NCAgendaEntry.isShown(account: "ali https://drive.test"))
        #expect(!NCAgendaEntry.isShown(account: ""))
    }

    @Test("Open-in links: calendar (base64 of the DAV path, and the instance), tasks, NoGantt and NoBoard")
    func links() {
        let path = "/remote.php/dav/calendars/ali/personal/dentist.ics"
        let encoded = Data(path.utf8).base64EncodedString().addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        let single = AgendaLink(home: .calendar, path: path, calendarUri: "personal", fileName: "dentist.ics")
        #expect(NCAgendaWebLinks.path(for: single) == "index.php/apps/calendar/edit/" + encoded)
        let instance = AgendaLink(home: .calendar, path: path, calendarUri: "personal", fileName: "dentist.ics", recurrence: Date(timeIntervalSince1970: 1_761_800_000))
        #expect(NCAgendaWebLinks.path(for: instance) == "index.php/apps/calendar/edit/" + encoded + "/1761800000")
        let todo = AgendaLink(home: .tasks, path: "/x", calendarUri: "my list", fileName: "draft.ics")
        #expect(NCAgendaWebLinks.path(for: todo) == "index.php/apps/tasks/calendars/my%20list/tasks/draft.ics")
        #expect(NCAgendaWebLinks.path(for: AgendaLink(home: .gantt, projectId: 1, taskId: 11)) == "index.php/apps/nc_gantt/?project=1&task=11")
        #expect(NCAgendaWebLinks.path(for: AgendaLink(home: .gantt, projectId: 1)) == "index.php/apps/nc_gantt/?project=1")
        #expect(NCAgendaWebLinks.path(for: AgendaLink(home: .board, cardId: 21)) == "index.php/apps/deck/card/21")
        #expect(NCAgendaWebLinks.path(for: AgendaLink(home: .board)) == "index.php/apps/deck/")
        #expect(NCAgendaWebLinks.url(for: AgendaLink(home: .board, cardId: 21), base: "https://drive.test")?.absoluteString == "https://drive.test/index.php/apps/deck/card/21")
        #expect(NCAgendaWebLinks.homeURL(.gantt, base: "https://drive.test/sub")?.absoluteString == "https://drive.test/sub/index.php/apps/nc_gantt/")
    }

    @Test("The English texts exist and carry no other brand")
    func texts() {
        #expect(NCAgendaText.t("_nodrive_agenda_open_gantt_") == "Open in NoGantt")
        #expect(NCAgendaText.t("_nodrive_agenda_personal_question_") == "Which of your calendars are personal?")
        #expect(NCAgendaText.f("_nodrive_agenda_days_late_", 2) == "2 days late")
        #expect(NCAgendaText.t("_nodrive_agenda_nothing_") == "Nothing for this day.")
        for key in ["_nodrive_agenda_home_refused_", "_nodrive_agenda_home_read_only_", "_nodrive_agenda_not_linked_", "_nodrive_agenda_registry_invalid_"] {
            #expect(!NCAgendaText.t(key).lowercased().contains("nextcloud"))
        }
    }

    @Test("Row texts: time of an event, spoken label")
    func rows() {
        var item = AgendaItem(key: "k", home: .calendar, kind: .event, title: "Dentist", sourceKey: "cal:personal", sourceName: "Personal",
                              sourceColor: "#2563EB", link: AgendaLink(home: .calendar))
        item.start = ISO8601DateFormatter().date(from: "2026-10-30T10:00:00Z")
        item.end = ISO8601DateFormatter().date(from: "2026-10-30T11:00:00Z")
        let calendar = AgendaRuntimeSupport.calendar
        #expect(NCAgendaFormat.whenText(item, calendar: calendar)?.contains(" - ") == true)
        let spoken = NCAgendaFormat.spoken(item, calendar: calendar)
        #expect(spoken.contains("Dentist") && spoken.contains("Personal"))
        item.allDay = true
        #expect(NCAgendaFormat.whenText(item, calendar: calendar) == NCAgendaText.t("_nodrive_agenda_all_day_"))
    }
}
