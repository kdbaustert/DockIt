import CoreGraphics
import Observation

/// One screen's dock state. The model's items are shared by every dock; where the pointer sits, how
/// long the strip is and whether the bar is hidden belong to each screen's own panel — with one dock
/// per display, a hover on one screen must not magnify the others.
@MainActor
@Observable
final class PanelState {
    /// Along-axis pointer position within this panel's strip, while it is over (or approaching) the bar.
    var pointer: CGFloat?
    /// Whether the pointer is on the bar itself, as against approaching it with `pointer` set only
    /// to ease the magnification in. The hover highlight and name label follow this, not `pointer`.
    var isOverBar = false
    var stripLength: CGFloat = 0
    var isHidden = false
    /// Scales the magnification growth, 0...1. Stays 1 except while "magnify as the pointer
    /// approaches" is easing the bar up before the pointer has reached it.
    var gain: CGFloat = 1
    /// The last layout and what it was built from; see `DockModel.layout(for:)`.
    @ObservationIgnored var layoutCache: (key: DockModel.LayoutKey, layout: DockLayout)?
}
