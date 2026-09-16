import Foundation
import Testing

@testable import Fenestra

private func window(
  id: String,
  kind: UsageWindowKind,
  start: Date? = nil,
  end: Date? = nil,
  remainingPercent: Double = 100
) -> UsageWindowSnapshot {
  UsageWindowSnapshot(
    id: id,
    kind: kind,
    label: kind.panelLabel,
    windowStart: start,
    windowEnd: end,
    quotaTotal: 100,
    used: 100 - remainingPercent,
    remainingPercent: remainingPercent,
    resetSource: nil,
    breakdown: []
  )
}

@Suite("Menu bar window selection")
struct MenuBarWindowSelectionTests {
  private func shortest(_ windows: [UsageWindowSnapshot]) -> UsageWindowSnapshot? {
    windows.min { FenestraStore.menuWindowRank($0) < FenestraStore.menuWindowRank($1) }
  }

  @Test @MainActor
  func codexWeeklyBeatsUnusedSparkSession() {
    let now = Date()
    let weekly = window(
      id: "codex-secondary", kind: .weekly,
      start: now, end: now.addingTimeInterval(7 * 24 * 60 * 60),
      remainingPercent: 78
    )
    let spark = window(
      id: "codex-extra-spark-primary", kind: .fiveHour,
      start: now, end: now.addingTimeInterval(5 * 60 * 60)
    )

    #expect(shortest([spark, weekly])?.remainingPercent == 78)
    #expect(shortest([weekly, spark])?.id == weekly.id)
    #expect(shortest([spark])?.id == spark.id)
    let session = window(id: "codex-primary", kind: .fiveHour,
                         start: spark.windowStart, end: spark.windowEnd)
    #expect(shortest([spark, weekly, session])?.id == session.id)
    let undatedWeekly = window(id: "codex-secondary", kind: .weekly)
    #expect(shortest([spark, undatedWeekly])?.id == undatedWeekly.id)
  }

  @Test @MainActor
  func measuredSessionWindowBeatsLongerMonthlyCap() {
    let now = Date()
    let session = window(
      id: "session",
      kind: .fiveHour,
      start: now,
      end: now.addingTimeInterval(5 * 60 * 60)
    )
    let monthly = window(
      id: "monthly",
      kind: .monthly,
      start: now,
      end: now.addingTimeInterval(30 * 24 * 60 * 60)
    )

    #expect(shortest([monthly, session])?.id == "session")
  }

  @Test @MainActor
  func measuredWindowBeatsUnknownDurationWindow() {
    let now = Date()
    let monthly = window(
      id: "monthly",
      kind: .monthly,
      start: now,
      end: now.addingTimeInterval(30 * 24 * 60 * 60)
    )
    let unknown = window(id: "unknown", kind: .other)

    #expect(shortest([unknown, monthly])?.id == "monthly")
  }

  @Test @MainActor
  func unmeasuredWindowsFallBackToFiveHourThenWeeklyThenMonthly() {
    let ordered = [
      window(id: "other", kind: .other),
      window(id: "monthly", kind: .monthly),
      window(id: "weekly", kind: .weekly),
      window(id: "session", kind: .fiveHour),
    ]

    #expect(shortest(ordered)?.id == "session")
    #expect(shortest(ordered.filter { $0.id != "session" })?.id == "weekly")
    #expect(shortest([ordered[0], ordered[1]])?.id == "monthly")
  }

  @Test @MainActor
  func zeroLengthWindowIsNotTreatedAsMeasured() {
    let now = Date()
    let degenerate = window(id: "degenerate", kind: .monthly, start: now, end: now)
    let session = window(
      id: "session",
      kind: .fiveHour,
      start: now,
      end: now.addingTimeInterval(5 * 60 * 60)
    )

    #expect(shortest([degenerate, session])?.id == "session")
  }

  @Test @MainActor
  func tiedDurationsKeepProviderWindowOrder() {
    let now = Date()
    let end = now.addingTimeInterval(60 * 60)
    let first = window(id: "first", kind: .fiveHour, start: now, end: end)
    let second = window(id: "second", kind: .fiveHour, start: now, end: end)

    #expect(shortest([first, second])?.id == "first")
    #expect(shortest([second, first])?.id == "second")
  }
}

@Suite("Last selected provider persistence")
struct LastSelectedProviderTests {
  @Test @MainActor
  func lastSelectedProviderRoundTrips() throws {
    let suiteName = "FenestraTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let settings = AppSettings(defaults: defaults)
    settings.load()
    #expect(settings.lastSelectedProvider == .claudeCode)
    settings.lastSelectedProvider = .cursor

    let reloaded = AppSettings(defaults: defaults)
    reloaded.load()
    #expect(reloaded.lastSelectedProvider == .cursor)
  }
}
