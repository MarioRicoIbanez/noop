import SwiftUI
import StrandAnalytics
import StrandDesign
import WhoopProtocol

// MARK: - Live rep counter

/// Buffers the gyro half of each 100 Hz motion frame while a set is running and recounts the set once
/// a second. The count comes from `RepCounter`, which is experimental; nothing here is stored.
@MainActor
final class RepCounterLive: ObservableObject {
    struct SetResult: Identifiable {
        let id = UUID()
        let reps: Int
        let seconds: Int
    }

    static let shared = RepCounterLive()

    @Published private(set) var isCounting = false
    @Published private(set) var reps = 0
    @Published private(set) var secondsReceived = 0
    @Published private(set) var sets: [SetResult] = []
    /// Last ten seconds of the swing angle in degrees, 20 values a second. Empty until three seconds in.
    @Published private(set) var angleTrace: [Double] = []
    /// Last ten seconds of the three gyro axes in degrees per second, 20 values a second.
    @Published private(set) var gyroTrace: [[Double]] = [[], [], []]
    /// Swing of the current set in degrees (peak to peak of the recent angle).
    @Published private(set) var swingDegrees: Double = 0

    private var gx: [Double] = []
    private var gy: [Double] = []
    private var gz: [Double] = []

    /// Degrees per second per raw count.
    private static let gyroScale = 2000.0 / 32768.0
    /// A set longer than this stops taking samples, so the buffer stays bounded.
    private static let maxSeconds = 300

    private init() {}

    func begin() {
        gx.removeAll(keepingCapacity: true)
        gy.removeAll(keepingCapacity: true)
        gz.removeAll(keepingCapacity: true)
        reps = 0
        secondsReceived = 0
        angleTrace = []
        gyroTrace = [[], [], []]
        swingDegrees = 0
        isCounting = true
    }

    func finish() {
        guard isCounting else { return }
        isCounting = false
        if secondsReceived > 0 {
            sets.insert(SetResult(reps: reps, seconds: secondsReceived), at: 0)
        }
    }

    /// Called for every frame the collector sees; ignores anything that is not a motion frame.
    func ingest(frame: [UInt8]) {
        guard isCounting, secondsReceived < Self.maxSeconds else { return }
        guard let columns = Whoop5RawImu.rawColumns(frame), columns.count >= 600 else { return }
        for i in 0..<100 {
            gx.append(Double(columns[300 + i]) * Self.gyroScale)
            gy.append(Double(columns[400 + i]) * Self.gyroScale)
            gz.append(Double(columns[500 + i]) * Self.gyroScale)
        }
        secondsReceived += 1
        let analysis = RepCounter.analyse(gx: gx, gy: gy, gz: gz)
        if analysis.result.reps > reps { reps = analysis.result.reps }
        gyroTrace = [Self.recent(gx), Self.recent(gy), Self.recent(gz)]
        angleTrace = Self.recent(analysis.angle)
        if let low = angleTrace.min(), let high = angleTrace.max() { swingDegrees = high - low }
    }

    /// The last ten seconds of a 100 Hz series, thinned to 20 values a second.
    private static func recent(_ series: [Double]) -> [Double] {
        let tail = series.suffix(1_000)
        var out: [Double] = []
        out.reserveCapacity(tail.count / 5 + 1)
        var index = tail.startIndex
        while index < tail.endIndex {
            out.append(tail[index])
            index += 5
        }
        return out
    }
}

// MARK: - Screen

