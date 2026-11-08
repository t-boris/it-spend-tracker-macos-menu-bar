#!/bin/zsh
# Builds (and optionally tests) the app quietly, printing only diagnostics and the result.
cd "$(dirname "$0")/.."
xcodegen generate --quiet
action=${1:-build}
xcodebuild -project ITSpendTracker.xcodeproj -scheme ITSpendTracker -configuration Debug -derivedDataPath build "$action" 2>&1 \
  | grep -vE "DVTPlugIn|CoreSimulator|DVTCoreDevice|No locator class|^\s*$" \
  | grep -E "error:|warning:|BUILD|TEST|Test Case .*failed|Executed|\*\*" | sort -u | head -80
