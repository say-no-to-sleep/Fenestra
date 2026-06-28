import Foundation
import Observation

@Observable
@MainActor
final class HistoryStore {
  private(set) var points: [HistoryPoint] = []

  @ObservationIgnored private let retention: TimeInterval = 90 * 24 * 60 * 60
  @ObservationIgnored private let minimumSampleInterval: TimeInterval = 10 * 60
  @ObservationIgnored private let significantChange = 1.0
  @ObservationIgnored private let fileURL: URL

  init(fileURL: URL? = nil) {
    self.fileURL = fileURL ?? Self.applicationSupportDirectory.appending(path: "history.json")
  }

  func loadAndPrune(now: Date = Date()) {
    do {
      let data = try Data(contentsOf: fileURL)
      points = try JSONDecoder().decode([HistoryPoint].self, from: data)
    } catch CocoaError.fileReadNoSuchFile {
      points = []
    } catch {
      points = []
      LocalLog.record("History load failed: \(error.localizedDescription)")
    }
    _ = prune(now: now)
    persist()
  }

  func append(_ snapshot: UsageSnapshot) {
    var appended = false
    for pool in snapshot.pools {
      for window in pool.windows {
        let pace = PaceCalculator.delta(
          remainingPercent: window.remainingPercent,
          at: snapshot.freshness,
          windowStart: window.windowStart,
          windowEnd: window.windowEnd
        )
        guard
          shouldAppend(
            providerID: snapshot.providerID,
            poolID: pool.id,
            windowID: window.id,
            timestamp: snapshot.freshness,
            remainingPercent: window.remainingPercent
          )
        else {
          continue
        }
        points.append(
          HistoryPoint(
            providerID: snapshot.providerID,
            poolID: pool.id,
            windowID: window.id,
            timestamp: snapshot.freshness,
            remainingPercent: window.remainingPercent,
            paceDelta: pace
          ))
        appended = true
      }
    }
    let pruned = prune(now: snapshot.freshness)
    if appended || pruned {
      persist()
    }
  }

  func points(
    providerID: ProviderID,
    poolID: String,
    windowID: String,
    since: Date? = nil
  ) -> [HistoryPoint] {
    points.filter {
      guard $0.providerID == providerID,
        $0.poolID == poolID,
        $0.windowID == windowID
      else {
        return false
      }
      guard let since else { return true }
      return $0.timestamp >= since
    }
  }

  func recentPoints(
    providerID: ProviderID,
    poolID: String,
    windowID: String,
    now: Date,
    lookback: TimeInterval = 60 * 60
  ) -> [HistoryPoint] {
    points(
      providerID: providerID,
      poolID: poolID,
      windowID: windowID,
      since: now.addingTimeInterval(-lookback)
    )
  }

  func dailyActivity(providerID: ProviderID? = nil, days: Int = 90) -> [DailyActivity] {
    let calendar = Calendar.autoupdatingCurrent
    let cutoff = calendar.date(byAdding: .day, value: -days, to: Date()) ?? .distantPast
    let filtered =
      points
      .filter { $0.timestamp >= cutoff && (providerID == nil || $0.providerID == providerID) }
      .sorted { $0.timestamp < $1.timestamp }
    var totals: [Date: Double] = [:]
    var previousByWindow: [String: HistoryPoint] = [:]
    for point in filtered {
      let key = "\(point.providerID.rawValue)|\(point.poolID)|\(point.windowID)"
      if let previous = previousByWindow[key] {
        let consumed = max(0, previous.remainingPercent - point.remainingPercent)
        totals[calendar.startOfDay(for: point.timestamp), default: 0] += consumed
      }
      previousByWindow[key] = point
    }
    return totals.map { DailyActivity(date: $0.key, amount: $0.value) }
      .sorted { $0.date < $1.date }
  }

  func dailyWorstPace(providerID: ProviderID? = nil, days: Int = 90) -> [DailyPace] {
    let calendar = Calendar.autoupdatingCurrent
    let cutoff = calendar.date(byAdding: .day, value: -days, to: Date()) ?? .distantPast
    var values: [Date: Double] = [:]
    for point in points
    where point.timestamp >= cutoff
      && (providerID == nil || point.providerID == providerID)
    {
      guard let delta = point.paceDelta else { continue }
      let day = calendar.startOfDay(for: point.timestamp)
      values[day] = min(values[day] ?? delta, delta)
    }
    return values.map { DailyPace(date: $0.key, delta: $0.value) }
      .sorted { $0.date < $1.date }
  }

  private func shouldAppend(
    providerID: ProviderID,
    poolID: String,
    windowID: String,
    timestamp: Date,
    remainingPercent: Double
  ) -> Bool {
    guard
      let last = points.last(where: {
        $0.providerID == providerID && $0.poolID == poolID && $0.windowID == windowID
      })
    else {
      return true
    }
    return timestamp.timeIntervalSince(last.timestamp) >= minimumSampleInterval
      || abs(remainingPercent - last.remainingPercent) >= significantChange
  }

  @discardableResult
  private func prune(now: Date) -> Bool {
    let cutoff = now.addingTimeInterval(-retention)
    let previousCount = points.count
    points.removeAll { $0.timestamp < cutoff }
    return points.count != previousCount
  }

  private func persist() {
    do {
      try FileManager.default.createDirectory(
        at: fileURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys]
      let data = try encoder.encode(points)
      try data.write(to: fileURL, options: .atomic)
    } catch {
      LocalLog.record("History save failed: \(error.localizedDescription)")
    }
  }

  nonisolated static var applicationSupportDirectory: URL {
    let base =
      FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? FileManager.default.homeDirectoryForCurrentUser
      .appending(path: "Library/Application Support", directoryHint: .isDirectory)
    return base.appending(path: "Fenestra", directoryHint: .isDirectory)
  }
}

struct DailyActivity: Identifiable, Equatable, Sendable {
  var id: Date { date }
  let date: Date
  let amount: Double
}

struct DailyPace: Identifiable, Equatable, Sendable {
  var id: Date { date }
  let date: Date
  let delta: Double
}
