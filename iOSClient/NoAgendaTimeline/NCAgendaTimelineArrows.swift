// SPDX-FileCopyrightText: 2026 Nourax
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// The dependency arrows, read only, drawn under the bars. No hit testing. VoiceOver gets one line per arrow
/// ("Review banners comes after Write homepage copy").
struct NCAgendaTimelineArrowsView: View {
    let layout: TimelineLayout
    let height: CGFloat

    var body: some View {
        Canvas { context, _ in
            for arrow in layout.arrows where arrow.points.count >= 2 {
                var path = Path()
                path.move(to: arrow.points[0])
                for point in arrow.points.dropFirst() { path.addLine(to: point) }
                context.stroke(path, with: .color(Color.secondary), style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
                context.fill(Self.head(of: arrow.points), with: .color(Color.secondary))
            }
        }
        .frame(width: layout.scale.totalWidth, height: height)
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(NCAgendaTimelineLayout.spokenArrows(layout))
        .accessibilityHidden(layout.arrows.isEmpty)
        .accessibilityIdentifier("agendaTimelineArrows")
    }

    /// The little triangle at the last point, pointing the way the last segment goes.
    static func head(of points: [CGPoint]) -> Path {
        var path = Path()
        guard points.count >= 2, let tip = points.last else { return path }
        let before = points[points.count - 2]
        let dx = tip.x - before.x
        let dy = tip.y - before.y
        let length = max(0.001, (dx * dx + dy * dy).squareRoot())
        let ux = dx / length
        let uy = dy / length
        let size: CGFloat = 6
        let base = CGPoint(x: tip.x - ux * size, y: tip.y - uy * size)
        path.move(to: tip)
        path.addLine(to: CGPoint(x: base.x - uy * size / 2, y: base.y + ux * size / 2))
        path.addLine(to: CGPoint(x: base.x + uy * size / 2, y: base.y - ux * size / 2))
        path.closeSubpath()
        return path
    }
}
