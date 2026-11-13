import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
  @Bindable var store: FenestraStore
  @State private var selectedTab = "general"
  @State private var providerSearch = ""

  var body: some View {
    // Sidebar layout, like System Settings: fixed window, each pane scrolls on its own.
    NavigationSplitView {
      List(selection: $selectedTab) {
        Label("General", systemImage: "gear").tag("general")
        Label("Providers", systemImage: "square.grid.2x2").tag("providers")
        Label("Alerts", systemImage: "bell").tag("alerts")
      }
      .navigationSplitViewColumnWidth(170)
      .toolbar(removing: .sidebarToggle)
    } detail: {
      switch selectedTab {
      case "providers":
        ProvidersSettingsTab(
          store: store,
          search: $providerSearch,
          configure: { store.providerToConfigure = $0 }
        )
      case "alerts":
        AlertsSettingsTab(settings: store.settings)
      default:
        GeneralSettingsTab(store: store)
      }
    }
    .frame(width: 760, height: 540)
    .background(SettingsWindowLifecycle())
    .onChange(of: store.providerToConfigure, initial: true) {
      if store.providerToConfigure != nil { selectedTab = "providers" }
    }
    .sheet(item: $store.providerToConfigure) { providerID in
      ProviderConnectionEditor(
        providerID: providerID,
        settings: store.settings
      )
    }
  }
}

struct GeneralSettingsTab: View {
  let store: FenestraStore
  @State private var exportDocument: UsageExportDocument?
  @State private var exportName = "Fenestra Usage"
  @State private var exportType: UTType = .json
  @State private var showingExporter = false
  @State private var confirmingClear = false

  var body: some View {
    @Bindable var settings = store.settings
    Form {
      Section("General") {
        Toggle(
          "Open at login",
          isOn: Binding(
            get: { settings.launchAtLogin },
            set: { settings.setLaunchAtLogin($0) }
          )
        )
        Picker("Pace colors", selection: $settings.paceThemeStyle) {
          ForEach(PaceThemeStyle.allCases) { style in
            Text(style.label).tag(style)
          }
        }
      }
      Section("Menu bar") {
        Picker("Show", selection: $settings.menuBarFollowsMostUrgent) {
          Text("Selected provider").tag(false)
          Text("Provider furthest over pace").tag(true)
        }
        Toggle("Show provider name", isOn: $settings.menuBarShowsProviderName)
      }
      Section {
        LabeledContent("Usage history") {
          Button("Export CSV…") { prepareExport(.csv) }
          Button("Export JSON…") { prepareExport(.fullJSON) }
        }
        LabeledContent("Diagnostics") {
          Button("Export…") { prepareExport(.diagnostics) }
            .help("Privacy-safe diagnostics: no credentials or account details")
          Button("Show Log") {
            NSWorkspace.shared.activateFileViewerSelecting([LocalLog.fileURL])
          }
        }
        LabeledContent("Learned and history data") {
          Button("Clear…", role: .destructive) {
            confirmingClear = true
          }
        }
      } header: {
        Text("Data")
      } footer: {
        Text("Provider endpoints only · No analytics · History stays on this Mac")
      }
    }
    .formStyle(.grouped)
    .fileExporter(
      isPresented: $showingExporter,
      document: exportDocument,
      contentType: exportType,
      defaultFilename: exportName
    ) { result in
      if case .failure(let error) = result {
        LocalLog.record("Export failed: \(error.localizedDescription)")
      }
    }
    .confirmationDialog("Clear all learned and history data?", isPresented: $confirmingClear) {
      Button("Clear Data", role: .destructive) {
        Task { await store.clearLearnedAndHistoryData() }
      }
    } message: {
      Text("This permanently removes the SQLite usage history, learned profiles, and anomalies. Provider credentials are not affected.")
    }
  }

  private enum ExportKind { case csv, fullJSON, diagnostics }

