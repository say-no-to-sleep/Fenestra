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

  static func evaluate(
    window: UsageWindowSnapshot,
    at date: Date,
    recentHistory: [HistoryPoint]
  ) -> PaceEvaluation? {
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
      projectedExhaustion: projectedExhaustion(
        remainingPercent: window.remainingPercent,
        now: date,
        recentHistory: recentHistory
      )
    )
  }

  static func projectedExhaustion(
    remainingPercent: Double,
    now: Date,
    recentHistory: [HistoryPoint],
    lookback: TimeInterval = 60 * 60
  ) -> Date? {
    guard remainingPercent > 0 else { return nil }
    let cutoff = now.addingTimeInterval(-lookback)
    let samples =
      recentHistory
      .filter { $0.timestamp >= cutoff && $0.timestamp <= now }
      .sorted { $0.timestamp < $1.timestamp }
    guard let first = samples.first, let last = samples.last, last.timestamp > first.timestamp
    else {
      return nil
    }
    let consumed = first.remainingPercent - last.remainingPercent
    guard consumed > 0.05 else { return nil }
    let ratePerSecond = consumed / last.timestamp.timeIntervalSince(first.timestamp)
    guard ratePerSecond.isFinite, ratePerSecond > 0 else { return nil }
    return now.addingTimeInterval(remainingPercent / ratePerSecond)
  }
}
