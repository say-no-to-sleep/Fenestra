import Foundation

@MainActor
final class ClaudeCodeProvider: UsageProvider {
  let id: ProviderID = .claudeCode
  let displayName = "Claude"

  var manualWeeklyReset: Date?
  var cacheAnalysisInterval: TimeInterval?

  private let rateLimitGate = ClaudeUsageRateLimitGate()
  private let projectsURL = FileManager.default.homeDirectoryForCurrentUser
    .appending(path: ".claude/projects")

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
    let credentials = try ClaudeCredentialStore.load()
    do {
      let usage = try await fetchUsage(accessToken: credentials.accessToken)
      return (usage, credentials)
    } catch ClaudeAPIError.unauthorized {
      throw ProviderFailure.reauthenticationRequired(
        "Claude: OAuth session expired — run `claude auth login --claudeai`"
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
