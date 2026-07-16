import Foundation

struct ForecastValidation: Equatable, Sendable {
  let checkpointCount: Int
  let brierScore: Double
  let baselineBrierScore: Double
  let medianAbsoluteError: TimeInterval?
  let baselineMedianAbsoluteError: TimeInterval?
  let bandCoverage: Double

  var improvement: Double {
    let pattern = medianAbsoluteError ?? brierScore
    let baseline = baselineMedianAbsoluteError ?? baselineBrierScore
    guard baseline > 0 else { return 0 }
    return (baseline - pattern) / baseline
  }
}

enum PersonalizedForecaster {
  static func forecast(
    baseline: ExhaustionPrediction?,
    window: UsageWindowSnapshot,
    now: Date,
    histories: [HistoricalUsageWindow],
    returningPlanNeedsValidation: Bool = false,
    calendar: Calendar = .autoupdatingCurrent
  ) -> ExhaustionPrediction? {
    guard let baseline, baseline.hasRange,
      let start = window.windowStart, let reset = window.windowEnd, reset > start,
      histories.count >= 3
    else { return baseline }

    let comparable = histories.filter {
      $0.kind == window.kind && $0.observationCoverage >= 0.6 && $0.samples.count >= 2
    }
    guard comparable.count >= 3 else { return baseline }
    let outcomes = comparable.compactMap {
      replay(
        history: $0,
        currentRemaining: window.remainingPercent,
        currentStart: start,
        currentEnd: reset,
        now: now,
        calendar: calendar
      )
    }
    guard outcomes.count >= 3 else { return baseline }

    let probability = weightedProbability(outcomes)
    let exhaustionOutcomes = outcomes.filter { $0.exhaustion != nil }
    let validation = validate(comparable, calendar: calendar)
    let promoted = comparable.count >= 6
      && validation.checkpointCount >= 18
      && comparable.map(\.observationCoverage).reduce(0, +) / Double(comparable.count) >= 0.7
      && validation.improvement >= 0.1
      && validation.bandCoverage >= 0.45
    if comparable.count >= 6,
      validation.checkpointCount >= 18,
      validation.improvement < 0.1
    {
      return ExhaustionPrediction(
        earliest: baseline.earliest,
        likely: baseline.likely,
        latest: baseline.latest,
        confidence: baseline.confidence,
        method: .recent,
        exhaustionProbability: baseline.exhaustionProbability,
        evidenceCount: comparable.count,
        validationError: validation.medianAbsoluteError,
        notificationEligible: baseline.notificationEligible
      )
    }
    let earlyCap = returningPlanNeedsValidation ? 0.2 : 0.2
    let weight: Double
    if promoted {
      weight = min(0.65, max(0.2, validation.improvement))
    } else {
      weight = earlyCap
    }

    guard !exhaustionOutcomes.isEmpty,
      let patternEarliest = weightedDate(exhaustionOutcomes, percentile: 0.25),
      let patternLikely = weightedDate(exhaustionOutcomes, percentile: 0.5),
      let patternLatest = weightedDate(exhaustionOutcomes, percentile: 0.75),
      let baseEarliest = baseline.earliest,
      let baseLikely = baseline.likely,
      let baseLatest = baseline.latest
    else {
      return ExhaustionPrediction(
        earliest: baseline.earliest,
        likely: baseline.likely,
        latest: baseline.latest,
        confidence: baseline.confidence,
        method: .blended,
        exhaustionProbability: probability,
        evidenceCount: comparable.count,
        validationError: validation.medianAbsoluteError,
        notificationEligible: false
      )
    }

    let confidence: ExhaustionPredictionConfidence =
      promoted && comparable.count >= 8 ? .high : baseline.confidence
    return ExhaustionPrediction(
      earliest: blend(baseEarliest, patternEarliest, weight: weight),
      likely: blend(baseLikely, patternLikely, weight: weight),
      latest: blend(baseLatest, patternLatest, weight: weight),
      confidence: confidence,
      method: promoted ? .personalized : .blended,
      exhaustionProbability: probability,
      evidenceCount: comparable.count,
      validationError: validation.medianAbsoluteError,
      notificationEligible: promoted && !returningPlanNeedsValidation
        ? baseline.notificationEligible : false
    )
  }

