import SwiftUI
import AppKit

struct TimelineView: View {
    @ObservedObject var store: SessionStore
    @AppStorage("timeline-exclude-reviews") private var excludeReviews = true
    @State private var zoom = 60
    @State private var date = Date()
    @State private var destination: Double?
    @State private var request = 0
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Toggle("Exclude reviews", isOn: $excludeReviews).toggleStyle(.checkbox)
                Spacer()
                DatePicker("Date", selection: $date, displayedComponents: .date).labelsHidden().frame(width: 125)
                    .onChange(of: date) { _, value in
                        destination = (Calendar.current.date(bySettingHour: 23, minute: 59, second: 59, of: value) ?? value).timeIntervalSince1970 * 1000; request += 1
                    }
                Button("Now") { destination = nil; request += 1 }
                Picker("Time per screen", selection: $zoom) { ForEach([15, 30, 60, 120, 240, 480, 1440], id: \.self) { Text($0 < 60 ? "\($0)m" : "\($0 / 60)h").tag($0) } }.frame(width: 200)
                Button { zoom = max(15, zoom / 2) } label: { Image(systemName: "plus.magnifyingglass") }.keyboardShortcut("+")
                Button { zoom = min(1440, zoom * 2) } label: { Image(systemName: "minus.magnifyingglass") }.keyboardShortcut("-")
            }.padding(12)
            Divider()
            NativeTimeline(sessions: store.sessions, excludeReviews: excludeReviews, zoom: zoom, destination: destination, request: request) { row in
                store.mode = "Sessions"; store.select(row.sessionKey, messageIndex: row.messageIndex)
            }
            HStack {
                Text("Activity by project, branch, and PR · click a prompt to open its transcript")
                Spacer()
                let untimed = store.sessions.reduce(0) { $0 + $1.untimed }
                if untimed > 0 { Text("\(untimed) prompts without timestamps") }
            }.font(.caption).foregroundStyle(.secondary).padding(10)
        }
    }
}
struct NativeTimeline: NSViewRepresentable {
    var sessions: [Session]
    var excludeReviews: Bool
    var zoom: Int
    var destination: Double?
    var request: Int
    var open: (TimelineRow) -> Void
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = TimelineScrollView()
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true; scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        let canvas = TimelineCanvas()
        canvas.open = open; scroll.documentView = canvas
        scroll.contentView.postsBoundsChangedNotifications = true
        canvas.observer = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak canvas] _ in canvas?.updateVisible() }
        return scroll
    }
    func updateNSView(_ view: NSScrollView, context: Context) {
        guard let canvas = view.documentView as? TimelineCanvas else { return }
        canvas.open = open
        if canvas.sessions != sessions || canvas.excludeReviews != excludeReviews || canvas.zoom != zoom {
            canvas.configure(sessions, excludeReviews, zoom)
        }
        if canvas.request != request { canvas.request = request; canvas.scroll(to: destination) }
    }
}
final class TimelineScrollView: NSScrollView {
    override func layout() {
        super.layout()
        (documentView as? TimelineCanvas)?.resizeIfNeeded()
    }
}
final class TimelinePromptElement: NSAccessibilityElement {
    var press: (() -> Void)?
    override func accessibilityPerformPress() -> Bool { press?(); return true }
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
    private var lanes: [String] = []
    private var labels: [String: String] = [:]
    private var scale = TimeScale(rows: [], now: Date().timeIntervalSince1970 * 1000, pixelsPerMS: 1)
    private var hitAreas: [(NSRect, TimelineRow)] = []
    private var viewportHeight = 0.0
    private let axis = 150.0, header = 48.0
    private var columnWidth = 280.0
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
        var previous: [String: Double] = [:]
        labels = [:]; rows = []
        for row in prompts {
            let y = max(scale.y(at: row.timestamp) + header, previous[row.lane] ?? header)
            previous[row.lane] = y + 28
            rows.append((row, y, scale.y(at: row.end) + header))
            labels[row.lane] = titles[row.lane] ?? row.label
        }
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
        visible = rows.filter { $0.1 + 28 >= rect.minY && $0.2 <= rect.maxY }
        let active = Set(visible.map { $0.0.lane })
        lanes = lanes.filter { active.contains($0) } + active.filter { !lanes.contains($0) }.sorted()
        columnWidth = max(260, (scroll.contentSize.width - axis) / Double(max(1, lanes.count)))
        let width = max(scroll.contentSize.width, axis + columnWidth * Double(lanes.count))
        if abs(frame.width - width) > 1 { setFrameSize(NSSize(width: width, height: frame.height)) }
        needsDisplay = true
    }
    private func color(_ lane: String) -> NSColor {
        let hash = lane.utf8.reduce(UInt32(0)) { ($0 &* 31) &+ UInt32($1) }
        return NSColor(calibratedHue: CGFloat(hash % 360) / 360, saturation: 0.5, brightness: 0.85, alpha: 1)
    }
    private func text(_ value: String, _ rect: NSRect, color: NSColor = .labelColor, size: CGFloat = 11, bold: Bool = false) {
        let style = NSMutableParagraphStyle(); style.lineBreakMode = .byTruncatingTail
        (value as NSString).draw(in: rect, withAttributes: [.font: bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size), .foregroundColor: color, .paragraphStyle: style])
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let scroll = enclosingScrollView else { return }
        let view = scroll.contentView.bounds
        NSColor.windowBackgroundColor.setFill(); dirtyRect.fill()
        hitAreas = []
        for (index, lane) in lanes.enumerated() {
            let x = axis + Double(index) * columnWidth
            color(lane).withAlphaComponent(0.045).setFill(); NSRect(x: x, y: view.minY, width: columnWidth - 1, height: view.height).fill()
        }
        let formatter = DateFormatter(); formatter.dateFormat = "MMM d · HH:mm:ss"
        var lastLabel = -Double.infinity
        for segment in scale.segments where segment.bottom + header >= view.minY && segment.top <= view.maxY {
            if segment.gap {
                let minutes = Int((segment.newer - segment.older) / 60000)
                let duration = minutes >= 1440 ? "\(minutes / 1440)d \(minutes % 1440 / 60)h" : minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
                text("↯ \(duration) skipped", NSRect(x: view.minX + 8, y: segment.top + header + 12, width: axis - 12, height: 20), color: .secondaryLabelColor)
                NSColor.separatorColor.setFill(); NSRect(x: axis, y: segment.top + header + 22, width: frame.width - axis, height: 1).fill()
                lastLabel = segment.bottom + header
                continue
            }
            let step = Double([5, 10, 15, 30, 60, 120, 180, 360].first(where: { $0 >= zoom / 8 }) ?? 360) * 60000
            var time = floor(min(segment.newer, scale.time(at: max(0, view.minY - header))) / step) * step
            while time >= segment.older {
                let y = scale.y(at: time) + header
                if y > view.maxY { break }
                if y >= view.minY, y - lastLabel >= 42 {
                    text(formatter.string(from: Date(timeIntervalSince1970: time / 1000)), NSRect(x: view.minX + 8, y: y, width: axis - 12, height: 20), color: .secondaryLabelColor)
                    NSColor.separatorColor.withAlphaComponent(0.3).setFill(); NSRect(x: axis, y: y + 20, width: frame.width - axis, height: 1).fill()
                    lastLabel = y
                }
                time -= step
            }
        }
        formatter.dateFormat = "HH:mm:ss"
        for (row, y, top) in visible {
            guard let index = lanes.firstIndex(of: row.lane) else { continue }
            let x = axis + Double(index) * columnWidth
            if row.end > row.timestamp {
                color(row.lane).withAlphaComponent(0.12).setFill()
                NSRect(x: x + 5, y: max(top, view.minY), width: columnWidth - 10, height: max(0, min(view.maxY, y + 25) - max(top, view.minY))).fill()
            }
            guard y + 28 >= view.minY, y <= view.maxY else { continue }
            let rect = NSRect(x: x + 8, y: y, width: columnWidth - 16, height: 25)
            NSColor.controlBackgroundColor.setFill(); NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
            color(row.lane).setFill(); NSRect(x: rect.minX, y: y, width: 3, height: 25).fill()
            text(formatter.string(from: Date(timeIntervalSince1970: row.timestamp / 1000)), NSRect(x: x + 17, y: y + 5, width: 58, height: 18), color: .secondaryLabelColor, size: 10)
            text(row.text, NSRect(x: x + 78, y: y + 4, width: columnWidth - 96, height: 20))
            hitAreas.append((rect, row))
        }
        NSColor.windowBackgroundColor.setFill(); NSRect(x: view.minX, y: view.minY, width: view.width, height: header).fill()
        text("TIME ↓", NSRect(x: view.minX + 12, y: view.minY + 16, width: axis - 24, height: 20), color: .secondaryLabelColor, bold: true)
        for (index, lane) in lanes.enumerated() {
            let x = axis + Double(index) * columnWidth
            color(lane).setFill(); NSRect(x: x, y: view.minY, width: columnWidth - 1, height: 3).fill()
            text(labels[lane] ?? lane, NSRect(x: x + 12, y: view.minY + 15, width: columnWidth - 24, height: 22), bold: true)
        }
        if rows.isEmpty { text("No timestamped prompts to show.", NSRect(x: 170, y: view.minY + 80, width: 500, height: 24), color: .secondaryLabelColor, size: 14) }
        removeAllToolTips()
        for (rect, row) in hitAreas { addToolTip(rect, owner: "\(labels[row.lane] ?? row.label)\n\(row.cwd)\n\(row.branch)\n\(row.text)\nClick to open this message" as NSString, userData: nil) }
    }
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard point.y > (enclosingScrollView?.contentView.bounds.minY ?? 0) + header else { return }
        if let row = hitAreas.last(where: { $0.0.contains(point) })?.1 { open?(row) }
    }
    override func accessibilityChildren() -> [Any]? {
        guard let window, let scroll = enclosingScrollView else { return [] }
        return hitAreas.filter { $0.0.minY >= scroll.contentView.bounds.minY + header }.map { rect, row in
            let element = TimelinePromptElement()
            element.setAccessibilityElement(true)
            element.setAccessibilityRole(.button)
            element.setAccessibilityLabel("\(labels[row.lane] ?? row.label): \(row.text)")
            element.setAccessibilityParent(self)
            element.setAccessibilityFrame(window.convertToScreen(convert(rect, to: nil)))
            element.press = { [weak self] in self?.open?(row) }
            return element
        }
    }
}
