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
    var revealSensitivity: Double?
    var revealDelay: Double?
    var hideDelay: Double?
    var revealSpeed: Double?
    var hideSpeed: Double?
    var showsWindowPreviews: Bool?
    var previewDelay: Double?
    var previewShowsControls: Bool?
    var livePreviews: Bool?
    var showsMinimizedWindows: Bool?
    var showsNowPlaying: Bool?
    var showsWeather: Bool?
    var showsClock: Bool?
    var widgetOrder: [String]?
    var weatherLocation: String?
    var weatherLatitude: Double?
    var weatherLongitude: Double?
    var weatherFahrenheit: Bool?
    var clock24Hour: Bool?
    var barTint: String?
    var barTintIntensity: Double?
    var barCornerRadius: Double?
    var iconShadows: Bool?
    var showsRunningDots: Bool?
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

    /// Every number pulled into the range its Settings slider offers. A file is outside input: one
    /// carrying 1e20 would reach the sliders' `Int(value)` labels, which trap on it.
    func clamped() -> PortableSettings {
        func clamp(_ value: Double?, _ range: ClosedRange<Double>) -> Double? {
            value.map { min(max($0, range.lowerBound), range.upperBound) }
        }
        var p = self
        p.iconSize = clamp(iconSize, 24...128)
        p.iconPadding = clamp(iconPadding, 0...24)
        p.dockPadding = clamp(dockPadding, 0...24)
        p.magnifyAmount = clamp(magnifyAmount, 1...2.5)
        p.barTintIntensity = clamp(barTintIntensity, 0...60)
        p.barCornerRadius = clamp(barCornerRadius, 8...24)
        p.weatherLatitude = clamp(weatherLatitude, -90...90)
        p.weatherLongitude = clamp(weatherLongitude, -180...180)
        p.magnifyReach = clamp(magnifyReach, 1...4)
        p.hoverIntensity = clamp(hoverIntensity, 0...40)
        p.previewDelay = clamp(previewDelay, 0...2)
        p.revealSensitivity = clamp(revealSensitivity, 1...20)
        p.revealDelay = clamp(revealDelay, 0...2)
        p.hideDelay = clamp(hideDelay, 0...2)
        p.revealSpeed = clamp(revealSpeed, 0.25...4)
        p.hideSpeed = clamp(hideSpeed, 0.25...4)
        return p
    }
}

extension DockSettings {
    var portable: PortableSettings {
        PortableSettings(
            edge: edge.rawValue, iconSize: iconSize, iconPadding: iconPadding, dockPadding: dockPadding,
            magnifies: magnifies, magnifyAmount: magnifyAmount, magnifyReach: magnifyReach,
            magnifyOnApproach: magnifyOnApproach, smoothHover: smoothHover,
            hoverIntensity: hoverIntensity, bouncesOnLaunch: bouncesOnLaunch, autoHides: autoHides,
            revealSensitivity: revealSensitivity, revealDelay: revealDelay, hideDelay: hideDelay,
            revealSpeed: revealSpeed, hideSpeed: hideSpeed,
            showsWindowPreviews: showsWindowPreviews, previewDelay: previewDelay,
            previewShowsControls: previewShowsControls,
            livePreviews: livePreviews, showsMinimizedWindows: showsMinimizedWindows,
            showsNowPlaying: showsNowPlaying, showsWeather: showsWeather, showsClock: showsClock,
            widgetOrder: widgetOrder, weatherLocation: weatherLocation,
            weatherLatitude: weatherLatitude, weatherLongitude: weatherLongitude,
            weatherFahrenheit: weatherFahrenheit,
            clock24Hour: clock24Hour, barTint: barTint, barTintIntensity: barTintIntensity,
            barCornerRadius: barCornerRadius, iconShadows: iconShadows,
            showsRunningDots: showsRunningDots,
            showsMenuBarIcon: showsMenuBarIcon, pinnedApps: pinnedApps, stacks: stacks, hiddenApps: hiddenApps
        )
    }

