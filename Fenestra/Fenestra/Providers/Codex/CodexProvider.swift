import Foundation

@MainActor
final class CodexProvider: UsageProvider {
  let id: ProviderID = .codex
  let displayName = "Codex"

  func currentSnapshot() async throws -> UsageSnapshot {
    let credentials = try CodexCredentialStore.load()
    do {
      return try await fetch(credentials)
    } catch CodexAPIError.unauthorized {
      throw ProviderFailure.reauthenticationRequired(
        "Codex: needs reauth — run `codex login`"
      )
    }
  }

  private func fetch(_ credentials: CodexCredentials) async throws -> UsageSnapshot {
    guard let url = URL(string: "https://chatgpt.com/backend-api/wham/usage") else {
      throw ProviderFailure.invalidResponse("Codex: invalid usage endpoint")
    }
    var request = URLRequest(url: url)
    request.timeoutInterval = 30
    request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("codex-cli/0.142.3", forHTTPHeaderField: "User-Agent")
    if let accountID = credentials.accountID {
      request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
    }

    let (data, response) = try await RestrictedHTTPClient.data(for: request)
    switch response.statusCode {
    case 200:
      break
    case 401:
      throw CodexAPIError.unauthorized
    case 403:
      throw ProviderFailure.reauthenticationRequired("Codex: account access denied")
    default:
      throw ProviderFailure.unavailable("Codex: usage API returned HTTP \(response.statusCode)")
    }

    let payload: CodexUsageResponse
    do {
      payload = try JSONDecoder().decode(CodexUsageResponse.self, from: data)
    } catch {
      throw ProviderFailure.invalidResponse("Codex: unexpected usage response")
    }
    guard let rateLimit = payload.rateLimit else {
      throw ProviderFailure.invalidResponse("Codex: no rate-limit data")
    }

    let freshness = Date()
    let windows = [
      makeWindow(rateLimit.primaryWindow, position: "primary", freshness: freshness),
      makeWindow(rateLimit.secondaryWindow, position: "secondary", freshness: freshness),
    ].compactMap(\.self)
    guard !windows.isEmpty else {
      throw ProviderFailure.invalidResponse("Codex: no usage windows")
    }

    var notes: [String] = []
    if let count = payload.rateLimitResetCredits?.availableCount, count > 0 {
      notes.append("\(count) reset credit\(count == 1 ? "" : "s") banked")
    }
    if windows.contains(where: { $0.windowEnd == nil }) {
      notes.append("Reset time unknown")
    } else if windows.contains(where: { !$0.hasKnownTimeline }) {
      notes.append("Window start unknown")
    }
    return UsageSnapshot(
      providerID: .codex,
      displayName: displayName,
      pools: [UsagePoolSnapshot(id: "default", name: "Default", windows: windows)],
      freshness: freshness,
      sourceDescription: "Codex CLI usage API",
      cacheHitRate: nil,
      accountDescription: payload.planType,
      planDescription: payload.planType,
      notes: notes
    )
  }

  private func makeWindow(
    _ payload: CodexRateLimitWindow?,
    position: String,
    freshness: Date
  ) -> UsageWindowSnapshot? {
    guard let payload, payload.usedPercent.isFinite else { return nil }
    let duration = payload.limitWindowSeconds
      .flatMap { $0 > 0 ? TimeInterval($0) : nil }
    let kind = UsageWindowKind.inferred(from: duration)
    let end = ProviderDateParser.future(
      ProviderDateParser.epochDate(payload.resetAt ?? 0),
      after: freshness
    )
    let timeline = ProviderDateParser.window(endingAt: end, providerDuration: duration)
    let used = payload.usedPercent
    return UsageWindowSnapshot(
      id: "codex-\(position)-\(Int(payload.limitWindowSeconds ?? 0))",
      kind: kind,
      label: kind.panelLabel,
      windowStart: timeline.start,
      windowEnd: timeline.end,
      quotaTotal: 100,
      used: used,
      remainingPercent: 100 - used,
      resetSource: end == nil ? nil : "Codex usage API",
      breakdown: []
    )
  }
}

private enum CodexAPIError: Error {
  case unauthorized
}

private struct CodexUsageResponse: Decodable {
  let planType: String?
  let rateLimit: CodexRateLimitDetails?
  let rateLimitResetCredits: CodexResetCredits?

  enum CodingKeys: String, CodingKey {
    case planType = "plan_type"
    case rateLimit = "rate_limit"
    case rateLimitResetCredits = "rate_limit_reset_credits"
  }
}

private struct CodexRateLimitDetails: Decodable {
  let primaryWindow: CodexRateLimitWindow?
  let secondaryWindow: CodexRateLimitWindow?

  enum CodingKeys: String, CodingKey {
    case primaryWindow = "primary_window"
    case secondaryWindow = "secondary_window"
  }
}

private struct CodexRateLimitWindow: Decodable {
  let usedPercent: Double
  let limitWindowSeconds: Int?
  let resetAt: Double?

  enum CodingKeys: String, CodingKey {
    case usedPercent = "used_percent"
    case limitWindowSeconds = "limit_window_seconds"
    case resetAt = "reset_at"
  }
}

private struct CodexResetCredits: Decodable {
  let availableCount: Int

  enum CodingKeys: String, CodingKey {
    case availableCount = "available_count"
  }
}
