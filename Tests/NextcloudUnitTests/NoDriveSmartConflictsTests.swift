// SPDX-FileCopyrightText: 2026 Nourax
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import NextcloudKit
import Testing
@testable import Nextcloud

// MARK: - Fakes and helpers

private let account = "citest https://drive.nourax.org"
private let serverUrl = "https://drive.nourax.org/remote.php/dav/files/citest/Camera"
private let serverUrlBase = "https://drive.nourax.org/remote.php/dav/files/citest/Camera"

/// Answers the probe from a table: `url -> state`; every other url is free (missing).
private final class FakeProbe: NCRemoteProbe {
    var answers: [String: NCConflictRemoteState] = [:]
    private(set) var asked: [String] = []

    func state(of serverUrlFileName: String, account: String) async -> NCConflictRemoteState {
        asked.append(serverUrlFileName)
        return answers[serverUrlFileName] ?? .missing
    }

    func set(_ name: String, _ state: NCConflictRemoteState) {
        answers[NCConflictNaming.join(serverUrl, name)] = state
    }
}

/// The database and the file work, in memory.
private final class FakeStore: NCConflictStore {
    var policies: [String: NCConflictPolicy] = [:]
    var sizes: [String: Int64] = [:]            // ocId -> size of the extracted copy
    var queued: Set<String> = []                // names used by items of the app
    var waiting: [tableMetadata] = []           // rows in the queue that were not passed in
    private(set) var done: [String] = []        // ocIds marked as already in NoDrive
    private(set) var renamed: [(ocId: String, from: String, to: String)] = []
    private(set) var history: [(base: String, name: String, asset: String)] = []

    func policy(account: String) -> NCConflictPolicy { policies[account] ?? .smart }
    func localSize(of metadata: tableMetadata) -> Int64 { sizes[metadata.ocId] ?? metadata.size }
    func isNameQueued(_ fileName: String, serverUrl: String, account: String) async -> Bool { queued.contains(fileName) }
    func mate(of metadata: tableMetadata) async -> tableMetadata? {
        waiting.first { $0.assetLocalIdentifier == metadata.assetLocalIdentifier && $0.isLivePhotoImage != metadata.isLivePhotoImage }
    }
    func markDone(_ metadata: tableMetadata) async {
        done.append(metadata.ocId)
        waiting.removeAll { $0.ocId == metadata.ocId }
    }
    func rename(_ metadata: tableMetadata, to newName: String, livePhotoFile: String?) async -> tableMetadata {
        let updated = metadata.detachedCopy()
        renamed.append((metadata.ocId, metadata.fileName, newName))
        queued.remove(metadata.fileName)
        queued.insert(newName)
        updated.fileName = newName
        updated.fileNameView = newName
        updated.serverUrlFileName = NCConflictNaming.join(metadata.serverUrl, newName)
        if let livePhotoFile { updated.livePhotoFile = livePhotoFile }
        return updated
    }
    func recordUploaded(account: String, serverUrlBase: String, fileName: String, assetLocalIdentifier: String, date: Date) async {
        history.append((serverUrlBase, fileName, assetLocalIdentifier))
    }
}

private enum Kind { case plain, photo, video }

private func row(_ ocId: String, _ name: String, asset: String = "ASSET-1", kind: Kind = .plain, size: Int64 = 100) -> tableMetadata {
    let metadata = tableMetadata()
    metadata.ocId = ocId
    metadata.account = account
    metadata.fileName = name
    metadata.fileNameView = name
    metadata.serverUrl = serverUrl
    metadata.serverUrlFileName = NCConflictNaming.join(serverUrl, name)
    metadata.assetLocalIdentifier = asset
    metadata.sessionSelector = NCGlobal.shared.selectorUploadAutoUpload
    metadata.autoUploadServerUrlBase = serverUrlBase
    metadata.status = NCGlobal.shared.metadataStatusWaitUpload
    metadata.isExtractFile = true
    metadata.size = size
    metadata.creationDate = Date(timeIntervalSince1970: 1_700_000_000) as NSDate
    let stem = (name as NSString).deletingPathExtension
    switch kind {
    case .plain:
        metadata.classFile = NKTypeClassFile.image.rawValue
    case .photo:
        metadata.classFile = NKTypeClassFile.image.rawValue
        metadata.livePhotoFile = stem + ".mov"
    case .video:
        metadata.classFile = NKTypeClassFile.video.rawValue
        metadata.livePhotoFile = stem + ".HEIC"
    }
    return metadata
}

