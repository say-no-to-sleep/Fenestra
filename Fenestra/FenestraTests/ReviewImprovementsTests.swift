import SwiftUI
import Testing

@testable import Fenestra

@Suite("Dashboard trust and clarity")
@MainActor
struct ReviewImprovementsTests {
  private let now = Date()

  private func window(_ id: String, remaining: Double, kind: UsageWindowKind = .weekly) -> UsageWindowSnapshot {
    UsageWindowSnapshot(id: id, kind: kind, label: id.contains("extra") ? "Codex Spark Weekly" : kind.panelLabel,
      windowStart: now.addingTimeInterval(-2 * 24 * 3600),
      windowEnd: now.addingTimeInterval(5 * 24 * 3600),
      quotaTotal: 100, used: 100 - remaining, remainingPercent: remaining,
      resetSource: "Test", breakdown: [])
  }

  private func snapshot(_ windows: [UsageWindowSnapshot], at date: Date? = nil) -> UsageSnapshot {
    UsageSnapshot(providerID: .codex, displayName: "Codex",
      pools: [UsagePoolSnapshot(id: "default", name: "Default", windows: windows)],
      freshness: date ?? now, sourceDescription: "Test", cacheHitRate: nil,
      accountDescription: nil, planDescription: "prolite", notes: [])
  }

  @Test func recommendationUsesTightestMainQuotaAndIgnoresExtras() throws {
    let main = window("codex-secondary", remaining: 20)
    let extra = window("codex-extra-spark", remaining: 100)
    let expected = try #require(FenestraStore.limitingPace(snapshot([main]), at: now))
    #expect(FenestraStore.limitingPace(snapshot([extra, main]), at: now) == expected)
    #expect(FenestraStore.limitingPace(snapshot([window("codex-primary", remaining: 90), main]), at: now) == expected)
    #expect(FenestraStore.limitingPace(snapshot([extra]), at: now) == nil)
    #expect(FenestraStore.limitingPace(snapshot([window("codex-secondary", remaining: 0)]), at: now) == nil)
    #expect(FenestraStore.limitingPace(snapshot([main]), at: now.addingTimeInterval(6 * 24 * 3600)) == nil)
  }

