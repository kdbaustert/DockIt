import AppKit
import Observation
import SwiftUI

struct DockItem: Identifiable, Equatable, Sendable {
    enum Kind: Sendable {
        case app, folder, trash, separator, spacer, minimizedWindow, nowPlaying, weather, clock, battery, calendar
    }

    let id: String
    let kind: Kind
    let url: URL?
    let name: String
    let isPinned: Bool
    let isRunning: Bool
    let pid: pid_t?
    /// The window a `.minimizedWindow` tile stands for.
    var windowID: CGWindowID?
    /// And the app that window belongs to, for VoiceOver — looked up once per rebuild, not per render.
    var appName: String?

    /// How much of the bar the item takes. The widget widths are fixed points: their content is
    /// text, which does not scale with the icons.
    func spec(for m: DockMetrics) -> DockItemSpec {
        switch kind {
        case .app, .folder, .trash: .icon(m)
        case .minimizedWindow: .init(resting: m.iconSize * 1.4, magnifies: false)
        case .separator: .fixed(m.separatorExtent)
        case .spacer: .fixed(m.iconSize * 0.55)
        case .nowPlaying: .fixed(180)
        case .weather: .fixed(128)
        case .clock: .fixed(84)
        case .battery: .fixed(84)
        case .calendar: .fixed(156)
        }
    }
}

/// Spacers persist inside `pinnedApps` so they order and drag like everything else there.
let spacerPrefix = "spacer:"

struct MinimizedWindow: Equatable, Sendable {
    let id: CGWindowID
    let pid: pid_t
    let title: String

    /// Which window this is, title aside: a title that changes while minimized (a player's track,
    /// a terminal's command) is not a different window and must not rebuild or re-screenshot it.
    struct Identity: Hashable { let id: CGWindowID; let pid: pid_t }
    var identity: Identity { Identity(id: id, pid: pid) }
}

/// A running app's windows, as its context menu lists them.
struct MenuWindows: Equatable, Sendable {
    struct Window: Equatable, Sendable {
        let id: CGWindowID
        let title: String
    }

    let pid: pid_t
    let windows: [Window]
}

@MainActor
@Observable
final class DockModel {
    nonisolated static let finderPath = "/System/Library/CoreServices/Finder.app"
    nonisolated static let finderID = key(URL(fileURLWithPath: finderPath))

    private(set) var items: [DockItem] = []
    private(set) var trashIsFull = false
    // The sweeps' results, and their in-flight flags below, are not `private`: the sweeps that set
    // them live in DockModel+Sweeps.swift, and Swift has no access level for "this type, any file".
    /// Windows currently in the Dock's sense of minimized — tiles between the separator and Trash.
    var minimizedWindows: [MinimizedWindow] = []
    /// Their thumbnails, tracked so the tile redraws when a late capture lands.
    var minimizedThumbs: [CGWindowID: NSImage] = [:]
    /// Item ids of apps between starting to launch and finishing — their icons bounce.
    private(set) var launching: Set<String> = []
    /// Each app's badge — an unread count, usually — by item id.
    var badges: [String: String] = [:]
    /// The windows the last-opened app context menu asked for. One app's at a time: only one menu
    /// is ever open. See `requestMenuWindows` in DockModel+Sweeps.swift.
    var menuWindows: MenuWindows?
    @ObservationIgnored var menuWindowsAsked: (pid: pid_t, at: Date)?

    @ObservationIgnored let settings: DockSettings
    /// Opens a Grid stack's grid from the dock it was clicked on, answering whether one did. Set by
    /// the app delegate, which holds the docks: the model sees the click, and only a dock knows where
    /// the icon is.
    @ObservationIgnored var showStackGrid: ((DockItem) -> Bool)?
    @ObservationIgnored private var icons: [String: NSImage] = [:]

