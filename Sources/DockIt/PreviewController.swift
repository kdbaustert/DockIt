import AppKit
import SwiftUI

/// The window-preview panel: rest the pointer on a running app and, after the configured delay,
/// thumbnails of its windows appear beside the dock. Fed by `DockController.tick`, which already
/// knows where the pointer is and which item it is over.
@MainActor
final class PreviewController {
    /// How long the pointer may be between the bar and the panel before the panel gives up. The gap
    /// is real: the name labels sit in it.
    private static let leaveGrace: TimeInterval = 0.35
    /// Switching between icons while the panel is already up ignores most of the dwell — as the
    /// Windows taskbar does, where only the first preview waits.
    private static let switchDelay: TimeInterval = 0.1
    private static let thumbHeight: CGFloat = 140

    private let settings: DockSettings
    private let panel = PreviewPanel()
    private let host = FirstMouseHostingView(rootView: AnyView(EmptyView()))

    private var shownItemID: String?
    private var hoverItemID: String?
    private var hoverStart: Date?
    private var leftAt: Date?
    private var captureTask: Task<Void, Never>?
    private var pointerInPanel = false
    /// The screen this dock lives on — where the panel must stay, whichever screen is "first".
    private weak var clampScreen: NSScreen?

    /// While the pointer is in the panel, the dock must not auto-hide under it.
    var keepsDockShown: Bool { panel.isVisible && pointerInPanel }

    init(settings: DockSettings) {
        self.settings = settings
        panel.contentView = host
    }

    /// One pointer tick. `center` is the hovered item's along-axis centre within the strip.
    func update(
        hovered: DockItem?, center: CGFloat?, mouse: NSPoint,
        dockFrame: NSRect, edge: DockEdge, barReach: CGFloat, isDockHidden: Bool,
        screen: NSScreen? = nil
    ) {
        clampScreen = screen
        guard settings.showsWindowPreviews, !isDockHidden else {
            hide()
            return
        }
        pointerInPanel = panel.isVisible && panel.frame.insetBy(dx: -8, dy: -8).contains(mouse)

        let eligible = hovered.flatMap { item -> DockItem? in
            item.kind == .app && item.isRunning && item.pid != nil ? item : nil
        }
        if let item = eligible, let center {
            leftAt = nil
            if item.id == shownItemID { return }
            if item.id != hoverItemID {
                hoverItemID = item.id
                hoverStart = Date()
            }
            let dwell = panel.isVisible ? min(settings.previewDelay, Self.switchDelay) : settings.previewDelay
            if let start = hoverStart, Date().timeIntervalSince(start) >= dwell {
                show(item, center: center, dockFrame: dockFrame, edge: edge, barReach: barReach)
            }
        } else if pointerInPanel {
            leftAt = nil
        } else if panel.isVisible || captureTask != nil {
            // Not over an icon and not in the panel: a grace period covers the walk across the gap.
            if let left = leftAt {
                if Date().timeIntervalSince(left) > Self.leaveGrace { hide() }
            } else {
                leftAt = Date()
            }
        } else {
            hoverItemID = nil
            hoverStart = nil
        }
    }

    func hide() {
        captureTask?.cancel()
        captureTask = nil
        shownItemID = nil
        hoverItemID = nil
        hoverStart = nil
        leftAt = nil
        pointerInPanel = false
        if panel.isVisible {
            panel.orderOut(nil)
            // The thumbnails are the panel's biggest allocation; a dismissed panel keeps none.
            host.rootView = AnyView(EmptyView())
        }
    }

