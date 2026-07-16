# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What Fenestra is

Fenestra is a native, menu-bar-only macOS app (SwiftUI, Swift 6, targeting macOS 27 / Apple Silicon) that tracks quota **pace** — whether you are burning a provider's quota faster or slower than an even spend toward its real reset time — across many AI coding tools. The Xcode project lives in the nested `Fenestra/` directory, not the repo root.

**Core design rule (do not violate):** never fabricate, guess, or hardcode a reset timestamp (`windowStart`/`windowEnd`). Every reset shown in the UI must trace back to a real value the provider supplied. When a true anchor cannot be determined, the UI shows an explicit "Reset time unknown" state rather than charting against an invented timeline. Claude Code is the one exception where a user-supplied **manual weekly-reset override** is allowed to fill a missing anchor. The full product spec that these rules come from is `Fenestra/FenestraPlan.md`.

## Build, test, run

All commands run from the project directory `Fenestra/` (the one containing `Fenestra.xcodeproj`):

```sh
# Build (Release)
xcodebuild -project Fenestra.xcodeproj -scheme Fenestra -configuration Release -derivedDataPath .build

# Run the whole test suite (unit tests use the FenestraTests target)
xcodebuild test -project Fenestra.xcodeproj -scheme Fenestra -destination 'platform=macOS'

# Run a single test class or method
xcodebuild test -project Fenestra.xcodeproj -scheme Fenestra -destination 'platform=macOS' \
  -only-testing:FenestraTests/PaceCalculatorTests
xcodebuild test -project Fenestra.xcodeproj -scheme Fenestra -destination 'platform=macOS' \
  -only-testing:FenestraTests/PaceCalculatorTests/testUnderPaceIsPositiveDelta
```

The app is unsandboxed and ad-hoc signed. There is no separate lint step configured; rely on the Swift 6 compiler (strict concurrency) as the correctness gate.

Debug builds expose an environment-gated window for UI automation (the Release build has no such window):

```sh
FENESTRA_UI_TEST_WINDOW=1 /path/to/Fenestra.app/Contents/MacOS/Fenestra
```

`FenestraStore.start()` short-circuits when `XCTestConfigurationFilePath` is set, so the store does no polling/network under test.

## Architecture

The app is a thin native shell around a pinned upstream engine. **`CodexBarCore`** (Swift package `steipete/CodexBar`, pinned to an exact reviewed commit in `Package.resolved`) does the actual provider fetching, credential reading, and quota parsing for all ~54 providers. Fenestra owns the pace math, persistence, forecasting, notifications, and UI. When quota-source behavior seems wrong, the cause is often in the pinned core, not local code — the pin is deliberate so provider changes are never silently absorbed.

Data flows in one direction:

