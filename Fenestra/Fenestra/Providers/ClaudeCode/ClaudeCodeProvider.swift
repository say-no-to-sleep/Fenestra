import Foundation

@MainActor
final class ClaudeCodeProvider: UsageProvider {
  let id: ProviderID = .claudeCode
  let displayName = "Claude"

  var manualWeeklyReset: Date?
  var cacheAnalysisInterval: TimeInterval?

  private let rateLimitGate = ClaudeUsageRateLimitGate()
  private let refreshGate = ClaudeUsageRateLimitGate(
    blockedUntilKey: ClaudeUsageRateLimitGate.tokenRefreshBlockedUntilKey,
    cooldown: ClaudeUsageRateLimitGate.tokenRefreshCooldown
  )
  private let projectsURL = FileManager.default.homeDirectoryForCurrentUser
    .appending(path: ".claude/projects")
  private var tokenRefreshTask: Task<ClaudeCredentials, Error>?
  private var blockedRefreshFingerprint: Int?

  func prepareForcedRefresh() {
    blockedRefreshFingerprint = nil
  }

  func refreshCacheAnalysis() async -> Double? {
    await ClaudeCacheAnalyzer.shared.markDirty(projectsURL: projectsURL)
    return await ClaudeCacheAnalyzer.shared.analyze(projectsURL: projectsURL).hitRate
  }

  func currentSnapshot() async throws -> UsageSnapshot {
    let statusline = ClaudeStatuslineReader.read()
    if let statusline,
      Date().timeIntervalSince(statusline.freshness) <= 90
    {
      return await enrichedSnapshot(
        fiveHourUsed: statusline.fiveHourUsedPercent,
        fiveHourReset: statusline.fiveHourReset,
        weeklyUsed: statusline.weeklyUsedPercent,
        weeklyReset: statusline.weeklyReset ?? manualWeeklyReset,
        freshness: statusline.freshness,
        source: "Claude statusline",
        account: nil
      )
    }

    do {
      let (usage, credentials) = try await authenticatedUsage()
      return await enrichedSnapshot(
        fiveHourUsed: usage.fiveHour?.utilization,
        fiveHourReset: ProviderDateParser.date(from: usage.fiveHour?.resetsAt),
        weeklyUsed: usage.sevenDay?.utilization,
        weeklyReset: ProviderDateParser.date(from: usage.sevenDay?.resetsAt)
          ?? manualWeeklyReset,
        freshness: Date(),
        source: "Anthropic OAuth",
        account: credentials.source
      )
    } catch {
      guard let statusline else { throw error }
      return await enrichedSnapshot(
        fiveHourUsed: statusline.fiveHourUsedPercent,
        fiveHourReset: statusline.fiveHourReset,
        weeklyUsed: statusline.weeklyUsedPercent,
        weeklyReset: statusline.weeklyReset ?? manualWeeklyReset,
        freshness: statusline.freshness,
        source: "Claude statusline fallback",
        account: nil
      )
    }
  }

  private func authenticatedUsage() async throws -> (ClaudeUsageResponse, ClaudeCredentials) {
    var credentials = try await ensureFreshCredentials(try ClaudeCredentialStore.load())
    do {
      let usage = try await fetchUsage(accessToken: credentials.accessToken)
      return (usage, credentials)
    } catch ClaudeAPIError.unauthorized {
      // Throttled: a 401 every poll must not mean a Keychain prompt every poll.
      credentials = try ClaudeCredentialStore.reload() ?? credentials
      if !credentials.isExpired() {
        do {
          let usage = try await fetchUsage(accessToken: credentials.accessToken)
          return (usage, credentials)
        } catch ClaudeAPIError.unauthorized {
          credentials = try await refreshCredentials(credentials, force: true)
        }
      } else {
        credentials = try await refreshCredentials(credentials, force: true)
      }
      do {
        let usage = try await fetchUsage(accessToken: credentials.accessToken)
        return (usage, credentials)
      } catch ClaudeAPIError.unauthorized {
        throw ProviderFailure.reauthenticationRequired(
          ClaudeOAuthRefresher.expiredSessionMessage
        )
      }
    }
  }

  private func ensureFreshCredentials(
    _ credentials: ClaudeCredentials
  ) async throws -> ClaudeCredentials {
    guard credentials.isExpired() else { return credentials }
    return try await refreshCredentials(credentials, force: false)
  }

