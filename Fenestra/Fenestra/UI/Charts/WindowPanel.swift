import Charts
import SwiftUI

private struct WindowChartSample: Identifiable {
  let id: String
  let date: Date
  let remaining: Double
  let ideal: Double

  var isOverPace: Bool { remaining < ideal }
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
      if window.remainingPercent <= 0 {
        ExhaustionBanner(date: nil)
      } else if let exhaustion = evaluation?.projectedExhaustion,
        let reset = window.windowEnd,
        exhaustion < reset
      {
        ExhaustionBanner(date: exhaustion)
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
}

private struct WindowPanelHeader: View {
  let window: UsageWindowSnapshot
  let evaluation: PaceEvaluation?
  @Environment(\.paceTheme) private var paceTheme

  var body: some View {
    HStack(alignment: .firstTextBaseline) {
      Text(window.label)
        .font(.headline)
      Spacer()
      if let evaluation {
        Text(evaluation.label)
          .font(.callout.weight(.semibold))
          .foregroundStyle(paceTheme.color(isOverPace: evaluation.isOverPace))
      } else {
        Text("\(window.remainingPercent.formatted(.number.precision(.fractionLength(0))))% left")
          .font(.callout.weight(.semibold))
      }
    }
  }
}

private struct WindowPaceChart: View {
  let window: UsageWindowSnapshot
  let windowStart: Date
  let windowEnd: Date
  let freshness: Date
  let history: [HistoryPoint]
  let evaluation: PaceEvaluation?
  @Environment(\.paceTheme) private var paceTheme

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

  var body: some View {
    VStack(spacing: 3) {
      Chart {
        idealMarks()
        actualMarks()
      }
      .chartXScale(domain: windowStart...windowEnd)
      .chartYScale(
        domain: min(0, window.remainingPercent - 10)...max(100, window.remainingPercent + 10)
      )
      .chartLegend(.hidden)
      .chartXAxis(.hidden)
      .chartYAxis {
        AxisMarks(values: [0, 50, 100]) {
          AxisGridLine()
          AxisValueLabel(anchor: .trailing)
        }
      }
      .accessibilityLabel("\(window.label) remaining usage chart")
      .accessibilityValue(accessibilityValue)

      HStack {
        if window.kind == .fiveHour {
          Text(windowStart, format: .dateTime.hour().minute())
          Spacer()
          Text(windowEnd, format: .dateTime.hour().minute())
        } else {
          Text(windowStart, format: .dateTime.month(.abbreviated).day())
          Spacer()
          Text(windowEnd, format: .dateTime.month(.abbreviated).day())
        }
      }
      .font(.caption2)
      .foregroundStyle(.secondary)
      .accessibilityHidden(true)
    }
  }

  @ChartContentBuilder
  private func idealMarks() -> some ChartContent {
    LineMark(
      x: .value("Time", windowStart),
      y: .value("Ideal remaining percent", 100),
      series: .value("Series", "Ideal")
    )
    .foregroundStyle(paceTheme.overPace.opacity(0.65))
    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [5, 4]))

    LineMark(
      x: .value("Time", windowEnd),
      y: .value("Ideal remaining percent", 0),
      series: .value("Series", "Ideal")
    )
    .foregroundStyle(paceTheme.overPace.opacity(0.65))
    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
  }

  @ChartContentBuilder
  private func actualMarks() -> some ChartContent {
    ForEach(samples.filter(\.isOverPace)) { sample in
      AreaMark(
        x: .value("Time", sample.date),
        yStart: .value("Actual remaining percent", sample.remaining),
        yEnd: .value("Ideal remaining percent", sample.ideal),
        series: .value("Pace band", "Over")
      )
      .foregroundStyle(paceTheme.fill(isOverPace: true, opacity: 0.18))
    }

    ForEach(samples.filter { !$0.isOverPace }) { sample in
      AreaMark(
        x: .value("Time", sample.date),
        yStart: .value("Actual remaining percent", sample.remaining),
        yEnd: .value("Ideal remaining percent", sample.ideal),
        series: .value("Pace band", "Under")
      )
      .foregroundStyle(paceTheme.fill(isOverPace: false, opacity: 0.18))
    }

    ForEach(samples) { sample in
      LineMark(
        x: .value("Time", sample.date),
        y: .value("Actual remaining percent", sample.remaining),
        series: .value("Series", "Actual")
      )
      .foregroundStyle(paceTheme.color(isOverPace: isOverPace))
      .lineStyle(StrokeStyle(lineWidth: 2))
    }

    PointMark(
      x: .value("Current time", freshness),
      y: .value("Current remaining percent", window.remainingPercent)
    )
    .foregroundStyle(paceTheme.color(isOverPace: isOverPace))
    .symbolSize(30)
    .annotation(position: .top, spacing: 4) {
      Text("\(window.remainingPercent.formatted(.number.precision(.fractionLength(0))))%")
        .font(.caption2.bold())
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background {
          Capsule().fill(.regularMaterial)
        }
    }
  }

  private var accessibilityValue: String {
    let remaining = window.remainingPercent.formatted(.number.precision(.fractionLength(0)))
    if let evaluation {
      return "\(remaining) percent remaining, \(evaluation.label)"
    }
    return "\(remaining) percent remaining"
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

private struct ExhaustionBanner: View {
  let date: Date?
  @Environment(\.paceTheme) private var paceTheme

  var body: some View {
    Label {
      if let date {
        Text("Runs out \(date, format: .dateTime.hour().minute())")
      } else {
        Text("Quota exhausted")
      }
    } icon: {
      Image(systemName: "exclamationmark.octagon.fill")
    }
    .font(.caption.weight(.semibold))
    .foregroundStyle(paceTheme.overPace)
    .padding(.horizontal, 8)
    .padding(.vertical, 5)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background {
      RoundedRectangle(cornerRadius: 7).fill(paceTheme.fill(isOverPace: true, opacity: 0.1))
    }
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
