import SwiftUI
import StrandDesign
import WhoopStore

// MARK: - Summary vitals model

/// One nightly vital as the Summary and Vitals screens draw it: the latest value, the trailing nights
/// and the wearer's own usual range (mean ± 2 SD of the earlier nights, the same width `VitalBands`
/// uses). The range is nil until there are at least four earlier nights.
struct SummaryVital: Identifiable {
    let id: String
    let title: LocalizedStringKey
    let unit: String
    let decimals: Int
    let signed: Bool
    /// Oldest → newest, at most 30 nights. The last entry is the value shown.
    let series: [Double]
    let low: Double?
    let high: Double?

    var value: Double? { series.last }

    var hasRange: Bool { low != nil && high != nil }

    var isAbove: Bool {
        guard let v = value, let hi = high else { return false }
        return v > hi
    }

    var isBelow: Bool {
        guard let v = value, let lo = low else { return false }
        return v < lo
    }

    var outOfRange: Bool { isAbove || isBelow }

    func format(_ x: Double) -> String {
        let body = abs(x).formatted(.number.precision(.fractionLength(decimals)))
        if signed {
            if x > 0 { return "+" + body }
            if x < 0 { return "−" + body }
            return body
        }
        return x < 0 ? "−" + body : body
    }

    var valueText: String {
        guard let v = value else { return "–" }
        return format(v)
    }

    /// Where `x` sits when the usual range spans 0…1. Nil without a range.
    func position(_ x: Double) -> Double? {
        guard let lo = low, let hi = high, hi > lo else { return nil }
        return (x - lo) / (hi - lo)
    }
}

enum SummaryVitals {
    /// The strap's own nightly oxygen figure, read from the computed series. Unverified: nobody has
    /// compared it with a reference oximeter. Empty when the experimental display is switched off.
    @MainActor
    static func loadOxygenEstimate(_ repo: Repository) async -> [String: Double] {
        guard PuffinExperiment.spo2CandidateDisplayEnabled else { return [:] }
        let points = await repo.exploreSeries(key: "spo2_candidate", source: "my-whoop", days: 45)
        return Dictionary(points.map { ($0.day, $0.value) }, uniquingKeysWith: { first, _ in first })
    }

    /// `oxygenEstimate` is the strap's unverified nightly oxygen figure by day; it fills in only where
    /// no calibrated value exists.
    static func build(days: [DailyMetric], oxygenEstimate: [String: Double] = [:]) -> [SummaryVital] {
        let recent = Array(days.sorted { $0.day < $1.day }.suffix(45))

        func make(_ id: String, _ title: LocalizedStringKey, _ unit: String, decimals: Int,
                  signed: Bool = false, minSD: Double,
                  _ value: (DailyMetric) -> Double?) -> SummaryVital {
            let series = Array(recent.compactMap(value).suffix(30))
            let history = Array(series.dropLast())
            var low: Double?
            var high: Double?
            if history.count >= 4 {
                let n = Double(history.count)
                let mean = history.reduce(0, +) / n
                var sumSq = 0.0
                for x in history { sumSq += (x - mean) * (x - mean) }
                let sd = max((sumSq / n).squareRoot(), minSD)
                low = mean - 2 * sd
                high = mean + 2 * sd
            }
            return SummaryVital(id: id, title: title, unit: unit, decimals: decimals, signed: signed,
                                series: series, low: low, high: high)
        }

        return [
            make("hrv", "Variability", "ms", decimals: 0, minSD: 2) { $0.avgHrv },
            make("rhr", "Pulse", "bpm", decimals: 0, minSD: 1) { d in d.restingHr.map { Double($0) } },
            make("resp", "Breathing", "rpm", decimals: 1, minSD: 0.2) { $0.respRateBpm },
            make("skin", "Temperature", "°", decimals: 1, signed: true, minSD: 0.1) { $0.skinTempDevC },
            make("spo2", "Oxygen", "%", decimals: 0, minSD: 0.4) { $0.spo2Pct ?? oxygenEstimate[$0.day] },
        ]
    }
}

