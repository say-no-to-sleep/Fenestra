import Charts
import SwiftUI

private struct HeatCell: Identifiable {
  var id: Date { date }
  let date: Date
  let week: Date
  let weekday: Int
  let amount: Double?
}

struct ProviderHistoryView: View {
  let store: FenestraStore
  let onContentHeightChange: (CGFloat) -> Void
  @State private var selection = ""

  private var choices: [(pool: UsagePoolSnapshot, window: UsageWindowSnapshot)] {
    (store.state(for: store.selectedProvider).snapshot?.pools ?? []).flatMap { pool in
      pool.windows.map { (pool, $0) }
    }
  }

  private var selected: (pool: UsagePoolSnapshot, window: UsageWindowSnapshot)? {
    choices.first { "\($0.pool.id)|\($0.window.id)" == selection }
      ?? choices.min { FenestraStore.menuWindowRank($0.window) < FenestraStore.menuWindowRank($1.window) }
  }

  var body: some View {
    if let selected {
      VStack(spacing: 0) {
        Picker("Quota", selection: Binding(
          get: { "\(selected.pool.id)|\(selected.window.id)" }, set: { selection = $0 }
        )) {
          ForEach(store.state(for: store.selectedProvider).snapshot?.pools ?? []) { pool in
            ForEach(pool.windows) { window in
              Text(pool.name == "Default" ? window.label : "\(pool.name) · \(window.label)")
                .tag("\(pool.id)|\(window.id)")
            }
          }
        }
        .padding(.horizontal, 18)
        .padding(.top, 12)
        ActivityHistoryView(
          activity: store.history.dailyActivity(providerID: store.selectedProvider,
                                                poolID: selected.pool.id, windowID: selected.window.id),
          pace: store.history.dailyWorstPace(providerID: store.selectedProvider,
                                            poolID: selected.pool.id, windowID: selected.window.id),
          onContentHeightChange: { onContentHeightChange($0 + 45) }
        )
      }
    } else {
      ContentUnavailableView("No quota history", systemImage: "clock",
                             description: Text("Connect a provider to begin recording usage."))
    }
  }
}

struct ActivityHistoryView: View {
  let activity: [DailyActivity]
  let pace: [DailyPace]
  var onContentHeightChange: (CGFloat) -> Void = { _ in }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 22) {
        HStack {
          Text("90-day observed quota use")
          Spacer()
          ActivityScale()
            .accessibilityHidden(true)
        }
          .font(.headline)
        ActivityHeatmap(cells: heatCells)
          .frame(height: 180)

        Text("Each day shows observed percentage points used for this quota. Unobserved periods are not estimated.")
          .font(.caption)
          .foregroundStyle(.secondary)
        Text("Worst daily pace")
          .font(.headline)
        PaceSparkline(points: pace)
          .frame(height: 190)
      }
      .padding(18)
      .onGeometryChange(for: CGFloat.self) { proxy in
        proxy.size.height
      } action: { height in
        onContentHeightChange(height)
      }
    }
    .scrollEdgeEffectStyle(.soft, for: .top)
  }

  private var heatCells: [HeatCell] {
    let calendar = Calendar.autoupdatingCurrent
    let values = Dictionary(
      uniqueKeysWithValues: activity.map {
        (calendar.startOfDay(for: $0.date), $0.amount)
      })
    return (0..<90).compactMap { offset in
      guard let date = calendar.date(byAdding: .day, value: -offset, to: Date()) else {
        return nil
      }
      let day = calendar.startOfDay(for: date)
      let weekday = calendar.component(.weekday, from: day)
      let week = calendar.dateInterval(of: .weekOfYear, for: day)?.start ?? day
      return HeatCell(
        date: day,
        week: week,
        weekday: weekday,
        amount: values[day]
      )
    }
  }
}

private struct ActivityHeatmap: View, AXChartDescriptorRepresentable {
  let cells: [HeatCell]
  @Environment(\.paceTheme) private var paceTheme
  @State private var hoveredCell: HeatCell?

