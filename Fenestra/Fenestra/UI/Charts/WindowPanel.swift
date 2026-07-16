import Charts
import SwiftUI

private struct WindowChartSample: Identifiable {
  let id: String
  let date: Date
  let remaining: Double
  let ideal: Double

  var isOverPace: Bool { remaining < ideal }
}

private struct PaceBandSegment: Identifiable {
  let id: String
  let isOverPace: Bool
  let samples: [WindowChartSample]
}

private struct PredictionBandSample: Identifiable {
  var id: Date { date }
  let date: Date
  let lowerRemaining: Double
  let upperRemaining: Double
  let likelyRemaining: Double
}

struct WindowPanel: View {
  let providerID: ProviderID
  let pool: UsagePoolSnapshot
  let window: UsageWindowSnapshot
  let freshness: Date
  let history: [HistoryPoint]
  let evaluation: PaceEvaluation?

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      WindowPanelHeader(window: window, evaluation: evaluation)
      if let windowStart = window.windowStart,
        let windowEnd = window.windowEnd,
        windowEnd > windowStart
      {
        WindowPaceChart(
          window: window,
          windowStart: windowStart,
          windowEnd: windowEnd,
          freshness: freshness,
          history: history,
          evaluation: evaluation
        )
        .frame(minHeight: 155)
      } else {
        UnknownTimelineView(window: window)
      }
      if window.tokensUsed != nil {
        TokenUsageRow(window: window)
      }
      if window.remainingPercent <= 0 {
        PredictionBanner(status: .exhausted)
      } else if let status = predictionStatus {
        PredictionBanner(status: status)
      }
      if let prediction = evaluation?.exhaustionPrediction, prediction.method != .recent {
        ForecastEvidenceView(prediction: prediction, reset: window.windowEnd)
      }
      if !window.breakdown.isEmpty {
        UsageBreakdown(items: window.breakdown)
      }
    }
    .padding(12)
    .background {
      RoundedRectangle(cornerRadius: 12)
        .fill(.quaternary.opacity(0.45))
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("\(providerID.displayName), \(pool.name), \(window.label)")
  }

  private var predictionStatus: PredictionBanner.Status? {
    guard let prediction = evaluation?.exhaustionPrediction else { return nil }
    guard prediction.hasRange else { return .unstable }
    guard let earliest = prediction.earliest,
      let likely = prediction.likely,
      let latest = prediction.latest,
      let reset = window.windowEnd,
      earliest < reset
    else { return nil }
    return likely < reset
      ? .likely(earliest: earliest, latest: latest)
      : .possible
  }
}

private struct WindowPanelHeader: View {
  let window: UsageWindowSnapshot
  let evaluation: PaceEvaluation?
  @Environment(\.paceTheme) private var paceTheme

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 10) {
      Text(window.label)
        .font(.headline)
      Spacer()
      Text("\(window.remainingPercent.formatted(.number.precision(.fractionLength(0))))% left")
        .font(.callout.monospacedDigit())
        .foregroundStyle(.secondary)
      if let evaluation {
        Text(evaluation.label)
          .font(.callout.weight(.semibold))
          .foregroundStyle(paceTheme.color(isOverPace: evaluation.isOverPace))
      }
    }
  }
}

private struct WindowPaceChart: View, AXChartDescriptorRepresentable {
  let window: UsageWindowSnapshot
  let windowStart: Date
  let windowEnd: Date
  let freshness: Date
  let history: [HistoryPoint]
  let evaluation: PaceEvaluation?
  @Environment(\.paceTheme) private var paceTheme
  @State private var hoveredDate: Date?
  @State private var zoomDomain: ClosedRange<Date>?
  @State private var pendingZoom: ClosedRange<Date>?

  private var visibleDomain: ClosedRange<Date> {
    zoomDomain ?? windowStart...windowEnd
  }

  private var yDomain: ClosedRange<Double> {
    min(0, window.remainingPercent - 10)...max(100, window.remainingPercent + 10)
  }

