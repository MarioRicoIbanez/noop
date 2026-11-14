import Foundation

/// A live breathing-rate estimate from beat-to-beat intervals. Heart rate rises on the in-breath and
/// falls on the out-breath, so the dominant rhythm of the intervals between 6 and 30 cycles a minute
/// follows the breath. Experimental: it needs a still wearer and about a minute of clean beats, and
/// returns nil when no single rhythm stands out.
public enum LiveBreathing {
    /// Breaths per minute, or nil when the recent beats do not carry a clear rhythm.
    public static func breathsPerMinute(rrMillis: [Int]) -> Double? {
        let valid = rrMillis.filter { $0 >= 300 && $0 <= 2_000 }.map(Double.init)
        guard valid.count >= 30 else { return nil }
        let median = valid.sorted()[valid.count / 2]
        let clean = valid.filter { abs($0 - median) <= 0.25 * median }
        guard clean.count >= 30, Double(clean.count) >= 0.8 * Double(valid.count) else { return nil }

        // Beat times in seconds, then the interval series resampled evenly at 4 Hz.
        var times: [Double] = []
        times.reserveCapacity(clean.count)
        var elapsed = 0.0
        for interval in clean {
            elapsed += interval / 1_000
            times.append(elapsed)
        }
        let rate = 4.0
        let count = Int((times[times.count - 1] - times[0]) * rate)
        guard count >= 120 else { return nil }
        var series: [Double] = []
        series.reserveCapacity(count)
        var j = 0
        for k in 0..<count {
            let t = times[0] + Double(k) / rate
            while j + 1 < times.count - 1, times[j + 1] < t { j += 1 }
            let share = (t - times[j]) / (times[j + 1] - times[j])
            series.append(clean[j] + (clean[j + 1] - clean[j]) * share)
        }

        // Remove the slow drift with an eight-second moving mean.
        let half = 16
        var detrended: [Double] = []
        detrended.reserveCapacity(count)
        for k in 0..<count {
            let low = max(0, k - half), high = min(count, k + half + 1)
            var sum = 0.0
            for i in low..<high { sum += series[i] }
            detrended.append(series[k] - sum / Double(high - low))
        }

        // Power at each candidate rate from 0.1 to 0.5 Hz; the peak must stand well above the average.
        var bestPower = 0.0, bestFrequency = 0.0, totalPower = 0.0
        let steps = 81
        for step in 0..<steps {
            let frequency = 0.1 + 0.005 * Double(step)
            var re = 0.0, im = 0.0
            for k in 0..<count {
                let angle = 2 * Double.pi * frequency * Double(k) / rate
                re += detrended[k] * cos(angle)
                im += detrended[k] * sin(angle)
            }
            let power = re * re + im * im
            totalPower += power
            if power > bestPower {
                bestPower = power
                bestFrequency = frequency
            }
        }
        guard totalPower > 0, bestPower >= 10 * totalPower / Double(steps) else { return nil }
        let amplitude = 2 * bestPower.squareRoot() / Double(count)
        guard amplitude >= 4 else { return nil }
        return bestFrequency * 60
    }

    /// Short-window heart-rate variability (RMSSD, milliseconds) over the recent beats, or nil with
    /// fewer than ten clean intervals.
    public static func rmssd(rrMillis: [Int]) -> Double? {
        let valid = rrMillis.filter { $0 >= 300 && $0 <= 2_000 }.map(Double.init)
        guard valid.count >= 10 else { return nil }
        var sum = 0.0
        var n = 0
        for i in 1..<valid.count {
            let diff = valid[i] - valid[i - 1]
            guard abs(diff) <= 0.25 * valid[i - 1] else { continue }
            sum += diff * diff
            n += 1
        }
        guard n >= 8 else { return nil }
        return (sum / Double(n)).squareRoot()
    }
}
