import CodexBarCore
import Foundation
import Security

enum ProviderDataSource: String, CaseIterable, Codable, Identifiable, Sendable {
  case auto
  case web
  case cli
  case oauth
  case api

  var id: String { rawValue }

  var label: String {
    switch self {
    case .auto: "Automatic"
    case .web: "Web session"
    case .cli: "CLI / local"
    case .oauth: "OAuth"
    case .api: "API key"
    }
  }

  var codexBarValue: ProviderSourceMode {
    ProviderSourceMode(rawValue: rawValue) ?? .auto
  }
}

enum ProviderCookieMode: String, CaseIterable, Codable, Identifiable, Sendable {
  case auto
  case manual
  case off

  var id: String { rawValue }

  var label: String {
    switch self {
    case .auto: "Automatic"
    case .manual: "Manual"
    case .off: "Off"
    }
  }

  var codexBarValue: ProviderCookieSource {
    ProviderCookieSource(rawValue: rawValue) ?? .auto
  }
}

struct ProviderConnectionConfiguration: Equatable, Sendable {
  var source: ProviderDataSource = .auto
  var cookieMode: ProviderCookieMode = .auto
  var apiKey = ""
  var secretKey = ""
  var cookieHeader = ""
  var region = ""
  var workspaceID = ""
  var enterpriseHost = ""
  var awsProfile = ""
  var awsAuthMode = ""

  func codexBarConfig(for provider: ProviderID) -> ProviderConfig {
    ProviderConfig(
      id: provider.codexBarProvider,
      source: source.codexBarValue,
      apiKey: cleaned(apiKey),
      secretKey: cleaned(secretKey),
      cookieHeader: cleaned(cookieHeader),
      cookieSource: cookieMode.codexBarValue,
      region: cleaned(region),
      workspaceID: cleaned(workspaceID),
      enterpriseHost: cleaned(enterpriseHost),
      awsProfile: cleaned(awsProfile),
      awsAuthMode: cleaned(awsAuthMode)
    )
  }

  init() {}

  private func cleaned(_ value: String) -> String? {
    let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return value.isEmpty ? nil : value
  }
}

extension ProviderID {
  var supportedDataSources: [ProviderDataSource] {
    let supported = ProviderDescriptorRegistry.descriptor(for: codexBarProvider)
      .fetchPlan.sourceModes
    return ProviderDataSource.allCases.filter {
      supported.contains($0.codexBarValue)
    }
  }

  var supportsAPIKeyConfiguration: Bool {
    if ProviderConfigEnvironment.supportsAPIKeyOverride(for: codexBarProvider)
      || self == .stepFun
    {
      return true
    }
    guard let support = TokenAccountSupportCatalog.support(for: codexBarProvider) else {
      return false
    }
    if case .environment = support.injection {
      return true
    }
    return false
  }

  var supportsCookieConfiguration: Bool {
    switch self {
    case .codex, .claudeCode, .cursor, .openCode, .openCodeGo, .alibaba,
      .alibabaTokenPlan, .factory, .miniMax, .manus, .kimi, .augment, .amp,
      .t3Chat, .ollama, .windsurf, .perplexity, .mimo, .abacus, .mistral,
      .devin, .sakana, .commandCode, .stepFun:
      true
    default:
      false
    }
  }

  var supportsRegionConfiguration: Bool {
    switch self {
    case .alibaba, .miniMax, .zai, .moonshot, .bedrock:
      true
    default:
      false
    }
  }

  var supportsWorkspaceConfiguration: Bool {
    switch self {
    case .openAI, .azureOpenAI, .openCode, .openCodeGo, .deepgram, .devin:
      true
    default:
      false
    }
  }

  var supportsHostConfiguration: Bool {
    switch self {
    case .azureOpenAI, .kimi, .copilot, .llmProxy, .liteLLM, .jetBrains:
      true
    default:
      false
    }
  }

  var hasConnectionConfiguration: Bool {
    supportedDataSources.count > 1
      || supportsAPIKeyConfiguration
      || supportsCookieConfiguration
      || supportsRegionConfiguration
      || supportsWorkspaceConfiguration
      || supportsHostConfiguration
      || self == .bedrock
  }
}

@MainActor
protocol ProviderSecretStoring {
  func value(provider: ProviderID, field: ProviderSecretField) throws -> String?
  func setValue(_ value: String?, provider: ProviderID, field: ProviderSecretField) throws
}

enum ProviderSecretField: String, CaseIterable, Sendable {
  case apiKey
  case secretKey
  case cookieHeader
}

@MainActor
final class KeychainProviderSecretStore: ProviderSecretStoring {
  private let service = "com.eugenezhao.Fenestra.provider-credentials"

  func value(provider: ProviderID, field: ProviderSecretField) throws -> String? {
    var query = baseQuery(provider: provider, field: field)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUISkip

    var result: AnyObject?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    switch status {
    case errSecSuccess:
      guard let data = result as? Data else { return nil }
      return String(data: data, encoding: .utf8)
    case errSecItemNotFound:
      return nil
    default:
      throw ProviderSecretStoreError.operationFailed(status)
    }
  }

  func setValue(
    _ value: String?,
    provider: ProviderID,
    field: ProviderSecretField
  ) throws {
    let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines)
    let query = baseQuery(provider: provider, field: field)
    guard let normalized, !normalized.isEmpty else {
      let status = SecItemDelete(query as CFDictionary)
      guard status == errSecSuccess || status == errSecItemNotFound else {
        throw ProviderSecretStoreError.operationFailed(status)
      }
      return
    }

    let data = Data(normalized.utf8)
    let updateStatus = SecItemUpdate(
      query as CFDictionary,
      [kSecValueData as String: data] as CFDictionary
    )
    if updateStatus == errSecSuccess {
      return
    }
    guard updateStatus == errSecItemNotFound else {
      throw ProviderSecretStoreError.operationFailed(updateStatus)
    }

    var item = query
    item[kSecValueData as String] = data
    let addStatus = SecItemAdd(item as CFDictionary, nil)
    guard addStatus == errSecSuccess else {
      throw ProviderSecretStoreError.operationFailed(addStatus)
    }
  }

  private func baseQuery(
    provider: ProviderID,
    field: ProviderSecretField
  ) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: "\(provider.settingsKey).\(field.rawValue)",
    ]
  }
}

private enum ProviderSecretStoreError: LocalizedError {
  case operationFailed(OSStatus)

  var errorDescription: String? {
    switch self {
    case .operationFailed(let status):
      "Could not update provider credentials: "
        + (SecCopyErrorMessageString(status, nil) as String? ?? "\(status)")
    }
  }
}
