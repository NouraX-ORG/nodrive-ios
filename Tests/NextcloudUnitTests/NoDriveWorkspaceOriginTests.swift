// SPDX-FileCopyrightText: 2026 Nourax
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import Nextcloud

/// The Workspace web view's rules: which URLs belong to the account's own server, which pages mean the session
/// ended, and where a link goes. The credential and the session cookies are only ever for the own origin.
@Suite("NoDrive Workspace origin rules")
struct NoDriveWorkspaceOriginTests {
    let base = "https://drive.nourax.org"

    @Test("Same origin", arguments: [
        "https://drive.nourax.org/apps/mail/",
        "https://DRIVE.nourax.org/x",
        "https://drive.nourax.org:443/x",
        "https://drive.nourax.org",
        "https://drive.nourax.org/index.php/apps/mail/?x=1#top"
    ])
    func sameOrigin(candidate: String) {
        #expect(NCWorkspaceOrigin.isSameOrigin(candidate, base: base))
    }

    @Test("Other origins", arguments: [
        "https://evil.example/",
        "http://drive.nourax.org/",
        "https://drive.nourax.org:8443/",
        "https://drive.nourax.org@evil.example/",
        "https://user@drive.nourax.org/",
        "https://user:secret@drive.nourax.org/",
        "https://drive.nourax.org.evil.example/",
        "https://sub.drive.nourax.org/",
        "https://nourax.org/",
        "https://drive.nourax.org./",
        "https://drive.nourax.org\\@evil.example/",
        "javascript:alert(1)",
        "data:text/html,x",
        "file:///etc/hosts",
        "intent://x",
        "",
        "not a url"
    ])
    func otherOrigin(candidate: String) {
        #expect(!NCWorkspaceOrigin.isSameOrigin(candidate, base: base))
    }

    @Test("A server on a local address and port")
    func localServer() {
        let local = "http://10.0.2.2:8080"
        #expect(NCWorkspaceOrigin.isSameOrigin("http://10.0.2.2:8080/x", base: local))
        #expect(!NCWorkspaceOrigin.isSameOrigin("http://10.0.2.2:8081/x", base: local))
        #expect(!NCWorkspaceOrigin.isSameOrigin("https://10.0.2.2:8080/x", base: local))
    }

    @Test("A base that is not a web address matches nothing")
    func badBase() {
        #expect(!NCWorkspaceOrigin.isSameOrigin("https://drive.nourax.org/", base: ""))
        #expect(!NCWorkspaceOrigin.isSameOrigin("https://drive.nourax.org/", base: "ftp://drive.nourax.org"))
    }

    @Test("Login pages end the web session")
    func loginPaths() {
        #expect(NCWorkspaceOrigin.isLoginPath("https://drive.nourax.org/login", base: base))
        #expect(NCWorkspaceOrigin.isLoginPath("https://drive.nourax.org/index.php/login?redirect_url=%2Fapps%2Fmail", base: base))
        #expect(NCWorkspaceOrigin.isLoginPath("https://drive.nourax.org/apps/user_oidc/login/1", base: base))
        #expect(NCWorkspaceOrigin.isLoginPath("https://drive.nourax.org/index.php/apps/user_oidc/login/1", base: base))
        #expect(!NCWorkspaceOrigin.isLoginPath("https://drive.nourax.org/apps/mail/login-help", base: base))
        #expect(!NCWorkspaceOrigin.isLoginPath("https://drive.nourax.org/apps/mail/", base: base))
        #expect(!NCWorkspaceOrigin.isLoginPath("https://evil.example/login", base: base))
    }

    @Test("Login and log-out paths under a web root")
    func webRoot() {
        let root = "https://h.example/cloud"
        #expect(NCWorkspaceOrigin.isLoginPath("https://h.example/cloud/index.php/login", base: root))
        #expect(NCWorkspaceOrigin.isLoginPath("https://h.example/cloud/login", base: root))
        #expect(!NCWorkspaceOrigin.isLoginPath("https://h.example/login", base: root))
        #expect(NCWorkspaceOrigin.isLogoutPath("https://h.example/cloud/logout?requesttoken=x", base: root))
        #expect(!NCWorkspaceOrigin.isLogoutPath("https://h.example/logout", base: root))
    }

    @Test("The log-out page closes the screen")
    func logoutPaths() {
        #expect(NCWorkspaceOrigin.isLogoutPath("https://drive.nourax.org/logout?requesttoken=abc", base: base))
        #expect(NCWorkspaceOrigin.isLogoutPath("https://drive.nourax.org/index.php/logout", base: base))
        #expect(!NCWorkspaceOrigin.isLogoutPath("https://drive.nourax.org/apps/mail/logout", base: base))
        #expect(!NCWorkspaceOrigin.isLogoutPath("https://evil.example/logout", base: base))
    }

