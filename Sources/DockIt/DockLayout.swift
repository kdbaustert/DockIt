import CoreGraphics

/// Fixed proportions of the bar. "Along" is the axis the icons run on; "thickness" is across it.
struct DockMetrics: Equatable {
    var iconSize: CGFloat = 48
    var magnifiedSize: CGFloat = 48
    var spacing: CGFloat = 4
    var padding: CGFloat = 6
    var separatorExtent: CGFloat = 13

    var thickness: CGFloat { iconSize + 2 * padding }
}

/// Where the bar and each item sit along the edge, for one pointer position. Pure geometry, so the
/// view, the panel's hit-testing and the tests all agree on it.
struct DockLayout: Equatable {
    /// Along-axis extent of each item.
    let sizes: [CGFloat]
    /// Bar start along the strip (the panel's full edge), padding included.
    let start: CGFloat
    /// Bar length, padding included.
    let length: CGFloat
    let metrics: DockMetrics

    /// - Parameters:
    ///   - magnifies: one entry per item; `false` for separators, which never grow.
    ///   - pointer: along-axis pointer position within the strip, or nil when not hovering.
    ///   - falloff: growth for a pointer `distance` from an icon's centre, 0...1.
    init(
        magnifies: [Bool],
        metrics m: DockMetrics,
        stripLength: CGFloat,
        pointer: CGFloat?,
        falloff: (_ distance: CGFloat, _ iconSize: CGFloat) -> CGFloat
    ) {
        metrics = m
        let resting = magnifies.map { $0 ? m.iconSize : m.separatorExtent }
        let restingLength = Self.length(of: resting, metrics: m)
        let restingStart = (stripLength - restingLength) / 2

        guard let pointer, m.magnifiedSize > m.iconSize else {
            sizes = resting
            start = restingStart
            length = restingLength
            return
        }

        // Distances are measured on the resting row, not the magnified one: measuring on the row
        // being produced would feed each frame's growth back into the next.
        var grown = resting
        var cursor = restingStart + m.padding
        for index in resting.indices {
            let centre = cursor + resting[index] / 2
            cursor += resting[index] + m.spacing
            guard magnifies[index] else { continue }
            let growth = min(max(falloff(abs(pointer - centre), m.iconSize), 0), 1)
            grown[index] = m.iconSize + (m.magnifiedSize - m.iconSize) * growth
        }
        sizes = grown
        length = Self.length(of: grown, metrics: m)

        // Keep whatever is under the pointer under it. Centring the grown row instead makes the
        // icons slide away from the pointer toward the bar's ends, so the one you are aiming for
        // runs off. Walk the row as segments (padding, item + gap, ..., padding), find the one the
        // pointer is in at rest, and put the same fraction of its grown segment under the pointer.
        // The grown row reaches past the resting one, so the pointer can be over the bar yet outside
        // every resting segment; held to the row's end (a hair inside, so it lands in the last
        // segment) it keeps the end anchored instead of the row jumping to the centre.
        let held = min(max(pointer, restingStart), restingStart + restingLength - 0.001)
        let restingSegments = Self.segments(resting, metrics: m)
        let grownSegments = Self.segments(grown, metrics: m)
        var restingCursor = restingStart
        var grownOffset: CGFloat?
        var grownCursor: CGFloat = 0
        for (rest, grow) in zip(restingSegments, grownSegments) {
            if rest > 0, held >= restingCursor, held < restingCursor + rest {
                grownOffset = grownCursor + (held - restingCursor) / rest * grow
                break
            }
            restingCursor += rest
            grownCursor += grow
        }
        let anchored = grownOffset.map { held - $0 } ?? (stripLength - length) / 2
        start = length <= stripLength ? min(max(anchored, 0), stripLength - length) : anchored
    }

    /// The along-axis centre of an item — where a preview panel anchors.
    func center(of index: Int) -> CGFloat {
        var cursor = start + metrics.padding
        for (i, size) in sizes.enumerated() {
            if i == index { return cursor + size / 2 }
            cursor += size + metrics.spacing
        }
        return cursor
    }

    /// The item whose extent, plus half the gap on either side, contains `along`.
    func index(at along: CGFloat) -> Int? {
        var cursor = start + metrics.padding
        for (index, size) in sizes.enumerated() {
            if along >= cursor - metrics.spacing / 2, along < cursor + size + metrics.spacing / 2 {
                return index
            }
            cursor += size + metrics.spacing
        }
        return nil
    }

    private static func length(of sizes: [CGFloat], metrics m: DockMetrics) -> CGFloat {
        sizes.reduce(0, +) + m.spacing * CGFloat(max(sizes.count - 1, 0)) + 2 * m.padding
    }

    private static func segments(_ sizes: [CGFloat], metrics m: DockMetrics) -> [CGFloat] {
        let items = sizes.enumerated().map { $0.offset < sizes.count - 1 ? $0.element + m.spacing : $0.element }
        return [m.padding] + items + [m.padding]
    }
}
