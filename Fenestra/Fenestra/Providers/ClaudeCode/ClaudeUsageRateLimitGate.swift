import Foundation

struct ClaudeUsageRateLimitGate {
  static let defaultCooldown: TimeInterval = 5 * 60

  private let defaults: UserDefaults
  private let blockedUntilKey: String

  init(
    defaults: UserDefaults = .standard,
    blockedUntilKey: String = "providers.claude.oauthUsageBlockedUntil"
  ) {
    self.defaults = defaults
    self.blockedUntilKey = blockedUntilKey
  }

  func blockedUntil(now: Date = Date()) -> Date? {
    guard let timestamp = defaults.object(forKey: blockedUntilKey) as? Double else {
      return nil
    }
    let date = Date(timeIntervalSince1970: timestamp)
    guard date > now else {
      defaults.removeObject(forKey: blockedUntilKey)
      return nil
    }
    return date
  }

  @discardableResult
  func recordRateLimit(retryAfter: Date?, now: Date = Date()) -> Date {
    let blockedUntil =
      if let retryAfter, retryAfter > now {
        retryAfter
      } else {
        now.addingTimeInterval(Self.defaultCooldown)
      }
    defaults.set(blockedUntil.timeIntervalSince1970, forKey: blockedUntilKey)
    return blockedUntil
  }

  func recordSuccess() {
    defaults.removeObject(forKey: blockedUntilKey)
  }

  func allowManualRetry() {
    defaults.removeObject(forKey: blockedUntilKey)
  }

  static func retryAfterDate(
    from response: HTTPURLResponse,
    now: Date = Date()
  ) -> Date? {
    guard let value = response.value(forHTTPHeaderField: "Retry-After")?
      .trimmingCharacters(in: .whitespacesAndNewlines),
      !value.isEmpty
    else {
      return nil
    }

    if let seconds = TimeInterval(value), seconds >= 0 {
      return now.addingTimeInterval(seconds)
    }

    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss zzz"
    return formatter.date(from: value)
  }

  static func message(blockedUntil: Date) -> String {
    let retryTime = blockedUntil.formatted(date: .omitted, time: .shortened)
    return "Claude: usage API rate limited — retry after \(retryTime)"
  }
}