// MARK: - Shared pieces

enum SummaryStyle {
    static let tint = NoopVisualStyle.green
    static let pale = NoopVisualStyle.greenSoft
    static let deep = NoopVisualStyle.greenDeep
    static let warn = NoopVisualStyle.warning
    static let primary = StrandPalette.textPrimary
    static let secondary = StrandPalette.textSecondary
    static let tertiary = StrandPalette.textTertiary
    static let rule = Color.white.opacity(0.09)

    static func number(_ size: CGFloat, _ weight: Font.Weight = .light) -> Font {
        Font.system(size: size, weight: weight).monospacedDigit()
    }
}

/// The card every Summary block sits in: near-black fill, a half-point edge, a small caps header.
struct SummaryCard<Content: View>: View {
    let symbol: String
    let title: LocalizedStringKey
    var trailing: LocalizedStringKey? = nil
    var showsChevron: Bool = false
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .semibold))
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .textCase(.uppercase)
                    .tracking(0.25)
                Spacer(minLength: 8)
                if let trailing {
                    Text(trailing)
                        .font(.system(size: 13))
                        .foregroundStyle(SummaryStyle.tertiary)
                }
                if showsChevron {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(SummaryStyle.tertiary)
                }
            }
            .foregroundStyle(SummaryStyle.secondary)
            content()
        }
        .padding(.horizontal, 18)
        .padding(.top, 15)
        .padding(.bottom, 17)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(StrandPalette.surfaceRaised)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.white.opacity(0.085), lineWidth: 0.5)
        )
    }
}

/// A value with its unit set smaller and greyer beside it.
struct SummaryValue: View {
    let text: String
    let unit: String
    var size: CGFloat = 23
    var weight: Font.Weight = .regular
    var color: Color = SummaryStyle.primary

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(text)
                .font(SummaryStyle.number(size, weight))
                .foregroundStyle(color)
            Text(unit)
                .font(.system(size: max(12, size * 0.5)))
                .foregroundStyle(SummaryStyle.secondary)
        }
        .lineLimit(1)
    }
}

// MARK: - Recovery ring

/// Three arcs, one per recovery input. Each arc's length is that input's weight and its bright part
/// is how well the input did last night.
struct SummaryRing: View {
    struct Segment {
        let weight: Double
        let fill: Double
        let color: Color
    }

    let segments: [Segment]
    private let gap = 0.035

    private func bounds(_ index: Int) -> (start: Double, end: Double) {
        let free = 1 - gap * Double(segments.count)
        var start = gap / 2
        for i in 0..<index {
            start += segments[i].weight * free + gap
        }
        return (start, start + segments[index].weight * free)
    }

    var body: some View {
        ZStack {
            Canvas { ctx, size in
                let c = CGPoint(x: size.width / 2, y: size.height / 2)
                let outer = size.width / 2 - 14
                for m in 0..<60 {
                    let a = Double(m) / 60 * 2 * Double.pi
                    let major = m % 5 == 0
                    let inner = outer - (major ? 3.5 : 2)
                    var p = Path()
                    p.move(to: CGPoint(x: c.x + CGFloat(cos(a)) * outer, y: c.y + CGFloat(sin(a)) * outer))
                    p.addLine(to: CGPoint(x: c.x + CGFloat(cos(a)) * inner, y: c.y + CGFloat(sin(a)) * inner))
                    ctx.stroke(p, with: .color(Color.white.opacity(major ? 0.3 : 0.13)), lineWidth: 0.7)
                }
            }
            ForEach(0..<segments.count, id: \.self) { i in
                let b = bounds(i)
                let seg = segments[i]
                let lit = b.start + (b.end - b.start) * min(1, max(0, seg.fill))
                Circle()
                    .trim(from: b.start, to: b.end)
                    .stroke(seg.color.opacity(0.2), style: StrokeStyle(lineWidth: 7, lineCap: .round))
                if seg.fill > 0.01 {
                    Circle()
                        .trim(from: b.start, to: lit)
                        .stroke(seg.color, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                }
            }
            .rotationEffect(.degrees(-90))
            .padding(3.5)
        }
    }
}

// MARK: - Vitals range track

/// One vital on a ruler: the grey stretch is the usual range, the hairlines are the previous seven
/// nights and the tall mark is last night.
struct VitalRangeTrack: View {
    let vital: SummaryVital

