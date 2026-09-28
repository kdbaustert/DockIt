import AppKit
import ApplicationServices
import ScreenCaptureKit

/// One window's preview: enough to draw the thumbnail and to act on the window afterwards.
/// `CGImage` is immutable; the conformance is stated because the SDK does not.
struct WindowThumb: Identifiable, @unchecked Sendable {
    let id: CGWindowID
    let title: String
    let image: CGImage
}

/// One-shot thumbnails of an app's windows, the way Cmd-Tab's WindowPreview.swift takes them —
/// ScreenCaptureKit screenshots, never a stream. ScreenCaptureKit rather than Accessibility decides
/// which windows exist: AX returns an empty list for Chromium and Electron apps (measured there).
enum WindowCapture {
    @MainActor private static var hasAskedForPermission = false

    /// Previews need Screen Recording. Asks the system once per run, the first time a preview would
    /// appear; after that the panel shows a pointer to System Settings instead.
    @MainActor static var canCapture: Bool { CGPreflightScreenCaptureAccess() }

    @MainActor static func askForPermissionOnce() {
        guard !hasAskedForPermission, !canCapture else { return }
        hasAskedForPermission = true
        CGRequestScreenCaptureAccess()
    }

    /// Front-to-back thumbnails of `pid`'s windows. Empty when permission is missing, the app has no
    /// windows, or the list cannot be read.
    nonisolated static func thumbnails(pid: pid_t, maxHeight: CGFloat) async -> [WindowThumb] {
        guard let content = try? await SCShareableContent
            .excludingDesktopWindows(true, onScreenWindowsOnly: false)
        else { return [] }
        // The title filter is the one that matters: layer-0 debris — Chrome's dropdown surfaces,
        // Electron overlays — is untitled. `onScreenWindowsOnly: false` keeps windows on other
        // Spaces and minimized ones, which capture real pixels (measured by Cmd-Tab, 15–60 ms each).
        let axClaimed = axWindowIDs(pid: pid)
        let windows = content.windows.filter { window in
            guard window.owningApplication?.processID == pid, window.windowLayer == 0,
                window.windowID != 0, window.frame.width > 40, window.frame.height > 40,
                !(window.title ?? "").isEmpty
            else { return false }
            // Titled, full-size phantoms remain — Teams keeps an 800×600 shell window that shows
            // as a strip of buttons (measured 2026-09-28). A real window is on screen, or on some
            // Desktop, or claimed by its app through AX; the shell is none of the three. AX alone
            // cannot decide it: Electron apps claim no windows at all.
            return window.isOnScreen || isOnSomeSpace(window.windowID) || axClaimed.contains(window.windowID)
        }.prefix(10)

        // In parallel, but back in front-to-back order. SCWindow is not Sendable; the wrapper only
        // carries it into the child task, which is the pattern Cmd-Tab uses.
        struct Job: @unchecked Sendable {
            let index: Int
            let window: SCWindow
        }
        let jobs = windows.enumerated().map { Job(index: $0.offset, window: $0.element) }
        let captured: [(Int, WindowThumb)] = await withTaskGroup(of: (Int, WindowThumb)?.self) { group in
            for job in jobs {
                group.addTask {
                    guard let image = await capture(job.window, maxHeight: maxHeight), !isBlank(image) else {
                        return nil
                    }
                    return (job.index, WindowThumb(
                        id: job.window.windowID, title: job.window.title ?? "", image: image))
                }
            }
            var out: [(Int, WindowThumb)] = []
            for await result in group {
                if let result { out.append(result) }
            }
            return out
        }
        return captured.sorted { $0.0 < $1.0 }.map(\.1)
    }

