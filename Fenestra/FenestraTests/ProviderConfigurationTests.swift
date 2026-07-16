import CodexBarCore
import Foundation
import Testing

@testable import Fenestra

@Suite("Provider configuration")
struct ProviderConfigurationTests {
  @Test @MainActor
  func sourceCatalogMatchesEveryDescriptor() {
    for providerID in ProviderID.allCases {
      let expected = ProviderDescriptorRegistry.descriptor(
        for: providerID.codexBarProvider
      ).fetchPlan.sourceModes
      let actual = Set(providerID.supportedDataSources.map(\.codexBarValue))

      #expect(!actual.isEmpty)
      #expect(actual == expected)
      #expect(actual.contains(.auto))
    }
  }

  @Test @MainActor
  func everyProviderBuildsSettingsAndEnvironment() {
    for providerID in ProviderID.allCases {
      var configuration = ProviderConnectionConfiguration()
      configuration.source = providerID.supportedDataSources.first ?? .auto
      configuration.apiKey = "test-api-key"
      configuration.secretKey = "test-secret"
      configuration.cookieHeader = "session=test"
      configuration.cookieMode = .manual
      configuration.region = "test-region"
      configuration.workspaceID = "test-workspace"
      configuration.enterpriseHost = "https://example.test"

      _ = CodexBarSettingsBridge.settings(
        provider: providerID,
        configuration: configuration
      )
      _ = CodexBarSettingsBridge.environment(
        base: [:],
        provider: providerID,
        configuration: configuration
      )
    }
  }

  @Test @MainActor
  func apiAndDedicatedOverridesReachCodexBarEnvironment() {
    var openRouter = ProviderConnectionConfiguration()
    openRouter.apiKey = "openrouter-secret"
    let openRouterEnvironment = CodexBarSettingsBridge.environment(
      base: [:],
      provider: .openRouter,
      configuration: openRouter
    )
    #expect(openRouterEnvironment["OPENROUTER_API_KEY"] == "openrouter-secret")

    var deepSeek = ProviderConnectionConfiguration()
    deepSeek.apiKey = "deepseek-secret"
    let deepSeekEnvironment = CodexBarSettingsBridge.environment(
      base: [:],
      provider: .deepSeek,
      configuration: deepSeek
    )
    #expect(deepSeekEnvironment["DEEPSEEK_API_KEY"] == "deepseek-secret")

    var bedrock = ProviderConnectionConfiguration()
    bedrock.apiKey = "access-key"
    bedrock.secretKey = "secret-key"
    bedrock.region = "ca-central-1"
    bedrock.awsAuthMode = "keys"
    let bedrockEnvironment = CodexBarSettingsBridge.environment(
      base: [:],
      provider: .bedrock,
      configuration: bedrock
    )
    #expect(bedrockEnvironment["AWS_ACCESS_KEY_ID"] == "access-key")
    #expect(bedrockEnvironment["AWS_SECRET_ACCESS_KEY"] == "secret-key")
    #expect(bedrockEnvironment["AWS_REGION"] == "ca-central-1")
  }

