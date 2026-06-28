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
}
