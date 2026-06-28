import Foundation

@MainActor
final class AntigravityProvider: UsageProvider {
  let id: ProviderID = .antigravity
  let displayName = "Antigravity"

  func currentSnapshot() async throws -> UsageSnapshot {
    do {
      let endpoints = try await AntigravityDiscovery.endpoints()
      if let snapshot = try await fetchLocal(endpoints: endpoints) {
        return snapshot
      }
    } catch {
      LocalLog.record("Antigravity local discovery failed: \(error.localizedDescription)")
    }

    let token = try AntigravityCloudFallback.loadToken()
    guard let accessToken = token.accessToken, !accessToken.isEmpty else {
      throw ProviderFailure.notLoggedIn(
        "Antigravity: open the app or run `agy` and sign in"
      )
    }
    if let summaryData = try await AntigravityCloudFallback.fetchQuotaSummary(
      accessToken: accessToken
    ),
      let snapshot = try parseQuotaSummary(
        summaryData,
        sourceDescription: "Google Cloud Code quota"
      )
    {
      return snapshot
    }
    let models = try await AntigravityCloudFallback.fetchModels(accessToken: accessToken)
    guard !models.isEmpty,
      let snapshot = snapshotFromModels(
        models,
        identity: nil,
        source: "Google Cloud Code"
      )
    else {
      throw ProviderFailure.invalidResponse("Antigravity: no quota models returned")
    }
    return snapshot
  }

  private func fetchLocal(endpoints: [AntigravityEndpoint]) async throws -> UsageSnapshot? {
    var lastError: Error?
    for endpoint in endpoints {
      do {
        let quotaData = try await AntigravityLocalClient.request(
          endpoint: endpoint,
          method: "RetrieveUserQuotaSummary",
          body: ["forceRefresh": true]
        )
        if let snapshot = try parseQuotaSummary(quotaData) {
          return snapshot
        }
      } catch {
        lastError = error
      }

      do {
        let statusData = try await AntigravityLocalClient.request(
          endpoint: endpoint,
          method: "GetUserStatus",
          body: AntigravityLocalClient.metadataBody
        )
        if let parsed = parseUserStatus(statusData), !parsed.models.isEmpty {
          if let snapshot = snapshotFromModels(
            parsed.models,
            identity: parsed.identity,
            source: "Antigravity local RPC"
          ) {
            return snapshot
          }
        }
      } catch {
        lastError = error
      }

      do {
        let configData = try await AntigravityLocalClient.request(
          endpoint: endpoint,
          method: "GetCommandModelConfigs",
          body: AntigravityLocalClient.metadataBody
        )
        if let envelope = try? JSONDecoder().decode(
          AntigravityCommandConfigEnvelope.self,
          from: configData
        ) {
          let models = quotas(from: envelope.clientModelConfigs ?? [])
          if !models.isEmpty,
            let snapshot = snapshotFromModels(
              models,
              identity: nil,
              source: "Antigravity model-config RPC"
            )
          {
            return snapshot
          }
        }
      } catch {
        lastError = error
      }
    }
    if let lastError { throw lastError }
    return nil
  }

  private func parseQuotaSummary(
    _ data: Data,
    sourceDescription: String = "Antigravity quota RPC"
  ) throws -> UsageSnapshot? {
    let envelope = try JSONDecoder().decode(AntigravityQuotaSummaryResponse.self, from: data)
    let groups = envelope.response?.groups ?? envelope.summary?.groups ?? envelope.groups ?? []
    let freshness = Date()
    var windowsByPool: [String: [UsageWindowSnapshot]] = [:]
    for (groupIndex, group) in groups.enumerated() {
      for (bucketIndex, bucket) in (group.buckets ?? []).enumerated() {
        guard bucket.disabled != true else { continue }
        let remaining =
          bucket.remainingFraction
          ?? bucket.remaining?.remainingFraction
          ?? bucket.remaining?.value
        guard let remaining, remaining.isFinite, (0...1).contains(remaining) else { continue }
        let combined = "\(bucket.bucketID ?? "") \(bucket.displayName ?? "")".lowercased()
        let name = poolName("\(group.displayName ?? "") \(combined)")
        let kind: UsageWindowKind
        if combined.contains("5h")
          || combined.contains("5-hour")
          || combined.contains("five hour")
        {
          kind = .fiveHour
        } else if combined.contains("week") {
          kind = .weekly
        } else {
          kind = .other
        }
        let end = ProviderDateParser.future(
          ProviderDateParser.date(from: bucket.resetTime),
          after: freshness
        )
        let timeline = ProviderDateParser.window(
          endingAt: end,
          providerDuration: kind.knownDuration
        )
        let fallbackID = "\(bucket.displayName ?? kind.rawValue)-\(groupIndex)-\(bucketIndex)"
        let bucketID = bucket.bucketID ?? fallbackID
        windowsByPool[name, default: []].append(
          UsageWindowSnapshot(
            id: "antigravity-\(poolID(for: name))-\(bucketID)",
            kind: kind,
            label: bucket.displayName ?? kind.shortLabel,
            windowStart: timeline.start,
            windowEnd: timeline.end,
            quotaTotal: 100,
            used: (1 - remaining) * 100,
            remainingPercent: remaining * 100,
            resetSource: end == nil ? nil : "Antigravity quota RPC",
            breakdown: []
          ))
      }
    }
    let pools = ["Gemini", "Claude/GPT-OSS"].compactMap { name -> UsagePoolSnapshot? in
      guard let windows = windowsByPool[name], !windows.isEmpty else { return nil }
      return UsagePoolSnapshot(id: poolID(for: name), name: name, windows: windows)
    }
    guard !pools.isEmpty else { return nil }
    return UsageSnapshot(
      providerID: .antigravity,
      displayName: displayName,
      pools: pools,
      freshness: freshness,
      sourceDescription: sourceDescription,
      cacheHitRate: nil,
      accountDescription: nil,
      notes: timelineNotes(for: pools)
    )
  }

