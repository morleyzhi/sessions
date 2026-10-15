import SwiftUI

struct Turn: Identifiable {
    var id: Int
    var messages: [Message]
    var role: String { messages.first!.toolCalls != nil ? "assistant" : messages.first!.role }
    var isSidechain: Bool { messages.first!.isSidechain }
}
func groupTurns(_ messages: [Message]) -> [Turn] {
    var turns: [Turn] = []
    for (index, message) in messages.enumerated() {
        if message.toolCalls != nil && message.toolCalls!.isEmpty { continue }
        let role = message.toolCalls != nil ? "assistant" : message.role
        if let last = turns.last, role == "assistant", last.role == role, last.isSidechain == message.isSidechain {
            turns[turns.count - 1].messages.append(message)
        } else { turns.append(Turn(id: index, messages: [message])) }
    }
    return turns
}

struct TranscriptView: View {
    let session: Session
    @ObservedObject var store: SessionStore
    @State private var find = ""
    @State private var matchIndex = 0
    @State private var copied = false
    @FocusState private var findFocused: Bool
    private var turns: [Turn] { groupTurns(session.messages) }
    private var found: [Int] {
        guard !find.isEmpty else { return [] }
        return turns.filter { $0.messages.contains(where: { $0.text.localizedCaseInsensitiveContains(find) }) }.map(\.id)
    }
    var body: some View {
        ScrollViewReader { proxy in
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(session.title).font(.title2.bold()).textSelection(.enabled)
                    HStack {
                        Label(session.toolName, systemImage: "circle.fill").foregroundStyle(toolColor(session.tool))
                        Text(session.cwd.isEmpty ? "No working directory" : session.cwd).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        Spacer()
                        Text(Date(timeIntervalSince1970: session.updatedAt / 1000), format: .dateTime.month().day().hour().minute())
                    }.font(.caption).foregroundStyle(.secondary)
                    if store.live.contains(session.key) {
                        Label("This session is running. Quit its CLI process before resuming.", systemImage: "circle.fill").font(.caption).foregroundStyle(.green)
                    }
                    HStack {
                        Text(session.resumeCommand).font(.system(.caption, design: .monospaced)).lineLimit(2).textSelection(.enabled)
                        Spacer()
                        Button(copied ? "Copied" : "Copy resume command") {
                            store.copy(session.resumeCommand); copied = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
                        }
                    }
                    HStack {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Find in this session", text: $find).textFieldStyle(.plain).focused($findFocused)
                            .onSubmit { moveMatch(1, proxy) }
                            .onExitCommand { find = "" }
                        if !find.isEmpty { Text(found.isEmpty ? "No matches" : "\(min(matchIndex + 1, found.count)) of \(found.count) turns").font(.caption).foregroundStyle(.secondary) }
                        Button { moveMatch(-1, proxy) } label: { Image(systemName: "chevron.up") }.disabled(found.isEmpty)
                        Button { moveMatch(1, proxy) } label: { Image(systemName: "chevron.down") }.disabled(found.isEmpty)
                    }.padding(8).background(.quaternary, in: RoundedRectangle(cornerRadius: 7))
                }.padding(18)
                Divider()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(turns) { turn in
                            TurnView(turn: turn, find: find, reveal: found.contains(turn.id) || turn.id == store.jumpToMessage)
                                .id(turn.id)
                        }
                        if turns.isEmpty { Text("No readable messages").foregroundStyle(.secondary) }
                        Color.clear.frame(height: 1).id("bottom")
                    }.padding(20)
                }
                HStack {
                    Text("\(session.messageCount) messages").foregroundStyle(.secondary)
                    Spacer()
                    Button("Scroll to bottom", systemImage: "arrow.down") { proxy.scrollTo("bottom", anchor: .bottom) }
                }.font(.caption).padding(10)
            }
            .background { Button("") { findFocused = true }.keyboardShortcut("f").hidden() }
            .onChange(of: find) { _, _ in matchIndex = 0; if let first = found.first { proxy.scrollTo(first, anchor: .top) } }
            .onChange(of: store.jumpToMessage) { _, index in jump(index, proxy) }
            .onAppear { jump(store.jumpToMessage, proxy) }
        }
    }
    private func moveMatch(_ direction: Int, _ proxy: ScrollViewProxy) {
        guard !found.isEmpty else { return }
        matchIndex = (matchIndex + direction + found.count) % found.count
        proxy.scrollTo(found[matchIndex], anchor: .top)
    }
    private func jump(_ index: Int?, _ proxy: ScrollViewProxy) {
        guard let index, let turn = turns.last(where: { $0.id <= index }) else { return }
        DispatchQueue.main.async { proxy.scrollTo(turn.id, anchor: .top) }
    }
}
struct TurnView: View {
    let turn: Turn
    let find: String
    let reveal: Bool
    @State private var open = true
    @State private var expanded = false
    private var long: Bool { turn.messages.reduce(0) { $0 + $1.text.count } > 3500 }
    var body: some View {
        DisclosureGroup(isExpanded: $open) {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(turn.messages.enumerated()), id: \.offset) { _, message in
                    if let calls = message.toolCalls {
                        DisclosureGroup("\(calls.count) tool \(calls.count == 1 ? "call" : "calls") · \(Array(Set(calls.map(\.name))).sorted().joined(separator: ", "))") {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(Array(calls.enumerated()), id: \.offset) { _, call in
                                    Text(call.name).font(.system(.caption, design: .monospaced).bold())
                                    Text(highlighted(call.summary, find)).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                                }
                            }.padding(8)
                        }.font(.caption).foregroundStyle(.secondary)
                    } else {
                        MarkdownText(text: message.text, find: find)
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
                .frame(maxHeight: long && !expanded && !reveal ? 600 : nil, alignment: .top).clipped()
                .padding(12).background(turn.role == "user" ? Color.accentColor.opacity(0.10) : Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
            if long && !reveal { Button(expanded ? "Retract" : "Expand") { expanded.toggle() }.buttonStyle(.link).padding(.top, 4) }
        } label: {
            HStack {
                Text(turn.role + (turn.isSidechain ? " · subagent" : "")).font(.caption.bold()).textCase(.uppercase)
                Spacer()
                if let time = turn.messages.first?.timestamp { Text(Date(timeIntervalSince1970: time / 1000), format: .dateTime.month().day().hour().minute()).font(.caption).foregroundStyle(.secondary) }
            }
        }.opacity(turn.isSidechain ? 0.6 : 1)
            .onChange(of: reveal) { _, value in if value { open = true; expanded = true } }
    }
}

struct MarkdownBlock: Identifiable {
    var id: Int
    var kind: String
    var text: String
}
func markdownBlocks(_ text: String) -> [MarkdownBlock] {
    var blocks: [MarkdownBlock] = [], lines: [String] = [], fenced = false
    func flush(_ kind: String = "text") {
        if !lines.isEmpty { blocks.append(MarkdownBlock(id: blocks.count, kind: kind, text: lines.joined(separator: "\n"))); lines = [] }
    }
    for line in text.components(separatedBy: "\n") {
        if trimmed(line).hasPrefix("```") { flush(fenced ? "code" : "text"); fenced.toggle(); continue }
        if fenced { lines.append(line); continue }
        if trimmed(line).isEmpty { flush(); continue }
        if let heading = matches(#"^(#{1,6})\s+(.*)$"#, line).first { flush(); blocks.append(MarkdownBlock(id: blocks.count, kind: "h" + String(heading[1].count), text: heading[2])); continue }
        if !matches(#"^\s*([-*_])\s*\1\s*\1[-*_\s]*$"#, line).isEmpty { flush(); blocks.append(MarkdownBlock(id: blocks.count, kind: "rule", text: "")); continue }
        if trimmed(line).hasPrefix("|") {
            flush()
            if blocks.last?.kind == "table" { blocks[blocks.count - 1].text += "\n" + line }
            else { blocks.append(MarkdownBlock(id: blocks.count, kind: "table", text: line)) }
            continue
        }
        lines.append(line)
    }
    flush(fenced ? "code" : "text")
    return blocks
}
struct MarkdownText: View {
    let text: String
    let find: String
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(markdownBlocks(text)) { block in
                if block.kind == "rule" { Divider() }
                else if block.kind == "table" {
                    ScrollView(.horizontal) {
                        Grid(alignment: .topLeading, horizontalSpacing: 16, verticalSpacing: 8) {
                            ForEach(Array(tableRows(block.text).enumerated()), id: \.offset) { index, cells in
                                GridRow {
                                    ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in
                                        Text(attributed(cell)).fontWeight(index == 0 ? .semibold : .regular).textSelection(.enabled)
                                    }
                                }
                                if index == 0 { Divider() }
                            }
                        }.padding(10)
                    }.background(.black.opacity(0.15), in: RoundedRectangle(cornerRadius: 5))
                } else if block.kind == "code" {
                    ScrollView(.horizontal) {
                        Text(highlighted(block.text, find)).font(.system(.callout, design: .monospaced)).textSelection(.enabled).padding(9)
                    }.background(.black.opacity(0.2), in: RoundedRectangle(cornerRadius: 5))
                } else {
                    Text(attributed(block.text)).font(block.kind.hasPrefix("h") ? .headline : .body).textSelection(.enabled).lineSpacing(4)
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
            .environment(\.openURL, OpenURLAction { url in
                guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return .discarded }
                NSWorkspace.shared.open(url); return .handled
            })
    }
    private func tableRows(_ text: String) -> [[String]] {
        text.components(separatedBy: "\n").filter { matches(#"^\s*\|?[\s:|-]*-[\s:|-]*$"#, $0).isEmpty }.map { line in
            var line = trimmed(line)
            if line.hasPrefix("|") { line.removeFirst() }; if line.hasSuffix("|") { line.removeLast() }
            return line.components(separatedBy: "|").map { trimmed($0) }
        }
    }
    private func attributed(_ text: String) -> AttributedString {
        var result = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
        if !find.isEmpty {
            let plain = String(result.characters)
            var start = plain.startIndex
            while let range = plain.range(of: find, options: .caseInsensitive, range: start..<plain.endIndex) {
                if let low = AttributedString.Index(range.lowerBound, within: result), let high = AttributedString.Index(range.upperBound, within: result) { result[low..<high].backgroundColor = .yellow.opacity(0.35) }
                start = range.upperBound
                if start == plain.endIndex { break }
            }
        }
        return result
    }
}
