// SPDX-FileCopyrightText: 2026 Nourax
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

extension NCAgendaStore {
    /// What the editing step needs from the cache: the person, the registry, NoGantt and Deck as last read, the
    /// calendars. The guards are passed (a NoGantt or Deck edit may be sent) only when the last read of that home was
    /// fresh and of the tested version.
    func editContext(status: AgendaStatus) -> AgendaEditContext {
        let meta = cache.load(AgendaMeta.self, name: "meta") ?? AgendaMeta()
        var context = AgendaEditContext()
        context.me = meta.me
        context.registry = cache.load(NCAgendaRegistry.self, name: "registry")
        context.gantt = cache.load(RawGantt.self, name: "gantt")
        context.deck = cache.load(RawDeck.self, name: "deck")
        context.calendars = cache.load([RawCalendar].self, name: "calendars") ?? []
        context.settings = settings()
        context.ganttGuardOK = status.gantt == .fresh
        context.deckGuardOK = status.board == .fresh
        return context
    }
}
