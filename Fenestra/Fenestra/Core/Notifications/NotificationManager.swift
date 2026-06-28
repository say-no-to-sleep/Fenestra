import Foundation
import UserNotifications

@MainActor
final class NotificationManager {
  private var badPaceCounts: [String: Int] = [:]
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
        let recent = history.recentPoints(
          providerID: snapshot.providerID,
          poolID: pool.id,
          windowID: window.id,
          now: snapshot.freshness
        )
        let evaluation = PaceCalculator.evaluate(
          window: window,
          at: snapshot.freshness,
          recentHistory: recent
        )
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
    guard let exhaustion = evaluation?.projectedExhaustion,
      let reset = window.windowEnd,
      exhaustion < reset
    else {
      deliveredConditions.remove(conditionKey)
      return
    }
    guard !deliveredConditions.contains(conditionKey) else { return }

    let content = UNMutableNotificationContent()
    content.title = "\(providerName) may run out"
    let time = exhaustion.formatted(date: .omitted, time: .shortened)
    content.body =
      poolName == "Default"
      ? "Projected \(time), before reset"
      : "\(poolName): projected \(time), before reset"
    content.sound = .default
    content.interruptionLevel = timeSensitiveAllowed ? .timeSensitive : .active
    if await add(content, identifier: conditionKey, center: center) {
      deliveredConditions.insert(conditionKey)
    }
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
