import Foundation

@MainActor
final class CursorProvider: UsageProvider {
  let id: ProviderID = .cursor
  let displayName = "Cursor"
  var allowBrowserKeychainAccess = false

  private var cachedSession: CursorAuthSession?

  func currentSnapshot() async throws -> UsageSnapshot {
    var localCandidates: [CursorAuthSession] = []
    if let cachedSession {
      localCandidates.append(cachedSession)
    }
    if let app = CursorAppAuthStore.load(),
      !localCandidates.contains(where: { $0.cookieHeader == app.cookieHeader })
    {
      localCandidates.append(app)
    }

    let localResult = await firstSnapshot(from: localCandidates)
    if let snapshot = localResult.snapshot {
      return snapshot
    }

    var browserResult: SnapshotAttempt?
    if let browser = CursorBrowserCookieStore.load(
      allowKeychainAccess: allowBrowserKeychainAccess
    ),
      !localCandidates.contains(where: { $0.cookieHeader == browser.cookieHeader })
    {
      browserResult = await firstSnapshot(from: [browser])
      if let snapshot = browserResult?.snapshot {
        return snapshot
      }
    }

    guard !localCandidates.isEmpty || browserResult != nil else {
      if CursorBrowserCookieStore.keychainBrowserDetected {
        if allowBrowserKeychainAccess,
          CursorBrowserCookieStore.keychainApprovalRequired
        {
          throw ProviderFailure.notLoggedIn(
            "Cursor: browser Keychain access requires approval"
          )
        }
        if allowBrowserKeychainAccess {
          throw ProviderFailure.notLoggedIn(
            "Cursor: sign in to cursor.com in your browser"
          )
        }
        throw ProviderFailure.notLoggedIn(
          "Cursor: enable browser access in Settings or sign in to Cursor.app"
        )
      }
      throw ProviderFailure.notLoggedIn("Cursor: sign in to cursor.com in your browser")
    }

    throw browserResult?.lastError
      ?? localResult.lastError
      ?? ProviderFailure.unavailable("Cursor: usage unavailable")
  }

  func authorizeBrowserKeychainAccess() throws {
    guard allowBrowserKeychainAccess else {
      throw ProviderFailure.unavailable("Cursor: enable browser access in Settings first")
    }
    CursorBrowserCookieStore.resetKeychainCache()
    guard
      let session = CursorBrowserCookieStore.load(
        allowKeychainAccess: true,
        allowInteraction: true
      )
    else {
      throw ProviderFailure.notLoggedIn(
        "Cursor: no signed-in cursor.com browser session found"
      )
    }
    cachedSession = session
  }

  private func firstSnapshot(from candidates: [CursorAuthSession]) async -> SnapshotAttempt {
    var lastError: Error?
    for session in candidates {
      do {
        let snapshot = try await fetch(session)
        cachedSession = session
        return SnapshotAttempt(snapshot: snapshot, lastError: nil)
      } catch CursorAPIError.unauthorized {
        if cachedSession?.cookieHeader == session.cookieHeader {
          cachedSession = nil
        }
        lastError = ProviderFailure.notLoggedIn(
          "Cursor: sign in to cursor.com in your browser"
        )
      } catch {
        lastError = error
      }
    }
    return SnapshotAttempt(snapshot: nil, lastError: lastError)
  }

