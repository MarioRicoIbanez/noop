import Foundation

/// A habit-based age estimate: the wearer's real age, moved up or down by four measured habits.
///
/// Each habit is turned into a mortality hazard ratio against a typical adult using a published
/// cohort study, and the hazard ratio into years with the Gompertz rule that adult mortality doubles
/// about every eight years of age: `years = 8 · log2(hazard ratio)`.
///
/// Sources:
/// - Steps: Paluch et al., Lancet Public Health 2022 (15 cohorts). Quartile medians 3553 / 5801 /
///   7842 / 10 901 steps a day; adjusted hazard ratios 1 / 0.60 / 0.55 / 0.47.
/// - Resting heart rate: Zhang et al., CMAJ 2016. Relative risk 1.09 per 10 beats a minute.
/// - Sleep duration: Yin et al., JAHA 2017. Lowest risk near 7 hours; relative risk 1.06 per hour
///   below it and 1.13 per hour above it.
/// - Sleep regularity: Windred et al., Sleep 2024. Sleep Regularity Index quintile medians 65.1 /
///   75.6 / 81.0 / 85.2 / 89.8; fully adjusted hazard ratios 1 / 0.80 / 0.75 / 0.72 / 0.70.
///
/// Status: not validated. The four effects come from separate studies and overlap in real life, so
/// their sum overstates the combined effect. It is a way to read habits in years, not a measurement
/// of biological age, and it carries no medical meaning.
public enum BiologicalAge {

    public struct Factor: Equatable, Sendable, Identifiable {
        public enum Kind: String, Sendable { case steps, restingHR, sleepDuration, sleepRegularity }
        public let kind: Kind
        /// The measured 30-day value: steps a day, beats a minute, hours, or index points.
        public let value: Double
        /// Years this habit adds (positive) or removes (negative).
        public let years: Double
        public var id: String { kind.rawValue }

        public init(kind: Kind, value: Double, years: Double) {
            self.kind = kind
            self.value = value
            self.years = years
        }
    }

    public struct Result: Equatable, Sendable {
        public let age: Double
        public let chronologicalAge: Double
        public let factors: [Factor]
        public var deltaYears: Double { age - chronologicalAge }

        public init(age: Double, chronologicalAge: Double, factors: [Factor]) {
            self.age = age
            self.chronologicalAge = chronologicalAge
            self.factors = factors
        }
    }

    /// Years of age per doubling of mortality risk.
    public static let doublingYears = 8.0

    // Reference points: the habit level that counts as zero years.
    public static let referenceSteps = 6500.0
    public static let referenceRestingHR = 65.0
    public static let referenceSleepHours = 7.0
    public static let referenceRegularity = 81.0

    /// Estimate from 30-day averages. A nil input leaves that habit out. Returns nil with no inputs.
    public static func estimate(chronologicalAge: Double,
                                steps: Double? = nil,
                                restingHR: Double? = nil,
                                sleepHours: Double? = nil,
                                sleepRegularity: Double? = nil) -> Result? {
        var factors: [Factor] = []
        if let steps {
            let logHR = stepsLogHazard(steps) - stepsLogHazard(referenceSteps)
            factors.append(Factor(kind: .steps, value: steps, years: years(logHR)))
        }
        if let restingHR {
            let bounded = min(100, max(40, restingHR))
            let logHR = log(1.09) * (bounded - referenceRestingHR) / 10
            factors.append(Factor(kind: .restingHR, value: restingHR, years: years(logHR)))
        }
        if let sleepHours {
            let bounded = min(11, max(4, sleepHours))
            let logHR = bounded < referenceSleepHours
                ? log(1.06) * (referenceSleepHours - bounded)
                : log(1.13) * (bounded - referenceSleepHours)
            factors.append(Factor(kind: .sleepDuration, value: sleepHours, years: years(logHR)))
        }
        if let sleepRegularity {
            let logHR = regularityLogHazard(sleepRegularity) - regularityLogHazard(referenceRegularity)
            factors.append(Factor(kind: .sleepRegularity, value: sleepRegularity, years: years(logHR)))
        }
        guard !factors.isEmpty else { return nil }
        let total = factors.reduce(0) { $0 + $1.years }
        return Result(age: chronologicalAge + total, chronologicalAge: chronologicalAge, factors: factors)
    }

    static func years(_ logHazard: Double) -> Double {
        doublingYears * logHazard / log(2)
    }

    static func stepsLogHazard(_ steps: Double) -> Double {
        interpolate(steps, xs: [3553, 5801, 7842, 10901], ys: [0, log(0.60), log(0.55), log(0.47)])
    }

    static func regularityLogHazard(_ index: Double) -> Double {
        interpolate(index, xs: [65.10, 75.62, 80.99, 85.22, 89.80],
                    ys: [0, log(0.80), log(0.75), log(0.72), log(0.70)])
    }

    /// Piecewise-linear interpolation, held flat outside the first and last point.
    static func interpolate(_ x: Double, xs: [Double], ys: [Double]) -> Double {
        guard let firstX = xs.first, let lastX = xs.last, xs.count == ys.count else { return 0 }
        if x <= firstX { return ys[0] }
        if x >= lastX { return ys[ys.count - 1] }
        for i in 1..<xs.count where x <= xs[i] {
            let t = (x - xs[i - 1]) / (xs[i] - xs[i - 1])
            return ys[i - 1] + t * (ys[i] - ys[i - 1])
        }
        return ys[ys.count - 1]
    }

    // MARK: - Sleep Regularity Index

    /// Sleep Regularity Index from sleep sessions: how often the asleep/awake state at one minute
    /// matches the state 24 hours later, scaled so 100 is identical days and 0 is chance.
    ///
    /// Sessions are (start, end) in Unix seconds. Wake periods inside a session count as asleep, so
    /// this reads a little higher than an index built from minute-level staging. Nil with fewer than
    /// five nights.
    public static func sleepRegularityIndex(sessions: [(start: Int, end: Int)]) -> Double? {
        let sorted = sessions.filter { $0.end > $0.start }.sorted { $0.start < $1.start }
        guard sorted.count >= 5, let first = sorted.first, let last = sorted.last else { return nil }
        let day = 86_400
        let from = first.start
        let to = last.end - day
        guard to > from else { return nil }

        func asleep(_ t: Int) -> Bool {
            for s in sorted {
                if t < s.start { return false }
                if t < s.end { return true }
            }
            return false
        }

        var matches = 0
        var total = 0
        var t = from
        while t < to {
            if asleep(t) == asleep(t + day) { matches += 1 }
            total += 1
            t += 60
        }
        guard total > 0 else { return nil }
        return -100 + 200 * Double(matches) / Double(total)
    }
}