private func makeResolver(_ store: FakeStore, _ probe: FakeProbe) -> (NCConflictResolver, NCConflictRenameLedger) {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("ledger-\(UUID().uuidString).json")
    let ledger = NCConflictRenameLedger(url: url)
    return (NCConflictResolver(store: store, probe: probe, ledger: ledger), ledger)
}

// MARK: - Policy store

@Suite("NoDrive conflict policy")
struct NoDriveConflictPolicyTests {
    private func makeDefaults() -> (UserDefaults, String) {
        let suite = "nodrive-conflict-tests-\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite)!, suite)
    }

    @Test("The default is Smart, also for an unknown stored value")
    func defaultIsSmart() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = NCConflictPolicyStore(defaults: defaults)
        #expect(store.policy(account: account) == .smart)
        defaults.set("ask", forKey: NCConflictPolicyStore.key(account: account))
        #expect(store.policy(account: account) == .smart)
    }

    @Test("The choice is kept per account and survives a new store")
    func perAccountAndPersistent() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        NCConflictPolicyStore(defaults: defaults).setPolicy(.keepBoth, account: "a https://x")
        NCConflictPolicyStore(defaults: defaults).setPolicy(.keepPhone, account: "b https://x")
        let again = NCConflictPolicyStore(defaults: defaults)
        #expect(again.policy(account: "a https://x") == .keepBoth)
        #expect(again.policy(account: "b https://x") == .keepPhone)
        #expect(again.policy(account: "c https://x") == .smart)
    }

    @Test("Stable raw values, four choices, no Ask")
    func rawValues() {
        #expect(NCConflictPolicy.allCases.map(\.rawValue) == ["smart", "keep-nodrive", "keep-phone", "keep-both"])
    }

    @Test("The texts are exactly the ones of the contract")
    func texts() {
        #expect(NCConflictPolicy.settingTitle == "If a file is already in NoDrive")
        #expect(NCConflictPolicy.smart.title == "Smart (recommended)")
        #expect(NCConflictPolicy.smart.summary == "Skip it if it's the same size, otherwise keep both")
        #expect(NCConflictPolicy.keepNoDrive.title == "Keep the NoDrive copy")
        #expect(NCConflictPolicy.keepPhone.title == "Keep the phone copy")
        #expect(NCConflictPolicy.keepBoth.title == "Keep both")
        #expect(NCConflictPolicy.keepNoDrive.summary == nil)
        let all = NCConflictPolicy.allCases.map { $0.title + ($0.summary ?? "") } + [NCConflictPolicy.settingTitle]
        #expect(all.allSatisfy { !$0.localizedCaseInsensitiveContains("nextcloud") && !$0.localizedCaseInsensitiveContains("ask") })
    }

    @Test("The upstream pre-check runs for Keep the NoDrive copy only")
    func precheck() {
        let name = "precheck-\(UUID().uuidString) https://drive.nourax.org"
        defer { UserDefaults(suiteName: NCBrandOptions.shared.capabilitiesGroup)?.removeObject(forKey: NCConflictPolicyStore.key(account: name)) }
        let uploadAccount = tableAccount()
        uploadAccount.account = name
        for policy in NCConflictPolicy.allCases {
            NCConflictPolicyStore().setPolicy(policy, account: name)
            #expect(NCAutoUploadConflicts.shared.upstreamPrecheck(uploadAccount) == (policy == .keepNoDrive))
        }
    }

    @Test("NoDrive decides Auto upload items; PhotoKit leftovers and other uploads keep upstream's check")
    func handles() {
        let auto = row("1", "IMG_1.HEIC")
        #expect(NCAutoUploadConflicts.shared.handles(auto, backgroundResource: false))
        #expect(!NCAutoUploadConflicts.shared.handles(auto, backgroundResource: true))
        let manual = row("2", "IMG_2.HEIC")
        manual.sessionSelector = NCGlobal.shared.selectorUploadFile
        #expect(!NCAutoUploadConflicts.shared.handles(manual, backgroundResource: false))
    }
}

// MARK: - Decision

struct DecisionCase: CustomTestStringConvertible {
    let policy: NCConflictPolicy
    let remote: NCConflictRemoteState
    let expected: NCConflictDecision
    var testDescription: String { "\(policy.rawValue) / \(remote)" }
}

