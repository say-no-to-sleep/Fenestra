import Foundation
import Observation

@Observable
@MainActor
final class HistoryStore {
  private(set) var points: [HistoryPoint] = []
  private(set) var activeRegimes: [ProviderID: SubscriptionRegime] = [:]
  private(set) var activeAnomalies: [UsageAnomaly] = []
  private(set) var profileChangeSuggestions: Set<ProviderID> = []
  private(set) var databaseAvailable = true

  @ObservationIgnored private let memoryRetention: TimeInterval = 90 * 24 * 60 * 60
  @ObservationIgnored private let minimumSampleInterval: TimeInterval = 10 * 60
  @ObservationIgnored private let significantChange = 1.0
  @ObservationIgnored private let legacyFileURL: URL
  @ObservationIgnored private let database: HistoryDatabase

  init(fileURL: URL? = nil, databaseURL: URL? = nil) {
    let legacy = fileURL ?? Self.applicationSupportDirectory.appending(path: "history.json")
    legacyFileURL = legacy
    let sqlite = databaseURL
      ?? legacy.deletingLastPathComponent().appending(path: "history.sqlite3")
    database = HistoryDatabase(databaseURL: sqlite)
  }

  func loadAndPrune(now: Date = Date()) async {
    do {
      try await database.prepare()
      try await database.importLegacyJSONIfNeeded(from: legacyFileURL)
      try await database.prune(now: now)
      points = try await database.loadRecentPoints(
        since: now.addingTimeInterval(-memoryRetention)
      )
      for providerID in ProviderID.allCases {
        if let regime = try await database.activeRegime(providerID: providerID) {
          activeRegimes[providerID] = regime
        }
      }
      activeAnomalies = try await database.activeAnomalies()
      databaseAvailable = true
    } catch {
      databaseAvailable = false
      loadLegacyAndPrune(now: now)
      LocalLog.record("SQLite history unavailable; using legacy history: \(error.localizedDescription)")
    }
  }

  func append(_ snapshot: UsageSnapshot) async {
    var newPoints: [HistoryPoint] = []
    for pool in snapshot.pools {
      for window in pool.windows {
        let pace = PaceCalculator.delta(
          remainingPercent: window.remainingPercent,
          at: snapshot.freshness,
          windowStart: window.windowStart,
          windowEnd: window.windowEnd
        )
        guard shouldAppend(
          providerID: snapshot.providerID,
          poolID: pool.id,
          windowID: window.id,
          timestamp: snapshot.freshness,
          remainingPercent: window.remainingPercent
        ) else { continue }
        newPoints.append(
          HistoryPoint(
            providerID: snapshot.providerID,
            poolID: pool.id,
            windowID: window.id,
            timestamp: snapshot.freshness,
            remainingPercent: window.remainingPercent,
            paceDelta: pace
          ))
      }
    }
    if !newPoints.isEmpty {
      points.append(contentsOf: newPoints)
      _ = pruneMemory(now: snapshot.freshness)
    }

    guard databaseAvailable else {
      if !newPoints.isEmpty { persistLegacy() }
      return
    }
    do {
      let resolution = try await database.record(snapshot: snapshot, points: newPoints)
      activeRegimes[snapshot.providerID] = resolution.regime
      if resolution.patternChangeSuggested {
        profileChangeSuggestions.insert(snapshot.providerID)
      } else {
        profileChangeSuggestions.remove(snapshot.providerID)
      }
    } catch {
      databaseAvailable = false
      persistLegacy()
      LocalLog.record("SQLite history write failed; using legacy history: \(error.localizedDescription)")
    }
  }

