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
      exhaustionPrediction: exhaustionPrediction(
        remainingPercent: window.remainingPercent,
        now: date,
        recentHistory: recentHistory
      )
    )
  }

  static func exhaustionPrediction(
    remainingPercent: Double,
    now: Date,
    recentHistory: [HistoryPoint]
  ) -> ExhaustionPrediction? {
    guard remainingPercent > 0 else { return nil }

    var samples = recentHistory
      .filter { $0.timestamp >= now.addingTimeInterval(-2 * 60 * 60) && $0.timestamp <= now }
      .sorted { $0.timestamp < $1.timestamp }
    if samples.last?.timestamp != now {
      samples.append(
        HistoryPoint(
          providerID: samples.last?.providerID ?? .codex,
          poolID: samples.last?.poolID ?? "prediction",
          windowID: samples.last?.windowID ?? "prediction",
          timestamp: now,
          remainingPercent: remainingPercent,
          paceDelta: nil
        ))
    }

    if let correction = samples.indices.dropFirst().last(where: { index in
      samples[index].remainingPercent - samples[index - 1].remainingPercent > 2
    }) {
      samples = Array(samples[correction...])
    }

    let horizons: [(seconds: TimeInterval, weight: Double)] = [
      (15 * 60, 4),
      (30 * 60, 3),
      (60 * 60, 2),
      (120 * 60, 1),
    ]
    let rates = horizons.compactMap { horizon -> WeightedRate? in
      guard let first = samples.first(where: {
        $0.timestamp >= now.addingTimeInterval(-horizon.seconds)
      }), let last = samples.last
      else { return nil }
      let elapsed = last.timestamp.timeIntervalSince(first.timestamp)
      let consumed = first.remainingPercent - last.remainingPercent
      guard elapsed >= max(10 * 60, horizon.seconds * 0.8), consumed >= 0.5 else {
        return nil
      }
      let rate = consumed / elapsed
      guard rate.isFinite, rate > 0 else { return nil }
      return WeightedRate(rate: rate, weight: horizon.weight, span: elapsed)
    }

    guard rates.count >= 2 else {
      return rates.isEmpty
        ? nil
        : ExhaustionPrediction(
          earliest: nil,
          likely: nil,
          latest: nil,
          confidence: .unstable
        )
    }

    let slower = weightedQuantile(rates, percentile: 0.25)
    let likely = weightedQuantile(rates, percentile: 0.5)
    let faster = weightedQuantile(rates, percentile: 0.75)
    guard slower > 0, likely > 0, faster > 0 else { return nil }
    let dispersion = (faster - slower) / likely
    let confidence: ExhaustionPredictionConfidence
    if rates.count >= 3, rates.map(\.span).max() ?? 0 >= 60 * 60, dispersion <= 0.5 {
      confidence = .high
    } else if dispersion <= 1 {
      confidence = .medium
    } else {
      return ExhaustionPrediction(
        earliest: nil,
        likely: nil,
        latest: nil,
        confidence: .unstable
      )
    }

    return ExhaustionPrediction(
      earliest: now.addingTimeInterval(remainingPercent / faster),
      likely: now.addingTimeInterval(remainingPercent / likely),
      latest: now.addingTimeInterval(remainingPercent / slower),
      confidence: confidence
    )
  }

  private struct WeightedRate {
    let rate: Double
    let weight: Double
    let span: TimeInterval
  }

  private static func weightedQuantile(
    _ values: [WeightedRate],
    percentile: Double
  ) -> Double {
    let sorted = values.sorted { $0.rate < $1.rate }
    let target = sorted.reduce(0) { $0 + $1.weight } * percentile
    var cumulative = 0.0
    for value in sorted {
      cumulative += value.weight
      if cumulative >= target { return value.rate }
    }
    return sorted.last?.rate ?? 0
  }
}
