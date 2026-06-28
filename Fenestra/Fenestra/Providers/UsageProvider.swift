import Foundation

@MainActor
protocol UsageProvider: AnyObject {
  var id: ProviderID { get }
  var displayName: String { get }
  func currentSnapshot() async throws -> UsageSnapshot
}

enum ProviderFailure: LocalizedError, Equatable {
  case notLoggedIn(String)
  case reauthenticationRequired(String)
  case unavailable(String)
  case invalidResponse(String)

  var errorDescription: String? {
    switch self {
    case .notLoggedIn(let message),
      .reauthenticationRequired(let message),
      .unavailable(let message),
      .invalidResponse(let message):
      message
    }
  }
}
