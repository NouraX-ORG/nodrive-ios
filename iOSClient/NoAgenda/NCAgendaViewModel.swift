// SPDX-FileCopyrightText: 2026 Nourax
// SPDX-License-Identifier: GPL-3.0-or-later

import Observation
import SwiftUI

enum AgendaViewKind: String, CaseIterable, Identifiable {
    case day, week, month
    var id: String { rawValue }

    var title: String {
        switch self {
        case .day: return NCAgendaText.t("_nodrive_agenda_day_")
        case .week: return NCAgendaText.t("_nodrive_agenda_week_")
        case .month: return NCAgendaText.t("_nodrive_agenda_month_")
        }
    }
}

/// A line above the list: a state of the data (design 2.8), with "Open in ..." where the person can act.
struct AgendaBanner: Identifiable, Equatable {
    var id: String
    var text: String
    var openHome: AgendaHome?
}

/// Texts and times for rows and the header. Plain functions.
enum NCAgendaFormat {
    static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    static func dayTitle(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }

    static func shortDay(_ date: Date) -> String {
        date.formatted(.dateTime.day().month(.abbreviated))
    }

    /// "10:00 - 11:00", "All day", "Due 17:00" and so on; nil when the item has no time.
    static func whenText(_ item: AgendaItem, calendar: Calendar) -> String? {
        switch item.kind {
        case .event:
            if item.allDay { return NCAgendaText.t("_nodrive_agenda_all_day_") }
            guard let start = item.start else { return nil }
            if let end = item.end, end > start { return time(start) + " - " + time(end) }
            return time(start)
        case .todo:
            if let due = item.due { return NCAgendaText.f("_nodrive_agenda_due_", shortDay(due)) }
            if let start = item.start { return shortDay(start) }
            return nil
        case .ganttTask:
            if let start = item.start, let end = item.end { return shortDay(start) + " - " + shortDay(end) }
            if let end = item.end { return NCAgendaText.f("_nodrive_agenda_due_", shortDay(end)) }
            return nil
        case .milestone:
            return (item.end ?? item.start).map { shortDay($0) }
        case .card:
            return item.due.map { NCAgendaText.f("_nodrive_agenda_due_", shortDay($0)) }
        }
    }

    /// What a screen reader says: "Event, Dentist, 10:00 - 11:00, Personal, done by you".
    static func spoken(_ item: AgendaItem, calendar: Calendar) -> String {
        var parts = [item.kind.spokenName, item.title]
        if let when = whenText(item, calendar: calendar) { parts.append(when) }
        parts.append(item.sourceName)
        parts.append(item.agent.isSelf ? NCAgendaText.t("_nodrive_agenda_spoken_by_you_") : NCAgendaText.f("_nodrive_agenda_spoken_by_agent_", item.agent.displayText))
        if let person = item.personName { parts.append(person) }
        if item.late { parts.append(NCAgendaText.t("_nodrive_agenda_late_")) }
        if item.blocked { parts.append(NCAgendaText.t("_nodrive_agenda_blocked_")) }
        if item.boardBadge { parts.append(NCAgendaText.t("_nodrive_agenda_spoken_board_")) }
        if item.lock != nil { parts.append(NCAgendaText.t("_nodrive_agenda_spoken_locked_")) }
        return parts.joined(separator: ", ")
    }
}

/// The state of the NoAgenda screens.
@MainActor
@Observable
final class NCAgendaViewModel {
    let account: String
    var store: NCAgendaStore
    var result = AgendaRefreshResult()
    var view: AgendaViewKind = .day
    var day: Date
    var showAllTeam = false
    var isLoading = false
    var hasLoaded = false
    var showPersonalQuestion = false
    var showSources = false
    var selectedItem: AgendaItem?
    var calendar = Calendar.current
    /// Opens a page of the server signed in (set by the screen that hosts NoAgenda).
    var openPage: (URL, String) -> Void = { _, _ in }
    private var now: () -> Date

    init(account: String, store: NCAgendaStore? = nil, now: @escaping () -> Date = { NCAgendaUITestHooks.today ?? Date() }) {
        self.account = account
        self.store = store ?? NCAgendaStore.shared(for: account)
        self.now = now
        self.day = Calendar.current.startOfDay(for: now())
    }

    var today: Date { now() }
    var filter: AgendaFilter { result.settings.filter }

    /// The accent of the screen: the brand colour of the account's theme (the same as the other NoDrive screens).
    var accentColor: Color { Color(NCBrandColor.shared.getElement(account: account)) }

    // MARK: Loading

    func start() async {
        result = await store.cached()
        applyStoredView()
        hasLoaded = !result.snapshot.sources.isEmpty
        _ = await store.updateSettings { $0.openedOnce = true }
        await refresh()
    }

    func refresh() async {
        isLoading = true
        result = await store.refresh()
        applyStoredView()
        isLoading = false
        hasLoaded = true
        if !result.settings.personalQuestionAnswered, ownCalendars.isEmpty == false, !result.status.offline, !result.status.signedOut {
            showPersonalQuestion = true
        }
    }

    /// The app came back to the foreground while NoAgenda is shown (plan 2.9): read again, unless a read is running
    /// or the first one has not finished.
    func appCameToForeground() async {
        guard hasLoaded, !isLoading else { return }
        await refresh()
    }

    private func applyStoredView() {
        if let stored = AgendaViewKind(rawValue: result.settings.view), !hasLoaded { view = stored }
    }

    // MARK: Header

