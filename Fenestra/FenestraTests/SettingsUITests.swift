import XCTest

@testable import Fenestra

private final class InMemoryProviderSecretStore: ProviderSecretStoring {
  func value(provider: ProviderID, field: ProviderSecretField) throws -> String? { nil }
  func setValue(_ value: String?, provider: ProviderID, field: ProviderSecretField) throws {}
}

final class SettingsUITests: XCTestCase {
  @MainActor
  func testProviderSearchIsCaseInsensitive() {
    XCTAssertEqual(
      ProviderCatalogFilter.matches(query: "cOdEx", providers: [.cursor, .codex, .claudeCode]),
      [.codex]
    )
  }

  @MainActor
  func testProviderHealthLabels() {
    XCTAssertEqual(
      ProviderHealth(enabled: false, state: ProviderDisplayState()).label,
      "Disabled"
    )
    XCTAssertEqual(
      ProviderHealth(
        enabled: true,
        state: ProviderDisplayState(availability: .available)
      ).label,
      "Connected"
    )
    XCTAssertEqual(
      ProviderHealth(
        enabled: true,
        state: ProviderDisplayState(availability: .unavailable("Login needed"))
      ).label,
      "Needs attention"
    )
  }

  @MainActor
  func testThresholdMagnitudeKeepsNegativeStorage() {
    let settings = AppSettings(
      defaults: UserDefaults(suiteName: #function)!,
      secretStore: InMemoryProviderSecretStore()
    )
    settings.badPaceThresholdMagnitude = 35
    XCTAssertEqual(settings.badPaceThreshold, -35)
    XCTAssertEqual(settings.badPaceThresholdMagnitude, 35)
  }
}
