import AppKit

final class TimelineScrollView: HoverScrollView {
    override func layout() {
        super.layout()
        (documentView as? TimelineCanvas)?.resizeIfNeeded()
    }
}
final class TimelinePromptControl: NSButton {
    var row: TimelineRow
    var ink: NSColor
    var pressed: () -> Void
    private var hovered = false
    private var tracking: NSTrackingArea?
    private static let clock: DateFormatter = { let value = DateFormatter(); value.dateFormat = "HH:mm:ss"; return value }()
    init(row: TimelineRow, color: NSColor, pressed: @escaping () -> Void) {
        self.row = row; ink = color; self.pressed = pressed
        super.init(frame: .zero); isBordered = false; focusRingType = .none
        title = row.text
        setButtonType(.momentaryPushIn); target = self; action = #selector(invoke)
        setAccessibilityLabel(row.text)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    override var isFlipped: Bool { true }
    @objc private func invoke() { pressed() }
    override func updateTrackingAreas() {
        super.updateTrackingAreas(); if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: bounds, options: [.activeInKeyWindow, .mouseEnteredAndExited], owner: self); addTrackingArea(tracking!)
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func keyDown(with event: NSEvent) { if event.keyCode == 36 || event.keyCode == 76 { performClick(nil) } else { super.keyDown(with: event) } }
    override func draw(_ dirtyRect: NSRect) {
        rounded(bounds, 4, fill: hovered ? Theme.hover : Theme.panel, border: hovered || window?.firstResponder === self ? Theme.accent : Theme.border)
        ink.setFill(); NSRect(x: 0, y: 0, width: 3, height: bounds.height).fill()
        drawText(Self.clock.string(from: Date(timeIntervalSince1970: row.timestamp / 1000)), in: NSRect(x: 9, y: 5, width: 58, height: 18), size: 10, color: Theme.muted)
        drawText(row.text, in: NSRect(x: 70, y: 4, width: bounds.width - 80, height: 20), size: 12)
    }
}
final class TimelineCanvas: NSView {
    override var isFlipped: Bool { true }
    var sessions: [Session] = []
    var excludeReviews = true
    var zoom = 60
    var request = 0
    var open: ((TimelineRow) -> Void)?
    var observer: NSObjectProtocol?
    private var rows: [(TimelineRow, Double, Double)] = []
    private var visible: [(TimelineRow, Double, Double)] = []
    private var rowBottoms: [Double] = []
    private var lanes: [String] = []
    private var labels: [String: String] = [:]
    private var activityByLane: [String: [TimelineRow]] = [:]
    private var scale = TimeScale(rows: [], now: Date().timeIntervalSince1970 * 1000, pixelsPerMS: 1)
    private var hitAreas: [(NSRect, TimelineRow)] = []
    private var viewportHeight = 0.0
    private let axis = 128.0, header = 50.0
    private var columnWidth = 240.0
    private var configuring = false
    private var updatingVisible = false
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Activity timeline")
    }
    required init?(coder: NSCoder) { super.init(coder: coder) }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); needsDisplay = true }
    func resizeIfNeeded() {
        guard !configuring, let scroll = enclosingScrollView, scroll.contentSize.height >= 200,
              abs(scroll.contentSize.height - viewportHeight) > 1 else { return }
        configure(sessions, excludeReviews, zoom)
    }
    func configure(_ sessions: [Session], _ exclude: Bool, _ zoom: Int) {
        guard !configuring else { return }
        configuring = true
        defer { configuring = false }
        let anchor = enclosingScrollView.map { scale.time(at: max(0, $0.contentView.bounds.minY)) }
        self.sessions = sessions; excludeReviews = exclude; self.zoom = zoom
        viewportHeight = max(200, enclosingScrollView?.contentSize.height ?? 600)
        var titles: [String: String] = [:]
        for session in sessions.reversed() { titles.merge(session.prTitles) { _, newest in newest } }
        let prompts = sessions.filter { !exclude || !$0.isReview }.flatMap(\.timeline).sorted { $0.timestamp > $1.timestamp }
        let now = max(Date().timeIntervalSince1970 * 1000, prompts.first?.end ?? 0)
        scale = TimeScale(rows: prompts, now: now, pixelsPerMS: (viewportHeight - header) / (Double(zoom) * 60000))
        activityByLane = Dictionary(grouping: prompts, by: \.lane)
        var lastInLane: [String: Int] = [:], counts: [Int: Int] = [:]
        labels = [:]; rows = []
        for row in prompts {
            let y = scale.y(at: row.timestamp) + header
            labels[row.lane] = titles[row.lane] ?? row.label
            if let index = lastInLane[row.lane], y - rows[index].1 < 28 {
                counts[index, default: 1] += 1
            } else {
                lastInLane[row.lane] = rows.count
                rows.append((row, y, scale.y(at: row.end) + header))
            }
        }
        for (index, count) in counts { rows[index].0.text = "\(count) prompts · " + rows[index].0.text }
        rows.sort { $0.2 < $1.2 }
        var bottom = 0.0
        rowBottoms = rows.map { bottom = max(bottom, $0.1 + 28); return bottom }
        let height = max(viewportHeight, rows.map { $0.1 + 100 }.max() ?? viewportHeight)
        setFrameSize(NSSize(width: max(900, enclosingScrollView?.contentSize.width ?? 900), height: height))
        if let anchor, enclosingScrollView?.contentView.bounds.minY ?? 0 > 10 { scroll(to: anchor) }
        updateVisible()
    }
    func scroll(to time: Double?) {
        let y = time.map { scale.y(at: $0) } ?? 0
        enclosingScrollView?.contentView.scroll(to: NSPoint(x: 0, y: min(max(0, y), max(0, frame.height - viewportHeight))))
        if let scroll = enclosingScrollView { scroll.reflectScrolledClipView(scroll.contentView) }
        updateVisible()
    }
    func updateVisible() {
        guard !updatingVisible, let scroll = enclosingScrollView else { return }
        updatingVisible = true
        defer { updatingVisible = false }
        let rect = scroll.contentView.bounds
        // Rows are sorted by their top; accumulated bottoms include long-running work.
        var low = 0, high = rows.count
        while low < high { let mid = (low + high) / 2; if rowBottoms[mid] < rect.minY { low = mid + 1 } else { high = mid } }
        let first = low
        high = rows.count
        while low < high { let mid = (low + high) / 2; if rows[mid].2 <= rect.maxY { low = mid + 1 } else { high = mid } }
        visible = rows[first..<low].filter { $0.1 + 28 >= rect.minY }
        var active: [String] = []
        for item in visible where item.1 + 28 >= rect.minY + header && item.1 <= rect.maxY && !active.contains(item.0.lane) { active.append(item.0.lane) }
        lanes = active.filter { !lanes.contains($0) } + lanes.filter { active.contains($0) }
        columnWidth = max(240, (scroll.contentSize.width - axis) / Double(max(1, lanes.count)))
        let width = max(scroll.contentSize.width, axis + columnWidth * Double(lanes.count))
        if abs(frame.width - width) > 1 { setFrameSize(NSSize(width: width, height: frame.height)) }
        updateButtons(rect)
        needsDisplay = true
    }
    private func color(_ lane: String) -> NSColor {
        let hash = lane.reduce(Int32(0)) { ($0 &* 31) &+ Int32($1.utf16.first ?? 0) }
        let hue = CGFloat(abs(Int64(hash)) % 360) / 360
        return NSColor(calibratedHue: hue, saturation: 0.441558, brightness: 0.847, alpha: 1)
    }
    private func text(_ value: String, _ rect: NSRect, color: NSColor = Theme.text, size: CGFloat = 11, bold: Bool = false) {
        let style = NSMutableParagraphStyle(); style.lineBreakMode = .byTruncatingTail
        (value as NSString).draw(in: rect, withAttributes: [.font: bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size), .foregroundColor: color, .paragraphStyle: style])
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let scroll = enclosingScrollView else { return }
        let view = scroll.contentView.bounds
        Theme.background.setFill(); dirtyRect.fill()
        hitAreas = []
        for index in lanes.indices {
            let x = axis + Double(index) * columnWidth
            Theme.border.setFill(); NSRect(x: x, y: view.minY, width: 1, height: view.height).fill()
        }
        let formatter = DateFormatter(); formatter.dateFormat = "MMM d · HH:mm:ss"
        var lastLabel = -Double.infinity
        for segment in scale.segments where segment.bottom + header >= view.minY && segment.top <= view.maxY {
            if segment.gap {
                let minutes = Int((segment.newer - segment.older) / 60000)
                let duration = minutes >= 1440 ? "\(minutes / 1440)d \(minutes % 1440 / 60)h" : minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
                text("↯ \(duration) skipped", NSRect(x: view.minX + 8, y: segment.top + header + 12, width: axis - 12, height: 20), color: Theme.muted)
                Theme.border.setFill(); NSRect(x: axis, y: segment.top + header + 22, width: frame.width - axis, height: 1).fill()
                lastLabel = segment.bottom + header
                continue
            }
            let step = Double([5, 10, 15, 30, 60, 120, 180, 360].first(where: { $0 >= zoom / 8 }) ?? 360) * 60000
            var time = floor(min(segment.newer, scale.time(at: max(0, view.minY - header))) / step) * step
            while time >= segment.older {
                let y = scale.y(at: time) + header
                if y > view.maxY { break }
                if y >= view.minY, y - lastLabel >= 42 {
                    text(formatter.string(from: Date(timeIntervalSince1970: time / 1000)), NSRect(x: view.minX + 8, y: y, width: axis - 12, height: 20), color: Theme.muted)
                    Theme.border.withAlphaComponent(0.3).setFill(); NSRect(x: axis, y: y + 20, width: frame.width - axis, height: 1).fill()
                    lastLabel = y
                }
                time -= step
            }
        }
        for (row, y, top) in visible {
            guard let index = lanes.firstIndex(of: row.lane) else { continue }
            let x = axis + Double(index) * columnWidth
            guard x + columnWidth >= view.minX, x <= view.maxX else { continue }
            if row.end > row.timestamp {
                color(row.lane).withAlphaComponent(0.12).setFill()
                NSRect(x: x + 5, y: max(top, view.minY), width: columnWidth - 10, height: max(0, min(view.maxY, y + 25) - max(top, view.minY))).fill()
            }
            guard y + 28 >= view.minY, y <= view.maxY else { continue }
            let rect = NSRect(x: x + 8, y: y, width: columnWidth - 16, height: 25)
            hitAreas.append((rect, row))
        }
        Theme.background.setFill(); NSRect(x: view.minX, y: view.minY, width: view.width, height: header).fill()
        text("TIME ↓", NSRect(x: view.minX + 12, y: view.minY + 16, width: axis - 24, height: 20), color: Theme.muted, size: 10)
        for (index, lane) in lanes.enumerated() {
            let x = axis + Double(index) * columnWidth
            rounded(NSRect(x: x, y: view.minY, width: columnWidth, height: 50), 0, fill: Theme.panel, border: Theme.border)
            color(lane).setFill(); NSRect(x: x, y: view.minY, width: columnWidth, height: 3).fill()
            text(labels[lane] ?? lane, NSRect(x: x + 12, y: view.minY + 15, width: columnWidth - 24, height: 22), size: 12)
        }
        if rows.isEmpty { text("No timestamped prompts to show.", NSRect(x: 170, y: view.minY + 80, width: 500, height: 24), color: Theme.muted, size: 14) }

    }
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard point.y > (enclosingScrollView?.contentView.bounds.minY ?? 0) + header else { return }
        if let row = hitAreas.last(where: { $0.0.contains(point) })?.1 { open?(row) }
    }
    private var buttons: [String: TimelinePromptControl] = [:]
    private func updateButtons(_ rect: NSRect) {
        var active = Set<String>()
        for (row, y, _) in visible where y >= rect.minY + header && y < rect.maxY {
            guard let index = lanes.firstIndex(of: row.lane) else { continue }
            let x = axis + Double(index) * columnWidth
            guard x + columnWidth >= rect.minX, x <= rect.maxX else { continue }
            active.insert(row.id)
            let button = buttons[row.id] ?? TimelinePromptControl(row: row, color: color(row.lane)) { [weak self] in self?.open?(row) }
            if button.superview == nil { addSubview(button); buttons[row.id] = button }
            button.row = row; button.setAccessibilityLabel("\(labels[row.lane] ?? row.label): \(row.text)")
            button.frame = NSRect(x: axis + Double(index) * columnWidth + 8, y: y, width: columnWidth - 16, height: 25)
        }
        for key in Array(buttons.keys) where !active.contains(key) { buttons.removeValue(forKey: key)?.removeFromSuperview() }
    }
    private var hoverArea: NSTrackingArea?
    private let tooltip = TimelineTooltip()
    override func updateTrackingAreas() {
        super.updateTrackingAreas(); if let hoverArea { removeTrackingArea(hoverArea) }
        hoverArea = NSTrackingArea(rect: .zero, options: [.inVisibleRect, .activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited], owner: self)
        addTrackingArea(hoverArea!)
    }
    func hideTooltip() { tooltip.orderOut(nil) }
    override func mouseExited(with event: NSEvent) { hideTooltip() }
    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let index = Int(floor((point.x - axis) / columnWidth))
        guard lanes.indices.contains(index), let window else { hideTooltip(); return }
        let lane = lanes[index], activity = activityByLane[lane] ?? []
        let keys = Set(activity.map(\.sessionKey)), related = sessions.filter { keys.contains($0.key) }
        var lines = [labels[lane] ?? lane]
        if lane.hasPrefix("https://") { lines.append(lane) }
        let branches = Set(activity.map(\.branch).filter { !$0.isEmpty }).sorted()
        if !branches.isEmpty { lines.append("Branch: " + branches.joined(separator: ", ")) }
        lines += Set(activity.map(\.cwd).filter { !$0.isEmpty }).sorted()
        let tools = Set(related.map(\.toolName)).sorted().joined(separator: ", ")
        lines.append("\(activity.count) messages · \(related.count) \(related.count == 1 ? "session" : "sessions") · \(tools)")
        lines += related.prefix(3).map { "Session: " + $0.title }
        if related.count > 3 { lines.append("+\(related.count - 3) more sessions") }
        if point.y > (enclosingScrollView?.contentView.bounds.minY ?? 0) + header, let row = hitAreas.last(where: { $0.0.contains(point) })?.1 {
            let date = DateFormatter(); date.dateStyle = .short; date.timeStyle = .medium
            lines += ["", date.string(from: Date(timeIntervalSince1970: row.timestamp / 1000)), row.text, "Click to open this message"]
        }
        tooltip.show(lines.joined(separator: "\n"), in: window)
    }
}

