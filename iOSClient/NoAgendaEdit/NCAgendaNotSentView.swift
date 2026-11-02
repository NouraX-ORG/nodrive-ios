// SPDX-FileCopyrightText: 2026 Nourax
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// "Not sent": the edits that did not go through, each with what it was, where, why, and what the person can do. A
/// command leaves this list only by a tap (or when it was sent).
struct NCAgendaNotSentView: View {
    @Bindable var model: NCAgendaViewModel

    var body: some View {
        NavigationStack {
            List {
                if model.notSentCommands.isEmpty, model.waitingCommands.isEmpty {
                    Text(NCAgendaEditText.t("_nodrive_agenda_edit_nothing_unsent_")).foregroundStyle(.secondary)
                }
                // What still waits to be sent (a person can look at it; a waiting change is sent by itself, or moves here).
                if !model.waitingCommands.isEmpty {
                    Section(NCAgendaEditText.t("_nodrive_agenda_edit_waiting_title_")) {
                        ForEach(model.waitingCommands) { command in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(command.title.isEmpty ? " " : command.title).font(.headline)
                                Text(command.summary + " · " + command.home.productName)
                                    .font(.footnote).foregroundStyle(.secondary)
                                Text(NCAgendaEditText.t("_nodrive_agenda_edit_waiting_row_")).font(.subheadline)
                            }
                            .padding(.vertical, 4)
                            .accessibilityElement(children: .combine)
                            .accessibilityIdentifier("agendaWaiting-" + command.id.uuidString)
                        }
                    }
                }
                ForEach(model.notSentCommands) { command in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(command.title.isEmpty ? " " : command.title).font(.headline)
                        Text(command.summary + " · " + command.home.productName)
                            .font(.footnote).foregroundStyle(.secondary)
                        if let reason = command.notSent {
                            Text(reason.text).font(.subheadline)
                        }
                        Button(NCAgendaEditText.t("_nodrive_agenda_edit_apply_again_")) {
                            Task { await model.applyAgain(command) }
                        }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("agendaApplyAgain")
                        Button(NCAgendaEditText.t("_nodrive_agenda_edit_keep_other_")) {
                            Task { await model.keepOtherChange(command) }
                        }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("agendaKeepOther")
                        if command.link.path != nil || command.link.projectId != nil || command.link.cardId != nil {
                            Button(command.home.openTitle) { model.openHome(of: command) }
                                .accessibilityIdentifier("agendaNotSentOpen")
                        }
                    }
                    .padding(.vertical, 4)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("agendaNotSent-" + command.id.uuidString)
                }
            }
            .accessibilityIdentifier("agendaNotSentList")
            .navigationTitle(NCAgendaEditText.t("_nodrive_agenda_edit_not_sent_title_"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(NCAgendaText.t("_nodrive_agenda_done_")) { model.showNotSent = false }
                        .accessibilityIdentifier("agendaNotSentDone")
                }
            }
        }
    }
}