    var body: some View {
        Canvas { ctx, size in
            let w = size.width
            let midY = size.height / 2
            var base = Path()
            base.move(to: CGPoint(x: 0, y: midY))
            base.addLine(to: CGPoint(x: w, y: midY))
            ctx.stroke(base, with: .color(Color.white.opacity(0.12)), lineWidth: 1)
            guard vital.hasRange else { return }

            let band = CGRect(x: w * 0.28, y: midY - 3, width: w * 0.44, height: 6)
            ctx.fill(Path(roundedRect: band, cornerRadius: 3), with: .color(Color(white: 0.23)))

            func x(_ value: Double) -> CGFloat {
                let pos = vital.position(value) ?? 0.5
                return min(w - 3, max(3, w * CGFloat(0.28 + pos * 0.44)))
            }
            let earlier = vital.series.dropLast().suffix(7)
            for night in earlier {
                let tick = CGRect(x: x(night) - 0.5, y: midY - 3, width: 1, height: 6)
                ctx.fill(Path(tick), with: .color(Color.white.opacity(0.28)))
            }
            if let v = vital.value {
                let mark = CGRect(x: x(v) - 1.25, y: midY - 8, width: 2.5, height: 16)
                let color = vital.outOfRange ? SummaryStyle.warn : SummaryStyle.primary
                ctx.fill(Path(roundedRect: mark, cornerRadius: 1.25), with: .color(color))
            }
        }
        .frame(height: 20)
    }
}

// MARK: - Summary screen

/// The first tab: last night's recovery, the vitals against the wearer's own range, and today's effort.
struct SummaryView: View {
    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var router: NavRouter
    @State private var oxygenEstimate: [String: Double] = [:]

    var body: some View {
        let days = repo.days.sorted { $0.day < $1.day }
        let latest = days.last
        let vitals = SummaryVitals.build(days: days, oxygenEstimate: oxygenEstimate)

        ScreenScaffold(title: nil, onRefresh: { await repo.refresh() }) {
            header
            recoveryCard(latest: latest, vitals: vitals)
            NavigationLink(value: TabRoute.vitals) {
                vitalsCard(vitals)
            }
            .buttonStyle(.plain)
            NavigationLink(value: TabRoute.workouts) {
                effortCard(days: days)
            }
            .buttonStyle(.plain)
        }
        .task(id: repo.refreshSeq) {
            oxygenEstimate = await SummaryVitals.loadOxygenEstimate(repo)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 1) {
                Text(Date(), format: .dateTime.weekday(.wide).day().month(.wide))
                    .font(.system(size: 13))
                    .foregroundStyle(SummaryStyle.secondary)
                Text("Summary")
                    .font(.system(size: 31, weight: .medium))
                    .foregroundStyle(SummaryStyle.primary)
            }
            Spacer()
            Button {
                router.openDevices()
            } label: {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(SummaryStyle.secondary)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(StrandPalette.surfaceInset))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Devices"))
        }
        .padding(.bottom, 4)
    }

    // MARK: Recovery

