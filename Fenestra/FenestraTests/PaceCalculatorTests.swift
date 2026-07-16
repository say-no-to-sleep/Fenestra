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
        recentHistory: []
      )
    )
  }

  @MainActor
  func testSteadyBurnProducesHighConfidenceRange() throws {
    let now = Date(timeIntervalSince1970: 10_000)
    let result = try XCTUnwrap(
      PaceCalculator.exhaustionPrediction(
        remainingPercent: 40,
        now: now,
        recentHistory: points(
          now: now,
          samples: [(-120, 60), (-60, 50), (-30, 45), (-15, 42.5), (0, 40)]
        )
      ))
    XCTAssertEqual(result.confidence, .high)
    XCTAssertEqual(try XCTUnwrap(result.earliest).timeIntervalSince(now), 14_400, accuracy: 1)
    XCTAssertEqual(result.earliest, result.likely)
    XCTAssertEqual(result.likely, result.latest)
  }

  @MainActor
  func testFlatUsageProducesNoPrediction() {
    let now = Date(timeIntervalSince1970: 10_000)
    XCTAssertNil(
      PaceCalculator.exhaustionPrediction(
        remainingPercent: 40,
        now: now,
        recentHistory: points(now: now, samples: [(-120, 40), (-60, 40), (0, 40)])
      ))
  }

  @MainActor
  func testSparseUsageProducesUnstablePrediction() throws {
    let now = Date(timeIntervalSince1970: 10_000)
    let result = try XCTUnwrap(
      PaceCalculator.exhaustionPrediction(
        remainingPercent: 40,
        now: now,
        recentHistory: points(now: now, samples: [(-15, 45), (0, 40)])
      ))
    XCTAssertEqual(result.confidence, .unstable)
    XCTAssertFalse(result.hasRange)
  }

  @MainActor
  func testUpwardCorrectionDiscardsEarlierSamples() throws {
    let now = Date(timeIntervalSince1970: 10_000)
    let result = try XCTUnwrap(
      PaceCalculator.exhaustionPrediction(
        remainingPercent: 80,
        now: now,
        recentHistory: points(
          now: now,
          samples: [(-120, 80), (-90, 70), (-60, 90), (-30, 85), (-15, 82.5), (0, 80)]
        )
      ))
    XCTAssertTrue(result.hasRange)
    XCTAssertEqual(try XCTUnwrap(result.likely).timeIntervalSince(now), 28_800, accuracy: 1)
  }

  @MainActor
  func testInconsistentHorizonsAreUnstable() throws {
    let now = Date(timeIntervalSince1970: 10_000)
    let result = try XCTUnwrap(
      PaceCalculator.exhaustionPrediction(
        remainingPercent: 40,
        now: now,
        recentHistory: points(
          now: now,
          samples: [(-120, 58), (-60, 56), (-30, 55), (-15, 42.5), (0, 40)]
        )
      ))
    XCTAssertEqual(result.confidence, .unstable)
    XCTAssertFalse(result.hasRange)
  }

  @MainActor
  private func points(
    now: Date,
    samples: [(minutes: Double, remaining: Double)]
  ) -> [HistoryPoint] {
    samples.map { sample in
      HistoryPoint(
        providerID: .codex,
        poolID: "default",
        windowID: "weekly",
        timestamp: now.addingTimeInterval(sample.minutes * 60),
        remainingPercent: sample.remaining,
        paceDelta: nil
      )
    }
  }
}
