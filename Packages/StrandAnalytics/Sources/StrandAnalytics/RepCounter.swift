import Foundation

/// Counts repetitions of a gym exercise from wrist gyroscope samples.
///
/// The method: take the axis the wrist rotates around most (first principal component of the gyro),
/// band-pass that rotation rate to 0.2–3 Hz, integrate it to an angle, and count the angle's peaks.
/// A set is only counted when the swing is large and mostly around one axis, which rejects ordinary
/// arm movement.
///
/// Status: experimental. The thresholds were set on one recording of ten biceps curls and one
/// recording of ordinary movement; synthetic sets of 3 to 15 repetitions are recovered exactly, but
/// other real exercises and tempos are unverified.
public enum RepCounter {

    public struct Result: Equatable, Sendable {
        /// Repetitions counted, 0 when the movement does not look like a set.
        public let reps: Int
        /// 95th percentile of the swing angle around its midpoint, in degrees.
        public let swingDegrees: Double
        /// Share of gyro variance on the main rotation axis, 0…1.
        public let axisShare: Double

        public init(reps: Int, swingDegrees: Double, axisShare: Double) {
            self.reps = reps
            self.swingDegrees = swingDegrees
            self.axisShare = axisShare
        }

        public static let none = Result(reps: 0, swingDegrees: 0, axisShare: 0)
    }

    /// Smallest swing, in degrees, that counts as an exercise.
    public static let minSwingDegrees = 18.0
    /// Smallest share of variance on the main axis that counts as an exercise.
    public static let minAxisShare = 0.6
    /// Shortest time between two repetitions, in seconds.
    public static let minRepSeconds = 0.6

    /// Count repetitions in one set. `gx`, `gy`, `gz` are gyro rates in degrees per second.
    public static func count(gx: [Double], gy: [Double], gz: [Double], sampleRate: Double = 100,
                             settings: Settings = .standard) -> Result {
        analyse(gx: gx, gy: gy, gz: gz, sampleRate: sampleRate, settings: settings).result
    }

    /// The four thresholds of the counter. `standard` suits a slow curl; a wearer's marked set can
    /// produce a better fit for one exercise through `calibrate`.
    public struct Settings: Equatable, Codable, Sendable {
        /// How far a peak must stand out, as a fraction of the swing.
        public var prominenceFraction: Double
        /// Shortest time between two repetitions, in seconds.
        public var minRepSeconds: Double
        /// Smallest swing, in degrees, that counts as a set.
        public var minSwingDegrees: Double
        /// Smallest share of variance on the main axis that counts as a set.
        public var minAxisShare: Double

        public init(prominenceFraction: Double, minRepSeconds: Double, minSwingDegrees: Double,
                    minAxisShare: Double) {
            self.prominenceFraction = prominenceFraction
            self.minRepSeconds = minRepSeconds
            self.minSwingDegrees = minSwingDegrees
            self.minAxisShare = minAxisShare
        }

        public static let standard = Settings(prominenceFraction: 0.6, minRepSeconds: RepCounter.minRepSeconds,
                                              minSwingDegrees: RepCounter.minSwingDegrees,
                                              minAxisShare: RepCounter.minAxisShare)
    }

    /// Find settings under which this recorded set counts exactly `targetReps`, the number the wearer
    /// marked by hand. Tries a small grid and keeps the match closest to the standard settings; the
    /// set's own swing and axis share become the gates, loosened so a lighter set still passes.
    /// Nil when no combination reproduces the marked count.
    public static func calibrate(gx: [Double], gy: [Double], gz: [Double], targetReps: Int,
                                 sampleRate: Double = 100) -> Settings? {
        guard targetReps > 0 else { return nil }
        let open = Settings(prominenceFraction: 0.6, minRepSeconds: 0.6, minSwingDegrees: 0, minAxisShare: 0)
        let base = analyse(gx: gx, gy: gy, gz: gz, sampleRate: sampleRate, settings: open).result
        guard base.swingDegrees > 0 else { return nil }
        let swingGate = base.swingDegrees * 0.5
        let shareGate = max(0.3, base.axisShare * 0.75)

        var best: Settings?
        var bestCost = Double.infinity
        for prominence in [0.6, 0.5, 0.7, 0.4, 0.8, 0.3] {
            for minRep in [0.6, 0.8, 0.4, 1.0, 1.3] {
                let candidate = Settings(prominenceFraction: prominence, minRepSeconds: minRep,
                                         minSwingDegrees: swingGate, minAxisShare: shareGate)
                let counted = analyse(gx: gx, gy: gy, gz: gz, sampleRate: sampleRate, settings: candidate).result.reps
                guard counted == targetReps else { continue }
                let cost = abs(prominence - 0.6) + abs(minRep - 0.6)
                if cost < bestCost {
                    bestCost = cost
                    best = candidate
                }
            }
        }
        return best
    }

