import Foundation

enum AntigravityDiscovery {
  static func endpoints() async throws -> [AntigravityEndpoint] {
    let processResult = try await ProcessRunner.run(
      executable: URL(filePath: "/bin/ps"),
      arguments: ["-ax", "-o", "pid=,command="],
      timeout: 8
    )
    let processes = processInfos(from: processResult.stdout)
    guard !processes.isEmpty else {
      throw ProviderFailure.unavailable("Antigravity: app or `agy` not detected")
    }

    var endpoints: [AntigravityEndpoint] = []
    for process in processes {
      let ports = try await listeningPorts(pid: process.pid)
      guard !ports.isEmpty else { continue }
      endpoints.append(
        contentsOf: ports.flatMap { port in
          [
            AntigravityEndpoint(scheme: "https", port: port, csrfToken: process.csrfToken),
            AntigravityEndpoint(scheme: "http", port: port, csrfToken: process.csrfToken),
          ]
        })
      if let extensionPort = process.extensionPort {
        endpoints.insert(
          AntigravityEndpoint(
            scheme: "http",
            port: extensionPort,
            csrfToken: process.extensionCSRFToken ?? process.csrfToken
          ),
          at: 0
        )
      }
    }
    guard !endpoints.isEmpty else {
      throw ProviderFailure.unavailable("Antigravity: local API port not detected")
    }
    return endpoints
  }

  private static func processInfos(from output: String) -> [ProcessInfo] {
    var results: [ProcessInfo] = []
    for rawLine in output.split(separator: "\n") {
      let line = rawLine.trimmingCharacters(in: .whitespaces)
      let pieces = line.split(
        separator: " ",
        maxSplits: 1,
        omittingEmptySubsequences: true
      )
      guard pieces.count == 2, let pid = Int(pieces[0]) else { continue }
      let command = String(pieces[1])
      if let info = languageServerProcess(command: command, pid: pid) {
        results.append(info)
        continue
      }
      if let info = agyProcess(command: command, pid: pid) {
        results.append(info)
      }
    }
    return results
  }

  private static func languageServerProcess(command: String, pid: Int) -> ProcessInfo? {
    let lower = command.lowercased()
    let isLanguageServer =
      lower.range(
        of: #"(^|[/\\])language(?:_|-)server(?:[_-][a-z0-9]+)*(?:\.exe)?(\s|$)"#,
        options: .regularExpression
      ) != nil
    guard isLanguageServer else { return nil }
    let isAntigravity =
      lower.contains("antigravity")
      || lower.contains("/extensions/antigravity/")
      || lower.contains("antigravity-cli")
      || lower.contains("jetski")
    guard isAntigravity else { return nil }
    let csrf = extractFlag("--csrf_token", from: command)
    guard csrf != nil else { return nil }
    return ProcessInfo(
      pid: pid,
      csrfToken: csrf ?? "",
      extensionPort: extractFlag("--extension_server_port", from: command).flatMap(Int.init),
      extensionCSRFToken: extractFlag("--extension_server_csrf_token", from: command)
    )
  }

  private static func agyProcess(command: String, pid: Int) -> ProcessInfo? {
    let executable = command.split(
      separator: " ",
      maxSplits: 1,
      omittingEmptySubsequences: true
    ).first.map(String.init) ?? command
    guard (executable as NSString).lastPathComponent.lowercased() == "agy" else { return nil }

    let arguments = command.dropFirst(executable.count).trimmingCharacters(in: .whitespaces)
    guard !arguments.hasPrefix("-") else { return nil }
    let firstToken = arguments.split(separator: " ").first.map(String.init) ?? ""
    let oneShotCommands = [
      "models", "help", "changelog", "install", "update", "plugin", "plugins",
    ]
    guard !oneShotCommands.contains(firstToken) else { return nil }

    return ProcessInfo(
      pid: pid,
      csrfToken: extractFlag("--csrf_token", from: command) ?? "",
      extensionPort: nil,
      extensionCSRFToken: nil
    )
  }

  private static func extractFlag(_ flag: String, from command: String) -> String? {
    let escaped = NSRegularExpression.escapedPattern(for: flag)
    guard
      let regex = try? NSRegularExpression(
        pattern: "\(escaped)[=\\s]+([^\\s]+)",
        options: .caseInsensitive
      )
    else {
      return nil
    }
    let range = NSRange(command.startIndex..<command.endIndex, in: command)
    guard let match = regex.firstMatch(in: command, range: range),
      let valueRange = Range(match.range(at: 1), in: command)
    else {
      return nil
    }
    return String(command[valueRange])
  }

  private static func listeningPorts(pid: Int) async throws -> [Int] {
    let result = try await ProcessRunner.run(
      executable: URL(filePath: "/usr/sbin/lsof"),
      arguments: ["-nP", "-iTCP", "-sTCP:LISTEN", "-a", "-p", String(pid)],
      timeout: 8
    )
    guard let regex = try? NSRegularExpression(pattern: #":(\d+)\s+\(LISTEN\)"#) else {
      return []
    }
    let output = result.stdout
    let range = NSRange(output.startIndex..<output.endIndex, in: output)
    var ports: Set<Int> = []
    regex.enumerateMatches(in: output, range: range) { match, _, _ in
      guard let match,
        let portRange = Range(match.range(at: 1), in: output),
        let port = Int(output[portRange])
      else {
        return
      }
      ports.insert(port)
    }
    return ports.sorted()
  }

  private struct ProcessInfo {
    let pid: Int
    let csrfToken: String
    let extensionPort: Int?
    let extensionCSRFToken: String?
  }
}
