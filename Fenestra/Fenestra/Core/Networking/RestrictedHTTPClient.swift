import Foundation

/// Fenestra has no analytics, telemetry, crash reporting, or cloud sync.
/// Requests and redirects are rejected unless they target a provider endpoint
/// explicitly used by Claude Code, Codex, Antigravity, or Cursor.
enum RestrictedHTTPClient {
  nonisolated private static let remoteHosts: Set<String> = [
    "api.anthropic.com",
    "chatgpt.com",
    "daily-cloudcode-pa.googleapis.com",
    "cloudcode-pa.googleapis.com",
    "cursor.com",
    "www.cursor.com",
  ]
  nonisolated private static let loopbackHosts: Set<String> = [
    "127.0.0.1",
    "::1",
    "localhost",
  ]

  private static let remoteSession = makeSession(allowUntrustedLoopbackTLS: false)
  private static let localSession = makeSession(allowUntrustedLoopbackTLS: true)

  static func data(
    for request: URLRequest,
    allowUntrustedLoopbackTLS: Bool = false
  ) async throws -> (Data, HTTPURLResponse) {
    guard isAllowed(request.url) else {
      throw ProviderFailure.unavailable("Blocked non-provider network request")
    }

    let session = allowUntrustedLoopbackTLS ? localSession : remoteSession
    let (data, response) = try await session.data(for: request)
    guard let response = response as? HTTPURLResponse else {
      throw ProviderFailure.invalidResponse("Provider returned a non-HTTP response")
    }
    return (data, response)
  }

  nonisolated static func isAllowed(_ url: URL?) -> Bool {
    guard let url,
      let scheme = url.scheme?.lowercased(),
      let host = url.host?.lowercased()
    else {
      return false
    }
    if loopbackHosts.contains(host) {
      return scheme == "http" || scheme == "https"
    }
    guard remoteHosts.contains(host), scheme == "https" else {
      return false
    }
    return url.port == nil || url.port == 443
  }

  private static func makeSession(allowUntrustedLoopbackTLS: Bool) -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.waitsForConnectivity = false
    configuration.httpShouldSetCookies = false
    configuration.urlCache = nil
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    return URLSession(
      configuration: configuration,
      delegate: RestrictedSessionDelegate(
        allowUntrustedLoopbackTLS: allowUntrustedLoopbackTLS
      ),
      delegateQueue: nil
    )
  }
}

private final class RestrictedSessionDelegate: NSObject, URLSessionTaskDelegate,
  @unchecked Sendable
{
  private let allowUntrustedLoopbackTLS: Bool

  init(allowUntrustedLoopbackTLS: Bool) {
    self.allowUntrustedLoopbackTLS = allowUntrustedLoopbackTLS
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) {
    let originalHost = task.originalRequest?.url?.host?.lowercased()
    let redirectHost = request.url?.host?.lowercased()
    guard originalHost == redirectHost, RestrictedHTTPClient.isAllowed(request.url) else {
      completionHandler(nil)
      return
    }
    completionHandler(request)
  }

  func urlSession(
    _ session: URLSession,
    didReceive challenge: URLAuthenticationChallenge
  ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
    let host = challenge.protectionSpace.host.lowercased()
    guard allowUntrustedLoopbackTLS,
      host == "127.0.0.1" || host == "::1" || host == "localhost",
      let trust = challenge.protectionSpace.serverTrust
    else {
      return (.performDefaultHandling, nil)
    }
    return (.useCredential, URLCredential(trust: trust))
  }
}
