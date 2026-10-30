// SPDX-FileCopyrightText: 2026 Nourax
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import UIKit

/// The sidebar entry of NoAgenda: first item of the Apps section, above the server's Workspace apps.
enum NCAgendaEntry {
    static let title = "NoAgenda"
    static let symbolName = "calendar.day.timeline.left"
    static let sidebarIdentifier = "sidebarNoAgenda"

    /// NoAgenda is there for every signed-in account (it does not depend on what the server lists).
    static func isShown(account: String) -> Bool {
        !account.isEmpty
    }
}

/// The links of "Open in NoCalendar / NoTasks / NoGantt / NoBoard" (design 2.5.5). All relative to the account's
/// server and opened signed in.
enum NCAgendaWebLinks {
    static func homePath(_ home: AgendaHome) -> String {
        switch home {
        case .calendar: return "index.php/apps/calendar/"
        case .tasks: return "index.php/apps/tasks/"
        case .gantt: return "index.php/apps/nc_gantt/"
        case .board: return "index.php/apps/deck/"
        }
    }

    private static let unreserved = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))

    static func encode(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: unreserved) ?? text
    }

    /// The path of the item's own page, or the app's start page when the item can't be addressed.
    static func path(for link: AgendaLink) -> String {
        switch link.home {
        case .calendar:
            guard let object = link.path, let encoded = object.data(using: .utf8)?.base64EncodedString() else { return homePath(.calendar) }
            var path = "index.php/apps/calendar/edit/" + encode(encoded)
            if let instance = link.recurrence { path += "/" + String(Int(instance.timeIntervalSince1970)) }
            return path
        case .tasks:
            guard let calendar = link.calendarUri, let file = link.fileName else { return homePath(.tasks) }
            return "index.php/apps/tasks/calendars/" + encode(calendar) + "/tasks/" + encode(file)
        case .gantt:
            guard let project = link.projectId else { return homePath(.gantt) }
            var path = homePath(.gantt) + "?project=\(project)"
            if let task = link.taskId { path += "&task=\(task)" }
            return path
        case .board:
            guard let card = link.cardId ?? link.deckCardId else { return homePath(.board) }
            return "index.php/apps/deck/card/\(card)"
        }
    }

    static func url(for link: AgendaLink, base: String) -> URL? {
        guard let resolved = NCWorkspaceOrigin.resolve(path(for: link), base: base),
              NCWorkspaceOrigin.isSameOrigin(resolved, base: base) else { return nil }
        return URL(string: resolved)
    }

    static func homeURL(_ home: AgendaHome, base: String) -> URL? {
        url(for: AgendaLink(home: home), base: base)
    }
}

extension NCMainTabBarController {
    /// NoAgenda in the main area (the "Browse" tab), like the Workspace apps.
    func openSidebarAgenda() {
        let account = self.account
        let model = NCAgendaViewModel(account: account)
        let hosting = UIHostingController(rootView: NCAgendaRootView(model: model))
        hosting.title = NCAgendaEntry.title
        hosting.restorationIdentifier = NCAgendaEntry.sidebarIdentifier
        model.openPage = { [weak hosting] url, title in
            let web = NCWorkspaceWebViewController(account: account, url: url, title: title)
            hosting?.navigationController?.pushViewController(web, animated: true)
        }
        selectSidebarDestination(NCMainNavigationController(rootViewController: hosting))
    }
}
