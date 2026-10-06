import AppKit
import Carbon.HIToolbox
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

enum Prefs {
    static let historyLimitKey = "historyLimit"
    static let ignoredAppsKey = "ignoredApps"
    static let showInDockKey = "showInDock"
    static let hotKeyKey = "hotKey"
    static let autoPasteKey = "autoPaste"

    /// Password managers are ignored out of the box; most also mark their copies as concealed.
    static let defaultIgnoredApps = [
        "com.apple.keychainaccess", "com.apple.Passwords", "com.1password.1password",
        "com.agilebits.onepassword7", "com.bitwarden.desktop", "com.lastpass.LastPass",
    ]

    /// Unpinned items to keep; 0 means unlimited.
    static var historyLimit: Int { UserDefaults.standard.object(forKey: historyLimitKey) as? Int ?? 1000 }

    static var ignoredApps: [String] {
        get { UserDefaults.standard.stringArray(forKey: ignoredAppsKey) ?? defaultIgnoredApps }
        set { UserDefaults.standard.set(newValue, forKey: ignoredAppsKey) }
    }

    static var showInDock: Bool { UserDefaults.standard.object(forKey: showInDockKey) as? Bool ?? true }
    static var autoPaste: Bool { UserDefaults.standard.object(forKey: autoPasteKey) as? Bool ?? true }
    static var hotKey: HotKeyPreset {
        UserDefaults.standard.string(forKey: hotKeyKey).flatMap(HotKeyPreset.init(rawValue:)) ?? .shiftCommandV
    }
}

enum HotKeyPreset: String, CaseIterable, Identifiable {
    case shiftCommandV, optionCommandV, controlCommandV, controlOptionV, commandSemicolon

    var id: String { rawValue }

    var display: String {
        switch self {
        case .shiftCommandV: return "⇧⌘V"
        case .optionCommandV: return "⌥⌘V"
        case .controlCommandV: return "⌃⌘V"
        case .controlOptionV: return "⌃⌥V"
        case .commandSemicolon: return "⌘;"
        }
    }

    var keyCode: Int { self == .commandSemicolon ? kVK_ANSI_Semicolon : kVK_ANSI_V }

    var modifiers: Int {
        switch self {
        case .shiftCommandV: return cmdKey | shiftKey
        case .optionCommandV: return cmdKey | optionKey
        case .controlCommandV: return cmdKey | controlKey
        case .controlOptionV: return controlKey | optionKey
        case .commandSemicolon: return cmdKey
        }
    }
}

struct SettingsView: View {
    @ObservedObject var store: HistoryStore

    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            HistorySettings(store: store)
                .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
            PrivacySettings(store: store)
                .tabItem { Label("Privacy", systemImage: "hand.raised") }
        }
        .frame(width: 520)
    }
}

private struct GeneralSettings: View {
    @AppStorage(Prefs.showInDockKey) private var showInDock = true
    @AppStorage(Prefs.hotKeyKey) private var hotKey = HotKeyPreset.shiftCommandV
    @AppStorage(Prefs.autoPasteKey) private var autoPaste = true
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?
    @ObservedObject private var status = AppStatus.shared

    var body: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in setLaunchAtLogin(enabled) }
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.red)
                }
                Toggle("Show in Dock while a window is open", isOn: $showInDock)
                    .onChange(of: showInDock) { _, _ in DockIcon.shared.update() }
            }

            Section {
                Picker("Quick Paste shortcut", selection: $hotKey) {
                    ForEach(HotKeyPreset.allCases) { Text($0.display).tag($0) }
                }
                if let conflict = status.hotKeyConflict {
                    Label("\(conflict.display) is already used by another app. Choose a different shortcut.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Toggle("Paste into the active app after choosing an item", isOn: $autoPaste)
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    LabeledContent("Accessibility access") {
                        if Paster.isTrusted {
                            Label("Granted", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        } else {
                            Button("Grant Access…") { Paster.requestTrust() }
                        }
                    }
                }
            } header: {
                Text("Quick Paste")
            } footer: {
                Text("Pasting for you needs Accessibility access. Without it, the item is copied and you press ⌘V yourself.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = error.localizedDescription
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

private struct HistorySettings: View {
    @ObservedObject var store: HistoryStore
    @AppStorage(Prefs.historyLimitKey) private var historyLimit = 1000
    @State private var confirmClear = false

    var body: some View {
        Form {
            Section {
                Picker("Keep", selection: $historyLimit) {
                    Text("100 items").tag(100)
                    Text("500 items").tag(500)
                    Text("1,000 items").tag(1000)
                    Text("5,000 items").tag(5000)
                    Text("Unlimited").tag(0)
                }
                .onChange(of: historyLimit) { _, _ in store.trim() }
                LabeledContent("Items", value: "\(store.items.count) (\(store.items.filter(\.pinned).count) pinned)")
                LabeledContent("Disk usage", value: ByteCountFormatter.string(fromByteCount: Int64(store.storageBytes),
                                                                              countStyle: .file))
            } footer: {
                Text("Pinned items are never removed automatically.").font(.caption).foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([store.imagesDir.deletingLastPathComponent()]) }
                    Spacer()
                    Button("Clear History…", role: .destructive) { confirmClear = true }
                }
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        .confirmationDialog("Clear clipboard history?", isPresented: $confirmClear) {
            Button("Clear History", role: .destructive) { store.clearUnpinned() }
        } message: {
            Text("Everything except pinned items will be deleted. This can't be undone.")
        }
    }
}

private struct PrivacySettings: View {
    @ObservedObject var store: HistoryStore
    @State private var ignored = Prefs.ignoredApps
    @State private var selection: String?

    var body: some View {
        Form {
            Section {
                Toggle("Pause capturing", isOn: $store.isPaused)
            } footer: {
                Text("Items that apps mark as concealed, such as passwords from password managers, are never saved.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Ignore copies from these apps") {
                List(selection: $selection) {
                    ForEach(ignored, id: \.self) { bundleID in
                        HStack(spacing: 8) {
                            if let icon = AppIcons.icon(for: bundleID) {
                                Image(nsImage: icon).resizable().frame(width: 18, height: 18)
                            } else {
                                Image(systemName: "app.dashed").frame(width: 18, height: 18)
                            }
                            Text(AppIcons.name(for: bundleID) ?? bundleID)
                            Spacer()
                            if AppIcons.name(for: bundleID) == nil {
                                Text("Not installed").font(.caption).foregroundStyle(.tertiary)
                            }
                        }
                        .tag(bundleID)
                    }
                }
                .frame(height: 170)
                HStack(spacing: 6) {
                    Button { addApp() } label: { Image(systemName: "plus") }
                    Button { remove() } label: { Image(systemName: "minus") }.disabled(selection == nil)
                    Spacer()
                    Button("Restore Defaults") { save(Prefs.defaultIgnoredApps) }
                }
                .buttonStyle(.borderless)
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func addApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = true
        panel.prompt = "Ignore"
        guard panel.runModal() == .OK else { return }
        let ids = panel.urls.compactMap { Bundle(url: $0)?.bundleIdentifier }
        save(ignored + ids.filter { !ignored.contains($0) })
    }

    private func remove() {
        guard let selection else { return }
        save(ignored.filter { $0 != selection })
        self.selection = nil
    }

    private func save(_ list: [String]) {
        ignored = list
        Prefs.ignoredApps = list
    }
}