  private var samples: [WindowChartSample] {
    var values = history.compactMap { point -> WindowChartSample? in
      guard
        let ideal = PaceCalculator.idealRemaining(
          at: point.timestamp,
          windowStart: windowStart,
          windowEnd: windowEnd
        )
      else {
        return nil
      }
      return WindowChartSample(
        id: point.id.uuidString,
        date: point.timestamp,
        remaining: point.remainingPercent,
        ideal: ideal
      )
    }
    if values.last?.date != freshness,
      let ideal = PaceCalculator.idealRemaining(
        at: freshness,
        windowStart: windowStart,
        windowEnd: windowEnd
      )
    {
      values.append(
        WindowChartSample(
          id: "current-\(window.id)",
          date: freshness,
          remaining: window.remainingPercent,
          ideal: ideal
        ))
    }
    return values
  }

  private var isOverPace: Bool {
    evaluation?.isOverPace ?? samples.last?.isOverPace ?? false
  }

  private var paceBandSegments: [PaceBandSegment] {
    guard let first = samples.first else { return [] }
    var result: [PaceBandSegment] = []
    var current = [first]
    var isOver = first.isOverPace

    for sample in samples.dropFirst() {
      guard let previous = current.last else { continue }
      if sample.isOverPace == isOver {
        current.append(sample)
        continue
      }
      let previousDelta = previous.remaining - previous.ideal
      let nextDelta = sample.remaining - sample.ideal
      let fraction = previousDelta / (previousDelta - nextDelta)
      let crossing = WindowChartSample(
        id: "crossing-\(previous.id)-\(sample.id)",
        date: previous.date.addingTimeInterval(
          sample.date.timeIntervalSince(previous.date) * fraction
        ),
        remaining: previous.remaining + (sample.remaining - previous.remaining) * fraction,
        ideal: previous.ideal + (sample.ideal - previous.ideal) * fraction
      )
      current.append(crossing)
      result.append(
        PaceBandSegment(
          id: "\(window.id)-band-\(result.count)",
          isOverPace: isOver,
          samples: current
        ))
      isOver = sample.isOverPace
      current = [crossing, sample]
    }
    result.append(
      PaceBandSegment(
        id: "\(window.id)-band-\(result.count)",
        isOverPace: isOver,
        samples: current
      ))
    return result
  }

  private var predictionBand: [PredictionBandSample] {
    guard let prediction = evaluation?.exhaustionPrediction,
      prediction.hasRange,
      let earliest = prediction.earliest,
      let likely = prediction.likely,
      let latest = prediction.latest,
      earliest < windowEnd,
      freshness < windowEnd
    else { return [] }
    let dates = Set([freshness, min(earliest, windowEnd), min(likely, windowEnd), min(latest, windowEnd)])
    return dates.sorted().map { date in
      PredictionBandSample(
        date: date,
        lowerRemaining: projectedRemaining(at: date, exhaustion: earliest),
        upperRemaining: projectedRemaining(at: date, exhaustion: latest),
        likelyRemaining: projectedRemaining(at: date, exhaustion: likely)
      )
    }
  }

  private func projectedRemaining(at date: Date, exhaustion: Date) -> Double {
    let duration = exhaustion.timeIntervalSince(freshness)
    guard duration > 0 else { return 0 }
    let progress = date.timeIntervalSince(freshness) / duration
    return max(0, window.remainingPercent * (1 - progress))
  }

