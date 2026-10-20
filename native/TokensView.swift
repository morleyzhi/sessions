import AppKit

struct TokenChart {
    let scale: TimeScale
    let offset: Double
    let duration: Double
    let series: [String]
    let values: [[Double]]
    let trendValues: [[Double]]
    var trendMinutes: Int { smoothingMinutes * 5 }
    let gaps: [Bool]
    let totalDuration: Double
    let smoothingMinutes: Int
    var maximum: Double { max(1, values.map { $0.reduce(0, +) }.max() ?? 0) }
    init(samples: [TokenSample], now: Double, offset: Double, minutes: Int, count: Int = 400) {
        let samples = samples.filter { $0.end > $0.start && $0.tokens > 0 && $0.end <= now }
        let rows = samples.enumerated().map { index, sample in
            TimelineRow(messageIndex: index, timestamp: sample.start, end: sample.end, text: "", cwd: "", branch: "")
        }
        // The timeline's idle intervals become narrow breaks along the horizontal axis.
        let scale = TimeScale(rows: rows, now: now, pixelsPerMS: 0.001)
        let duration = Double(minutes * 60)
        let totalDuration = scale.segments.last?.bottom ?? duration
        let offset = min(max(0, offset), max(0, totalDuration - duration))
        self.scale = scale; self.duration = duration; self.totalDuration = totalDuration; self.offset = offset
        let smoothingMinutes = [60: 2, 120: 3, 240: 5, 480: 8, 720: 10, 1440: 15][minutes] ?? 2
        self.smoothingMinutes = smoothingMinutes
        let windowDuration = Double(smoothingMinutes) * 60000
        let step = duration / Double(count)
        var breaks = Array(repeating: false, count: count)
        var windows = Array(repeating: (0.0, 0.0), count: count)
        var trendWindows = windows
        for index in 0..<count {
            let left = offset + Double(index) * step, right = left + step
            breaks[index] = scale.segments.contains { $0.gap && left < $0.bottom && right > $0.top }
            let position = (left + right) / 2
            if !breaks[index], let segment = scale.segments.first(where: { !$0.gap && position >= $0.top && position < $0.bottom }) {
                let time = scale.time(at: position)
                windows[index] = (max(segment.older, time - windowDuration), time)
                trendWindows[index] = (max(segment.older, time - windowDuration * 5), time)
            }
        }
        gaps = Array(breaks.reversed())
        let oldest = trendWindows.filter { $0.1 > $0.0 }.map { $0.0 }.min() ?? now
        let newest = trendWindows.map { $0.1 }.max() ?? now
        let visible = samples.filter { $0.end > oldest && $0.start < newest }
        let mainOldest = windows.filter { $0.1 > $0.0 }.map { $0.0 }.min() ?? now
        let mainNewest = windows.map { $0.1 }.max() ?? now
        let series = Set(visible.filter { $0.end > mainOldest && $0.start < mainNewest }.map(\.series)).sorted()
        self.series = series
        let groups = Dictionary(grouping: visible, by: \.series)
        func averages(_ windows: [(Double, Double)]) -> [[Double]] {
            var values = Array(repeating: Array(repeating: 0.0, count: series.count), count: count)
            for (column, name) in series.enumerated() {
                let samples = (groups[name] ?? []).sorted { $0.start < $1.start }
                var active: [(Double, Double)] = []
                // Concurrent sessions add tokens while sharing the same active seconds.
                for sample in samples {
                    if let last = active.last, sample.start <= last.1 { active[active.count - 1].1 = max(last.1, sample.end) }
                    else { active.append((sample.start, sample.end)) }
                }
                for (index, window) in windows.enumerated() where window.1 > window.0 {
                    let activeMS = active.reduce(0.0) { $0 + max(0, min($1.1, window.1) - max($1.0, window.0)) }
                    guard activeMS > 0 else { continue }
                    let tokens = samples.reduce(0.0) { sum, sample in
                        sum + sample.rate * max(0, min(sample.end, window.1) - max(sample.start, window.0)) / 1000
                    }
                    values[index][column] = tokens / (activeMS / 1000)
                }
            }
            return Array(values.reversed())
        }
        values = averages(windows)
        trendValues = averages(trendWindows)
    }
    func time(at fraction: Double) -> Double { scale.time(at: offset + duration * (1 - fraction)) }
}

