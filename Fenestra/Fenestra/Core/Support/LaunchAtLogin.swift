import Foundation
import ServiceManagement

@MainActor
enum LaunchAtLogin {
  static var isEnabled: Bool {
    guard !isRunningTests else { return false }
    return SMAppService.mainApp.status == .enabled
  }

  static func setEnabled(_ enabled: Bool) throws {
    guard !isRunningTests else { return }
    if enabled {
      try SMAppService.mainApp.register()
    } else {
      try SMAppService.mainApp.unregister()
    }
  }

  static func sync(preference enabled: Bool) {
    guard !isRunningTests, isEnabled != enabled else { return }
    try? setEnabled(enabled)
  }

  private static var isRunningTests: Bool {
    ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
  }
}