    @Test("Relative references become absolute against the account's server")
    func resolve() {
        #expect(NCWorkspaceOrigin.resolve("/apps/mail/", base: base) == "https://drive.nourax.org/apps/mail/")
        #expect(NCWorkspaceOrigin.resolve("/cloud/apps/mail/", base: "https://h.example/cloud") == "https://h.example/cloud/apps/mail/")
        #expect(NCWorkspaceOrigin.resolve("apps/mail/", base: "https://h.example/cloud") == "https://h.example/cloud/apps/mail/")
        #expect(NCWorkspaceOrigin.resolve("/x", base: "http://10.0.2.2:8080") == "http://10.0.2.2:8080/x")
        #expect(NCWorkspaceOrigin.resolve("https://evil.example/x", base: base) == "https://evil.example/x")
        #expect(NCWorkspaceOrigin.resolve("", base: base) == nil)
        #expect(!NCWorkspaceOrigin.isSameOrigin(NCWorkspaceOrigin.resolve("//evil.example/x", base: base) ?? "", base: base))
    }

    @Test("An outside menu page needs https and a plain host")
    func outsideLinks() {
        let yes = ["https://mail.nourax.org/", "https://mail.nourax.org", "HTTPS://Mail.Nourax.org/x?y=1#z",
                   "https://mail.nourax.org:8443/", "https://drive.nourax.org/apps/mail/"]
        for url in yes {
            #expect(NCWorkspaceOrigin.isOutsideLink(url), "\(url)")
        }
        let no = ["http://mail.nourax.org/", "ftp://mail.nourax.org/", "javascript:alert(1)", "data:text/html,x",
                  "mailto:a@b.example", "tel:+4912345", "file:///etc/hosts", "blob:https://mail.nourax.org/x",
                  "https://user@mail.nourax.org/", "https://user:pw@mail.nourax.org/", "https://drive.nourax.org@evil.example/",
                  "https:///x", "https://:443/", "https://", "https://mail.nourax.org\\@evil.example/", "https://mail nourax.org/",
                  "https://m\u{00E4}il.nourax.org/", "https://mail.nourax.org/\u{0}", "nodrive://x", "about:blank", ""]
        for url in no {
            #expect(!NCWorkspaceOrigin.isOutsideLink(url), "\(url)")
        }
    }

    @Test("Navigation policy of the web view")
    func navigationDecisions() {
        typealias Decision = NCWorkspaceOrigin.NavigationDecision
        let cases: [(String, Decision)] = [
            ("https://drive.nourax.org/apps/mail/", .allow),
            ("https://drive.nourax.org/index.php/apps/calendar/", .allow),
            ("https://drive.nourax.org/login?redirect_url=%2Fapps%2Fmail", .reauthenticate),
            ("https://drive.nourax.org/apps/user_oidc/login/1", .reauthenticate),
            ("https://drive.nourax.org/logout?requesttoken=x", .close),
            ("https://evil.example/", .openExternally),
            ("https://drive.nourax.org@evil.example/", .openExternally),
            ("http://drive.nourax.org/apps/mail/", .openExternally),
            ("https://drive.nourax.org:8443/apps/mail/", .openExternally),
            ("mailto:someone@example.org", .openSystem),
            ("tel:+4912345", .openSystem),
            ("about:blank", .allow),
            ("about:srcdoc", .cancel),
            ("javascript:alert(1)", .cancel),
            ("file:///etc/hosts", .cancel),
            ("data:text/html,x", .cancel),
            ("blob:https://drive.nourax.org/abc", .cancel),
            ("intent://x", .cancel),
            ("nodrive://x", .cancel),
            ("", .cancel)
        ]
        for (url, expected) in cases {
            #expect(NCWorkspaceOrigin.navigationDecision(for: url, base: base) == expected, "\(url)")
        }
    }

    @Test("Notification links")
    func notificationRoutes() {
        #expect(NCWorkspaceOrigin.route(link: "https://drive.nourax.org/apps/spreed/call/abc", base: base) == .inApp)
        #expect(NCWorkspaceOrigin.route(link: "https://drive.nourax.org/index.php/apps/files/?dir=/x", base: base) == .inApp)
        #expect(NCWorkspaceOrigin.route(link: "https://evil.example/apps/spreed", base: base) == .external)
        #expect(NCWorkspaceOrigin.route(link: "https://drive.nourax.org@evil.example/", base: base) == .external)
        #expect(NCWorkspaceOrigin.route(link: "http://drive.nourax.org/apps/spreed", base: base) == .external)
        #expect(NCWorkspaceOrigin.route(link: "nextcloudtalk://open-conversation?server=x", base: base) == .external)
        #expect(NCWorkspaceOrigin.route(link: "", base: base) == .ignore)
        #expect(NCWorkspaceOrigin.route(link: "not a url", base: base) == .ignore)
    }
}
