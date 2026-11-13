import AppKit
import CodexBarCore
import Foundation
import Observation

enum PaceUrgency: Comparable, Sendable {
  case unknown
  case good
  case warning
  case critical

  static func < (lhs: PaceUrgency, rhs: PaceUrgency) -> Bool {
    rank(lhs) < rank(rhs)
  }

  private static func rank(_ value: PaceUrgency) -> Int {
    switch value {
    case .unknown: 0
    case .good: 1
    case .warning: 2
    case .critical: 3
    }
  }
}

@Observable
@MainActor
final class FenestraStore {
  let settings = AppSettings()
  let history = HistoryStore()

  private(set) var states: [ProviderID: ProviderDisplayState] = Dictionary(
    uniqueKeysWithValues: ProviderID.allCases.map { ($0, ProviderDisplayState()) }
  )
  private(set) var healthSummaries: [ProviderID: ProviderHealthSummary] = [:]
  var selectedProvider: ProviderID = .claudeCode
  var providerToConfigure: ProviderID?

  @ObservationIgnored private let notificationManager = NotificationManager()
  @ObservationIgnored private var providers: [ProviderID: any UsageProvider] = [:]
  @ObservationIgnored private var pollingTasks: [ProviderID: Task<Void, Never>] = [:]
  @ObservationIgnored private var activeRefreshes: Set<ProviderID> = []
  @ObservationIgnored private var pendingRefreshes: [ProviderID: Bool] = [:]
  @ObservationIgnored private var wakeTask: Task<Void, Never>?
  @ObservationIgnored private var settingsChangeTask: Task<Void, Never>?
  @ObservationIgnored private var claudeProjectsWatcher: ClaudeProjectsWatcher?
  @ObservationIgnored private var hasStarted = false
  @ObservationIgnored private var userSelectedProvider = false
  @ObservationIgnored private var anomalyDetector = AnomalyDetector()

  func start() async {
    guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else {
      return
    }
    guard !hasStarted else { return }
    hasStarted = true

    settings.load()
    if settings.isEnabled(settings.lastSelectedProvider) {
      selectedProvider = settings.lastSelectedProvider
      userSelectedProvider = true
    }
    await history.loadAndPrune()
    configureProviders()
    restartClaudeProjectsWatcher()
    settings.onChange = { [weak self] in
      self?.settingsDidChange()
    }
    if settings.notificationsEnabled {
      await notificationManager.requestAuthorizationIfNeeded()
    }
    startWakeObservation()
    restartPolling()
    await refreshAll()
  }

  func state(for providerID: ProviderID) -> ProviderDisplayState {
    states[providerID] ?? ProviderDisplayState()
  }

  func select(_ providerID: ProviderID) {
    selectedProvider = providerID
    userSelectedProvider = true
    settings.lastSelectedProvider = providerID
  }

  func refreshAll() async {
    let tasks: [Task<Void, Never>] = settings.enabledProviders.map { providerID in
      Task { [weak self] in
        guard let self else { return }
        await self.refresh(providerID)
      }
    }
    for task in tasks {
      await task.value
    }
    chooseUrgentProviderIfNeeded()
  }