/// Every choice against every state of the name: the exact action.
private let conflictMatrix: [DecisionCase] = [
    // nothing there: always upload as is
    DecisionCase(policy: .smart, remote: .missing, expected: .upload(skipping: [])),
    DecisionCase(policy: .keepNoDrive, remote: .missing, expected: .upload(skipping: [])),
    DecisionCase(policy: .keepPhone, remote: .missing, expected: .upload(skipping: [])),
    DecisionCase(policy: .keepBoth, remote: .missing, expected: .upload(skipping: [])),
    // a file of the same size
    DecisionCase(policy: .smart, remote: .file(size: 100), expected: .upload(skipping: [0])),
    DecisionCase(policy: .keepNoDrive, remote: .file(size: 100), expected: .upload(skipping: [0])),
    DecisionCase(policy: .keepPhone, remote: .file(size: 100), expected: .upload(skipping: [])),
    DecisionCase(policy: .keepBoth, remote: .file(size: 100), expected: .renameAll),
    // a file of another size
    DecisionCase(policy: .smart, remote: .file(size: 99), expected: .renameAll),
    DecisionCase(policy: .keepNoDrive, remote: .file(size: 99), expected: .upload(skipping: [0])),
    DecisionCase(policy: .keepPhone, remote: .file(size: 99), expected: .upload(skipping: [])),
    DecisionCase(policy: .keepBoth, remote: .file(size: 99), expected: .renameAll),
    // a folder has the name
    DecisionCase(policy: .smart, remote: .folder, expected: .renameAll),
    DecisionCase(policy: .keepNoDrive, remote: .folder, expected: .upload(skipping: [0])),
    DecisionCase(policy: .keepPhone, remote: .folder, expected: .upload(skipping: [])),
    DecisionCase(policy: .keepBoth, remote: .folder, expected: .renameAll),
    // the server did not give a clear answer: retry later, never a guess (Keep the phone copy asks nothing)
    DecisionCase(policy: .smart, remote: .unknown, expected: .retryLater),
    DecisionCase(policy: .keepNoDrive, remote: .unknown, expected: .retryLater),
    DecisionCase(policy: .keepPhone, remote: .unknown, expected: .upload(skipping: [])),
    DecisionCase(policy: .keepBoth, remote: .unknown, expected: .retryLater)
]

@Suite("NoDrive conflict decision")
struct NoDriveConflictDecisionTests {
    private func part(_ remote: NCConflictRemoteState, local: Int64 = 100, name: String = "IMG_0001.HEIC") -> NCConflictPart {
        NCConflictPart(name: name, localSize: local, remote: remote)
    }

    @Test("One file: every choice against every state", arguments: conflictMatrix)
    func singleFile(_ item: DecisionCase) {
        #expect(NCConflictDecision.decide(policy: item.policy, parts: [part(item.remote)]) == item.expected)
    }

    @Test("Only Keep the phone copy ever uploads over a name that exists")
    func neverReplacesExceptKeepPhone() {
        let states: [NCConflictRemoteState] = [.missing, .file(size: 100), .file(size: 99), .folder, .unknown]
        for policy in NCConflictPolicy.allCases where policy != .keepPhone {
            for first in states {
                for second in states {
                    let parts = [part(first), part(second)]
                    guard case .upload(let skipping) = NCConflictDecision.decide(policy: policy, parts: parts) else { continue }
                    for (index, p) in parts.enumerated() where p.remote.exists {
                        #expect(skipping.contains(index), "\(policy) would upload over \(p.remote)")
                    }
                }
            }
        }
    }

    @Test("Smart: an unreadable local size is never compared")
    func smartLocalSizeUnreadable() {
        #expect(NCConflictDecision.decide(policy: .smart, parts: [part(.file(size: 0), local: 0)]) == .retryLater)
        #expect(NCConflictDecision.decide(policy: .smart, parts: [part(.missing, local: 0)]) == .upload(skipping: []))
    }

    @Test("Live Photo, Smart: both the same -> both done; photo same and video missing -> only the video uploads")
    func livePhotoSmart() {
        let photo = part(.file(size: 100), name: "IMG_0001.HEIC")
        let video = part(.file(size: 50), local: 50, name: "IMG_0001.MOV")
        #expect(NCConflictDecision.decide(policy: .smart, parts: [photo, video]) == .upload(skipping: [0, 1]))
        let missingVideo = part(.missing, local: 50, name: "IMG_0001.MOV")
        #expect(NCConflictDecision.decide(policy: .smart, parts: [photo, missingVideo]) == .upload(skipping: [0]))
    }

