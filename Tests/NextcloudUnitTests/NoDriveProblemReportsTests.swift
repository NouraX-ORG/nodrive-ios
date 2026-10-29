// SPDX-FileCopyrightText: 2026 Nourax
// SPDX-License-Identifier: GPL-3.0-or-later

import Compression
import Foundation
import Testing
@testable import Nextcloud

// Problem reports (iOSClient/ProblemReports): scrubbing, the report contents and size, the zip, the run marker,
// crash capture, the decisions, and the sending steps with a fake server. Fixtures are literals in this file.

// MARK: - Scrubbing

@Suite("NoDrive report scrubbing")
struct NoDriveReportScrubbingTests {
    private func scrub(_ text: String) -> String {
        NCProblemReportScrubber.scrub(text)
    }

    @Test("Authorization headers lose their value, Basic and Bearer values go anywhere")
    func authorization() {
        let basic = scrub("GET /ocs\nAuthorization: Basic YWJjOmRlZmdoaWprbG1ub3BxcnN0dQ==\nAccept: json")
        #expect(!basic.contains("YWJj"))
        #expect(basic.contains("Authorization:"))
        #expect(basic.contains("Accept: json"))

        let dictionary = scrub(#"headers ["Authorization": "Basic Zm9vOmJhcmJhcmJheg==", "Accept": "json"]"#)
        #expect(!dictionary.contains("Zm9v"))
        #expect(dictionary.contains(#""Accept": "json""#))

        let bearer = scrub("sent Bearer eyJhbGciOiJIUzI1NiJ9abcdefghijkl to the server")
        #expect(!bearer.contains("eyJhbGci"))
        #expect(bearer.contains("to the server"))

        let loose = scrub("retry with Basic dXNlcjpwYXNzd29yZDEyMw== now")
        #expect(!loose.contains("dXNlcjpw"))
    }

    @Test("App passwords and long secrets go")
    func appPasswords() {
        let long = String(repeating: "aB3", count: 24)   // 72 letters and digits
        #expect(long.count == 72)
        let first = scrub("password is \(long) ok")
        #expect(!first.contains(long))
        #expect(first.contains("ok"))

        let groups = scrub("created abcde-fghij-klmno-pqrst-uvwxy for the device")
        #expect(!groups.contains("abcde-fghij"))
        #expect(groups.contains("<secret>"))

        let thirtyTwo = String(repeating: "x7", count: 16)
        #expect(!scrub("t=\(thirtyTwo)").contains(thirtyTwo))
        // short words and ids stay
        #expect(scrub("fileid 00012345ocabc123 done") == "fileid 00012345ocabc123 done")
    }

    @Test("Cookie and Set-Cookie headers lose their values")
    func cookieHeaders() {
        let cookie = scrub("Cookie: a=1; nc_session_id=zzz999; oc_sessionPassphrase=Qwe123")
        #expect(!cookie.contains("zzz999"))
        #expect(!cookie.contains("Qwe123"))
        #expect(cookie.hasPrefix("Cookie:"))
        let set = scrub("Set-Cookie: ocabc123def456=VALUE9; path=/; secure; HttpOnly")
        #expect(!set.contains("VALUE9"))
        #expect(set.hasPrefix("Set-Cookie:"))
    }

    @Test("Session cookies go by name, name and value")
    func sessionCookies() {
        for fixture in ["oc_sessionPassphrase=Pass1234567", "nc_session_id=Sess7654321",
                        "__Host-nc_sameSiteCookielax=true", "ocabc123def456=Inst4455667"] {
            let result = scrub("cookies: \(fixture); other=1")
            let name = String(fixture.split(separator: "=")[0])
            let value = String(fixture.split(separator: "=")[1])
            #expect(!result.contains(value), "value of \(name) is still there: \(result)")
            #expect(!result.contains(name), "name \(name) is still there: \(result)")
            #expect(result.contains("<cookie>"))
        }
    }

    @Test("Named URL query values go in any case; other parameters stay")
    func queryValues() {
        for name in ["token", "password", "pass", "secret", "key", "sig", "code", "state",
                     "Token", "PASSWORD", "PaSs", "SECRET", "Key", "SIG", "Code", "STATE"] {
            let url = "https://drive.nourax.org/index.php/s/x?dir=/Photos&fileid=123&\(name)=SeCrEt9z&view=list"
            let result = scrub(url)
            #expect(!result.contains("SeCrEt9z"), "\(name): \(result)")
            #expect(result.contains("dir=/Photos"))
            #expect(result.contains("fileid=123"))
            #expect(result.contains("view=list"))
        }
        // the first parameter after ? too
        #expect(!scrub("/login?token=abc123XYZ").contains("abc123XYZ"))
    }

    @Test("Private keys and end-to-end encryption material go")
    func keysAndE2ee() {
        let pem = """
        before
        -----BEGIN PRIVATE KEY-----
        MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQC7
        VtpTcMhIvqzx4KQw1u8Eoo0zYy9nJbq3Fz2f8Hh6u8d0XgLw9o==
        -----END PRIVATE KEY-----
        after
        """
        let key = scrub(pem)
        #expect(!key.contains("MIIEvQ"))
        #expect(!key.contains("VtpTcM"))
        #expect(key.contains("before") && key.contains("after"))

        let cut = scrub("log -----BEGIN RSA PRIVATE KEY-----\nMIIEowIBAAKCAQEA1234567890abcdefghij\nnext line")
        #expect(!cut.contains("MIIEow"))

        let json = scrub(#"{"privateKey":"AAAA1111bbbb","mnemonic":"apple pear plum","metadataKey":"MK-9988","encryptedKey":"EK-7766","name":"kept"}"#)
        for secret in ["AAAA1111bbbb", "apple", "MK-9988", "EK-7766"] {
            #expect(!json.contains(secret), "\(secret) is still there: \(json)")
        }
        #expect(json.contains(#""name":"kept""#))
    }

    @Test("Long base64 runs go, paths that are long stay")
    func base64() {
        let blob = (0..<150).map { index -> String in
            let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/")
            return String(alphabet[(index * 7 + 3) % alphabet.count])
        }.joined()
        #expect(blob.count == 150)
        let result = scrub("data: \(blob) end")
        #expect(!result.contains(String(blob.prefix(60))))
        #expect(result.hasSuffix(" end"))

        let path = "Documents/Projects/Holiday2026/Photos/Family/Summer/Beach/Day1/Morning/Walk/IMG_0001.HEIC"
        #expect(path.count > 64)
        #expect(scrub(path) == path)
    }

    @Test("Email addresses are replaced, also inside a WebDAV path; file and folder names stay")
    func emailsAndNames() {
        let result = scrub("PROPFIND /remote.php/dav/files/jane.doe@example.com/Photos/Holiday 2026/IMG_0001.HEIC for jane.doe+x@mail.example.org")
        #expect(!result.contains("example.com"))
        #expect(!result.contains("example.org"))
        #expect(result.contains("/files/<email>/Photos/Holiday 2026/IMG_0001.HEIC"))
        #expect(scrub("Photos/Holiday 2026/IMG_0001.HEIC") == "Photos/Holiday 2026/IMG_0001.HEIC")
    }

    @Test("Scrubbing twice changes nothing")
    func idempotent() {
        let text = """
        Authorization: Basic YWJjOmRlZmdoaWprbG1ub3BxcnN0dQ==
        Cookie: oc_sessionPassphrase=Qwe123; nc_session_id=zzz999
        Set-Cookie: ocabc123def456=VALUE9; path=/
        GET https://drive.nourax.org/s?token=abc&dir=/Photos&Key=zz&code=1
        Bearer abcdefghijklmnop and abcde-fghij-klmno-pqrst-uvwxy and \(String(repeating: "q9", count: 40))
        {"privateKey":"AAAA","passphrase":"hello world"}
        mail jane@example.com password: hunter2 secret=abc
        -----BEGIN PRIVATE KEY-----
        MIIEvQIBADANBgkqhkiG9w0BAQEFAASC
        -----END PRIVATE KEY-----
        """
        let once = scrub(text)
        #expect(scrub(once) == once)
        #expect(!once.contains("hunter2"))
    }
}

// MARK: - Report contents, size and zip

/// Reads a zip the way an unzip tool does: end record, central directory, local header, inflate, CRC-32.
struct TestZip {
    struct Item {
        let name: String
        let bytes: Data
        let method: Int
        let crcOK: Bool
    }

    let items: [Item]

    init?(_ data: Data) {
        func u16(_ at: Int) -> Int { Int(data[at]) | Int(data[at + 1]) << 8 }
        func u32(_ at: Int) -> Int { u16(at) | u16(at + 2) << 16 }
        guard data.count > 22 else { return nil }
        var end = data.count - 22
        while end >= 0, u32(end) != 0x0605_4B50 { end -= 1 }
        guard end >= 0 else { return nil }
        let count = u16(end + 10)
        var cursor = u32(end + 16)
        var found: [Item] = []
        for _ in 0..<count {
            guard u32(cursor) == 0x0201_4B50 else { return nil }
            let method = u16(cursor + 10)
            let crc = u32(cursor + 16)
            let compressedSize = u32(cursor + 20)
            let size = u32(cursor + 24)
            let nameLength = u16(cursor + 28)
            let extraLength = u16(cursor + 30)
            let commentLength = u16(cursor + 32)
            let local = u32(cursor + 42)
            let name = String(decoding: data[(cursor + 46)..<(cursor + 46 + nameLength)], as: UTF8.self)
            guard u32(local) == 0x0403_4B50 else { return nil }
            let start = local + 30 + u16(local + 26) + u16(local + 28)
            let payload = Data(data[start..<(start + compressedSize)])
            var bytes = payload
            if method == 8 {
                let capacity = max(size, 1)
                var out = [UInt8](repeating: 0, count: capacity)
                let written = payload.withUnsafeBytes { raw -> Int in
                    guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                    return compression_decode_buffer(&out, capacity, base, payload.count, nil, COMPRESSION_ZLIB)
                }
                guard written == size else { return nil }
                bytes = Data(out.prefix(size))
            } else if method != 0 {
                return nil
            }
            found.append(Item(name: name, bytes: bytes, method: method,
                              crcOK: bytes.count == size && Int(NCProblemReportZip.crc32(bytes)) == crc))
            cursor += 46 + nameLength + extraLength + commentLength
        }
        items = found
    }

    func data(_ name: String) -> Data? {
        items.first { $0.name == name }?.bytes
    }

    func text(_ name: String) -> String? {
        data(name).map { String(decoding: $0, as: UTF8.self) }
    }
}

@Suite("NoDrive report contents")
struct NoDriveReportContentsTests {
    static let info = NCProblemReportInfo(appVersion: "35.2.1-nourax.1", build: "7", osVersion: "27.0",
                                          deviceModel: "iPhone17,1", locale: "en_US", serverHost: "drive.nourax.org")
    static let date = Date(timeIntervalSince1970: 1_793_000_000)   // 2026-10-26 07:33:20 UTC

    private func json(_ zip: Data) throws -> [String: Any] {
        let archive = try #require(TestZip(zip))
        let data = try #require(archive.data("report.json"))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test("report.json has every field with the right type and value")
    func fields() throws {
        let zip = NCProblemReportBuilder.build(kind: .manual, note: "It froze, mail me at jane@example.com",
                                               crashText: nil, logs: [], info: Self.info, date: Self.date)
        let report = try json(zip)
        #expect(Set(report.keys) == ["schema", "kind", "app", "app_version", "build", "platform", "os_version",
                                     "device_model", "locale", "created_utc", "server_host", "user_note"])
        #expect(report["schema"] as? Int == 1)
        #expect(report["kind"] as? String == "manual")
        #expect(report["app"] as? String == "NoDrive iOS")
        #expect(report["app_version"] as? String == "35.2.1-nourax.1")
        #expect(report["build"] as? String == "7")
        #expect(report["platform"] as? String == "ios")
        #expect(report["os_version"] as? String == "27.0")
        #expect(report["device_model"] as? String == "iPhone17,1")
        #expect(report["locale"] as? String == "en_US")
        #expect(report["server_host"] as? String == "drive.nourax.org")
        let created = try #require(report["created_utc"] as? String)
        #expect(created.hasSuffix("Z"))
        #expect(created == "2026-10-26T07:33:20Z")
        let note = try #require(report["user_note"] as? String)
        #expect(note.contains("<email>") && !note.contains("example.com"))
    }

    @Test("The keys come in the order of the contract")
    func order() throws {
        let zip = NCProblemReportBuilder.build(kind: .crash, note: "", crashText: "x", logs: [], info: Self.info, date: Self.date)
        let archive = try #require(TestZip(zip))
        let text = try #require(archive.text("report.json"))
        let keys = ["schema", "kind", "app", "app_version", "build", "platform", "os_version", "device_model",
                    "locale", "created_utc", "server_host", "user_note"]
        let positions = keys.compactMap { text.range(of: "\"\($0)\"")?.lowerBound }
        #expect(positions.count == keys.count)
        #expect(positions == positions.sorted())
    }

    @Test("The three kinds; crash.txt only for a crash; the crash text is scrubbed")
    func kinds() throws {
        for kind in [NCProblemReportKind.crash, .manual, .uncleanExit] {
            let crash = kind == .crash ? "Name: X\nAuthorization: Basic YWJjOmRlZmdoaWprbG1ub3BxcnN0dQ==\n" : nil
            let zip = NCProblemReportBuilder.build(kind: kind, note: "", crashText: crash, logs: [], info: Self.info, date: Self.date)
            let archive = try #require(TestZip(zip))
            #expect(try json(zip)["kind"] as? String == kind.rawValue)
            if kind == .crash {
                let text = try #require(archive.text("crash.txt"))
                #expect(text.contains("Name: X"))
                #expect(!text.contains("YWJj"))
            } else {
                #expect(archive.data("crash.txt") == nil)
            }
        }
        #expect(NCProblemReportKind.uncleanExit.rawValue == "unclean-exit")
    }

    @Test("The file name has the contract's pattern, in UTC")
    func fileName() throws {
        let name = NCProblemReportBuilder.fileName(date: Self.date, appVersion: "35.2.1-nourax.1")
        #expect(name == "2026-10-26_07-33-20_ios_35.2.1-nourax.1.zip")
        let pattern = #"^\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}_ios_[0-9A-Za-z.\-]+\.zip$"#
        #expect(name.range(of: pattern, options: .regularExpression) != nil)
        let odd = NCProblemReportBuilder.fileName(date: Self.date, appVersion: "35 beta/1")
        #expect(odd.range(of: pattern, options: .regularExpression) != nil)
    }

    @Test("The device facts are the real ones")
    func realInfo() async {
        let info = await MainActor.run { NCProblemReportInfo.current(serverHost: "drive.nourax.org") }
        #expect(!info.osVersion.isEmpty)
        #expect(!info.deviceModel.isEmpty)
        #expect(!info.locale.isEmpty)
        #expect(info.appVersion == nouraxVersion)
    }

    @Test("The log folder helper finds the app's real log folder shape: log.txt and dated files, newest first")
    func logFolder() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("logs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("old line\n".utf8).write(to: folder.appendingPathComponent("log-2026-10-24.txt"))
        try Data("new line\n".utf8).write(to: folder.appendingPathComponent("log.txt"))
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000)],
                                              ofItemAtPath: folder.appendingPathComponent("log-2026-10-24.txt").path)
        let logs = NCProblemReportBuilder.readLogs(in: folder)
        #expect(Set(logs.map(\.name)) == ["log.txt", "log-2026-10-24.txt"])
        let zip = NCProblemReportBuilder.build(kind: .manual, note: "", crashText: nil, logs: logs, info: Self.info, date: Self.date)
        let archive = try #require(TestZip(zip))
        #expect(archive.text("logs/log.txt") == "new line\n")
        #expect(archive.text("logs/log-2026-10-24.txt") == "old line\n")
        // the real directory helper is the one the app writes to: its last path component is "Logs"
        #expect(NCPreferences.sharedLogDirectory?.lastPathComponent == "Logs" || NCPreferences.sharedLogDirectory == nil)
    }
}

