import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

struct DockItem: Identifiable, Equatable, Sendable {
    enum Kind: Sendable { case app, folder, trash, separator, spacer, minimizedWindow, nowPlaying, weather, clock }

    let id: String
    let kind: Kind
    let url: URL?
    let name: String
    let isPinned: Bool
    let isRunning: Bool
    let pid: pid_t?
    /// The window a `.minimizedWindow` tile stands for.
    var windowID: CGWindowID?

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

/// The payload an icon carries while dragged inside the dock: the app's path under a type only DockIt
/// knows. Not the app's file URL, which dropped on Finder would copy or alias the app, and not plain
/// text, which Finder drops on the desktop as a text clipping.
private let dragType = UTType(exportedAs: "dev.kennyb.dockit.item")

@MainActor
@Observable
final class DockModel {
    static let finderPath = "/System/Library/CoreServices/Finder.app"
    static let finderID = key(URL(fileURLWithPath: finderPath))
    static let dropTypes: [UTType] = [.fileURL, dragType]

    private(set) var items: [DockItem] = []
    private(set) var trashIsFull = false
    /// Windows currently in the Dock's sense of minimized — tiles between the separator and Trash.
    private(set) var minimizedWindows: [MinimizedWindow] = []
    /// Their thumbnails, tracked so the tile redraws when a late capture lands.
    private(set) var minimizedThumbs: [CGWindowID: NSImage] = [:]
    /// Item ids of apps between starting to launch and finishing — their icons bounce.
    private(set) var launching: Set<String> = []

    @ObservationIgnored let settings: DockSettings
    @ObservationIgnored private var icons: [String: NSImage] = [:]

