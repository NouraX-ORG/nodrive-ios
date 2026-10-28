// SPDX-FileCopyrightText: 2026 Nourax
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// What Auto upload does when a file with the same name is already in the destination folder on the Drive.
/// One choice per account ("If a file is already in NoDrive" in the Auto upload settings). There is no "ask":
/// Auto upload runs in the background.
enum NCConflictPolicy: String, CaseIterable, Equatable {
    /// Skip it when the NoDrive copy has the same size, otherwise keep both. The default.
    case smart = "smart"
    /// Do not upload the phone copy.
    case keepNoDrive = "keep-nodrive"
    /// Upload the phone copy and replace the NoDrive file.
    case keepPhone = "keep-phone"
    /// Upload the phone copy under a new numbered name.
    case keepBoth = "keep-both"

    static let defaultPolicy: NCConflictPolicy = .smart

    /// The NoDrive-owned string table of this feature (SmartConflicts/en.lproj/SmartConflicts.strings).
    static let tableName = "SmartConflicts"

    static func text(_ key: String) -> String {
        NSLocalizedString(key, tableName: tableName, comment: "")
    }

    /// Title of the setting itself (the row in Auto upload and the title of the choice list).
    static var settingTitle: String { text("_nodrive_conflict_setting_") }

    var title: String {
        switch self {
        case .smart: return Self.text("_nodrive_conflict_smart_")
        case .keepNoDrive: return Self.text("_nodrive_conflict_keep_nodrive_")
        case .keepPhone: return Self.text("_nodrive_conflict_keep_phone_")
        case .keepBoth: return Self.text("_nodrive_conflict_keep_both_")
        }
    }

    /// Only Smart has a summary line.
    var summary: String? {
        self == .smart ? Self.text("_nodrive_conflict_smart_summary_") : nil
    }

    /// Accessibility identifier of the row in the choice list.
    var rowIdentifier: String { "nodriveConflict-" + rawValue }
}

/// The choice, per account, in the app group's user defaults (the suite NCPreferences uses). A missing or an
/// unknown value reads as Smart. Nothing is stored in Realm, so there is no schema migration.
struct NCConflictPolicyStore {
    private let defaults: UserDefaults

    init(defaults: UserDefaults? = nil) {
        self.defaults = defaults
            ?? UserDefaults(suiteName: NCBrandOptions.shared.capabilitiesGroup)
            ?? .standard
    }

    static func key(account: String) -> String {
        "NoDriveAutoUploadConflictPolicy_" + account
    }

    func policy(account: String) -> NCConflictPolicy {
        guard let raw = defaults.string(forKey: Self.key(account: account)),
              let policy = NCConflictPolicy(rawValue: raw) else {
            return NCConflictPolicy.defaultPolicy
        }
        return policy
    }

    func setPolicy(_ policy: NCConflictPolicy, account: String) {
        defaults.set(policy.rawValue, forKey: Self.key(account: account))
    }
}
