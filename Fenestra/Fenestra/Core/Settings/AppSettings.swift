import Foundation
import Observation

enum RefreshCadence: Int, CaseIterable, Identifiable, Sendable {
  case manual = 0
  case fortyFiveSeconds = 45
  case oneMinute = 60
  case twoMinutes = 120
  case fiveMinutes = 300
  case fifteenMinutes = 900

  var id: Int { rawValue }

  var label: String {
    switch self {
    case .manual: "Manual"
    case .fortyFiveSeconds: "45 sec"
    case .oneMinute: "1 min"
    case .twoMinutes: "2 min"
    case .fiveMinutes: "5 min"
    case .fifteenMinutes: "15 min"
    }
  }

  var duration: TimeInterval? {
    rawValue == 0 ? nil : TimeInterval(rawValue)
  }
}

@Observable
@MainActor
final class AppSettings {
  private(set) var providerEnabled = Dictionary(
    uniqueKeysWithValues: ProviderID.allCases.map {
      ($0, AppSettings.defaultEnabled(for: $0))
    }
  )
  private(set) var providerCadences = Dictionary(
    uniqueKeysWithValues: ProviderID.allCases.map {
      ($0, AppSettings.defaultCadence(for: $0))
    }
  )
  private(set) var providerConnections = Dictionary(
    uniqueKeysWithValues: ProviderID.allCases.map {
      ($0, ProviderConnectionConfiguration())
    }
  )
  var claudeCachePollCadence: RefreshCadence = .fiveMinutes { didSet { changed() } }

  var useClaudeWeeklyResetOverride = false {
    didSet {
      if useClaudeWeeklyResetOverride, claudeWeeklyResetOverride <= Date() {
        claudeWeeklyResetOverride = Date().addingTimeInterval(7 * 24 * 60 * 60)
      }
      changed()
    }
  }
  var claudeWeeklyResetOverride = Date().addingTimeInterval(7 * 24 * 60 * 60) {
    didSet { changed() }
  }
  var notificationsEnabled = true { didSet { changed() } }
  var anomalyNotificationsEnabled = true { didSet { changed() } }
  var badPaceThreshold = -25.0 { didSet { changed() } }
  var launchAtLogin = false { didSet { changed() } }
  var paceThemeStyle: PaceThemeStyle = .classic { didSet { changed() } }
  var expandedPopover = true { didSet { changed() } }
  var menuBarFollowsMostUrgent = false { didSet { changed() } }
  var menuBarShowsProviderName = true { didSet { changed() } }

  var lastSelectedProvider: ProviderID = .claudeCode {
    didSet {
      guard hasLoaded, lastSelectedProvider != oldValue else { return }
      defaults.set(lastSelectedProvider.rawValue, forKey: Keys.lastSelectedProvider)
    }
  }

  var paceTheme: PaceTheme {
    PaceTheme.palette(for: paceThemeStyle)
  }

  var badPaceThresholdMagnitude: Double {
    get { abs(badPaceThreshold) }
    set { badPaceThreshold = -abs(newValue) }
  }

  @ObservationIgnored private let defaults: UserDefaults
  @ObservationIgnored private let secretStore: any ProviderSecretStoring
  @ObservationIgnored private var hasLoaded = false
  @ObservationIgnored var onChange: (() -> Void)?

  init(
    defaults: UserDefaults = .standard,
    secretStore: any ProviderSecretStoring = KeychainProviderSecretStore()
  ) {
    self.defaults = defaults
    self.secretStore = secretStore
  }