final class TokensCanvas: FlippedView {
    var chart: TokenChart? { didSet { needsDisplay = true } }
    var stacked = true { didSet { needsDisplay = true } }
    var selectedSeries: String? { didSet { needsDisplay = true } }
    var shownColumns: [Int] { chart.map { chart in chart.series.indices.filter { selectedSeries == nil || chart.series[$0] == selectedSeries } } ?? [] }
    var trendColumn: Int? { shownColumns.count == 1 ? shownColumns.first : nil }
    var maximumRate: Double {
        guard let chart else { return 0 }
        let main = chart.values.map { row in stacked ? shownColumns.reduce(0.0) { $0 + row[$1] } : shownColumns.map { row[$0] }.max() ?? 0 }.max() ?? 0
        let trend = trendColumn.map { column in chart.trendValues.map { $0[column] }.max() ?? 0 } ?? 0
        return max(main, trend)
    }
    private let tooltip = TimelineTooltip()
    private var tracking: NSTrackingArea?
    var plot: NSRect { NSRect(x: 65, y: 28, width: max(1, bounds.width - 90), height: max(1, bounds.height - 88)) }
    var seriesColors: [String: NSColor] = [:]
    func color(_ name: String) -> NSColor {
        if let color = seriesColors[name] { return color }
        let hash = name.utf8.reduce(UInt64(5381)) { ($0 &* 33) &+ UInt64($1) }
        return NSColor(calibratedHue: CGFloat(hash % 360) / 360, saturation: 0.56, brightness: 0.9, alpha: 1)
    }
    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true); setAccessibilityRole(.image); setAccessibilityLabel("Output tokens per second. Newest time is on the right.")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    override func draw(_ dirtyRect: NSRect) {
        Theme.background.setFill(); bounds.fill()
        guard let chart else { return }
        let columns = shownColumns
        let rect = plot, maximum = max(10, ceil(maximumRate / 10) * 10)
        drawText(stacked && selectedSeries == nil ? "STACKED TPS" : "OUTPUT TPS", in: NSRect(x: 12, y: 2, width: 150, height: 18), size: 10, color: Theme.muted)
        for tick in 0...4 {
            let value = maximum * Double(tick) / 4, y = rect.maxY - rect.height * Double(tick) / 4
            Theme.border.setFill(); NSRect(x: rect.minX, y: y, width: rect.width, height: 1).fill()
            drawText(String(format: "%.0f", value), in: NSRect(x: 2, y: y - 8, width: 54, height: 18), size: 11, color: Theme.muted)
        }
        NSGraphicsContext.saveGraphicsState(); NSBezierPath(rect: rect).addClip()
        var lower = Array(repeating: 0.0, count: chart.values.count)
        for column in columns {
            let name = chart.series[column]
            let upper = chart.values.enumerated().map { lower[$0.offset] + $0.element[column] }
            let color = color(name)
            var first = 0
            while first < upper.count {
                if chart.gaps[first] { first += 1; continue }
                var end = first + 1
                while end < upper.count && !chart.gaps[end] { end += 1 }
                func point(_ index: Int, _ values: [Double]) -> NSPoint {
                    NSPoint(x: rect.minX + (Double(index) + 0.5) / Double(upper.count) * rect.width, y: rect.maxY - values[index] / maximum * rect.height)
                }
                let fill = NSBezierPath(), line = NSBezierPath()
                fill.move(to: point(first, lower)); fill.line(to: point(first, upper)); line.move(to: point(first, upper))
                for index in (first + 1)..<end {
                    fill.line(to: point(index, upper))
                    if chart.values[index][column] > 0 && chart.values[index - 1][column] > 0 { line.line(to: point(index, upper)) }
                    else { line.move(to: point(index, upper)) }
                }
                for index in (first..<end).reversed() { fill.line(to: point(index, lower)) }
                if stacked { fill.close(); color.withAlphaComponent(0.32).setFill(); fill.fill() }
                color.setStroke(); line.lineWidth = 2; line.lineJoinStyle = .round; line.lineCapStyle = .round; line.stroke(); first = end
            }
            if stacked { lower = upper }
        }
        if let column = trendColumn {
            let line = NSBezierPath(); var connected = false
            for index in chart.trendValues.indices {
                let value = chart.trendValues[index][column]
                guard !chart.gaps[index], value > 0 else { connected = false; continue }
                let point = NSPoint(x: rect.minX + (Double(index) + 0.5) / Double(chart.trendValues.count) * rect.width, y: rect.maxY - value / maximum * rect.height)
                if connected { line.line(to: point) } else { line.move(to: point) }
                connected = true
            }
            color(chart.series[column]).setStroke(); line.lineWidth = 2
            line.setLineDash([6, 5], count: 2, phase: 0); line.stroke()
        }
        for segment in chart.scale.segments where segment.gap {
            let width = max(5, (segment.bottom - segment.top) / chart.duration * rect.width)
            let x = rect.maxX - (segment.top - chart.offset) / chart.duration * rect.width - width
            guard x + width >= rect.minX && x < rect.maxX else { continue }
            Theme.panel.setFill(); NSRect(x: x, y: rect.minY, width: width, height: rect.height).fill()
            drawText("↯", in: NSRect(x: x, y: rect.midY - 10, width: 22, height: 20), size: 12, color: Theme.muted)
        }
        NSGraphicsContext.restoreGraphicsState()
        let formatter = DateFormatter(); formatter.dateFormat = "MMM d HH:mm"
        for index in 0...4 {
            let fraction = Double(index) / 4, time = chart.time(at: fraction)
            let text = index == 4 && chart.offset == 0 ? "Now" : formatter.string(from: Date(timeIntervalSince1970: time / 1000))
            drawText(text, in: NSRect(x: min(rect.maxX - 110, max(rect.minX, rect.minX + fraction * rect.width - 50)), y: rect.maxY + 12, width: 118, height: 20), size: 11, color: Theme.muted)
        }
        drawText("TIME → NEWER    ·    ↯ inactivity skipped", in: NSRect(x: rect.minX, y: rect.maxY + 36, width: 400, height: 18), size: 10, color: Theme.muted)
        if chart.series.isEmpty { drawText("No timed token usage in this period", in: NSRect(x: rect.midX - 160, y: rect.midY, width: 350, height: 24), size: 14, color: Theme.muted) }
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas(); if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: .zero, options: [.inVisibleRect, .activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited], owner: self); addTrackingArea(tracking!)
    }
    func hideTooltip() { tooltip.orderOut(nil) }
    override func mouseExited(with event: NSEvent) { hideTooltip() }
    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard plot.contains(point), let chart, let window else { hideTooltip(); return }
        let fraction = (point.x - plot.minX) / plot.width
        let position = chart.offset + (1 - fraction) * chart.duration
        if let gap = chart.scale.segments.first(where: { $0.gap && position >= $0.top && position <= $0.bottom }) {
            tooltip.show("\(Int((gap.newer - gap.older) / 60000)) minutes of inactivity skipped", in: window); return
        }
        let index = min(chart.values.count - 1, max(0, Int(fraction * Double(chart.values.count))))
        let formatter = DateFormatter(); formatter.dateStyle = .medium; formatter.timeStyle = .medium
        var lines = [formatter.string(from: Date(timeIntervalSince1970: chart.time(at: fraction) / 1000))]
        lines.append("\(chart.smoothingMinutes) min trailing average · Active seconds only")
        lines.append(String(format: "Total: %.1f output TPS", shownColumns.reduce(0.0) { $0 + chart.values[index][$1] }))
        for column in shownColumns { lines.append(String(format: "%@: %.1f TPS", chart.series[column], chart.values[index][column])) }
        if let column = trendColumn { lines.append(String(format: "Dashed %d min average: %.1f TPS", chart.trendMinutes, chart.trendValues[index][column])) }
        tooltip.show(lines.joined(separator: "\n"), in: window)
    }
}

