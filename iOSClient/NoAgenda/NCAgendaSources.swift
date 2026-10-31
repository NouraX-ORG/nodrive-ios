// SPDX-FileCopyrightText: 2026 Nourax
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// Colours of sources. The server hands out its own default blues for new projects and calendars; NoDrive
/// shows those as Nourax cobalt (the no-brand-of-others rule). The reference colours are written as numbers.
enum NCAgendaColors {
    static let cobalt = "#2563EB"
    private static let defaultServerBlues: [(Int, Int, Int)] = [(0, 130, 201), (0, 103, 158), (73, 171, 234)]
    private static let distance = 32.0

    /// "#RRGGBB" (or "#RRGGBBAA" or "RRGGBB") as three numbers.
    static func rgb(_ text: String) -> (Int, Int, Int)? {
        var hex = text.trimmingCharacters(in: .whitespaces)
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6 || hex.count == 8 || hex.count == 3 else { return nil }
        if hex.count == 3 { hex = hex.map { String([$0, $0]) }.joined() }
        guard let value = UInt32(hex.prefix(6), radix: 16) else { return nil }
        return (Int((value >> 16) & 0xFF), Int((value >> 8) & 0xFF), Int(value & 0xFF))
    }

    /// The colour to show: a missing or unreadable colour and the server's default blues become cobalt.
    static func mapped(_ text: String?) -> String {
        guard let text, let (red, green, blue) = rgb(text) else { return cobalt }
        for reference in defaultServerBlues {
            let dr = Double(red - reference.0)
            let dg = Double(green - reference.1)
            let db = Double(blue - reference.2)
            if (dr * dr + dg * dg + db * db).squareRoot() <= distance { return cobalt }
        }
        return String(format: "#%02X%02X%02X", red, green, blue)
    }

    static func color(_ text: String) -> Color {
        // A colour that can't be read is cobalt (#2563EB)
        guard let (red, green, blue) = rgb(text) else { return Color(red: 37.0 / 255, green: 99.0 / 255, blue: 235.0 / 255) }
        return Color(red: Double(red) / 255, green: Double(green) / 255, blue: Double(blue) / 255)
    }
}

/// The defaults of design 6.1 and how a relation to a project or board is worked out. Plain functions.
enum NCAgendaSources {
    static func calendarKey(_ uri: String) -> String { "cal:" + uri }
    static func projectKey(_ id: Int) -> String { "project:" + String(id) }
    static func boardKey(_ id: Int) -> String { "board:" + String(id) }

    /// A share to me or to one of my groups with admin rights. A share to a team can't be resolved and is never
    /// guessed.
    static func hasAdminShare(_ shares: [GanttShare]?, userId: String, groups: [String]) -> Bool {
        guard let shares else { return false }
        return shares.contains { share in
            guard share.permission.lowercased() == "admin" else { return false }
            let type = share.type.lowercased()
            if type == "user" || type == "0" { return share.with.lowercased() == userId.lowercased() }
            if type == "group" || type == "1" { return groups.contains(share.with) }
            return false
        }
    }

    static func projectSetting(_ project: GanttProject, hasMyTasks: Bool, settings: AgendaSettings, userId: String,
                               groups: [String], shares: [GanttShare]?) -> SourceSetting {
        if let chosen = settings.chosen[projectKey(project.id)], [.doIt, .doOversee, .hidden].contains(chosen) { return chosen }
        if project.ownerId.lowercased() == userId.lowercased() { return .doOversee }
        if hasAdminShare(shares, userId: userId, groups: groups) { return .doOversee }
        // Editors and viewers, and a server admin who is neither owner nor shared with: only with tasks of mine.
        return hasMyTasks ? .doIt : .hidden
    }

    static func boardSetting(_ board: DeckBoard, userId: String, settings: AgendaSettings) -> SourceSetting {
        if let chosen = settings.chosen[boardKey(board.id)], [.doIt, .doOversee, .hidden].contains(chosen) { return chosen }
        if board.owner?.uid.lowercased() == userId.lowercased() || board.canManage { return .doOversee }
        return .doIt
    }
}
