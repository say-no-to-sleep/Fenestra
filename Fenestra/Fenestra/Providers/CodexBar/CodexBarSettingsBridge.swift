import CodexBarCore
import Foundation

enum CodexBarSettingsBridge {
  static func environment(
    base: [String: String],
    provider: ProviderID,
    configuration: ProviderConnectionConfiguration
  ) -> [String: String] {
    var environment = ProviderConfigEnvironment.applyProviderConfigOverrides(
      base: base,
      provider: provider.codexBarProvider,
      config: configuration.codexBarConfig(for: provider)
    )
    let apiKey = configuration.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    if !apiKey.isEmpty,
      let override = TokenAccountSupportCatalog.envOverride(
        for: provider.codexBarProvider,
        token: apiKey
      )
    {
      environment.merge(override) { _, configured in configured }
    }
    return environment
  }

  static func settings(
    provider: ProviderID,
    configuration: ProviderConnectionConfiguration
  ) -> ProviderSettingsSnapshot {
    let cookieSource = configuration.cookieMode.codexBarValue
    let cookieHeader = cleaned(configuration.cookieHeader)
    let source = configuration.source

    switch provider {
    case .codex:
      return .make(
        codex: .init(
          usageDataSource: CodexUsageDataSource(rawValue: source.rawValue) ?? .auto,
          cookieSource: cookieSource,
          manualCookieHeader: cookieHeader
        ))
    case .claudeCode:
      return .make(
        claude: .init(
          usageDataSource: ClaudeUsageDataSource(rawValue: source.rawValue) ?? .auto,
          webExtrasEnabled: false,
          cookieSource: cookieSource,
          manualCookieHeader: cookieHeader
        ))
    case .cursor:
      return .make(
        cursor: .init(
          cookieSource: cookieSource,
          manualCookieHeader: cookieHeader
        ))
    case .openCode:
      return .make(
        opencode: .init(
          cookieSource: cookieSource,
          manualCookieHeader: cookieHeader,
          workspaceID: cleaned(configuration.workspaceID)
        ))
    case .openCodeGo:
      return .make(
        opencodego: .init(
          cookieSource: cookieSource,
          manualCookieHeader: cookieHeader,
          workspaceID: cleaned(configuration.workspaceID)
        ))
    case .alibaba:
      return .make(
        alibaba: .init(
          cookieSource: cookieSource,
          manualCookieHeader: cookieHeader,
          apiRegion: AlibabaCodingPlanAPIRegion(rawValue: configuration.region)
            ?? .international
        ))
    case .alibabaTokenPlan:
      return .make(
        alibabaTokenPlan: .init(
          cookieSource: cookieSource,
          manualCookieHeader: cookieHeader
        ))
    case .factory:
      return .make(
        factory: .init(
          cookieSource: cookieSource,
          manualCookieHeader: cookieHeader
        ))
    case .miniMax:
      return .make(
        minimax: .init(
          cookieSource: cookieSource,
          manualCookieHeader: cookieHeader,
          apiRegion: MiniMaxAPIRegion(rawValue: configuration.region) ?? .global
        ))
    case .manus:
      return .make(
        manus: .init(
          cookieSource: cookieSource,
          manualCookieHeader: cookieHeader
        ))
    case .zai:
      return .make(
        zai: .init(
          apiRegion: ZaiAPIRegion(rawValue: configuration.region) ?? .global
        ))
    case .copilot:
      return .make(
        copilot: .init(
          apiToken: cleaned(configuration.apiKey),
          enterpriseHost: cleaned(configuration.enterpriseHost),
          budgetCookieSource: cookieSource,
          manualBudgetCookieHeader: cookieHeader
        ))
    case .kilo:
      return .make(
        kilo: .init(
          usageDataSource: KiloUsageDataSource(rawValue: source.rawValue) ?? .auto,
          extrasEnabled: true
        ))
    case .kimi:
      return .make(
        kimi: .init(
          cookieSource: cookieSource,
          manualCookieHeader: cookieHeader
        ))
    case .augment:
      return .make(
        augment: .init(
          cookieSource: cookieSource,
          manualCookieHeader: cookieHeader
        ))
    case .moonshot:
      return .make(
        moonshot: .init(
          region: MoonshotRegion(rawValue: configuration.region)
        ))
    case .amp:
      return .make(
        amp: .init(
          cookieSource: cookieSource,
          manualCookieHeader: cookieHeader
        ))
    case .t3Chat:
      return .make(
        t3chat: .init(
          cookieSource: cookieSource,
          manualCookieHeader: cookieHeader
        ))
    case .devin:
      return .make(
        devin: .init(
          cookieSource: cookieSource,
          manualBearerToken: cookieHeader,
          organization: cleaned(configuration.workspaceID)
        ))
    case .commandCode:
      return .make(
        commandcode: .init(
          cookieSource: cookieSource,
          manualCookieHeader: cookieHeader
        ))
    case .ollama:
      return .make(
        ollama: .init(
          cookieSource: cookieSource,
          manualCookieHeader: cookieHeader
        ))
    case .jetBrains:
      return .make(
        jetbrains: .init(
          ideBasePath: cleaned(configuration.enterpriseHost)
        ))
    case .windsurf:
      return .make(
        windsurf: .init(
          usageDataSource: WindsurfUsageDataSource(rawValue: source.rawValue) ?? .auto,
          cookieSource: cookieSource,
          manualCookieHeader: cookieHeader
        ))
    case .perplexity:
      return .make(
        perplexity: .init(
          cookieSource: cookieSource,
          manualCookieHeader: cookieHeader
        ))
    case .mimo:
      return .make(
        mimo: .init(
          cookieSource: cookieSource,
          manualCookieHeader: cookieHeader
        ))
    case .abacus:
      return .make(
        abacus: .init(
          cookieSource: cookieSource,
          manualCookieHeader: cookieHeader
        ))
    case .mistral:
      return .make(
        mistral: .init(
          cookieSource: cookieSource,
          manualCookieHeader: cookieHeader
        ))
    case .stepFun:
      return .make(
        stepfun: .init(
          cookieSource: cookieSource,
          manualToken: cookieHeader ?? "",
          username: cleaned(configuration.apiKey) ?? "",
          password: cleaned(configuration.secretKey) ?? ""
        ))
    default:
      return .make()
    }
  }

  private static func cleaned(_ value: String) -> String? {
    let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return value.isEmpty ? nil : value
  }
}
