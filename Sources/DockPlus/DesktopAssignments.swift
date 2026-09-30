import AppKit

/// The macOS Dock's Options ▸ Assign To: which Desktop (Space) an app's windows open on.
///
/// macOS keeps the answer in `com.apple.spaces` under `app-bindings` — lowercased bundle identifier
/// to Space UUID, `AllSpaces` for All Desktops, and no entry for None. An empty string was read as
/// All Desktops once; on macOS 27.2 the Dock writes `AllSpaces` and ignored an empty one, keeping its
/// old Desktop (measured 2026-09-30). Both still read as All Desktops, since older bindings hold "".
///
/// A choice is made by picking the same item in the hidden macOS Dock's own menu, over
/// Accessibility: the Dock owns Spaces, and only it moves the app's open windows at once. Writing
/// the dictionary and restarting the Dock only reached windows opened afterwards (measured: Teams
/// saved as All Desktops stayed on one Desktop). The Dock's menu is on screen for the moment it
/// takes, about 130 ms. What that menu does not list — a Desktop the app's windows are on that is not
/// in front — is written and the Dock restarted instead; its windows are already there to keep.
@MainActor
enum DesktopAssignments {
    enum Assignment: Equatable, Sendable {
        case none
        case allDesktops
        /// One Desktop, by its Space UUID. Never empty: an empty binding means All Desktops.
        case desktop(String)
    }

    /// One display's Desktops, as the window server lists them.
    struct Display: Equatable, Sendable {
        /// The Desktop in front on it.
        let current: String?
        /// Its user Desktops' UUIDs, in the order they are numbered.
        let desktops: [String]
    }

    /// A Desktop item in the menu, ticked when `assignment` is the app's.
    struct Option: Equatable, Sendable {
        let title: String
        let assignment: Assignment
        var isEnabled = true
    }

    private static let domain = "com.apple.spaces" as CFString
    private static let key = "app-bindings" as CFString
    private static let allSpaces = "AllSpaces"

    static func assignment(of bundleID: String) -> Assignment {
        guard let uuid = bindings()[bundleID.lowercased()] else { return .none }
        return uuid.isEmpty || uuid == allSpaces ? .allDesktops : .desktop(uuid)
    }

    /// The Desktop items between All Desktops and None, read from the Space layout now. `pid` is the
    /// app's while it runs, for the Desktops its windows are on.
    static func desktopOptions(for current: Assignment, pid: pid_t?) -> [Option] {
        desktopOptions(displays: Spaces.displays(), current: current,
                       appDesktops: pid.map(Spaces.desktops(ofWindowsOf:)) ?? [])
    }

    /// On each display, the Desktops the app's windows are on (`appDesktops`), so assigning it keeps
    /// it where it already is; with none there, the Desktop in front, as the macOS Dock offers. The one
    /// in front is "This Desktop" with one display and "Desktop on Display 2" with several; any other
    /// goes by its number there. After them, when the app is bound to another of that display's
    /// Desktops, that one. A binding to a Desktop that no longer exists shows as Another Desktop,
    /// ticked and inert, so the tick is not lost. Several displays means "Displays have separate
    /// Spaces" is on; with it off the window server lists one.
    ///
    /// A Desktop can carry an empty UUID — measured 2026-09-28: Desktop 4 of this machine's display
    /// does — and an empty binding already means All Desktops (confirmed against a Messages binding
    /// set in the real Dock). Such a Desktop is offered disabled rather than silently saving All
    /// Desktops. Pure, for the tests.
    nonisolated static func desktopOptions(
        displays: [Display], current: Assignment, appDesktops: Set<String> = []
    ) -> [Option] {
        let several = displays.count > 1
        var options: [Option] = []
        var listed = Set<String>()
        for (index, display) in displays.enumerated() {
            let suffix = several ? " on Display \(index + 1)" : ""
            let frontTitle = several ? "Desktop" + suffix : "This Desktop"
            let front = display.current.flatMap { $0.isEmpty ? nil : $0 }
            let appHere = display.desktops.filter { !$0.isEmpty && appDesktops.contains($0) }
            if appHere.isEmpty {
                options.append(Option(title: frontTitle, assignment: .desktop(front ?? ""), isEnabled: front != nil))
                if let front { listed.insert(front) }
            }
            for (number, uuid) in display.desktops.enumerated() where appHere.contains(uuid) {
                options.append(Option(title: uuid == front ? frontTitle : "Desktop \(number + 1)" + suffix,
                                      assignment: .desktop(uuid)))
                listed.insert(uuid)
            }
            if case .desktop(let bound) = current, !listed.contains(bound),
               let number = display.desktops.firstIndex(of: bound) {
                options.append(Option(title: "Desktop \(number + 1)" + suffix, assignment: current))
                listed.insert(bound)
            }
        }
        if case .desktop(let bound) = current, !listed.contains(bound) {
            options.append(Option(title: "Another Desktop", assignment: current, isEnabled: false))
        }
        return options
    }