    /// The count together with the two signals it was read from, for drawing.
    public struct Analysis: Sendable {
        public let result: Result
        /// Swing angle around its midpoint, in degrees, one value per sample.
        public let angle: [Double]
        /// Rotation rate around the main axis, in degrees per second, one value per sample.
        public let rate: [Double]
        /// Sample index of each counted repetition's top.
        public let peaks: [Int]
        /// Unit vector of the main rotation axis in the strap's frame. Its sign is arbitrary.
        public let axis: [Double]

        public static let empty = Analysis(result: .none, angle: [], rate: [], peaks: [], axis: [0, 0, 0])
    }

    /// Count repetitions in one set and keep the angle and rate signals.
    public static func analyse(gx: [Double], gy: [Double], gz: [Double], sampleRate: Double = 100,
                               settings: Settings = .standard) -> Analysis {
        let n = min(gx.count, min(gy.count, gz.count))
        guard n >= Int(3 * sampleRate) else { return .empty }

        // Centre each axis.
        var cols: [[Double]] = []
        for source in [gx, gy, gz] {
            var sum = 0.0
            for i in 0..<n { sum += source[i] }
            let mean = sum / Double(n)
            var centred = [Double](repeating: 0, count: n)
            for i in 0..<n { centred[i] = source[i] - mean }
            cols.append(centred)
        }

        // 3×3 covariance and its dominant eigenvector by power iteration.
        var cov = [[Double]](repeating: [Double](repeating: 0, count: 3), count: 3)
        for a in 0..<3 {
            for b in a..<3 {
                var sum = 0.0
                for i in 0..<n { sum += cols[a][i] * cols[b][i] }
                cov[a][b] = sum / Double(n)
                cov[b][a] = cov[a][b]
            }
        }
        var axis = [1.0, 1.0, 1.0]
        for _ in 0..<60 {
            var next = [0.0, 0.0, 0.0]
            for a in 0..<3 {
                next[a] = cov[a][0] * axis[0] + cov[a][1] * axis[1] + cov[a][2] * axis[2]
            }
            let norm = (next[0] * next[0] + next[1] * next[1] + next[2] * next[2]).squareRoot()
            guard norm > 0 else { return .empty }
            axis = [next[0] / norm, next[1] / norm, next[2] / norm]
        }
        var lambda = 0.0
        for a in 0..<3 {
            lambda += axis[a] * (cov[a][0] * axis[0] + cov[a][1] * axis[1] + cov[a][2] * axis[2])
        }
        let total = cov[0][0] + cov[1][1] + cov[2][2]
        let share = total > 0 ? lambda / total : 0

        // Rotation rate around the main axis, band-passed.
        var rate = [Double](repeating: 0, count: n)
        for i in 0..<n {
            rate[i] = cols[0][i] * axis[0] + cols[1][i] * axis[1] + cols[2][i] * axis[2]
        }

        // Which way is "up": a set starts at rest, so the unfiltered angle at the start sits at the
        // low end of the movement. If it sits above the median instead, the axis points the other way.
        var rawAngle = [Double](repeating: 0, count: n)
        var rawAcc = 0.0
        for i in 0..<n {
            rawAcc += rate[i] / sampleRate
            rawAngle[i] = rawAcc
        }
        let restCount = max(1, Int(0.5 * sampleRate))
        var restSum = 0.0
        for i in 0..<restCount { restSum += rawAngle[i] }
        let median = rawAngle.sorted()[n / 2]
        let flipped = restSum / Double(restCount) > median

        rate = zeroPhase(rate, highPass: true, cutoff: 0.2, sampleRate: sampleRate)
        rate = zeroPhase(rate, highPass: false, cutoff: 3.0, sampleRate: sampleRate)

        // Integrate to an angle, orient it, and remove slow drift.
        var angle = [Double](repeating: 0, count: n)
        var acc = 0.0
        for i in 0..<n {
            acc += rate[i] / sampleRate
            angle[i] = acc
        }
        if flipped {
            for i in 0..<n { angle[i] = -angle[i] }
        }
        angle = zeroPhase(angle, highPass: true, cutoff: 0.15, sampleRate: sampleRate)

        let magnitudes = angle.map { abs($0) }.sorted()
        let p95 = magnitudes[Int(0.95 * Double(n - 1))]

        // Local maxima, thinned so no two are closer than the shortest repetition (tallest first).
        var candidates: [Int] = []
        if n >= 3 {
            for i in 1..<(n - 1) where angle[i] > angle[i - 1] && angle[i] >= angle[i + 1] {
                candidates.append(i)
            }
        }
        let minDistance = Int(settings.minRepSeconds * sampleRate)
        var kept: [Int] = []
        for i in candidates.sorted(by: { angle[$0] > angle[$1] }) {
            var clear = true
            for k in kept where abs(i - k) < minDistance {
                clear = false
                break
            }
            if clear { kept.append(i) }
        }
        kept.sort()

        // Keep the peaks that stand out from their surroundings by 60 % of the swing.
        var peaks: [Int] = []
        for i in kept {
            var left = angle[i]
            var j = i - 1
            while j >= 0 && angle[j] <= angle[i] {
                left = min(left, angle[j])
                j -= 1
            }
            var right = angle[i]
            j = i + 1
            while j < n && angle[j] <= angle[i] {
                right = min(right, angle[j])
                j += 1
            }
            if angle[i] - max(left, right) >= settings.prominenceFraction * p95 { peaks.append(i) }
        }

        let looksLikeSet = p95 >= settings.minSwingDegrees && share >= settings.minAxisShare
        let result = Result(reps: looksLikeSet ? peaks.count : 0, swingDegrees: p95, axisShare: share)
        return Analysis(result: result, angle: angle, rate: rate, peaks: looksLikeSet ? peaks : [], axis: axis)
    }