  var body: some View {
    VStack(spacing: 3) {
      Chart {
        zoomSelectionMarks()
        idealMarks()
        predictionMarks()
        actualMarks()
        hoverMarks()
      }
      .chartXScale(domain: visibleDomain)
      .chartYScale(domain: yDomain)
      .chartLegend(.hidden)
      .chartXAxis {
        switch window.kind {
        case .weekly:
          if visibleDomain.upperBound.timeIntervalSince(visibleDomain.lowerBound) <= 2 * 24 * 60 * 60 {
            AxisMarks(values: .stride(by: .hour, count: 3)) { value in
              AxisGridLine().foregroundStyle(Color.secondary.opacity(0.12))
              AxisValueLabel(format: .dateTime.hour(.defaultDigits(amPM: .abbreviated)), centered: true)
            }
          } else {
            AxisMarks(values: .stride(by: .day)) { value in
              AxisGridLine().foregroundStyle(Color.secondary.opacity(0.16))
              AxisValueLabel(format: .dateTime.weekday(.narrow), centered: true)
            }
          }
        case .fiveHour:
          AxisMarks(values: .stride(by: .hour, count: 1)) { value in
            AxisGridLine().foregroundStyle(Color.secondary.opacity(0.12))
            AxisValueLabel(format: .dateTime.hour(.defaultDigits(amPM: .abbreviated)), centered: true)
          }
        case .monthly, .other:
          AxisMarks(values: .automatic(desiredCount: 5)) { value in
            AxisGridLine().foregroundStyle(Color.secondary.opacity(0.12))
            AxisValueLabel(format: .dateTime.month(.abbreviated).day(), centered: true)
          }
        }
      }
      .chartYAxis {
        AxisMarks(values: [0, 50, 100]) {
          AxisGridLine()
          AxisValueLabel(anchor: .trailing)
        }
      }
      .chartOverlay { proxy in
        GeometryReader { geo in
          Rectangle()
            .fill(Color.clear)
            .contentShape(Rectangle())
            .onContinuousHover { phase in
              switch phase {
              case .active(let location):
                guard let plotFrame = proxy.plotFrame else { return }
                let xPosition = location.x - geo[plotFrame].origin.x
                guard let date: Date = proxy.value(atX: xPosition) else { return }
                hoveredDate = date
              case .ended:
                hoveredDate = nil
              }
            }
            .gesture(
              DragGesture(minimumDistance: 5)
                .onChanged { value in
                  guard let plotFrame = proxy.plotFrame else { return }
                  let frame = geo[plotFrame]
                  let startX = min(frame.width, max(0, value.startLocation.x - frame.minX))
                  let currentX = min(frame.width, max(0, value.location.x - frame.minX))
                  guard let start: Date = proxy.value(atX: startX),
                    let current: Date = proxy.value(atX: currentX)
                  else { return }
                  pendingZoom = min(start, current)...max(start, current)
                  hoveredDate = current
                }
                .onEnded { _ in
                  if let selection = pendingZoom,
                    selection.upperBound.timeIntervalSince(selection.lowerBound)
                      >= max(5 * 60, visibleDomain.upperBound.timeIntervalSince(visibleDomain.lowerBound) * 0.01)
                  {
                    zoomDomain = selection
                  }
                  pendingZoom = nil
                }
            )
        }
      }
      .accessibilityLabel("\(window.label) remaining usage chart")
      .accessibilityValue(accessibilityValue)
      .accessibilityChartDescriptor(self)
      .accessibilityElement(children: .ignore)

      HStack {
        Text(visibleDomain.lowerBound, format: .dateTime.month(.abbreviated).day().hour().minute())
          .accessibilityHidden(true)
        Spacer()
        if zoomDomain != nil {
          Button("Reset view", systemImage: "arrow.up.left.and.arrow.down.right") {
            zoomDomain = nil
          }
          .labelStyle(.titleAndIcon)
          .buttonStyle(.plain)
          .keyboardShortcut(.cancelAction)
          .foregroundStyle(.secondary)
          Spacer()
        }
        Text(visibleDomain.upperBound, format: .dateTime.month(.abbreviated).day().hour().minute())
          .accessibilityHidden(true)
      }
      .font(.caption2)
      .foregroundStyle(.tertiary)
    }
    .onChange(of: windowStart) {
      zoomDomain = nil
      pendingZoom = nil
    }
    .onChange(of: windowEnd) {
      zoomDomain = nil
      pendingZoom = nil
    }
  }

  @ChartContentBuilder
  private func zoomSelectionMarks() -> some ChartContent {
    if let pendingZoom {
      RectangleMark(
        xStart: .value("Zoom start", pendingZoom.lowerBound),
        xEnd: .value("Zoom end", pendingZoom.upperBound),
        yStart: .value("Zoom lower bound", yDomain.lowerBound),
        yEnd: .value("Zoom upper bound", yDomain.upperBound)
      )
      .foregroundStyle(.blue.opacity(0.12))
    }
  }

