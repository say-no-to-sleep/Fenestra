import Foundation

struct AnomalyDetector {
  private var previousSnapshots: [ProviderID: UsageSnapshot] = [:]
  private var confirmations: [String: Int] = [:]
  private var activeByKey: [String: UsageAnomaly] = [:]
  private var resolvedChanges: [UsageAnomaly] = []

  mutating func evaluate(
    snapshot: UsageSnapshot,
    history: [HistoryPoint],
    refreshCadence: TimeInterval
  ) -> [UsageAnomaly] {
    var seen: Set<String> = []
    resolve(
      key: "\(snapshot.providerID.rawValue)|\(UsageAnomalyKind.repeatedRefreshFailure.rawValue)",
      at: snapshot.freshness
    )
    let previous = previousSnapshots[snapshot.providerID]
    for pool in snapshot.pools {
      for window in pool.windows {
        let seriesKey = HistoryDatabase.seriesKey(
          providerID: snapshot.providerID,
          poolID: pool.id,
          windowID: window.id
        )
        let oldWindow = previous?.pools.first(where: { $0.id == pool.id })?
          .windows.first(where: { $0.id == window.id })

        if let oldWindow, window.remainingPercent - oldWindow.remainingPercent > 2 {
          let key = "\(seriesKey)|\(UsageAnomalyKind.upwardCorrection.rawValue)"
          seen.insert(key)
          confirm(
            key: key,
            providerID: snapshot.providerID,
            seriesKey: seriesKey,
            kind: .upwardCorrection,
            at: snapshot.freshness,
            detail: "Remaining quota increased by \((window.remainingPercent - oldWindow.remainingPercent).formatted(.number.precision(.fractionLength(1)))) points.",
            alertable: false,
            requiredConfirmations: 1
          )
        }

        if let oldWindow, let previous,
          snapshot.freshness > previous.freshness,
          oldWindow.remainingPercent > window.remainingPercent
        {
          let elapsed = snapshot.freshness.timeIntervalSince(previous.freshness)
          let rate = (oldWindow.remainingPercent - window.remainingPercent) / elapsed * 3_600
          let historicalRates = burnRates(
            history.filter {
              $0.providerID == snapshot.providerID && $0.poolID == pool.id && $0.windowID == window.id
            }
          )
          if historicalRates.count >= 8 {
            let sorted = historicalRates.sorted()
            let percentile95 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
            let median = sorted[sorted.count / 2]
            let deviations = sorted.map { abs($0 - median) }.sorted()
            let mad = deviations[deviations.count / 2]
            if rate > percentile95 && rate > median + 3 * mad {
              let key = "\(seriesKey)|\(UsageAnomalyKind.unusualBurn.rawValue)"
              seen.insert(key)
              confirm(
                key: key,
                providerID: snapshot.providerID,
                seriesKey: seriesKey,
                kind: .unusualBurn,
                at: snapshot.freshness,
                detail: "Usage is burning at \(rate.formatted(.number.precision(.fractionLength(1)))) points per hour.",
                alertable: true,
                requiredConfirmations: 2
              )
            }
          }
        }

        if let oldEnd = oldWindow?.windowEnd,
          snapshot.freshness.timeIntervalSince(oldEnd) > max(600, 2 * refreshCadence),
          window.windowEnd == oldEnd
        {
          let key = "\(seriesKey)|\(UsageAnomalyKind.overdueReset.rawValue)"
          seen.insert(key)
          confirm(
            key: key,
            providerID: snapshot.providerID,
            seriesKey: seriesKey,
            kind: .overdueReset,
            at: snapshot.freshness,
            detail: "The provider still reports the old reset window.",
            alertable: true,
            requiredConfirmations: 2
          )
        }
      }
    }
    previousSnapshots[snapshot.providerID] = snapshot
    resolveMissing(providerID: snapshot.providerID, seen: seen, at: snapshot.freshness)
    return results()
  }

  mutating func recordFailure(
    providerID: ProviderID,
    at date: Date,
    staleDuration: TimeInterval
  ) -> [UsageAnomaly] {
    let key = "\(providerID.rawValue)|\(UsageAnomalyKind.repeatedRefreshFailure.rawValue)"
    confirm(
      key: key,
      providerID: providerID,
      seriesKey: nil,
      kind: .repeatedRefreshFailure,
      at: date,
      detail: staleDuration > 0
        ? "Usage data has been stale for \(Duration.seconds(staleDuration).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated)))."
        : "Multiple provider refreshes have failed.",
      alertable: true,
      requiredConfirmations: 2
    )
    return results()
  }

  private mutating func confirm(
    key: String,
    providerID: ProviderID,
    seriesKey: String?,
    kind: UsageAnomalyKind,
    at date: Date,
    detail: String,
    alertable: Bool,
    requiredConfirmations: Int
  ) {
    confirmations[key, default: 0] += 1
    guard confirmations[key, default: 0] >= requiredConfirmations else { return }
    if var existing = activeByKey[key] {
      if existing.confirmedAt == nil { existing.confirmedAt = date }
      activeByKey[key] = existing
    } else {
      activeByKey[key] = UsageAnomaly(
        id: UUID(),
        providerID: providerID,
        seriesKey: seriesKey,
        kind: kind,
        detectedAt: date,
        confirmedAt: requiredConfirmations == 1 ? date : date,
        resolvedAt: nil,
        detail: detail,
        alertable: alertable
      )
    }
  }

  private mutating func resolveMissing(providerID: ProviderID, seen: Set<String>, at date: Date) {
    let keys = activeByKey.compactMap { key, anomaly in
      anomaly.providerID == providerID && anomaly.kind != .repeatedRefreshFailure && !seen.contains(key)
        ? key : nil
    }
    for key in keys {
      resolve(key: key, at: date)
    }
  }

  private mutating func resolve(key: String, at date: Date) {
    guard var anomaly = activeByKey.removeValue(forKey: key) else {
      confirmations[key] = 0
      return
    }
    anomaly.resolvedAt = date
    resolvedChanges.append(anomaly)
    confirmations[key] = 0
  }

  private mutating func results() -> [UsageAnomaly] {
    defer { resolvedChanges = [] }
    return Array(activeByKey.values) + resolvedChanges
  }

  private func burnRates(_ points: [HistoryPoint]) -> [Double] {
    let sorted = points.sorted { $0.timestamp < $1.timestamp }
    return zip(sorted, sorted.dropFirst()).compactMap { first, second in
      let elapsed = second.timestamp.timeIntervalSince(first.timestamp)
      let burn = first.remainingPercent - second.remainingPercent
      guard elapsed >= 60, elapsed <= 45 * 60, burn > 0 else { return nil }
      return burn / elapsed * 3_600
    }
  }
}
