# Factorial macOS Widget

macOS menu bar app to clock in to [Factorial HR](https://factorialhr.com) with one click.

## Features

- Clock in for any date with configurable start/end time
- Remembers last used hours and project
- Select project from your assigned Factorial projects
- OAuth 2.0 via system browser (`ASWebAuthenticationSession`)
- No Dock icon — lives entirely in the menu bar

## Requirements

- macOS 13 Ventura or later

## Install

Deploy `FactorialWidget.pkg` via MDM. No user configuration required.

PKG releases are built locally and distributed out-of-band. See [Building a PKG](#building-a-pkg) below.

## First launch

1. Click the Factorial icon in the menu bar
2. **Reautorizar OAuth** → log in via browser and authorise
3. Done — status updates automatically on every open

OAuth tokens are stored at `~/.factorial-tokens.json`.

## Development

```bash
git clone https://github.com/nomasystems/factorial-macos-widget.git
open FactorialWidget/FactorialWidget.xcodeproj
```

Requires Xcode 15+. No external dependencies.

The app reads credentials and telemetry config from environment variables at runtime — no secrets are baked into the build. Set these via JAMF or any MDM tool:

```
FACTORIAL_CLIENT_ID=<your_client_id>
FACTORIAL_CLIENT_SECRET=<your_client_secret>
OTEL_EXPORTER_OTLP_ENDPOINT=http://<host>:4318
OTEL_EXPORTER_OTLP_HEADERS=Authorization=Bearer <token>
```

## Building a PKG

```bash
chmod +x make-pkg.sh
./make-pkg.sh 1.0.0
```

Produces `FactorialWidget-1.0.0.pkg`. Deliver this file to your sysadmin for MDM distribution. Credentials are injected via environment variables — no rebuild needed per environment.

## Release

Push a version tag to create a GitHub release with auto-generated changelog:

```bash
git tag v1.0.0
git push origin v1.0.0
```

The PKG is **not** attached to the GitHub release — it is built locally and distributed out-of-band.

## Network

The app requires HTTPS to `api.factorialhr.com` (Factorial API + OAuth).

An App Transport Security exception for `46.27.220.60` is configured in `Info.plist` — this is the OTLP telemetry collector endpoint, which uses plain HTTP. Telemetry is fire-and-forget and does not affect widget functionality.
