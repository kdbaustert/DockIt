import Foundation

/// The macOS Dock, which DockPlus hides rather than kills: the same process draws Cmd-Tab, Mission
/// Control, Spaces and the wallpaper, so it has to stay running. Auto-hide with a delay no pointer
/// will ever wait out keeps it alive and out of sight.
@MainActor
enum SystemDock {
    private static let domain = "com.apple.dock"
    /// The user's own `autohide` / `autohide-delay`, captured before the first change. A key absent
    /// from the dictionary was absent from the Dock's preferences, and is deleted on restore.
    private static let savedKey = "savedSystemDock"
    private static let hiddenDelay = 1000.0
    /// `restore()` waits on `defaults` and `killall`, and `waitUntilExit()` spins the main run loop
    /// while it does — so the watchdog or the Settings toggle can call `hide()` in the middle of a
    /// restore, while `hidesSystemDock` is still true, and undo it.
    private static var isRestoring = false
    /// Consecutive writes whose values never read back. Something that keeps overriding them would
    /// otherwise get a write and a Dock restart from the watchdog every few seconds, forever.
    private static var failedAttempts = 0
    private static let maxAttempts = 3

    static func hide() {
        guard !isRestoring else { return }
        let store = UserDefaults.standard
        // Only the first time: after a crash or a kill the Dock is still hidden, and capturing it
        // again would overwrite the originals with DockPlus's own values.
        if store.dictionary(forKey: savedKey) == nil {
            let dock = UserDefaults(suiteName: domain)
            var saved: [String: Any] = [:]
            if let value = dock?.object(forKey: "autohide") { saved["autohide"] = value }
            if let value = dock?.object(forKey: "autohide-delay") { saved["autohide-delay"] = value }
            store.set(saved, forKey: savedKey)
        }
        // Read fresh through CFPreferences: this runs every few seconds, and a `UserDefaults` for
        // another app's domain can go on answering from its cache after that app's prefs changed.
        CFPreferencesAppSynchronize(domain as CFString)
        let autohide = CFPreferencesCopyAppValue("autohide" as CFString, domain as CFString) as? Bool
        let delay = CFPreferencesCopyAppValue("autohide-delay" as CFString, domain as CFString) as? Double
        if autohide == true, delay == hiddenDelay {
            failedAttempts = 0
            return
        }
        // A configuration profile that forces the Dock's settings wins over any write.
        if CFPreferencesAppValueIsForced("autohide" as CFString, domain as CFString)
            || CFPreferencesAppValueIsForced("autohide-delay" as CFString, domain as CFString) {
            return
        }
        guard failedAttempts < maxAttempts else {
            if failedAttempts == maxAttempts {
                NSLog("DockPlus: the macOS Dock's auto-hide settings do not stick; no longer re-applying them")
                failedAttempts += 1
            }
            return
        }
        failedAttempts += 1
        defaults(["write", domain, "autohide", "-bool", "true"])
        defaults(["write", domain, "autohide-delay", "-float", String(hiddenDelay)])
        run("/usr/bin/killall", ["Dock"])
    }

    static func restore() {
        let store = UserDefaults.standard
        guard let saved = store.dictionary(forKey: savedKey) else { return }
        isRestoring = true
        defer { isRestoring = false }
        var succeeded = true
        if let value = saved["autohide"] as? Bool {
            succeeded = defaults(["write", domain, "autohide", "-bool", value ? "true" : "false"]) && succeeded
        } else {
            succeeded = delete("autohide") && succeeded
        }
        if let value = saved["autohide-delay"] as? Double {
            succeeded = defaults(["write", domain, "autohide-delay", "-float", String(value)]) && succeeded
        } else {
            succeeded = delete("autohide-delay") && succeeded
        }
        // Only once the Dock really has the originals back; otherwise they are the only copy left.
        if succeeded { store.removeObject(forKey: savedKey) }
        run("/usr/bin/killall", ["Dock"])
    }

    /// `defaults delete` exits non-zero for a key that is already absent, which is the outcome
    /// wanted — so only a key that is there counts against the restore.
    private static func delete(_ key: String) -> Bool {
        CFPreferencesAppSynchronize(domain as CFString)
        guard CFPreferencesCopyAppValue(key as CFString, domain as CFString) != nil else { return true }
        return defaults(["delete", domain, key])
    }

    /// File paths from one of the Dock's tile lists — `persistent-apps` (the pinned apps) or
    /// `persistent-others` (the folders beside the Trash) — used to seed DockPlus on first launch.
    static func tilePaths(_ key: String) -> [String] {
        guard let tiles = UserDefaults(suiteName: domain)?.array(forKey: key) as? [[String: Any]] else {
            return []
        }
        return tiles.compactMap { tile in
            guard let data = tile["tile-data"] as? [String: Any],
                  let file = data["file-data"] as? [String: Any],
                  let string = file["_CFURLString"] as? String
            else { return nil }
            if let url = URL(string: string), url.isFileURL { return url.path }
            return string.hasPrefix("/") ? string : nil
        }
    }

    /// Through the `defaults` tool rather than `UserDefaults(suiteName:)`: the write has to be
    /// flushed to disk before `killall Dock`, and the tool returns only once cfprefsd has it.
    @discardableResult
    private static func defaults(_ arguments: [String]) -> Bool {
        run("/usr/bin/defaults", arguments)
    }

    /// Restarts the Dock so it re-reads preferences it only loads at launch.
    static func restartDock() {
        run("/usr/bin/killall", ["Dock"])
    }

    /// Whether the tool launched and exited with status 0.
    @discardableResult
    private static func run(_ tool: String, _ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            NSLog("DockPlus: \(tool) failed: \(error)")
            return false
        }
    }
}