    private typealias MainConnectionFn = @convention(c) () -> Int32
    private typealias CopySpacesForWindowsFn = @convention(c) (Int32, UInt32, CFArray) -> Unmanaged<CFArray>?
    private typealias CopyManagedFn = @convention(c) (Int32) -> Unmanaged<CFArray>?
    private typealias SetCurrentSpaceFn = @convention(c) (Int32, CFString, UInt64) -> Void
    private typealias ShowHideSpacesFn = @convention(c) (Int32, CFArray) -> Void
    private nonisolated(unsafe) static let skyLight = dlopen(
        "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight", RTLD_LAZY)
    private nonisolated(unsafe) static let mainConnection: MainConnectionFn? = {
        guard let skyLight, let sym = dlsym(skyLight, "CGSMainConnectionID") else { return nil }
        return unsafeBitCast(sym, to: MainConnectionFn.self)
    }()
    private nonisolated(unsafe) static let copySpacesForWindows: CopySpacesForWindowsFn? = {
        guard let skyLight, let sym = dlsym(skyLight, "CGSCopySpacesForWindows") else { return nil }
        return unsafeBitCast(sym, to: CopySpacesForWindowsFn.self)
    }()
    private nonisolated(unsafe) static let copyManaged: CopyManagedFn? = {
        guard let skyLight, let sym = dlsym(skyLight, "CGSCopyManagedDisplaySpaces") else { return nil }
        return unsafeBitCast(sym, to: CopyManagedFn.self)
    }()
    private nonisolated(unsafe) static let setCurrentSpace: SetCurrentSpaceFn? = {
        guard let skyLight, let sym = dlsym(skyLight, "CGSManagedDisplaySetCurrentSpace") else { return nil }
        return unsafeBitCast(sym, to: SetCurrentSpaceFn.self)
    }()
    private nonisolated(unsafe) static let showSpaces: ShowHideSpacesFn? = {
        guard let skyLight, let sym = dlsym(skyLight, "CGSShowSpaces") else { return nil }
        return unsafeBitCast(sym, to: ShowHideSpacesFn.self)
    }()
    private nonisolated(unsafe) static let hideSpaces: ShowHideSpacesFn? = {
        guard let skyLight, let sym = dlsym(skyLight, "CGSHideSpaces") else { return nil }
        return unsafeBitCast(sym, to: ShowHideSpacesFn.self)
    }()

    private nonisolated static func spaceID(from dict: [String: Any]) -> UInt64? {
        ((dict["ManagedSpaceID"] as? NSNumber) ?? (dict["id64"] as? NSNumber))?.uint64Value
    }

    /// Switches to the Desktop holding `windowID`, on whichever display that Desktop belongs to.
    /// Show-then-set-then-hide, not the write alone: `CGSManagedDisplaySetCurrentSpace` only
    /// re-points the window server's bookkeeping, and the screen keeps compositing the old Desktop —
    /// Cmd-Tab chased that as "the window jumped to my Desktop and jumped back" before pairing the
    /// write with CGSShowSpaces/CGSHideSpaces (its SpaceMover has the full account).
    @discardableResult
    nonisolated static func travelToSpace(of windowID: CGWindowID) -> Bool {
        guard let mainConnection, let copySpacesForWindows, let copyManaged,
              let setCurrentSpace, let showSpaces, let hideSpaces
        else { return false }
        let cid = mainConnection()
        guard let spaces = copySpacesForWindows(cid, 0x7, [NSNumber(value: windowID)] as CFArray)?
            .takeRetainedValue() as? [NSNumber],
            let windowSpace = spaces.first?.uint64Value,
            let displays = copyManaged(cid)?.takeRetainedValue() as? [[String: Any]]
        else { return false }
        for display in displays {
            guard let ident = display["Display Identifier"] as? String,
                  let list = display["Spaces"] as? [[String: Any]],
                  list.contains(where: { spaceID(from: $0) == windowSpace }),
                  let current = (display["Current Space"] as? [String: Any]).flatMap(spaceID(from:)),
                  current != windowSpace
            else { continue }
            showSpaces(cid, [NSNumber(value: windowSpace)] as CFArray)
            setCurrentSpace(cid, ident as CFString, windowSpace)
            hideSpaces(cid, [NSNumber(value: current)] as CFArray)
            return true
        }
        return false
    }

