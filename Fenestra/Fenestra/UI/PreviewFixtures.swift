#if DEBUG
  import Foundation

  enum PreviewFixtures {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    static func window(
      id: String,
      label: String,
      kind: UsageWindowKind,
      remaining: Double,
      startOffset: TimeInterval,
      endOffset: TimeInterval,
      breakdown: [UsageBreakdownItem] = []
    ) -> UsageWindowSnapshot {
      UsageWindowSnapshot(
        id: id,
        kind: kind,
        label: label,
        windowStart: now.addingTimeInterval(startOffset),
        windowEnd: now.addingTimeInterval(endOffset),
        quotaTotal: 100,
        used: 100 - remaining,
        remainingPercent: remaining,
        resetSource: "Preview",
        breakdown: breakdown
      )
    }

    static let codex = UsageSnapshot(
      providerID: .codex,
      displayName: "Codex",
      pools: [
        UsagePoolSnapshot(
          id: "default",
          name: "Default",
          windows: [
            window(
              id: "codex-weekly",
              label: "Weekly",
              kind: .weekly,
              remaining: 42,
              startOffset: -4 * 24 * 60 * 60,
              endOffset: 3 * 24 * 60 * 60
            )
          ]
        )
      ],
      freshness: now,
      sourceDescription: "OAuth usage API with a deliberately long source description",
      cacheHitRate: nil,
      accountDescription: "private@example.com",
      planDescription: "Plus",
      notes: []
    )

    static let cursor = UsageSnapshot(
      providerID: .cursor,
      displayName: "Cursor",
      pools: [
        UsagePoolSnapshot(
          id: "included",
          name: "Included",
          windows: [
            window(
              id: "cursor-monthly-v2",
              label: "Monthly",
              kind: .monthly,
              remaining: 72,
              startOffset: -8 * 24 * 60 * 60,
              endOffset: 22 * 24 * 60 * 60,
              breakdown: [
                UsageBreakdownItem(id: "auto", label: "Auto + Composer", usedPercent: 31),
                UsageBreakdownItem(id: "api", label: "API", usedPercent: 18),
              ]
            )
          ]
        )
      ],
      freshness: now,
      sourceDescription: "Web",
      cacheHitRate: nil,
      accountDescription: "hidden@example.com",
      planDescription: "Cursor Pro",
      notes: ["$5.60 / $20.00"]
    )

    static let antigravity = UsageSnapshot(
      providerID: .antigravity,
      displayName: "Antigravity",
      pools: ["Gemini", "Claude/GPT-OSS"].map { pool in
        UsagePoolSnapshot(
          id: pool.lowercased(),
          name: pool,
          windows: [
            window(
              id: "\(pool)-5h",
              label: "5-hour",
              kind: .fiveHour,
              remaining: pool == "Gemini" ? 61 : 84,
              startOffset: -2 * 60 * 60,
              endOffset: 3 * 60 * 60
            ),
            window(
              id: "\(pool)-week",
              label: "Weekly",
              kind: .weekly,
              remaining: pool == "Gemini" ? 48 : 76,
              startOffset: -4 * 24 * 60 * 60,
              endOffset: 3 * 24 * 60 * 60
            ),
          ]
        )
      },
      freshness: now,
      sourceDescription: "Local IDE",
      cacheHitRate: nil,
      accountDescription: "hidden@example.com",
      planDescription: "Google AI Pro",
      notes: []
    )

    static let history: [DailyActivity] = makeHistory()
    static let pace: [DailyPace] = makePace()

    private static func makeHistory() -> [DailyActivity] {
      (0..<30).map { offset in
        let seconds = -Double(offset) * 24 * 60 * 60
        return DailyActivity(
          date: now.addingTimeInterval(seconds),
          amount: Double((offset * 7) % 35)
        )
      }
    }

    private static func makePace() -> [DailyPace] {
      (0..<18).map { offset in
        let seconds = -Double(offset) * 24 * 60 * 60
        return DailyPace(
          date: now.addingTimeInterval(seconds),
          delta: -Double((offset * 13) % 70)
        )
      }
    }
  }
#endif
