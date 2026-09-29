import CoreGraphics

/// How much an icon grows when the pointer is `distance` points from its centre, as a fraction:
/// 0 is the resting size, 1 is the full magnified size. `DockLayout` clamps the result to 0...1
/// and calls this once per icon per frame (60 times a second while hovering), so keep it cheap.
///
/// `iconSize` is the resting size in points — scale the reach by it, so the same number of
/// neighbours swell whether the dock is set small or large.
func magnificationFalloff(distance: CGFloat, iconSize: CGFloat, reachIcons: CGFloat = 2.0) -> CGFloat {
    // A raised cosine: flat at the peak, so the icon under the pointer does not twitch as the pointer
    // crosses it, and flat again where it reaches zero, so the outermost neighbours ease in rather
    // than starting to grow with a visible kink. Linear has a kink at both; a Gaussian never quite
    // reaches zero, so every icon on the bar would shimmer.
    // Defaults to two icon widths, matched to DockFix (measured 2026-09-28: the hovered icon's
    // direct neighbour swells about 1.2x and the next one out not at all). The Reach setting scales it.
    let reach = iconSize * max(reachIcons, 0.5)
    guard distance < reach else { return 0 }
    return (1 + cos(.pi * distance / reach)) / 2
}