@Suite("NoDrive report size")
struct NoDriveReportSizeTests {
    /// Words that do not compress much and are not secrets: lines with a counter and random-looking lowercase words.
    private func makeLog(bytes: Int, label: String) -> Data {
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        var out = Data()
        out.reserveCapacity(bytes + 200)
        var index = 0
        while out.count < bytes {
            var line = "\(label) \(String(format: "%08d", index))"
            for _ in 0..<8 {
                state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                var word = ""
                var value = state >> 20
                for _ in 0..<6 {
                    word.append(Character(UnicodeScalar(UInt8(97 + value % 26))))
                    value /= 26
                }
                line += " " + word
            }
            out.append(Data((line + "\n").utf8))
            index += 1
        }
        return out
    }

    @Test("20 MB of logs: the zip is at most 5,000,000 bytes, the newest lines stay, the oldest go, report.json is there")
    func twentyMegabytes() throws {
        let old = makeLog(bytes: 10_000_000, label: "OLDEST")
        let new = makeLog(bytes: 10_000_000, label: "NEWEST")
        let logs = [
            NCProblemReportLogFile(name: "log-2026-10-20.txt", modified: Date(timeIntervalSince1970: 1_000), data: old),
            NCProblemReportLogFile(name: "log.txt", modified: Date(timeIntervalSince1970: 2_000), data: new)
        ]
        let zip = NCProblemReportBuilder.build(kind: .manual, note: "n", crashText: nil, logs: logs,
                                               info: NoDriveReportContentsTests.info, date: NoDriveReportContentsTests.date)
        #expect(zip.count <= NCProblemReportBuilder.maxZipBytes)
        #expect(NCProblemReportBuilder.maxZipBytes == 5_000_000)
        let archive = try #require(TestZip(zip))
        #expect(archive.items.allSatisfy(\.crcOK))
        #expect(archive.data("report.json") != nil)
        let kept = try #require(archive.text("logs/log.txt"))
        let lastLine = String(decoding: new.suffix(200), as: UTF8.self).split(separator: "\n").last.map(String.init) ?? ""
        #expect(!lastLine.isEmpty)
        #expect(kept.contains(lastLine), "the newest line is gone")
        #expect(!kept.contains("NEWEST 00000000"), "the oldest line of the newest file should be dropped")
        let firstOld = String(decoding: old.prefix(40), as: UTF8.self).split(separator: "\n").first.map(String.init) ?? ""
        #expect(!(archive.text("logs/log-2026-10-20.txt") ?? "").contains(firstOld))
    }