  private func refreshCredentials(
    _ credentials: ClaudeCredentials,
    force: Bool
  ) async throws -> ClaudeCredentials {
    if let tokenRefreshTask {
      return try await tokenRefreshTask.value
    }
    let task = Task { @MainActor in
      try await self.performTokenRefresh(credentials, force: force)
    }
    tokenRefreshTask = task
    defer { tokenRefreshTask = nil }
    return try await task.value
  }

  private func performTokenRefresh(
    _ credentials: ClaudeCredentials,
    force: Bool
  ) async throws -> ClaudeCredentials {
    guard let refreshToken = credentials.refreshToken, !refreshToken.isEmpty else {
      throw ProviderFailure.reauthenticationRequired(
        ClaudeOAuthRefresher.expiredSessionMessage
      )
    }
    if !force, blockedRefreshFingerprint == credentials.fingerprint {
      throw ProviderFailure.reauthenticationRequired(
        ClaudeOAuthRefresher.expiredSessionMessage
      )
    }
    if let blockedUntil = refreshGate.blockedUntil() {
      throw ProviderFailure.unavailable(
        ClaudeUsageRateLimitGate.message(blockedUntil: blockedUntil, subject: "token refresh")
      )
    }

    let request = ClaudeOAuthRefresher.tokenRequest(
      refreshToken: refreshToken,
      userAgent: await ClaudeCodeUserAgent.value()
    )
    let (data, response) = try await RestrictedHTTPClient.data(for: request)
    switch response.statusCode {
    case 200:
      let tokens = try ClaudeOAuthRefresher.parseTokens(from: data)
      try ClaudeCredentialStore.persist(tokens, replacing: credentials)
      blockedRefreshFingerprint = nil
      refreshGate.recordSuccess()
      LocalLog.record("Claude: refreshed OAuth access token")
      // persist() already primed the Keychain cache, so this is prompt-free.
      return try ClaudeCredentialStore.load()
    case 429:
      let blockedUntil = refreshGate.recordRateLimit(
        retryAfter: ClaudeUsageRateLimitGate.retryAfterDate(from: response)
      )
      throw ProviderFailure.unavailable(
        ClaudeUsageRateLimitGate.message(blockedUntil: blockedUntil, subject: "token refresh")
      )
    case 400, 401:
      let error = ClaudeOAuthRefresher.oauthErrorCode(from: data)
      if error == "invalid_grant" {
        blockedRefreshFingerprint = credentials.fingerprint
        throw ProviderFailure.reauthenticationRequired(
          ClaudeOAuthRefresher.expiredSessionMessage
        )
      }
      throw ProviderFailure.unavailable(
        "Claude: OAuth refresh failed (HTTP \(response.statusCode))"
      )
    default:
      throw ProviderFailure.unavailable(
        "Claude: OAuth refresh failed (HTTP \(response.statusCode))"
      )
    }
  }

  private func fetchUsage(accessToken: String) async throws -> ClaudeUsageResponse {
    if let blockedUntil = rateLimitGate.blockedUntil() {
      throw ProviderFailure.unavailable(
        ClaudeUsageRateLimitGate.message(blockedUntil: blockedUntil)
      )
    }
    guard let url = URL(string: "https://api.anthropic.com/api/oauth/usage") else {
      throw ProviderFailure.invalidResponse("Claude: invalid usage endpoint")
    }
    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.timeoutInterval = 30
    request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
    request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(await ClaudeCodeUserAgent.value(), forHTTPHeaderField: "User-Agent")
    let (data, response) = try await RestrictedHTTPClient.data(for: request)
    switch response.statusCode {
    case 200:
      do {
        let usage = try JSONDecoder().decode(ClaudeUsageResponse.self, from: data)
        let values = [
          usage.fiveHour?.utilization,
          usage.sevenDay?.utilization,
        ].compactMap(\.self)
        guard !values.isEmpty,
          values.allSatisfy({ $0.isFinite && (0...100).contains($0) })
        else {
          throw ProviderFailure.invalidResponse("Claude: invalid usage values")
        }
        rateLimitGate.recordSuccess()
        return usage
      } catch {
        if let failure = error as? ProviderFailure {
          throw failure
        }
        throw ProviderFailure.invalidResponse("Claude: unexpected usage response")
      }
    case 401:
      throw ClaudeAPIError.unauthorized
    case 429:
      let retryAfter = ClaudeUsageRateLimitGate.retryAfterDate(from: response)
      let blockedUntil = rateLimitGate.recordRateLimit(retryAfter: retryAfter)
      throw ProviderFailure.unavailable(
        ClaudeUsageRateLimitGate.message(blockedUntil: blockedUntil)
      )
    default:
      throw ProviderFailure.unavailable("Claude: usage API returned HTTP \(response.statusCode)")
    }
  }

