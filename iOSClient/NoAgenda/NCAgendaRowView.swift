// SPDX-FileCopyrightText: 2026 Nourax
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// One row of the lists (design 8, "Each row shows").
struct NCAgendaRowView: View {
    let item: AgendaItem
    let calendar: Calendar
    var onOpen: () -> Void = {}

    var body: some View {
        Button(action: onOpen) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: item.kind.symbolName)
                    .font(.system(size: 18))
                    .foregroundStyle(NCAgendaColors.color(item.sourceColor))
                    .frame(width: 24)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title.isEmpty ? " " : item.title)
                        .font(.body.weight(.medium))
                        .foregroundStyle(item.agent.isPaused ? .secondary : .primary)
                        .multilineTextAlignment(.leading)
                    if let when = NCAgendaFormat.whenText(item, calendar: calendar) {
                        Text(when)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 6) {
                        Circle()
                            .fill(NCAgendaColors.color(item.sourceColor))
                            .frame(width: 8, height: 8)
                            .accessibilityHidden(true)
                        Text(item.sourceName)
                            .font(.footnote)
                            .foregroundStyle(NCAgendaColors.color(item.sourceColor))
                        Text(item.relation == .team ? teamText : item.agent.displayText)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    if let note = item.timeZoneNote {
                        Text(note).font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(Array(item.flags.enumerated()), id: \.offset) { _, flag in
                        Label(flag.text, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                Spacer(minLength: 0)
                badges
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(NCAgendaFormat.spoken(item, calendar: calendar))
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("agendaRow-" + item.key)
    }

    private var teamText: String {
        var parts: [String] = []
        if let person = item.personName { parts.append(person) }
        if !item.agent.isSelf { parts.append(item.agent.displayText) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var badges: some View {
        VStack(alignment: .trailing, spacing: 4) {
            if item.late {
                Image(systemName: "alarm").foregroundStyle(.red)
            }
            if item.blocked {
                Image(systemName: "nosign").foregroundStyle(.orange)
            }
            if item.boardBadge {
                Image(systemName: "rectangle.split.3x1").foregroundStyle(.secondary)
            }
            if item.lock != nil {
                Image(systemName: "lock.fill").foregroundStyle(.secondary)
            }
        }
        .font(.footnote)
        .accessibilityHidden(true)
    }
}

/// A problem row of "Problems with your agents" or "My team".
struct NCAgendaProblemRowView: View {
    let problem: AgendaProblem
    var onOpen: () -> Void = {}

    var body: some View {
        Button(action: onOpen) {
            HStack(alignment: .top, spacing: 8) {
                Text(problem.text)
                    .font(.subheadline)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                if problem.link != nil {
                    Text(problem.home.openTitle)
                        .font(.caption)
                        .foregroundStyle(Color.accentColor)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(problem.text)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("agendaProblem-" + problem.key)
    }
}