  @ChartContentBuilder
  private func idealMarks() -> some ChartContent {
    LineMark(
      x: .value("Time", visibleDomain.lowerBound),
      y: .value(
        "Ideal remaining percent",
        PaceCalculator.idealRemaining(
          at: visibleDomain.lowerBound,
          windowStart: windowStart,
          windowEnd: windowEnd
        ) ?? 100
      ),
      series: .value("Series", "Ideal")
    )
    .foregroundStyle(Color.secondary.opacity(0.55))
    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [5, 4]))

    LineMark(
      x: .value("Time", visibleDomain.upperBound),
      y: .value(
        "Ideal remaining percent",
        PaceCalculator.idealRemaining(
          at: visibleDomain.upperBound,
          windowStart: windowStart,
          windowEnd: windowEnd
        ) ?? 0
      ),
      series: .value("Series", "Ideal")
    )
    .foregroundStyle(Color.secondary.opacity(0.55))
    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
  }

  private func nearestSample(to date: Date) -> WindowChartSample? {
    samples.min {
      abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date))
    }
  }

  @ChartContentBuilder
  private func predictionMarks() -> some ChartContent {
    ForEach(predictionBand) { sample in
      AreaMark(
        x: .value("Prediction time", sample.date),
        yStart: .value("Fast estimate remaining percent", sample.lowerRemaining),
        yEnd: .value("Slow estimate remaining percent", sample.upperRemaining),
        series: .value("Prediction series", "Range")
      )
      .foregroundStyle(.blue.opacity(0.1))

      LineMark(
        x: .value("Prediction time", sample.date),
        y: .value("Likely remaining percent", sample.likelyRemaining),
        series: .value("Prediction series", "Likely")
      )
      .foregroundStyle(.blue.opacity(0.65))
      .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
    }
  }

  @ChartContentBuilder
  private func hoverMarks() -> some ChartContent {
    if let hoveredDate {
      RuleMark(x: .value("Time", hoveredDate))
        .foregroundStyle(Color.secondary.opacity(0.5))
        .lineStyle(StrokeStyle(lineWidth: 1))
        .annotation(
          position: .top,
          overflowResolution: .init(x: .fit(to: .chart), y: .disabled)
        ) {
          VStack(spacing: 1) {
            Text(hoveredDate, format: .dateTime.weekday(.abbreviated).hour().minute())
              .foregroundStyle(.secondary)
            if let remaining = hoverRemaining(at: hoveredDate) {
              Text("\(remaining.formatted(.number.precision(.fractionLength(0))))%")
                .bold()
            }
          }
          .font(.caption2)
          .padding(.horizontal, 6)
          .padding(.vertical, 3)
          .background {
            RoundedRectangle(cornerRadius: 6).fill(.regularMaterial)
          }
        }
    }
  }

  @ChartContentBuilder
  private func actualMarks() -> some ChartContent {
    ForEach(paceBandSegments) { segment in
      ForEach(segment.samples) { sample in
        AreaMark(
          x: .value("Time", sample.date),
          yStart: .value("Actual remaining percent", sample.remaining),
          yEnd: .value("Ideal remaining percent", sample.ideal),
          series: .value("Pace band", segment.id)
        )
        .foregroundStyle(
          paceTheme.fill(isOverPace: segment.isOverPace, opacity: 0.18)
        )
      }
    }

    ForEach(samples) { sample in
      LineMark(
        x: .value("Time", sample.date),
        y: .value("Actual remaining percent", sample.remaining),
        series: .value("Series", "Actual")
      )
      .foregroundStyle(Color.gray.opacity(0.9))
      .lineStyle(StrokeStyle(lineWidth: 2))
    }

    PointMark(
      x: .value("Current time", freshness),
      y: .value("Current remaining percent", window.remainingPercent)
    )
    .foregroundStyle(paceTheme.color(isOverPace: isOverPace))
    .symbolSize(30)
  }

  private func hoverRemaining(at date: Date) -> Double? {
    guard date > freshness else { return nearestSample(to: date)?.remaining }
    guard let likely = evaluation?.exhaustionPrediction?.likely else { return nil }
    return projectedRemaining(at: date, exhaustion: likely)
  }

  func makeChartDescriptor() -> AXChartDescriptor {
    let yRange = min(0, window.remainingPercent - 10)...max(100, window.remainingPercent + 10)
    let xAxis = AXNumericDataAxisDescriptor(
      title: "Time",
      range: visibleDomain.lowerBound.timeIntervalSince1970...visibleDomain.upperBound.timeIntervalSince1970,
      gridlinePositions: []
    ) { Date(timeIntervalSince1970: $0).formatted(date: .abbreviated, time: .shortened) }
    let yAxis = AXNumericDataAxisDescriptor(
      title: "Remaining percent",
      range: yRange,
      gridlinePositions: [0, 50, 100]
    ) { "\($0.formatted(.number.precision(.fractionLength(0)))) percent" }
    var series = [
      AXDataSeriesDescriptor(
        name: "Actual remaining",
        isContinuous: true,
        dataPoints: samples.map { .init(x: $0.date.timeIntervalSince1970, y: $0.remaining) }
      ),
      AXDataSeriesDescriptor(
        name: "Ideal remaining",
        isContinuous: true,
        dataPoints: [
          .init(
            x: visibleDomain.lowerBound.timeIntervalSince1970,
            y: PaceCalculator.idealRemaining(
              at: visibleDomain.lowerBound,
              windowStart: windowStart,
              windowEnd: windowEnd
            ) ?? 100
          ),
          .init(
            x: visibleDomain.upperBound.timeIntervalSince1970,
            y: PaceCalculator.idealRemaining(
              at: visibleDomain.upperBound,
              windowStart: windowStart,
              windowEnd: windowEnd
            ) ?? 0
          ),
        ]
      ),
    ]
    if !predictionBand.isEmpty {
      series.append(
        AXDataSeriesDescriptor(
          name: "Likely projection",
          isContinuous: true,
          dataPoints: predictionBand.map {
            .init(x: $0.date.timeIntervalSince1970, y: $0.likelyRemaining)
          }
        ))
    }
    return AXChartDescriptor(
      title: "\(window.label) usage pace",
      summary: accessibilityValue,
      xAxis: xAxis,
      yAxis: yAxis,
      additionalAxes: [],
      series: series
    )
  }

  private var accessibilityValue: String {
    let remaining = window.remainingPercent.formatted(.number.precision(.fractionLength(0)))
    var parts = ["\(remaining) percent remaining"]
    if let evaluation {
      parts.append(evaluation.label)
      if let prediction = evaluation.exhaustionPrediction {
        parts.append(
          prediction.confidence == .unstable
            ? "exhaustion estimate unstable"
            : "\(prediction.confidence.rawValue) confidence exhaustion estimate"
        )
      }
    }
    return parts.joined(separator: ", ")
  }
}