  private func prepareExport(_ kind: ExportKind) {
    Task {
      switch kind {
      case .csv:
        exportDocument = UsageExportDocument(data: await store.history.usageCSV())
        exportName = "Fenestra Usage"
        exportType = .commaSeparatedText
      case .fullJSON:
        exportDocument = UsageExportDocument(data: await store.history.fullJSON())
        exportName = "Fenestra Usage History"
        exportType = .json
      case .diagnostics:
        exportDocument = UsageExportDocument(data: await store.privacySafeDiagnosticsJSON())
        exportName = "Fenestra Diagnostics"
        exportType = .json
      }
      showingExporter = true
    }
  }
}

private struct UsageExportDocument: FileDocument {
  static var readableContentTypes: [UTType] { [.json, .commaSeparatedText] }
  let data: Data

  init(data: Data) { self.data = data }

  init(configuration: ReadConfiguration) throws {
    data = configuration.file.regularFileContents ?? Data()
  }

  func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
    FileWrapper(regularFileWithContents: data)
  }
}

struct ProvidersSettingsTab: View {
  let store: FenestraStore
  @Binding var search: String
  let configure: (ProviderID) -> Void

  private var matches: [ProviderID] {
    ProviderCatalogFilter.matches(query: search)
  }

  var body: some View {
    @Bindable var settings = store.settings
    Form {
      // ponytail: inline field, not .searchable — in a Settings window that lands in the
      // tab toolbar with a stray "Search" caption and grabs focus on open.
      Section {
        TextField("Search providers", text: $search, prompt: Text("Search providers"))
          .labelsHidden()
          .textFieldStyle(.roundedBorder)
      }
      providerSection("Enabled", providers: matches.filter(settings.isEnabled))

      if search.isEmpty, settings.isEnabled(.claudeCode) {
        Section {
          Toggle("Manual weekly reset", isOn: $settings.useClaudeWeeklyResetOverride)
          if settings.useClaudeWeeklyResetOverride {
            DatePicker(
              "Next reset",
              selection: $settings.claudeWeeklyResetOverride,
              in: Date()...,
              displayedComponents: [.date, .hourAndMinute]
            )
          }
          Picker("Cache-hit poll", selection: $settings.claudeCachePollCadence) {
            ForEach(RefreshCadence.allCases) { cadence in
              Text(cadence.label).tag(cadence)
            }
          }
        } header: {
          Text("\(ProviderID.claudeCode.displayName) options")
        } footer: {
          Text("The manual reset is used only when Claude does not report its weekly reset time.")
        }
      }

      providerSection("Available", providers: matches.filter { !settings.isEnabled($0) })

      if matches.isEmpty {
        ContentUnavailableView.search(text: search)
      }
    }
    .formStyle(.grouped)
  }

  @ViewBuilder
  private func providerSection(_ title: String, providers: [ProviderID]) -> some View {
    if !providers.isEmpty {
      Section(title) {
        ForEach(providers) { providerID in
          ProviderSettingRow(
            providerID: providerID,
            health: ProviderHealth(
              enabled: store.settings.isEnabled(providerID),
              state: store.state(for: providerID)
            ),
            isEnabled: Binding(
              get: { store.settings.isEnabled(providerID) },
              set: { store.settings.setEnabled($0, for: providerID) }
            ),
            cadence: Binding(
              get: { store.settings.cadence(for: providerID) },
              set: { store.settings.setCadence($0, for: providerID) }
            ),
            configure: { configure(providerID) }
          )
        }
      }
    }
  }
}

struct AlertsSettingsTab: View {
  @Bindable var settings: AppSettings

  var body: some View {
    Form {
      Section {
        Toggle("Notifications", isOn: $settings.notificationsEnabled)
      }
      Section {
        LabeledContent("Notify when") {
          HStack {
            Slider(value: $settings.badPaceThresholdMagnitude, in: 5...75, step: 5)
              .accessibilityLabel("Over-pace threshold")
            Text("\(settings.badPaceThresholdMagnitude.formatted(.number.precision(.fractionLength(0)))) pp over pace")
              .monospacedDigit()
              .frame(width: 120, alignment: .trailing)
          }
        }
        Toggle("Anomaly notifications", isOn: $settings.anomalyNotificationsEnabled)
      } footer: {
        Text(
          "Pace alerts fire when a quota falls this many percentage points behind an even "
            + "spend toward its reset. Anomaly alerts flag unusual provider readings."
        )
      }
      .disabled(!settings.notificationsEnabled)
    }
    .formStyle(.grouped)
  }
}

