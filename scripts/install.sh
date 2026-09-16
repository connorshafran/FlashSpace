#!/bin/bash
#
# Builds FlashSpace (Release), replaces /Applications/FlashSpace.app and relaunches it.
#
# The app is signed with a stable Apple Development certificate, so macOS keeps
# Accessibility and Screen Recording permissions across rebuilds.
#

set -euo pipefail
cd "$(dirname "$0")/.."

SIGNING_IDENTITY="Apple Development"
TEAM_ID="JMA3M8CC99"
BUNDLE_ID="pl.wojciechkulik.FlashSpace"
# Outside iCloud Drive, so build products aren't synced
DERIVED_DATA="$HOME/Library/Developer/Xcode/DerivedData/FlashSpace-Install"
BUILT_APP="$DERIVED_DATA/Build/Products/Release/FlashSpace.app"
INSTALLED_APP="/Applications/FlashSpace.app"

echo "Building FlashSpace..."
xcodebuild \
    -project FlashSpace.xcodeproj \
    -scheme FlashSpace \
    -configuration Release \
    -destination 'platform=macOS' \
    -derivedDataPath "$DERIVED_DATA" \
    -quiet \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="$SIGNING_IDENTITY" \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    build

echo "Quitting FlashSpace..."
# A regular quit lets FlashSpace move hidden Finder windows back on-screen
osascript -e "quit app id \"$BUNDLE_ID\"" 2>/dev/null || true
for _ in {1..50}; do
    pgrep -xq FlashSpace || break
    sleep 0.1
done

if pgrep -xq FlashSpace; then
    echo "FlashSpace is still running. Quit it and run this script again." >&2
    exit 1
fi

echo "Installing to $INSTALLED_APP..."
rm -rf "$INSTALLED_APP"
ditto "$BUILT_APP" "$INSTALLED_APP"

open "$INSTALLED_APP"
echo "Done."
