import AppKit

@main struct ViewTests {
    static func main() {
        _ = NSApplication.shared
        var count = 0
        func check(_ name: String, _ condition: @autoclosure () -> Bool) {
            guard condition() else { fatalError("FAIL: \(name)") }; count += 1
        }
        let scroll = TimelineScrollView(frame: .zero)
        let canvas = TimelineCanvas()
        scroll.documentView = canvas
        canvas.configure([], true, 60)
        check("A timeline with no viewport finishes layout", canvas.frame.height.isFinite)
        scroll.setFrameSize(NSSize(width: 1000, height: 700))
        scroll.layoutSubtreeIfNeeded()
        canvas.resizeIfNeeded()
        check("An empty timeline fills the viewport", canvas.frame.height >= 600)
        let now = Date().timeIntervalSince1970 * 1000
        let row = TimelineRow(messageIndex: 0, timestamp: now - 60000, end: now, text: "Build this app", cwd: "/projects/sessions", branch: "mz-native", lane: "sessions", label: "Sessions", sessionKey: "codex:one")
        let session = Session(id: "one", tool: "codex", title: "Build", cwd: row.cwd, filePath: "", startedAt: row.timestamp, updatedAt: now, messageCount: 1, preview: row.text, searchText: row.text, timeline: [row])
        canvas.configure([session], false, 60)
        check("A populated timeline finishes layout", canvas.frame.width >= scroll.contentSize.width)
        for zoom in [15, 30, 240, 1440] { canvas.configure([session], false, zoom); canvas.updateVisible() }
        check("Zoom retains a finite document size", canvas.frame.height.isFinite)
        canvas.scroll(to: now - 60000)
        check("Date navigation stays inside the document", scroll.contentView.bounds.minY >= 0)
        scroll.setFrameSize(NSSize(width: 900, height: 550))
        scroll.layoutSubtreeIfNeeded(); canvas.resizeIfNeeded(); canvas.updateVisible()
        check("Resizing finishes without repeated layout", canvas.frame.height.isFinite)
        print("\(count) view tests passing")
    }
}