    @Test("Live Photo, Smart: one part differs -> both parts get a new number; one unknown -> retry")
    func livePhotoSmartDiffers() {
        let photo = part(.file(size: 100))
        #expect(NCConflictDecision.decide(policy: .smart, parts: [photo, part(.file(size: 49), local: 50)]) == .renameAll)
        #expect(NCConflictDecision.decide(policy: .smart, parts: [photo, part(.folder, local: 50)]) == .renameAll)
        #expect(NCConflictDecision.decide(policy: .smart, parts: [photo, part(.unknown, local: 50)]) == .retryLater)
    }

    @Test("Live Photo: Keep both renames both when either exists; Keep the NoDrive copy decides per part; Keep the phone copy uploads both")
    func livePhotoOtherChoices() {
        let photo = part(.file(size: 100))
        let video = part(.missing, local: 50)
        #expect(NCConflictDecision.decide(policy: .keepBoth, parts: [photo, video]) == .renameAll)
        #expect(NCConflictDecision.decide(policy: .keepBoth, parts: [part(.missing), video]) == .upload(skipping: []))
        #expect(NCConflictDecision.decide(policy: .keepNoDrive, parts: [photo, video]) == .upload(skipping: [0]))
        #expect(NCConflictDecision.decide(policy: .keepPhone, parts: [photo, video]) == .upload(skipping: []))
    }

    @Test("The setting alone decides: it does not depend on any other upload switch")
    func independentOfForceReupload() {
        // decide() has no input but the choice and the parts, so "Upload previously uploaded photos and videos
        // again" cannot make Smart replace a file.
        #expect(NCConflictDecision.decide(policy: .smart, parts: [part(.file(size: 99))]) == .renameAll)
    }
}

// MARK: - Naming

@Suite("NoDrive conflict naming")
struct NoDriveConflictNamingTests {
    @Test("The numbering of the app: name 1.ext, a trailing number counts on")
    func nextName() {
        #expect(NCConflictNaming.nextName(after: "IMG_0001.JPG") == "IMG_0001 1.JPG")
        #expect(NCConflictNaming.nextName(after: "IMG_0001 1.JPG") == "IMG_0001 2.JPG")
        #expect(NCConflictNaming.nextName(after: "IMG 3.JPG") == "IMG 4.JPG")
        #expect(NCConflictNaming.nextName(after: "My Photo.jpg") == "My Photo 1.jpg")
        #expect(NCConflictNaming.nextName(after: "README") == "README 1")
        #expect(NCConflictNaming.nextName(after: "photo.v2.jpg") == "photo.v2 1.jpg")
    }

    @Test("The first free number; a pair takes the first number free for both")
    func pairTakesCommonNumber() async {
        let probe = FakeProbe()
        probe.set("IMG_0001 1.HEIC", .missing)
        probe.set("IMG_0001 1.MOV", .file(size: 5))
        let names = await NCConflictNaming.freeNames(for: ["IMG_0001.HEIC", "IMG_0001.MOV"], serverUrl: serverUrl, account: account,
                                                     probe: probe, isQueued: { _ in false })
        #expect(names == ["IMG_0001 2.HEIC", "IMG_0001 2.MOV"])
    }

    @Test("A name used by a queued item is skipped")
    func queuedNameSkipped() async {
        let names = await NCConflictNaming.freeNames(for: ["IMG_0001.JPG"], serverUrl: serverUrl, account: account,
                                                     probe: FakeProbe(), isQueued: { $0 == "IMG_0001 1.JPG" })
        #expect(names == ["IMG_0001 2.JPG"])
    }

    @Test("A folder with the candidate name is taken")
    func folderIsTaken() async {
        let probe = FakeProbe()
        probe.set("IMG_0001 1.JPG", .folder)
        let names = await NCConflictNaming.freeNames(for: ["IMG_0001.JPG"], serverUrl: serverUrl, account: account,
                                                     probe: probe, isQueued: { _ in false })
        #expect(names == ["IMG_0001 2.JPG"])
    }

    @Test("A server answer that is not clear ends in retry later, never in a guess")
    func unknownAnswerFailsClosed() async {
        let probe = FakeProbe()
        probe.set("IMG_0001 1.JPG", .unknown)
        let names = await NCConflictNaming.freeNames(for: ["IMG_0001.JPG"], serverUrl: serverUrl, account: account,
                                                     probe: probe, isQueued: { _ in false })
        #expect(names == nil)
    }

    @Test("100 taken names end in retry later")
    func hundredTaken() async {
        let probe = FakeProbe()
        for number in 1...100 { probe.set("IMG_0001 \(number).JPG", .file(size: 1)) }
        let names = await NCConflictNaming.freeNames(for: ["IMG_0001.JPG"], serverUrl: serverUrl, account: account,
                                                     probe: probe, isQueued: { _ in false })
        #expect(names == nil)
    }
}

