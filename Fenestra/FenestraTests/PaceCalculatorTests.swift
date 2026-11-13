import XCTest

@testable import Fenestra

final class PaceCalculatorTests: XCTestCase {
  @MainActor
  func testIdealRemainingAtMidpoint() throws {
    let start = Date(timeIntervalSince1970: 1_000)
    let end = start.addingTimeInterval(300)
    let midpoint = start.addingTimeInterval(150)

    let value = try XCTUnwrap(
      PaceCalculator.idealRemaining(
        at: midpoint,
        windowStart: start,
        windowEnd: end
      )
    )
    XCTAssertEqual(value, 50, accuracy: 0.0001)
  }

  @MainActor
  func testDeltaIsPositiveWhenUnderPace() throws {
    let start = Date(timeIntervalSince1970: 1_000)
    let end = start.addingTimeInterval(300)
    let midpoint = start.addingTimeInterval(150)

    let value = try XCTUnwrap(
      PaceCalculator.delta(
        remainingPercent: 65,
        at: midpoint,
        windowStart: start,
        windowEnd: end
      )
    )
    XCTAssertEqual(value, 15, accuracy: 0.0001)
  }

  @MainActor
  func testUnknownTimelineProducesNoPace() {
    XCTAssertNil(
      PaceCalculator.delta(
        remainingPercent: 50,
        at: Date(),
        windowStart: nil,
        windowEnd: nil
      )
    )
  }

  @MainActor
  func testExhaustedQuotaHasNoFutureProjection() {
    XCTAssertNil(
      PaceCalculator.exhaustionPrediction(
        remainingPercent: 0,
        now: Date(),
        windowStart: Date().addingTimeInterval(-3_600)
      )
    )
  }

  @MainActor
  func testAverageBurnExtrapolatesWithBand() throws {
    let now = Date(timeIntervalSince1970: 10_000)
    // 60% used over 2h → 40% left lasts 80 min.
    let result = try XCTUnwrap(
      PaceCalculator.exhaustionPrediction(
        remainingPercent: 40,
        now: now,
        windowStart: now.addingTimeInterval(-7_200)
      ))
    XCTAssertTrue(result.hasRange)
    XCTAssertEqual(try XCTUnwrap(result.likely).timeIntervalSince(now), 4_800, accuracy: 1)
    XCTAssertEqual(try XCTUnwrap(result.earliest).timeIntervalSince(now), 3_840, accuracy: 1)
    XCTAssertEqual(try XCTUnwrap(result.latest).timeIntervalSince(now), 5_760, accuracy: 1)
  }

  @MainActor
  func testUnusedOrUnanchoredWindowHasNoPrediction() {
    let now = Date(timeIntervalSince1970: 10_000)
    XCTAssertNil(
      PaceCalculator.exhaustionPrediction(
        remainingPercent: 100, now: now, windowStart: now.addingTimeInterval(-7_200)))
    XCTAssertNil(
      PaceCalculator.exhaustionPrediction(remainingPercent: 40, now: now, windowStart: nil))
  }
}
