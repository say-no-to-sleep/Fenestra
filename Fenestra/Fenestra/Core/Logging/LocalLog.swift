import Foundation

enum LocalLog {
  nonisolated private static let queue = DispatchQueue(
    label: "dev.fenestra.local-log",
    qos: .utility
  )

  nonisolated static var fileURL: URL {
    HistoryStore.applicationSupportDirectory.appending(path: "fenestra.log")
  }

  nonisolated static func record(_ message: String) {
    let timestamp = Date().formatted(.iso8601)
    let line = "\(timestamp) \(message)\n"
    queue.async {
      do {
        let url = fileURL
        try FileManager.default.createDirectory(
          at: url.deletingLastPathComponent(),
          withIntermediateDirectories: true
        )
        rotateIfNeeded(url)
        if !FileManager.default.fileExists(atPath: url.path) {
          try Data(line.utf8).write(to: url, options: .atomic)
          return
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(line.utf8))
      } catch {
        // Local logging is best effort and never falls back to an external service.
      }
    }
  }

  nonisolated private static func rotateIfNeeded(_ url: URL) {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
      let size = attributes[.size] as? NSNumber,
      size.intValue > 1_000_000
    else {
      return
    }
    let old = url.deletingLastPathComponent().appending(path: "fenestra.old.log")
    try? FileManager.default.removeItem(at: old)
    try? FileManager.default.moveItem(at: url, to: old)
  }
}
