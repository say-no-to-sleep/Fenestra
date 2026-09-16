import Foundation

struct ClaudeOAuthTokens: Equatable, Sendable {
  var accessToken: String
  var refreshToken: String?
  var expiresAt: Date
  var refreshTokenExpiresAt: Date?
}

enum ClaudeOAuthRefresher {
  static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
  static let tokenURL = URL(string: "https://platform.claude.com/v1/oauth/token")!
  static let defaultAccessLifetime: TimeInterval = 8 * 60 * 60
  static let expiredSessionMessage =
    "Claude: OAuth session expired — run `claude auth login --claudeai`"

  static func tokenRequest(refreshToken: String, userAgent: String) -> URLRequest {
    var request = URLRequest(url: tokenURL)
    request.httpMethod = "POST"
    request.timeoutInterval = 30
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
    request.httpBody = try? JSONSerialization.data(
      withJSONObject: [
        "grant_type": "refresh_token",
        "refresh_token": refreshToken,
        "client_id": clientID,
      ]
    )
    return request
  }

  static func parseTokens(from data: Data, now: Date = Date()) throws -> ClaudeOAuthTokens {
    guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let accessToken = stringValue(root, keys: ["access_token", "accessToken"]),
      !accessToken.isEmpty
    else {
      throw ProviderFailure.invalidResponse("Claude: unexpected OAuth refresh response")
    }

    let expiresIn = numberValue(root, keys: ["expires_in", "expiresIn"])
    let expiresAt =
      ProviderDateParser.date(from: root["expires_at"] ?? root["expiresAt"])
      ?? now.addingTimeInterval(expiresIn ?? defaultAccessLifetime)
    let refreshExpiresIn = numberValue(
      root,
      keys: ["refresh_token_expires_in", "refreshTokenExpiresIn"]
    )
    let refreshTokenExpiresAt =
      ProviderDateParser.date(
        from: root["refresh_token_expires_at"] ?? root["refreshTokenExpiresAt"]
      )
      ?? refreshExpiresIn.map { now.addingTimeInterval($0) }

    return ClaudeOAuthTokens(
      accessToken: accessToken,
      refreshToken: stringValue(root, keys: ["refresh_token", "refreshToken"]),
      expiresAt: expiresAt,
      refreshTokenExpiresAt: refreshTokenExpiresAt
    )
  }

  static func oauthErrorCode(from data: Data) -> String? {
    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      return nil
    }
    return stringValue(root, keys: ["error"])
  }

  static func applying(_ tokens: ClaudeOAuthTokens, to data: Data) throws -> Data {
    guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw ProviderFailure.invalidResponse("Claude: credentials are not JSON")
    }

    let oauthKey: String?
    if root["claudeAiOauth"] is [String: Any] {
      oauthKey = "claudeAiOauth"
    } else if root["claude_ai_oauth"] is [String: Any] {
      oauthKey = "claude_ai_oauth"
    } else {
      oauthKey = nil
    }

    var oauth = oauthKey.flatMap { root[$0] as? [String: Any] } ?? root
    set(&oauth, camel: "accessToken", snake: "access_token", value: tokens.accessToken)
    if let refreshToken = tokens.refreshToken, !refreshToken.isEmpty {
      set(&oauth, camel: "refreshToken", snake: "refresh_token", value: refreshToken)
    }
    set(
      &oauth,
      camel: "expiresAt",
      snake: "expires_at",
      value: NSNumber(value: milliseconds(tokens.expiresAt))
    )
    if let refreshTokenExpiresAt = tokens.refreshTokenExpiresAt {
      set(
        &oauth,
        camel: "refreshTokenExpiresAt",
        snake: "refresh_token_expires_at",
        value: NSNumber(value: milliseconds(refreshTokenExpiresAt))
      )
    }

    if let oauthKey {
      root[oauthKey] = oauth
    } else {
      root = oauth
    }
    return try JSONSerialization.data(withJSONObject: root)
  }

  private static func set(
    _ object: inout [String: Any],
    camel: String,
    snake: String,
    value: Any
  ) {
    let hasCamel = object[camel] != nil
    let hasSnake = object[snake] != nil
    if hasSnake && !hasCamel {
      object[snake] = value
    } else {
      object[camel] = value
      if hasSnake {
        object[snake] = value
      }
    }
  }

  private static func milliseconds(_ date: Date) -> Int64 {
    Int64((date.timeIntervalSince1970 * 1_000).rounded())
  }

  static func stringValue(_ object: [String: Any], keys: [String]) -> String? {
    for key in keys {
      if let value = object[key] as? String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
      }
    }
    return nil
  }

  private static func numberValue(_ object: [String: Any], keys: [String]) -> Double? {
    for key in keys {
      if let number = object[key] as? NSNumber {
        let value = number.doubleValue
        if value.isFinite, value > 0 { return value }
      }
      if let string = object[key] as? String, let value = Double(string), value > 0 {
        return value
      }
    }
    return nil
  }
}
