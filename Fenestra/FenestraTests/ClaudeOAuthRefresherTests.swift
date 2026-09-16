import Foundation
import Testing

@testable import Fenestra

@Suite("Claude OAuth refresh")
@MainActor
struct ClaudeOAuthRefresherTests {
  @Test
  func parsesMillisecondExpiryAndRefreshToken() throws {
    let json = Data(
      """
      {"claudeAiOauth":{"accessToken":"access","refreshToken":"refresh","expiresAt":1700000000000}}
      """.utf8
    )
    let credentials = try #require(
      ClaudeCredentialStore.parse(json, source: "test", origin: .keychain)
    )

    #expect(credentials.accessToken == "access")
    #expect(credentials.refreshToken == "refresh")
    #expect(credentials.expiresAt == Date(timeIntervalSince1970: 1_700_000_000))
  }

  @Test
  func treatsTokenAsExpiredInsideSkewWindow() throws {
    let json = Data(#"{"accessToken":"access","expiresAt":2300}"#.utf8)
    let credentials = try #require(
      ClaudeCredentialStore.parse(json, source: "test", origin: .keychain)
    )

    #expect(credentials.isExpired(now: Date(timeIntervalSince1970: 2_000), skew: 5 * 60))
    #expect(!credentials.isExpired(now: Date(timeIntervalSince1970: 1_900), skew: 5 * 60))
  }

  @Test
  func missingExpiryIsNotTreatedAsExpired() throws {
    let json = Data(#"{"accessToken":"access","refreshToken":"refresh"}"#.utf8)
    let credentials = try #require(
      ClaudeCredentialStore.parse(json, source: "test", origin: .keychain)
    )

    #expect(!credentials.isExpired(now: Date(timeIntervalSince1970: 1)))
    #expect(credentials.refreshToken == "refresh")
  }

  @Test
  func parsesRefreshResponseAndDefaultsLifetime() throws {
    let now = Date(timeIntervalSince1970: 1_000)
    let tokens = try ClaudeOAuthRefresher.parseTokens(
      from: Data(
        """
        {"access_token":"new-access","refresh_token":"new-refresh","expires_in":28800,"refresh_token_expires_in":600}
        """.utf8
      ),
      now: now
    )

    #expect(tokens.accessToken == "new-access")
    #expect(tokens.refreshToken == "new-refresh")
    #expect(tokens.expiresAt == now.addingTimeInterval(28_800))
    #expect(tokens.refreshTokenExpiresAt == now.addingTimeInterval(600))
  }

  @Test
  func writesRotatedTokensBackWithoutDroppingOtherOAuthFields() throws {
    let original = Data(
      """
      {"claudeAiOauth":{"accessToken":"old","refreshToken":"old-rt","expiresAt":1,"scopes":["user:profile"],"subscriptionType":"pro"}}
      """.utf8
    )
    let updated = try ClaudeOAuthRefresher.applying(
      ClaudeOAuthTokens(
        accessToken: "new",
        refreshToken: "new-rt",
        expiresAt: Date(timeIntervalSince1970: 1_700_000_000),
        refreshTokenExpiresAt: Date(timeIntervalSince1970: 1_800_000_000)
      ),
      to: original
    )
    let root = try #require(
      JSONSerialization.jsonObject(with: updated) as? [String: Any]
    )
    let oauth = try #require(root["claudeAiOauth"] as? [String: Any])

    #expect(oauth["accessToken"] as? String == "new")
    #expect(oauth["refreshToken"] as? String == "new-rt")
    #expect((oauth["expiresAt"] as? NSNumber)?.int64Value == 1_700_000_000_000)
    #expect((oauth["refreshTokenExpiresAt"] as? NSNumber)?.int64Value == 1_800_000_000_000)
    #expect(oauth["subscriptionType"] as? String == "pro")
    #expect((oauth["scopes"] as? [Any])?.compactMap { $0 as? String } == ["user:profile"])
  }

  @Test
  func tokenRequestUsesPublicClaudeCodeClient() throws {
    let request = ClaudeOAuthRefresher.tokenRequest(
      refreshToken: "rt",
      userAgent: "claude-code/2.1.229"
    )
    let bodyData = try #require(request.httpBody)
    let body = try #require(
      JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
    )

    #expect(request.url == ClaudeOAuthRefresher.tokenURL)
    #expect(request.httpMethod == "POST")
    #expect(body["grant_type"] as? String == "refresh_token")
    #expect(body["client_id"] as? String == ClaudeOAuthRefresher.clientID)
    #expect(body["refresh_token"] as? String == "rt")
  }

  @Test
  func readsOAuthErrorCodeWithoutExposingTheBody() {
    let data = Data(#"{"error":"invalid_grant","error_description":"secret"}"#.utf8)
    #expect(ClaudeOAuthRefresher.oauthErrorCode(from: data) == "invalid_grant")
  }
}
