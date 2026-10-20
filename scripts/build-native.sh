#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
APP="dist/Sessions.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" dist/swift-cache
swiftc -O -whole-module-optimization -swift-version 5 -target "$(uname -m)-apple-macosx14.0" \
  -module-cache-path dist/swift-cache native/App.swift native/Models.swift native/Indexers.swift native/Store.swift native/Appearance.swift native/SessionList.swift native/Markdown.swift native/TranscriptView.swift native/TimelineView.swift native/TokensView.swift native/ContentView.swift -o "$APP/Contents/MacOS/Sessions" \
  -framework AppKit -lsqlite3
rm -rf "$APP/Contents/Resources/renderer"
swift -module-cache-path dist/swift-cache scripts/make-icon.swift dist/Sessions.iconset
iconutil -c icns dist/Sessions.iconset -o "$APP/Contents/Resources/Sessions.icns"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Sessions</string>
<key>CFBundleDisplayName</key><string>Sessions</string>
<key>CFBundleIdentifier</key><string>com.morleyzhi.sessions</string>
<key>CFBundleIconFile</key><string>Sessions.icns</string>
<key>CFBundleExecutable</key><string>Sessions</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>2.0.0</string>
<key>CFBundleVersion</key><string>2</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
echo "Built $APP"