// MARK: - Probe parser

@Suite("NoDrive conflict probe")
struct NoDriveConflictProbeTests {
    /// The shape of a Nextcloud 35 answer to the request in NCWebDAVProbe: tools/ci/server_round3_check.py sends that
    /// request to a real Nextcloud 35 and checks that its answer has this structure.
    static let fileAnswer = """
    <?xml version="1.0"?>
    <d:multistatus xmlns:d="DAV:" xmlns:s="http://sabredav.org/ns" xmlns:oc="http://owncloud.org/ns" xmlns:nc="http://nextcloud.org/ns">
      <d:response>
        <d:href>/remote.php/dav/files/citest/Camera/IMG_0001.HEIC</d:href>
        <d:propstat>
          <d:prop>
            <d:getcontentlength>12345</d:getcontentlength>
            <d:resourcetype/>
            <oc:size>12345</oc:size>
          </d:prop>
          <d:status>HTTP/1.1 200 OK</d:status>
        </d:propstat>
      </d:response>
    </d:multistatus>
    """

    static let folderAnswer = """
    <?xml version="1.0"?>
    <d:multistatus xmlns:d="DAV:" xmlns:s="http://sabredav.org/ns" xmlns:oc="http://owncloud.org/ns" xmlns:nc="http://nextcloud.org/ns">
      <d:response>
        <d:href>/remote.php/dav/files/citest/Camera/IMG_0001.HEIC/</d:href>
        <d:propstat>
          <d:prop>
            <d:resourcetype><d:collection/></d:resourcetype>
            <oc:size>4096</oc:size>
          </d:prop>
          <d:status>HTTP/1.1 200 OK</d:status>
        </d:propstat>
        <d:propstat>
          <d:prop>
            <d:getcontentlength/>
          </d:prop>
          <d:status>HTTP/1.1 404 Not Found</d:status>
        </d:propstat>
      </d:response>
    </d:multistatus>
    """

    static let fileWithoutLength = """
    <?xml version="1.0"?>
    <d:multistatus xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns">
      <d:response>
        <d:href>/remote.php/dav/files/citest/Camera/IMG_0001.HEIC</d:href>
        <d:propstat>
          <d:prop><d:resourcetype/></d:prop>
          <d:status>HTTP/1.1 200 OK</d:status>
        </d:propstat>
        <d:propstat>
          <d:prop><d:getcontentlength/></d:prop>
          <d:status>HTTP/1.1 404 Not Found</d:status>
        </d:propstat>
      </d:response>
    </d:multistatus>
    """

    @Test("A file: its getcontentlength")
    func file() {
        #expect(NCPropfindSizeParser.parse(Data(Self.fileAnswer.utf8)) == .file(size: 12345))
    }

    @Test("A folder: collection, and getcontentlength only in the 404 propstat")
    func folder() {
        #expect(NCPropfindSizeParser.parse(Data(Self.folderAnswer.utf8)) == .folder)
    }

    @Test("A file answer without a size is unknown")
    func fileWithoutLength() {
        #expect(NCPropfindSizeParser.parse(Data(Self.fileWithoutLength.utf8)) == .unknown)
    }

    @Test("An answer that is not XML, or empty, is unknown")
    func notXml() {
        #expect(NCPropfindSizeParser.parse(Data("<html>not dav".utf8)) == .unknown)
        #expect(NCPropfindSizeParser.parse(Data()) == .unknown)
    }

    @Test("The prefixes of the answer do not matter, only the namespaces")
    func otherPrefixes() {
        let xml = Self.fileAnswer.replacingOccurrences(of: "d:", with: "x:").replacingOccurrences(of: "xmlns:d=", with: "xmlns:x=")
        #expect(NCPropfindSizeParser.parse(Data(xml.utf8)) == .file(size: 12345))
    }

    @Test("Only the first response counts")
    func firstResponseOnly() {
        let two = Self.fileAnswer.replacingOccurrences(of: "</d:multistatus>", with: """
          <d:response><d:href>/x</d:href><d:propstat><d:prop><d:getcontentlength>7</d:getcontentlength></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
        </d:multistatus>
        """)
        #expect(NCPropfindSizeParser.parse(Data(two.utf8)) == .file(size: 12345))
    }

