// SPDX-FileCopyrightText: 2026 Nourax
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import Nextcloud

/// The sidebar's Apps section: it must follow the stored list while the sidebar is already open.
@Suite("NoDrive Workspace menu")
@MainActor
struct NoDriveWorkspaceMenuTests {
    let base = "https://drive.nourax.org"
    let account = "citest https://drive.nourax.org"

    private var request: URLRequest {
        URLRequest(url: URL(string: "https://drive.nourax.org/ocs/v2.php/core/navigation/apps?absolute=false&format=json")!)
    }

    /// A store with its own defaults and its own notification centre, so nothing else can reach the model.
    private func makeStore(center: NotificationCenter) -> NCWorkspaceAppsStore {
        let suite = "nodrive.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return NCWorkspaceAppsStore(defaults: defaults, center: center)
    }

    /// The change reaches the model on the main queue: wait for it (a hundred steps of 50 ms at most).
    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<100 where !condition() {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    private func answer(_ transport: NoDriveWorkspaceAppsTests.Transport,
                        store: NCWorkspaceAppsStore,
                        status: Int,
                        body: String,
                        at time: Date) async {
        transport.answers = [(status, body, nil)]
        _ = await store.refresh(account: account, base: base, request: request, force: true, now: time, fetch: transport.fetch)
    }

    @Test("The sidebar is open, the list arrives later: the Apps section fills by itself")
    func listArrivesAfterTheSidebarOpened() async {
        let center = NotificationCenter()
        let store = makeStore(center: center)
        let model = NCWorkspaceAppsModel(store: store, center: center)
        let transport = NoDriveWorkspaceAppsTests.Transport()

        // The sidebar opens: nothing is known yet, so the section is empty
        model.show(account: account)
        #expect(model.apps.isEmpty)

        // The list arrives from the server; nobody reopens the sidebar
        await answer(transport, store: store, status: 200, body: NoDriveWorkspaceAppsTests.fixture, at: Date())
        await waitUntil { !model.apps.isEmpty }
        #expect(model.apps.map(\.name) == ["Dashboard", "Mail", "NoMail", "Calendar", "Talk", "Contacts"])
        #expect(model.apps.first { $0.name == "NoMail" }?.outside == true)

        // The server changes the list (Mail is gone): the open section follows
        let withoutMail = NoDriveWorkspaceAppsTests.fixture.replacingOccurrences(of: #"{"id":"mail","#, with: #"{"id":"photos","#)
        await answer(transport, store: store, status: 200, body: withoutMail, at: Date().addingTimeInterval(1))
        await waitUntil { !model.apps.contains { $0.id == "mail" } }
        #expect(!model.apps.contains { $0.id == "mail" })
        #expect(model.apps.map(\.id) == ["dashboard", "nourax_nomail", "calendar", "spreed", "contacts"])

        // The server stops offering the list (404): the section empties
        await answer(transport, store: store, status: 404, body: "", at: Date().addingTimeInterval(2))
        await waitUntil { model.apps.isEmpty }
        #expect(model.apps.isEmpty)
    }

    @Test("A change of another account does not touch the open sidebar")
    func otherAccountIsIgnored() async {
        let center = NotificationCenter()
        let store = makeStore(center: center)
        let model = NCWorkspaceAppsModel(store: store, center: center)
        let transport = NoDriveWorkspaceAppsTests.Transport()
        let other = "other https://drive.nourax.org"

        model.show(account: account)
        transport.answers = [(200, NoDriveWorkspaceAppsTests.fixture, nil)]
        _ = await store.refresh(account: other, base: base, request: request, force: true, now: Date(), fetch: transport.fetch)
        // Give the notification time to arrive; the model must stay empty
        try? await Task.sleep(for: .milliseconds(300))
        #expect(model.apps.isEmpty)
        #expect(store.cached(account: other).count == 6)
    }

    @Test("Forgetting the account empties the open section, and the model reads the new account after a switch")
    func forgetAndSwitch() async {
        let center = NotificationCenter()
        let store = makeStore(center: center)
        let model = NCWorkspaceAppsModel(store: store, center: center)
        let transport = NoDriveWorkspaceAppsTests.Transport()
        await answer(transport, store: store, status: 200, body: NoDriveWorkspaceAppsTests.fixture, at: Date())

        // The sidebar opens with the cached list at once
        model.show(account: account)
        #expect(model.apps.count == 6)

        // Another account is chosen: nothing of the first account stays
        model.clear()
        #expect(model.apps.isEmpty)
        model.show(account: "other https://drive.nourax.org")
        #expect(model.apps.isEmpty)

        // Back on the first account, then the account is removed while the sidebar is open
        model.show(account: account)
        #expect(model.apps.count == 6)
        store.forget(account: account)
        await waitUntil { model.apps.isEmpty }
        #expect(model.apps.isEmpty)
    }

    @Test("A late answer for the same list does not change the model")
    func sameListDoesNotRepublish() async {
        let center = NotificationCenter()
        let store = makeStore(center: center)
        let model = NCWorkspaceAppsModel(store: store, center: center)
        let transport = NoDriveWorkspaceAppsTests.Transport()
        model.show(account: account)
        await answer(transport, store: store, status: 200, body: NoDriveWorkspaceAppsTests.fixture, at: Date())
        await waitUntil { !model.apps.isEmpty }
        let before = model.apps
        await answer(transport, store: store, status: 200, body: NoDriveWorkspaceAppsTests.fixture, at: Date().addingTimeInterval(5))
        try? await Task.sleep(for: .milliseconds(200))
        #expect(model.apps == before)
    }
}
