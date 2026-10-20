import AppKit
import Combine

let dataDirectory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/sessions", isDirectory: true)

func run(_ executable: String, _ arguments: [String], timeout: Double = 4) -> String {
    let process = Process(), output = Pipe()
    process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
    process.standardOutput = output; process.standardError = FileHandle.nullDevice
    do {
        try process.run()
        let finished = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: finished)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit(); finished.cancel()
        return String(decoding: data, as: UTF8.self)
    } catch { return "" }
}

func liveSessionKeys(_ sessions: [Session]) -> Set<String> {
    struct CLI { var pid: String; var tool: String; var started: Double; var sessionID: String }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
    var processes: [CLI] = []
    let names = ["claude": "claude", "codex": "codex", "cursor-agent": "cursor"]
    for line in run("/bin/ps", ["-axo", "pid=,lstart=,args="]).components(separatedBy: "\n") {
        guard let match = matches(#"^\s*(\d+)\s+(\w{3} \w{3}\s+\d+ \d+:\d+:\d+ \d{4})\s+(.*)$"#, line).first else { continue }
        let args = match[3]
        guard matches(#"--type=|app-server|code-mode-host|\bsandbox\b|\bmcp\b|Frameworks/"#, args).isEmpty else { continue }
        guard let tool = args.split(separator: " ").prefix(2).compactMap({ names[(String($0) as NSString).lastPathComponent] }).first, let started = formatter.date(from: match[2]) else { continue }
        let id = matches(#"(?i)\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b"#, args).first?.first ?? ""
        processes.append(CLI(pid: match[1], tool: tool, started: started.timeIntervalSince1970 * 1000, sessionID: id.lowercased()))
    }
    guard !processes.isEmpty else { return [] }
    var directories: [String: String] = [:], pid = ""
    for line in run("/usr/sbin/lsof", ["-a", "-d", "cwd", "-Fpn", "-p", processes.map(\.pid).joined(separator: ",")]).components(separatedBy: "\n") {
        if line.hasPrefix("p") { pid = String(line.dropFirst()) }
        else if line.hasPrefix("n") { directories[pid] = String(line.dropFirst()) }
    }
    var keys = Set<String>()
    for process in processes {
        if !process.sessionID.isEmpty { keys.insert("\(process.tool):\(process.sessionID)") }
        else if let cwd = directories[process.pid], let owned = sessions.first(where: { $0.tool == process.tool && $0.cwd == cwd && $0.updatedAt >= process.started }) { keys.insert(owned.key) }
    }
    return keys
}

final class IndexStore {
    let reader: TranscriptReader
    let directory: URL
    private var cache: [String: Session] = [:]
    private var needsCacheWrite = false
    init(home: String = NSHomeDirectory(), directory: URL = dataDirectory) {
        reader = TranscriptReader(home: home); self.directory = directory
        if let data = try? Data(contentsOf: directory.appendingPathComponent("native-index-v1.json")), let stored = try? JSONDecoder().decode([String: Session].self, from: data) {
            cache = stored
        } else if let data = try? Data(contentsOf: directory.appendingPathComponent("index.json")), let previous = json(data) as? [String: [String: Any]] {
            // Reuse unchanged summaries from the installed Electron app.
            for (path, original) in previous {
                var value = original
                let tool = value["tool"] as? String ?? ""
                let key = "\(tool):\(value["id"] as? String ?? "")"
                let timeline = value["timeline"] as? [String: Any] ?? [:]
                value["timeline"] = (timeline["rows"] as? [[String: Any]] ?? []).map { row in
                    var row = row; row["sessionKey"] = key; return row
                }
                value["untimed"] = timeline["untimed"] as? Int ?? 0
                value["prTitles"] = value["prTitles"] ?? [String: String]()
                value["messages"] = [Any]()
                guard let encoded = try? JSONSerialization.data(withJSONObject: value), var session = try? JSONDecoder().decode(Session.self, from: encoded) else { continue }
                let source = tool == "cursor" ? path + "/store.db" : path
                let old = session.fingerprint.components(separatedBy: ":")
                if tool != "cursor", old.count == 3, old[0] == "v6", let modified = Double(old[1]), let size = UInt64(old[2]), let attrs = try? FileManager.default.attributesOfItem(atPath: source), let date = attrs[.modificationDate] as? Date, abs(date.timeIntervalSince1970 * 1000 - modified) < 1, (attrs[.size] as? NSNumber)?.uint64Value == size {
                    session.fingerprint = "native-v1:\(date.timeIntervalSince1970):\(attrs[.size] ?? 0)"
                }
                cache[path] = session
            }
            needsCacheWrite = true
        }
    }
    func cachedSessions() -> [Session] { uniqueSessions(Array(cache.values)) }
    private func uniqueSessions(_ sessions: [Session]) -> [Session] {
        var unique: [String: Session] = [:]
        for session in sessions {
            if let previous = unique[session.key], previous.messageCount > session.messageCount { continue }
            unique[session.key] = session
        }
        return unique.values.sorted { $0.updatedAt == $1.updatedAt ? $0.key < $1.key : $0.updatedAt > $1.updatedAt }
    }
    func refresh(progress: ((Int, Int, [Session]) -> Void)? = nil) -> [Session] {
        let titles = reader.titles()
        var next: [String: Session] = [:]
        var changed = needsCacheWrite
        let targets = reader.targets()
        for (offset, target) in targets.enumerated() {
            let (tool, path) = target
            if offset % 20 == 0 { progress?(offset, targets.count, uniqueSessions(Array(next.values))) }
            let source = tool == "cursor" ? path + "/store.db" : path
            guard let stat = try? FileManager.default.attributesOfItem(atPath: source) else { continue }
            var fingerprint = "native-v2:\((stat[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0):\(stat[.size] ?? 0)"
            if tool == "cursor" {
                for extra in [path + "/store.db-wal", path + "/meta.json"] {
                    let attrs = try? FileManager.default.attributesOfItem(atPath: extra)
                    fingerprint += ":\((attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0):\(attrs?[.size] ?? 0)"
                }
            }
            if var cached = cache[path], cached.fingerprint == fingerprint {
                if tool == "codex", let title = titles[cached.id], cached.title != title { cached.title = title; changed = true }
                next[path] = cached
            } else {
                changed = true
                if var session = reader.parse(tool: tool, path: path, titles: titles), session.messageCount > 0 {
                    session.fingerprint = fingerprint; session.messages = []; next[path] = session
                }
            }
        }
        if changed || next.count != cache.count {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if let data = try? JSONEncoder().encode(next) { try? data.write(to: directory.appendingPathComponent("native-index-v1.json"), options: .atomic) }
        }
        cache = next; needsCacheWrite = false
        return uniqueSessions(Array(next.values))
    }
}

final class SessionStore: ObservableObject {
    @Published var sessions: [Session] = []
    @Published var visible: [Session] = []
    @Published var selectedKey: String?
    @Published var detail: Session?
    @Published var live: Set<String> = []
    @Published var pins: [String] = []
    @Published var query = "" { didSet { scheduleFilter() } }
    @Published var tool = "all" { didSet { filter() } }
    @Published var mode = "Sessions"
    @Published var status = "Reading sessions…"
    @Published var detailError = ""
    @Published var jumpToMessage: Int?
    private let worker = DispatchQueue(label: "sessions.index", qos: .userInitiated)
    private let searchWorker = DispatchQueue(label: "sessions.search", qos: .userInitiated)
    private let detailWorker = DispatchQueue(label: "sessions.transcript", qos: .userInitiated)
    private var index: IndexStore?
    private var refreshing = false
    private var timer: Timer?
    private var filterRequest = 0
    private let directory: URL
    init(automaticallyRefresh: Bool = true, directory: URL = dataDirectory) {
        self.directory = directory
        if let data = try? Data(contentsOf: directory.appendingPathComponent("pins.json")), let saved = try? JSONDecoder().decode([String].self, from: data) { pins = saved }
        guard automaticallyRefresh else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.refresh() }
    }
    func refresh() {
        guard !refreshing else { return }; refreshing = true
        worker.async { [weak self] in
            guard let self else { return }
            let firstRefresh = self.index == nil
            if firstRefresh {
                self.index = IndexStore(directory: self.directory)
                let cached = self.index!.cachedSessions()
                DispatchQueue.main.async { if !cached.isEmpty { self.sessions = cached; self.filter() } }
            }
            let sessions = self.index!.refresh { done, total, partial in
                guard firstRefresh else { return }
                DispatchQueue.main.async {
                    self.status = "Reading \(done) / \(total) transcripts…"
                    if self.sessions.isEmpty && !partial.isEmpty { self.sessions = partial; self.filter() }
                }
            }
            let live = liveSessionKeys(sessions)
            DispatchQueue.main.async {
                self.refreshing = false
                if self.sessions != sessions { self.sessions = sessions; self.filter() }
                if self.live != live { self.live = live }
                self.status = "\(sessions.count) sessions"
            }
        }
    }
    private func scheduleFilter() {
        filterRequest += 1
        let request = filterRequest
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self, self.filterRequest == request else { return }; self.filter()
        }
    }
    func filter() {
        filterRequest += 1
        let request = filterRequest, sessions = sessions, tool = tool, terms = queryTerms(query), pins = pins
        searchWorker.async { [weak self] in
            var result = sessions.filter { session in
                guard tool == "all" || session.tool == tool else { return false }
                let haystack = (session.title + "\n" + session.cwd + "\n" + session.searchText).lowercased()
                return terms.allSatisfy { haystack.contains($0) }
            }
            let order = Dictionary(pins.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: min)
            result.sort {
                let left = order[$0.key] ?? Int.max, right = order[$1.key] ?? Int.max
                return left == right ? $0.updatedAt > $1.updatedAt : left < right
            }
            let filtered = result
            DispatchQueue.main.async { guard let self, self.filterRequest == request else { return }; self.visible = filtered }
        }
    }
    func select(_ key: String?, messageIndex: Int? = nil) {
        selectedKey = key; jumpToMessage = messageIndex
        guard let key, let summary = sessions.first(where: { $0.key == key }) else { detail = nil; return }
        if detail?.key == key { return }
        detail = nil; detailError = ""
        detailWorker.async { [weak self] in
            let session = TranscriptReader().parse(tool: summary.tool, path: summary.filePath, titles: summary.tool == "codex" ? TranscriptReader().titles() : [:])
            DispatchQueue.main.async {
                guard let self, self.selectedKey == key else { return }
                self.detail = session; if session == nil { self.detailError = "Could not read this session." }
            }
        }
    }
    func togglePin(_ key: String) {
        pins = pins.contains(key) ? pins.filter { $0 != key } : [key] + pins
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(pins).write(to: directory.appendingPathComponent("pins.json"), options: .atomic)
        } catch { status = "Could not save pins: \(error.localizedDescription)" }
        filter()
    }
    func copy(_ text: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
}
