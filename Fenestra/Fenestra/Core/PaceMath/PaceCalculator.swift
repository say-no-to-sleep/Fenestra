import Foundation

enum PaceCalculator {
  static func idealRemaining(
    at date: Date,
    windowStart: Date?,
    windowEnd: Date?
  ) -> Double? {
    guard let windowStart, let windowEnd, windowEnd > windowStart else { return nil }
    let duration = windowEnd.timeIntervalSince(windowStart)
    let elapsed = date.timeIntervalSince(windowStart)
    let progress = min(1, max(0, elapsed / duration))
    return 100 * (1 - progress)
  }

  static func delta(
    remainingPercent: Double,
    at date: Date,
    windowStart: Date?,
    windowEnd: Date?
  ) -> Double? {
    guard let ideal = idealRemaining(at: date, windowStart: windowStart, windowEnd: windowEnd)
    else {
      return nil
    }
    return remainingPercent - ideal
  }

  static func evaluate(window: UsageWindowSnapshot, at date: Date) -> PaceEvaluation? {
    guard
      let ideal = idealRemaining(
        at: date,
        windowStart: window.windowStart,
        windowEnd: window.windowEnd
      )
    else {
      return nil
    }

    return PaceEvaluation(
      idealRemaining: ideal,
      delta: window.remainingPercent - ideal,
      exhaustionPrediction: exhaustionPrediction(
        remainingPercent: window.remainingPercent,
        now: date,
        windowStart: window.windowStart
      )
    )
  }

  // ponytail: straight-line extrapolation of the average burn since the window opened,
  // ±20% band. Replaced a rolling-rate + personalized forecaster that blanked out whenever
  // usage paused and cost a history scan per render. Upgrade: blend in a recent rate.
  static func exhaustionPrediction(
    remainingPercent: Double,
    now: Date,
    windowStart: Date?
  ) -> ExhaustionPrediction? {
    guard remainingPercent > 0, let windowStart else { return nil }
    let elapsed = now.timeIntervalSince(windowStart)
    let used = 100 - remainingPercent
    guard elapsed >= 10 * 60, used >= 0.5 else { return nil }
    let timeLeft = remainingPercent / (used / elapsed)
    return ExhaustionPrediction(
      earliest: now.addingTimeInterval(timeLeft * 0.8),
      likely: now.addingTimeInterval(timeLeft),
      latest: now.addingTimeInterval(timeLeft * 1.2),
      confidence: .medium
    )
  }
}