  var body: some View {
    Chart(cells) { cell in
      RectangleMark(
        x: .value("Week", cell.week, unit: .weekOfYear),
        y: .value("Weekday", cell.weekday),
        width: .fixed(11),
        height: .fixed(11)
      )
      .foregroundStyle(activityColor(cell.amount))
      .cornerRadius(2)
      if hoveredCell?.id == cell.id {
        RectangleMark(
          x: .value("Selected week", cell.week, unit: .weekOfYear),
          y: .value("Selected weekday", cell.weekday),
          width: .fixed(11),
          height: .fixed(11)
        )
        .foregroundStyle(Color.clear)
        .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
          VStack(spacing: 1) {
            Text(cell.date, format: .dateTime.month(.abbreviated).day())
              .foregroundStyle(.secondary)
            Text(cell.amount.map { "\($0.formatted(.number.precision(.fractionLength(0)))) pp observed" } ?? "No data")
              .bold()
          }
          .font(.caption2)
          .padding(.horizontal, 6)
          .padding(.vertical, 3)
          .background { RoundedRectangle(cornerRadius: 6).fill(.regularMaterial) }
        }
      }
    }
    .chartYAxis {
      AxisMarks(values: [2, 4, 6]) { value in
        AxisValueLabel {
          if let day = value.as(Int.self) {
            Text(weekdayLabel(day))
          }
        }
      }
    }
    .chartXAxis {
      AxisMarks(values: .stride(by: .month)) {
        AxisValueLabel(format: .dateTime.month(.abbreviated))
      }
    }
    .chartLegend(.hidden)
    .chartOverlay { proxy in
      GeometryReader { geometry in
        Rectangle().fill(.clear).contentShape(.rect)
          .onContinuousHover { phase in
            switch phase {
            case .active(let location):
              guard let plotFrame = proxy.plotFrame else { return }
              let point = CGPoint(
                x: location.x - geometry[plotFrame].origin.x,
                y: location.y - geometry[plotFrame].origin.y
              )
              guard let date: Date = proxy.value(atX: point.x),
                let weekday: Int = proxy.value(atY: point.y)
              else { return }
              hoveredCell = cells.min {
                let lhs = abs($0.week.timeIntervalSince(date)) + Double(abs($0.weekday - weekday))
                let rhs = abs($1.week.timeIntervalSince(date)) + Double(abs($1.weekday - weekday))
                return lhs < rhs
              }
            case .ended:
              hoveredCell = nil
            }
          }
      }
    }
    .accessibilityLabel("Daily usage activity heatmap")
    .accessibilityChartDescriptor(self)
    .accessibilityElement(children: .ignore)
  }

  private func activityColor(_ amount: Double?) -> Color {
    guard let amount else { return .secondary.opacity(0.04) }
    guard amount > 0 else { return .secondary.opacity(0.20) }
    return paceTheme.underPace.opacity(min(0.9, 0.25 + amount / 40))
  }

  private func weekdayLabel(_ weekday: Int) -> String {
    let symbols = Calendar.autoupdatingCurrent.shortWeekdaySymbols
    guard symbols.indices.contains(weekday - 1) else { return "" }
    return symbols[weekday - 1]
  }

  func makeChartDescriptor() -> AXChartDescriptor {
    let sorted = cells.sorted { $0.date < $1.date }
    let first = sorted.first?.date ?? Date()
    let last = sorted.last?.date ?? first
    let maximum = max(1, sorted.compactMap(\.amount).max() ?? 1)
    return AXChartDescriptor(
      title: "90-day quota activity",
      summary: "Daily quota percentage points used",
      xAxis: AXNumericDataAxisDescriptor(
        title: "Date",
        range: first.timeIntervalSince1970...last.timeIntervalSince1970,
        gridlinePositions: []
      ) { Date(timeIntervalSince1970: $0).formatted(date: .abbreviated, time: .omitted) },
      yAxis: AXNumericDataAxisDescriptor(
        title: "Quota used", range: 0...maximum, gridlinePositions: []
      ) { "\($0.formatted(.number.precision(.fractionLength(0)))) percentage points" },
      additionalAxes: [],
      series: [
        AXDataSeriesDescriptor(
          name: "Quota used",
          isContinuous: false,
          dataPoints: sorted.compactMap { cell in
            cell.amount.map { .init(x: cell.date.timeIntervalSince1970, y: $0) }
          }
        )
      ]
    )
  }
}

private struct ActivityScale: View {
  @Environment(\.paceTheme) private var paceTheme

  var body: some View {
    HStack(spacing: 3) {
      Rectangle().fill(.secondary.opacity(0.04)).frame(width: 8, height: 8)
      Text("No data").padding(.trailing, 8)
      Text("Less")
      ForEach(0..<4, id: \.self) { index in
        RoundedRectangle(cornerRadius: 1)
          .fill(paceTheme.underPace.opacity(0.25 + Double(index) * 0.2))
          .frame(width: 8, height: 8)
      }
      Text("More")
    }
    .font(.caption2)
    .foregroundStyle(.secondary)
    .accessibilityLabel("Activity scale, less to more quota used")
  }
}

