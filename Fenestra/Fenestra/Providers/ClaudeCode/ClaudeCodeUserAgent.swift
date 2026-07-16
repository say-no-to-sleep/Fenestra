import Foundation

enum ClaudeCodeUserAgent {
  private static let fallbackVersion = "2.1.0"
  private static var cachedValue: String?

  static func value() async -> String {
    if let cachedValue {
      return cachedValue
    }

    let version = await detectedVersion() ?? fallbackVersion
    let value = "claude-code/\(version)"
    cachedValue = value
    return value
  }

  static func normalizedVersion(_ output: String?) -> String? {
    guard let output else { return nil }
    let token =
      output
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .split(whereSeparator: \.isWhitespace)
      .first
      .map(String.init)
    guard let token, !token.isEmpty, token.count <= 64 else { return nil }

    let allowed = CharacterSet.alphanumerics.union(
      CharacterSet(charactersIn: "._-")
    )
    guard token.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
    return token
  }

  private static func detectedVersion() async -> String? {
    guard let executable = ProcessRunner.locate("claude"),
      let result = try? await ProcessRunner.run(
        executable: executable,
        arguments: ["--version"],
        timeout: 5
      ),
      result.terminationStatus == 0
    else {
      return nil
    }
    return normalizedVersion(result.stdout)
  }
}
