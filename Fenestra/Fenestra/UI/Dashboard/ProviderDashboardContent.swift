import SwiftUI

struct ProviderDashboardContent: View {
  let snapshot: UsageSnapshot
  let errorMessage: String?
  let store: FenestraStore
  let onContentHeightChange: (CGFloat) -> Void

  var body: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 12) {
        FreshnessLine(snapshot: snapshot)
        if let errorMessage {
          StaleDataBanner(message: errorMessage)
        }
        if snapshot.providerID == .antigravity {
          AntigravityPoolsView(snapshot: snapshot, store: store)
        } else {
          StandardPoolsView(snapshot: snapshot, store: store)
        }
        SnapshotDetails(snapshot: snapshot)
      }
      .padding(14)
      .onGeometryChange(for: CGFloat.self) { proxy in
        proxy.size.height
      } action: { height in
        onContentHeightChange(height)
      }
    }
    .scrollEdgeEffectStyle(.soft, for: .top)
  }
}

private struct FreshnessLine: View {
  let snapshot: UsageSnapshot

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack(spacing: 4) {
        Text("Updated")
        Text(snapshot.freshness, style: .relative)
        Text("·")
        Text("Source: \(snapshot.sourceDescription)")
      }
      if let plan = snapshot.planDescription, !plan.isEmpty {
        Text(plan)
          .lineLimit(2)
      }
    }
    .font(.caption)
    .foregroundStyle(.secondary)
    .accessibilityElement(children: .combine)
  }
}

private struct StaleDataBanner: View {
  let message: String

  var body: some View {
    Label(message, systemImage: "exclamationmark.triangle.fill")
      .font(.caption)
      .foregroundStyle(.orange)
      .padding(.horizontal, 10)
      .padding(.vertical, 6)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background {
        RoundedRectangle(cornerRadius: 8)
          .fill(.orange.opacity(0.1))
      }
  }
}

private struct StandardPoolsView: View {
  let snapshot: UsageSnapshot
  let store: FenestraStore

  var body: some View {
    if snapshot.pools.allSatisfy({ $0.windows.isEmpty }) {
      ContentUnavailableView {
        Label("No percentage quota", systemImage: "gauge.open.with.lines.needle.33percent")
      } description: {
        Text("This provider returned account or balance information without a quota percentage.")
      }
      .frame(maxWidth: .infinity)
      .padding(.vertical, 50)
    } else {
      ForEach(snapshot.pools) { pool in
        PoolColumn(snapshot: snapshot, pool: pool, store: store)
      }
    }
  }
}

private struct AntigravityPoolsView: View {
  let snapshot: UsageSnapshot
  let store: FenestraStore

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      ForEach(snapshot.pools) { pool in
        PoolColumn(snapshot: snapshot, pool: pool, store: store)
          .frame(maxWidth: .infinity, alignment: .top)
      }
    }
  }
}

private struct PoolColumn: View {
  let snapshot: UsageSnapshot
  let pool: UsagePoolSnapshot
  let store: FenestraStore

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      if snapshot.providerID == .antigravity {
        Text(pool.name)
          .font(.headline)
      }
      ForEach(pool.windows) { window in
        HistoricalWindowBrowser(
          providerID: snapshot.providerID,
          pool: pool,
          window: window,
          freshness: snapshot.freshness,
          currentHistory: store.historyPoints(
            providerID: snapshot.providerID,
            poolID: pool.id,
            windowID: window.id,
            since: window.windowStart
          ),
          evaluation: store.paceEvaluation(
            providerID: snapshot.providerID,
            pool: pool,
            window: window,
            at: snapshot.freshness
          ),
          historyStore: store.history
        )
      }
    }
  }
}

private struct SnapshotDetails: View {
  let snapshot: UsageSnapshot

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      if let cacheHitRate = snapshot.cacheHitRate {
        Label(
          "Cache \(cacheHitRate.formatted(.number.precision(.fractionLength(0))))%",
          systemImage: "memorychip"
        )
      }
      ForEach(snapshot.notes, id: \.self) { note in
        Text(note)
      }
    }
    .font(.caption)
    .foregroundStyle(.secondary)
  }
}
