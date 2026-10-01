import Foundation

/// The window server's private framework, opened once for every caller — Space layout, Space
/// switching and window fronting all live here and have no public API.
enum SkyLight {
    /// A `dlopen` handle is an opaque token that is never written after this; it is safe to share.
    private nonisolated(unsafe) static let handle = dlopen(
        "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight", RTLD_LAZY)

    /// The symbol as a C function of type `T`, or nil when this macOS no longer vends it — callers
    /// treat nil as "fall back", never as fatal.
    static func symbol<T>(_ name: String, _ type: T.Type) -> T? {
        guard let handle, let pointer = dlsym(handle, name) else { return nil }
        return unsafeBitCast(pointer, to: T.self)
    }

    // The Space-layout symbols both the capture's Space travel and Desktop assignments read.
    // Declared once: these are private ABI, and two copies had already drifted apart on the mask's
    // type — a macOS change should be one edit.

    typealias MainConnectionFn = @convention(c) () -> Int32
    typealias CopyManagedFn = @convention(c) (Int32) -> Unmanaged<CFArray>?
    typealias CopySpacesForWindowsFn = @convention(c) (Int32, UInt32, CFArray) -> Unmanaged<CFArray>?

    static let mainConnection = symbol("CGSMainConnectionID", MainConnectionFn.self)
    static let copyManaged = symbol("CGSCopyManagedDisplaySpaces", CopyManagedFn.self)
    static let copySpacesForWindows = symbol("CGSCopySpacesForWindows", CopySpacesForWindowsFn.self)

    /// Current, other and user Spaces alike: where a window is, not only if it is in front.
    static let allSpacesMask: UInt32 = 7

    /// Each display's Space dictionaries, as `CGSCopyManagedDisplaySpaces` hands them back; empty
    /// when the symbols are gone.
    static func managedDisplays() -> [[String: Any]] {
        guard let mainConnection, let copyManaged,
              let displays = copyManaged(mainConnection())?.takeRetainedValue() as? [[String: Any]]
        else { return [] }
        return displays
    }
}