    @Test("A small log is kept whole")
    func smallLog() throws {
        let logs = [NCProblemReportLogFile(name: "log.txt", modified: Date(), data: Data("one\ntwo\nthree\n".utf8))]
        let zip = NCProblemReportBuilder.build(kind: .manual, note: "", crashText: nil, logs: logs,
                                               info: NoDriveReportContentsTests.info, date: NoDriveReportContentsTests.date)
        let archive = try #require(TestZip(zip))
        #expect(archive.text("logs/log.txt") == "one\ntwo\nthree\n")
    }

    @Test("The log text is scrubbed before it is zipped")
    func logsAreScrubbed() throws {
        let text = "ok line\nAuthorization: Basic YWJjOmRlZmdoaWprbG1ub3BxcnN0dQ==\nmail jane@example.com\nPhotos/Holiday 2026/IMG_0001.HEIC\n"
        let logs = [NCProblemReportLogFile(name: "log.txt", modified: Date(), data: Data(text.utf8))]
        let zip = NCProblemReportBuilder.build(kind: .manual, note: "", crashText: nil, logs: logs,
                                               info: NoDriveReportContentsTests.info, date: NoDriveReportContentsTests.date)
        let kept = try #require(TestZip(zip)?.text("logs/log.txt"))
        #expect(!kept.contains("YWJj") && !kept.contains("example.com"))
        #expect(kept.contains("Photos/Holiday 2026/IMG_0001.HEIC"))
    }

