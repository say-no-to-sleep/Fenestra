import AppKit
import SwiftUI

private enum DashboardMode: String, CaseIterable, Identifiable {
  case pace = "Pace"
  case history = "History"

  var id: String { rawValue }
}

struct DashboardView: View {
  @Bindable var store: FenestraStore
  @State private var mode: DashboardMode = .pace

  var body: some View {
    VStack(spacing: 0) {
      DashboardHeader(store: store, mode: $mode)
      Divider()
      dashboardContent
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      Divider()
      DashboardFooter(suggestion: store.smartSuggestion)
    }
    .frame(
      width: store.selectedProvider == .antigravity ? 820 : 580,
      height: 690
    )
    .containerBackground(.ultraThinMaterial, for: .window)
    .task {
      await store.start()
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
    } else if mode == .history {
      ActivityHistoryView(
        activity: store.history.dailyActivity(providerID: store.selectedProvider),
        pace: store.history.dailyWorstPace(providerID: store.selectedProvider)
      )
    } else {
      ProviderStateView(
        providerID: store.selectedProvider,
        state: store.state(for: store.selectedProvider),
        store: store
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
        .pickerStyle(.segmented)
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

  var body: some View {
    switch state.availability {
    case .idle, .loading:
      if let snapshot = state.snapshot {
        ProviderDashboardContent(snapshot: snapshot, errorMessage: nil, store: store)
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
          store: store
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
        store.settings.cursorBrowserAccessEnabled,
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
