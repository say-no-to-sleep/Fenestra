import AppKit
import SwiftUI

private enum DashboardMode: String, CaseIterable, Identifiable {
  case pace = "Pace"
  case history = "History"
  case timeline = "Timeline"
  case health = "Health"

  var id: String { rawValue }
}

struct DashboardView: View {
  @Bindable var store: FenestraStore
  @State private var mode: DashboardMode = .pace
  @State private var contentHeight: CGFloat = 220

  var body: some View {
    Group {
      if store.settings.expandedPopover {
        expandedDashboard
      } else {
        CompactDashboardView(store: store)
      }
    }
    .containerBackground(.ultraThinMaterial, for: .window)
    .background(providerShortcuts)
    .task {
      await store.start()
    }
    .onChange(of: store.selectedProvider) { contentHeight = 220 }
    .onChange(of: mode) { contentHeight = 390 }
  }

  private var expandedDashboard: some View {
    VStack(spacing: 0) {
      DashboardHeader(store: store, mode: $mode)
      Divider()
      dashboardContent
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      Divider()
      DashboardFooter(suggestion: store.smartSuggestion)
    }
    .frame(
      width: store.selectedProvider == .antigravity && mode == .pace ? 820 : 580,
      height: min(690, max(360, contentHeight + 145))
    )
  }

  // Invisible buttons so ⌘[ / ⌘] cycle providers and ⌘1…⌘9 jump directly.
  private var providerShortcuts: some View {
    let providers = store.settings.enabledProviders
    return Group {
      Button("Next provider") { cycleProvider(by: 1) }
        .keyboardShortcut("]")
      Button("Previous provider") { cycleProvider(by: -1) }
        .keyboardShortcut("[")
      ForEach(Array(providers.prefix(9).enumerated()), id: \.element) { index, provider in
        Button(provider.displayName) { store.select(provider) }
          .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")))
      }
    }
    .opacity(0)
    .frame(width: 0, height: 0)
    .accessibilityHidden(true)
  }

  private func cycleProvider(by delta: Int) {
    let providers = store.settings.enabledProviders
    guard !providers.isEmpty,
      let i = providers.firstIndex(of: store.selectedProvider)
    else { return }
    store.select(providers[(i + delta + providers.count) % providers.count])
  }

  @ViewBuilder
  private var dashboardContent: some View {
    if store.settings.enabledProviders.isEmpty {
      ContentUnavailableView {
        Label("No providers enabled", systemImage: "switch.2")
      } description: {
        Text("Enable at least one provider in Settings.")
      }
    } else if mode == .history {
      ActivityHistoryView(
        activity: store.history.dailyActivity(providerID: store.selectedProvider),
        pace: store.history.dailyWorstPace(providerID: store.selectedProvider),
        onContentHeightChange: { contentHeight = $0 }
      )
    } else if mode == .timeline {
      ResetTimelineView(items: store.resetTimeline) { contentHeight = $0 }
    } else if mode == .health {
      ProviderHealthView(store: store) { contentHeight = $0 }
    } else {
      ProviderStateView(
        providerID: store.selectedProvider,
        state: store.state(for: store.selectedProvider),
        store: store,
        onContentHeightChange: { contentHeight = $0 }
      )
    }
  }
}

private struct DashboardHeader: View {
  @Bindable var store: FenestraStore
  @Binding var mode: DashboardMode
  @Environment(\.openSettings) private var openSettings

  var body: some View {
    VStack(spacing: 10) {
      HStack(spacing: 10) {
        Picker("Provider", selection: providerSelection) {
          ForEach(store.settings.enabledProviders) { providerID in
            Label(providerID.displayName, systemImage: providerID.systemImage)
              .labelStyle(.titleAndIcon)
              .tag(providerID)
          }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .frame(minWidth: 190, alignment: .leading)
        .accessibilityLabel("Provider")

        Button("Refresh", systemImage: "arrow.clockwise") {
          Task { await store.refresh(store.selectedProvider, force: true) }
        }
        .labelStyle(.iconOnly)
        .help("Refresh")
        .disabled(!store.settings.isEnabled(store.selectedProvider))

        Button {
          SettingsPresentation.open(using: openSettings)
        } label: {
          Label("Settings", systemImage: "gear")
            .labelStyle(.iconOnly)
        }
        .help("Settings")

        Button("Compact", systemImage: "arrow.down.right.and.arrow.up.left") {
          store.settings.expandedPopover = false
        }
        .labelStyle(.iconOnly)
        .help("Use compact view")
      }

      Picker("View", selection: $mode) {
        ForEach(DashboardMode.allCases) { item in
          Text(item.rawValue).tag(item)
        }
      }
      .labelsHidden()
      .pickerStyle(.segmented)
      .controlSize(.small)
      .frame(maxWidth: 220)
    }
    .padding(14)
  }

  private var providerSelection: Binding<ProviderID> {
    Binding(
      get: { store.selectedProvider },
      set: { store.select($0) }
    )
  }
}

private struct CompactDashboardView: View {
  @Bindable var store: FenestraStore
  @Environment(\.openSettings) private var openSettings

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Label("Fenestra", systemImage: "gauge.with.dots.needle.50percent")
          .font(.headline)
        Spacer()
        Button("Refresh", systemImage: "arrow.clockwise") {
          Task { await store.refreshAll() }
        }
        .labelStyle(.iconOnly)
        Button("Settings", systemImage: "gear") {
          SettingsPresentation.open(using: openSettings)
        }
        .labelStyle(.iconOnly)
        Button("Expand", systemImage: "arrow.up.left.and.arrow.down.right") {
          store.settings.expandedPopover = true
        }
        .labelStyle(.iconOnly)
      }