  func refresh(_ providerID: ProviderID, force: Bool = false) async {
    guard settings.isEnabled(providerID),
      let provider = providers[providerID]
    else {
      return
    }
    guard activeRefreshes.insert(providerID).inserted else {
      pendingRefreshes[providerID] = (pendingRefreshes[providerID] ?? false) || force
      return
    }
    defer {
      activeRefreshes.remove(providerID)
      if let pendingForce = pendingRefreshes.removeValue(forKey: providerID) {
        Task { [weak self] in
          await self?.refresh(providerID, force: pendingForce)
        }
      }
    }

    if force {
      invalidateProviderCaches(for: providerID)
    }

    var state = states[providerID] ?? ProviderDisplayState()
    if force || state.snapshot == nil {
      state.availability = .loading
    }
    states[providerID] = state

    let refreshStarted = Date()
    do {
      let interaction: ProviderInteraction = force ? .userInitiated : .background
      let snapshot = try await ProviderInteractionContext.$current.withValue(interaction) {
        try await provider.currentSnapshot()
      }
      states[providerID] = ProviderDisplayState(
        snapshot: snapshot,
        availability: .available
      )
      await history.append(snapshot)
      let anomalies = anomalyDetector.evaluate(
        snapshot: snapshot,
        history: history.points,
        refreshCadence: settings.cadence(for: providerID).duration ?? 5 * 60
      )
      await history.saveAnomalies(anomalies)
      await history.recordRefresh(
        ProviderRefreshEvent(
          id: UUID(),
          providerID: providerID,
          timestamp: snapshot.freshness,
          duration: Date().timeIntervalSince(refreshStarted),
          source: snapshot.sourceDescription,
          succeeded: true,
          failureCategory: nil,
          staleDuration: 0
        )
      )
      await updateHealth(providerID: providerID)
      await notificationManager.evaluate(
        snapshot: snapshot,
        history: history,
        settings: settings
      )
    } catch {
      let message =
        (error as? LocalizedError)?.errorDescription
        ?? error.localizedDescription
      LocalLog.record("\(providerID.displayName) refresh failed: \(message)")
      states[providerID] = ProviderDisplayState(
        snapshot: state.snapshot,
        availability: .unavailable(message)
      )
      let staleDuration = state.snapshot.map {
        max(0, Date().timeIntervalSince($0.freshness))
      } ?? 0
      await history.recordRefresh(
        ProviderRefreshEvent(
          id: UUID(),
          providerID: providerID,
          timestamp: Date(),
          duration: Date().timeIntervalSince(refreshStarted),
          source: state.snapshot?.sourceDescription,
          succeeded: false,
          failureCategory: Self.failureCategory(error),
          staleDuration: staleDuration
        )
      )
      let anomalies = anomalyDetector.recordFailure(
        providerID: providerID,
        at: Date(),
        staleDuration: staleDuration
      )
      await history.saveAnomalies(anomalies)
      await updateHealth(providerID: providerID)
    }
    chooseUrgentProviderIfNeeded()
  }

  func openAntigravity() async {
    let bundleIdentifiers = [
      "com.google.antigravity",
      "com.google.antigravity-ide",
    ]
    guard
      let applicationURL = bundleIdentifiers.lazy.compactMap({
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0)
      }).first
    else {
      states[.antigravity] = ProviderDisplayState(
        availability: .unavailable("Antigravity: app not installed")
      )
      return
    }

    guard NSWorkspace.shared.open(applicationURL) else {
      states[.antigravity] = ProviderDisplayState(
        availability: .unavailable("Antigravity: could not open the app")
      )
      return
    }

