import AppKit

/// The macOS Dock's Options ▸ Assign To: which Desktop (Space) an app's windows open on.
///
/// macOS keeps the answer in `com.apple.spaces` under `app-bindings` — lowercased bundle identifier
/// to Space UUID, with an empty string meaning All Desktops and no entry meaning None (both
/// measured against the live dictionary). The Dock process owns
/// Spaces and reads the dictionary when it starts, so a change is written through CFPreferences and
/// the Dock restarted. Measured 2026-09-28: a binding written that way survived the restart, and
/// every other binding came through untouched.
@MainActor
enum DesktopAssignments {
    enum Assignment: Equatable {
        case none
        case allDesktops
        case thisDesktop
        /// Assigned to a Desktop other than the one in front; its 1-based number when it still
        /// exists.
        case otherDesktop(Int?)
    }

    private static let domain = "com.apple.spaces" as CFString
    private static let key = "app-bindings" as CFString

    /// Whether the Desktop in front can be named in a binding at all. A Desktop can carry an empty
    /// UUID — measured 2026-09-28: Desktop 4 of this machine's display does — and an empty binding
    /// already means All Desktops (confirmed by the user against a Messages binding set in the real
    /// Dock). So on such a Desktop "This Desktop" would silently save All Desktops; it is offered
    /// disabled instead. Also false when the Space layout cannot be read.
    static var canAssignThisDesktop: Bool {
        guard let uuid = Spaces.currentSpaceUUID() else { return false }
        return !uuid.isEmpty
    }

    static func assignment(of bundleID: String) -> Assignment {
        guard let uuid = bindings()[bundleID.lowercased()] else { return .none }
        if uuid.isEmpty { return .allDesktops }
        let spaces = Spaces.userSpaceUUIDs()
        if uuid == Spaces.currentSpaceUUID() { return .thisDesktop }
        return .otherDesktop(spaces.firstIndex(of: uuid).map { $0 + 1 })
    }

    static func assign(_ bundleID: String, to target: Assignment) {
        let before = bindings()
        var all = before
        let id = bundleID.lowercased()
        switch target {
        case .none:
            all.removeValue(forKey: id)
        case .allDesktops:
            all[id] = ""
        case .thisDesktop:
            guard canAssignThisDesktop, let uuid = Spaces.currentSpaceUUID() else { return }
            all[id] = uuid
        case .otherDesktop:
            return
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

    private static let mainConnection = SkyLight.symbol("CGSMainConnectionID", MainConnectionFn.self)
    private static let copyManaged = SkyLight.symbol("CGSCopyManagedDisplaySpaces", CopyManagedFn.self)

    /// The Desktop in front on the display whose dock was clicked. "This Desktop" in the Dock means that one.
    static func currentSpaceUUID() -> String? {
        let displays = managedDisplays()
        // "Main" instead of a UUID when "Displays have separate Spaces" is off: then there is one
        // Space list for every display, and it is the first entry.
        let entry = displays.first { ($0["Display Identifier"] as? String) == dockDisplayUUID() }
            ?? displays.first
        return (entry?["Current Space"] as? [String: Any])?["uuid"] as? String
    }

    /// Every user Desktop's UUID, in the order the Desktops are numbered.
    static func userSpaceUUIDs() -> [String] {
        managedDisplays().flatMap { display -> [String] in
            let spaces = display["Spaces"] as? [[String: Any]] ?? []
            return spaces.filter { ($0["type"] as? Int) == 0 }.compactMap { $0["uuid"] as? String }
        }
    }

    private static func managedDisplays() -> [[String: Any]] {
        guard let mainConnection, let copyManaged,
              let displays = copyManaged(mainConnection())?.takeRetainedValue() as? [[String: Any]]
        else { return [] }
        return displays
    }

    /// The display the pointer is on — the menu asking was opened there, on that display's dock, and
    /// with a dock on every screen the first screen is often the wrong one.
    private static func dockDisplayUUID() -> String? {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.screens.first
        return screen?.displayUUID
    }
}