    private func recoveryCard(latest: DailyMetric?, vitals: [SummaryVital]) -> some View {
        let recovery = latest?.recovery
        let hrv = vitals.first { $0.id == "hrv" }
        let rhr = vitals.first { $0.id == "rhr" }
        let sleepMin = latest?.totalSleepMin

        let hrvFill = hrv?.value.flatMap { hrv?.position($0) } ?? (hrv?.value == nil ? 0 : 0.5)
        let rhrPos = rhr?.value.flatMap { rhr?.position($0) }
        let rhrFill = rhrPos.map { 1 - $0 } ?? (rhr?.value == nil ? 0 : 0.5)
        let sleepFill = sleepMin.map { min(1, $0 / 480) } ?? 0

        let segments = [
            SummaryRing.Segment(weight: 0.4, fill: hrvFill, color: SummaryStyle.pale),
            SummaryRing.Segment(weight: 0.3, fill: rhrFill, color: SummaryStyle.tint),
            SummaryRing.Segment(weight: 0.3, fill: sleepFill, color: SummaryStyle.deep),
        ]

        return SummaryCard(symbol: "heart.fill", title: "Recovery") {
            HStack(alignment: .center, spacing: 20) {
                ZStack {
                    SummaryRing(segments: segments)
                    VStack(spacing: 2) {
                        Text(recovery.map { String(Int($0.rounded())) } ?? "–")
                            .font(SummaryStyle.number(54))
                            .tracking(-1.8)
                            .foregroundStyle(SummaryStyle.primary)
                        if let recovery {
                            Text(recoveryLabel(recovery))
                                .font(.system(size: 13))
                                .foregroundStyle(SummaryStyle.secondary)
                        }
                    }
                }
                .frame(width: 148, height: 148)

                VStack(alignment: .leading, spacing: 10) {
                    factor("Variability", hrv?.valueText ?? "–", "ms", SummaryStyle.pale)
                    factor("Resting pulse", rhr?.valueText ?? "–", "bpm", SummaryStyle.tint)
                    sleepFactor(sleepMin)
                }
                Spacer(minLength: 0)
            }
            .padding(.top, 12)
            .padding(.bottom, 14)

            Text(recoverySentence(recovery))
                .font(.system(size: 15))
                .foregroundStyle(SummaryStyle.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func factor(_ label: LocalizedStringKey, _ value: String, _ unit: String, _ color: Color) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(color)
                .frame(width: 3, height: 36)
            VStack(alignment: .leading, spacing: 0) {
                Text(label)
                    .font(.system(size: 13))
                    .foregroundStyle(SummaryStyle.secondary)
                    .lineLimit(1)
                SummaryValue(text: value, unit: unit)
            }
        }
    }

    private func sleepFactor(_ minutes: Double?) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(SummaryStyle.deep)
                .frame(width: 3, height: 36)
            VStack(alignment: .leading, spacing: 0) {
                Text("Sleep")
                    .font(.system(size: 13))
                    .foregroundStyle(SummaryStyle.secondary)
                if let minutes {
                    let total = Int(minutes.rounded())
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        SummaryValue(text: String(total / 60), unit: "h")
                        SummaryValue(text: String(total % 60), unit: "min")
                    }
                } else {
                    SummaryValue(text: "–", unit: "")
                }
            }
        }
    }

    private func recoveryLabel(_ value: Double) -> LocalizedStringKey {
        if value >= 67 { return "Good recovery" }
        if value >= 34 { return "Fair recovery" }
        return "Low recovery"
    }

    private func recoverySentence(_ value: Double?) -> LocalizedStringKey {
        guard let value else {
            return "No recovery score yet. Wear the strap tonight and sync in the morning."
        }
        if value >= 67 { return "You recovered well. Train as usual." }
        if value >= 34 { return "You recovered partly. Keep today's effort measured." }
        return "You recovered little. Favour rest today."
    }

    // MARK: Vitals

    private func vitalsCard(_ vitals: [SummaryVital]) -> some View {
        let measured = vitals.filter { $0.value != nil && $0.hasRange }
        let inRange = measured.filter { !$0.outOfRange }.count

        return SummaryCard(symbol: "waveform.path.ecg", title: "Vitals", trailing: "Last night",
                           showsChevron: true) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if measured.isEmpty {
                    Text("Your usual range appears after five nights.")
                        .font(.system(size: 15))
                        .foregroundStyle(SummaryStyle.secondary)
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 0) {
                        Text(String(inRange))
                            .foregroundStyle(SummaryStyle.primary)
                        Text("/" + String(measured.count))
                            .foregroundStyle(SummaryStyle.tertiary)
                    }
                    .font(SummaryStyle.number(30))
                    Text("in your usual range")
                        .font(.system(size: 15))
                        .foregroundStyle(SummaryStyle.primary)
                }
            }
            .padding(.top, 10)
            .padding(.bottom, 8)

            ForEach(Array(vitals.enumerated()), id: \.element.id) { index, vital in
                if index > 0 {
                    Rectangle().fill(SummaryStyle.rule).frame(height: 0.5)
                }
                HStack(spacing: 10) {
                    Text(vital.title)
                        .font(.system(size: 14))
                        .foregroundStyle(SummaryStyle.secondary)
                        .lineLimit(1)
                        .frame(width: 96, alignment: .leading)
                    VitalRangeTrack(vital: vital)
                    SummaryValue(text: vital.valueText, unit: vital.unit, size: 18,
                                 color: vital.outOfRange ? SummaryStyle.warn : SummaryStyle.primary)
                        .frame(width: 78, alignment: .trailing)
                }
                .frame(height: 35)
            }
        }
        .contentShape(Rectangle())
    }

    // MARK: Effort

    private func effortCard(days: [DailyMetric]) -> some View {
        let factor = UnitPrefs.currentEffortDisplayFactor()
        let recent = Array(days.suffix(14))
        let today = recent.last?.strain
        let values = recent.map { $0.strain ?? 0 }
        let top = max(values.max() ?? 0, 1)

        return SummaryCard(symbol: "flame.fill", title: "Effort", trailing: "Last 14 days",
                           showsChevron: true) {
            HStack(alignment: .bottom) {
                Text(today.map { ($0 * factor).formatted(.number.precision(.fractionLength(1))) } ?? "–")
                    .font(SummaryStyle.number(38))
                    .tracking(-1.1)
                    .foregroundStyle(SummaryStyle.primary)
                Spacer()
                HStack(alignment: .bottom, spacing: 3) {
                    ForEach(0..<values.count, id: \.self) { i in
                        let last = i == values.count - 1
                        RoundedRectangle(cornerRadius: 2)
                            .fill(last ? SummaryStyle.tint : Color(white: 0.34))
                            .frame(width: 5, height: max(3, CGFloat(values[i] / top) * 50))
                    }
                }
                .frame(height: 52, alignment: .bottom)
            }
            .padding(.top, 8)
        }
        .contentShape(Rectangle())
    }
}