    /// Whether the window server has the window on any Desktop. 0x7 asks for every kind of Space.
    /// Unreadable counts as "yes": better a phantom thumbnail than real windows vanishing.
    private nonisolated static func isOnSomeSpace(_ windowID: CGWindowID) -> Bool {
        guard let mainConnection, let copySpacesForWindows else { return true }
        guard let spaces = copySpacesForWindows(
            mainConnection(), 0x7, [NSNumber(value: windowID)] as CFArray)?.takeRetainedValue()
        else { return true }
        return CFArrayGetCount(spaces) > 0
    }

    /// The windows the app itself lists over Accessibility. Empty for Electron apps — and when the
    /// permission is missing — so membership can only ever rescue a window, never veto one.
    private nonisolated static func axWindowIDs(pid: pid_t) -> Set<CGWindowID> {
        guard let getWindowID = WindowActions.getWindowIDFn else { return [] }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.3)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement]
        else { return [] }
        var out: Set<CGWindowID> = []
        for window in windows {
            var id: CGWindowID = 0
            if getWindowID(window, &id) == .success, id != 0 { out.insert(id) }
        }
        return out
    }

    /// Captured straight at thumbnail size rather than scaled afterwards.
    private nonisolated static func capture(_ window: SCWindow, maxHeight: CGFloat) async -> CGImage? {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        let scale = min(1, maxHeight / max(window.frame.height, 1))
        config.width = max(Int(window.frame.width * scale), 1)
        config.height = max(Int(window.frame.height * scale), 1)
        config.showsCursor = false
        return try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    /// Whether a capture is a transparent nothing — helper surfaces capture fully clear. Sampled on
    /// a 16×16 grid; blank means fewer than a tenth of the samples carry any alpha.
    private nonisolated static func isBlank(_ image: CGImage) -> Bool {
        let side = 16
        guard let context = CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let data = context.data else { return false }
        let pixels = data.bindMemory(to: UInt8.self, capacity: side * side * 4)
        var opaque = 0
        for i in 0..<(side * side) where pixels[i * 4 + 3] > 8 { opaque += 1 }
        return opaque < side * side / 10
    }
}

