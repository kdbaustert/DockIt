import AppKit

/// The settings that travel between Macs — in an exported file and over iCloud. Everything is
/// optional so a file from an older or newer DockIt still applies whatever it does carry.
///
/// Two settings deliberately stay on each Mac: hiding the macOS Dock, whose change restarts that
/// Mac's Dock (not something one Mac should do to another), and the sync switch itself.
struct PortableSettings: Codable, Equatable {
    var edge: String?
    var iconSize: Double?
    var iconPadding: Double?
    var dockPadding: Double?
    var magnifies: Bool?
    var magnifyAmount: Double?
    var magnifyReach: Double?
    var magnifyOnApproach: Bool?
    /// The pre-amount schema: a magnified size in points. Read so an old file still applies.
    var magnifiedSize: Double?
    var smoothHover: Bool?
    var hoverIntensity: Double?
    var bouncesOnLaunch: Bool?
    var autoHides: Bool?
    var showsWindowPreviews: Bool?
    var previewDelay: Double?
    var previewShowsControls: Bool?
    var showsMenuBarIcon: Bool?
    var pinnedApps: [String]?
    var stacks: [String]?
    var hiddenApps: [String]?

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        // Sorted, so the same settings always produce the same bytes and an unchanged file is
        // recognisably unchanged.
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    static func decoded(from data: Data) throws -> PortableSettings {
        try JSONDecoder().decode(PortableSettings.self, from: data)
    }
}

extension DockSettings {
    var portable: PortableSettings {
        PortableSettings(
            edge: edge.rawValue, iconSize: iconSize, iconPadding: iconPadding, dockPadding: dockPadding,
            magnifies: magnifies, magnifyAmount: magnifyAmount, magnifyReach: magnifyReach,
            magnifyOnApproach: magnifyOnApproach, smoothHover: smoothHover,
            hoverIntensity: hoverIntensity, bouncesOnLaunch: bouncesOnLaunch, autoHides: autoHides,
            showsWindowPreviews: showsWindowPreviews, previewDelay: previewDelay,
            previewShowsControls: previewShowsControls,
            showsMenuBarIcon: showsMenuBarIcon, pinnedApps: pinnedApps, stacks: stacks, hiddenApps: hiddenApps
        )
    }

    /// Assigns only what differs, so an unchanged value does not fire its observers (the panel would
    /// re-lay out for nothing).
    func apply(_ p: PortableSettings) {
        if let v = p.edge.flatMap(DockEdge.init(rawValue:)), v != edge { edge = v }
        if let v = p.iconSize, v != iconSize { iconSize = v }
        if let v = p.iconPadding, v != iconPadding { iconPadding = v }
        if let v = p.dockPadding, v != dockPadding { dockPadding = v }
        if let v = p.magnifies, v != magnifies { magnifies = v }
        if let v = p.magnifyAmount, v != magnifyAmount { magnifyAmount = v }
        // An old export carries points; a current one carries the multiple, which wins.
        if p.magnifyAmount == nil, let v = p.magnifiedSize, iconSize > 0 {
            let amount = min(max(v / iconSize, 1.0), 2.5)
            if amount != magnifyAmount { magnifyAmount = amount }
        }
        if let v = p.magnifyReach, v != magnifyReach { magnifyReach = v }
        if let v = p.magnifyOnApproach, v != magnifyOnApproach { magnifyOnApproach = v }
        if let v = p.smoothHover, v != smoothHover { smoothHover = v }
        if let v = p.hoverIntensity, v != hoverIntensity { hoverIntensity = v }
        if let v = p.bouncesOnLaunch, v != bouncesOnLaunch { bouncesOnLaunch = v }
        if let v = p.autoHides, v != autoHides { autoHides = v }
        if let v = p.showsWindowPreviews, v != showsWindowPreviews { showsWindowPreviews = v }
        if let v = p.previewDelay, v != previewDelay { previewDelay = v }
        if let v = p.previewShowsControls, v != previewShowsControls { previewShowsControls = v }
        if let v = p.showsMenuBarIcon, v != showsMenuBarIcon { showsMenuBarIcon = v }
        if let v = p.pinnedApps, v != pinnedApps { pinnedApps = v }
        if let v = p.stacks, v != stacks { stacks = v }
        if let v = p.hiddenApps, v != hiddenApps { hiddenApps = v }
    }
}

// MARK: - Export and import

@MainActor
enum SettingsFile {
    static func export(_ settings: DockSettings) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "DockIt Settings.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try settings.portable.encoded().write(to: url, options: .atomic)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    static func importInto(_ settings: DockSettings) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            settings.apply(try PortableSettings.decoded(from: Data(contentsOf: url)))
        } catch {
            let alert = NSAlert()
            alert.messageText = "That file isn't a DockIt settings file."
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }
}

