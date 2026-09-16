import Foundation

struct CursorResolvedUsage: Equatable {
  let quotaTotal: Double
  let used: Double
  let totalPercent: Double
  let unitNote: String
  var modelsPercent: Double? = nil
  var apiPercent: Double? = nil
}

enum CursorUsageResolver {
  static func pools(
    usage: CursorResolvedUsage,
    start: Date?,
    end: Date?,
    breakdown: [UsageBreakdownItem]
  ) -> [UsagePoolSnapshot] {
    var pools = [
      UsagePoolSnapshot(
        id: usage.modelsPercent == nil ? "included" : "cursor-models",
        name: usage.modelsPercent == nil ? "Included" : "Cursor Models",
        windows: [
          includedWindow(
            usage: usage,
            start: start,
            end: end,
            breakdown: breakdown
          )
        ]
      )
    ]
    if let apiPercent = usage.apiPercent {
      pools.append(
        UsagePoolSnapshot(
          id: "cursor-api",
          name: "Other Models",
          windows: [apiWindow(percentUsed: apiPercent, start: start, end: end)]
        )
      )
    }
    return pools
  }

  static func includedWindow(
    usage: CursorResolvedUsage,
    start: Date?,
    end: Date?,
    breakdown: [UsageBreakdownItem]
  ) -> UsageWindowSnapshot {
    if let modelsPercent = usage.modelsPercent {
      return percentWindow(
        id: "cursor-models-monthly",
        label: "Cursor Models",
        percentUsed: modelsPercent,
        start: start,
        end: end
      )
    }
    return UsageWindowSnapshot(
      id: "cursor-monthly-v2",
      kind: .monthly,
      label: "Included",
      windowStart: start,
      windowEnd: end,
      quotaTotal: usage.quotaTotal,
      used: usage.used,
      remainingPercent: max(0, 100 - usage.totalPercent),
      resetSource: end == nil ? nil : "Cursor billing data",
      breakdown: breakdown.filter {
        $0.id.caseInsensitiveCompare("total") != .orderedSame
          && $0.id.caseInsensitiveCompare("api") != .orderedSame
          && $0.id.caseInsensitiveCompare("auto") != .orderedSame
      }
    )
  }

  static func apiWindow(
    percentUsed: Double,
    start: Date?,
    end: Date?
  ) -> UsageWindowSnapshot {
    percentWindow(
      id: "cursor-api-monthly",
      label: "Other Models",
      percentUsed: percentUsed,
      start: start,
      end: end
    )
  }

  private static func percentWindow(
    id: String,
    label: String,
    percentUsed: Double,
    start: Date?,
    end: Date?
  ) -> UsageWindowSnapshot {
    UsageWindowSnapshot(
      id: id,
      kind: .monthly,
      label: label,
      windowStart: start,
      windowEnd: end,
      quotaTotal: 100,
      used: min(100, max(0, percentUsed)),
      remainingPercent: max(0, 100 - percentUsed),
      resetSource: end == nil ? nil : "Cursor billing data",
      breakdown: []
    )
  }

  static func resolve(
    summary: CursorUsageSummary,
    legacy: CursorLegacyUsage?,
    breakdown: [UsageBreakdownItem]
  ) throws -> CursorResolvedUsage {
    if let requestLimit = legacy?.gpt4?.maxRequestUsage, requestLimit > 0 {
      let used = Double(legacy?.gpt4?.numRequestsTotal ?? legacy?.gpt4?.numRequests ?? 0)
      guard used >= 0 else {
        throw ProviderFailure.invalidResponse("Cursor: invalid request usage")
      }
      return CursorResolvedUsage(
        quotaTotal: Double(requestLimit),
        used: used,
        totalPercent: used / Double(requestLimit) * 100,
        unitNote: "\(Int(used))/\(requestLimit) requests",
        apiPercent: nil
      )
    }

    let plan = summary.individualUsage?.plan
    let overall = summary.individualUsage?.overall
    let limitCents = plan?.limit ?? overall?.limit ?? 0
    let rawUsedCents = plan?.used ?? overall?.used
    guard limitCents.isFinite, limitCents >= 0 else {
      throw ProviderFailure.invalidResponse("Cursor: invalid included usage")
    }
    if let rawUsedCents, !rawUsedCents.isFinite || rawUsedCents < 0 {
      throw ProviderFailure.invalidResponse("Cursor: invalid included usage")
    }

    // Cursor can return plan.used == plan.limit while totalPercentUsed and the
    // component percentages are much lower. Treat its explicit percentage as
    // authoritative and derive the displayed dollar consumption from it.
    let reportedPercent =
      plan?.totalPercentUsed
      ?? breakdown.first(where: {
        $0.id.caseInsensitiveCompare("total") == .orderedSame
      })?.usedPercent
    let quotaTotal = limitCents / 100
    let used: Double
    let totalPercent: Double

    if let reportedPercent {
      guard reportedPercent.isFinite, reportedPercent >= 0 else {
        throw ProviderFailure.invalidResponse("Cursor: invalid included-usage percentage")
      }
      totalPercent = reportedPercent
      used = quotaTotal > 0 ? quotaTotal * reportedPercent / 100 : reportedPercent
    } else if quotaTotal > 0, let rawUsedCents {
      used = rawUsedCents / 100
      totalPercent = used / quotaTotal * 100
    } else {
      throw ProviderFailure.invalidResponse("Cursor: no included-usage total")
    }

    let normalizedQuota = quotaTotal > 0 ? quotaTotal : 100
    let unitNote =
      quotaTotal > 0
      ? "\(used.formatted(.currency(code: "USD"))) / \(quotaTotal.formatted(.currency(code: "USD")))"
      : "Included usage"
    return CursorResolvedUsage(
      quotaTotal: normalizedQuota,
      used: used,
      totalPercent: totalPercent,
      unitNote: unitNote,
      modelsPercent: percent(plan?.autoPercentUsed, breakdownID: "auto", breakdown: breakdown),
      apiPercent: percent(plan?.apiPercentUsed, breakdownID: "api", breakdown: breakdown)
    )
  }

  private static func percent(
    _ planValue: Double?,
    breakdownID: String,
    breakdown: [UsageBreakdownItem]
  ) -> Double? {
    let raw =
      planValue
      ?? breakdown.first(where: {
        $0.id.caseInsensitiveCompare(breakdownID) == .orderedSame
      })?.usedPercent
    guard let raw, raw.isFinite, raw >= 0 else { return nil }
    return raw
  }
}
