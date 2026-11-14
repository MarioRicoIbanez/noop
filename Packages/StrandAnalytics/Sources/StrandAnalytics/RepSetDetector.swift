import Foundation

/// Finds sets in a continuous wrist gyro stream, one second at a time, so the wearer does not have to
/// press start and stop.
///
/// While idle it looks at the last eight seconds with `RepCounter`. Two repetitions at a lifting tempo
/// open a set; the set closes once the count has stopped rising for a few seconds, and is recounted up
/// to its last repetition so whatever the wearer did afterwards does not change it.
///
/// Status: experimental. Checked on one recording of ten biceps curls, one of ordinary movement and
/// synthetic sets of 1.5 to 4.5 seconds per repetition. Repetitions faster than 1.3 seconds are
/// ignored on purpose, because that is the tempo of an arm swinging while walking.
public struct RepSetDetector: Sendable {

    public struct DetectedSet: Equatable, Sendable {
        public let reps: Int
        /// Length of the set in seconds, from the lead-in to one second after the last repetition.
        public let seconds: Int
        /// Median time between repetitions, in seconds.
        public let secondsPerRep: Double
        public let swingDegrees: Double
        /// Unit vector of the main rotation axis in the strap's frame. Its sign is arbitrary.
        public let axis: [Double]

        public init(reps: Int, seconds: Int, secondsPerRep: Double, swingDegrees: Double, axis: [Double]) {
            self.reps = reps
            self.seconds = seconds
            self.secondsPerRep = secondsPerRep
            self.swingDegrees = swingDegrees
            self.axis = axis
        }
    }

    public enum Event: Equatable, Sendable {
        case started(reps: Int)
        case progress(reps: Int)
        case finished(DetectedSet)
        /// What looked like a set turned out too short or too fast to be one.
        case dropped
    }

    /// Seconds looked at while idle.
    public static let windowSeconds = 8
    /// Slowest tempo taken for walking rather than lifting, in seconds per repetition.
    public static let minSecondsPerRep = 1.3
    /// A finished set with fewer repetitions is dropped.
    public static let minReps = 3
    /// Seconds kept before the first repetition.
    public static let leadInSeconds = 2
    /// Longest set, in seconds.
    public static let maxSeconds = 300

    public private(set) var isActive = false
    /// Repetitions counted so far in the open set.
    public private(set) var reps = 0

    private var gx: [Double] = []
    private var gy: [Double] = []
    private var gz: [Double] = []
    /// Samples in the buffer when the count last rose.
    private var keptSamples = 0
    private let sampleRate: Double

    public init(sampleRate: Double = 100) {
        self.sampleRate = sampleRate
    }

    /// Forget everything, including an open set.
    public mutating func reset() {
        gx.removeAll(keepingCapacity: true)
        gy.removeAll(keepingCapacity: true)
        gz.removeAll(keepingCapacity: true)
        isActive = false
        reps = 0
        keptSamples = 0
    }

    /// The gyro samples of the open set, for drawing or learning. Empty while idle.
    public var openSet: (gx: [Double], gy: [Double], gz: [Double]) {
        isActive ? (gx, gy, gz) : ([], [], [])
    }

    /// Feed the next second of gyro rates in degrees per second.
    public mutating func feed(gx newX: [Double], gy newY: [Double], gz newZ: [Double],
                              settings: RepCounter.Settings = .standard) -> Event? {
        gx.append(contentsOf: newX)
        gy.append(contentsOf: newY)
        gz.append(contentsOf: newZ)
        var n = min(gx.count, min(gy.count, gz.count))

        if !isActive {
            let keep = Int(Double(Self.windowSeconds) * sampleRate)
            if n > keep {
                gx.removeFirst(gx.count - keep)
                gy.removeFirst(gy.count - keep)
                gz.removeFirst(gz.count - keep)
                n = keep
            }
            guard n >= Int(6 * sampleRate) else { return nil }
            let analysis = RepCounter.analyse(gx: gx, gy: gy, gz: gz, sampleRate: sampleRate, settings: settings)
            guard analysis.result.reps >= 2, let first = analysis.peaks.first,
                  Self.medianGap(analysis.peaks, sampleRate: sampleRate) >= Self.minSecondsPerRep else { return nil }
            let cut = max(0, first - Int(Double(Self.leadInSeconds) * sampleRate))
            if cut > 0 {
                gx.removeFirst(min(cut, gx.count))
                gy.removeFirst(min(cut, gy.count))
                gz.removeFirst(min(cut, gz.count))
            }
            isActive = true
            reps = analysis.result.reps
            keptSamples = min(gx.count, min(gy.count, gz.count))
            return .started(reps: reps)
        }

        let analysis = RepCounter.analyse(gx: gx, gy: gy, gz: gz, sampleRate: sampleRate, settings: settings)
        var rose = false
        if analysis.result.reps > reps {
            reps = analysis.result.reps
            keptSamples = n
            rose = true
        }
        let quiet = Double(n - keptSamples) / sampleRate
        let perRep = Double(keptSamples) / sampleRate / Double(max(reps, 1))
        let gap = min(8.0, max(4.0, 2.5 * perRep))
        guard quiet >= gap || n >= Int(Double(Self.maxSeconds) * sampleRate) else {
            return rose ? .progress(reps: reps) : nil
        }

        let m = min(n, keptSamples + Int(sampleRate))
        let closing = RepCounter.analyse(gx: Array(gx[0..<m]), gy: Array(gy[0..<m]), gz: Array(gz[0..<m]),
                                       sampleRate: sampleRate, settings: settings)
        let perRepFinal = Self.medianGap(closing.peaks, sampleRate: sampleRate)
        reset()
        guard closing.result.reps >= Self.minReps, perRepFinal >= Self.minSecondsPerRep else { return .dropped }
        return .finished(DetectedSet(reps: closing.result.reps, seconds: Int(Double(m) / sampleRate),
                                     secondsPerRep: perRepFinal, swingDegrees: closing.result.swingDegrees,
                                     axis: closing.axis))
    }

    /// Median time between consecutive peaks, in seconds; 0 with fewer than two peaks.
    public static func medianGap(_ peaks: [Int], sampleRate: Double) -> Double {
        guard peaks.count >= 2 else { return 0 }
        var gaps: [Double] = []
        for i in 1..<peaks.count { gaps.append(Double(peaks[i] - peaks[i - 1]) / sampleRate) }
        gaps.sort()
        return gaps[gaps.count / 2]
    }

    /// How alike two rotation axes are, 0…1, ignoring their sign.
    public static func axisSimilarity(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == 3, b.count == 3 else { return 0 }
        let dot = a[0] * b[0] + a[1] * b[1] + a[2] * b[2]
        let na = (a[0] * a[0] + a[1] * a[1] + a[2] * a[2]).squareRoot()
        let nb = (b[0] * b[0] + b[1] * b[1] + b[2] * b[2]).squareRoot()
        guard na > 0, nb > 0 else { return 0 }
        return min(1, abs(dot) / (na * nb))
    }
}
