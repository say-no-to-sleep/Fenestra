import Testing

@testable import Fenestra

@Suite("Usage window kind inference")
struct UsageWindowKindTests {
  @Test func fiveHourWindow() {
    #expect(UsageWindowKind.inferred(from: 5 * 60 * 60) == .fiveHour)
  }

  @Test func weeklyWindow() {
    #expect(UsageWindowKind.inferred(from: 7 * 24 * 60 * 60) == .weekly)
  }

  @Test func monthlyWindow() {
    #expect(UsageWindowKind.inferred(from: 30 * 24 * 60 * 60) == .monthly)
  }

  @Test func monthlyPanelLabel() {
    #expect(UsageWindowKind.monthly.panelLabel == "Monthly")
  }
}
