// SPDX-FileCopyrightText: 2026 Nourax
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// What one PROPFIND (Depth 0) says about a name in the destination folder.
enum NCConflictRemoteState: Equatable {
    /// 404: nothing has this name.
    case missing
    /// A file; `size` is its `getcontentlength` in bytes.
    case file(size: Int64)
    /// A folder has this name.
    case folder
    /// Any other answer: 401, 403, 423, 5xx, a timeout, or a file answer without a size. Never guessed.
    case unknown

    var exists: Bool {
        switch self {
        case .file, .folder: return true
        case .missing, .unknown: return false
        }
    }
}

/// One file of a decision: a photo or video, or one of the two parts of a Live Photo.
struct NCConflictPart: Equatable {
    let name: String
    /// Size in bytes of the file the app will upload.
    let localSize: Int64
    let remote: NCConflictRemoteState
}

/// The outcome for one file or one Live Photo. Pure logic, no I/O.
enum NCConflictDecision: Equatable {
    /// Upload every part under its own name, except the parts at these indexes: they are already in NoDrive and are
    /// marked as done. Under "Keep the phone copy" nothing is skipped and the NoDrive file is replaced.
    case upload(skipping: [Int])
    /// Upload all parts under the first free common number (`IMG_0001 1.HEIC` with `IMG_0001 1.MOV`).
    case renameAll
    /// Nothing is uploaded and nothing is marked; the item stays waiting and is tried again on the next pass.
    case retryLater

    /// Decides for one file (one part) or for a Live Photo (two parts, always decided together).
    static func decide(policy: NCConflictPolicy, parts: [NCConflictPart]) -> NCConflictDecision {
        switch policy {
        case .keepPhone:
            // Replaces the NoDrive file. The answer of the server is not needed.
            return .upload(skipping: [])

        case .keepNoDrive:
            if parts.contains(where: { $0.remote == .unknown }) { return .retryLater }
            return .upload(skipping: parts.indices.filter { parts[$0].remote.exists })

        case .keepBoth:
            if parts.contains(where: { $0.remote == .unknown }) { return .retryLater }
            return parts.contains(where: { $0.remote.exists }) ? .renameAll : .upload(skipping: [])

        case .smart:
            if parts.contains(where: { $0.remote == .unknown }) { return .retryLater }
            var skipping: [Int] = []
            for (index, part) in parts.enumerated() {
                switch part.remote {
                case .missing, .unknown:
                    continue
                case .folder:
                    return .renameAll
                case .file(let size):
                    // A local size that cannot be read is never compared.
                    if part.localSize <= 0 { return .retryLater }
                    if size != part.localSize { return .renameAll }
                    skipping.append(index)
                }
            }
            return .upload(skipping: skipping)
        }
    }
}
