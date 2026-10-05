import SwiftUI

/// App-wide state that isn't clipboard data.
@MainActor
final class AppStatus: ObservableObject {
    static let shared = AppStatus()
    /// Set when the chosen Quick Paste shortcut couldn't be registered (usually taken by another app).
    @Published var hotKeyConflict: HotKeyPreset?
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var hotKey: HotKey?
    private var registeredPreset: HotKeyPreset?
    private var defaultsObserver: NSObjectProtocol?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Always open the main window at launch instead of restoring a "closed" state from the last quit.
        UserDefaults.standard.register(defaults: ["NSQuitAlwaysKeepsWindows": false])
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(Prefs.showInDock ? .regular : .accessory)
        registerHotKey()
        // Re-register when the shortcut is changed in Settings.
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.registerHotKey() }
        }
        // Debug aid (used for screenshots): `open ClipStash.app --args -showQuickPanelOnLaunch YES`
        if UserDefaults.standard.bool(forKey: "showQuickPanelOnLaunch") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { QuickPanel.shared.show() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        HistoryStore.shared.saveNow()
    }

    // Keep capturing in the background after the window is closed.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    private func registerHotKey() {
        let preset = Prefs.hotKey
        guard preset != registeredPreset else { return }
        registeredPreset = preset
        hotKey = nil
        let hotKey = HotKey(keyCode: preset.keyCode, modifiers: preset.modifiers) {
            MainActor.assumeIsolated { QuickPanel.shared.toggle() }
        }
        self.hotKey = hotKey
        AppStatus.shared.hotKeyConflict = hotKey.isRegistered ? nil : preset
        if !hotKey.isRegistered { log.error("Shortcut \(preset.display, privacy: .public) is taken by another app") }
    }
}

@main
struct ClipStashApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @ObservedObject private var store = HistoryStore.shared

    var body: some Scene {
        Window("ClipStash", id: "library") {
            LibraryView(store: store)
        }
        .defaultSize(width: 1080, height: 660)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Quick Paste") { QuickPanel.shared.show() }
                    .keyboardShortcut("v", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView(store: store)
        }

        MenuBarExtra("ClipStash", systemImage: store.isPaused ? "pause.circle" : "list.clipboard") {
            MenuBarMenu(store: store)
        }
    }
}

private struct MenuBarMenu: View {
    @ObservedObject var store: HistoryStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Quick Paste  \(Prefs.hotKey.display)") { QuickPanel.shared.show() }
        Button("Open ClipStash") {
            openWindow(id: "library")
            NSApp.activate()
        }

        Divider()
        Text("Recent")
        ForEach(store.items.prefix(8)) { item in
            Button(menuTitle(item)) { store.copy(item) }
        }

        Divider()
        Toggle("Pause Capturing", isOn: $store.isPaused)
        SettingsLink { Text("Settings…") }
            .keyboardShortcut(",")
        Button("Quit ClipStash") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func menuTitle(_ item: ClipItem) -> String {
        let text = item.title.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
        return text.count > 50 ? String(text.prefix(50)) + "…" : text
    }
}
