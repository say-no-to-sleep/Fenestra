import Charts
import SwiftUI

private struct HeatCell: Identifiable {
  var id: Date { date }
  let date: Date
  let week: Date
  let weekday: Int
  let amount: Double
}

struct ActivityHistoryView: View {
  let activity: [DailyActivity]
  let pace: [DailyPace]

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 22) {
        Text("90-day activity")
          .font(.headline)
        ActivityHeatmap(cells: heatCells)
          .frame(height: 180)

        Text("Worst daily pace")
          .font(.headline)
        PaceSparkline(points: pace)
          .frame(height: 190)
      }
      .padding(18)
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
        amount: values[day] ?? 0
      )
    }
  }
}

private struct ActivityHeatmap: View {
  let cells: [HeatCell]
  @Environment(\.paceTheme) private var paceTheme

  var body: some View {
    Chart(cells) { cell in
      RectangleMark(
        x: .value("Week", cell.week, unit: .weekOfYear),
        y: .value("Weekday", cell.weekday)
      )
      .foregroundStyle(activityColor(cell.amount))
      .cornerRadius(2)
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
    .accessibilityLabel("Daily usage activity heatmap")
  }

  private func activityColor(_ amount: Double) -> Color {
    guard amount > 0 else { return .secondary.opacity(0.12) }
    return paceTheme.underPace.opacity(min(0.9, 0.25 + amount / 40))
  }

  private func weekdayLabel(_ weekday: Int) -> String {
    let symbols = Calendar.autoupdatingCurrent.shortWeekdaySymbols
    guard symbols.indices.contains(weekday - 1) else { return "" }
    return symbols[weekday - 1]
  }
}

private struct PaceSparkline: View {
  let points: [DailyPace]
  @Environment(\.paceTheme) private var paceTheme

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
      }
      .chartYAxis {
        AxisMarks {
          AxisGridLine()
          AxisValueLabel()
        }
      }
      .accessibilityLabel("Worst daily pace delta")
    }
  }
}
