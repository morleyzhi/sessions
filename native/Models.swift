import Foundation

let prPattern = #"https://github\.com/[\w.-]+/[\w.-]+/pull/\d+"#
private let expressions = NSCache<NSString, NSRegularExpression>()

func expression(_ pattern: String) -> NSRegularExpression? {
    if let cached = expressions.object(forKey: pattern as NSString) { return cached }
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
    expressions.setObject(regex, forKey: pattern as NSString)
    return regex
}

func matches(_ pattern: String, _ text: String) -> [[String]] {
    guard let regex = expression(pattern) else { return [] }
    let source = text as NSString
    return regex.matches(in: text, range: NSRange(location: 0, length: source.length)).map { match in
        (0..<match.numberOfRanges).map { match.range(at: $0).location == NSNotFound ? "" : source.substring(with: match.range(at: $0)) }
    }
}

func replace(_ pattern: String, _ text: String, _ replacement: String = "") -> String {
    expression(pattern)?.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: text.utf16.count), withTemplate: replacement) ?? text
}
func prefixUTF16(_ text: String, _ count: Int) -> String { String(decoding: text.utf16.prefix(count), as: UTF16.self) }
func collapse(_ text: String) -> String { replace(#"\s+"#, text, " ").trimmingCharacters(in: .whitespacesAndNewlines) }
func trimmed(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
func shellDoubleQuote(_ text: String) -> String { "\"" + text.reduce("") { $0 + (["\\", "\"", "$", "`"].contains(String($1)) ? "\\" : "") + String($1) } + "\"" }
func shellQuote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
func queryTerms(_ query: String) -> [String] {
    matches(#""[^"]*"?|\S+"#, query.lowercased()).map { trimmed($0[0].replacingOccurrences(of: "\"", with: "")) }.filter { !$0.isEmpty }
}

struct ToolCall: Codable, Equatable { var name: String; var summary: String }
struct Message: Codable, Equatable {
    var role: String
    var text: String
    var timestamp: Double?
    var cwd = ""
    var branch = ""
    var isSidechain = false
    var toolCalls: [ToolCall]?
}
func isToolOnly(_ text: String) -> Bool {
    guard trimmed(text).hasPrefix("[tool") else { return false }
    return text.components(separatedBy: "\n").allSatisfy { !matches(#"^\[tool\b[^\]]*\]"#, trimmed($0)).isEmpty }
}
func toolCalls(_ text: String) -> [ToolCall] {
    text.components(separatedBy: "\n").flatMap { matches(#"^\[tool: ([^\]]*)\]\s*(.*)$"#, trimmed($0)) }
        .filter { !["TodoWrite", "todowrite", "update_plan"].contains($0[1]) }
        .map { ToolCall(name: $0[1], summary: $0[2]) }
}
func toolMarker(_ name: String, _ input: Any?) -> String {
    var summary = input as? String ?? ""
    if let object = input as? [String: Any] {
        for field in ["command", "file_path", "path", "pattern", "query", "url", "description", "prompt", "notebook_path"] {
            if let value = object[field] as? String, !trimmed(value).isEmpty { summary = value; break }
        }
    }
    summary = prefixUTF16(collapse(summary), 120)
    return "[tool: \(name)]" + (summary.isEmpty ? "" : " \(summary)")
}
func extractContent(_ content: Any?) -> String {
    if let text = content as? String { return text }
    guard let parts = content as? [Any] else { return "" }
    return parts.compactMap { part -> String? in
        if let text = part as? String { return text }
        guard let part = part as? [String: Any] else { return nil }
        switch part["type"] as? String {
        case "text", "input_text", "output_text": return part["text"] as? String
        case "thinking": return part["thinking"] as? String
        case "tool_use": return toolMarker(part["name"] as? String ?? "unknown", part["input"])
        case "tool_result": return "[tool result]"
        default: return nil
        }
    }.filter { !$0.isEmpty }.joined(separator: "\n")
}

struct TimelineRow: Codable, Identifiable, Equatable {
    var messageIndex: Int
    var timestamp: Double
    var end: Double
    var text: String
    var cwd: String
    var branch: String
    var lane = ""
    var label = ""
    var kind = "Session project"
    var sessionKey = ""
    var id: String { "\(sessionKey):\(messageIndex)" }
}
struct Session: Codable, Identifiable, Equatable {
    var id: String
    var tool: String
    var title: String
    var cwd: String
    var filePath: String
    var startedAt: Double
    var updatedAt: Double
    var messageCount: Int
    var preview: String
    var searchText: String
    var fingerprint = ""
    var timeline: [TimelineRow] = []
    var untimed = 0
    var prTitles: [String: String] = [:]
    var messages: [Message] = []
    var key: String { "\(tool):\(id)" }
    var project: String { (cwd as NSString).lastPathComponent }
    var toolName: String { ["claude": "Claude", "codex": "Codex", "cursor": "Cursor"][tool] ?? tool }
    var resumeCommand: String {
        let command = ["claude": "claude --resume ", "codex": "codex resume ", "cursor": "cursor-agent --resume="][tool] ?? ""
        return (cwd.isEmpty ? "" : "cd \(shellDoubleQuote(cwd)) && ") + command + (matches(#"^[A-Za-z0-9_-]+$"#, id).isEmpty ? shellQuote(id) : id)
    }
    var isReview: Bool {
        let opening = replace(#"https?://\S+"#, prefixUTF16(timeline.first?.text ?? preview, 400))
        let review = matches(#"(?i)\b(?:re[ -]?)?review\b"#, opening).first?.first
        let change = matches(#"(?i)\b(?:implement|fix|resolve|address|build|create|add|remove|update|change)\b"#, opening).first?.first
        if let change, let at = opening.range(of: change), review == nil || at.lowerBound < opening.range(of: review!)!.lowerBound { return false }
        return review != nil || !matches(#"(?i)\b(?:re[ -]?)?review\b"#, title).isEmpty
    }
    func snippet(_ terms: [String]) -> String {
        guard let term = terms.first else { return preview }
        let source = searchText as NSString
        let position = source.range(of: term, options: .caseInsensitive).location
        guard position != NSNotFound else { return preview }
        let start = max(0, position - 60), end = min(source.length, position + 140)
        return (start > 0 ? "…" : "") + replace(#"\s+"#, source.substring(with: NSRange(location: start, length: end - start)), " ") + "…"
    }
}

func makeTimeline(_ session: Session) -> ([TimelineRow], Int) {
    var rows: [TimelineRow] = []
    var current: TimelineRow?
    var prs = Set<String>()
    var untimed = 0
    func finish() {
        guard var row = current else { return }
        let project = (row.cwd as NSString).lastPathComponent
        row.sessionKey = session.key
        row.lane = prs.count == 1 ? prs.first! : "\(row.cwd.isEmpty ? session.id : row.cwd):\(row.branch)"
        row.label = prs.count == 1 ? row.lane.replacingOccurrences(of: "https://github.com/", with: "").replacingOccurrences(of: "/pull/", with: " #") : "\(project.isEmpty ? "Unknown project" : project)\(row.branch.isEmpty ? "" : " · " + row.branch)"
        row.kind = prs.count == 1 ? "PR mentioned by agent" : row.branch.isEmpty ? "Session project" : "Recorded branch"
        rows.append(row)
    }
    for (index, message) in session.messages.enumerated() where !message.isSidechain {
        if message.role == "user", message.toolCalls == nil {
            finish(); current = nil; prs = []
            guard let time = message.timestamp else { untimed += 1; continue }
            current = TimelineRow(messageIndex: index, timestamp: time, end: time, text: prefixUTF16(collapse(message.text), 500), cwd: message.cwd.isEmpty ? session.cwd : message.cwd, branch: message.branch)
        } else if message.role == "assistant", current != nil {
            if let time = message.timestamp, time >= current!.end, time - current!.end <= 30 * 60000 { current!.end = time }
            for match in matches(prPattern, message.text) { prs.insert(match[0]) }
        }
    }
    finish()
    var branchPRs: [String: [String: String]] = [:]
    for row in rows where row.kind == "PR mentioned by agent" { branchPRs["\(row.cwd):\(row.branch)", default: [:]][row.lane] = row.label }
    for index in rows.indices {
        let row = rows[index]
        if !row.branch.isEmpty, row.kind != "PR mentioned by agent", let prs = branchPRs["\(row.cwd):\(row.branch)"], prs.count == 1, let pr = prs.first {
            rows[index].lane = pr.key; rows[index].label = pr.value; rows[index].kind = "PR inferred from this session"
        }
    }
    return (rows, untimed)
}

struct TimeScale {
    struct Segment {
        var newer: Double; var older: Double; var top: Double; var bottom: Double; var gap: Bool
    }
    var segments: [Segment] = []
    init(rows: [TimelineRow], now: Double, pixelsPerMS: Double) {
        var merged: [(Double, Double)] = []
        for row in rows.sorted(by: { $0.timestamp < $1.timestamp }) {
            if let last = merged.last, row.timestamp <= last.1 { merged[merged.count - 1].1 = max(last.1, row.end) }
            else { merged.append((row.timestamp, max(row.timestamp, row.end))) }
        }
        var time = now
        var y = 0.0
        func add(_ older: Double, _ height: Double, _ gap: Bool = false) {
            guard time > older else { return }
            segments.append(Segment(newer: time, older: older, top: y, bottom: y + height, gap: gap)); time = older; y += height
        }
        var newer = now
        for interval in merged.reversed() {
            if newer - interval.1 > 15 * 60000 {
                add(newer - 60000, (time - newer + 60000) * pixelsPerMS)
                add(interval.1 + 60000, 44, true)
            }
            newer = interval.0
        }
        let oldest = (merged.first?.0 ?? now) - 10 * 60000
        add(oldest, (time - oldest) * pixelsPerMS)
    }
    private func segment(at value: Double, time: Bool) -> Segment {
        var low = 0, high = segments.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if time ? segments[middle].newer >= value : segments[middle].top <= value { low = middle }
            else { high = middle - 1 }
        }
        return segments[low]
    }
    func y(at time: Double) -> Double {
        let segment = segment(at: time, time: true)
        return max(0, segment.top + (segment.newer - time) / (segment.newer - segment.older) * (segment.bottom - segment.top))
    }
    func time(at y: Double) -> Double {
        let segment = segment(at: y, time: false)
        return segment.newer - (y - segment.top) / (segment.bottom - segment.top) * (segment.newer - segment.older)
    }
}
