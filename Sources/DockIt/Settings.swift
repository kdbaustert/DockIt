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
    var magnifiedSize: Double { didSet { store.set(magnifiedSize, forKey: "magnifiedSize") } }
    /// Icons glide after the pointer on a spring rather than snapping to it each frame.
    var smoothHover: Bool { didSet { store.set(smoothHover, forKey: "smoothHover") } }
    /// Opacity of the highlight behind the hovered icon, in percent; 0 turns it off.
    var hoverIntensity: Double { didSet { store.set(hoverIntensity, forKey: "hoverIntensity") } }
    /// Icons bounce while their app launches, as in the macOS Dock.
    var bouncesOnLaunch: Bool { didSet { store.set(bouncesOnLaunch, forKey: "bouncesOnLaunch") } }
    var autoHides: Bool { didSet { store.set(autoHides, forKey: "autoHides") } }
    var showsMenuBarIcon: Bool { didSet { store.set(showsMenuBarIcon, forKey: "showsMenuBarIcon") } }
    /// Keep the portable settings in iCloud Drive — see SettingsSync. Per Mac, never synced itself.
    var syncsWithICloud: Bool { didSet { store.set(syncsWithICloud, forKey: "syncsWithICloud") } }
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
            "magnifiedSize": 80.0,
            "smoothHover": true,
            "hoverIntensity": 14.0,
            "bouncesOnLaunch": true,
            "autoHides": false,
            "showsMenuBarIcon": true,
            "syncsWithICloud": false,
            "hidesSystemDock": true,
        ])
        edge = DockEdge(rawValue: store.string(forKey: "edge") ?? "") ?? .bottom
        iconSize = store.double(forKey: "iconSize")
        iconPadding = store.double(forKey: "iconPadding")
        dockPadding = store.double(forKey: "dockPadding")
        magnifies = store.bool(forKey: "magnifies")
        magnifiedSize = store.double(forKey: "magnifiedSize")
        smoothHover = store.bool(forKey: "smoothHover")
        hoverIntensity = store.double(forKey: "hoverIntensity")
        bouncesOnLaunch = store.bool(forKey: "bouncesOnLaunch")
        autoHides = store.bool(forKey: "autoHides")
        showsMenuBarIcon = store.bool(forKey: "showsMenuBarIcon")
        syncsWithICloud = store.bool(forKey: "syncsWithICloud")
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
