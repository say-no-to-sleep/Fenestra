import Foundation

struct ClaudeCredentials: Sendable {
  let accessToken: String
  let refreshToken: String?
  let expiresAt: Date?
  let source: String
  let origin: ClaudeCredentialOrigin
  let rawJSON: Data

  func isExpired(now: Date = Date(), skew: TimeInterval = 5 * 60) -> Bool {
    guard let expiresAt else { return false }
    return expiresAt.timeIntervalSince(now) <= skew
  }

  var fingerprint: Int {
    var hasher = Hasher()
    hasher.combine(accessToken)
    hasher.combine(refreshToken)
    hasher.combine(expiresAt?.timeIntervalSince1970)
    return hasher.finalize()
  }
}

enum ClaudeCredentialOrigin: Sendable, Equatable {
  case file(URL)
  case keychain
}

@MainActor
enum ClaudeCredentialStore {
  static let keychainService = "Claude Code-credentials"
  /// Each uncached Keychain read can cost a macOS authorization prompt, and the CLI
  /// resets this item's ACL whenever it rotates tokens. Re-reading on every poll is
  /// what turns "Always Allow" into a prompt every refresh.
  static let keychainRecheckInterval: TimeInterval = 10 * 60
  private static var lastKeychainRecheck: Date?

  static func load(allowKeychainPrompt: Bool = false) throws -> ClaudeCredentials {
    let credentials = try loadOnce(allowKeychainPrompt: allowKeychainPrompt)
    guard credentials.isExpired(), credentials.origin == .keychain else {
      return credentials
    }
    // The CLI may have rotated the token behind us; look again, but not every poll.
    return try reload(allowKeychainPrompt: allowKeychainPrompt) ?? credentials
  }

  /// Re-read the Keychain, throttled to `keychainRecheckInterval`.
  /// Returns nil when the throttle suppressed the read.
  @discardableResult
  static func reload(allowKeychainPrompt: Bool = false) throws -> ClaudeCredentials? {
    let now = Date()
    if let lastKeychainRecheck,
      now.timeIntervalSince(lastKeychainRecheck) < keychainRecheckInterval
    {
      return nil
    }
    lastKeychainRecheck = now
    KeychainReader.invalidate(service: keychainService)
    return try loadOnce(allowKeychainPrompt: allowKeychainPrompt)
  }

  static func authorizeKeychainAccess() throws {
    lastKeychainRecheck = nil
    KeychainReader.invalidate(service: keychainService)
    _ = try load(allowKeychainPrompt: true)
  }

  static func persist(_ tokens: ClaudeOAuthTokens, replacing credentials: ClaudeCredentials) throws {
    let updated = try ClaudeOAuthRefresher.applying(tokens, to: credentials.rawJSON)
    switch credentials.origin {
    case .file(let url):
      try updated.write(to: url, options: .atomic)
    case .keychain:
      try KeychainReader.updateGenericPassword(service: keychainService, data: updated)
    }
  }

  static func parse(
    _ data: Data,
    source: String,
    origin: ClaudeCredentialOrigin
  ) -> ClaudeCredentials? {
    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      return nil
    }
    let oauth =
      (root["claudeAiOauth"] as? [String: Any])
      ?? (root["claude_ai_oauth"] as? [String: Any])
      ?? root
    guard let token = ClaudeOAuthRefresher.stringValue(
      oauth,
      keys: ["accessToken", "access_token", "token"]
    )
    else {
      return nil
    }
    return ClaudeCredentials(
      accessToken: token,
      refreshToken: ClaudeOAuthRefresher.stringValue(
        oauth,
        keys: ["refreshToken", "refresh_token"]
      ),
      expiresAt: ProviderDateParser.date(from: oauth["expiresAt"] ?? oauth["expires_at"]),
      source: source,
      origin: origin,
      rawJSON: data
    )
  }

  private static func loadOnce(allowKeychainPrompt: Bool) throws -> ClaudeCredentials {
    let fileURL = FileManager.default.homeDirectoryForCurrentUser
      .appending(path: ".claude/.credentials.json")
    if let data = try? Data(contentsOf: fileURL),
      let credentials = parse(
        data,
        source: "~/.claude/.credentials.json",
        origin: .file(fileURL)
      )
    {
      return credentials
    }

    if let data = try KeychainReader.genericPassword(
      service: keychainService,
      allowInteraction: allowKeychainPrompt
    ),
      let credentials = parse(
        data,
        source: "Claude Code Keychain",
        origin: .keychain
      )
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
}