private struct TokenUsageRow: View {
  let window: UsageWindowSnapshot

  // Estimated window total, backed out from local tokens + the reported usage %.
  // Only shown when enough is consumed for the ratio to be meaningful.
  private var estimatedRemaining: Double? {
    guard let used = window.tokensUsed else { return nil }
    let usedFraction = (100 - window.remainingPercent) / 100
    guard usedFraction >= 0.05 else { return nil }
    let total = used / usedFraction
    let remaining = total - used
    return remaining > 0 ? remaining : nil
  }

  var body: some View {
    HStack(spacing: 4) {
      Image(systemName: "number")
      Text("\(Self.format(window.tokensUsed ?? 0)) tokens used")
      if let estimatedRemaining {
        Text("· ~\(Self.format(estimatedRemaining)) left (est.)")
          .foregroundStyle(.tertiary)
      }
      Spacer()
    }
    .font(.caption2)
    .foregroundStyle(.secondary)
    .accessibilityElement(children: .combine)
  }

  static func format(_ value: Double) -> String {
    switch value {
    case 1_000_000...:
      return "\((value / 1_000_000).formatted(.number.precision(.fractionLength(1))))M"
    case 1_000...:
      return "\((value / 1_000).formatted(.number.precision(.fractionLength(0))))K"
    default:
      return value.formatted(.number.precision(.fractionLength(0)))
    }
  }
}

private struct UnknownTimelineView: View {
  let window: UsageWindowSnapshot

  var body: some View {
    VStack(spacing: 8) {
      Text("\(window.remainingPercent.formatted(.number.precision(.fractionLength(0))))%")
        .font(.system(.largeTitle, design: .rounded, weight: .semibold))
      Label {
        if let windowEnd = window.windowEnd {
          Text("Resets \(windowEnd, format: .dateTime.month(.abbreviated).day().hour().minute())")
        } else {
          Text("Reset time unknown")
        }
      } icon: {
        Image(systemName: "calendar.badge.exclamationmark")
      }
      .font(.caption)
      .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, minHeight: 120)
  }
}

private struct PredictionBanner: View {
  enum Status {
    case exhausted
    case likely(earliest: Date, latest: Date)
    case possible
    case unstable
  }

  let status: Status
  @Environment(\.paceTheme) private var paceTheme

