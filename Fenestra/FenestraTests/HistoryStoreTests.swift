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
