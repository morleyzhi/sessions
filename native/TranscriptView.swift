import AppKit

struct Turn {
    var id: Int
    var messages: [Message]
    var role: String { messages.first!.toolCalls == nil ? messages.first!.role : "assistant" }
    var isSidechain: Bool { messages.first!.isSidechain }
}
func groupTurns(_ messages: [Message]) -> [Turn] {
    var turns: [Turn] = []
    for (index, message) in messages.enumerated() {
        if let calls = message.toolCalls, calls.isEmpty { continue }
        let role = message.toolCalls == nil ? message.role : "assistant"
        if let last = turns.last, role == "assistant", last.role == role, last.isSidechain == message.isSidechain { turns[turns.count - 1].messages.append(message) }
        else { turns.append(Turn(id: index, messages: [message])) }
    }
    return turns
}
final class TurnHeader: NSButton {
    var role = "", time = "", open = true
    init(action: @escaping () -> Void) {
        super.init(frame: .zero); isBordered = false; setButtonType(.momentaryPushIn)
        self.block = action; target = self; self.action = #selector(invoke)
    }
    private var block: () -> Void = {}
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    override var isFlipped: Bool { true }
    @objc private func invoke() { block() }
    override func draw(_ dirtyRect: NSRect) {
        let ink = role.hasPrefix("user") ? Theme.accent : Theme.muted
        let y: CGFloat = open ? 0 : 8
        drawText(open ? "▾" : "▸", in: NSRect(x: 0, y: y + 1, width: 10, height: 14), size: 9, color: ink)
        let text = NSMutableAttributedString(attributedString: attributed(role.uppercased(), size: 10.5, color: ink))
        text.addAttribute(.kern, value: 0.6, range: NSRange(location: 0, length: text.length)); text.draw(at: NSPoint(x: 20, y: y))
        let width = (time as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 10.5)]).width
        drawText(time, in: NSRect(x: bounds.width - width, y: y, width: width, height: 17), size: 10.5, color: Theme.muted)
    }
}
final class FadeView: FlippedView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) { NSGradient(starting: Theme.panel.withAlphaComponent(0), ending: Theme.panel)?.draw(in: bounds, angle: 90) }
}
final class ToolGroupView: FlippedView {
    let content: MarkdownView
    let header: ActionButton
    private let calls: [ToolCall]
    private let names: String
    var open = false
    var changed: (() -> Void)?
    init(_ calls: [ToolCall]) {
        self.calls = calls
        content = MarkdownView(calls.map { $0.name + "   " + $0.summary }.joined(separator: "\n"), plain: true)
        names = Array(NSOrderedSet(array: calls.map(\.name))).prefix(4).compactMap { $0 as? String }.joined(separator: ", ")
        header = ActionButton("▸  \(calls.count) tool \(calls.count == 1 ? "call" : "calls")    \(names)", size: 11.5)
        super.init(frame: .zero); addSubview(header); addSubview(content)
        header.showBorder = false; header.hoverStyle = false; header.textAlignment = .left; header.ink = Theme.muted; header.fill = Theme.panel
        header.actionBlock = { [weak self] in guard let self else { return }; self.open.toggle(); self.changed?() }
        for text in content.texts {
            let value = NSMutableAttributedString(attributedString: text.original)
            let paragraph = NSMutableParagraphStyle(); paragraph.minimumLineHeight = 21.25; paragraph.maximumLineHeight = 21.25; paragraph.lineBreakMode = .byTruncatingTail
            value.addAttributes([.font: NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular), .paragraphStyle: paragraph], range: NSRange(location: 0, length: value.length))
            var offset = 0
            for call in calls {
                value.addAttributes([.font: NSFont.systemFont(ofSize: 11.5), .foregroundColor: Theme.text], range: NSRange(location: offset, length: (call.name as NSString).length))
                offset += ((call.name + "   " + call.summary + "\n") as NSString).length
            }
            text.original = value; text.textStorage?.setAttributedString(value)
            text.reveal = { [weak self] in self?.open = true }
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    func measure(_ width: CGFloat) -> CGFloat {
        header.frame = NSRect(x: 1, y: 1, width: width - 2, height: 31)
        let title = NSMutableAttributedString(attributedString: attributed((open ? "▾" : "▸") + "  ", size: 9, color: Theme.muted, truncate: true))
        title.append(attributed("\(calls.count) tool \(calls.count == 1 ? "call" : "calls")", size: 11.5, truncate: true))
        title.append(attributed("    " + names, size: 11.5, color: Theme.muted, truncate: true))
        header.drawingTitle = title
        let height = content.measure(max(1, width - 22))
        content.frame = NSRect(x: 11, y: 39, width: width - 22, height: height); content.isHidden = !open
        return open ? 47 + height : 33
    }
    override func draw(_ dirtyRect: NSRect) { rounded(bounds, 8, fill: Theme.panel, border: Theme.border); if open { Theme.border.setFill(); NSRect(x: 0, y: 33, width: bounds.width, height: 1).fill() } }
}
final class TurnView: FlippedView {
    let turn: Turn
    let header: TurnHeader
    let clip = FlippedView(), content = FlippedView(), fade = FadeView()
    let expand = ActionButton("Expand")
    var items: [NSView] = [], texts: [TranscriptText] = []
    var open = true, expanded = false, timelineSelected = false
    var changed: (() -> Void)?
    private(set) var long = false
    private(set) var bubbleHeight: CGFloat = 0
    init(_ turn: Turn) {
        self.turn = turn; header = TurnHeader(action: {})
        super.init(frame: .zero)
        header.role = turn.role + (turn.isSidechain ? " · subagent" : "")
        header.title = header.role.uppercased()
        header.time = turn.messages.first?.timestamp.map(turnTime) ?? ""
        header.target = self; header.action = #selector(toggleOpen)
        header.setAccessibilityLabel(header.role + ", " + header.time)
        addSubview(header); addSubview(clip); clip.addSubview(content); clip.addSubview(fade); addSubview(expand)
        clip.wantsLayer = true; clip.layer?.masksToBounds = true; clip.layer?.cornerRadius = 7
        alphaValue = turn.isSidechain ? 0.6 : 1
        for message in turn.messages {
            if let calls = message.toolCalls {
                let tools = ToolGroupView(calls); tools.changed = { [weak self] in self?.changed?() }
                items.append(tools); texts += tools.content.texts
            } else { let text = MarkdownView(message.text); items.append(text); texts += text.texts }
        }
        for item in items { content.addSubview(item) }
        expand.fill = Theme.hover
        expand.actionBlock = { [weak self] in guard let self else { return }; self.expanded.toggle(); self.changed?() }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    @objc private func toggleOpen() { open.toggle(); changed?() }
    func measure(_ width: CGFloat) -> CGFloat {
        header.open = open; header.frame = NSRect(x: 0, y: 0, width: width, height: open ? 16 : 32); header.needsDisplay = true
        clip.isHidden = !open; expand.isHidden = true
        guard open else { bubbleHeight = 0; return 36 }
        var y: CGFloat = 0
        for (index, item) in items.enumerated() {
            if index > 0 { y += 8 }
            let height = (item as? MarkdownView)?.measure(width - 28) ?? (item as! ToolGroupView).measure(width - 28)
            item.frame = NSRect(x: 0, y: y, width: width - 28, height: height); y += height
        }
        let fullHeight = y + 22
        long = fullHeight > 600; bubbleHeight = long && !expanded ? 400 : fullHeight
        clip.frame = NSRect(x: 1, y: 21, width: width - 2, height: bubbleHeight - 2)
        content.frame = NSRect(x: 13, y: 10, width: width - 28, height: y)
        fade.frame = NSRect(x: 0, y: bubbleHeight - 66, width: width - 2, height: 64); fade.isHidden = !long || expanded
        var height = 20 + bubbleHeight
        if long {
            expand.isHidden = false; expand.title = expanded ? "Retract" : "Expand"
            expand.frame = NSRect(x: (width - 76) / 2, y: height + 6, width: 76, height: 29); height += 35
        }
        needsDisplay = true; return height
    }
    override func draw(_ dirtyRect: NSRect) {
        if open { rounded(NSRect(x: 0, y: 20, width: bounds.width, height: bubbleHeight), 8, fill: Theme.panel, border: timelineSelected ? Theme.accent : turn.role == "user" ? Theme.accent.withAlphaComponent(0.3) : Theme.border, width: timelineSelected ? 2 : 1) }
    }
}
final class TranscriptHeader: FlippedView {
    let title = label(size: 17, weight: .bold, selectable: true)
    let metadata = label(size: 12, color: Theme.muted, selectable: true)
    let timestamp = label(size: 12, color: Theme.muted)
    let notice = label(size: 12)
    let command = label(size: 11.5, color: Theme.muted, selectable: true)
    let copy = ActionButton("Copy resume command")
    let find = InputView("Find in this session", size: 12.5)
    let count = label(size: 11.5, color: Theme.muted)
    let previous = ActionButton("↑"), next = ActionButton("↓")
    var session: Session?, live = false
    private var pill = NSRect.zero, noticeBox = NSRect.zero
    override init(frame: NSRect) {
        super.init(frame: frame)
        for view in [title, metadata, timestamp, notice, command, copy, find, count, previous, next] { addSubview(view) }
        command.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular); command.lineBreakMode = .byClipping; command.cell?.isScrollable = true
        count.alignment = .right
        for field in [title, metadata, notice] { field.usesSingleLineMode = false; field.maximumNumberOfLines = 0; field.lineBreakMode = .byWordWrapping; field.cell?.wraps = true }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    func measure(_ width: CGFloat) -> CGFloat {
        guard let session else { return 0 }
        title.stringValue = session.title
        let titleHeight = max(22, ceil(attributed(session.title, size: 17, weight: .bold).boundingRect(with: NSSize(width: width - 48, height: 10000), options: [.usesLineFragmentOrigin, .usesFontLeading]).height) + 2)
        title.frame = NSRect(x: 24, y: 4, width: width - 48, height: titleHeight)
        let subtitleY = title.frame.maxY + 6
        let pillWidth = ceil((session.toolName as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11)]).width) + 29
        pill = NSRect(x: 24, y: subtitleY - 1, width: pillWidth, height: 21)
        let date = DateFormatter(); date.dateFormat = "M/d/yyyy, h:mm:ss a"
        metadata.stringValue = session.cwd.isEmpty ? "no working directory" : session.cwd
        timestamp.stringValue = date.string(from: Date(timeIntervalSince1970: session.updatedAt / 1000))
        let directoryWidth = ceil(attributed(metadata.stringValue, size: 12).size().width) + 4
        var x = pill.maxX + 10, rowY = subtitleY
        if directoryWidth > width - 24 - x { x = 24; rowY += 30 }
        let directoryHeight = max(20, ceil(attributed(metadata.stringValue, size: 12).boundingRect(with: NSSize(width: min(directoryWidth, width - 48), height: 10000), options: [.usesLineFragmentOrigin, .usesFontLeading]).height) + 2)
        metadata.frame = NSRect(x: x, y: rowY, width: min(directoryWidth, width - 48), height: directoryHeight)
        let dateWidth = ceil(timestamp.intrinsicContentSize.width)
        x = metadata.frame.maxX + 10
        if dateWidth > width - 24 - x { x = 24; rowY = metadata.frame.maxY + 10 }
        timestamp.frame = NSRect(x: x, y: rowY, width: min(dateWidth, width - 48), height: 20)
        var y = max(pill.maxY, metadata.frame.maxY, timestamp.frame.maxY)
        notice.isHidden = !live
        if live {
            notice.stringValue = "This session is open in a running \(session.toolName). Resuming it will fail until you quit that process."
            let height = ceil(attributed(notice.stringValue, size: 12, lineHeight: 18).boundingRect(with: NSSize(width: width - 70, height: 10000), options: [.usesLineFragmentOrigin, .usesFontLeading]).height)
            noticeBox = NSRect(x: 24, y: y + 12, width: width - 48, height: height + 18)
            notice.frame = NSRect(x: 35, y: noticeBox.minY + 8, width: width - 70, height: height + 2); y = noticeBox.maxY
        }
        command.stringValue = session.resumeCommand
        let copyWidth = ceil((copy.title as NSString).size(withAttributes: [.font: copy.font!]).width) + 30
        copy.frame = NSRect(x: width - 24 - copyWidth, y: y + 12, width: copyWidth, height: 32)
        command.frame = NSRect(x: 35, y: y + 20, width: max(20, copy.frame.minX - 54), height: 17)
        y += 52
        let countWidth: CGFloat = count.stringValue.isEmpty ? 64 : max(64, count.intrinsicContentSize.width)
        find.frame = NSRect(x: 24, y: y, width: max(20, width - 48 - countWidth - 76), height: 29)
        count.frame = NSRect(x: find.frame.maxX + 8, y: y + 6, width: countWidth, height: 18)
        previous.frame = NSRect(x: width - 84, y: y + 1, width: 26, height: 26)
        next.frame = NSRect(x: width - 50, y: y + 1, width: 26, height: 26)
        needsDisplay = true; return y + 45
    }
    override func draw(_ dirtyRect: NSRect) {
        Theme.background.setFill(); bounds.fill(); Theme.border.setFill(); NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
        guard let session else { return }
        rounded(pill, 11, fill: Theme.panel, border: Theme.border)
        drawDot(session.tool, NSRect(x: pill.minX + 8, y: pill.minY + 7, width: 7, height: 7))
        drawText(session.toolName, in: NSRect(x: pill.minX + 20, y: pill.minY + 3, width: pill.width - 24, height: 17), size: 11)
        if live { rounded(noticeBox, 6, fill: Theme.accent.withAlphaComponent(0.09), border: Theme.accent.withAlphaComponent(0.35)) }
        rounded(NSRect(x: 24, y: copy.frame.minY, width: max(20, copy.frame.minX - 32), height: 32), 6, fill: Theme.panel, border: Theme.border)
    }
}
final class TranscriptPane: FlippedView {
    let document = FlippedView(), header = TranscriptHeader(frame: .zero)
    let scroll: NSScrollView
    let bottom = ActionButton("↓ Scroll to bottom")
    let empty = label("Select a session", color: Theme.muted)
    var session: Session?, turns: [TurnView] = []
    private(set) var matches: [(TurnView, TranscriptText, NSRange)] = []
    private(set) var matchIndex = 0
    private var findTerm = "", findRequest = 0
    private var observer: NSObjectProtocol?
    var copyCommand: ((String) -> Void)?
    override init(frame: NSRect) {
        scroll = scrollView(document)
        (scroll.verticalScroller as? ThinScroller)?.alwaysVisible = true
        super.init(frame: frame); addSubview(scroll); addSubview(header); addSubview(bottom); addSubview(empty)
        header.copy.fill = Theme.hover; bottom.fill = Theme.hover
        empty.alignment = .center; header.isHidden = true; scroll.isHidden = true; bottom.isHidden = true
        header.find.changed = { [weak self] term in
            guard let self else { return }; self.findRequest += 1; let request = self.findRequest
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { if self.findRequest == request { self.applyFind(term) } }
        }
        header.find.submitted = { [weak self] flags in self?.moveMatch(flags.contains(.shift) ? -1 : 1) }
        header.previous.actionBlock = { [weak self] in self?.moveMatch(-1) }; header.next.actionBlock = { [weak self] in self?.moveMatch(1) }
        header.copy.actionBlock = { [weak self] in
            guard let self, let session = self.session else { return }; self.copyCommand?(session.resumeCommand)
            self.header.copy.title = "Copied — paste in iTerm2"; self.header.copy.ink = Theme.tool("codex"); self.header.copy.stroke = Theme.tool("codex"); self.header.copy.needsDisplay = true; self.relayout()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.header.copy.title = "Copy resume command"; self.header.copy.ink = Theme.text; self.header.copy.stroke = Theme.border; self.header.copy.needsDisplay = true; self.relayout() }
        }
        bottom.actionBlock = { [weak self] in guard let self else { return }; self.scrollTo(self.document.bounds.height - self.scroll.contentSize.height) }
        observer = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak self] _ in self?.updateBottom() }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    func show(_ session: Session?, live: Bool, message: String = "Select a session") {
        if self.session?.key == session?.key, header.live == live, session != nil || empty.stringValue == message { return }
        if self.session?.key != session?.key || (self.session == nil && session != nil) {
            for turn in turns { turn.removeFromSuperview() }; turns = []
            self.session = session; findTerm = ""; header.find.field.stringValue = ""; header.count.stringValue = ""; matches = []
            if let session {
                turns = groupTurns(session.messages).map { TurnView($0) }
                for turn in turns { document.addSubview(turn); turn.changed = { [weak self] in self?.relayout() } }
            }
            scrollTo(0)
        }
        header.session = session; header.live = live
        header.isHidden = session == nil; scroll.isHidden = session == nil; empty.isHidden = session != nil; empty.stringValue = message
        needsLayout = true
    }
    override func layout() { super.layout(); relayout() }
    func relayout() {
        scroll.frame = bounds
        empty.frame = NSRect(x: 24, y: 40, width: max(0, bounds.width - 48), height: 25)
        guard session != nil else { bottom.isHidden = true; return }
        let width = max(100, bounds.width - 11)
        let headerHeight = header.measure(width); header.frame = NSRect(x: 0, y: 0, width: width, height: headerHeight)
        var y = headerHeight + 16
        for turn in turns { let height = turn.measure(max(50, width - 48)); turn.frame = NSRect(x: 24, y: y, width: max(50, width - 48), height: height); y += height + 18 }
        document.frame = NSRect(x: 0, y: 0, width: width, height: max(bounds.height, y + 42))
        bottom.frame = NSRect(x: bounds.width - 179, y: bounds.height - 49, width: 147, height: 29)
        updateBottom()
    }
    private func updateBottom() { bottom.isHidden = session == nil || document.bounds.height - scroll.contentView.bounds.maxY <= 32 }
    private func scrollTo(_ y: CGFloat) { scroll.contentView.scroll(to: NSPoint(x: 0, y: min(max(0, y), max(0, document.bounds.height - scroll.contentSize.height)))); scroll.reflectScrolledClipView(scroll.contentView); updateBottom() }
    func applyFind(_ term: String) {
        findTerm = term; matches = []; matchIndex = 0
        for turn in turns {
            turn.open = true; turn.expanded = false
            for item in turn.items { (item as? ToolGroupView)?.open = false }
        }
        for turn in turns { for text in turn.texts { let ranges = text.find(term); text.highlight(ranges); matches += ranges.map { (turn, text, $0) } } }
        header.count.stringValue = term.isEmpty ? "" : matches.isEmpty ? "no matches" : "1 of \(matches.count)"
        if !matches.isEmpty { focusMatch(0) } else { relayout() }
    }
    func moveMatch(_ direction: Int) { if !matches.isEmpty { focusMatch((matchIndex + direction + matches.count) % matches.count) } }
    private func focusMatch(_ index: Int) {
        matchIndex = index
        for turn in turns { for text in turn.texts { text.highlight(text.find(findTerm)) } }
        let (turn, text, range) = matches[index]; turn.open = true; text.reveal?(); relayout()
        if let manager = text.layoutManager, let container = text.textContainer {
            let glyphs = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            var rect = text.convert(manager.boundingRect(forGlyphRange: glyphs, in: container), to: document)
            if turn.long && !turn.expanded && rect.maxY > turn.frame.minY + 20 + turn.bubbleHeight - 64 { turn.expanded = true; relayout(); rect = text.convert(manager.boundingRect(forGlyphRange: glyphs, in: container), to: document) }
            scrollTo(rect.midY - (scroll.contentSize.height + header.frame.height) / 2)
        }
        text.highlight(text.find(findTerm), current: range); header.count.stringValue = "\(index + 1) of \(matches.count)"; relayout()
    }
    func jump(to index: Int) {
        guard let turn = turns.first(where: { $0.turn.id == index }) else { return }
        turn.open = true; turn.timelineSelected = true; relayout(); scrollTo(turn.frame.minY - header.frame.height - 16)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { turn.timelineSelected = false; turn.needsDisplay = true }
    }
}
