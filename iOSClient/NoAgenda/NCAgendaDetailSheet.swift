// SPDX-FileCopyrightText: 2026 Nourax
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// The details of one row (read only in this step) with "Open in ...", which opens the page signed in.
struct NCAgendaDetailSheet: View {
    @Bindable var model: NCAgendaViewModel
    let item: AgendaItem

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button(item.home.openTitle) { model.open(item.link, title: item.home.openTitle) }
                        .accessibilityIdentifier("agendaDetailOpen")
                }
                Section {
                    Label(item.title.isEmpty ? " " : item.title, systemImage: item.kind.symbolName)
                        .font(.headline)
                        .accessibilityIdentifier("agendaDetailTitle")
                    row(NCAgendaText.t("_nodrive_agenda_detail_kind_"), item.kind.spokenName)
                    if let when = NCAgendaFormat.whenText(item, calendar: model.calendar) {
                        row(NCAgendaText.t("_nodrive_agenda_detail_when_"), when)
                    }
                    row(NCAgendaText.t("_nodrive_agenda_detail_source_"), item.sourceName)
                    row(NCAgendaText.t("_nodrive_agenda_detail_agent_"), item.agent.displayText)
                        .accessibilityIdentifier("agendaDetailAgent")
                    if item.invited {
                        Text(NCAgendaText.t("_nodrive_agenda_invited_")).font(.footnote).foregroundStyle(.secondary)
                    }
                    if let note = item.timeZoneNote {
                        Text(note).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if item.projectName != nil || item.phase != nil || item.percent != nil || item.status != nil {
                    Section {
                        if let project = item.projectName { row(NCAgendaText.t("_nodrive_agenda_detail_project_"), project) }
                        if let phase = item.phase { row(NCAgendaText.t("_nodrive_agenda_detail_phase_"), phase) }
                        if let percent = item.percent {
                            row(NCAgendaText.t("_nodrive_agenda_detail_done_"), "\(percent) %")
                                .accessibilityIdentifier("agendaDetailPercent")
                        }
                        if let status = item.status, item.home == .gantt { row(NCAgendaText.t("_nodrive_agenda_detail_status_"), status) }
                        if let hours = item.workShare { row(NCAgendaText.t("_nodrive_agenda_detail_work_"), String(format: "%.1f", hours)) }
                    }
                }
                if !item.dependencies.isEmpty {
                    Section(NCAgendaText.t("_nodrive_agenda_detail_dependencies_")) {
                        ForEach(Array(item.dependencies.enumerated()), id: \.offset) { _, dependency in
                            Text(dependency.predecessorTitle)
                        }
                    }
                }
                if let person = item.personName {
                    Section(NCAgendaText.t("_nodrive_agenda_detail_people_")) { Text(person) }
                }
                if !item.flags.isEmpty {
                    Section {
                        ForEach(Array(item.flags.enumerated()), id: \.offset) { _, flag in
                            Label(flag.text, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                        }
                    }
                }
                if let lock = item.lock {
                    Section {
                        Label(lockText(lock), systemImage: "lock.fill").font(.footnote)
                    }
                }
            }
            .navigationTitle(NCAgendaText.t("_nodrive_agenda_detail_title_"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(NCAgendaText.t("_nodrive_agenda_done_")) { model.selectedItem = nil }
                        .accessibilityIdentifier("agendaDetailDone")
                }
            }
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        LabeledContent(title, value: value)
    }

    private func lockText(_ lock: LockReason) -> String {
        switch lock {
        case .readOnlyCalendar: return NCAgendaText.t("_nodrive_agenda_lock_read_only_")
        case .viewerProject: return NCAgendaText.t("_nodrive_agenda_lock_viewer_")
        case .guardReadOnly: return NCAgendaText.t("_nodrive_agenda_lock_guard_")
        case .repeating: return NCAgendaText.f("_nodrive_agenda_lock_repeating_", item.home.openTitle)
        }
    }
}
