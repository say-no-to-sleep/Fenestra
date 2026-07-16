import CodexBarCore
import Foundation

@MainActor
final class CodexBarProvider: UsageProvider {
  let id: ProviderID
  let displayName: String

  var connectionConfiguration = ProviderConnectionConfiguration()
  var manualWeeklyReset: Date?
  var cacheAnalysisInterval: TimeInterval?

  private let coreID: CodexBarCore.UsageProvider
  private let descriptor: ProviderDescriptor
  private let browserDetection: BrowserDetection
  private let claudeProjectsURL = FileManager.default.homeDirectoryForCurrentUser
    .appending(path: ".claude/projects")
  private static let sharedBrowserDetection = BrowserDetection()

  init(
    id: ProviderID,
    browserDetection: BrowserDetection? = nil
  ) {
    self.id = id
    self.displayName = id.displayName
    self.coreID = id.codexBarProvider
    self.descriptor = ProviderDescriptorRegistry.descriptor(for: id.codexBarProvider)
    self.browserDetection = browserDetection ?? Self.sharedBrowserDetection
  }

  func currentSnapshot() async throws -> UsageSnapshot {
    let environment = CodexBarSettingsBridge.environment(
      base: ProcessInfo.processInfo.environment,
      provider: id,
      configuration: connectionConfiguration
    )
    let context = ProviderFetchContext(
      runtime: .app,
      sourceMode: connectionConfiguration.source.codexBarValue,
      includeCredits: true,
      includeOptionalUsage: true,
      webTimeout: 60,
      webDebugDumpHTML: false,
      verbose: false,
      env: environment,
      settings: CodexBarSettingsBridge.settings(
        provider: id,
        configuration: connectionConfiguration
      ),
      fetcher: CodexBarCore.UsageFetcher(environment: environment),
      claudeFetcher: ClaudeUsageFetcher(
        browserDetection: browserDetection,
        environment: environment,
        runtime: .app,
        // ponytail: respect the user's configured source; .oauth/.auto read the
        // keychain (macOS password prompt each poll), .cli/.web don't.
        dataSource: ClaudeUsageDataSource(rawValue: connectionConfiguration.source.rawValue) ?? .oauth,
        oauthKeychainPromptCooldownEnabled: true
      ),
      browserDetection: browserDetection,
      costUsageHistoryDays: 30,
      persistsCLISessions: true,
      persistentCLISessionIdleWindow: 6 * 60
    )
    let result = try await descriptor.fetch(context: context)
    let snapshot = map(result)
    return await enrichClaudeIfNeeded(snapshot)
  }

  func refreshCacheAnalysis() async -> Double? {
    guard id == .claudeCode else { return nil }
    await ClaudeCacheAnalyzer.shared.markDirty(projectsURL: claudeProjectsURL)
    return await ClaudeCacheAnalyzer.shared.analyze(projectsURL: claudeProjectsURL).hitRate
  }

