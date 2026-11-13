import SwiftUI

@main
struct FenestraApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @State private var store = FenestraStore()
  @State private var menuNow = Date()

  var body: some Scene {
    MenuBarExtra {
      DashboardView(store: store)
        .environment(\.paceTheme, store.settings.paceTheme)
    } label: {
      MenuBarGlyph(urgency: store.menuUrgency, quota: store.menuQuota,
                   isStale: store.isStale(store.menuQuota?.providerID ?? store.selectedProvider,
                                          at: menuNow),
                   showsProviderName: store.settings.menuBarShowsProviderName)
        .environment(\.paceTheme, store.settings.paceTheme)
        .task {
          await store.start()
          while !Task.isCancelled {
            do { try await Task.sleep(for: .seconds(60)) } catch { return }
            menuNow = Date()
          }
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
  let quota: UrgentQuotaSummary?
  let isStale: Bool
  let showsProviderName: Bool
  @Environment(\.paceTheme) private var paceTheme

  var body: some View {
    HStack(spacing: 4) {
      Image(systemName: symbol)
        .symbolRenderingMode(.monochrome)
        .foregroundStyle(isStale ? .orange : paceTheme.urgencyColor(urgency))
      if let quota {
        Text("\(showsProviderName ? quota.providerID.displayName + " " : "")\(quota.remainingPercent.formatted(.number.precision(.fractionLength(0))))% · \(quota.windowKind.shortLabel)")
          .monospacedDigit()
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(accessibilityText)
    .help(accessibilityText)
  }

  private var symbol: String {
    if isStale { return "exclamationmark.triangle" }
    return switch urgency {
    case .unknown: "gauge.with.dots.needle.0percent"
    case .good: "gauge.with.dots.needle.33percent"
    case .warning: "gauge.with.dots.needle.67percent"
    case .critical: "gauge.with.dots.needle.100percent"
    }
  }

  private var accessibilityText: String {
    if let quota {
      var value = "Fenestra. \(quota.providerID.displayName) \(quota.windowName), \(quota.remainingPercent.formatted(.number.precision(.fractionLength(0)))) percent remaining"
      if let delta = quota.paceDelta {
        value += delta < 0 ? ", \(abs(delta).rounded().formatted()) percentage points over pace" : ", on pace"
      }
      if isStale { value += ", stale data; refresh needed" }
      return value
    }
    return switch urgency {
    case .unknown: "Fenestra, pace unknown"
    case .good: "Fenestra, pace good"
    case .warning: "Fenestra, pace warning"
    case .critical: "Fenestra, pace critical"
    }
  }
}