      if let urgent = store.urgentQuota {
        VStack(alignment: .leading, spacing: 4) {
          Text("\(urgent.providerID.displayName) · \(urgent.windowName)")
            .font(.caption)
            .foregroundStyle(.secondary)
          Text("\(urgent.remainingPercent.formatted(.number.precision(.fractionLength(0))))% remaining")
            .font(.title2.bold())
          if let prediction = urgent.prediction {
            ForecastEvidenceView(prediction: prediction, reset: urgent.reset)
          } else if let delta = urgent.paceDelta {
            Text(delta < 0 ? "\(abs(delta).rounded().formatted())% over pace" : "On pace")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
      } else {
        Text("Waiting for usage data")
          .foregroundStyle(.secondary)
      }

      if let anomaly = store.history.activeAnomalies.first {
        Label(anomaly.kind.title, systemImage: "waveform.path.ecg.rectangle")
          .font(.caption.weight(.semibold))
          .foregroundStyle(anomaly.alertable ? .orange : .secondary)
      }

      Divider()
      VStack(alignment: .leading, spacing: 6) {
        Text("Next resets").font(.caption.weight(.semibold))
        ForEach(Array(store.resetTimeline.prefix(3))) { item in
          HStack {
            Text("\(item.providerID.displayName) · \(item.windowName)")
            Spacer()
            if let reset = item.reset {
              Text(reset, format: .dateTime.weekday(.abbreviated).hour().minute())
            } else {
              Text("Unknown")
            }
          }
          .font(.caption)
          .foregroundStyle(.secondary)
        }
      }
      Divider()
      HStack {
        Spacer()
        Button("Quit") { NSApplication.shared.terminate(nil) }
          .buttonStyle(.plain)
          .foregroundStyle(.secondary)
      }
    }
    .padding(14)
    .frame(width: 420, height: 360, alignment: .top)
  }
}

private struct DashboardFooter: View {
  let suggestion: String

  var body: some View {
    HStack {
      Label(suggestion, systemImage: "arrow.triangle.branch")
        .font(.callout)
        .foregroundStyle(.secondary)
      Spacer()
      Button("Quit") {
        NSApplication.shared.terminate(nil)
      }
      .buttonStyle(.plain)
      .foregroundStyle(.secondary)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
  }
}

private struct ProviderStateView: View {
  let providerID: ProviderID
  let state: ProviderDisplayState
  let store: FenestraStore
  let onContentHeightChange: (CGFloat) -> Void

  var body: some View {
    switch state.availability {
    case .idle, .loading:
      if let snapshot = state.snapshot {
        ProviderDashboardContent(
          snapshot: snapshot,
          errorMessage: nil,
          store: store,
          onContentHeightChange: onContentHeightChange
        )
      } else {
        ProgressView()
          .controlSize(.small)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .accessibilityLabel("Loading \(providerID.displayName) usage")
      }
    case .unavailable(let message) where state.snapshot == nil:
      UnavailableProviderView(providerID: providerID, message: message, store: store)
    default:
      if let snapshot = state.snapshot {
        ProviderDashboardContent(
          snapshot: snapshot,
          errorMessage: errorMessage,
          store: store,
          onContentHeightChange: onContentHeightChange
        )
      } else {
        UnavailableProviderView(
          providerID: providerID,
          message: "\(providerID.displayName): no usage data",
          store: store
        )
      }
    }
  }

  private var errorMessage: String? {
    if case .unavailable(let message) = state.availability {
      return message
    }
    return nil
  }
}

private struct UnavailableProviderView: View {
  let providerID: ProviderID
  let message: String
  let store: FenestraStore

  var body: some View {
    ContentUnavailableView {
      Label(providerID.displayName, systemImage: providerID.systemImage)
    } description: {
      Text(message)
    } actions: {
      if providerID == .claudeCode, message.localizedCaseInsensitiveContains("Keychain") {
        Button("Allow OAuth Access") {
          Task { await store.authorizeClaudeKeychainAccess() }
        }
      } else if providerID == .antigravity {
        Button("Open Antigravity") {
          Task { await store.openAntigravity() }
        }
      } else if providerID == .cursor,
        message.localizedCaseInsensitiveContains("Keychain")
      {
        Button("Allow Browser Access") {
          Task { await store.authorizeCursorBrowserAccess() }
        }
      }
    }
    .padding()
  }
}

#if DEBUG
  #Preview("Loading") {
    DashboardView(
      store: FenestraStore.preview(
        selectedProvider: .codex,
        state: ProviderDisplayState(availability: .loading)
      ))
  }

  #Preview("No providers") {
    DashboardView(store: FenestraStore.emptyPreview())
  }

  #Preview("Stale long metadata") {
    DashboardView(
      store: FenestraStore.preview(
        selectedProvider: .codex,
        state: ProviderDisplayState(
          snapshot: PreviewFixtures.codex,
          availability: .unavailable("Last refresh failed; showing saved usage")
        )
      ))
  }

  #Preview("Cursor breakdown") {
    DashboardView(
      store: FenestraStore.preview(
        selectedProvider: .cursor,
        state: ProviderDisplayState(snapshot: PreviewFixtures.cursor, availability: .available)
      ))
  }

  #Preview("Antigravity pools") {
    DashboardView(
      store: FenestraStore.preview(
        selectedProvider: .antigravity,
        state: ProviderDisplayState(
          snapshot: PreviewFixtures.antigravity,
          availability: .available
        )
      ))
  }
#endif
