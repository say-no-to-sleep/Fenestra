import Foundation
import Testing

@testable import Fenestra

@Suite("Cursor usage resolution")
struct CursorUsageResolverTests {
  @Test @MainActor
  func reportedPercentageWinsOverContradictoryRawDollarFields() throws {
    let summary = CursorUsageSummary(
      billingCycleStart: nil,
      billingCycleEnd: nil,
      membershipType: nil,
      individualUsage: CursorIndividualUsage(
        plan: CursorPlanUsage(
          used: 2_000,
          limit: 2_000,
          totalPercentUsed: 27.166_666_666_7
        ),
        overall: nil
      )
    )

    let result = try CursorUsageResolver.resolve(
      summary: summary,
      legacy: nil,
      breakdown: []
    )

    #expect(abs(result.quotaTotal - 20) < 0.0001)
    #expect(abs(result.used - 5.433_333_333_34) < 0.0001)
    #expect(abs(result.totalPercent - 27.166_666_666_7) < 0.0001)
  }

  @Test @MainActor
  func rawDollarRatioRemainsAvailableAsFallback() throws {
    let summary = CursorUsageSummary(
      billingCycleStart: nil,
      billingCycleEnd: nil,
      membershipType: nil,
      individualUsage: CursorIndividualUsage(
        plan: CursorPlanUsage(used: 500, limit: 2_000, totalPercentUsed: nil),
        overall: nil
      )
    )

    let result = try CursorUsageResolver.resolve(
      summary: summary,
      legacy: nil,
      breakdown: []
    )

    #expect(abs(result.used - 5) < 0.0001)
    #expect(abs(result.totalPercent - 25) < 0.0001)
  }

  @Test @MainActor
  func includedWindowUsesCursorModelsPercentWhenPresent() {
    let window = CursorUsageResolver.includedWindow(
      usage: CursorResolvedUsage(
        quotaTotal: 20,
        used: 7.66,
        totalPercent: 38.3,
        unitNote: "$7.66 / $20.00",
        modelsPercent: 50
      ),
      start: Date(timeIntervalSince1970: 1_000),
      end: Date(timeIntervalSince1970: 2_000),
      breakdown: [UsageBreakdownItem(id: "auto", label: "Auto", usedPercent: 50)]
    )

    #expect(window.id == "cursor-models-monthly")
    #expect(window.label == "Cursor Models")
    #expect(window.remainingPercent == 50)
    #expect(window.breakdown.isEmpty)
  }

  @Test @MainActor
  func includedWindowFallsBackToTotalWhenModelsPercentIsMissing() {
    let items = [
      UsageBreakdownItem(id: "total", label: "Total", usedPercent: 25),
      UsageBreakdownItem(id: "api", label: "API", usedPercent: 20),
      UsageBreakdownItem(id: "auto", label: "Auto", usedPercent: 30),
    ]
    let window = CursorUsageResolver.includedWindow(
      usage: CursorResolvedUsage(
        quotaTotal: 20,
        used: 5,
        totalPercent: 25,
        unitNote: "$5 / $20"
      ),
      start: Date(timeIntervalSince1970: 1_000),
      end: Date(timeIntervalSince1970: 2_000),
      breakdown: items
    )

    #expect(window.id == "cursor-monthly-v2")
    #expect(window.label == "Included")
    #expect(window.remainingPercent == 75)
    #expect(window.breakdown.isEmpty)
  }

  @Test @MainActor
  func poolsMatchCursorModelsAndOtherModelsMeters() {
    let pools = CursorUsageResolver.pools(
      usage: CursorResolvedUsage(
        quotaTotal: 20,
        used: 7.66,
        totalPercent: 38.3,
        unitNote: "$7.66 / $20.00",
        modelsPercent: 50,
        apiPercent: 26
      ),
      start: Date(timeIntervalSince1970: 1_000),
      end: Date(timeIntervalSince1970: 2_000),
      breakdown: []
    )

    #expect(pools.map(\.name) == ["Cursor Models", "Other Models"])
    #expect(pools[0].windows[0].remainingPercent == 50)
    #expect(pools[1].windows[0].remainingPercent == 74)
    #expect(pools[1].windows[0].label == "Other Models")
  }

  @Test @MainActor
  func poolsOmitAPIWhenPercentIsMissing() {
    let pools = CursorUsageResolver.pools(
      usage: CursorResolvedUsage(
        quotaTotal: 20,
        used: 5,
        totalPercent: 25,
        unitNote: "$5 / $20"
      ),
      start: Date(timeIntervalSince1970: 1_000),
      end: Date(timeIntervalSince1970: 2_000),
      breakdown: []
    )

    #expect(pools.map(\.id) == ["included"])
  }

  @Test @MainActor
  func resolveReadsModelsAndAPIPercentsFromPlan() throws {
    let summary = CursorUsageSummary(
      billingCycleStart: nil,
      billingCycleEnd: nil,
      membershipType: nil,
      individualUsage: CursorIndividualUsage(
        plan: CursorPlanUsage(
          used: 766,
          limit: 2_000,
          totalPercentUsed: 38.3,
          autoPercentUsed: 50,
          apiPercentUsed: 26
        ),
        overall: nil
      )
    )

    let result = try CursorUsageResolver.resolve(
      summary: summary,
      legacy: nil,
      breakdown: []
    )

    #expect(abs((result.modelsPercent ?? -1) - 50) < 0.0001)
    #expect(abs((result.apiPercent ?? -1) - 26) < 0.0001)
  }

  @Test @MainActor
  func resolveFallsBackToBreakdownAPIPercent() throws {
    let summary = CursorUsageSummary(
      billingCycleStart: nil,
      billingCycleEnd: nil,
      membershipType: nil,
      individualUsage: CursorIndividualUsage(
        plan: CursorPlanUsage(used: 500, limit: 2_000, totalPercentUsed: 25),
        overall: nil
      )
    )

    let result = try CursorUsageResolver.resolve(
      summary: summary,
      legacy: nil,
      breakdown: [UsageBreakdownItem(id: "api", label: "API", usedPercent: 22)]
    )

    #expect(abs((result.apiPercent ?? -1) - 22) < 0.0001)
  }

  @Test @MainActor
  func planUsageDecodesAPIPercent() throws {
    let data = Data(
      #"{"used":500,"limit":2000,"totalPercentUsed":25,"apiPercentUsed":18}"#.utf8
    )
    let plan = try JSONDecoder().decode(CursorPlanUsage.self, from: data)
    #expect(plan.apiPercentUsed == 18)
  }

  @Test @MainActor
  func legacyRequestPlanDoesNotExposeAPIPercent() throws {
    let summary = CursorUsageSummary(
      billingCycleStart: nil,
      billingCycleEnd: nil,
      membershipType: nil,
      individualUsage: CursorIndividualUsage(
        plan: CursorPlanUsage(used: 500, limit: 2_000, apiPercentUsed: 40),
        overall: nil
      )
    )
    let legacy = CursorLegacyUsage(
      gpt4: CursorLegacyModelUsage(
        numRequests: 10,
        numRequestsTotal: 12,
        maxRequestUsage: 500
      )
    )

    let result = try CursorUsageResolver.resolve(
      summary: summary,
      legacy: legacy,
      breakdown: [UsageBreakdownItem(id: "api", label: "API", usedPercent: 40)]
    )

    #expect(result.apiPercent == nil)
  }
}
