// SPDX-FileCopyrightText: 2026 Nourax
// SPDX-License-Identifier: GPL-3.0-or-later

import Darwin
import Foundation
import Network
import Testing
@testable import Nextcloud

// "Add to iPhone Calendar & Contacts" (iOSClient/DeviceSync): the profile, the one-time loopback server, the sign-in
// that creates the separate password, the flow, the secrecy of the password and the removal message. Fixtures are
// literals in this file. The password below is a made-up value, never a real one.

private let planted = "PLANTED-pw-4f9c2e7a1b8d"
private let base = "https://drive.nourax.org"

private func account(userId: String = "ali", loginName: String = "ali", key: String = "ali https://drive.nourax.org") -> NCDeviceSyncProfile.Account {
    NCDeviceSyncProfile.Account(base: base, userId: userId, loginName: loginName, accountKey: key)
}

private func plist(_ data: Data) throws -> [String: Any] {
    try #require((try PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any])
}

// MARK: - The profile

@Suite("NoDrive device sync profile")
struct NoDriveDeviceSyncProfileTests {
    @Test("The profile reads back with exactly the keys of Apple's CalDAV and CardDAV payloads")
    func keys() throws {
        let data = try NCDeviceSyncProfile.build(account: account(), password: planted, bundleIdentifier: "org.nourax.nodrive")
        let root = try plist(data)
        #expect(Set(root.keys) == ["PayloadType", "PayloadVersion", "PayloadIdentifier", "PayloadUUID", "PayloadDisplayName",
                                   "PayloadOrganization", "PayloadDescription", "PayloadRemovalDisallowed", "PayloadContent"])
        #expect(root["PayloadType"] as? String == "Configuration")
        #expect(root["PayloadVersion"] as? Int == 1)
        #expect(root["PayloadDisplayName"] as? String == "NoDrive Calendar & Contacts")
        #expect(root["PayloadOrganization"] as? String == "Nourax")
        #expect(root["PayloadRemovalDisallowed"] as? Bool == false)
        let content = try #require(root["PayloadContent"] as? [[String: Any]])
        #expect(content.count == 2)

        let caldav = content[0]
        #expect(caldav["PayloadType"] as? String == "com.apple.caldav.account")
        #expect(caldav["PayloadDisplayName"] as? String == "NoDrive Calendar")
        #expect(caldav["CalDAVAccountDescription"] as? String == "NoDrive")
        #expect(caldav["CalDAVHostName"] as? String == "drive.nourax.org")
        #expect(caldav["CalDAVPort"] as? Int == 443)
        #expect(caldav["CalDAVUseSSL"] as? Bool == true)
        #expect(caldav["CalDAVUsername"] as? String == "ali")
        #expect(caldav["CalDAVPassword"] as? String == planted)
        #expect(caldav["CalDAVPrincipalURL"] as? String == "https://drive.nourax.org/remote.php/dav/principals/users/ali/")

        let carddav = content[1]
        #expect(carddav["PayloadType"] as? String == "com.apple.carddav.account")
        #expect(carddav["PayloadDisplayName"] as? String == "NoDrive Contacts")
        #expect(carddav["CardDAVAccountDescription"] as? String == "NoDrive")
        #expect(carddav["CardDAVHostName"] as? String == "drive.nourax.org")
        #expect(carddav["CardDAVPort"] as? Int == 443)
        #expect(carddav["CardDAVUseSSL"] as? Bool == true)
        #expect(carddav["CardDAVUsername"] as? String == "ali")
        #expect(carddav["CardDAVPassword"] as? String == planted)
        #expect(carddav["CardDAVPrincipalURL"] as? String == "https://drive.nourax.org/remote.php/dav/principals/users/ali/")
    }

    @Test("A user id that needs percent-encoding is one path part of the principal URL")
    func principalEncoding() {
        #expect(NCDeviceSyncProfile.principalURL(base: base, userId: "ali.b@example.org") == "https://drive.nourax.org/remote.php/dav/principals/users/ali.b%40example.org/")
        #expect(NCDeviceSyncProfile.principalURL(base: base, userId: "a b/c") == "https://drive.nourax.org/remote.php/dav/principals/users/a%20b%2Fc/")
        #expect(NCDeviceSyncProfile.principalURL(base: "https://cloud.example.org:8443/nc/", userId: "x") == "https://cloud.example.org:8443/nc/remote.php/dav/principals/users/x/")
    }

    @Test("The identifier is stable for an account; every build has new UUIDs")
    func identifiers() throws {
        let a = NCDeviceSyncProfile.identifier(accountKey: "ali https://drive.nourax.org", bundleIdentifier: "org.nourax.nodrive")
        #expect(a == NCDeviceSyncProfile.identifier(accountKey: "ali https://drive.nourax.org", bundleIdentifier: "org.nourax.nodrive"))
        #expect(a != NCDeviceSyncProfile.identifier(accountKey: "mara https://drive.nourax.org", bundleIdentifier: "org.nourax.nodrive"))
        #expect(a.hasPrefix("org.nourax.nodrive.devicesync."))

        let first = try plist(NCDeviceSyncProfile.build(account: account(), password: planted, bundleIdentifier: "org.nourax.nodrive"))
        let second = try plist(NCDeviceSyncProfile.build(account: account(), password: planted, bundleIdentifier: "org.nourax.nodrive"))
        #expect(first["PayloadIdentifier"] as? String == second["PayloadIdentifier"] as? String)
        #expect(first["PayloadIdentifier"] as? String == a)
        #expect(first["PayloadUUID"] as? String != second["PayloadUUID"] as? String)
        let uuids = [first, second].flatMap { root -> [String] in
            let inner = (root["PayloadContent"] as? [[String: Any]] ?? []).compactMap { $0["PayloadUUID"] as? String }
            return inner + [root["PayloadUUID"] as? String ?? ""]
        }
        #expect(Set(uuids).count == 6)
        let inner = try #require(first["PayloadContent"] as? [[String: Any]])
        #expect(inner[0]["PayloadIdentifier"] as? String == a + ".caldav")
        #expect(inner[1]["PayloadIdentifier"] as? String == a + ".carddav")
    }

    @Test("The profile never names the upstream product")
    func noUpstreamName() throws {
        let data = try NCDeviceSyncProfile.build(account: account(), password: planted, bundleIdentifier: "org.nourax.nodrive")
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.range(of: "nextcloud", options: .caseInsensitive) == nil)
        #expect(text.contains("NoDrive"))
    }

    @Test("Only https is accepted")
    func needsHTTPS() {
        let insecure = NCDeviceSyncProfile.Account(base: "http://drive.example.org", userId: "ali", loginName: "ali", accountKey: "k")
        #expect(throws: NCDeviceSyncProfile.BuildError.needsHTTPS) {
            try NCDeviceSyncProfile.build(account: insecure, password: planted, bundleIdentifier: "x.y")
        }
    }

    @Test("The test copy has both passwords replaced")
    func redacted() throws {
        let data = try NCDeviceSyncProfile.build(account: account(), password: planted, bundleIdentifier: "org.nourax.nodrive")
        let copy = try #require(NCDeviceSyncProfile.redacted(data))
        let text = String(decoding: copy, as: UTF8.self)
        #expect(!text.contains(planted))
        let content = try #require(try plist(copy)["PayloadContent"] as? [[String: Any]])
        #expect(content[0]["CalDAVPassword"] as? String == "<redacted>")
        #expect(content[1]["CardDAVPassword"] as? String == "<redacted>")
        #expect(content[0]["CalDAVUsername"] as? String == "ali")
    }
}

