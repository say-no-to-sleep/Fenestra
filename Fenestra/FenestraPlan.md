# Build: Fenestra — macOS Menu Bar Usage Pace Tracker

## Goal

Build a complete, working native macOS menu bar app named **Fenestra** in Swift/SwiftUI that tracks usage **pace** (not just raw percentage) for four AI coding tools: Claude Code, OpenAI Codex CLI, Google Antigravity, and Cursor. The core insight to surface is not "how much have I used" but "am I burning my quota faster or slower than a perfectly even pace toward the next reset, and will I actually get locked out before relief arrives." Cursor is the odd one out: it has no 5-hour window at all, just a single monthly window anchored to the user's billing date, so don't assume every provider fits the 5h+weekly shape — the data model needs to support providers reporting just one window.

**Hard rule on reset timestamps:** never fabricate, guess, or hardcode a `windowStart`/`windowEnd` value (e.g. assuming "resets every Monday at midnight," "5 hours after app launch," or "resets on the 1st of the month") when the real value isn't available. Every reset timestamp shown in the UI must trace back to an actual value from the provider (Codex's or Claude Code's usage API response, Antigravity's `GetUserStatus` response, or Cursor's account/billing data — Cursor specifically resets on the user's individual billing date, not the calendar month, so this is an easy one to get wrong by assumption). If a provider's true reset anchor genuinely can't be determined from any available local source, the UI must show an explicit "reset time unknown" state (and, for Claude Code specifically, prompt the user to set it manually per the Settings option below) rather than rendering a chart against an invented timeline. A wrong-but-confident chart is worse than an honest "unknown."

## Platform & stack

- **Target: macOS 27 (Golden Gate)**, Apple Silicon only (no Intel/x86_64 considerations needed — Golden Gate dropped Intel support entirely). Swift 6, SwiftUI.
- Note: macOS 27 is currently in developer beta (public beta expected July, full release fall 2026). Build against the macOS 27 SDK. The menu bar/overflow architecture changed again this cycle (it broke several third-party menu bar *management* tools like Bartender/Ice, which hook in via accessibility APIs) — this app uses the standard first-party `MenuBarExtra` API rather than any such hooks, so it should be unaffected, but verify actual rendering/behavior once built rather than assuming older menu bar layout conventions, since beta behavior can still shift.
- macOS 27 reverted menu item icon visibility (icons are hidden by default again, opt back in per-item with the `.icon` label style / `preferredImageVisibility` where a menu item represents an object rather than an action — e.g. provider icons in the picker).
- Prefer system materials (e.g. `.regularMaterial`, standard system glass backgrounds) for the popover background rather than custom-drawn translucency, so it respects the user's own Liquid Glass translucency slider setting rather than looking inconsistent with the rest of the system.
- `MenuBarExtra` for the menu bar presence, no Dock icon
- Swift Charts (built-in) for all charts
- `UserNotifications` framework for alerts
- Local persistence via SQLite (a tiny wrapper is fine) or flat JSON files under Application Support — no Core Data needed
- No third-party dependencies unless truly necessary
- **Do not enable App Sandbox.** This app reads other applications' credential files (`~/.claude/.credentials.json`, `~/.codex/auth.json`), scans running processes to discover Antigravity's language server, and reads browser cookies for Cursor — none of which is possible under the sandbox. Ship as a regular unsandboxed app; ad-hoc/self-signing with a free Apple ID (Personal Team) is sufficient since this is for the user's own machine, no paid Apple Developer Program membership needed. Expect one Gatekeeper right-click → Open on first launch, that's fine. The Cursor provider specifically will additionally need either Full Disk Access (to read Safari's cookie store) or Keychain access (to decrypt Chrome's Safe Storage key) depending on which browser the user is signed into Cursor's web dashboard with — request only whichever is needed for the browser actually detected, and explain in-app why the permission is requested before the system prompt fires.
- **Hard constraint:** no network calls to anything other than the four local provider sources described below. No analytics, telemetry, crash reporting SDKs, or cloud sync of any kind. State this explicitly in code comments and the README so it's auditable.

## Shared provider abstraction

Define a `UsageProvider` protocol:

```swift
protocol UsageProvider {
    var id: ProviderID { get } // .claudeCode, .codex, .antigravity, .cursor
    var displayName: String { get }
    func currentSnapshot() async throws -> UsageSnapshot
    func startWatching(onUpdate: @escaping (UsageSnapshot) -> Void) -> CancellableToken
}
```