  func load() {
    guard !hasLoaded else { return }

    providerEnabled = Dictionary(
      uniqueKeysWithValues: ProviderID.allCases.map { providerID in
        let key = providerKey(providerID, suffix: "enabled")
        let value =
          defaults.object(forKey: key) as? Bool
          ?? Self.defaultEnabled(for: providerID)
        return (providerID, value)
      }
    )
    providerCadences = Dictionary(
      uniqueKeysWithValues: ProviderID.allCases.map { providerID in
        let key = providerKey(providerID, suffix: "cadence")
        let value = cadence(
          defaults,
          key: key,
          fallback: Self.defaultCadence(for: providerID)
        )
        return (providerID, value)
      }
    )
    providerConnections = Dictionary(
      uniqueKeysWithValues: ProviderID.allCases.map { providerID in
        (providerID, loadConnectionConfiguration(for: providerID))
      }
    )
    claudeCachePollCadence = cadence(
      defaults,
      key: Keys.claudeCachePollCadence,
      fallback: .fiveMinutes
    )
    useClaudeWeeklyResetOverride =
      defaults.object(forKey: Keys.useClaudeWeeklyResetOverride) as? Bool ?? false
    if let date = defaults.object(forKey: Keys.claudeWeeklyResetOverride) as? Date {
      claudeWeeklyResetOverride = date
      if date <= Date() {
        useClaudeWeeklyResetOverride = false
      }
    } else if useClaudeWeeklyResetOverride {
      useClaudeWeeklyResetOverride = false
    }
    notificationsEnabled = defaults.object(forKey: Keys.notificationsEnabled) as? Bool ?? true
    anomalyNotificationsEnabled =
      defaults.object(forKey: Keys.anomalyNotificationsEnabled) as? Bool ?? true
    if defaults.object(forKey: Keys.badPaceThreshold) != nil {
      let storedThreshold = defaults.double(forKey: Keys.badPaceThreshold)
      if storedThreshold.isFinite {
        badPaceThreshold = min(-5, max(-75, storedThreshold))
      }
    }
    let preferredLaunchAtLogin =
      defaults.object(forKey: Keys.launchAtLogin) as? Bool ?? false
    LaunchAtLogin.sync(preference: preferredLaunchAtLogin)
    launchAtLogin = LaunchAtLogin.isEnabled
    if let rawTheme = defaults.string(forKey: Keys.paceThemeStyle),
      let style = PaceThemeStyle(rawValue: rawTheme)
    {
      paceThemeStyle = style
    }
    expandedPopover = defaults.object(forKey: Keys.expandedPopover) as? Bool ?? true
    menuBarFollowsMostUrgent = defaults.bool(forKey: Keys.menuBarFollowsMostUrgent)
    menuBarShowsProviderName =
      defaults.object(forKey: Keys.menuBarShowsProviderName) as? Bool ?? true
    if let raw = defaults.string(forKey: Keys.lastSelectedProvider),
      let providerID = ProviderID(rawValue: raw)
    {
      lastSelectedProvider = providerID
    }
    hasLoaded = true
  }

  func setLaunchAtLogin(_ enabled: Bool) {
    guard hasLoaded, enabled != launchAtLogin else { return }
    do {
      try LaunchAtLogin.setEnabled(enabled)
      launchAtLogin = enabled
    } catch {
      LocalLog.record("Launch at login failed: \(error.localizedDescription)")
    }
  }

  func isEnabled(_ providerID: ProviderID) -> Bool {
    providerEnabled[providerID] ?? Self.defaultEnabled(for: providerID)
  }

  func setEnabled(_ enabled: Bool, for providerID: ProviderID) {
    guard providerEnabled[providerID] != enabled else { return }
    providerEnabled[providerID] = enabled
    changed()
  }

  func cadence(for providerID: ProviderID) -> RefreshCadence {
    providerCadences[providerID] ?? Self.defaultCadence(for: providerID)
  }

  func setCadence(_ cadence: RefreshCadence, for providerID: ProviderID) {
    guard providerCadences[providerID] != cadence else { return }
    providerCadences[providerID] = cadence
    changed()
  }

  func connectionConfiguration(
    for providerID: ProviderID
  ) -> ProviderConnectionConfiguration {
    providerConnections[providerID] ?? ProviderConnectionConfiguration()
  }

  func setConnectionConfiguration(
    _ configuration: ProviderConnectionConfiguration,
    for providerID: ProviderID
  ) throws {
    var configuration = configuration
    if !providerID.supportedDataSources.contains(configuration.source) {
      configuration.source = .auto
    }
    try secretStore.setValue(
      configuration.apiKey,
      provider: providerID,
      field: .apiKey
    )
    try secretStore.setValue(
      configuration.secretKey,
      provider: providerID,
      field: .secretKey
    )
    try secretStore.setValue(
      configuration.cookieHeader,
      provider: providerID,
      field: .cookieHeader
    )
    guard providerConnections[providerID] != configuration else { return }
    providerConnections[providerID] = configuration
    changed()
  }

  var enabledProviders: [ProviderID] {
    ProviderID.allCases.filter(isEnabled)
  }

  var manualClaudeWeeklyReset: Date? {
    guard useClaudeWeeklyResetOverride, claudeWeeklyResetOverride > Date() else {
      return nil
    }
    return claudeWeeklyResetOverride
  }

  private func cadence(
    _ defaults: UserDefaults,
    key: String,
    fallback: RefreshCadence
  ) -> RefreshCadence {
    guard defaults.object(forKey: key) != nil else {
      return fallback
    }
    return RefreshCadence(rawValue: defaults.integer(forKey: key)) ?? fallback
  }

  private func changed() {
    guard hasLoaded else { return }
    save()
    onChange?()
  }

