import XCTest
@testable import StrandAnalytics

final class RepSetDetectorTests: XCTestCase {

    private typealias Stream = (x: [Double], y: [Double], z: [Double])

    private func still(_ seconds: Double) -> Stream {
        let zeros = [Double](repeating: 0, count: Int(seconds * 100))
        return (zeros, zeros, zeros)
    }

    /// `reps` smooth lifts of `swing` degrees peak to peak around `axis`, with `rest` seconds either side.
    private func lifts(reps: Int, period: Double, swing: Double, axis: [Double] = [0.2, 0.9, 0.3],
                       rest: Double = 3) -> Stream {
        let norm = (axis[0] * axis[0] + axis[1] * axis[1] + axis[2] * axis[2]).squareRoot()
        let unit = axis.map { $0 / norm }
        var out: Stream = ([], [], [])
        let total = Int((rest * 2 + Double(reps) * period) * 100)
        for i in 0..<total {
            let t = Double(i) / 100 - rest
            var rate = 0.0
            if t >= 0, t < Double(reps) * period {
                let w = 2 * Double.pi / period
                rate = swing / 2 * w * sin(w * t)
            }
            out.x.append(rate * unit[0])
            out.y.append(rate * unit[1])
            out.z.append(rate * unit[2])
        }
        return out
    }

    private func join(_ parts: [Stream]) -> Stream {
        var out: Stream = ([], [], [])
        for part in parts {
            out.x += part.x
            out.y += part.y
            out.z += part.z
        }
        return out
    }

    /// Feed a stream one second at a time and keep the sets it finds.
    private func sets(in stream: Stream) -> [RepSetDetector.DetectedSet] {
        var detector = RepSetDetector()
        var found: [RepSetDetector.DetectedSet] = []
        for second in 0..<(stream.x.count / 100) {
            let range = (second * 100)..<((second + 1) * 100)
            let event = detector.feed(gx: Array(stream.x[range]), gy: Array(stream.y[range]),
                                      gz: Array(stream.z[range]))
            if case .finished(let set) = event { found.append(set) }
        }
        return found
    }

    func testFindsSetsOfSeveralTempos() {
        let cases: [(reps: Int, period: Double, swing: Double)] = [(5, 2.0, 60), (8, 2.5, 90), (12, 1.5, 40),
                                                                    (10, 3.5, 120)]
        for item in cases {
            let found = sets(in: join([still(10), lifts(reps: item.reps, period: item.period, swing: item.swing),
                                       still(15)]))
            XCTAssertEqual(found.map(\.reps), [item.reps], "\(item)")
            XCTAssertEqual(found.first?.secondsPerRep ?? 0, item.period, accuracy: 0.1, "\(item)")
        }
    }

    func testWalkingTempoIsNotASet() {
        let found = sets(in: join([still(5), lifts(reps: 40, period: 1.0, swing: 35, rest: 0), still(10)]))
        XCTAssertTrue(found.isEmpty)
    }

    func testTwoSetsKeepTheirOwnAxes() {
        let first = [0.2, 0.9, 0.3]
        let second = [0.9, 0.1, 0.3]
        let found = sets(in: join([still(8), lifts(reps: 8, period: 2.2, swing: 80, axis: first), still(40),
                                   lifts(reps: 10, period: 2.0, swing: 60, axis: second), still(15)]))
        XCTAssertEqual(found.map(\.reps), [8, 10])
        guard found.count == 2 else { return }
        XCTAssertGreaterThan(RepSetDetector.axisSimilarity(found[0].axis, first), 0.98)
        XCTAssertGreaterThan(RepSetDetector.axisSimilarity(found[1].axis, second), 0.98)
        XCTAssertLessThan(RepSetDetector.axisSimilarity(found[0].axis, found[1].axis), 0.6)
    }
}
