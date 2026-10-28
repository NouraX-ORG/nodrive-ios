// SPDX-FileCopyrightText: 2026 Nourax
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// The numbering of the second copy: `name.ext` -> `name 1.ext` -> `name 2.ext`. A name that already ends in
/// " <number>" counts on (`IMG 3.JPG` -> `IMG 4.JPG`), exactly as `NCNetworking.createFileName` does. Unlike that
/// function, this one fails closed: any server answer other than "404 free" or "taken" ends in `nil` (try again
/// later), and it never hands out a name that may be taken.
enum NCConflictNaming {
    static let maxAttempts = 100

    /// `IMG_0001` -> `IMG_0001 1`; `IMG 3` -> `IMG 4`.
    static func nextStem(_ stem: String) -> String {
        if let space = stem.range(of: " ", options: .backwards) {
            let prefix = String(stem[..<space.lowerBound])
            let suffix = String(stem[space.upperBound...])
            if let number = Int(suffix), number >= 0 {
                return "\(prefix) \(number + 1)"
            }
        }
        return stem + " 1"
    }

    /// `IMG_0001.JPG` -> `IMG_0001 1.JPG`; a name without an extension gets the number at its end.
    static func nextName(after name: String) -> String {
        let ns = name as NSString
        let ext = ns.pathExtension
        let stem = ns.deletingPathExtension
        return ext.isEmpty ? nextStem(stem) : nextStem(stem) + "." + ext
    }

    static func join(_ serverUrl: String, _ name: String) -> String {
        serverUrl.last == "/" ? serverUrl + name : serverUrl + "/" + name
    }

    /// The first number that is free for every name (one file, or the two parts of a Live Photo).
    ///
    /// A candidate is free when the server answers 404 for all its names, no queued item of the app uses one of
    /// them, and none was handed out earlier in the same pass (`reserved`). Returns the new names in the order of
    /// `names`, or `nil` when a server answer is not clear or 100 candidates were taken (retry later).
    static func freeNames(for names: [String],
                          serverUrl: String,
                          account: String,
                          probe: NCRemoteProbe,
                          isQueued: (String) async -> Bool,
                          reserved: Set<String> = []) async -> [String]? {
        var candidates = names
        for _ in 0..<maxAttempts {
            candidates = candidates.map(nextName(after:))
            var free = true
            for candidate in candidates {
                if reserved.contains(candidate) {
                    free = false
                    break
                }
                if await isQueued(candidate) {
                    free = false
                    break
                }
                switch await probe.state(of: join(serverUrl, candidate), account: account) {
                case .missing:
                    continue
                case .file, .folder:
                    free = false
                case .unknown:
                    return nil
                }
                if !free { break }
            }
            if free { return candidates }
        }
        return nil
    }
}
