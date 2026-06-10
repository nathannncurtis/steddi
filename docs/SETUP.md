# Steddi Development Setup

## Prerequisites
- Xcode with the iOS 26 SDK
- [xcodegen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)
- iOS 26+ device or simulator

No API keys or tokens — Steddi uses Apple MapKit and the public OSRM demo server.

## Project Generation
The Xcode project is generated from `project.yml`:

```
git clone <repo>
cd steddi
xcodegen generate
```

Re-run `xcodegen generate` after any change to `project.yml`. All Info.plist entries (location usage strings, background modes, URL scheme, CarPlay scene configuration) are defined in `project.yml` — no manual plist editing needed.

## Signing
Code signing is Automatic. `project.yml` sets `DEVELOPMENT_TEAM` on all targets (Steddi, SteddiWidget, SteddiLiveActivity, SteddiTests) — change it to your own team ID if you're not the owner, then regenerate.

Entitlements in use:
- App Group `group.to.nathancurtis.steddi` (app, widget, live activity)
- CarPlay navigation (`com.apple.developer.carplay-maps`) — requires Apple approval; remove from `Steddi/Steddi.entitlements` if your account doesn't have it

## Building
1. Open `Steddi.xcodeproj` in Xcode
2. Select a device or simulator
3. Run the `Steddi` scheme

Or from the command line:

```
xcodebuild -project Steddi.xcodeproj -scheme Steddi -destination 'generic/platform=iOS Simulator' build
```

## Tests
- Swift: `SteddiTests` target (run via Xcode or `xcodebuild test`)
- Python: ports of the reroute engine and CarPlay state logic — `python3 -m pytest tests/ -v` from the project root
