// SPDX-FileCopyrightText: 2026 Nourax
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import UIKit

// UI tests only. A test run signs an account in by itself (the real sign-in page cannot be driven by a test).
// The code exists in Debug builds only: a Release build gets the empty stub in the #else branch below, and
// tools/check-branding.py checks that this file keeps its #if DEBUG wrapper.
#if DEBUG

/// With the launch argument UI_TESTING and the environment variable NODRIVE_UITEST_ACCOUNT
/// ("server URL|login name|app password") the app creates that account at launch, exactly like a finished
/// sign-in does (the same NCAccount().createAccount call). CI passes a throwaway value created for a stand-in
/// server; the value is never logged.
enum NCUITestAccount {
    @MainActor
    static func injectIfRequested() async {
        let info = ProcessInfo.processInfo
        guard info.arguments.contains("UI_TESTING"),
              let value = info.environment["NODRIVE_UITEST_ACCOUNT"] else { return }
        let parts = value.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, !parts[0].isEmpty, !parts[1].isEmpty, !parts[2].isEmpty else { return }

        // Wait for the first screen (the intro) of a launch without an account.
        for _ in 0..<240 {
            if let window = UIApplication.shared.mainAppWindow,
               window.rootViewController is UINavigationController {
                break
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        guard let window = UIApplication.shared.mainAppWindow,
              let presenter = window.rootViewController else { return }
        await NCAccount().createAccount(viewController: presenter,
                                        urlBase: parts[0],
                                        user: parts[1],
                                        password: parts[2],
                                        controller: nil)
    }
}

#else

enum NCUITestAccount {
    @MainActor
    static func injectIfRequested() async {}
}

#endif
