import CodexBarCore
import Foundation

enum ProviderID: String, CaseIterable, Codable, Identifiable, Sendable {
  case codex
  case openAI = "openai"
  case azureOpenAI = "azureopenai"
  case claudeCode
  case cursor
  case openCode = "opencode"
  case openCodeGo = "opencodego"
  case alibaba = "alibaba"
  case alibabaTokenPlan = "alibabatokenplan"
  case factory
  case gemini
  case antigravity
  case copilot
  case devin
  case zai
  case miniMax = "minimax"
  case manus
  case kimi
  case kilo
  case kiro
  case vertexAI = "vertexai"
  case augment
  case jetBrains = "jetbrains"
  case kimiK2 = "kimik2"
  case moonshot
  case amp
  case t3Chat = "t3chat"
  case ollama
  case synthetic
  case warp
  case openRouter = "openrouter"
  case elevenLabs = "elevenlabs"
  case windsurf
  case zed
  case perplexity
  case mimo
  case doubao
  case sakana
  case abacus
  case mistral
  case deepSeek = "deepseek"
  case codebuff
  case crof
  case venice
  case commandCode = "commandcode"
  case stepFun = "stepfun"
  case bedrock
  case grok
  case groq
  case llmProxy = "llmproxy"
  case liteLLM = "litellm"
  case deepgram
  case poe
  case chutes

  var id: String { rawValue }

  var codexBarProvider: CodexBarCore.UsageProvider {
    let coreRawValue = self == .claudeCode ? "claude" : rawValue
    guard let provider = CodexBarCore.UsageProvider(rawValue: coreRawValue) else {
      preconditionFailure("Missing CodexBar provider mapping for \(rawValue)")
    }
    return provider
  }

  var displayName: String {
    ProviderDescriptorRegistry.descriptor(for: codexBarProvider).metadata.displayName
  }

  var systemImage: String {
    switch self {
    case .claudeCode: "c.square.fill"
    case .codex: "terminal.fill"
    case .antigravity: "sparkles"
    case .cursor: "cursorarrow.rays"
    case .openAI, .azureOpenAI: "brain.head.profile.fill"
    case .gemini: "diamond.fill"
    case .copilot: "chevron.left.forwardslash.chevron.right"
    case .vertexAI, .bedrock: "cloud.fill"
    case .openCode, .openCodeGo, .kiro, .amp, .codebuff:
      "terminal.fill"
    default: "gauge.with.dots.needle.50percent"
    }
  }

