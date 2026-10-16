import AppKit
import Combine

final class SidebarView: FlippedView {
    let query = InputView("Search sessions")
    let pinned = SessionList(), list = SessionList()
    let filters = ["All", "Claude", "Codex", "Cursor"].map { ActionButton($0) }
    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(query); pinned.pinned = true; addSubview(pinned.scroll); addSubview(list.scroll)
        for button in filters { button.capsule = true; button.hoverStyle = false; button.fill = Theme.background; addSubview(button) }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    override func layout() {
        super.layout(); query.frame = NSRect(x: 12, y: 0, width: bounds.width - 25, height: 33)
        let width = (bounds.width - 43) / 4
        for (index, button) in filters.enumerated() { button.frame = NSRect(x: 12 + CGFloat(index) * (width + 6), y: 43, width: width, height: 27) }
        let height = pinned.rows.isEmpty ? 0 : min(bounds.height / 2, pinned.totalHeight + 6)
        pinned.scroll.isHidden = height == 0
        pinned.scroll.frame = NSRect(x: 4, y: 78, width: bounds.width - 9, height: height)
        let y: CGFloat = 78 + height + (height == 0 ? 0 : 6)
        list.scroll.frame = NSRect(x: 4, y: y, width: bounds.width - 9, height: max(0, bounds.height - y - 8))
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        Theme.background.setFill(); bounds.fill(); Theme.border.setFill(); NSRect(x: bounds.width - 1, y: 0, width: 1, height: bounds.height).fill()
        if !pinned.rows.isEmpty { NSRect(x: 0, y: pinned.scroll.frame.maxY, width: bounds.width, height: 1).fill() }
    }
}
final class SessionsContent: FlippedView {
    let store: SessionStore
    let sidebar = SidebarView(frame: .zero), transcript = TranscriptPane(frame: .zero)
    let timeline = TimelinePane(frame: .zero)
    let sessionsButton = ActionButton("Sessions", size: 13), timelineButton = ActionButton("Timeline", size: 13)
    private var cancellables = Set<AnyCancellable>()
    private var scheduled = false
    private var lastTimelineSessions: [Session] = []
    private var lastJump = ""
    private var menuActions: [() -> Void] = []
    init(store: SessionStore) {
        self.store = store
        super.init(frame: .zero)
        for view in [sidebar, transcript, timeline, sessionsButton, timelineButton] { addSubview(view) }
        for button in [sessionsButton, timelineButton] { button.showBorder = false; button.hoverStyle = false; button.fill = Theme.background; button.radius = 5 }
        sessionsButton.actionBlock = { [weak self] in self?.store.mode = "Sessions" }
        timelineButton.actionBlock = { [weak self] in self?.store.mode = "Timeline" }
        sidebar.query.changed = { [weak self] in self?.store.query = $0 }
        for (index, button) in sidebar.filters.enumerated() {
            let tool = ["all", "claude", "codex", "cursor"][index]; button.dot = tool
            button.actionBlock = { [weak self] in self?.store.tool = tool }
        }
        for list in [sidebar.pinned, sidebar.list] {
            list.select = { [weak self] in self?.store.select($0) }
            list.pin = { [weak self] in self?.store.togglePin($0) }
            list.menu = { [weak self] session in self?.contextMenu(session) ?? NSMenu() }
        }
        transcript.copyCommand = { [weak self] in self?.store.copy($0) }
        timeline.open = { [weak self] row in self?.lastJump = ""; self?.store.mode = "Sessions"; self?.store.select(row.sessionKey, messageIndex: row.messageIndex) }
        store.objectWillChange.sink { [weak self] _ in self?.scheduleUpdate() }.store(in: &cancellables)
        update()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    private func scheduleUpdate() {
        guard !scheduled else { return }; scheduled = true
        DispatchQueue.main.async { [weak self] in self?.scheduled = false; self?.update() }
    }
    func update() {
        let mode = store.mode == "Timeline"
        sidebar.isHidden = mode; transcript.isHidden = mode; timeline.isHidden = !mode
        if !mode { timeline.hideTooltip() }
        sessionsButton.active = !mode; timelineButton.active = mode
        sessionsButton.ink = mode ? Theme.muted : Theme.text; timelineButton.ink = mode ? Theme.text : Theme.muted
        sessionsButton.needsDisplay = true; timelineButton.needsDisplay = true
        let terms = queryTerms(store.query), pins = Set(store.pins)
        let rows = store.visible.sorted { $0.updatedAt > $1.updatedAt }
        sidebar.pinned.apply(rows.filter { pins.contains($0.key) }, terms: terms, live: store.live, selected: store.selectedKey)
        sidebar.list.apply(rows.filter { !pins.contains($0.key) }, terms: terms, live: store.live, selected: store.selectedKey)
        for (index, button) in sidebar.filters.enumerated() {
            button.active = store.tool == ["all", "claude", "codex", "cursor"][index]
            button.ink = button.active ? Theme.text : Theme.muted; button.needsDisplay = true
        }
        if let detail = store.detail { transcript.show(detail, live: store.live.contains(detail.key)) }
        else { transcript.show(nil, live: false, message: !store.detailError.isEmpty ? "Could not read this session" : store.selectedKey == nil ? "Select a session" : "Loading…") }
        if lastTimelineSessions != store.sessions { lastTimelineSessions = store.sessions; timeline.setSessions(store.sessions) }
        if let index = store.jumpToMessage, let key = store.detail?.key {
            let jump = "\(key):\(index)"
            if jump != lastJump { lastJump = jump; DispatchQueue.main.async { [weak self] in self?.transcript.jump(to: index) } }
        } else { lastJump = "" }
        needsLayout = true
    }
    override func layout() {
        super.layout()
        sessionsButton.frame = NSRect(x: bounds.midX - 98, y: 11, width: 96, height: 26)
        timelineButton.frame = NSRect(x: bounds.midX - 2, y: 11, width: 100, height: 26)
        sidebar.frame = NSRect(x: 0, y: 48, width: 380, height: max(0, bounds.height - 48)); sidebar.needsLayout = true
        transcript.frame = NSRect(x: 380, y: 48, width: max(0, bounds.width - 380), height: max(0, bounds.height - 48))
        timeline.frame = NSRect(x: 0, y: 48, width: bounds.width, height: max(0, bounds.height - 48))
    }
    override func draw(_ dirtyRect: NSRect) { Theme.background.setFill(); bounds.fill(); rounded(NSRect(x: bounds.midX - 102, y: 7, width: 204, height: 34), 8, fill: Theme.background, border: Theme.border) }
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if point.y < 48 { if event.clickCount == 2 { window?.performZoom(nil) } else { window?.performDrag(with: event) } }
        else { super.mouseDown(with: event) }
    }
    func focusFind() { if store.detail != nil && store.mode != "Timeline" { transcript.header.find.focus() } else { sidebar.query.focus() } }
    func zoom(_ direction: Int) { if store.mode == "Timeline" { timeline.stepZoom(direction) } }
    private func contextMenu(_ session: Session) -> NSMenu {
        let menu = NSMenu(); menu.autoenablesItems = false; menuActions = []
        func item(_ title: String, _ enabled: Bool = true, _ action: @escaping () -> Void) {
            let item = NSMenuItem(title: title, action: #selector(menuAction(_:)), keyEquivalent: ""); item.target = self; item.tag = menuActions.count; item.isEnabled = enabled
            menu.addItem(item); menuActions.append(action)
        }
        item(store.pins.contains(session.key) ? "Unpin" : "Pin to Top") { self.store.togglePin(session.key) }
        menu.addItem(.separator()); item("Copy Command") { self.store.copy(session.resumeCommand) }; menu.addItem(.separator())
        for (title, value) in [("Copy Title", session.title), ("Copy Session ID", session.id), ("Copy Working Directory", session.cwd), ("Copy Transcript Path", session.filePath)] { item(title, !value.isEmpty) { self.store.copy(value) } }
        return menu
    }
    @objc private func menuAction(_ sender: NSMenuItem) { if menuActions.indices.contains(sender.tag) { menuActions[sender.tag]() } }
}