  private func fetch(_ session: CursorAuthSession) async throws -> UsageSnapshot {
    async let summaryResult = request(path: "/api/usage-summary", session: session)
    async let userResult = try? request(path: "/api/auth/me", session: session)
    let (summaryData, _) = try await summaryResult
    let userData = await userResult?.0

    let summary: CursorUsageSummary
    do {
      summary = try JSONDecoder().decode(CursorUsageSummary.self, from: summaryData)
    } catch {
      throw ProviderFailure.invalidResponse("Cursor: unexpected usage response")
    }
    let user = userData.flatMap { try? JSONDecoder().decode(CursorUserInfo.self, from: $0) }
    let userID = user?.sub ?? session.userID
    var legacy: CursorLegacyUsage?
    if let userID {
      if let data = try? await request(
        path: "/api/usage",
        queryItems: [URLQueryItem(name: "user", value: userID)],
        session: session
      ).0 {
        legacy = try? JSONDecoder().decode(CursorLegacyUsage.self, from: data)
      }
    }

    let freshness = Date()
    let billing = ProviderDateParser.activeWindow(
      start: ProviderDateParser.date(from: summary.billingCycleStart),
      end: ProviderDateParser.date(from: summary.billingCycleEnd),
      at: freshness
    )
    let breakdown = dynamicBreakdown(from: summaryData)
    let meter = try CursorUsageResolver.resolve(
      summary: summary,
      legacy: legacy,
      breakdown: breakdown
    )

    let pools = CursorUsageResolver.pools(
      usage: meter,
      start: billing.start,
      end: billing.end,
      breakdown: breakdown
    )

    var notes = [meter.unitNote]
    if !pools.contains(where: { $0.windows.contains(where: \.hasKnownTimeline) }) {
      notes.append("Billing reset unknown")
    }
    return UsageSnapshot(
      providerID: .cursor,
      displayName: displayName,
      pools: pools,
      freshness: freshness,
      sourceDescription: session.source,
      cacheHitRate: nil,
      accountDescription: [user?.email, summary.membershipType].compactMap(\.self)
        .joined(separator: " · "),
      planDescription: summary.membershipType,
      notes: notes
    )
  }

  private func request(
    path: String,
    queryItems: [URLQueryItem] = [],
    session: CursorAuthSession
  ) async throws -> (Data, HTTPURLResponse) {
    guard path.hasPrefix("/"), !path.contains("..") else {
      throw ProviderFailure.invalidResponse("Cursor: invalid endpoint path")
    }
    var components = URLComponents()
    components.scheme = "https"
    components.host = "cursor.com"
    components.path = path
    components.queryItems = queryItems.isEmpty ? nil : queryItems
    guard let url = components.url else {
      throw ProviderFailure.invalidResponse("Cursor: invalid endpoint")
    }
    var request = URLRequest(url: url)
    request.timeoutInterval = 15
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue(session.cookieHeader, forHTTPHeaderField: "Cookie")
    let result = try await RestrictedHTTPClient.data(for: request)
    switch result.1.statusCode {
    case 200:
      return result
    case 401, 403:
      throw CursorAPIError.unauthorized
    default:
      throw ProviderFailure.unavailable(
        "Cursor: dashboard returned HTTP \(result.1.statusCode)"
      )
    }
  }

  private func dynamicBreakdown(from data: Data) -> [UsageBreakdownItem] {
    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let individual = root["individualUsage"] as? [String: Any],
      let plan = individual["plan"] as? [String: Any]
    else {
      return []
    }
    return plan.compactMap { key, value -> UsageBreakdownItem? in
      guard key.hasSuffix("PercentUsed"),
        let number = value as? NSNumber,
        number.doubleValue.isFinite,
        number.doubleValue >= 0
      else {
        return nil
      }
      let raw = String(key.dropLast("PercentUsed".count))
      guard !raw.isEmpty else { return nil }
      let label = raw == "total" ? "Total" : humanize(raw)
      return UsageBreakdownItem(
        id: raw,
        label: label,
        usedPercent: number.doubleValue
      )
    }.sorted { $0.label < $1.label }
  }

  private func humanize(_ value: String) -> String {
    if value.lowercased() == "api" {
      return "API"
    }
    let spaced = value.reduce(into: "") { result, character in
      if character.isUppercase, !result.isEmpty {
        result.append(" ")
      }
      result.append(character)
    }
    return spaced.prefix(1).uppercased() + spaced.dropFirst()
  }
}

private enum CursorAPIError: Error {
  case unauthorized
}

private struct SnapshotAttempt {
  let snapshot: UsageSnapshot?
  let lastError: Error?
}