  static func validate(
    _ histories: [HistoricalUsageWindow],
    calendar: Calendar = .autoupdatingCurrent
  ) -> ForecastValidation {
    let ordered = histories.sorted { $0.end < $1.end }
    var patternBrier: [Double] = []
    var baselineBrier: [Double] = []
    var patternErrors: [TimeInterval] = []
    var baselineErrors: [TimeInterval] = []
    var covered = 0
    var bands = 0

    for index in ordered.indices where index >= 3 {
      let target = ordered[index]
      let training = Array(ordered[..<index])
      for fraction in [0.25, 0.5, 0.75] {
        guard let checkpoint = target.start.addingTimeInterval(
          target.end.timeIntervalSince(target.start) * fraction
        ) as Date?,
          let remaining = interpolatedRemaining(in: target, at: checkpoint)
        else { continue }
        let actualExhaustion = target.exhaustedAt
        let actual = actualExhaustion == nil ? 0.0 : 1.0
        let outcomes = training.compactMap {
          replay(
            history: $0,
            currentRemaining: remaining,
            currentStart: target.start,
            currentEnd: target.end,
            now: checkpoint,
            calendar: calendar
          )
        }
        guard outcomes.count >= 3 else { continue }
        let probability = weightedProbability(outcomes)
        patternBrier.append(pow(probability - actual, 2))

        let prefix = target.samples.filter { $0.timestamp <= checkpoint }
        let baselineDate = netRateExhaustion(points: prefix, remaining: remaining, now: checkpoint)
        baselineBrier.append(pow((baselineDate.map { $0 < target.end ? 1 : 0 } ?? 0) - actual, 2))
        if let actualExhaustion {
          if let likely = weightedDate(outcomes.filter { $0.exhaustion != nil }, percentile: 0.5) {
            patternErrors.append(abs(likely.timeIntervalSince(actualExhaustion)))
          }
          if let baselineDate {
            baselineErrors.append(abs(baselineDate.timeIntervalSince(actualExhaustion)))
          }
          if let lower = weightedDate(outcomes.filter { $0.exhaustion != nil }, percentile: 0.25),
            let upper = weightedDate(outcomes.filter { $0.exhaustion != nil }, percentile: 0.75)
          {
            bands += 1
            if lower <= actualExhaustion && actualExhaustion <= upper { covered += 1 }
          }
        }
      }
    }
    return ForecastValidation(
      checkpointCount: patternBrier.count,
      brierScore: mean(patternBrier),
      baselineBrierScore: mean(baselineBrier),
      medianAbsoluteError: median(patternErrors),
      baselineMedianAbsoluteError: median(baselineErrors),
      bandCoverage: bands == 0 ? 0 : Double(covered) / Double(bands)
    )
  }

  private struct Outcome {
    let exhaustion: Date?
    let weight: Double
  }

  private static func replay(
    history: HistoricalUsageWindow,
    currentRemaining: Double,
    currentStart: Date,
    currentEnd: Date,
    now: Date,
    calendar: Calendar
  ) -> Outcome? {
    let duration = currentEnd.timeIntervalSince(currentStart)
    let historicalDuration = history.end.timeIntervalSince(history.start)
    guard duration > 0, historicalDuration > 0 else { return nil }
    let progress = min(1, max(0, now.timeIntervalSince(currentStart) / duration))
    let historicalCheckpoint = history.start.addingTimeInterval(historicalDuration * progress)
    guard interpolatedRemaining(in: history, at: historicalCheckpoint) != nil else { return nil }

    let burns = fifteenMinuteBurnBuckets(history)
    guard !burns.isEmpty else { return nil }
    let firstBucket = min(burns.count - 1, max(0, Int((historicalCheckpoint.timeIntervalSince(history.start) / 900).rounded(.down))))
    var cumulative = 0.0
    var exhaustion: Date?
    for index in firstBucket..<burns.count {
      let burn = burns[index]
      cumulative += burn
      guard cumulative >= currentRemaining else { continue }
      let fraction = burn > 0 ? (currentRemaining - (cumulative - burn)) / burn : 1
      let historicalDate = history.start.addingTimeInterval((Double(index) + fraction) * 900)
      let normalized = historicalDate.timeIntervalSince(history.start) / historicalDuration
      exhaustion = currentStart.addingTimeInterval(duration * normalized)
      break
    }

    let ageDays = max(0, now.timeIntervalSince(history.end) / 86_400)
    let recency = exp(-ageDays / 60)
    let weekday = calendar.component(.weekday, from: currentStart)
      == calendar.component(.weekday, from: history.start) ? 1.0 : 0.65
    let startHourDelta = abs(
      calendar.component(.hour, from: currentStart) - calendar.component(.hour, from: history.start)
    )
    let startSimilarity: Double
    if history.kind == .weekly {
      let currentHour = (calendar.component(.weekday, from: now) - 1) * 24
        + calendar.component(.hour, from: now)
      let historicalHour = (calendar.component(.weekday, from: historicalCheckpoint) - 1) * 24
        + calendar.component(.hour, from: historicalCheckpoint)
      let distance = min(abs(currentHour - historicalHour), 168 - abs(currentHour - historicalHour))
      startSimilarity = max(0.35, 1 - Double(distance) / 48)
    } else {
      startSimilarity = max(0.35, 1 - Double(min(startHourDelta, 12)) / 18)
    }
    return Outcome(
      exhaustion: exhaustion,
      weight: recency * weekday * startSimilarity * history.observationCoverage
    )
  }

