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
}
