import SwiftUI
import AppKit

@main
struct SessionsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var store = SessionStore()
    var body: some Scene {
        Window("Sessions", id: "main") {
            ContentView(store: store).frame(minWidth: 900, minHeight: 540)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 1280, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) { Button("Sessions") { delegate.showWindow() }.keyboardShortcut("n") }
            CommandGroup(after: .toolbar) { Button("Refresh Sessions") { store.refresh() }.keyboardShortcut("r") }
        }
    }
}
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow(); return true
    }
    func showWindow() { NSApp.windows.first(where: { $0.canBecomeMain })?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
}

func toolColor(_ tool: String) -> Color { tool == "claude" ? .orange : tool == "codex" ? .green : .purple }
func highlighted(_ text: String, _ query: String) -> AttributedString {
    var result = AttributedString(text)
    for term in queryTerms(query) {
        var start = text.startIndex
        while start < text.endIndex, let range = text.range(of: term, options: .caseInsensitive, range: start..<text.endIndex) {
            if let lower = AttributedString.Index(range.lowerBound, within: result), let upper = AttributedString.Index(range.upperBound, within: result) {
                result[lower..<upper].backgroundColor = .yellow.opacity(0.3)
            }
            start = range.upperBound
        }
    }
    return result
}

struct ContentView: View {
    @ObservedObject var store: SessionStore
    @FocusState private var searchFocused: Bool
    var body: some View {
        VStack(spacing: 0) {
            if store.mode == "Timeline" { TimelineView(store: store) }
            else {
                HSplitView {
                    VStack(spacing: 0) {
                        HStack {
                            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                            TextField("Search sessions", text: $store.query).textFieldStyle(.plain).focused($searchFocused)
                            if !store.query.isEmpty { Button { store.query = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain) }
                        }.padding(12)
                        Picker("Tool", selection: $store.tool) {
                            Text("All").tag("all"); Text("Claude").tag("claude"); Text("Codex").tag("codex"); Text("Cursor").tag("cursor")
                        }.pickerStyle(.segmented).labelsHidden().padding(.horizontal, 10).padding(.bottom, 10)
                        Divider()
                        List(selection: Binding(get: { store.selectedKey }, set: { store.select($0) })) {
                            ForEach(store.visible, id: \.key) { session in
                                SessionRow(session: session, store: store).tag(session.key)
                                    .contextMenu { SessionMenu(session: session, store: store) }
                                    .onDrag { NSItemProvider(object: (session.resumeCommand + "\n") as NSString) }
                            }
                        }.listStyle(.sidebar)
                        HStack { Text(store.status); Spacer(); if !store.query.isEmpty { Text("\(store.visible.count) matches") } }
                            .font(.caption).foregroundStyle(.secondary).padding(10)
                    }.frame(minWidth: 300, idealWidth: 360, maxWidth: 520)
                    Group {
                        if let session = store.detail { TranscriptView(session: session, store: store).id(session.key) }
                        else if !store.detailError.isEmpty { ContentUnavailableView(store.detailError, systemImage: "exclamationmark.triangle") }
                        else if store.selectedKey != nil { ProgressView("Reading transcript…").frame(maxWidth: .infinity, maxHeight: .infinity) }
                        else { ContentUnavailableView("Choose a session", systemImage: "text.bubble", description: Text("Browse your Claude, Codex, and Cursor history.")) }
                    }.frame(minWidth: 450, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("View", selection: $store.mode) { Text("Sessions").tag("Sessions"); Text("Timeline").tag("Timeline") }
                    .pickerStyle(.segmented).frame(width: 220)
            }
            ToolbarItem { Button { store.refresh() } label: { Image(systemName: "arrow.clockwise") }.help("Refresh sessions (⌘R)") }
        }
        .background {
            Button("") { searchFocused = true }.keyboardShortcut("f", modifiers: store.detail == nil ? .command : [.command, .shift]).hidden()
        }
    }
}
struct SessionRow: View {
    let session: Session
    @ObservedObject var store: SessionStore
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Circle().fill(toolColor(session.tool)).frame(width: 7, height: 7)
                Text(highlighted(session.title, store.query)).fontWeight(.medium).lineLimit(2)
                Spacer(minLength: 0)
                if store.live.contains(session.key) { Text("live").font(.caption2).foregroundStyle(.green) }
                Button { store.togglePin(session.key) } label: { Image(systemName: store.pins.contains(session.key) ? "pin.fill" : "pin").foregroundStyle(store.pins.contains(session.key) ? .orange : .secondary) }.buttonStyle(.borderless).help("Pin or unpin session")
            }
            HStack { Text(session.project.isEmpty ? "—" : session.project); Spacer(); Text(Date(timeIntervalSince1970: session.updatedAt / 1000), style: .relative) }
                .font(.caption).foregroundStyle(.secondary)
            Text(highlighted(session.snippet(queryTerms(store.query)), store.query)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }.padding(.vertical, 6).accessibilityElement(children: .contain)
    }
}
struct SessionMenu: View {
    let session: Session
    @ObservedObject var store: SessionStore
    var body: some View {
        Button(store.pins.contains(session.key) ? "Unpin" : "Pin to Top") { store.togglePin(session.key) }
        Divider()
        Button("Copy Command") { store.copy(session.resumeCommand) }
        Button("Copy Title") { store.copy(session.title) }
        Button("Copy Session ID") { store.copy(session.id) }
        Button("Copy Working Directory") { store.copy(session.cwd) }
        Button("Copy Transcript Path") { store.copy(session.filePath) }
        Button("Show Transcript in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: session.filePath)]) }
    }
}
