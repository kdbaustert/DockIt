import Foundation
import Observation

enum DockEdge: String, CaseIterable {
    case bottom, left, right

    var title: String {
        switch self {
        case .bottom: "Bottom"
        case .left: "Left"
        case .right: "Right"
        }
    }
}

/// Where the dock lives when more than one screen is attached.
enum DisplayMode: String, CaseIterable {
    /// Moves to whichever screen the pointer is on.
    case followPointer
    /// Stays on the screen with the menu bar.
    case primary
    /// Stays on one chosen screen.
    case specific
    /// A dock on every screen at once.
    case all
}

@MainActor
@Observable
final class DockSettings {
    static let shared = DockSettings()

    @ObservationIgnored private let store = UserDefaults.standard

    var edge: DockEdge { didSet { store.set(edge.rawValue, forKey: "edge") } }
    var iconSize: Double { didSet { store.set(iconSize, forKey: "iconSize") } }
    /// Gap between neighbouring icons.
    var iconPadding: Double { didSet { store.set(iconPadding, forKey: "iconPadding") } }
    /// Space between the icons and the bar's edge.
    var dockPadding: Double { didSet { store.set(dockPadding, forKey: "dockPadding") } }
    var magnifies: Bool { didSet { store.set(magnifies, forKey: "magnifies") } }
    /// How much the hovered icon grows, as a multiple of the resting size — 1.35 means 35% larger.
    var magnifyAmount: Double { didSet { store.set(magnifyAmount, forKey: "magnifyAmount") } }
    /// How many icon-widths from the pointer the growth fades to nothing.
    var magnifyReach: Double { didSet { store.set(magnifyReach, forKey: "magnifyReach") } }
    /// Grow gradually as the pointer nears the bar, instead of only once it is over it.
    var magnifyOnApproach: Bool { didSet { store.set(magnifyOnApproach, forKey: "magnifyOnApproach") } }
    /// The magnified size in points, which the layout wants; the stored setting is the multiple.
    var magnifiedSize: Double { iconSize * magnifyAmount }
    /// Icons glide after the pointer on a spring rather than snapping to it each frame.
    var smoothHover: Bool { didSet { store.set(smoothHover, forKey: "smoothHover") } }
    /// Opacity of the highlight behind the hovered icon, in percent; 0 turns it off.
    var hoverIntensity: Double { didSet { store.set(hoverIntensity, forKey: "hoverIntensity") } }
    /// Icons bounce while their app launches, as in the macOS Dock.
    var bouncesOnLaunch: Bool { didSet { store.set(bouncesOnLaunch, forKey: "bouncesOnLaunch") } }
    var autoHides: Bool { didSet { store.set(autoHides, forKey: "autoHides") } }
    /// How far from the screen edge, in points, the pointer counts as pushing against it.
    var revealSensitivity: Double { didSet { store.set(revealSensitivity, forKey: "revealSensitivity") } }
    /// Seconds the pointer must hold the edge before a hidden dock slides out.
    var revealDelay: Double { didSet { store.set(revealDelay, forKey: "revealDelay") } }
    /// Seconds after the pointer leaves before the dock slides away.
    var hideDelay: Double { didSet { store.set(hideDelay, forKey: "hideDelay") } }
    /// Animation speed multipliers; 2 is twice as fast.
    var revealSpeed: Double { didSet { store.set(revealSpeed, forKey: "revealSpeed") } }
    var hideSpeed: Double { didSet { store.set(hideSpeed, forKey: "hideSpeed") } }
    /// Hovering a running app shows thumbnails of its windows.
    var showsWindowPreviews: Bool { didSet { store.set(showsWindowPreviews, forKey: "showsWindowPreviews") } }
    /// Seconds the pointer rests on an icon before its previews appear.
    var previewDelay: Double { didSet { store.set(previewDelay, forKey: "previewDelay") } }
    /// Each thumbnail carries a close button and its window's title.
    var previewShowsControls: Bool { didSet { store.set(previewShowsControls, forKey: "previewShowsControls") } }
    var showsMenuBarIcon: Bool { didSet { store.set(showsMenuBarIcon, forKey: "showsMenuBarIcon") } }
    /// Keep the portable settings in iCloud Drive — see SettingsSync. Per Mac, never synced itself.
    var syncsWithICloud: Bool { didSet { store.set(syncsWithICloud, forKey: "syncsWithICloud") } }
    /// Which screen the dock lives on. Per Mac, like everything display-shaped.
    var displayMode: DisplayMode { didSet { store.set(displayMode.rawValue, forKey: "displayMode") } }
    /// The chosen screen's UUID when `displayMode` is `.specific`.
    var specificDisplay: String { didSet { store.set(specificDisplay, forKey: "specificDisplay") } }
    var hidesSystemDock: Bool {
        didSet {
            store.set(hidesSystemDock, forKey: "hidesSystemDock")
            hidesSystemDock ? SystemDock.hide() : SystemDock.restore()
        }
    }
    /// Pinned app paths in dock order. Finder is not in here: like the real Dock, it is always first.
    var pinnedApps: [String] { didSet { store.set(pinnedApps, forKey: "pinnedApps") } }
    /// Folder paths shown as stacks beside the Trash.
    var stacks: [String] { didSet { store.set(stacks, forKey: "stacks") } }
    /// App paths never shown in the dock, even while running — helpers and background tools.
    var hiddenApps: [String] { didSet { store.set(hiddenApps, forKey: "hiddenApps") } }

