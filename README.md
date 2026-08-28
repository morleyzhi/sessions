# Sessions

A local desktop app that lists, searches, and displays your Claude Code, Codex CLI, and Cursor session history, and copies the command to resume any session in iTerm2.

Everything runs on your machine. The app makes no network requests, has no auto-updater, and has one dependency: Electron.

## Run it

```bash
git clone https://github.com/morleyzhi/sessions.git
cd sessions
npm install
npm start
```

The first launch indexes every session it finds and caches the result in
`~/Library/Application Support/sessions/index.json`. Later launches read the cache and
only re-parse files whose size or modification time changed.

## What it does

1. **List** — every session across the three tools, newest first, with the project name, message count, and relative time. Filter by tool with the buttons at the top of the sidebar.
2. **Search** — substring match across titles, working directories, and message text. All terms must match. Results show a highlighted snippet.
3. **View** — the full transcript, user and assistant turns, with Claude Code subagent messages dimmed.
4. **Copy resume command** — puts the right command on your clipboard. Paste it into iTerm2 and press Enter.

The resume commands are:

| Tool | Command |
| --- | --- |
| Claude Code | `cd <cwd> && claude --resume <id>` |
| Codex | `cd <cwd> && codex resume <id>` |
| Cursor | `cd <cwd> && cursor-agent --resume=<id>` |

## Where the data comes from

| Tool | Location | Format |
| --- | --- | --- |
| Claude Code | `~/.claude/projects/<project>/<uuid>.jsonl` | One JSON event per line. Titles come from the `ai-title` event. |
| Codex | `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` | One JSON event per line. Titles come from `~/.codex/session_index.jsonl`. |
| Cursor | `~/.cursor/chats/<workspace>/<chat>/store.db` | SQLite. Titles and working directory come from the sibling `meta.json`. |

All files are opened read-only. The Cursor database is read through `/usr/bin/sqlite3`
with the `-readonly` flag, which keeps the app free of native modules.

## Known limits

- **Cursor transcripts are reconstructed, not read directly.** Cursor stores each turn in a
  content-addressed blob store where most blobs are protobuf, and some are encrypted with a
  key in `meta.json`. `src/indexers/protobuf.js` walks the protobuf wire format and pulls out
  the embedded JSON messages, which recovers the user and assistant turns but not tool calls
  or attachments. Expect a Cursor transcript to be less complete than a Claude or Codex one.
- **Cursor messages have no timestamps**, so they are ordered by insertion order, which
  matches conversation order in practice but is not guaranteed.
- Message text is capped at 40 KB per session for the search index. Long sessions are
  searchable up to that point; the transcript view always shows everything.
- Sessions with no readable messages are skipped rather than listed as empty.

## Layout

```
src/
  main.js              Electron main process, IPC handlers, clipboard
  preload.js           contextBridge surface exposed to the renderer
  indexers/
    index.js           Builds and caches the combined index
    claude.js          ~/.claude/projects reader
    codex.js           ~/.codex/sessions reader
    cursor.js          ~/.cursor/chats reader
    protobuf.js        Minimal protobuf wire-format string scanner
    text.js            Shared content extraction
  renderer/            index.html, styles.css, renderer.js
```

The renderer has no build step and no framework, so what you read is what runs.
