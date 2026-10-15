# Sessions

A native macOS app for browsing, searching, and resuming Claude Code, Codex CLI, and Cursor sessions. Built with SwiftUI, AppKit, Foundation, and the system SQLite library. Requires macOS 14 or later.

Transcripts stay on your machine. Sessions reads local files and makes no network requests. Links you click open in your default browser.

## Install

Install Xcode or the Xcode command line tools, then run:

```bash
bash scripts/install-app.sh
```

The script builds an optimized `dist/Sessions.app`, installs it in `/Applications`, and opens it. Node and npm are optional conveniences; `npm run install-app` runs the same installer. There are no package dependencies.

To build without installing:

```bash
bash scripts/build-native.sh
open dist/Sessions.app
```

To run the native tests:

```bash
bash scripts/test-native.sh
```

## Features

- Browse sessions by tool, project, and last conversation time; saved Claude and Codex names appear as session titles.
- Search titles, working directories, and the first 40,000 UTF-16 code units of conversation text. Every term must match; double quotes keep a phrase together.
- Read complete transcripts with selectable text, Markdown, code, tables, foldable turns, and tool summaries. Subagent messages appear dimmed.
- Find text in an open transcript with ⌘F. Use ⌘⇧F to search all sessions.
- Pin sessions to the top. Pins from the Electron app carry over automatically.
- Copy resume commands or drag a session into a terminal to paste its command with a trailing newline.
- Right-click sessions to copy their title, ID, working directory, command, or transcript path, or reveal their transcript in Finder.
- See which sessions belong to a running CLI. The index and live indicators refresh every three seconds; disk reading and search run off the main thread.
- Explore activity on a timeline grouped by project, branch, or PR. Zoom, jump to dates, exclude reviews, and click prompts to open their transcripts. Idle periods longer than 15 minutes collapse to labeled strips.

## Local data

| Tool | Location | Format |
| --- | --- | --- |
| Claude | `~/.claude/projects/<project>/<uuid>.jsonl` | JSON events; custom titles take precedence over generated titles |
| Codex | `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` | JSON events; titles from `~/.codex/session_index.jsonl` |
| Cursor | `~/.cursor/chats/<workspace>/<chat>/store.db` | Read-only SQLite; metadata from the adjacent `meta.json` |

The cache and pins live in `~/Library/Application Support/sessions/`. The native app uses `native-index-v1.json` and leaves the previous app's cache intact.

Cursor messages are reconstructed from embedded JSON in protobuf blobs. Encrypted messages and attachments are not recovered. Cursor messages have no timestamps; Sessions preserves their database insertion order and omits them from the timeline. Sessions with no readable messages are omitted from the list.

## Source

```
native/
  App.swift             App lifecycle, session list, filters, menus
  Models.swift          Session types, content extraction, timeline grouping and scale
  Indexers.swift        Streaming Claude/Codex readers and read-only Cursor SQLite reader
  Store.swift           Background indexing, cache, search, pins, live CLI detection
  TranscriptView.swift  Native transcript, Markdown, find, fold and expand controls
  TimelineView.swift    AppKit drawing view with visible activity rows
scripts/
  build-native.sh       Compile and sign the app bundle
  install-app.sh        Install and launch the app
  make-icon.swift       Draw the app icon
  test-native.sh        Compile and run native tests
```

The build invokes `swiftc` directly; there are no downloaded packages or generated Xcode projects. The previous Electron implementation in `src/` and its JavaScript tests remain as a reference; they are not included in the native app bundle.
