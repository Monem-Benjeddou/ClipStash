import AppKit
import SwiftUI

@MainActor
final class QuickPanelState: ObservableObject {
    @Published var query = "" { didSet { selection = 0 } }
    @Published var filter: LibraryFilter = .all { didSet { selection = 0 } }
    @Published var selection = 0
    /// Shown in the footer when the chosen item couldn't be pasted; the panel stays open.
    @Published var error: String?
    let store: HistoryStore

    init(store: HistoryStore) { self.store = store }

    var results: [ClipItem] { store.items.filter { filter.matches($0) && searchMatches($0, query) } }

    var selectedItem: ClipItem? {
        let results = self.results
        return results.indices.contains(selection) ? results[selection] : nil
    }

    func move(_ delta: Int) {
        error = nil
        let count = results.count
        guard count > 0 else { return }
        selection = min(max(selection + delta, 0), count - 1)
    }
}

/// Takes keyboard focus without activating ClipStash, so the app you were in stays frontmost and receives the paste.
final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// The Spotlight-style picker opened with the global shortcut.
@MainActor
final class QuickPanel: NSObject, NSWindowDelegate {
    static let shared = QuickPanel(store: .shared)

    private let store: HistoryStore
    private var state: QuickPanelState
    private let panel: FloatingPanel
    private var keyMonitor: Any?

    private init(store: HistoryStore) {
        self.store = store
        self.state = QuickPanelState(store: store)
        panel = FloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 500),
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView, .resizable],
            backing: .buffered, defer: true)
        super.init()
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.minSize = NSSize(width: 560, height: 340)
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }
    }

    func toggle() { panel.isVisible ? hide() : show() }

    func show() {
        state = QuickPanelState(store: store)
        panel.contentView = NSHostingView(rootView: QuickPanelView(state: state, store: store) { [weak self] item, plain in
            self?.paste(item, plainText: plain)
        })
        positionOnActiveScreen()
        panel.makeKeyAndOrderFront(nil)
        installKeyMonitor()
    }

    func hide() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        panel.orderOut(nil)
    }

    func windowDidResignKey(_ notification: Notification) { hide() }

    private func positionOnActiveScreen() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2,
                                     y: visible.minY + visible.height * 0.6 - size.height / 2))
    }

    private func paste(_ item: ClipItem, plainText: Bool) {
        if case .failed(let message) = store.copy(item, plainText: plainText) {
            state.error = message
            NSSound.beep()
            return
        }
        hide()
        guard Prefs.autoPaste, Paster.isTrusted else { return } // otherwise it's copied, ready for ⌘V
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { Paster.pasteIntoFrontApp() }
    }

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.panel.isKeyWindow else { return event }
            return self.handle(event) ? nil : event
        }
    }

    /// Returns true if the key was consumed.
    private func handle(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let command = flags.contains(.command)
        switch Int(event.keyCode) {
        case 125: state.move(1); return true                       // ↓
        case 126: state.move(-1); return true                      // ↑
        case 53: hide(); return true                               // esc
        case 36, 76:                                               // return / enter
            if let item = state.selectedItem { paste(item, plainText: flags.contains(.shift)) }
            return true
        case 51 where command:                                     // ⌘⌫
            if let item = state.selectedItem {
                store.delete(item)
                state.selection = min(state.selection, max(state.results.count - 1, 0))
            }
            return true
        default: break
        }
        guard command, let chars = event.charactersIgnoringModifiers?.lowercased() else { return false }
        if chars == "p", let item = state.selectedItem { store.togglePin(item); return true }
        if let digit = Int(chars), (1...9).contains(digit) {
            let results = state.results
            if results.indices.contains(digit - 1) { paste(results[digit - 1], plainText: false) }
            return true
        }
        return false
    }
}

private struct QuickPanelView: View {
    @ObservedObject var state: QuickPanelState
    @ObservedObject var store: HistoryStore
    let onPaste: (ClipItem, Bool) -> Void
    @FocusState private var searchFocused: Bool

    private let filters: [(String, LibraryFilter)] = [
        ("All", .all), ("Pinned", .pinned), ("Text", .kind(.text)), ("Links", .kind(.link)),
        ("Images", .kind(.image)), ("Files", .kind(.files)),
    ]

    var body: some View {
        let results = state.results
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").font(.title3).foregroundStyle(.secondary)
                TextField("Search clipboard history", text: $state.query)
                    .textFieldStyle(.plain)
                    .font(.title2)
                    .focused($searchFocused)
            }
            .padding(.horizontal, 18)
            .padding(.top, 16)
            .padding(.bottom, 10)

            HStack(spacing: 6) {
                ForEach(filters, id: \.0) { title, filter in
                    FilterChip(title: title, selected: state.filter == filter) { state.filter = filter }
                }
                Spacer()
                if store.isPaused {
                    Label("Paused", systemImage: "pause.circle.fill").font(.caption).foregroundStyle(.orange)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 10)

            Divider()

            if results.isEmpty {
                ContentUnavailableView(store.items.isEmpty ? "Nothing Copied Yet" : "No Matches",
                                       systemImage: store.items.isEmpty ? "doc.on.clipboard" : "magnifyingglass",
                                       description: Text(store.items.isEmpty ? "Copy something and it will appear here." : "Try a different search."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 0) {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 2) {
                                ForEach(Array(results.enumerated()), id: \.element.id) { index, item in
                                    ClipRow(item: item, shortcutIndex: index, selected: index == state.selection)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 6)
                                        .background(RoundedRectangle(cornerRadius: 7)
                                            .fill(index == state.selection ? Color.accentColor : .clear))
                                        .contentShape(Rectangle())
                                        .id(item.id)
                                        .onTapGesture(count: 2) { onPaste(item, false) }
                                        .simultaneousGesture(TapGesture().onEnded { state.selection = index })
                                }
                            }
                            .padding(8)
                        }
                        .onChange(of: state.selection) { _, newValue in
                            if results.indices.contains(newValue) { proxy.scrollTo(results[newValue].id) }
                        }
                    }
                    .frame(width: 340)

                    Divider()

                    if let item = state.selectedItem { ClipPreview(item: item) }
                }
            }

            Divider()
            HStack(spacing: 16) {
                KeyHint(keys: "↩", label: "Paste")
                KeyHint(keys: "⇧↩", label: "Plain text")
                KeyHint(keys: "⌘P", label: "Pin")
                KeyHint(keys: "⌘⌫", label: "Delete")
                KeyHint(keys: "esc", label: "Close")
                Spacer()
                if let error = state.error {
                    Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).lineLimit(1)
                } else {
                    Text("\(results.count.formatted()) of \(store.items.count.formatted())").foregroundStyle(.secondary)
                }
            }
            .font(.caption)
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
        }
        .background(.regularMaterial)
        .onAppear { searchFocused = true }
    }
}

private struct FilterChip: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.callout.weight(selected ? .semibold : .regular))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(selected ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.06)))
                .foregroundStyle(selected ? Color.accentColor : .primary)
        }
        .buttonStyle(.plain)
    }
}

private struct KeyHint: View {
    let keys: String
    let label: String

    var body: some View {
        HStack(spacing: 5) {
            Text(keys)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 4).stroke(.secondary.opacity(0.5)))
            Text(label).foregroundStyle(.secondary)
        }
    }
}
