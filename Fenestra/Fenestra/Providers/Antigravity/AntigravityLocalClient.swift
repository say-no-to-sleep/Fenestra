import Foundation

enum AntigravityLocalClient {
  private static let service = "exa.language_server_pb.LanguageServerService"

  static func request(
    endpoint: AntigravityEndpoint,
    method: String,
    body: [String: Any]
  ) async throws -> Data {
    guard
      let url = URL(
        string: "\(endpoint.scheme)://127.0.0.1:\(endpoint.port)/\(service)/\(method)"
      )
    else {
      throw ProviderFailure.invalidResponse("Antigravity: invalid local endpoint")
    }
    let payload = try JSONSerialization.data(withJSONObject: body)
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.httpBody = payload
    request.timeoutInterval = 8
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
    if !endpoint.csrfToken.isEmpty {
      request.setValue(endpoint.csrfToken, forHTTPHeaderField: "X-Codeium-Csrf-Token")
    }

    let (data, response) = try await RestrictedHTTPClient.data(
      for: request,
      allowUntrustedLoopbackTLS: endpoint.scheme == "https"
    )
    guard response.statusCode == 200 else {
      throw ProviderFailure.unavailable(
        "Antigravity: local API returned HTTP \(response.statusCode)"
      )
    }
    return data
  }

  static var metadataBody: [String: Any] {
    [
      "metadata": [
        "ideName": "antigravity",
        "extensionName": "antigravity",
        "ideVersion": "unknown",
        "locale": "en",
      ]
    ]
  }
}