// MARK: - Vitals detail

/// Thirty nights of one vital as dots over the usual-range band, with the limits written beside it.
struct VitalNightsChart: View {
    let vital: SummaryVital

    var body: some View {
        Canvas { ctx, size in
            let labelW: CGFloat = 34
            let w = size.width - labelW
            let h = size.height
            let series = vital.series
            guard let v = vital.value else { return }

            let lo = vital.low ?? (series.min() ?? v)
            let hi = vital.high ?? (series.max() ?? v)
            let spread = max(hi - lo, 0.0001)
            let dataMin = min(series.min() ?? v, lo - spread * 0.5)
            let dataMax = max(series.max() ?? v, hi + spread * 0.5)
            let range = max(dataMax - dataMin, 0.0001)

            func y(_ q: Double) -> CGFloat {
                h - 5 - CGFloat((q - dataMin) / range) * (h - 10)
            }
            func x(_ i: Int) -> CGFloat {
                let slots = max(29, series.count - 1)
                let offset = 30 - series.count
                return 6 + CGFloat(i + max(0, offset)) / CGFloat(slots) * (w - 12)
            }

            if vital.hasRange {
                let band = CGRect(x: 0, y: y(hi), width: w, height: y(lo) - y(hi))
                ctx.fill(Path(roundedRect: band, cornerRadius: 2), with: .color(Color.white.opacity(0.075)))
                for limit in [hi, lo] {
                    let label = Text(vital.format(limit))
                        .font(.system(size: 10.5))
                        .foregroundColor(SummaryStyle.tertiary)
                    ctx.draw(label, at: CGPoint(x: w + 6, y: y(limit)), anchor: .leading)
                }
            }
            for i in 0..<max(0, series.count - 1) {
                let q = series[i]
                let outside = vital.hasRange && (q < lo || q > hi)
                let dot = CGRect(x: x(i) - 1.55, y: y(q) - 1.55, width: 3.1, height: 3.1)
                ctx.fill(Path(ellipseIn: dot), with: .color(SummaryStyle.primary.opacity(outside ? 0.9 : 0.42)))
            }
            let cx = x(series.count - 1)
            let cy = y(v)
            let color = vital.outOfRange ? SummaryStyle.warn : SummaryStyle.primary
            ctx.fill(Path(ellipseIn: CGRect(x: cx - 3.6, y: cy - 3.6, width: 7.2, height: 7.2)), with: .color(color))
        }
        .frame(height: 70)
    }
}

