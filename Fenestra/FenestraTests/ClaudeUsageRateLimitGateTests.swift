import Foundation
import Testing

@testable import Fenestra

@Suite("Claude usage rate-limit handling")
struct ClaudeUsageRateLimitGateTests {
  @Test @MainActor
  func recordsServerRetryAfterAndExpiresIt() throws {
    let suiteName = "FenestraTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let gate = ClaudeUsageRateLimitGate(defaults: defaults)
    let now = Date(timeIntervalSince1970: 1_000)
    let retryAfter = now.addingTimeInterval(90)

    #expect(gate.recordRateLimit(retryAfter: retryAfter, now: now) == retryAfter)
    #expect(gate.blockedUntil(now: now) == retryAfter)
    #expect(gate.blockedUntil(now: retryAfter) == nil)
  }

  @Test @MainActor
  func usesFiveMinuteCooldownWithoutRetryAfter() throws {
    let suiteName = "FenestraTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let gate = ClaudeUsageRateLimitGate(defaults: defaults)
    let now = Date(timeIntervalSince1970: 2_000)

    let blockedUntil = gate.recordRateLimit(retryAfter: nil, now: now)

    #expect(
      blockedUntil == now.addingTimeInterval(ClaudeUsageRateLimitGate.defaultCooldown)
    )
  }

  @Test @MainActor
  func manualRetryAndSuccessClearCooldown() throws {
    let suiteName = "FenestraTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let gate = ClaudeUsageRateLimitGate(defaults: defaults)
    let now = Date(timeIntervalSince1970: 3_000)

    gate.recordRateLimit(retryAfter: nil, now: now)
    gate.allowManualRetry()
    #expect(gate.blockedUntil(now: now) == nil)

    gate.recordRateLimit(retryAfter: nil, now: now)
    gate.recordSuccess()
    #expect(gate.blockedUntil(now: now) == nil)
  }

  @Test @MainActor
  func parsesRetryAfterSecondsAndHTTPDate() throws {
    let now = Date(timeIntervalSince1970: 0)
    let secondsResponse = try #require(
      HTTPURLResponse(
        url: URL(string: "https://api.anthropic.com")!,
        statusCode: 429,
        httpVersion: nil,
        headerFields: ["Retry-After": "120"]
      ))
    #expect(
      ClaudeUsageRateLimitGate.retryAfterDate(from: secondsResponse, now: now)
        == now.addingTimeInterval(120)
    )

    let dateResponse = try #require(
      HTTPURLResponse(
        url: URL(string: "https://api.anthropic.com")!,
        statusCode: 429,
        httpVersion: nil,
        headerFields: ["Retry-After": "Thu, 01 Jan 1970 00:05:00 GMT"]
      ))
    #expect(
      ClaudeUsageRateLimitGate.retryAfterDate(from: dateResponse, now: now)
        == Date(timeIntervalSince1970: 300)
    )
  }

  /// The token endpoint is IP-rate-limited and shared with the CLI, so its gate
  /// must back off much harder than the usage gate and keep its own key.
  @Test @MainActor
  func tokenRefreshGateBacksOffLongerAndIndependently() throws {
    let suiteName = "FenestraTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let usageGate = ClaudeUsageRateLimitGate(defaults: defaults)
    let refreshGate = ClaudeUsageRateLimitGate(
      defaults: defaults,
      blockedUntilKey: ClaudeUsageRateLimitGate.tokenRefreshBlockedUntilKey,
      cooldown: ClaudeUsageRateLimitGate.tokenRefreshCooldown
    )
    let now = Date(timeIntervalSince1970: 4_000)

    let blockedUntil = refreshGate.recordRateLimit(retryAfter: nil, now: now)
    #expect(
      blockedUntil == now.addingTimeInterval(ClaudeUsageRateLimitGate.tokenRefreshCooldown)
    )
    #expect(ClaudeUsageRateLimitGate.tokenRefreshCooldown > ClaudeUsageRateLimitGate.defaultCooldown)
    // A 429 on refresh must not gate the usage API, and vice versa.
    #expect(usageGate.blockedUntil(now: now) == nil)
  }

  @Test @MainActor
  func statuslineReaderAcceptsClaudeCodeUsedPercentage() throws {
    let payload = """
      {"rate_limits":{"five_hour":{"used_percentage":42.5,"resets_at":1800000000},\
      "seven_day":{"used_percentage":13,"resets_at":1800500000}}}
      """
    let url = ClaudeStatuslineReader.captureURL
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data(payload.utf8).write(to: url, options: .atomic)

    let usage = try #require(ClaudeStatuslineReader.read())
    #expect(usage.fiveHourUsedPercent == 42.5)
    #expect(usage.weeklyUsedPercent == 13)
  }

  @Test @MainActor
  func normalizesClaudeCodeVersionForUserAgent() {
    #expect(
      ClaudeCodeUserAgent.normalizedVersion("2.1.80 (Claude Code)\n") == "2.1.80"
    )
    #expect(ClaudeCodeUserAgent.normalizedVersion("bad/version") == nil)
    #expect(ClaudeCodeUserAgent.normalizedVersion(nil) == nil)
  }
}
