import AppKit

/// DockIt's menu bar icon, present while the "Show menu bar icon" setting is on. Hiding it loses
/// nothing: Settings and Quit are also on the dock's own right-click menu.
@MainActor
final class MenuBarItem {
    private let settings: DockSettings
    private var item: NSStatusItem?

    init(settings: DockSettings) {
        self.settings = settings
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
        item.button?.image = NSImage(systemSymbolName: "dock.rectangle", accessibilityDescription: "DockIt")
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem("DockIt Settings…") { SettingsWindow.show() })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Quit DockIt") { NSApp.terminate(nil) })
        item.menu = menu
        self.item = item
    }

    private func remove() {
        guard let item else { return }
        NSStatusBar.system.removeStatusItem(item)
        self.item = nil
    }
}