    @Test("The request body asks for exactly what the parser reads")
    func requestBody() {
        let body = NCWebDAVProbe.requestBodyText
        #expect(body.contains("<d:getcontentlength/>"))
        #expect(body.contains("<d:resourcetype/>"))
        #expect(body.contains("<oc:size/>"))
        #expect(XMLParser(data: Data(body.utf8)).parse())
    }
}

// MARK: - Resolver

@Suite("NoDrive conflict resolver")
struct NoDriveConflictResolverTests {
    @Test("Smart, same size: marked done, nothing uploads, nothing renamed")
    func smartSameSize() async {
        let store = FakeStore()
        let probe = FakeProbe()
        probe.set("IMG_0001.HEIC", .file(size: 100))
        let (resolver, _) = makeResolver(store, probe)
        let result = await resolver.resolve([row("a", "IMG_0001.HEIC")])
        #expect(result.isEmpty)
        #expect(store.done == ["a"])
        #expect(store.renamed.isEmpty)
    }

    @Test("Smart, different size: the item uploads under a new number; the NoDrive file is not touched")
    func smartDifferentSize() async {
        let store = FakeStore()
        let probe = FakeProbe()
        probe.set("IMG_0001.HEIC", .file(size: 99))
        let (resolver, ledger) = makeResolver(store, probe)
        let result = await resolver.resolve([row("a", "IMG_0001.HEIC")])
        #expect(result.map(\.fileName) == ["IMG_0001 1.HEIC"])
        #expect(result.first?.fileNameView == "IMG_0001 1.HEIC")
        #expect(result.first?.serverUrlFileName == NCConflictNaming.join(serverUrl, "IMG_0001 1.HEIC"))
        #expect(store.done.isEmpty)
        #expect(store.renamed.count == 1)
        let entry = await ledger.entry(account: account, serverUrlBase: serverUrlBase, newName: "IMG_0001 1.HEIC")
        #expect(entry?.originalName == "IMG_0001.HEIC")
    }

    @Test("Smart, name free: uploads as is")
    func smartFree() async {
        let store = FakeStore()
        let (resolver, ledger) = makeResolver(store, FakeProbe())
        let result = await resolver.resolve([row("a", "IMG_0001.HEIC")])
        #expect(result.map(\.fileName) == ["IMG_0001.HEIC"])
        #expect(store.done.isEmpty && store.renamed.isEmpty)
        #expect(await ledger.count == 0)
    }

    @Test("Smart, answer not clear: nothing uploads, nothing is marked, nothing renamed")
    func smartUnknown() async {
        let store = FakeStore()
        let probe = FakeProbe()
        probe.set("IMG_0001.HEIC", .unknown)
        let (resolver, ledger) = makeResolver(store, probe)
        let result = await resolver.resolve([row("a", "IMG_0001.HEIC")])
        #expect(result.isEmpty)
        #expect(store.done.isEmpty && store.renamed.isEmpty)
        #expect(await ledger.count == 0)
    }

    @Test("Keep the NoDrive copy: an existing name is marked done, a free one uploads")
    func keepNoDrive() async {
        let store = FakeStore()
        store.policies[account] = .keepNoDrive
        let probe = FakeProbe()
        probe.set("A.HEIC", .file(size: 1))
        let (resolver, _) = makeResolver(store, probe)
        let result = await resolver.resolve([row("a", "A.HEIC"), row("b", "B.HEIC", asset: "ASSET-2")])
        #expect(result.map(\.fileName) == ["B.HEIC"])
        #expect(store.done == ["a"])
        #expect(store.renamed.isEmpty)
    }

    @Test("Keep the phone copy: uploads as is and asks the server nothing")
    func keepPhone() async {
        let store = FakeStore()
        store.policies[account] = .keepPhone
        let probe = FakeProbe()
        probe.set("A.HEIC", .file(size: 1))
        let (resolver, _) = makeResolver(store, probe)
        let result = await resolver.resolve([row("a", "A.HEIC")])
        #expect(result.map(\.fileName) == ["A.HEIC"])
        #expect(probe.asked.isEmpty)
        #expect(store.done.isEmpty && store.renamed.isEmpty)
    }

    @Test("Keep both: an existing name of the same size still gets a second copy")
    func keepBoth() async {
        let store = FakeStore()
        store.policies[account] = .keepBoth
        let probe = FakeProbe()
        probe.set("A.HEIC", .file(size: 100))
        let (resolver, _) = makeResolver(store, probe)
        let result = await resolver.resolve([row("a", "A.HEIC")])
        #expect(result.map(\.fileName) == ["A 1.HEIC"])
        #expect(store.done.isEmpty)
    }

