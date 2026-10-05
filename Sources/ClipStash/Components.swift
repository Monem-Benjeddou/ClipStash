import AppKit
import SwiftUI

extension ClipItem.Kind {
    var label: String {
        switch self {
        case .text: return "Text"
        case .link: return "Link"
        case .image: return "Image"
        case .files: return "Files"
        }
    }

    var symbol: String {
        switch self {
        case .text: return "text.alignleft"
        case .link: return "link"
        case .image: return "photo"
        case .files: return "doc"
        }
    }

    var tint: Color {
        switch self {
        case .text: return .blue
        case .link: return .purple
        case .image: return .orange
        case .files: return .teal
        }
    }
}

/// Square thumbnail for a clip: the image itself, the file's icon, or a tinted symbol.
struct ClipThumbnail: View {
    let item: ClipItem
    let size: CGFloat

    var body: some View {
        Group {
            switch item.kind {
            case .image:
                if let url = HistoryStore.shared.imageURL(for: item), let image = ImageCache.shared.thumbnail(url) {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                } else {
                    symbolTile
                }
            case .files:
                Image(nsImage: NSWorkspace.shared.icon(forFile: item.filePaths?.first ?? "/")).resizable()
            case .text, .link:
                symbolTile
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22))
    }

    private var symbolTile: some View {
        Image(systemName: item.kind.symbol)
            .font(.system(size: size * 0.42, weight: .medium))
            .foregroundStyle(item.kind.tint)
            .frame(width: size, height: size)
            .background(item.kind.tint.opacity(0.14))
    }
}

/// One clip in a list. `selected` is used where the list draws its own highlight (the Quick Paste panel).
struct ClipRow: View {
    let item: ClipItem
    var shortcutIndex: Int?
    var selected = false

    var body: some View {
        HStack(spacing: 10) {
            ClipThumbnail(item: item, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(preview).lineLimit(1).truncationMode(.tail)
                HStack(spacing: 4) {
                    if item.pinned { Image(systemName: "pin.fill").foregroundStyle(selected ? .white : .orange) }
                    if let icon = AppIcons.icon(for: item.sourceBundleID) {
                        Image(nsImage: icon).resizable().frame(width: 12, height: 12)
                    }
                    Text(subtitle)
                }
                .font(.caption)
                .foregroundStyle(selected ? AnyShapeStyle(.white.opacity(0.85)) : AnyShapeStyle(.secondary))
            }
            Spacer(minLength: 0)
            if let shortcutIndex, shortcutIndex < 9 {
                Text("⌘\(shortcutIndex + 1)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(selected ? AnyShapeStyle(.white.opacity(0.85)) : AnyShapeStyle(.tertiary))
            }
        }
        .foregroundStyle(selected ? .white : .primary)
    }

    private var preview: String {
        let collapsed = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .newlines).filter { !$0.isEmpty }.joined(separator: " ⏎ ")
        return String(collapsed.prefix(300))
    }

    private var subtitle: String {
        [item.sourceName, item.date.formatted(.relative(presentation: .named))].compactMap { $0 }.joined(separator: " · ")
    }
}

/// Full preview of a clip, with its metadata in a footer.
struct ClipPreview: View {
    let item: ClipItem

    var body: some View {
        VStack(spacing: 0) {
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack(spacing: 6) {
                Label(item.kind.label, systemImage: item.kind.symbol).foregroundStyle(item.kind.tint)
                ForEach(details, id: \.self) { Text("·"); Text($0) }
                Spacer()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder private var content: some View {
        switch item.kind {
        case .text, .link:
            ScrollView {
                Text(item.text ?? "")
                    .font(looksLikeCode ? .system(.callout, design: .monospaced) : .body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(16)
            }
        case .image:
            if let url = HistoryStore.shared.imageURL(for: item), let image = NSImage(contentsOf: url) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: image.size.width, maxHeight: image.size.height)
                    .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
                    .padding(20)
            } else {
                ContentUnavailableView("Image Missing", systemImage: "photo.badge.exclamationmark")
            }
        case .files:
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(item.filePaths ?? [], id: \.self) { path in
                        HStack(spacing: 10) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable().frame(width: 32, height: 32)
                            VStack(alignment: .leading, spacing: 1) {
                                Text((path as NSString).lastPathComponent).lineLimit(1)
                                Text((path as NSString).deletingLastPathComponent)
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                            if !FileManager.default.fileExists(atPath: path) {
                                Text("Missing").font(.caption).foregroundStyle(.red)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(16)
            }
        }
    }

    private var looksLikeCode: Bool {
        guard item.kind == .text, let text = item.text else { return false }
        let markers = ["{", "}", ";", "=>", "->", "</", "\t", "  "]
        return markers.filter { text.contains($0) }.count >= 2
    }

    private var details: [String] {
        var parts: [String] = []
        if let source = item.sourceName { parts.append(source) }
        parts.append(item.date.formatted(date: .abbreviated, time: .shortened))
        switch item.kind {
        case .text, .link:
            let text = item.text ?? ""
            parts.append("\(text.count.formatted()) characters")
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false).count
            if lines > 1 { parts.append("\(lines.formatted()) lines") }
        case .image:
            if let url = HistoryStore.shared.imageURL(for: item), let rep = NSImageRep(contentsOf: url) {
                parts.append("\(rep.pixelsWide) × \(rep.pixelsHigh)")
            }
        case .files:
            let count = item.filePaths?.count ?? 0
            parts.append("\(count) file\(count == 1 ? "" : "s")")
        }
        return parts
    }
}

@MainActor
enum AppIcons {
    private static var icons: [String: NSImage] = [:]
    private static var names: [String: String] = [:]

    static func icon(for bundleID: String?) -> NSImage? {
        guard let bundleID else { return nil }
        if let cached = icons[bundleID] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icons[bundleID] = icon
        return icon
    }

    static func name(for bundleID: String) -> String? {
        if let cached = names[bundleID] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        names[bundleID] = name
        return name
    }
}

final class ImageCache {
    static let shared = ImageCache()
    private let cache = NSCache<NSURL, NSImage>()

    func thumbnail(_ url: URL) -> NSImage? {
        if let cached = cache.object(forKey: url as NSURL) { return cached }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: 120,
              ] as CFDictionary) else { return nil }
        let image = NSImage(cgImage: cgImage, size: .zero)
        cache.setObject(image, forKey: url as NSURL)
        return image
    }
}