  private func save() {
    for providerID in ProviderID.allCases {
      defaults.set(
        isEnabled(providerID),
        forKey: providerKey(providerID, suffix: "enabled")
      )
      defaults.set(
        cadence(for: providerID).rawValue,
        forKey: providerKey(providerID, suffix: "cadence")
      )
      let connection = connectionConfiguration(for: providerID)
      defaults.set(
        connection.source.rawValue,
        forKey: providerKey(providerID, suffix: "source")
      )
      defaults.set(
        connection.cookieMode.rawValue,
        forKey: providerKey(providerID, suffix: "cookieSource")
      )
      defaults.set(
        connection.region,
        forKey: providerKey(providerID, suffix: "region")
      )
      defaults.set(
        connection.workspaceID,
        forKey: providerKey(providerID, suffix: "workspaceID")
      )
      defaults.set(
        connection.enterpriseHost,
        forKey: providerKey(providerID, suffix: "enterpriseHost")
      )
      defaults.set(
        connection.awsProfile,
        forKey: providerKey(providerID, suffix: "awsProfile")
      )
      defaults.set(
        connection.awsAuthMode,
        forKey: providerKey(providerID, suffix: "awsAuthMode")
      )
    }
    defaults.set(claudeCachePollCadence.rawValue, forKey: Keys.claudeCachePollCadence)
    defaults.set(useClaudeWeeklyResetOverride, forKey: Keys.useClaudeWeeklyResetOverride)
    defaults.set(claudeWeeklyResetOverride, forKey: Keys.claudeWeeklyResetOverride)
    defaults.set(notificationsEnabled, forKey: Keys.notificationsEnabled)
    defaults.set(anomalyNotificationsEnabled, forKey: Keys.anomalyNotificationsEnabled)
    defaults.set(badPaceThreshold, forKey: Keys.badPaceThreshold)
    defaults.set(launchAtLogin, forKey: Keys.launchAtLogin)
    defaults.set(paceThemeStyle.rawValue, forKey: Keys.paceThemeStyle)
    defaults.set(expandedPopover, forKey: Keys.expandedPopover)
    defaults.set(menuBarFollowsMostUrgent, forKey: Keys.menuBarFollowsMostUrgent)
    defaults.set(menuBarShowsProviderName, forKey: Keys.menuBarShowsProviderName)
  }

  private func providerKey(_ providerID: ProviderID, suffix: String) -> String {
    "providers.\(providerID.settingsKey).\(suffix)"
  }

  private func loadConnectionConfiguration(
    for providerID: ProviderID
  ) -> ProviderConnectionConfiguration {
    var configuration = ProviderConnectionConfiguration()
    if let raw = defaults.string(forKey: providerKey(providerID, suffix: "source")),
      let source = ProviderDataSource(rawValue: raw),
      providerID.supportedDataSources.contains(source)
    {
      configuration.source = source
    }
    if let raw = defaults.string(
      forKey: providerKey(providerID, suffix: "cookieSource")
    ),
      let cookieMode = ProviderCookieMode(rawValue: raw)
    {
      configuration.cookieMode = cookieMode
    }
    configuration.region =
      defaults.string(forKey: providerKey(providerID, suffix: "region")) ?? ""
    configuration.workspaceID =
      defaults.string(forKey: providerKey(providerID, suffix: "workspaceID")) ?? ""
    configuration.enterpriseHost =
      defaults.string(forKey: providerKey(providerID, suffix: "enterpriseHost")) ?? ""
    configuration.awsProfile =
      defaults.string(forKey: providerKey(providerID, suffix: "awsProfile")) ?? ""
    configuration.awsAuthMode =
      defaults.string(forKey: providerKey(providerID, suffix: "awsAuthMode")) ?? ""
    do {
      configuration.apiKey =
        try secretStore.value(provider: providerID, field: .apiKey) ?? ""
      configuration.secretKey =
        try secretStore.value(provider: providerID, field: .secretKey) ?? ""
      configuration.cookieHeader =
        try secretStore.value(provider: providerID, field: .cookieHeader) ?? ""
    } catch {
      LocalLog.record(
        "\(providerID.displayName) credential load failed: \(error.localizedDescription)"
      )
    }
    return configuration
  }

  private static func defaultEnabled(for providerID: ProviderID) -> Bool {
    switch providerID {
    case .claudeCode, .codex, .antigravity, .cursor:
      true
    default:
      false
    }
  }

  private static func defaultCadence(for providerID: ProviderID) -> RefreshCadence {
    switch providerID {
    case .codex:
      .fortyFiveSeconds
    case .antigravity, .cursor:
      .oneMinute
    default:
      .fiveMinutes
    }
  }

  private enum Keys {
    static let claudeCachePollCadence = "providers.claude.cacheCadence"
    static let useClaudeWeeklyResetOverride = "providers.claude.useWeeklyResetOverride"
    static let claudeWeeklyResetOverride = "providers.claude.weeklyResetOverride"
    static let notificationsEnabled = "notifications.enabled"
    static let anomalyNotificationsEnabled = "notifications.anomaliesEnabled"
    static let badPaceThreshold = "notifications.badPaceThreshold"
    static let launchAtLogin = "general.launchAtLogin"
    static let paceThemeStyle = "general.paceThemeStyle"
    static let expandedPopover = "general.expandedPopover"
    static let menuBarFollowsMostUrgent = "general.menuBarFollowsMostUrgent"
    static let menuBarShowsProviderName = "general.menuBarShowsProviderName"
    static let lastSelectedProvider = "general.lastSelectedProvider"
  }
}
