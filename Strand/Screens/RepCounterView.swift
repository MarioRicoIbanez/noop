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
        let counted = RepCounter.count(gx: gx, gy: gy, gz: gz).reps
        if counted > reps { reps = counted }
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
                    .disabled(!live.bonded && !counter.isCounting)
                    .opacity(!live.bonded && !counter.isCounting ? 0.4 : 1)
                    .padding(.top, 14)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 8)
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
        if !live.bonded { return "Connect the strap to count repetitions." }
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
