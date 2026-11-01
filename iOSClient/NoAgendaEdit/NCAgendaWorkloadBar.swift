// SPDX-FileCopyrightText: 2026 Nourax
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// The workload bar (design 7 and 8): my own planned hours against my free hours, "6 h planned / 4 h free" with a
/// warning when the day is overbooked. Per day on Week it is the small form.
struct NCAgendaWorkloadBar: View {
    let workload: AgendaWorkload
    var compact = false

    var body: some View {
        let total = max(workload.planned, workload.free, 0.1)
        VStack(alignment: .leading, spacing: compact ? 2 : 4) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.2))
                    Capsule()
                        .fill(workload.isOver ? Color.orange : Color.accentColor)
                        .frame(width: proxy.size.width * min(1, workload.planned / total))
                    Rectangle()
                        .fill(Color.primary.opacity(0.6))
                        .frame(width: 2)
                        .offset(x: proxy.size.width * min(1, workload.free / total) - 1)
                }
            }
            .frame(height: compact ? 5 : 8)
            HStack(spacing: 4) {
                if workload.isOver {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).accessibilityHidden(true)
                }
                Text(workload.text)
                    .font(compact ? .caption : .subheadline)
                    .foregroundStyle(workload.isOver ? Color.orange : Color.secondary)
                if workload.noEstimate > 0 {
                    Text("· " + NCAgendaEditText.f("_nodrive_agenda_edit_no_estimate_", workload.noEstimate))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(workload.text + (workload.isOver ? ", " + NCAgendaEditText.t("_nodrive_agenda_edit_overbooked_spoken_") : ""))
        .accessibilityIdentifier(compact ? "agendaWorkloadBarWeek" : "agendaWorkloadBar")
    }
}

/// The toast at the bottom of the screen, with Undo for a NoGantt move.
struct NCAgendaToastView: View {
    let toast: AgendaToast
    var onUndo: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(toast.text).font(.subheadline).multilineTextAlignment(.leading)
                .accessibilityIdentifier("agendaToastText")
            Spacer(minLength: 0)
            if toast.undoOpId != nil {
                Button(NCAgendaEditText.t("_nodrive_agenda_edit_undo_"), action: onUndo)
                    .font(.subheadline.weight(.semibold))
                    .accessibilityIdentifier("agendaToastUndo")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .shadow(radius: 4)
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("agendaToast")
    }
}
