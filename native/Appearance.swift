import AppKit

func rgb(_ hex: Int, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: alpha)
}
enum Theme {
    static let background = rgb(0x0e0f12), panel = rgb(0x16181d), hover = rgb(0x1e2128)
    static let border = rgb(0x262932), text = rgb(0xe6e8ec), muted = rgb(0x8d93a1), accent = rgb(0x7aa2f7)
    static func tool(_ tool: String) -> NSColor { tool == "claude" ? rgb(0xd97757) : tool == "codex" ? rgb(0x10a37f) : rgb(0xb18cf0) }
}
func rounded(_ rect: NSRect, _ radius: CGFloat, fill: NSColor, border: NSColor? = nil, width: CGFloat = 1) {
    let path = NSBezierPath(roundedRect: rect.insetBy(dx: width / 2, dy: width / 2), xRadius: radius, yRadius: radius)
    fill.setFill(); path.fill()
    if let border { border.setStroke(); path.lineWidth = width; path.stroke() }
}
func attributed(_ text: String, size: CGFloat = 13, color: NSColor = Theme.text, weight: NSFont.Weight = .regular, lineHeight: CGFloat? = nil, truncate: Bool = false) -> NSAttributedString {
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineBreakMode = truncate ? .byTruncatingTail : .byWordWrapping
    if let lineHeight { paragraph.minimumLineHeight = lineHeight; paragraph.maximumLineHeight = lineHeight }
    return NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color, .paragraphStyle: paragraph])
}
func drawText(_ text: String, in rect: NSRect, size: CGFloat = 13, color: NSColor = Theme.text, weight: NSFont.Weight = .regular) {
    attributed(text, size: size, color: color, weight: weight, truncate: true).draw(in: rect)
}
func label(_ text: String = "", size: CGFloat = 13, color: NSColor = Theme.text, weight: NSFont.Weight = .regular, selectable: Bool = false) -> NSTextField {
    let field = NSTextField(labelWithString: text)
    field.font = .systemFont(ofSize: size, weight: weight); field.textColor = color
    field.isSelectable = selectable; field.lineBreakMode = .byTruncatingTail
    return field
}
class FlippedView: NSView { override var isFlipped: Bool { true } }
final class ActionButton: NSButton {
    var actionBlock: (() -> Void)?
    var fill = Theme.panel, stroke = Theme.border, ink = Theme.text
    var radius: CGFloat = 6
    var active = false, capsule = false, showBorder = true
    var dot: String?
    var showsChevron = false
    var textAlignment: NSTextAlignment = .center
    var drawingTitle: NSAttributedString? { didSet { needsDisplay = true } }
    var hovered = false
    var hoverStyle = true
    private var area: NSTrackingArea?
    init(_ title: String, size: CGFloat = 12, action: (() -> Void)? = nil) {
        super.init(frame: .zero)
        self.title = title; font = .systemFont(ofSize: size); isBordered = false; focusRingType = .none
        target = self; self.action = #selector(invoke); actionBlock = action
        setButtonType(.momentaryPushIn)
        setAccessibilityLabel(title)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    override var isFlipped: Bool { true }
    @objc func invoke() { actionBlock?() }
    override func updateTrackingAreas() {
        super.updateTrackingAreas(); if let area { removeTrackingArea(area) }
        area = NSTrackingArea(rect: bounds, options: [.activeInKeyWindow, .mouseEnteredAndExited], owner: self)
        addTrackingArea(area!)
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        rounded(bounds, capsule ? bounds.height / 2 : radius, fill: active || (hovered && hoverStyle) ? Theme.hover : fill, border: showBorder ? (hovered && hoverStyle ? Theme.accent : stroke) : nil)
        let size = font?.pointSize ?? 12
        let textWidth = (title as NSString).size(withAttributes: [.font: font!]).width
        let total = ceil(textWidth) + (dot == nil ? 0 : 12) + (showsChevron ? 18 : 0)
        let start = textAlignment == .left ? 11 : max(8, (bounds.width - total) / 2)
        var x = start
        if let dot { drawDot(dot, NSRect(x: x, y: (bounds.height - 7) / 2, width: 7, height: 7), alpha: active ? 1 : 0.55); x += 12 }
        let rect = NSRect(x: x, y: (bounds.height - size * 1.2) / 2, width: max(0, bounds.width - x - (textAlignment == .left ? 11 : start) - (showsChevron ? 18 : 0)), height: size * 1.4)
        if showsChevron {
            let center = NSPoint(x: bounds.width - start - 5, y: bounds.midY)
            let path = NSBezierPath(); path.move(to: NSPoint(x: center.x - 3.5, y: center.y - 1.75))
            path.line(to: NSPoint(x: center.x, y: center.y + 1.75)); path.line(to: NSPoint(x: center.x + 3.5, y: center.y - 1.75))
            ink.setStroke(); path.lineWidth = 1.3; path.lineCapStyle = .round; path.lineJoinStyle = .round; path.stroke()
        }
        if window?.firstResponder === self {
            rounded(bounds.insetBy(dx: 2, dy: 2), capsule ? (bounds.height - 4) / 2 : max(0, radius - 2), fill: .clear, border: Theme.accent.withAlphaComponent(0.65))
        }
        if let drawingTitle { drawingTitle.draw(in: rect) }
        else { drawText(title, in: rect, size: size, color: isEnabled ? ink : Theme.muted) }
    }
}
func drawDot(_ tool: String, _ rect: NSRect, alpha: CGFloat = 1) {
    NSGraphicsContext.saveGraphicsState(); NSBezierPath(ovalIn: rect).addClip()
    if tool == "all" {
        for (index, color) in [Theme.tool("claude"), Theme.tool("codex"), Theme.tool("cursor")].enumerated() {
            color.withAlphaComponent(alpha).setFill()
            let x = rect.minX + CGFloat(index) * rect.width / 3
            NSRect(x: x, y: rect.minY, width: rect.width / 3 + 0.3, height: rect.height).fill()
        }
    } else { Theme.tool(tool).withAlphaComponent(alpha).setFill(); rect.fill() }
    NSGraphicsContext.restoreGraphicsState()
}
final class InputView: FlippedView, NSTextFieldDelegate {
    let field = NSTextField()
    var changed: ((String) -> Void)?
    var submitted: ((NSEvent.ModifierFlags) -> Void)?
    var escaped: (() -> Void)?
    init(_ placeholder: String, size: CGFloat = 13) {
        super.init(frame: .zero)
        field.isBordered = false; field.drawsBackground = false; field.focusRingType = .none
        field.font = .systemFont(ofSize: size); field.textColor = Theme.text
        field.placeholderAttributedString = attributed(placeholder, size: size, color: Theme.muted)
        field.cell?.isScrollable = true; field.usesSingleLineMode = true
        field.delegate = self; addSubview(field)
        field.setAccessibilityLabel(placeholder)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    override func layout() { super.layout(); field.frame = NSRect(x: 10, y: (bounds.height - 19) / 2, width: max(0, bounds.width - 20), height: 19) }
    override func draw(_ dirtyRect: NSRect) {
        let focused = field.currentEditor() != nil
        rounded(bounds, 7, fill: Theme.panel, border: focused ? Theme.accent : Theme.border)
    }
    func focus() { window?.makeFirstResponder(field); field.selectText(nil) }
    func controlTextDidChange(_ obj: Notification) { changed?(field.stringValue) }
    func controlTextDidBeginEditing(_ obj: Notification) { needsDisplay = true }
    func controlTextDidEndEditing(_ obj: Notification) { needsDisplay = true }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if ["insertNewline:", "insertLineBreak:", "insertNewlineIgnoringFieldEditor:"].contains(NSStringFromSelector(commandSelector)) { submitted?(NSApp.currentEvent?.modifierFlags ?? []); return true }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) { field.stringValue = ""; changed?(""); escaped?(); return true }
        return false
    }
}
final class ThinScroller: NSScroller {
    override class func scrollerWidth(for controlSize: NSControl.ControlSize, scrollerStyle: NSScroller.Style) -> CGFloat { 11 }
    var alwaysVisible = false
    var pointerInside = false { didSet { needsDisplay = true } }
    private var dragging = false
    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {}
    override func trackKnob(with event: NSEvent) {
        dragging = true
        defer { dragging = false; needsDisplay = true }
        super.trackKnob(with: event)
    }
    override func drawKnob() {
        guard alwaysVisible || pointerInside || dragging else { return }
        let rect = rect(for: .knob)
        let narrow = isHorizontal ? NSRect(x: rect.minX + 3, y: rect.midY - 2.5, width: max(0, rect.width - 6), height: 5) : NSRect(x: rect.midX - 2.5, y: rect.minY + 3, width: 5, height: max(0, rect.height - 6))
        rounded(narrow, 3, fill: rgb(0x4d5361), width: 0)
    }
    private var isHorizontal: Bool { bounds.width > bounds.height }
}
class HoverScrollView: NSScrollView {
    private var hoverArea: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas(); if let hoverArea { removeTrackingArea(hoverArea) }
        hoverArea = NSTrackingArea(rect: .zero, options: [.inVisibleRect, .activeAlways, .mouseEnteredAndExited], owner: self)
        addTrackingArea(hoverArea!)
    }
    override func mouseEntered(with event: NSEvent) { setHovered(true) }
    override func mouseExited(with event: NSEvent) { setHovered(false) }
    private func setHovered(_ value: Bool) {
        (verticalScroller as? ThinScroller)?.pointerInside = value
        (horizontalScroller as? ThinScroller)?.pointerInside = value
    }
}
func scrollView(_ document: NSView) -> NSScrollView {
    let scroll = HoverScrollView(); scroll.documentView = document
    scroll.hasVerticalScroller = true; scroll.scrollerStyle = .legacy; scroll.autohidesScrollers = false
    scroll.verticalScroller = ThinScroller(); scroll.drawsBackground = false
    scroll.automaticallyAdjustsContentInsets = false; scroll.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
    scroll.contentView.postsBoundsChangedNotifications = true
    return scroll
}
func relativeTime(_ timestamp: Double) -> String {
    let minutes = Int(((Date().timeIntervalSince1970 * 1000 - timestamp) / 60000).rounded())
    if minutes < 1 { return "just now" }; if minutes < 60 { return "\(minutes)m ago" }
    let hours = Int((Double(minutes) / 60).rounded()); if hours < 24 { return "\(hours)h ago" }
    let days = Int((Double(hours) / 24).rounded()); if days < 30 { return "\(days)d ago" }
    let formatter = DateFormatter(); formatter.setLocalizedDateFormatFromTemplate("yMd")
    return formatter.string(from: Date(timeIntervalSince1970: timestamp / 1000))
}
func turnTime(_ timestamp: Double) -> String {
    let date = Date(timeIntervalSince1970: timestamp / 1000), formatter = DateFormatter()
    formatter.dateFormat = Calendar.current.isDateInToday(date) ? "h:mm a" : "MMM d, h:mm a"
    return formatter.string(from: date)
}
