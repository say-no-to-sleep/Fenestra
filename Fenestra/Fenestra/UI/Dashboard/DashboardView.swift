import AppKit
import SwiftUI

struct DashboardView: View {
  @Bindable var store: FenestraStore
  @Environment(\.openSettings) private var openSettings
  @State private var contentHeight: CGFloat = 220
  @State private var isRefreshingAll = false

  var body: some View {
    TimelineView(.periodic(from: .now, by: 60)) { _ in
      if store.settings.expandedPopover {
        expandedDashboard
      } else {
        OverviewView(store: store, isRefreshing: isRefreshingAll, refreshAll: refreshAll)
      }
    }
    .containerBackground(.ultraThinMaterial, for: .window)
    .background(shortcuts)
    .task {
      await store.start()
    }
  }

  private var expandedDashboard: some View {
    VStack(spacing: 0) {
      DashboardHeader(store: store)
      Divider()
      dashboardContent
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      Divider()
      DashboardFooter(store: store)
    }
    .frame(
      width: store.selectedProvider == .antigravity ? 820 : 580,
      height: min(690, max(360, contentHeight + 115))
    )
  }

  // Invisible buttons: ⌘[ / ⌘] cycle providers, ⌘1…⌘9 jump directly, ⌘R refreshes,
  // ⌘, opens Settings and ⌘Q quits (a menu-bar-only app has no main menu to carry them).
  private var shortcuts: some View {
    let providers = store.settings.enabledProviders
    return Group {
      Button("Next provider") { cycleProvider(by: 1) }
        .keyboardShortcut("]")
      Button("Previous provider") { cycleProvider(by: -1) }
        .keyboardShortcut("[")
      ForEach(Array(providers.prefix(9).enumerated()), id: \.element) { index, provider in
        Button(provider.displayName) { show(provider) }
          .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")))
      }
      Button("Refresh") {
        if store.settings.expandedPopover {
          Task { await store.refresh(store.selectedProvider, force: true) }
        } else {
          refreshAll()
        }
      }
      .keyboardShortcut("r")
      Button("Settings") { SettingsPresentation.open(using: openSettings) }
        .keyboardShortcut(",")
      Button("Quit") { NSApplication.shared.terminate(nil) }
        .keyboardShortcut("q")
    }
    .opacity(0)
    .frame(width: 0, height: 0)
    .accessibilityHidden(true)
  }

  private func show(_ provider: ProviderID) {
    store.select(provider)
    store.settings.expandedPopover = true
  }

  private func cycleProvider(by delta: Int) {
    let providers = store.settings.enabledProviders
    guard !providers.isEmpty,
      let i = providers.firstIndex(of: store.selectedProvider)
    else { return }
    show(providers[(i + delta + providers.count) % providers.count])
  }

  // Not forced: a background-style refresh of every provider must not raise a
  // Keychain prompt per provider. The per-provider Refresh stays user-initiated.
  private func refreshAll() {
    guard !isRefreshingAll else { return }
    isRefreshingAll = true
    Task {
      await store.refreshAll()
      isRefreshingAll = false
    }
  }

