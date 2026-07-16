# Fenestra

Fenestra is a native, menu-bar-only macOS app that compares quota consumption
with an even pace toward the provider's real reset time. It supports all 54
usage providers registered by the pinned CodexBar provider core.

## Requirements

- Apple silicon Mac
- macOS 27
- Xcode 27 / Swift 6
- App Sandbox disabled (already configured)

Build from Xcode, or:

```sh
xcodebuild \
  -project Fenestra.xcodeproj \
  -scheme Fenestra \
  -configuration Release \
  -derivedDataPath .build
```

The target uses ad-hoc signing. Open the resulting app with right-click → Open
the first time if Gatekeeper asks.

## What Fenestra shows

- Dashed even-spend line and observed remaining-quota line
- Green/red pace difference
- Confidence-aware recent and locally personalized exhaustion forecasts
- 5-hour and weekly windows where a provider reports them
- Provider-specific rate, spend, credit, and subscription windows
- One year of local usage history with previous-window browsing and comparison
- Reset timeline, anomaly detection, and provider reliability health

Fenestra does not invent reset anchors. A chart is rendered only when the
provider supplies enough data to establish its timeline. Otherwise the panel
explicitly says `Reset time unknown`.

## Provider setup and caveats

Providers are disabled or enabled individually in Settings. Each provider also
has its own refresh cadence. The configuration button exposes only source modes
registered by that provider, plus the relevant API key, cookie, region,
workspace, host, or AWS fields.

Automatic mode follows CodexBar's tested provider-specific fallback order. For
example:

- Claude: Admin API key when configured; otherwise OAuth → Claude CLI → web
  session. This means an OAuth HTTP 429 can fall back to the same web usage
  source CodexBar uses.
- Codex: OAuth → Codex CLI.
- Kilo: API token → local CLI session.
- Augment: local CLI → browser session.
- OpenCode Go: browser session → local SQLite.

The complete audited source list is in
[`PROVIDER_SOURCES.md`](PROVIDER_SOURCES.md). The app pins CodexBar to an exact
reviewed commit rather than silently taking provider changes.

API keys, secret keys, and manual cookie headers entered in Fenestra are stored
in the macOS Keychain. Source mode and non-secret routing fields are stored in
preferences. Background refreshes remain non-interactive; a manual Refresh is
marked as user initiated for provider flows that may need explicit Keychain
approval.

Claude JSONL under `~/.claude/projects` remains local and is used only for the
cache-hit statistic. It is never used to reconstruct quota. Fenestra scans a
bounded sample and file events update only that local statistic.

## Privacy and network policy

All history, settings, credentials, and logs remain on the Mac:

`~/Library/Application Support/Fenestra/`

There is no analytics, telemetry, crash reporting, or cloud sync. Provider
fetching uses the pinned MIT-licensed `CodexBarCore`; see
[`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md). Its provider-specific
clients validate credential-bearing endpoint overrides, require HTTPS where
appropriate, and scope cookies/tokens to the corresponding provider. Local
probes use loopback or provider CLIs.

Usage history is stored in a WAL-mode SQLite database. On first launch after an
upgrade, Fenestra transactionally imports `history.json` once and leaves that
file untouched as a fallback. Usage samples and completed windows are retained
for 365 days; refresh events are retained for 30 days. Forecast training is
partitioned by subscription profile so changing between paid and free tiers
does not mix incompatible behavior. Settings can export usage or privacy-safe
diagnostics and can clear all learned/history data without touching credentials.

## Notifications

Fenestra asks for notification permission on first launch. Bad-pace alerts
require two consecutive threshold crossings. Exhaustion-before-reset alerts use
time-sensitive delivery only when macOS reports it as enabled; otherwise they
fall back to normal active notifications.

Personalized forecasts cannot trigger notifications while they are still in
the early-learning stage. Alertable anomalies also require two confirming
refreshes and always use ordinary notification priority.

## Debugging

Settings → Show debug log reveals:

`~/Library/Application Support/Fenestra/fenestra.log`

Provider failures retain the last successful snapshot and mark it stale.
Missing CLIs, credentials, permissions, unexpected payloads, and a stopped
Antigravity IDE are surfaced as explicit UI states.

## macOS 27 beta note

The project targets macOS 27 explicitly and uses first-party `MenuBarExtra`.
The debug build has an environment-gated test window for UI automation:

```sh
FENESTRA_UI_TEST_WINDOW=1 /path/to/Fenestra.app/Contents/MacOS/Fenestra
```

The Release build contains no debug window. Menu-bar rendering and SwiftUI
behavior should be retested on later macOS 27 seeds.