    func setView(_ kind: AgendaViewKind) {
        view = kind
        Task { result.settings = await store.updateSettings { $0.view = kind.rawValue } }
    }

    func setFilter(_ change: (inout AgendaFilter) -> Void) {
        var value = result.settings.filter
        change(&value)
        result.settings.filter = value
        let saved = value
        Task { _ = await store.updateSettings { $0.filter = saved } }
    }

    func step(_ direction: Int) {
        let component: Calendar.Component
        switch view {
        case .day: component = .day
        case .week: component = .weekOfYear
        case .month: component = .month
        }
        day = calendar.date(byAdding: component, value: direction, to: day) ?? day
    }

    func goToToday() {
        day = calendar.startOfDay(for: today)
    }

    var headerTitle: String {
        switch view {
        case .day:
            return NCAgendaFormat.dayTitle(day)
        case .week:
            let days = NCAgendaPlanner.weekDays(of: day, calendar: calendar)
            guard let first = days.first, let last = days.last else { return NCAgendaFormat.dayTitle(day) }
            return NCAgendaFormat.shortDay(first) + " - " + NCAgendaFormat.shortDay(last)
        case .month:
            return day.formatted(.dateTime.month(.wide).year())
        }
    }

    // MARK: Lists

    func plan(for date: Date) -> AgendaDayPlan {
        NCAgendaPlanner.plan(day: date, snapshot: result.snapshot, filter: filter, showAllTeam: showAllTeam, now: today, calendar: calendar)
    }

    var weekDays: [Date] { NCAgendaPlanner.weekDays(of: day, calendar: calendar) }
    var monthCells: [Date?] { NCAgendaPlanner.monthGrid(of: day, calendar: calendar) }

    func hasItems(on date: Date) -> Bool {
        NCAgendaPlanner.hasItems(on: date, snapshot: result.snapshot, filter: filter, calendar: calendar)
    }

    var updatedText: String? {
        result.status.updatedAt.map { NCAgendaText.f("_nodrive_agenda_updated_", NCAgendaFormat.time($0)) }
    }

    // MARK: Banners (design 2.8 and 2.6)

    var banners: [AgendaBanner] {
        var list: [AgendaBanner] = []
        let status = result.status
        let savedText = status.updatedAt.map { NCAgendaFormat.time($0) } ?? "-"
        if status.signedOut {
            list.append(AgendaBanner(id: "signedOut", text: NCAgendaText.t("_nodrive_agenda_signed_out_"), openHome: nil))
        }
        if status.offline {
            list.append(AgendaBanner(id: "offline", text: NCAgendaText.f("_nodrive_agenda_offline_", savedText), openHome: nil))
        }
        if result.snapshot.notLinked {
            list.append(AgendaBanner(id: "notLinked", text: NCAgendaText.t("_nodrive_agenda_not_linked_"), openHome: nil))
        }
        list += homeBanners(state: status.gantt, name: "NoGantt", home: .gantt, idPrefix: "gantt")
        list += homeBanners(state: status.board, name: "NoBoard", home: .board, idPrefix: "board")
        if status.registry == .invalid {
            list.append(AgendaBanner(id: "registryInvalid", text: NCAgendaText.t("_nodrive_agenda_registry_invalid_"), openHome: nil))
        }
        return list
    }

    private func homeBanners(state: AgendaHomeState, name: String, home: AgendaHome, idPrefix: String) -> [AgendaBanner] {
        switch state {
        case .unreachable(let savedAt):
            let time = savedAt.map { NCAgendaFormat.time($0) } ?? "-"
            return [AgendaBanner(id: idPrefix + "Unreachable", text: NCAgendaText.f("_nodrive_agenda_home_unreachable_", name, time), openHome: nil)]
        case .refused:
            return [AgendaBanner(id: idPrefix + "Refused", text: NCAgendaText.f("_nodrive_agenda_home_refused_", name), openHome: home)]
        case .readOnly:
            return [AgendaBanner(id: idPrefix + "ReadOnly", text: NCAgendaText.f("_nodrive_agenda_home_read_only_", name), openHome: home)]
        default:
            return []
        }
    }

    // MARK: Sources and the one-time question

    var ownCalendars: [AgendaSource] {
        result.snapshot.sources.filter { ($0.kind == .calendar || $0.kind == .list) && $0.lockedReason == nil && [.personal, .work].contains($0.setting) }
    }

    /// Done on the question: the chosen calendars are Personal, the others Work.
    func answerPersonalQuestion(personalKeys: Set<String>) async {
        let own = ownCalendars.map { $0.key }
        result.settings = await store.updateSettings { settings in
            for key in own { settings.chosen[key] = personalKeys.contains(key) ? .personal : .work }
            settings.personalQuestionAnswered = true
        }
        showPersonalQuestion = false
        result = await store.cached()
    }

    func choose(_ setting: SourceSetting, for key: String) async {
        _ = await store.updateSettings { $0.chosen[key] = setting }
        await refresh()
    }

    func openHome(_ home: AgendaHome) {
        guard let base = NCWorkspaceSession.credentials(account: account)?.base,
              let url = NCAgendaWebLinks.homeURL(home, base: base) else { return }
        openPage(url, home.openTitle)
    }

    func open(_ link: AgendaLink, title: String) {
        guard let base = NCWorkspaceSession.credentials(account: account)?.base,
              let url = NCAgendaWebLinks.url(for: link, base: base) else { return }
        selectedItem = nil
        openPage(url, title)
    }
}
