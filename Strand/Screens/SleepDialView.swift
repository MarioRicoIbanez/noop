import SwiftUI
import StrandDesign

// MARK: - Shared stage styling

enum SleepStageStyle {
    static func color(_ stage: SleepStage) -> Color {
        switch stage {
        case .awake: return SummaryStyle.warn
        case .rem: return SummaryStyle.pale
        case .light: return SummaryStyle.tint
        case .deep: return SummaryStyle.deep
        }
    }

    static func title(_ stage: SleepStage) -> LocalizedStringKey {
        switch stage {
        case .awake: return "Awake"
        case .rem: return "REM"
        case .light: return "Light"
        case .deep: return "Deep"
        }
    }

    /// Top-to-bottom order of the stage lanes.
    static let order: [SleepStage] = [.awake, .rem, .light, .deep]

    static func duration(_ minutes: Double) -> String {
        let total = Int(minutes.rounded())
        if total >= 60 { return "\(total / 60) h \(total % 60) min" }
        return "\(total) min"
    }
}

// MARK: - Night dial

/// The night drawn on a 12-hour clock face: the arc runs from bedtime to wake-up and each stretch
/// takes its stage's colour.
struct SleepDial: View {
    let night: Night

    private func angle(_ secondsFromOnset: TimeInterval) -> Double {
        let onset = night.onsetDate
        let parts = Calendar.current.dateComponents([.hour, .minute, .second], from: onset)
        let onsetSeconds = Double((parts.hour ?? 0) * 3_600 + (parts.minute ?? 0) * 60 + (parts.second ?? 0))
        let hours = (onsetSeconds + secondsFromOnset) / 3_600
        return hours / 12 * 2 * Double.pi - Double.pi / 2
    }

    var body: some View {
        let intervals = night.intervals
        let total = intervals.last?.end ?? 0
        let asleep = Int(night.stages.asleep.rounded())

        ZStack {
            Canvas { ctx, size in
                let c = CGPoint(x: size.width / 2, y: size.height / 2)
                let radius = min(size.width, size.height) / 2 - 12
                let width: CGFloat = 20

                var track = Path()
                track.addArc(center: c, radius: radius, startAngle: .zero, endAngle: .degrees(360), clockwise: false)
                ctx.stroke(track, with: .color(Color(white: 0.088)), lineWidth: width)

                for m in 0..<60 {
                    let a = Double(m) / 60 * 2 * Double.pi - Double.pi / 2
                    let major = m % 5 == 0
                    let r0 = radius - width / 2 - 7
                    let r1 = radius - width / 2 - (major ? 13 : 10.5)
                    var tick = Path()
                    tick.move(to: CGPoint(x: c.x + CGFloat(cos(a)) * r0, y: c.y + CGFloat(sin(a)) * r0))
                    tick.addLine(to: CGPoint(x: c.x + CGFloat(cos(a)) * r1, y: c.y + CGFloat(sin(a)) * r1))
                    ctx.stroke(tick, with: .color(Color.white.opacity(major ? 0.5 : 0.2)),
                               style: StrokeStyle(lineWidth: major ? 1 : 0.7, lineCap: .round))
                }
                let numerals: [(Double, String)] = [(0, "12"), (3, "3"), (6, "6"), (9, "9")]
                for (hour, label) in numerals {
                    let a = hour / 12 * 2 * Double.pi - Double.pi / 2
                    let r = radius - width / 2 - 27
                    let text = Text(label).font(.system(size: 12)).foregroundColor(SummaryStyle.secondary)
                    ctx.draw(text, at: CGPoint(x: c.x + CGFloat(cos(a)) * r, y: c.y + CGFloat(sin(a)) * r))
                }

                guard total > 0 else { return }
                let start = angle(0)
                let end = angle(total)
                var whole = Path()
                whole.addArc(center: c, radius: radius, startAngle: .radians(start), endAngle: .radians(end),
                             clockwise: false)
                ctx.stroke(whole, with: .color(SummaryStyle.tint),
                           style: StrokeStyle(lineWidth: width - 4, lineCap: .round))
                if intervals.count > 2 {
                    for interval in intervals.dropFirst().dropLast() {
                        var arc = Path()
                        arc.addArc(center: c, radius: radius,
                                   startAngle: .radians(angle(interval.start) - 0.002),
                                   endAngle: .radians(angle(interval.end) + 0.002), clockwise: false)
                        ctx.stroke(arc, with: .color(SleepStageStyle.color(interval.stage)), lineWidth: width - 4)
                    }
                }
                let knobs: [(Double, String)] = [(start + 0.03, "bed.double.fill"), (end - 0.03, "alarm.fill")]
                for (a, symbol) in knobs {
                    let icon = Text(Image(systemName: symbol))
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(Color(red: 0.02, green: 0.15, blue: 0.10))
                    ctx.draw(icon, at: CGPoint(x: c.x + CGFloat(cos(a)) * radius, y: c.y + CGFloat(sin(a)) * radius))
                }
            }

            VStack(spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    SummaryValue(text: String(asleep / 60), unit: "h", size: 46, weight: .light)
                    SummaryValue(text: String(asleep % 60), unit: "min", size: 46, weight: .light)
                }
                Text("Time asleep")
                    .font(.system(size: 13))
                    .foregroundStyle(SummaryStyle.secondary)
            }
        }
        .frame(height: 296)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Stage lanes

/// The night as four lanes, one per stage, with thin connectors where the stage changes.
struct SleepLanes: View {
    let night: Night

