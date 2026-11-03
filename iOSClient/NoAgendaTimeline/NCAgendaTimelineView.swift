// SPDX-FileCopyrightText: 2026 Nourax
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// The title above the Timeline: the first and the last day it shows.
enum NCAgendaTimelineHeader {
    static func title(shown: Date, calendar: Calendar) -> String {
        let range = TimelineRange.around(shown, calendar: calendar)
        let first = NCAgendaTimelineDays.date(range.firstDay, calendar: calendar)
        let last = NCAgendaTimelineDays.date(range.lastDay, calendar: calendar)
        return NCAgendaTimelineText.f("_nodrive_agenda_timeline_range_", NCAgendaFormat.shortDay(first), NCAgendaFormat.shortDay(last))
    }
}

private struct TimelineScrollXKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// Tells the name cells how far the chart is scrolled. From iOS 18 the scroll view says so itself; before that the content
/// reports its own position through a preference (set in `chart`).
private struct TimelineScrollTracker: ViewModifier {
    let scroll: NCAgendaTimelineScroll

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentOffset.x
            } action: { _, newValue in
                scroll.x = newValue
            }
        } else {
            content
        }
    }
}

/// The months, the weeks and (at the Days zoom) the days, pinned above the bars.
struct NCAgendaTimelineScaleView: View {
    let scale: TimelineScale
    let todayDay: Int
    let calendar: Calendar
    let accent: Color

    static func height(for zoom: TimelineZoom) -> CGFloat { zoom == .days ? 68 : 38 }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Canvas { context, size in
                let ppd = scale.pointsPerDay
                for offset in 0..<scale.range.dayCount {
                    let number = scale.range.firstDay + offset
                    let left = scale.x(forDay: number)
                    let date = NCAgendaTimelineDays.date(number, calendar: calendar)
                    let day = NCAgendaTimelineDays.parts(of: number).day
                    if number == todayDay, scale.zoom == .days {
                        context.fill(Path(CGRect(x: left, y: size.height - 30, width: ppd, height: 30)), with: .color(accent.opacity(0.2)))
                    }
                    if day == 1 || (offset == 0 && day <= 20) {
                        var line = Path()
                        line.move(to: CGPoint(x: left, y: 0))
                        line.addLine(to: CGPoint(x: left, y: 18))
                        context.stroke(line, with: .color(Color.secondary.opacity(0.4)), lineWidth: 0.5)
                        context.draw(Text(date.formatted(.dateTime.month(.wide).year())).font(.caption2.weight(.semibold)),
                                     at: CGPoint(x: left + 4, y: 9), anchor: .leading)
                    }
                    if NCAgendaTimelineDays.isWeekStart(number, calendar: calendar) {
                        var line = Path()
                        line.move(to: CGPoint(x: left, y: 18))
                        line.addLine(to: CGPoint(x: left, y: size.height))
                        context.stroke(line, with: .color(Color.secondary.opacity(0.3)), lineWidth: 0.5)
                        context.draw(Text(NCAgendaFormat.shortDay(date)).font(.caption2).foregroundStyle(Color.secondary),
                                     at: CGPoint(x: left + 3, y: 28), anchor: .leading)
                    }
                    if scale.zoom == .days {
                        let weekday = date.formatted(.dateTime.weekday(.abbreviated))
                        context.draw(Text(weekday).font(.system(size: 9)).foregroundStyle(Color.secondary),
                                     at: CGPoint(x: left + ppd / 2, y: 43), anchor: .center)
                        context.draw(Text(String(day)).font(.caption2.weight(number == todayDay ? .bold : .regular)),
                                     at: CGPoint(x: left + ppd / 2, y: 57), anchor: .center)
                    }
                }
            }
            .frame(width: scale.totalWidth, height: Self.height(for: scale.zoom))
            .accessibilityHidden(true)
        }
        .frame(width: scale.totalWidth, height: Self.height(for: scale.zoom), alignment: .topLeading)
        .background(Color(UIColor.systemBackground))
        .overlay(alignment: .bottom) { Rectangle().fill(Color(UIColor.separator)).frame(height: 0.5) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(NCAgendaTimelineText.t("_nodrive_agenda_timeline_scale_"))
        .accessibilityIdentifier("agendaTimelineScale")
    }
}

/// The corner above the name column: it stays at the left edge while the scale scrolls under it.
struct NCAgendaTimelineCorner: View {
    let scale: TimelineScale
    let scroll: NCAgendaTimelineScroll

