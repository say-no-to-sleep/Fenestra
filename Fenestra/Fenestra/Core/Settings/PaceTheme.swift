import AppKit
import SwiftUI

enum PaceThemeStyle: String, CaseIterable, Identifiable, Codable, Sendable {
  case classic
  case bluePurple

  var id: String { rawValue }

  var label: String {
    switch self {
    case .classic: "Green & red"
    case .bluePurple: "Blue & purple"
    }
  }
}

struct PaceTheme: Equatable {
  let underPace: Color
  let overPace: Color

  static let classic = PaceTheme(underPace: .green, overPace: .red)

  static let bluePurple = PaceTheme(
    underPace: adaptivePaceColor(red: 67, green: 44, blue: 95),
    overPace: adaptivePaceColor(red: 29, green: 37, blue: 84)
  )

  private static func adaptivePaceColor(red: Int, green: Int, blue: Int) -> Color {
    let light = (
      CGFloat(red) / 255,
      CGFloat(green) / 255,
      CGFloat(blue) / 255
    )
    let lighten: CGFloat = 0.58
    let dark = (
      light.0 + (1 - light.0) * lighten,
      light.1 + (1 - light.1) * lighten,
      light.2 + (1 - light.2) * lighten
    )
    return Color(
      nsColor: NSColor(name: nil, dynamicProvider: { appearance in
        let rgb: (CGFloat, CGFloat, CGFloat)
        switch appearance.bestMatch(from: [.darkAqua, .aqua]) {
        case .darkAqua:
          rgb = dark
        default:
          rgb = light
        }
        return NSColor(red: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
      })
    )
  }

  static func palette(for style: PaceThemeStyle) -> PaceTheme {
    switch style {
    case .classic: .classic
    case .bluePurple: .bluePurple
    }
  }

  func color(isOverPace: Bool) -> Color {
    isOverPace ? overPace : underPace
  }

  func color(delta: Double) -> Color {
    delta < 0 ? overPace : underPace
  }

  func fill(isOverPace: Bool, opacity: Double) -> Color {
    color(isOverPace: isOverPace).opacity(opacity)
  }

  func fill(delta: Double, opacity: Double) -> Color {
    color(delta: delta).opacity(opacity)
  }

  func urgencyColor(_ urgency: PaceUrgency) -> Color {
    switch urgency {
    case .unknown: .secondary
    case .good: underPace
    case .warning: .yellow
    case .critical: overPace
    }
  }
}

private struct PaceThemeKey: EnvironmentKey {
  static let defaultValue = PaceTheme.classic
}

extension EnvironmentValues {
  var paceTheme: PaceTheme {
    get { self[PaceThemeKey.self] }
    set { self[PaceThemeKey.self] = newValue }
  }
}
