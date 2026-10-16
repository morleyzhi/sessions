import AppKit

final class SessionCell: NSTableCellView {
    var session: Session!
    var selected = false, pinned = false, live = false, hovered = false
    var terms: [String] = []
    var pin: (() -> Void)?
    private var area: NSTrackingArea?
    override var isFlipped: Bool { true }
    override func updateTrackingAreas() {
        super.updateTrackingAreas(); if let area { removeTrackingArea(area) }
        area = NSTrackingArea(rect: bounds, options: [.activeInKeyWindow, .mouseEnteredAndExited], owner: self); addTrackingArea(area!)
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func mouseDown(with event: NSEvent) {
        if convert(event.locationInWindow, from: nil).x >= bounds.width - 29 { pin?() }
        else { super.mouseDown(with: event) }
    }
    static func height(_ session: Session, width: CGFloat, terms: [String]) -> CGFloat {
        let text = session.snippet(terms)
        if text.isEmpty { return 56 }
        let size = attributed(text, size: 11.5, color: Theme.muted, lineHeight: 17.25).boundingRect(with: NSSize(width: max(50, width - 18), height: 100), options: [.usesLineFragmentOrigin, .usesFontLeading])
        return 56 + min(34.5, size.height) + 3
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let session else { return }
        let rect = bounds.insetBy(dx: 0, dy: 0).offsetBy(dx: 0, dy: 0)
        let fill = pinned ? (selected ? rgb(0x2a3750) : hovered ? rgb(0x242e43) : rgb(0x1b2232)) : selected ? Theme.hover : hovered ? Theme.panel : Theme.background
        rounded(NSRect(x: 0, y: 0, width: rect.width, height: rect.height - (pinned ? 3 : 0)), 8, fill: fill, border: selected ? (pinned ? Theme.accent : Theme.border) : .clear)
        drawDot(session.tool, NSRect(x: 9, y: 15, width: 7, height: 7))
        let liveWidth: CGFloat = live ? 44 : 0
        let title = NSMutableAttributedString(attributedString: attributed(session.title, size: 13, weight: .medium, lineHeight: 19.5, truncate: true))
        mark(title)
        title.draw(in: NSRect(x: 23, y: 9, width: max(0, bounds.width - 56 - liveWidth), height: 20))
        if live {
            let badge = NSRect(x: bounds.width - 33 - 39, y: 9, width: 39, height: 17)
            rounded(badge, 8, fill: .clear, border: Theme.accent.withAlphaComponent(0.4))
            let text = NSMutableAttributedString(attributedString: attributed("LIVE", size: 9.5, color: Theme.accent))
            text.addAttribute(.kern, value: 0.6, range: NSRange(location: 0, length: text.length))
            text.draw(at: NSPoint(x: badge.minX + 6, y: badge.minY + 1))
        }
        if pinned || hovered {
            let center = NSPoint(x: bounds.width - 18, y: 17)
            NSGraphicsContext.saveGraphicsState()
            let transform = NSAffineTransform(); transform.translateX(by: center.x, yBy: center.y)
            if pinned { transform.rotate(byDegrees: 45) }; transform.concat()
            let path = NSBezierPath(); path.move(to: NSPoint(x: -3, y: -5)); path.line(to: NSPoint(x: 3, y: -5)); path.move(to: NSPoint(x: -2, y: -5)); path.line(to: NSPoint(x: -2, y: 0)); path.line(to: NSPoint(x: -4, y: 3)); path.line(to: NSPoint(x: 4, y: 3)); path.line(to: NSPoint(x: 2, y: 0)); path.line(to: NSPoint(x: 2, y: -5)); path.move(to: NSPoint(x: 0, y: 3)); path.line(to: NSPoint(x: 0, y: 7))
            (pinned ? Theme.accent : Theme.muted).setStroke(); path.lineWidth = 1.2; path.stroke(); NSGraphicsContext.restoreGraphicsState()
        }
        let project = session.project.isEmpty ? "—" : session.project
        let meta = project + "   " + relativeTime(session.updatedAt)
        drawText(meta, in: NSRect(x: 9, y: 30.5, width: bounds.width - 18, height: 17), size: 11, color: Theme.muted)
        let snippet = NSMutableAttributedString(attributedString: attributed(session.snippet(terms), size: 11.5, color: Theme.muted, lineHeight: 17.25))
        mark(snippet); snippet.draw(with: NSRect(x: 9, y: 50, width: bounds.width - 18, height: min(34.5, bounds.height - 50)), options: [.usesLineFragmentOrigin, .usesFontLeading, .truncatesLastVisibleLine])
    }
    private func mark(_ value: NSMutableAttributedString) {
        let source = value.string as NSString
        for term in terms {
            var range = NSRange(location: 0, length: source.length)
            while range.length > 0 {
                let found = source.range(of: term, options: .caseInsensitive, range: range)
                if found.location == NSNotFound { break }
                value.addAttributes([.backgroundColor: Theme.accent.withAlphaComponent(0.28), .foregroundColor: Theme.text], range: found)
                range = NSRange(location: NSMaxRange(found), length: source.length - NSMaxRange(found))
            }
        }
    }
}
final class SessionTableView: NSTableView {
    var menuForRow: ((Int) -> NSMenu?)?
    override func frameOfCell(atColumn column: Int, row: Int) -> NSRect {
        var rect = super.frameOfCell(atColumn: column, row: row)
        rect.origin.x = 0; rect.size.width = bounds.width
        return rect
    }
    override func menu(for event: NSEvent) -> NSMenu? { menuForRow?(row(at: convert(event.locationInWindow, from: nil))) }
}
final class SessionList: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let table = SessionTableView()
    let scroll: NSScrollView
    var rows: [Session] = []
    var terms: [String] = [], live: Set<String> = [], selected: String?
    var pinned = false
    private var applying = false
    var select: ((String) -> Void)?, pin: ((String) -> Void)?, menu: ((Session) -> NSMenu)?
    override init() {
        scroll = scrollView(table)
        super.init()
        scroll.autohidesScrollers = true
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("sessions")); column.resizingMask = .autoresizingMask
        table.addTableColumn(column); table.headerView = nil; table.dataSource = self; table.delegate = self
        table.style = .fullWidth; table.backgroundColor = Theme.background; table.intercellSpacing = .zero; table.selectionHighlightStyle = .none
        table.autoresizingMask = [.width]; table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle; table.focusRingType = .none
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        table.menuForRow = { [weak self] index in guard let self, self.rows.indices.contains(index) else { return nil }; return self.menu?(self.rows[index]) }
    }
    func apply(_ rows: [Session], terms: [String], live: Set<String>, selected: String?) {
        guard self.rows != rows || self.terms != terms || self.live != live || self.selected != selected else { return }
        let oldKeys = self.rows.map(\.key), newKeys = rows.map(\.key)
        let first = table.row(at: NSPoint(x: 0, y: scroll.contentView.bounds.minY))
        let anchor = self.rows.indices.contains(first) ? self.rows[first].key : nil
        let offset = first >= 0 ? scroll.contentView.bounds.minY - table.rect(ofRow: first).minY : 0
        let oldHeights = self.rows.map { SessionCell.height($0, width: table.bounds.width, terms: self.terms) }
        self.terms = terms; self.live = live; self.selected = selected
        applying = true
        if oldKeys != newKeys {
            let keys = Set(newKeys)
            NSAnimationContext.beginGrouping(); NSAnimationContext.current.duration = 0
            table.beginUpdates()
            for index in self.rows.indices.reversed() where !keys.contains(self.rows[index].key) {
                self.rows.remove(at: index); table.removeRows(at: IndexSet(integer: index), withAnimation: [])
            }
            for (index, session) in rows.enumerated() {
                if self.rows.indices.contains(index), self.rows[index].key == session.key { self.rows[index] = session }
                else if let previous = self.rows.firstIndex(where: { $0.key == session.key }) {
                    self.rows.remove(at: previous); self.rows.insert(session, at: index); table.moveRow(at: previous, to: index)
                } else { self.rows.insert(session, at: index); table.insertRows(at: IndexSet(integer: index), withAnimation: []) }
            }
            table.endUpdates(); NSAnimationContext.endGrouping()
        } else { self.rows = rows }
        var changedHeights = IndexSet()
        for index in rows.indices {
            if oldKeys != newKeys || index >= oldHeights.count || oldHeights[index] != SessionCell.height(rows[index], width: table.bounds.width, terms: terms) { changedHeights.insert(index) }
            if let cell = table.view(atColumn: 0, row: index, makeIfNecessary: false) as? SessionCell { configure(cell, session: rows[index]) }
        }
        if !changedHeights.isEmpty { table.noteHeightOfRows(withIndexesChanged: changedHeights) }
        if let index = rows.firstIndex(where: { $0.key == selected }) { table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false) } else { table.deselectAll(nil) }
        applying = false
        if oldKeys != newKeys, scroll.contentView.bounds.minY > 0, let anchor, let index = rows.firstIndex(where: { $0.key == anchor }) {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, table.rect(ofRow: index).minY + offset))); scroll.reflectScrolledClipView(scroll.contentView)
        }
    }
    var totalHeight: CGFloat { rows.reduce(0) { $0 + SessionCell.height($1, width: table.bounds.width, terms: terms) + (pinned ? 3 : 0) } }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { SessionCell.height(rows[row], width: tableView.bounds.width, terms: terms) + (pinned ? 3 : 0) }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("session")
        let view = tableView.makeView(withIdentifier: id, owner: self) as? SessionCell ?? SessionCell()
        view.identifier = id; configure(view, session: rows[row]); return view
    }
    private func configure(_ view: SessionCell, session: Session) {
        view.session = session; view.pinned = pinned; view.live = live.contains(session.key); view.selected = selected == session.key; view.terms = terms
        view.pin = { [weak self] in self?.pin?(session.key) }; view.needsDisplay = true
        view.setAccessibilityLabel(session.title + ", " + session.project + ", " + relativeTime(session.updatedAt))
    }
    func tableViewSelectionDidChange(_ notification: Notification) { guard !applying else { return }; let row = table.selectedRow; if rows.indices.contains(row) { select?(rows[row].key) } }
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        let item = NSPasteboardItem(); item.setString(rows[row].resumeCommand + "\n", forType: .string); return item
    }
}
