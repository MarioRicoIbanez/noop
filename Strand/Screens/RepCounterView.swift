import SwiftUI
import StrandAnalytics
import StrandDesign
import WhoopProtocol

// MARK: - Live rep counter

/// Reads the gyro half of each 100 Hz motion frame while the rep counter screen is open. With
/// automatic sets on it finds each set by itself (`RepSetDetector`); a set started by hand can be
/// marked rep by rep, which teaches the counter that exercise. Both counts are experimental. Raw
/// motion is not stored; only the per-exercise settings, the movement signatures and the finished sets
/// are kept.
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

    /// Something the last automatic set says about the chosen exercise.
    enum Notice: Equatable {
        /// The set moved like another exercise the wearer has done, so the screen changed to it.
        case switched(from: LibraryExercise?, to: LibraryExercise)
        /// The set did not move like the chosen exercise or any other known one.
        case unfamiliar
    }

    static let shared = RepCounterLive()

    private static let automaticKey = "repCounter.automatic.v1"

    /// The exercise being done. Changing it brings back the weight last used for it.
    @Published var exercise: LibraryExercise? = nil {
        didSet {
            guard oldValue != exercise else { return }
            settings = exercise.flatMap { RepProfileStore.profile(for: $0.id)?.settings } ?? .standard
            weightKg = exercise.map { RepSetStore.lastWeight(for: $0.id) } ?? 0
            notice = nil
        }
    }
    /// The weight on the bar or in the hand, in kilograms. Optional; it only labels the set.
    @Published var weightKg: Double = 0
    /// Whether sets start and end by themselves.
    @Published var automatic: Bool = true {
        didSet {
            UserDefaults.standard.set(automatic, forKey: Self.automaticKey)
            if !automatic { cancelAutomaticSet() }
        }
    }

    /// True while a set started by hand is running.
    @Published private(set) var isCounting = false
    /// True while a set the detector opened is running.
    @Published private(set) var isAutoCounting = false
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
    @Published private(set) var notice: Notice?
    /// When the last set ended, for the rest clock.
    @Published private(set) var lastSetEnd: Date?
    /// Last ten seconds of the swing angle in degrees, 20 values a second. Empty until three seconds in.
    @Published private(set) var angleTrace: [Double] = []
    /// Last ten seconds of the three gyro axes in degrees per second, 20 values a second.
    @Published private(set) var gyroTrace: [[Double]] = [[], [], []]
    /// Swing of the current set in degrees (peak to peak of the recent angle).
    @Published private(set) var swingDegrees: Double = 0

    private var gx: [Double] = []
    private var gy: [Double] = []
    private var gz: [Double] = []
    private var settings = RepCounter.Settings.standard
    private var detector = RepSetDetector()
    /// The stored record and movement of the last automatic set, kept so it can be moved to another exercise.
    private var lastRecordId: UUID?
    private var lastDetected: RepSetDetector.DetectedSet?

    /// Degrees per second per raw count.
    private static let gyroScale = 2000.0 / 32768.0
    /// A set longer than this stops taking samples, so the buffer stays bounded.
    private static let maxSeconds = 300

    private init() {
        automatic = (UserDefaults.standard.object(forKey: Self.automaticKey) as? Bool) ?? true
    }

    /// True while any set is running.
    var isBusy: Bool { isCounting || isAutoCounting }

    /// The screen opened the motion stream.
    func startListening() {
        guard !isListening else { return }
        isListening = true
        framesReceived = 0
    }

    /// The screen closed the motion stream.
    func stopListening() {
        isListening = false
        cancelAutomaticSet()
        if !isCounting {
            gx.removeAll(keepingCapacity: true)
            gy.removeAll(keepingCapacity: true)
            gz.removeAll(keepingCapacity: true)
            angleTrace = []
            gyroTrace = [[], [], []]
            swingDegrees = 0
        }
    }

    /// Start a set by hand. A known exercise counts with the settings learned for it.
    func begin() {
        cancelAutomaticSet()
        gx.removeAll(keepingCapacity: true)
        gy.removeAll(keepingCapacity: true)
        gz.removeAll(keepingCapacity: true)
        reps = 0
        marks = 0
        secondsReceived = 0
        angleTrace = []
        gyroTrace = [[], [], []]
        swingDegrees = 0
        lastLearning = .none
        notice = nil
        isCounting = true
    }

    /// The wearer finished one repetition.
    func mark() {
        guard isCounting else { return }
        marks += 1
    }

    /// End a set started by hand. When the wearer marked repetitions for a chosen exercise, fit the
    /// settings to that count and remember them for next time.
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
                settings = learned
                reps = marks
                lastLearning = .learned
            } else {
                lastLearning = .noMatch
            }
        }
        // A set done by hand under a chosen exercise is the best example of how that exercise moves.
        if reps >= RepSetDetector.minReps, let exercise {
            let analysis = RepCounter.analyse(gx: gx, gy: gy, gz: gz, settings: settings)
            let tempo = RepSetDetector.medianGap(analysis.peaks, sampleRate: 100)
            if analysis.result.reps > 0, tempo > 0 {
                RepSignatureStore.learn(exerciseId: exercise.id,
                                        from: RepSetDetector.DetectedSet(reps: reps, seconds: secondsReceived,
                                                                         secondsPerRep: tempo,
                                                                         swingDegrees: analysis.result.swingDegrees,
                                                                         axis: analysis.axis))
            }
        }
        sets.insert(SetResult(name: exercise?.name ?? "", reps: reps, marked: marks, seconds: secondsReceived),
                    at: 0)
        if reps > 0 {
            RepSetStore.append(RepSetRecord(date: Date(), exerciseId: exercise?.id ?? "",
                                            name: exercise?.name ?? "", muscle: exercise?.muscle ?? "",
                                            secondary: exercise?.secondary ?? [], reps: reps,
                                            seconds: secondsReceived, weightKg: weightKg))
            if let exercise { RepSetStore.setLastWeight(weightKg, for: exercise.id) }
            lastSetEnd = Date()
        }
        lastRecordId = nil
        lastDetected = nil
    }

    /// Called for every live frame from the strap; ignores anything that is not a motion frame.
    func ingest(frame: [UInt8]) {
        guard isListening || isCounting else { return }
        guard !isCounting || secondsReceived < Self.maxSeconds else { return }
        guard let columns = Whoop5RawImu.rawColumns(frame), columns.count >= 600 else { return }
        framesReceived += 1
        var sx = [Double](repeating: 0, count: 100)
        var sy = [Double](repeating: 0, count: 100)
        var sz = [Double](repeating: 0, count: 100)
        for i in 0..<100 {
            sx[i] = Double(columns[300 + i]) * Self.gyroScale
            sy[i] = Double(columns[400 + i]) * Self.gyroScale
            sz[i] = Double(columns[500 + i]) * Self.gyroScale
        }
        gx.append(contentsOf: sx)
        gy.append(contentsOf: sy)
        gz.append(contentsOf: sz)
        if !isCounting, gx.count > 1_000 {
            // Between sets only the last ten seconds are kept, enough to draw the traces.
            gx.removeFirst(gx.count - 1_000)
            gy.removeFirst(gy.count - 1_000)
            gz.removeFirst(gz.count - 1_000)
        }
        if !isCounting, automatic {
            if isAutoCounting { secondsReceived += 1 }
            handle(detector.feed(gx: sx, gy: sy, gz: sz, settings: settings))
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

    // MARK: Automatic sets

    private func cancelAutomaticSet() {
        detector.reset()
        if isAutoCounting {
            isAutoCounting = false
            reps = 0
        }
    }

    private func handle(_ event: RepSetDetector.Event?) {
        guard let event else { return }
        switch event {
        case .started(let count):
            isAutoCounting = true
            reps = count
            marks = 0
            secondsReceived = RepSetDetector.leadInSeconds
            lastLearning = .none
            notice = nil
            StrandHaptic.light.play()
        case .progress(let count):
            reps = count
        case .dropped:
            isAutoCounting = false
            reps = 0
        case .finished(let set):
            isAutoCounting = false
            reps = set.reps
            record(set)
            StrandHaptic.success.play()
        }
    }

    /// Store an automatic set under the exercise it moved like.
    private func record(_ set: RepSetDetector.DetectedSet) {
        let signatures = RepSignatureStore.all()
        let chosen = exercise
        var target = chosen
        var found: Notice?
        if let chosen, let known = signatures[chosen.id] {
            if !RepSignatureStore.matches(set, known, minAxis: 0.7) {
                if let id = RepSignatureStore.bestMatch(for: set, in: signatures, excluding: chosen.id),
                   let other = ExerciseLibrary.find(id) {
                    target = other
                    found = .switched(from: chosen, to: other)
                } else {
                    found = .unfamiliar
                }
            }
        } else if chosen == nil, let id = RepSignatureStore.bestMatch(for: set, in: signatures, excluding: nil),
                  let other = ExerciseLibrary.find(id) {
            target = other
            found = .switched(from: nil, to: other)
        }

        let weight = target == chosen ? weightKg : (target.map { RepSetStore.lastWeight(for: $0.id) } ?? 0)
        let stored = RepSetRecord(date: Date(), exerciseId: target?.id ?? "", name: target?.name ?? "",
                                  muscle: target?.muscle ?? "", secondary: target?.secondary ?? [],
                                  reps: set.reps, seconds: set.seconds, weightKg: weight)
        RepSetStore.append(stored)
        lastRecordId = stored.id
        lastDetected = set
        if found != .unfamiliar, let target {
            RepSignatureStore.learn(exerciseId: target.id, from: set)
            RepSetStore.setLastWeight(weight, for: target.id)
        }
        sets.insert(SetResult(name: target?.name ?? "", reps: set.reps, marked: 0, seconds: set.seconds), at: 0)
        secondsReceived = set.seconds
        lastSetEnd = Date()
        if target != chosen { exercise = target }
        notice = found
    }

    /// The last automatic set belongs to `chosen` after all: move it there and remember how it moved.
    func assignLastSet(to chosen: LibraryExercise?) {
        guard let id = lastRecordId, let set = lastDetected else {
            notice = nil
            return
        }
        let weight = chosen.map { RepSetStore.lastWeight(for: $0.id) } ?? 0
        RepSetStore.reassign(id: id, to: chosen, weightKg: weight)
        if let chosen { RepSignatureStore.learn(exerciseId: chosen.id, from: set, replace: true) }
        if !sets.isEmpty {
            sets[0] = SetResult(name: chosen?.name ?? "", reps: set.reps, marked: 0, seconds: set.seconds)
        }
        exercise = chosen
        notice = nil
    }

    /// The notice was wrong or has been read.
    func dismissNotice() {
        notice = nil
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

/// The strap streams motion while this screen is open. With automatic sets on, the wearer only lifts:
/// each set is found, counted and stored by itself, and a set that moves like another known exercise
/// changes the screen to it. A set started by hand can be marked rep by rep to teach an exercise.
struct RepCounterView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var live: LiveState
    @ObservedObject private var counter = RepCounterLive.shared
    @State private var startFailed = false
    @State private var choosing = false
    @State private var correcting = false
    @State private var corrected: LibraryExercise?
    @State private var showsMotion = false

    var body: some View {
        ScreenScaffold(title: "Rep counter") {
            setCard
            if let notice = counter.notice { noticeCard(notice) }
            if !counter.sets.isEmpty { setsCard }
            if let exercise = counter.exercise { exerciseCard(exercise) }
            motionCard
            NavigationLink {
                MuscleLoadView()
            } label: {
                SummaryCard(symbol: "figure.strengthtraining.traditional", title: "Muscle load",
                            showsChevron: true, accent: SummaryStyle.activity) {
                    Text("Sets per muscle group this week, and your history.")
                        .font(.system(size: 16))
                        .foregroundStyle(SummaryStyle.primary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 8)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: counter.notice)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: counter.sets.count)
        .sheet(isPresented: $choosing) {
            ExercisePickerView(selection: $counter.exercise)
        }
        .sheet(isPresented: $correcting, onDismiss: {
            if let corrected { counter.assignLastSet(to: corrected) }
            corrected = nil
        }) {
            ExercisePickerView(selection: $corrected)
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

    private var setCard: some View {
        SummaryCard(symbol: "repeat", title: "Current set", accent: SummaryStyle.activity) {
            VStack(spacing: 0) {
                exerciseRow
                    .padding(.top, 12)
                Rectangle().fill(SummaryStyle.rule).frame(height: 0.5).padding(.top, 12)
                dial
                    .padding(.top, 22)
                statusLine
                    .padding(.top, 14)
                if counter.isCounting {
                    Button {
                        counter.mark()
                        StrandHaptic.light.play()
                    } label: {
                        Text("Mark a rep (\(counter.marks))")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(Color.black)
                            .frame(maxWidth: .infinity)
                            .frame(height: 64)
                            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(SummaryStyle.activity))
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 16)
                }
                weightRow
                    .padding(.top, 18)
                Rectangle().fill(SummaryStyle.rule).frame(height: 0.5).padding(.top, 14)
                Toggle(isOn: $counter.automatic) {
                    Text("Automatic sets")
                        .font(.system(size: 17))
                        .foregroundStyle(SummaryStyle.primary)
                }
                .tint(SummaryStyle.activity)
                .disabled(counter.isCounting)
                .frame(minHeight: 50)
                handButton
                    .padding(.top, 6)
            }
            .frame(maxWidth: .infinity)
        }
    }

    /// The chosen exercise as one row that opens the picker.
    private var exerciseRow: some View {
        Button {
            if !counter.isBusy { choosing = true }
        } label: {
            HStack(spacing: 14) {
                if let exercise = counter.exercise {
                    AsyncImage(url: exercise.imageURLs.first) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        StrandPalette.surfaceInset
                    }
                    .frame(width: 64, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(exercise.name)
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(SummaryStyle.primary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        Text(MuscleGroups.title(exercise.muscle))
                            .font(.system(size: 15))
                            .foregroundStyle(SummaryStyle.activity)
                    }
                } else {
                    Image(systemName: "dumbbell.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(SummaryStyle.activity)
                        .frame(width: 64, height: 48)
                        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(StrandPalette.surfaceInset))
                    Text("Choose exercise")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(SummaryStyle.primary)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(SummaryStyle.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// The count inside a ring that sends out a slow pulse while a set is running.
    private var dial: some View {
        ZStack {
            if counter.isBusy { RepPulseRing() }
            Circle()
                .stroke(Color.white.opacity(0.07), lineWidth: 8)
            Circle()
                .stroke(SummaryStyle.activity.opacity(counter.isBusy ? 1 : 0.28), lineWidth: 8)
                .animation(.easeInOut(duration: 0.35), value: counter.isBusy)
            VStack(spacing: 0) {
                Text(String(counter.reps))
                    .font(SummaryStyle.number(88, .thin))
                    .foregroundStyle(SummaryStyle.primary)
                    .contentTransition(.numericText())
                    .animation(.spring(response: 0.3, dampingFraction: 0.8), value: counter.reps)
                Text("reps")
                    .font(.system(size: 15))
                    .foregroundStyle(SummaryStyle.secondary)
            }
        }
        .frame(width: 208, height: 208)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var statusLine: some View {
        if !counter.isBusy, counter.lastLearning == .none, !startFailed, live.connected, live.encryptedBond,
           let end = counter.lastSetEnd {
            TimelineView(.periodic(from: end, by: 1)) { timeline in
                let rest = max(0, Int(timeline.date.timeIntervalSince(end)))
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Rest")
                        .font(.system(size: 16))
                        .foregroundStyle(SummaryStyle.secondary)
                    Text(String(format: "%d:%02d", rest / 60, rest % 60))
                        .font(SummaryStyle.number(22, .regular))
                        .foregroundStyle(SummaryStyle.primary)
                }
            }
        } else {
            Text(status)
                .font(.system(size: 16))
                .foregroundStyle(SummaryStyle.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The weight on the bar or in the hand, in steps of 2.5 kg. Optional; it only labels the set.
    private var weightRow: some View {
        HStack(spacing: 12) {
            Text("Weight")
                .font(.system(size: 17))
                .foregroundStyle(SummaryStyle.primary)
            Spacer()
            weightButton("minus") { counter.weightKg = max(0, counter.weightKg - 2.5) }
            SummaryValue(text: counter.weightKg.formatted(.number.precision(.fractionLength(0...1))), unit: "kg",
                         size: 20)
                .frame(minWidth: 76)
            weightButton("plus") { counter.weightKg = min(500, counter.weightKg + 2.5) }
        }
    }

    private func weightButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button {
            action()
            StrandHaptic.selection.play()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(SummaryStyle.primary)
                .frame(width: 44, height: 44)
                .background(Circle().fill(StrandPalette.surfaceInset))
        }
        .buttonStyle(.plain)
    }

    /// Starts or ends a set by hand. With automatic sets on it is the quiet second option, used to
    /// teach an exercise by marking its repetitions.
    private var handButton: some View {
        let primary = !counter.automatic && !counter.isCounting
        return Button {
            if counter.isCounting { counter.finish() } else { start() }
        } label: {
            Text(counter.isCounting ? "Finish set" : (counter.automatic ? "Start by hand" : "Start set"))
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(primary ? Color.black : SummaryStyle.primary)
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(primary ? SummaryStyle.activity : StrandPalette.surfaceInset)
                )
        }
        .buttonStyle(.plain)
        .disabled(!live.encryptedBond && !counter.isCounting)
        .opacity(!live.encryptedBond && !counter.isCounting ? 0.4 : 1)
    }

    private func noticeCard(_ notice: RepCounterLive.Notice) -> some View {
        SummaryCard(symbol: "sparkles", title: "Exercise check", trailing: "Experimental",
                    accent: SummaryStyle.activity) {
            VStack(alignment: .leading, spacing: 14) {
                switch notice {
                case .switched(let from, let to):
                    Text("That set moved like \(to.name), so it was saved there.")
                        .font(.system(size: 17))
                        .foregroundStyle(SummaryStyle.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    NoopButtonRow {
                        noticeButton("Correct", filled: true) { counter.dismissNotice() }
                        if let from {
                            noticeButton("No, it was \(from.name)", filled: false) { counter.assignLastSet(to: from) }
                        } else {
                            noticeButton("Choose another", filled: false) { correcting = true }
                        }
                    }
                case .unfamiliar:
                    Text("That set did not move like \(counter.exercise?.name ?? ""). Did you change exercise?")
                        .font(.system(size: 17))
                        .foregroundStyle(SummaryStyle.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    NoopButtonRow {
                        noticeButton("Choose exercise", filled: true) { correcting = true }
                        noticeButton("Same exercise", filled: false) { counter.assignLastSet(to: counter.exercise) }
                    }
                }
            }
            .padding(.top, 10)
        }
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private func noticeButton(_ title: LocalizedStringKey, filled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(filled ? Color.black : SummaryStyle.primary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, minHeight: 48)
                .background(
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(filled ? SummaryStyle.activity : StrandPalette.surfaceInset)
                )
        }
        .buttonStyle(.plain)
    }

    /// The exercise's photos and the muscles it works.
    private func exerciseCard(_ exercise: LibraryExercise) -> some View {
        SummaryCard(symbol: "dumbbell.fill", title: "Exercise",
                    trailing: RepProfileStore.profile(for: exercise.id) == nil ? nil : "Learned",
                    accent: SummaryStyle.activity) {
            VStack(alignment: .leading, spacing: 12) {
                ExerciseAnimation(exercise: exercise)
                MuscleFigure(levels: exercise.muscleLevels)
                    .frame(height: 220)
            }
            .padding(.top, 12)
        }
    }

    /// The live sensor traces, folded away until asked for.
    private var motionCard: some View {
        SummaryCard(symbol: "gyroscope", title: "Motion", trailing: motionStatus, accent: SummaryStyle.activity) {
            Button {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) { showsMotion.toggle() }
            } label: {
                HStack {
                    Text(showsMotion ? "Hide sensors" : "Show sensors")
                        .font(.system(size: 17))
                        .foregroundStyle(SummaryStyle.primary)
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(SummaryStyle.tertiary)
                        .rotationEffect(.degrees(showsMotion ? 180 : 0))
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
            if showsMotion {
                HStack(alignment: .firstTextBaseline) {
                    Text("Elevation")
                        .font(.system(size: 14))
                        .foregroundStyle(SummaryStyle.secondary)
                    Spacer()
                    SummaryValue(text: String(Int(counter.swingDegrees.rounded())), unit: "°", size: 18)
                }
                .padding(.top, 6)
                RepMotionTrace(series: [counter.angleTrace], colors: [SummaryStyle.activity])
                    .frame(height: 90)
                Rectangle().fill(SummaryStyle.rule).frame(height: 0.5).padding(.vertical, 10)
                Text("Gyroscope")
                    .font(.system(size: 14))
                    .foregroundStyle(SummaryStyle.secondary)
                RepMotionTrace(series: counter.gyroTrace,
                               colors: [SummaryStyle.activityPale, SummaryStyle.activity, SummaryStyle.activityDeep])
                    .frame(height: 70)
            }
        }
    }

    private var setsCard: some View {
        SummaryCard(symbol: "list.bullet", title: "Sets", accent: SummaryStyle.activity) {
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
                                .font(.system(size: 14))
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
            return counter.secondsReceived == 0 ? "Waiting for motion data" : "Counting. Mark each rep to teach it."
        }
        if counter.isAutoCounting { return "Counting" }
        switch counter.lastLearning {
        case .learned: return "Learned from your marks. Next time this exercise counts by itself."
        case .noMatch: return "Could not match your marks on this set. Try marking another set."
        case .none: break
        }
        if !live.connected { return "Connect the strap to count repetitions." }
        if !live.encryptedBond {
            return "The strap is connected without a secure pairing, so it cannot send motion. Pair it again with its light flashing blue."
        }
        if counter.automatic {
            return counter.framesReceived == 0 ? "Waiting for motion data" : "Ready. Just start lifting."
        }
        return "Start, do your set, then finish."
    }

    private var motionStatus: LocalizedStringKey {
        if !counter.isListening { return "No signal" }
        return counter.framesReceived == 0 ? "Waiting for motion data" : "Live"
    }

    /// Ask the strap for motion as soon as the screen is up and the pairing allows it, so sets can be
    /// found without pressing anything.
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
        counter.begin()
    }
}

/// A thin ring that grows and fades over and over, drawn around the count while a set is running.
private struct RepPulseRing: View {
    @State private var out = false

    var body: some View {
        Circle()
            .stroke(SummaryStyle.activity, lineWidth: 2)
            .scaleEffect(out ? 1.18 : 1)
            .opacity(out ? 0 : 0.7)
            .onAppear {
                withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) { out = true }
            }
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
        SummaryCard(symbol: "repeat", title: "Rep counter", showsChevron: true, accent: SummaryStyle.activity) {
            Text("Count your sets with the strap's motion sensor.")
                .font(.system(size: 15))
                .foregroundStyle(SummaryStyle.primary)
                .padding(.top, 8)
        }
        .contentShape(Rectangle())
    }
}