    var body: some View {
        let intervals = night.intervals
        let total = max(intervals.last?.end ?? 0, 1)

        Canvas { ctx, size in
            let labelWidth: CGFloat = 74
            let plot = size.width - labelWidth
            let rowHeight: CGFloat = 12
            let gap: CGFloat = 13

            func y(_ stage: SleepStage) -> CGFloat {
                CGFloat(SleepStageStyle.order.firstIndex(of: stage) ?? 0) * (rowHeight + gap)
            }
            for stage in SleepStageStyle.order {
                let label = Text(SleepStageStyle.title(stage))
                    .font(.system(size: 12))
                    .foregroundColor(SummaryStyle.secondary)
                ctx.draw(label, at: CGPoint(x: 0, y: y(stage) + rowHeight / 2), anchor: .leading)
            }

            var previous: SleepStage?
            for interval in intervals {
                let x = labelWidth + CGFloat(interval.start / total) * plot
                let w = CGFloat((interval.end - interval.start) / total) * plot
                if let previous, previous != interval.stage {
                    let y0 = y(previous) + rowHeight / 2
                    let y1 = y(interval.stage) + rowHeight / 2
                    var link = Path()
                    link.move(to: CGPoint(x: x, y: min(y0, y1)))
                    link.addLine(to: CGPoint(x: x, y: max(y0, y1)))
                    ctx.stroke(link, with: .color(Color.white.opacity(0.22)), lineWidth: 1)
                }
                let rect = CGRect(x: x + 0.4, y: y(interval.stage), width: max(w - 0.8, 2.2), height: rowHeight)
                ctx.fill(Path(roundedRect: rect, cornerRadius: min(2, rect.width / 2)),
                         with: .color(SleepStageStyle.color(interval.stage)))
                previous = interval.stage
            }
        }
        .frame(height: 4 * 12 + 3 * 13)
    }
}

/// The night's stages card: lanes on top, one row per stage with its duration below.
struct SleepStagesCard: View {
    let night: Night

    private func minutes(_ stage: SleepStage) -> Double {
        switch stage {
        case .awake: return night.stages.awake
        case .rem: return night.stages.rem
        case .light: return night.stages.light
        case .deep: return night.stages.deep
        }
    }

    var body: some View {
        SummaryCard(symbol: "moon.fill", title: "Stages",
                    trailing: LocalizedStringKey(night.onsetText + " – " + night.wakeText)) {
            SleepLanes(night: night)
                .padding(.top, 12)
                .padding(.bottom, 10)
            ForEach(SleepStageStyle.order, id: \.self) { stage in
                Rectangle().fill(SummaryStyle.rule).frame(height: 0.5)
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(SleepStageStyle.color(stage))
                        .frame(width: 3, height: 16)
                    Text(SleepStageStyle.title(stage))
                        .font(.system(size: 16))
                        .foregroundStyle(SummaryStyle.primary)
                    Spacer()
                    Text(SleepStageStyle.duration(minutes(stage)))
                        .font(SummaryStyle.number(16, .regular))
                        .foregroundStyle(SummaryStyle.secondary)
                }
                .frame(height: 42)
            }
        }
    }
}

/// The top of the Sleep tab: title, the night dial, and the stages card.
struct SleepDialHero: View {
    let night: Night

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 1) {
                Text(night.dateLabel)
                    .font(.system(size: 13))
                    .foregroundStyle(SummaryStyle.secondary)
                Text("Sleep")
                    .font(.system(size: 31, weight: .medium))
                    .foregroundStyle(SummaryStyle.primary)
            }
            SleepDial(night: night)
            SleepStagesCard(night: night)
        }
    }
}