  @ViewBuilder
  private var dashboardContent: some View {
    if store.settings.enabledProviders.isEmpty {
      ContentUnavailableView {
        Label("No providers enabled", systemImage: "switch.2")
      } description: {
        Text("Enable at least one provider in Settings.")
      }
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

  var body: some View {
    HStack(spacing: 10) {
      Button("All providers", systemImage: "chevron.left") {
        store.settings.expandedPopover = false
      }
      .labelStyle(.iconOnly)
      .help("All providers")

      Picker("Provider", selection: providerSelection) {
        ForEach(store.settings.enabledProviders) { providerID in
          Label(providerID.displayName, systemImage: providerID.systemImage)
            .labelStyle(.titleAndIcon)
            .tag(providerID)
        }
      }
      .labelsHidden()
      .pickerStyle(.menu)
      .help("Switch provider: ⌘[ / ⌘]. Jump to a provider: ⌘1–⌘9.")
      .frame(minWidth: 190, alignment: .leading)
      .fixedSize()
      Spacer()
      let isRefreshing = store.state(for: store.selectedProvider).availability == .loading

      Button("Refresh", systemImage: "arrow.clockwise") {
        Task { await store.refresh(store.selectedProvider, force: true) }
      }
      .labelStyle(.iconOnly)
      .help(isRefreshing ? "Refreshing…" : "Refresh (⌘R)")
      .disabled(!store.settings.isEnabled(store.selectedProvider) || isRefreshing)

      DashboardMenu()
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

/// Settings and Quit, kept out of the way of the quota content.
private struct DashboardMenu: View {
  @Environment(\.openSettings) private var openSettings

  var body: some View {
    Menu("More", systemImage: "ellipsis.circle") {
      Button("Settings… (⌘,)") { SettingsPresentation.open(using: openSettings) }
      Divider()
      Button("Quit Fenestra (⌘Q)") { NSApplication.shared.terminate(nil) }
    }
    .labelStyle(.iconOnly)
    .menuIndicator(.hidden)
    .fixedSize()
    .help("Settings and Quit")
  }
}

/// Every enabled provider at a glance; a row opens that provider's charts.
private struct OverviewView: View {
  @Bindable var store: FenestraStore
  let isRefreshing: Bool
  let refreshAll: () -> Void

  private static let rowHeight: CGFloat = 52

  var body: some View {
    let providers = store.settings.enabledProviders
    VStack(spacing: 0) {
      HStack(spacing: 10) {
        Text("All providers").font(.headline)
        Spacer()
        if isRefreshing { ProgressView().controlSize(.small) }
        Button("Refresh all", systemImage: "arrow.clockwise", action: refreshAll)
          .labelStyle(.iconOnly)
          .help(isRefreshing ? "Refreshing…" : "Refresh all (⌘R)")
          .disabled(providers.isEmpty || isRefreshing)
        DashboardMenu()
      }
      .padding(14)
      Divider()
      if providers.isEmpty {
        ContentUnavailableView {
          Label("No providers enabled", systemImage: "switch.2")
        } description: {
          Text("Enable at least one provider in Settings.")
        }
        .frame(height: 200)
      } else {
        ScrollView {
          LazyVStack(spacing: 0) {
            ForEach(Array(providers.enumerated()), id: \.element) { index, providerID in
              OverviewRow(
                providerID: providerID,
                summary: store.quotaSummary(for: providerID, limiting: true),
                state: store.state(for: providerID),
                isStale: store.isStale(providerID),
                shortcut: index < 9 ? "⌘\(index + 1)" : nil
              ) {
                store.select(providerID)
                store.settings.expandedPopover = true
              }
              .frame(height: Self.rowHeight)
            }
          }
        }
        .frame(height: min(CGFloat(providers.count) * Self.rowHeight, 7 * Self.rowHeight))
      }
      Divider()
      DashboardFooter(store: store)
    }
    .frame(width: 420)
  }
}

private struct OverviewRow: View {
  let providerID: ProviderID
  let summary: UrgentQuotaSummary?
  let state: ProviderDisplayState
  let isStale: Bool
  let shortcut: String?
  let open: () -> Void
  @Environment(\.paceTheme) private var paceTheme
  @State private var isHovered = false

  var body: some View {
    Button(action: open) {
      HStack(spacing: 10) {
        Image(systemName: providerID.systemImage)
          .foregroundStyle(.secondary)
          .frame(width: 20)
        VStack(alignment: .leading, spacing: 2) {
          Text(providerID.displayName)
          caption
            .font(.caption)
            .foregroundStyle(needsAttention ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
            .lineLimit(1)
        }
        Spacer(minLength: 8)
        if let summary {
          VStack(alignment: .trailing, spacing: 2) {
            Text("\(summary.remainingPercent.formatted(.number.precision(.fractionLength(0))))% left")
              .font(.body.weight(.semibold))
              .monospacedDigit()
            if let delta = summary.paceDelta {
              let pace = PaceEvaluation(idealRemaining: 0, delta: delta, exhaustionPrediction: nil)
              Text(pace.label)
                .font(.caption)
                .foregroundStyle(pace.label == "On pace"
                  ? AnyShapeStyle(.secondary) : AnyShapeStyle(paceTheme.color(delta: delta)))
            }
          }
        } else if state.availability == .loading {
          ProgressView().controlSize(.small)
        }
        Image(systemName: "chevron.right")
          .font(.caption)
          .foregroundStyle(.tertiary)
      }
      .padding(.horizontal, 14)
      .frame(maxHeight: .infinity)
      .background(isHovered ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear))
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .onHover { isHovered = $0 }
    .help(shortcut.map { "Show \(providerID.displayName) charts (\($0))" }
      ?? "Show \(providerID.displayName) charts")
    .accessibilityElement(children: .combine)
  }

  private var needsAttention: Bool {
    if isStale, summary != nil { return true }
    if case .unavailable = state.availability { return true }
    return false
  }

  @ViewBuilder
  private var caption: some View {
    if let summary {
      if isStale {
        Text("Saved usage · refresh needed")
      } else if let reset = summary.reset {
        Text("\(summary.windowName) · resets \(reset, format: .relative(presentation: .numeric))")
      } else {
        // Never invent a reset: say so when the provider gave no anchor.
        Text("\(summary.windowName) · reset time unknown")
      }
    } else if case .unavailable(let message) = state.availability {
      Text(message)
    } else if state.snapshot != nil {
      Text("No percentage quota")
    } else {
      Text("Waiting for usage data")
    }
  }
}

private struct DashboardFooter: View {
  let store: FenestraStore

  var body: some View {
    let suggestion = store.smartSuggestion
    Button {
      if let target = suggestion.target {
        store.select(target)
        store.settings.expandedPopover = true
      }
    } label: {
      Label(suggestion.text, systemImage: "arrow.triangle.branch")
        .font(.callout)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .allowsHitTesting(suggestion.target != nil)
    .help(suggestion.target.map { "Show \($0.displayName)" } ?? suggestion.text)
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
          isRefreshing: state.availability == .loading,
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
          isRefreshing: false,
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
  @Environment(\.openSettings) private var openSettings

  var body: some View {
    ContentUnavailableView {
      Label(providerID.displayName, systemImage: providerID.systemImage)
    } description: {
      Text(message)
    } actions: {
      Button("Retry", systemImage: "arrow.clockwise") {
        Task { await store.refresh(providerID, force: true) }
      }
      Button("Connection settings", systemImage: "gear") {
        store.providerToConfigure = providerID
        SettingsPresentation.open(using: openSettings)
      }
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
