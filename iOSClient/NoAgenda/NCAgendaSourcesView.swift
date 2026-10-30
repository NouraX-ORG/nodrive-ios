// SPDX-FileCopyrightText: 2026 Nourax
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// The Sources screen: every calendar, list, project and board with its setting (design 6.1), the working hours
/// and the agents of the registry.
struct NCAgendaSourcesView: View {
    @Bindable var model: NCAgendaViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            group(NCAgendaText.t("_nodrive_agenda_group_calendars_"), kinds: [.calendar])
            group(NCAgendaText.t("_nodrive_agenda_group_lists_"), kinds: [.list])
            group(NCAgendaText.t("_nodrive_agenda_group_projects_"), kinds: [.project])
            group(NCAgendaText.t("_nodrive_agenda_group_boards_"), kinds: [.board])
            workingHours
            agents
            Section {
                Button(NCAgendaText.t("_nodrive_agenda_personal_question_")) {
                    model.showSources = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { model.showPersonalQuestion = true }
                }
                .accessibilityIdentifier("agendaAskPersonal")
                if NCAgendaBackground.isRefreshOff {
                    Text(NCAgendaText.t("_nodrive_agenda_background_off_")).font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(NCAgendaText.t("_nodrive_agenda_sources_"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(NCAgendaText.t("_nodrive_agenda_done_")) { dismiss() }
                    .accessibilityIdentifier("agendaSourcesDone")
            }
        }
        .accessibilityIdentifier("agendaSourcesList")
    }

    private func options(for source: AgendaSource) -> [SourceSetting] {
        switch source.kind {
        case .calendar, .list: return [.personal, .work, .team, .info, .hidden]
        case .project, .board: return [.doIt, .doOversee, .hidden]
        }
    }

    @ViewBuilder
    private func group(_ title: String, kinds: [AgendaSourceKind]) -> some View {
        let rows = model.result.snapshot.sources.filter { kinds.contains($0.kind) }
        if !rows.isEmpty {
            Section(title) {
                ForEach(rows) { source in
                    sourceRow(source)
                }
            }
        }
    }

    private func sourceRow(_ source: AgendaSource) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Circle().fill(NCAgendaColors.color(source.color)).frame(width: 10, height: 10).accessibilityHidden(true)
                Text(source.name)
                if source.isNew {
                    Text(NCAgendaText.t("_nodrive_agenda_new_")).font(.caption).foregroundStyle(.tint)
                }
                Spacer()
                if source.lockedReason == nil {
                    Picker("", selection: Binding(get: { source.setting }, set: { value in
                        Task { await model.choose(value, for: source.key) }
                    })) {
                        ForEach(options(for: source), id: \.self) { setting in
                            Text(setting.title).tag(setting)
                        }
                    }
                    .labelsHidden()
                    .accessibilityIdentifier("agendaSourceSetting-" + source.key)
                } else {
                    Text(source.setting.title).foregroundStyle(.secondary)
                }
            }
            if let reason = source.lockedReason {
                Text(reason).font(.footnote).foregroundStyle(.secondary)
            }
            if let note = source.note {
                Text(note).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("agendaSource-" + source.key)
    }

    // MARK: Working hours

    private var workingHours: some View {
        Section(NCAgendaText.t("_nodrive_agenda_working_hours_")) {
            ForEach(0..<7, id: \.self) { index in
                Toggle(dayName(index), isOn: Binding(get: { model.result.settings.workDays.contains(index) }, set: { on in
                    Task {
                        model.result.settings = await model.store.updateSettings { settings in
                            if on { if !settings.workDays.contains(index) { settings.workDays.append(index) } } else { settings.workDays.removeAll { $0 == index } }
                        }
                    }
                }))
            }
            DatePicker(NCAgendaText.t("_nodrive_agenda_from_"), selection: minutesBinding(start: true), displayedComponents: .hourAndMinute)
            DatePicker(NCAgendaText.t("_nodrive_agenda_to_"), selection: minutesBinding(start: false), displayedComponents: .hourAndMinute)
        }
    }

    private func dayName(_ mondayBased: Int) -> String {
        let symbols = model.calendar.weekdaySymbols
        return symbols[(mondayBased + 1) % 7]
    }

    private func minutesBinding(start: Bool) -> Binding<Date> {
        Binding(get: {
            let minutes = start ? model.result.settings.workStartMinutes : model.result.settings.workEndMinutes
            return model.calendar.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: model.today) ?? model.today
        }, set: { date in
            let parts = model.calendar.dateComponents([.hour, .minute], from: date)
            let minutes = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
            Task {
                model.result.settings = await model.store.updateSettings { settings in
                    if start { settings.workStartMinutes = minutes } else { settings.workEndMinutes = minutes }
                }
            }
        })
    }

    // MARK: Agents

    private var agents: some View {
        Section(NCAgendaText.t("_nodrive_agenda_agents_")) {
            switch model.result.status.registry {
            case .missing:
                Text(NCAgendaText.t("_nodrive_agenda_registry_missing_")).font(.footnote).foregroundStyle(.secondary)
            case .invalid:
                Text(NCAgendaText.t("_nodrive_agenda_registry_invalid_")).font(.footnote).foregroundStyle(.secondary)
            default:
                if model.result.snapshot.agents.isEmpty {
                    Text(NCAgendaText.t("_nodrive_agenda_no_agents_")).font(.footnote).foregroundStyle(.secondary)
                }
            }
            ForEach(model.result.snapshot.agents) { agent in
                VStack(alignment: .leading, spacing: 2) {
                    Text("🤖 " + agent.name)
                    Text(agent.status.rawValue.capitalized + (agent.organisation.isEmpty ? "" : " · " + agent.organisation))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("agendaAgent-" + agent.id)
            }
            switch model.result.status.gantt {
            case .notInstalled:
                Text(NCAgendaText.t("_nodrive_agenda_gantt_not_installed_")).font(.footnote).foregroundStyle(.secondary)
            default:
                EmptyView()
            }
        }
    }
}

/// "Which of your calendars are personal?", asked once per account.
struct NCAgendaPersonalQuestionView: View {
    @Bindable var model: NCAgendaViewModel
    @State private var personal: Set<String> = []
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(NCAgendaText.t("_nodrive_agenda_personal_explain_")).font(.footnote).foregroundStyle(.secondary)
                    ForEach(model.ownCalendars) { source in
                        Toggle(isOn: Binding(get: { personal.contains(source.key) }, set: { on in
                            if on { personal.insert(source.key) } else { personal.remove(source.key) }
                        })) {
                            HStack {
                                Circle().fill(NCAgendaColors.color(source.color)).frame(width: 10, height: 10).accessibilityHidden(true)
                                Text(source.name)
                            }
                        }
                        .accessibilityIdentifier("agendaPersonalToggle-" + source.key)
                    }
                }
            }
            .navigationTitle(NCAgendaText.t("_nodrive_agenda_personal_question_"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(NCAgendaText.t("_nodrive_agenda_done_")) {
                        Task { await model.answerPersonalQuestion(personalKeys: personal) }
                    }
                    .accessibilityIdentifier("agendaPersonalDone")
                }
            }
            .onAppear {
                guard !loaded else { return }
                loaded = true
                personal = Set(model.ownCalendars.filter { $0.setting == .personal }.map { $0.key })
            }
        }
        .interactiveDismissDisabled()
        .accessibilityIdentifier("agendaPersonalQuestion")
    }
}
