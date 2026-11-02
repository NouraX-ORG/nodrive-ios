// SPDX-FileCopyrightText: 2026 Nourax
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

extension NCAgendaTimelineDays {
    /// 0 for Monday ... 6 for Sunday (1970-01-01 was a Thursday).
    static func weekdayIndex(_ number: Int) -> Int {
        ((number + 3) % 7 + 7) % 7
    }

    /// Does the week of the calendar start on this day?
    static func isWeekStart(_ number: Int, calendar: Calendar) -> Bool {
        weekdayIndex(number) == (calendar.firstWeekday + 5) % 7
    }
}

/// The days behind the bars: the tint of my busy time, the hatching of days off, a hairline at the start of each week and
/// the line of today. No hit testing, hidden from VoiceOver (the bars carry the words).
struct NCAgendaTimelineShadingView: View {
    let scale: TimelineScale
    let shades: [TimelineDayShade]
    let todayDay: Int
    let height: CGFloat
    let calendar: Calendar
    let accent: Color

    var body: some View {
        Canvas { context, size in
            let width = scale.pointsPerDay
            for shade in shades {
                let left = scale.x(forDay: shade.day)
                let column = CGRect(x: left, y: 0, width: width, height: size.height)
                if shade.share > 0 {
                    context.fill(Path(column), with: .color(accent.opacity(NCAgendaTimelineLayout.maxTint * shade.share)))
                }
                if shade.hatched {
                    var hatch = Path()
                    var top: CGFloat = -width
                    while top < size.height {
                        hatch.move(to: CGPoint(x: left, y: top + width))
                        hatch.addLine(to: CGPoint(x: left + width, y: top))
                        top += 8
                    }
                    context.stroke(hatch, with: .color(Color.secondary.opacity(0.35)), lineWidth: 0.7)
                }
                if NCAgendaTimelineDays.isWeekStart(shade.day, calendar: calendar) {
                    var line = Path()
                    line.move(to: CGPoint(x: left, y: 0))
                    line.addLine(to: CGPoint(x: left, y: size.height))
                    context.stroke(line, with: .color(Color.secondary.opacity(0.25)), lineWidth: 0.5)
                }
            }
            if scale.range.contains(day: todayDay) {
                let middle = scale.x(forDayCenter: todayDay)
                var line = Path()
                line.move(to: CGPoint(x: middle, y: 0))
                line.addLine(to: CGPoint(x: middle, y: size.height))
                context.stroke(line, with: .color(accent), lineWidth: 1.5)
            }
        }
        .frame(width: scale.totalWidth, height: height)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
