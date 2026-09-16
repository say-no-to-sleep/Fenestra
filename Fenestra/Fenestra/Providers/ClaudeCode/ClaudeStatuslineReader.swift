import Foundation

struct ClaudeStatuslineUsage: Sendable {
  let fiveHourUsedPercent: Double?
  let fiveHourReset: Date?
  let weeklyUsedPercent: Double?
  let weeklyReset: Date?
  let freshness: Date
}

enum ClaudeStatuslineReader {
  static var captureURL: URL {
    HistoryStore.applicationSupportDirectory.appending(path: "claude-statusline.json")
  }

  static func read() -> ClaudeStatuslineUsage? {
    guard let data = try? Data(contentsOf: captureURL),
      let attributes = try? FileManager.default.attributesOfItem(atPath: captureURL.path),
      let modified = attributes[.modificationDate] as? Date,
      (-60..<10 * 60).contains(Date().timeIntervalSince(modified)),
      let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let limits = root["rate_limits"] as? [String: Any]
    else {
      return nil
    }
    let fiveHour = limits["five_hour"] as? [String: Any]
    let sevenDay = limits["seven_day"] as? [String: Any]
    let fiveHourUsed = usedPercent(fiveHour)
    let weeklyUsed = usedPercent(sevenDay)
    guard fiveHourUsed != nil || weeklyUsed != nil else { return nil }
    return ClaudeStatuslineUsage(
      fiveHourUsedPercent: fiveHourUsed,
      fiveHourReset: ProviderDateParser.date(
        from: fiveHour?["resets_at"] ?? fiveHour?["reset_at"]
      ),
      weeklyUsedPercent: weeklyUsed,
      weeklyReset: ProviderDateParser.date(
        from: sevenDay?["resets_at"] ?? sevenDay?["reset_at"]
      ),
      freshness: modified
    )
  }

  private static func usedPercent(_ object: [String: Any]?) -> Double? {
    guard let object else { return nil }
    // Claude Code ≥2.1 emits `used_percentage`; the others are older/aliased spellings.
    let value =
      object["used_percentage"]
      ?? object["utilization"]
      ?? object["used_percent"]
      ?? object["usedPercent"]
    guard let number = value as? NSNumber,
      number.doubleValue.isFinite,
      (0...100).contains(number.doubleValue)
    else {
      return nil
    }
    return number.doubleValue
  }
}