/// Start a set, do it, finish it: the strap streams motion while the set runs and the count updates
/// about once a second.
struct RepCounterView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var live: LiveState
    @ObservedObject private var counter = RepCounterLive.shared
    @State private var startFailed = false

    var body: some View {
        ScreenScaffold(title: "Rep counter",
                       subtitle: "Counts repetitions from the strap's motion sensor. Experimental.") {
            SummaryCard(symbol: "repeat", title: "Current set") {
                VStack(spacing: 6) {
                    Text(String(counter.reps))
                        .font(SummaryStyle.number(96, .thin))
                        .foregroundStyle(SummaryStyle.primary)
                    Text(status)
                        .font(.system(size: 15))
                        .foregroundStyle(SummaryStyle.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        if counter.isCounting { finish() } else { start() }
                    } label: {
                        Text(counter.isCounting ? "Finish set" : "Start set")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(counter.isCounting ? SummaryStyle.primary : Color.black)
                            .frame(maxWidth: .infinity)
                            .frame(height: 50)
                            .background(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(counter.isCounting ? StrandPalette.surfaceInset : SummaryStyle.tint)
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(!live.encryptedBond && !counter.isCounting)
                    .opacity(!live.encryptedBond && !counter.isCounting ? 0.4 : 1)
                    .padding(.top, 14)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 8)
            }

            SummaryCard(symbol: "gyroscope", title: "Motion", trailing: "Last 10 seconds") {
                HStack(alignment: .firstTextBaseline) {
                    Text("Elevation")
                        .font(.system(size: 13))
                        .foregroundStyle(SummaryStyle.secondary)
                    Spacer()
                    SummaryValue(text: String(Int(counter.swingDegrees.rounded())), unit: "°", size: 18)
                }
                .padding(.top, 12)
                MotionTrace(series: [counter.angleTrace], colors: [SummaryStyle.tint])
                    .frame(height: 90)
                Rectangle().fill(SummaryStyle.rule).frame(height: 0.5).padding(.vertical, 10)
                Text("Gyroscope")
                    .font(.system(size: 13))
                    .foregroundStyle(SummaryStyle.secondary)
                MotionTrace(series: counter.gyroTrace,
                            colors: [SummaryStyle.pale, SummaryStyle.tint, SummaryStyle.deep])
                    .frame(height: 70)
            }

            if !counter.sets.isEmpty {
                SummaryCard(symbol: "list.bullet", title: "Sets") {
                    ForEach(Array(counter.sets.enumerated()), id: \.element.id) { index, set in
                        if index > 0 {
                            Rectangle().fill(SummaryStyle.rule).frame(height: 0.5)
                        }
                        HStack {
                            Text("Set \(counter.sets.count - index)")
                                .font(.system(size: 16))
                                .foregroundStyle(SummaryStyle.primary)
                            Spacer()
                            Text("\(set.reps) reps")
                                .font(SummaryStyle.number(16, .regular))
                                .foregroundStyle(SummaryStyle.secondary)
                        }
                        .frame(height: 42)
                    }
                }
            }
        }
        .onDisappear {
            if counter.isCounting { finish() }
        }
    }

    private var status: LocalizedStringKey {
        if startFailed { return "Could not start. Another raw capture is running." }
        if counter.isCounting {
            return counter.secondsReceived == 0 ? "Waiting for motion data" : "Counting"
        }
        if !live.connected { return "Connect the strap to count repetitions." }
        if !live.encryptedBond {
            return "The strap is connected without a secure pairing, so it cannot send motion. Pair it again with its light flashing blue."
        }
        return "Start, do your set, then finish."
    }

    private func start() {
        startFailed = false
        guard model.ble.startGroundTruthRawCapture(sessionId: "rep-counter") else {
            startFailed = true
            return
        }
        counter.begin()
    }

    private func finish() {
        counter.finish()
        Task { await model.ble.stopGroundTruthRawCapture() }
    }
}

/// One or more series drawn as lines over a shared zero line, scaled to the largest swing shown.
struct MotionTrace: View {
    let series: [[Double]]
    let colors: [Color]

    var body: some View {
        Canvas { ctx, size in
            let midY = size.height / 2
            var zero = Path()
            zero.move(to: CGPoint(x: 0, y: midY))
            zero.addLine(to: CGPoint(x: size.width, y: midY))
            ctx.stroke(zero, with: .color(Color.white.opacity(0.14)), lineWidth: 1)

            var peak = 1.0
            for line in series {
                for value in line where abs(value) > peak { peak = abs(value) }
            }
            for (index, line) in series.enumerated() where line.count >= 2 {
                let step = size.width / CGFloat(200 - 1)
                let offset = CGFloat(200 - line.count) * step
                var path = Path()
                for (i, value) in line.enumerated() {
                    let x = offset + CGFloat(i) * step
                    let y = midY - CGFloat(value / peak) * (midY - 3)
                    if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
                }
                let color = index < colors.count ? colors[index] : SummaryStyle.primary
                ctx.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
            }
        }
    }
}

/// The entry card shown at the top of the Training tab.
struct RepCounterEntryCard: View {
    var body: some View {
        SummaryCard(symbol: "repeat", title: "Rep counter", showsChevron: true) {
            Text("Count your sets with the strap's motion sensor.")
                .font(.system(size: 15))
                .foregroundStyle(SummaryStyle.primary)
                .padding(.top, 8)
        }
        .contentShape(Rectangle())
    }
}
