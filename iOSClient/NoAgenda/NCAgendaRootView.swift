// SPDX-FileCopyrightText: 2026 Nourax
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// NoAgenda: header (views, dates, chips, switch, status line), banners and the Day, Week and Month lists.
struct NCAgendaRootView: View {
    @Bindable var model: NCAgendaViewModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            list
        }
        .background(Color(UIColor.systemBackground))
        .navigationTitle(NCAgendaEntry.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    model.showSources = true
                } label: {
                    Label(NCAgendaText.t("_nodrive_agenda_sources_"), systemImage: "slider.horizontal.3")
                }
                .accessibilityIdentifier("agendaSources")
            }
        }
        .task { await model.start() }
        .sheet(item: $model.selectedItem) { item in
            NCAgendaDetailSheet(model: model, item: item)
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $model.showSources) {
            NavigationStack { NCAgendaSourcesView(model: model) }
        }
        .sheet(isPresented: $model.showPersonalQuestion) {
            NCAgendaPersonalQuestionView(model: model)
                .presentationDetents([.medium, .large])
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: 8) {
            Picker("", selection: Binding(get: { model.view }, set: { model.setView($0) })) {
                ForEach(AgendaViewKind.allCases) { kind in
                    Text(kind.title).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("agendaViewPicker")

            HStack {
                Button { model.step(-1) } label: { Image(systemName: "chevron.left") }
                    .accessibilityLabel(NCAgendaText.t("_nodrive_agenda_previous_"))
                    .accessibilityIdentifier("agendaPrevious")
                Spacer()
                Text(model.headerTitle)
                    .font(.headline)
                    .accessibilityIdentifier("agendaHeaderTitle")
                Spacer()
                Button(NCAgendaText.t("_nodrive_agenda_today_")) { model.goToToday() }
                    .accessibilityIdentifier("agendaToday")
                Button { model.step(1) } label: { Image(systemName: "chevron.right") }
                    .accessibilityLabel(NCAgendaText.t("_nodrive_agenda_next_"))
                    .accessibilityIdentifier("agendaNext")
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    chip("👤 " + NCAgendaText.t("_nodrive_agenda_chip_me_"), id: "me",
                         isOn: Binding(get: { model.filter.me }, set: { value in model.setFilter { $0.me = value } }))
                    chip("🤖 " + NCAgendaText.t("_nodrive_agenda_chip_agents_"), id: "agents",
                         isOn: Binding(get: { model.filter.agents }, set: { value in model.setFilter { $0.agents = value } }))
                    chip("👥 " + NCAgendaText.t("_nodrive_agenda_chip_team_"), id: "team",
                         isOn: Binding(get: { model.filter.team }, set: { value in model.setFilter { $0.team = value } }))
                }
            }

            Picker("", selection: Binding(get: { model.filter.scope }, set: { value in model.setFilter { $0.scope = value } })) {
                Text(NCAgendaText.t("_nodrive_agenda_all_")).tag(AgendaFilter.Scope.all)
                Text(NCAgendaText.t("_nodrive_agenda_work_")).tag(AgendaFilter.Scope.work)
                Text(NCAgendaText.t("_nodrive_agenda_personal_")).tag(AgendaFilter.Scope.personal)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("agendaScope")

            if let updated = model.updatedText {
                Text(updated)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("agendaUpdated")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func chip(_ title: String, id: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) { Text(title).font(.subheadline) }
            .toggleStyle(.button)
            .accessibilityIdentifier("agendaChip-" + id)
    }

    // MARK: Lists

    private var list: some View {
        List {
            ForEach(model.banners) { banner in
                bannerRow(banner)
            }
            if model.isLoading && !model.hasLoaded {
                HStack(spacing: 8) {
                    ProgressView()
                    Text(NCAgendaText.t("_nodrive_agenda_reading_"))
                }
                .accessibilityIdentifier("agendaReading")
            }
            switch model.view {
            case .day:
                daySections(model.plan(for: model.day), showEmpty: true)
            case .week:
                ForEach(model.weekDays, id: \.self) { date in
                    Section(NCAgendaFormat.dayTitle(date)) {
                        dayRows(model.plan(for: date))
                    }
                }
            case .month:
                Section { NCAgendaMonthGrid(model: model) }
                daySections(model.plan(for: model.day), showEmpty: true)
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await model.refresh() }
        .accessibilityIdentifier("agendaList")
    }

    private func bannerRow(_ banner: AgendaBanner) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(banner.text).font(.subheadline)
            if let home = banner.openHome {
                Button(home.openTitle) { model.openHome(home) }
                    .font(.subheadline.weight(.semibold))
                    .accessibilityIdentifier("agendaBannerOpen-" + banner.id)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("agendaBanner-" + banner.id)
        .listRowBackground(Color.yellow.opacity(0.15))
    }

    @ViewBuilder
    private func daySections(_ plan: AgendaDayPlan, showEmpty: Bool) -> some View {
        if plan.isEmpty && showEmpty && (model.hasLoaded || !model.isLoading) {
            Text(NCAgendaText.t("_nodrive_agenda_nothing_"))
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("agendaEmpty")
        }
        section(plan.timed, title: nil)
        section(plan.dueToday, title: NCAgendaText.t("_nodrive_agenda_due_today_"))
        section(plan.inProgress, title: NCAgendaText.t("_nodrive_agenda_in_progress_"))
        section(plan.late, title: NCAgendaText.t("_nodrive_agenda_late_"))
        if !plan.ownProblems.isEmpty {
            Section(NCAgendaText.t("_nodrive_agenda_problems_")) {
                ForEach(plan.ownProblems) { problem in problemRow(problem) }
            }
        }
        if !plan.teamProblems.isEmpty || !plan.teamItems.isEmpty || model.filter.team && hasTeam {
            Section(NCAgendaText.t("_nodrive_agenda_my_team_")) {
                ForEach(plan.teamProblems) { problem in problemRow(problem) }
                ForEach(plan.teamItems) { item in
                    NCAgendaRowView(item: item, calendar: model.calendar) { model.selectedItem = item }
                }
                if hasTeam {
                    Toggle(NCAgendaText.t("_nodrive_agenda_show_all_team_"), isOn: $model.showAllTeam)
                        .accessibilityIdentifier("agendaShowAllTeam")
                }
            }
        }
        if !plan.noDate.isEmpty {
            DisclosureGroup(NCAgendaText.t("_nodrive_agenda_no_date_") + " (\(plan.noDate.count))") {
                ForEach(plan.noDate) { item in
                    NCAgendaRowView(item: item, calendar: model.calendar) { model.selectedItem = item }
                }
            }
            .accessibilityIdentifier("agendaNoDate")
        }
    }

    /// Does the person run any project or board? Then "My team" is there.
    private var hasTeam: Bool {
        model.result.snapshot.sources.contains { $0.setting == .doOversee }
    }

    @ViewBuilder
    private func dayRows(_ plan: AgendaDayPlan) -> some View {
        if plan.timed.isEmpty && plan.dueToday.isEmpty && plan.inProgress.isEmpty && plan.teamItems.isEmpty {
            Text(NCAgendaText.t("_nodrive_agenda_nothing_")).foregroundStyle(.secondary)
        }
        ForEach(plan.timed + plan.dueToday + plan.inProgress + plan.teamItems) { item in
            NCAgendaRowView(item: item, calendar: model.calendar) { model.selectedItem = item }
        }
    }

    @ViewBuilder
    private func section(_ items: [AgendaItem], title: String?) -> some View {
        if !items.isEmpty {
            if let title {
                Section(title) {
                    ForEach(items) { item in
                        NCAgendaRowView(item: item, calendar: model.calendar) { model.selectedItem = item }
                    }
                }
            } else {
                Section {
                    ForEach(items) { item in
                        NCAgendaRowView(item: item, calendar: model.calendar) { model.selectedItem = item }
                    }
                }
            }
        }
    }

    private func problemRow(_ problem: AgendaProblem) -> some View {
        NCAgendaProblemRowView(problem: problem) {
            if let link = problem.link { model.open(link, title: problem.home.openTitle) }
        }
    }
}

/// The month: a 7-column grid with a dot on every day that has items, then the list of the chosen day.
struct NCAgendaMonthGrid: View {
    @Bindable var model: NCAgendaViewModel

    var body: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 7)
        VStack(spacing: 6) {
            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(Array(model.calendar.veryShortWeekdaySymbols.enumerated()), id: \.offset) { index, _ in
                    let symbols = model.calendar.veryShortWeekdaySymbols
                    Text(symbols[(index + model.calendar.firstWeekday - 1) % 7])
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(Array(model.monthCells.enumerated()), id: \.offset) { _, cell in
                    if let date = cell {
                        cellView(date)
                    } else {
                        Color.clear.frame(height: 40)
                    }
                }
            }
        }
        .accessibilityIdentifier("agendaMonthGrid")
    }

    private func cellView(_ date: Date) -> some View {
        let selected = model.calendar.isDate(date, inSameDayAs: model.day)
        let dayNumber = model.calendar.component(.day, from: date)
        return Button {
            model.day = model.calendar.startOfDay(for: date)
        } label: {
            VStack(spacing: 2) {
                Text("\(dayNumber)")
                    .font(.body)
                    .foregroundStyle(selected ? Color.white : Color.primary)
                Circle()
                    .fill(model.hasItems(on: date) ? (selected ? Color.white : Color.accentColor) : Color.clear)
                    .frame(width: 6, height: 6)
            }
            .frame(maxWidth: .infinity, minHeight: 40)
            .background(selected ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("agendaMonthDay-\(dayNumber)")
    }
}