  var settingsKey: String {
    codexBarProvider.rawValue
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

  nonisolated var knownDuration: TimeInterval? {
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
  // Tokens consumed within this window, summed from local Claude Code transcripts.
  // nil when no token data is available (e.g. non-Claude providers, or no CLI usage).
  var tokensUsed: Double? = nil

  nonisolated var hasKnownTimeline: Bool {
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
  var planDescription: String? = nil
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
  var regimeID: UUID? = nil
  var windowInstanceID: UUID? = nil

  nonisolated init(
    id: UUID = UUID(),
    providerID: ProviderID,
    poolID: String,
    windowID: String,
    timestamp: Date,
    remainingPercent: Double,
    paceDelta: Double?,
    regimeID: UUID? = nil,
    windowInstanceID: UUID? = nil
  ) {
    self.id = id
    self.providerID = providerID
    self.poolID = poolID
    self.windowID = windowID
    self.timestamp = timestamp
    self.remainingPercent = remainingPercent
    self.paceDelta = paceDelta
    self.regimeID = regimeID
    self.windowInstanceID = windowInstanceID
  }
}

enum ExhaustionPredictionConfidence: String, Codable, Equatable, Sendable {
  case medium
  case high
  case unstable
}

enum ExhaustionPredictionMethod: String, Codable, Equatable, Sendable {
  case recent
  case blended
  case personalized
}

struct ExhaustionPrediction: Codable, Equatable, Sendable {
  let earliest: Date?
  let likely: Date?
  let latest: Date?
  let confidence: ExhaustionPredictionConfidence
  let method: ExhaustionPredictionMethod
  let exhaustionProbability: Double?
  let evidenceCount: Int
  let validationError: TimeInterval?
  let notificationEligible: Bool

  init(
    earliest: Date?,
    likely: Date?,
    latest: Date?,
    confidence: ExhaustionPredictionConfidence,
    method: ExhaustionPredictionMethod = .recent,
    exhaustionProbability: Double? = nil,
    evidenceCount: Int = 0,
    validationError: TimeInterval? = nil,
    notificationEligible: Bool = true
  ) {
    self.earliest = earliest
    self.likely = likely
    self.latest = latest
    self.confidence = confidence
    self.method = method
    self.exhaustionProbability = exhaustionProbability
    self.evidenceCount = evidenceCount
    self.validationError = validationError
    self.notificationEligible = notificationEligible
  }

  var hasRange: Bool {
    earliest != nil && likely != nil && latest != nil && confidence != .unstable
  }
}

struct SubscriptionRegime: Codable, Equatable, Identifiable, Sendable {
  let id: UUID
  let providerID: ProviderID
  let fingerprint: String
  let planName: String?
  let startedAt: Date
  var endedAt: Date?
  let createdManually: Bool
  var returningPlanNeedsValidation: Bool
  var completedWindowsSinceReturn: Int

  var isActive: Bool { endedAt == nil }
}

struct HistoricalUsageWindow: Codable, Equatable, Identifiable, Sendable {
  let id: UUID
  let providerID: ProviderID
  let seriesKey: String
  let poolID: String
  let windowID: String
  let kind: UsageWindowKind
  let start: Date
  let end: Date
  let quotaTotal: Double
  let regimeID: UUID?
  let planName: String?
  let observationCoverage: Double
  let samples: [HistoryPoint]

  var totalPercentUsed: Double {
    guard let first = samples.first, let last = samples.last else { return 0 }
    return max(0, first.remainingPercent - last.remainingPercent)
  }

  var peakBurnPerHour: Double {
    zip(samples, samples.dropFirst()).reduce(0) { peak, pair in
      let elapsed = pair.1.timestamp.timeIntervalSince(pair.0.timestamp)
      guard elapsed > 0 else { return peak }
      return max(peak, max(0, pair.0.remainingPercent - pair.1.remainingPercent) / elapsed * 3_600)
    }
  }

  var exhaustedAt: Date? {
    samples.first(where: { $0.remainingPercent <= 0 })?.timestamp
  }
}

enum RefreshFailureCategory: String, Codable, CaseIterable, Sendable {
  case authentication
  case network
  case rateLimited
  case unavailable
  case parsing
  case unknown
}

struct ProviderRefreshEvent: Codable, Equatable, Identifiable, Sendable {
  let id: UUID
  let providerID: ProviderID
  let timestamp: Date
  let duration: TimeInterval
  let source: String?
  let succeeded: Bool
  let failureCategory: RefreshFailureCategory?
  let staleDuration: TimeInterval
}

enum UsageAnomalyKind: String, Codable, CaseIterable, Sendable {
  case unusualBurn
  case overdueReset
  case upwardCorrection
  case repeatedRefreshFailure
  case sourceDisagreement

  var title: String {
    switch self {
    case .unusualBurn: "Unusual usage burst"
    case .overdueReset: "Reset appears overdue"
    case .upwardCorrection: "Provider corrected usage"
    case .repeatedRefreshFailure: "Provider refresh is unreliable"
    case .sourceDisagreement: "Usage sources disagree"
    }
  }
}

struct UsageAnomaly: Codable, Equatable, Identifiable, Sendable {
  let id: UUID
  let providerID: ProviderID
  let seriesKey: String?
  let kind: UsageAnomalyKind
  let detectedAt: Date
  var confirmedAt: Date?
  var resolvedAt: Date?
  let detail: String
  let alertable: Bool

  var isActive: Bool { resolvedAt == nil }
}

struct ProviderHealthSummary: Equatable, Sendable {
  let providerID: ProviderID
  let source: String?
  let lastSuccess: Date?
  let sevenDaySuccessRate: Double?
  let medianRefreshLatency: TimeInterval?
  let fallbackCount: Int
  let staleDuration: TimeInterval
  let resetAccuracy: TimeInterval?
  let activeRegime: SubscriptionRegime?
  let activeAnomalies: [UsageAnomaly]
}

struct ResetTimelineItem: Identifiable, Equatable, Sendable {
  let providerID: ProviderID
  let poolName: String
  let windowName: String
  let reset: Date?

  var id: String { "\(providerID.rawValue)|\(poolName)|\(windowName)" }
}

struct UrgentQuotaSummary: Equatable, Sendable {
  let providerID: ProviderID
  let poolName: String
  let windowName: String
  let remainingPercent: Double
  let paceDelta: Double?
  let prediction: ExhaustionPrediction?
  let reset: Date?
}

struct StoredUsageWindow: Codable, Equatable, Identifiable, Sendable {
  let id: UUID
  let providerID: ProviderID
  let seriesKey: String
  let poolID: String
  let windowID: String
  let kind: UsageWindowKind
  let start: Date
  let end: Date
  let quotaTotal: Double
  let regimeID: UUID?
  let planName: String?
  let observationCoverage: Double
}

struct UsageHistoryExport: Codable, Sendable {
  let generatedAt: Date
  let regimes: [SubscriptionRegime]
  let windows: [StoredUsageWindow]
  let samples: [HistoryPoint]
  let refreshEvents: [ProviderRefreshEvent]
  let anomalies: [UsageAnomaly]
}

struct PaceEvaluation: Equatable, Sendable {
  let idealRemaining: Double
  let delta: Double
  let exhaustionPrediction: ExhaustionPrediction?

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
