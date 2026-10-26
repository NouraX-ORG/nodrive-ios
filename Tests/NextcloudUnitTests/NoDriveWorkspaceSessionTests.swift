// SPDX-FileCopyrightText: 2026 Nourax
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import Nextcloud

/// The sign-in hand-off: the session cookies of the server's answer, and the one request that asks for them.
@Suite("NoDrive Workspace session")
struct NoDriveWorkspaceSessionTests {
    let url = URL(string: "https://drive.nourax.org/ocs/v2.php/cloud/user?format=json")!

    /// What the server sends: PHP starts a session (one cookie), regenerates its id at the sign-in (a second
    /// one of the same name), the same-site cookies, and the log-in cookies it deletes.
    var setCookie: String {
        [
            "oc_sessionPassphrase=pass%2Fphrase; path=/; secure; HttpOnly; SameSite=Lax",
            "ocabcdefghij=oldsession; path=/; secure; HttpOnly; SameSite=Lax",
            "ocabcdefghij=newsession; path=/; secure; HttpOnly; SameSite=Lax",
            "nc_username=deleted; expires=Thu, 01-Jan-1970 00:00:01 GMT; Max-Age=0; path=/; secure",
            "__Host-nc_sameSiteCookielax=true; path=/; httponly; secure; expires=Fri, 31-Dec-2100 23:59:59 GMT; Max-Age=31536000; SameSite=lax",
            "__Host-nc_sameSiteCookiestrict=true; path=/; httponly; secure; expires=Fri, 31-Dec-2100 23:59:59 GMT; Max-Age=31536000; SameSite=strict",
            "oc_other=x; path=/; domain=.nourax.org; secure"
        ].joined(separator: ", ")
    }

    private func cookies(_ header: String? = nil) -> [HTTPCookie] {
        NCWorkspaceCookies.cookies(fromHeaderFields: ["Set-Cookie": header ?? setCookie], url: url)
    }

    @Test("A cookie name sent twice keeps the last; deletion cookies are dropped")
    func duplicatesAndDeletions() {
        let result = cookies()
        #expect(result.filter { $0.name == "ocabcdefghij" }.count == 1)
        #expect(result.first { $0.name == "ocabcdefghij" }?.value == "newsession")
        #expect(result.first { $0.name == "nc_username" } == nil)
        #expect(result.map(\.name).contains("oc_sessionPassphrase"))
    }

    @Test("Every cookie is host-only for the account's host")
    func hostOnly() {
        let result = cookies()
        #expect(!result.isEmpty)
        #expect(result.allSatisfy { $0.domain == "drive.nourax.org" })
        // The server's Domain attribute is gone
        #expect(result.first { $0.name == "oc_other" }?.domain == "drive.nourax.org")
    }

    @Test("Path, Secure, HttpOnly and SameSite stay; the __Host- cookies keep Secure and Path=/")
    func attributesStay() {
        let result = cookies()
        let session = result.first { $0.name == "ocabcdefghij" }
        #expect(session?.isSecure == true)
        #expect(session?.isHTTPOnly == true)
        #expect(session?.path == "/")
        #expect(session?.sameSitePolicy == HTTPCookieStringPolicy.sameSiteLax)
        for name in ["__Host-nc_sameSiteCookielax", "__Host-nc_sameSiteCookiestrict"] {
            let cookie = result.first { $0.name == name }
            #expect(cookie?.isSecure == true, "\(name)")
            #expect(cookie?.path == "/", "\(name)")
        }
    }

    @Test("A complete session has the passphrase cookie and a session cookie")
    func completeSession() {
        #expect(NCWorkspaceCookies.isCompleteSession(cookies()))
        let withoutPassphrase = cookies("ocabcdefghij=s; path=/; secure; HttpOnly")
        #expect(!NCWorkspaceCookies.isCompleteSession(withoutPassphrase))
        let onlyPassphrase = cookies("oc_sessionPassphrase=p; path=/; secure; HttpOnly")
        #expect(!NCWorkspaceCookies.isCompleteSession(onlyPassphrase))
        #expect(!NCWorkspaceCookies.isCompleteSession([]))
    }