    /// The longest an icon bounces. An app that never reports finishing its launch — one that hangs,
    /// or is stopped by Gatekeeper — would otherwise bounce forever.
    private static let launchTimeout: TimeInterval = 15
    /// One bounce — the keyframes in DockIcon (0.3 up + 0.3 down). A bounce only ever stops at the
    /// end of a whole cycle: stopping mid-flight would drop the icon back onto the bar in one frame.
    /// That also means a launch always shows at least one bounce — measured, TextEdit reports
    /// finishing 50 ms after starting, which cut the bounce off before a frame of it was drawn.
    private nonisolated static let bounceCycle: TimeInterval = 0.6
    @ObservationIgnored private var launchStarts: [String: Date] = [:]
    @ObservationIgnored private var runningObservation: NSKeyValueObservation?
    /// What the running apps looked like at the last rebuild; see the maintenance timer.
    @ObservationIgnored private var lastRunningSignature: [pid_t: Int] = [:]
    /// Counts the maintenance timer's beats, for the minimized windows' periodic full sweep.
    @ObservationIgnored private var maintenanceBeats = 0
    @ObservationIgnored var isSweepingMinimized = false
    @ObservationIgnored var isSweepingBadges = false
    @ObservationIgnored private var maintenanceTimer: Timer?
    @ObservationIgnored private var isRebuildPending = false

