import Charts
import SwiftUI

struct HistoricalWindowBrowser: View {
  let providerID: ProviderID
  let pool: UsagePoolSnapshot
  let window: UsageWindowSnapshot
  let freshness: Date
  let currentHistory: [HistoryPoint]
  let evaluation: PaceEvaluation?
  let historyStore: HistoryStore
  var isStale: Bool = false

  @State private var completed: [HistoricalUsageWindow] = []
  @State private var position = 0
  @State private var compareWithCurrent = false
  @State private var includeOtherPlans = false

  var body: some View {
    VStack(spacing: 8) {
      HStack(spacing: 8) {
        Button("Older window", systemImage: "chevron.left") {
          position = min(completed.count, position + 1)
        }
        .labelStyle(.iconOnly)
        .disabled(position >= completed.count)
        Text(position == 0 ? "Current" : "Previous \(position)")
          .font(.caption.weight(.semibold))
          .frame(minWidth: 72)
        Button("Newer window", systemImage: "chevron.right") {
          position = max(0, position - 1)
        }
        .labelStyle(.iconOnly)
        .disabled(position == 0)
        Spacer()
        Menu("Plan history", systemImage: "line.3.horizontal.decrease.circle") {
          Toggle("Include other plans", isOn: $includeOtherPlans)
        }
        .labelStyle(.iconOnly)
        .help("Choose which usage profiles appear")
      }
      .controlSize(.mini)

      if let selected {
        if let latest = selected.samples.last {
          WindowPanel(
            providerID: providerID,
            pool: pool,
            window: selectedSnapshot(selected, remainingPercent: latest.remainingPercent),
            freshness: latest.timestamp,
            history: selected.samples,
            evaluation: nil,
            embedded: true
          )
          HistoricalWindowStats(window: selected)
          Toggle("Compare with Current", isOn: $compareWithCurrent)
            .toggleStyle(.switch)
            .controlSize(.mini)
            .frame(maxWidth: .infinity, alignment: .trailing)
          if compareWithCurrent {
            NormalizedComparisonChart(
              current: currentHistory,
              currentStart: window.windowStart,
              currentEnd: window.windowEnd,
              selected: selected
            )
            .frame(height: 150)
          }
        } else {
          HistoricalWindowEmptyView(label: window.label, window: selected)
        }
      } else {
        WindowPanel(
          providerID: providerID,
          pool: pool,
          window: window,
          freshness: freshness,
          history: currentHistory,
          evaluation: isStale ? nil : evaluation,
          embedded: true
        )
      }
    }
    .padding(12)
    .background { RoundedRectangle(cornerRadius: 12).fill(.quaternary.opacity(0.45)) }
    .task(
      id: "\(providerID.rawValue)|\(pool.id)|\(window.id)|\(includeOtherPlans)|\(activeRegimeID)"
    ) {
      completed = await historyStore.historicalWindows(
        providerID: providerID,
        poolID: pool.id,
        windowID: window.id,
        includeOtherRegimes: includeOtherPlans
      )
      position = min(position, completed.count)
    }
  }

  private var selected: HistoricalUsageWindow? {
    guard position > 0, completed.indices.contains(position - 1) else { return nil }
    return completed[position - 1]
  }

  private var activeRegimeID: String {
    historyStore.activeRegimes[providerID]?.id.uuidString ?? "none"
  }

  private func selectedSnapshot(_ historical: HistoricalUsageWindow, remainingPercent: Double) -> UsageWindowSnapshot {
    UsageWindowSnapshot(
      id: historical.windowID,
      kind: historical.kind,
      label: window.label,
      windowStart: historical.start,
      windowEnd: historical.end,
      quotaTotal: historical.quotaTotal,
      used: historical.totalPercentUsed,
      remainingPercent: remainingPercent,
      resetSource: "History",
      breakdown: []
    )
  }
}

