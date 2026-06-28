import Foundation

struct CursorResolvedUsage: Equatable {
  let quotaTotal: Double
  let used: Double
  let totalPercent: Double
  let unitNote: String
}

enum CursorUsageResolver {
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
        unitNote: "\(Int(used))/\(requestLimit) requests"
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
      unitNote: unitNote
    )
  }
}
