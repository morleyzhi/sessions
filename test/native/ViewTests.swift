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
        (existingCell as? SessionCell)?.hovered = true
        var revised = session; revised.updatedAt += 1000
        root.sidebar.list.apply([revised], terms: [], live: [session.key], selected: session.key)
        check("Refreshing a row preserves its native view", root.sidebar.list.table.view(atColumn: 0, row: 0, makeIfNecessary: true) === existingCell)
        check("Refreshing clears a reused row's hover", (existingCell as? SessionCell)?.hovered == false)
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
        var busy = session
        busy.timeline = (0..<2000).map { index in
            var row = session.timeline[0]; row.messageIndex = index
            row.timestamp = now - Double(index) * 60000; row.end = row.timestamp
            return row
        }
        canvas.configure([busy], false, 2880)
        check("Two-day zoom keeps dense activity aligned to time", canvas.frame.height < 1400)
        let cards = canvas.subviews.compactMap { $0 as? TimelinePromptControl }
        check("Two-day zoom groups overlapping prompts", cards.contains { $0.row.text.contains("prompts ·") })
        check("Two-day zoom limits visible prompt controls", cards.count < 30)
        busy.timeline = (0..<2000).map { index in
            var row = session.timeline[0]; row.messageIndex = index
            row.timestamp = now - Double(index) * 10 * 60000; row.end = row.timestamp
            return row
        }
        canvas.configure([busy], false, 60)
        canvas.scroll(to: now - 1000 * 10 * 60000)
        let scrolledCards = canvas.subviews.compactMap { $0 as? TimelinePromptControl }
        check("Scrolling creates controls only inside the viewport", scrolledCards.allSatisfy { scroll.contentView.bounds.intersects($0.frame) })
        check("Scrolling reaches older timeline prompts", scrolledCards.contains { $0.row.messageIndex >= 1000 })
        let tokenNow = 10_000_000.0
        let tokenSample = TokenSample(start: tokenNow - 240000, end: tokenNow, tokens: 2400, harness: "codex", model: "gpt", effort: "high")
        let chart = TokenChart(samples: [tokenSample, tokenSample], now: tokenNow, offset: 0, minutes: 60)
        check("Simultaneous sessions add their output rates", abs(chart.maximum - 20) < 0.001)
        var secondModel = tokenSample; secondModel.model = "second"; secondModel.tokens = 4800
        let combined = TokenChart(samples: [tokenSample, secondModel], now: tokenNow, offset: 0, minutes: 60)
        check("Different models stack to their combined rate", abs(combined.maximum - 30) < 0.001)
        let comparison = TokensCanvas(frame: .zero); comparison.chart = combined
        check("Stacked charts use the combined rate for the axis", abs(comparison.maximumRate - 30) < 0.001)
        comparison.stacked = false
        check("Unstacked charts use the largest individual rate for the axis", abs(comparison.maximumRate - 20) < 0.001)
        check("The chart shows now on the right", chart.time(at: 1) == tokenNow)
        check("Older times appear on the left", chart.time(at: 0) < chart.time(at: 1))
        check("Recent token output appears on the right", chart.values.last?[0] == 20)
        check("Earlier quiet periods appear on the left", chart.values.first?[0] == 0)
        let history = TokenSample(start: tokenNow - 7200000, end: tokenNow - 7140000, tokens: 600, harness: "claude", model: "opus", effort: "low")
        let compressed = TokenChart(samples: [tokenSample, history], now: tokenNow, offset: 0, minutes: 60)
        check("Long inactive periods collapse", compressed.totalDuration < 3600)
        check("Idle intervals mark breaks in the lines", compressed.gaps.contains(true))
        let continuous = TokenSample(start: tokenNow - 10000000, end: tokenNow, tokens: 10000, harness: "codex", model: "gpt", effort: "high")
        let burst = TokenSample(start: tokenNow - 605000, end: tokenNow - 595000, tokens: 1000, harness: "claude", model: "opus", effort: "low")
        let smoothed = TokenChart(samples: [continuous, burst], now: tokenNow, offset: 0, minutes: 60)
        check("Short activity retains its recorded token rate", abs(smoothed.maximum - 101) < 0.001)
        check("Smoothing preserves a steady output rate", smoothed.values.prefix(10).allSatisfy { abs($0[1] - 1) < 0.001 })
        check("The solid line smooths one active minute", smoothed.smoothingMinutes == 1)
        check("Zoom preserves active-time smoothing", TokenChart(samples: [continuous], now: tokenNow, offset: 0, minutes: 1440).smoothingMinutes == 1)
        let shortUse = TokenSample(start: tokenNow - 70000, end: tokenNow - 60000, tokens: 100, harness: "codex", model: "gpt", effort: "high")
        let longerUse = TokenSample(start: tokenNow - 40000, end: tokenNow - 10000, tokens: 600, harness: "codex", model: "gpt", effort: "high")
        let activeOnly = TokenChart(samples: [shortUse, longerUse], now: tokenNow, offset: 0, minutes: 60)
        var adjacentUse = shortUse; adjacentUse.start = longerUse.start - 10000; adjacentUse.end = longerUse.start
        let withoutPause = TokenChart(samples: [adjacentUse, longerUse], now: tokenNow, offset: 0, minutes: 60)
        let lastActivity = activeOnly.values.lastIndex { $0[0] > 0 }!
        check("Pauses do not lower the solid line", abs(activeOnly.values[lastActivity][0] - withoutPause.values[lastActivity][0]) < 0.001)
        check("Pauses do not lower the dashed line", abs(activeOnly.trendValues[lastActivity][0] - withoutPause.trendValues[lastActivity][0]) < 0.001)
        check("The solid line stops when activity ends", activeOnly.values.last![0] == 0)
        check("The dashed line stops when activity ends", activeOnly.trendValues.last![0] == 0)
        check("Both lines end with the same activity", activeOnly.values.lastIndex { $0[0] > 0 } == activeOnly.trendValues.lastIndex { $0[0] > 0 })
        let steadyUse = TokenSample(start: tokenNow - 600000, end: tokenNow - 30000, tokens: 5700, harness: "codex", model: "gpt", effort: "high")
        var fasterUse = longerUse; fasterUse.start = tokenNow - 30000; fasterUse.end = tokenNow; fasterUse.tokens = 3000
        let trend = TokenChart(samples: [steadyUse, fasterUse], now: tokenNow, offset: 0, minutes: 60)
        let beforeActivity = trend.values.indices.filter { trend.time(at: (Double($0) + 0.5) / Double(trend.values.count)) <= steadyUse.start }
        check("The solid line excludes future activity", beforeActivity.allSatisfy { trend.values[$0][0] == 0 })
        check("The dashed line excludes future activity", beforeActivity.allSatisfy { trend.trendValues[$0][0] == 0 })
        check("Both averages start with recorded activity", trend.values.firstIndex { $0[0] > 0 } == trend.trendValues.firstIndex { $0[0] > 0 })
        check("The trend smooths five active minutes", trend.trendMinutes == 5)
        let decay = 60 / log(2.0)
        let expectedRecentRate = 100 - 90 * decay / 9 * (exp(-21 / decay) - exp(-30 / decay))
        check("A recent rate change fades in exponentially", abs(trend.values.last![0] - expectedRecentRate) < 0.001)
        check("The longer trend softens recent rate changes", trend.trendValues.last![0] < trend.values.last![0])
        comparison.chart = trend
        check("A single series shows the dashed trend", comparison.trendColumn == 0)
        comparison.chart = combined
        check("Several series hide the dashed trend", comparison.trendColumn == nil)
        comparison.selectedSeries = combined.series[0]
        check("Legend isolation shows the dashed trend", comparison.trendColumn == 0)
        let quiet = TokenSample(start: history.start, end: history.end, tokens: 60, harness: "claude", model: "opus", effort: "low")
        let separate = TokenChart(samples: [tokenSample, quiet], now: tokenNow, offset: 0, minutes: 60)
        let quietColumn = separate.series.firstIndex(of: quiet.series)!
        check("Smoothing stops at skipped inactivity", separate.values.enumerated().filter { separate.time(at: (Double($0.offset) + 0.5) / Double(separate.values.count)) > tokenSample.start }.allSatisfy { $0.element[quietColumn] == 0 })
        check("Skipped inactivity has no plotted output", separate.values.enumerated().filter { separate.gaps[$0.offset] }.allSatisfy { $0.element.allSatisfy { $0 == 0 } })
        check("The dashed trend stops at skipped inactivity", separate.trendValues.enumerated().filter { separate.gaps[$0.offset] }.allSatisfy { $0.element.allSatisfy { $0 == 0 } })
        let olderChart = TokenChart(samples: [continuous], now: tokenNow, offset: 3600, minutes: 60)
        check("Paging shows the preceding hour", olderChart.time(at: 1) == tokenNow - 3600000)
        check("Paging stops at recorded history", TokenChart(samples: [continuous], now: tokenNow, offset: 1e9, minutes: 60).offset == olderChart.totalDuration - 3600)
        check("An empty chart has no series", TokenChart(samples: [], now: tokenNow, offset: 0, minutes: 60).series.isEmpty)
        session.tokenSamples = [tokenSample, history, continuous, secondModel]
        root.tokens.setSessions([session])
        root.tokensButton.performClick(nil); root.update(); root.layoutSubtreeIfNeeded()
        check("The token tab opens its chart", !root.tokens.isHidden)
        check("The token tab hides the transcript", root.transcript.isHidden)
        check("The token chart starts with one hour", root.tokens.period.indexOfSelectedItem == 0)
        check("The token chart offers one day", root.tokens.minutes.last == 1440)
        let modelColors = root.tokens.canvas.seriesColors
        check("Concurrent models have distinct colors", Set(modelColors.values.map { $0.description }).count == modelColors.count)
        root.tokens.harness.selectItem(withTitle: "claude"); root.tokens.refresh()
        check("Harness filters remove other harnesses", root.tokens.canvas.chart?.series.allSatisfy { $0.hasPrefix("Claude") } == true)
        check("Filtering keeps model colors consistent", root.tokens.canvas.seriesColors == modelColors)
        root.tokens.harness.selectItem(at: 0); root.tokens.model.selectItem(withTitle: "gpt"); root.tokens.refresh()
        check("Model filters remove other models", root.tokens.canvas.chart?.series.allSatisfy { $0.contains("gpt") } == true)
        root.tokens.model.selectItem(at: 0); root.tokens.effort.selectItem(withTitle: "low"); root.tokens.refresh()
        check("Effort filters remove other efforts", root.tokens.canvas.chart?.series.allSatisfy { $0.hasSuffix("low") } == true)
        root.tokens.effort.selectItem(at: 0); root.tokens.refresh()
        let legendButton = root.tokens.legendButtons[1]
        root.tokens.refresh()
        check("Refreshing keeps legend buttons available", root.tokens.legendButtons[1] === legendButton)
        let allSeries = root.tokens.canvas.chart!.series
        let firstSeries = allSeries[0]
        let chartTime = root.tokens.canvas.chart!.time(at: 0)
        root.tokens.legendButtons[1].performClick(nil)
        check("Clicking the legend shows one line", root.tokens.canvas.shownColumns.count == 1)
        check("The legend shows the clicked series", root.tokens.canvas.chart!.series[root.tokens.canvas.shownColumns[0]] == firstSeries)
        check("Isolating a line keeps the time period", abs(root.tokens.canvas.chart!.time(at: 0) - chartTime) < 1000)
        root.tokens.legendButtons[1].performClick(nil)
        check("Clicking the selected legend item restores all lines", root.tokens.canvas.shownColumns.count == allSeries.count)
        root.tokens.legendButtons[2].performClick(nil); root.tokens.legendButtons[0].performClick(nil)
        check("Show all restores all lines", root.tokens.canvas.selectedSeries == nil)
        if root.tokens.stacked.state == .off { root.tokens.stacked.performClick(nil) }
        root.tokens.stacked.performClick(nil)
        check("Clearing Stacked draws individual lines", !root.tokens.canvas.stacked)
        root.tokens.stacked.performClick(nil)
        check("Selecting Stacked restores stacked bands", root.tokens.canvas.stacked)
        root.tokens.page(1)
        check("Older pages move away from now", root.tokens.offset > 0)
        root.tokens.now.performClick(nil)
        check("Now returns to the newest page", root.tokens.offset == 0)
        root.tokens.setFrameSize(NSSize(width: 900, height: 700)); root.tokens.layoutSubtreeIfNeeded()
        check("Older paging sits to the left of newer paging", root.tokens.older.frame.minX < root.tokens.newer.frame.minX)
        check("The filters fit the minimum window width", root.tokens.effort.frame.maxX < root.tokens.period.frame.minX)
        root.tokens.canvas.display()
        store.togglePin(session.key)
        let savedPins = try JSONDecoder().decode([String].self, from: Data(contentsOf: directory.appendingPathComponent("pins.json")))
        check("Pins persist on disk", savedPins.contains(session.key))
        print("\(count) view tests passing")
    }
}
