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
  @ObservationIgnored private var personalizedPredictions: [String: ExhaustionPrediction] = [:]
  @ObservationIgnored private var anomalyDetector = AnomalyDetector()

  func start() async {
    guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else {
      return
    }
    guard !hasStarted else { return }
    hasStarted = true

    settings.load()
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
      await history.append(snapshot)
      await updatePersonalizedPredictions(snapshot: snapshot)
      states[providerID] = ProviderDisplayState(
        snapshot: snapshot,
        availability: .available
      )
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
        settings: settings,
        predictions: personalizedPredictions
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
    let recent = history.recentPoints(
      providerID: providerID,
      poolID: pool.id,
      windowID: window.id,
      now: date,
      lookback: 2 * 60 * 60
    )
    guard let baseline = PaceCalculator.evaluate(window: window, at: date, recentHistory: recent)
    else { return nil }
    let prediction = personalizedPredictions[
      predictionKey(providerID: providerID, poolID: pool.id, windowID: window.id)
    ] ?? baseline.exhaustionPrediction
    return PaceEvaluation(
      idealRemaining: baseline.idealRemaining,
      delta: baseline.delta,
      exhaustionPrediction: prediction
    )
  }

  var urgentQuota: UrgentQuotaSummary? {
    let candidates = settings.enabledProviders.flatMap { providerID -> [UrgentQuotaSummary] in
      guard let snapshot = states[providerID]?.snapshot else { return [] }
      return snapshot.pools.flatMap { pool in
        pool.windows.map { window in
          let evaluation = paceEvaluation(
            providerID: providerID,
            pool: pool,
            window: window,
            at: snapshot.freshness
          )
          return UrgentQuotaSummary(
            providerID: providerID,
            poolName: pool.name,
            windowName: window.label,
            remainingPercent: window.remainingPercent,
            paceDelta: evaluation?.delta,
            prediction: evaluation?.exhaustionPrediction,
            reset: window.windowEnd
          )
        }
      }
    }
    return candidates.max { urgencyScore($0) < urgencyScore($1) }
  }

  var resetTimeline: [ResetTimelineItem] {
    settings.enabledProviders.flatMap { providerID -> [ResetTimelineItem] in
      guard let snapshot = states[providerID]?.snapshot else { return [] }
      return snapshot.pools.flatMap { pool in
        pool.windows.map {
          ResetTimelineItem(
            providerID: providerID,
            poolName: pool.name,
            windowName: $0.label,
            reset: $0.windowEnd
          )
        }
      }
    }.sorted {
      switch ($0.reset, $1.reset) {
      case (.some(let lhs), .some(let rhs)): lhs < rhs
      case (.some, .none): true
      case (.none, .some): false
      case (.none, .none): $0.providerID.displayName < $1.providerID.displayName
      }
    }
  }

  var urgency: PaceUrgency {
    guard let worst = allPaceDeltas().map(\.delta).min() else { return .unknown }
    if worst < -25 { return .critical }
    if worst < -10 { return .warning }
    return .good
  }

  var smartSuggestion: String {
    let deltas = allPaceDeltas()
    guard !deltas.isEmpty else { return "Pace unknown" }
    if deltas.allSatisfy({ $0.delta < -10 }) {
      return "Everything’s tight"
    }
    guard let best = deltas.max(by: { $0.delta < $1.delta }) else {
      return "Pace unknown"
    }
    return "\(best.providerID.displayName) has most headroom"
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
      await updatePersonalizedPredictions(snapshot: snapshot)
      await updateHealth(providerID: selectedProvider)
    }
  }

  func clearLearnedAndHistoryData() async {
    await history.clearAll()
    personalizedPredictions = [:]
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
    let predictionEvidence: [[String: Any]] = personalizedPredictions.map { key, prediction in
      [
        "series": key,
        "method": prediction.method.rawValue,
        "confidence": prediction.confidence.rawValue,
        "evidenceCount": prediction.evidenceCount,
        "validationErrorSeconds": prediction.validationError ?? NSNull(),
        "notificationEligible": prediction.notificationEligible,
      ]
    }
    let failures = payload?.refreshEvents.compactMap(\.failureCategory?.rawValue) ?? []
    let object: [String: Any] = [
      "generatedAt": ISO8601DateFormatter().string(from: Date()),
      "appVersion": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development",
      "osVersion": ProcessInfo.processInfo.operatingSystemVersionString,
      "databaseAvailable": history.databaseAvailable,
      "providers": providers,
      "predictionEvidence": predictionEvidence,
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
        while !Task.isCancelled {
          try? await Task.sleep(for: .seconds(interval))
          guard !Task.isCancelled else { return }
          await self?.refresh(providerID)
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

  private func updatePersonalizedPredictions(snapshot: UsageSnapshot) async {
    for pool in snapshot.pools {
      for window in pool.windows {
        let recent = history.recentPoints(
          providerID: snapshot.providerID,
          poolID: pool.id,
          windowID: window.id,
          now: snapshot.freshness,
          lookback: 2 * 60 * 60
        )
        let baseline = PaceCalculator.exhaustionPrediction(
          remainingPercent: window.remainingPercent,
          now: snapshot.freshness,
          recentHistory: recent
        )
        let key = predictionKey(
          providerID: snapshot.providerID,
          poolID: pool.id,
          windowID: window.id
        )
        guard settings.personalizedForecastingEnabled else {
          personalizedPredictions[key] = baseline
          continue
        }
        let comparable = await history.comparableWindows(
          providerID: snapshot.providerID,
          poolID: pool.id,
          windowID: window.id
        )
        personalizedPredictions[key] = PersonalizedForecaster.forecast(
          baseline: baseline,
          window: window,
          now: snapshot.freshness,
          histories: comparable,
          returningPlanNeedsValidation:
            history.activeRegimes[snapshot.providerID]?.returningPlanNeedsValidation ?? false
        )
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

  private func predictionKey(providerID: ProviderID, poolID: String, windowID: String) -> String {
    "\(providerID.rawValue)|\(poolID)|\(windowID)"
  }

  private func urgencyScore(_ quota: UrgentQuotaSummary) -> Double {
    let validatedRisk: Double
    if let prediction = quota.prediction,
      prediction.notificationEligible,
      let reset = quota.reset,
      let likely = prediction.likely,
      likely < reset
    {
      validatedRisk = 10_000 + (prediction.exhaustionProbability ?? 1) * 1_000
    } else {
      validatedRisk = 0
    }
    return validatedRisk + max(0, -(quota.paceDelta ?? 0)) * 10 + (100 - quota.remainingPercent)
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
