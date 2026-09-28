import AppKit
import SwiftUI

/// Owns the panel along the screen edge and decides, from the pointer, what the dock does:
/// magnify, take clicks, auto-hide.
///
/// The panel spans the whole edge and is deep enough for magnified icons and their name labels, so
/// most of it is transparent. It ignores the mouse except while the pointer is over the bar, which
/// lets clicks through to the windows behind everywhere else.
@MainActor
final class DockController {
    private static let labelRoom: CGFloat = 40
    private static let sideLabelRoom: CGFloat = 240
    private static let hideDelay: TimeInterval = 0.5

    private let model: DockModel
    private let settings: DockSettings
    private let panel = DockPanel()
    private var timer: Timer?
    private var isPollingFast = false
    private var leftBarAt: Date?
    private var openMenus = 0

    init(model: DockModel, settings: DockSettings) {
        self.model = model
        self.settings = settings

        let host = FirstMouseHostingView(rootView: DockView(model: model, settings: settings))
        // The panel's frame is DockIt's to set; without this the hosting view resizes the window to
        // fit its content.
        host.sizingOptions = []
        panel.contentView = host
        layoutPanel()
        panel.orderFrontRegardless()

        let center = NotificationCenter.default
        center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.layoutPanel() }
        }
        // An open context menu or stack keeps the dock up even though the pointer has left the bar.
        center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.openMenus += 1 }
        }
        center.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.openMenus = max((self?.openMenus ?? 1) - 1, 0) }
        }
        trackSettings()
        setPolling(fast: false)
    }

    private func trackSettings() {
        observeContinuously { [settings] in
            _ = (settings.edge, settings.iconSize, settings.iconPadding, settings.dockPadding, settings.magnifies, settings.magnifiedSize, settings.autoHides)
        } onChange: { [weak self] in
            self?.layoutPanel()
        }
    }

    private func layoutPanel() {
        guard let screen = NSScreen.screens.first else { return }
        let metrics = model.metrics
        let depth = metrics.magnifiedSize + 2 * metrics.padding
        let full = screen.frame
        // Side docks stop at the menu bar; the bottom dock owns the whole width.
        let top = screen.visibleFrame.maxY
        let frame = switch settings.edge {
        case .bottom:
            NSRect(x: full.minX, y: full.minY, width: full.width, height: depth + Self.labelRoom)
        case .left:
            NSRect(x: full.minX, y: full.minY, width: depth + Self.sideLabelRoom, height: top - full.minY)
        case .right:
            NSRect(x: full.maxX - depth - Self.sideLabelRoom, y: full.minY, width: depth + Self.sideLabelRoom, height: top - full.minY)
        }
        panel.setFrame(frame, display: true)
        model.stripLength = settings.edge == .bottom ? frame.width : frame.height
    }

    // MARK: - Pointer

    /// Polls the pointer rather than monitoring events. A global monitor goes quiet once the pointer
    /// is over DockIt's own panel, a local one needs the panel to be key (it never is), and neither
    /// reliably reports a Finder drag in progress. Reading the location is cheap. Near the edge it
    /// runs at the display's refresh rate (120 Hz on ProMotion) so magnification keeps up with the
    /// pointer; the rate drops to 10 Hz whenever the pointer is away from the edge.
    private func setPolling(fast: Bool) {
        guard timer == nil || fast != isPollingFast else { return }
        timer?.invalidate()
        isPollingFast = fast
        let refreshRate = Double(max(NSScreen.screens.first?.maximumFramesPerSecond ?? 60, 60))
        let timer = Timer(timeInterval: fast ? 1 / refreshRate : 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = fast ? 0.002 : 0.02
        // .common, so it keeps running while a menu or a drag spins the run loop in tracking mode.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        let mouse = NSEvent.mouseLocation
        let frame = panel.frame
        let (along, across) = switch settings.edge {
        case .bottom: (mouse.x - frame.minX, mouse.y - frame.minY)
        case .left: (frame.maxY - mouse.y, mouse.x - frame.minX)
        case .right: (frame.maxY - mouse.y, frame.maxX - mouse.x)
        }
        let metrics = model.metrics
        let layout = model.layout
        let onEdge = along >= 0 && along <= model.stripLength && across >= -1
        // Once magnified, the grown icons are part of the bar; before that, only the resting bar is.
        let reach = model.pointer == nil ? metrics.thickness : (layout.sizes.max() ?? metrics.iconSize) + metrics.padding
        let overBar = onEdge && !model.isHidden
            && along >= layout.start && along <= layout.start + layout.length && across <= reach

        // Only where the bar is: revealed anywhere along the edge, a bar the pointer is not over
        // hides again half a second later and is at once revealed again, over and over.
        let alongBar = along >= layout.start && along <= layout.start + layout.length
        updateAutoHide(onEdge: onEdge && alongBar, across: across, overBar: overBar)

        let pointer = overBar ? along : nil
        if pointer != model.pointer {
            if pointer != nil, model.pointer == nil { model.refreshTrash() }
            // Every update is animated, not just entering and leaving. A spring retargets mid-flight
            // and keeps its velocity, so each new pointer position bends the motion already under
            // way instead of snapping to it — the icons glide after the pointer rather than stepping
            // once per tick, and a non-animated update would cut short any animation in progress.
            let spring: Animation? = if !settings.smoothHover {
                nil
            } else if pointer == nil {
                .smooth(duration: 0.3)
            } else {
                // No overshoot, settling in about a quarter second — DockFix's glide, measured by
                // jumping the pointer between icons: a third grown at 0.11 s, settled by 0.25-0.3 s.
                .smooth(duration: 0.25)
            }
            withAnimation(spring) { model.pointer = pointer }
        }
        if panel.ignoresMouseEvents == overBar { panel.ignoresMouseEvents = !overBar }

        let nearZone = model.isHidden ? 20 : metrics.magnifiedSize + 2 * metrics.padding + 40
        setPolling(fast: onEdge && across < nearZone)
    }

    private func updateAutoHide(onEdge: Bool, across: CGFloat, overBar: Bool) {
        guard settings.autoHides else {
            if model.isHidden { setHidden(false) }
            return
        }
        if model.isHidden {
            if onEdge && across <= 1 { setHidden(false) }
        } else if overBar || openMenus > 0 {
            leftBarAt = nil
        } else if let left = leftBarAt {
            if Date().timeIntervalSince(left) > Self.hideDelay { setHidden(true) }
        } else {
            leftBarAt = Date()
        }
    }

    private func setHidden(_ hidden: Bool) {
        leftBarAt = nil
        withAnimation(.easeInOut(duration: 0.2)) { model.isHidden = hidden }
    }
}

final class DockPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)))
        // On every Space, still during Space switches, out of Cmd-` — and, lacking
        // .fullScreenAuxiliary, absent from full-screen apps, as the real Dock is.
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        // Cmd-H while Settings is frontmost hides the whole app, which would take the dock with it.
        canHide = false
        ignoresMouseEvents = true
    }

    // Never key: clicking the dock must not take focus from the app being used.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Takes the first click even though its window is never key — otherwise every dock click would
/// only "focus" the panel and do nothing.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