    @Test("Live Photo, Smart, one part differs: both parts get the same number and point at each other")
    func livePhotoRenamed() async {
        let store = FakeStore()
        let probe = FakeProbe()
        probe.set("IMG_0001.HEIC", .file(size: 100))
        probe.set("IMG_0001.mov", .file(size: 49))
        let (resolver, ledger) = makeResolver(store, probe)
        let photo = row("p", "IMG_0001.HEIC", kind: .photo)
        let video = row("v", "IMG_0001.mov", kind: .video, size: 50)
        let result = await resolver.resolve([photo, video])
        #expect(result.map(\.fileName) == ["IMG_0001 1.HEIC", "IMG_0001 1.mov"])
        #expect(result[0].livePhotoFile == "IMG_0001 1.mov")
        #expect(result[1].livePhotoFile == "IMG_0001 1.HEIC")
        #expect(await ledger.count == 2)
    }

    @Test("Live Photo, Smart, both the same size: both marked done")
    func livePhotoBothDone() async {
        let store = FakeStore()
        let probe = FakeProbe()
        probe.set("IMG_0001.HEIC", .file(size: 100))
        probe.set("IMG_0001.mov", .file(size: 50))
        let (resolver, _) = makeResolver(store, probe)
        let result = await resolver.resolve([row("p", "IMG_0001.HEIC", kind: .photo), row("v", "IMG_0001.mov", kind: .video, size: 50)])
        #expect(result.isEmpty)
        #expect(Set(store.done) == ["p", "v"])
    }

    @Test("Live Photo, one part unknown: retry later for both")
    func livePhotoRetry() async {
        let store = FakeStore()
        let probe = FakeProbe()
        probe.set("IMG_0001.mov", .unknown)
        let (resolver, _) = makeResolver(store, probe)
        let result = await resolver.resolve([row("p", "IMG_0001.HEIC", kind: .photo), row("v", "IMG_0001.mov", kind: .video, size: 50)])
        #expect(result.isEmpty)
        #expect(store.done.isEmpty && store.renamed.isEmpty)
    }

    @Test("A partner that was extracted earlier is found and decided with its pair")
    func partnerFromQueue() async {
        let store = FakeStore()
        let photo = row("p", "IMG_0001.HEIC", kind: .photo)
        store.waiting = [photo]
        let probe = FakeProbe()
        probe.set("IMG_0001.mov", .file(size: 49))
        let (resolver, _) = makeResolver(store, probe)
        // only the video comes back from the extraction; its photo waits in the queue
        let result = await resolver.resolve([row("v", "IMG_0001.mov", kind: .video, size: 50)])
        #expect(result.map(\.fileName) == ["IMG_0001 1.mov"])
        #expect(Set(store.renamed.map { $0.ocId }) == ["p", "v"], "the photo follows the video's decision")
    }

    @Test("Items that are not Auto upload items come back unchanged")
    func otherItemsUnchanged() async {
        let store = FakeStore()
        let probe = FakeProbe()
        probe.set("M.HEIC", .file(size: 1))
        let manual = row("m", "M.HEIC")
        manual.sessionSelector = NCGlobal.shared.selectorUploadFile
        let (resolver, _) = makeResolver(store, probe)
        let result = await resolver.resolve([manual])
        #expect(result.map(\.ocId) == ["m"])
        #expect(probe.asked.isEmpty)
    }

    @Test("PhotoKit background leftovers are returned unchanged")
    func backgroundResourceUnchanged() async {
        let item = row("x", "X.HEIC")
        let result = await NCAutoUploadConflicts.shared.resolve([item], backgroundResource: true)
        #expect(result.map(\.ocId) == ["x"])
        #expect(!NCAutoUploadConflicts.shared.handles(item, backgroundResource: true))
    }
}

// MARK: - Ledger

@Suite("NoDrive conflict ledger")
struct NoDriveConflictLedgerTests {
    @Test("A renamed upload that succeeded also records the original name, once")
    func successRecordsOriginal() async {
        let store = FakeStore()
        let probe = FakeProbe()
        probe.set("IMG_0001.HEIC", .file(size: 99))
        let (resolver, ledger) = makeResolver(store, probe)
        _ = await resolver.resolve([row("a", "IMG_0001.HEIC")])
        await resolver.uploaded(account: account, serverUrlBase: serverUrlBase, fileName: "IMG_0001 1.HEIC")
        #expect(store.history.map { $0.name } == ["IMG_0001.HEIC"])
        #expect(store.history.first?.asset == "ASSET-1")
        #expect(await ledger.count == 0)
        await resolver.uploaded(account: account, serverUrlBase: serverUrlBase, fileName: "IMG_0001 1.HEIC")
        #expect(store.history.count == 1)
    }