1. **`FenestraApp`** (`App/`) declares a `MenuBarExtra` (window style, no Dock icon) plus a `Settings` scene, both fed by a single `@State FenestraStore`.
2. **`FenestraStore`** (`Core/Store/`) is the `@Observable @MainActor` hub and the single source of truth. It owns providers, per-provider polling `Task`s, `AppSettings`, `HistoryStore`, `NotificationManager`, `AnomalyDetector`, and personalized predictions. It reacts to `NSWorkspace.didWakeNotification` by force-refreshing all providers (timers don't fire while asleep), and debounces settings changes (300ms) before reconfiguring.
3. **`UsageProvider`** (`Providers/UsageProvider.swift`) is the local protocol: `currentSnapshot() async throws -> UsageSnapshot`. In practice the only concrete implementation is **`CodexBarProvider`**, one instance per `ProviderID`.
4. **`CodexBarProvider`** (`Providers/CodexBar/`) is the bridge/adapter. It builds a `ProviderFetchContext`, calls the pinned core's descriptor `fetch`, and **`map(...)`s** the core result into the app's `UsageSnapshot`. This mapping layer holds the provider-specific quirks — treat it as the seam between "upstream shape" and "our model."

### The provider model (`Core/Models/UsageModels.swift`)

`UsageSnapshot` → one or more `UsagePoolSnapshot` → one or more `UsageWindowSnapshot`. The number of pools and windows is **not fixed** — never assume every provider has a 5h + weekly pair. Key shapes the mapping deliberately produces:

- **Antigravity** splits into two independent pools (`Gemini` and `Claude/GPT-OSS`) by canonical family matching on the window label (substring, not an exact allowlist — new model names must not be misclassified). Its real quotas arrive as `extraRateWindows`; the core's primary/secondary rollups are dropped to avoid duplicate graphs.
- **Cursor** is collapsed to a single `Monthly` window (no 5h concept) anchored to the user's billing date, with its Total plus a `breakdown` of sub-meters (e.g. Auto+Composer, API) parsed from whatever components the response contains.
- **Claude Code** is enriched separately (see below).

`ProviderID` (in the same file) enumerates every supported provider and maps each to its `codexBarProvider` counterpart.

### Claude Code specifics

Claude Code has two extra local mechanisms beyond the core fetch, wired through `Providers/ClaudeCode/`:

- **Cache-hit rate** is computed locally from JSONL under `~/.claude/projects` (`ClaudeCacheAnalyzer`, `ClaudeProjectsWatcher`). This is FSEvents-watched with a debounce and a low-frequency backstop poll; it feeds only the cache-hit statistic and is **never** used to reconstruct quota (JSONL token totals are known to undercount). `FenestraStore.restartClaudeProjectsWatcher()` owns the watcher lifecycle.
- **Manual weekly-reset override**: when the provider omits a weekly timeline, `CodexBarProvider.enrichClaudeIfNeeded` applies the user's configured `manualClaudeWeeklyReset` and marks the source as "Manual override." If a window still has no known timeline, it appends the "Reset time unknown" note.

Source-mode selection matters here: `.oauth`/`.auto` read the Keychain (each poll can trigger a macOS password prompt), while `.cli`/`.web` do not. See the `dataSource` wiring in `CodexBarProvider.currentSnapshot()`.

### Pace math and forecasting (`Core/PaceMath/`)

- `PaceCalculator` computes ideal linear decay, the actual-vs-ideal `delta` (positive = under pace = good/green; negative = over pace = bad/red), and a baseline exhaustion prediction from a recent rolling lookback (~2h in the store), not the whole-window average.
- `PersonalizedForecaster` refines the baseline using comparable historical windows, **partitioned by subscription profile** so paid/free tiers don't mix. Early-learning predictions are gated out of notifications.
- `AnomalyDetector` tracks provider reliability/health and requires two confirming refreshes before an anomaly is alertable.

### Persistence (`Core/Persistence/`)

`HistoryStore` (in-memory + async API) sits over `HistoryDatabase` (WAL-mode SQLite in `~/Library/Application Support/Fenestra/`). On first launch after upgrade it transactionally imports the legacy `history.json` once and leaves that file as a fallback. Usage samples/windows are retained 365 days, refresh events 30 days, pruned on launch.

### UI (`UI/`)

`DashboardView` is the popover; it renders whatever pools/windows a snapshot actually contains (stacked pair, two side-by-side columns for Antigravity, single panel for Cursor). Charts use Swift Charts. `WindowPanel` is the shared panel visual (dashed ideal line, solid actual line, shaded delta, callout). Settings live under `UI/Settings/`. Theming goes through the `\.paceTheme` environment value (`Core/Settings/PaceTheme.swift`).

## Conventions and constraints

- **Everything is `@MainActor`** at the store/provider/UI layer; respect Swift 6 strict concurrency. Long-running work is dispatched to detached `Task`s, and `FenestraStore` uses `@ObservationIgnored` for non-observed mutable state.
- **Network policy is a hard, auditable constraint.** No analytics, telemetry, crash reporting, or cloud sync. Outbound calls go only through the pinned core's provider clients (see `Core/Networking/RestrictedHTTPClient.swift`). Keep this stated in code comments where relevant.
- **Secrets** (API keys, secret keys, manual cookie headers) go in the macOS Keychain (`Core/Support/KeychainReader.swift`, provider credential stores). Non-secret routing fields (source mode, region, workspace, host) go in preferences (`AppSettings`).
- **Refresh interaction context**: background refreshes are non-interactive; a user-initiated (`force`) refresh sets `.userInitiated` and invalidates provider caches (Keychain services, cached tokens) so flows that need explicit approval can prompt. See `FenestraStore.refresh` and `invalidateProviderCaches`.
- **Codebase comments prefixed `ponytail:`** mark places where the local mapping intentionally diverges from the raw core output — read them before "simplifying" that code.
- **Author-facing docs to keep in sync when behavior changes:** `Fenestra/README.md` (user-facing setup/privacy/caveats), `Fenestra/PROVIDER_SOURCES.md` (audited per-provider source order), `Fenestra/THIRD_PARTY_NOTICES.md`, and `Fenestra/FenestraPlan.md` (the original spec).
- `repomix-output.xml` at the repo root is a generated flat dump of the codebase for tooling; it is not source and should not be hand-edited.