/// Pushed from the Summary vitals card: each vital with its last 30 nights.
struct VitalsDetailView: View {
    @EnvironmentObject private var repo: Repository
    @State private var oxygenEstimate: [String: Double] = [:]

    var body: some View {
        let vitals = SummaryVitals.build(days: repo.days, oxygenEstimate: oxygenEstimate)
        let measured = vitals.filter { $0.value != nil && $0.hasRange }
        let inRange = measured.filter { !$0.outOfRange }.count

        ScreenScaffold(title: "Vitals", onRefresh: { await repo.refresh() }) {
            Group {
                if measured.isEmpty {
                    Text("Your usual range appears after five nights. Until then each vital shows its nightly value only.")
                } else {
                    Text("\(inRange) of \(measured.count) in your usual range. The band in each chart is your range over the last 30 nights.")
                }
            }
            .font(.system(size: 15))
            .foregroundStyle(SummaryStyle.secondary)
            .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 0) {
                ForEach(Array(vitals.enumerated()), id: \.element.id) { index, vital in
                    if index > 0 {
                        Rectangle().fill(SummaryStyle.rule).frame(height: 0.5)
                    }
                    row(vital)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(StrandPalette.surfaceRaised)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.085), lineWidth: 0.5)
            )

            if !oxygenEstimate.isEmpty {
                Text("Oxygen is the strap's own estimate and has not been verified against an oximeter.")
                    .font(.system(size: 13))
                    .foregroundStyle(SummaryStyle.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task(id: repo.refreshSeq) {
            oxygenEstimate = await SummaryVitals.loadOxygenEstimate(repo)
        }
    }

    private func row(_ vital: SummaryVital) -> some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(vital.title)
                    .font(.system(size: 13))
                    .foregroundStyle(SummaryStyle.secondary)
                SummaryValue(text: vital.valueText, unit: vital.unit, size: 31, weight: .light,
                             color: vital.outOfRange ? SummaryStyle.warn : SummaryStyle.primary)
                caption(vital)
                    .font(.system(size: 11.5))
                    .foregroundStyle(SummaryStyle.tertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(width: 124, alignment: .leading)
            VitalNightsChart(vital: vital)
        }
        .frame(height: 101)
    }

    private func caption(_ vital: SummaryVital) -> Text {
        if vital.value == nil { return Text("No value yet") }
        guard let lo = vital.low, let hi = vital.high else { return Text("Building your range") }
        if vital.isAbove { return Text("Above your usual range") }
        if vital.isBelow { return Text("Below your usual range") }
        return Text("Usual \(vital.format(lo)) to \(vital.format(hi))")
    }
}
