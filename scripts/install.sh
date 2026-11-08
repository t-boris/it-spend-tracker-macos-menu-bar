#!/bin/zsh
# Builds a Release copy, installs it to /Applications, relaunches it and registers it as a login item (DEC-037).
set -e
cd "$(dirname "$0")/.."
APP="/Applications/IT Spend Tracker.app"
xcodegen generate --quiet
xcodebuild -project ITSpendTracker.xcodeproj -scheme ITSpendTracker -configuration Release -derivedDataPath build build 2>&1 \
  | grep -E "error:|BUILD" | sort -u
BUILT="build/Build/Products/Release/ITSpendTracker.app"
[ -d "$BUILT" ] || { echo "build failed"; exit 1; }
pkill -x ITSpendTracker 2>/dev/null || true
sleep 1
rm -rf "$APP"
ditto "$BUILT" "$APP"
open "$APP"
echo "Installed to $APP and launched. Launch at login is enabled on first launch; change it in Settings → Startup."
