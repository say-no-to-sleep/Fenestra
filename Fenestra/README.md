# Fenestra

Fenestra is a native, menu-bar-only macOS app that compares quota consumption
with an even pace toward the provider's real reset time. It tracks Claude Code,
Codex CLI, Antigravity, and Cursor.

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
- Rolling one-hour exhaustion projection
- 5-hour and weekly windows where a provider reports them
- Antigravity's independent Gemini and Claude/GPT-OSS pools
- Cursor's single billing-cycle window and returned component breakdown
- 90-day local activity heatmap and daily worst-pace history

Fenestra does not invent reset anchors. A chart is rendered only when the
provider supplies enough data to establish its timeline. Otherwise the panel
explicitly says `Reset time unknown`.

## Provider setup and caveats

### Claude Code

Fenestra reads `~/.claude/.credentials.json` or the current
`Claude Code-credentials` Keychain item and calls:

`https://api.anthropic.com/api/oauth/usage`

This OAuth usage endpoint is undocumented. Fenestra never launches Claude Code,
sends a model prompt to force refresh, or stores Anthropic OAuth client
credentials. If the OAuth session expires, it shows the exact login command;
running Claude Code remains an explicit user action.

Claude Code 2.1+ can provide the same reset timestamps to a status-line command.
To use that local source, make the bundled helper executable and configure it as
your status line:

```sh
chmod +x /path/to/Fenestra/Scripts/fenestra-claude-statusline
```

```json
{
  "statusLine": {
    "type": "command",
    "command": "/absolute/path/to/Fenestra/Scripts/fenestra-claude-statusline"
  }
}
```

The helper stores the last status-line payload at
`~/Library/Application Support/Fenestra/claude-statusline.json`.

Fenestra never opens a Keychain authorization dialog in the background. If no
status-line payload is available, the Claude tab offers **Allow OAuth Access**;
that explicit action authorizes Claude Code's Keychain item once and Fenestra
reuses the credential in memory for the rest of the app session.

JSONL under `~/.claude/projects` is used only for cache-hit efficiency. Raw
input/output token fields can undercount billed totals and are never used to
reconstruct remaining quota. The cache stat is a bounded recent sample (up to
the 50 most recently modified files and the latest 1 MB of each), computed off
the launch path so a large Claude history cannot stall the menu. Fenestra
watches this tree with a debounced file event source, reuses unchanged results,
and keeps a configurable five-minute polling backstop by default.

### Codex

Fenestra reads `~/.codex/auth.json` and calls the same current endpoint used by
Codex CLI 0.142.x:

`https://chatgpt.com/backend-api/wham/usage`

The `ChatGPT-Account-Id` header is included when present. The endpoint is
internal and may change. The installed CLI has no documented terminating
refresh command, so Fenestra never launches it automatically. On expiry it asks
you to run `codex login`. Banked reset credits are informational and remaining
percentages are not clamped, so future API values above 100% remain valid.

### Antigravity

Fenestra first scans for Antigravity's `language_server` process, finds
its listening ports with `lsof`, reads its CSRF command-line flag, and calls:

- `RetrieveUserQuotaSummary`
- `GetUserStatus`
- `GetCommandModelConfigs` as fallback

If the local server is unavailable, Fenestra reads the same `gemini` /
`antigravity` Keychain token used by `agy`, then calls Google's Cloud Code
API: `loadCodeAssist` → `retrieveUserQuotaSummary` for full grouped 5h +
weekly quota, falling back to `fetchAvailableModels` (5h per-model only) if
the summary endpoint is unavailable. It never writes back to Antigravity's
Keychain item. Open Antigravity or run `agy` to refresh an expired session.
If the app is not running, Fenestra's unavailable state includes an **Open
Antigravity** button that launches the installed app and retries local
discovery.

This provider is reverse-engineered and the most likely to need maintenance.
Models are grouped by canonical family matching: names containing `Gemini` go
to Gemini; other public text models go to Claude/GPT-OSS. The UI does not
assume both 5-hour and weekly buckets exist.

### Cursor

Fenestra calls Cursor's current web dashboard endpoints:

- `/api/usage-summary`
- `/api/auth/me`
- legacy `/api/usage?user=…`

It accepts either dollar-credit quotas or legacy request-count quotas. Billing
start/end timestamps come from Cursor's response; Fenestra never assumes the
first day of the month. Percentage fields returned under the plan are parsed
dynamically into component rows rather than hardcoding a particular plan's
names.

Fenestra can reuse a valid Cursor.app session. Browser fallback supports:

- Firefox cookie SQLite (no Keychain prompt)
- Safari `Cookies.binarycookies` (may require Full Disk Access)
- Chrome and Edge cookie SQLite (requires their Safe Storage Keychain item)

Chrome/Edge access is opt-in under Settings → Cursor. Fenestra first attempts a
non-interactive read; when macOS approval is required, the Cursor tab shows an
explicit **Allow Browser Access** action before any system dialog can appear.
Full Disk Access only grants access to protected files such as Safari's cookie
database; it does not bypass or remember macOS Keychain authorization.
If no session works, Fenestra shows a sign-in message instead of zero usage.

Cursor's dashboard and cookie formats are undocumented and can change.

## Privacy and network policy

All history, settings, and logs remain on the Mac:

`~/Library/Application Support/Fenestra/`

There is no analytics, telemetry, crash reporting, cloud sync, or third-party
SDK. `RestrictedHTTPClient` rejects requests and redirects outside this
provider allowlist and requires HTTPS except for loopback:

- `api.anthropic.com`
- `chatgpt.com`
- `daily-cloudcode-pa.googleapis.com`
- `cloudcode-pa.googleapis.com`
- `cursor.com`
- loopback (`127.0.0.1` / `localhost`)

The app never sends browser cookies or provider tokens anywhere except the
corresponding provider endpoint.

## Notifications

Fenestra asks for notification permission on first launch. Bad-pace alerts
require two consecutive threshold crossings. Exhaustion-before-reset alerts use
time-sensitive delivery only when macOS reports it as enabled; otherwise they
fall back to normal active notifications.

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
