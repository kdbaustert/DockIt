import AppKit
import UniformTypeIdentifiers

/// The payload an icon carries while dragged inside the dock: the app's path under a type only DockIt
/// knows. Not the app's file URL, which dropped on Finder would copy or alias the app, and not plain
/// text, which Finder drops on the desktop as a text clipping.
private let dragType = UTType(exportedAs: "dev.kennyb.dockit.item")

extension DockModel {
    static let dropTypes: [UTType] = [.fileURL, dragType]

    /// Reorders the widgets: `name` lands before `target`, or at the end. Pure, for the tests.
    nonisolated static func reordered(_ order: [String], moving name: String, before target: String?) -> [String] {
        var out = order.filter { $0 != name }
        if let target, let index = out.firstIndex(of: target) {
            out.insert(name, at: index)
        } else {
            out.append(name)
        }
        return out
    }

    private static let widgetIDPrefix = "widget:"

    func placeWidget(_ name: String, before target: DockItem?) {
        let targetName = target.flatMap { item -> String? in
            item.id.hasPrefix(Self.widgetIDPrefix) ? String(item.id.dropFirst(Self.widgetIDPrefix.count)) : nil
        }
        // Before the name check: a gallery widget dropped on itself is still a widget to add.
        WidgetsModel.shared.add(name)
        guard name != targetName else { return }
        settings.widgetOrder = Self.reordered(settings.widgetOrder, moving: name, before: targetName)
    }

    /// Pins the app at `path` immediately before `target`, or at the end of the pinned apps. Moving an
    /// already pinned app is the same operation: take it out, put it back in.
    func place(_ path: String, before target: DockItem?) {
        guard let pinned = Self.placed(path, before: target, in: settings.pinnedApps) else { return }
        settings.pinnedApps = pinned
        let id = Self.pinnedID(path)
        // Pinning is an explicit ask to see the app, so it overrides an earlier Hide from Dock.
        settings.hiddenApps.removeAll { Self.key(URL(fileURLWithPath: $0)) == id }
    }

    /// `place`'s list work: the pinned list with `path` moved or added before `target`, or nil when
    /// the drop changes nothing. Pure, for the tests.
    nonisolated static func placed(_ path: String, before target: DockItem?, in pinnedApps: [String]) -> [String]? {
        let isSpacer = path.hasPrefix(spacerPrefix)
        let id = pinnedID(path)
        guard path.hasSuffix(".app") || isSpacer, id != finderID, id != target?.id else { return nil }
        var pinned = pinnedApps.filter { pinnedID($0) != id }
        var index = pinned.count
        if let target, target.kind == .app || target.kind == .spacer, target.isPinned {
            if target.id == finderID {
                index = 0
            } else if let found = pinned.firstIndex(where: { pinnedID($0) == target.id }) {
                index = found
            }
        }
        pinned.insert(path, at: index)
        return pinned
    }

    /// A `pinnedApps` entry's item id: a spacer is its own id, an app its resolved path.
    private nonisolated static func pinnedID(_ entry: String) -> String {
        entry.hasPrefix(spacerPrefix) ? entry : key(URL(fileURLWithPath: entry))
    }

    // MARK: - Drag and drop

    func dragPayload(for item: DockItem) -> NSItemProvider {
        // Spacers and widgets drag by their identity strings, exactly as an app drags by its path.
        if item.kind == .spacer || item.id.hasPrefix(Self.widgetIDPrefix) {
            return Self.ownProcessPayload(item.id)
        }
        guard item.kind == .app, item.id != Self.finderID, let url = item.url else { return NSItemProvider() }
        let provider = NSItemProvider()
        let data = Data(url.path.utf8)
        provider.registerDataRepresentation(forTypeIdentifier: dragType.identifier, visibility: .all) { completion in
            completion(data, nil)
            return nil
        }
        return provider
    }

    /// A widget dragged out of Settings' gallery: the payload a tile on the bar drags, so the bar's
    /// drop handling places it wherever it lands.
    static func dragPayload(forWidget name: String) -> NSItemProvider {
        ownProcessPayload(widgetIDPrefix + name)
    }

    private static func ownProcessPayload(_ id: String) -> NSItemProvider {
        let provider = NSItemProvider()
        let payload = Data(id.utf8)
        provider.registerDataRepresentation(forTypeIdentifier: dragType.identifier, visibility: .ownProcess) {
            completion in
            completion(payload, nil)
            return nil
        }
        return provider
    }

    /// A drop on an icon (`target`) or on the bar itself (nil).
    func handleDrop(_ providers: [NSItemProvider], onto target: DockItem?) -> Bool {
        let files = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        if files.isEmpty {
            guard let provider = providers.first(where: {
                $0.hasItemConformingToTypeIdentifier(dragType.identifier)
            }) else { return false }
            _ = provider.loadDataRepresentation(forTypeIdentifier: dragType.identifier) { [weak self] data, _ in
                guard let data, let path = String(data: data, encoding: .utf8) else { return }
                Task { @MainActor in
                    if path.hasPrefix(Self.widgetIDPrefix) {
                        self?.placeWidget(String(path.dropFirst(Self.widgetIDPrefix.count)), before: target)
                    } else {
                        self?.place(path, before: target)
                    }
                }
            }
            return true
        }
        Task {
            var urls: [URL] = []
            for provider in files {
                if let url = await loadURL(provider) { urls.append(url) }
            }
            drop(urls, onto: target)
        }
        return true
    }

    private func loadURL(_ provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in continuation.resume(returning: url) }
        }
    }

    private func drop(_ urls: [URL], onto target: DockItem?) {
        guard !urls.isEmpty else { return }
        if target?.kind == .trash {
            NSWorkspace.shared.recycle(urls) { [weak self] _, _ in
                Task { @MainActor in self?.refreshTrash() }
            }
            return
        }
        if urls.allSatisfy({ $0.pathExtension == "app" }) {
            for url in urls { place(url.path, before: target) }
            return
        }
        if let target, target.kind == .app, let app = target.url {
            NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
            return
        }
        let folders = urls.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
        if target == nil || target?.kind == .folder, !folders.isEmpty {
            settings.stacks += folders.map(\.path).filter { !settings.stacks.contains($0) }
        }
    }
}