  var body: some View {
    Label {
      switch status {
      case .exhausted:
        Text("Quota exhausted")
      case .likely(let earliest, let latest):
        Text("Likely runs out \(Self.range(earliest, latest))")
      case .possible:
        Text("May run out before reset")
      case .unstable:
        Text("Estimate unstable")
      }
    } icon: {
      Image(systemName: isUrgent ? "exclamationmark.octagon.fill" : "waveform.path.ecg")
    }
    .font(.caption.weight(.semibold))
    .foregroundStyle(isUrgent ? paceTheme.overPace : Color.secondary)
    .padding(.horizontal, 8)
    .padding(.vertical, 5)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background {
      RoundedRectangle(cornerRadius: 7)
        .fill(
          isUrgent
            ? paceTheme.fill(isOverPace: true, opacity: 0.1)
            : Color.secondary.opacity(0.08)
        )
    }
  }

  private var isUrgent: Bool {
    switch status {
    case .exhausted, .likely, .possible: true
    case .unstable: false
    }
  }

  private static func range(_ earliest: Date, _ latest: Date) -> String {
    let calendar = Calendar.autoupdatingCurrent
    let relativeDay: String
    if calendar.isDateInToday(earliest) {
      relativeDay = ""
    } else if calendar.isDateInTomorrow(earliest) {
      relativeDay = "Tomorrow, "
    } else {
      relativeDay = earliest.formatted(.dateTime.weekday(.abbreviated)) + ", "
    }
    let first = earliest.formatted(date: .omitted, time: .shortened)
    let last = calendar.isDate(earliest, inSameDayAs: latest)
      ? latest.formatted(date: .omitted, time: .shortened)
      : latest.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    return "\(relativeDay)\(first)–\(last)"
  }
}

private struct UsageBreakdown: View {
  let items: [UsageBreakdownItem]

  var body: some View {
    VStack(spacing: 5) {
      ForEach(items) { item in
        HStack(spacing: 8) {
          Text(item.label)
            .lineLimit(1)
          ProgressView(value: item.usedPercent, total: 100)
            .tint(item.usedPercent > 80 ? .orange : .accentColor)
          Text("\(item.usedPercent.formatted(.number.precision(.fractionLength(0))))%")
            .monospacedDigit()
        }
        .font(.caption)
      }
    }
  }
}

#if DEBUG
  #Preview("Prediction range") {
    let window = PreviewFixtures.window(
      id: "prediction",
      label: "Weekly",
      kind: .weekly,
      remaining: 28,
      startOffset: -4 * 24 * 60 * 60,
      endOffset: 3 * 24 * 60 * 60
    )
    WindowPanel(
      providerID: .codex,
      pool: UsagePoolSnapshot(id: "default", name: "Default", windows: [window]),
      window: window,
      freshness: PreviewFixtures.now,
      history: [],
      evaluation: PaceEvaluation(
        idealRemaining: 43,
        delta: -15,
        exhaustionPrediction: ExhaustionPrediction(
          earliest: PreviewFixtures.now.addingTimeInterval(8 * 60 * 60),
          likely: PreviewFixtures.now.addingTimeInterval(14 * 60 * 60),
          latest: PreviewFixtures.now.addingTimeInterval(20 * 60 * 60),
          confidence: .medium
        )
      )
    )
    .frame(width: 550)
    .padding()
  }

  #Preview("Unknown reset") {
    let window = UsageWindowSnapshot(
      id: "unknown",
      kind: .weekly,
      label: "Weekly",
      windowStart: nil,
      windowEnd: nil,
      quotaTotal: 100,
      used: 38,
      remainingPercent: 62,
      resetSource: nil,
      breakdown: []
    )
    WindowPanel(
      providerID: .claudeCode,
      pool: UsagePoolSnapshot(id: "default", name: "Default", windows: [window]),
      window: window,
      freshness: PreviewFixtures.now,
      history: [],
      evaluation: nil
    )
    .frame(width: 550)
    .padding()
  }

  #Preview("Exhausted") {
    let window = PreviewFixtures.window(
      id: "exhausted",
      label: "5-hour",
      kind: .fiveHour,
      remaining: 0,
      startOffset: -4 * 60 * 60,
      endOffset: 60 * 60
    )
    WindowPanel(
      providerID: .codex,
      pool: UsagePoolSnapshot(id: "default", name: "Default", windows: [window]),
      window: window,
      freshness: PreviewFixtures.now,
      history: [],
      evaluation: PaceEvaluation(
        idealRemaining: 20,
        delta: -20,
        exhaustionPrediction: nil
      )
    )
    .frame(width: 550)
    .padding()
  }
#endif
