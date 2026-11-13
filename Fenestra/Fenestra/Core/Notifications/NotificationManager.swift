import Foundation
import UserNotifications

enum ExhaustionAlertKind: Equatable {
  case none
  case possible
  case likely

  static func classify(prediction: ExhaustionPrediction?, reset: Date?) -> Self {
    guard let prediction, prediction.hasRange,
      let earliest = prediction.earliest,
      let likely = prediction.likely,
      let reset,
      earliest < reset
    else { return .none }
    return likely < reset ? .likely : .possible
  }
}

struct ExhaustionWarningGate {
  private var counts: [String: Int] = [:]

  mutating func shouldDeliver(key: String, kind: ExhaustionAlertKind) -> Bool {
    switch kind {
    case .none:
      counts[key] = 0
      return false
    case .likely:
      counts[key] = 0
      return true
    case .possible:
      counts[key, default: 0] += 1
      return counts[key, default: 0] >= 2
    }
  }
}

@MainActor
final class NotificationManager {
  private var badPaceCounts: [String: Int] = [:]
  private var exhaustionWarningGate = ExhaustionWarningGate()
  private var deliveredConditions: Set<String> = []

  func requestAuthorizationIfNeeded() async {
    let center = UNUserNotificationCenter.current()
    let settings = await center.notificationSettings()
    guard settings.authorizationStatus == .notDetermined else { return }
    do {
      _ = try await center.requestAuthorization(options: [.alert, .sound])
    } catch {
      LocalLog.record("Notification authorization failed: \(error.localizedDescription)")
    }
  }

  func evaluate(
    snapshot: UsageSnapshot,
    history: HistoryStore,
    settings: AppSettings
  ) async {
    guard settings.notificationsEnabled else { return }
    let center = UNUserNotificationCenter.current()
    let notificationSettings = await center.notificationSettings()
    guard
      notificationSettings.authorizationStatus == .authorized
        || notificationSettings.authorizationStatus == .provisional
    else {
      return
    }

    for pool in snapshot.pools {
      for window in pool.windows {
        let key = "\(snapshot.providerID.rawValue).\(pool.id).\(window.id)"
        let evaluation = PaceCalculator.evaluate(window: window, at: snapshot.freshness)
        if let evaluation {
          await evaluateBadPace(
            key: key,
            providerName: snapshot.displayName,
            poolName: pool.name,
            evaluation: evaluation,
            threshold: settings.badPaceThreshold,
            center: center
          )
        } else {
          badPaceCounts[key] = 0
        }

        await evaluateExhaustion(
          key: key,
          providerName: snapshot.displayName,
          poolName: pool.name,
          window: window,
          evaluation: evaluation,
          timeSensitiveAllowed: notificationSettings.timeSensitiveSetting == .enabled,
          center: center
        )
      }
    }
    if settings.anomalyNotificationsEnabled {
      await evaluateAnomalies(
        history.activeAnomalies.filter { $0.providerID == snapshot.providerID },
        center: center
      )
    }
  }

  private func evaluateAnomalies(
    _ anomalies: [UsageAnomaly],
    center: UNUserNotificationCenter
  ) async {
    let activeKeys = Set(anomalies.map { "anomaly.\($0.id.uuidString)" })
    deliveredConditions = deliveredConditions.filter {
      !$0.hasPrefix("anomaly.") || activeKeys.contains($0)
    }
    for anomaly in anomalies where anomaly.alertable && anomaly.confirmedAt != nil {
      let key = "anomaly.\(anomaly.id.uuidString)"
      guard !deliveredConditions.contains(key) else { continue }
      let content = UNMutableNotificationContent()
      content.title = "\(anomaly.providerID.displayName): \(anomaly.kind.title)"
      content.body = anomaly.detail
      content.sound = .default
      content.interruptionLevel = .active
      if await add(content, identifier: key, center: center) {
        deliveredConditions.insert(key)
      }
    }
  }

