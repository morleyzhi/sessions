#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p dist/swift-cache
swiftc -swift-version 5 -module-cache-path dist/swift-cache native/Models.swift native/Indexers.swift native/Store.swift test/native/Tests.swift -o dist/native-tests -framework AppKit -lsqlite3
dist/native-tests
swiftc -swift-version 5 -target "$(uname -m)-apple-macosx14.0" -module-cache-path dist/swift-cache native/Models.swift native/Indexers.swift native/Store.swift native/Appearance.swift native/SessionList.swift native/Markdown.swift native/TranscriptView.swift native/TimelineView.swift native/ContentView.swift test/native/ViewTests.swift -o dist/native-view-tests -framework AppKit -lsqlite3
dist/native-view-tests