// MARK: - The secret

@Suite("NoDrive device sync secret")
struct NoDriveDeviceSyncSecretTests {
    @Test("A wiped secret gives nothing back")
    func wipe() {
        let secret = NCDeviceSyncSecret(planted)
        #expect(secret.string() == planted)
        #expect(!secret.isWiped)
        secret.wipe()
        #expect(secret.isWiped)
        #expect(secret.data() == nil)
        #expect(secret.string() == nil)
    }
}

// MARK: - The loopback server

/// One raw HTTP request on 127.0.0.1 (or another address), the whole answer, or nil when the connection failed.
private func rawRequest(host: String, port: UInt16, path: String, timeout: TimeInterval = 5) async -> Data? {
    await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
        final class State: @unchecked Sendable {
            let lock = NSLock()
            var finished = false
            var received = Data()
        }
        let state = State()
        let connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        let queue = DispatchQueue(label: "devicesync-test-client")
        func finish() {
            state.lock.lock()
            defer { state.lock.unlock() }
            if state.finished { return }
            state.finished = true
            connection.cancel()
            continuation.resume(returning: state.received.isEmpty ? nil : state.received)
        }
        func receive() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, complete, error in
                if let data {
                    state.lock.lock()
                    state.received.append(data)
                    state.lock.unlock()
                }
                if complete || error != nil {
                    finish()
                } else {
                    receive()
                }
            }
        }
        connection.stateUpdateHandler = { newState in
            switch newState {
            case .ready:
                connection.send(content: Data("GET \(path) HTTP/1.1\r\nHost: \(host)\r\nConnection: close\r\n\r\n".utf8),
                                completion: .contentProcessed { _ in })
                receive()
            case .failed, .waiting, .cancelled:
                finish()
            default:
                break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + timeout) { finish() }
    }
}

