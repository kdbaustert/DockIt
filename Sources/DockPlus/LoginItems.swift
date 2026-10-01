import Foundation

/// The macOS Dock's Options ▸ Open at Login, for any app.
///
/// macOS has no current API for another app's login items: `SMAppService` covers only the calling
/// app. The shared file list it replaced still reads and writes them — measured on macOS 27.2,
/// 2026-09-30: an app added showed in the list at once and was removed cleanly, with no permission
/// prompt. Deprecated since macOS 10.11, so every call goes through its C symbol, as SkyLight's do:
/// no deprecation warnings, and a macOS that stops vending one reads as "not a login item" and adds
/// nothing, rather than failing to launch.
@MainActor
enum LoginItems {
    private typealias CreateFn = @convention(c) (CFAllocator?, CFString, AnyObject?) -> Unmanaged<AnyObject>?
    private typealias SnapshotFn = @convention(c) (AnyObject, UnsafeMutablePointer<UInt32>?) -> Unmanaged<CFArray>?
    private typealias ResolveFn = @convention(c) (
        AnyObject, UInt32, UnsafeMutablePointer<Unmanaged<CFError>?>?
    ) -> Unmanaged<CFURL>?
    private typealias RemoveFn = @convention(c) (AnyObject, AnyObject) -> Int32
    /// The position is a raw pointer, not an object: "at the end" is the sentinel value 2, and Swift
    /// retaining it as an object crashed (measured).
    private typealias InsertFn = @convention(c) (
        AnyObject, UnsafeRawPointer?, CFString?, OpaquePointer?, CFURL, CFDictionary?, CFArray?
    ) -> Unmanaged<AnyObject>?

    private static let create = symbol("LSSharedFileListCreate", CreateFn.self)
    private static let snapshot = symbol("LSSharedFileListCopySnapshot", SnapshotFn.self)
    private static let resolve = symbol("LSSharedFileListItemCopyResolvedURL", ResolveFn.self)
    private static let remove = symbol("LSSharedFileListItemRemove", RemoveFn.self)
    private static let insert = symbol("LSSharedFileListInsertItemURL", InsertFn.self)
    /// Both constants are globals, so the symbol is where the value lives, not the value.
    private static let sessionLoginItems = dlsym(defaultHandle, "kLSSharedFileListSessionLoginItems")?
        .load(as: CFString?.self)
    private static let atEnd = dlsym(defaultHandle, "kLSSharedFileListItemLast")?.load(as: UnsafeRawPointer?.self)

    /// Resolving an item never asks the user anything and never mounts a volume to find it.
    private static let resolveFlags: UInt32 = 1 | 2

    /// Read when the menu is built, like Assign To: the list belongs to macOS, and nothing announces
    /// a change to it.
    static func opensAtLogin(_ app: URL) -> Bool {
        guard let list = sessionList() else { return false }
        return item(for: app, in: list) != nil
    }

    /// A failure is logged, not shown: the menu is closed by then, and reopening it reads the list
    /// again, so its tick already tells the truth.
    static func setOpensAtLogin(_ app: URL, _ on: Bool) {
        guard let list = sessionList() else {
            NSLog("DockPlus: the login items list is unavailable; \(app.lastPathComponent) left as it was")
            return
        }
        let existing = item(for: app, in: list)
        if on {
            guard existing == nil else { return }
            guard let insert, let atEnd,
                  insert(list, atEnd, nil, nil, app as CFURL, nil, nil)?.takeRetainedValue() != nil
            else {
                NSLog("DockPlus: could not add \(app.lastPathComponent) to the login items")
                return
            }
        } else if let existing {
            let status = remove.map { $0(list, existing) }
            if status != 0 {
                NSLog("DockPlus: could not remove \(app.lastPathComponent) from the login items: \(status.map(String.init) ?? "no symbol")")
            }
        }
    }

    private static func sessionList() -> AnyObject? {
        guard let create, let sessionLoginItems else { return nil }
        return create(nil, sessionLoginItems, nil)?.takeRetainedValue()
    }

    private static func item(for app: URL, in list: AnyObject) -> AnyObject? {
        guard let snapshot, let resolve,
              let items = snapshot(list, nil)?.takeRetainedValue() as? [AnyObject]
        else { return nil }
        // By path, as the Dock's tiles are matched: a resolved item's URL ends in a slash where one
        // built from a symlinked bundle's path does not.
        let target = DockModel.key(app)
        return items.first { item in
            let url = resolve(item, resolveFlags, nil)?.takeRetainedValue() as URL?
            return url.map(DockModel.key) == target
        }
    }

    /// RTLD_DEFAULT: CoreServices is already loaded, under AppKit.
    private static let defaultHandle = UnsafeMutableRawPointer(bitPattern: -2)

    private static func symbol<T>(_ name: String, _ type: T.Type) -> T? {
        dlsym(defaultHandle, name).map { unsafeBitCast($0, to: T.self) }
    }
}
