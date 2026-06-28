import AppKit
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
  var selectedProvider: ProviderID = .claudeCode

  @ObservationIgnored private let notificationManager = NotificationManager()
  @ObservationIgnored private var providers: [ProviderID: any UsageProvider] = [:]
  @ObservationIgnored private var pollingTasks: [ProviderID: Task<Void, Never>] = [:]
  @ObservationIgnored private var activeRefreshes: Set<ProviderID> = []
  @ObservationIgnored private var pendingRefreshes: Set<ProviderID> = []
  @ObservationIgnored private var wakeTask: Task<Void, Never>?
  @ObservationIgnored private var settingsChangeTask: Task<Void, Never>?
  @ObservationIgnored private var claudeProjectsWatcher: ClaudeProjectsWatcher?
  @ObservationIgnored private var hasStarted = false
  @ObservationIgnored private var userSelectedProvider = false

  func start() async {
    guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else {
      return
    }
    guard !hasStarted else { return }
    hasStarted = true

    settings.load()
    history.loadAndPrune()
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
      pendingRefreshes.insert(providerID)
      return
    }
    defer {
      activeRefreshes.remove(providerID)
      if pendingRefreshes.remove(providerID) != nil {
        Task { [weak self] in
          await self?.refresh(providerID, force: force)
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

    do {
      let snapshot = try await provider.currentSnapshot()
      history.append(snapshot)
      states[providerID] = ProviderDisplayState(
        snapshot: snapshot,
        availability: .available
      )
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
    do {
      guard let cursor = providers[.cursor] as? CursorProvider else {
        throw ProviderFailure.unavailable("Cursor: provider unavailable")
      }
      try cursor.authorizeBrowserKeychainAccess()
      await refresh(.cursor)
    } catch {
      let message =
        (error as? LocalizedError)?.errorDescription
        ?? error.localizedDescription
      states[.cursor] = ProviderDisplayState(
        availability: .unavailable(message)
      )
    }
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
      now: date
    )
    return PaceCalculator.evaluate(window: window, at: date, recentHistory: recent)
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
    let claude = (providers[.claudeCode] as? ClaudeCodeProvider) ?? ClaudeCodeProvider()
    claude.manualWeeklyReset = settings.manualClaudeWeeklyReset
    claude.cacheAnalysisInterval = settings.claudeCachePollCadence.duration

    let codex = (providers[.codex] as? CodexProvider) ?? CodexProvider()

    let antigravity =
      (providers[.antigravity] as? AntigravityProvider)
      ?? AntigravityProvider()

    let cursor = (providers[.cursor] as? CursorProvider) ?? CursorProvider()
    cursor.allowBrowserKeychainAccess = settings.cursorBrowserAccessEnabled

    providers = [
      .claudeCode: claude,
      .codex: codex,
      .antigravity: antigravity,
      .cursor: cursor,
    ]
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
    guard settings.claudeEnabled else { return }
    let projectsURL = FileManager.default.homeDirectoryForCurrentUser
      .appending(path: ".claude/projects")
    let watcher = ClaudeProjectsWatcher(
      projectsURL: projectsURL,
      backstopInterval: settings.claudeCachePollCadence.duration
    ) { [weak self] in
      Task { @MainActor in
        await ClaudeCacheAnalyzer.shared.markDirty(projectsURL: projectsURL)
        await self?.refresh(.claudeCode)
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

  private func invalidateProviderCaches(for providerID: ProviderID) {
    switch providerID {
    case .antigravity:
      AntigravityCloudFallback.invalidateCachedToken()
    case .claudeCode:
      KeychainReader.invalidate(service: "Claude Code-credentials")
    case .cursor:
      KeychainReader.invalidate(service: "Chrome Safe Storage")
      KeychainReader.invalidate(service: "Microsoft Edge Safe Storage")
    case .codex:
      break
    }
  }
}
