import Darwin
import Foundation

final class ClaudeProjectsWatcher: @unchecked Sendable {
  private let projectsURL: URL
  private let queue = DispatchQueue(label: "dev.fenestra.claude-projects", qos: .utility)
  private let onChange: @Sendable () -> Void
  nonisolated(unsafe) private var source: DispatchSourceFileSystemObject?
  nonisolated(unsafe) private var timer: DispatchSourceTimer?
  nonisolated(unsafe) private var debounce: DispatchWorkItem?
  nonisolated(unsafe) private var lastCallback = Date.distantPast
  nonisolated(unsafe) private var lastModification = Date.distantPast
  private let backstopInterval: TimeInterval?

  nonisolated init(
    projectsURL: URL,
    backstopInterval: TimeInterval?,
    onChange: @escaping @Sendable () -> Void
  ) {
    self.projectsURL = projectsURL
    self.backstopInterval = backstopInterval
    self.onChange = onChange
  }

  nonisolated func start() {
    queue.async { [weak self] in
      self?.startSource()
      self?.startBackstop()
    }
  }

  nonisolated func stop() {
    queue.async { [weak self] in
      self?.debounce?.cancel()
      self?.debounce = nil
      self?.source?.cancel()
      self?.source = nil
      self?.timer?.cancel()
      self?.timer = nil
    }
  }

  nonisolated private func startSource() {
    guard source == nil else { return }
    let descriptor = open(projectsURL.path, O_EVTONLY)
    guard descriptor >= 0 else { return }
    let source = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: descriptor,
      eventMask: [.write, .extend, .attrib, .rename, .delete],
      queue: queue
    )
    source.setEventHandler { [weak self] in
      self?.handleFileEvent()
    }
    source.setCancelHandler {
      close(descriptor)
    }
    self.source = source
    source.resume()
  }

  nonisolated private func startBackstop() {
    timer?.cancel()
    guard let backstopInterval, backstopInterval > 0 else {
      timer = nil
      return
    }
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(
      deadline: .now() + backstopInterval,
      repeating: backstopInterval,
      leeway: .seconds(2)
    )
    timer.setEventHandler { [weak self] in
      self?.checkBackstop()
    }
    self.timer = timer
    lastModification = latestJSONLModification()
    timer.resume()
  }

  nonisolated private func handleFileEvent() {
    lastCallback = Date()
    scheduleDebouncedRefresh()
  }

  nonisolated private func scheduleDebouncedRefresh() {
    debounce?.cancel()
    let item = DispatchWorkItem { [onChange] in onChange() }
    debounce = item
    queue.asyncAfter(deadline: .now() + 0.4, execute: item)
  }

  nonisolated private func checkBackstop() {
    let modification = latestJSONLModification()
    guard modification > lastModification else { return }
    lastModification = modification
    if Date().timeIntervalSince(lastCallback) > 120 {
      source?.cancel()
      source = nil
      startSource()
    }
    scheduleDebouncedRefresh()
  }

  nonisolated private func latestJSONLModification() -> Date {
    guard
      let enumerator = FileManager.default.enumerator(
        at: projectsURL,
        includingPropertiesForKeys: [.contentModificationDateKey],
        options: [.skipsHiddenFiles]
      )
    else {
      return .distantPast
    }
    var latest = Date.distantPast
    for case let url as URL in enumerator where url.pathExtension == "jsonl" {
      if let date = try? url.resourceValues(
        forKeys: [.contentModificationDateKey]
      ).contentModificationDate {
        latest = max(latest, date)
      }
    }
    return latest
  }
}