    var body: some View {
        Color(UIColor.systemBackground)
            .frame(width: scale.nameWidth, height: NCAgendaTimelineScaleView.height(for: scale.zoom))
            .overlay(alignment: .trailing) { Rectangle().fill(Color(UIColor.separator)).frame(width: 0.5) }
            .offset(x: max(0, scroll.x))
            .accessibilityHidden(true)
    }
}

/// The Timeline (design 8): my Gantt tasks, my to-dos with two dates, milestones and dated cards as bars and diamonds
/// along a scale of days, with my busy time shaded behind them. A name column and the scale stay in place while the rest
/// scrolls. There is no drag on phones: a tap opens the detail sheet, whose editor has the two dates and "Move by".
struct NCAgendaTimelineView: View {
    let model: NCAgendaViewModel
    @State private var zoom: TimelineZoom = .weeks
    @State private var scroll = NCAgendaTimelineScroll()
    @State private var showLegend = false
    @Environment(\.horizontalSizeClass) private var sizeClass

    private let anchorId = "agendaTimelineAnchor"
    private static let bottomRoom: CGFloat = 96
    private let spaceName = "agendaTimelineH"

    private var nameWidth: CGFloat { sizeClass == .compact ? 120 : 160 }

    /// The items to draw: mine, with the chips, the switch and the Conflicts chip applied.
    private var drawnItems: [AgendaItem] {
        model.display.items.filter { item in
            guard item.relation == .mine, model.filter.allows(item) else { return false }
            return !model.conflictsOnly || NCAgendaConflicts.hasConflict(item)
        }
    }

    var body: some View {
        let scale = TimelineScale(range: TimelineRange.around(model.day, calendar: model.calendar), zoom: zoom, nameWidth: nameWidth)
        let layout = NCAgendaTimelineLayout.build(items: drawnItems, scale: scale, calendar: model.calendar, ganttZone: model.ganttZone)
        let shades = NCAgendaTimelineLayout.shading(range: scale.range, events: model.display.items, pattern: model.pattern, calendar: model.calendar)
        VStack(spacing: 0) {
            controls
            GeometryReader { proxy in
                chart(layout: layout, shades: shades, size: proxy.size)
            }
        }
        .sheet(isPresented: $showLegend) {
            NCAgendaTimelineLegend()
                .tint(model.accentColor)
                .presentationDetents([.medium, .large])
        }
    }