private func split(_ answer: Data) -> (head: String, body: Data) {
    let marker = Data("\r\n\r\n".utf8)
    guard let range = answer.range(of: marker) else { return (String(decoding: answer, as: UTF8.self), Data()) }
    return (String(decoding: answer[..<range.lowerBound], as: UTF8.self), Data(answer[range.upperBound...]))
}

/// An IPv4 address of this device that is not the loopback address, if there is one.
private func otherIPv4() -> String? {
    var list: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&list) == 0, let first = list else { return nil }
    defer { freeifaddrs(list) }
    var cursor: UnsafeMutablePointer<ifaddrs>? = first
    while let item = cursor {
        let flags = Int32(item.pointee.ifa_flags)
        if let address = item.pointee.ifa_addr, address.pointee.sa_family == sa_family_t(AF_INET),
           flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 {
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                return String(cString: host)
            }
        }
        cursor = item.pointee.ifa_next
    }
    return nil
}

@Suite("NoDrive device sync loopback server", .serialized)
struct NoDriveDeviceSyncServerTests {
    private func start(lifetime: TimeInterval = 120, profile: String = "PROFILE-BYTES") async throws -> (NCDeviceSyncProfileServer, URL, NCDeviceSyncSecret) {
        let secret = NCDeviceSyncSecret(profile)
        let server = NCDeviceSyncProfileServer(profile: secret, lifetime: lifetime)
        let url = try await server.start()
        return (server, url, secret)
    }

    @Test("It listens on 127.0.0.1 only, on a random path of 32 bytes")
    func address() async throws {
        let (server, url, _) = try await start()
        defer { server.cancel() }
        #expect(url.host == "127.0.0.1")
        #expect(url.scheme == "http")
        let name = url.lastPathComponent
        #expect(name.hasSuffix(".mobileconfig"))
        let token = name.replacingOccurrences(of: ".mobileconfig", with: "")
        #expect(token.count == 64)
        #expect(token.allSatisfy { $0.isHexDigit })
        let (other, otherURL, _) = try await start()
        defer { other.cancel() }
        #expect(otherURL.lastPathComponent != name)

        // another address of this device does not reach it
        if let address = otherIPv4(), let port = url.port {
            let reached = await rawRequest(host: address, port: UInt16(port), path: url.path, timeout: 3)
            #expect(reached == nil, "the server answered on \(address)")
        }
    }

