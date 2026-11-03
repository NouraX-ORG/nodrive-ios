// SPDX-FileCopyrightText: 2026 Nourax
// SPDX-License-Identifier: GPL-3.0-or-later

import UIKit

/// When a NoDrive account is removed: if a profile was offered to this iPhone, tell the person how to remove it
/// (the app cannot remove a profile itself). Nothing on the phone is changed or deleted by NoDrive.
enum NCDeviceSyncRemoval {
    /// What shows the message. The tests replace it.
    @MainActor
    static var present: (_ title: String, _ message: String) -> Void = { title, message in
        guard let window = UIApplication.shared.mainAppWindow ?? UIApplication.shared.connectedScenes
            .compactMap({ ($0 as? UIWindowScene)?.windows.first(where: { $0.isKeyWindow }) }).first else { return }
        var top = window.rootViewController
        while let next = top?.presentedViewController {
            top = next
        }
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: NSLocalizedString("_ok_", comment: ""), style: .default))
        top?.present(alert, animated: true)
    }

    /// How long to wait before the message shows: the app swaps its main screen when the last account goes.
    @MainActor
    static var delay: Duration = .milliseconds(1500)

    static var state = NCDeviceSyncState()

    /// Called by `NCAccount.deleteAccount`. True when the message was queued.
    @MainActor
    @discardableResult
    static func accountRemoved(account: String) async -> Bool {
        guard state.profileOffered(account: account) else { return false }
        state.setProfileOffered(false, account: account)
        NCDeviceSyncLog.log("account-removed-with-profile")
        let title = NCDeviceSync.text("_nodrive_devicesync_removal_title_")
        let message = NCDeviceSync.text("_nodrive_devicesync_removal_message_")
        let wait = delay
        Task { @MainActor in
            try? await Task.sleep(for: wait)
            present(title, message)
        }
        return true
    }
}