    init(settings: DockSettings) {
        self.settings = settings
        let center = NSWorkspace.shared.notificationCenter
        // "Will launch" as well as "did": an app started anywhere — Spotlight, Finder, a link — bounces,
        // as it does in the real Dock, not only one clicked here.
        center.addObserver(forName: NSWorkspace.willLaunchApplicationNotification, object: nil, queue: .main) {
            [weak self] note in
            let url = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleURL
            MainActor.assumeIsolated {
                if let url { self?.startedLaunching(url) }
                // An app that is not pinned has no icon until it is in the running list, so it
                // gets one now to bounce, rather than appearing only once it has finished.
                self?.scheduleRebuild()
            }
        }
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let url = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleURL
                MainActor.assumeIsolated {
                    if let url {
                        self?.finishedLaunching(url)
                        if name == NSWorkspace.didTerminateApplicationNotification { self?.recordQuit(url) }
                    }
                    self?.scheduleRebuild()
                }
            }
        }
        // On NSWorkspace, which lives as long as the process — never on the NSRunningApplication
        // objects themselves. Per-app KVO on `activationPolicy` was tried and crashed (SIGSEGV in
        // AppKit's runningApplicationNotificationCallback, report 2026-09-28-102833): AppKit can
        // deallocate an app's record while it is still observed. Policy flips with no membership
        // change are caught by the timer below instead.
        runningObservation = NSWorkspace.shared.observe(\.runningApplications) {
            @Sendable [weak self] _, _ in
            Task { @MainActor in self?.scheduleRebuild() }
        }
        rebuild()
        refreshTrash()
        trackItems()
        // Minimized windows: a full sweep whenever the frontmost app changes, and on the timer below
        // the frontmost app each beat and every app each 15th (30 s). Asking every app each beat was a
        // round trip per app every two seconds, and it is almost always the frontmost app that
        // minimizes or restores. Badges too: switching to an app is usually reading what its badge
        // counted, and the count should clear then, not at the next slow sweep.
        center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) {
            [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshMinimizedWindows()
                self?.refreshBadges()
            }
        }
        startMaintenance()
    }

    /// Things reach the Trash from Finder with nothing announced to DockIt, and it cannot watch a
    /// folder it is not allowed to open. Two `stat` calls every couple of seconds costs nothing.
    /// The running-app check sweeps up what no notification announces — chiefly an app switching
    /// its activation policy to become a regular app after launch. Only the check runs here, not
    /// a rebuild: a rebuild touches the disk for every pinned app and stack, and one stack on a
    /// dead SMB share would freeze the dock every two seconds.
    ///
    /// The running-app check and the badge sweep run every third beat (6 s). Each is a trip to
    /// another process — about 4 ms of Launch Services for the first, the Dock over Accessibility
    /// for the second — and neither is something anyone watches to the second: a policy flip is
    /// rare, launches and quits are announced, and a badge is also swept on every app switch.
    private func startMaintenance() {
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.maintenanceBeats += 1
                self.refreshTrash()
                self.refreshMinimizedWindows(frontmostOnly: self.maintenanceBeats % 15 != 0)
                if self.maintenanceBeats % 3 == 0 {
                    self.rebuildIfRunningAppsChanged()
                    self.refreshBadges()
                }
            }
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        maintenanceTimer = timer
    }

    /// Stopped while nobody can see the dock; see AppDelegate. Waking catches up at once on
    /// everything the beat would have noticed in the meantime.
    func setPaused(_ paused: Bool) {
        if paused {
            maintenanceTimer?.invalidate()
            maintenanceTimer = nil
            return
        }
        guard maintenanceTimer == nil else { return }
        startMaintenance()
        rebuild()
        refreshTrash()
        refreshMinimizedWindows()
        refreshBadges()
    }

    /// Rebuilds whenever the pinned apps or stacks change, whether the dock itself changed them or
    /// the Applications or Stacks tab in Settings did.
    private func trackItems() {
        observeContinuously(ownedBy: self) { [settings] in
            _ = (settings.pinnedApps, settings.stacks, settings.hiddenApps,
                 settings.showsMinimizedWindows, settings.showsNowPlaying, settings.showsWeather,
                 settings.showsClock, settings.showsBattery, settings.showsCalendar, settings.widgetOrder,
                 settings.edge, settings.showsRecentApps)
        } onChange: { [weak self] in
            self?.rebuild()
        }
    }

    var metrics: DockMetrics {
        DockMetrics(
            iconSize: settings.iconSize,
            magnifiedSize: settings.magnifies ? max(settings.magnifiedSize, settings.iconSize) : settings.iconSize,
            spacing: settings.iconPadding,
            padding: settings.dockPadding
        )
    }

    /// Everything a layout is built from, so an unchanged one is not built again.
    struct LayoutKey: Equatable {
        let items: [DockItem]
        let metrics: DockMetrics
        let stripLength: CGFloat
        let pointer: CGFloat?
        let gain: CGFloat
        let reach: Double
    }

    /// The bar's geometry for one screen's panel, with the icons shrunk to fit that screen's edge.
    /// The falloff carries the Reach setting and the panel's approach gain, so the pure geometry
    /// stays free of both. Cached per panel: the pointer tick (up to 120 Hz) and the view's body both
    /// ask for it, with the same inputs, for every pointer move — and each build is a handful of
    /// arrays. Callers take the metrics from the result, since fitting can change the icon size.
    func layout(for state: PanelState) -> DockLayout {
        let reach = settings.magnifyReach
        let gain = state.gain
        let key = LayoutKey(
            items: items, metrics: metrics, stripLength: state.stripLength, pointer: state.pointer,
            gain: gain, reach: reach)
        if let cached = state.layoutCache, cached.key == key { return cached.layout }
        let items = self.items
        // Some room at either end, as the macOS Dock leaves.
        let fitted = DockLayout.fitted(metrics, available: state.stripLength - 16) { m in
            items.map { $0.spec(for: m) }
        }
        let layout = DockLayout(
            items: items.map { $0.spec(for: fitted) },
            metrics: fitted,
            stripLength: state.stripLength,
            pointer: state.pointer,
            falloff: { distance, iconSize in
                magnificationFalloff(distance: distance, iconSize: iconSize, reachIcons: reach) * gain
            }
        )
        state.layoutCache = (key, layout)
        return layout
    }

    // MARK: - Items

    /// Every running process with its activation policy — in-memory reads only, no disk.
    private static func runningSignature(_ apps: [NSRunningApplication]) -> [pid_t: Int] {
        Dictionary(apps.map { ($0.processIdentifier, $0.activationPolicy.rawValue) }) { first, _ in first }
    }

    private func rebuildIfRunningAppsChanged() {
        if Self.runningSignature(NSWorkspace.shared.runningApplications) != lastRunningSignature { rebuild() }
    }

    /// One rebuild on the next turn of the run loop for however many asked in this one. A launch
    /// alone announces itself three or four times — will launch, the running-apps KVO, did launch —
    /// and each rebuild touches the disk for every pinned app and stack, on the main thread.
    private func scheduleRebuild() {
        guard !isRebuildPending else { return }
        isRebuildPending = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.isRebuildPending = false
                self?.rebuild()
            }
        }
    }

    func rebuild() {
        let me = ProcessInfo.processInfo.processIdentifier
        let myBundleID = Bundle.main.bundleIdentifier
        let all = NSWorkspace.shared.runningApplications
        lastRunningSignature = Self.runningSignature(all)
        // By bundle as well as pid: the now-playing poll's osascript children register under
        // DockIt's bundle as regular apps, and each flashed a tile for its tenth of a second.
        let running = all.filter {
            $0.activationPolicy == .regular && $0.processIdentifier != me
                && (myBundleID == nil || $0.bundleIdentifier != myBundleID)
        }
        var enabledWidgets: Set<String> = []
        if settings.showsNowPlaying { enabledWidgets.insert("nowPlaying") }
        if settings.showsWeather { enabledWidgets.insert("weather") }
        if settings.showsClock { enabledWidgets.insert("clock") }
        if settings.showsBattery, WidgetsModel.hasBattery { enabledWidgets.insert("battery") }
        if settings.showsCalendar { enabledWidgets.insert("calendar") }
        let result = Self.items(
            pinned: settings.pinnedApps, hidden: settings.hiddenApps, stacks: settings.stacks,
            running: running.map(RunningApp.init), recent: settings.showsRecentApps ? settings.recentApps : [],
            minimized: minimizedWindows,
            widgetOrder: settings.widgetOrder, enabledWidgets: enabledWidgets, edge: settings.edge,
            fileExists: { FileManager.default.fileExists(atPath: $0) },
            isFolder: { path in
                var isDirectory: ObjCBool = false
                return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
            },
            displayName: { FileManager.default.displayName(atPath: $0) }
        )
        // An app with no bundle has no file to take an icon from; its process has one.
        for app in running where app.bundleURL == nil {
            if let icon = app.icon { icons[RunningApp(app).id] = icon }
        }

        if result != items { items = result }
        // Only what is on the bar: apps come and go all day, and an app with no bundle gets a new
        // "pid:" key at every launch, so the cache otherwise only ever grew.
        let onBar = Set(result.map(\.id))
        icons = icons.filter { onBar.contains($0.key) }
    }

    /// A running app as the item list needs it: plain values, so the list can be built in a test.
    struct RunningApp: Sendable {
        let pid: pid_t
        let bundleURL: URL?
        let name: String

        /// Its item id: the bundle's resolved path, or the pid for an app with no bundle.
        var id: String { bundleURL.map(DockModel.key) ?? "pid:\(pid)" }
    }

    /// The bar's items in order: Finder, the pinned apps and spacers, the running apps not already
    /// there, the recent apps behind a separator of their own, the separator, the stacks, the
    /// minimized windows, the Trash, then the widgets. The disk is reached only through the three
    /// closures (and `key`'s symlink resolution), for the tests.
    nonisolated static func items(
        pinned: [String], hidden: [String], stacks: [String], running: [RunningApp], recent: [String],
        minimized: [MinimizedWindow], widgetOrder: [String], enabledWidgets: Set<String>, edge: DockEdge,
        fileExists: (String) -> Bool, isFolder: (String) -> Bool, displayName: (String) -> String
    ) -> [DockItem] {
        var runningByID: [String: RunningApp] = [:]
        for app in running {
            if let url = app.bundleURL { runningByID[key(url)] = app }
        }

        var result: [DockItem] = []
        // Hidden apps start out "seen", so both loops below skip them, pinned or running.
        var seen = Set(hidden.map { key(URL(fileURLWithPath: $0)) })
        seen.remove(finderID)
        for path in [finderPath] + pinned {
            if path.hasPrefix(spacerPrefix) {
                result.append(DockItem(id: path, kind: .spacer, url: nil, name: "", isPinned: true, isRunning: false, pid: nil))
                continue
            }
            let url = URL(fileURLWithPath: path)
            let id = key(url)
            guard !seen.contains(id), fileExists(path) else { continue }
            seen.insert(id)
            let app = runningByID[id]
            result.append(DockItem(
                id: id, kind: .app, url: url, name: displayName(path),
                isPinned: true, isRunning: app != nil, pid: app?.pid
            ))
        }
        for app in running {
            let id = app.id
            guard !seen.contains(id) else { continue }
            seen.insert(id)
            result.append(DockItem(
                id: id, kind: .app, url: app.bundleURL, name: app.name,
                isPinned: false, isRunning: true, pid: app.pid
            ))
        }
        // Only apps with no tile already — pinned, running, hidden and Finder are all in `seen` by now.
        var recents: [DockItem] = []
        for path in recent where recents.count < recentAppsShown {
            let url = URL(fileURLWithPath: path)
            let id = key(url)
            guard !seen.contains(id), fileExists(path) else { continue }
            seen.insert(id)
            recents.append(DockItem(
                id: id, kind: .app, url: url, name: displayName(path), isPinned: false, isRunning: false, pid: nil))
        }
        if !recents.isEmpty {
            result.append(DockItem(
                id: "separator:recent", kind: .separator, url: nil, name: "", isPinned: true, isRunning: false, pid: nil))
            result += recents
        }
        result.append(DockItem(id: "separator", kind: .separator, url: nil, name: "", isPinned: true, isRunning: false, pid: nil))
        var seenStacks = Set<String>()
        for path in stacks {
            // Folders only, each once: a document tile is not a stack, and a repeated path would give
            // ForEach two items with one id.
            guard isFolder(path), seenStacks.insert(path).inserted else { continue }
            result.append(DockItem(
                id: "folder:" + path, kind: .folder, url: URL(fileURLWithPath: path),
                name: displayName(path), isPinned: true, isRunning: false, pid: nil
            ))
        }
        let appNames = Dictionary(running.map { ($0.pid, $0.name) }) { first, _ in first }
        for window in minimized {
            result.append(DockItem(
                id: "min:\(window.id)", kind: .minimizedWindow, url: nil, name: window.title,
                isPinned: false, isRunning: true, pid: window.pid, windowID: window.id,
                appName: appNames[window.pid].flatMap { $0.isEmpty ? nil : $0 }))
        }
        result.append(DockItem(id: "trash", kind: .trash, url: nil, name: "Trash", isPinned: true, isRunning: false, pid: nil))
        // Bottom only: the widgets are wide, short text tiles, and a side dock's bar is one icon
        // wide — they would spill across the screen or be crushed to nothing.
        // Normalized on every read, not just at load: a sync or an import can hand back an order
        // missing a widget, and a missing one would never show.
        for name in edge == .bottom ? normalizedWidgetOrder(widgetOrder) : [] {
            let kind: DockItem.Kind
            switch name {
            case "nowPlaying": kind = .nowPlaying
            case "weather": kind = .weather
            case "clock": kind = .clock
            case "battery": kind = .battery
            case "calendar": kind = .calendar
            default: continue
            }
            guard enabledWidgets.contains(name) else { continue }
            result.append(DockItem(id: "widget:" + name, kind: kind, url: nil, name: name, isPinned: true, isRunning: false, pid: nil))
        }
        return result
    }

    func icon(for item: DockItem) -> NSImage {
        if item.kind == .trash {
            return NSImage(named: trashIsFull ? NSImage.trashFullName : NSImage.trashEmptyName) ?? NSImage()
        }
        if let cached = icons[item.id] { return cached }
        let icon = if item.kind == .minimizedWindow {
            // Its app's icon, which marks the tile until the window's snapshot lands.
            item.pid.flatMap { NSRunningApplication(processIdentifier: $0)?.icon } ?? NSImage()
        } else {
            item.url.map { NSWorkspace.shared.icon(forFile: $0.path) } ?? NSImage()
        }
        icons[item.id] = icon
        return icon
    }

    /// Whether the Trash holds anything, without reading it. Listing ~/.Trash needs Full Disk Access
    /// ("Operation not permitted" otherwise, so the Trash always looked empty), but `stat` on the
    /// folder and on a known name inside it does not. Measured on APFS: a folder's link count is 2
    /// plus every item in it, files and folders alike — so the count, less Finder's own `.DS_Store`,
    /// is the number of things in the Trash.
    func refreshTrash() {
        var folder = stat()
        guard stat(Self.trashURL.path, &folder) == 0 else { return }
        var items = Int(folder.st_nlink) - 2
        var dsStore = stat()
        if stat(Self.trashURL.path + "/.DS_Store", &dsStore) == 0 { items -= 1 }
        let full = items > 0
        if full != trashIsFull { trashIsFull = full }
    }

    // MARK: - Actions

    func open(_ item: DockItem) {
        switch item.kind {
        case .app:
            if let app = runningApp(item) {
                bringForward(app)
                restoreMinimizedWindow(of: app)
            } else if let url = item.url {
                // Bounce from the click, not from macOS's "will launch", which can lag a moment
                // behind while Launch Services finds the app.
                startedLaunching(url)
            }
            if let url = item.url {
                // Launches it if it is not running. If it is, this sends the reopen event, which
                // brings back a window when it has none — what a Dock click does; activating alone
                // would leave a windowless app frontmost with nothing to show.
                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            }
        case .folder:
            if let url = item.url { showStack(url) }
        case .trash:
            NSWorkspace.shared.open(Self.trashURL)
        case .minimizedWindow:
            if let windowID = item.windowID, let pid = item.pid {
                WindowActions.raise(windowID, pid: pid)
            }
        case .separator, .spacer, .nowPlaying, .weather, .clock, .battery, .calendar:
            break
        }
    }

    /// Since macOS 14, activation is cooperative: an app can only hand the focus to another while it
    /// holds the focus itself, and a click in DockIt's non-activating panel deliberately never gives
    /// it the focus. So a bare request to activate the clicked app was a request macOS was free to
    /// ignore — and for some apps it did, leaving them behind. Taking the focus for a moment and then
    /// yielding it to the app is the handover the system honours.
    private func bringForward(_ app: NSRunningApplication) {
        NSApp.activate(ignoringOtherApps: true)
        if app.isHidden { app.unhide() }
        // All windows, as a Dock click does — not just the app's key window.
        app.activate(from: .current, options: [.activateAllWindows])
    }

    /// When every window the app has is minimized, puts the frontmost one back — as a Dock click does.
    /// Activating alone brings the app forward with nothing to show, and the reopen event sent after
    /// this only restores a window in apps that choose to handle it; many do not, which is why some
    /// minimized apps stayed minimized.
    ///
    /// Needs Accessibility permission: another app's windows are only reachable through AX. The
    /// system prompt is shown the first time it is needed in each run — here or closing a window from a
    /// preview — not on every click; after that the permission is only checked, and this is skipped
    /// until it is granted.
    private func restoreMinimizedWindow(of app: NSRunningApplication) {
        guard WindowActions.requestAccessibilityOnce(),
              let windows = WindowActions.windows(of: app.processIdentifier)
        else { return }
        // Standard windows only: panels, sheets and palettes do not count as something to show.
        let standard = windows.filter {
            WindowActions.string(of: $0, kAXSubroleAttribute) == kAXStandardWindowSubrole
        }
        guard !standard.isEmpty, standard.allSatisfy(WindowActions.isMinimized), let window = standard.first else {
            return
        }
        AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
    }

    private func startedLaunching(_ url: URL) {
        let id = Self.key(url)
        guard launching.insert(id).inserted else { return }
        let start = Date()
        launchStarts[id] = start
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.launchTimeout) { [weak self] in
            MainActor.assumeIsolated { self?.stopBouncing(id, startedAt: start) }
        }
    }

    /// Stops the bounce at the end of the cycle it is in — at least one whole bounce.
    private func finishedLaunching(_ url: URL) {
        let id = Self.key(url)
        guard let start = launchStarts[id] else { return }
        let remaining = Self.bounceRemaining(after: Date().timeIntervalSince(start))
        DispatchQueue.main.asyncAfter(deadline: .now() + remaining) { [weak self] in
            MainActor.assumeIsolated { self?.stopBouncing(id, startedAt: start) }
        }
    }

    /// How long a bounce `elapsed` seconds in has left until its cycle ends — at least one whole
    /// cycle from the start. Pure, for the tests.
    nonisolated static func bounceRemaining(after elapsed: TimeInterval) -> TimeInterval {
        let cycles = max((elapsed / bounceCycle).rounded(.up), 1)
        return cycles * bounceCycle - elapsed
    }

    /// Only when this is still the launch it was scheduled for: a quit and relaunch inside the
    /// timeout must not have its bounce cut short by the earlier launch's timer.
    private func stopBouncing(_ id: String, startedAt start: Date) {
        guard launchStarts[id] == start else { return }
        launchStarts[id] = nil
        launching.remove(id)
    }

    enum ClickAction: Equatable { case open, reveal, openHidingOthers, hide }

    /// What a click on an item does. Command reveals it in Finder and Option opens an app while
    /// hiding the rest, as in the macOS Dock; with the setting on, a click on the app already in
    /// front hides it. Pure, for the tests.
    nonisolated static func clickAction(
        kind: DockItem.Kind, hasURL: Bool, command: Bool, option: Bool, isFrontmost: Bool,
        hidesFrontmost: Bool
    ) -> ClickAction {
        if command, hasURL, kind == .app || kind == .folder { return .reveal }
        guard kind == .app else { return .open }
        if option { return .openHidingOthers }
        if hidesFrontmost, isFrontmost { return .hide }
        return .open
    }

    /// A click on an icon, with the modifier keys held for it. VoiceOver's press passes none: its
    /// own keys include Option, which would otherwise read as an Option-click and hide every app.
    func click(_ item: DockItem, modifiers: NSEvent.ModifierFlags) {
        let app = runningApp(item)
        let isFrontmost = app != nil
            && app?.processIdentifier == NSWorkspace.shared.frontmostApplication?.processIdentifier
        let action = Self.clickAction(
            kind: item.kind, hasURL: item.url != nil, command: modifiers.contains(.command),
            option: modifiers.contains(.option), isFrontmost: isFrontmost,
            hidesFrontmost: settings.clickHidesFrontmostApp)
        switch action {
        case .open: if !openAsGrid(item) { open(item) }
        case .reveal: reveal(item)
        case .hide: app?.hide()
        case .openHidingOthers:
            open(item)
            hideOthers(than: item)
        }
    }

    /// Every other app hidden. Not `NSApp.hideOtherApplications`: that spares the app calling it —
    /// DockIt — and so would hide the very app just clicked. An app still launching has no pid yet,
    /// so everything else hides and it opens onto a clear screen.
    private func hideOthers(than item: DockItem) {
        let me = ProcessInfo.processInfo.processIdentifier
        for app in NSWorkspace.shared.runningApplications
        where app.activationPolicy == .regular && app.processIdentifier != me
            && app.processIdentifier != item.pid && !app.isHidden {
            app.hide()
        }
    }

    func hide(_ item: DockItem) { runningApp(item)?.hide() }
    func unhide(_ item: DockItem) { runningApp(item)?.unhide() }

    /// Unhidden and in front with every window, without the reopen event a click sends — that
    /// could open a new window in an app that has none, which is not what this asks for.
    func showAllWindows(_ item: DockItem) {
        if let app = runningApp(item) { bringForward(app) }
    }

    func quit(_ item: DockItem) { runningApp(item)?.terminate() }
    func forceQuit(_ item: DockItem) { runningApp(item)?.forceTerminate() }

    func reveal(_ item: DockItem) {
        if let url = item.url { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }

    func pin(_ item: DockItem) {
        if let url = item.url { place(url.path, before: nil) }
    }

    /// Keeps the app out of the dock for good, running or not — and so out of the pinned list too.
    func hideFromDock(_ item: DockItem) {
        guard item.kind == .app, item.id != Self.finderID, let url = item.url else { return }
        if !settings.hiddenApps.contains(where: { Self.key(URL(fileURLWithPath: $0)) == item.id }) {
            settings.hiddenApps.append(url.path)
        }
        settings.pinnedApps.removeAll { Self.key(URL(fileURLWithPath: $0)) == item.id }
    }

    func unpin(_ item: DockItem) {
        switch item.kind {
        case .app:
            settings.pinnedApps.removeAll { Self.key(URL(fileURLWithPath: $0)) == item.id }
        case .folder:
            settings.stacks.removeAll { "folder:" + $0 == item.id }
        case .spacer:
            settings.pinnedApps.removeAll { $0 == item.id }
        case .trash, .separator, .minimizedWindow, .nowPlaying, .weather, .clock, .battery, .calendar:
            return
        }
    }

    // MARK: - Recent apps

    /// As many as the macOS Dock shows.
    nonisolated static let recentAppsShown = 3
    /// More kept than shown: an app on the list that is pinned or running again since has a tile
    /// already and is skipped, and the next one down takes its place rather than leaving a gap.
    nonisolated static let recentAppsKept = 10

    /// Recorded at the quit, not the launch: while an app runs it has a running tile anyway, so
    /// quitting is the moment it becomes recent. Only an app that had a tile of its own on the bar
    /// — not a hidden one, a helper or DockIt's own osascript children — and not Finder, which is
    /// always there. Off, nothing is recorded, so turning the switch on starts an empty list rather
    /// than one kept behind the user's back.
    private func recordQuit(_ url: URL) {
        guard settings.showsRecentApps else { return }
        let id = Self.key(url)
        guard id != Self.finderID, items.contains(where: { $0.id == id && $0.kind == .app && $0.isRunning })
        else { return }
        let updated = Self.recordingRecent(url.path, in: settings.recentApps)
        if updated != settings.recentApps { settings.recentApps = updated }
    }

    /// The recent list once the app at `path` has quit: first, once (compared after symlinks
    /// resolve, as the bar compares apps), and no more than `recentAppsKept`. Pure, for the tests.
    nonisolated static func recordingRecent(_ path: String, in list: [String]) -> [String] {
        let id = key(URL(fileURLWithPath: path))
        return Array(([path] + list.filter { key(URL(fileURLWithPath: $0)) != id }).prefix(recentAppsKept))
    }

    func addSpacer() {
        settings.addSpacer()
    }

    func emptyTrash() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "tell application \"Finder\" to empty trash"]
        let err = Pipe()
        process.standardError = err
        process.terminationHandler = { [weak self] process in
            // Only a refusal (-1743) is a permission problem. Cancelling Finder's "are you sure?"
            // (-128) is the user's answer, and any other failure is not something Automation fixes —
            // both used to bring up the permission alert all the same.
            let message = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let denied = process.terminationStatus != 0 && message.contains("-1743")
            if process.terminationStatus != 0, !denied, !message.contains("-128") {
                NSLog("DockIt: emptying the Trash failed: \(message)")
            }
            Task { @MainActor in
                self?.refreshTrash()
                if denied { DockModel.explainAutomationDenied() }
            }
        }
        do {
            try process.run()
        } catch {
            NSLog("DockIt: could not run osascript to empty the Trash: \(error)")
        }
    }

    /// osascript fails when DockIt is not allowed to control Finder, and otherwise nothing would say so.
    private static func explainAutomationDenied() {
        let alert = NSAlert()
        alert.messageText = "DockIt couldn't empty the Trash"
        alert.informativeText = """
            DockIt needs permission to control Finder. Turn on Finder under DockIt in \
            System Settings › Privacy & Security › Automation.
            """
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        // DockIt is a background app; without this the alert can open behind other windows.
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn,
              let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")
        else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Helpers

    private static let trashURL = URL(fileURLWithPath: NSHomeDirectory() + "/.Trash")

    /// Paths compare after symlinks resolve: a bundle URL and a pinned path can name the same app
    /// through different routes.
    nonisolated static func key(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    private func runningApp(_ item: DockItem) -> NSRunningApplication? {
        item.pid.flatMap { NSRunningApplication(processIdentifier: $0) }
    }
}

extension DockModel.RunningApp {
    init(_ app: NSRunningApplication) {
        self.init(pid: app.processIdentifier, bundleURL: app.bundleURL, name: app.localizedName ?? "")
    }
}

/// An NSMenuItem that runs a closure, since the model is not an NSObject to be a target.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, image: NSImage? = nil, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
        self.image = image
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func fire() { handler() }
}
