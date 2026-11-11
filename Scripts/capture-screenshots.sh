#!/usr/bin/env bash
# Captures App Store screenshots from a booted iOS simulator.
# Requires macOS + Xcode. Not run in this repository's environment.
set -euo pipefail
cd "$(dirname "$0")/.."

BUNDLE_ID="${BUNDLE_ID:-com.chromex.browser}"
OUT="${1:-screenshots}"
mkdir -p "$OUT"

echo "Booting simulator..."
xcrun simctl boot "iPhone 16 Pro" 2>/dev/null || true
open -a Simulator || true
sleep 5

echo "Building for the simulator..."
xcodebuild -project CHROMEX.xcodeproj -scheme CHROMEX -configuration Release \
  -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  -derivedDataPath build CODE_SIGNING_ALLOWED=NO build >/dev/null

APP="$(find build/Build/Products -name 'CHROMEX.app' -maxdepth 3 | head -1)"
[ -n "$APP" ] || { echo "app not found" >&2; exit 1; }

xcrun simctl install booted "$APP"
xcrun simctl launch booted "$BUNDLE_ID" || true
sleep 4
xcrun simctl io booted screenshot "$OUT/01-home.png"

# The remaining screens need navigation; drive them manually or with XCUITest.
echo "Captured $OUT/01-home.png. Navigate the app and screenshot with:"
echo "  xcrun simctl io booted screenshot $OUT/<name>.png"