  private func enrichedSnapshot(
    fiveHourUsed: Double?,
    fiveHourReset: Date?,
    weeklyUsed: Double?,
    weeklyReset: Date?,
    freshness: Date,
    source: String,
    account: String? = nil
  ) async -> UsageSnapshot {
    let cacheAnalysis = await ClaudeCacheAnalyzer.shared.cachedAnalysisSchedulingRefresh(
      projectsURL: projectsURL,
      minimumInterval: cacheAnalysisInterval
    )
    return snapshot(
      fiveHourUsed: fiveHourUsed,
      fiveHourReset: fiveHourReset,
      weeklyUsed: weeklyUsed,
      weeklyReset: weeklyReset,
      freshness: freshness,
      source: source,
      cacheHitRate: cacheAnalysis.hitRate,
      account: account
    )
  }

  private func snapshot(
    fiveHourUsed: Double?,
    fiveHourReset: Date?,
    weeklyUsed: Double?,
    weeklyReset: Date?,
    freshness: Date,
    source: String,
    cacheHitRate: Double?,
    account: String?
  ) -> UsageSnapshot {
    let now = Date()
    let effectiveFiveHourReset = ProviderDateParser.future(fiveHourReset, after: now)
    let effectiveWeeklyReset = ProviderDateParser.future(weeklyReset, after: now)
    var windows: [UsageWindowSnapshot] = []
    if let fiveHourUsed {
      let timeline = ProviderDateParser.window(
        endingAt: effectiveFiveHourReset,
        providerDuration: UsageWindowKind.fiveHour.knownDuration
      )
      windows.append(
        UsageWindowSnapshot(
          id: "claude-five-hour",
          kind: .fiveHour,
          label: "5-hour",
          windowStart: timeline.start,
          windowEnd: timeline.end,
          quotaTotal: 100,
          used: fiveHourUsed,
          remainingPercent: 100 - fiveHourUsed,
          resetSource: effectiveFiveHourReset == nil ? nil : source,
          breakdown: []
        ))
    }
    if let weeklyUsed {
      let timeline = ProviderDateParser.window(
        endingAt: effectiveWeeklyReset,
        providerDuration: UsageWindowKind.weekly.knownDuration
      )
      let isManual =
        effectiveWeeklyReset == manualWeeklyReset
        && manualWeeklyReset != nil
      windows.append(
        UsageWindowSnapshot(
          id: "claude-weekly",
          kind: .weekly,
          label: "Weekly",
          windowStart: timeline.start,
          windowEnd: timeline.end,
          quotaTotal: 100,
          used: weeklyUsed,
          remainingPercent: 100 - weeklyUsed,
          resetSource:
            effectiveWeeklyReset == nil ? nil : (isManual ? "Manual override" : source),
          breakdown: []
        ))
    }

    var notes: [String] = []
    if isClaudePeakWindow() {
      notes.append("Peak window · eases 11am PT")
    }
    if windows.contains(where: { !$0.hasKnownTimeline }) {
      notes.append("Reset time unknown")
    }
    if weeklyUsed != nil, effectiveWeeklyReset == nil {
      notes.append("Set weekly reset in Settings")
    }
    return UsageSnapshot(
      providerID: .claudeCode,
      displayName: displayName,
      pools: [UsagePoolSnapshot(id: "default", name: "Default", windows: windows)],
      freshness: freshness,
      sourceDescription: source,
      cacheHitRate: cacheHitRate,
      accountDescription: account,
      notes: notes
    )
  }

  private func isClaudePeakWindow(now: Date = Date()) -> Bool {
    guard let pacific = TimeZone(identifier: "America/Los_Angeles") else { return false }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = pacific
    let weekday = calendar.component(.weekday, from: now)
    let hour = calendar.component(.hour, from: now)
    return (2...6).contains(weekday) && (5..<11).contains(hour)
  }
}

private enum ClaudeAPIError: LocalizedError {
  case unauthorized

  var errorDescription: String? {
    "Claude: OAuth session expired — run `claude auth login --claudeai`"
  }
}

private struct ClaudeUsageResponse: Decodable {
  let fiveHour: ClaudeUsageWindow?
  let sevenDay: ClaudeUsageWindow?

  enum CodingKeys: String, CodingKey {
    case fiveHour = "five_hour"
    case sevenDay = "seven_day"
  }
}

private struct ClaudeUsageWindow: Decodable {
  let utilization: Double?
  let resetsAt: String?

  enum CodingKeys: String, CodingKey {
    case utilization
    case resetsAt = "resets_at"
  }
}
