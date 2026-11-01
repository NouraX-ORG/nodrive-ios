// SPDX-FileCopyrightText: 2026 Nourax
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// "Who does it?": Self and the person's own agents. A paused agent is greyed, a retired one is not offered, and an
/// agent that NoGantt can't show in the project says who to ask.
struct NCAgendaAgentPicker: View {
    let options: [AgentOption]
    @Binding var selection: AgentChoice
    var onOpenGantt: () -> Void = {}

    var body: some View {
        Section(NCAgendaEditText.t("_nodrive_agenda_edit_who_does_it_")) {
            ForEach(options) { option in
                VStack(alignment: .leading, spacing: 2) {
                    Button {
                        selection = option.choice
                    } label: {
                        HStack {
                            Text(option.choice.title)
                                .foregroundStyle(option.enabled ? Color.primary : Color.secondary)
                            Spacer()
                            if selection.id == option.choice.id {
                                Image(systemName: "checkmark").foregroundStyle(.tint)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!option.enabled)
                    .accessibilityIdentifier("agendaAgentOption-" + option.choice.rowId)
                    .accessibilityAddTraits(selection.id == option.choice.id ? .isSelected : [])
                    if let note = option.note {
                        Text(note).font(.footnote).foregroundStyle(.secondary)
                    }
                    if option.offersOpen {
                        Button(AgendaHome.gantt.openTitle, action: onOpenGantt)
                            .font(.footnote.weight(.semibold))
                            .accessibilityIdentifier("agendaAgentOpenGantt")
                    }
                }
            }
        }
    }
}

/// An optional date: a switch, and the picker when it is on.
struct NCAgendaOptionalDate: View {
    let title: String
    @Binding var isOn: Bool
    @Binding var date: Date
    var canSwitch = true
    var identifier: String

    var body: some View {
        if canSwitch {
            Toggle(title, isOn: $isOn).accessibilityIdentifier(identifier + "Switch")
        }
        if isOn || !canSwitch {
            DatePicker(canSwitch ? "" : title, selection: $date)
                .hidingLabel(canSwitch)
                .accessibilityIdentifier(identifier)
        }
    }
}

private extension View {
    @ViewBuilder
    func hidingLabel(_ hidden: Bool) -> some View {
        if hidden { self.labelsHidden() } else { self }
    }
}

/// The edit form of the detail sheet (design 9). Save is on only after a change.
struct NCAgendaEditorView: View {
    @Bindable var model: NCAgendaViewModel
    let item: AgendaItem
    @State private var draft: NCAgendaEditDraft
    @State private var saving = false
    @State private var confirmDelete = false
    private let original: NCAgendaEditDraft

    @MainActor
    init(model: NCAgendaViewModel, item: AgendaItem) {
        self._model = Bindable(wrappedValue: model)
        self.item = item
        let start = NCAgendaEditDraft(item: item, calendar: model.calendar)
        _draft = State(initialValue: start)
        original = start
    }

    private var changed: Bool { draft != original }
    private var isCalendarItem: Bool { item.kind == .event || item.kind == .todo }

    var body: some View {
        Form {
            switch item.kind {
            case .event: eventFields
            case .todo: todoFields
            case .ganttTask: ganttFields
            case .card: cardFields
            case .milestone: EmptyView()
            }
            if isCalendarItem, item.descriptionLength > 2000 {
                Section {
                    Text(NCAgendaEditText.f("_nodrive_agenda_edit_description_long_", item.home.openTitle)).font(.footnote)
                    Button(item.home.openTitle) { model.open(item.link, title: item.home.openTitle) }
                        .accessibilityIdentifier("agendaEditorOpenLong")
                }
            } else if isCalendarItem {
                Section(NCAgendaEditText.t("_nodrive_agenda_edit_description_")) {
                    TextField(NCAgendaEditText.t("_nodrive_agenda_edit_description_"), text: $draft.descriptionText, axis: .vertical)
                        .lineLimit(1...6)
                        .accessibilityIdentifier("agendaEditorDescription")
                }
            }
            agentSection
            if isCalendarItem {
                Section {
                    Button(role: .destructive) { confirmDelete = true } label: {
                        Text(NCAgendaEditText.t("_nodrive_agenda_edit_delete_"))
                    }
                    .accessibilityIdentifier("agendaEditorDelete")
                }
            }
        }
        .navigationTitle(NCAgendaEditText.t("_nodrive_agenda_edit_title_"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(NCAgendaEditText.t("_nodrive_agenda_edit_save_")) {
                    saving = true
                    Task { await model.save(draft: draft, for: item) }
                }
                .disabled(!changed || saving || (isCalendarItem && draft.title.trimmingCharacters(in: .whitespaces).isEmpty))
                .accessibilityIdentifier("agendaEditorSave")
            }
        }
        .confirmationDialog(deleteQuestion, isPresented: $confirmDelete, titleVisibility: .visible) {
            Button(NCAgendaEditText.t("_nodrive_agenda_edit_delete_"), role: .destructive) {
                Task { await delete() }
            }
            Button(NCAgendaEditText.t("_nodrive_agenda_edit_cancel_"), role: .cancel) {}
        }
    }

    private var deleteQuestion: String {
        item.kind == .event ? NCAgendaEditText.t("_nodrive_agenda_edit_delete_event_") : NCAgendaEditText.t("_nodrive_agenda_edit_delete_todo_")
    }

    private func delete() async {
        var command = NCAgendaEditCommand(id: UUID(), kind: .calendarDelete, createdAt: Date(), itemKey: item.key, title: item.title,
                                          sourceKey: item.sourceKey, link: item.link)
        command.component = item.kind == .event ? "VEVENT" : "VTODO"
        model.selectedItem = nil
        await model.submit([command])
    }

    // MARK: Fields

    @ViewBuilder
    private var eventFields: some View {
        Section {
            TextField(NCAgendaEditText.t("_nodrive_agenda_edit_field_title_"), text: $draft.title)
                .accessibilityIdentifier("agendaEditorTitle")
            Toggle(NCAgendaText.t("_nodrive_agenda_all_day_"), isOn: $draft.allDay)
                .accessibilityIdentifier("agendaEditorAllDay")
            DatePicker(NCAgendaEditText.t("_nodrive_agenda_edit_field_start_"), selection: $draft.start,
                       displayedComponents: draft.allDay ? [.date] : [.date, .hourAndMinute])
                .accessibilityIdentifier("agendaEditorStart")
            DatePicker(NCAgendaEditText.t("_nodrive_agenda_edit_field_end_"), selection: $draft.end,
                       displayedComponents: draft.allDay ? [.date] : [.date, .hourAndMinute])
                .accessibilityIdentifier("agendaEditorEnd")
        }
    }

    @ViewBuilder
    private var todoFields: some View {
        Section {
            TextField(NCAgendaEditText.t("_nodrive_agenda_edit_field_title_"), text: $draft.title)
                .accessibilityIdentifier("agendaEditorTitle")
            Toggle(NCAgendaEditText.t("_nodrive_agenda_edit_field_done_"), isOn: $draft.done)
                .accessibilityIdentifier("agendaEditorDone")
            NCAgendaOptionalDate(title: NCAgendaEditText.t("_nodrive_agenda_edit_field_start_"), isOn: $draft.hasStart, date: $draft.start,
                                 canSwitch: item.start == nil, identifier: "agendaEditorStart")
            NCAgendaOptionalDate(title: NCAgendaEditText.t("_nodrive_agenda_edit_field_due_"), isOn: $draft.hasDue, date: $draft.due,
                                 canSwitch: item.due == nil, identifier: "agendaEditorDue")
        }
    }

    @ViewBuilder
    private var ganttFields: some View {
        Section {
            Text(item.title).font(.headline)
            DatePicker(NCAgendaEditText.t("_nodrive_agenda_edit_field_start_"), selection: $draft.start, displayedComponents: [.date])
                .environment(\.timeZone, model.ganttZone)
                .accessibilityIdentifier("agendaEditorStart")
            DatePicker(NCAgendaEditText.t("_nodrive_agenda_edit_field_end_"), selection: $draft.end, displayedComponents: [.date])
                .environment(\.timeZone, model.ganttZone)
                .accessibilityIdentifier("agendaEditorEnd")
            Stepper(value: $draft.percent, in: 0...100, step: 5) {
                Text(NCAgendaEditText.t("_nodrive_agenda_edit_field_percent_") + " \(draft.percent) %")
            }
            .accessibilityIdentifier("agendaEditorPercent")
            Picker(NCAgendaText.t("_nodrive_agenda_detail_status_"), selection: $draft.status) {
                ForEach(statusChoices, id: \.self) { value in
                    Text(NCAgendaText.ganttStatus(value)).tag(value)
                }
            }
            .accessibilityIdentifier("agendaEditorStatus")
            Toggle(NCAgendaEditText.t("_nodrive_agenda_edit_field_done_"), isOn: $draft.done)
                .accessibilityIdentifier("agendaEditorDone")
        }
    }

    private var statusChoices: [String] {
        var values = ["not_started", "in_progress", "blocked", "on_hold", "cancelled"]
        if !draft.status.isEmpty, !values.contains(draft.status) { values.insert(draft.status, at: 0) }
        return values
    }

    @ViewBuilder
    private var cardFields: some View {
        Section {
            Text(item.title).font(.headline)
            Toggle(NCAgendaEditText.t("_nodrive_agenda_edit_field_done_"), isOn: $draft.done)
                .accessibilityIdentifier("agendaEditorDone")
            NCAgendaOptionalDate(title: NCAgendaEditText.t("_nodrive_agenda_edit_field_due_"), isOn: $draft.hasDue, date: $draft.due,
                                 canSwitch: item.due == nil, identifier: "agendaEditorDue")
        }
    }

    @ViewBuilder
    private var agentSection: some View {
        if item.invited {
            Section(NCAgendaEditText.t("_nodrive_agenda_edit_who_does_it_")) {
                Text(NCAgendaText.t("_nodrive_agenda_invited_")).font(.footnote)
            }
        } else {
            NCAgendaAgentPicker(options: model.agentOptions(for: item), selection: $draft.agent) {
                model.open(item.link, title: item.home.openTitle)
            }
        }
    }
}