    @Test("The right path is served once, with the profile content type, then it is gone")
    func servesOnce() async throws {
        let (server, url, _) = try await start(profile: "THE-PROFILE")
        defer { server.cancel() }
        let port = UInt16(try #require(url.port))
        let served = Counter()
        server.onServed = { served.add() }
        let first = try #require(await rawRequest(host: "127.0.0.1", port: port, path: url.path))
        let parts = split(first)
        #expect(parts.head.hasPrefix("HTTP/1.1 200"))
        #expect(parts.head.contains("Content-Type: application/x-apple-aspen-config"))
        #expect(parts.head.contains("Content-Disposition: attachment; filename=\"NoDrive.mobileconfig\""))
        #expect(parts.head.contains("Cache-Control: no-store"))
        #expect(String(decoding: parts.body, as: UTF8.self) == "THE-PROFILE")
        #expect(served.value == 1)
        // the second request: refused (closed) or 404, never the profile
        let second = await rawRequest(host: "127.0.0.1", port: port, path: url.path, timeout: 3)
        if let second {
            #expect(split(second).head.hasPrefix("HTTP/1.1 404"))
            #expect(!String(decoding: second, as: UTF8.self).contains("THE-PROFILE"))
        }
    }

    @Test("A wrong path is 404 and does not use up the serve")
    func wrongPath() async throws {
        let (server, url, _) = try await start()
        defer { server.cancel() }
        let port = UInt16(try #require(url.port))
        for path in ["/", "/profile.mobileconfig", url.path + "x", "/" + String(repeating: "0", count: 64) + ".mobileconfig"] {
            let answer = try #require(await rawRequest(host: "127.0.0.1", port: port, path: path))
            #expect(split(answer).head.hasPrefix("HTTP/1.1 404"), "\(path)")
        }
        let good = try #require(await rawRequest(host: "127.0.0.1", port: port, path: url.path))
        #expect(split(good).head.hasPrefix("HTTP/1.1 200"))
    }

    @Test("It closes after its lifetime")
    func lifetime() async throws {
        let (server, url, _) = try await start(lifetime: 1)
        defer { server.cancel() }
        let closed = Counter()
        server.onClosed = { closed.add() }
        let port = UInt16(try #require(url.port))
        try await Task.sleep(for: .seconds(2.5))
        #expect(closed.value == 1)
        let late = await rawRequest(host: "127.0.0.1", port: port, path: url.path, timeout: 3)
        #expect(late == nil || !String(decoding: late!, as: UTF8.self).contains("PROFILE-BYTES"))
    }

    @Test("It closes on cancel, and a wiped profile is never served")
    func cancelAndWipe() async throws {
        let (server, url, _) = try await start()
        let closed = Counter()
        server.onClosed = { closed.add() }
        server.cancel()
        try await Task.sleep(for: .seconds(0.5))
        #expect(closed.value == 1)
        _ = url

        let (wiped, wipedURL, secret) = try await start()
        defer { wiped.cancel() }
        secret.wipe()
        let answer = try #require(await rawRequest(host: "127.0.0.1", port: UInt16(try #require(wipedURL.port)), path: wipedURL.path))
        #expect(split(answer).head.hasPrefix("HTTP/1.1 404"))
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func add() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

// MARK: - The sign-in that makes the separate password

/// Records every request and answers from a script.
private final class FakeServer: @unchecked Sendable {
    struct Seen {
        let method: String
        let url: String
        let userAgent: String?
        let authorization: String?
        let body: String
    }

    private let lock = NSLock()
    private(set) var seen: [Seen] = []
    /// Poll answers in order; the last one repeats.
    var pollAnswers: [(Int, String)] = [(404, "[]")]
    var startAnswer: (Int, String) = (200, #"{"poll":{"token":"POLL-TOKEN-1234","endpoint":"https://drive.nourax.org/login/v2/poll"},"login":"https://drive.nourax.org/login/v2/flow/FLOW-1"}"#)
    var revokeStatus = 200
    private var polls = 0

    func transport(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.lock()
        defer { lock.unlock() }
        let url = request.url!
        seen.append(Seen(method: request.httpMethod ?? "", url: url.absoluteString,
                         userAgent: request.value(forHTTPHeaderField: "User-Agent"),
                         authorization: request.value(forHTTPHeaderField: "Authorization"),
                         body: String(decoding: request.httpBody ?? Data(), as: UTF8.self)))
        func answer(_ status: Int, _ text: String) -> (Data, HTTPURLResponse) {
            (Data(text.utf8), HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!)
        }
        if request.httpMethod == "DELETE" { return answer(revokeStatus, "{}") }
        if url.path.hasSuffix("/index.php/login/v2") { return answer(startAnswer.0, startAnswer.1) }
        let index = min(polls, pollAnswers.count - 1)
        polls += 1
        return answer(pollAnswers[index].0, pollAnswers[index].1)
    }

    func methods() -> [String] { lock.lock(); defer { lock.unlock() }; return seen.map(\.method) }
}

private func grantJSON(server: String = base, loginName: String = "ali", password: String = planted) -> String {
    #"{"server":"\#(server)","loginName":"\#(loginName)","appPassword":"\#(password)"}"#
}

@Suite("NoDrive device sync sign-in", .serialized)
struct NoDriveDeviceSyncSignInTests {
    private func client(_ server: FakeServer) -> NCDeviceAppPasswordClient {
        NCDeviceAppPasswordClient(base: base, transport: { try await server.transport($0) })
    }

    @Test("The start request is a POST to login/v2 with our own user agent")
    func start() async throws {
        let server = FakeServer()
        let flow = try await client(server).start()
        let request = try #require(server.seen.first)
        #expect(request.method == "POST")
        #expect(request.url == "https://drive.nourax.org/index.php/login/v2")
        #expect(request.userAgent == "NoDrive Calendar & Contacts (iPhone)")
        #expect(request.authorization == nil)
        #expect(flow.loginURL.absoluteString == "https://drive.nourax.org/login/v2/flow/FLOW-1")
        #expect(!"\(flow)".contains("POLL-TOKEN"))
    }

    @Test("A login page or a poll endpoint of another origin stops the flow")
    func otherOrigin() async {
        for answer in [#"{"poll":{"token":"t","endpoint":"https://drive.nourax.org/login/v2/poll"},"login":"https://evil.example.com/login"}"#,
                       #"{"poll":{"token":"t","endpoint":"https://evil.example.com/poll"},"login":"https://drive.nourax.org/login/v2/flow/x"}"#,
                       #"{"poll":{"token":"t","endpoint":"http://drive.nourax.org/poll"},"login":"https://drive.nourax.org/login/v2/flow/x"}"#] {
            let server = FakeServer()
            server.startAnswer = (200, answer)
            await #expect(throws: NCDeviceAppPasswordError.wrongOrigin) { try await client(server).start() }
        }
    }

    @Test("A server that does not start the sign-in is a refusal")
    func refused() async {
        let server = FakeServer()
        server.startAnswer = (403, "{}")
        await #expect(throws: NCDeviceAppPasswordError.refused) { try await client(server).start() }
    }

    @Test("Polling goes on after 404 and ends with the password")
    func polling() async throws {
        let server = FakeServer()
        server.pollAnswers = [(404, "[]"), (404, "[]"), (200, grantJSON())]
        let c = client(server)
        let flow = try await c.start()
        let slept = Counter()
        let grant = try await c.waitForGrant(flow, interval: 5, timeout: 1200, sleep: { _ in slept.add() })
        #expect(grant.loginName == "ali")
        #expect(grant.secret.string() == planted)
        #expect(slept.value == 2)
        let polls = server.seen.filter { $0.url.hasSuffix("/login/v2/poll") }
        #expect(polls.count == 3)
        #expect(polls.allSatisfy { $0.method == "POST" && $0.body == "token=POLL-TOKEN-1234" && $0.userAgent == "NoDrive Calendar & Contacts (iPhone)" })
    }

    @Test("It stops after the timeout")
    func timeout() async throws {
        let server = FakeServer()
        let c = client(server)
        let flow = try await c.start()
        await #expect(throws: NCDeviceAppPasswordError.timedOut) {
            try await c.waitForGrant(flow, interval: 5, timeout: 20, sleep: { _ in })
        }
        #expect(server.seen.filter { $0.url.hasSuffix("/login/v2/poll") }.count == 4)
    }

    @Test("An answer that names another server is refused and revoked")
    func mismatch() async throws {
        let server = FakeServer()
        server.pollAnswers = [(200, grantJSON(server: "https://evil.example.com"))]
        let c = client(server)
        let flow = try await c.start()
        await #expect(throws: NCDeviceAppPasswordError.wrongServer) {
            try await c.waitForGrant(flow, interval: 1, timeout: 5, sleep: { _ in })
        }
        let revoke = try #require(server.seen.last)
        #expect(revoke.method == "DELETE")
        // the password goes to the account's own server, never to the server the answer named
        #expect(revoke.url == "https://drive.nourax.org/ocs/v2.php/core/apppassword")
        #expect(!server.seen.contains { $0.url.contains("evil.example.com") })
    }

    @Test("The same server with another case or a trailing slash is accepted")
    func sameServer() {
        #expect(NCDeviceAppPasswordClient.sameServer("https://Drive.Nourax.org/", base))
        #expect(!NCDeviceAppPasswordClient.sameServer("https://drive.nourax.org/other", base))
        #expect(!NCDeviceAppPasswordClient.sameServer("http://drive.nourax.org", base))
        #expect(!NCDeviceAppPasswordClient.sameServer("https://drive.nourax.org.evil.com", base))
    }

    @Test("Revoking sends DELETE with the Basic header of the new password")
    func revoke() async throws {
        let server = FakeServer()
        let c = client(server)
        await c.revoke(NCDeviceAppPasswordClient.Grant(loginName: "ali", secret: NCDeviceSyncSecret(planted)))
        let request = try #require(server.seen.first)
        #expect(request.method == "DELETE")
        #expect(request.url == "https://drive.nourax.org/ocs/v2.php/core/apppassword")
        let expected = "Basic " + Data("ali:\(planted)".utf8).base64EncodedString()
        #expect(request.authorization == expected)
    }
}

// MARK: - The flow

@MainActor
private final class FlowFixture {
    let server = FakeServer()
    let defaults = UserDefaults(suiteName: "devicesync-test-\(UUID().uuidString)")!
    var logs: [String] = []
    var built: [Data] = []
    var signInOpened = 0
    var signInDismissed = 0
    var safariOpened: [URL] = []
    var safariResult = true
    var servers: [NCDeviceSyncProfileServer] = []
    /// The install window is an hour for the fake sleep, unless a test wants it to end.
    var fastInstallWindow = false

    func flow() -> NCDeviceSyncFlow {
        let state = NCDeviceSyncState(defaults: defaults)
        let fake = server
        let dependencies = NCDeviceSyncFlow.Dependencies(
            account: "ali https://drive.nourax.org",
            client: { NCDeviceAppPasswordClient(base: base, transport: { try await fake.transport($0) }) },
            profileAccount: { loginName in
                NCDeviceSyncProfile.Account(base: base, userId: "ali", loginName: loginName, accountKey: "ali https://drive.nourax.org")
            },
            bundleIdentifier: "org.nourax.nodrive",
            presentSignIn: { [unowned self] _, _ in self.signInOpened += 1 },
            dismissSignIn: { [unowned self] in self.signInDismissed += 1 },
            startServer: { [unowned self] profile in
                let created = NCDeviceSyncProfileServer(profile: profile)
                self.servers.append(created)
                return (URL(string: "http://127.0.0.1:1/test.mobileconfig")!, created)
            },
            openInSafari: { [unowned self] url in
                self.safariOpened.append(url)
                return self.safariResult
            },
            state: state,
            pollInterval: 0.001,
            pollTimeout: 0.01,
            installWindow: 600,
            sleep: { [unowned self] seconds in
                if seconds >= 100 {
                    try await Task.sleep(nanoseconds: self.fastInstallWindow ? 100_000_000 : 3_600_000_000_000)
                } else {
                    try await Task.sleep(nanoseconds: 1_000_000)
                }
            },
            profileBuilt: { [unowned self] data in self.built.append(data) })
        return NCDeviceSyncFlow(dependencies: dependencies)
    }

    func waitFor(_ flow: NCDeviceSyncFlow, _ phase: NCDeviceSyncFlow.Phase) async -> Bool {
        for _ in 0..<500 {
            if flow.phase == phase { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }
}

@Suite("NoDrive device sync flow", .serialized)
@MainActor
struct NoDriveDeviceSyncFlowTests {
    @Test("Continue, allow, profile, Safari, install steps, Installed: the password is forgotten")
    func happyPath() async throws {
        let fixture = FlowFixture()
        fixture.server.pollAnswers = [(404, "[]"), (200, grantJSON())]
        let logs = LogCapture()
        defer { logs.restore() }
        let flow = fixture.flow()
        #expect(flow.phase == .intro)
        flow.begin()
        #expect(await fixture.waitFor(flow, .installSteps))
        #expect(fixture.signInOpened == 1)
        #expect(fixture.signInDismissed >= 1)
        #expect(fixture.safariOpened.count == 1)
        #expect(NCDeviceSyncState(defaults: fixture.defaults).profileOffered(account: "ali https://drive.nourax.org"))
        #expect(flow.holdsSecret)
        // the built profile has the planted password; the test copy has not
        let built = try #require(fixture.built.first)
        #expect(String(decoding: built, as: UTF8.self).contains(planted))
        #expect(!String(decoding: try #require(NCDeviceSyncProfile.redacted(built)), as: UTF8.self).contains(planted))

        flow.installed()
        #expect(flow.phase == .done)
        #expect(!flow.holdsSecret)
        #expect(!fixture.server.methods().contains("DELETE"))
        #expect(logs.lines.allSatisfy { !$0.contains(planted) && !$0.contains("POLL-TOKEN") })
    }

    @Test("Open Safari again makes a new one-time address from the same profile")
    func openAgain() async throws {
        let fixture = FlowFixture()
        fixture.server.pollAnswers = [(200, grantJSON())]
        let flow = fixture.flow()
        flow.begin()
        #expect(await fixture.waitFor(flow, .installSteps))
        await flow.openSafari()
        #expect(fixture.safariOpened.count == 2)
        #expect(fixture.servers.count == 2)
        #expect(flow.phase == .installSteps)
        flow.installed()
        #expect(!flow.holdsSecret)
    }

    @Test("It didn't work: DELETE with the new password's Basic header, then everything is forgotten")
    func didntWork() async throws {
        let fixture = FlowFixture()
        fixture.server.pollAnswers = [(200, grantJSON())]
        let flow = fixture.flow()
        flow.begin()
        #expect(await fixture.waitFor(flow, .installSteps))
        flow.didntWork()
        #expect(flow.phase == .undone)
        for _ in 0..<200 where !fixture.server.methods().contains("DELETE") {
            try await Task.sleep(for: .milliseconds(10))
        }
        let revoke = try #require(fixture.server.seen.last)
        #expect(revoke.method == "DELETE")
        #expect(revoke.url == "https://drive.nourax.org/ocs/v2.php/core/apppassword")
        #expect(revoke.authorization == "Basic " + Data("ali:\(planted)".utf8).base64EncodedString())
        for _ in 0..<200 where flow.holdsSecret {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!flow.holdsSecret)
    }

    @Test("Cancel while waiting revokes nothing (no password yet) and forgets the sign-in")
    func cancelWaiting() async throws {
        let fixture = FlowFixture()
        fixture.server.pollAnswers = [(404, "[]")]
        let flow = fixture.flow()
        flow.begin()
        #expect(await fixture.waitFor(flow, .waiting))
        flow.cancel()
        #expect(flow.phase == .intro)
        #expect(!flow.holdsSecret)
        #expect(!fixture.server.methods().contains("DELETE"))
    }

    @Test("The sign-in that takes too long ends in the timeout text state")
    func timedOut() async throws {
        let fixture = FlowFixture()
        fixture.server.pollAnswers = [(404, "[]")]
        let flow = fixture.flow()
        flow.begin()
        #expect(await fixture.waitFor(flow, .timedOut))
        #expect(!flow.holdsSecret)
    }

    @Test("A server that does not start the sign-in gives the administrator message state")
    func refusedByServer() async throws {
        let fixture = FlowFixture()
        fixture.server.startAnswer = (404, "{}")
        let flow = fixture.flow()
        flow.begin()
        #expect(await fixture.waitFor(flow, .refused))
    }

    @Test("Safari that cannot be opened leaves a state with Try again, and nothing is marked as offered")
    func safariFails() async throws {
        let fixture = FlowFixture()
        fixture.server.pollAnswers = [(200, grantJSON())]
        fixture.safariResult = false
        let flow = fixture.flow()
        flow.begin()
        #expect(await fixture.waitFor(flow, .failed))
        // nothing reached Safari: the password is removed again and nothing is marked as offered
        for _ in 0..<200 where !fixture.server.methods().contains("DELETE") {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(fixture.server.methods().contains("DELETE"))
        #expect(!NCDeviceSyncState(defaults: fixture.defaults).profileOffered(account: "ali https://drive.nourax.org"))
        #expect(!flow.holdsSecret)
    }

    @Test("The install window forgets the password and the profile")
    func installWindow() async throws {
        let fixture = FlowFixture()
        fixture.server.pollAnswers = [(200, grantJSON())]
        fixture.fastInstallWindow = true
        let flow = fixture.flow()
        flow.begin()
        #expect(await fixture.waitFor(flow, .installSteps))
        for _ in 0..<300 where flow.holdsSecret {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!flow.holdsSecret)
        #expect(flow.phase == .expired)
    }
}

/// Collects the lines of the device sync log for the length of a test.
private final class LogCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var collected: [String] = []
    private let previous: (String) -> Void

    init() {
        previous = NCDeviceSyncLog.sink
        NCDeviceSyncLog.sink = { [weak self] line in
            guard let self else { return }
            self.lock.lock()
            self.collected.append(line)
            self.lock.unlock()
        }
    }

    var lines: [String] { lock.lock(); defer { lock.unlock() }; return collected }

    func restore() { NCDeviceSyncLog.sink = previous }
}

// MARK: - Secrecy

// Secrecy tests run in the suite of the flow (one at a time), because they replace the log's sink.
extension NoDriveDeviceSyncFlowTests {
    @Test("A planted password is in the served bytes only: not in the log, the defaults, the account state or the redacted copy")
    func plantedPassword() async throws {
        let fixture = FlowFixture()
        fixture.server.pollAnswers = [(404, "[]"), (200, grantJSON())]
        let logs = LogCapture()
        defer { logs.restore() }
        let flow = fixture.flow()
        flow.begin()
        #expect(await fixture.waitFor(flow, .installSteps))
        flow.installed()

        // the log
        #expect(!logs.lines.isEmpty)
        for line in logs.lines {
            #expect(!line.contains(planted), "the log has the password: \(line)")
            #expect(!line.contains("POLL-TOKEN"), "the log has the poll token: \(line)")
        }
        // the defaults: everything the flow wrote
        let dump = String(describing: fixture.defaults.dictionaryRepresentation())
        #expect(!dump.contains(planted))
        #expect(!dump.contains("POLL-TOKEN"))
        // the files the app keeps for the sign-in and the profile
        let directories = [FileManager.default.temporaryDirectory,
                           FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
                           FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first].compactMap { $0 }
        for directory in directories {
            let items = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey])
            while let url = items?.nextObject() as? URL {
                guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                      values.isRegularFile == true, (values.fileSize ?? 0) < 500_000,
                      let data = try? Data(contentsOf: url) else { continue }
                #expect(data.range(of: Data(planted.utf8)) == nil, "a file holds the password: \(url.lastPathComponent)")
            }
        }
        // the served copy for the test run is redacted
        let built = try #require(fixture.built.first)
        #expect(String(decoding: built, as: UTF8.self).contains(planted))
        #expect(String(decoding: try #require(NCDeviceSyncProfile.redacted(built)), as: UTF8.self).contains("<redacted>"))
    }

    @Test("The log helper takes fixed words and numbers only")
    func logShape() {
        let logs = LogCapture()
        defer { logs.restore() }
        NCDeviceSyncLog.log("signin-start", status: 200)
        NCDeviceSyncLog.log("profile-served", count: 1234)
        #expect(logs.lines.contains("devicesync signin-start status=200"))
        #expect(logs.lines.contains("devicesync profile-served count=1234"))
    }
}

// MARK: - Removal

@Suite("NoDrive device sync removal", .serialized)
@MainActor
struct NoDriveDeviceSyncRemovalTests {
    private func run(offered: Bool) async -> (queued: Bool, shown: [(String, String)], offeredAfter: Bool) {
        let defaults = UserDefaults(suiteName: "devicesync-removal-\(UUID().uuidString)")!
        let state = NCDeviceSyncState(defaults: defaults)
        state.setProfileOffered(offered, account: "ali https://drive.nourax.org")
        let savedState = NCDeviceSyncRemoval.state
        let savedPresent = NCDeviceSyncRemoval.present
        let savedDelay = NCDeviceSyncRemoval.delay
        defer {
            NCDeviceSyncRemoval.state = savedState
            NCDeviceSyncRemoval.present = savedPresent
            NCDeviceSyncRemoval.delay = savedDelay
        }
        NCDeviceSyncRemoval.state = state
        NCDeviceSyncRemoval.delay = .milliseconds(1)
        var shown: [(String, String)] = []
        NCDeviceSyncRemoval.present = { title, message in shown.append((title, message)) }
        let queued = await NCDeviceSyncRemoval.accountRemoved(account: "ali https://drive.nourax.org")
        try? await Task.sleep(for: .milliseconds(200))
        return (queued, shown, state.profileOffered(account: "ali https://drive.nourax.org"))
    }

    @Test("The steps show only when a profile was offered")
    func onlyWhenOffered() async {
        let without = await run(offered: false)
        #expect(!without.queued)
        #expect(without.shown.isEmpty)

        let with = await run(offered: true)
        #expect(with.queued)
        #expect(with.shown.count == 1)
        #expect(!with.offeredAfter)
        #expect(with.shown.first?.1.contains("Settings › General › VPN & Device Management") == true)
        #expect(with.shown.first?.1.contains("NoDrive Calendar & Contacts") == true)
        #expect(with.shown.first?.1.contains("Remove Profile") == true)
        #expect(with.shown.first?.1.range(of: "nextcloud", options: .caseInsensitive) == nil)
    }
}

// MARK: - Texts and hooks

@Suite("NoDrive device sync texts")
struct NoDriveDeviceSyncTextTests {
    @Test("Every text exists, in English, and none names the upstream product")
    func texts() {
        let keys = ["header", "button", "footer", "signin_first", "step1_title", "step1", "continue", "waiting", "reopen", "timeout",
                    "refused", "failed", "try_again", "opening", "install_title", "install_steps", "installed", "didnt_work",
                    "open_safari", "done", "done_button", "undone", "expired", "removal_title", "removal_message"]
        for key in keys {
            let full = "_nodrive_devicesync_\(key)_"
            let text = NCDeviceSync.text(full)
            #expect(text != full, "no text for \(full)")
            #expect(!text.isEmpty)
            #expect(text.range(of: "nextcloud", options: .caseInsensitive) == nil, "\(full) names the upstream product")
        }
        #expect(NCDeviceSync.text("_nodrive_devicesync_button_") == "Add to iPhone Calendar & Contacts")
        #expect(NCDeviceSync.text("_nodrive_devicesync_installed_") == "Installed")
        #expect(NCDeviceSync.text("_nodrive_devicesync_didnt_work_") == "It didn't work")
    }

    @Test("Upstream's profile entry is switched off")
    func upstreamEntryOff() {
        #expect(NCBrandOptions.shared.disable_mobileconfig)
    }
}