  private func parseUserStatus(
    _ data: Data
  ) -> (models: [AntigravityModelQuota], identity: AntigravityIdentity)? {
    guard
      let envelope = try? JSONDecoder().decode(
        AntigravityUserStatusEnvelope.self,
        from: data
      ),
      let status = envelope.userStatus
    else {
      return nil
    }
    let plan =
      status.userTier?.name
      ?? status.planStatus?.planInfo?.planDisplayName
      ?? status.planStatus?.planInfo?.planName
    return (
      quotas(from: status.cascadeModelConfigData?.clientModelConfigs ?? []),
      AntigravityIdentity(email: status.email, plan: plan)
    )
  }

  private func quotas(from models: [AntigravityModelConfig]) -> [AntigravityModelQuota] {
    models.compactMap { model in
      guard let quota = model.quotaInfo,
        let fraction = quota.remainingFraction,
        fraction.isFinite,
        (0...1).contains(fraction)
      else {
        return nil
      }
      let id = model.modelOrAlias?.model ?? model.label ?? "unknown"
      return AntigravityModelQuota(
        label: model.label ?? id,
        modelID: id,
        remainingFraction: fraction,
        resetTime: ProviderDateParser.date(from: quota.resetTime)
      )
    }
  }

  private func snapshotFromModels(
    _ models: [AntigravityModelQuota],
    identity: AntigravityIdentity?,
    source: String
  ) -> UsageSnapshot? {
    let freshness = Date()
    let visibleModels = models.filter {
      !$0.modelID.localizedCaseInsensitiveContains("placeholder")
        && !$0.label.localizedCaseInsensitiveContains("placeholder")
    }
    var grouped: [String: [AntigravityModelQuota]] = [:]
    for model in visibleModels {
      let name = poolName("\(model.label) \(model.modelID)")
      grouped[name, default: []].append(model)
    }
    let pools = ["Gemini", "Claude/GPT-OSS"].compactMap { name -> UsagePoolSnapshot? in
      guard let candidates = grouped[name],
        let representative = candidates.min(by: { lhs, rhs in
          if lhs.remainingFraction != rhs.remainingFraction {
            return lhs.remainingFraction < rhs.remainingFraction
          }
          if lhs.resetTime != nil, rhs.resetTime == nil {
            return true
          }
          return lhs.label.localizedCaseInsensitiveCompare(rhs.label) == .orderedAscending
        })
      else {
        return nil
      }
      let resetTime = ProviderDateParser.future(
        representative.resetTime,
        after: freshness
      )
      let timeline = ProviderDateParser.window(
        endingAt: resetTime,
        providerDuration: UsageWindowKind.fiveHour.knownDuration
      )
      let window = UsageWindowSnapshot(
        id: name == "Gemini" ? "antigravity-gemini-five-hour" : "antigravity-claude-five-hour",
        kind: .fiveHour,
        label: "5-hour",
        windowStart: timeline.start,
        windowEnd: timeline.end,
        quotaTotal: 100,
        used: (1 - representative.remainingFraction) * 100,
        remainingPercent: representative.remainingFraction * 100,
        resetSource: resetTime == nil ? nil : source,
        breakdown: []
      )
      return UsagePoolSnapshot(
        id: name == "Gemini" ? "gemini" : "claude-gpt",
        name: name,
        windows: [window]
      )
    }
    guard !pools.isEmpty else { return nil }
    return UsageSnapshot(
      providerID: .antigravity,
      displayName: displayName,
      pools: pools,
      freshness: freshness,
      sourceDescription: source,
      cacheHitRate: nil,
      accountDescription: [identity?.email, identity?.plan].compactMap(\.self)
        .joined(separator: " · "),
      notes: timelineNotes(for: pools)
    )
  }

  private func poolName(_ text: String) -> String {
    let normalized = text.lowercased()
    if normalized.contains("gemini") {
      return "Gemini"
    }
    return "Claude/GPT-OSS"
  }

  private func poolID(for name: String) -> String {
    name == "Gemini" ? "gemini" : "claude-gpt"
  }

  private func timelineNotes(for pools: [UsagePoolSnapshot]) -> [String] {
    let windows = pools.flatMap(\.windows)
    if windows.contains(where: { $0.windowEnd == nil }) {
      return ["Reset time unknown"]
    }
    if windows.contains(where: { !$0.hasKnownTimeline }) {
      return ["Window start unknown"]
    }
    return []
  }
}
