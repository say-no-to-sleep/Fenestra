import Foundation

enum ProviderDateParser {
  nonisolated static func date(from value: Any?) -> Date? {
    if let date = value as? Date {
      return date
    }
    if let number = value as? NSNumber {
      return epochDate(number.doubleValue)
    }
    guard let string = value as? String else { return nil }
    if let numeric = Double(string) {
      return epochDate(numeric)
    }

    let withFractional = ISO8601DateFormatter()
    withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = withFractional.date(from: string) {
      return date
    }
    let standard = ISO8601DateFormatter()
    return standard.date(from: string)
  }

  nonisolated static func epochDate(_ raw: Double) -> Date? {
    guard raw.isFinite, raw > 0 else { return nil }
    let seconds = raw > 10_000_000_000 ? raw / 1_000 : raw
    return Date(timeIntervalSince1970: seconds)
  }

  nonisolated static func window(
    endingAt end: Date?,
    providerDuration: TimeInterval?
  ) -> (start: Date?, end: Date?) {
    guard let end, let providerDuration, providerDuration > 0 else {
      return (nil, end)
    }
    return (end.addingTimeInterval(-providerDuration), end)
  }

  nonisolated static func future(_ date: Date?, after reference: Date) -> Date? {
    guard let date, date > reference else { return nil }
    return date
  }

  nonisolated static func activeWindow(
    start: Date?,
    end: Date?,
    at reference: Date
  ) -> (start: Date?, end: Date?) {
    guard let start, let end, start <= reference, end > reference, end > start else {
      return (nil, nil)
    }
    return (start, end)
  }
}
