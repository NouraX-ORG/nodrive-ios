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

    // MARK: - Reads that join, survive and repeat

    /// Counts calls from any thread.
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }
        @discardableResult
        func next() -> Int {
            lock.lock()
            defer { lock.unlock() }
            count += 1
            return count
        }
    }

    private func makeStore(center: NotificationCenter, defaults: UserDefaults, retryDelays: [TimeInterval]) -> NCWorkspaceAppsStore {
        NCWorkspaceAppsStore(defaults: defaults, center: center, retryDelays: retryDelays)
    }

    private func freshDefaults() -> UserDefaults {
        let suite = "nodrive.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test("A second ask while a read is going joins it: one read, both callers get its outcome")
    func askingTwiceJoinsTheRunningRead() async {
        let store = makeStore(center: NotificationCenter(), defaults: freshDefaults(), retryDelays: [])
        let account = self.account
        let reads = Counter()
        let perform: @Sendable () async -> NCWorkspaceAppsStore.Outcome = {
            reads.next()
            try? await Task.sleep(for: .milliseconds(200))
            return .done
        }
        async let first = store.coalesced(account: account, perform: perform)
        try? await Task.sleep(for: .milliseconds(50))
        async let second = store.coalesced(account: account, perform: perform)
        let outcomes = await [first, second]
        #expect(outcomes == [.done, .done])
        #expect(reads.value == 1)

        // A later ask starts a new read
        _ = await store.coalesced(account: account, perform: perform)
        #expect(reads.value == 2)
    }

    @Test("A screen that goes away does not stop the read: the list is stored and reaches a new sidebar")
    func cancelledCallerDoesNotStopTheRead() async {
        let center = NotificationCenter()
        let store = makeStore(center: center, defaults: freshDefaults(), retryDelays: [])
        let transport = NoDriveWorkspaceAppsTests.Transport()
        transport.answers = [(200, NoDriveWorkspaceAppsTests.fixture, nil)]
        let request = self.request
        let account = self.account
        let base = self.base
        let caller = Task {
            await store.coalesced(account: account) {
                try? await Task.sleep(for: .milliseconds(150))
                _ = await store.refresh(account: account, base: base, request: request, force: true, now: Date(), fetch: transport.fetch)
                return .done
            }
        }
        try? await Task.sleep(for: .milliseconds(30))
        caller.cancel()
        // A second sidebar opens and asks while the first read is still going: it joins it
        let joined = await store.coalesced(account: account) { .retry }
        #expect(joined == .done)
        #expect(store.cached(account: account).count == 6)
        let model = NCWorkspaceAppsModel(store: store, center: center)
        model.show(account: account)
        #expect(model.apps.count == 6)
    }

    @Test("A read that fails is tried again by itself, a limited number of times")
    func failedReadIsRepeated() async {
        let store = makeStore(center: NotificationCenter(), defaults: freshDefaults(), retryDelays: [0.02, 0.02])
        let reads = Counter()
        let outcome = await store.coalesced(account: account) {
            // No session yet on the first two tries, then the server answers
            reads.next() < 3 ? .retry : .done
        }
        #expect(outcome == .retry)
        for _ in 0..<100 where reads.value < 3 {
            try? await Task.sleep(for: .milliseconds(50))
        }
        #expect(reads.value == 3)

        // Never succeeds: the first try and two repeats, then it stops
        let never = Counter()
        _ = await store.coalesced(account: "never https://drive.nourax.org") {
            never.next()
            return .retry
        }
        try? await Task.sleep(for: .milliseconds(400))
        #expect(never.value == 3)
    }

    @Test("Removing the account stops its read and its repeats: nothing is written back")
    func forgetStopsTheRead() async {
        let store = makeStore(center: NotificationCenter(), defaults: freshDefaults(), retryDelays: [0.02])
        let transport = NoDriveWorkspaceAppsTests.Transport()
        transport.answers = [(200, NoDriveWorkspaceAppsTests.fixture, nil)]
        let request = self.request
        let account = self.account
        let base = self.base
        let reads = Counter()
        let perform: @Sendable () async -> NCWorkspaceAppsStore.Outcome = {
            reads.next()
            let result = await store.refresh(account: account, base: base, request: request, force: true, now: Date()) { request in
                try await Task.sleep(for: .milliseconds(300))
                return try await transport.fetch(request)
            }
            return result == .kept ? .retry : .done
        }
        let running = Task { await store.coalesced(account: account, perform: perform) }
        try? await Task.sleep(for: .milliseconds(50))
        store.forget(account: account)
        _ = await running.value
        try? await Task.sleep(for: .milliseconds(300))
        #expect(store.cached(account: account).isEmpty)
        #expect(reads.value == 1)

        // The same account signs in again: a new read works and its list shows
        let again = await store.coalesced(account: account) {
            _ = await store.refresh(account: account, base: base, request: request, force: true, now: Date(), fetch: transport.fetch)
            return .done
        }
        #expect(again == .done)
        #expect(store.cached(account: account).count == 6)
    }

    // MARK: - Every path fills the section

    @Test("Restored launch: a new store and a new sidebar on the saved list show it at once")
    func restoredLaunchShowsTheSavedList() async {
        let defaults = freshDefaults()
        let firstLaunch = makeStore(center: NotificationCenter(), defaults: defaults, retryDelays: [])
        let transport = NoDriveWorkspaceAppsTests.Transport()
        await answer(transport, store: firstLaunch, status: 200, body: NoDriveWorkspaceAppsTests.fixture, at: Date())

        let center = NotificationCenter()
        let secondLaunch = makeStore(center: center, defaults: defaults, retryDelays: [])
        let model = NCWorkspaceAppsModel(store: secondLaunch, center: center)
        model.show(account: account)
        #expect(model.apps.count == 6)
        // The server still has the list: the answer is not modified and the open section stays as it is
        transport.answers = [(304, "", nil)]
        let result = await secondLaunch.refresh(account: account, base: base, request: request, force: true,
                                                now: Date().addingTimeInterval(700), fetch: transport.fetch)
        #expect(result == .notModified)
        #expect(model.apps.count == 6)
    }

    @Test("Sign out and sign in again with the same account: the section is empty, then the new list arrives by itself")
    func signInAgainWithTheSameAccount() async {
        let center = NotificationCenter()
        let store = makeStore(center: center, defaults: freshDefaults(), retryDelays: [])
        let model = NCWorkspaceAppsModel(store: store, center: center)
        let transport = NoDriveWorkspaceAppsTests.Transport()
        await answer(transport, store: store, status: 200, body: NoDriveWorkspaceAppsTests.fixture, at: Date())
        model.show(account: account)
        #expect(model.apps.count == 6)

        // The account is removed (the app forgets its list), the sidebar of the new sign-in is already open
        store.forget(account: account)
        await waitUntil { model.apps.isEmpty }
        #expect(model.apps.isEmpty)
        model.show(account: account)
        #expect(model.apps.isEmpty)

        // The list arrives late, in the open sidebar
        await answer(transport, store: store, status: 200, body: NoDriveWorkspaceAppsTests.fixture, at: Date().addingTimeInterval(30))
        await waitUntil { !model.apps.isEmpty }
        #expect(model.apps.count == 6)
    }
}
