// SPDX-FileCopyrightText: 2026 Nourax
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import NextcloudKit

/// Asks the Drive about one name. A protocol, so the tests can answer without a server.
protocol NCRemoteProbe {
    func state(of serverUrlFileName: String, account: String) async -> NCConflictRemoteState
}

/// PROPFIND Depth 0 for `getcontentlength`, `resourcetype` and `oc:size`, with the account's own session.
/// 404 is "missing", every other error is "unknown" (never a guess).
struct NCWebDAVProbe: NCRemoteProbe {
    // tools/ci/server_round3_check.py reads this body between the two markers and sends exactly this text to a
    // real Nextcloud 35 in CI, so keep the markers.
    // PROPFIND-BODY-BEGIN
    static let requestBodyText = """
    <?xml version="1.0"?>
    <d:propfind xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns">
    <d:prop><d:getcontentlength/><d:resourcetype/><oc:size/></d:prop>
    </d:propfind>
    """
    // PROPFIND-BODY-END

    func state(of serverUrlFileName: String, account: String) async -> NCConflictRemoteState {
        let results = await NextcloudKit.shared.readFileOrFolderAsync(serverUrlFileName: serverUrlFileName,
                                                                      depth: "0",
                                                                      requestBody: Self.requestBodyText.data(using: .utf8),
                                                                      account: account)
        if results.error == .success {
            guard let data = results.responseData?.data else { return .unknown }
            return NCPropfindSizeParser.parse(data)
        }
        return results.error.errorCode == 404 ? .missing : .unknown
    }
}

/// Reads the answer of the PROPFIND above (namespace aware, the first response only).
///
/// Nextcloud answers 207 with one `d:propstat` per status. A file has `getcontentlength` in the 200 propstat. A
/// folder has `d:collection` in `d:resourcetype` and reports `getcontentlength` as "not found" (404 propstat).
enum NCPropfindSizeParser {
    static func parse(_ data: Data) -> NCConflictRemoteState {
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = delegate
        _ = parser.parse()
        // The parser is stopped after the first response, which makes parse() return false: only an answer that
        // did not reach the end of its first response is unreadable.
        guard delegate.finishedFirstResponse else { return .unknown }
        if delegate.isCollection { return .folder }
        if let length = delegate.contentLength,
           let size = Int64(length.trimmingCharacters(in: .whitespacesAndNewlines)),
           size >= 0 {
            return .file(size: size)
        }
        return .unknown
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        private var path: [String] = []
        private var text = ""
        private var responses = 0
        private var propstatOk = false
        private var collectionInPropstat = false
        private var lengthInPropstat: String?

        var finishedFirstResponse = false
        var isCollection = false
        var contentLength: String?

        private static func qualified(_ elementName: String, _ namespaceURI: String?) -> String {
            "{" + (namespaceURI ?? "") + "}" + elementName
        }

        func parser(_ parser: XMLParser,
                    didStartElement elementName: String,
                    namespaceURI: String?,
                    qualifiedName qName: String?,
                    attributes attributeDict: [String: String] = [:]) {
            let name = Self.qualified(elementName, namespaceURI)
            path.append(name)
            text = ""
            switch name {
            case "{DAV:}response":
                responses += 1
            case "{DAV:}propstat":
                propstatOk = false
                collectionInPropstat = false
                lengthInPropstat = nil
            case "{DAV:}collection":
                if responses == 1, path.contains("{DAV:}resourcetype") {
                    collectionInPropstat = true
                }
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            text += string
        }

        func parser(_ parser: XMLParser,
                    didEndElement elementName: String,
                    namespaceURI: String?,
                    qualifiedName qName: String?) {
            let name = Self.qualified(elementName, namespaceURI)
            let parent = path.dropLast().last
            defer { if !path.isEmpty { path.removeLast() } }
            guard responses == 1 else { return }
            switch name {
            case "{DAV:}getcontentlength":
                lengthInPropstat = text
            case "{DAV:}status":
                if parent == "{DAV:}propstat" {
                    propstatOk = Self.statusCode(text) == 200
                }
            case "{DAV:}propstat":
                // The status element comes after the prop element, so a propstat is read when it ends.
                if propstatOk {
                    if collectionInPropstat { isCollection = true }
                    if let lengthInPropstat { contentLength = lengthInPropstat }
                }
            case "{DAV:}response":
                finishedFirstResponse = true
                parser.abortParsing()
            default:
                break
            }
        }

        private static func statusCode(_ status: String) -> Int? {
            // "HTTP/1.1 200 OK"
            let parts = status.split(separator: " ")
            guard parts.count >= 2 else { return nil }
            return Int(parts[1])
        }
    }
}
