import SwiftUI

struct ForecastEvidenceView: View {
  let prediction: ExhaustionPrediction
  let reset: Date?
  var showsStatus: Bool = true

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      if showsStatus {
      if prediction.hasRange, let earliest = prediction.earliest, let latest = prediction.latest {
        Text(statusText(earliest: earliest, latest: latest))
          .font(.caption.weight(.semibold))
      } else {
        Text("Estimate unstable")
          .font(.caption.weight(.semibold))
      }
      }
      if prediction.method != .recent {
        Text(evidenceText)
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
    }
    .accessibilityElement(children: .combine)
  }

  private var evidenceText: String {
    var parts = [
      prediction.method == .personalized ? "Pattern-adjusted" : "Learning your pattern",
      "\(prediction.evidenceCount) comparable windows",
    ]
    if let error = prediction.validationError {
      parts.append("typical error \(Duration.seconds(error).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated)))")
    }
    return parts.joined(separator: " · ")
  }

  private func statusText(earliest: Date, latest: Date) -> String {
    guard let reset, earliest < reset else { return "Expected to last until reset" }
    if let likely = prediction.likely, likely < reset {
      return "Likely runs out \(Self.range(earliest, latest))"
    }
    return "May run out before reset"
  }

  private static func range(_ earliest: Date, _ latest: Date) -> String {
    if latest.timeIntervalSince(earliest) >= 24 * 60 * 60 {
      return earliest.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        + "–" + latest.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }
    let calendar = Calendar.autoupdatingCurrent
    let prefix: String
    if calendar.isDateInToday(earliest) { prefix = "" }
    else if calendar.isDateInTomorrow(earliest) { prefix = "Tomorrow, " }
    else { prefix = earliest.formatted(.dateTime.weekday(.abbreviated)) + ", " }
    let first = earliest.formatted(date: .omitted, time: .shortened)
    let last = calendar.isDate(earliest, inSameDayAs: latest)
      ? latest.formatted(date: .omitted, time: .shortened)
      : latest.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    return "\(prefix)\(first)–\(last)"
  }
}

struct ResetTimelineView: View {
  let items: [ResetTimelineItem]
  let onContentHeightChange: (CGFloat) -> Void

  var body: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 16) {
        ForEach(groups, id: \.title) { group in
          Section(group.title) {
            ForEach(group.items) { item in
              HStack(spacing: 10) {
                Image(systemName: item.providerID.systemImage)
                  .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                  Text(item.providerID.displayName)
                  Text(item.poolName == "Default" ? item.windowName : "\(item.poolName) · \(item.windowName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Text(item.reset.map(Self.contextualDate) ?? "Unknown")
                  .font(.callout.monospacedDigit())
                  .foregroundStyle(.secondary)
              }
              .accessibilityElement(children: .combine)
            }
          }
        }
      }
      .padding(14)
      .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
        onContentHeightChange(height)
      }
    }
    .overlay {
      if items.isEmpty {
        ContentUnavailableView("No resets reported", systemImage: "calendar.badge.questionmark")
      }
    }
  }

  private var groups: [(title: String, items: [ResetTimelineItem])] {
    let calendar = Calendar.autoupdatingCurrent
    let definitions = ["Today", "Tomorrow", "Later", "Unknown"]
    let grouped = Dictionary(grouping: items) { item -> String in
      guard let reset = item.reset else { return "Unknown" }
      if calendar.isDateInToday(reset) { return "Today" }
      if calendar.isDateInTomorrow(reset) { return "Tomorrow" }
      return "Later"
    }
    return definitions.compactMap { title in
      guard let values = grouped[title], !values.isEmpty else { return nil }
      return (title, values)
    }
  }

  private static func contextualDate(_ date: Date) -> String {
    let calendar = Calendar.autoupdatingCurrent
    if calendar.isDateInToday(date) || calendar.isDateInTomorrow(date) {
      return date.formatted(date: .omitted, time: .shortened)
    }
    return date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
  }
}