  private static func fifteenMinuteBurnBuckets(
    _ history: HistoricalUsageWindow
  ) -> [Double] {
    let duration = history.end.timeIntervalSince(history.start)
    guard duration > 0 else { return [] }
    var buckets = Array(repeating: 0.0, count: max(1, Int(ceil(duration / 900))))
    let samples = history.samples.sorted { $0.timestamp < $1.timestamp }
    for (first, second) in zip(samples, samples.dropFirst()) {
      let elapsed = second.timestamp.timeIntervalSince(first.timestamp)
      let burn = first.remainingPercent - second.remainingPercent
      guard elapsed > 0, elapsed <= 45 * 60, burn > 0 else { continue }
      let intervalStart = max(first.timestamp, history.start)
      let intervalEnd = min(second.timestamp, history.end)
      guard intervalEnd > intervalStart else { continue }
      let firstIndex = max(0, Int(intervalStart.timeIntervalSince(history.start) / 900))
      let lastIndex = min(buckets.count - 1, Int(intervalEnd.timeIntervalSince(history.start) / 900))
      for index in firstIndex...lastIndex {
        let bucketStart = history.start.addingTimeInterval(Double(index) * 900)
        let bucketEnd = bucketStart.addingTimeInterval(900)
        let overlap = max(0, min(intervalEnd, bucketEnd).timeIntervalSince(max(intervalStart, bucketStart)))
        buckets[index] += burn * overlap / elapsed
      }
    }
    return buckets
  }

  private static func interpolatedRemaining(
    in window: HistoricalUsageWindow,
    at date: Date
  ) -> Double? {
    guard let first = window.samples.first, let last = window.samples.last,
      date >= first.timestamp, date <= last.timestamp
    else { return nil }
    if let exact = window.samples.first(where: { $0.timestamp == date }) {
      return exact.remainingPercent
    }
    guard let upperIndex = window.samples.firstIndex(where: { $0.timestamp > date }), upperIndex > 0 else {
      return nil
    }
    let lower = window.samples[upperIndex - 1]
    let upper = window.samples[upperIndex]
    let span = upper.timestamp.timeIntervalSince(lower.timestamp)
    guard span > 0, span <= 45 * 60 else { return nil }
    let fraction = date.timeIntervalSince(lower.timestamp) / span
    return lower.remainingPercent + (upper.remainingPercent - lower.remainingPercent) * fraction
  }

  private static func weightedProbability(_ outcomes: [Outcome]) -> Double {
    let total = outcomes.reduce(0) { $0 + $1.weight }
    guard total > 0 else { return 0 }
    return outcomes.reduce(0) { $0 + ($1.exhaustion == nil ? 0 : $1.weight) } / total
  }

  private static func weightedDate(_ outcomes: [Outcome], percentile: Double) -> Date? {
    let dated = outcomes.compactMap { outcome in
      outcome.exhaustion.map { ($0, outcome.weight) }
    }.sorted { $0.0 < $1.0 }
    let total = dated.reduce(0) { $0 + $1.1 }
    guard total > 0 else { return nil }
    let target = total * percentile
    var cumulative = 0.0
    for value in dated {
      cumulative += value.1
      if cumulative >= target { return value.0 }
    }
    return dated.last?.0
  }

  private static func blend(_ baseline: Date, _ pattern: Date, weight: Double) -> Date {
    Date(
      timeIntervalSince1970:
        baseline.timeIntervalSince1970 * (1 - weight) + pattern.timeIntervalSince1970 * weight
    )
  }

  private static func netRateExhaustion(
    points: [HistoryPoint],
    remaining: Double,
    now: Date
  ) -> Date? {
    guard let first = points.first, let last = points.last else { return nil }
    let elapsed = last.timestamp.timeIntervalSince(first.timestamp)
    let consumed = first.remainingPercent - last.remainingPercent
    guard elapsed >= 600, consumed >= 0.5 else { return nil }
    return now.addingTimeInterval(remaining / (consumed / elapsed))
  }

  private static func mean(_ values: [Double]) -> Double {
    values.isEmpty ? 1 : values.reduce(0, +) / Double(values.count)
  }

  private static func median(_ values: [TimeInterval]) -> TimeInterval? {
    guard !values.isEmpty else { return nil }
    let sorted = values.sorted()
    return sorted[sorted.count / 2]
  }
}
