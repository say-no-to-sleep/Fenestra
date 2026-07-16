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
    underPace: .blue,
    overPace: .purple
  )

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

extension EnvironmentValues {
  @Entry var paceTheme = PaceTheme.classic
}
