import Foundation

struct ClaudeCredentials: Sendable {
  let accessToken: String
  let source: String
}

@MainActor
enum ClaudeCredentialStore {
  private static let keychainService = "Claude Code-credentials"

  static func load(allowKeychainPrompt: Bool = false) throws -> ClaudeCredentials {
    let fileURL = FileManager.default.homeDirectoryForCurrentUser
      .appending(path: ".claude/.credentials.json")
    if let data = try? Data(contentsOf: fileURL),
      let credentials = parse(data, source: "~/.claude/.credentials.json")
    {
      return credentials
    }

    if let data = try KeychainReader.genericPassword(
      service: keychainService,
      allowInteraction: allowKeychainPrompt
    ),
      let credentials = parse(data, source: "Claude Code Keychain")
    {
      return credentials
    }

    if !allowKeychainPrompt {
      throw ProviderFailure.unavailable(
        "Claude: OAuth Keychain access requires approval"
      )
    }
    throw ProviderFailure.notLoggedIn(
      "Claude: Pro/Max OAuth session unavailable — run `claude auth login --claudeai`"
    )
  }

  static func authorizeKeychainAccess() throws {
    KeychainReader.invalidate(service: keychainService)
    _ = try load(allowKeychainPrompt: true)
  }

  private static func parse(_ data: Data, source: String) -> ClaudeCredentials? {
    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      return nil
    }
    let oauth =
      (root["claudeAiOauth"] as? [String: Any])
      ?? (root["claude_ai_oauth"] as? [String: Any])
      ?? root
    guard let token = firstString(oauth, keys: ["accessToken", "access_token", "token"]),
      !token.isEmpty
    else {
      return nil
    }
    return ClaudeCredentials(
      accessToken: token,
      source: source
    )
  }

  private static func firstString(_ object: [String: Any], keys: [String]) -> String? {
    for key in keys {
      if let value = object[key] as? String {
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
      }
    }
    return nil
  }
}
