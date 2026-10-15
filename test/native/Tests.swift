import Foundation
import SQLite3

@main struct NativeTests {
    static func main() throws {
        var count = 0
        func check(_ name: String, _ condition: @autoclosure () -> Bool) {
            guard condition() else { fatalError("FAIL: \(name)") }; count += 1
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sessions-native-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func write(_ relative: String, _ events: [[String: Any]]) throws -> String {
            let path = root.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            let lines = try events.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }.joined(separator: "\n")
            try Data(lines.utf8).write(to: path)
            return path.path
        }
        let reader = TranscriptReader(home: root.path)
        let start = 1_000_000_000.0
        func user(_ minute: Double, _ branch: String = "", sidechain: Bool = false) -> Message { Message(role: "user", text: "Work on this", timestamp: start + minute * 60000, cwd: "/projects/sessions", branch: branch, isSidechain: sidechain) }
        func assistant(_ minute: Double, _ text: String = "Done") -> Message { Message(role: "assistant", text: text, timestamp: start + minute * 60000) }
        func session(_ messages: [Message]) -> Session {
            Session(id: "one", tool: "claude", title: "Work", cwd: "/projects/sessions", filePath: "", startedAt: start, updatedAt: start, messageCount: messages.count, preview: "", searchText: "", messages: messages)
        }
        let tools = Message(role: "user", text: "[tool result]", timestamp: start, toolCalls: [])
        let (rows, _) = makeTimeline(session([user(0), tools, assistant(1), user(2)]))
        check("Prompts retain their message numbers", rows.map(\.messageIndex) == [0, 3])
        check("Replies extend recorded activity", rows[0].end == start + 60000)
        var missing = user(0); missing.timestamp = nil
        check("Untimed prompts have no invented date", makeTimeline(session([missing, user(1)])).1 == 1)
        check("Long silences end at the earlier reply", makeTimeline(session([user(0), assistant(2), assistant(90)])).0[0].end == start + 120000)
        let pr = "https://github.com/example/sessions/pull/12"
        let branchRows = makeTimeline(session([user(0, "mz-test"), assistant(1), user(2, "mz-test"), assistant(3, "Opened " + pr)])).0
        check("Earlier prompts on a branch share its PR", branchRows.map(\.lane) == [pr, pr])
        check("Several PRs keep project attribution", makeTimeline(session([user(0), assistant(1, pr + " https://github.com/example/a/pull/1")])).0[0].kind == "Session project")
        check("Subagent prompts stay off the timeline", makeTimeline(session([user(0), user(1, sidechain: true), assistant(2)])).0.count == 1)
        var titles: [String: String] = [:]
        collectPRTitles(["payload": ["output": "Process exited\n{\"title\":\"Show work by hour\",\"url\":\"\(pr)\"}"]], &titles)
        check("Saved GitHub output supplies titles", titles[pr] == "Show work by hour")
        titles = [:]; collectPRTitles("[Show work by hour](\(pr))", &titles)
        check("Named PR links supply titles", titles[pr] == "Show work by hour")
        titles = [:]; collectPRTitles("[PR #12](\(pr))", &titles)
        check("PR numbers are not titles", resolvePRTitles(titles).isEmpty)
        collectPRTitles("{\"number\":12,\"title\":\"Show work by hour\"}", &titles)
        check("PR numbers use the recorded repository", resolvePRTitles(titles)[pr] == "Show work by hour")
        collectPRTitles("https://github.com/example/other/pull/1", &titles)
        check("PR numbers do not guess a repository", resolvePRTitles(titles).isEmpty)
        var review = session([]); review.preview = "In a worktree, review this PR for correctness"
        check("Review requests hide followups", review.isReview)
        review.title = "Review PR 123"; review.preview = pr
        check("Review titles identify link-only requests", review.isReview)
        review.preview = "Address the review comments on this PR"
        check("Addressing review comments stays visible", !review.isReview)
        review.preview = "Implement this feature then review it"
        check("Implementation stays visible", !review.isReview)
        let now = 1000 * 60000.0
        func row(_ ago: Double, _ endAgo: Double? = nil) -> TimelineRow { TimelineRow(messageIndex: 0, timestamp: now - ago * 60000, end: now - (endAgo ?? ago) * 60000, text: "", cwd: "", branch: "") }
        let scale = TimeScale(rows: [row(5), row(90)], now: now, pixelsPerMS: 10 / 60000)
        check("Lunch gaps collapse to 44 points", scale.segments.filter(\.gap).first.map { $0.bottom - $0.top } == 44)
        check("Time after lunch retains its position", scale.y(at: now - 90 * 60000) == 114)
        check("Overlapping work stays expanded", TimeScale(rows: [row(90, 30), row(40, 0)], now: now, pixelsPerMS: 10 / 60000).segments.filter(\.gap).isEmpty)
        check("Short pauses keep the selected zoom", TimeScale(rows: [row(5), row(15)], now: now, pixelsPerMS: 10 / 60000).y(at: now - 15 * 60000) == 150)
        for pixels in [2.0, 10, 40] {
            let scale = TimeScale(rows: [row(0), row(900)], now: now, pixelsPerMS: pixels / 60000)
            check("Zoom \(pixels) preserves time inside skips", [0.0, 1, 450, 899, 900].allSatisfy { abs(scale.time(at: scale.y(at: now - $0 * 60000)) - (now - $0 * 60000)) < 1 })
        }
        check("An empty timeline starts now", TimeScale(rows: [], now: now, pixelsPerMS: 1).time(at: 0) == now)
        let claude = try write(".claude/projects/demo/claude.jsonl", [
            ["type": "ai-title", "aiTitle": "Generated"], ["type": "custom-title", "customTitle": "My session"],
            ["type": "user", "cwd": "/tmp/project", "gitBranch": "mz-work", "timestamp": "2026-10-09T10:00:00Z", "message": ["content": "Find the issue"]],
            ["type": "assistant", "timestamp": "2026-10-09T10:01:00.000Z", "message": ["content": [["type": "text", "text": "Fixed"]]]],
            ["type": "assistant", "timestamp": "2026-10-09T10:02:00Z", "message": ["content": [["type": "tool_use", "name": "Bash", "input": ["command": "ls"]]]]],
            ["type": "user", "timestamp": "2026-10-09T10:03:00Z", "isSidechain": true, "message": ["content": "Review"]]
        ])
        let parsed = reader.parse(tool: "claude", path: claude)!
        check("Claude custom titles outrank generated titles", parsed.title == "My session")
        check("Claude main message counts exclude subagents", parsed.messageCount == 3)
        check("Claude transcripts preserve subagents", parsed.messages.count == 4)
        check("Tool calls do not change the last conversation time", parsed.updatedAt == reader.time("2026-10-09T10:01:00Z"))
        check("Tool summaries include the command", parsed.messages[2].toolCalls?.first == ToolCall(name: "Bash", summary: "ls"))
        let guardian = try write(".codex/sessions/guardian.jsonl", [["type": "session_meta", "payload": ["id": "approval", "source": ["subagent": ["other": "guardian"]]]], ["type": "response_item", "payload": ["type": "message", "role": "user", "content": "Review this action"]]])
        check("Guardian reviews stay out of history", reader.parse(tool: "codex", path: guardian) == nil)
        let codex = try write(".codex/sessions/2026/10/09/codex.jsonl", [
            ["type": "session_meta", "payload": ["id": "codex-id", "cwd": "/tmp/project", "git": ["branch": "mz-work"]]],
            ["type": "response_item", "timestamp": "2026-10-09T10:00:00Z", "payload": ["type": "message", "role": "user", "content": "# AGENTS.md instructions\nIgnore me"]],
            ["type": "response_item", "timestamp": "2026-10-09T10:01:00Z", "payload": ["type": "message", "role": "user", "content": [["type": "input_text", "text": "Build this app"]]]],
            ["type": "response_item", "timestamp": "2026-10-09T10:02:00Z", "payload": ["type": "function_call", "name": "exec_command", "arguments": "{\"command\":\"pwd\"}"]]
        ])
        _ = try write(".codex/session_index.jsonl", [["id": "codex-id", "thread_name": "Native app"]])
        let codexSession = reader.parse(tool: "codex", path: codex, titles: reader.titles())!
        check("Codex uses the session index title", codexSession.title == "Native app")
        check("Codex injected instructions stay out of messages", codexSession.messageCount == 2)
        check("Codex tool calls retain summaries", codexSession.messages[1].toolCalls?.first?.summary == "pwd")
        let chat = root.appendingPathComponent(".cursor/chats/workspace/chat")
        try FileManager.default.createDirectory(at: chat, withIntermediateDirectories: true)
        var db: OpaquePointer?
        sqlite3_open(chat.appendingPathComponent("store.db").path, &db)
        sqlite3_exec(db, "create table blobs(data blob)", nil, nil, nil)
        let cursorJSON = #"{"role":"user","content":"<user_query>Find the bug</user_query>","id":"cursor-message"}"#
        let bytes = Array(cursorJSON.utf8)
        let proto: [UInt8] = [0x0a, UInt8(bytes.count)] + bytes
        let hex = proto.map { String(format: "%02x", $0) }.joined()
        sqlite3_exec(db, "insert into blobs values(X'\(hex)'); insert into blobs values(X'\(hex)')", nil, nil, nil)
        sqlite3_close(db)
        let cursor = reader.parse(tool: "cursor", path: chat.path)!
        check("Cursor reads protobuf messages", cursor.messages.first?.text == "Find the bug")
        check("Cursor deduplicates stored messages", cursor.messages.count == 1)
        check("Malformed protobuf stops safely", protobufStrings([0x0a, 0xff, 0xff]).isEmpty)
        let cacheDir = root.appendingPathComponent("cache")
        let index = IndexStore(home: root.path, directory: cacheDir)
        let indexed = index.refresh()
        check("Index lists all three tools", Set(indexed.map(\.tool)) == Set(["claude", "codex", "cursor"]))
        check("Cache omits full transcripts", indexed.allSatisfy { $0.messages.isEmpty })
        check("Cached refresh preserves sessions", index.refresh() == indexed)
        _ = try write(".codex/session_index.jsonl", [["id": "codex-id", "thread_name": "Renamed session"]])
        check("Renames update without transcript changes", index.refresh().first(where: { $0.tool == "codex" })?.title == "Renamed session")
        let migrationDir = root.appendingPathComponent("migration")
        try FileManager.default.createDirectory(at: migrationDir, withIntermediateDirectories: true)
        var legacy = json(try JSONEncoder().encode(parsed)) as! [String: Any]
        legacy["title"] = "Saved title"
        legacy["timeline"] = ["rows": legacy["timeline"]!, "untimed": 0]
        legacy.removeValue(forKey: "messages")
        let attrs = try FileManager.default.attributesOfItem(atPath: claude)
        legacy["fingerprint"] = "v6:\((attrs[.modificationDate] as! Date).timeIntervalSince1970 * 1000):\(attrs[.size]!)"
        try JSONSerialization.data(withJSONObject: [claude: legacy]).write(to: migrationDir.appendingPathComponent("index.json"))
        let migrated = IndexStore(home: root.path, directory: migrationDir)
        check("Existing app summaries appear before scanning", migrated.cachedSessions().first?.title == "Saved title")
        check("Unchanged transcripts retain migrated summaries", migrated.refresh().first(where: { $0.tool == "claude" })?.title == "Saved title")
        check("Migrated summaries persist as a native cache", FileManager.default.fileExists(atPath: migrationDir.appendingPathComponent("native-index-v1.json").path))
        check("Emoji count consistently in search text", prefixUTF16("a😀bc", 4) == "a😀b")
        try FileManager.default.removeItem(atPath: claude)
        check("Deleted transcripts leave the index", index.refresh().count == 2)
        check("Quoted search phrases remain one term", queryTerms("Native \"Find the bug\"") == ["native", "find the bug"])
        check("Shell quoting keeps command substitutions literal", shellQuote("/tmp/$(touch bad)'x") == "'/tmp/$(touch bad)'\\''x'")
        print("\(count) tests passing")
    }
}