final class TooltipContent: FlippedView {
    var text = NSAttributedString(string: "")
    override func draw(_ dirtyRect: NSRect) { rounded(bounds, 5, fill: Theme.hover, border: Theme.border); text.draw(with: bounds.insetBy(dx: 8, dy: 4), options: [.usesLineFragmentOrigin, .usesFontLeading]) }
}
final class TimelineTooltip: NSPanel {
    private let bodyView = TooltipContent()
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false; backgroundColor = .clear; hasShadow = true; ignoresMouseEvents = true; hidesOnDeactivate = true; level = .floating
        contentView = bodyView
    }
    func show(_ text: String, in window: NSWindow) {
        guard window.isKeyWindow else { orderOut(nil); return }
        bodyView.text = attributed(text, size: 11, lineHeight: 17.6)
        let width = min(440, window.frame.width - 16)
        let measured = bodyView.text.boundingRect(with: NSSize(width: width - 16, height: 10000), options: [.usesLineFragmentOrigin, .usesFontLeading])
        let size = NSSize(width: min(width, ceil(measured.width) + 16), height: min(window.frame.height - 16, ceil(measured.height) + 8))
        let point = NSEvent.mouseLocation
        let origin = NSPoint(x: max(window.frame.minX + 8, min(point.x + 16, window.frame.maxX - size.width - 8)), y: max(window.frame.minY + 8, min(point.y - size.height - 16, window.frame.maxY - size.height - 8)))
        setFrame(NSRect(origin: origin, size: size), display: true); bodyView.needsDisplay = true; orderFrontRegardless()
    }
}
final class TimelinePane: FlippedView {
    let canvas = TimelineCanvas(), scroll = TimelineScrollView()
    let heading = label("Work timeline", size: 17, weight: .bold)
    let review = NSButton(checkboxWithTitle: "Exclude reviews", target: nil, action: nil)
    let zoomLabel = label("Zoom", size: 12, color: Theme.muted), jumpLabel = label("Jump to", size: 12, color: Theme.muted)
    let zoom = ActionButton("1 hour"), date = InputView("mm/dd/yyyy", size: 12), calendar = ActionButton("▦"), now = ActionButton("Now ↑")
    let levels = [15, 30, 60, 120, 240, 480, 720, 1440, 2880]
    let names = ["15 min", "30 min", "1 hour", "2 hours", "4 hours", "8 hours", "12 hours", "1 day", "2 days"]
    private(set) var zoomIndex = 2
    private var sessions: [Session] = []
    var open: ((TimelineRow) -> Void)? { didSet { canvas.open = open } }
    private var popover: NSPopover?
    private var timer: Timer?
    override init(frame: NSRect) {
        super.init(frame: frame)
        scroll.documentView = canvas; scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true; scroll.scrollerStyle = .legacy
        scroll.verticalScroller = ThinScroller(); scroll.horizontalScroller = ThinScroller(); scroll.drawsBackground = false; scroll.autohidesScrollers = false
        scroll.contentView.postsBoundsChangedNotifications = true
        canvas.observer = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak canvas] _ in canvas?.updateVisible() }
        for view in [scroll, heading, review, zoomLabel, zoom, jumpLabel, date, calendar, now] { addSubview(view) }
        review.font = .systemFont(ofSize: 12); review.contentTintColor = Theme.accent
        review.attributedTitle = attributed("Exclude reviews", size: 12, color: Theme.muted)
        review.state = UserDefaults.standard.object(forKey: "timeline-exclude-reviews") as? Bool == false ? .off : .on
        review.target = self; review.action = #selector(toggleReviews)
        zoom.showsChevron = true
        zoom.actionBlock = { [weak self] in self?.showZoomMenu() }
        now.actionBlock = { [weak self] in guard let self else { return }; self.setSessions(self.sessions); self.canvas.scroll(to: nil) }
        date.changed = { [weak self] _ in self?.jumpDate() }; date.submitted = { [weak self] _ in self?.jumpDate() }
        calendar.actionBlock = { [weak self] in self?.showCalendar() }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            guard let self, !self.isHidden, self.scroll.contentView.bounds.minY < 10 else { return }; self.setSessions(self.sessions)
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    func setSessions(_ sessions: [Session]) { self.sessions = sessions; canvas.configure(sessions, review.state == .on, levels[zoomIndex]) }
    func hideTooltip() { canvas.hideTooltip() }
    override func layout() {
        super.layout(); heading.frame = NSRect(x: 20, y: 14, width: 180, height: 25)
        now.frame = NSRect(x: bounds.width - 80, y: 12, width: 60, height: 29)
        calendar.frame = NSRect(x: now.frame.minX - 39, y: 12, width: 27, height: 29)
        date.frame = NSRect(x: calendar.frame.minX - 108, y: 12, width: 112, height: 29)
        jumpLabel.frame = NSRect(x: date.frame.minX - 55, y: 18, width: 50, height: 19)
        zoom.frame = NSRect(x: jumpLabel.frame.minX - 110, y: 12, width: 98, height: 29)
        zoomLabel.frame = NSRect(x: zoom.frame.minX - 48, y: 18, width: 43, height: 19)
        review.frame = NSRect(x: zoomLabel.frame.minX - 140, y: 15, width: 128, height: 24)
        scroll.frame = NSRect(x: 0, y: 50, width: bounds.width, height: max(0, bounds.height - 50)); canvas.resizeIfNeeded()
    }
    override func draw(_ dirtyRect: NSRect) { Theme.background.setFill(); bounds.fill(); Theme.border.setFill(); NSRect(x: 0, y: 49, width: bounds.width, height: 1).fill() }
    @objc private func toggleReviews() { UserDefaults.standard.set(review.state == .on, forKey: "timeline-exclude-reviews"); setSessions(sessions) }
    func stepZoom(_ direction: Int) { zoomIndex = min(levels.count - 1, max(0, zoomIndex + direction)); zoom.title = names[zoomIndex]; zoom.setAccessibilityLabel(names[zoomIndex]); zoom.needsDisplay = true; setSessions(sessions) }
    private func showZoomMenu() {
        let menu = NSMenu()
        for (index, name) in names.enumerated() { let item = NSMenuItem(title: name, action: #selector(chooseZoom(_:)), keyEquivalent: ""); item.target = self; item.tag = index; item.state = index == zoomIndex ? .on : .off; menu.addItem(item) }
        menu.popUp(positioning: menu.item(at: zoomIndex), at: NSPoint(x: 0, y: zoom.bounds.height), in: zoom)
    }
    @objc private func chooseZoom(_ item: NSMenuItem) { stepZoom(item.tag - zoomIndex) }
    private func jumpDate() {
        for format in ["M/d/yyyy", "yyyy-MM-dd"] {
            let formatter = DateFormatter(); formatter.dateFormat = format; formatter.isLenient = false
            if let value = formatter.date(from: date.field.stringValue) { jump(value); break }
        }
    }
    private func jump(_ value: Date) {
        let end = Calendar.current.date(bySettingHour: 23, minute: 59, second: 59, of: value) ?? value
        canvas.scroll(to: min(Date().timeIntervalSince1970, end.timeIntervalSince1970) * 1000)
    }
    private func showCalendar() {
        let controller = NSViewController(); controller.view = NSView(frame: NSRect(x: 0, y: 0, width: 270, height: 190))
        let picker = NSDatePicker(frame: NSRect(x: 10, y: 10, width: 250, height: 170)); picker.datePickerStyle = .clockAndCalendar; picker.datePickerElements = .yearMonthDay
        picker.target = self; picker.action = #selector(chooseDate(_:)); controller.view.addSubview(picker)
        let popover = NSPopover(); popover.contentViewController = controller; popover.behavior = .transient; self.popover = popover
        popover.show(relativeTo: calendar.bounds, of: calendar, preferredEdge: .maxY)
    }
    @objc private func chooseDate(_ picker: NSDatePicker) { let formatter = DateFormatter(); formatter.dateFormat = "M/d/yyyy"; date.field.stringValue = formatter.string(from: picker.dateValue); jump(picker.dateValue) }
}
