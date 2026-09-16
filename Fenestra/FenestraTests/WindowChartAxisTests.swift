import SwiftUI
import Testing

@testable import Fenestra

@Suite("Window chart axes")
struct WindowChartAxisTests {
  @Test @MainActor
  func mostlyVerticalDragsPreserveTimeRange() {
    #expect(WindowPaceChart.isVerticalDrag(width: 0, height: 50))
    #expect(WindowPaceChart.isVerticalDrag(width: -12, height: -50))
    #expect(!WindowPaceChart.isVerticalDrag(width: 50, height: 50))
    #expect(!WindowPaceChart.isVerticalDrag(width: 50, height: 3))
    #expect(!WindowPaceChart.isVerticalDrag(width: 0, height: 3))
  }

  @Test @MainActor
  func quotaLabelsFollowTheirPointsAndStayInsidePlot() {
    let over = WindowPaceChart.quotaLabelPositions(actualY: 40, idealY: 20, bounds: 0...150)
    #expect(over.ideal < over.pace && over.pace < over.actual)
    let under = WindowPaceChart.quotaLabelPositions(actualY: 30, idealY: 130, bounds: 0...150)
    #expect(under.actual == 30 && under.ideal == 130 && under.pace == 80)
    let edge = WindowPaceChart.quotaLabelPositions(actualY: 0, idealY: 0, bounds: 0...150)
    #expect(edge.actual >= 9 && edge.ideal <= 141)
    #expect(edge.ideal - edge.actual >= 40)
  }

  @Test @MainActor
  func boxZoomNormalizesVerticalBoundsAndPreservesHorizontalDrags() {
    #expect(WindowPaceChart.quotaSelection(from: 80, to: 60, dragHeight: 40) == 60...80)
    #expect(WindowPaceChart.quotaSelection(from: 60, to: 80, dragHeight: -40) == 60...80)
    #expect(WindowPaceChart.quotaSelection(from: 80, to: 79, dragHeight: 3) == nil)
    #expect(WindowPaceChart.quotaSelection(from: 60, to: 60, dragHeight: 40) == nil)
    #expect(WindowPaceChart.quotaSelection(from: .nan, to: 60, dragHeight: 40) == nil)
    #expect(WindowPaceChart.quotaSelection(from: 80, to: .infinity, dragHeight: 40) == nil)
  }

  @Test @MainActor
  func hourlyTicksIncludeStartAndResetAcrossMidnight() throws {
    let start = try #require(ISO8601DateFormatter().date(from: "2026-09-08T00:08:00Z"))
    let end = start.addingTimeInterval(5 * 60 * 60)
    let ticks = WindowPaceChart.hourlyTicks(in: start...end)
    #expect(ticks.count == 6)
    #expect(ticks.first == start)
    #expect(ticks.last == end)
    #expect(zip(ticks, ticks.dropFirst()).allSatisfy { $1.timeIntervalSince($0) == 3600 })
    let zoomEnd = start.addingTimeInterval(90 * 60)
    #expect(WindowPaceChart.hourlyTicks(in: start...zoomEnd) == [start, start.addingTimeInterval(3600)])

    let panels = VStack(spacing: 12) {
      panel(kind: .weekly, start: start, duration: 7 * 24 * 60 * 60)
      panel(kind: .fiveHour, start: start, duration: 5 * 60 * 60)
    }
    .padding(12)
    .frame(width: 550)
    .environment(\.locale, Locale(identifier: "en_US"))
    .environment(\.timeZone, try #require(TimeZone(identifier: "America/Toronto")))
    .background(.white)
    let renderer = ImageRenderer(content: panels)
    renderer.scale = 2
    let image = try #require(renderer.nsImage)
    let data = try #require(image.tiffRepresentation)
    let bitmap = try #require(NSBitmapImageRep(data: data))
    let png = try #require(bitmap.representation(using: .png, properties: [:]))
    try png.write(to: URL(fileURLWithPath: "/tmp/fenestra-chart-axes.png"))
  }

  @Test @MainActor
  func hoverTimeRendersAbovePlotWithoutChangingLayout() throws {
    let date = try #require(ISO8601DateFormatter().date(from: "2026-09-14T14:30:00Z"))
    let hidden = ImageRenderer(content: ChartHoverLabel(date: nil).frame(width: 500))
    let visible = ImageRenderer(content: ChartHoverLabel(date: date).frame(width: 500))
    #expect(try #require(hidden.nsImage).size == #require(visible.nsImage).size)
    let content = VStack(spacing: 6) {
      ChartHoverLabel(date: date)
      panel(kind: .weekly, start: date, duration: 7 * 24 * 60 * 60)
    }
    .frame(width: 500)
    .padding(12)
    .environment(\.locale, Locale(identifier: "en_US"))
    .environment(\.timeZone, try #require(TimeZone(identifier: "America/Toronto")))
    .environment(\.colorScheme, .dark)
    .background(.black)
    let renderer = ImageRenderer(content: content)
    renderer.scale = 2
    let image = try #require(renderer.nsImage)
    let data = try #require(image.tiffRepresentation)
    let bitmap = try #require(NSBitmapImageRep(data: data))
    let png = try #require(bitmap.representation(using: .png, properties: [:]))
    try png.write(to: URL(fileURLWithPath: "/tmp/fenestra-hover-labels.png"))
  }

  @MainActor
  private func panel(kind: UsageWindowKind, start: Date, duration: TimeInterval) -> some View {
    let window = UsageWindowSnapshot(
      id: "axis-test", kind: kind, label: kind.panelLabel,
      windowStart: start, windowEnd: start.addingTimeInterval(duration),
      quotaTotal: 100, used: 0, remainingPercent: 100, resetSource: nil, breakdown: []
    )
    return WindowPanel(
      providerID: .codex,
      pool: UsagePoolSnapshot(id: "default", name: "Default", windows: [window]),
      window: window, freshness: start, history: [], evaluation: nil
    )
  }
}
