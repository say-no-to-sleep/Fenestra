import Foundation
import SQLite3

enum HistoryDatabaseError: Error, LocalizedError {
  case open(String)
  case statement(String)
  case step(String)

  var errorDescription: String? {
    switch self {
    case .open(let message): "Could not open usage database: \(message)"
    case .statement(let message): "Could not prepare usage database statement: \(message)"
    case .step(let message): "Usage database operation failed: \(message)"
    }
  }
}

struct RegimeResolution: Sendable {
  let regime: SubscriptionRegime
  let patternChangeSuggested: Bool
}

actor HistoryDatabase {
  private let databaseURL: URL
  private var connection: OpaquePointer?
  private let encoder = JSONEncoder()
  private let decoder = JSONDecoder()

  init(databaseURL: URL) {
    self.databaseURL = databaseURL
  }

  isolated deinit {
    if let connection { sqlite3_close(connection) }
  }

  func prepare() throws {
    guard connection == nil else { return }
    try FileManager.default.createDirectory(
      at: databaseURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    var database: OpaquePointer?
    guard sqlite3_open_v2(
      databaseURL.path,
      &database,
      SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
      nil
    ) == SQLITE_OK, let database
    else {
      throw HistoryDatabaseError.open(database.map(errorMessage) ?? "Unknown SQLite error")
    }
    connection = database
    try execute("PRAGMA journal_mode=WAL")
    try execute("PRAGMA foreign_keys=ON")
    try execute("PRAGMA synchronous=NORMAL")
    try execute(Self.schema)
  }

  func importLegacyJSONIfNeeded(from fileURL: URL) throws {
    try prepare()
    guard try metaValue(for: "legacy_json_imported") != "1" else { return }
    guard FileManager.default.fileExists(atPath: fileURL.path) else {
      try setMeta("1", for: "legacy_json_imported")
      return
    }
    let data = try Data(contentsOf: fileURL)
    let points = try decoder.decode([HistoryPoint].self, from: data)
    try transaction {
      for point in points {
        try insert(point, regimeID: nil, windowInstanceID: nil)
      }
      try setMeta("1", for: "legacy_json_imported")
    }
  }

  func loadRecentPoints(since cutoff: Date) throws -> [HistoryPoint] {
    try prepare()
    return try queryPoints(
      sql: """
        SELECT id, provider, pool_id, window_id, timestamp, remaining, pace_delta,
               regime_id, window_instance_id
        FROM usage_samples WHERE timestamp >= ? ORDER BY timestamp
        """,
      bind: { statement in bind(cutoff.timeIntervalSince1970, to: 1, in: statement) }
    )
  }

  func record(snapshot: UsageSnapshot, points: [HistoryPoint]) throws -> RegimeResolution {
    try prepare()
    return try transaction {
      let resolution = try resolveRegime(for: snapshot)
      for pool in snapshot.pools {
        for window in pool.windows {
          guard let start = window.windowStart, let end = window.windowEnd, end > start else {
            continue
          }
          let seriesKey = Self.seriesKey(
            providerID: snapshot.providerID,
            poolID: pool.id,
            windowID: window.id
          )
          let instanceID = try upsertWindowInstance(
            snapshot: snapshot,
            pool: pool,
            window: window,
            seriesKey: seriesKey,
            regime: resolution.regime
          )
          try assignLegacySamples(
            providerID: snapshot.providerID,
            poolID: pool.id,
            windowID: window.id,
            start: start,
            end: end,
            instanceID: instanceID,
            regimeID: resolution.regime.id
          )
        }
      }
      for point in points {
        let instanceID = try matchingWindowInstance(for: point)
        try insert(point, regimeID: resolution.regime.id, windowInstanceID: instanceID)
      }
      try updateCoverage(providerID: snapshot.providerID, now: snapshot.freshness)
      return resolution
    }
  }

  func recordRefresh(_ event: ProviderRefreshEvent) throws {
    try prepare()
    try withStatement(
      """
      INSERT OR REPLACE INTO refresh_events
      (id, provider, timestamp, duration, source, succeeded, failure_category, stale_duration)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?)
      """
    ) { statement in
      bind(event.id.uuidString, to: 1, in: statement)
      bind(event.providerID.rawValue, to: 2, in: statement)
      bind(event.timestamp.timeIntervalSince1970, to: 3, in: statement)
      bind(event.duration, to: 4, in: statement)
      bind(event.source, to: 5, in: statement)
      bind(event.succeeded ? 1 : 0, to: 6, in: statement)
      bind(event.failureCategory?.rawValue, to: 7, in: statement)
      bind(event.staleDuration, to: 8, in: statement)
      try stepDone(statement)
    }
  }

  func historicalWindows(
    providerID: ProviderID,
    seriesKey: String,
    regimeID: UUID?,
    includeOtherRegimes: Bool,
    limit: Int
  ) throws -> [HistoricalUsageWindow] {
    try prepare()
    // A provider can revise its reset on each poll, so each poll may store a shifted report.
    // A report is superseded by the next one when that next report starts before it ends AND
    // either starts within 5 min of it (a drifted revision, or Codex's idle window that slides
    // with every poll) or nothing was used before it (an idle placeholder). Otherwise the next
    // report is an early reset and this one is a real session that ended early.
    // The 5 min slack also absorbs back-to-back sessions whose start jitters ~1 min before
    // the previous reported end (Claude), which used to merge and drop the earlier session.
    var sql = """
      WITH reports AS (
        SELECT *, LEAD(start) OVER (
          PARTITION BY regime_id, kind, quota_total ORDER BY start, end, id
        ) AS next_start
        FROM window_instances WHERE provider = ? AND series_key = ?
      """
    if !includeOtherRegimes, regimeID != nil { sql += " AND regime_id = ?" }
    sql += """
      )
      SELECT id, pool_id, window_id, kind, start, end, quota_total, regime_id, plan_name, coverage,
        next_start
      FROM reports WHERE end <= ? AND (
        next_start IS NULL OR next_start >= end - 300
        OR (next_start - start >= 300 AND EXISTS (
          SELECT 1 FROM usage_samples s
          WHERE s.provider = reports.provider AND s.series_key = reports.series_key
            AND s.timestamp >= reports.start AND s.timestamp < reports.next_start
            AND s.remaining < 100
        ))
      )
      ORDER BY end DESC LIMIT ?
      """
    return try withStatement(sql) { statement in
      bind(providerID.rawValue, to: 1, in: statement)
      bind(seriesKey, to: 2, in: statement)
      var index: Int32 = 3
      if !includeOtherRegimes, let regimeID {
        bind(regimeID.uuidString, to: index, in: statement)
        index += 1
      }
      bind(Date().timeIntervalSince1970, to: index, in: statement)
      bind(limit, to: index + 1, in: statement)
      var windows: [HistoricalUsageWindow] = []
      while sqlite3_step(statement) == SQLITE_ROW {
        guard let id = UUID(uuidString: text(statement, 0)),
          let kind = UsageWindowKind(rawValue: text(statement, 3))
        else { continue }
        let start = Date(timeIntervalSince1970: sqlite3_column_double(statement, 4))
        let end = Date(timeIntervalSince1970: sqlite3_column_double(statement, 5))
        let windowRegimeID = optionalUUID(statement, 7)
        // An early-reset session stops at the next window's start; later samples belong to it.
        let samplesEnd = optionalDate(statement, 10).map { min($0, end) } ?? end
        let samples = try samples(
          providerID: providerID,
          seriesKey: seriesKey,
          start: start,
          end: samplesEnd,
          regimeID: windowRegimeID
        )
        let expectedSamples = max(1, end.timeIntervalSince(start) / 600)
        let observedCoverage = min(1, Double(samples.count) / expectedSamples)
        windows.append(
          HistoricalUsageWindow(
            id: id,
            providerID: providerID,
            seriesKey: seriesKey,
            poolID: text(statement, 1),
            windowID: text(statement, 2),
            kind: kind,
            start: start,
            end: end,
            quotaTotal: sqlite3_column_double(statement, 6),
            regimeID: windowRegimeID,
            planName: optionalText(statement, 8),
            observationCoverage: max(sqlite3_column_double(statement, 9), observedCoverage),
            samples: samples
          ))
      }
      return windows
    }
  }

  func activeRegime(providerID: ProviderID) throws -> SubscriptionRegime? {
    try prepare()
    return try withStatement(
      """
      SELECT id, fingerprint, plan_name, started_at, ended_at, manual,
             returning_validation, completed_since_return
      FROM regimes WHERE provider = ? AND ended_at IS NULL ORDER BY started_at DESC LIMIT 1
      """
    ) { statement in
      bind(providerID.rawValue, to: 1, in: statement)
      guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
      return regime(from: statement, providerID: providerID)
    }
  }

  func startNewProfile(providerID: ProviderID, now: Date) throws {
    try prepare()
    try transaction {
      try withStatement(
        "UPDATE regimes SET ended_at = ? WHERE provider = ? AND ended_at IS NULL"
      ) { statement in
        bind(now.timeIntervalSince1970, to: 1, in: statement)
        bind(providerID.rawValue, to: 2, in: statement)
        try stepDone(statement)
      }
      try setMeta(UUID().uuidString, for: "manual_epoch.\(providerID.rawValue)")
    }
  }

  func prune(now: Date) throws {
    try prepare()
    let sampleCutoff = now.addingTimeInterval(-365 * 24 * 60 * 60).timeIntervalSince1970
    let refreshCutoff = now.addingTimeInterval(-30 * 24 * 60 * 60).timeIntervalSince1970
    try transaction {
      try execute("DELETE FROM usage_samples WHERE timestamp < \(sampleCutoff)")
      try execute("DELETE FROM window_instances WHERE end < \(sampleCutoff)")
      try execute("DELETE FROM refresh_events WHERE timestamp < \(refreshCutoff)")
    }
  }

  func clearAll() throws {
    try prepare()
    try transaction {
      for table in ["usage_samples", "window_instances", "regimes", "refresh_events", "anomalies"] {
        try execute("DELETE FROM \(table)")
      }
      try execute("DELETE FROM metadata WHERE key LIKE 'manual_epoch.%'")
    }
  }

  func refreshEvents(providerID: ProviderID, since: Date) throws -> [ProviderRefreshEvent] {
    try prepare()
    return try withStatement(
      """
      SELECT id, timestamp, duration, source, succeeded, failure_category, stale_duration
      FROM refresh_events WHERE provider = ? AND timestamp >= ? ORDER BY timestamp
      """
    ) { statement in
      bind(providerID.rawValue, to: 1, in: statement)
      bind(since.timeIntervalSince1970, to: 2, in: statement)
      var events: [ProviderRefreshEvent] = []
      while sqlite3_step(statement) == SQLITE_ROW {
        guard let id = UUID(uuidString: text(statement, 0)) else { continue }
        events.append(
          ProviderRefreshEvent(
            id: id,
            providerID: providerID,
            timestamp: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
            duration: sqlite3_column_double(statement, 2),
            source: optionalText(statement, 3),
            succeeded: sqlite3_column_int(statement, 4) != 0,
            failureCategory: optionalText(statement, 5).flatMap(RefreshFailureCategory.init),
            staleDuration: sqlite3_column_double(statement, 6)
          ))
      }
      return events
    }
  }

  func upsertAnomaly(_ anomaly: UsageAnomaly) throws {
    try prepare()
    try withStatement(
      """
      INSERT OR REPLACE INTO anomalies
      (id, provider, series_key, kind, detected_at, confirmed_at, resolved_at, detail, alertable)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
      """
    ) { statement in
      bind(anomaly.id.uuidString, to: 1, in: statement)
      bind(anomaly.providerID.rawValue, to: 2, in: statement)
      bind(anomaly.seriesKey, to: 3, in: statement)
      bind(anomaly.kind.rawValue, to: 4, in: statement)
      bind(anomaly.detectedAt.timeIntervalSince1970, to: 5, in: statement)
      bind(anomaly.confirmedAt?.timeIntervalSince1970, to: 6, in: statement)
      bind(anomaly.resolvedAt?.timeIntervalSince1970, to: 7, in: statement)
      bind(anomaly.detail, to: 8, in: statement)
      bind(anomaly.alertable ? 1 : 0, to: 9, in: statement)
      try stepDone(statement)
    }
  }

  func activeAnomalies(providerID: ProviderID? = nil) throws -> [UsageAnomaly] {
    try prepare()
    var sql = """
      SELECT id, provider, series_key, kind, detected_at, confirmed_at, resolved_at, detail, alertable
      FROM anomalies WHERE resolved_at IS NULL
      """
    if providerID != nil { sql += " AND provider = ?" }
    sql += " ORDER BY detected_at DESC"
    return try withStatement(sql) { statement in
      if let providerID { bind(providerID.rawValue, to: 1, in: statement) }
      var result: [UsageAnomaly] = []
      while sqlite3_step(statement) == SQLITE_ROW {
        guard let id = UUID(uuidString: text(statement, 0)),
          let provider = ProviderID(rawValue: text(statement, 1)),
          let kind = UsageAnomalyKind(rawValue: text(statement, 3))
        else { continue }
        result.append(
          UsageAnomaly(
            id: id,
            providerID: provider,
            seriesKey: optionalText(statement, 2),
            kind: kind,
            detectedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4)),
            confirmedAt: optionalDate(statement, 5),
            resolvedAt: optionalDate(statement, 6),
            detail: text(statement, 7),
            alertable: sqlite3_column_int(statement, 8) != 0
          ))
      }
      return result
    }
  }

  func exportPayload(now: Date = Date()) throws -> UsageHistoryExport {
    try prepare()
    let samples = try queryPoints(
      sql: """
        SELECT id, provider, pool_id, window_id, timestamp, remaining, pace_delta,
               regime_id, window_instance_id
        FROM usage_samples ORDER BY timestamp
        """,
      bind: { _ in }
    )
    let regimes = try withStatement(
      """
      SELECT id, provider, fingerprint, plan_name, started_at, ended_at, manual,
             returning_validation, completed_since_return
      FROM regimes ORDER BY started_at
      """
    ) { statement in
      var values: [SubscriptionRegime] = []
      while sqlite3_step(statement) == SQLITE_ROW {
        guard let provider = ProviderID(rawValue: text(statement, 1)),
          let id = UUID(uuidString: text(statement, 0))
        else { continue }
        values.append(
          SubscriptionRegime(
            id: id,
            providerID: provider,
            fingerprint: text(statement, 2),
            planName: optionalText(statement, 3),
            startedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4)),
            endedAt: optionalDate(statement, 5),
            createdManually: sqlite3_column_int(statement, 6) != 0,
            returningPlanNeedsValidation: sqlite3_column_int(statement, 7) != 0,
            completedWindowsSinceReturn: Int(sqlite3_column_int(statement, 8))
          ))
      }
      return values
    }
    let windows = try withStatement(
      """
      SELECT id, provider, series_key, pool_id, window_id, kind, start, end,
             quota_total, regime_id, plan_name, coverage
      FROM window_instances ORDER BY start
      """
    ) { statement in
      var values: [StoredUsageWindow] = []
      while sqlite3_step(statement) == SQLITE_ROW {
        guard let id = UUID(uuidString: text(statement, 0)),
          let provider = ProviderID(rawValue: text(statement, 1)),
          let kind = UsageWindowKind(rawValue: text(statement, 5))
        else { continue }
        values.append(
          StoredUsageWindow(
            id: id,
            providerID: provider,
            seriesKey: text(statement, 2),
            poolID: text(statement, 3),
            windowID: text(statement, 4),
            kind: kind,
            start: Date(timeIntervalSince1970: sqlite3_column_double(statement, 6)),
            end: Date(timeIntervalSince1970: sqlite3_column_double(statement, 7)),
            quotaTotal: sqlite3_column_double(statement, 8),
            regimeID: optionalUUID(statement, 9),
            planName: optionalText(statement, 10),
            observationCoverage: sqlite3_column_double(statement, 11)
          ))
      }
      return values
    }
    let refreshEvents = try allRefreshEvents()
    let anomalies = try allAnomalies()
    return UsageHistoryExport(
      generatedAt: now,
      regimes: regimes,
      windows: windows,
      samples: samples,
      refreshEvents: refreshEvents,
      anomalies: anomalies
    )
  }

  static func seriesKey(providerID: ProviderID, poolID: String, windowID: String) -> String {
    let pool = canonicalAlias(poolID)
    let window = canonicalAlias(windowID)
    return "\(providerID.rawValue)|\(pool)|\(window)"
  }

  private static func canonicalAlias(_ raw: String) -> String {
    let value = raw.lowercased().filter { $0.isLetter || $0.isNumber }
    switch value {
    case "gemini3prohigh", "gemini3prolow", "geminipro", "pro": return "geminipro"
    case "gemini3flash", "geminiflash", "flash": return "geminiflash"
    case "cursor", "included", "onetime", "api", "totalmonthly", "monthly": return "total"
    case "defaultpool", "primary": return "default"
    default: return value
    }
  }

  private func resolveRegime(for snapshot: UsageSnapshot) throws -> RegimeResolution {
    let plan = Self.reliablePlanName(snapshot.planDescription)
    let coreFingerprint = Self.fingerprint(snapshot: snapshot, plan: plan)
    let epoch = try metaValue(for: "manual_epoch.\(snapshot.providerID.rawValue)") ?? ""
    let fingerprint = epoch.isEmpty ? coreFingerprint : "\(coreFingerprint)|profile:\(epoch)"
    if let active = try activeRegime(providerID: snapshot.providerID) {
      if active.planName == plan,
        Self.isTimelineLoss(snapshot: snapshot, comparedWith: active)
      {
        return RegimeResolution(regime: active, patternChangeSuggested: false)
      }
      if let plan,
        let previous = try previousCompatibleRegime(
          providerID: snapshot.providerID,
          planName: plan,
          createdManually: active.createdManually,
          excluding: active.id
        ),
        Self.isTimelineLoss(snapshot: snapshot, comparedWith: previous),
        previous.endedAt.map({ abs($0.timeIntervalSince(active.startedAt)) < 120 }) == true
      {
        return RegimeResolution(
          regime: try mergeTransientRegime(active, into: previous),
          patternChangeSuggested: false
        )
      }
      if active.fingerprint == fingerprint {
        return RegimeResolution(regime: active, patternChangeSuggested: false)
      }
      if plan == nil {
        return RegimeResolution(regime: active, patternChangeSuggested: true)
      }
      try closeRegime(active.id, at: snapshot.freshness)
    }

    if var returning = try regime(providerID: snapshot.providerID, fingerprint: fingerprint) {
      try withStatement(
        """
        UPDATE regimes SET ended_at = NULL, returning_validation = 1,
          completed_since_return = 0 WHERE id = ?
        """
      ) { statement in
        bind(returning.id.uuidString, to: 1, in: statement)
        try stepDone(statement)
      }
      returning.endedAt = nil
      returning.returningPlanNeedsValidation = true
      returning.completedWindowsSinceReturn = 0
      return RegimeResolution(regime: returning, patternChangeSuggested: false)
    }

    let regime = SubscriptionRegime(
      id: UUID(),
      providerID: snapshot.providerID,
      fingerprint: fingerprint,
      planName: plan,
      startedAt: snapshot.freshness,
      endedAt: nil,
      createdManually: !epoch.isEmpty,
      returningPlanNeedsValidation: false,
      completedWindowsSinceReturn: 0
    )
    try insert(regime)
    return RegimeResolution(regime: regime, patternChangeSuggested: false)
  }

  private static func reliablePlanName(_ raw: String?) -> String? {
    guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
      return nil
    }
    let lower = value.lowercased()
    guard lower != "unknown", lower != "account", !lower.contains("unavailable") else { return nil }
    return lower.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
  }

  private static func fingerprint(snapshot: UsageSnapshot, plan: String?) -> String {
    let windows = snapshot.pools.flatMap { pool in
      pool.windows.map { window in
        let duration = window.windowStart.flatMap { start in
          window.windowEnd.map { Int($0.timeIntervalSince(start).rounded()) }
        } ?? 0
        let breakdown = window.breakdown.map(\.id).sorted().joined(separator: ",")
        return "\(canonicalAlias(pool.id))/\(canonicalAlias(window.id))/\(window.kind.rawValue)/\(duration)/\(window.quotaTotal.rounded())/[\(breakdown)]"
      }
    }.sorted().joined(separator: ";")
    return "\(snapshot.providerID.rawValue)|\(plan ?? "unidentified")|\(windows)"
  }

  private static func isTimelineLoss(
    snapshot: UsageSnapshot,
    comparedWith previous: SubscriptionRegime
  ) -> Bool {
    snapshot.pools.contains { pool in
      pool.windows.contains { window in
        guard !window.hasKnownTimeline, let duration = window.kind.knownDuration else {
          return false
        }
        let knownSignature =
          "\(canonicalAlias(pool.id))/\(canonicalAlias(window.id))/\(window.kind.rawValue)/\(Int(duration))/"
        return previous.fingerprint.contains(knownSignature)
      }
    }
  }

  private func upsertWindowInstance(
    snapshot: UsageSnapshot,
    pool: UsagePoolSnapshot,
    window: UsageWindowSnapshot,
    seriesKey: String,
    regime: SubscriptionRegime
  ) throws -> UUID {
    guard let start = window.windowStart, let end = window.windowEnd else { return UUID() }
    let existing: UUID? = try withStatement(
      """
      SELECT id FROM window_instances
      WHERE provider = ? AND series_key = ?
        AND ABS(start - ?) < 2 AND ABS(end - ?) < 2
      ORDER BY ABS(end - ?) LIMIT 1
      """
    ) { statement -> UUID? in
      bind(snapshot.providerID.rawValue, to: 1, in: statement)
      bind(seriesKey, to: 2, in: statement)
      bind(start.timeIntervalSince1970, to: 3, in: statement)
      bind(end.timeIntervalSince1970, to: 4, in: statement)
      bind(end.timeIntervalSince1970, to: 5, in: statement)
      guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
      return UUID(uuidString: text(statement, 0))
    }
    if let existing { return existing }

    let id = UUID()
    try withStatement(
      """
      INSERT INTO window_instances
      (id, provider, series_key, pool_id, window_id, kind, start, end, quota_total,
       quota_metadata, regime_id, plan_name, coverage)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0)
      """
    ) { statement in
      bind(id.uuidString, to: 1, in: statement)
      bind(snapshot.providerID.rawValue, to: 2, in: statement)
      bind(seriesKey, to: 3, in: statement)
      bind(pool.id, to: 4, in: statement)
      bind(window.id, to: 5, in: statement)
      bind(window.kind.rawValue, to: 6, in: statement)
      bind(start.timeIntervalSince1970, to: 7, in: statement)
      bind(end.timeIntervalSince1970, to: 8, in: statement)
      bind(window.quotaTotal, to: 9, in: statement)
      let metadata = (try? encoder.encode(window.breakdown)).flatMap { String(data: $0, encoding: .utf8) }
      bind(metadata, to: 10, in: statement)
      bind(regime.id.uuidString, to: 11, in: statement)
      bind(regime.planName, to: 12, in: statement)
      try stepDone(statement)
    }
    return id
  }

  private func matchingWindowInstance(for point: HistoryPoint) throws -> UUID? {
    let key = Self.seriesKey(providerID: point.providerID, poolID: point.poolID, windowID: point.windowID)
    return try withStatement(
      """
      SELECT id FROM window_instances
      WHERE provider = ? AND series_key = ? AND start <= ? AND end >= ?
      ORDER BY end DESC LIMIT 1
      """
    ) { statement in
      bind(point.providerID.rawValue, to: 1, in: statement)
      bind(key, to: 2, in: statement)
      bind(point.timestamp.timeIntervalSince1970, to: 3, in: statement)
      bind(point.timestamp.timeIntervalSince1970, to: 4, in: statement)
      guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
      return UUID(uuidString: text(statement, 0))
    }
  }

  private func assignLegacySamples(
    providerID: ProviderID,
    poolID: String,
    windowID: String,
    start: Date,
    end: Date,
    instanceID: UUID,
    regimeID: UUID
  ) throws {
    let aliases = Self.seriesKey(providerID: providerID, poolID: poolID, windowID: windowID)
    let candidates = try queryPoints(
      sql: """
      SELECT id, provider, pool_id, window_id, timestamp, remaining, pace_delta,
             regime_id, window_instance_id
      FROM usage_samples
      WHERE provider = ? AND timestamp >= ? AND timestamp <= ? AND window_instance_id IS NULL
      """,
      bind: { statement in
        bind(providerID.rawValue, to: 1, in: statement)
        bind(start.timeIntervalSince1970, to: 2, in: statement)
        bind(end.timeIntervalSince1970, to: 3, in: statement)
      }
    )
    for point in candidates where Self.seriesKey(
      providerID: point.providerID,
      poolID: point.poolID,
      windowID: point.windowID
    ) == aliases {
      try withStatement(
        "UPDATE usage_samples SET window_instance_id = ?, regime_id = ? WHERE id = ?"
      ) { statement in
        bind(instanceID.uuidString, to: 1, in: statement)
        bind(regimeID.uuidString, to: 2, in: statement)
        bind(point.id.uuidString, to: 3, in: statement)
        try stepDone(statement)
      }
    }
  }

  private func updateCoverage(providerID: ProviderID, now: Date) throws {
    let recentCutoff = now.addingTimeInterval(-24 * 60 * 60)
    let instances: [(UUID, Date, Date)] = try withStatement(
      """
      SELECT id, start, end FROM window_instances
      WHERE provider = ? AND end <= ? AND (coverage = 0 OR end >= ?)
      """
    ) { statement in
      bind(providerID.rawValue, to: 1, in: statement)
      bind(now.timeIntervalSince1970, to: 2, in: statement)
      bind(recentCutoff.timeIntervalSince1970, to: 3, in: statement)
      var values: [(UUID, Date, Date)] = []
      while sqlite3_step(statement) == SQLITE_ROW {
        if let id = UUID(uuidString: text(statement, 0)) {
          values.append((id, Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)), Date(timeIntervalSince1970: sqlite3_column_double(statement, 2))))
        }
      }
      return values
    }
    for (id, start, end) in instances {
      let count = try scalarInt("SELECT COUNT(*) FROM usage_samples WHERE window_instance_id = ?") {
        bind(id.uuidString, to: 1, in: $0)
      }
      let expected = max(1, end.timeIntervalSince(start) / 600)
      let coverage = min(1, Double(count) / expected)
      try withStatement("UPDATE window_instances SET coverage = ? WHERE id = ?") { statement in
        bind(coverage, to: 1, in: statement)
        bind(id.uuidString, to: 2, in: statement)
        try stepDone(statement)
      }
      guard coverage >= 0.6,
        try metaValue(for: "return_counted.\(id.uuidString)") == nil
      else { continue }
      let regimeID: UUID? = try withStatement(
        "SELECT regime_id FROM window_instances WHERE id = ?"
      ) { statement in
        bind(id.uuidString, to: 1, in: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return optionalUUID(statement, 0)
      }
      guard let regimeID else { continue }
      let needsValidation = try scalarInt(
        "SELECT returning_validation FROM regimes WHERE id = ?"
      ) { bind(regimeID.uuidString, to: 1, in: $0) } != 0
      guard needsValidation else { continue }
      try setMeta("1", for: "return_counted.\(id.uuidString)")
      try withStatement(
        """
        UPDATE regimes SET
          completed_since_return = completed_since_return + 1,
          returning_validation = CASE WHEN completed_since_return + 1 >= 2 THEN 0 ELSE 1 END
        WHERE id = ?
        """
      ) { statement in
        bind(regimeID.uuidString, to: 1, in: statement)
        try stepDone(statement)
      }
    }
  }

  private func allRefreshEvents() throws -> [ProviderRefreshEvent] {
    try withStatement(
      """
      SELECT id, provider, timestamp, duration, source, succeeded, failure_category, stale_duration
      FROM refresh_events ORDER BY timestamp
      """
    ) { statement in
      var values: [ProviderRefreshEvent] = []
      while sqlite3_step(statement) == SQLITE_ROW {
        guard let id = UUID(uuidString: text(statement, 0)),
          let provider = ProviderID(rawValue: text(statement, 1))
        else { continue }
        values.append(
          ProviderRefreshEvent(
            id: id,
            providerID: provider,
            timestamp: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)),
            duration: sqlite3_column_double(statement, 3),
            source: optionalText(statement, 4),
            succeeded: sqlite3_column_int(statement, 5) != 0,
            failureCategory: optionalText(statement, 6).flatMap(RefreshFailureCategory.init),
            staleDuration: sqlite3_column_double(statement, 7)
          ))
      }
      return values
    }
  }

  private func allAnomalies() throws -> [UsageAnomaly] {
    try withStatement(
      """
      SELECT id, provider, series_key, kind, detected_at, confirmed_at, resolved_at, detail, alertable
      FROM anomalies ORDER BY detected_at
      """
    ) { statement in
      var values: [UsageAnomaly] = []
      while sqlite3_step(statement) == SQLITE_ROW {
        guard let id = UUID(uuidString: text(statement, 0)),
          let provider = ProviderID(rawValue: text(statement, 1)),
          let kind = UsageAnomalyKind(rawValue: text(statement, 3))
        else { continue }
        values.append(
          UsageAnomaly(
            id: id,
            providerID: provider,
            seriesKey: optionalText(statement, 2),
            kind: kind,
            detectedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4)),
            confirmedAt: optionalDate(statement, 5),
            resolvedAt: optionalDate(statement, 6),
            detail: text(statement, 7),
            alertable: sqlite3_column_int(statement, 8) != 0
          ))
      }
      return values
    }
  }

  private func samples(windowInstanceID: UUID) throws -> [HistoryPoint] {
    try queryPoints(
      sql: """
      SELECT id, provider, pool_id, window_id, timestamp, remaining, pace_delta,
             regime_id, window_instance_id
      FROM usage_samples WHERE window_instance_id = ? ORDER BY timestamp
      """,
      bind: { bind(windowInstanceID.uuidString, to: 1, in: $0) }
    )
  }

  private func samples(
    providerID: ProviderID,
    seriesKey: String,
    start: Date,
    end: Date,
    regimeID: UUID?
  ) throws -> [HistoryPoint] {
    var sql = """
      SELECT id, provider, pool_id, window_id, timestamp, remaining, pace_delta,
             regime_id, window_instance_id
      FROM usage_samples
      WHERE provider = ? AND series_key = ? AND timestamp >= ? AND timestamp <= ?
      """
    if regimeID != nil { sql += " AND regime_id = ?" }
    sql += " ORDER BY timestamp"
    return try queryPoints(sql: sql) { statement in
      bind(providerID.rawValue, to: 1, in: statement)
      bind(seriesKey, to: 2, in: statement)
      bind(start.timeIntervalSince1970, to: 3, in: statement)
      bind(end.timeIntervalSince1970, to: 4, in: statement)
      if let regimeID { bind(regimeID.uuidString, to: 5, in: statement) }
    }
  }

  private func previousCompatibleRegime(
    providerID: ProviderID,
    planName: String,
    createdManually: Bool,
    excluding activeID: UUID
  ) throws -> SubscriptionRegime? {
    try withStatement(
      """
      SELECT id, fingerprint, plan_name, started_at, ended_at, manual,
             returning_validation, completed_since_return
      FROM regimes
      WHERE provider = ? AND plan_name = ? AND manual = ? AND id != ? AND ended_at IS NOT NULL
      ORDER BY ended_at DESC LIMIT 1
      """
    ) { statement in
      bind(providerID.rawValue, to: 1, in: statement)
      bind(planName, to: 2, in: statement)
      bind(createdManually ? 1 : 0, to: 3, in: statement)
      bind(activeID.uuidString, to: 4, in: statement)
      guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
      return regime(from: statement, providerID: providerID)
    }
  }

  private func mergeTransientRegime(
    _ transient: SubscriptionRegime,
    into previous: SubscriptionRegime
  ) throws -> SubscriptionRegime {
    try withStatement("UPDATE usage_samples SET regime_id = ? WHERE regime_id = ?") { statement in
      bind(previous.id.uuidString, to: 1, in: statement)
      bind(transient.id.uuidString, to: 2, in: statement)
      try stepDone(statement)
    }
    try withStatement("UPDATE window_instances SET regime_id = ? WHERE regime_id = ?") { statement in
      bind(previous.id.uuidString, to: 1, in: statement)
      bind(transient.id.uuidString, to: 2, in: statement)
      try stepDone(statement)
    }
    try withStatement("DELETE FROM regimes WHERE id = ?") { statement in
      bind(transient.id.uuidString, to: 1, in: statement)
      try stepDone(statement)
    }
    try withStatement(
      "UPDATE regimes SET ended_at = NULL, returning_validation = 0 WHERE id = ?"
    ) { statement in
      bind(previous.id.uuidString, to: 1, in: statement)
      try stepDone(statement)
    }
    var restored = previous
    restored.endedAt = nil
    restored.returningPlanNeedsValidation = false
    return restored
  }

  private func queryPoints(
    sql: String,
    bind bindings: (OpaquePointer) throws -> Void
  ) throws -> [HistoryPoint] {
    try withStatement(sql) { statement in
      try bindings(statement)
      var result: [HistoryPoint] = []
      while sqlite3_step(statement) == SQLITE_ROW {
        guard let id = UUID(uuidString: text(statement, 0)),
          let provider = ProviderID(rawValue: text(statement, 1))
        else { continue }
        result.append(
          HistoryPoint(
            id: id,
            providerID: provider,
            poolID: text(statement, 2),
            windowID: text(statement, 3),
            timestamp: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4)),
            remainingPercent: sqlite3_column_double(statement, 5),
            paceDelta: sqlite3_column_type(statement, 6) == SQLITE_NULL
              ? nil : sqlite3_column_double(statement, 6),
            regimeID: optionalUUID(statement, 7),
            windowInstanceID: optionalUUID(statement, 8)
          ))
      }
      return result
    }
  }

  private func insert(
    _ point: HistoryPoint,
    regimeID: UUID?,
    windowInstanceID: UUID?
  ) throws {
    try withStatement(
      """
      INSERT OR IGNORE INTO usage_samples
      (id, provider, series_key, pool_id, window_id, timestamp, remaining, pace_delta,
       regime_id, window_instance_id)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      """
    ) { statement in
      bind(point.id.uuidString, to: 1, in: statement)
      bind(point.providerID.rawValue, to: 2, in: statement)
      bind(Self.seriesKey(providerID: point.providerID, poolID: point.poolID, windowID: point.windowID), to: 3, in: statement)
      bind(point.poolID, to: 4, in: statement)
      bind(point.windowID, to: 5, in: statement)
      bind(point.timestamp.timeIntervalSince1970, to: 6, in: statement)
      bind(point.remainingPercent, to: 7, in: statement)
      bind(point.paceDelta, to: 8, in: statement)
      bind((regimeID ?? point.regimeID)?.uuidString, to: 9, in: statement)
      bind((windowInstanceID ?? point.windowInstanceID)?.uuidString, to: 10, in: statement)
      try stepDone(statement)
    }
  }

  private func insert(_ regime: SubscriptionRegime) throws {
    try withStatement(
      """
      INSERT INTO regimes
      (id, provider, fingerprint, plan_name, started_at, ended_at, manual,
       returning_validation, completed_since_return)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
      """
    ) { statement in
      bind(regime.id.uuidString, to: 1, in: statement)
      bind(regime.providerID.rawValue, to: 2, in: statement)
      bind(regime.fingerprint, to: 3, in: statement)
      bind(regime.planName, to: 4, in: statement)
      bind(regime.startedAt.timeIntervalSince1970, to: 5, in: statement)
      bind(regime.endedAt?.timeIntervalSince1970, to: 6, in: statement)
      bind(regime.createdManually ? 1 : 0, to: 7, in: statement)
      bind(regime.returningPlanNeedsValidation ? 1 : 0, to: 8, in: statement)
      bind(regime.completedWindowsSinceReturn, to: 9, in: statement)
      try stepDone(statement)
    }
  }

  private func regime(providerID: ProviderID, fingerprint: String) throws -> SubscriptionRegime? {
    try withStatement(
      """
      SELECT id, fingerprint, plan_name, started_at, ended_at, manual,
             returning_validation, completed_since_return
      FROM regimes WHERE provider = ? AND fingerprint = ? ORDER BY started_at DESC LIMIT 1
      """
    ) { statement in
      bind(providerID.rawValue, to: 1, in: statement)
      bind(fingerprint, to: 2, in: statement)
      guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
      return regime(from: statement, providerID: providerID)
    }
  }

  private func regime(from statement: OpaquePointer, providerID: ProviderID) -> SubscriptionRegime? {
    guard let id = UUID(uuidString: text(statement, 0)) else { return nil }
    return SubscriptionRegime(
      id: id,
      providerID: providerID,
      fingerprint: text(statement, 1),
      planName: optionalText(statement, 2),
      startedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3)),
      endedAt: optionalDate(statement, 4),
      createdManually: sqlite3_column_int(statement, 5) != 0,
      returningPlanNeedsValidation: sqlite3_column_int(statement, 6) != 0,
      completedWindowsSinceReturn: Int(sqlite3_column_int(statement, 7))
    )
  }

  private func closeRegime(_ id: UUID, at date: Date) throws {
    try withStatement("UPDATE regimes SET ended_at = ? WHERE id = ?") { statement in
      bind(date.timeIntervalSince1970, to: 1, in: statement)
      bind(id.uuidString, to: 2, in: statement)
      try stepDone(statement)
    }
  }

  private func metaValue(for key: String) throws -> String? {
    try withStatement("SELECT value FROM metadata WHERE key = ?") { statement in
      bind(key, to: 1, in: statement)
      return sqlite3_step(statement) == SQLITE_ROW ? optionalText(statement, 0) : nil
    }
  }

  private func setMeta(_ value: String, for key: String) throws {
    try withStatement("INSERT OR REPLACE INTO metadata (key, value) VALUES (?, ?)") { statement in
      bind(key, to: 1, in: statement)
      bind(value, to: 2, in: statement)
      try stepDone(statement)
    }
  }

  private func scalarInt(
    _ sql: String,
    bind bindings: (OpaquePointer) throws -> Void
  ) throws -> Int {
    try withStatement(sql) { statement in
      try bindings(statement)
      guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
      return Int(sqlite3_column_int64(statement, 0))
    }
  }

  private func transaction<T>(_ body: () throws -> T) throws -> T {
    try execute("BEGIN IMMEDIATE")
    do {
      let value = try body()
      try execute("COMMIT")
      return value
    } catch {
      try? execute("ROLLBACK")
      throw error
    }
  }

  private func execute(_ sql: String) throws {
    guard let connection else { throw HistoryDatabaseError.open("Database is not prepared") }
    var error: UnsafeMutablePointer<CChar>?
    guard sqlite3_exec(connection, sql, nil, nil, &error) == SQLITE_OK else {
      let message = error.map { String(cString: $0) } ?? errorMessage(connection)
      sqlite3_free(error)
      throw HistoryDatabaseError.step(message)
    }
  }

  private func withStatement<T>(_ sql: String, body: (OpaquePointer) throws -> T) throws -> T {
    guard let connection else { throw HistoryDatabaseError.open("Database is not prepared") }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK,
      let statement
    else { throw HistoryDatabaseError.statement(errorMessage(connection)) }
    defer { sqlite3_finalize(statement) }
    return try body(statement)
  }

  private func stepDone(_ statement: OpaquePointer) throws {
    guard sqlite3_step(statement) == SQLITE_DONE else {
      throw HistoryDatabaseError.step(connection.map(errorMessage) ?? "Unknown SQLite error")
    }
  }

  private func errorMessage(_ database: OpaquePointer) -> String {
    String(cString: sqlite3_errmsg(database))
  }

  private func bind(_ value: String?, to index: Int32, in statement: OpaquePointer) {
    guard let value else { sqlite3_bind_null(statement, index); return }
    sqlite3_bind_text(statement, index, value, -1, Self.sqliteTransient)
  }

  private func bind(_ value: Double?, to index: Int32, in statement: OpaquePointer) {
    guard let value else { sqlite3_bind_null(statement, index); return }
    sqlite3_bind_double(statement, index, value)
  }

  private func bind(_ value: Int, to index: Int32, in statement: OpaquePointer) {
    sqlite3_bind_int64(statement, index, sqlite3_int64(value))
  }

  private func text(_ statement: OpaquePointer, _ column: Int32) -> String {
    optionalText(statement, column) ?? ""
  }

  private func optionalText(_ statement: OpaquePointer, _ column: Int32) -> String? {
    guard sqlite3_column_type(statement, column) != SQLITE_NULL,
      let value = sqlite3_column_text(statement, column)
    else { return nil }
    return String(cString: value)
  }

  private func optionalUUID(_ statement: OpaquePointer, _ column: Int32) -> UUID? {
    optionalText(statement, column).flatMap(UUID.init)
  }

  private func optionalDate(_ statement: OpaquePointer, _ column: Int32) -> Date? {
    sqlite3_column_type(statement, column) == SQLITE_NULL
      ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, column))
  }

  private static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

  private static let schema = """
    CREATE TABLE IF NOT EXISTS metadata (
      key TEXT PRIMARY KEY,
      value TEXT NOT NULL
    );
    CREATE TABLE IF NOT EXISTS regimes (
      id TEXT PRIMARY KEY,
      provider TEXT NOT NULL,
      fingerprint TEXT NOT NULL,
      plan_name TEXT,
      started_at REAL NOT NULL,
      ended_at REAL,
      manual INTEGER NOT NULL DEFAULT 0,
      returning_validation INTEGER NOT NULL DEFAULT 0,
      completed_since_return INTEGER NOT NULL DEFAULT 0
    );
    CREATE TABLE IF NOT EXISTS window_instances (
      id TEXT PRIMARY KEY,
      provider TEXT NOT NULL,
      series_key TEXT NOT NULL,
      pool_id TEXT NOT NULL,
      window_id TEXT NOT NULL,
      kind TEXT NOT NULL,
      start REAL NOT NULL,
      end REAL NOT NULL,
      quota_total REAL NOT NULL,
      quota_metadata TEXT,
      regime_id TEXT,
      plan_name TEXT,
      coverage REAL NOT NULL DEFAULT 0,
      FOREIGN KEY(regime_id) REFERENCES regimes(id)
    );
    CREATE TABLE IF NOT EXISTS usage_samples (
      id TEXT PRIMARY KEY,
      provider TEXT NOT NULL,
      series_key TEXT NOT NULL,
      pool_id TEXT NOT NULL,
      window_id TEXT NOT NULL,
      timestamp REAL NOT NULL,
      remaining REAL NOT NULL,
      pace_delta REAL,
      regime_id TEXT,
      window_instance_id TEXT,
      FOREIGN KEY(regime_id) REFERENCES regimes(id),
      FOREIGN KEY(window_instance_id) REFERENCES window_instances(id)
    );
    CREATE TABLE IF NOT EXISTS refresh_events (
      id TEXT PRIMARY KEY,
      provider TEXT NOT NULL,
      timestamp REAL NOT NULL,
      duration REAL NOT NULL,
      source TEXT,
      succeeded INTEGER NOT NULL,
      failure_category TEXT,
      stale_duration REAL NOT NULL DEFAULT 0
    );
    CREATE TABLE IF NOT EXISTS anomalies (
      id TEXT PRIMARY KEY,
      provider TEXT NOT NULL,
      series_key TEXT,
      kind TEXT NOT NULL,
      detected_at REAL NOT NULL,
      confirmed_at REAL,
      resolved_at REAL,
      detail TEXT NOT NULL,
      alertable INTEGER NOT NULL DEFAULT 0
    );
    CREATE INDEX IF NOT EXISTS idx_samples_series_time
      ON usage_samples(provider, series_key, timestamp);
    CREATE INDEX IF NOT EXISTS idx_samples_regime_time
      ON usage_samples(regime_id, timestamp);
    CREATE INDEX IF NOT EXISTS idx_samples_window_instance
      ON usage_samples(window_instance_id);
    CREATE INDEX IF NOT EXISTS idx_windows_series_end
      ON window_instances(provider, series_key, end);
    CREATE INDEX IF NOT EXISTS idx_windows_regime_end
      ON window_instances(regime_id, end);
    CREATE INDEX IF NOT EXISTS idx_windows_provider_end_coverage
      ON window_instances(provider, end, coverage);
    CREATE INDEX IF NOT EXISTS idx_regimes_provider_active
      ON regimes(provider, ended_at);
    CREATE INDEX IF NOT EXISTS idx_refresh_provider_time
      ON refresh_events(provider, timestamp);
    CREATE INDEX IF NOT EXISTS idx_anomalies_provider_active
      ON anomalies(provider, resolved_at);
    """
}