  @Test func staleDataIncludesFailuresAgeAndPassedReset() {
    let usage = snapshot([window("codex-secondary", remaining: 78)])
    let fresh = ProviderDisplayState(snapshot: usage, availability: .available)
    #expect(!fresh.isStale(at: now, cadence: 60))
    #expect(fresh.isStale(at: now.addingTimeInterval(301), cadence: 60))
    #expect(!fresh.isStale(at: now.addingTimeInterval(901), cadence: 900))
    #expect(ProviderDisplayState(snapshot: usage, availability: .unavailable("Offline")).isStale(at: now, cadence: 900))
    #expect(ProviderDisplayState().isStale(at: now, cadence: nil))
    let expired = snapshot([window("codex-secondary", remaining: 78)], at: now.addingTimeInterval(6 * 24 * 3600))
    #expect(ProviderDisplayState(snapshot: expired, availability: .available)
      .isStale(at: expired.freshness, cadence: 900))
  }

  @Test func historySeparatesQuotasAndDoesNotInventZeroDays() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = HistoryStore(fileURL: directory.appending(path: "history.json"))
    let sampleTime = Calendar.current.startOfDay(for: now).addingTimeInterval(3600)
    await store.append(snapshot([window("weekly", remaining: 90), window("spark", remaining: 60)], at: sampleTime))
    #expect(store.dailyActivity(providerID: .codex, poolID: "default", windowID: "weekly").isEmpty)
    await store.append(snapshot([window("weekly", remaining: 80), window("spark", remaining: 30)], at: sampleTime.addingTimeInterval(1200)))
    let weekly = store.dailyActivity(providerID: .codex, poolID: "default", windowID: "weekly")
    #expect(weekly.count == 1)
    #expect(weekly.first?.amount == 10)
    #expect(store.dailyActivity(providerID: .codex, poolID: "default", windowID: "spark").first?.amount == 30)
    #expect(store.dailyActivity(providerID: .codex, poolID: "missing", windowID: "weekly").isEmpty)
    #expect(store.dailyWorstPace(providerID: .codex, poolID: "default", windowID: "weekly").count == 1)
  }

  @Test func historicalOutcomeRequiresEvidence() {
    func history(remaining: Double, timestamp: Date) -> HistoricalUsageWindow {
      HistoricalUsageWindow(id: UUID(), providerID: .codex, seriesKey: "test", poolID: "default",
        windowID: "weekly", kind: .weekly, start: now.addingTimeInterval(-7 * 24 * 3600), end: now,
        quotaTotal: 100, regimeID: nil, planName: nil, observationCoverage: 0.1,
        samples: [HistoryPoint(providerID: .codex, poolID: "default", windowID: "weekly",
                              timestamp: timestamp, remainingPercent: remaining, paceDelta: nil)])
    }
    #expect(history(remaining: 20, timestamp: now.addingTimeInterval(-3600)).outcomeLabel == "Outcome unknown")
    #expect(history(remaining: 0, timestamp: now.addingTimeInterval(-3600)).outcomeLabel == "Exhausted")
    #expect(history(remaining: 20, timestamp: now).outcomeLabel == "Quota left at reset")
    #expect(PaceEvaluation(idealRemaining: 0, delta: -0.1, exhaustionPrediction: nil).label == "On pace")
    #expect(PaceEvaluation(idealRemaining: 0, delta: -9, exhaustionPrediction: nil).label == "9 pp over pace")
    #expect(snapshot([]).displayPlan == "Pro Lite")
  }

  @Test func rendersDashboardStates() async throws {
    let usage = snapshot([window("codex-secondary", remaining: 77), window("codex-extra-spark", remaining: 100)])
    let store = FenestraStore.preview(state: ProviderDisplayState(snapshot: usage, availability: .available))
    try await render(ProviderHistoryView(store: store, onContentHeightChange: { _ in })
      .frame(width: 580, height: 600), name: "history-picker")
    let main = usage.pools[0].windows[0]
    try await render(WindowPanel(providerID: .codex, pool: usage.pools[0], window: main,
      freshness: now, history: [], evaluation: PaceEvaluation(idealRemaining: 85, delta: -8,
        exhaustionPrediction: ExhaustionPrediction(earliest: now.addingTimeInterval(24 * 3600),
          likely: now.addingTimeInterval(48 * 3600), latest: now.addingTimeInterval(72 * 3600), confidence: .medium)))
      .frame(width: 550), name: "forecast")
    try await render(DashboardView(store: store), name: "dashboard")
    try await render(DashboardView(store: store).environment(\.colorScheme, .dark), name: "dashboard-dark")
    store.settings.expandedPopover = false
    try await render(DashboardView(store: store), name: "compact")
    let stale = FenestraStore.preview(state: ProviderDisplayState(snapshot: usage, availability: .unavailable("Offline · showing saved usage")))
    try await render(DashboardView(store: stale), name: "stale")
    try await render(ActivityHistoryView(activity: [], pace: []).frame(width: 580, height: 580), name: "history-empty")
  }

  private func render<V: View>(_ content: V, name: String) async throws {
    let host = NSHostingView(rootView: content.padding(16).background(.background)
      .environment(\.colorScheme, name.contains("dark") ? .dark : .light))
    host.frame = CGRect(origin: .zero, size: host.fittingSize)
    let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    defer { window.close() }
    // Let SwiftUI mount AppKit-backed controls and scroll content before capturing.
    try await Task.sleep(for: .milliseconds(200))
    host.layoutSubtreeIfNeeded()
    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: bitmap)
    let png = try #require(bitmap.representation(using: .png, properties: [:]))
    try png.write(to: URL(fileURLWithPath: "/tmp/fenestra-review-\(name).png"))
  }
}
