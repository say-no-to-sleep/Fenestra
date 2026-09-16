# Fenestra

Fenestra tracks AI service usage from your desktop, comparing remaining quota
with an even spending pace toward the provider's reset time. It shows usage
charts, reset windows, local history, and exhaustion forecasts.

Fenestra is a native SwiftUI menu bar application for macOS. It uses the
CodexBar provider core, with dedicated Claude, Codex, and Cursor integrations.

## macOS

Requires macOS 27 and Xcode 27 with Swift 6. Open
`Fenestra/Fenestra.xcodeproj` in Xcode, select the `Fenestra` scheme, and run.
To build from the repository root:

```sh
xcodebuild -project Fenestra/Fenestra.xcodeproj -scheme Fenestra \
  -configuration Release -derivedDataPath Fenestra/.build
```

Enable providers and configure their credentials in Settings. Available
authentication methods depend on the provider and can include existing CLI
sessions, API keys, and browser sessions.

See the [macOS README](Fenestra/README.md) for setup, charts, notifications,
privacy, and debugging, and [provider sources](Fenestra/PROVIDER_SOURCES.md)
for integration details.

## Data and privacy

Settings, history, and logs are stored locally. Provider requests use the
credentials configured for each integration. The application does not include
analytics, telemetry, or cloud sync. Treat usage forecasts as estimates;
provider-reported quotas and reset times remain the source of truth.

## Tests

Run the macOS tests from the repository root:

```sh
xcodebuild test -project Fenestra/Fenestra.xcodeproj -scheme Fenestra \
  -destination 'platform=macOS' -derivedDataPath Fenestra/.build
```

Passing automated tests does
not establish tray, menu bar, accessibility, or physical display behavior.

## Third-party components

The macOS application pins its CodexBar dependency. See
[third-party notices](Fenestra/THIRD_PARTY_NOTICES.md) for attribution.