  func map(_ result: ProviderFetchResult) -> UsageSnapshot {
    let coreSnapshot = result.usage
    var windows: [UsageWindowSnapshot] = []

    // ponytail: Antigravity reports its real quotas (2 families × 5h+weekly) as 4
    // extraRateWindows; primary/secondary just duplicate them as family rollups
    // ("Gemini Models", "Claude and GPT"). Skip them so we show 4 graphs, not 6.
    let includesPrimarySecondary = id != .antigravity
    if includesPrimarySecondary, let primary = coreSnapshot.primary {
      windows.append(
        map(
          primary,
          id: "\(id.rawValue)-primary",
          label: descriptor.metadata.sessionLabel,
          source: result.sourceLabel
        ))
    }
    if includesPrimarySecondary, let secondary = coreSnapshot.secondary {
      windows.append(
        map(
          secondary,
          id: "\(id.rawValue)-secondary",
          label: descriptor.metadata.weeklyLabel,
          source: result.sourceLabel
        ))
    }
    if let tertiary = coreSnapshot.tertiary {
      windows.append(
        map(
          tertiary,
          id: "\(id.rawValue)-tertiary",
          label: descriptor.metadata.opusLabel ?? "Additional",
          source: result.sourceLabel
        ))
    }
    for extra in coreSnapshot.extraRateWindows ?? [] where extra.usageKnown {
      windows.append(
        map(
          extra.window,
          id: "\(id.rawValue)-extra-\(extra.id)",
          label: extra.title,
          source: result.sourceLabel
        ))
    }
    if id == .cursor,
      let totalIndex = windows.firstIndex(where: { $0.id == "cursor-primary" })
    {
      let total = windows[totalIndex]
      let componentIDs = Set(["cursor-secondary", "cursor-tertiary"])
      let breakdown = windows.filter { componentIDs.contains($0.id) }.map {
        UsageBreakdownItem(
          id: $0.id.replacingOccurrences(of: "cursor-", with: ""),
          label: $0.label,
          usedPercent: max(0, 100 - $0.remainingPercent)
        )
      }
      windows.removeAll { $0.id == "cursor-primary" || componentIDs.contains($0.id) }
      windows.insert(
        UsageWindowSnapshot(
          id: "cursor-monthly-v2",
          kind: .monthly,
          label: "Monthly",
          windowStart: total.windowStart,
          windowEnd: total.windowEnd,
          quotaTotal: total.quotaTotal,
          used: total.used,
          remainingPercent: total.remainingPercent,
          resetSource: total.resetSource,
          breakdown: breakdown
        ),
        at: 0
      )
    }
    if let cost = coreSnapshot.providerCost,
      cost.used.isFinite,
      cost.limit.isFinite,
      cost.limit > 0
    {
      let remainingPercent = max(0, 100 - cost.used / cost.limit * 100)
      let reset = ProviderDateParser.future(cost.resetsAt, after: coreSnapshot.updatedAt)
      windows.append(
        UsageWindowSnapshot(
          id: "\(id.rawValue)-cost",
          kind: Self.kind(period: cost.period),
          label: cost.period ?? "Spend",
          windowStart: nil,
          windowEnd: reset,
          quotaTotal: cost.limit,
          used: cost.used,
          remainingPercent: remainingPercent,
          resetSource: reset == nil ? nil : result.sourceLabel,
          breakdown: []
        ))
    }
    if let creditLimit = result.credits?.codexCreditLimit,
      creditLimit.limit.isFinite,
      creditLimit.limit > 0
    {
      let reset = ProviderDateParser.future(
        creditLimit.resetsAt,
        after: coreSnapshot.updatedAt
      )
      windows.append(
        UsageWindowSnapshot(
          id: "\(id.rawValue)-credit-limit",
          kind: .monthly,
          label: creditLimit.title,
          windowStart: nil,
          windowEnd: reset,
          quotaTotal: creditLimit.limit,
          used: creditLimit.used,
          remainingPercent: creditLimit.remainingPercent,
          resetSource: reset == nil ? nil : result.sourceLabel,
          breakdown: []
        ))
    }

    var notes: [String] = []
    if let credits = result.credits {
      notes.append("Balance \(credits.remaining.formatted(.number.precision(.fractionLength(2))))")
    }
    if let resetCredits = coreSnapshot.codexResetCredits,
      resetCredits.availableCount > 0
    {
      notes.append(
        "\(resetCredits.availableCount) reset credit"
          + (resetCredits.availableCount == 1 ? "" : "s")
      )
    }
    if let renewsAt = coreSnapshot.subscriptionRenewsAt {
      notes.append("Renews \(renewsAt.formatted(date: .abbreviated, time: .omitted))")
    } else if let expiresAt = coreSnapshot.subscriptionExpiresAt {
      notes.append("Expires \(expiresAt.formatted(date: .abbreviated, time: .omitted))")
    }
    switch coreSnapshot.dataConfidence {
    case .estimated:
      notes.append("Estimated usage")
    case .percentOnly:
      notes.append("Percentage only")
    case .exact, .unknown:
      break
    }
    if windows.isEmpty {
      notes.append("No percentage quota reported")
    }

    return UsageSnapshot(
      providerID: id,
      displayName: displayName,
      pools: pools(for: windows),
      freshness: coreSnapshot.updatedAt,
      sourceDescription: result.sourceLabel,
      cacheHitRate: nil,
      accountDescription: accountDescription(coreSnapshot.identity),
      planDescription: planDescription(coreSnapshot.identity),
      notes: notes
    )
  }

