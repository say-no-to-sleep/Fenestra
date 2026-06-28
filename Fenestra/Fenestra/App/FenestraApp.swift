import SwiftUI

@main
struct FenestraApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @State private var store = FenestraStore()

  var body: some Scene {
    MenuBarExtra {
      DashboardView(store: store)
        .environment(\.paceTheme, store.settings.paceTheme)
    } label: {
      MenuBarGlyph(urgency: store.urgency)
        .environment(\.paceTheme, store.settings.paceTheme)
        .task {
          await store.start()
        }
    }
    .menuBarExtraStyle(.window)

    Settings {
      SettingsView(store: store)
        .environment(\.paceTheme, store.settings.paceTheme)
    }

    #if DEBUG
      Window("Fenestra UI Test", id: "ui-test") {
        DashboardView(store: store)
          .environment(\.paceTheme, store.settings.paceTheme)
      }
      .defaultLaunchBehavior(Self.showsUITestWindow ? .presented : .suppressed)
    #endif
  }

  #if DEBUG
    private static var showsUITestWindow: Bool {
      ProcessInfo.processInfo.environment["FENESTRA_UI_TEST_WINDOW"] == "1"
    }
  #endif
}

private struct MenuBarGlyph: View {
  let urgency: PaceUrgency
  @Environment(\.paceTheme) private var paceTheme

  var body: some View {
    Image(systemName: symbol)
      .symbolRenderingMode(.monochrome)
      .foregroundStyle(paceTheme.urgencyColor(urgency))
      .accessibilityLabel(accessibilityText)
  }

  private var symbol: String {
    switch urgency {
    case .unknown: "gauge.with.dots.needle.0percent"
    case .good: "gauge.with.dots.needle.33percent"
    case .warning: "gauge.with.dots.needle.67percent"
    case .critical: "gauge.with.dots.needle.100percent"
    }
  }

  private var accessibilityText: String {
    switch urgency {
    case .unknown: "Fenestra, pace unknown"
    case .good: "Fenestra, pace good"
    case .warning: "Fenestra, pace warning"
    case .critical: "Fenestra, pace critical"
    }
  }
}