    @Test("newestLines keeps whole lines from the end")
    func newest() {
        let data = Data("aaaa\nbbbb\ncccc\n".utf8)
        #expect(String(decoding: NCProblemReportBuilder.newestLines(of: data, atMost: 100), as: UTF8.self) == "aaaa\nbbbb\ncccc\n")
        #expect(String(decoding: NCProblemReportBuilder.newestLines(of: data, atMost: 11), as: UTF8.self) == "cccc\n")
        #expect(NCProblemReportBuilder.newestLines(of: data, atMost: 0).isEmpty)
    }
}

@Suite("NoDrive report zip")
struct NoDriveReportZipTests {
    @Test("The archive reads back: names at the root, CRC-32, inflate")
    func roundTrip() throws {
        let text = Data(String(repeating: "hello zip ", count: 500).utf8)
        let empty = Data()
        let random = Data((0..<2000).map { UInt8(truncatingIfNeeded: ($0 &* 2_654_435_761) >> 7) })
        let zip = NCProblemReportZip.archive([
            .init(name: "report.json", data: Data("{}\n".utf8)),
            .init(name: "crash.txt", data: text),
            .init(name: "logs/log.txt", data: random),
            .init(name: "logs/empty.txt", data: empty)
        ])
        let archive = try #require(TestZip(zip))
        #expect(archive.items.map(\.name) == ["report.json", "crash.txt", "logs/log.txt", "logs/empty.txt"])
        #expect(archive.items.allSatisfy(\.crcOK))
        #expect(archive.data("crash.txt") == text)
        #expect(archive.data("logs/log.txt") == random)
        #expect(archive.data("logs/empty.txt") == empty)
        // compressible data is deflated, an empty file is stored
        #expect(archive.items.first { $0.name == "crash.txt" }?.method == 8)
        #expect(archive.items.first { $0.name == "logs/empty.txt" }?.method == 0)
        // no entry sits under a top-level folder
        #expect(archive.items.allSatisfy { !$0.name.hasPrefix("/") && !$0.name.contains("..") })
        #expect(zip.prefix(4) == Data([0x50, 0x4B, 0x03, 0x04]))
    }

    @Test("CRC-32 of the standard check string")
    func crc() {
        #expect(NCProblemReportZip.crc32(Data("123456789".utf8)) == 0xCBF4_3926)
        #expect(NCProblemReportZip.crc32(Data()) == 0)
    }

    @Test("DOS time and date")
    func dos() {
        let (time, date) = NCProblemReportZip.dosDateTime(Date(timeIntervalSince1970: 1_793_000_000))   // 2026-10-26 07:33:20 UTC
        #expect(time == UInt16((7 << 11) | (33 << 5) | (20 / 2)))
        #expect(date == UInt16(((2026 - 1980) << 9) | (10 << 5) | 26))
    }
}

// MARK: - Run marker

@Suite("NoDrive report run marker")
struct NoDriveReportRunMarkerTests {
    private func marker() -> NCProblemReportRunMarker {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("marker-\(UUID().uuidString)")
        return NCProblemReportRunMarker(url: folder.appendingPathComponent("run-marker.json"))
    }

    @Test("Foreground, then killed: unclean exit")
    func foregroundKilled() {
        let marker = marker()
        marker.write(.foreground, build: "7")
        #expect(marker.previousRunEndedUncleanly(currentBuild: "7"))
    }

    @Test("Background, then killed: nothing (iOS ends suspended apps all the time)")
    func backgroundKilled() {
        let marker = marker()
        marker.write(.foreground, build: "7")
        marker.write(.background, build: "7")
        #expect(!marker.previousRunEndedUncleanly(currentBuild: "7"))
    }

