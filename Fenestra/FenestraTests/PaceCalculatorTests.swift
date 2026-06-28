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
      PaceCalculator.projectedExhaustion(
        remainingPercent: 0,
        now: Date(),
        recentHistory: []
      )
    )
  }

  @MainActor
  func testProjectedExhaustionUsesRecentBurnRate() throws {
    let now = Date(timeIntervalSince1970: 10_000)
    let first = HistoryPoint(
      providerID: .codex,
      poolID: "default",
      windowID: "weekly",
      timestamp: now.addingTimeInterval(-1_800),
      remainingPercent: 50,
      paceDelta: nil
    )
    let last = HistoryPoint(
      providerID: .codex,
      poolID: "default",
      windowID: "weekly",
      timestamp: now,
      remainingPercent: 40,
      paceDelta: nil
    )

    let result = try XCTUnwrap(
      PaceCalculator.projectedExhaustion(
        remainingPercent: 40,
        now: now,
        recentHistory: [first, last]
      ))

    XCTAssertEqual(
      result.timeIntervalSince(now),
      7_200,
      accuracy: 0.001
    )
  }
}
