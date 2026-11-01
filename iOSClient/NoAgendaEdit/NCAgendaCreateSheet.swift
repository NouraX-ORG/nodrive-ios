// SPDX-FileCopyrightText: 2026 Nourax
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// "+" (design 8 and 9): a new event or to-do. The person is me and the agent is required, with Self preselected.
struct NCAgendaCreateDraft: Equatable {
    var isTodo = false
    var calendarUri: String?
    var title = ""
    var allDay = false
    var start: Date
    var end: Date
    var hasDue = false
    var due: Date
    var agent: AgentChoice = .selfChoice

    init(now: Date, calendar: Calendar) {
        // The next full hour.
        let hour = calendar.dateInterval(of: .hour, for: now)?.end ?? now
        start = hour
        end = hour.addingTimeInterval(3_600)
        due = hour
    }

    /// The command that makes the new object: UTC times, a new UUID, `PRODID:-//Nourax//NoAgenda//EN`.
    func command(calendars: [RawCalendar], registry: NCAgendaRegistry?, calendar: Calendar, now: Date) -> NCAgendaEditCommand? {
        guard let target = calendars.first(where: { $0.uri == calendarUri }) else { return nil }
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        let component = isTodo ? "VTODO" : "VEVENT"
        var change = CalendarChange()
        change.title = name
        if isTodo {
            if hasDue { change.due = due }
        } else {
            change.allDay = allDay
            change.start = start
            change.end = allDay ? (calendar.date(byAdding: .day, value: 1, to: end) ?? end) : end
        }
        change.agent = agent.calendarWrite
        let uid = UUID().uuidString.lowercased()
        let base = target.href.hasSuffix("/") ? target.href : target.href + "/"
        var command = NCAgendaEditCommand(id: UUID(), kind: .calendarCreate, createdAt: now, itemKey: nil, title: name,
                                          sourceKey: NCAgendaSources.calendarKey(target.uri),
                                          link: AgendaLink(home: isTodo ? .tasks : .calendar, calendarUri: target.uri))
        command.calendar = change
        command.agent = agent
        command.component = component
        command.createPath = base + uid + ".ics"
        command.createText = NCAgendaICalPatch.make(kind: component, uid: uid, change: change, now: now, zone: calendar.timeZone)
        return command
    }
}

struct NCAgendaCreateSheet: View {
    @Bindable var model: NCAgendaViewModel
    @State private var draft: NCAgendaCreateDraft
    @Environment(\.dismiss) private var dismiss

    @MainActor
    init(model: NCAgendaViewModel) {
        self._model = Bindable(wrappedValue: model)
        var start = NCAgendaCreateDraft(now: model.today, calendar: model.calendar)
        start.calendarUri = model.creatableCalendars(todo: false).first?.uri
        _draft = State(initialValue: start)
    }

    private var targets: [RawCalendar] { model.creatableCalendars(todo: draft.isTodo) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("", selection: $draft.isTodo) {
                        Text(NCAgendaEditText.t("_nodrive_agenda_edit_new_event_")).tag(false)
                        Text(NCAgendaEditText.t("_nodrive_agenda_edit_new_todo_")).tag(true)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("agendaCreateKind")
                    .onChange(of: draft.isTodo) { _, _ in
                        if !targets.contains(where: { $0.uri == draft.calendarUri }) { draft.calendarUri = targets.first?.uri }
                    }
                    if targets.isEmpty {
                        Text(NCAgendaEditText.t("_nodrive_agenda_edit_no_calendar_")).font(.footnote).foregroundStyle(.secondary)
                    } else {
                        Picker(draft.isTodo ? NCAgendaEditText.t("_nodrive_agenda_edit_list_") : NCAgendaEditText.t("_nodrive_agenda_edit_calendar_"),
                               selection: $draft.calendarUri) {
                            ForEach(targets, id: \.uri) { calendar in
                                Text(calendar.name).tag(Optional(calendar.uri))
                            }
                        }
                        .accessibilityIdentifier("agendaCreateCalendar")
                    }
                    TextField(NCAgendaEditText.t("_nodrive_agenda_edit_field_title_"), text: $draft.title)
                        .accessibilityIdentifier("agendaCreateTitle")
                    if draft.isTodo {
                        NCAgendaOptionalDate(title: NCAgendaEditText.t("_nodrive_agenda_edit_field_due_"), isOn: $draft.hasDue, date: $draft.due,
                                             canSwitch: true, identifier: "agendaCreateDue")
                    } else {
                        Toggle(NCAgendaText.t("_nodrive_agenda_all_day_"), isOn: $draft.allDay)
                            .accessibilityIdentifier("agendaCreateAllDay")
                        DatePicker(NCAgendaEditText.t("_nodrive_agenda_edit_field_start_"), selection: $draft.start,
                                   displayedComponents: draft.allDay ? [.date] : [.date, .hourAndMinute])
                            .accessibilityIdentifier("agendaCreateStart")
                        DatePicker(NCAgendaEditText.t("_nodrive_agenda_edit_field_end_"), selection: $draft.end,
                                   displayedComponents: draft.allDay ? [.date] : [.date, .hourAndMinute])
                            .accessibilityIdentifier("agendaCreateEnd")
                    }
                }
                NCAgendaAgentPicker(options: model.agentOptions(for: nil), selection: $draft.agent)
            }
            .navigationTitle(NCAgendaEditText.t("_nodrive_agenda_edit_new_title_"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NCAgendaEditText.t("_nodrive_agenda_edit_cancel_")) { dismiss() }
                        .accessibilityIdentifier("agendaCreateCancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(NCAgendaEditText.t("_nodrive_agenda_edit_save_")) {
                        Task { await model.create(draft) }
                    }
                    .disabled(draft.title.trimmingCharacters(in: .whitespaces).isEmpty || draft.calendarUri == nil)
                    .accessibilityIdentifier("agendaCreateSave")
                }
            }
        }
    }
}