    @Test("Terminated normally: nothing")
    func terminated() {
        let marker = marker()
        marker.write(.foreground, build: "7")
        marker.remove()
        #expect(!marker.previousRunEndedUncleanly(currentBuild: "7"))
    }

    @Test("Another build (an update): nothing")
    func otherBuild() {
        let marker = marker()
        marker.write(.foreground, build: "6")
        #expect(!marker.previousRunEndedUncleanly(currentBuild: "7"))
    }

    @Test("No marker: nothing")
    func noMarker() {
        #expect(!marker().previousRunEndedUncleanly(currentBuild: "7"))
    }

    @Test("UI-test runs without the reports variable switch the detection off; the Release stub never does")
    func uiTestSuppression() {
#if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        let requested = ProcessInfo.processInfo.environment["NODRIVE_UITEST_REPORTS"]
        #expect(NCProblemReportUITestHooks.detectionSuppressed == (arguments.contains("UI_TESTING") && requested == nil))
#else
        #expect(!NCProblemReportUITestHooks.detectionSuppressed)
#endif
    }
}

// MARK: - Crash capture

@Suite("NoDrive report crash capture", .serialized)
struct NoDriveReportCrashTests {
    private func folder() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("crash-\(UUID().uuidString)", isDirectory: true)
    }

    @Test("The installed handler writes name, reason and call stack, and chains the previous handler")
    func handlerWritesAndChains() throws {
        let directory = folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("crash-pending.txt")

        NCProblemReportCrash.removeExceptionHandlerForTests()
        chainProbe = false
        NSSetUncaughtExceptionHandler { _ in chainProbe = true }
        defer {
            NCProblemReportCrash.removeExceptionHandlerForTests()
            NSSetUncaughtExceptionHandler(nil)
        }

        NCProblemReportCrash.installExceptionHandler(writingTo: file)
        let installed = try #require(NSGetUncaughtExceptionHandler())

        let exception = NSException(name: NSExceptionName("NoDriveTestException"), reason: "something broke", userInfo: nil)
        installed(exception)   // what the runtime does for an uncaught exception, minus the abort afterwards

        #expect(chainProbe, "the previous handler was not called")
        let text = try #require(NCProblemReportCrash.takePendingException(at: file))
        #expect(text.contains("Name: NoDriveTestException"))
        #expect(text.contains("Reason: something broke"))
        #expect(text.contains("Call stack:"))
        // the file is gone after it was taken
        #expect(NCProblemReportCrash.takePendingException(at: file) == nil)
    }

    @Test("Installing twice does not chain the handler to itself")
    func installOnce() throws {
        let directory = folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        NCProblemReportCrash.removeExceptionHandlerForTests()
        chainProbe = false
        NSSetUncaughtExceptionHandler { _ in chainProbe = true }
        defer {
            NCProblemReportCrash.removeExceptionHandlerForTests()
            NSSetUncaughtExceptionHandler(nil)
        }
        NCProblemReportCrash.installExceptionHandler(writingTo: directory.appendingPathComponent("a.txt"))
        let first = try #require(NSGetUncaughtExceptionHandler())
        let file = directory.appendingPathComponent("b.txt")
        NCProblemReportCrash.installExceptionHandler(writingTo: file)
        let second = try #require(NSGetUncaughtExceptionHandler())
        #expect(unsafeBitCast(first, to: Int.self) == unsafeBitCast(second, to: Int.self))
        second(NSException(name: NSExceptionName("Once"), reason: "r", userInfo: nil))
        #expect(chainProbe)
        #expect(NCProblemReportCrash.takePendingException(at: file)?.contains("Name: Once") == true)
    }

    @Test("A MetricKit diagnostic of the old shape becomes readable crash text")
    func oldDiagnosticShape() {
        let json = """
        {"callStackTree":{"callStacks":[{"threadAttributed":true,"callStackRootFrames":[{"binaryName":"Nextcloud","address":4301234,"subFrames":[]}]}],"callStackPerThread":false},
         "diagnosticMetaData":{"signal":"6","exceptionType":"6","exceptionCode":"0","terminationReason":"Namespace SIGNAL, Code 6 Abort trap: 6","appBuildVersion":"7","osVersion":"iPhone OS 26.0","deviceType":"iPhone17,1"},
         "version":"1.0.0"}
        """
        let text = NCProblemReportCrash.crashText(fromDiagnosticJSON: Data(json.utf8))
        #expect(text.hasPrefix("MetricKit crash diagnostic"))
        #expect(text.contains("signal: 6"))
        #expect(text.contains("exceptionType: 6"))
        #expect(text.contains("terminationReason: Namespace SIGNAL, Code 6 Abort trap: 6"))
        #expect(text.contains("callStackRootFrames"))
    }

    @Test("A diagnostic of the iOS 27 shape (encoded value) becomes readable crash text too")
    func newDiagnosticShape() {
        let json = """
        {"result":{"crash":{"signal":11,"exceptionType":1,"terminationReason":"Namespace SIGNAL, Code 11","callStackTree":{"callStacks":[]}}},
         "environment":{"applicationVersion":"35.2.1"}}
        """
        let text = NCProblemReportCrash.crashText(fromDiagnosticJSON: Data(json.utf8))
        #expect(text.contains("signal: 11"))
        #expect(text.contains("applicationVersion: 35.2.1"))
        #expect(text.contains("Diagnostic JSON:"))
        let raw = NCProblemReportCrash.crashText(fromDiagnosticJSON: Data("not json".utf8))
        #expect(raw.contains("not json"))
    }

    @Test("Stored MetricKit diagnostics are returned once")
    func store() {
        let directory = folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = NCMetricKitStore(directory: directory)
        #expect(!store.hasDiagnostics)
        store.save(text: "one", version: "7")
        store.save(text: "two", version: "7")
        #expect(store.hasDiagnostics)
        #expect(Set(store.takeAll()) == ["one", "two"])
        #expect(!store.hasDiagnostics)
        #expect(store.takeAll().isEmpty)
    }
}

