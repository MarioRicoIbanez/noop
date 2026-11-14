import XCTest
@testable import StrandAnalytics

final class RepCounterTests: XCTestCase {

    /// A set of `reps` smooth swings of `amplitude` degrees, with two seconds of rest either side.
    private func set(reps: Int, period: Double, amplitude: Double, negative: Bool = false) -> [Double] {
        let fs = 100.0
        let sign = negative ? -1.0 : 1.0
        var rate = [Double](repeating: 0, count: 200)
        let n = Int(Double(reps) * period * fs)
        for i in 0..<n {
            let t = Double(i) / fs
            rate.append(sign * amplitude / 2 * (2 * Double.pi / period) * sin(2 * Double.pi * t / period))
        }
        rate += [Double](repeating: 0, count: 200)
        return rate
    }

    private func count(_ rate: [Double]) -> Int {
        let minor = rate.map { $0 * 0.02 }
        let zero = [Double](repeating: 0, count: rate.count)
        return RepCounter.count(gx: rate, gy: minor, gz: zero).reps
    }

    func testRecoversSeveralInjectedCounts() {
        XCTAssertEqual(count(set(reps: 8, period: 2.0, amplitude: 60)), 8)
        XCTAssertEqual(count(set(reps: 12, period: 1.5, amplitude: 45, negative: true)), 12)
        XCTAssertEqual(count(set(reps: 5, period: 3.0, amplitude: 90)), 5)
        XCTAssertEqual(count(set(reps: 15, period: 1.2, amplitude: 70, negative: true)), 15)
        XCTAssertEqual(count(set(reps: 3, period: 2.5, amplitude: 80)), 3)
    }

    func testSmallSwingIsNotASet() {
        XCTAssertEqual(count(set(reps: 8, period: 2.0, amplitude: 10)), 0)
    }

    func testCalibrationReproducesAMarkedCount() throws {
        // A fast, small-swing set that the standard settings refuse.
        let rate = set(reps: 10, period: 1.0, amplitude: 24)
        let minor = rate.map { $0 * 0.02 }
        let zero = [Double](repeating: 0, count: rate.count)
        XCTAssertEqual(RepCounter.count(gx: rate, gy: minor, gz: zero).reps, 0)
        let learned = try XCTUnwrap(RepCounter.calibrate(gx: rate, gy: minor, gz: zero, targetReps: 10))
        XCTAssertEqual(RepCounter.count(gx: rate, gy: minor, gz: zero, settings: learned).reps, 10)
    }

    func testShortInputIsNotASet() {
        XCTAssertEqual(RepCounter.count(gx: [1, 2], gy: [0, 0], gz: [0, 0]), .none)
    }
}
