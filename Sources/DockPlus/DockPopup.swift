import AppKit

/// Where a panel hangs off the dock — the window previews and a stack's grid alike: an item's
/// along-axis centre within the strip, and the bar it hangs off.
struct DockAnchor: Equatable {
    let center: CGFloat
    let dockFrame: NSRect
    let edge: DockEdge
    let barReach: CGFloat

    /// A panel of `size` centred on the item and just clear of the (magnified) icons, kept 8pt inside
    /// `visible` — the dock's own screen, so a panel near a corner does not spill onto the next
    /// display. The gap is the preview strip's: its 4pt transparent margin leaves the glass 8pt off
    /// the icons. It covers the item's name label, which the panel makes redundant; clearing the
    /// label as well left a gap taller than a small icon. Pure, for the tests.
    func frame(for size: NSSize, within visible: NSRect?) -> NSRect {
        let gap = barReach + 4.0
        var origin = switch edge {
        case .bottom:
            NSPoint(x: dockFrame.minX + center - size.width / 2, y: dockFrame.minY + gap)
        case .left:
            NSPoint(x: dockFrame.minX + gap, y: dockFrame.maxY - center - size.height / 2)
        case .right:
            NSPoint(x: dockFrame.maxX - gap - size.width, y: dockFrame.maxY - center - size.height / 2)
        }
        if let visible {
            origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
            origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - size.height - 8)
        }
        return NSRect(origin: origin, size: size)
    }
}

/// Same shape as `DockPanel`, above the dock's own level as a menu would be. The previews' panel is
/// never key, so a preview click cannot steal the user's focus — the hosting view's first-mouse
/// acceptance is what makes the click land anyway. A stack's grid may become key, for Escape: being
/// non-activating, it takes the keyboard without bringing DockPlus forward, as Spotlight's panel does.
final class DockPopupPanel: NSPanel {
    private let acceptsKey: Bool

    init(acceptsKey: Bool = false) {
        self.acceptsKey = acceptsKey
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

    override var canBecomeKey: Bool { acceptsKey }
    override var canBecomeMain: Bool { false }
}
