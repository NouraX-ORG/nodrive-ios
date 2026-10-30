// SPDX-FileCopyrightText: 2026 Nourax
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import NextcloudKit

/// What NoAgenda writes to its log. Only counted and coded facts can be passed in, so a title, an address, a name
/// or a password cannot get into the log (the app's logs go into problem reports).
enum NCAgendaLog {
    /// Where the lines go. The tests replace it.
    static var sink: (String) -> Void = { line in
        nkLog(debug: line)
    }

    static func log(_ event: String, home: String? = nil, status: Int? = nil, count: Int? = nil, milliseconds: Int? = nil, id: Int? = nil) {
        var line = "agenda " + event
        if let home { line += " home=\(home)" }
        if let id { line += " id=\(id)" }
        if let status { line += " status=\(status)" }
        if let count { line += " count=\(count)" }
        if let milliseconds { line += " ms=\(milliseconds)" }
        sink(line)
    }
}

enum NCAgendaHTTPError: Error, Equatable {
    case noSession
    case wrongOrigin
    case redirected(Int)
    case status(Int)
    case network
    case invalid
}

/// The methods NoAgenda uses to read. (The writing methods come with the editing step.)
enum NCAgendaMethod: String {
    case get = "GET"
    case propfind = "PROPFIND"
    case report = "REPORT"
}

struct NCAgendaResponse {
    var status: Int
    var data: Data
    var etag: String?
}

/// One transport for every read: the account's own server only, the account's existing credential, no cookies,
/// no cache, no redirects (a 3xx is an error). `fetch` is replaced in tests.
struct NCAgendaHTTP {
    typealias Fetch = (URLRequest) async throws -> (Data, HTTPURLResponse)

    let account: String
    let base: String
    let userId: String
    let authorization: String
    let userAgent: String
    var fetch: Fetch

    init(account: String, base: String, userId: String, authorization: String, userAgent: String, fetch: @escaping Fetch) {
        self.account = account
        self.base = base
        self.userId = userId
        self.authorization = authorization
        self.userAgent = userAgent
        self.fetch = fetch
    }

    static func live(account: String) -> NCAgendaHTTP? {
        guard let credentials = NCWorkspaceSession.credentials(account: account) else { return nil }
        return NCAgendaHTTP(account: account, base: credentials.base, userId: credentials.userId,
                            authorization: credentials.authorization, userAgent: credentials.userAgent,
                            fetch: { request in try await NCWorkspaceSession.fetch(request) })
    }

    /// The user id as one URL path part.
    var encodedUser: String {
        userId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? userId
    }

    /// Builds one request. `path` is relative to the account's server ("remote.php/dav/...") or an absolute
    /// path from the server ("/remote.php/dav/calendars/..."). The result must be of the account's own origin;
    /// nothing else ever gets a header.
    func makeRequest(_ method: NCAgendaMethod, path: String, query: String? = nil, headers: [String: String] = [:], body: Data? = nil) throws -> URLRequest {
        guard let resolved = NCWorkspaceOrigin.resolve(path, base: base),
              NCWorkspaceOrigin.isSameOrigin(resolved, base: base) else { throw NCAgendaHTTPError.wrongOrigin }
        var text = resolved
        if let query, !query.isEmpty { text += (text.contains("?") ? "&" : "?") + query }
        guard let url = URL(string: text) else { throw NCAgendaHTTPError.wrongOrigin }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = method.rawValue
        request.httpShouldHandleCookies = false
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        request.setValue("true", forHTTPHeaderField: "OCS-APIRequest")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if request.value(forHTTPHeaderField: "Accept") == nil {
            request.setValue("application/json, application/xml, text/calendar, */*", forHTTPHeaderField: "Accept")
        }
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        if let body {
            request.httpBody = body
            if request.value(forHTTPHeaderField: "Content-Type") == nil {
                request.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
            }
        }
        return request
    }

    /// Sends one request. A 3xx is an error, a 4xx and 5xx are returned for the caller to decide.
    func send(_ method: NCAgendaMethod, path: String, query: String? = nil, headers: [String: String] = [:], body: Data? = nil, home: String) async throws -> NCAgendaResponse {
        let request = try makeRequest(method, path: path, query: query, headers: headers, body: body)
        let started = Date()
        do {
            let (data, response) = try await fetch(request)
            let milliseconds = Int(Date().timeIntervalSince(started) * 1000)
            NCAgendaLog.log("request", home: home, status: response.statusCode, milliseconds: milliseconds)
            if (300..<400).contains(response.statusCode) { throw NCAgendaHTTPError.redirected(response.statusCode) }
            return NCAgendaResponse(status: response.statusCode, data: data, etag: response.value(forHTTPHeaderField: "ETag"))
        } catch let error as NCAgendaHTTPError {
            throw error
        } catch {
            NCAgendaLog.log("network-error", home: home)
            throw NCAgendaHTTPError.network
        }
    }

    // MARK: - OCS

    /// The OCS path of the server's own APIs.
    func ocs(_ path: String, home: String, extraQuery: String? = nil) async throws -> NCAgendaResponse {
        let query = "format=json" + (extraQuery.map { "&" + $0 } ?? "")
        return try await send(.get, path: "ocs/v2.php/" + path, query: query, headers: ["Accept": "application/json"], home: home)
    }

    /// The `ocs.data` of an OCS answer.
    static func ocsData(_ data: Data) -> Any? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ocs = root["ocs"] as? [String: Any] else { return nil }
        return ocs["data"]
    }
}

/// Plain JSON reading helpers: tolerant, numbers and strings both allowed where a server may send either.
enum NCAgendaJSON {
    static func int(_ value: Any?) -> Int? {
        if let number = value as? Int { return number }
        if let number = value as? NSNumber, !(value is Bool) { return number.intValue }
        if let text = value as? String { return Int(text) }
        return nil
    }

    static func double(_ value: Any?) -> Double? {
        if let number = value as? Double { return number }
        if let number = value as? NSNumber, !(value is Bool) { return number.doubleValue }
        if let text = value as? String { return Double(text) }
        return nil
    }

    static func string(_ value: Any?) -> String? {
        if let text = value as? String { return text }
        if let number = value as? NSNumber, !(value is Bool) { return number.stringValue }
        return nil
    }

    static func bool(_ value: Any?) -> Bool? {
        if let flag = value as? Bool { return flag }
        if let number = value as? NSNumber { return number.intValue != 0 }
        return nil
    }

    static func dictionaries(_ value: Any?) -> [[String: Any]] {
        (value as? [Any])?.compactMap { $0 as? [String: Any] } ?? []
    }
}
