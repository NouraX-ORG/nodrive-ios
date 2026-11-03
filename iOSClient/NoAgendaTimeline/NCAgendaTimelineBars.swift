// SPDX-FileCopyrightText: 2026 Nourax
// SPDX-License-Identifier: GPL-3.0-or-later

import Observation
import SwiftUI

/// How far the chart is scrolled to the right (points). The name column follows it, so it stays at the left edge. It is an
/// object of its own, so that only the name cells are drawn again while the chart scrolls.
@Observable
final class NCAgendaTimelineScroll: @unchecked Sendable {
    var x: CGFloat = 0
}

/// The name of a row, pinned to the left edge of the screen while the chart scrolls under it.
struct NCAgendaTimelineNameCell: View {
    let text: String
    let width: CGFloat
    let height: CGFloat
    let scroll: NCAgendaTimelineScroll

    var body: some View {
        Text(text.isEmpty ? " " : text)
            .font(.footnote)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, 8)
            .frame(width: width, height: height, alignment: .leading)
            .background(Color(UIColor.systemBackground))
            .overlay(alignment: .trailing) {
                Rectangle().fill(Color(UIColor.separator)).frame(width: 0.5)
            }
            .offset(x: max(0, scroll.x))
            .accessibilityHidden(true)
    }
}

/// A project, a phase, a list of to-dos or a board: a title on a tinted strip.
struct NCAgendaTimelineGroupRow: View {
    let title: String
    let level: Int
    let width: CGFloat
    let scroll: NCAgendaTimelineScroll

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color(UIColor.secondarySystemBackground).opacity(level == 0 ? 0.9 : 0.55)
                .frame(width: width, height: NCAgendaTimelineLayout.groupHeight)
            Text(title)
                .font(level == 0 ? .footnote.weight(.semibold) : .footnote)
                .foregroundStyle(level == 0 ? Color.primary : Color.secondary)
                .lineLimit(1)
                .fixedSize()
                .padding(.leading, level == 0 ? 8 : 20)
                .frame(height: NCAgendaTimelineLayout.groupHeight, alignment: .leading)
                .offset(x: max(0, scroll.x))
        }
        .frame(width: width, height: NCAgendaTimelineLayout.groupHeight, alignment: .topLeading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("agendaTimelineGroup-" + title)
    }
}

/// One bar or diamond with its name, its agent and its marks. The tap target is at least 44 points high and wide, so a
/// one-day bar is still easy to hit.
struct NCAgendaTimelineItemRow: View {
    let model: NCAgendaViewModel
    let item: AgendaItem
    let shape: TimelineShape
    let stubs: [String]
    let scale: TimelineScale
    let scroll: NCAgendaTimelineScroll

    private var color: Color { NCAgendaColors.color(item.sourceColor) }

    private var isLocked: Bool {
        if shape.noDates { return true }
        if case .locked = model.ability(of: item) { return true }
        return false
    }

    private var isNotSent: Bool {
        model.notSentCommands.contains { $0.itemKey == item.key }
    }

    var body: some View {
        let locked = isLocked
        let notSent = isNotSent
        ZStack(alignment: .topLeading) {
            if !stubs.isEmpty { stubButton }
            barButton(spoken: NCAgendaTimelineLayout.spoken(item, shape: shape, calendar: model.calendar, locked: locked, notSent: notSent))
            trailing(locked: locked, notSent: notSent)
            NCAgendaTimelineNameCell(text: item.title, width: scale.nameWidth, height: NCAgendaTimelineLayout.rowHeight, scroll: scroll)
        }
        .frame(width: scale.totalWidth, height: NCAgendaTimelineLayout.rowHeight, alignment: .topLeading)
    }

    // MARK: Bar or diamond

    private func barButton(spoken: String) -> some View {
        let hit = max(shape.isDiamond ? 0 : shape.width, 44)
        let alignment: Alignment = shape.isDiamond ? .center : .leading
        return Button {
            model.selectedItem = item
        } label: {
            ZStack(alignment: alignment) {
                Color.clear
                drawing
            }
            .frame(width: hit, height: NCAgendaTimelineLayout.rowHeight, alignment: alignment)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("agendaTimelineBar-" + item.key)
        .offset(x: shape.isDiamond ? shape.x - hit / 2 : shape.x)
    }

    @ViewBuilder
    private var drawing: some View {
        switch shape.kind {
        case .bar:
            ZStack(alignment: .leading) {
                Rectangle().fill(color.opacity(0.25))
                Rectangle().fill(color).frame(width: shape.width * CGFloat(shape.fill))
            }
            .frame(width: shape.width, height: NCAgendaTimelineLayout.barHeight)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(color, lineWidth: 1))
        case .todoBar:
            RoundedRectangle(cornerRadius: 4)
                .fill(color.opacity(0.3))
                .frame(width: shape.width, height: NCAgendaTimelineLayout.todoBarHeight)
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(color, style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
        case .diamond:
            Image(systemName: item.kind == .card ? "diamond" : "diamond.fill")
                .font(.system(size: NCAgendaTimelineLayout.diamondSize))
                .foregroundStyle(color)
        }
    }

    // MARK: After the bar

    private func trailing(locked: Bool, notSent: Bool) -> some View {
        HStack(spacing: 4) {
            // NoGantt milestones have no assignee
            if item.kind != .milestone {
                Text(item.agent.displayText)
                    .font(.caption2)
                    .foregroundStyle(item.agent.isPaused ? Color.secondary.opacity(0.6) : Color.secondary)
                    .lineLimit(1)
            }
            if item.late { mark("alarm", .red) }
            if item.blocked { mark("nosign", .orange) }
            if locked { mark("lock.fill", .secondary) }
            if item.clash == .hard { mark("exclamationmark.triangle.fill", .red) }
            if item.clash == .soft { mark("exclamationmark.triangle", .orange) }
            if item.dayOff { mark("calendar.badge.exclamationmark", .orange) }
            if item.pending { mark("clock", .orange) }
            if notSent { mark("exclamationmark.triangle.fill", .orange) }
        }
        .fixedSize()
        .frame(height: NCAgendaTimelineLayout.rowHeight)
        .offset(x: shape.trailingX + 6)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func mark(_ symbol: String, _ tint: Color) -> some View {
        Image(systemName: symbol).font(.caption2).foregroundStyle(tint)
    }

    // MARK: Stub

    /// A short arrow before a bar whose predecessor is not on the screen. Tapping it says which task it follows.
    private var stubButton: some View {
        let text = stubs.joined(separator: "; ")
        return Button {
            model.showToast(text)
        } label: {
            HStack(spacing: 0) {
                Rectangle().fill(Color.secondary).frame(width: 12, height: 1.5)
                Image(systemName: "arrowtriangle.right.fill").font(.system(size: 8)).foregroundStyle(Color.secondary)
            }
            .frame(width: 28, height: NCAgendaTimelineLayout.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
        .accessibilityHint(NCAgendaTimelineText.t("_nodrive_agenda_timeline_spoken_stub_"))
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("agendaTimelineStub-" + item.key)
        .offset(x: shape.startPoint.x - 30)
    }
}
