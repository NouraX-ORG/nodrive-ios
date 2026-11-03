// SPDX-FileCopyrightText: 2026 Nourax
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Network
import Security

/// A one-time server on this iPhone's loopback address (127.0.0.1 only), so Safari can download the profile: iOS
/// installs a configuration profile that comes "from a website". It serves the profile once, on a path that is 32 random
/// bytes long, and then closes. It also closes after its lifetime (2 minutes) or on `cancel()`. Anything else gets 404.
///
/// Listening on a loopback address needs no local-network permission (Apple TN3179).
final class NCDeviceSyncProfileServer: @unchecked Sendable {
    enum ServerError: Error, Equatable {
        case notReady
        case failed
    }

    static let contentType = "application/x-apple-aspen-config"
    static let fileName = "NoDrive.mobileconfig"

    private let queue = DispatchQueue(label: "org.nourax.nodrive.devicesync.profile-server")
    private let secret: NCDeviceSyncSecret
    private let lifetime: TimeInterval
    private let token: String
    private var listener: NWListener?
    private var closed = false
    private var served = false
    private var timeout: DispatchWorkItem?
    /// Called once when the profile was served.
    var onServed: (@Sendable () -> Void)?
    /// Called once when the server closed (after the serve, the lifetime, a cancel or a failure).
    var onClosed: (@Sendable () -> Void)?

    /// `secret` holds the profile bytes. The server reads them at the moment of the serve, so a wiped secret serves nothing.
    init(profile: NCDeviceSyncSecret, lifetime: TimeInterval = 120) {
        self.secret = profile
        self.lifetime = lifetime
        var bytes = [UInt8](repeating: 0, count: 32)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            bytes = (0..<32).map { _ in UInt8.random(in: 0...255) }
        }
        token = bytes.map { String(format: "%02x", $0) }.joined()
    }

    var path: String { "/" + token + ".mobileconfig" }

    /// Starts listening on 127.0.0.1 and any free port; returns the URL for Safari once the listener is ready.
    func start() async throws -> URL {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            let lock = NSLock()
            var finished = false
            func finish(_ result: Result<UInt16, Error>) {
                lock.lock()
                defer { lock.unlock() }
                if finished { return }
                finished = true
                continuation.resume(with: result)
            }
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    if let port = listener.port?.rawValue {
                        finish(.success(port))
                    } else {
                        finish(.failure(ServerError.notReady))
                    }
                case .failed, .cancelled:
                    finish(.failure(ServerError.failed))
                    self?.close()
                default:
                    break
                }
            }
            listener.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 10) {
                finish(.failure(ServerError.notReady))
            }
        }
        let work = DispatchWorkItem { [weak self] in
            self?.close()
        }
        queue.async { [weak self] in
            self?.timeout = work
        }
        queue.asyncAfter(deadline: .now() + lifetime, execute: work)
        NCDeviceSyncLog.log("profile-server-listening")
        guard let url = URL(string: "http://127.0.0.1:\(port)\(path)") else { throw ServerError.failed }
        return url
    }

    func cancel() {
        queue.async { [weak self] in
            self?.close()
        }
    }

    /// Only on the queue.
    private func close() {
        guard !closed else { return }
        closed = true
        timeout?.cancel()
        listener?.cancel()
        listener = nil
        NCDeviceSyncLog.log("profile-server-closed")
        let callback = onClosed
        onClosed = nil
        callback?()
    }

    // MARK: Connections

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, error in
            guard let self else {
                connection.cancel()
                return
            }
            guard error == nil, let data else {
                connection.cancel()
                return
            }
            let response = self.answer(to: data)
            connection.send(content: response.data, completion: .contentProcessed { _ in
                connection.cancel()
            })
            if response.served {
                self.onServed?()
                self.close()
            }
        }
    }

    /// The whole answer for one request. A request is served only when it is `GET` of the random path, once.
    private func answer(to request: Data) -> (data: Data, served: Bool) {
        let head = String(decoding: request.prefix(2048), as: UTF8.self)
        let line = head.split(separator: "\r\n", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? ""
        let words = line.split(separator: " ")
        guard words.count >= 2, words[0] == "GET", String(words[1]) == path, !served,
              let profile = secret.data() else {
            return (Self.notFound, false)
        }
        served = true
        var data = Data()
        let header = "HTTP/1.1 200 OK\r\n"
            + "Content-Type: \(Self.contentType)\r\n"
            + "Content-Disposition: attachment; filename=\"\(Self.fileName)\"\r\n"
            + "Content-Length: \(profile.count)\r\n"
            + "Cache-Control: no-store\r\n"
            + "Connection: close\r\n\r\n"
        data.append(Data(header.utf8))
        data.append(profile)
        NCDeviceSyncLog.log("profile-served", count: profile.count)
        return (data, true)
    }

    private static let notFound = Data(("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n").utf8)
}
