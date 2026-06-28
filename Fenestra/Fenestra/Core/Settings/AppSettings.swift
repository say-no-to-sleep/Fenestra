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
  var claudeEnabled = true { didSet { changed() } }
  var codexEnabled = true { didSet { changed() } }
  var antigravityEnabled = true { didSet { changed() } }
  var cursorEnabled = true { didSet { changed() } }

  var claudeCadence: RefreshCadence = .fortyFiveSeconds { didSet { changed() } }
  var codexCadence: RefreshCadence = .fortyFiveSeconds { didSet { changed() } }
  var antigravityCadence: RefreshCadence = .oneMinute { didSet { changed() } }
  var cursorCadence: RefreshCadence = .oneMinute { didSet { changed() } }
  var claudeCachePollCadence: RefreshCadence = .fiveMinutes { didSet { changed() } }
  var cursorBrowserAccessEnabled = false { didSet { changed() } }

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
  var badPaceThreshold = -25.0 { didSet { changed() } }
  var launchAtLogin = false { didSet { changed() } }
  var paceThemeStyle: PaceThemeStyle = .classic { didSet { changed() } }

  var paceTheme: PaceTheme {
    PaceTheme.palette(for: paceThemeStyle)
  }

  @ObservationIgnored private let defaults: UserDefaults
  @ObservationIgnored private var hasLoaded = false
  @ObservationIgnored var onChange: (() -> Void)?

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  func load() {
    guard !hasLoaded else { return }

    claudeEnabled = defaults.object(forKey: Keys.claudeEnabled) as? Bool ?? true
    codexEnabled = defaults.object(forKey: Keys.codexEnabled) as? Bool ?? true
    antigravityEnabled = defaults.object(forKey: Keys.antigravityEnabled) as? Bool ?? true
    cursorEnabled = defaults.object(forKey: Keys.cursorEnabled) as? Bool ?? true
    claudeCadence = cadence(defaults, key: Keys.claudeCadence, fallback: .fortyFiveSeconds)
    codexCadence = cadence(defaults, key: Keys.codexCadence, fallback: .fortyFiveSeconds)
    antigravityCadence = cadence(defaults, key: Keys.antigravityCadence, fallback: .oneMinute)
    cursorCadence = cadence(defaults, key: Keys.cursorCadence, fallback: .oneMinute)
    claudeCachePollCadence = cadence(
      defaults,
      key: Keys.claudeCachePollCadence,
      fallback: .fiveMinutes
    )
    cursorBrowserAccessEnabled =
      defaults.object(forKey: Keys.cursorBrowserAccessEnabled) as? Bool ?? false
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
    switch providerID {
    case .claudeCode: claudeEnabled
    case .codex: codexEnabled
    case .antigravity: antigravityEnabled
    case .cursor: cursorEnabled
    }
  }

  func cadence(for providerID: ProviderID) -> RefreshCadence {
    switch providerID {
    case .claudeCode: claudeCadence
    case .codex: codexCadence
    case .antigravity: antigravityCadence
    case .cursor: cursorCadence
    }
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
    defaults.set(claudeEnabled, forKey: Keys.claudeEnabled)
    defaults.set(codexEnabled, forKey: Keys.codexEnabled)
    defaults.set(antigravityEnabled, forKey: Keys.antigravityEnabled)
    defaults.set(cursorEnabled, forKey: Keys.cursorEnabled)
    defaults.set(claudeCadence.rawValue, forKey: Keys.claudeCadence)
    defaults.set(codexCadence.rawValue, forKey: Keys.codexCadence)
    defaults.set(antigravityCadence.rawValue, forKey: Keys.antigravityCadence)
    defaults.set(cursorCadence.rawValue, forKey: Keys.cursorCadence)
    defaults.set(claudeCachePollCadence.rawValue, forKey: Keys.claudeCachePollCadence)
    defaults.set(cursorBrowserAccessEnabled, forKey: Keys.cursorBrowserAccessEnabled)
    defaults.set(useClaudeWeeklyResetOverride, forKey: Keys.useClaudeWeeklyResetOverride)
    defaults.set(claudeWeeklyResetOverride, forKey: Keys.claudeWeeklyResetOverride)
    defaults.set(notificationsEnabled, forKey: Keys.notificationsEnabled)
    defaults.set(badPaceThreshold, forKey: Keys.badPaceThreshold)
    defaults.set(launchAtLogin, forKey: Keys.launchAtLogin)
    defaults.set(paceThemeStyle.rawValue, forKey: Keys.paceThemeStyle)
  }

  private enum Keys {
    static let claudeEnabled = "providers.claude.enabled"
    static let codexEnabled = "providers.codex.enabled"
    static let antigravityEnabled = "providers.antigravity.enabled"
    static let cursorEnabled = "providers.cursor.enabled"
    static let claudeCadence = "providers.claude.cadence"
    static let codexCadence = "providers.codex.cadence"
    static let antigravityCadence = "providers.antigravity.cadence"
    static let cursorCadence = "providers.cursor.cadence"
    static let claudeCachePollCadence = "providers.claude.cacheCadence"
    static let cursorBrowserAccessEnabled = "providers.cursor.browserAccess"
    static let useClaudeWeeklyResetOverride = "providers.claude.useWeeklyResetOverride"
    static let claudeWeeklyResetOverride = "providers.claude.weeklyResetOverride"
    static let notificationsEnabled = "notifications.enabled"
    static let badPaceThreshold = "notifications.badPaceThreshold"
    static let launchAtLogin = "general.launchAtLogin"
    static let paceThemeStyle = "general.paceThemeStyle"
  }
}
