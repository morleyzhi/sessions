#!/bin/bash
# Build Sessions.app, replace any installed copy, and reopen it.
set -euo pipefail

BUILT="dist/Sessions-darwin-arm64/Sessions.app"
INSTALLED="/Applications/Sessions.app"

npm run package

# A build that dropped our source produces Electron's default welcome window
# instead of the app, so refuse to install one.
if [ ! -f "$BUILT/Contents/Resources/app/src/main.js" ]; then
  echo "Build is missing src/main.js. Delete node_modules and dist, then run npm install again." >&2
  exit 1
fi

pkill -f '/Applications/Sessions[.]app' || true
sleep 1
rm -rf "$INSTALLED"
cp -R "$BUILT" /Applications/
xattr -dr com.apple.quarantine "$INSTALLED"
open -a "$INSTALLED"
echo "Installed $(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$INSTALLED/Contents/Info.plist")"
