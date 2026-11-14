import XCTest
@testable import StrandAnalytics

final class LiveBreathingTests: XCTestCase {
    private func beats(breathsPerMinute: Double, swing: Double = 35) -> [Int] {
        var out: [Int] = []
        var t = 0.0
        while out.count < 60 {
            let interval = 850 + swing * sin(2 * Double.pi * breathsPerMinute / 60 * t)
            out.append(Int(interval))
            t += interval / 1_000
        }
        return out
    }

    func testRecoversSeveralBreathingRates() {
        for target in [9.0, 12.0, 15.0, 18.0, 24.0] {
            let estimate = LiveBreathing.breathsPerMinute(rrMillis: beats(breathsPerMinute: target))
            XCTAssertNotNil(estimate)
            XCTAssertEqual(estimate ?? 0, target, accuracy: 0.6)
        }
    }

    func testFlatBeatsGiveNoEstimate() {
        XCTAssertNil(LiveBreathing.breathsPerMinute(rrMillis: Array(repeating: 850, count: 60)))
    }

    func testTooFewBeatsGiveNoEstimate() {
        XCTAssertNil(LiveBreathing.breathsPerMinute(rrMillis: Array(beats(breathsPerMinute: 15).prefix(20))))
    }

    func testRmssdOfAlternatingBeats() {
        let rr = (0..<20).map { $0 % 2 == 0 ? 800 : 840 }
        XCTAssertEqual(LiveBreathing.rmssd(rrMillis: rr) ?? 0, 40, accuracy: 0.001)
    }
}
