import SwiftUI
import StrandDesign
import WhoopStore

/// The top of the Trends tab: a period picker, sleep compared with the period before, and deep sleep
/// per night. Reads only the daily rows.
struct TrendsHighlights: View {
    let days: [DailyMetric]
    @State private var period = 30

    private static let periods: [(days: Int, label: LocalizedStringKey)] = [
        (7, "7D"), (30, "30D"), (180, "6M"), (365, "1Y"),
    ]

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// Day keys for the `count` days ending `endingDaysAgo` days before today, oldest first.
    private func keys(count: Int, endingDaysAgo: Int) -> [String] {
        let calendar = Calendar.current
        let today = Date()
        var out: [String] = []
        for back in stride(from: endingDaysAgo + count - 1, through: endingDaysAgo, by: -1) {
            if let date = calendar.date(byAdding: .day, value: -back, to: today) {
                out.append(Self.dayFormatter.string(from: date))
            }
        }
        return out
    }

    private func mean(_ values: [Double]) -> Double? {
        values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }

    var body: some View {
        var byDay: [String: DailyMetric] = [:]
        for d in days { byDay[d.day] = d }
        let current = keys(count: period, endingDaysAgo: 0)
        let earlier = keys(count: period, endingDaysAgo: period)

        let sleepNow = current.compactMap { byDay[$0]?.totalSleepMin }.filter { $0 > 0 }
        let sleepBefore = earlier.compactMap { byDay[$0]?.totalSleepMin }.filter { $0 > 0 }
        let deep: [Double?] = current.map { key in
            guard let v = byDay[key]?.deepMin, v > 0 else { return nil }
            return v
        }

        return VStack(alignment: .leading, spacing: 14) {
            Picker("Period", selection: $period) {
                ForEach(Self.periods, id: \.days) { item in
                    Text(item.label).tag(item.days)
                }
            }
            .pickerStyle(.segmented)

            sleepCard(now: sleepNow, before: sleepBefore)
            deepCard(deep)
        }
    }

    // MARK: Sleep comparison

    private func sleepCard(now: [Double], before: [Double]) -> some View {
        let nowMean = mean(now)
        let beforeMean = mean(before)
        let comparable = now.count >= 3 && before.count >= 3
        let top = max(nowMean ?? 0, beforeMean ?? 0, 1)

        return SummaryCard(symbol: "bed.double.fill", title: "Sleep", accent: SummaryStyle.sleep) {
            Text(headline(now: nowMean, before: beforeMean, comparable: comparable))
                .font(.system(size: 20))
                .foregroundStyle(SummaryStyle.primary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)
                .padding(.bottom, 18)
            comparisonRow("This period", nowMean, top, SummaryStyle.sleep, SummaryStyle.primary)
            comparisonRow("The period before", beforeMean, top, Color(white: 0.23), SummaryStyle.secondary)
                .padding(.top, 16)
        }
    }

    private func headline(now: Double?, before: Double?, comparable: Bool) -> LocalizedStringKey {
        guard comparable, let now, let before else { return "Not enough nights yet to compare." }
        let diff = Int((now - before).rounded())
        if diff >= 3 { return "On average you sleep \(diff) minutes more than in the period before." }
        if diff <= -3 { return "On average you sleep \(-diff) minutes less than in the period before." }
        return "On average you sleep the same as in the period before."
    }

    private func comparisonRow(_ label: LocalizedStringKey, _ minutes: Double?, _ top: Double,
                               _ bar: Color, _ text: Color) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label)
                .font(.system(size: 12.5))
                .foregroundStyle(SummaryStyle.secondary)
            if let minutes {
                let total = Int(minutes.rounded())
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    SummaryValue(text: String(total / 60), unit: "h", size: 32, weight: .light, color: text)
                    SummaryValue(text: String(total % 60), unit: "min", size: 32, weight: .light, color: text)
                }
                GeometryReader { geo in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(bar)
                        .frame(width: max(6, geo.size.width * CGFloat(minutes / top)), height: 6)
                }
                .frame(height: 6)
                .padding(.top, 7)
            } else {
                SummaryValue(text: "–", unit: "", size: 32, weight: .light, color: text)
            }
        }
    }

    // MARK: Deep sleep

    private func deepCard(_ nights: [Double?]) -> some View {
        let values = nights.compactMap { $0 }
        let average = mean(values)
        // Long periods are drawn as weekly means so the bars stay readable.
        let bars: [Double?] = nights.count > 60 ? weekly(nights) : nights

        return SummaryCard(symbol: "moon.zzz.fill", title: "Deep sleep", accent: SummaryStyle.sleep) {
            Text("Average per night")
                .font(.system(size: 12.5))
                .foregroundStyle(SummaryStyle.secondary)
                .padding(.top, 12)
            if let average {
                let total = Int(average.rounded())
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    SummaryValue(text: String(total / 60), unit: "h", size: 38, weight: .light)
                    SummaryValue(text: String(total % 60), unit: "min", size: 38, weight: .light)
                }
            } else {
                SummaryValue(text: "–", unit: "", size: 38, weight: .light)
            }
            Canvas { ctx, size in
                let top = max((bars.compactMap { $0 }.max() ?? 0) * 1.1, 60)
                let slot = size.width / CGFloat(max(bars.count, 1))
                var base = Path()
                base.move(to: CGPoint(x: 0, y: size.height - 0.5))
                base.addLine(to: CGPoint(x: size.width, y: size.height - 0.5))
                ctx.stroke(base, with: .color(Color.white.opacity(0.3)), lineWidth: 1)
                for (i, value) in bars.enumerated() {
                    guard let value else { continue }
                    let h = CGFloat(value / top) * (size.height - 4)
                    let inset = min(2.2, slot * 0.2)
                    let rect = CGRect(x: CGFloat(i) * slot + inset, y: size.height - h,
                                      width: max(1, slot - inset * 2), height: h)
                    ctx.fill(Path(roundedRect: rect, cornerRadius: 1.6), with: .color(SummaryStyle.sleep))
                }
                if let average {
                    let y = size.height - CGFloat(average / top) * (size.height - 4)
                    var line = Path()
                    line.move(to: CGPoint(x: 0, y: y))
                    line.addLine(to: CGPoint(x: size.width, y: y))
                    ctx.stroke(line, with: .color(SummaryStyle.primary), lineWidth: 1)
                }
            }
            .frame(height: 120)
            .padding(.top, 10)
        }
    }

    private func weekly(_ nights: [Double?]) -> [Double?] {
        var out: [Double?] = []
        var index = 0
        while index < nights.count {
            let chunk = nights[index..<min(index + 7, nights.count)].compactMap { $0 }
            out.append(mean(chunk))
            index += 7
        }
        return out
    }
}