/// Acting on one specific window, which only Accessibility can do. Needs the same permission the
/// minimized-window restore already asks for; without it, raising falls back to activating the app.
@MainActor
enum WindowActions {
    /// The only bridge from a CGWindowID to an AX element. Private, but stable enough that Cmd-Tab
    /// ships on it; loaded once, and nil simply downgrades every raise to an app activation.
    typealias GetWindowFn = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    /// Shared with WindowCapture's claims check; the symbol only needs loading once.
    nonisolated(unsafe) static let getWindowIDFn: GetWindowFn? = {
        guard let handle = dlopen(
            "/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_LAZY),
            let symbol = dlsym(handle, "_AXUIElementGetWindow")
        else { return nil }
        return unsafeBitCast(symbol, to: GetWindowFn.self)
    }()

    private typealias SetFrontFn = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UInt32, UInt32) -> OSStatus
    private typealias PostEventFn = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UnsafeMutablePointer<UInt8>) -> OSStatus
    private typealias GetProcessForPIDFn = @convention(c) (pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus

    private nonisolated(unsafe) static let skyLight = dlopen(
        "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight", RTLD_LAZY)
    private nonisolated(unsafe) static let setFront: SetFrontFn? = {
        guard let skyLight, let sym = dlsym(skyLight, "_SLPSSetFrontProcessWithOptions") else { return nil }
        return unsafeBitCast(sym, to: SetFrontFn.self)
    }()
    private nonisolated(unsafe) static let postEvent: PostEventFn? = {
        guard let skyLight, let sym = dlsym(skyLight, "SLPSPostEventRecordTo") else { return nil }
        return unsafeBitCast(sym, to: PostEventFn.self)
    }()
    /// By path, not from the loaded images: Cmd-Tab measured that importing ApplicationServices does
    /// not bring in the image that vends `GetProcessForPID`, leaving the whole path silently dead.
    private nonisolated(unsafe) static let getProcessForPID: GetProcessForPIDFn? = {
        guard let handle = dlopen(
            "/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_LAZY),
            let sym = dlsym(handle, "GetProcessForPID")
        else { return nil }
        return unsafeBitCast(sym, to: GetProcessForPIDFn.self)
    }()

    /// Brings one window forward. Activating the app is not enough here: an app with another window
    /// already visible — say on the second display — keeps focus on that one and never travels, which
    /// was exactly the reported failure. So this fronts the *window* through the window server, the
    /// way Cmd-Tab's FrontProcess does, after switching to its Desktop; app-level activation is only
    /// the fallback when the private symbols are gone.
    static func raise(_ windowID: CGWindowID, pid: pid_t) {
        let app = NSRunningApplication(processIdentifier: pid)
        let axWindow = element(for: windowID, pid: pid)
        if let axWindow {
            AXUIElementSetAttributeValue(axWindow, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            AXUIElementPerformAction(axWindow, kAXRaiseAction as CFString)
        }
        let switched = WindowCapture.travelToSpace(of: windowID)
        // After a Desktop switch, not during it: key events posted mid-transition are swallowed —
        // measured here, Chrome kept its other display's window focused until the focus was retried
        // once the switch had landed.
        let focusNow = { @MainActor in
            if focus(windowID, pid: pid), let axWindow {
                // The app's own bookkeeping, so it draws the window active rather than dimmed.
                AXUIElementSetAttributeValue(axWindow, kAXMainAttribute as CFString, kCFBooleanTrue)
                AXUIElementSetAttributeValue(axWindow, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            }
        }
        if focus(windowID, pid: pid) {
            if let axWindow {
                AXUIElementSetAttributeValue(axWindow, kAXMainAttribute as CFString, kCFBooleanTrue)
                AXUIElementSetAttributeValue(axWindow, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            }
            if switched {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { focusNow() }
            }
        } else if axWindow != nil {
            NSApp.activate(ignoringOtherApps: true)
            app?.activate()
        } else {
            // No AX and no window server: the whole app, all windows.
            NSApp.activate(ignoringOtherApps: true)
            app?.activate(from: .current, options: [.activateAllWindows])
        }
    }

    /// Fronts `window` and sends it the key-state events a real click would have. Without the two
    /// events, apps that track key state themselves draw the window focused-but-dimmed.
    private static func focus(_ windowID: CGWindowID, pid: pid_t) -> Bool {
        guard let setFront, let postEvent, let getProcessForPID else { return false }
        var psn = ProcessSerialNumber()
        guard getProcessForPID(pid, &psn) == noErr else { return false }
        // 0x2: "user generated" — anything else is not treated as a real activation.
        guard setFront(&psn, windowID, 0x2) == noErr else { return false }
        var bytes = [UInt8](repeating: 0, count: 0xf8)
        bytes[0x04] = 0xf8
        bytes[0x3a] = 0x10
        withUnsafeBytes(of: windowID.littleEndian) { raw in
            for (offset, byte) in raw.enumerated() { bytes[0x3c + offset] = byte }
        }
        for index in 0x20..<0x30 { bytes[index] = 0xff }
        bytes[0x08] = 0x01  // window is becoming key
        _ = postEvent(&psn, &bytes)
        bytes[0x08] = 0x02  // and is now key
        _ = postEvent(&psn, &bytes)
        return true
    }

    /// Presses the window's own close button — closing is the window's decision, not a kill.
    static func close(_ windowID: CGWindowID, pid: pid_t) {
        guard let window = element(for: windowID, pid: pid) else { return }
        var button: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXCloseButtonAttribute as CFString, &button) == .success,
              let button = button.map({ $0 as! AXUIElement })
        else { return }
        AXUIElementPerformAction(button, kAXPressAction as CFString)
    }

    private static func element(for windowID: CGWindowID, pid: pid_t) -> AXUIElement? {
        guard AXIsProcessTrusted(), let getWindowID = Self.getWindowIDFn else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.3)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement]
        else { return nil }
        for window in windows {
            var id: CGWindowID = 0
            if getWindowID(window, &id) == .success, id == windowID { return window }
        }
        return nil
    }
}