    /// The longest an icon bounces. An app that never reports finishing its launch — one that hangs,
    /// or is stopped by Gatekeeper — would otherwise bounce forever.
    private static let launchTimeout: TimeInterval = 15
    /// One bounce — the keyframes in DockIcon (0.3 up + 0.3 down). A bounce only ever stops at the
    /// end of a whole cycle: stopping mid-flight would drop the icon back onto the bar in one frame.
    /// That also means a launch always shows at least one bounce — measured, TextEdit reports
    /// finishing 50 ms after starting, which cut the bounce off before a frame of it was drawn.
    private static let bounceCycle: TimeInterval = 0.6
    @ObservationIgnored private var launchStarts: [String: Date] = [:]
    @ObservationIgnored private var runningObservation: NSKeyValueObservation?
    /// What the running apps looked like at the last rebuild; see the maintenance timer.
    @ObservationIgnored private var lastRunningSignature: [pid_t: Int] = [:]
    /// Counts the maintenance timer's beats, for the minimized windows' periodic full sweep.
    @ObservationIgnored private var maintenanceBeats = 0
    /// Whether the Accessibility prompt has been shown in this run.
    private static var hasPromptedForAccessibility = false

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
                self?.rebuild()
            }
        }
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let url = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleURL
                MainActor.assumeIsolated {
                    if let url { self?.finishedLaunching(url) }
                    self?.rebuild()
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
            Task { @MainActor in self?.rebuild() }
        }
        rebuild()
        refreshTrash()
        trackItems()
        // Minimized windows: a full sweep whenever the frontmost app changes, and on the timer below
        // the frontmost app each beat and every app each 15th (30 s). Asking every app each beat was a
        // round trip per app every two seconds, and it is almost always the frontmost app that
        // minimizes or restores.
        center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.refreshMinimizedWindows() }
        }
        // Things reach the Trash from Finder with nothing announced to DockIt, and it cannot watch a
        // folder it is not allowed to open. Two `stat` calls every couple of seconds costs nothing.
        // The running-app check sweeps up what no notification announces — chiefly an app switching
        // its activation policy to become a regular app after launch. Only the check runs here, not
        // a rebuild: a rebuild touches the disk for every pinned app and stack, and one stack on a
        // dead SMB share would freeze the dock every two seconds.
        let maintenanceTimer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.maintenanceBeats += 1
                self.refreshTrash()
                self.rebuildIfRunningAppsChanged()
                self.refreshMinimizedWindows(frontmostOnly: self.maintenanceBeats % 15 != 0)
            }
        }
        maintenanceTimer.tolerance = 0.5
        RunLoop.main.add(maintenanceTimer, forMode: .common)
    }

    /// Rebuilds whenever the pinned apps or stacks change, whether the dock itself changed them or
    /// the Applications or Stacks tab in Settings did.
    private func trackItems() {
        observeContinuously(ownedBy: self) { [settings] in
            _ = (settings.pinnedApps, settings.stacks, settings.hiddenApps,
                 settings.showsMinimizedWindows, settings.showsNowPlaying, settings.showsWeather,
                 settings.showsClock, settings.widgetOrder, settings.edge)
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

    /// The bar's geometry for one screen's panel. The falloff carries the Reach setting and the
    /// panel's approach gain, so the pure geometry stays free of both.
    func layout(for state: PanelState) -> DockLayout {
        let reach = settings.magnifyReach
        let gain = state.gain
        return DockLayout(
            items: items.map { $0.spec(for: metrics) },
            metrics: metrics,
            stripLength: state.stripLength,
            pointer: state.pointer,
            falloff: { distance, iconSize in
                magnificationFalloff(distance: distance, iconSize: iconSize, reachIcons: reach) * gain
            }
        )
    }

    // MARK: - Items

    /// Every running process with its activation policy — in-memory reads only, no disk.
    private static func runningSignature(_ apps: [NSRunningApplication]) -> [pid_t: Int] {
        Dictionary(apps.map { ($0.processIdentifier, $0.activationPolicy.rawValue) }) { first, _ in first }
    }

    private func rebuildIfRunningAppsChanged() {
        if Self.runningSignature(NSWorkspace.shared.runningApplications) != lastRunningSignature { rebuild() }
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
        var runningByID: [String: NSRunningApplication] = [:]
        for app in running {
            if let url = app.bundleURL { runningByID[Self.key(url)] = app }
        }

        var result: [DockItem] = []
        // Hidden apps start out "seen", so both loops below skip them, pinned or running.
        var seen = Set(settings.hiddenApps.map { Self.key(URL(fileURLWithPath: $0)) })
        seen.remove(Self.finderID)
        for path in [Self.finderPath] + settings.pinnedApps {
            if path.hasPrefix(spacerPrefix) {
                result.append(DockItem(id: path, kind: .spacer, url: nil, name: "", isPinned: true, isRunning: false, pid: nil))
                continue
            }
            let url = URL(fileURLWithPath: path)
            let id = Self.key(url)
            guard !seen.contains(id), FileManager.default.fileExists(atPath: path) else { continue }
            seen.insert(id)
            let app = runningByID[id]
            result.append(DockItem(
                id: id, kind: .app, url: url, name: FileManager.default.displayName(atPath: path),
                isPinned: true, isRunning: app != nil, pid: app?.processIdentifier
            ))
        }
        for app in running {
            let id = app.bundleURL.map(Self.key) ?? "pid:\(app.processIdentifier)"
            guard !seen.contains(id) else { continue }
            seen.insert(id)
            if app.bundleURL == nil, let icon = app.icon { icons[id] = icon }
            result.append(DockItem(
                id: id, kind: .app, url: app.bundleURL, name: app.localizedName ?? "",
                isPinned: false, isRunning: true, pid: app.processIdentifier
            ))
        }
        result.append(DockItem(id: "separator", kind: .separator, url: nil, name: "", isPinned: true, isRunning: false, pid: nil))
        var seenStacks = Set<String>()
        for path in settings.stacks {
            // Folders only, each once: a document tile is not a stack, and a repeated path would give
            // ForEach two items with one id.
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue,
                  seenStacks.insert(path).inserted
            else { continue }
            result.append(DockItem(
                id: "folder:" + path, kind: .folder, url: URL(fileURLWithPath: path),
                name: FileManager.default.displayName(atPath: path), isPinned: true, isRunning: false, pid: nil
            ))
        }
        for window in minimizedWindows {
            result.append(DockItem(
                id: "min:\(window.id)", kind: .minimizedWindow, url: nil, name: window.title,
                isPinned: false, isRunning: true, pid: window.pid, windowID: window.id))
        }
        result.append(DockItem(id: "trash", kind: .trash, url: nil, name: "Trash", isPinned: true, isRunning: false, pid: nil))
        // Bottom only: the widgets are wide, short text tiles, and a side dock's bar is one icon
        // wide — they would spill across the screen or be crushed to nothing.
        // Normalized on every read, not just at load: a sync or an import can hand back an order
        // missing a widget, and a missing one would never show.
        for name in settings.edge == .bottom ? normalizedWidgetOrder(settings.widgetOrder) : [] {
            let enabled: Bool
            let kind: DockItem.Kind
            switch name {
            case "nowPlaying": (enabled, kind) = (settings.showsNowPlaying, .nowPlaying)
            case "weather": (enabled, kind) = (settings.showsWeather, .weather)
            case "clock": (enabled, kind) = (settings.showsClock, .clock)
            default: continue
            }
            guard enabled else { continue }
            result.append(DockItem(id: "widget:" + name, kind: kind, url: nil, name: name, isPinned: true, isRunning: false, pid: nil))
        }

        if result != items { items = result }
    }

    /// Minimized is each app's own word for it: the windows it lists over Accessibility with
    /// AXMinimized set. Inferring it from the window server — off screen and on no Space — let
    /// phantoms through (Teams' shell window and a Rio leftover, measured) and would count whole
    /// other Desktops on macOS 26. The accepted trade-off: Electron apps list no AX windows at all,
    /// so their minimized windows get no tile.
    ///
    /// Only checked, never prompted for: this runs off a timer, and the prompt belongs to a click.
    ///
    /// `frontmostOnly` asks just the frontmost app and keeps what the last sweep found for the rest.
    private func refreshMinimizedWindows(frontmostOnly: Bool = false) {
        guard settings.showsMinimizedWindows, AXIsProcessTrusted(), let getWindowID = WindowActions.getWindowIDFn
        else {
            if !minimizedWindows.isEmpty {
                minimizedWindows = []
                rebuild()
            }
            return
        }
        let me = ProcessInfo.processInfo.processIdentifier
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        var found: [MinimizedWindow] = []
        for app in NSWorkspace.shared.runningApplications
        where app.activationPolicy == .regular && app.processIdentifier != me {
            // Walked in running order either way, so a partial pass keeps the tiles where they were.
            if frontmostOnly, app.processIdentifier != frontmost {
                found += minimizedWindows.filter { $0.pid == app.processIdentifier }
                continue
            }
            let element = AXUIElementCreateApplication(app.processIdentifier)
            // As in restoreMinimizedWindow: on the main thread, a hung app must not stall the dock
            // for the default six seconds.
            AXUIElementSetMessagingTimeout(element, 0.3)
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &value) == .success,
                  let windows = value as? [AXUIElement]
            else { continue }
            for window in windows where Self.isMinimized(window) {
                var id: CGWindowID = 0
                guard getWindowID(window, &id) == .success, id != 0 else { continue }
                // The AX title, which needs no Screen Recording, unlike the window server's.
                let title = Self.string(of: window, kAXTitleAttribute) ?? ""
                found.append(MinimizedWindow(id: id, pid: app.processIdentifier, title: title))
            }
        }
        let known = Set(minimizedWindows.map(\.identity))
        guard Set(found.map(\.identity)) != known else { return }
        let fresh = found.filter { !known.contains($0.identity) }
        minimizedWindows = found
        minimizedThumbs = minimizedThumbs.filter { thumb in found.contains { $0.id == thumb.key } }
        rebuild()
        // Thumbnails arrive late and only for windows still minimized then.
        for window in fresh {
            Task { [weak self] in
                guard let image = await WindowCapture.windowThumbnail(windowID: window.id, maxHeight: 120)
                else { return }
                guard let self, minimizedWindows.contains(where: { $0.identity == window.identity }) else { return }
                minimizedThumbs[window.id] = NSImage(cgImage: image, size: .zero)
            }
        }
    }

    func icon(for item: DockItem) -> NSImage {
        if item.kind == .trash {
            return NSImage(named: trashIsFull ? NSImage.trashFullName : NSImage.trashEmptyName) ?? NSImage()
        }
        if let cached = icons[item.id] { return cached }
        let icon = item.url.map { NSWorkspace.shared.icon(forFile: $0.path) } ?? NSImage()
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
        case .separator, .spacer, .nowPlaying, .weather, .clock:
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
    /// system prompt is shown the first time it is needed in each run, not on every click; after that
    /// the permission is only checked, and this is skipped until it is granted.
    private func restoreMinimizedWindow(of app: NSRunningApplication) {
        let trusted: Bool
        if Self.hasPromptedForAccessibility {
            trusted = AXIsProcessTrusted()
        } else {
            Self.hasPromptedForAccessibility = true
            // The option's key as a literal: the exported `kAXTrustedCheckOptionPrompt` is a mutable
            // global, which Swift 6 will not read from here.
            trusted = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        }
        guard trusted else { return }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        // AX calls block until the app answers, and this runs on the main thread: a hung app would
        // freeze the dock for the default six seconds per call.
        AXUIElementSetMessagingTimeout(element, 0.3)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement]
        else { return }
        // Standard windows only: panels, sheets and palettes do not count as something to show.
        let standard = windows.filter { Self.string(of: $0, kAXSubroleAttribute) == kAXStandardWindowSubrole }
        guard !standard.isEmpty, standard.allSatisfy({ Self.isMinimized($0) }), let window = standard.first else {
            return
        }
        AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
    }

    private static func isMinimized(_ window: AXUIElement) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &value) == .success else {
            return false
        }
        return (value as? Bool) == true
    }

    private static func string(of element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
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
        let elapsed = Date().timeIntervalSince(start)
        let cycles = max((elapsed / Self.bounceCycle).rounded(.up), 1)
        let remaining = cycles * Self.bounceCycle - elapsed
        DispatchQueue.main.asyncAfter(deadline: .now() + remaining) { [weak self] in
            MainActor.assumeIsolated { self?.stopBouncing(id, startedAt: start) }
        }
    }

    /// Only when this is still the launch it was scheduled for: a quit and relaunch inside the
    /// timeout must not have its bounce cut short by the earlier launch's timer.
    private func stopBouncing(_ id: String, startedAt start: Date) {
        guard launchStarts[id] == start else { return }
        launchStarts[id] = nil
        launching.remove(id)
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
        case .trash, .separator, .minimizedWindow, .nowPlaying, .weather, .clock:
            return
        }
    }

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
        guard name != targetName else { return }
        settings.widgetOrder = Self.reordered(settings.widgetOrder, moving: name, before: targetName)
    }

    func addSpacer() {
        settings.addSpacer()
    }

    func emptyTrash() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "tell application \"Finder\" to empty trash"]
        process.terminationHandler = { [weak self] process in
            let failed = process.terminationStatus != 0
            Task { @MainActor in
                self?.refreshTrash()
                if failed { DockModel.explainAutomationDenied() }
            }
        }
        try? process.run()
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

    /// Pins the app at `path` immediately before `target`, or at the end of the pinned apps. Moving an
    /// already pinned app is the same operation: take it out, put it back in.
    func place(_ path: String, before target: DockItem?) {
        let isSpacer = path.hasPrefix(spacerPrefix)
        let id = isSpacer ? path : Self.key(URL(fileURLWithPath: path))
        guard path.hasSuffix(".app") || isSpacer, id != Self.finderID, id != target?.id else { return }
        var pinned = settings.pinnedApps.filter {
            ($0.hasPrefix(spacerPrefix) ? $0 : Self.key(URL(fileURLWithPath: $0))) != id
        }
        var index = pinned.count
        if let target, target.kind == .app || target.kind == .spacer, target.isPinned {
            if target.id == Self.finderID {
                index = 0
            } else if let found = pinned.firstIndex(where: {
                ($0.hasPrefix(spacerPrefix) ? $0 : Self.key(URL(fileURLWithPath: $0))) == target.id
            }) {
                index = found
            }
        }
        pinned.insert(path, at: index)
        settings.pinnedApps = pinned
        // Pinning is an explicit ask to see the app, so it overrides an earlier Hide from Dock.
        settings.hiddenApps.removeAll { Self.key(URL(fileURLWithPath: $0)) == id }
    }

    // MARK: - Drag and drop

    func dragPayload(for item: DockItem) -> NSItemProvider {
        // Spacers and widgets drag by their identity strings, exactly as an app drags by its path.
        if item.kind == .spacer || item.id.hasPrefix(Self.widgetIDPrefix) {
            let provider = NSItemProvider()
            let payload = Data(item.id.utf8)
            provider.registerDataRepresentation(forTypeIdentifier: dragType.identifier, visibility: .ownProcess) {
                completion in
                completion(payload, nil)
                return nil
            }
            return provider
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

    // MARK: - Helpers

    private static let trashURL = URL(fileURLWithPath: NSHomeDirectory() + "/.Trash")

    /// Paths compare after symlinks resolve: a bundle URL and a pinned path can name the same app
    /// through different routes.
    static func key(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    private func runningApp(_ item: DockItem) -> NSRunningApplication? {
        item.pid.flatMap { NSRunningApplication(processIdentifier: $0) }
    }

    /// A folder stack: the 20 most recently added items, newest first, as a menu at the pointer.
    private func showStack(_ folder: URL) {
        let keys: Set<URLResourceKey> = [.addedToDirectoryDateKey, .contentModificationDateKey]
        var files: [URL] = []
        var isDenied = false
        do {
            files = try FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]
            )
        } catch {
            // Desktop, Documents, Downloads and removable volumes are behind a privacy permission; a
            // folder DockIt may not read is not an empty one.
            isDenied = (error as? CocoaError)?.code == .fileReadNoPermission
        }
        func added(_ url: URL) -> Date {
            let values = try? url.resourceValues(forKeys: keys)
            return values?.addedToDirectoryDate ?? values?.contentModificationDate ?? .distantPast
        }

        let menu = NSMenu()
        let newest = files.map { ($0, added($0)) }.sorted { $0.1 > $1.1 }.prefix(20).map(\.0)
        for file in newest {
            let icon = NSWorkspace.shared.icon(forFile: file.path)
            icon.size = NSSize(width: 16, height: 16)
            menu.addItem(ClosureMenuItem(file.lastPathComponent, image: icon) { NSWorkspace.shared.open(file) })
        }
        if isDenied {
            let denied = NSMenuItem(title: "DockIt can't read this folder", action: nil, keyEquivalent: "")
            denied.isEnabled = false
            menu.addItem(denied)
            menu.addItem(ClosureMenuItem("Open Files and Folders Settings…") {
                if let url = URL(
                    string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders"
                ) {
                    NSWorkspace.shared.open(url)
                }
            })
        } else if newest.isEmpty {
            let empty = NSMenuItem(title: "No Items", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Open in Finder") { NSWorkspace.shared.open(folder) })
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
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
