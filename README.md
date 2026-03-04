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

Create a `Secrets.xcconfig` file in the project root with your Factorial OAuth credentials (this file is gitignored):

```
FACTORIAL_CLIENT_ID = <your_client_id>
FACTORIAL_CLIENT_SECRET = <your_client_secret>
```

## Building a PKG

Requires a `Secrets.xcconfig` with valid credentials (see [Development](#development)).

```bash
chmod +x make-pkg.sh
./make-pkg.sh 1.0.0
```

Produces `FactorialWidget-1.0.0.pkg`. Deliver this file to your sysadmin for MDM distribution.

## Release

Push a version tag to create a GitHub release with auto-generated changelog:

```bash
git tag v1.0.0
git push origin v1.0.0
```

The PKG is **not** attached to the GitHub release — it is built locally and distributed out-of-band.
