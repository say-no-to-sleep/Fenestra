import Foundation
import Testing

@testable import Fenestra

@Suite("History persistence")
@MainActor
struct HistoryStoreTests {
  @Test
  func coalescesSmallFrequentSamplesButKeepsSignificantChanges() async {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: "fenestra-history-\(UUID().uuidString)", directoryHint: .isDirectory)
    let fileURL = directory.appending(path: "history.json")
    defer { try? FileManager.default.removeItem(at: directory) }

    let store = HistoryStore(fileURL: fileURL)
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    await store.append(snapshot(at: start, remaining: 90))
    await store.append(snapshot(at: start.addingTimeInterval(60), remaining: 89.5))
    #expect(store.points.count == 1)

    await store.append(snapshot(at: start.addingTimeInterval(120), remaining: 88.5))
    #expect(store.points.count == 2)

    await store.append(snapshot(at: start.addingTimeInterval(12 * 60), remaining: 88.4))
    #expect(store.points.count == 3)
  }

  /// The per-series index backs every menu-bar read, so it drifting out of step with
  /// the flat array would silently feed stale pace math to the UI.
  @Test
  func seriesIndexStaysInStepWithFlatPoints() async {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: "fenestra-history-\(UUID().uuidString)", directoryHint: .isDirectory)
    let fileURL = directory.appending(path: "history.json")
    defer { try? FileManager.default.removeItem(at: directory) }

    let store = HistoryStore(fileURL: fileURL)
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    for step in 0..<5 {
      await store.append(
        snapshot(at: start.addingTimeInterval(Double(step) * 12 * 60), remaining: 90 - Double(step))
      )
    }

    let indexed = store.points(providerID: .claudeCode, poolID: "default", windowID: "five-hour")
    #expect(indexed == store.points)

    let since = start.addingTimeInterval(24 * 60)
    let recent = store.points(
      providerID: .claudeCode,
      poolID: "default",
      windowID: "five-hour",
      since: since
    )
    #expect(recent == store.points.filter { $0.timestamp >= since })
    #expect(recent.count == 3)

    // Series that were never recorded must come back empty, not fall through to everything.
    #expect(store.points(providerID: .codex, poolID: "default", windowID: "five-hour").isEmpty)
    #expect(store.points(providerID: .claudeCode, poolID: "default", windowID: "weekly").isEmpty)

    await store.clearAll()
    #expect(store.points(providerID: .claudeCode, poolID: "default", windowID: "five-hour").isEmpty)
  }

  @Test(arguments: [false, true])
  func historicalNavigationGroupsDriftingResetsAndKeepsAdjacentSessions(includeOtherRegimes: Bool) async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let database = HistoryDatabase(databaseURL: directory.appending(path: "history.sqlite"))
    let base = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970) - 3 * 24 * 3600)
    let duration: TimeInterval = 5 * 3600
    var regimeID: UUID?
    // Reproduce the existing database: each poll has its own slightly shifted window.
    for offset in [0.0, 120, 240, duration + 300] {
      let date = base.addingTimeInterval(offset)
      regimeID = try await database.record(snapshot: snapshot(at: date, remaining: 90), points: []).regime.id
    }
    let windows = try await database.historicalWindows(
      providerID: .claudeCode, seriesKey: HistoryDatabase.seriesKey(
        providerID: .claudeCode, poolID: "default", windowID: "five-hour"),
      regimeID: regimeID, includeOtherRegimes: includeOtherRegimes, limit: 2)
    #expect(windows.count == 2)
    // Keep the latest provider-supplied pair, rather than a fabricated union timeline.
    #expect(windows.last?.start == base.addingTimeInterval(180))
    #expect(windows.last?.end == base.addingTimeInterval(duration + 240))
    #expect(windows.first?.end == base.addingTimeInterval(2 * duration + 300))
  }

  @Test
  func driftingReportsOfActiveSessionAreNotOfferedAsCompleted() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let database = HistoryDatabase(databaseURL: directory.appending(path: "history.sqlite"))
    let now = Date()
    for offset in [-120.0, 120] {
      let date = now.addingTimeInterval(-5 * 3600 + offset)
      _ = try await database.record(snapshot: snapshot(at: date, remaining: 90), points: [])
    }
    let windows = try await database.historicalWindows(
      providerID: .claudeCode, seriesKey: HistoryDatabase.seriesKey(
        providerID: .claudeCode, poolID: "default", windowID: "five-hour"),
      regimeID: nil, includeOtherRegimes: true, limit: 50)
    #expect(windows.isEmpty)
  }

  /// Regression: previous sessions vanished from history when a new report overlapped them.
  @Test
  func keepsBackToBackAndEarlyResetSessionsButCollapsesIdlePlaceholders() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let database = HistoryDatabase(databaseURL: directory.appending(path: "history.sqlite"))
    let base = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970) - 4 * 24 * 3600)
    let duration: TimeInterval = 5 * 3600
    // `snapshot(at:)` reports a window starting 60s before the poll.
    let a = base
    let b = a.addingTimeInterval(duration + 59)  // starts 1s before A's reported end (Claude jitter)
    let c = b.addingTimeInterval(3600)  // Codex-style early reset while B is still open
    let idle1 = c.addingTimeInterval(duration + 3600)  // sliding windows while unused
    let idle2 = idle1.addingTimeInterval(1200)
    let e = idle2.addingTimeInterval(1200)
    var regimeID: UUID?
    for (date, remaining) in [(a, 50.0), (b, 50), (c, 50), (idle1, 100), (idle2, 100), (e, 50)] {
      let points = remaining < 100
        ? [HistoryPoint(
            providerID: .claudeCode, poolID: "default", windowID: "five-hour",
            timestamp: date, remainingPercent: remaining, paceDelta: nil)]
        : []
      regimeID = try await database.record(
        snapshot: snapshot(at: date, remaining: remaining), points: points
      ).regime.id
    }
    let windows = try await database.historicalWindows(
      providerID: .claudeCode, seriesKey: HistoryDatabase.seriesKey(
        providerID: .claudeCode, poolID: "default", windowID: "five-hour"),
      regimeID: regimeID, includeOtherRegimes: false, limit: 50)
    #expect(windows.map(\.start) == [e, c, b, a].map { $0.addingTimeInterval(-60) })
    // B's chart stops at C's reset instead of absorbing C's samples.
    #expect(windows[2].samples.map(\.timestamp) == [b])
  }

  private func snapshot(at date: Date, remaining: Double) -> UsageSnapshot {
    UsageSnapshot(
      providerID: .claudeCode,
      displayName: "Claude",
      pools: [
        UsagePoolSnapshot(
          id: "default",
          name: "Default",
          windows: [
            UsageWindowSnapshot(
              id: "five-hour",
              kind: .fiveHour,
              label: "5-hour",
              windowStart: date.addingTimeInterval(-60),
              windowEnd: date.addingTimeInterval(5 * 60 * 60),
              quotaTotal: 100,
              used: 100 - remaining,
              remainingPercent: remaining,
              resetSource: "Test",
              breakdown: []
            )
          ]
        )
      ],
      freshness: date,
      sourceDescription: "Test",
      cacheHitRate: nil,
      accountDescription: nil,
      notes: []
    )
  }
}
