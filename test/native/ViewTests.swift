import AppKit

@main struct ViewTests {
    static func main() throws {
        _ = NSApplication.shared
        var count = 0
        func check(_ name: String, _ condition: @autoclosure () -> Bool) { guard condition() else { fatalError("FAIL: \(name)") }; count += 1 }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sessions-views-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date().timeIntervalSince1970 * 1000
        let prompt = Message(role: "user", text: "Find needle twice: needle\n\n# Heading\n\n| Name | Value |\n| --- | --- |\n| A | B |\n\n```\nconst result = 1;\n```", timestamp: now - 60000, cwd: "/projects/sessions", branch: "mz-test")
        let answer = Message(role: "assistant", text: Array(repeating: "A detailed explanation with enough words to wrap over several lines in the transcript.", count: 100).joined(separator: "\n\n") + "\n\nFinal needle", timestamp: now)
        var session = Session(id: "one", tool: "claude", title: "First session", cwd: "/projects/sessions", filePath: "/fixtures/one.jsonl", startedAt: now - 60000, updatedAt: now, messageCount: 2, preview: "Find needle twice: needle", searchText: prompt.text, messages: [prompt, answer])
        (session.timeline, session.untimed) = makeTimeline(session)
        var second = session; second.id = "two"; second.title = "Pinned session"; second.timeline = []
        let store = SessionStore(automaticallyRefresh: false, directory: directory)
        store.sessions = [session, second]; store.visible = store.sessions; store.pins = [second.key]
        let root = SessionsContent(store: store)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = root; root.frame = NSRect(x: 0, y: 0, width: 1280, height: 820)
        root.update(); root.layoutSubtreeIfNeeded()
        check("The sidebar stays 380 points wide", root.sidebar.frame.width == 380)
        check("The titlebar stays 48 points high", root.sidebar.frame.minY == 48)
        check("The search field keeps its compact height", root.sidebar.query.frame.height == 33)
        check("Filters retain all four tool dots", root.sidebar.filters.compactMap(\.dot) == ["all", "claude", "codex", "cursor"])
        check("Pinned sessions use their own list", root.sidebar.pinned.rows.map(\.key) == [second.key])
        check("Unpinned sessions use the remaining list", root.sidebar.list.rows.map(\.key) == [session.key])
        let existingCell = root.sidebar.list.table.view(atColumn: 0, row: 0, makeIfNecessary: true)
        let leadingEdge = existingCell?.convert(existingCell!.bounds, to: root.sidebar.list.table).minX ?? -1
        check("Session rows have no system inset", leadingEdge >= 0 && leadingEdge <= 1)
        var revised = session; revised.updatedAt += 1000
        root.sidebar.list.apply([revised], terms: [], live: [session.key], selected: session.key)
        check("Refreshing a row preserves its native view", root.sidebar.list.table.view(atColumn: 0, row: 0, makeIfNecessary: true) === existingCell)
        root.sidebar.list.apply([revised, second], terms: [], live: [], selected: session.key)
        root.sidebar.list.apply([second, revised], terms: [], live: [], selected: session.key)
        check("Reordering sessions moves their rows", root.sidebar.list.rows.map(\.key) == [second.key, session.key])
        root.sidebar.list.apply([revised], terms: [], live: [], selected: session.key)
        check("Removed sessions leave the table", root.sidebar.list.table.numberOfRows == 1)
        root.update(); root.layoutSubtreeIfNeeded()
        check("Pinned sessions occupy at most half the sidebar", root.sidebar.pinned.scroll.frame.height <= root.sidebar.bounds.height / 2)
        store.detail = session; store.selectedKey = session.key; root.update(); root.layoutSubtreeIfNeeded()
        let pane = root.transcript
        check("Resume commands retain their displayed format", pane.header.command.stringValue == "cd \"/projects/sessions\" && claude --resume one")
        check("Consecutive user prompts stay separate", groupTurns([prompt, prompt]).count == 2)
        check("Consecutive assistant messages share a fold control", groupTurns([answer, answer]).count == 1)
        check("Transcript text retains its content", pane.turns[0].texts[0].textStorage?.string.contains("needle") == true)
        check("Transcript text occupies space", pane.turns[0].texts[0].frame.height > 0)
        check("Long turns start at 400 points", pane.turns[1].long && pane.turns[1].bubbleHeight == 400)
        pane.turns[1].expand.performClick(nil)
        check("Expand reveals the whole turn", pane.turns[1].expanded && pane.turns[1].bubbleHeight > 600)
        pane.turns[1].expand.performClick(nil)
        check("Retract shortens the turn again", !pane.turns[1].expanded && pane.turns[1].bubbleHeight == 400)
        pane.turns[0].header.performClick(nil)
        check("A turn folds from its header", !pane.turns[0].open)
        pane.applyFind("needle")
        check("Find counts individual occurrences", pane.matches.count == 3)
        check("Find opens a folded turn", pane.turns[0].open)
        check("Find starts at the first occurrence", pane.header.count.stringValue == "1 of 3")
        pane.moveMatch(1)
        check("Find moves to the next occurrence", pane.header.count.stringValue == "2 of 3")
        pane.moveMatch(1)
        check("Find expands shortened content containing the match", pane.turns[1].expanded)
        pane.moveMatch(1)
        check("Find wraps to the first occurrence", pane.matchIndex == 0)
        pane.moveMatch(-1)
        check("Previous match wraps to the last occurrence", pane.matchIndex == 2)
        pane.applyFind("")
        check("Clearing find removes its count", pane.header.count.stringValue.isEmpty)
        let pinnedHeaderY = pane.header.frame.minY
        pane.scroll.contentView.scroll(to: NSPoint(x: 0, y: 100))
        check("The transcript header stays fixed", pane.header.frame.minY == pinnedHeaderY)
        pane.jump(to: 0)
        check("Timeline selection marks the original prompt", pane.turns[0].timelineSelected)
        let shortHeaderHeight = pane.header.measure(400)
        var longTitle = session; longTitle.title = String(repeating: "A saved session name ", count: 12)
        pane.header.session = longTitle
        check("Long saved names wrap in the header", pane.header.measure(400) > shortHeaderHeight)
        pane.header.session = session; pane.relayout()
        let rich = markdownParts(prompt.text)
        check("Fenced code retains its own native text view", rich.contains { $0.code && $0.text.string.contains("const result = 1;") })
        check("Markdown tables use native text tables", rich.contains { ($0.text.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)?.textBlocks.first is NSTextTableBlock })
        check("Inline links keep their destination", inlineText("[Open](https://example.com)").attribute(.link, at: 0, effectiveRange: nil) as? URL == URL(string: "https://example.com"))
        check("Long code lines remain horizontally scrollable", MarkdownView("```\n" + String(repeating: "x", count: 500) + "\n```").subviews.first is NSScrollView)
        check("Dragging includes the command newline", (root.sidebar.list.tableView(root.sidebar.list.table, pasteboardWriterForRow: 0) as? NSPasteboardItem)?.string(forType: .string) == session.resumeCommand + "\n")
        check("The timeline retains all nine zoom levels", root.timeline.levels == [15, 30, 60, 120, 240, 480, 720, 1440, 2880])
        root.timeline.stepZoom(-1)
        check("Zooming in steps from one hour to thirty minutes", root.timeline.levels[root.timeline.zoomIndex] == 30)
        root.timeline.stepZoom(100)
        check("Zooming out stops at two days", root.timeline.levels[root.timeline.zoomIndex] == 2880)
        var openedPrompt = false
        let promptButton = TimelinePromptControl(row: session.timeline[0], color: Theme.accent) { openedPrompt = true }
        promptButton.performClick(nil)
        check("Timeline prompts use enabled native buttons", promptButton.isEnabled && openedPrompt)
        let canvas = TimelineCanvas(), scroll = TimelineScrollView(frame: .zero); scroll.documentView = canvas
        canvas.configure([], true, 60)
        check("An empty viewport finishes timeline layout", canvas.frame.height.isFinite)
        scroll.setFrameSize(NSSize(width: 1000, height: 700)); scroll.layoutSubtreeIfNeeded(); canvas.resizeIfNeeded()
        canvas.configure([session], false, 60); canvas.updateVisible()
        check("A populated timeline finishes layout", canvas.frame.height.isFinite)
        for zoom in [15, 30, 240, 1440, 2880] { canvas.configure([session], false, zoom); canvas.updateVisible() }
        check("Timeline zoom retains a finite document size", canvas.frame.height.isFinite)
        store.togglePin(session.key)
        let savedPins = try JSONDecoder().decode([String].self, from: Data(contentsOf: directory.appendingPathComponent("pins.json")))
        check("Pins persist on disk", savedPins.contains(session.key))
        print("\(count) view tests passing")
    }
}
