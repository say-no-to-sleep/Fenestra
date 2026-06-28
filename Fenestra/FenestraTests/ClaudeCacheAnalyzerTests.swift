import Foundation
import Testing

@testable import Fenestra

@Suite("Claude cache analysis")
@MainActor
struct ClaudeCacheAnalyzerTests {
  @Test
  func deduplicatesUUIDsAndReanalyzesOnlyChangedFileState() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: "fenestra-claude-cache-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: false
    )

    let first = directory.appending(path: "a.jsonl")
    let second = directory.appending(path: "b.jsonl")
    try write(
      [
        usageLine(uuid: "duplicate", cacheRead: 80, cacheCreation: 10, input: 10)
      ],
      to: first
    )
    try write(
      [
        usageLine(uuid: "duplicate", cacheRead: 1, cacheCreation: 0, input: 99),
        usageLine(uuid: "second", cacheRead: 20, cacheCreation: 0, input: 80),
      ],
      to: second
    )

    let initial = await ClaudeCacheAnalyzer.shared.analyze(projectsURL: directory)
    #expect(abs(try #require(initial.hitRate) - 50) < 0.0001)

    try write(
      [
        usageLine(uuid: "duplicate", cacheRead: 1, cacheCreation: 0, input: 99),
        usageLine(uuid: "second", cacheRead: 20, cacheCreation: 0, input: 80),
        usageLine(uuid: "third", cacheRead: 100, cacheCreation: 0, input: 0),
      ],
      to: second
    )
    let updated = await ClaudeCacheAnalyzer.shared.analyze(projectsURL: directory)
    #expect(abs(try #require(updated.hitRate) - 66.666_666_666_7) < 0.0001)
  }

  private func usageLine(
    uuid: String,
    cacheRead: Int,
    cacheCreation: Int,
    input: Int
  ) -> String {
    """
    {"uuid":"\(uuid)","message":{"usage":{"cache_read_input_tokens":\(cacheRead),"cache_creation_input_tokens":\(cacheCreation),"input_tokens":\(input)}}}
    """
  }

  private func write(_ lines: [String], to url: URL) throws {
    try Data((lines.joined(separator: "\n") + "\n").utf8)
      .write(to: url, options: .atomic)
  }
}