private struct PaceSparkline: View, AXChartDescriptorRepresentable {
  let points: [DailyPace]
  @Environment(\.paceTheme) private var paceTheme
  @State private var hoveredPoint: DailyPace?

  var body: some View {
    if points.isEmpty {
      ContentUnavailableView(
        "No pace history",
        systemImage: "chart.xyaxis.line"
      )
    } else {
      Chart(points) { point in
        AreaMark(
          x: .value("Date", point.date),
          yStart: .value("Pace delta", point.delta),
          yEnd: .value("Neutral", 0)
        )
        .foregroundStyle(paceTheme.fill(delta: point.delta, opacity: 0.15))

        LineMark(
          x: .value("Date", point.date),
          y: .value("Pace delta", point.delta)
        )
        .foregroundStyle(paceTheme.color(delta: point.delta))

        PointMark(
          x: .value("Date", point.date),
          y: .value("Pace delta", point.delta)
        )
        .foregroundStyle(paceTheme.color(delta: point.delta))
        .symbolSize(24)

        if hoveredPoint?.date == point.date {
          RuleMark(x: .value("Selected date", point.date))
            .foregroundStyle(.secondary.opacity(0.5))
            .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
              VStack(spacing: 1) {
                Text(point.date, format: .dateTime.month(.abbreviated).day())
                  .foregroundStyle(.secondary)
                Text("\(point.delta.formatted(.number.precision(.fractionLength(0)))) pp pace")
                  .bold()
              }
              .font(.caption2)
              .padding(.horizontal, 6)
              .padding(.vertical, 3)
              .background { RoundedRectangle(cornerRadius: 6).fill(.regularMaterial) }
            }
        }

        RuleMark(y: .value("Even pace", 0))
          .foregroundStyle(.secondary.opacity(0.5))
      }
      .chartYAxis {
        AxisMarks { value in
          AxisGridLine()
          AxisValueLabel {
            if let delta = value.as(Double.self) { Text("\(delta.formatted()) pp") }
          }
        }
      }
      .chartOverlay { proxy in
        GeometryReader { geometry in
          Rectangle().fill(.clear).contentShape(.rect)
            .onContinuousHover { phase in
              switch phase {
              case .active(let location):
                guard let plotFrame = proxy.plotFrame else { return }
                let x = location.x - geometry[plotFrame].origin.x
                guard let date: Date = proxy.value(atX: x) else { return }
                hoveredPoint = points.min {
                  abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date))
                }
              case .ended:
                hoveredPoint = nil
              }
            }
        }
      }
      .accessibilityLabel("Worst daily pace delta")
      .accessibilityChartDescriptor(self)
      .accessibilityElement(children: .ignore)
    }
  }

  func makeChartDescriptor() -> AXChartDescriptor {
    let sorted = points.sorted { $0.date < $1.date }
    let first = sorted.first?.date ?? Date()
    let last = sorted.last?.date ?? first
    let minimum = min(-1, sorted.map(\.delta).min() ?? -1)
    let maximum = max(1, sorted.map(\.delta).max() ?? 1)
    return AXChartDescriptor(
      title: "Worst daily pace",
      summary: "Daily pace delta in percentage points",
      xAxis: AXNumericDataAxisDescriptor(
        title: "Date",
        range: first.timeIntervalSince1970...last.timeIntervalSince1970,
        gridlinePositions: []
      ) { Date(timeIntervalSince1970: $0).formatted(date: .abbreviated, time: .omitted) },
      yAxis: AXNumericDataAxisDescriptor(
        title: "Pace delta", range: minimum...maximum, gridlinePositions: [0]
      ) { "\($0.formatted(.number.precision(.fractionLength(0)))) percentage points" },
      additionalAxes: [],
      series: [
        AXDataSeriesDescriptor(
          name: "Worst pace",
          isContinuous: true,
          dataPoints: sorted.map { .init(x: $0.date.timeIntervalSince1970, y: $0.delta) }
        )
      ]
    )
  }
}

#if DEBUG
  #Preview("History") {
    ActivityHistoryView(activity: PreviewFixtures.history, pace: PreviewFixtures.pace)
      .frame(width: 580, height: 520)
  }
#endif
