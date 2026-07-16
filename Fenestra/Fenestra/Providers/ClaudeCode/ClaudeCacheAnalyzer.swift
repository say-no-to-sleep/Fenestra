import Foundation

struct ClaudeCacheAnalysis: Sendable {
  let hitRate: Double?
  // (timestamp, total tokens) per message, sorted by time. Used to sum usage per window.
  var tokenEvents: [TokenEvent] = []

  struct TokenEvent: Sendable {
    let timestamp: Date
    let tokens: Double
  }

  /// Total tokens consumed since `start` (nil if the window start is unknown).
  func tokensUsed(since start: Date?) -> Double? {
    guard let start else { return nil }
    let total = tokenEvents.lazy.filter { $0.timestamp >= start }.reduce(0) { $0 + $1.tokens }
    return total > 0 ? total : nil
  }
}

actor ClaudeCacheAnalyzer {
  static let shared = ClaudeCacheAnalyzer()
  private static let recentFileLimit = 50
  private static let bytesPerFileLimit = 1_000_000
  private static let recencyLimit: TimeInterval = 30 * 24 * 60 * 60

  private struct FileStamp: Equatable {
    let modificationDate: Date
    let size: Int
  }

  private struct UsageRecord {
    let uuid: String?
    let timestamp: Date?
    let cacheRead: Double
    let cacheCreation: Double
    let input: Double
    let output: Double

    var totalTokens: Double { cacheRead + cacheCreation + input + output }
  }

  private struct CachedFile {
    let stamp: FileStamp
    let records: [UsageRecord]
  }

  private var rootURL: URL?
  private var cachedFiles: [URL: CachedFile] = [:]
  private var latestAnalysis = ClaudeCacheAnalysis(hitRate: nil)
  private var isAnalyzing = false
  private var isDirty = true
  private var lastAnalysisDate: Date?

  func cachedAnalysisSchedulingRefresh(
    projectsURL: URL,
    minimumInterval: TimeInterval?
  ) -> ClaudeCacheAnalysis {
    if rootURL != projectsURL {
      rootURL = projectsURL
      cachedFiles.removeAll()
      latestAnalysis = ClaudeCacheAnalysis(hitRate: nil)
      isDirty = true
      lastAnalysisDate = nil
    }
    let current = latestAnalysis
    let intervalElapsed =
      minimumInterval.map { interval in
        lastAnalysisDate.map { Date().timeIntervalSince($0) >= interval } ?? true
      } ?? (lastAnalysisDate == nil)
    if !isAnalyzing, isDirty || intervalElapsed {
      isAnalyzing = true
      isDirty = false
      Task { [weak self] in
        await self?.performScheduledAnalysis(projectsURL: projectsURL)
      }
    }
    return current
  }

  func markDirty(projectsURL: URL) {
    if rootURL != projectsURL {
      rootURL = projectsURL
      cachedFiles.removeAll()
      latestAnalysis = ClaudeCacheAnalysis(hitRate: nil)
      lastAnalysisDate = nil
    }
    isDirty = true
  }

  func analyze(projectsURL: URL) -> ClaudeCacheAnalysis {
    if rootURL != projectsURL {
      rootURL = projectsURL
      cachedFiles.removeAll()
    }
    guard
      let enumerator = FileManager.default.enumerator(
        at: projectsURL,
        includingPropertiesForKeys: [
          .isRegularFileKey,
          .contentModificationDateKey,
          .fileSizeKey,
        ],
        options: [.skipsHiddenFiles]
      )
    else {
      cachedFiles.removeAll()
      latestAnalysis = ClaudeCacheAnalysis(hitRate: nil)
      return latestAnalysis
    }

    let cutoff = Date().addingTimeInterval(-Self.recencyLimit)
    var candidates: [(url: URL, stamp: FileStamp)] = []
    for case let fileURL as URL in enumerator where fileURL.pathExtension == "jsonl" {
      guard
        let values = try? fileURL.resourceValues(
          forKeys: [
            .isRegularFileKey,
            .contentModificationDateKey,
            .fileSizeKey,
          ]
        ),
        values.isRegularFile == true,
        let modificationDate = values.contentModificationDate,
        modificationDate >= cutoff
      else {
        continue
      }
      candidates.append(
        (
          fileURL,
          FileStamp(
            modificationDate: modificationDate,
            size: values.fileSize ?? 0
          )
        ))
    }
    candidates.sort {
      if $0.stamp.modificationDate != $1.stamp.modificationDate {
        return $0.stamp.modificationDate > $1.stamp.modificationDate
      }
      return $0.url.path < $1.url.path
    }

    var currentFiles: Set<URL> = []
    for candidate in candidates.prefix(Self.recentFileLimit) {
      let fileURL = candidate.url
      let stamp = candidate.stamp
      currentFiles.insert(fileURL)
      if cachedFiles[fileURL]?.stamp != stamp {
        cachedFiles[fileURL] = CachedFile(
          stamp: stamp,
          records: Self.records(in: fileURL)
        )
      }
    }
    cachedFiles = cachedFiles.filter { currentFiles.contains($0.key) }

    var seenUUIDs: Set<String> = []
    var cacheRead = 0.0
    var cacheCreation = 0.0
    var input = 0.0
    var tokenEvents: [ClaudeCacheAnalysis.TokenEvent] = []

    for fileURL in cachedFiles.keys.sorted(by: { $0.path < $1.path }) {
      for record in cachedFiles[fileURL]?.records ?? [] {
        if let uuid = record.uuid, !seenUUIDs.insert(uuid).inserted {
          continue
        }
        cacheRead += record.cacheRead
        cacheCreation += record.cacheCreation
        input += record.input
        if let timestamp = record.timestamp, record.totalTokens > 0 {
          tokenEvents.append(.init(timestamp: timestamp, tokens: record.totalTokens))
        }
      }
    }

    let denominator = cacheRead + cacheCreation + input
    latestAnalysis = ClaudeCacheAnalysis(
      hitRate: denominator > 0 ? cacheRead / denominator * 100 : nil,
      tokenEvents: tokenEvents
    )
    lastAnalysisDate = Date()
    isDirty = false
    return latestAnalysis
  }

  private func performScheduledAnalysis(projectsURL: URL) {
    _ = analyze(projectsURL: projectsURL)
    isAnalyzing = false
  }

  private nonisolated static func records(in fileURL: URL) -> [UsageRecord] {
    guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
      return []
    }
    defer { try? handle.close() }
    guard let fileSize = try? handle.seekToEnd() else { return [] }
    let start =
      fileSize > UInt64(bytesPerFileLimit)
      ? fileSize - UInt64(bytesPerFileLimit)
      : 0
    do {
      try handle.seek(toOffset: start)
    } catch {
      return []
    }
    guard var data = try? handle.readToEnd(), !data.isEmpty else { return [] }
    if start > 0 {
      guard let newline = data.firstIndex(of: 0x0A) else { return [] }
      data.removeSubrange(data.startIndex...newline)
    }
    guard let text = String(data: data, encoding: .utf8)
    else {
      return []
    }
    return text.split(separator: "\n").compactMap { line in
      guard let lineData = line.data(using: .utf8),
        let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
      else {
        return nil
      }
      let message = object["message"] as? [String: Any]
      guard
        let usage =
          (message?["usage"] as? [String: Any])
          ?? (object["usage"] as? [String: Any])
      else {
        return nil
      }
      return UsageRecord(
        uuid: object["uuid"] as? String,
        timestamp: date(object["timestamp"]),
        cacheRead: number(
          usage["cache_read_input_tokens"] ?? usage["cacheReadInputTokens"]
        ),
        cacheCreation: number(
          usage["cache_creation_input_tokens"] ?? usage["cacheCreationInputTokens"]
        ),
        input: number(usage["input_tokens"] ?? usage["inputTokens"]),
        output: number(usage["output_tokens"] ?? usage["outputTokens"])
      )
    }
  }

  // ponytail: ISO8601DateFormatter parsing is thread-safe in practice; unsafe-static
  // avoids re-creating it per record without an actor hop.
  nonisolated(unsafe) private static let isoFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
  }()

  nonisolated(unsafe) private static let isoFormatterNoFraction = ISO8601DateFormatter()

  nonisolated private static func date(_ value: Any?) -> Date? {
    guard let string = value as? String else { return nil }
    return isoFormatter.date(from: string)
      ?? isoFormatterNoFraction.date(from: string)
  }

  nonisolated private static func number(_ value: Any?) -> Double {
    let parsed: Double?
    if let number = value as? NSNumber {
      parsed = number.doubleValue
    } else if let string = value as? String {
      parsed = Double(string)
    } else {
      parsed = nil
    }
    guard let parsed, parsed.isFinite, parsed >= 0 else { return 0 }
    return parsed
  }
}
