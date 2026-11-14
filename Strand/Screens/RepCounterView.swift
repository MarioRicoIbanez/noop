import SwiftUI
import StrandAnalytics
import StrandDesign
import WhoopProtocol

// MARK: - Live rep counter

/// Buffers the gyro half of each 100 Hz motion frame while a set is running and recounts the set once
/// a second. The count comes from `RepCounter`, which is experimental. Raw motion is not stored; only
/// the per-exercise settings learned from marked sets are kept.
@MainActor
final class RepCounterLive: ObservableObject {
    struct SetResult: Identifiable {
        let id = UUID()
        let name: String
        let reps: Int
        let marked: Int
        let seconds: Int
    }

    /// What finishing a marked set did to the exercise's profile.
    enum Learning {
        case none
        case learned
        case noMatch
    }

    static let shared = RepCounterLive()

    @Published private(set) var isCounting = false
    /// True while the screen has asked the strap for motion; the traces move even between sets.
    @Published private(set) var isListening = false
    /// Motion frames (one a second) received since listening started.
    @Published private(set) var framesReceived = 0
    @Published private(set) var reps = 0
    /// Repetitions the wearer marked by hand in the current set.
    @Published private(set) var marks = 0
    @Published private(set) var secondsReceived = 0
    @Published private(set) var sets: [SetResult] = []
    @Published private(set) var lastLearning: Learning = .none
    /// Last ten seconds of the swing angle in degrees, 20 values a second. Empty until three seconds in.
    @Published private(set) var angleTrace: [Double] = []
    /// Last ten seconds of the three gyro axes in degrees per second, 20 values a second.
    @Published private(set) var gyroTrace: [[Double]] = [[], [], []]
    /// Swing of the current set in degrees (peak to peak of the recent angle).
    @Published private(set) var swingDegrees: Double = 0

    private var gx: [Double] = []
    private var gy: [Double] = []
    private var gz: [Double] = []
    private var exercise: LibraryExercise?
    private var settings = RepCounter.Settings.standard

    /// Degrees per second per raw count.
    private static let gyroScale = 2000.0 / 32768.0
    /// A set longer than this stops taking samples, so the buffer stays bounded.
    private static let maxSeconds = 300

    private init() {}

    /// The screen opened the motion stream.
    func startListening() {
        guard !isListening else { return }
        isListening = true
        framesReceived = 0
    }

    /// The screen closed the motion stream.
    func stopListening() {
        isListening = false
        if !isCounting {
            gx.removeAll(keepingCapacity: true)
            gy.removeAll(keepingCapacity: true)
            gz.removeAll(keepingCapacity: true)
            angleTrace = []
            gyroTrace = [[], [], []]
            swingDegrees = 0
        }
    }

    /// Start a set. A known exercise counts with the settings learned for it.
    func begin(exercise: LibraryExercise?) {
        gx.removeAll(keepingCapacity: true)
        gy.removeAll(keepingCapacity: true)
        gz.removeAll(keepingCapacity: true)
        self.exercise = exercise
        settings = exercise.flatMap { RepProfileStore.profile(for: $0.id)?.settings } ?? .standard
        reps = 0
        marks = 0
        secondsReceived = 0
        angleTrace = []
        gyroTrace = [[], [], []]
        swingDegrees = 0
        lastLearning = .none
        isCounting = true
    }

    /// The wearer finished one repetition.
    func mark() {
        guard isCounting else { return }
        marks += 1
    }

