#!/usr/bin/env bash
#
# Simulated drive runner: build, install, and drive Steddi along a waypoint
# file in the iOS simulator, capturing timed screenshots.
#
# Usage: tests/sim/drive.sh [udid] [waypoints-file] [speed-m/s] [screenshot-dir]
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

UDID="${1:-892569A3-4378-41E6-850D-C275724E0466}"
WAYPOINTS="${2:-$REPO_ROOT/TestLocations/victoria_offroute_drive.waypoints}"
SPEED="${3:-15}"
SHOT_DIR="${4:-/tmp/steddi-run}"

BUNDLE_ID="to.nathancurtis.steddi"
DERIVED_DATA="/tmp/steddi-dd"
APP_PATH="$DERIVED_DATA/Build/Products/Debug-iphonesimulator/Steddi.app"

[[ -f "$WAYPOINTS" ]] || { echo "waypoints file not found: $WAYPOINTS" >&2; exit 1; }

WAYPOINT_ARGS=()
while IFS= read -r line; do
    [[ -z "$line" || "$line" == \#* ]] && continue
    WAYPOINT_ARGS+=("$line")
done < "$WAYPOINTS"
[[ ${#WAYPOINT_ARGS[@]} -ge 2 ]] || { echo "need at least 2 waypoints" >&2; exit 1; }

cleanup() {
    xcrun simctl location "$UDID" clear || true
    xcrun simctl terminate "$UDID" "$BUNDLE_ID" 2>/dev/null || true
}
trap cleanup EXIT

# Sleep for a duration tuned to the default 15 m/s, rescaled for actual speed.
drive_sleep() {
    sleep "$(awk -v t="$1" -v s="$SPEED" 'BEGIN { printf "%d", (t * 15 / s) + 0.5 }')"
}

shot() {
    xcrun simctl io "$UDID" screenshot "$SHOT_DIR/$1.png"
    echo "screenshot: $SHOT_DIR/$1.png"
}

mkdir -p "$SHOT_DIR"

echo "== boot $UDID"
xcrun simctl bootstatus "$UDID" -b

echo "== build"
xcodebuild -project "$REPO_ROOT/Steddi.xcodeproj" -scheme Steddi \
    -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath "$DERIVED_DATA" build -quiet

echo "== install + prep"
xcrun simctl install "$UDID" "$APP_PATH"
xcrun simctl privacy "$UDID" grant location-always "$BUNDLE_ID"
xcrun simctl spawn "$UDID" defaults write "$BUNDLE_ID" hasCompletedOnboarding -bool true
# Pre-approve the steddi:// scheme so `simctl openurl` doesn't hang on the
# "Open in Steddi?" SpringBoard confirmation (appears on iOS 18.4+ runtimes).
xcrun simctl spawn "$UDID" defaults write com.apple.launchservices.schemeapproval \
    "com.apple.CoreSimulator.CoreSimulatorBridge-->steddi" -string "$BUNDLE_ID"
xcrun simctl location "$UDID" set "${WAYPOINT_ARGS[0]}"

echo "== launch + start navigation"
xcrun simctl terminate "$UDID" "$BUNDLE_ID" 2>/dev/null || true
xcrun simctl launch "$UDID" "$BUNDLE_ID"
xcrun simctl openurl "$UDID" "steddi://navigate?lat=33.97774&lng=-117.37601&name=Victoria%20Test"
sleep 12

echo "== drive: ${#WAYPOINT_ARGS[@]} waypoints at ${SPEED} m/s"
xcrun simctl location "$UDID" start --speed="$SPEED" --interval=1 "${WAYPOINT_ARGS[@]}"

drive_sleep 5
shot 01-nav-start
drive_sleep 55
shot 02-mid-drive
drive_sleep 80
shot 03-off-route
drive_sleep 50
shot 04-post-reroute
drive_sleep 90

xcrun simctl openurl "$UDID" "steddi://arrive"
sleep 3
shot 05-arrival

echo "== done"