    private init() {
        store.register(defaults: [
            "edge": DockEdge.bottom.rawValue,
            "iconSize": 48.0,
            "iconPadding": 4.0,
            "dockPadding": 6.0,
            "magnifies": true,
            "magnifyAmount": 1.35,
            "magnifyReach": 2.0,
            "magnifyOnApproach": false,
            "smoothHover": true,
            "hoverIntensity": 14.0,
            "bouncesOnLaunch": true,
            "autoHides": false,
            "revealSensitivity": 3.0,
            "revealDelay": 0.0,
            "hideDelay": 0.5,
            "revealSpeed": 1.0,
            "hideSpeed": 1.0,
            "showsWindowPreviews": true,
            "previewDelay": 0.5,
            "previewShowsControls": true,
            "showsMenuBarIcon": true,
            "syncsWithICloud": false,
            "displayMode": DisplayMode.primary.rawValue,
            "specificDisplay": "",
            "hidesSystemDock": true,
        ])
        edge = DockEdge(rawValue: store.string(forKey: "edge") ?? "") ?? .bottom
        iconSize = store.double(forKey: "iconSize")
        iconPadding = store.double(forKey: "iconPadding")
        dockPadding = store.double(forKey: "dockPadding")
        magnifies = store.bool(forKey: "magnifies")
        // Migrated once from the old points-based setting, so an existing install keeps its size.
        if store.object(forKey: "magnifyAmount") == nil, store.object(forKey: "magnifiedSize") != nil,
            store.double(forKey: "iconSize") > 0 {
            let ratio = store.double(forKey: "magnifiedSize") / store.double(forKey: "iconSize")
            // Snapped to the slider's own 0.05 steps: 42pt over 36pt icons is 1.1666…, and a value
            // the slider cannot land on reads as a glitch (measured: it showed as "1.17×").
            let snapped = (min(max(ratio, 1.0), 2.5) / 0.05).rounded() * 0.05
            store.set(snapped, forKey: "magnifyAmount")
        }
        magnifyAmount = store.double(forKey: "magnifyAmount")
        magnifyReach = store.double(forKey: "magnifyReach")
        magnifyOnApproach = store.bool(forKey: "magnifyOnApproach")
        smoothHover = store.bool(forKey: "smoothHover")
        hoverIntensity = store.double(forKey: "hoverIntensity")
        bouncesOnLaunch = store.bool(forKey: "bouncesOnLaunch")
        autoHides = store.bool(forKey: "autoHides")
        revealSensitivity = store.double(forKey: "revealSensitivity")
        revealDelay = store.double(forKey: "revealDelay")
        hideDelay = store.double(forKey: "hideDelay")
        revealSpeed = store.double(forKey: "revealSpeed")
        hideSpeed = store.double(forKey: "hideSpeed")
        showsWindowPreviews = store.bool(forKey: "showsWindowPreviews")
        previewDelay = store.double(forKey: "previewDelay")
        previewShowsControls = store.bool(forKey: "previewShowsControls")
        showsMenuBarIcon = store.bool(forKey: "showsMenuBarIcon")
        syncsWithICloud = store.bool(forKey: "syncsWithICloud")
        displayMode = DisplayMode(rawValue: store.string(forKey: "displayMode") ?? "") ?? .primary
        specificDisplay = store.string(forKey: "specificDisplay") ?? ""
        hidesSystemDock = store.bool(forKey: "hidesSystemDock")
        hiddenApps = store.stringArray(forKey: "hiddenApps") ?? []

        // First launch starts from what the macOS Dock already holds, so switching loses nothing.
        // Written straight back so the seed is taken once, not re-read from a Dock DockIt has changed.
        let pinned = store.stringArray(forKey: "pinnedApps")
            ?? SystemDock.tilePaths("persistent-apps").filter { $0.hasSuffix(".app") }
        // Folders only, each once: the Dock's right side also holds document tiles.
        var seenFolders = Set<String>()
        let folders = SystemDock.tilePaths("persistent-others").filter { path in
            var isDirectory: ObjCBool = false
            return !path.hasSuffix(".app")
                && FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
                && seenFolders.insert(path).inserted
        }
        let stacks = store.stringArray(forKey: "stacks")
            ?? (folders.isEmpty ? [NSHomeDirectory() + "/Downloads"] : folders)
        store.set(pinned, forKey: "pinnedApps")
        store.set(stacks, forKey: "stacks")
        pinnedApps = pinned
        self.stacks = stacks
    }
}
