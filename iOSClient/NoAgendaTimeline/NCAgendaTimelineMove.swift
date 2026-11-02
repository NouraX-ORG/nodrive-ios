// SPDX-FileCopyrightText: 2026 Nourax
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

extension NCAgendaEditDraft {
    /// The steps of "Move by", in days.
    static let moveSteps = [-7, -1, 1, 7]

    /// "Move by" is offered for a Gantt task that has a start and an end, and for a to-do that has a start and a due date.
    static func canMoveDates(_ item: AgendaItem) -> Bool {
        switch item.kind {
        case .ganttTask: return item.start != nil && item.end != nil
        case .todo: return item.start != nil && item.due != nil
        default: return false
        }
    }

    /// Moves both dates by whole days, keeping the time of day. The draft then becomes the same commands as when the
    /// person sets the two dates by hand: a NoGantt move (`ganttUpdate`, with `adjust_lag`) or a CalDAV change (`calendarPatch`).
    mutating func moveBy(days: Int, calendar: Calendar, zone: TimeZone) {
        switch kind {
        case .ganttTask:
            var zoned = calendar
            zoned.timeZone = zone
            start = zoned.date(byAdding: .day, value: days, to: start) ?? start
            end = zoned.date(byAdding: .day, value: days, to: end) ?? end
        case .todo:
            guard hasStart, hasDue else { return }
            start = calendar.date(byAdding: .day, value: days, to: start) ?? start
            due = calendar.date(byAdding: .day, value: days, to: due) ?? due
        default:
            return
        }
    }
}

/// "Move by -7 / -1 / +1 / +7 days": four buttons in the editor, next to the two date pickers (no drag on phones).
struct NCAgendaMoveByView: View {
    @Binding var draft: NCAgendaEditDraft
    let calendar: Calendar
    let zone: TimeZone

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(NCAgendaTimelineText.t("_nodrive_agenda_timeline_move_by_"))
                .font(.subheadline)
            HStack(spacing: 8) {
                ForEach(NCAgendaEditDraft.moveSteps, id: \.self) { days in
                    Button {
                        draft.moveBy(days: days, calendar: calendar, zone: zone)
                    } label: {
                        Text(String(format: "%+d", days))
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel(Self.spoken(days))
                    .accessibilityIdentifier("agendaMoveBy" + (days < 0 ? "Minus" : "Plus") + String(abs(days)))
                }
            }
        }
        .padding(.vertical, 2)
    }

    static func spoken(_ days: Int) -> String {
        let count = abs(days)
        if days < 0 {
            return count == 1 ? NCAgendaTimelineText.t("_nodrive_agenda_timeline_earlier_one_") : NCAgendaTimelineText.f("_nodrive_agenda_timeline_earlier_", count)
        }
        return count == 1 ? NCAgendaTimelineText.t("_nodrive_agenda_timeline_later_one_") : NCAgendaTimelineText.f("_nodrive_agenda_timeline_later_", count)
    }
}