// MARK: - iCloud

/// Keeps the portable settings in a file in iCloud Drive, so every Mac signed in to the same account
/// shares them. Cmd-Tab's approach: a plain file in the user's own iCloud Drive folder, which syncs
/// like any other document and needs no ubiquity entitlement — which a locally signed app cannot
/// have, so `NSUbiquitousKeyValueStore` is not an option.
///
/// Changes here are written after a short pause (a slider drag is dozens of changes); changes there
/// are noticed by watching the folder, with a slow poll behind it because iCloud does not always
/// deliver a file-system event when it swaps a download in. Last writer wins.
@MainActor
final class SettingsSync {
    static var folderURL: URL? {
        let cloudDocs = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        guard FileManager.default.fileExists(atPath: cloudDocs.path) else { return nil }
        return cloudDocs.appendingPathComponent("DockIt", isDirectory: true)
    }

    /// False when iCloud Drive is off or signed out on this Mac.
    static var isAvailable: Bool { folderURL != nil }

    private static var fileURL: URL? { folderURL?.appendingPathComponent("settings.json") }

    private let settings: DockSettings
    private var isRunning = false
    /// The settings the file and this Mac last agreed on. A change that matches it — the echo of
    /// applying the file, or a file this Mac wrote itself — is not sent back round.
    private var agreed: PortableSettings?
    private var lastModified: Date?
    private var pendingWrite: DispatchWorkItem?
    private var watcher: DispatchSourceFileSystemObject?
    private var poll: Timer?

    init(settings: DockSettings) {
        self.settings = settings
        observeContinuously { [weak self] in
            guard let self else { return }
            settings.syncsWithICloud && Self.isAvailable ? start() : stop()
        } onChange: {}
        observeContinuously { [settings] in
            _ = settings.portable
        } onChange: { [weak self] in
            self?.scheduleWrite()
        }
    }

    private func start() {
        guard !isRunning, let folder = Self.folderURL else { return }
        isRunning = true
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Turning sync on adopts what another Mac already put there; only an empty iCloud gets this
        // Mac's settings.
        if !readRemote() {
            writeNow()
        } else {
            // Rewrite what was adopted in the current schema. Without this, a file from an older
            // DockIt is re-adopted at every launch and its converted values stomp any change made
            // since — measured: an old "magnifiedSize" file reset the Amount slider on each launch.
            scheduleWrite()
        }
        watch(folder)
        let poll = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.readRemote() }
        }
        poll.tolerance = 5
        RunLoop.main.add(poll, forMode: .common)
        self.poll = poll
    }

    private func stop() {
        guard isRunning else { return }
        isRunning = false
        pendingWrite?.cancel()
        pendingWrite = nil
        watcher?.cancel()
        watcher = nil
        poll?.invalidate()
        poll = nil
        agreed = nil
        lastModified = nil
    }

    private func watch(_ folder: URL) {
        let descriptor = open(folder.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .rename, .delete], queue: .main
        )
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { _ = self?.readRemote() }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        watcher = source
    }

    private func scheduleWrite() {
        guard isRunning else { return }
        pendingWrite?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.writeNow() }
        }
        pendingWrite = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    private func writeNow() {
        guard isRunning, let url = Self.fileURL else { return }
        let current = settings.portable
        guard current != agreed else { return }
        do {
            try current.encoded().write(to: url, options: .atomic)
            agreed = current
            lastModified = Self.modified(url)
        } catch {
            NSLog("DockIt: could not write iCloud settings: \(error)")
        }
    }

    /// Applies the file when it changed since last read. Returns whether a file was there to read.
    @discardableResult
    private func readRemote() -> Bool {
        guard isRunning, let url = Self.fileURL else { return false }
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else {
            // Evicted to save space: iCloud keeps a ".settings.json.icloud" placeholder instead.
            // Ask for it back; the folder watcher sees it land.
            let placeholder = url.deletingLastPathComponent().appendingPathComponent(".settings.json.icloud")
            if fm.fileExists(atPath: placeholder.path) {
                try? fm.startDownloadingUbiquitousItem(at: url)
                return true
            }
            return false
        }
        let modified = Self.modified(url)
        if let modified, modified == lastModified { return true }
        guard let data = try? Data(contentsOf: url), let remote = try? PortableSettings.decoded(from: data) else {
            return true
        }
        lastModified = modified
        agreed = remote
        settings.apply(remote)
        return true
    }

    private static func modified(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }
}