    /// End the set. When the wearer marked repetitions for a chosen exercise, fit the settings to that
    /// count and remember them for next time.
    func finish() {
        guard isCounting else { return }
        isCounting = false
        guard secondsReceived > 0 else { return }

        if marks > 0, let exercise {
            if let learned = RepCounter.calibrate(gx: gx, gy: gy, gz: gz, targetReps: marks) {
                let analysis = RepCounter.analyse(gx: gx, gy: gy, gz: gz, settings: learned)
                let previous = RepProfileStore.profile(for: exercise.id)
                RepProfileStore.save(RepProfile(exerciseId: exercise.id, name: exercise.name, settings: learned,
                                                swingDegrees: analysis.result.swingDegrees * 2,
                                                secondsPerRep: Double(secondsReceived) / Double(marks),
                                                markedSets: (previous?.markedSets ?? 0) + 1))
                reps = marks
                lastLearning = .learned
            } else {
                lastLearning = .noMatch
            }
        }
        sets.insert(SetResult(name: exercise?.name ?? "", reps: reps, marked: marks, seconds: secondsReceived),
                    at: 0)
    }

    /// Called for every frame the collector sees; ignores anything that is not a motion frame.
    func ingest(frame: [UInt8]) {
        guard isListening || isCounting else { return }
        guard !isCounting || secondsReceived < Self.maxSeconds else { return }
        guard let columns = Whoop5RawImu.rawColumns(frame), columns.count >= 600 else { return }
        framesReceived += 1
        for i in 0..<100 {
            gx.append(Double(columns[300 + i]) * Self.gyroScale)
            gy.append(Double(columns[400 + i]) * Self.gyroScale)
            gz.append(Double(columns[500 + i]) * Self.gyroScale)
        }
        if !isCounting, gx.count > 1_000 {
            // Between sets only the last ten seconds are kept, enough to draw the traces.
            gx.removeFirst(gx.count - 1_000)
            gy.removeFirst(gy.count - 1_000)
            gz.removeFirst(gz.count - 1_000)
        }
        let analysis = RepCounter.analyse(gx: gx, gy: gy, gz: gz, settings: settings)
        if isCounting {
            secondsReceived += 1
            if analysis.result.reps > reps { reps = analysis.result.reps }
        }
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

/// Choose an exercise, start a set, do it, finish it. The strap streams motion while the set runs and
/// the count updates about once a second. Marking each repetition by hand teaches the counter that
/// exercise.
struct RepCounterView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var live: LiveState
    @ObservedObject private var counter = RepCounterLive.shared
    @State private var startFailed = false
    @State private var exercise: LibraryExercise?
    @State private var choosing = false

    var body: some View {
        ScreenScaffold(title: "Rep counter") {
            exerciseCard
            setCard
            motionCard
            if !counter.sets.isEmpty { setsCard }
        }
        .sheet(isPresented: $choosing) {
            ExercisePickerView(selection: $exercise)
        }
        .onAppear { listen() }
        .onChange(of: live.encryptedBond) { _ in listen() }
        .onChange(of: live.connected) { connected in
            // A dropped link ends the stream on the strap; ask again once it is back.
            if connected { listen() } else { counter.stopListening() }
        }
        .onDisappear {
            if counter.isCounting { counter.finish() }
            if counter.isListening {
                counter.stopListening()
                Task { await model.ble.stopGroundTruthRawCapture() }
            }
        }
    }

    // MARK: Cards

    private var exerciseCard: some View {
        Button {
            if !counter.isCounting { choosing = true }
        } label: {
            SummaryCard(symbol: "dumbbell.fill", title: "Exercise", showsChevron: true) {
                if let exercise {
                    HStack(alignment: .center, spacing: 14) {
                        ExerciseAnimation(exercise: exercise)
                            .frame(width: 120)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(exercise.name)
                                .font(.system(size: 17, weight: .medium))
                                .foregroundStyle(SummaryStyle.primary)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(RepProfileStore.profile(for: exercise.id) == nil ? "Not learned yet" : "Learned")
                                .font(.system(size: 13))
                                .foregroundStyle(SummaryStyle.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.top, 12)
                } else {
                    Text("Choose exercise")
                        .font(.system(size: 17))
                        .foregroundStyle(SummaryStyle.primary)
                        .padding(.top, 10)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var setCard: some View {
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
                if counter.isCounting {
                    Button {
                        counter.mark()
                    } label: {
                        Text("Mark a rep (\(counter.marks))")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(Color.black)
                            .frame(maxWidth: .infinity)
                            .frame(height: 64)
                            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(SummaryStyle.tint))
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 14)
                }
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
                .padding(.top, counter.isCounting ? 4 : 14)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 8)
        }
    }

    private var motionCard: some View {
        SummaryCard(symbol: "gyroscope", title: "Motion", trailing: motionStatus) {
            HStack(alignment: .firstTextBaseline) {
                Text("Elevation")
                    .font(.system(size: 13))
                    .foregroundStyle(SummaryStyle.secondary)
                Spacer()
                SummaryValue(text: String(Int(counter.swingDegrees.rounded())), unit: "°", size: 18)
            }
            .padding(.top, 12)
            RepMotionTrace(series: [counter.angleTrace], colors: [SummaryStyle.tint])
                .frame(height: 90)
            Rectangle().fill(SummaryStyle.rule).frame(height: 0.5).padding(.vertical, 10)
            Text("Gyroscope")
                .font(.system(size: 13))
                .foregroundStyle(SummaryStyle.secondary)
            RepMotionTrace(series: counter.gyroTrace,
                           colors: [SummaryStyle.pale, SummaryStyle.tint, SummaryStyle.deep])
                .frame(height: 70)
        }
    }

    private var setsCard: some View {
        SummaryCard(symbol: "list.bullet", title: "Sets") {
            ForEach(Array(counter.sets.enumerated()), id: \.element.id) { index, set in
                if index > 0 {
                    Rectangle().fill(SummaryStyle.rule).frame(height: 0.5)
                }
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Set \(counter.sets.count - index)")
                            .font(.system(size: 16))
                            .foregroundStyle(SummaryStyle.primary)
                        if !set.name.isEmpty {
                            Text(set.name)
                                .font(.system(size: 13))
                                .foregroundStyle(SummaryStyle.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer()
                    Text("\(set.reps) reps")
                        .font(SummaryStyle.number(16, .regular))
                        .foregroundStyle(SummaryStyle.secondary)
                }
                .frame(height: 50)
            }
        }
    }

    // MARK: State

    private var status: LocalizedStringKey {
        if startFailed { return "Could not start. Another raw capture is running." }
        if counter.isCounting {
            return counter.secondsReceived == 0 ? "Waiting for motion data" : "Counting"
        }
        switch counter.lastLearning {
        case .learned: return "Learned from your marks. Next time this exercise counts by itself."
        case .noMatch: return "Could not match your marks on this set. Try marking another set."
        case .none: break
        }
        if !live.connected { return "Connect the strap to count repetitions." }
        if !live.encryptedBond {
            return "The strap is connected without a secure pairing, so it cannot send motion. Pair it again with its light flashing blue."
        }
        return "Start, do your set, then finish."
    }

    private var motionStatus: LocalizedStringKey {
        if !counter.isListening { return "No signal" }
        return counter.framesReceived == 0 ? "Waiting for motion data" : "Live"
    }

    /// Ask the strap for motion as soon as the screen is up and the pairing allows it, so the traces
    /// move before the first set.
    private func listen() {
        guard live.connected, live.encryptedBond, !counter.isListening else { return }
        startFailed = false
        guard model.ble.startGroundTruthRawCapture(sessionId: "rep-counter") else {
            startFailed = true
            return
        }
        counter.startListening()
    }

    private func start() {
        listen()
        guard counter.isListening else { return }
        counter.begin(exercise: exercise)
    }

    private func finish() {
        counter.finish()
    }
}

/// One or more series drawn as lines over a shared zero line, scaled to the largest swing shown.
struct RepMotionTrace: View {
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
            let step = size.width / CGFloat(199)
            for (index, line) in series.enumerated() where line.count >= 2 {
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