  private func evaluateBadPace(
    key: String,
    providerName: String,
    poolName: String,
    evaluation: PaceEvaluation,
    threshold: Double,
    center: UNUserNotificationCenter
  ) async {
    let conditionKey = "pace.\(key)"
    guard evaluation.delta < threshold else {
      badPaceCounts[key] = 0
      deliveredConditions.remove(conditionKey)
      return
    }
    badPaceCounts[key, default: 0] += 1
    guard badPaceCounts[key, default: 0] >= 2,
      !deliveredConditions.contains(conditionKey)
    else {
      return
    }

    let content = UNMutableNotificationContent()
    content.title = "\(providerName) pace"
    content.body =
      poolName == "Default"
      ? evaluation.label
      : "\(poolName): \(evaluation.label)"
    content.sound = .default
    content.interruptionLevel = .active
    if await add(content, identifier: conditionKey, center: center) {
      deliveredConditions.insert(conditionKey)
    }
  }

  private func evaluateExhaustion(
    key: String,
    providerName: String,
    poolName: String,
    window: UsageWindowSnapshot,
    evaluation: PaceEvaluation?,
    timeSensitiveAllowed: Bool,
    center: UNUserNotificationCenter
  ) async {
    let conditionKey = "exhaustion.\(key)"
    let exhaustedKey = "exhausted.\(key)"
    if window.remainingPercent <= 0 {
      deliveredConditions.remove(conditionKey)
      guard !deliveredConditions.contains(exhaustedKey) else { return }

      let content = UNMutableNotificationContent()
      content.title = "\(providerName) quota exhausted"
      let status = window.windowEnd == nil ? "Quota exhausted" : "Quota exhausted before reset"
      content.body = poolName == "Default" ? status : "\(poolName): \(status.lowercased())"
      content.sound = .default
      content.interruptionLevel = timeSensitiveAllowed ? .timeSensitive : .active
      if await add(content, identifier: exhaustedKey, center: center) {
        deliveredConditions.insert(exhaustedKey)
      }
      return
    }

    deliveredConditions.remove(exhaustedKey)
    guard let prediction = evaluation?.exhaustionPrediction,
      prediction.notificationEligible,
      prediction.hasRange,
      let earliest = prediction.earliest,
      let latest = prediction.latest,
      let reset = window.windowEnd
    else {
      _ = exhaustionWarningGate.shouldDeliver(key: key, kind: .none)
      deliveredConditions.remove(conditionKey)
      return
    }
    let kind = ExhaustionAlertKind.classify(prediction: prediction, reset: reset)
    guard kind != .none else {
      _ = exhaustionWarningGate.shouldDeliver(key: key, kind: .none)
      deliveredConditions.remove(conditionKey)
      return
    }
    guard exhaustionWarningGate.shouldDeliver(key: key, kind: kind) else { return }
    let likelyBeforeReset = kind == .likely
    guard !deliveredConditions.contains(conditionKey) else { return }

    let content = UNMutableNotificationContent()
    content.title = likelyBeforeReset
      ? "\(providerName) likely to run out"
      : "\(providerName) may run out"
    let range = Self.predictionRange(earliest: earliest, latest: latest)
    content.body =
      poolName == "Default"
      ? "Projected \(range), before reset"
      : "\(poolName): projected \(range), before reset"
    content.sound = .default
    content.interruptionLevel =
      likelyBeforeReset && timeSensitiveAllowed ? .timeSensitive : .active
    if await add(content, identifier: conditionKey, center: center) {
      deliveredConditions.insert(conditionKey)
    }
  }

  private static func predictionRange(earliest: Date, latest: Date) -> String {
    let calendar = Calendar.autoupdatingCurrent
    let first = earliest.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    let last = calendar.isDate(earliest, inSameDayAs: latest)
      ? latest.formatted(date: .omitted, time: .shortened)
      : latest.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    return "\(first)–\(last)"
  }

  private func add(
    _ content: UNNotificationContent,
    identifier: String,
    center: UNUserNotificationCenter
  ) async -> Bool {
    do {
      try await center.add(
        UNNotificationRequest(
          identifier: identifier,
          content: content,
          trigger: nil
        ))
      return true
    } catch {
      guard content.interruptionLevel == .timeSensitive,
        let fallback = content.mutableCopy() as? UNMutableNotificationContent
      else {
        LocalLog.record("Notification delivery failed: \(error.localizedDescription)")
        return false
      }
      fallback.interruptionLevel = .active
      do {
        try await center.add(
          UNNotificationRequest(
            identifier: identifier,
            content: fallback,
            trigger: nil
          ))
        return true
      } catch {
        LocalLog.record("Notification delivery failed: \(error.localizedDescription)")
        return false
      }
    }
  }
}
