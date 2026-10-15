# Working in this repo

Sessions is a native macOS app built with SwiftUI and AppKit. `native/App.swift`
contains the app lifecycle and session list, `native/Indexers.swift` reads local
transcripts, `native/Store.swift` indexes and searches them off the main thread,
and the transcript and timeline views live in their own Swift files. Build with
`bash scripts/build-native.sh`; run tests with `bash scripts/test-native.sh`.
There are no package dependencies. npm scripts wrap the shell scripts.
The previous Electron source in `src/` remains as a reference and is not shipped.

## After each change

Run all three, in order, every time:

```bash
npm run install-app
git add -A && git commit -m "<what the change does>"
git push origin main
```

`npm run install-app` packages the app and replaces the copy in `/Applications`, so
the running app picks the change up. A change that is not installed is not testable.

## Commit messages

One line, present tense, naming the behavior a user sees — "Show the name you gave a
session with /rename", not "Add customTitle handling". No body unless the change needs
one.

## Branches

Work on `main` unless asked otherwise. A new branch is named `mz-<topic>`.

## Changing an indexer

`native/Store.swift` caches parsed summaries by `native-v1:mtime:size`, including
Cursor metadata and SQLite WAL changes. If a parser change alters a summary for
an unchanged transcript, bump the fingerprint prefix to invalidate old summaries.
Codex title changes are applied on every refresh without reparsing transcripts.
