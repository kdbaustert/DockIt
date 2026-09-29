import AppKit
import Sparkle

/// DockPlus's menu bar icon, present while the "Show menu bar icon" setting is on. Hiding it loses
/// nothing: Settings and Quit are also on the dock's own right-click menu.
///
/// Its menu also lists what is on the dock. That is the keyboard's and VoiceOver's way in: Control-F8
/// or Full Keyboard Access reach the menu bar, while Control-F3 goes to the hidden macOS Dock and no
/// hotkey of DockPlus's own survives Secure Input.
@MainActor
final class MenuBarItem: NSObject, NSMenuDelegate {
    private let settings: DockSettings
    private let model: DockModel
    private let updater: SPUStandardUpdaterController?
    private var item: NSStatusItem?

    init(settings: DockSettings, model: DockModel, updater: SPUStandardUpdaterController?) {
        self.settings = settings
        self.model = model
        self.updater = updater
        super.init()
        update()
    }

    private func update() {
        // Re-running the read is the whole update, so there is nothing more to do on a change.
        observeContinuously(ownedBy: self) { [weak self] in
            guard let self else { return }
            settings.showsMenuBarIcon ? install() : remove()
        } onChange: {}
    }

    private func install() {
        guard item == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = Self.icon()
        let menu = NSMenu()
        // Filled in as it opens, so it costs nothing until then and is never stale.
        menu.delegate = self
        item.menu = menu
        self.item = item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        addDockItems(to: menu)
        menu.addItem(ClosureMenuItem("DockPlus Settings…") { SettingsWindow.show() })
        // Aimed at the controller's own action, which also validates the item: it greys out while a
        // check is already running. Absent from a local build, which has no feed to check.
        if let updater {
            let check = NSMenuItem(
                title: "Check for Updates…",
                action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)), keyEquivalent: "")
            check.target = updater
            menu.addItem(check)
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Quit DockPlus") { NSApp.terminate(nil) })
    }

    /// The dock's apps, stacks, minimized windows and Trash in bar order, each doing what its click
    /// on the bar does. Running apps carry the dock's dot, and a badge follows the name.
    private func addDockItems(to menu: NSMenu) {
        var previous: DockItem.Kind?
        // The running-apps tile's apps go back where the bar would have had them, just before the
        // first separator, so the menu reads the same with the widget on or off.
        var entries = model.items.filter { $0.kind != .runningApps }
        if let collected = model.items.first(where: { $0.kind == .runningApps })?.apps {
            entries.insert(contentsOf: collected, at: entries.firstIndex { $0.kind == .separator } ?? entries.count)
        }
        for dockItem in entries {
            let isEntry = switch dockItem.kind {
            case .app, .folder, .minimizedWindow, .trash: true
            case .separator, .spacer, .nowPlaying, .weather, .clock, .battery, .calendar, .runningApps: false
            }
            guard isEntry else { continue }
            // A rule where the bar has its separator: apps above, everything else below.
            if previous == .app, dockItem.kind != .app { menu.addItem(.separator()) }
            previous = dockItem.kind
            var title = dockItem.name.isEmpty ? "Untitled" : dockItem.name
            if let badge = model.badges[dockItem.id] { title += " (\(badge))" }
            // A copy: the model's icons are the ones on the bar, and resizing one here shrank it there.
            let icon = model.icon(for: dockItem).copy() as? NSImage
            icon?.size = NSSize(width: 16, height: 16)
            let entry = ClosureMenuItem(title, image: icon) { [model] in model.open(dockItem) }
            if dockItem.kind == .app, dockItem.isRunning {
                entry.state = .on
                entry.onStateImage = Self.runningDot
                entry.setAccessibilityValueDescription("running")
            }
            menu.addItem(entry)
        }
        if previous != nil { menu.addItem(.separator()) }
    }

    private static let runningDot = NSImage(size: NSSize(width: 6, height: 6), flipped: false) { rect in
        NSColor.black.set()
        NSBezierPath(ovalIn: rect).fill()
        return true
    }.withTemplate()

    /// A screen with its dock along the bottom edge, the middle tile magnified. Drawn rather than
    /// bundled because build.sh copies only the .icns into Resources, and a template image lets the
    /// system tint it for light, dark and highlighted menu bars.
    private static func icon() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.set()
            let screen = NSBezierPath(
                roundedRect: NSRect(x: 1, y: 2, width: 16, height: 14), xRadius: 3, yRadius: 3)
            screen.lineWidth = 1.5
            screen.stroke()
            let tiles = [
                NSRect(x: 4.2, y: 4.2, width: 2.6, height: 2.6),
                NSRect(x: 7.4, y: 4.2, width: 3.2, height: 4.2),
                NSRect(x: 11.2, y: 4.2, width: 2.6, height: 2.6),
            ]
            for tile in tiles {
                NSBezierPath(roundedRect: tile, xRadius: 0.8, yRadius: 0.8).fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "DockPlus"
        return image
    }

    private func remove() {
        guard let item else { return }
        NSStatusBar.system.removeStatusItem(item)
        self.item = nil
    }
}

private extension NSImage {
    func withTemplate() -> NSImage {
        isTemplate = true
        return self
    }
}
