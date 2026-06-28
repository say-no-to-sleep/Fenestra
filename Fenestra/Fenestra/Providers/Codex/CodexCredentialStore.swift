import Foundation

struct CodexCredentials: Sendable {
  let accessToken: String
  let accountID: String?
}

enum CodexCredentialStore {
  static func load() throws -> CodexCredentials {
    let url = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".codex/auth.json")
    guard let data = try? Data(contentsOf: url),
      let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let tokens = root["tokens"] as? [String: Any],
      let accessToken = tokens["access_token"] as? String,
      !accessToken.isEmpty
    else {
      throw ProviderFailure.notLoggedIn("Codex: run `codex login`")
    }
    return CodexCredentials(
      accessToken: accessToken,
      accountID: tokens["account_id"] as? String
    )
  }
}
