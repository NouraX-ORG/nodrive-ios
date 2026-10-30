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
    /// A pause in every answer, so that two callers overlap in the tests (a real server takes time too).
    var pauseNanoseconds: UInt64 = 0

    func state(of serverUrlFileName: String, account: String) async -> NCConflictRemoteState {
        asked.append(serverUrlFileName)
        if pauseNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: pauseNanoseconds)
        }
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
    var queue: [tableMetadata] = []             // every waiting or uploading row (for "another photo uses this name")
    private(set) var done: [String] = []        // ocIds marked as already in NoDrive
    private(set) var renamed: [(ocId: String, from: String, to: String)] = []
    var failRename = false                      // a file copy fails: nothing is renamed
    private(set) var history: [(base: String, name: String, asset: String)] = []

    func policy(account: String) -> NCConflictPolicy { policies[account] ?? .smart }
    func localSize(of metadata: tableMetadata) -> Int64 { sizes[metadata.ocId] ?? metadata.size }
    func isNameQueued(_ fileName: String, serverUrl: String, account: String) async -> Bool { queued.contains(fileName) }
    func isNameUploadingByOtherItem(_ metadata: tableMetadata) async -> Bool {
        queue.contains {
            $0.fileNameView == metadata.fileNameView && $0.serverUrl == metadata.serverUrl && $0.ocId != metadata.ocId
                && $0.assetLocalIdentifier != metadata.assetLocalIdentifier
                && $0.status == NCGlobal.shared.metadataStatusUploading
        }
    }
    func activeOcIds(among ocIds: Set<String>) async -> Set<String> {
        Set(queue.filter {
            ocIds.contains($0.ocId) && ($0.status == NCGlobal.shared.metadataStatusWaitUpload || $0.status == NCGlobal.shared.metadataStatusUploading)
        }.map(\.ocId))
    }
    func mate(of metadata: tableMetadata) async -> tableMetadata? {
        waiting.first { $0.assetLocalIdentifier == metadata.assetLocalIdentifier && $0.isLivePhotoImage != metadata.isLivePhotoImage }
    }
    func markDone(_ metadata: tableMetadata) async {
        done.append(metadata.ocId)
        waiting.removeAll { $0.ocId == metadata.ocId }
    }
    func rename(_ renames: [NCConflictRename]) async -> [tableMetadata]? {
        if failRename { return nil }
        var rows: [tableMetadata] = []
        for rename in renames {
            let metadata = rename.metadata
            let updated = metadata.detachedCopy()
            renamed.append((metadata.ocId, metadata.fileName, rename.newName))
            queued.remove(metadata.fileName)
            queued.insert(rename.newName)
            for queuedRow in queue where queuedRow.ocId == metadata.ocId {
                queuedRow.fileName = rename.newName
                queuedRow.fileNameView = rename.newName
            }
            updated.fileName = rename.newName
            updated.fileNameView = rename.newName
            updated.serverUrlFileName = NCConflictNaming.join(metadata.serverUrl, rename.newName)
            if let livePhotoFile = rename.livePhotoFile { updated.livePhotoFile = livePhotoFile }
            rows.append(updated)
        }
        return rows
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

    @Test("A free name that another photo of the phone is about to take: Smart and Keep both rename, Keep the NoDrive copy waits, Keep the phone copy replaces by choice")
    func nameTakenByOtherPhoto() {
        let taken = NCConflictPart(name: "IMG_0001.HEIC", localSize: 100, remote: .missing, takenByOther: true)
        #expect(NCConflictDecision.decide(policy: .smart, parts: [taken]) == .renameAll)
        #expect(NCConflictDecision.decide(policy: .keepBoth, parts: [taken]) == .renameAll)
        #expect(NCConflictDecision.decide(policy: .keepNoDrive, parts: [taken]) == .retryLater)
        #expect(NCConflictDecision.decide(policy: .keepPhone, parts: [taken]) == .upload(skipping: []))
        // An answer that is not clear still wins: retry later.
        let unclear = NCConflictPart(name: "IMG_0001.MOV", localSize: 100, remote: .unknown)
        #expect(NCConflictDecision.decide(policy: .smart, parts: [taken, unclear]) == .retryLater)
        // One part of a Live Photo is enough for both to get a number.
        let free = NCConflictPart(name: "IMG_0001.MOV", localSize: 100, remote: .missing)
        #expect(NCConflictDecision.decide(policy: .smart, parts: [free, taken]) == .renameAll)
        #expect(NCConflictDecision.decide(policy: .keepBoth, parts: [free, taken]) == .renameAll)
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

    private func probe(answering error: NKError, data: Data? = nil) -> NCWebDAVProbe {
        NCWebDAVProbe(call: { _, _, _ in NCPropfindAnswer(error: error, data: data) })
    }

    @Test("The answer of the server becomes the state: 404 is missing, any other error is unknown")
    func statusMapping() async {
        let answers: [(Int, NCConflictRemoteState)] = [(404, .missing), (401, .unknown), (403, .unknown), (423, .unknown),
                                                       (500, .unknown), (503, .unknown), (-1001, .unknown)]
        for (code, expected) in answers {
            let state = await probe(answering: NKError(errorCode: code, errorDescription: "test")).state(of: "https://x/y", account: account)
            #expect(state == expected, "status \(code)")
        }
    }

    @Test("No session (the library answers with an error of its own) is unknown, never missing")
    func noSession() async {
        let state = await probe(answering: NKError.urlError).state(of: "https://x/y", account: account)
        #expect(state == .unknown)
    }

    @Test("A good answer is read: a file with its size, a folder; a body that is missing or unreadable is unknown")
    func successMapping() async {
        let file = await probe(answering: .success, data: Data(Self.fileAnswer.utf8)).state(of: "https://x/y", account: account)
        #expect(file == .file(size: 12345))
        let folder = await probe(answering: .success, data: Data(Self.folderAnswer.utf8)).state(of: "https://x/y", account: account)
        #expect(folder == .folder)
        let noBody = await probe(answering: .success).state(of: "https://x/y", account: account)
        #expect(noBody == .unknown)
        let junk = await probe(answering: .success, data: Data("nope".utf8)).state(of: "https://x/y", account: account)
        #expect(junk == .unknown)
    }

    @Test("The probe asks for the url of the name with the account's own session and the request body")
    func askedWith() async {
        final class Seen: @unchecked Sendable {
            var url = ""
            var body: Data?
            var account = ""
        }
        let seen = Seen()
        let probe = NCWebDAVProbe(call: { url, body, account in
            seen.url = url
            seen.body = body
            seen.account = account
            return NCPropfindAnswer(error: NKError(errorCode: 404, errorDescription: "Not Found"), data: nil)
        })
        let state = await probe.state(of: "https://x/y/IMG.HEIC", account: "acc")
        #expect(state == .missing)
        #expect(seen.url == "https://x/y/IMG.HEIC")
        #expect(seen.account == "acc")
        #expect(seen.body == Data(NCWebDAVProbe.requestBodyText.utf8))
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

    @Test("Two upload passes at the same time never give one new name to two photos")
    func overlappingPasses() async {
        let store = FakeStore()
        let probe = FakeProbe()
        probe.pauseNanoseconds = 5_000_000
        probe.set("IMG_0001.JPG", .file(size: 99))
        let (resolver, _) = makeResolver(store, probe)
        let first = row("a", "IMG_0001.JPG", asset: "ASSET-A")
        let second = row("b", "IMG_0001.JPG", asset: "ASSET-B")
        async let one = resolver.resolve([first])
        async let two = resolver.resolve([second])
        let results = await [one, two]
        #expect(results.map(\.count) == [1, 1])
        let names = results.flatMap { $0.map(\.fileName) }
        #expect(Set(names) == ["IMG_0001 1.JPG", "IMG_0001 2.JPG"])
        #expect(store.renamed.count == 2)
        #expect(Set(store.renamed.map(\.to)).count == 2)
    }

    @Test("Two photos with one name, the Drive has neither: one uploads as is, the other gets the next number")
    func sameNameTwoAssetsSmartAndKeepBoth() async {
        for policy in [NCConflictPolicy.smart, .keepBoth] {
            let store = FakeStore()
            store.policies[account] = policy
            let first = row("a", "IMG_0001.JPG", asset: "ASSET-A")
            let second = row("b", "IMG_0001.JPG", asset: "ASSET-B")
            store.queue = [first, second]
            let (resolver, _) = makeResolver(store, FakeProbe())
            let result = await resolver.resolve([first, second])
            #expect(Set(result.map(\.fileName)) == ["IMG_0001.JPG", "IMG_0001 1.JPG"], "\(policy)")
            #expect(result.count == 2)
            #expect(store.renamed.count == 1)
            #expect(store.done.isEmpty)
        }
    }

    @Test("Two photos with one name, the other already uploading in the background session: this one gets a number")
    func sameNameOtherIsUploading() async {
        let store = FakeStore()
        let uploading = row("u", "IMG_0001.JPG", asset: "ASSET-A")
        uploading.status = NCGlobal.shared.metadataStatusUploading
        let waitingRow = row("a", "IMG_0001.JPG", asset: "ASSET-B")
        store.queue = [uploading, waitingRow]
        let (resolver, _) = makeResolver(store, FakeProbe())
        let result = await resolver.resolve([waitingRow])
        #expect(result.map(\.fileName) == ["IMG_0001 1.JPG"])
    }

    @Test("Two photos with one name under Keep the NoDrive copy: the one that goes second waits, they never wait for each other")
    func sameNameKeepNoDriveWaits() async {
        let store = FakeStore()
        store.policies[account] = .keepNoDrive
        let first = row("a", "IMG_0001.JPG", asset: "ASSET-A")
        let second = row("b", "IMG_0001.JPG", asset: "ASSET-B")
        store.queue = [first, second]
        let (resolver, _) = makeResolver(store, FakeProbe())
        let result = await resolver.resolve([first, second])
        #expect(result.map(\.ocId) == ["a"])
        #expect(store.done.isEmpty && store.renamed.isEmpty)
    }

    @Test("Two Live Photos with one name, photo and video ocIds crossed, Keep the NoDrive copy: one pair uploads, the other waits, then is done")
    func sameNameLivePhotosKeepNoDrive() async {
        let store = FakeStore()
        store.policies[account] = .keepNoDrive
        // The photo of A sorts before the photo of B, the video of B before the video of A.
        let photoA = row("p-a", "IMG_0001.HEIC", asset: "ASSET-A", kind: .photo)
        let videoA = row("v-b", "IMG_0001.mov", asset: "ASSET-A", kind: .video, size: 50)
        let photoB = row("p-b", "IMG_0001.HEIC", asset: "ASSET-B", kind: .photo)
        let videoB = row("v-a", "IMG_0001.mov", asset: "ASSET-B", kind: .video, size: 50)
        store.queue = [photoA, videoA, photoB, videoB]
        let probe = FakeProbe()
        let (resolver, _) = makeResolver(store, probe)

        var result = await resolver.resolve([photoA, videoA, photoB, videoB])
        #expect(result.map(\.ocId) == ["p-a", "v-b"], "exactly one pair uploads")
        #expect(store.done.isEmpty && store.renamed.isEmpty)

        // The next pass: the first pair is still in flight, the second one keeps waiting (both parts together).
        result = await resolver.resolve([photoB, videoB])
        #expect(result.isEmpty)
        #expect(store.done.isEmpty)

        // The first pair is uploaded and gone from the queue: its names are on the Drive, the second pair is done.
        store.queue.removeAll { $0.assetLocalIdentifier == "ASSET-A" }
        probe.set("IMG_0001.HEIC", .file(size: 100))
        probe.set("IMG_0001.mov", .file(size: 50))
        result = await resolver.resolve([photoB, videoB])
        #expect(result.isEmpty)
        #expect(Set(store.done) == ["p-b", "v-a"])
    }

    @Test("Two Live Photos with one name, Smart: the second pair gets one common number for both parts")
    func sameNameLivePhotosSmart() async {
        let store = FakeStore()
        let photoA = row("p-a", "IMG_0001.HEIC", asset: "ASSET-A", kind: .photo)
        let videoA = row("v-b", "IMG_0001.mov", asset: "ASSET-A", kind: .video, size: 50)
        let photoB = row("p-b", "IMG_0001.HEIC", asset: "ASSET-B", kind: .photo)
        let videoB = row("v-a", "IMG_0001.mov", asset: "ASSET-B", kind: .video, size: 50)
        store.queue = [photoA, videoA, photoB, videoB]
        let (resolver, _) = makeResolver(store, FakeProbe())
        let result = await resolver.resolve([photoA, videoA, photoB, videoB])
        #expect(result.map(\.fileName) == ["IMG_0001.HEIC", "IMG_0001.mov", "IMG_0001 1.HEIC", "IMG_0001 1.mov"])
        #expect(Set(store.renamed.map { $0.ocId }) == ["p-b", "v-a"])
    }

    @Test("A waiting photo only waits for one that was handed out: a row behind it in the queue never blocks it")
    func waitingPhotoIsNotBlockedByRowBehindIt() async {
        let store = FakeStore()
        store.policies[account] = .keepNoDrive
        // "a" has the smaller ocId but is not part of this pass (it sits behind in the queue).
        let behind = row("a", "IMG_0001.JPG", asset: "ASSET-A")
        let head = row("z", "IMG_0001.JPG", asset: "ASSET-B")
        store.queue = [head, behind]
        let (resolver, _) = makeResolver(store, FakeProbe())
        let result = await resolver.resolve([head])
        #expect(result.map(\.ocId) == ["z"], "the one at the head of the queue uploads, it does not wait")
        // The row behind it waits for the one in flight, and only for it.
        let later = await resolver.resolve([behind])
        #expect(later.isEmpty)
    }

    @Test("A claim ends when its row has left the queue: a failed upload never blocks the name")
    func staleClaimDoesNotBlock() async {
        let store = FakeStore()
        store.policies[account] = .keepNoDrive
        let first = row("a", "IMG_0001.JPG", asset: "ASSET-A")
        let second = row("b", "IMG_0001.JPG", asset: "ASSET-B")
        store.queue = [first, second]
        let (resolver, _) = makeResolver(store, FakeProbe())
        #expect(await resolver.resolve([first, second]).map(\.ocId) == ["a"])
        first.status = NCGlobal.shared.metadataStatusUploadError
        #expect(await resolver.resolve([second]).map(\.ocId) == ["b"])
    }

    @Test("A photo with the same asset (its own seed) or a name nobody else uses is not taken")
    func sameAssetIsNotTaken() async {
        let store = FakeStore()
        let item = row("a", "IMG_0001.JPG", asset: "ASSET-A")
        store.queue = [item, row("z", "IMG_0001.JPG", asset: "ASSET-A"), row("y", "IMG_0002.JPG", asset: "ASSET-B")]
        let (resolver, _) = makeResolver(store, FakeProbe())
        let result = await resolver.resolve([item])
        #expect(result.map(\.fileName) == ["IMG_0001.JPG"])
        #expect(store.renamed.isEmpty)
    }

    @Test("Keep the phone copy still uploads as is, even when another photo uses the name (the owner chose to replace)")
    func sameNameKeepPhone() async {
        let store = FakeStore()
        store.policies[account] = .keepPhone
        let first = row("a", "IMG_0001.JPG", asset: "ASSET-A")
        let second = row("b", "IMG_0001.JPG", asset: "ASSET-B")
        store.queue = [first, second]
        let (resolver, _) = makeResolver(store, FakeProbe())
        let result = await resolver.resolve([first, second])
        #expect(result.map(\.fileName) == ["IMG_0001.JPG", "IMG_0001.JPG"])
        #expect(store.renamed.isEmpty)
    }

    @Test("The lock is let go on every path: a pass that ends in retry later does not block the next one")
    func lockIsReleased() async {
        let store = FakeStore()
        let probe = FakeProbe()
        probe.pauseNanoseconds = 1_000_000
        probe.set("A.HEIC", .unknown)
        let (resolver, _) = makeResolver(store, probe)
        async let blocked = resolver.resolve([row("a", "A.HEIC", asset: "ASSET-A")])
        async let free = resolver.resolve([row("b", "B.HEIC", asset: "ASSET-B")])
        let results = await [blocked, free]
        #expect(results.map { $0.map(\.fileName) } == [[], ["B.HEIC"]])
    }

    @Test("Live Photo, a file copy fails: neither part is renamed, nothing is recorded, nothing uploads")
    func livePhotoCopyFails() async {
        let store = FakeStore()
        store.failRename = true
        let probe = FakeProbe()
        probe.set("IMG_0001.HEIC", .file(size: 100))
        probe.set("IMG_0001.mov", .file(size: 49))
        let (resolver, ledger) = makeResolver(store, probe)
        let result = await resolver.resolve([row("p", "IMG_0001.HEIC", kind: .photo),
                                             row("v", "IMG_0001.mov", kind: .video, size: 50)])
        #expect(result.isEmpty)
        #expect(store.renamed.isEmpty)
        #expect(store.done.isEmpty)
        #expect(await ledger.count == 0)
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

// MARK: - The real store (the test app's database and file system)

@Suite("NoDrive conflict database store")
struct NoDriveConflictDatabaseStoreTests {
    private let urlBase = "https://nodrive-test.invalid"
    private let userId = "citest-store"
    // A host that cannot exist: nothing in the test app can reach a real server with these rows.
    private let storeAccount = "citest-store https://nodrive-test.invalid"
    private let dbServerUrl = "https://nodrive-test.invalid/remote.php/dav/files/citest-store/Camera"
    private let store = NCDatabaseConflictStore()
    private let utility = NCUtilityFileSystem()

    private func folder(_ ocId: String) -> String {
        utility.getDirectoryProviderStorageOcId(ocId, userId: userId, urlBase: urlBase)
    }

    /// A waiting Auto upload item with its extracted file (`bytes` long) in the app's storage.
    private func make(_ ocId: String, _ name: String, kind: Kind = .plain, bytes: Int, asset: String) async throws -> tableMetadata {
        let metadata = row(ocId, name, asset: asset, kind: kind, size: 1)
        metadata.userId = userId
        metadata.urlBase = urlBase
        metadata.account = storeAccount
        metadata.serverUrl = dbServerUrl
        metadata.serverUrlFileName = NCConflictNaming.join(dbServerUrl, name)
        metadata.autoUploadServerUrlBase = dbServerUrl
        try Data(count: bytes).write(to: URL(fileURLWithPath: folder(ocId) + "/" + name))
        await NCManageDatabase.shared.addMetadataAsync(metadata)
        return metadata
    }

    private func stored(_ ocId: String) async -> tableMetadata? {
        await NCManageDatabase.shared.getMetadataAsync(predicate: NSPredicate(format: "ocId == %@", ocId))
    }

    private func exists(_ ocId: String, _ name: String) -> Bool {
        FileManager.default.fileExists(atPath: folder(ocId) + "/" + name)
    }

    /// The old copy is dropped on a background queue: wait a moment for it.
    private func waitUntilGone(_ ocId: String, _ name: String) async -> Bool {
        for _ in 0..<50 {
            if !exists(ocId, name) { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return false
    }

    /// Removes the rows and files this test made (its own, by their unique ids).
    private func clean(_ ocIds: [String]) async {
        for ocId in ocIds {
            await NCManageDatabase.shared.deleteMetadataAsync(ocId: ocId)
            try? FileManager.default.removeItem(atPath: folder(ocId))
        }
    }

    @Test("The size is the one of the extracted file; the queue is asked by name, folder and account")
    func sizeAndQueue() async throws {
        let id = "ndtest-" + UUID().uuidString
        let item = try await make(id, "IMG_0001.HEIC", bytes: 7, asset: "ASSET-S1")
        #expect(store.localSize(of: item) == 7)
        #expect(await store.isNameQueued("IMG_0001.HEIC", serverUrl: dbServerUrl, account: storeAccount))
        #expect(await store.isNameQueued("IMG_0001 1.HEIC", serverUrl: dbServerUrl, account: storeAccount) == false)
        #expect(await store.isNameQueued("IMG_0001.HEIC", serverUrl: dbServerUrl + "/Other", account: storeAccount) == false)
        await clean([id])
    }

    @Test("Another photo with the same name in the queue: only an uploading one counts, a waiting one never; the same asset never")
    func nameUploadingByOtherItem() async throws {
        let low = "ndtest-a-" + UUID().uuidString
        let high = "ndtest-b-" + UUID().uuidString
        let same = "ndtest-c-" + UUID().uuidString
        let lowItem = try await make(low, "IMG_0009.HEIC", bytes: 3, asset: "ASSET-T1")
        let highItem = try await make(high, "IMG_0009.HEIC", bytes: 3, asset: "ASSET-T2")
        // Two waiting photos never count for each other (the resolver orders them with its own claims).
        #expect(await store.isNameUploadingByOtherItem(lowItem) == false)
        #expect(await store.isNameUploadingByOtherItem(highItem) == false)
        // An uploading row of the same asset never counts.
        let sameAsset = try await make(same, "IMG_0009.HEIC", bytes: 3, asset: "ASSET-T1")
        let sameUploading = sameAsset.detachedCopy()
        sameUploading.status = NCGlobal.shared.metadataStatusUploading
        await NCManageDatabase.shared.addMetadataAsync(sameUploading)
        #expect(await store.isNameUploadingByOtherItem(lowItem) == false)
        // An uploading row of another asset counts for every other photo.
        let uploading = highItem.detachedCopy()
        uploading.status = NCGlobal.shared.metadataStatusUploading
        await NCManageDatabase.shared.addMetadataAsync(uploading)
        #expect(await store.isNameUploadingByOtherItem(lowItem))
        // Another name is not taken.
        #expect(await store.isNameUploadingByOtherItem(row("zz", "IMG_0010.HEIC", asset: "ASSET-T3")) == false)
        await clean([low, high, same])
    }

    @Test("The rows that are still in the queue: waiting or uploading, not an error, not a missing row")
    func activeOcIds() async throws {
        let waitingId = "ndtest-w-" + UUID().uuidString
        let errorId = "ndtest-e-" + UUID().uuidString
        let waitingItem = try await make(waitingId, "IMG_0011.HEIC", bytes: 3, asset: "ASSET-T4")
        let errorItem = try await make(errorId, "IMG_0012.HEIC", bytes: 3, asset: "ASSET-T5")
        let failed = errorItem.detachedCopy()
        failed.status = NCGlobal.shared.metadataStatusUploadError
        await NCManageDatabase.shared.addMetadataAsync(failed)
        let active = await store.activeOcIds(among: [waitingItem.ocId, errorId, "ndtest-missing"])
        #expect(active == [waitingId])
        #expect(await store.activeOcIds(among: []).isEmpty)
        await clean([waitingId, errorId])
    }

    @Test("A rename moves the extracted file with the row: the new name is in the database, the old one is gone")
    func renameOne() async throws {
        let id = "ndtest-" + UUID().uuidString
        let item = try await make(id, "IMG_0001.HEIC", bytes: 7, asset: "ASSET-S2")
        let rows = await store.rename([NCConflictRename(metadata: item, newName: "IMG_0001 1.HEIC", livePhotoFile: nil)])
        #expect(rows?.map(\.fileName) == ["IMG_0001 1.HEIC"])
        let saved = await stored(id)
        #expect(saved?.fileName == "IMG_0001 1.HEIC")
        #expect(saved?.fileNameView == "IMG_0001 1.HEIC")
        #expect(saved?.serverUrlFileName == NCConflictNaming.join(dbServerUrl, "IMG_0001 1.HEIC"))
        #expect(exists(id, "IMG_0001 1.HEIC"))
        #expect(store.localSize(of: saved ?? item) == 7)
        #expect(await waitUntilGone(id, "IMG_0001.HEIC"))
        #expect(await store.isNameQueued("IMG_0001.HEIC", serverUrl: dbServerUrl, account: storeAccount) == false)
        #expect(await store.isNameQueued("IMG_0001 1.HEIC", serverUrl: dbServerUrl, account: storeAccount))
        await clean([id])
    }

    @Test("A Live Photo: the partner is found in the queue, both rows get the new name and point at each other")
    func renamePair() async throws {
        let photoId = "ndtest-" + UUID().uuidString
        let videoId = "ndtest-" + UUID().uuidString
        let photo = try await make(photoId, "IMG_0002.HEIC", kind: .photo, bytes: 5, asset: "ASSET-S3")
        let video = try await make(videoId, "IMG_0002.mov", kind: .video, bytes: 9, asset: "ASSET-S3")
        #expect(await store.mate(of: photo)?.ocId == videoId)
        #expect(await store.mate(of: video)?.ocId == photoId)
        let rows = await store.rename([NCConflictRename(metadata: photo, newName: "IMG_0002 1.HEIC", livePhotoFile: "IMG_0002 1.mov"),
                                       NCConflictRename(metadata: video, newName: "IMG_0002 1.mov", livePhotoFile: "IMG_0002 1.HEIC")])
        #expect(rows?.count == 2)
        let newPhoto = await stored(photoId)
        let newVideo = await stored(videoId)
        #expect(newPhoto?.fileName == "IMG_0002 1.HEIC")
        #expect(newPhoto?.livePhotoFile == "IMG_0002 1.mov")
        #expect(newVideo?.fileName == "IMG_0002 1.mov")
        #expect(newVideo?.livePhotoFile == "IMG_0002 1.HEIC")
        #expect(exists(photoId, "IMG_0002 1.HEIC") && exists(videoId, "IMG_0002 1.mov"))
        await clean([photoId, videoId])
    }

    @Test("A Live Photo whose second copy fails: nothing changes, the first new copy is dropped, no row is renamed")
    func renamePairFails() async throws {
        let photoId = "ndtest-" + UUID().uuidString
        let videoId = "ndtest-" + UUID().uuidString
        let photo = try await make(photoId, "IMG_0003.HEIC", kind: .photo, bytes: 5, asset: "ASSET-S4")
        let video = try await make(videoId, "IMG_0003.mov", kind: .video, bytes: 9, asset: "ASSET-S4")
        // A folder that does not exist makes the second copy fail.
        let rows = await store.rename([NCConflictRename(metadata: photo, newName: "IMG_0003 1.HEIC", livePhotoFile: "x"),
                                       NCConflictRename(metadata: video, newName: "no-such-folder/IMG_0003 1.mov", livePhotoFile: "y")])
        #expect(rows == nil)
        #expect(await stored(photoId)?.fileName == "IMG_0003.HEIC")
        #expect(await stored(videoId)?.fileName == "IMG_0003.mov")
        #expect(await stored(photoId)?.livePhotoFile == "IMG_0003.mov")
        #expect(exists(photoId, "IMG_0003.HEIC") && exists(videoId, "IMG_0003.mov"))
        #expect(await waitUntilGone(photoId, "IMG_0003 1.HEIC"))
        await clean([photoId, videoId])
    }
}
