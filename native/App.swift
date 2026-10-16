import AppKit

@main
struct SessionsApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        if CommandLine.arguments.contains("--check-window") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                let windows = app.windows.filter { $0.title == "Sessions" }
                let visible = windows.contains { $0.isVisible && !$0.isMiniaturized && $0.frame.width >= 900 && $0.frame.height > 100 }
                print(visible ? "Sessions window opens" : "Sessions window is missing")
                fflush(stdout)
                exit(visible ? 0 : 1)
            }
        }
        withExtendedLifetime(delegate) { app.run() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow!
    private var content: SessionsContent!
    private var keyMonitor: Any?
    func applicationDidFinishLaunching(_ notification: Notification) {
        content = SessionsContent(store: SessionStore())
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Sessions"
        window.identifier = NSUserInterfaceItemIdentifier("main")
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = NSColor(srgbRed: 14/255, green: 15/255, blue: 18/255, alpha: 1)
        window.appearance = NSAppearance(named: .darkAqua)
        window.minSize = NSSize(width: 900, height: 0)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.acceptsMouseMovedEvents = true
        window.contentView = content
        window.setFrame(NSRect(x: 0, y: 0, width: 1280, height: 820), display: false)
        window.center()
        buildMenu()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window, self.content.store.mode == "Timeline",
                  !event.modifierFlags.contains(.option), !event.modifierFlags.intersection([.command, .control]).isEmpty else { return event }
            let key = event.charactersIgnoringModifiers ?? ""
            let direction = ["+", "="].contains(key) ? -1 : key == "-" ? 1 : 0
            guard direction != 0 else { return event }
            self.content.zoom(direction)
            return nil
        }
        showWindow()
        content.sidebar.query.focus()
    }
    @objc func showWindow() {
        NSApp.unhide(nil)
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    @objc private func find() { content.focusFind() }
    @objc private func refresh() { content.store.refresh() }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showWindow(); return true }
    private func buildMenu() {
        let menu = NSMenu()
        func submenu(_ title: String) -> NSMenu {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let child = NSMenu(title: title); item.submenu = child; menu.addItem(item); return child
        }
        let app = submenu("Sessions")
        app.addItem(withTitle: "About Sessions", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Hide Sessions", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(withTitle: "Quit Sessions", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let file = submenu("File")
        let open = file.addItem(withTitle: "Sessions", action: #selector(showWindow), keyEquivalent: "n"); open.target = self
        file.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let edit = submenu("Edit")
        for (title, action, key) in [("Undo", "undo:", "z"), ("Redo", "redo:", "Z"), ("Cut", "cut:", "x"), ("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
            edit.addItem(withTitle: title, action: Selector(action), keyEquivalent: key)
        }
        let find = edit.addItem(withTitle: "Find", action: #selector(find), keyEquivalent: "f"); find.target = self
        let view = submenu("View")
        let refresh = view.addItem(withTitle: "Refresh Sessions", action: #selector(refresh), keyEquivalent: "r"); refresh.target = self
        view.addItem(withTitle: "Toggle Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f").keyEquivalentModifierMask = [.command, .control]
        let windows = submenu("Window")
        windows.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windows.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        NSApp.windowsMenu = windows; NSApp.mainMenu = menu
    }
}
