import Foundation
import Testing

@testable import Fenestra

@Suite("Provider catalog")
struct ProviderCatalogTests {
  private static let codexBarProviderIDs: Set<String> = [
    "codex", "openai", "azureopenai", "claude", "cursor", "opencode",
    "opencodego", "alibaba", "alibabatokenplan", "factory", "gemini",
    "antigravity", "copilot", "devin", "zai", "minimax", "manus", "kimi",
    "kilo", "kiro", "vertexai", "augment", "jetbrains", "kimik2", "moonshot",
    "amp", "t3chat", "ollama", "synthetic", "warp", "openrouter",
    "elevenlabs", "windsurf", "zed", "perplexity", "mimo", "doubao", "sakana",
    "abacus", "mistral", "deepseek", "codebuff", "crof", "venice",
    "commandcode", "stepfun", "bedrock", "grok", "groq", "llmproxy", "litellm",
    "deepgram", "poe", "chutes",
  ]

  @Test @MainActor
  func coversEveryCodexBarProviderExactlyOnce() {
    let mappedIDs = Set(ProviderID.allCases.map(\.codexBarProvider.rawValue))

    #expect(ProviderID.allCases.count == 54)
    #expect(mappedIDs == Self.codexBarProviderIDs)
  }

  @Test @MainActor
  func everyProviderHasStableDisplayMetadata() {
    for providerID in ProviderID.allCases {
      #expect(!providerID.id.isEmpty)
      #expect(!providerID.displayName.isEmpty)
      #expect(!providerID.systemImage.isEmpty)
    }
  }

  @Test @MainActor
  func newProviderToggleAndCadencePersist() throws {
    let suiteName = "FenestraTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let settings = AppSettings(defaults: defaults)
    settings.load()
    #expect(!settings.isEnabled(.openRouter))

    settings.setEnabled(true, for: .openRouter)
    settings.setCadence(.fifteenMinutes, for: .openRouter)

    let reloaded = AppSettings(defaults: defaults)
    reloaded.load()
    #expect(reloaded.isEnabled(.openRouter))
    #expect(reloaded.cadence(for: .openRouter) == .fifteenMinutes)
  }
}