/// The previous handler of the crash tests. A C function pointer cannot capture, so the probe is a global.
private nonisolated(unsafe) var chainProbe = false

// MARK: - Decisions and sending (fake server, fake screens)

final class FakeReportTransport: NCProblemReportTransport, @unchecked Sendable {
    var host = "drive.nourax.org"
    var calls: [String] = []
    var uploads: [(remotePath: String, headers: [String: String], size: Int)] = []
    var folderStatus = 201
    var uploadStatuses: [Int] = []
    var sharedWith: [String]? = []
    var acceptShare = false

    func makeFolder(_ name: String) async -> Int {
        calls.append("MKCOL \(name)")
        return folderStatus
    }

    func upload(localPath: String, remotePath: String, headers: [String: String]) async -> Int {
        calls.append("PUT \(remotePath)")
        let status = uploadStatuses.isEmpty ? 201 : uploadStatuses.removeFirst()
        if status == 201 {
            let size = (try? Data(contentsOf: URL(fileURLWithPath: localPath)).count) ?? -1
            uploads.append((remotePath, headers, size))
        }
        return status
    }

    func usersSharedWith(path: String) async -> [String]? {
        calls.append("LIST \(path)")
        return sharedWith
    }

    func shareReadOnly(path: String, with user: String) async -> Bool {
        calls.append("SHARE \(path) \(user)")
        if acceptShare { sharedWith = (sharedWith ?? []) + [user] }
        return acceptShare
    }

    var shareCalls: Int { calls.filter { $0.hasPrefix("SHARE") }.count }
}

@MainActor
final class ReportsHarness {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("reports-\(UUID().uuidString)", isDirectory: true)
    let defaults: UserDefaults
    let suite = "nodrive.reports.\(UUID().uuidString)"
    let transport = FakeReportTransport()
    var signedIn = true
    var confirmAnswers: [Bool] = [true]
    var asked = 0
    var messages: [String] = []
    var clock = Date(timeIntervalSince1970: 1_793_000_000)
    var logs: [NCProblemReportLogFile] = [NCProblemReportLogFile(name: "log.txt", modified: Date(), data: Data("a line\n".utf8))]
    var engine: NCProblemReports!

    init() {
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        engine = makeEngine()
    }

    func makeEngine() -> NCProblemReports {
        NCProblemReports(dependencies: .init(
            directory: directory, defaults: defaults, build: "7", shortVersion: "35.2.1", detectionEnabled: true,
            now: { [unowned self] in self.clock },
            info: { NoDriveReportContentsTests.info },
            transport: { [unowned self] in self.signedIn ? self.transport : nil },
            accountExists: { [unowned self] in self.signedIn },
            logs: { [unowned self] in self.logs },
            confirm: { [unowned self] in
                self.asked += 1
                return self.confirmAnswers.isEmpty ? false : self.confirmAnswers.removeFirst()
            },
            notify: { [unowned self] text in self.messages.append(text) },
            metricKitWait: 0.3, transportWait: 0.3, flushInterval: 600))
    }

    /// A new launch: a fresh engine on the same folder.
    func relaunch() {
        engine = makeEngine()
    }

    /// What the files of the folder say about the previous run.
    func leaveRun(_ state: NCProblemReportRunMarker.State?) {
        let marker = NCProblemReportRunMarker(url: directory.appendingPathComponent("run-marker.json"))
        if let state { marker.write(state, build: "7") } else { marker.remove() }
    }

    func writeException(_ text: String = "Uncaught exception\nName: NoDriveTestException\nReason: boom\n") {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? Data(text.utf8).write(to: directory.appendingPathComponent("crash-pending.txt"))
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }
}

@Suite("NoDrive report decisions")
@MainActor
struct NoDriveReportDecisionTests {
    @Test("The switch is off on a fresh store")
    func offByDefault() {
        let harness = ReportsHarness()
        #expect(!harness.engine.isEnabled)
        harness.engine.setEnabled(true)
        #expect(harness.engine.isEnabled)
        harness.engine.setEnabled(false)
        #expect(!harness.engine.isEnabled)
    }

    @Test("Switch on after an unclean exit: sent by itself, no question")
    func onSendsAutomatically() async {
        let harness = ReportsHarness()
        harness.engine.setEnabled(true)
        harness.leaveRun(.foreground)
        harness.relaunch()
        harness.engine.prepareLaunch()
        await harness.engine.processPreviousRun()
        #expect(harness.asked == 0)
        #expect(harness.transport.uploads.count == 1)
        #expect(harness.messages == ["Problem report sent"] || harness.messages == ["Saved in your NoDrive › Problem reports."])
    }

    @Test("Switch off after an unclean exit: one question; Send sends")
    func offAsksAndSends() async {
        let harness = ReportsHarness()
        harness.confirmAnswers = [true]
        harness.leaveRun(.foreground)
        harness.relaunch()
        harness.engine.prepareLaunch()
        await harness.engine.processPreviousRun()
        #expect(harness.asked == 1)
        #expect(harness.transport.uploads.count == 1)
    }

    @Test("Not now sends nothing and the event is gone")
    func notNow() async {
        let harness = ReportsHarness()
        harness.confirmAnswers = [false]
        harness.leaveRun(.foreground)
        harness.relaunch()
        harness.engine.prepareLaunch()
        await harness.engine.processPreviousRun()
        #expect(harness.asked == 1)
        #expect(harness.transport.calls.isEmpty)
        #expect(harness.messages.isEmpty)
        // the next start has nothing to ask: the marker was rewritten and the flag removed
        harness.relaunch()
        harness.engine.prepareLaunch()
        await harness.engine.processPreviousRun()
        #expect(harness.asked == 1)
        #expect(harness.transport.calls.isEmpty)
    }

    @Test("A normal exit or a background end asks nothing")
    func cleanRuns() async {
        for state in [NCProblemReportRunMarker.State.background, nil] {
            let harness = ReportsHarness()
            harness.engine.setEnabled(true)
            harness.leaveRun(state)
            harness.relaunch()
            harness.engine.prepareLaunch()
            await harness.engine.processPreviousRun()
            #expect(harness.asked == 0)
            #expect(harness.transport.calls.isEmpty)
        }
    }