    private var controls: some View {
        HStack {
            Picker(NCAgendaTimelineText.t("_nodrive_agenda_timeline_zoom_"), selection: $zoom) {
                ForEach(TimelineZoom.allCases) { value in
                    Text(value.title).tag(value)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 200)
            .accessibilityIdentifier("agendaTimelineZoom")
            Spacer()
            Button {
                showLegend = true
            } label: {
                Image(systemName: "info.circle").font(.title3)
            }
            .accessibilityLabel(NCAgendaTimelineText.t("_nodrive_agenda_timeline_legend_info_"))
            .accessibilityIdentifier("agendaTimelineLegend")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    private func chart(layout: TimelineLayout, shades: [TimelineDayShade], size: CGSize) -> some View {
        let scale = layout.scale
        let scaleHeight = NCAgendaTimelineScaleView.height(for: scale.zoom)
        let bodyHeight = max(1, size.height - scaleHeight)
        let todayDay = NCAgendaTimelineDays.number(model.today, calendar: model.calendar)
        let shownDay = NCAgendaTimelineDays.number(model.day, calendar: model.calendar)
        let anchorX = max(0, scale.x(forDay: shownDay) - scale.nameWidth - 24)
        let contentHeight = max(layout.contentHeight, bodyHeight)
        return ScrollViewReader { reader in
            ScrollView(.horizontal, showsIndicators: true) {
                ZStack(alignment: .topLeading) {
                    VStack(spacing: 0) {
                        ZStack(alignment: .topLeading) {
                            NCAgendaTimelineScaleView(scale: scale, todayDay: todayDay, calendar: model.calendar, accent: model.accentColor)
                            NCAgendaTimelineCorner(scale: scale, scroll: scroll)
                        }
                        .frame(width: scale.totalWidth, height: scaleHeight, alignment: .topLeading)
                        ScrollView(.vertical, showsIndicators: true) {
                            ZStack(alignment: .topLeading) {
                                NCAgendaTimelineShadingView(scale: scale, shades: shades, todayDay: todayDay, height: contentHeight,
                                                            calendar: model.calendar, accent: model.accentColor)
                                NCAgendaTimelineArrowsView(layout: layout, height: contentHeight)
                                LazyVStack(spacing: 0) {
                                    ForEach(layout.rows) { row in
                                        rowView(row, layout: layout)
                                    }
                                }
                                .frame(width: scale.totalWidth, alignment: .topLeading)
                            }
                            .frame(width: scale.totalWidth, height: contentHeight, alignment: .topLeading)
                        }
                        // Room under the last row, so that it can be scrolled clear of the floating tab bar (only when the rows need to scroll)
                        .contentMargins(.bottom, layout.contentHeight + Self.bottomRoom > bodyHeight ? Self.bottomRoom : 0, for: .scrollContent)
                        .frame(width: scale.totalWidth, height: bodyHeight)
                        .refreshable { await model.refresh() }
                    }
                    // Where the shown date is: the scroll target (real layout, not an offset)
                    HStack(spacing: 0) {
                        Color.clear.frame(width: anchorX, height: 1)
                        Color.clear.frame(width: 1, height: 1).id(anchorId)
                        Spacer(minLength: 0)
                    }
                    .frame(width: scale.totalWidth, height: 1, alignment: .leading)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
                .frame(width: scale.totalWidth, height: size.height, alignment: .topLeading)
                .background(
                    GeometryReader { geometry in
                        Color.clear.preference(key: TimelineScrollXKey.self, value: -geometry.frame(in: .named(spaceName)).minX)
                    }
                )
            }
            .coordinateSpace(.named(spaceName))
            .modifier(TimelineScrollTracker(scroll: scroll))
            .onPreferenceChange(TimelineScrollXKey.self) { value in
                scroll.x = value
            }
            .onAppear {
                DispatchQueue.main.async { reader.scrollTo(anchorId, anchor: .leading) }
            }
            .onChange(of: model.day) { _, _ in
                DispatchQueue.main.async { reader.scrollTo(anchorId, anchor: .leading) }
            }
            .onChange(of: model.timelineTodayTick) { _, _ in
                DispatchQueue.main.async { reader.scrollTo(anchorId, anchor: .leading) }
            }
            .onChange(of: zoom) { _, _ in
                DispatchQueue.main.async { reader.scrollTo(anchorId, anchor: .leading) }
            }
        }
        .overlay {
            if !layout.hasItems && model.hasLoaded {
                Text(NCAgendaTimelineText.t("_nodrive_agenda_timeline_empty_"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 24)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("agendaTimelineEmpty")
            }
        }
        // A time line runs from the left to the right in every language: the bars (placed by offset), the scale, the shading
        // and the arrows (drawn on a canvas) must not mirror differently in Arabic
        .environment(\.layoutDirection, .leftToRight)
    }

    @ViewBuilder
    private func rowView(_ row: TimelineRow, layout: TimelineLayout) -> some View {
        switch row.content {
        case let .group(title, level):
            NCAgendaTimelineGroupRow(title: title, level: level, width: layout.scale.totalWidth, scroll: scroll)
        case let .item(item):
            if let shape = layout.shapes[item.key] {
                NCAgendaTimelineItemRow(model: model, item: item, shape: shape, stubs: layout.stubs[item.key] ?? [], scale: layout.scale, scroll: scroll)
            }
        }
    }
}

/// What the marks of the Timeline mean (the ⓘ button).
struct NCAgendaTimelineLegend: View {
    @Environment(\.dismiss) private var dismiss

    private let lines: [(String, String)] = [
        ("chart.bar.xaxis", "_nodrive_agenda_timeline_legend_bar_"),
        ("checklist", "_nodrive_agenda_timeline_legend_todo_"),
        ("diamond.fill", "_nodrive_agenda_timeline_legend_diamond_"),
        ("arrow.right", "_nodrive_agenda_timeline_legend_arrow_"),
        ("arrowtriangle.right.fill", "_nodrive_agenda_timeline_legend_stub_"),
        ("square.fill", "_nodrive_agenda_timeline_legend_shade_"),
        ("slash.circle", "_nodrive_agenda_timeline_legend_hatch_"),
        ("minus", "_nodrive_agenda_timeline_legend_today_"),
        ("person.crop.circle", "_nodrive_agenda_timeline_legend_agent_"),
        ("exclamationmark.triangle", "_nodrive_agenda_timeline_legend_marks_"),
        ("hand.tap", "_nodrive_agenda_timeline_legend_phone_")
    ]

    var body: some View {
        NavigationStack {
            List {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Label(NCAgendaTimelineText.t(line.1), systemImage: line.0)
                        .font(.subheadline)
                }
            }
            .navigationTitle(NCAgendaTimelineText.t("_nodrive_agenda_timeline_legend_"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(NCAgendaText.t("_nodrive_agenda_done_")) { dismiss() }
                        .accessibilityIdentifier("agendaTimelineLegendDone")
                }
            }
        }
    }
}
