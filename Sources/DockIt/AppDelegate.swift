import AppKit
import ServiceManagement
import Sparkle

@main
@MainActor
enum DockitApp {
    static func main() {
        let app = NSApplication.shared
        // NSApp holds its delegate weakly; this local lives as long as `run()`, which never returns.
        let delegate = AppDelegate()
        app.delegate = delegate
        // In code, not `LSUIElement` in Info.plist: with that key, macOS still took the menu bar
        // away while Settings had switched the app to `.regular`. Set before `run()`, so no Dock
        // icon appears at launch either way.
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = DockSettings.shared
    private var model: DockModel?
    private var controllers: [DockController] = []
    private var menuBarItem: MenuBarItem?
    private var settingsSync: SettingsSync?
    private var watchdog: Timer?
    /// Answers Sparkle's "which channels?" before each check. Held here because Sparkle keeps only
    /// a weak reference to its delegate.
    private let updateChannels = UpdateChannels()
    /// nil in a build with no feed (every plain `build.sh` build), where an updater could only fail.
    private var updater: SPUStandardUpdaterController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let model = DockModel(settings: settings)
        self.model = model
        rebuildControllers()
        // Both what decides which screens get a dock: the setting, and the screens themselves.
        observeContinuously(ownedBy: self) { [settings] in
            _ = (settings.displayMode, settings.specificDisplay)
        } onChange: { [weak self] in
            self?.rebuildControllers()
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuildControllers() }
        }
        // `startingUpdater: true` starts the scheduled daily check (SUEnableAutomaticChecks).
        if Updater.isConfigured {
            updater = SPUStandardUpdaterController(
                startingUpdater: true, updaterDelegate: updateChannels, userDriverDelegate: nil)
        }
        menuBarItem = MenuBarItem(settings: settings, updater: updater)
        settingsSync = SettingsSync(settings: settings)
        if settings.hidesSystemDock { SystemDock.hide() }
        // The Dock's preferences are not DockIt's to keep. Something else rewrote them within an hour
        // of the first install — the delay vanished and the Dock slid up at the screen edge again —
        // so hiding once at launch is not enough. The check is two preference reads; the Dock is
        // only touched when they are wrong.
        let watchdog = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                if self?.settings.hidesSystemDock == true { SystemDock.hide() }
            }
        }
        watchdog.tolerance = 1
        RunLoop.main.add(watchdog, forMode: .common)
        self.watchdog = watchdog
    }

    /// One dock per screen the display mode names. Rebuilt whole on any change: controllers are
    /// cheap, and reconciling panels across display setups is exactly the bookkeeping that breeds
    /// stale frames.
    private func rebuildControllers() {
        guard let model else { return }
        for controller in controllers { controller.tearDown() }
        let screens = NSScreen.screens
        guard let first = screens.first else {
            controllers = []
            return
        }
        let targets: [NSScreen] = switch settings.displayMode {
        case .all: screens
        case .specific: [screens.first { $0.displayUUID == settings.specificDisplay } ?? first]
        case .followPointer, .primary: [first]
        }
        controllers = targets.map { DockController(model: model, settings: settings, screen: $0) }
    }

    /// Opening DockIt again while it runs — Finder, Spotlight, Launchpad — shows Settings: with no
    /// window and possibly no menu-bar icon, there is otherwise nothing to show that it heard.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        SettingsWindow.show()
        return false
    }

    /// Asks whether to bring the macOS Dock back. Not at logout or shutdown: nobody is there to
    /// answer. Then it is restored without asking, unless DockIt starts at login — only then does
    /// something hide the Dock again, and restoring would just flash it at the next login. Without
    /// the login item, keeping it hidden left the next session with no dock at all. Nor for an
    /// update's relaunch: the new copy starts at once and hides the Dock again from the saved
    /// originals, which stay in place.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard settings.hidesSystemDock, !updateChannels.isRelaunchingForUpdate else { return .terminateNow }
        if Self.isSystemQuit() {
            if SMAppService.mainApp.status != .enabled {
                watchdog?.invalidate()
                SystemDock.restore()
            }
            return .terminateNow
        }

        let alert = NSAlert()
        alert.messageText = "Restore the macOS Dock?"
        alert.informativeText = """
            If you keep it hidden, you will have no dock until DockIt is opened again.
            """
        alert.addButton(withTitle: "Restore Dock")
        alert.addButton(withTitle: "Keep Hidden")
        alert.addButton(withTitle: "Cancel")
        // The blunt form: DockIt is a background app with nothing frontmost, and the polite
        // `activate()` can be declined, leaving the alert behind other apps' windows.
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            // The watchdog would re-hide the Dock from inside the restore, whose waits spin the run loop.
            watchdog?.invalidate()
            SystemDock.restore()
            return .terminateNow
        case .alertSecondButtonReturn:
            // The saved originals stay in place, so a later quit can still restore them.
            return .terminateNow
        default:
            return .terminateCancel
        }
    }

    /// Whether this quit is a logout, restart or shutdown — read from the quit event itself rather
    /// than remembered from a power-off notification, which stays set if the logout is cancelled.
    private static func isSystemQuit() -> Bool {
        guard let reason = NSAppleEventManager.shared().currentAppleEvent?
            .attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason))?.typeCodeValue
        else { return false }
        let systemReasons = [kAELogOut, kAEReallyLogOut, kAEShowRestartDialog, kAERestart,
                             kAEShowShutdownDialog, kAEShutDown]
        return systemReasons.contains(reason)
    }
}