    /// Assigns only what differs, so an unchanged value does not fire its observers (the panel would
    /// re-lay out for nothing).
    func apply(_ incoming: PortableSettings) {
        let p = incoming.clamped()
        if let v = p.edge.flatMap(DockEdge.init(rawValue:)), v != edge { edge = v }
        if let v = p.iconSize, v != iconSize { iconSize = v }
        if let v = p.iconPadding, v != iconPadding { iconPadding = v }
        if let v = p.dockPadding, v != dockPadding { dockPadding = v }
        if let v = p.magnifies, v != magnifies { magnifies = v }
        if let v = p.magnifyAmount, v != magnifyAmount { magnifyAmount = v }
        // An old export carries points; a current one carries the multiple, which wins.
        if p.magnifyAmount == nil, let v = p.magnifiedSize, iconSize > 0 {
            let amount = legacyMagnifyAmount(magnifiedSize: v, iconSize: iconSize)
            if amount != magnifyAmount { magnifyAmount = amount }
        }
        if let v = p.magnifyReach, v != magnifyReach { magnifyReach = v }
        if let v = p.magnifyOnApproach, v != magnifyOnApproach { magnifyOnApproach = v }
        if let v = p.smoothHover, v != smoothHover { smoothHover = v }
        if let v = p.hoverIntensity, v != hoverIntensity { hoverIntensity = v }
        if let v = p.bouncesOnLaunch, v != bouncesOnLaunch { bouncesOnLaunch = v }
        if let v = p.autoHides, v != autoHides { autoHides = v }
        if let v = p.revealSensitivity, v != revealSensitivity { revealSensitivity = v }
        if let v = p.revealDelay, v != revealDelay { revealDelay = v }
        if let v = p.hideDelay, v != hideDelay { hideDelay = v }
        if let v = p.revealSpeed, v != revealSpeed { revealSpeed = v }
        if let v = p.hideSpeed, v != hideSpeed { hideSpeed = v }
        if let v = p.showsWindowPreviews, v != showsWindowPreviews { showsWindowPreviews = v }
        if let v = p.previewDelay, v != previewDelay { previewDelay = v }
        if let v = p.previewShowsControls, v != previewShowsControls { previewShowsControls = v }
        if let v = p.livePreviews, v != livePreviews { livePreviews = v }
        if let v = p.showsMinimizedWindows, v != showsMinimizedWindows { showsMinimizedWindows = v }
        if let v = p.showsNowPlaying, v != showsNowPlaying { showsNowPlaying = v }
        if let v = p.showsWeather, v != showsWeather { showsWeather = v }
        if let v = p.showsClock, v != showsClock { showsClock = v }
        if let v = p.widgetOrder, v != widgetOrder { widgetOrder = v }
        if let v = p.weatherLocation, v != weatherLocation { weatherLocation = v }
        if let v = p.weatherLatitude, v != weatherLatitude { weatherLatitude = v }
        if let v = p.weatherLongitude, v != weatherLongitude { weatherLongitude = v }
        if let v = p.weatherFahrenheit, v != weatherFahrenheit { weatherFahrenheit = v }
        if let v = p.clock24Hour, v != clock24Hour { clock24Hour = v }
        if let v = p.barTint, v != barTint { barTint = v }
        if let v = p.barTintIntensity, v != barTintIntensity { barTintIntensity = v }
        if let v = p.barCornerRadius, v != barCornerRadius { barCornerRadius = v }
        if let v = p.iconShadows, v != iconShadows { iconShadows = v }
        if let v = p.showsRunningDots, v != showsRunningDots { showsRunningDots = v }
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
@Observable
final class SettingsSync {
    /// The running sync, for Settings to show its last error.
    private(set) static weak var current: SettingsSync?

    static var folderURL: URL? {
        let cloudDocs = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        guard FileManager.default.fileExists(atPath: cloudDocs.path) else { return nil }
        return cloudDocs.appendingPathComponent("DockIt", isDirectory: true)
    }

    /// False when iCloud Drive is off or signed out on this Mac.
    static var isAvailable: Bool { folderURL != nil }

    private static var fileURL: URL? { folderURL?.appendingPathComponent("settings.json") }

    /// Why the last write failed, until one succeeds; shown under the sync toggle. It used to go
    /// only to the log, so a sync that had stopped working looked exactly like one that worked.
    private(set) var lastError: String?

    @ObservationIgnored private let settings: DockSettings
    @ObservationIgnored private var isRunning = false
    /// The settings the file and this Mac last agreed on. A change that matches it — the echo of
    /// applying the file, or a file this Mac wrote itself — is not sent back round.
    @ObservationIgnored private var agreed: PortableSettings?
    /// Whether this Mac may write: only once it has adopted the file, or seen that there is none.
    /// Until then a write would put this Mac's settings over another's that simply had not
    /// downloaded yet — at a launch offline, or before iCloud had fetched the file.
    @ObservationIgnored private var mayWrite = false
    @ObservationIgnored private var lastModified: Date?
    @ObservationIgnored private var pendingWrite: DispatchWorkItem?
    @ObservationIgnored private var watcher: DispatchSourceFileSystemObject?
    @ObservationIgnored private var poll: Timer?

    init(settings: DockSettings) {
        self.settings = settings
        Self.current = self
        observeContinuously(ownedBy: self) { [weak self] in
            guard let self else { return }
            settings.syncsWithICloud && Self.isAvailable ? start() : stop()
        } onChange: {}
        observeContinuously(ownedBy: self) { [settings] in
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
        // Mac's settings. A file that is not readable yet is left alone: the watcher and the poll
        // read it again once it lands.
        switch readRemote() {
        case .absent:
            writeNow()
        case .adopted, .unchanged:
            // Rewrite what was adopted in the current schema. Without this, a file from an older
            // DockIt is re-adopted at every launch and its converted values stomp any change made
            // since — measured: an old "magnifiedSize" file reset the Amount slider on each launch.
            scheduleWrite()
        case .pending:
            break
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
        mayWrite = false
        lastError = nil
        lastModified = nil
    }

    private func watch(_ folder: URL) {
        let descriptor = open(folder.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .rename, .delete], queue: .main
        )
        source.setEventHandler { [weak self, weak source] in
            let events = source?.data ?? []
            MainActor.assumeIsolated { self?.folderChanged(folder, events: events) }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        watcher = source
    }

    private func folderChanged(_ folder: URL, events: DispatchSource.FileSystemEvent) {
        // The folder itself was deleted or moved: the descriptor now names a dead inode and would
        // never fire again, so watch the path afresh, re-creating the folder if it is gone.
        if events.contains(.delete) || events.contains(.rename) {
            watcher?.cancel()
            watcher = nil
            guard isRunning else { return }
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            watch(folder)
        }
        _ = readRemote()
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
        guard isRunning, mayWrite, let url = Self.fileURL else { return }
        let current = settings.portable
        guard current != agreed else { return }
        do {
            // The folder can be deleted in Finder while sync is on; without it every write fails.
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try current.encoded().write(to: url, options: .atomic)
            agreed = current
            lastModified = Self.modified(url)
            lastError = nil
        } catch {
            NSLog("DockIt: could not write iCloud settings: \(error)")
            lastError = error.localizedDescription
        }
    }

    enum ReadResult { case adopted, unchanged, absent, pending }

    /// Applies the file when it changed since last read.
    @discardableResult
    private func readRemote() -> ReadResult {
        guard isRunning, let url = Self.fileURL else { return .pending }
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else {
            // Evicted to save space, older iCloud: a ".settings.json.icloud" placeholder instead.
            // Ask for it back; the folder watcher sees it land.
            let placeholder = url.deletingLastPathComponent().appendingPathComponent(".settings.json.icloud")
            if fm.fileExists(atPath: placeholder.path) {
                try? fm.startDownloadingUbiquitousItem(at: url)
                return .pending
            }
            mayWrite = true
            return .absent
        }
        // Evicted on macOS 26: the file keeps its name but is "dataless" (`ls -lO`), and reading
        // it downloads it synchronously — on the main thread, for as long as the network takes.
        // Read it on a background queue instead, which brings it down; the watcher sees it land.
        var info = stat()
        if stat(url.path, &info) == 0, info.st_flags & UInt32(SF_DATALESS) != 0 {
            DispatchQueue.global(qos: .utility).async { _ = try? Data(contentsOf: url) }
            return .pending
        }
        let modified = Self.modified(url)
        if let modified, modified == lastModified { return .unchanged }
        guard let data = try? Data(contentsOf: url), let remote = try? PortableSettings.decoded(from: data) else {
            return .pending
        }
        lastModified = modified
        agreed = remote
        mayWrite = true
        lastError = nil
        settings.apply(remote)
        return .adopted
    }

    private static func modified(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }
}
