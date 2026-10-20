import Foundation
import SQLite3

func json(_ data: Data) -> Any? { try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) }
func jsonFile(_ path: String) -> [String: Any] { (try? Data(contentsOf: URL(fileURLWithPath: path))).flatMap { json($0) as? [String: Any] } ?? [:] }

// Read one event at a time, including a final line without a newline.
func readLines(_ path: String, _ body: (Data) -> Bool) {
    guard let file = fopen(path, "r") else { return }
    defer { fclose(file) }
    var line: UnsafeMutablePointer<CChar>?
    var capacity = 0
    defer { free(line) }
    while true {
        let count = getline(&line, &capacity, file)
        if count < 0 { break }
        if !body(Data(bytes: line!, count: count)) { break }
    }
}

final class TranscriptReader {
    let home: String
    private let fractional = ISO8601DateFormatter()
    private let whole = ISO8601DateFormatter()
    init(home: String = NSHomeDirectory()) {
        self.home = home
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }
    func time(_ value: Any?) -> Double? {
        guard let value = value as? String, let date = fractional.date(from: value) ?? whole.date(from: value) else { return nil }
        return date.timeIntervalSince1970 * 1000
    }
    func titles() -> [String: String] {
        var result: [String: String] = [:]
        readLines(home + "/.codex/session_index.jsonl") { data in
            if let event = json(data) as? [String: Any], let id = event["id"] as? String, let title = event["thread_name"] as? String { result[id] = title }
            return true
        }
        return result
    }
    func targets() -> [(String, String)] {
        var result: [(String, String)] = []
        let fm = FileManager.default
        let claude = home + "/.claude/projects"
        for project in (try? fm.contentsOfDirectory(atPath: claude)) ?? [] {
            for file in (try? fm.contentsOfDirectory(atPath: claude + "/" + project)) ?? [] where file.hasSuffix(".jsonl") {
                result.append(("claude", claude + "/" + project + "/" + file))
            }
        }
        let codex = home + "/.codex/sessions"
        if let files = fm.enumerator(atPath: codex) {
            for case let file as String in files where file.hasSuffix(".jsonl") { result.append(("codex", codex + "/" + file)) }
        }
        let cursor = home + "/.cursor/chats"
        for workspace in (try? fm.contentsOfDirectory(atPath: cursor)) ?? [] {
            for chat in (try? fm.contentsOfDirectory(atPath: cursor + "/" + workspace)) ?? [] {
                let dir = cursor + "/" + workspace + "/" + chat
                if fm.fileExists(atPath: dir + "/store.db") { result.append(("cursor", dir)) }
            }
        }
        return result
    }
    func parse(tool: String, path: String, titles: [String: String] = [:]) -> Session? {
        let source = tool == "cursor" ? path + "/store.db" : path
        guard let stats = try? FileManager.default.attributesOfItem(atPath: source) else { return nil }
        var id = (path as NSString).lastPathComponent.replacingOccurrences(of: ".jsonl", with: "")
        if tool == "codex" { id = replace(#"^rollout-\d{4}-\d{2}-\d{2}T[\d-]+-"#, id) }
        var cwd = "", branch = "", messageCwd = "", title = "", customTitle = ""
        var started: Double?, updated: Double?
        var sidechain = false, guardian = false
        var messages: [Message] = []
        var prTitles: [String: String] = [:]
        var tokenSamples: [TokenSample] = []
        var generationStart: Double?
        var model = "Unknown model", effort = "Unknown effort"
        var totalOutput = 0
        var claudeUsage: [String: Int] = [:]
        func recordUsage(_ tokens: Int, _ stamp: Double?) {
            guard tokens > 0, let end = stamp, let start = generationStart, end > start, end - start <= 30 * 60000 else { return }
            tokenSamples.append(TokenSample(start: start, end: end, tokens: tokens, harness: tool, model: model, effort: effort))
        }
        if tool == "cursor" {
            let meta = jsonFile(path + "/meta.json")
            title = meta["title"] as? String ?? ""; cwd = meta["cwd"] as? String ?? ""
            started = meta["createdAtMs"] as? Double; updated = meta["updatedAtMs"] as? Double
            messages = cursorMessages(source)
        } else {
            readLines(path) { data in
                autoreleasepool {
                    guard let event = json(data) as? [String: Any] else { return true }
                    let type = event["type"] as? String ?? ""
                    let stamp = self.time(event["timestamp"])
                    if let stamp { started = min(started ?? stamp, stamp); updated = max(updated ?? stamp, stamp) }
                    if data.range(of: Data("github.com/".utf8)) != nil || (data.range(of: Data("title".utf8)) != nil && data.range(of: Data("number".utf8)) != nil) { collectPRTitles(event, &prTitles) }
                    if tool == "claude" {
                        let message = event["message"] as? [String: Any] ?? [:]
                        if type == "user", let stamp { generationStart = stamp }
                        if type == "assistant" {
                            model = message["model"] as? String ?? "Unknown model"
                            effort = event["effort"] as? String ?? event["perTurnEffort"] as? String ?? "Unknown effort"
                            let usage = message["usage"] as? [String: Any] ?? [:]
                            let tokens = usage["output_tokens"] as? Int ?? 0
                            let messageID = message["id"] as? String ?? event["uuid"] as? String ?? ""
                            if let index = claudeUsage[messageID] {
                                tokenSamples[index].tokens = max(tokenSamples[index].tokens, tokens)
                                if let stamp { tokenSamples[index].end = max(tokenSamples[index].end, stamp) }
                            } else {
                                let count = tokenSamples.count
                                recordUsage(tokens, stamp)
                                if tokenSamples.count > count { claudeUsage[messageID] = count; generationStart = stamp }
                            }
                        }
                        if cwd.isEmpty { cwd = event["cwd"] as? String ?? "" }
                        if type == "ai-title", let value = event["aiTitle"] as? String { title = value }
                        if type == "custom-title", let value = event["customTitle"] as? String { customTitle = value }
                        guard ["user", "assistant"].contains(type), event["isMeta"] as? Bool != true else { return true }
                        let text = trimmed(extractContent((event["message"] as? [String: Any])?["content"]))
                        if text.isEmpty || ["<local-command-caveat>", "<command-name>", "<command-message>", "Caveat: The messages below"].contains(where: { text.hasPrefix($0) }) { return true }
                        messages.append(Message(role: type, text: text, timestamp: stamp, cwd: event["cwd"] as? String ?? cwd, branch: event["gitBranch"] as? String ?? "", isSidechain: event["isSidechain"] as? Bool ?? false, toolCalls: isToolOnly(text) ? toolCalls(text) : nil))
                    } else {
                        let payload = event["payload"] as? [String: Any] ?? [:]
                        if type == "session_meta" {
                            let subagent = (payload["source"] as? [String: Any])?["subagent"] as? [String: Any]
                            guardian = subagent?["other"] as? String == "guardian" || payload["thread_source"] as? String == "guardian_review"
                            if guardian { return false }
                            id = payload["id"] as? String ?? payload["session_id"] as? String ?? id
                            sidechain = (payload["source"] as? [String: Any])?["subagent"] != nil || payload["source"] as? String == "subagent"
                            cwd = payload["cwd"] as? String ?? ""; messageCwd = cwd
                            branch = (payload["git"] as? [String: Any])?["branch"] as? String ?? ""
                        }
                        if type == "turn_context" {
                            messageCwd = payload["cwd"] as? String ?? messageCwd
                            model = payload["model"] as? String ?? "Unknown model"
                            effort = payload["effort"] as? String ?? payload["reasoning_effort"] as? String ?? "Unknown effort"
                            generationStart = stamp
                        }
                        if type == "event_msg", payload["type"] as? String == "task_started" { generationStart = stamp }
                        if type == "event_msg", payload["type"] as? String == "token_count",
                           let info = payload["info"] as? [String: Any], let usage = info["total_token_usage"] as? [String: Any],
                           let output = usage["output_tokens"] as? Int {
                            // Cumulative usage repeats after replies; count each increase once.
                            if output > totalOutput { recordUsage(output - totalOutput, stamp); generationStart = stamp }
                            totalOutput = max(totalOutput, output)
                        }
                        if type == "response_item", ["function_call_output", "custom_tool_call_output"].contains(payload["type"] as? String ?? "") { generationStart = stamp }
                        guard type == "response_item" else { return true }
                        if payload["type"] as? String == "function_call" {
                            let argument = payload["arguments"] as? String ?? ""
                            let input = json(Data(argument.utf8)) ?? argument
                            let text = toolMarker(payload["name"] as? String ?? "unknown", input)
                            messages.append(Message(role: "assistant", text: text, timestamp: stamp, toolCalls: toolCalls(text)))
                        } else if payload["type"] as? String == "message", let role = payload["role"] as? String, ["user", "assistant"].contains(role) {
                            let text = trimmed(extractContent(payload["content"]))
                            if text.isEmpty || ["# AGENTS.md instructions", "<user_instructions>", "<environment_context>", "<skills_instructions>"].contains(where: { text.hasPrefix($0) }) { return true }
                            messages.append(Message(role: role, text: text, timestamp: stamp, cwd: messageCwd, branch: branch, isSidechain: sidechain, toolCalls: isToolOnly(text) ? toolCalls(text) : nil))
                        }
                    }
                    return true
                }
            }
        }
        if guardian { return nil }
        let main = tool == "claude" ? messages.filter { !$0.isSidechain } : messages
        let prompt = prefixUTF16(collapse(main.first(where: { $0.role == "user" && $0.text.utf16.count > 2 })?.text ?? ""), 120)
        if tool == "codex" { title = titles[id] ?? "" }
        if !customTitle.isEmpty { title = customTitle }
        if title.isEmpty { title = prompt.isEmpty ? "Untitled session" : prompt }
        let birth = (stats[.creationDate] as? Date ?? Date()).timeIntervalSince1970 * 1000
        let modified = (stats[.modificationDate] as? Date ?? Date()).timeIntervalSince1970 * 1000
        let last = main.last(where: { $0.timestamp != nil && !isToolOnly($0.text) })?.timestamp
        var search = ""
        for message in main { if search.utf16.count >= 40000 { break }; search += message.text + "\n" }
        var session = Session(id: id, tool: tool, title: title, cwd: cwd, filePath: path, startedAt: started ?? birth, updatedAt: tool == "cursor" ? updated ?? modified : last ?? updated ?? modified, messageCount: main.count, preview: collapse(prompt), searchText: prefixUTF16(search, 40000), prTitles: resolvePRTitles(prTitles), messages: messages)
        session.tokenSamples = tokenSamples
        (session.timeline, session.untimed) = makeTimeline(session)
        return session
    }
}

func collectPRTitles(_ value: Any, _ titles: inout [String: String], depth: Int = 0) {
    guard depth <= 12 else { return }
    if let object = value as? [String: Any] {
        if let title = object["title"] as? String, !trimmed(title).isEmpty {
            if let url = object["url"] as? String, let pr = matches("^" + prPattern, url).first?.first { titles[pr] = trimmed(title) }
            else if let number = object["number"] as? Int { titles["#\(number)"] = trimmed(title) }
        }
        for child in object.values { collectPRTitles(child, &titles, depth: depth + 1) }
    } else if let array = value as? [Any] {
        for child in array { collectPRTitles(child, &titles, depth: depth + 1) }
    } else if let text = value as? String, text.contains("github.com/") || (text.contains("\"title\"") && text.contains("\"number\"")) {
        for match in matches(#"https://github\.com/([\w.-]+/[\w.-]+)/pull/\d+"#, text) { titles["repo:" + match[1]] = "" }
        for match in matches(#"\[([^\]\n]+)\]\((https://github\.com/[\w.-]+/[\w.-]+/pull/\d+)[^\s)]*\)"#, text) {
            let label = trimmed(replace("[*`]", match[1]))
            if matches(#"(?i)^(?:(?:draft\s+)?(?:pr|pull request)\s*)?#?\d+$|^https?:|^(?:here|link|pr|pull request|draft pr|view pr)$"#, label).isEmpty, titles[match[2]] == nil { titles[match[2]] = label }
        }
        if let first = text.firstIndex(where: { $0 == "[" || $0 == "{" }), let last = text.lastIndex(where: { $0 == "]" || $0 == "}" }), first < last, let child = json(Data(text[first...last].utf8)) { collectPRTitles(child, &titles, depth: depth + 1) }
    }
}
func resolvePRTitles(_ titles: [String: String]) -> [String: String] {
    let repos = titles.keys.filter { $0.hasPrefix("repo:") }
    var result: [String: String] = [:]
    for (key, title) in titles {
        if key.hasPrefix("https:") { result[key] = title }
        else if key.hasPrefix("#"), repos.count == 1 { result["https://github.com/\(repos[0].dropFirst(5))/pull/\(key.dropFirst())"] = title }
    }
    return result
}

func protobufStrings(_ bytes: [UInt8], depth: Int = 0) -> [String] {
    var position = 0, result: [String] = []
    func varint() -> UInt64? {
        var value: UInt64 = 0
        for shift in stride(from: 0, through: 63, by: 7) {
            guard position < bytes.count else { return nil }
            let byte = bytes[position]; position += 1
            if shift == 63 && byte > 1 { return nil }
            value |= UInt64(byte & 127) << shift
            if byte & 128 == 0 { return value }
        }
        return nil
    }
    while position < bytes.count {
        guard let tag = varint() else { break }
        switch tag & 7 {
        case 0: if varint() == nil { return result }
        case 1: position += 8
        case 5: position += 4
        case 2:
            guard let length = varint(), length <= UInt64(bytes.count - position) else { return result }
            let end = position + Int(length), chunk = Array(bytes[position..<end])
            if let text = String(bytes: chunk, encoding: .utf8), chunk.count >= 2, Double(text.unicodeScalars.filter { $0.value >= 32 || [9, 10, 13].contains($0.value) }.count) / Double(max(1, text.unicodeScalars.count)) > 0.95 { result.append(text) }
            else if depth < 8 { result += protobufStrings(chunk, depth: depth + 1) }
            position = end
        default: return result
        }
    }
    return result
}
func cursorMessages(_ path: String) -> [Message] {
    var db: OpaquePointer?
    guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { if db != nil { sqlite3_close(db) }; return [] }
    defer { sqlite3_close(db) }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, "select data from blobs where length(data) < 2000000 order by rowid", -1, &statement, nil) == SQLITE_OK else { return [] }
    defer { sqlite3_finalize(statement) }
    var seen = Set<String>(), messages: [Message] = []
    while sqlite3_step(statement) == SQLITE_ROW {
        guard let pointer = sqlite3_column_blob(statement, 0) else { continue }
        let data = Data(bytes: pointer, count: Int(sqlite3_column_bytes(statement, 0)))
        let strings = data.first == 0x7b ? [String(decoding: data, as: UTF8.self)] : protobufStrings(Array(data))
        for text in strings {
            guard let blob = json(Data(trimmed(text).utf8)) as? [String: Any], let role = blob["role"] as? String, ["user", "assistant"].contains(role) else { continue }
            var content = trimmed(extractContent(blob["content"]))
            let queries = matches(#"<user_query>([\s\S]*?)</user_query>"#, content).map { trimmed($0[1]) }.filter { !$0.isEmpty }
            if !queries.isEmpty { content = queries.joined(separator: "\n\n") }
            else { while !matches(#"^<([a-z_]+)>[\s\S]*?</\1>\s*"#, content).isEmpty { content = trimmed(replace(#"^<([a-z_]+)>[\s\S]*?</\1>\s*"#, content)) } }
            if content.isEmpty || ["<user_info>", "<user_rules>", "<project_layout>", "<rules>", "<environment_details>"].contains(where: { content.hasPrefix($0) }) { continue }
            let key = blob["id"] as? String ?? prefixUTF16(content, 300)
            if seen.insert(key).inserted { messages.append(Message(role: role, text: content, timestamp: nil, toolCalls: isToolOnly(content) ? toolCalls(content) : nil)) }
        }
    }
    return messages
}
