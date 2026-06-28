import Foundation

@MainActor
enum AntigravityCloudFallback {
  private static let hosts = [
    "https://daily-cloudcode-pa.googleapis.com",
    "https://cloudcode-pa.googleapis.com",
  ]

  static func loadToken() throws -> AntigravityKeychainToken {
    guard
      let data = try KeychainReader.genericPassword(
        service: "gemini",
        account: "antigravity"
      ),
      let raw = String(data: data, encoding: .utf8),
      let decoded = unwrap(raw),
      let token = parse(decoded)
    else {
      throw ProviderFailure.notLoggedIn(
        "Antigravity: open the app or run `agy` and sign in"
      )
    }
    return token
  }

  static func invalidateCachedToken() {
    KeychainReader.invalidate(service: "gemini", account: "antigravity")
  }

  /// Full grouped 5h + weekly quota via Cloud Code (same data as local `RetrieveUserQuotaSummary`).
  static func fetchQuotaSummary(accessToken: String) async throws -> Data? {
    guard let project = try await loadProject(accessToken: accessToken) else {
      return nil
    }
    let body: [String: Any] = ["project": project]
    let paths = [
      "v1internal:retrieveUserQuotaSummary",
      "v1internal:retrieveUserQuota",
    ]
    var lastError: Error?
    for host in hosts {
      for path in paths {
        do {
          let (data, response) = try await post(
            accessToken: accessToken,
            host: host,
            path: path,
            body: body
          )
          if response.statusCode == 401 || response.statusCode == 403 {
            throw ProviderFailure.reauthenticationRequired(
              "Antigravity: session expired — open the app or run `agy` to refresh"
            )
          }
          guard response.statusCode == 200 else { continue }
          return data
        } catch let error as ProviderFailure {
          throw error
        } catch {
          lastError = error
        }
      }
    }
    if let lastError { throw lastError }
    return nil
  }

  static func fetchModels(accessToken: String) async throws -> [AntigravityModelQuota] {
    var lastStatus: Int?
    var lastError: Error?
    for host in hosts {
      let data: Data
      let response: HTTPURLResponse
      do {
        (data, response) = try await post(
          accessToken: accessToken,
          host: host,
          path: "v1internal:fetchAvailableModels",
          body: [:]
        )
      } catch {
        lastError = error
        continue
      }
      lastStatus = response.statusCode
      if response.statusCode == 401 || response.statusCode == 403 {
        throw ProviderFailure.reauthenticationRequired(
          "Antigravity: session expired — open the app or run `agy` to refresh"
        )
      }
      guard response.statusCode == 200,
        let envelope = try? JSONDecoder().decode(
          AntigravityCloudModelsEnvelope.self,
          from: data
        )
      else {
        continue
      }
      return (envelope.models ?? [:]).compactMap { key, model in
        guard model.isInternal != true,
          let quota = model.quotaInfo,
          let remaining = quota.remainingFraction,
          remaining.isFinite,
          (0...1).contains(remaining)
        else {
          return nil
        }
        let label = model.displayName ?? model.label ?? model.model ?? key
        return AntigravityModelQuota(
          label: label,
          modelID: model.model ?? key,
          remainingFraction: remaining,
          resetTime: ProviderDateParser.date(from: quota.resetTime)
        )
      }
    }
    if let lastError, lastStatus == nil {
      throw lastError
    }
    throw ProviderFailure.unavailable(
      "Antigravity: Cloud Code unavailable\(lastStatus.map { " (HTTP \($0))" } ?? "")"
    )
  }

  private static func loadProject(accessToken: String) async throws -> String? {
    let body: [String: Any] = [
      "metadata": [
        "ideType": "ANTIGRAVITY",
        "platform": "PLATFORM_UNSPECIFIED",
        "pluginType": "GEMINI",
      ]
    ]
    for host in hosts {
      do {
        let (data, response) = try await post(
          accessToken: accessToken,
          host: host,
          path: "v1internal:loadCodeAssist",
          body: body
        )
        if response.statusCode == 401 || response.statusCode == 403 {
          throw ProviderFailure.reauthenticationRequired(
            "Antigravity: session expired — open the app or run `agy` to refresh"
          )
        }
        guard response.statusCode == 200,
          let envelope = try? JSONDecoder().decode(
            AntigravityLoadCodeAssistResponse.self,
            from: data
          ),
          let project = envelope.cloudaicompanionProject,
          !project.isEmpty
        else {
          continue
        }
        return project
      } catch let error as ProviderFailure {
        throw error
      } catch {
        continue
      }
    }
    return nil
  }

  private static func post(
    accessToken: String,
    host: String,
    path: String,
    body: [String: Any]
  ) async throws -> (Data, HTTPURLResponse) {
    guard let url = URL(string: host + "/" + path) else {
      throw ProviderFailure.invalidResponse("Antigravity: invalid Cloud Code endpoint")
    }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.httpBody = try JSONSerialization.data(withJSONObject: body)
    request.timeoutInterval = 15
    request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("antigravity", forHTTPHeaderField: "User-Agent")
    let (data, response) = try await RestrictedHTTPClient.data(for: request)
    guard let http = response as? HTTPURLResponse else {
      throw ProviderFailure.invalidResponse("Antigravity: invalid Cloud Code response")
    }
    return (data, http)
  }

  private static func unwrap(_ raw: String) -> String? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    let prefix = "go-keyring-base64:"
    guard trimmed.hasPrefix(prefix) else { return trimmed }
    let base64 = String(trimmed.dropFirst(prefix.count))
    guard let data = Data(base64Encoded: base64) else { return nil }
    return String(data: data, encoding: .utf8)
  }

  private static func parse(_ raw: String) -> AntigravityKeychainToken? {
    guard let data = raw.data(using: .utf8),
      let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
      return AntigravityKeychainToken(accessToken: raw, expiry: nil)
    }
    let token = (root["token"] as? [String: Any]) ?? root
    let access =
      token["access_token"] as? String
      ?? token["accessToken"] as? String
    let expiry = ProviderDateParser.date(
      from: token["expiry"] ?? token["expires_at"] ?? token["expiresAt"]
    )
    return AntigravityKeychainToken(accessToken: access, expiry: expiry)
  }
}

private struct AntigravityLoadCodeAssistResponse: Decodable {
  let cloudaicompanionProject: String?
}
