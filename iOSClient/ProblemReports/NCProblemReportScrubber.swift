// SPDX-FileCopyrightText: 2026 Nourax
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Removes secrets from the text of a problem report (logs, crash text, the user's note) before it is zipped.
/// Always applied; running it twice changes nothing more. File and folder names are kept on purpose: they are
/// needed to find the problem, and the "What's included" screen says so.
enum NCProblemReportScrubber {
    private struct Rule {
        let regex: NSRegularExpression
        let template: String
    }

    private static func rule(_ pattern: String, _ template: String, options: NSRegularExpression.Options = []) -> Rule {
        // The patterns are constants of this file: a typo is a programming error found by the unit tests.
        Rule(regex: try! NSRegularExpression(pattern: pattern, options: options), template: template) // swiftlint:disable:this force_try
    }

    /// PEM private-key blocks, also one that was cut off (a log size limit) before its end line.
    private static let privateKeyBlock = rule(
        #"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----"#, "<private-key>")
    private static let privateKeyCut = rule(
        #"-----BEGIN [A-Z ]*PRIVATE KEY-----(?:[A-Za-z0-9+/=]+[ \t]*\r?\n?)*"#, "<private-key>")

    /// Session cookies by name: `oc_sessionPassphrase`, `nc_session_id`, `__Host-*` and the instance cookie
    /// `oc<instance id>`. Name and value go.
    private static let sessionCookies = rule(
        #"(?<![A-Za-z0-9_])(?:oc_sessionPassphrase|nc_session_id|__Host-[A-Za-z0-9_\-]+|oc[a-z0-9]{8,})=[^\s;,"']*"#, "<cookie>")

    /// `Authorization: ...` and `Cookie: ...` / `Set-Cookie: ...`, as a header line or as a dictionary entry.
    /// A value that is already the marker (and ends there) is left alone, so a second pass does not eat the rest of
    /// a dictionary line such as `"Authorization": <removed>, "OCS-APIRequest": "true"`.
    private static let authorizationHeader = rule(
        #"((?<![A-Za-z0-9_])["']?(?:Proxy-)?Authorization["']?[ \t]*[:=][ \t]*)("[^"\r\n]*"|'[^'\r\n]*'|<removed>(?=[,\]]|[ \t]*(?:\r|\n|$))|[^\r\n]*)"#,
        "$1<removed>", options: [.caseInsensitive])
    private static let cookieHeader = rule(
        #"((?<![A-Za-z0-9_])["']?(?:Set-)?Cookie["']?[ \t]*[:=][ \t]*)("[^"\r\n]*"|'[^'\r\n]*'|<cookie>(?=[,\]]|[ \t]*(?:\r|\n|$))|[^\r\n]*)"#,
        "$1<cookie>", options: [.caseInsensitive])

    /// `Basic <base64>` and `Bearer <token>` outside a header line.
    private static let basicValue = rule(#"(?<![A-Za-z0-9_])(Basic)[ \t]+[A-Za-z0-9\-._~+/]{10,}=*"#, "$1 <removed>")
    private static let bearerValue = rule(
        #"(?<![A-Za-z0-9_])(Bearer)[ \t]+[A-Za-z0-9\-._~+/]{6,}=*"#, "$1 <removed>", options: [.caseInsensitive])

    /// Values of the end-to-end encryption material in JSON or `key = value` text.
    private static let e2eeFields = rule(
        #"((?<![A-Za-z0-9])["']?(?:privateKey|private_key|mnemonic|passphrase|metadataKey|metadata_key|encryptedKey|encrypted_key|encryptedMetadataKey)["']?[ \t]*[:=][ \t]*)("[^"\r\n]*"|'[^'\r\n]*'|[^\s,;&}\]]+)"#,
        "$1<removed>", options: [.caseInsensitive])

    /// Plain secrets in `key = value` text.
    private static let secretFields = rule(
        #"((?<![A-Za-z0-9])["']?(?:password|passwd|app_?password|secret|access_token|refresh_token|token)["']?[ \t]*[:=][ \t]*)("[^"\r\n]*"|'[^'\r\n]*'|[^\s,;&}\]]+)"#,
        "$1<removed>", options: [.caseInsensitive])

    /// Values of URL query parameters with these names (any case).
    private static let queryValues = rule(
        #"([?&;](?:token|password|pass|secret|key|sig|code|state)=)[^&\s"'#]*"#, "$1<removed>", options: [.caseInsensitive])

    /// App passwords in the form `xxxxx-xxxxx-xxxxx-xxxxx-xxxxx`, and any run of 32 or more letters and digits.
    private static let appPasswordGroups = rule(
        #"(?<![A-Za-z0-9])[A-Za-z0-9]{5}(?:-[A-Za-z0-9]{5}){4}(?![A-Za-z0-9])"#, "<secret>")
    private static let longSecret = rule(#"(?<![A-Za-z0-9])[A-Za-z0-9]{32,}(?![A-Za-z0-9])"#, "<secret>")

    /// Long base64 runs (64 or more characters). A run that is mostly slashes is a path and is kept.
    private static let base64Run = try! NSRegularExpression(pattern: #"[A-Za-z0-9+/]{64,}={0,2}"#) // swiftlint:disable:this force_try

    /// `name@host.tld`, and the URL-encoded form `name%40host.tld` (login links, `?user=jane%40example.com`, DAV paths).
    /// The name is at most 64 characters, so a long run of name characters costs a few steps per position, not a scan
    /// to its end.
    private static let email = rule(#"[A-Za-z0-9._%+\-]{1,64}(?:@|%40)[A-Za-z0-9\-]+(?:\.[A-Za-z0-9\-]+)+"#, "<email>")

    /// Rules in the order they must run: cookies and headers before the generic secret shapes.
    private static let rules: [Rule] = [
        privateKeyBlock, privateKeyCut, sessionCookies, authorizationHeader, cookieHeader,
        basicValue, bearerValue, e2eeFields, secretFields, queryValues
    ]

    static func scrub(_ text: String) -> String {
        var result = text
        for rule in rules {
            result = apply(rule, to: result)
        }
        result = replaceBase64Runs(in: result)
        result = apply(appPasswordGroups, to: result)
        result = apply(longSecret, to: result)
        result = apply(email, to: result)
        return result
    }

    private static func apply(_ rule: Rule, to text: String) -> String {
        let range = NSRange(location: 0, length: (text as NSString).length)
        return rule.regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: rule.template)
    }

    private static func replaceBase64Runs(in text: String) -> String {
        let ns = text as NSString
        let matches = base64Run.matches(in: text, options: [], range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return text }
        var result = ""
        var last = 0
        for match in matches {
            let range = match.range
            result += ns.substring(with: NSRange(location: last, length: range.location - last))
            let run = ns.substring(with: range)
            let slashes = run.reduce(0) { $1 == "/" ? $0 + 1 : $0 }
            result += slashes * 20 > run.count ? run : "<removed>"
            last = range.location + range.length
        }
        result += ns.substring(from: last)
        return result
    }
}