    private func show(_ item: DockItem, center: CGFloat, dockFrame: NSRect, edge: DockEdge, barReach: CGFloat) {
        guard let pid = item.pid else { return }
        shownItemID = item.id

        guard WindowCapture.canCapture else {
            // The system prompt the first time; the pointer to Settings each time after.
            WindowCapture.askForPermissionOnce()
            if !WindowCapture.canCapture {
                present(AnyView(PermissionStrip()), center: center, dockFrame: dockFrame, edge: edge, barReach: barReach)
            }
            return
        }

        captureTask?.cancel()
        captureTask = Task { [weak self] in
            let thumbs = await WindowCapture.thumbnails(pid: pid, maxHeight: Self.thumbHeight)
            guard let self, !Task.isCancelled, shownItemID == item.id else { return }
            captureTask = nil
            guard !thumbs.isEmpty else {
                // Running, but nothing to show — a windowless agent, or every capture came up blank.
                hide()
                return
            }
            let strip = PreviewStrip(
                thumbs: thumbs, showsControls: settings.previewShowsControls,
                raise: { [weak self] id in
                    WindowActions.raise(id, pid: pid)
                    self?.hide()
                },
                close: { [weak self] id in
                    WindowActions.close(id, pid: pid)
                    // The window needs a moment to go; then what is left is re-captured.
                    Task { [weak self] in
                        try? await Task.sleep(for: .milliseconds(450))
                        guard let self, shownItemID == item.id else { return }
                        shownItemID = nil
                        show(item, center: center, dockFrame: dockFrame, edge: edge, barReach: barReach)
                    }
                }
            )
            present(AnyView(strip), center: center, dockFrame: dockFrame, edge: edge, barReach: barReach)
        }
    }

    private func present(_ view: AnyView, center: CGFloat, dockFrame: NSRect, edge: DockEdge, barReach: CGFloat) {
        host.rootView = view
        let size = host.fittingSize
        // Clear of the bar and the name labels that hang beside it.
        let gap = barReach + 34.0
        var origin = switch edge {
        case .bottom:
            NSPoint(x: dockFrame.minX + center - size.width / 2, y: dockFrame.minY + gap)
        case .left:
            NSPoint(x: dockFrame.minX + gap, y: dockFrame.maxY - center - size.height / 2)
        case .right:
            NSPoint(x: dockFrame.maxX - gap - size.width, y: dockFrame.maxY - center - size.height / 2)
        }
        if let screen = clampScreen ?? NSScreen.screens.first {
            let visible = screen.visibleFrame
            origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
            origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - size.height - 8)
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.orderFrontRegardless()
    }
}

/// The strip of thumbnails. Click one to jump to that window; the controls row adds each window's
/// title and a close button.
private struct PreviewStrip: View {
    let thumbs: [WindowThumb]
    let showsControls: Bool
    let raise: (CGWindowID) -> Void
    let close: (CGWindowID) -> Void

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            ForEach(thumbs) { thumb in
                VStack(spacing: 5) {
                    if showsControls {
                        HStack(spacing: 6) {
                            Button {
                                close(thumb.id)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 13))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Close \(thumb.title)")
                            Text(thumb.title)
                                .font(.system(size: 11, weight: .medium))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 0)
                        }
                    }
                    Image(decorative: thumb.image, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 220, maxHeight: 140)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(.primary.opacity(0.15), lineWidth: 0.5))
                }
                .contentShape(Rectangle())
                .onTapGesture { raise(thumb.id) }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(thumb.title)
                .accessibilityAddTraits(.isButton)
            }
        }
        .padding(12)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
        .padding(4)
    }
}

/// Shown instead of thumbnails while Screen Recording is not granted.
private struct PermissionStrip: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Window previews need Screen Recording")
                .font(.system(size: 12, weight: .semibold))
            Text("Grant it to DockIt in System Settings, then relaunch DockIt.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Button("Open System Settings…") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
        .padding(12)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
        .padding(4)
    }
}

/// Same shape as `DockPanel`: never key, so a preview click cannot steal the user's focus — the
/// hosting view's first-mouse acceptance is what makes the click land anyway. Above the dock's own
/// level, as a menu would be.
private final class PreviewPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        canHide = false
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