struct ProviderHealthView: View {
  @Bindable var store: FenestraStore
  let onContentHeightChange: (CGFloat) -> Void
  @State private var confirmingNewProfile = false

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        if let summary = store.healthSummaries[store.selectedProvider] {
          HealthMetricGrid(summary: summary)
          if let regime = summary.activeRegime {
            GroupBox("Usage profile") {
              VStack(alignment: .leading, spacing: 5) {
                LabeledContent("Plan", value: regime.planName ?? "Unidentified plan")
                LabeledContent("Started", value: regime.startedAt.formatted(date: .abbreviated, time: .shortened))
                if regime.returningPlanNeedsValidation {
                  Label("Returning plan · revalidating", systemImage: "arrow.triangle.2.circlepath")
                    .foregroundStyle(.orange)
                }
                if store.history.profileChangeSuggestions.contains(store.selectedProvider) {
                  Label("Usage pattern changed. Start a new profile if your tier changed.", systemImage: "person.crop.circle.badge.questionmark")
                    .foregroundStyle(.orange)
                }
              }
              .font(.caption)
              .frame(maxWidth: .infinity, alignment: .leading)
            }
          }
          GroupBox("Anomalies") {
            if summary.activeAnomalies.isEmpty {
              Label("No active anomalies", systemImage: "checkmark.circle")
                .foregroundStyle(.secondary)
            } else {
              VStack(alignment: .leading, spacing: 8) {
                ForEach(summary.activeAnomalies) { anomaly in
                  Label {
                    VStack(alignment: .leading) {
                      Text(anomaly.kind.title).fontWeight(.semibold)
                      Text(anomaly.detail).foregroundStyle(.secondary)
                    }
                  } icon: {
                    Image(systemName: anomaly.alertable ? "exclamationmark.triangle.fill" : "waveform.path.ecg")
                  }
                }
              }
              .font(.caption)
            }
          }
        } else {
          ContentUnavailableView("Health is learning", systemImage: "heart.text.square")
        }

        Button("Start New Usage Profile", systemImage: "person.crop.circle.badge.plus") {
          confirmingNewProfile = true
        }
        .help("Use this after changing subscription tier or quota structure")
      }
      .padding(14)
      .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
        onContentHeightChange(height)
      }
    }
    .confirmationDialog(
      "Start a new usage profile?",
      isPresented: $confirmingNewProfile
    ) {
      Button("Start New Profile") {
        Task { await store.startNewUsageProfile() }
      }
    } message: {
      Text("Old history is kept, but it will not train forecasts for the new profile.")
    }
  }
}

private struct HealthMetricGrid: View {
  let summary: ProviderHealthSummary

  var body: some View {
    Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
      metric("Source", summary.source ?? "Unknown")
      metric("Last success", summary.lastSuccess?.formatted(date: .omitted, time: .shortened) ?? "None")
      metric("7-day success", summary.sevenDaySuccessRate.map { ($0 * 100).formatted(.number.precision(.fractionLength(0))) + "%" } ?? "Learning")
      metric("Median latency", summary.medianRefreshLatency.map { Duration.seconds($0).formatted(.units(width: .abbreviated)) } ?? "Learning")
      metric("Fallbacks", summary.fallbackCount.formatted())
      metric("Stale for", Duration.seconds(summary.staleDuration).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated)))
      metric("Reset accuracy", summary.resetAccuracy.map { Duration.seconds($0).formatted(.units(width: .abbreviated)) } ?? "Learning")
    }
    .font(.caption)
  }

  private func metric(_ title: String, _ value: String) -> some View {
    GridRow {
      Text(title).foregroundStyle(.secondary)
      Text(value).frame(maxWidth: .infinity, alignment: .trailing)
    }
  }
}

#if DEBUG
  #Preview("Timeline") {
    ResetTimelineView(
      items: [
        ResetTimelineItem(providerID: .codex, poolName: "Default", windowName: "5-hour", reset: .now.addingTimeInterval(3_600)),
        ResetTimelineItem(providerID: .claudeCode, poolName: "Default", windowName: "Weekly", reset: .now.addingTimeInterval(90_000)),
        ResetTimelineItem(providerID: .cursor, poolName: "Default", windowName: "Monthly", reset: nil),
      ],
      onContentHeightChange: { _ in }
    ).frame(width: 580, height: 400)
  }
#endif