final class TokensPane: FlippedView {
    let canvas = TokensCanvas(frame: .zero)
    let harness = NSPopUpButton(), model = NSPopUpButton(), effort = NSPopUpButton(), period = NSPopUpButton()
    let newer = ActionButton("Newer →"), older = ActionButton("← Older"), now = ActionButton("Now")
    let stacked = NSButton(checkboxWithTitle: "Stacked", target: nil, action: nil)
    let range = label("", size: 12, color: Theme.muted)
    let note = label("", size: 11, color: Theme.muted)
    let legend = FlippedView(), legendScroll = NSScrollView()
    private(set) var legendButtons: [ActionButton] = []
    let minutes = [60, 120, 240, 480, 720, 1440]
    private(set) var offset = 0.0
    private var samples: [TokenSample] = []
    private var referenceNow: Double?
    private var timer: Timer?
    override init(frame: NSRect) {
        super.init(frame: frame)
        for view in [canvas, harness, model, effort, period, newer, older, now, stacked, range, note, legendScroll] { addSubview(view) }
        for popup in [harness, model, effort, period] { popup.font = .systemFont(ofSize: 12); popup.target = self; popup.action = #selector(changeFilter(_:)) }
        for (popup, title) in [(harness, "All harnesses"), (model, "All models"), (effort, "All efforts")] { popup.addItem(withTitle: title); popup.setAccessibilityLabel(title) }
        period.addItems(withTitles: ["1 hr", "2 hr", "4 hr", "8 hr", "12 hr", "24 hr"])
        period.setAccessibilityLabel("Active time per screen")
        stacked.font = .systemFont(ofSize: 12); stacked.contentTintColor = Theme.accent
        stacked.state = UserDefaults.standard.object(forKey: "tps-stacked") as? Bool == false ? .off : .on
        stacked.target = self; stacked.action = #selector(toggleStacked)
        newer.actionBlock = { [weak self] in self?.page(-1) }; older.actionBlock = { [weak self] in self?.page(1) }
        now.actionBlock = { [weak self] in self?.offset = 0; self?.referenceNow = nil; self?.refresh() }
        legendScroll.documentView = legend; legendScroll.hasVerticalScroller = true; legendScroll.drawsBackground = false; legendScroll.autohidesScrollers = true
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in guard let self, !self.isHidden, self.offset == 0 else { return }; self.refresh() }
        refresh()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    deinit { timer?.invalidate() }
    func setSessions(_ sessions: [Session]) {
        samples = sessions.flatMap { $0.tokenSamples ?? [] }
        let colors = [0x72b7ff, 0xffb86b, 0x75d9b0, 0xd8a0ff, 0xff8297, 0xe1d56c, 0x73d6e6, 0xb8c3ff]
        var seen = Set<String>()
        let names = samples.sorted { $0.end > $1.end }.map(\.series).filter { seen.insert($0).inserted }
        canvas.seriesColors = Dictionary(uniqueKeysWithValues: names.enumerated().map { index, name in
            (name, index < colors.count ? rgb(colors[index]) : NSColor(calibratedHue: (CGFloat(index) * 0.618034).truncatingRemainder(dividingBy: 1), saturation: 0.5, brightness: 0.95, alpha: 1))
        })
        for (popup, values) in [(harness, Set(samples.map(\.harness))), (model, Set(samples.map(\.model))), (effort, Set(samples.map(\.effort)))] {
            let selected = popup.indexOfSelectedItem > 0 ? popup.titleOfSelectedItem : nil
            let title = popup.itemTitle(at: 0)
            popup.removeAllItems(); popup.addItem(withTitle: title); popup.addItems(withTitles: values.sorted())
            if let selected { popup.selectItem(withTitle: selected) }
        }
        refresh()
    }
    func page(_ direction: Int) {
        if offset == 0 { referenceNow = Date().timeIntervalSince1970 * 1000 }
        offset += Double(direction * minutes[period.indexOfSelectedItem] * 60)
        if offset <= 0 { referenceNow = nil }
        refresh()
    }
    @objc private func toggleStacked() {
        UserDefaults.standard.set(stacked.state == .on, forKey: "tps-stacked")
        refresh()
    }
    func stepZoom(_ direction: Int) { period.selectItem(at: min(minutes.count - 1, max(0, period.indexOfSelectedItem + direction))); refresh() }
    @objc private func changeFilter(_ sender: NSPopUpButton) { if sender !== period { offset = 0; referenceNow = nil }; refresh() }
    func refresh() {
        let filtered = samples.filter { sample in
            (harness.indexOfSelectedItem == 0 || sample.harness == harness.titleOfSelectedItem) &&
            (model.indexOfSelectedItem == 0 || sample.model == model.titleOfSelectedItem) &&
            (effort.indexOfSelectedItem == 0 || sample.effort == effort.titleOfSelectedItem)
        }
        let chart = TokenChart(samples: filtered, now: referenceNow ?? Date().timeIntervalSince1970 * 1000, offset: offset, minutes: minutes[period.indexOfSelectedItem])
        offset = chart.offset; canvas.chart = chart; canvas.stacked = stacked.state == .on
        if let selected = canvas.selectedSeries, !chart.series.contains(selected) { canvas.selectedSeries = nil }
        let description = canvas.stacked ? "Colored bands stack to total TPS" : "Each line shows its own TPS"
        note.stringValue = canvas.trendColumn == nil
            ? "\(chart.smoothingMinutes) min average · Active seconds only · \(description)"
            : "Solid: \(chart.smoothingMinutes) min · Dashed: \(chart.trendMinutes) min · Active seconds only"
        newer.isEnabled = offset > 0; older.isEnabled = !filtered.isEmpty && offset + chart.duration < chart.totalDuration
        let formatter = DateFormatter(); formatter.dateFormat = "MMM d, HH:mm"
        range.stringValue = formatter.string(from: Date(timeIntervalSince1970: chart.time(at: 0) / 1000)) + "  →  " + formatter.string(from: Date(timeIntervalSince1970: chart.time(at: 1) / 1000))
        if legendButtons.map(\.title) != ["Show all"] + chart.series.map({ "● " + $0 }) {
            legendButtons.forEach { $0.removeFromSuperview() }; legendButtons = []
            let all = ActionButton("Show all", size: 11)
            all.active = canvas.selectedSeries == nil; all.actionBlock = { [weak self] in self?.isolateSeries(nil) }
            legendButtons.append(all)
            for name in chart.series {
                let button = ActionButton("● " + name, size: 11)
                button.ink = canvas.color(name); button.active = canvas.selectedSeries == name
                button.toolTip = "Click to show only " + name + "; click again to show all"
                button.actionBlock = { [weak self] in self?.isolateSeries(name) }
                legendButtons.append(button)
            }
            for button in legendButtons { legend.addSubview(button) }
        }
        for (index, button) in legendButtons.enumerated() {
            button.active = index == 0 ? canvas.selectedSeries == nil : canvas.selectedSeries == chart.series[index - 1]
            if index > 0 { button.ink = canvas.color(chart.series[index - 1]) }
            button.needsDisplay = true
        }
        needsLayout = true
    }
    func isolateSeries(_ name: String?) {
        canvas.selectedSeries = canvas.selectedSeries == name ? nil : name
        refresh()
    }
    override func layout() {
        super.layout()
        let width = max(120, (bounds.width - 40 - 180 - 30) / 3)
        for (index, popup) in [harness, model, effort].enumerated() { popup.frame = NSRect(x: 20 + Double(index) * (width + 10), y: 12, width: width, height: 28) }
        period.frame = NSRect(x: bounds.width - 200, y: 12, width: 180, height: 28)
        older.frame = NSRect(x: 20, y: 52, width: 85, height: 28); now.frame = NSRect(x: 113, y: 52, width: 55, height: 28); newer.frame = NSRect(x: 176, y: 52, width: 85, height: 28)
        range.frame = NSRect(x: 278, y: 58, width: max(0, bounds.width - 410), height: 20)
        stacked.frame = NSRect(x: bounds.width - 112, y: 55, width: 92, height: 24)
        note.frame = NSRect(x: 20, y: 92, width: max(0, bounds.width - 40), height: 20)
        canvas.frame = NSRect(x: 0, y: 122, width: bounds.width, height: max(0, bounds.height - 206))
        legendScroll.frame = NSRect(x: 65, y: max(122, bounds.height - 78), width: max(0, bounds.width - 90), height: 65)
        let available = legendScroll.contentSize.width
        var x = 0.0, y = 0.0
        for button in legendButtons {
            let width = min(available, ceil((button.title as NSString).size(withAttributes: [.font: button.font!]).width) + 24)
            if x > 0, x + width > available { x = 0; y += 32 }
            button.frame = NSRect(x: x, y: y, width: width, height: 27); x += width + 10
        }
        legend.setFrameSize(NSSize(width: available, height: max(65, y + 32)))
    }
    override func draw(_ dirtyRect: NSRect) { Theme.background.setFill(); bounds.fill() }
}