  private func enrichClaudeIfNeeded(_ snapshot: UsageSnapshot) async -> UsageSnapshot {
    guard id == .claudeCode else { return snapshot }
    let cacheAnalysis = await ClaudeCacheAnalyzer.shared.cachedAnalysisSchedulingRefresh(
      projectsURL: claudeProjectsURL,
      minimumInterval: cacheAnalysisInterval
    )
    let override = ProviderDateParser.future(manualWeeklyReset, after: snapshot.freshness)
    let pools = snapshot.pools.map { pool in
      UsagePoolSnapshot(
        id: pool.id,
        name: pool.name,
        windows: pool.windows.map { window in
          var window = window
          // Apply manual weekly-reset override when the provider omits a timeline.
          if window.kind == .weekly, window.windowEnd == nil, let override {
            let timeline = ProviderDateParser.window(
              endingAt: override,
              providerDuration: UsageWindowKind.weekly.knownDuration
            )
            window = UsageWindowSnapshot(
              id: window.id,
              kind: window.kind,
              label: window.label,
              windowStart: timeline.start,
              windowEnd: timeline.end,
              quotaTotal: window.quotaTotal,
              used: window.used,
              remainingPercent: window.remainingPercent,
              resetSource: "Manual override",
              breakdown: window.breakdown
            )
          }
          window.tokensUsed = cacheAnalysis.tokensUsed(since: window.windowStart)
          return window
        }
      )
    }
    var notes = snapshot.notes
    if pools.flatMap(\.windows).contains(where: { !$0.hasKnownTimeline }) {
      notes.append("Reset time unknown")
    }
    return UsageSnapshot(
      providerID: snapshot.providerID,
      displayName: snapshot.displayName,
      pools: pools,
      freshness: snapshot.freshness,
      sourceDescription: snapshot.sourceDescription,
      cacheHitRate: cacheAnalysis.hitRate,
      accountDescription: snapshot.accountDescription,
      planDescription: snapshot.planDescription,
      notes: notes.reduce(into: []) { result, note in
        if !result.contains(note) {
          result.append(note)
        }
      }
    )
  }

  private func map(
    _ window: RateWindow,
    id: String,
    label: String,
    source: String
  ) -> UsageWindowSnapshot {
    let duration = window.windowMinutes.flatMap {
      $0 > 0 ? TimeInterval($0 * 60) : nil
    }
    let reset = ProviderDateParser.future(window.resetsAt, after: Date())
    let timeline = ProviderDateParser.window(
      endingAt: reset,
      providerDuration: duration
    )
    return UsageWindowSnapshot(
      id: id,
      kind: UsageWindowKind.inferred(from: duration),
      label: label,
      windowStart: timeline.start,
      windowEnd: timeline.end,
      quotaTotal: 100,
      used: window.usedPercent,
      remainingPercent: window.remainingPercent,
      resetSource: reset == nil ? nil : source,
      breakdown: []
    )
  }

  private func accountDescription(_ identity: ProviderIdentitySnapshot?) -> String? {
    guard let identity,
      identity.providerID == nil || identity.providerID == coreID
    else {
      return nil
    }
    let fields = [
      identity.accountEmail,
      identity.accountOrganization,
      identity.loginMethod,
    ]
    .compactMap { value in
      let value = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      return value.isEmpty ? nil : value
    }
    return fields.isEmpty ? nil : fields.joined(separator: " · ")
  }

  private func planDescription(_ identity: ProviderIdentitySnapshot?) -> String? {
    guard let identity,
      identity.providerID == nil || identity.providerID == coreID
    else { return nil }
    let value = identity.loginMethod?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return value.isEmpty ? nil : value
  }

  private func pools(for windows: [UsageWindowSnapshot]) -> [UsagePoolSnapshot] {
    guard id == .antigravity else {
      return [UsagePoolSnapshot(id: "default", name: "Default", windows: windows)]
    }
    let definitions = [
      (id: "gemini", name: "Gemini", match: "gemini"),
      (id: "claude-gpt", name: "Claude/GPT-OSS", match: "claude"),
    ]
    return definitions.compactMap { definition in
      let matches = windows.filter {
        $0.label.localizedCaseInsensitiveContains(definition.match)
      }.map { window in
        UsageWindowSnapshot(
          id: window.id,
          kind: window.kind,
          label: window.kind.panelLabel,
          windowStart: window.windowStart,
          windowEnd: window.windowEnd,
          quotaTotal: window.quotaTotal,
          used: window.used,
          remainingPercent: window.remainingPercent,
          resetSource: window.resetSource,
          breakdown: window.breakdown,
          tokensUsed: window.tokensUsed
        )
      }
      guard !matches.isEmpty else { return nil }
      return UsagePoolSnapshot(id: definition.id, name: definition.name, windows: matches)
    }
  }

  private static func kind(period: String?) -> UsageWindowKind {
    guard let period = period?.lowercased() else { return .other }
    if period.contains("month") { return .monthly }
    if period.contains("week") { return .weekly }
    return .other
  }

}