    // MARK: - Filters

    /// Second-order Butterworth section run forwards then backwards, so the output has no phase lag.
    static func zeroPhase(_ x: [Double], highPass: Bool, cutoff: Double, sampleRate: Double) -> [Double] {
        let w = 2 * Double.pi * cutoff / sampleRate
        let c = cos(w)
        let alpha = sin(w) / (2 * (0.5).squareRoot())
        let a0 = 1 + alpha
        let b: [Double]
        if highPass {
            b = [(1 + c) / 2 / a0, -(1 + c) / a0, (1 + c) / 2 / a0]
        } else {
            b = [(1 - c) / 2 / a0, (1 - c) / a0, (1 - c) / 2 / a0]
        }
        let a = [-2 * c / a0, (1 - alpha) / a0]
        let forward = section(x, b: b, a: a)
        let backward = section(Array(forward.reversed()), b: b, a: a)
        return Array(backward.reversed())
    }

    private static func section(_ x: [Double], b: [Double], a: [Double]) -> [Double] {
        var y = [Double](repeating: 0, count: x.count)
        var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
        for i in 0..<x.count {
            let v = x[i]
            let out = b[0] * v + b[1] * x1 + b[2] * x2 - a[0] * y1 - a[1] * y2
            x2 = x1
            x1 = v
            y2 = y1
            y1 = out
            y[i] = out
        }
        return y
    }
}
