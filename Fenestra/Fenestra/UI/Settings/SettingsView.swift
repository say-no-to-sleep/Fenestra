import AppKit
import SwiftUI

struct SettingsView: View {
  let store: FenestraStore

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

      Section("Providers") {
        ProviderSettingRow(
          name: "Claude",
          isEnabled: $settings.claudeEnabled,
          cadence: $settings.claudeCadence
        )
        ProviderSettingRow(
          name: "Codex",
          isEnabled: $settings.codexEnabled,
          cadence: $settings.codexCadence
        )
        ProviderSettingRow(
          name: "Antigravity",
          isEnabled: $settings.antigravityEnabled,
          cadence: $settings.antigravityCadence
        )
        ProviderSettingRow(
          name: "Cursor",
          isEnabled: $settings.cursorEnabled,
          cadence: $settings.cursorCadence
        )
      }

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
        Picker("Cache poll", selection: $settings.claudeCachePollCadence) {
          ForEach(RefreshCadence.allCases) { cadence in
            Text(cadence.label).tag(cadence)
          }
        }
      } header: {
        Text("Claude")
      }

      Section {
        Toggle("Browser cookies", isOn: $settings.cursorBrowserAccessEnabled)
      } header: {
        Text("Cursor")
      } footer: {
        Text(
          "Fenestra never opens a Keychain dialog in the background. After enabling "
            + "browser cookies, use Allow Browser Access in the Cursor tab if needed. "
            + "Safari may require Full Disk Access. Cursor.app and Firefox need neither."
        )
      }

      Section("Alerts") {
        Toggle("Notifications", isOn: $settings.notificationsEnabled)
        HStack {
          Text("Bad pace")
          Slider(value: $settings.badPaceThreshold, in: -75 ... -5, step: 5)
          Text(
            "\(settings.badPaceThreshold.formatted(.number.precision(.fractionLength(0))))%"
          )
          .monospacedDigit()
          .frame(width: 42, alignment: .trailing)
        }
      }

      Section("Privacy") {
        Text("Provider endpoints only · No analytics · Local history")
          .foregroundStyle(.secondary)
        Button("Show debug log") {
          NSWorkspace.shared.activateFileViewerSelecting([LocalLog.fileURL])
        }
      }
    }
    .formStyle(.grouped)
    .scenePadding()
    .frame(width: 560, height: 670)
    .background(SettingsWindowLifecycle())
  }
}

private struct ProviderSettingRow: View {
  let name: String
  @Binding var isEnabled: Bool
  @Binding var cadence: RefreshCadence

  var body: some View {
    HStack {
      Toggle(name, isOn: $isEnabled)
      Spacer()
      Picker("Refresh", selection: $cadence) {
        ForEach(RefreshCadence.allCases) { item in
          Text(item.label).tag(item)
        }
      }
      .labelsHidden()
      .frame(width: 110)
      .disabled(!isEnabled)
    }
  }
}