enum ProviderCatalogFilter {
  static func matches(
    query: String,
    providers: [ProviderID] = ProviderID.allCases
  ) -> [ProviderID] {
    let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return providers }
    return providers.filter {
      $0.displayName.localizedCaseInsensitiveContains(query)
    }
  }
}

struct ProviderHealth: Equatable {
  let label: String
  let systemImage: String
  let color: Color
  /// The provider's own failure message, when it has one.
  var detail: String?

  init(enabled: Bool, state: ProviderDisplayState) {
    if enabled, case .unavailable(let message) = state.availability { detail = message }
    guard enabled else {
      (label, systemImage, color) = ("Disabled", "minus.circle", .secondary)
      return
    }
    switch state.availability {
    case .idle:
      (label, systemImage, color) = ("Waiting", "clock", .secondary)
    case .loading:
      (label, systemImage, color) = ("Refreshing", "arrow.clockwise", .blue)
    case .available:
      (label, systemImage, color) = ("Connected", "checkmark.circle.fill", .green)
    case .unavailable where state.snapshot != nil:
      (label, systemImage, color) = ("Stale", "exclamationmark.triangle.fill", .orange)
    case .unavailable:
      (label, systemImage, color) = ("Needs attention", "xmark.circle.fill", .red)
    }
  }
}

private struct ProviderSettingRow: View {
  let providerID: ProviderID
  let health: ProviderHealth
  @Binding var isEnabled: Bool
  @Binding var cadence: RefreshCadence
  let configure: () -> Void

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: providerID.systemImage)
        .foregroundStyle(.secondary)
        .frame(width: 20)
      VStack(alignment: .leading, spacing: 2) {
        Text(providerID.displayName)
        if isEnabled {
          Label(health.detail ?? health.label, systemImage: health.systemImage)
            .font(.caption)
            .foregroundStyle(health.color)
            .lineLimit(1)
            .help(health.detail ?? health.label)
        }
      }
      Spacer()
      // Refresh and connection controls only mean something once a provider is on.
      if isEnabled {
        Picker("Refresh", selection: $cadence) {
          ForEach(RefreshCadence.allCases) { item in
            Text(item == .manual ? item.label : "Every \(item.label)").tag(item)
          }
        }
        .labelsHidden()
        .frame(width: 125)
        .help("How often \(providerID.displayName) is refreshed")
        .accessibilityLabel("\(providerID.displayName) refresh interval")
        // Hidden (not removed) when unconfigurable so every row's controls stay in columns.
        Button("Configure \(providerID.displayName)", systemImage: "slider.horizontal.3") {
          configure()
        }
        .labelStyle(.iconOnly)
        .help("Connection settings for \(providerID.displayName)")
        .disabled(!providerID.hasConnectionConfiguration)
        .opacity(providerID.hasConnectionConfiguration ? 1 : 0)
        .accessibilityHidden(!providerID.hasConnectionConfiguration)
      }
      Toggle("\(providerID.displayName) enabled", isOn: $isEnabled)
        .labelsHidden()
        .toggleStyle(.switch)
    }
  }
}

private struct ProviderConnectionEditor: View {
  let providerID: ProviderID
  let settings: AppSettings

  @Environment(\.dismiss) private var dismiss
  @State private var configuration: ProviderConnectionConfiguration
  @State private var errorMessage: String?

  init(providerID: ProviderID, settings: AppSettings) {
    self.providerID = providerID
    self.settings = settings
    _configuration = State(
      initialValue: settings.connectionConfiguration(for: providerID)
    )
  }

