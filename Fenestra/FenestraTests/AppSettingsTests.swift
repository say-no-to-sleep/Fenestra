import Foundation
import Testing

@testable import Fenestra

@Suite("Settings persistence")
struct AppSettingsTests {
  @Test @MainActor
  func loadingOneSettingDoesNotOverwriteSettingsNotYetLoaded() throws {
    let suiteName = "FenestraTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.set(false, forKey: "providers.claude.enabled")
    defaults.set(RefreshCadence.fiveMinutes.rawValue, forKey: "providers.codex.cadence")
    defaults.set(-200.0, forKey: "notifications.badPaceThreshold")

    let settings = AppSettings(defaults: defaults)
    settings.load()

    #expect(!settings.claudeEnabled)
    #expect(settings.codexCadence == .fiveMinutes)
    #expect(settings.badPaceThreshold == -75)
  }

  @Test @MainActor
  func expiredClaudeResetOverrideIsDisabledInsteadOfInventingANewReset() throws {
    let suiteName = "FenestraTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.set(true, forKey: "providers.claude.useWeeklyResetOverride")
    defaults.set(
      Date().addingTimeInterval(-60),
      forKey: "providers.claude.weeklyResetOverride"
    )

    let settings = AppSettings(defaults: defaults)
    settings.load()

    #expect(!settings.useClaudeWeeklyResetOverride)
    #expect(settings.manualClaudeWeeklyReset == nil)
  }
}

@Suite("Network restrictions")
struct RestrictedHTTPClientTests {
  @Test
  func onlyProviderHTTPSAndLoopbackURLsAreAllowed() {
    #expect(
      RestrictedHTTPClient.isAllowed(
        URL(string: "https://api.anthropic.com/api/oauth/usage")
      ))
    #expect(
      !RestrictedHTTPClient.isAllowed(
        URL(string: "http://api.anthropic.com/api/oauth/usage")
      ))
    #expect(
      !RestrictedHTTPClient.isAllowed(
        URL(string: "https://api.anthropic.com.evil.example/steal")
      ))
    #expect(
      RestrictedHTTPClient.isAllowed(
        URL(string: "http://127.0.0.1:12345/local")
      ))
  }
}
