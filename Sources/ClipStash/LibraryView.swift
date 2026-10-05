import AppKit
import SwiftUI

enum LibraryFilter: Hashable {
    case all, pinned
    case kind(ClipItem.Kind)
    case source(String)

    func matches(_ item: ClipItem) -> Bool {
        switch self {
        case .all: return true
        case .pinned: return item.pinned
        case .kind(let kind): return item.kind == kind
        case .source(let bundleID): return item.sourceBundleID == bundleID
        }
    }
}

func searchMatches(_ item: ClipItem, _ query: String) -> Bool {
    let terms = query.lowercased().split(separator: " ")
    guard !terms.isEmpty else { return true }
    let fields: [String] = [item.title, item.filePaths?.joined(separator: " ") ?? "", item.sourceName ?? "", item.kind.label]
    let haystack = fields.joined(separator: " ").lowercased()
    return terms.allSatisfy { haystack.contains($0) }
}

struct LibraryView: View {
    @ObservedObject var store: HistoryStore
    @State private var filter: LibraryFilter? = .all
    @State private var query = ""
    @State private var selection: ClipItem.ID?
    @State private var toast: Toast?
    @ObservedObject private var status = AppStatus.shared

    struct Toast: Equatable {
        let message: String
        let isError: Bool
    }

    private var results: [ClipItem] {
        let filter = self.filter ?? .all
        return store.items.filter { filter.matches($0) && searchMatches($0, query) }
    }

    private var selectedItem: ClipItem? { selection.flatMap { id in store.items.first { $0.id == id } } }

