#!/bin/bash
# Build Sessions.app, replace the installed copy, and reopen it.
set -euo pipefail
cd "$(dirname "$0")/.."
BUILT="dist/Sessions.app"
INSTALLED="/Applications/Sessions.app"
bash scripts/build-native.sh
if [ ! -x "$BUILT/Contents/MacOS/Sessions" ] || [ -d "$BUILT/Contents/Frameworks/Electron Framework.framework" ]; then
  echo "The build does not contain the native Sessions executable." >&2
  exit 1
fi
pkill -f '/Applications/Sessions[.]app' || true
sleep 1
# Keep the installed app until the replacement is completely copied.
STAGED="$(mktemp -d /Applications/.sessions-install.XXXXXX)"
trap 'rm -rf "$STAGED"' EXIT
cp -R "$BUILT" "$STAGED/Sessions.app"
xattr -dr com.apple.quarantine "$STAGED/Sessions.app"
rm -rf "$INSTALLED"
mv "$STAGED/Sessions.app" "$INSTALLED"
open -a "$INSTALLED"
echo "Installed $(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$INSTALLED/Contents/Info.plist")"