`UsageSnapshot` carries a list of one or more named windows (not a fixed "5-hour + weekly" pair) — Claude Code, Codex, and Antigravity's two pools report `5h` and `weekly` windows, while Cursor reports a single `monthly` window. Each window carries:

- `windowStart`, `windowEnd` (Date)
- `quotaTotal` (Double — tokens, %, credits, or raw request count depending on provider; see Cursor's section below for why the unit varies even within one provider)
- `used` (Double)
- `remainingPercent` (Double, 0-100)
- a freshness timestamp + a short source description string (for an "Updated X ago · Source: Y" line in the UI)

The UI must render whatever set of windows a given snapshot actually contains rather than assuming every provider has both a 5h and a weekly panel.

## Provider 1: Claude Code

- **Primary source — real usage data, no inference needed**, same tier as the Codex and Antigravity providers below:
  - Read the OAuth access token from `~/.claude/.credentials.json` (`claudeAiOauth.accessToken`).
  - Call `https://api.anthropic.com/api/oauth/usage` with that bearer token and the `anthropic-beta: oauth-2025-04-20` header. This is an unofficial/undocumented endpoint (there are open public feature requests asking Anthropic to make equivalent data officially available), but it returns real plan-level 5-hour and weekly usage percentages with actual reset timestamps — trust these numbers directly rather than reconstructing anything locally.
  - As a secondary same-tier source: Claude Code (version ≥2.1.x) passes a `rate_limits` object directly on stdin to any configured statusline command, including `rate_limits.five_hour.resets_at` and `rate_limits.seven_day.resets_at` as real epoch timestamps it already computed — no network call needed if this is reachable. Prefer whichever of the two sources is available and freshest; they should agree.
  - Poll the usage API on a configurable interval (default 45s, matching the Codex provider's cadence) since it's a network call. Handle expired/missing credentials gracefully (surface a "needs Claude Code login" state, never crash).
- **JSONL parsing is for cache-efficiency only, and as a last-resort fallback**, not the primary pace/reset data source:
  - Read JSONL files under `~/.claude/projects/**/*.jsonl` purely to compute the **cache hit rate** (`cache_read / (cache_read + cache_creation + input_tokens)`), since that breakdown isn't present in the usage API response. Deduplicate by message `uuid`.
  - **Known caveat:** raw `input_tokens`/`output_tokens` in JSONL can be substantially undercounted vs. real billed totals, while `cache_read_input_tokens`/`cache_creation_input_tokens` are reliable — this is fine for the cache-hit-rate ratio (both numerator and the relevant denominator terms are reliable fields) but means JSONL-derived totals should never be used to reconstruct remaining-quota percentages.
  - Use FSEvents (via `DispatchSource` or a wrapper) to watch the projects directory recursively for this purpose. Debounce rapid successive write events (250-500ms) before re-parsing. Add a watcher health check: if no callback fires for ~2 minutes despite directory mtime changing, restart the watcher. Always run a low-frequency backstop poll (default 60s, user-configurable) in parallel in case FSEvents drops events.
  - Only if both the usage API and the statusline `rate_limits` field are unavailable should the app fall back to inferring the 5-hour block boundary from JSONL timestamps (first message after an idle gap as `t0`, +5h as `t1`) — and in that degraded case, the weekly anchor specifically still cannot be reliably inferred from JSONL alone, so follow the "reset time unknown" rule above rather than guessing it.
- Peak-hour note: Claude Code 5-hour limits are throttled weekdays 5-11am Pacific time. If current time falls in that window, show a small indicator and adjust messaging (e.g. "pace looks bad, partly because you're in the throttled window — eases up at 11am PT").

## Provider 2: Codex

- Read the OAuth token from `~/.codex/auth.json`.
- Call the same internal usage endpoint the Codex CLI itself uses to power its own `/status` display. This is an undocumented internal API and the exact host/path may have shifted — inspect the locally installed Codex CLI binary or its public source (github.com/openai/codex) if accessible in the build environment to confirm the current endpoint rather than guessing blindly.
- Parse the response for 5h and weekly window percentages and reset timestamps directly; trust its numbers over any local reconstruction.
- Poll on a configurable interval (default 45s) since this is a network call, not a file watch. Handle expired/missing token gracefully (surface a "needs Codex CLI login" state, never crash).
- If the user has a banked rate-limit reset, treat the effective ceiling as potentially >100% for that window (informational, not an error state) rather than letting the math choke on it.

## OAuth token refresh strategy (Claude Code & Codex)

Neither Claude Code's nor Codex's OAuth client credentials are available to a third-party app, so Fenestra cannot implement its own token refresh from scratch. Instead, follow the pattern (and avoid the known pitfall) seen in `steipete/CodexBar`'s Claude provider:

- Detect impending expiry proactively from the token's own `expiresAt`/`exp` field in the credentials file (Claude Code access tokens are short-lived, on the order of ~8 hours) rather than waiting for a 401 response.
- When near/past expiry, delegate the refresh to the real CLI rather than reimplementing OAuth: invoke it non-interactively in a way that completes and exits quickly (e.g. a one-shot/print-mode invocation), not a bare `claude`/`codex` launch that opens an interactive REPL and never returns within a reasonable timeout. CodexBar's current implementation has exactly this bug — it shells out to `claude` expecting a quick refresh-and-exit, but the CLI starts in REPL mode and the 8-second timeout always lapses, so the delegated refresh always fails. Use a generous timeout (e.g. 20-30s) and a command invocation that's actually guaranteed to terminate (print/non-interactive mode, or a dedicated short-lived subcommand if the installed CLI version has one) rather than copying CodexBar's timeout value as-is.
- After a successful delegated refresh, re-read the credentials file (the CLI will have written the new token to disk) and retry the original request once.
- If delegated refresh fails or the CLI isn't installed/reachable, surface a clear "needs reauth — run `claude`/`codex` once to refresh" state rather than retrying indefinitely or crashing.

## Provider 3: Antigravity

- No documented public API. Implement via local discovery, following the pattern used by independent open-source tools in this space — read their public source for the actual discovery algorithm rather than guessing from scratch:
  - `steipete/CodexBar` (Antigravity provider implementation)
  - `Henrik-3/AntigravityQuota`
  - `skainguyen1412/antigravity-usage`
  - `robinebers/openusage` (its Antigravity provider doc also notes a `GetCommandModelConfigs` fallback when `GetUserStatus` doesn't return what's expected, and a Google Cloud Code fallback path via Keychain token when the local language server isn't reachable at all — worth mirroring both fallbacks, not just the primary RPC)
  1. Scan running processes for the Antigravity IDE's language server process.
  2. Discover the local port it's listening on.
  3. Extract the local auth token the language server uses for its own loopback API.
  4. Call its `GetUserStatus` RPC (or equivalent) to retrieve quota data per model bucket.
- This is the most fragile provider. Build it defensively: if discovery fails at any step, show a clear "Antigravity not detected — is the IDE running?" state rather than crashing or silently showing zero. Poll on a configurable interval (default 60s).
- **Quota is split into two independent pools, not one unified percentage**: a **Gemini** pool (all Gemini model variants) and a **Claude/GPT-OSS** pool (Claude Sonnet/Opus and GPT-OSS models served through Antigravity). These drain completely independently — it's normal and expected for one pool to be exhausted while the other is untouched. `UsageSnapshot` needs to support multiple named pools per provider rather than assuming one; for Antigravity specifically, produce two snapshots (or one snapshot with two sub-pools) labeled "Gemini" and "Claude/GPT-OSS", each with its own 5h/weekly windows, not a single collapsed number. Model grouping should be done by canonical family matching (e.g. any model name containing "Gemini" → Gemini pool, anything else → Claude/GPT-OSS pool) rather than an exact model-name allowlist, since Antigravity's available model list and naming (e.g. "(Thinking)" suffixes) shifts over time and a brittle allowlist will silently misclassify new models — this exact bug has bitten other tools in this space (see `steipete/CodexBar` issue #577).
- No 5h/weekly symmetry guarantee within or across pools: Free tier is weekly-refresh-only, Pro/Ultra get a 5h layer on top. Gracefully omit the 5h panel if a snapshot doesn't include one.

## Provider 4: Cursor

Cursor is structurally different from the other three: no local credential file, no local RPC, no 5-hour window — its usage data lives behind a web dashboard and the most viable read path is browser cookies, following the pattern used by `steipete/CodexBar`'s Cursor provider.

- **Auth/read mechanism**: read the user's existing cursor.com / cursor.sh session cookie from whichever browser they're signed in with (Safari, Chrome, Firefox, or Edge), then call Cursor's web usage endpoint with that cookie. This requires either:
  - **Full Disk Access** (for reading Safari's cookie store directly), or
  - **Keychain access** (to decrypt Chrome/Edge's "Safe Storage" key and read its cookie database).
  Detect which browser the user is actually signed into Cursor with and request only the corresponding permission, explaining why in-app before the system prompt fires. If no valid session cookie can be found in any supported browser, surface "Cursor: sign in to cursor.com in your browser" rather than crashing or showing zero.
- **Single window, not two**: Cursor has no 5-hour concept at all. It resets **monthly, anchored to the user's individual billing date** (not the 1st of the calendar month, not a fixed weekly cycle) — this anchor must come from Cursor's own account data, never assumed. Render a single panel for Cursor (skip the 5h panel entirely, don't show an empty placeholder for it) using the same dashed-ideal-line / shaded-delta / callout visual language as the other panels, just scaled to a ~30-day window instead of 5h or 7d.
- **Quota unit varies by account vintage** — handle both shapes:
  - Newer accounts: dollar-credit-based (e.g. "$20 included this month"), `used`/`quotaTotal` in dollars.
  - Legacy accounts still on the older plan: a simple request count (used/limit), no dollar figure at all.
  Detect which shape the account's response has and render accordingly — don't assume one shape and break on the other.
- **The included-usage Total is itself composed of named sub-meters, not one flat number.** On an individual Pro plan, "Included in Pro" shows a Total percentage plus a breakdown into separate tracked components — observed as "Auto + Composer" and "API" — each progressing independently against the same overall monthly allowance, with distinct overflow behavior per component (e.g. Auto+Composer overflow draws from API quota or on-demand spend; API overflow goes straight to on-demand spend). This is structurally the same idea as Antigravity's two-pool split, just nested under one Total rather than fully separate. Parse and render whatever sub-meter breakdown the response actually contains (don't hardcode "Auto + Composer" / "API" as the only possible pair — naming and composition may differ on Pro+, Ultra, or Teams plans) rather than collapsing it into a single number or assuming any one component doesn't count at all.
- Auto mode pricing/counting behavior has changed at least once before (Teams plans split Composer/Auto into a separate, more generous pool from third-party-model usage as of June 2026) — don't hardcode assumptions about which components count toward the included pool versus bill separately; read whatever breakdown the actual account's response provides rather than encoding today's Pro-plan behavior as a universal rule.
- Poll on a configurable interval (default 60s, matching Antigravity's cadence, since this is also a less time-critical network read). Treat this as the most likely provider to silently break if Cursor changes its web dashboard internals, same caveat as Antigravity — build defensively and surface a clear degraded state.

## Pace math (shared across all providers)

For a window with start `t0`, end `t1`, duration `T = t1 - t0`, and quota `Q`:

- Ideal remaining at time `t`: `r_ideal(t) = 100 * (1 - (t - t0) / T)` — linear decay from 100% to 0%
- Actual remaining at time `t`: `r_actual(t) = 100 * (Q - used(t)) / Q`
- Pace delta: `delta(t) = r_actual(t) - r_ideal(t)`
  - `delta > 0`: under pace (more left than the even-spend line predicts) → good → shade green
  - `delta < 0`: over pace (less left than predicted) → bad → shade red
- Display `|delta|` rounded to whole percent as "X% over pace" / "X% under pace" (red text for over, green for under), matching the visual language of: dashed ideal-decay line, solid actual line, shaded delta region between them, callout bubble at the latest point.
- Also compute a **projected exhaustion time**: extrapolate the burn rate using a recent rolling lookback (e.g. last 30-60 minutes of actual usage, not the whole-window average, since burn is bursty) and estimate when remaining hits 0%. Compare against the window's natural reset time. If projected exhaustion is earlier than reset, surface this distinctly (e.g. a red banner) from the milder "currently over pace" state — this is the actionable "you will get locked out before relief" signal.

## UI

**Design directive: minimal text throughout.** Favor numbers, color, and the charts themselves over written copy. Labels should be as short as possible (e.g. "4% over pace" not "You are currently 4% over an even pace for this window"), avoid explanatory paragraphs in the popover itself, and keep Settings labels terse. Longer explanations (e.g. what "pace" means, provider caveats) belong in the README or a single optional "About"/help affordance, not in the main glanceable UI.

**Menu bar glyph:** small SF Symbol or custom shape reflecting the worst-case (most urgent) pace delta across all enabled providers, color-coded green/yellow/red. Click opens the popover.

**Popover:**
- Top: provider picker (segmented control or dropdown), showing only enabled/detected providers, defaulting to whichever is currently most urgent.
- "Updated {relative time} ago · Source: {description}" line.
- Render whatever windows the active provider's snapshot actually contains, per these layouts:
  - **Claude Code, Codex**: two stacked panels, 5-hour on top, weekly below.
  - **Antigravity**: **two side-by-side columns** (one labeled "Gemini", one labeled "Claude/GPT-OSS"), each column internally stacked the same way — 5-hour panel on top, weekly panel below — since Antigravity's two pools are independent and both worth seeing at once rather than picked via the provider dropdown's single-pool assumption.
  - **Cursor**: a single panel labeled "Monthly", scaled to its ~30-day billing-date-anchored window, charting the **Total** included-usage percentage (the pace math runs against this). No 5h panel exists for this provider at all — don't render an empty or placeholder slot for it. Below the chart, show the sub-meter breakdown as plain terse text/small bars (e.g. "Auto+Composer 27% · API 27%") using whatever components the response actually contains — this is supplementary detail, not a second pace chart, so keep it minimal per the text directive above.
  - Shared panel visual language regardless of window length: x-axis from windowStart to windowEnd with appropriate labels (clock times for 5h, dates for weekly/monthly), dashed ideal-decay line, solid actual-remaining line, shaded region colored red when actual < ideal else green, callout bubble at the latest point with current % and pace-delta text.
- Below the charts: a one-line **smart suggestion** computed by comparing pace delta across all enabled providers, kept terse (e.g. "Codex has the most headroom" or "Everything's tight"). Must genuinely compare, not always point at the same tool.
- A small cache-efficiency stat for Claude Code specifically (donut or simple ratio text).
- Settings (gear icon): refresh cadence presets per provider (manual / 1m / 2m / 5m / 15m), enable/disable individual providers, manual weekly-reset-anchor override for Claude Code, notification threshold configuration.
- Secondary tab/expand: rolling daily activity heatmap (GitHub-contribution-graph style) built from locally stored history, plus a sparkline of past windows' peak pace delta.

## Notifications

- Use `UNUserNotificationCenter`, request authorization on first launch.
- Fire when:
  - Pace delta crosses below a configurable bad-pace threshold (default -25%) and persists for more than one consecutive refresh cycle (avoid flapping on a single noisy reading).
  - Projected exhaustion time is earlier than the window's natural reset — mark this one more urgent (e.g. time-sensitive interruption level) since it's the scenario most worth pre-empting. The time-sensitive entitlement requires Apple approval and may not be available on a personal ad-hoc signed build; if requesting/using it fails or isn't available, fall back to a normal `.active` interruption level rather than failing to notify at all.

## Persistence

- Store rolling history (periodic snapshots of remaining % per provider per window) locally, either via SQLite or flat JSON under `~/Library/Application Support/Fenestra/`. No iCloud, no external sync of any kind.
- Cap retention to a sane window (e.g. 90 days) and prune on launch.

## Resilience

Every provider module must degrade gracefully: missing CLI, expired/missing auth, IDE not running, unexpected API response shape, file permission issues — all should produce a clear in-UI message ("Codex: not logged in", "Antigravity: IDE not detected", etc.), never a crash or a silently stuck/blank chart. Log errors to a local debug log file the user can optionally view, never to any external service.

**Sleep/wake handling:** scheduled timers (polling, the backstop poll) don't fire while the Mac is asleep. Observe `NSWorkspace.didWakeNotification` and force an immediate refresh across all providers on wake, rather than waiting for the next scheduled interval — otherwise the popover shows stale data for a while after opening the lid.

## Beta toolchain notes (Xcode 27 beta 2)

- Set explicit deployment target macOS 27.0.
- Xcode 27 bundles Apple's own SwiftUI Agent Skill for agentic coding tools, but it's iOS-first and currently omits macOS Scenes, window styling, `MenuBarExtra`, AppKit interop, and Swift Charts marks/axes/selection guidance — i.e. most of what this app actually needs. Don't rely on it alone for the menu bar or charting code; reason from the actual `MenuBarExtra` and Swift Charts API surface directly.
- SwiftUI's result builder model changed this cycle: `@ViewBuilder` now sits under a unified `@ContentBuilder`, and builder contents are no longer constrained to conform to `View`. When composing the stacked weekly/5-hour chart panels with conditional branches (e.g. omitting the 5h panel for providers without one), extract each branch into its own function marked `@ChartContentBuilder` rather than inlining deep conditionals, both for clean type-checking under the new model and to dodge a known Swift Charts type-check slowdown on deeply branching chart content.
- There's a reported beta crash (`EXC_BAD_ACCESS`) calling `UserDefaults.standard.integer(forKey:)` from a singleton during `App.init()` on iOS/iPadOS/visionOS 27 beta 1; not yet confirmed on macOS, but since refresh-cadence and notification-threshold settings will live in UserDefaults, defer those reads to `.task`/`.onAppear` rather than synchronous access inside `init()`, to be safe either way.
- This is beta software (public beta expected July, release fall 2026) — if something in the menu bar/SwiftUI APIs behaves unexpectedly, treat it as a possible beta bug rather than necessarily a code bug, and note it in the README so a future beta update can be re-tested.

## Build & test workflow

- Use the **Build macOS Apps** plugin (Codex's plugin tailored to native SwiftUI Mac apps — covers shell-first build/run loops, SwiftPM app packaging, scene/window patterns, AppKit interop, and signing/notarization) for the overall build loop rather than relying solely on the generic bundled SwiftUI skill, since that one is iOS-first and weak on exactly this app's surface (menu bar extras, AppKit interop, Charts).
- After the app builds and runs, use the **Computer Use** plugin to actually test it end to end rather than only relying on compiler success or unit tests. Install the plugin if not already installed, and grant Screen Recording + Accessibility permissions when prompted. Then drive through, at minimum:
  - Click the menu bar glyph and confirm the popover opens with the expected layout.
  - Switch the provider dropdown through each provider and confirm the correct panel layout renders for each (stacked pair for Claude Code/Codex, two stacked-pair columns for Antigravity, single panel for Cursor), each with a dashed ideal line, solid actual line, correctly colored shaded delta region, and a callout bubble with correct over/under-pace text.
  - Open Settings and exercise the refresh cadence presets, provider enable/disable toggles, and notification threshold fields.
  - Reproduce each degraded state on purpose (e.g. temporarily point the Claude Code path at an empty directory, test with Codex/Antigravity not authenticated/not running, or test Cursor with no browser session signed in) and confirm the UI shows the intended clear message rather than a crash, blank chart, or stuck spinner.
  - Confirm the "Updated X ago · Source: Y" line updates after a manual refresh and after a file-watch-triggered update.
  - If feasible, trigger a notification scenario (e.g. by temporarily lowering the bad-pace threshold) and confirm a system notification actually appears.
  - Note: Computer Use can't automate Terminal or Codex itself, and is currently unavailable in the EEA, UK, and Switzerland — if testing from one of those regions, fall back to manual verification and say so explicitly in the build summary.
- Treat anything Computer Use catches (visual glitch, wrong shading direction, crash on a degraded state) as a bug to fix before considering the build done, not just a note for later.

## Deliverable

A complete, buildable Xcode project (or SPM executable target configured as a macOS app bundle) with:
- Source organized by module: `Providers/ClaudeCode`, `Providers/Codex`, `Providers/Antigravity`, `Providers/Cursor`, `Core/PaceMath`, `Core/Persistence`, `UI/...`
- A README covering setup, the local-only privacy stance, and known caveats per provider (Antigravity's fragility and two-pool quota split, Claude Code's JSONL undercount issue, Codex's endpoint being undocumented/internal, Cursor's browser-cookie dependency and dual quota-unit shapes)
- Sensible defaults so the app is useful immediately on first launch with zero configuration, falling back cleanly for any provider it can't detect on this machine

Build this end to end. Where the Codex endpoint path or the Antigravity discovery specifics aren't fully certain, inspect locally installed CLI binaries/configuration if present on this machine, or fall back to the most well-corroborated public approach from the projects named above. Clearly flag in code comments and the README which parts rely on undocumented/reverse-engineered behavior that may need future maintenance.

Please, after finish running, perform a desloppify scan of this project.
Review the codebase and identify:
- rushed or messy implementation
- duplicated logic
- inconsistent naming or structure
- fragile assumptions
- missing error handling
- UI/UX rough edges
- security or validation issues
- dead code or unused files
- places where the architecture is becoming confusing
- anything that works now but will be painful to maintain later

Then Fix your implementation if anything surfaces.