struct HistoricalWindowEmptyView: View {
  let label: String
  let window: HistoricalUsageWindow

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(label)
        .font(.headline)
      ContentUnavailableView(
        "No recorded usage data",
        systemImage: "chart.xyaxis.line",
        description: Text("No usage samples are available for this window.")
      )
      .frame(maxWidth: .infinity, minHeight: 177)
      Text("\(window.start.formatted(date: .abbreviated, time: .shortened)) – \(window.end.formatted(date: .abbreviated, time: .shortened))")
        .font(.caption)
        .foregroundStyle(.secondary)
      LabeledContent("Plan", value: window.planName ?? "Unidentified")
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
  }
}

private struct HistoricalWindowStats: View {
  let window: HistoricalUsageWindow

  var body: some View {
    Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 3) {
      GridRow {
        stat("Used", "\(window.totalPercentUsed.formatted(.number.precision(.fractionLength(1)))) points")
        stat("Peak burn", "\(window.peakBurnPerHour.formatted(.number.precision(.fractionLength(1)))) points/hr")
      }
      GridRow {
        stat("Result", window.outcomeLabel)
        stat("Coverage", "\((window.observationCoverage * 100).formatted(.number.precision(.fractionLength(0))))%")
      }
      GridRow {
        stat("Plan", window.planName ?? "Unidentified")
        stat("Ended", window.end.formatted(date: .abbreviated, time: .shortened))
      }
    }
    .font(.caption2)
    .foregroundStyle(.secondary)
  }

  private func stat(_ title: String, _ value: String) -> some View {
    LabeledContent(title, value: value)
  }
}

private struct NormalizedComparisonChart: View, AXChartDescriptorRepresentable {
  struct Sample: Identifiable {
    let id: String
    let progress: Double
    let remaining: Double
    let series: String
  }

  let current: [HistoryPoint]
  let currentStart: Date?
  let currentEnd: Date?
  let selected: HistoricalUsageWindow

  private var samples: [Sample] {
    normalize(current, start: currentStart, end: currentEnd, series: "Current")
      + normalize(selected.samples, start: selected.start, end: selected.end, series: "Selected")
  }

  var body: some View {
    Chart(samples) { sample in
      LineMark(
        x: .value("Window elapsed percent", sample.progress),
        y: .value("Remaining percent", sample.remaining),
        series: .value("Window", sample.series)
      )
      .foregroundStyle(by: .value("Window", sample.series))
      .lineStyle(sample.series == "Current" ? StrokeStyle(lineWidth: 2.5) : StrokeStyle(lineWidth: 2, dash: [5, 3]))
    }
    .chartXScale(domain: 0...100)
    .chartYScale(domain: 0...100)
    .chartXAxisLabel("Window elapsed")
    .chartYAxisLabel("Remaining %")
    .accessibilityChartDescriptor(self)
    .accessibilityElement(children: .ignore)
  }

  func makeChartDescriptor() -> AXChartDescriptor {
    let xAxis = AXNumericDataAxisDescriptor(
      title: "Window elapsed percent",
      range: 0...100,
      gridlinePositions: [0, 25, 50, 75, 100]
    ) { "\($0.formatted(.number.precision(.fractionLength(0)))) percent" }
    let yAxis = AXNumericDataAxisDescriptor(
      title: "Remaining percent",
      range: 0...100,
      gridlinePositions: [0, 50, 100]
    ) { "\($0.formatted(.number.precision(.fractionLength(0)))) percent" }
    let series = ["Current", "Selected"].map { name in
      AXDataSeriesDescriptor(
        name: name,
        isContinuous: true,
        dataPoints: samples.filter { $0.series == name }.map { .init(x: $0.progress, y: $0.remaining) }
      )
    }
    return AXChartDescriptor(
      title: "Current and selected usage windows",
      summary: "Usage curves normalized to the same elapsed-window scale",
      xAxis: xAxis,
      yAxis: yAxis,
      additionalAxes: [],
      series: series
    )
  }

  private func normalize(
    _ points: [HistoryPoint],
    start: Date?,
    end: Date?,
    series: String
  ) -> [Sample] {
    guard let start, let end, end > start else { return [] }
    let duration = end.timeIntervalSince(start)
    return points.map {
      Sample(
        id: "\(series)-\($0.id)",
        progress: min(100, max(0, $0.timestamp.timeIntervalSince(start) / duration * 100)),
        remaining: $0.remainingPercent,
        series: series
      )
    }
  }
}
