import XCTest
@testable import StrandAnalytics

final class BiologicalAgeTests: XCTestCase {

    func testReferenceHabitsLeaveAgeUnchanged() throws {
        let r = try XCTUnwrap(BiologicalAge.estimate(chronologicalAge: 30, steps: 6500, restingHR: 65,
                                                     sleepHours: 7, sleepRegularity: 81))
        XCTAssertEqual(r.age, 30, accuracy: 0.05)
    }

    func testEachHabitMovesTheExpectedWay() throws {
        let few = try XCTUnwrap(BiologicalAge.estimate(chronologicalAge: 40, steps: 3553))
        let many = try XCTUnwrap(BiologicalAge.estimate(chronologicalAge: 40, steps: 10901))
        XCTAssertGreaterThan(few.age, 40)
        XCTAssertLessThan(many.age, 40)
        // Lowest against highest step quartile is a hazard ratio of 0.47: 8 · log2(1 / 0.47) years.
        XCTAssertEqual(few.age - many.age, 8 * log2(1 / 0.47), accuracy: 0.01)

        let slow = try XCTUnwrap(BiologicalAge.estimate(chronologicalAge: 40, restingHR: 55))
        XCTAssertEqual(slow.deltaYears, -8 * log2(1.09), accuracy: 0.01)

        let short = try XCTUnwrap(BiologicalAge.estimate(chronologicalAge: 40, sleepHours: 6))
        XCTAssertEqual(short.deltaYears, 8 * log2(1.06), accuracy: 0.01)
        let long = try XCTUnwrap(BiologicalAge.estimate(chronologicalAge: 40, sleepHours: 9))
        XCTAssertEqual(long.deltaYears, 16 * log2(1.13), accuracy: 0.01)

        let irregular = try XCTUnwrap(BiologicalAge.estimate(chronologicalAge: 40, sleepRegularity: 60))
        XCTAssertEqual(irregular.deltaYears, 8 * log2(1 / 0.75), accuracy: 0.01)
    }

    func testNoInputsGiveNoEstimate() {
        XCTAssertNil(BiologicalAge.estimate(chronologicalAge: 40))
    }

    func testRegularityIndexSeparatesRegularFromShiftedNights() throws {
        let day = 86_400
        let base = 1_700_000_000
        let regular = (0..<10).map { (start: base + $0 * day, end: base + $0 * day + 8 * 3_600) }
        XCTAssertEqual(try XCTUnwrap(BiologicalAge.sleepRegularityIndex(sessions: regular)), 100, accuracy: 0.01)

        // Every other night starts four hours later: half of each night's sleep no longer lines up.
        let shifted = (0..<10).map { i -> (start: Int, end: Int) in
            let offset = i % 2 == 0 ? 0 : 4 * 3_600
            return (start: base + i * day + offset, end: base + i * day + offset + 8 * 3_600)
        }
        let index = try XCTUnwrap(BiologicalAge.sleepRegularityIndex(sessions: shifted))
        XCTAssertLessThan(index, 50)
        XCTAssertNil(BiologicalAge.sleepRegularityIndex(sessions: Array(regular.prefix(3))))
    }
}