  @Test @MainActor
  func everyConfigurableAPIKeyIsInjected() {
    for providerID in ProviderID.allCases
    where providerID.supportsAPIKeyConfiguration && providerID != .stepFun {
      var configuration = ProviderConnectionConfiguration()
      configuration.apiKey = "fenestra-test-key"
      if providerID == .bedrock {
        configuration.secretKey = "fenestra-test-secret"
        configuration.awsAuthMode = "keys"
      }
      let environment = CodexBarSettingsBridge.environment(
        base: [:],
        provider: providerID,
        configuration: configuration
      )

      #expect(
        environment.values.contains("fenestra-test-key"),
        "No API-key environment injection for \(providerID.displayName)"
      )
    }
  }

  @Test @MainActor
  func connectionChoicesPersistWhileSecretsUseSecretStore() throws {
    let suiteName = "FenestraTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let secrets = MemoryProviderSecretStore()
    let settings = AppSettings(defaults: defaults, secretStore: secrets)
    settings.load()

    var configuration = settings.connectionConfiguration(for: .openRouter)
    configuration.source = .api
    configuration.apiKey = "secret-value"
    configuration.enterpriseHost = "https://openrouter.ai"
    try settings.setConnectionConfiguration(configuration, for: .openRouter)

    #expect(
      defaults.string(forKey: "providers.openrouter.source") == "api"
    )
    #expect(
      defaults.object(forKey: "providers.openrouter.apiKey") == nil
    )

    let reloaded = AppSettings(defaults: defaults, secretStore: secrets)
    reloaded.load()
    let result = reloaded.connectionConfiguration(for: .openRouter)
    #expect(result.source == .api)
    #expect(result.apiKey == "secret-value")
    #expect(result.enterpriseHost == "https://openrouter.ai")
  }

  @Test @MainActor
  func adapterMapsCoreWindowsCostAndCredits() throws {
    let now = Date()
    let reset = now.addingTimeInterval(5 * 60 * 60)
    let usage = CodexBarCore.UsageSnapshot(
      primary: RateWindow(
        usedPercent: 25,
        windowMinutes: 300,
        resetsAt: reset,
        resetDescription: nil
      ),
      secondary: nil,
      providerCost: ProviderCostSnapshot(
        used: 4,
        limit: 20,
        currencyCode: "USD",
        period: "Monthly",
        resetsAt: nil,
        updatedAt: now
      ),
      updatedAt: now
    )
    let result = ProviderFetchResult(
      usage: usage,
      credits: CreditsSnapshot(
        remaining: 16,
        events: [],
        updatedAt: now
      ),
      dashboard: nil,
      sourceLabel: "fixture",
      strategyID: "fixture.api",
      strategyKind: .apiToken
    )

    let mapped = CodexBarProvider(id: .openRouter).map(result)
    let windows = try #require(mapped.pools.first?.windows)
    #expect(windows.count == 2)
    #expect(windows[0].remainingPercent == 75)
    #expect(windows[0].windowEnd == reset)
    #expect(windows[1].remainingPercent == 80)
    #expect(mapped.sourceDescription == "fixture")
    #expect(mapped.notes.contains("Balance 16.00"))
  }

  @Test @MainActor
  func cursorAdapterCollapsesComponentsIntoOneMonthlyWindow() throws {
    let now = Date()
    let reset = now.addingTimeInterval(30 * 24 * 60 * 60)
    let usage = CodexBarCore.UsageSnapshot(
      primary: RateWindow(
        usedPercent: 25,
        windowMinutes: 30 * 24 * 60,
        resetsAt: reset,
        resetDescription: nil
      ),
      secondary: RateWindow(
        usedPercent: 30,
        windowMinutes: 30 * 24 * 60,
        resetsAt: reset,
        resetDescription: nil
      ),
      tertiary: RateWindow(
        usedPercent: 10,
        windowMinutes: 30 * 24 * 60,
        resetsAt: reset,
        resetDescription: nil
      ),
      updatedAt: now,
      identity: ProviderIdentitySnapshot(
        providerID: .cursor,
        accountEmail: "hidden@example.com",
        accountOrganization: nil,
        loginMethod: "Cursor Pro"
      )
    )
    let result = ProviderFetchResult(
      usage: usage,
      credits: nil,
      dashboard: nil,
      sourceLabel: "fixture",
      strategyID: "fixture.web",
      strategyKind: .web
    )

    let mapped = CodexBarProvider(id: .cursor).map(result)
    let windows = try #require(mapped.pools.first?.windows)
    #expect(windows.count == 1)
    #expect(windows[0].id == "cursor-monthly-v2")
    #expect(windows[0].breakdown.map(\.usedPercent) == [30, 10])
    #expect(mapped.planDescription == "Cursor Pro")
  }

  @Test @MainActor
  func antigravityAdapterBuildsTwoOrderedQuotaPools() throws {
    let now = Date()
    func window(_ minutes: Int, used: Double) -> RateWindow {
      RateWindow(
        usedPercent: used,
        windowMinutes: minutes,
        resetsAt: now.addingTimeInterval(Double(minutes) * 60),
        resetDescription: nil
      )
    }
    let usage = CodexBarCore.UsageSnapshot(
      primary: nil,
      secondary: nil,
      extraRateWindows: [
        NamedRateWindow(id: "gemini-5h", title: "Gemini 5-hour", window: window(300, used: 20)),
        NamedRateWindow(id: "gemini-weekly", title: "Gemini weekly", window: window(10_080, used: 30)),
        NamedRateWindow(id: "claude-5h", title: "Claude/GPT 5-hour", window: window(300, used: 40)),
        NamedRateWindow(id: "claude-weekly", title: "Claude/GPT weekly", window: window(10_080, used: 50)),
      ],
      updatedAt: now
    )
    let result = ProviderFetchResult(
      usage: usage,
      credits: nil,
      dashboard: nil,
      sourceLabel: "fixture",
      strategyID: "fixture.web",
      strategyKind: .web
    )

    let pools = CodexBarProvider(id: .antigravity).map(result).pools
    #expect(pools.map(\.name) == ["Gemini", "Claude/GPT-OSS"])
    #expect(pools.map { $0.windows.map(\.label) } == [["5-hour", "Weekly"], ["5-hour", "Weekly"]])
  }
}

@MainActor
private final class MemoryProviderSecretStore: ProviderSecretStoring {
  private var values: [String: String] = [:]

  func value(provider: ProviderID, field: ProviderSecretField) throws -> String? {
    values[key(provider: provider, field: field)]
  }

  func setValue(
    _ value: String?,
    provider: ProviderID,
    field: ProviderSecretField
  ) throws {
    let key = key(provider: provider, field: field)
    let value = value?.trimmingCharacters(in: .whitespacesAndNewlines)
    if let value, !value.isEmpty {
      values[key] = value
    } else {
      values.removeValue(forKey: key)
    }
  }

  private func key(provider: ProviderID, field: ProviderSecretField) -> String {
    "\(provider.settingsKey).\(field.rawValue)"
  }
}
