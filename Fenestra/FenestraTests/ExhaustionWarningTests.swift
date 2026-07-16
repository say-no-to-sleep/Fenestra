import XCTest

@testable import Fenestra

final class ExhaustionWarningTests: XCTestCase {
  @MainActor
  func testPossibleWarningRequiresTwoRefreshes() {
    var gate = ExhaustionWarningGate()
    XCTAssertFalse(gate.shouldDeliver(key: "codex", kind: .possible))
    XCTAssertTrue(gate.shouldDeliver(key: "codex", kind: .possible))
  }

  @MainActor
  func testLikelyWarningIsImmediate() {
    var gate = ExhaustionWarningGate()
    XCTAssertTrue(gate.shouldDeliver(key: "codex", kind: .likely))
  }

  @MainActor
  func testClearingConditionResetsPossibleCount() {
    var gate = ExhaustionWarningGate()
    XCTAssertFalse(gate.shouldDeliver(key: "codex", kind: .possible))
    XCTAssertFalse(gate.shouldDeliver(key: "codex", kind: .none))
    XCTAssertFalse(gate.shouldDeliver(key: "codex", kind: .possible))
  }

  @MainActor
  func testPredictionClassificationStraddlesReset() {
    let now = Date(timeIntervalSince1970: 10_000)
    let prediction = ExhaustionPrediction(
      earliest: now.addingTimeInterval(600),
      likely: now.addingTimeInterval(1_800),
      latest: now.addingTimeInterval(3_600),
      confidence: .medium
    )
    XCTAssertEqual(
      ExhaustionAlertKind.classify(
        prediction: prediction,
        reset: now.addingTimeInterval(1_200)
      ),
      .possible
    )
    XCTAssertEqual(
      ExhaustionAlertKind.classify(
        prediction: prediction,
        reset: now.addingTimeInterval(2_400)
      ),
      .likely
    )
  }
}
