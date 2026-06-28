import Foundation

struct ProcessResult: Sendable {
  let stdout: String
  let stderr: String
  let terminationStatus: Int32
}

enum ProcessRunner {
  static func locate(_ executable: String) -> URL? {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let candidates = [
      home.appending(path: ".local/bin/\(executable)"),
      home.appending(path: ".npm-global/bin/\(executable)"),
      URL(filePath: "/opt/homebrew/bin/\(executable)"),
      URL(filePath: "/usr/local/bin/\(executable)"),
      URL(filePath: "/usr/bin/\(executable)"),
    ]
    return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
  }

  static func run(
    executable: URL,
    arguments: [String],
    timeout: TimeInterval = 25
  ) async throws -> ProcessResult {
    try await withCheckedThrowingContinuation { continuation in
      let process = Process()
      let output = Pipe()
      let errors = Pipe()
      let outputBuffer = ProcessOutputBuffer()
      let errorBuffer = ProcessOutputBuffer()
      process.executableURL = executable
      process.arguments = arguments
      process.standardOutput = output
      process.standardError = errors
      process.standardInput = FileHandle.nullDevice
      process.environment = ProcessInfo.processInfo.environment
      output.fileHandleForReading.readabilityHandler = { handle in
        outputBuffer.append(handle.availableData)
      }
      errors.fileHandleForReading.readabilityHandler = { handle in
        errorBuffer.append(handle.availableData)
      }

      let state = ProcessContinuationState(continuation: continuation)
      process.terminationHandler = { process in
        output.fileHandleForReading.readabilityHandler = nil
        errors.fileHandleForReading.readabilityHandler = nil
        outputBuffer.append((try? output.fileHandleForReading.readToEnd()) ?? Data())
        errorBuffer.append((try? errors.fileHandleForReading.readToEnd()) ?? Data())
        state.finish(
          .success(
            ProcessResult(
              stdout: String(decoding: outputBuffer.data, as: UTF8.self),
              stderr: String(decoding: errorBuffer.data, as: UTF8.self),
              terminationStatus: process.terminationStatus
            )))
      }

      do {
        try process.run()
      } catch {
        state.finish(.failure(error))
        return
      }

      DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
        guard process.isRunning else { return }
        process.terminate()
        state.finish(
          .failure(
            ProviderFailure.unavailable(
              "\(executable.lastPathComponent) timed out"
            )))
      }
    }
  }
}

private final class ProcessOutputBuffer: @unchecked Sendable {
  private let lock = NSLock()
  nonisolated(unsafe) private var storage = Data()

  nonisolated func append(_ data: Data) {
    guard !data.isEmpty else { return }
    lock.lock()
    storage.append(data)
    lock.unlock()
  }

  nonisolated var data: Data {
    lock.lock()
    defer { lock.unlock() }
    return storage
  }
}

private final class ProcessContinuationState: @unchecked Sendable {
  private let lock = NSLock()
  nonisolated(unsafe) private var didFinish = false
  private let continuation: CheckedContinuation<ProcessResult, Error>

  nonisolated init(continuation: CheckedContinuation<ProcessResult, Error>) {
    self.continuation = continuation
  }

  nonisolated func finish(_ result: Result<ProcessResult, Error>) {
    lock.lock()
    guard !didFinish else {
      lock.unlock()
      return
    }
    didFinish = true
    lock.unlock()
    continuation.resume(with: result)
  }
}