  var body: some View {
    NavigationStack {
      Form {
        Section {
          Picker("Source", selection: $configuration.source) {
            ForEach(providerID.supportedDataSources) { source in
              Text(source.label).tag(source)
            }
          }
          if providerID.supportsCookieConfiguration {
            Picker("Browser session", selection: $configuration.cookieMode) {
              ForEach(ProviderCookieMode.allCases) { mode in
                Text(mode.label).tag(mode)
              }
            }
            if configuration.cookieMode == .manual {
              SecureField(cookieFieldLabel, text: $configuration.cookieHeader)
                .textContentType(.password)
            }
          }
        } header: {
          Text("Connection")
        } footer: {
          Text(
            "Automatic follows CodexBar’s tested fallback order using installed CLIs, "
              + "local credentials, and browser sessions."
          )
        }

        if providerID.supportsAPIKeyConfiguration || providerID == .bedrock {
          Section {
            SecureField(apiKeyLabel, text: $configuration.apiKey)
              .textContentType(.password)
            if providerID == .bedrock || providerID == .stepFun {
              SecureField(secretKeyLabel, text: $configuration.secretKey)
                .textContentType(.password)
            }
          } header: {
            Text("Credentials")
          } footer: {
            Text("Credentials are stored in the macOS Keychain.")
          }
        }

        if hasAdvancedFields {
          Section("Advanced") {
            if providerID.supportsRegionConfiguration {
              TextField(regionLabel, text: $configuration.region)
            }
            if providerID.supportsWorkspaceConfiguration {
              TextField(workspaceLabel, text: $configuration.workspaceID)
            }
            if providerID.supportsHostConfiguration {
              TextField(hostLabel, text: $configuration.enterpriseHost)
            }
            if providerID == .bedrock {
              TextField("AWS profile", text: $configuration.awsProfile)
              Picker("AWS authentication", selection: $configuration.awsAuthMode) {
                Text("Automatic").tag("")
                Text("Access keys").tag("keys")
                Text("Profile").tag("profile")
              }
            }
          }
        }

        if let errorMessage {
          Section {
            Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
              .foregroundStyle(.red)
          }
        }
      }
      .formStyle(.grouped)
      .navigationTitle(providerID.displayName)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") {
            dismiss()
          }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Save") {
            save()
          }
        }
      }
    }
    .frame(width: 500, height: 520)
  }

  private var hasAdvancedFields: Bool {
    providerID.supportsRegionConfiguration
      || providerID.supportsWorkspaceConfiguration
      || providerID.supportsHostConfiguration
      || providerID == .bedrock
  }

  private var apiKeyLabel: String {
    switch providerID {
    case .bedrock: "AWS access key ID"
    case .stepFun: "Username"
    case .claudeCode: "Admin API key"
    default: "API key or token"
    }
  }

  private var secretKeyLabel: String {
    providerID == .bedrock ? "AWS secret access key" : "Password"
  }

  private var cookieFieldLabel: String {
    switch providerID {
    case .devin, .windsurf: "Bearer/session token"
    case .stepFun: "Oasis token"
    default: "Cookie header"
    }
  }

  private var regionLabel: String {
    providerID == .bedrock ? "AWS region" : "Region"
  }

  private var workspaceLabel: String {
    switch providerID {
    case .azureOpenAI: "Deployment name"
    case .deepgram: "Project ID"
    case .devin: "Organization"
    default: "Workspace / project ID"
    }
  }

  private var hostLabel: String {
    switch providerID {
    case .azureOpenAI: "Azure endpoint"
    case .jetBrains: "IDE base path"
    default: "Base URL / enterprise host"
    }
  }

  private func save() {
    do {
      try settings.setConnectionConfiguration(configuration, for: providerID)
      dismiss()
    } catch {
      errorMessage = error.localizedDescription
    }
  }
}

#if DEBUG
  #Preview("Settings General") {
    GeneralSettingsTab(store: FenestraStore.preview())
      .frame(width: 600)
  }

  #Preview("Settings Providers") {
    @Previewable @State var search = ""
    ProvidersSettingsTab(
      store: FenestraStore.preview(),
      search: $search,
      configure: { _ in }
    )
    .frame(width: 600)
  }

  #Preview("Settings Alerts") {
    AlertsSettingsTab(settings: AppSettings())
      .frame(width: 600)
  }
#endif
