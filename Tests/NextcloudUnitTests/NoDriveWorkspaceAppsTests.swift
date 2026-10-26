// SPDX-FileCopyrightText: 2026 Nourax
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
import UIKit
@testable import Nextcloud

/// The server's navigation list: what the menu keeps, how it is cached and refreshed.
@Suite("NoDrive Workspace apps")
struct NoDriveWorkspaceAppsTests {
    let base = "https://drive.nourax.org"

    /// The shape of the server's answer (core/ResponseDefinitions.php, CoreNavigationEntry), with the cases the
    /// menu must handle: Files, an external-site entry, a foreign absolute address, an entry without order and
    /// app, an entry without a name, and a non-link entry.
    static let fixture = #"""
    {"ocs":{"meta":{"status":"ok","statuscode":200,"message":"OK"},"data":[
     {"id":"dashboard","order":1,"href":"/apps/dashboard/","icon":"/apps/dashboard/img/dashboard.svg","type":"link","name":"Dashboard","app":"dashboard","default":true,"active":false,"classes":"","unread":0},
     {"id":"files","order":2,"href":"/apps/files/","icon":"/apps/files/img/app.svg","type":"link","name":"Files","app":"files","active":false,"classes":"","unread":0},
     {"id":"mail","order":3,"href":"/apps/mail/","icon":"/apps/mail/img/mail.svg","type":"link","name":"Mail","app":"mail","active":false,"classes":"","unread":2},
     {"id":"calendar","order":4,"href":"/apps/calendar/","icon":"/apps/calendar/img/app.svg","type":"link","name":"Calendar","app":"calendar","active":false,"classes":"","unread":0},
     {"id":"spreed","order":5,"href":"/apps/spreed/","icon":"/apps/spreed/img/app.svg","type":"link","name":"Talk","app":"spreed","active":false,"classes":"","unread":0},
     {"id":"external_index1","order":6,"href":"/apps/external/1","icon":"/apps/external/img/app.svg","type":"link","name":"Wiki","app":"external","active":false,"classes":"","unread":0},
     {"id":"evil","order":7,"href":"https://evil.example/apps/x/","icon":"https://evil.example/i.svg","type":"link","name":"Foreign","app":"evil","active":false,"classes":"","unread":0},
     {"id":"contacts","href":"/apps/contacts/","icon":"","type":"link","name":"Contacts","active":false,"classes":"","unread":0},
     {"id":"nameless","href":"/apps/nameless/","type":"link","name":"   ","app":"nameless"},
     {"id":"settings","order":8,"href":"/settings/","type":"settings","name":"Settings","app":"settings"}
    ]}}
    """#

    private func parse(_ json: String = NoDriveWorkspaceAppsTests.fixture, base: String? = nil) throws -> [NCWorkspaceApp] {
        try NCWorkspaceAppsParser.parse(data: Data(json.utf8), base: base ?? self.base)
    }

    @Test("Keeps the apps, leaves out Files, external sites and foreign entries, keeps the server's order")
    func filter() throws {
        let apps = try parse()
        #expect(apps.map(\.id) == ["dashboard", "mail", "calendar", "spreed", "contacts"])
        #expect(apps.map(\.name) == ["Dashboard", "Mail", "Calendar", "Talk", "Contacts"])
    }

    @Test("Addresses are resolved against the account's server")
    func resolved() throws {
        let apps = try parse()
        #expect(apps.first { $0.id == "mail" }?.href == "https://drive.nourax.org/apps/mail/")
        #expect(apps.first { $0.id == "mail" }?.icon == "https://drive.nourax.org/apps/mail/img/mail.svg")
        #expect(apps.first { $0.id == "contacts" }?.icon == nil)
        #expect(apps.allSatisfy { NCWorkspaceOrigin.isSameOrigin($0.href, base: base) })
        // Server addresses with a web root already contain it
        let root = try parse(Self.fixture.replacingOccurrences(of: "\"/apps/", with: "\"/cloud/apps/"), base: "https://h.example/cloud")
        #expect(root.first { $0.id == "mail" }?.href == "https://h.example/cloud/apps/mail/")
    }

    @Test("An entry without order and app takes its id as the app")
    func withoutApp() throws {
        let apps = try parse()
        #expect(apps.first { $0.id == "contacts" }?.appId == "contacts")
        #expect(apps.first { $0.id == "mail" }?.appId == "mail")
    }

    @Test("An empty list is an empty menu; a broken answer is an error")
    func emptyAndBroken() throws {
        #expect(try parse(#"{"ocs":{"meta":{"statuscode":200},"data":[]}}"#).isEmpty)
        #expect(throws: NCWorkspaceAppsParser.ParseError.self) { try parse("not json") }
        #expect(throws: NCWorkspaceAppsParser.ParseError.self) { try parse(#"{"ocs":{"meta":{}}}"#) }
        #expect(throws: NCWorkspaceAppsParser.ParseError.self) { try parse(#"{"ocs":{"data":"x"}}"#) }
    }

    @Test("Every app maps to an SF Symbol that exists")
    func symbols() throws {
        let known = ["dashboard", "mail", "calendar", "spreed", "contacts", "deck", "notes", "tasks", "photos",
                     "activity", "forms", "tables", "somethingelse"]
        for appId in known {
            let name = NCWorkspaceApp.symbolName(appId: appId, id: appId)
            #expect(UIImage(systemName: name) != nil, "\(appId) -> \(name)")
        }
        #expect(NCWorkspaceApp.symbolName(appId: "unknown", id: "unknown") == "app")
        #expect(NCWorkspaceApp.symbolName(appId: "mail", id: "x") == "envelope")
    }

    // MARK: - Cache and refresh

    /// Records the requests and answers from a script.
    final class Transport: @unchecked Sendable {
        var requests: [URLRequest] = []
        var answers: [(Int, String, String?)] = []   // status, body, ETag

        func fetch(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            requests.append(request)
            guard !answers.isEmpty else { throw URLError(.notConnectedToInternet) }
            let (status, body, etag) = answers.removeFirst()
            var fields = ["Content-Type": "application/json"]
            if let etag { fields["ETag"] = etag }
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: fields)!
            return (Data(body.utf8), response)
        }
    }

    private func makeStore() -> NCWorkspaceAppsStore {
        let suite = "nodrive.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return NCWorkspaceAppsStore(defaults: defaults)
    }

    private var request: URLRequest {
        URLRequest(url: URL(string: "https://drive.nourax.org/ocs/v2.php/core/navigation/apps?absolute=false&format=json")!)
    }

    @Test("The list is cached with its ETag; 304 keeps it; 404 clears it; errors keep it")
    func cacheAndRefresh() async {
        let store = makeStore()
        let transport = Transport()
        let account = "citest https://drive.nourax.org"
        let start = Date()
        #expect(store.cached(account: account).isEmpty)

        transport.answers = [(200, Self.fixture, "\"abc\"")]
        var result = await store.refresh(account: account, base: base, request: request, force: false, now: start, fetch: transport.fetch)
        #expect(result == .updated)
        #expect(store.cached(account: account).count == 5)
        #expect(transport.requests.last?.value(forHTTPHeaderField: "If-None-Match") == nil)

        // Inside ten minutes nothing is asked
        result = await store.refresh(account: account, base: base, request: request, force: false, now: start.addingTimeInterval(300), fetch: transport.fetch)
        #expect(result == .throttled)
        #expect(transport.requests.count == 1)

        // After ten minutes the stored ETag is sent, 304 keeps the list
        transport.answers = [(304, "", nil)]
        result = await store.refresh(account: account, base: base, request: request, force: false, now: start.addingTimeInterval(700), fetch: transport.fetch)
        #expect(result == .notModified)
        #expect(transport.requests.last?.value(forHTTPHeaderField: "If-None-Match") == "\"abc\"")
        #expect(store.cached(account: account).count == 5)

        // A network error or a server error keeps the list; so does an answer that cannot be read
        transport.answers = []
        result = await store.refresh(account: account, base: base, request: request, force: true, now: start.addingTimeInterval(800), fetch: transport.fetch)
        #expect(result == .kept)
        transport.answers = [(500, "", nil)]
        result = await store.refresh(account: account, base: base, request: request, force: true, now: start.addingTimeInterval(810), fetch: transport.fetch)
        #expect(result == .kept)
        transport.answers = [(200, "not json", nil)]
        result = await store.refresh(account: account, base: base, request: request, force: true, now: start.addingTimeInterval(820), fetch: transport.fetch)
        #expect(result == .kept)
        #expect(store.cached(account: account).count == 5)

        // An older server without the list: the menu empties
        transport.answers = [(404, "", nil)]
        result = await store.refresh(account: account, base: base, request: request, force: true, now: start.addingTimeInterval(900), fetch: transport.fetch)
        #expect(result == .cleared)
        #expect(store.cached(account: account).isEmpty)
    }

    @Test("Each account has its own list; forgetting an account removes it")
    func perAccount() async {
        let store = makeStore()
        let transport = Transport()
        transport.answers = [(200, Self.fixture, nil)]
        _ = await store.refresh(account: "a https://drive.nourax.org", base: base, request: request, force: true, now: Date(), fetch: transport.fetch)
        #expect(store.cached(account: "a https://drive.nourax.org").count == 5)
        #expect(store.cached(account: "b https://drive.nourax.org").isEmpty)
        store.forget(account: "a https://drive.nourax.org")
        #expect(store.cached(account: "a https://drive.nourax.org").isEmpty)
    }
}
