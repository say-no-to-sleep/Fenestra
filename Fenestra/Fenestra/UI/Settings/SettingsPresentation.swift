import AppKit
import SwiftUI

enum SettingsPresentation {
  @MainActor
  static func open(using openSettings: OpenSettingsAction) {
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)
    openSettings()
    focusSettingsWindow()
  }

  @MainActor
  static func focusSettingsWindow() {
    for attempt in 0..<6 {
      DispatchQueue.main.asyncAfter(deadline: .now() + Double(attempt) * 0.05) {
        guard let window = settingsWindow else { return }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
      }
    }
  }

  @MainActor
  static var settingsWindow: NSWindow? {
    // The identifier is checked too: the title need not stay "… Settings" once panes exist.
    NSApp.windows.first {
      $0.title.localizedCaseInsensitiveContains("settings")
        || $0.identifier?.rawValue.localizedCaseInsensitiveContains("settings") == true
    }
  }

  @MainActor
  static func restoreMenuBarActivationPolicy() {
    NSApp.setActivationPolicy(.accessory)
  }
}

struct SettingsWindowLifecycle: NSViewRepresentable {
  func makeNSView(context: Context) -> NSView {
    let view = NSView(frame: .zero)
    DispatchQueue.main.async {
      context.coordinator.attach(to: view)
    }
    return view
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    DispatchQueue.main.async {
      context.coordinator.attach(to: nsView)
    }
  }

  func makeCoordinator() -> Coordinator { Coordinator() }

  @MainActor
  final class Coordinator {
    private var closeObserver: NSObjectProtocol?
    private weak var observedWindow: NSWindow?

    func attach(to view: NSView) {
      guard let window = view.window else { return }
      guard window !== observedWindow else { return }

      if let closeObserver {
        NotificationCenter.default.removeObserver(closeObserver)
        self.closeObserver = nil
      }

      observedWindow = window
      NSApp.setActivationPolicy(.regular)
      NSApp.activate(ignoringOtherApps: true)
      window.makeKeyAndOrderFront(nil)

      closeObserver = NotificationCenter.default.addObserver(
        forName: NSWindow.willCloseNotification,
        object: window,
        queue: .main
      ) { [weak self] _ in
        Task { @MainActor in
          guard let self else { return }
          if let observer = self.closeObserver {
            NotificationCenter.default.removeObserver(observer)
            self.closeObserver = nil
          }
          SettingsPresentation.restoreMenuBarActivationPolicy()
        }
      }
    }
  }
}
