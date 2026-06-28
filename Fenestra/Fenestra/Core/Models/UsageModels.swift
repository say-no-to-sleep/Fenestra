import Foundation

enum ProviderID: String, CaseIterable, Codable, Identifiable, Sendable {
  case claudeCode
  case codex
  case antigravity
  case cursor

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .claudeCode: "Claude"
    case .codex: "Codex"
    case .antigravity: "Antigravity"
    case .cursor: "Cursor"
    }
  }

  var systemImage: String {
    switch self {
    case .claudeCode: "c.square.fill"
    case .codex: "terminal.fill"
    case .antigravity: "sparkles"
    case .cursor: "cursorarrow.rays"
    }
  }
}

enum UsageWindowKind: String, Codable, Sendable {
  case fiveHour
  case weekly
  case monthly
  case other

  var shortLabel: String {
    switch self {
    case .fiveHour: "5h"
    case .weekly: "Week"
    case .monthly: "Month"
    case .other: "Quota"
    }
  }

  var knownDuration: TimeInterval? {
    switch self {
    case .fiveHour: 5 * 60 * 60
    case .weekly: 7 * 24 * 60 * 60
    case .monthly: nil
    case .other: nil
    }
  }

  nonisolated var panelLabel: String {
    switch self {
    case .fiveHour: "5-hour"
    case .weekly: "Weekly"
    case .monthly: "Monthly"
    case .other: "Quota"
    }
  }

  nonisolated static func inferred(from duration: TimeInterval?) -> UsageWindowKind {
    guard let duration, duration.isFinite, duration > 0 else { return .other }
    let hour: TimeInterval = 60 * 60
    let day: TimeInterval = 24 * hour
    if duration <= 6 * hour { return .fiveHour }
    if duration >= 20 * day { return .monthly }
    if duration >= 6 * day { return .weekly }
    return .other
  }
}

struct UsageBreakdownItem: Codable, Equatable, Identifiable, Sendable {
  let id: String
  let label: String
  let usedPercent: Double
}

struct UsageWindowSnapshot: Codable, Equatable, Identifiable, Sendable {
  let id: String
  let kind: UsageWindowKind
  let label: String
  let windowStart: Date?
  let windowEnd: Date?
  let quotaTotal: Double
  let used: Double
  let remainingPercent: Double
  let resetSource: String?
  let breakdown: [UsageBreakdownItem]

  var hasKnownTimeline: Bool {
    guard let windowStart, let windowEnd else { return false }
    return windowEnd > windowStart
  }
}

struct UsagePoolSnapshot: Codable, Equatable, Identifiable, Sendable {
  let id: String
  let name: String
  let windows: [UsageWindowSnapshot]
}

struct UsageSnapshot: Codable, Equatable, Identifiable, Sendable {
  var id: ProviderID { providerID }

  let providerID: ProviderID
  let displayName: String
  let pools: [UsagePoolSnapshot]
  let freshness: Date
  let sourceDescription: String
  let cacheHitRate: Double?
  let accountDescription: String?
  let notes: [String]
}

struct HistoryPoint: Codable, Equatable, Identifiable, Sendable {
  let id: UUID
  let providerID: ProviderID
  let poolID: String
  let windowID: String
  let timestamp: Date
  let remainingPercent: Double
  let paceDelta: Double?

  init(
    id: UUID = UUID(),
    providerID: ProviderID,
    poolID: String,
    windowID: String,
    timestamp: Date,
    remainingPercent: Double,
    paceDelta: Double?
  ) {
    self.id = id
    self.providerID = providerID
    self.poolID = poolID
    self.windowID = windowID
    self.timestamp = timestamp
    self.remainingPercent = remainingPercent
    self.paceDelta = paceDelta
  }
}

struct PaceEvaluation: Equatable, Sendable {
  let idealRemaining: Double
  let delta: Double
  let projectedExhaustion: Date?

  var isOverPace: Bool { delta < 0 }

  var label: String {
    let amount = abs(delta).rounded()
    return delta < 0
      ? "\(amount.formatted(.number.precision(.fractionLength(0))))% over pace"
      : "\(amount.formatted(.number.precision(.fractionLength(0))))% under pace"
  }
}

enum ProviderAvailability: Equatable, Sendable {
  case idle
  case loading
  case available
  case unavailable(String)
}

struct ProviderDisplayState: Equatable, Sendable {
  var snapshot: UsageSnapshot?
  var availability: ProviderAvailability = .idle
}