    // MARK: - The answer to the sign-in request

    private func response(_ status: Int, cookies header: String? = nil) -> HTTPURLResponse {
        var fields = ["Content-Type": "application/json"]
        if let header { fields["Set-Cookie"] = header }
        return HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: fields)!
    }

    private func body(_ id: String) -> Data {
        Data(#"{"ocs":{"meta":{"status":"ok","statuscode":200,"message":"OK"},"data":{"id":"\#(id)","enabled":true}}}"#.utf8)
    }

    @Test("The answer for the account's user with a complete session is accepted")
    func accepted() throws {
        let result = try NCWorkspaceSession.sessionCookies(data: body("citest"), response: response(200, cookies: setCookie),
                                                           url: url, userId: "citest")
        #expect(NCWorkspaceCookies.isCompleteSession(result))
    }

    @Test("Anything else is refused")
    func refused() {
        #expect(throws: NCWorkspaceSessionError.redirected) {
            try NCWorkspaceSession.sessionCookies(data: Data(), response: response(302, cookies: setCookie), url: url, userId: "citest")
        }
        #expect(throws: NCWorkspaceSessionError.badResponse(401)) {
            try NCWorkspaceSession.sessionCookies(data: Data(), response: response(401), url: url, userId: "citest")
        }
        #expect(throws: NCWorkspaceSessionError.badResponse(429)) {
            try NCWorkspaceSession.sessionCookies(data: Data(), response: response(429), url: url, userId: "citest")
        }
        #expect(throws: NCWorkspaceSessionError.wrongUser) {
            try NCWorkspaceSession.sessionCookies(data: body("someone-else"), response: response(200, cookies: setCookie), url: url, userId: "citest")
        }
        #expect(throws: NCWorkspaceSessionError.wrongUser) {
            try NCWorkspaceSession.sessionCookies(data: Data("{}".utf8), response: response(200, cookies: setCookie), url: url, userId: "citest")
        }
        #expect(throws: NCWorkspaceSessionError.incompleteSession) {
            try NCWorkspaceSession.sessionCookies(data: body("citest"), response: response(200), url: url, userId: "citest")
        }
        #expect(throws: NCWorkspaceSessionError.incompleteSession) {
            try NCWorkspaceSession.sessionCookies(data: body("citest"),
                                                  response: response(200, cookies: "ocabcdefghij=s; path=/; secure"),
                                                  url: url, userId: "citest")
        }
    }

    // MARK: - The request

    private func credentials(base: String) -> NCWorkspaceSession.Credentials {
        NCWorkspaceSession.Credentials(account: "citest \(base)", base: base, userId: "citest",
                                       authorization: "Basic dGVzdDp0ZXN0", userAgent: "Mozilla/5.0 (iOS) Test")
    }

    @Test("The sign-in request goes to the account's own server with the app's usual headers, and nothing else")
    func request() throws {
        let request = try #require(NCWorkspaceSession.apiRequest(path: "ocs/v2.php/cloud/user", query: "format=json",
                                                                 credentials: credentials(base: "https://drive.nourax.org")))
        #expect(request.url?.absoluteString == "https://drive.nourax.org/ocs/v2.php/cloud/user?format=json")
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Basic dGVzdDp0ZXN0")
        #expect(request.value(forHTTPHeaderField: "OCS-APIRequest") == "true")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
        #expect(request.httpShouldHandleCookies == false)
    }

    @Test("A base that is not a web address gets no request, so no credential can be sent")
    func noRequestForOtherBase() {
        #expect(NCWorkspaceSession.apiRequest(path: "ocs", query: "x=1", credentials: credentials(base: "ftp://drive.nourax.org")) == nil)
        #expect(NCWorkspaceSession.apiRequest(path: "ocs", query: "x=1", credentials: credentials(base: "")) == nil)
        #expect(NCWorkspaceSession.apiRequest(path: "ocs", query: "x=1", credentials: credentials(base: "https://user@drive.nourax.org")) == nil)
    }
}
