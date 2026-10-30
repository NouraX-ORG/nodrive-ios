// SPDX-FileCopyrightText: 2026 Nourax
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

// UI tests only. The code exists in Debug builds only: a Release build gets the stub in the #else branch, and
// tools/check-branding.py checks that this file keeps its #if DEBUG wrapper.
#if DEBUG

enum NCAgendaUITestHooks {
    /// "yyyy-MM-dd" in the variable NODRIVE_AGENDA_TODAY pins "today" to the day the CI server was seeded for, so a
    /// run that crosses midnight still shows the seeded data. Only with the launch argument UI_TESTING.
    static var today: Date? {
        let info = ProcessInfo.processInfo
        guard info.arguments.contains("UI_TESTING"), let text = info.environment["NODRIVE_AGENDA_TODAY"] else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        guard let day = formatter.date(from: text) else { return nil }
        // Noon, so a zone difference never moves the day.
        return Calendar.current.date(byAdding: .hour, value: 12, to: day)
    }
}

#else

enum NCAgendaUITestHooks {
    static var today: Date? { nil }
}

#endif