    @Test("A failed renamed upload records nothing: the next scan finds the photo again")
    func failureRecordsNothing() async {
        let store = FakeStore()
        let probe = FakeProbe()
        probe.set("IMG_0001.HEIC", .file(size: 99))
        let (resolver, ledger) = makeResolver(store, probe)
        _ = await resolver.resolve([row("a", "IMG_0001.HEIC")])
        #expect(store.history.isEmpty)
        #expect(await ledger.count == 1)
        // an upload of some other name changes nothing
        await resolver.uploaded(account: account, serverUrlBase: serverUrlBase, fileName: "Other.HEIC")
        #expect(store.history.isEmpty)
    }

    @Test("A second queue item of the same photo is marked done, not renamed again")
    func secondItem() async {
        let store = FakeStore()
        let probe = FakeProbe()
        probe.set("IMG_0001.HEIC", .file(size: 99))
        let (resolver, _) = makeResolver(store, probe)
        _ = await resolver.resolve([row("a", "IMG_0001.HEIC")])
        #expect(store.queued.contains("IMG_0001 1.HEIC"))
        let again = await resolver.resolve([row("b", "IMG_0001.HEIC")])
        #expect(again.isEmpty)
        #expect(store.done == ["b"])
        #expect(store.renamed.count == 1)
    }

    @Test("A stale entry (the renamed copy left the queue) never hides the photo")
    func staleEntry() async {
        let store = FakeStore()
        let probe = FakeProbe()
        probe.set("IMG_0001.HEIC", .file(size: 99))
        let (resolver, _) = makeResolver(store, probe)
        _ = await resolver.resolve([row("a", "IMG_0001.HEIC")])
        store.queued.remove("IMG_0001 1.HEIC")
        let again = await resolver.resolve([row("b", "IMG_0001.HEIC")])
        #expect(again.map(\.fileName) == ["IMG_0001 1.HEIC"])
        #expect(store.done.isEmpty)
    }

    @Test("A renamed copy found on the Drive (same size) is done and also records the original name")
    func renamedCopyAlreadyThere() async {
        let store = FakeStore()
        let probe = FakeProbe()
        probe.set("IMG_0001.HEIC", .file(size: 99))
        let (resolver, _) = makeResolver(store, probe)
        let renamed = await resolver.resolve([row("a", "IMG_0001.HEIC")])
        // the renamed upload reached the Drive, but the app did not record it; the next pass finds it
        probe.set("IMG_0001 1.HEIC", .file(size: 100))
        let next = await resolver.resolve(renamed)
        #expect(next.isEmpty)
        #expect(store.done == ["a"])
        #expect(store.history.map { $0.name } == ["IMG_0001.HEIC"])
    }

    @Test("The ledger is kept in a file and entries older than 90 days are dropped")
    func persistenceAndPruning() async {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ledger-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        var clock = Date(timeIntervalSince1970: 1_700_000_000)
        let first = NCConflictRenameLedger(url: url, now: { clock })
        await first.record(account: account, serverUrlBase: serverUrlBase, newName: "A 1.JPG", originalName: "A.JPG",
                           assetLocalIdentifier: "X", date: clock)
        clock = clock.addingTimeInterval(10 * 24 * 3600)
        let second = NCConflictRenameLedger(url: url, now: { clock })
        #expect(await second.entry(account: account, serverUrlBase: serverUrlBase, newName: "A 1.JPG")?.originalName == "A.JPG")
        clock = clock.addingTimeInterval(91 * 24 * 3600)
        let third = NCConflictRenameLedger(url: url, now: { clock })
        #expect(await third.entry(account: account, serverUrlBase: serverUrlBase, newName: "A 1.JPG") == nil)
        #expect(await third.count == 0)
    }
}

// MARK: - NoDrive branding of this feature

@Suite("NoDrive background upload extension")
struct NoDriveBackgroundUploadExtensionTests {
    @Test("The experimental PhotoKit background upload is off in NoDrive, so it can never replace a file")
    func switchedOff() {
        #expect(NCBrandOptions.shared.disable_background_upload_extension)
        #expect(!NCPreferences.canConfigureBackgroundUploadExtension)
        #expect(!NCPreferences().shouldUseBackgroundUploadExtension)
    }
}