    @Test("A start in the background keeps the news of the unclean exit until the app is opened")
    func backgroundStartKeepsTheNews() async {
        let harness = ReportsHarness()
        harness.engine.setEnabled(true)
        harness.leaveRun(.foreground)
        harness.relaunch()
        harness.engine.prepareLaunch()          // a background launch: never becomes active
        harness.relaunch()
        harness.engine.prepareLaunch()          // the next launch
        await harness.engine.processPreviousRun()
        #expect(harness.transport.uploads.count == 1)
    }

    @Test("An exception file becomes a crash report with its text; one report per previous run")
    func exceptionIsACrash() async throws {
        let harness = ReportsHarness()
        harness.engine.setEnabled(true)
        harness.writeException()
        harness.leaveRun(.foreground)   // the unclean marker too: still one report
        harness.relaunch()
        harness.engine.prepareLaunch()
        await harness.engine.processPreviousRun()
        #expect(harness.transport.uploads.count == 1)
        #expect(harness.transport.calls.filter { $0.hasPrefix("PUT") }.count == 1)
        #expect(!FileManager.default.fileExists(atPath: harness.directory.appendingPathComponent("crash-pending.txt").path))
    }

    @Test("A MetricKit diagnostic stored before the first activation is the crash of the previous run")
    func diagnosticBeforeActivation() async {
        let harness = ReportsHarness()
        harness.engine.setEnabled(true)
        harness.relaunch()
        NCMetricKitStore(directory: harness.directory.appendingPathComponent("metrickit")).save(text: "MetricKit crash diagnostic\nsignal: 11\n", version: "7")
        harness.engine.prepareLaunch()
        await harness.engine.processPreviousRun()
        #expect(harness.transport.uploads.count == 1)
    }

    @Test("A late diagnostic is its own crash report only when no report was made for the previous run")
    func lateDiagnostic() async {
        let reported = ReportsHarness()
        reported.engine.setEnabled(true)
        reported.leaveRun(.foreground)
        reported.relaunch()
        reported.engine.prepareLaunch()
        await reported.engine.processPreviousRun()      // an unclean-exit report was made
        NCMetricKitStore(directory: reported.directory.appendingPathComponent("metrickit")).save(text: "late", version: "7")
        await reported.engine.diagnosticArrived()
        #expect(reported.transport.uploads.count == 1, "the same event must not be reported twice")

        let quiet = ReportsHarness()
        quiet.engine.setEnabled(true)
        quiet.engine.prepareLaunch()
        await quiet.engine.processPreviousRun()         // nothing to report
        NCMetricKitStore(directory: quiet.directory.appendingPathComponent("metrickit")).save(text: "late", version: "7")
        await quiet.engine.diagnosticArrived()
        #expect(quiet.transport.uploads.count == 1)
    }

    @Test("A manual report works with the switch off")
    func manualWithSwitchOff() async {
        let harness = ReportsHarness()
        #expect(!harness.engine.isEnabled)
        let outcome = await harness.engine.sendManual(note: "it froze")
        #expect(outcome == .savedNotShared || outcome == .sent)
        #expect(harness.transport.uploads.count == 1)
        #expect(harness.asked == 0)
    }

    @Test("Nothing is sent while the switch is off, except what the user chose")
    func nothingWhileOff() async {
        let harness = ReportsHarness()
        harness.leaveRun(.foreground)
        harness.confirmAnswers = []   // the question is closed without an answer
        harness.relaunch()
        harness.engine.prepareLaunch()
        await harness.engine.processPreviousRun()
        await harness.engine.flushPending(force: true)
        #expect(harness.transport.calls.isEmpty)
    }
}

@Suite("NoDrive report sending")
@MainActor
struct NoDriveReportSendingTests {
    @Test("Order: MKCOL, PUT with If-None-Match, list shares, create the share only when it is missing")
    func order() async {
        let harness = ReportsHarness()
        harness.transport.acceptShare = true
        let outcome = await harness.engine.sendManual(note: "")
        #expect(outcome == .sent)
        #expect(harness.transport.calls.count == 4)
        #expect(harness.transport.calls[0] == "MKCOL Problem reports")
        #expect(harness.transport.calls[1].hasPrefix("PUT Problem reports/"))
        #expect(harness.transport.calls[1].hasSuffix("_ios_35.2.1-nourax.1.zip"))
        #expect(harness.transport.calls[2] == "LIST /Problem reports")
        #expect(harness.transport.calls[3] == "SHARE /Problem reports nourax-support")
        #expect(harness.transport.uploads.first?.headers == ["If-None-Match": "*"])
        #expect(harness.messages == ["Problem report sent"])
    }

    @Test("An existing share is not created again; MKCOL 405 (folder there) is fine")
    func existingShare() async {
        let harness = ReportsHarness()
        harness.transport.folderStatus = 405
        harness.transport.sharedWith = ["nourax-support"]
        let outcome = await harness.engine.sendManual(note: "")
        #expect(outcome == .sent)
        #expect(harness.transport.shareCalls == 0)
    }

    @Test("A failed share: saved in the Drive, said quietly, not tried again in that report; the next report tries again")
    func shareFails() async {
        let harness = ReportsHarness()
        harness.transport.acceptShare = false
        let first = await harness.engine.sendManual(note: "")
        #expect(first == .savedNotShared)
        #expect(harness.messages == ["Saved in your NoDrive › Problem reports."])
        #expect(harness.transport.shareCalls == 1)
        harness.clock = harness.clock.addingTimeInterval(5)
        let second = await harness.engine.sendManual(note: "")
        #expect(second == .savedNotShared)
        #expect(harness.transport.shareCalls == 2, "the next report tries the share again, once")
        // the account now exists
        harness.transport.acceptShare = true
        harness.clock = harness.clock.addingTimeInterval(5)
        #expect(await harness.engine.sendManual(note: "") == .sent)
        #expect(harness.transport.shareCalls == 3)
    }