    states[.antigravity] = ProviderDisplayState(availability: .loading)
    for delay in [2.0, 3.0, 4.0] {
      try? await Task.sleep(for: .seconds(delay))
      guard !Task.isCancelled else { return }
      await refresh(.antigravity)
      if states[.antigravity]?.availability == .available {
        return
      }
    }
  }

  func authorizeClaudeKeychainAccess() async {
    states[.claudeCode] = ProviderDisplayState(availability: .loading)
    do {
      try ClaudeCredentialStore.authorizeKeychainAccess()
      await refresh(.claudeCode)
    } catch {
      let message =
        (error as? LocalizedError)?.errorDescription
        ?? error.localizedDescription
      states[.claudeCode] = ProviderDisplayState(
        availability: .unavailable(message)
      )
    }
  }

  func authorizeCursorBrowserAccess() async {
    states[.cursor] = ProviderDisplayState(availability: .loading)
    await refresh(.cursor, force: true)
  }

  func paceEvaluation(
    providerID: ProviderID,
    pool: UsagePoolSnapshot,
    window: UsageWindowSnapshot,
    at date: Date
  ) -> PaceEvaluation? {
    PaceCalculator.evaluate(window: window, at: date)
  }

  /// One headline quota for a provider. By default its shortest window, preferring main
  /// Codex limits over separate model quotas such as Spark. With `limiting`, the main
  /// window furthest over pace instead, falling back to the shortest when no pace is known.
  func quotaSummary(for providerID: ProviderID, limiting: Bool = false) -> UrgentQuotaSummary? {
    guard settings.isEnabled(providerID), let snapshot = states[providerID]?.snapshot else {
      return nil
    }
    let candidates = snapshot.pools.flatMap { pool in
      pool.windows.map { window in
        (pool: pool, window: window,
         evaluation: paceEvaluation(providerID: providerID, pool: pool, window: window,
                                    at: snapshot.freshness))
      }
    }
    let tightest = limiting
      ? candidates.filter { !$0.window.isSupplementary && $0.evaluation != nil }
          .min { ($0.evaluation?.delta ?? 0) < ($1.evaluation?.delta ?? 0) }
      : nil
    // min(by:) keeps the first of equal-ranked windows, preserving provider window order.
    guard
      let choice = tightest ?? candidates.min(by: {
        Self.menuWindowRank($0.window) < Self.menuWindowRank($1.window)
      })
    else {
      return nil
    }
    return UrgentQuotaSummary(
      providerID: providerID,
      poolName: choice.pool.name,
      windowName: choice.window.label,
      remainingPercent: choice.window.remainingPercent,
      paceDelta: choice.evaluation?.delta,
      prediction: choice.evaluation?.exhaustionPrediction,
      reset: choice.window.windowEnd,
      windowKind: choice.window.kind
    )
  }

  /// What the menu bar shows: the selected provider, or (opt-in) the fresh provider
  /// furthest over pace. Stale readings never drive the choice.
  var menuQuota: UrgentQuotaSummary? {
    let selected = quotaSummary(for: selectedProvider)
    guard settings.menuBarFollowsMostUrgent else { return selected }
    return Self.mostUrgent(
      settings.enabledProviders.filter { !isStale($0) }
        .compactMap { quotaSummary(for: $0, limiting: true) }
    ) ?? selected
  }

  static func mostUrgent(_ summaries: [UrgentQuotaSummary]) -> UrgentQuotaSummary? {
    summaries.filter { $0.paceDelta != nil }
      .min { ($0.paceDelta ?? 0) < ($1.paceDelta ?? 0) }
  }

  var menuUrgency: PaceUrgency {
    Self.urgency(delta: menuQuota?.paceDelta)
  }

  /// Main Codex limits precede extra model quotas. Within each group, measured
  /// windows sort by duration; the rest fall back to 5-hour, weekly, then monthly.
  nonisolated static func menuWindowRank(_ window: UsageWindowSnapshot) -> (Int, Int, Double) {
    let modelQuota = window.isSupplementary ? 1 : 0
    if window.hasKnownTimeline, let start = window.windowStart, let end = window.windowEnd {
      return (modelQuota, 0, end.timeIntervalSince(start))
    }
    let fallback: Double =
      switch window.kind {
      case .fiveHour: 0
      case .weekly: 1
      case .monthly: 2
      case .other: 3
      }
    return (modelQuota, 1, fallback)
  }

  private static func urgency(delta: Double?) -> PaceUrgency {
    guard let delta else { return .unknown }
    if delta < -25 { return .critical }
    if delta < -10 { return .warning }
    return .good
  }

  var urgency: PaceUrgency {
    Self.urgency(delta: allPaceDeltas().map(\.delta).min())
  }

  func isStale(_ providerID: ProviderID, at date: Date = .now) -> Bool {
    state(for: providerID).isStale(at: date, cadence: settings.cadence(for: providerID).duration)
  }

  /// A provider is only as usable as its tightest main quota; model extras are separate.
  static func limitingPace(_ snapshot: UsageSnapshot, at date: Date) -> Double? {
    let windows = snapshot.mainWindows
    guard !windows.isEmpty else { return nil }
    var deltas: [Double] = []
    for window in windows {
      guard window.remainingPercent > 0,
        let start = window.windowStart, let end = window.windowEnd,
        start <= date, date < end,
        let delta = PaceCalculator.delta(remainingPercent: window.remainingPercent,
                                        at: snapshot.freshness, windowStart: start, windowEnd: end)
      else { return nil }
      deltas.append(delta)
    }
    return deltas.min()
  }

  var smartSuggestion: (text: String, target: ProviderID?) {
    let now = Date()
    let candidates = settings.enabledProviders.compactMap {
      provider -> (provider: ProviderID, delta: Double)? in
      guard !isStale(provider, at: now), let snapshot = states[provider]?.snapshot,
        let delta = Self.limitingPace(snapshot, at: now)
      else { return nil }
      return (provider, delta)
    }
    return Self.suggestion(candidates, selected: selectedProvider)
  }

  /// Names the provider with the most main-quota headroom and by how much. `target` is
  /// set only when that is a different provider worth switching to.
  static func suggestion(
    _ candidates: [(provider: ProviderID, delta: Double)], selected: ProviderID
  ) -> (text: String, target: ProviderID?) {
    guard candidates.count >= 2, let best = candidates.max(by: { $0.delta < $1.delta }) else {
      return ("Not enough fresh quotas to compare", nil)
    }
    let name = best.provider.displayName
    let pace = PaceEvaluation(idealRemaining: 0, delta: best.delta, exhaustionPrediction: nil)
      .label.lowercased()
    let target = best.provider == selected ? nil : best.provider
    if best.delta < -10 {
      return ("Every quota is over pace · \(name) is least behind (\(pace))", target)
    }
    if target == nil { return ("\(name) has the most headroom (\(pace))", nil) }
    return ("Switch to \(name) · most headroom (\(pace))", target)
  }

  func historyPoints(
    providerID: ProviderID,
    poolID: String,
    windowID: String,
    since: Date?
  ) -> [HistoryPoint] {
    history.points(
      providerID: providerID,
      poolID: poolID,
      windowID: windowID,
      since: since
    )
  }

  func startNewUsageProfile() async {
    await history.startNewProfile(providerID: selectedProvider)
    if let snapshot = states[selectedProvider]?.snapshot {
      await history.append(snapshot)
      await updateHealth(providerID: selectedProvider)
    }
  }

  func clearLearnedAndHistoryData() async {
    await history.clearAll()
    healthSummaries = [:]
  }

  func privacySafeDiagnosticsJSON() async -> Data {
    let payload = await history.exportPayload()
    let providers: [[String: Any]] = ProviderID.allCases.map { providerID in
      let health = healthSummaries[providerID]
      return [
        "provider": providerID.rawValue,
        "enabled": settings.isEnabled(providerID),
        "cadenceSeconds": settings.cadence(for: providerID).rawValue,
        "configuredSource": settings.connectionConfiguration(for: providerID).source.rawValue,
        "currentState": availabilityLabel(states[providerID]?.availability ?? .idle),
        "source": states[providerID]?.snapshot?.sourceDescription ?? NSNull(),
        "lastSuccess": health?.lastSuccess?.timeIntervalSince1970 ?? NSNull(),
        "sevenDaySuccessRate": health?.sevenDaySuccessRate ?? NSNull(),
        "medianRefreshLatency": health?.medianRefreshLatency ?? NSNull(),
        "staleDuration": health?.staleDuration ?? 0,
      ]
    }
    let failures = payload?.refreshEvents.compactMap(\.failureCategory?.rawValue) ?? []
    let object: [String: Any] = [
      "generatedAt": ISO8601DateFormatter().string(from: Date()),
      "appVersion": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development",
      "osVersion": ProcessInfo.processInfo.operatingSystemVersionString,
      "databaseAvailable": history.databaseAvailable,
      "providers": providers,
      "refreshFailureCategories": Dictionary(grouping: failures, by: { $0 }).mapValues(\.count),
      "activeAnomalies": history.activeAnomalies.map {
        ["provider": $0.providerID.rawValue, "kind": $0.kind.rawValue, "detail": $0.detail]
      },
    ]
    return (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]))
      ?? Data("{}".utf8)
  }

  private func availabilityLabel(_ availability: ProviderAvailability) -> String {
    switch availability {
    case .idle: "waiting"
    case .loading: "refreshing"
    case .available: "connected"
    case .unavailable: "unavailable"
    }
  }

  private func settingsDidChange() {
    settingsChangeTask?.cancel()
    settingsChangeTask = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(300))
      guard !Task.isCancelled else { return }
      self?.applySettingsChange()
    }
  }

  private func applySettingsChange() {
    configureProviders()
    restartClaudeProjectsWatcher()
    restartPolling()
    if !settings.isEnabled(selectedProvider) {
      selectedProvider = settings.enabledProviders.first ?? .claudeCode
      userSelectedProvider = false
    }
    Task {
      if settings.notificationsEnabled {
        await notificationManager.requestAuthorizationIfNeeded()
      }
      await refreshAll()
    }
  }

  private func configureProviders() {
    var configured: [ProviderID: any UsageProvider] = [:]
    for providerID in ProviderID.allCases {
      let provider =
        (providers[providerID] as? CodexBarProvider)
        ?? CodexBarProvider(id: providerID)
      provider.connectionConfiguration = settings.connectionConfiguration(for: providerID)
      if providerID == .claudeCode {
        provider.manualWeeklyReset = settings.manualClaudeWeeklyReset
        provider.cacheAnalysisInterval = settings.claudeCachePollCadence.duration
      }
      configured[providerID] = provider
    }
    providers = configured
  }

  private func restartPolling() {
    for task in pollingTasks.values {
      task.cancel()
    }
    pollingTasks.removeAll()
    for providerID in settings.enabledProviders {
      guard let interval = settings.cadence(for: providerID).duration else { continue }
      pollingTasks[providerID] = Task { [weak self] in
        var failures = 0
        while !Task.isCancelled {
          // ponytail: a source that keeps failing (e.g. Antigravity closed, which makes the
          // core boot the `agy` backend every poll) backs off 2x per failure up to 16x, capped
          // at 15 min. Wake, user refresh, and "Open Antigravity" still refresh immediately.
          let delay = min(interval * Double(1 << min(failures, 4)), max(interval, 15 * 60))
          try? await Task.sleep(for: .seconds(delay))
          guard !Task.isCancelled, let self else { return }
          await self.refresh(providerID)
          if case .unavailable = self.states[providerID]?.availability {
            failures += 1
          } else {
            failures = 0
          }
        }
      }
    }
  }

  private func restartClaudeProjectsWatcher() {
    claudeProjectsWatcher?.stop()
    claudeProjectsWatcher = nil
    guard settings.isEnabled(.claudeCode) else { return }
    let projectsURL = FileManager.default.homeDirectoryForCurrentUser
      .appending(path: ".claude/projects")
    let watcher = ClaudeProjectsWatcher(
      projectsURL: projectsURL,
      backstopInterval: settings.claudeCachePollCadence.duration
    ) { [weak self] in
      Task { @MainActor in
        guard let self,
          let provider = self.providers[.claudeCode] as? CodexBarProvider
        else {
          return
        }
        let hitRate = await provider.refreshCacheAnalysis()
        self.updateClaudeCacheHitRate(hitRate)
      }
    }
    claudeProjectsWatcher = watcher
    watcher.start()
  }

  private func startWakeObservation() {
    wakeTask?.cancel()
    wakeTask = Task { [weak self] in
      for await _ in NSWorkspace.shared.notificationCenter.notifications(
        named: NSWorkspace.didWakeNotification
      ) {
        guard !Task.isCancelled else { return }
        await self?.refreshAll()
      }
    }
  }

  private func chooseUrgentProviderIfNeeded() {
    guard !userSelectedProvider else { return }
    let byProvider = Dictionary(grouping: allPaceDeltas(), by: \.providerID)
      .compactMapValues { values in values.map(\.delta).min() }
    if let mostUrgent = byProvider.min(by: { $0.value < $1.value })?.key {
      selectedProvider = mostUrgent
    } else if !settings.isEnabled(selectedProvider) {
      selectedProvider = settings.enabledProviders.first ?? .claudeCode
    }
  }

  private func allPaceDeltas() -> [(providerID: ProviderID, delta: Double)] {
    settings.enabledProviders.flatMap {
      providerID -> [(providerID: ProviderID, delta: Double)] in
      guard let snapshot = states[providerID]?.snapshot else { return [] }
      return snapshot.pools.flatMap { pool in
        pool.windows.compactMap { window in
          PaceCalculator.delta(
            remainingPercent: window.remainingPercent,
            at: snapshot.freshness,
            windowStart: window.windowStart,
            windowEnd: window.windowEnd
          ).map { (providerID, $0) }
        }
      }
    }
  }

  private func updateHealth(providerID: ProviderID) async {
    let snapshot = states[providerID]?.snapshot
    healthSummaries[providerID] = await history.healthSummary(
      providerID: providerID,
      source: snapshot?.sourceDescription,
      staleDuration: snapshot.map { max(0, Date().timeIntervalSince($0.freshness)) } ?? 0
    )
  }

  private static func failureCategory(_ error: Error) -> RefreshFailureCategory {
    let message = error.localizedDescription.lowercased()
    if message.contains("auth") || message.contains("keychain") || message.contains("credential") {
      return .authentication
    }
    if message.contains("rate") || message.contains("429") { return .rateLimited }
    if message.contains("network") || message.contains("offline") || message.contains("timed out") {
      return .network
    }
    if message.contains("parse") || message.contains("decode") { return .parsing }
    if message.contains("unavailable") { return .unavailable }
    return .unknown
  }

  private func updateClaudeCacheHitRate(_ hitRate: Double?) {
    guard var state = states[.claudeCode],
      let snapshot = state.snapshot,
      snapshot.cacheHitRate != hitRate
    else {
      return
    }
    state.snapshot = UsageSnapshot(
      providerID: snapshot.providerID,
      displayName: snapshot.displayName,
      pools: snapshot.pools,
      freshness: snapshot.freshness,
      sourceDescription: snapshot.sourceDescription,
      cacheHitRate: hitRate,
      accountDescription: snapshot.accountDescription,
      planDescription: snapshot.planDescription,
      notes: snapshot.notes
    )
    states[.claudeCode] = state
  }

  private func invalidateProviderCaches(for providerID: ProviderID) {
    switch providerID {
    case .antigravity:
      AntigravityCloudFallback.invalidateCachedToken()
    case .claudeCode:
      KeychainReader.invalidate(service: "Claude Code-credentials")
      ClaudeUsageRateLimitGate().allowManualRetry()
    case .cursor:
      KeychainReader.invalidate(service: "Chrome Safe Storage")
      KeychainReader.invalidate(service: "Microsoft Edge Safe Storage")
    case .codex:
      break
    default:
      break
    }
  }

  #if DEBUG
    static func preview(
      selectedProvider: ProviderID = .codex,
      state: ProviderDisplayState = ProviderDisplayState()
    ) -> FenestraStore {
      let store = FenestraStore()
      store.hasStarted = true
      store.selectedProvider = selectedProvider
      store.states[selectedProvider] = state
      return store
    }

    static func emptyPreview() -> FenestraStore {
      let store = preview()
      for provider in ProviderID.allCases {
        store.settings.setEnabled(false, for: provider)
      }
      return store
    }
  #endif
}