    /// Picks `title` for the app at `app` in the Dock's menu, or writes `target` when the Dock's menu
    /// has no such item. Off the main thread: the Dock's menu takes a moment to open.
    static func assign(_ bundleID: String, to target: Assignment, title: String, app: URL) {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first,
              AXIsProcessTrusted()
        else {
            write(bundleID, target)
            return
        }
        let pid = dock.processIdentifier
        pressQueue.async {
            guard !pressDockMenuItem(title, for: app, dockPID: pid) else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { write(bundleID, target) } }
        }
    }

    /// One pick at a time: two menus of the Dock's open at once would each close the other.
    private nonisolated static let pressQueue = DispatchQueue(label: "dev.kennyb.dockplus.assign", qos: .userInitiated)

    /// Opens the Dock's menu for the app's tile and presses `title` in its Options — without opening
    /// that submenu, which the Dock does not need (measured). Closes the menu if the item is missing.
    private nonisolated static func pressDockMenuItem(_ title: String, for app: URL, dockPID: pid_t) -> Bool {
        let dock = AXUIElementCreateApplication(dockPID)
        AXUIElementSetMessagingTimeout(dock, 0.3)
        let target = app.resolvingSymlinksInPath().standardizedFileURL
        let tile = WindowActions.children(of: dock).lazy.flatMap(WindowActions.children(of:)).first { tile in
            var value: CFTypeRef?
            return AXUIElementCopyAttributeValue(tile, kAXURLAttribute as CFString, &value) == .success
                && (value as? URL)?.resolvingSymlinksInPath().standardizedFileURL == target
        }
        guard let tile, AXUIElementPerformAction(tile, "AXShowMenu" as CFString) == .success else { return false }
        // Readable after 12–130 ms in every measurement; half a second before giving up.
        var menu: AXUIElement?
        for _ in 0..<50 {
            menu = WindowActions.children(of: tile).first
            if menu != nil { break }
            usleep(10_000)
        }
        guard let menu else { return false }
        let item = WindowActions.children(of: menu)
            .first { WindowActions.string(of: $0, kAXTitleAttribute) == "Options" }
            .flatMap { WindowActions.children(of: $0).first }
            .flatMap { options in
                WindowActions.children(of: options).first { WindowActions.string(of: $0, kAXTitleAttribute) == title }
            }
        guard let item, AXUIElementPerformAction(item, kAXPressAction as CFString) == .success else {
            AXUIElementPerformAction(menu, "AXCancel" as CFString)
            return false
        }
        return true
    }

    /// The fallback: the dictionary written and the Dock restarted to read it.
    private static func write(_ bundleID: String, _ target: Assignment) {
        let before = bindings()
        var all = before
        let id = bundleID.lowercased()
        switch target {
        case .none:
            all.removeValue(forKey: id)
        case .allDesktops:
            all[id] = allSpaces
        case .desktop(let uuid):
            guard !uuid.isEmpty else { return }
            all[id] = uuid
        }
        // Nothing changed, so there is nothing for the Dock to reread; restarting it would only flash.
        guard all != before else { return }
        CFPreferencesSetAppValue(key, all as CFDictionary, domain)
        CFPreferencesAppSynchronize(domain)
        SystemDock.restartDock()
    }

    private static func bindings() -> [String: String] {
        CFPreferencesAppSynchronize(domain)
        return CFPreferencesCopyAppValue(key, domain) as? [String: String] ?? [:]
    }
}

/// The window server's Space layout, through private SkyLight calls — there is no public API for
/// which Desktop is in front, or for the UUIDs bindings are keyed by.
@MainActor
private enum Spaces {
    private typealias MainConnectionFn = @convention(c) () -> Int32
    private typealias CopyManagedFn = @convention(c) (Int32) -> Unmanaged<CFArray>?
    private typealias SpacesForWindowsFn = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?

    private static let mainConnection = SkyLight.symbol("CGSMainConnectionID", MainConnectionFn.self)
    private static let copyManaged = SkyLight.symbol("CGSCopyManagedDisplaySpaces", CopyManagedFn.self)
    private static let spacesForWindows = SkyLight.symbol("CGSCopySpacesForWindows", SpacesForWindowsFn.self)
    /// Current, other and user Spaces alike: where a window is, not only if it is in front.
    private static let allSpacesMask: Int32 = 7

    /// Each display's Desktops, in the window server's display order. One entry, "Main", when
    /// "Displays have separate Spaces" is off: then every display shares one list. Full-screen apps'
    /// Spaces are left out — they are not Desktops, and are not counted in the numbering.
    static func displays() -> [DesktopAssignments.Display] {
        managedDisplays().map { display in
            let spaces = display["Spaces"] as? [[String: Any]] ?? []
            return DesktopAssignments.Display(
                current: (display["Current Space"] as? [String: Any])?["uuid"] as? String,
                desktops: spaces.filter { ($0["type"] as? Int) == 0 }.compactMap { $0["uuid"] as? String })
        }
    }

    /// The Desktops the app's windows are on. Every window the app has, on any Desktop — the window
    /// list's "all" option, which needs no Screen Recording for ids and owners. A window on more than
    /// one Space is one shown on every Desktop, and names none of them, so it is left out.
    static func desktops(ofWindowsOf pid: pid_t) -> Set<String> {
        guard let mainConnection, let spacesForWindows,
              let info = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]]
        else { return [] }
        let uuids = Dictionary(
            managedDisplays().flatMap { $0["Spaces"] as? [[String: Any]] ?? [] }.compactMap { space in
                (space["ManagedSpaceID"] as? Int).flatMap { id in (space["uuid"] as? String).map { (id, $0) } }
            },
            uniquingKeysWith: { first, _ in first })
        let connection = mainConnection()
        var found = Set<String>()
        for window in info where (window[kCGWindowOwnerPID as String] as? pid_t) == pid
            && (window[kCGWindowLayer as String] as? Int) == 0 {
            guard let id = window[kCGWindowNumber as String] as? UInt32,
                  let spaces = spacesForWindows(connection, allSpacesMask, [NSNumber(value: id)] as CFArray)?
                    .takeRetainedValue() as? [Int],
                  spaces.count == 1, let uuid = uuids[spaces[0]]
            else { continue }
            found.insert(uuid)
        }
        return found
    }

    private static func managedDisplays() -> [[String: Any]] {
        guard let mainConnection, let copyManaged,
              let displays = copyManaged(mainConnection())?.takeRetainedValue() as? [[String: Any]]
        else { return [] }
        return displays
    }
}