  func recordRefresh(_ event: ProviderRefreshEvent) async {
    guard databaseAvailable else { return }
    do {
      try await database.recordRefresh(event)
    } catch {
      LocalLog.record("Refresh history write failed: \(error.localizedDescription)")
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
      else { return false }
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

  func historicalWindows(
    providerID: ProviderID,
    poolID: String,
    windowID: String,
    includeOtherRegimes: Bool = false,
    limit: Int = 52
  ) async -> [HistoricalUsageWindow] {
    guard databaseAvailable else { return [] }
    do {
      return try await database.historicalWindows(
        providerID: providerID,
        seriesKey: HistoryDatabase.seriesKey(
          providerID: providerID,
          poolID: poolID,
          windowID: windowID
        ),
        regimeID: activeRegimes[providerID]?.id,
        includeOtherRegimes: includeOtherRegimes,
        limit: limit
      )
    } catch {
      LocalLog.record("Historical window query failed: \(error.localizedDescription)")
      return []
    }
  }

  func comparableWindows(
    providerID: ProviderID,
    poolID: String,
    windowID: String,
    before date: Date = .distantFuture
  ) async -> [HistoricalUsageWindow] {
    guard databaseAvailable, let regime = activeRegimes[providerID] else { return [] }
    do {
      return try await database.comparableWindows(
        providerID: providerID,
        seriesKey: HistoryDatabase.seriesKey(
          providerID: providerID,
          poolID: poolID,
          windowID: windowID
        ),
        regimeID: regime.id,
        before: date
      )
    } catch {
      LocalLog.record("Comparable history query failed: \(error.localizedDescription)")
      return []
    }
  }

  func startNewProfile(providerID: ProviderID, now: Date = Date()) async {
    guard databaseAvailable else { return }
    do {
      try await database.startNewProfile(providerID: providerID, now: now)
      activeRegimes.removeValue(forKey: providerID)
      profileChangeSuggestions.remove(providerID)
    } catch {
      LocalLog.record("Could not start a new usage profile: \(error.localizedDescription)")
    }
  }

  func clearAll() async {
    points = []
    activeRegimes = [:]
    activeAnomalies = []
    profileChangeSuggestions = []
    if databaseAvailable {
      do { try await database.clearAll() }
      catch { LocalLog.record("Could not clear usage history: \(error.localizedDescription)") }
    }
  }

  func usageCSV() async -> Data {
    let samples = (try? await database.exportPayload().samples) ?? points
    var rows = ["id,provider,pool,window,timestamp,remaining_percent,pace_delta,regime_id,window_instance_id"]
    let formatter = ISO8601DateFormatter()
    rows += samples.map { point in
      [
        point.id.uuidString,
        point.providerID.rawValue,
        Self.csv(point.poolID),
        Self.csv(point.windowID),
        formatter.string(from: point.timestamp),
        point.remainingPercent.formatted(.number.locale(Locale(identifier: "en_US_POSIX"))),
        point.paceDelta?.formatted(.number.locale(Locale(identifier: "en_US_POSIX"))) ?? "",
        point.regimeID?.uuidString ?? "",
        point.windowInstanceID?.uuidString ?? "",
      ].joined(separator: ",")
    }
    return Data(rows.joined(separator: "\n").utf8)
  }

  func fullJSON() async -> Data {
    guard let payload = try? await database.exportPayload() else {
      return (try? JSONEncoder().encode(points)) ?? Data("[]".utf8)
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    return (try? encoder.encode(payload)) ?? Data("{}".utf8)
  }

  func exportPayload() async -> UsageHistoryExport? {
    try? await database.exportPayload()
  }

  func saveAnomalies(_ anomalies: [UsageAnomaly]) async {
    activeAnomalies = anomalies.filter(\.isActive)
    guard databaseAvailable else { return }
    for anomaly in anomalies {
      do { try await database.upsertAnomaly(anomaly) }
      catch { LocalLog.record("Anomaly history write failed: \(error.localizedDescription)") }
    }
  }

  func healthSummary(
    providerID: ProviderID,
    source: String?,
    staleDuration: TimeInterval
  ) async -> ProviderHealthSummary {
    let events = (try? await database.refreshEvents(
      providerID: providerID,
      since: Date().addingTimeInterval(-7 * 24 * 60 * 60)
    )) ?? []
    let successes = events.filter(\.succeeded)
    let latencies = successes.map(\.duration).sorted()
    let median = latencies.isEmpty ? nil : latencies[latencies.count / 2]
    return ProviderHealthSummary(
      providerID: providerID,
      source: source,
      lastSuccess: successes.last?.timestamp,
      sevenDaySuccessRate: events.isEmpty ? nil : Double(successes.count) / Double(events.count),
      medianRefreshLatency: median,
      fallbackCount: successes.filter { $0.source != nil && $0.source != source }.count,
      staleDuration: staleDuration,
      resetAccuracy: nil,
      activeRegime: activeRegimes[providerID],
      activeAnomalies: activeAnomalies.filter { $0.providerID == providerID }
    )
  }

  func dailyActivity(providerID: ProviderID? = nil, days: Int = 90) -> [DailyActivity] {
    let calendar = Calendar.autoupdatingCurrent
    let cutoff = calendar.date(byAdding: .day, value: -days, to: Date()) ?? .distantPast
    let filtered = points
      .filter { $0.timestamp >= cutoff && (providerID == nil || $0.providerID == providerID) }
      .sorted { $0.timestamp < $1.timestamp }
    var totals: [Date: Double] = [:]
    var previousByWindow: [String: HistoryPoint] = [:]
    for point in filtered {
      let key = "\(point.providerID.rawValue)|\(point.poolID)|\(point.windowID)"
      if let previous = previousByWindow[key] {
        totals[calendar.startOfDay(for: point.timestamp), default: 0] +=
          max(0, previous.remainingPercent - point.remainingPercent)
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
    for point in points where point.timestamp >= cutoff
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
    guard let last = points.last(where: {
      $0.providerID == providerID && $0.poolID == poolID && $0.windowID == windowID
    }) else { return true }
    return timestamp.timeIntervalSince(last.timestamp) >= minimumSampleInterval
      || abs(remainingPercent - last.remainingPercent) >= significantChange
  }

  @discardableResult
  private func pruneMemory(now: Date) -> Bool {
    let previousCount = points.count
    points.removeAll { $0.timestamp < now.addingTimeInterval(-memoryRetention) }
    return points.count != previousCount
  }

  private func loadLegacyAndPrune(now: Date) {
    do {
      points = try JSONDecoder().decode([HistoryPoint].self, from: Data(contentsOf: legacyFileURL))
    } catch CocoaError.fileReadNoSuchFile {
      points = []
    } catch {
      points = []
      LocalLog.record("History load failed: \(error.localizedDescription)")
    }
    _ = pruneMemory(now: now)
  }

  private func persistLegacy() {
    do {
      try FileManager.default.createDirectory(
        at: legacyFileURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys]
      try encoder.encode(points).write(to: legacyFileURL, options: .atomic)
    } catch {
      LocalLog.record("History save failed: \(error.localizedDescription)")
    }
  }

  private static func csv(_ value: String) -> String {
    guard value.contains(",") || value.contains("\"") || value.contains("\n") else { return value }
    return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
  }

  nonisolated static var applicationSupportDirectory: URL {
    let base = FileManager.default.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    ).first ?? FileManager.default.homeDirectoryForCurrentUser
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
