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

## Simulated drives

`tests/sim/drive.sh` runs an end-to-end drive in the simulator: builds the app, installs it, grants location permission, skips onboarding, starts navigation via `steddi://navigate`, then plays back a waypoint file with `simctl location start` while capturing timed screenshots.

```bash
tests/sim/drive.sh [udid] [waypoints-file] [speed-m/s] [screenshot-dir]

# Defaults: udid 892569A3-..., victoria_offroute_drive.waypoints, 15 m/s, /tmp/steddi-run
tests/sim/drive.sh
```

Waypoint files live in `TestLocations/` (one `lat,lon` per line):
- `victoria_clean_drive.waypoints` — home to Victoria Ave NW end, on-corridor
- `victoria_offroute_drive.waypoints` — same drive with a ~150m+ deviation mid-drive, then rejoin (exercises off-route detection and reroute)
- `victoria_short_smoke.waypoints` — first ~1km only, for quick smoke runs

Screenshots land in the screenshot dir as `01-nav-start` through `05-arrival`. Arrival is forced at the end via `steddi://arrive`.