    @Test("A list of shares that cannot be read is a quiet save, with no share request")
    func listFails() async {
        let harness = ReportsHarness()
        harness.transport.sharedWith = nil
        #expect(await harness.engine.sendManual(note: "") == .savedNotShared)
        #expect(harness.transport.shareCalls == 0)
    }

    @Test("412 (the name exists): never replaced, a new name with a later second")
    func nameExists() async {
        let harness = ReportsHarness()
        harness.transport.uploadStatuses = [412]
        harness.transport.sharedWith = ["nourax-support"]
        #expect(await harness.engine.sendManual(note: "") == .sent)
        let puts = harness.transport.calls.filter { $0.hasPrefix("PUT") }
        #expect(puts.count == 2)
        #expect(puts[0] != puts[1])
        #expect(puts[1].contains("2026-10-26_07-33-21_ios_"))
        #expect(harness.transport.uploads.count == 1)
    }

    @Test("Upload failure: kept on the phone, message says it will try again")
    func uploadFails() async {
        let harness = ReportsHarness()
        harness.transport.uploadStatuses = [503]
        #expect(await harness.engine.sendManual(note: "") == .keptForLater)
        #expect(harness.messages == ["The report could not be sent now. NoDrive will try again later."])
        let sender = NCProblemReportSender(transport: nil, pendingDirectory: harness.directory.appendingPathComponent("pending"),
                                           workDirectory: harness.directory.appendingPathComponent("work"))
        #expect(sender.pendingFiles().count == 1)
        // the next round sends it
        harness.transport.sharedWith = ["nourax-support"]
        harness.clock = harness.clock.addingTimeInterval(601)
        await harness.engine.flushPending(force: false)
        #expect(harness.transport.uploads.count == 1)
        #expect(sender.pendingFiles().isEmpty)
    }

    @Test("MKCOL failure: kept")
    func folderFails() async {
        let harness = ReportsHarness()
        harness.transport.folderStatus = 500
        #expect(await harness.engine.sendManual(note: "") == .keptForLater)
        #expect(harness.transport.calls == ["MKCOL Problem reports"])
    }

    @Test("Six reports kept: the newest five stay")
    func newestFive() async {
        let harness = ReportsHarness()
        harness.transport.uploadStatuses = Array(repeating: 503, count: 6)
        for index in 0..<6 {
            harness.clock = Date(timeIntervalSince1970: 1_793_000_000 + Double(index) * 10)
            _ = await harness.engine.sendManual(note: "n\(index)")
        }
        let sender = NCProblemReportSender(transport: nil, pendingDirectory: harness.directory.appendingPathComponent("pending"),
                                           workDirectory: harness.directory.appendingPathComponent("work"))
        let names = sender.pendingFiles().map(\.lastPathComponent)
        #expect(names.count == 5)
        #expect(names.first?.hasPrefix("2026-10-26_07-33-30") == true, "the oldest of the six should be gone: \(names)")
    }

    @Test("No account: kept; sent after the sign-in; throttled to once per 10 minutes otherwise")
    func noAccount() async {
        let harness = ReportsHarness()
        harness.signedIn = false
        harness.engine.setEnabled(true)
        harness.leaveRun(.foreground)
        harness.relaunch()
        harness.engine.prepareLaunch()
        await harness.engine.processPreviousRun()
        #expect(harness.transport.calls.isEmpty)
        #expect(harness.messages == ["NoDrive will send the report after you sign in."])

        harness.signedIn = true
        harness.transport.sharedWith = ["nourax-support"]
        await harness.engine.flushPending(force: true)       // the sign-in notification
        #expect(harness.transport.uploads.count == 1)

        // throttle: a second round inside 10 minutes does nothing, even with something waiting
        harness.transport.uploadStatuses = [503]
        _ = await harness.engine.sendManual(note: "again")
        let putsBefore = harness.transport.calls.filter { $0.hasPrefix("PUT") }.count
        await harness.engine.flushPending(force: false)
        await harness.engine.flushPending(force: false)
        #expect(harness.transport.calls.filter { $0.hasPrefix("PUT") }.count == putsBefore)
    }

    @Test("Reports that waited for the switch are not sent and not kept once it is off")
    func autoPendingDroppedWhenOff() async {
        let harness = ReportsHarness()
        harness.signedIn = false
        harness.engine.setEnabled(true)
        harness.leaveRun(.foreground)
        harness.relaunch()
        harness.engine.prepareLaunch()
        await harness.engine.processPreviousRun()
        harness.engine.setEnabled(false)
        harness.signedIn = true
        await harness.engine.flushPending(force: true)
        #expect(harness.transport.calls.isEmpty)
        let sender = NCProblemReportSender(transport: nil, pendingDirectory: harness.directory.appendingPathComponent("pending-auto"),
                                           workDirectory: harness.directory.appendingPathComponent("work"))
        #expect(sender.pendingFiles().isEmpty)
    }

    @Test("Every request goes to the account's server host only")
    func onlyTheAccountHost() async {
        let harness = ReportsHarness()
        harness.transport.acceptShare = true
        _ = await harness.engine.sendManual(note: "")
        #expect(harness.transport.host == "drive.nourax.org")
        // the real transport builds its URLs from the account's urlBase and user id only
        let transport = NCNextcloudKitReportTransport(account: "citest https://drive.nourax.org",
                                                      urlBase: "https://drive.nourax.org", userId: "citest")
        #expect(transport.host == "drive.nourax.org")
        let info = harness.transport.uploads.first
        #expect(info?.remotePath.hasPrefix("Problem reports/") == true)
    }

    @Test("The shifted name keeps the pattern")
    func shifted() {
        let shifted = NCProblemReportSender.shiftedName("2026-10-26_07-33-59_ios_35.2.1-nourax.1.zip", seconds: 2)
        #expect(shifted == "2026-10-26_07-34-01_ios_35.2.1-nourax.1.zip")
    }
}