    var body: some View {
        NavigationSplitView {
            sidebar
        } content: {
            clipList
        } detail: {
            detail.safeAreaInset(edge: .top, spacing: 0) { banners }
        }
        .searchable(text: $query, placement: .toolbar, prompt: "Search clipboard history")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Toggle(isOn: $store.isPaused) {
                    Label(store.isPaused ? "Resume Capturing" : "Pause Capturing",
                          systemImage: store.isPaused ? "pause.circle.fill" : "pause.circle")
                }
                .help(store.isPaused ? "Capturing is paused — click to resume" : "Pause capturing")
                Button {
                    QuickPanel.shared.show()
                } label: {
                    Label("Quick Paste", systemImage: "bolt")
                }
                .help("Open Quick Paste (\(Prefs.hotKey.display))")
            }
        }
        .overlay(alignment: .bottom) {
            if let toast {
                Label(toast.message, systemImage: toast.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(toast.isError ? AnyShapeStyle(.orange) : AnyShapeStyle(.primary))
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.thickMaterial, in: Capsule())
                    .shadow(radius: 6, y: 2)
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .frame(minWidth: 900, minHeight: 520)
    }

    // MARK: Sidebar

    private var sidebar: some View {
        List(selection: $filter) {
            Section("Library") {
                sidebarRow("All Items", "tray.full", .all)
                sidebarRow("Pinned", "pin", .pinned)
            }
            Section("Types") {
                ForEach([ClipItem.Kind.text, .link, .image, .files], id: \.self) { kind in
                    sidebarRow(kind == .link ? "Links" : kind == .image ? "Images" : kind.label, kind.symbol, .kind(kind))
                }
            }
            let sources = store.sources.prefix(12)
            if !sources.isEmpty {
                Section("Sources") {
                    ForEach(sources) { source in
                        Label {
                            Text(source.name)
                        } icon: {
                            if let icon = AppIcons.icon(for: source.bundleID) {
                                Image(nsImage: icon).resizable().frame(width: 16, height: 16)
                            } else {
                                Image(systemName: "app")
                            }
                        }
                        .badge(source.count)
                        .tag(LibraryFilter.source(source.bundleID))
                    }
                }
            }
        }
        .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
        .safeAreaInset(edge: .bottom) {
            if store.isPaused {
                Label("Capturing paused", systemImage: "pause.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
        }
    }

    private func sidebarRow(_ title: String, _ symbol: String, _ value: LibraryFilter) -> some View {
        Label(title, systemImage: symbol)
            .badge(store.items.filter(value.matches).count)
            .tag(value)
    }

    // MARK: List

    private var clipList: some View {
        List(selection: $selection) {
            ForEach(results) { item in
                ClipRow(item: item).padding(.vertical, 3).tag(item.id)
            }
        }
        .contextMenu(forSelectionType: ClipItem.ID.self) { ids in
            if let item = ids.first.flatMap({ id in store.items.first { $0.id == id } }) {
                itemActions(item)
            }
        } primaryAction: { ids in
            if let item = ids.first.flatMap({ id in store.items.first { $0.id == id } }) { copy(item) }
        }
        .onDeleteCommand { if let item = selectedItem { delete(item) } }
        .overlay {
            if results.isEmpty {
                if !query.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else if store.items.isEmpty {
                    ContentUnavailableView("Nothing Copied Yet", systemImage: "doc.on.clipboard",
                                           description: Text("Everything you copy shows up here. Press \(Prefs.hotKey.display) anywhere to paste from your history."))
                } else {
                    ContentUnavailableView("No Items", systemImage: "tray")
                }
            }
        }
        .navigationSplitViewColumnWidth(min: 280, ideal: 340, max: 480)
        .navigationTitle(title)
        .navigationSubtitle("\(results.count.formatted()) item\(results.count == 1 ? "" : "s")")
        .onChange(of: filter) { _, _ in selection = results.first?.id }
        .onAppear { if selection == nil { selection = results.first?.id } }
    }

    private var title: String {
        switch filter ?? .all {
        case .all: return "All Items"
        case .pinned: return "Pinned"
        case .kind(let kind): return kind == .link ? "Links" : kind == .image ? "Images" : kind.label
        case .source(let id): return store.sources.first { $0.bundleID == id }?.name ?? "Source"
        }
    }

    // MARK: Detail

    @ViewBuilder private var detail: some View {
        if let item = selectedItem {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Button { copy(item) } label: { Label("Copy", systemImage: "doc.on.doc") }
                        .keyboardShortcut("c", modifiers: .command)
                        .buttonStyle(.borderedProminent)
                    if item.kind == .text || item.kind == .link {
                        Button { copy(item, plain: true) } label: { Label("Copy as Plain Text", systemImage: "textformat") }
                    }
                    Spacer()
                    Button { store.togglePin(item) } label: {
                        Label(item.pinned ? "Unpin" : "Pin", systemImage: item.pinned ? "pin.slash" : "pin")
                    }
                    if let url = item.url {
                        Button { NSWorkspace.shared.open(url) } label: { Label("Open", systemImage: "safari") }
                    }
                    if item.kind == .files, let paths = item.filePaths {
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting(paths.map { URL(fileURLWithPath: $0) })
                        } label: { Label("Show in Finder", systemImage: "folder") }
                    }
                    Button(role: .destructive) { delete(item) } label: { Label("Delete", systemImage: "trash") }
                }
                .labelStyle(.titleAndIcon)
                .padding(12)
                Divider()
                ClipPreview(item: item)
            }
            .id(item.id)
        } else {
            ContentUnavailableView("No Selection", systemImage: "doc.on.clipboard",
                                   description: Text("Select an item to preview it."))
        }
    }

    @ViewBuilder private func itemActions(_ item: ClipItem) -> some View {
        Button("Copy") { copy(item) }
        if item.kind == .text || item.kind == .link { Button("Copy as Plain Text") { copy(item, plain: true) } }
        Button(item.pinned ? "Unpin" : "Pin") { store.togglePin(item) }
        if let url = item.url { Button("Open Link") { NSWorkspace.shared.open(url) } }
        if item.kind == .files, let paths = item.filePaths {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(paths.map { URL(fileURLWithPath: $0) }) }
        }
        Divider()
        Button("Delete", role: .destructive) { delete(item) }
    }

    // MARK: Actions

    private func copy(_ item: ClipItem, plain: Bool = false) {
        switch store.copy(item, plainText: plain) {
        case .copied:
            selection = item.id
            show(Toast(message: plain ? "Copied as plain text" : "Copied", isError: false))
        case .copiedWithWarning(let message):
            selection = item.id
            show(Toast(message: "Copied. " + message, isError: true))
        case .failed(let message):
            show(Toast(message: "Couldn't copy. " + message, isError: true))
        }
    }

    @ViewBuilder private var banners: some View {
        VStack(spacing: 0) {
            if let problem = store.problem {
                Banner(symbol: "exclamationmark.triangle.fill", tint: .orange, message: problem) { store.problem = nil }
            }
            if let conflict = status.hotKeyConflict {
                Banner(symbol: "keyboard", tint: .yellow,
                       message: "\(conflict.display) is used by another app, so Quick Paste has no shortcut. Pick another one in Settings.",
                       dismiss: nil)
            }
        }
    }

    private func delete(_ item: ClipItem) {
        let list = results
        let index = list.firstIndex(of: item) ?? 0
        store.delete(item)
        let remaining = results
        selection = remaining.isEmpty ? nil : remaining[min(index, remaining.count - 1)].id
    }

    private func show(_ newToast: Toast) {
        withAnimation(.snappy) { toast = newToast }
        DispatchQueue.main.asyncAfter(deadline: .now() + (newToast.isError ? 3.5 : 1.4)) {
            withAnimation(.snappy) { if toast == newToast { toast = nil } }
        }
    }
}

private struct Banner: View {
    let symbol: String
    let tint: Color
    let message: String
    let dismiss: (() -> Void)?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(message).font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer()
            if let dismiss {
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .help("Dismiss")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(tint.opacity(0.12))
        .overlay(alignment: .bottom) { Divider() }
    }
}
