import Foundation

/// Identity of a drawable wedge, stable across layouts so transitions can match segments.
public enum SegmentKey: Hashable, Sendable {
    case node(NodeRef)
    /// The merged "smaller objects…" wedge of a directory.
    case smaller(NodeRef)
    /// Used space the scan couldn't account for (volume root only).
    case hidden
}

public struct SunburstSegment: Sendable {
    public enum Kind: Sendable { case directory, file, smallerObjects, hiddenSpace }

    public let key: SegmentKey
    public let kind: Kind
    /// Ring index, 1 = innermost ring around the center disc.
    public let depth: Int
    /// Angles in radians from the start of the sweep (clockwise from 9 o'clock when drawn).
    public let start: Double
    public let end: Double
    /// 0..<1 — position of the segment's midpoint within the whole scan. Drives the color wheel,
    /// so an item keeps its color at every zoom level.
    public let hue: Double
    public let size: UInt64
    /// Number of items merged into a "smaller objects" wedge.
    public let mergedCount: Int
    /// For "smaller objects": the first merged child (the rest follow it in size order). Pass it as
    /// `Options.subsetStart` to expand the wedge into its individual items.
    public var firstMerged: NodeRef? = nil

    public var node: NodeRef? {
        if case .node(let ref) = key { return ref }
        return nil
    }

    public var span: Double { end - start }
}

/// Angular layout of a file tree around a focused directory, DaisyDisk style:
/// children sorted by size clockwise, tiny siblings merged into "smaller objects",
/// and at the volume root the chart only spans used / capacity of the circle.
public struct SunburstLayout: Sendable {
    public struct Options: Sendable {
        public var maxDepth: Int
        /// Items spanning less than this (radians) are merged into "smaller objects" when there are two or more.
        public var minAngle: Double
        /// Unaccounted used space, drawn as a "hidden space" wedge at the volume root.
        public var hiddenBytes: UInt64
        /// Fraction of the full circle the volume root spans (used / capacity). Ignored below the root.
        public var rootSweepFraction: Double
        /// Show only the focus' children from this one onward (an expanded "smaller objects" wedge).
        public var subsetStart: NodeRef?
        /// Slice of the color wheel (0…1) spread over the laid-out content. nil: the focus' own slice of the global
        /// wheel (so an item has the same color at every zoom level).
        public var hueRange: ClosedRange<Double>?

        public init(maxDepth: Int = 9, minAngle: Double = .pi / 180, hiddenBytes: UInt64 = 0, rootSweepFraction: Double = 1,
                    subsetStart: NodeRef? = nil, hueRange: ClosedRange<Double>? = nil) {
            self.maxDepth = maxDepth
            self.minAngle = minAngle
            self.hiddenBytes = hiddenBytes
            self.rootSweepFraction = rootSweepFraction
            self.subsetStart = subsetStart
            self.hueRange = hueRange
        }
    }

    public let focus: NodeRef
    /// Set when the layout shows only part of the focus' children (expanded "smaller objects").
    public let subsetStart: NodeRef?
    /// Bytes of the focus' children that come before `subsetStart` (excluded from this layout).
    public let skippedBytes: UInt64
    /// Total angle covered by the chart.
    public let sweep: Double
    /// Bytes represented by `sweep`.
    public let totalBytes: UInt64
    /// `rings[d - 1]` holds depth-d segments ordered by angle.
    public let rings: [[SunburstSegment]]
    private let lookup: [SegmentKey: SunburstSegment]

    public init(tree: FileTree, focus: NodeRef, options: Options = Options()) {
        self.focus = focus
        let subset = options.subsetStart.flatMap { start in tree.parent(start) == focus ? start : nil }
        subsetStart = subset
        var skipped: UInt64 = 0
        if let subset {
            for child in tree.sortedChildren(focus) {
                if child == subset { break }
                if !tree.flags(child).contains(.removed) { skipped += tree.size(child) }
            }
        }
        skippedBytes = skipped
        let isRoot = focus == tree.root && subset == nil
        let hidden = isRoot ? options.hiddenBytes : 0
        let focusSize = tree.size(focus) - skipped
        let total = focusSize + hidden
        let sweep = isRoot ? 2 * .pi * min(1, max(0, options.rootSweepFraction)) : 2 * .pi
        self.sweep = sweep
        totalBytes = total

        var rings = Array(repeating: [SunburstSegment](), count: options.maxDepth)
        let hueRange: ClosedRange<Double>
        if let explicit = options.hueRange {
            hueRange = explicit
        } else {
            let fullHue = Self.hueRange(tree: tree, node: focus, hiddenBytes: options.hiddenBytes)
            let denominator = Double(max(1, tree.size(tree.root) + options.hiddenBytes))
            hueRange = (fullHue.lowerBound + Double(skipped) / denominator)...fullHue.upperBound
        }
        if total > 0 {
            let focusSweep = sweep * Double(focusSize) / Double(total)
            Self.layoutChildren(of: focus, tree: tree, start: 0, end: focusSweep,
                                hueStart: hueRange.lowerBound, hueEnd: hueRange.upperBound,
                                depth: 1, options: options, subsetStart: subset, parentSize: focusSize, into: &rings)
            if hidden > 0 {
                rings[0].append(SunburstSegment(
                    key: .hidden, kind: .hiddenSpace, depth: 1, start: focusSweep, end: sweep,
                    hue: 0.8, size: hidden, mergedCount: 0))
            }
        }
        while let last = rings.last, last.isEmpty { rings.removeLast() }
        self.rings = rings
        var lookup: [SegmentKey: SunburstSegment] = [:]
        for ring in rings { for segment in ring { lookup[segment.key] = segment } }
        self.lookup = lookup
    }

    public var topLevel: [SunburstSegment] { rings.first ?? [] }
    public var maxDepth: Int { rings.count }

    public func segment(for key: SegmentKey) -> SunburstSegment? { lookup[key] }

    /// Segment at ring `depth` covering `angle` (radians from sweep start).
    public func hitTest(depth: Int, angle: Double) -> SunburstSegment? {
        guard depth >= 1, depth <= rings.count, angle >= 0, angle < sweep else { return nil }
        let ring = rings[depth - 1]
        var lo = 0, hi = ring.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if ring[mid].end <= angle { lo = mid + 1 } else if ring[mid].start > angle { hi = mid - 1 } else { return ring[mid] }
        }
        return nil
    }

    // MARK: - Construction

    private static func layoutChildren(of parent: NodeRef, tree: FileTree, start: Double, end: Double,
                                       hueStart: Double, hueEnd: Double, depth: Int,
                                       options: Options, subsetStart: NodeRef? = nil, parentSize: UInt64? = nil,
                                       into rings: inout [[SunburstSegment]]) {
        let parentSize = parentSize ?? tree.size(parent)
        guard depth <= options.maxDepth, parentSize > 0, end > start else { return }
        let anglePerByte = (end - start) / Double(parentSize)
        let huePerByte = (hueEnd - hueStart) / Double(parentSize)

        var all = tree.sortedChildren(parent)[...]
        if let subsetStart, let index = all.firstIndex(of: subsetStart) { all = all[index...] }
        let children = all.filter {
            !tree.flags($0).contains(.removed) && tree.size($0) > 0
        }
        // Children are sorted by size, so the small ones form a contiguous tail.
        let firstSmall = children.firstIndex { Double(tree.size($0)) * anglePerByte < options.minAngle } ?? children.endIndex
        let smallCount = children.endIndex - firstSmall
        let visible = smallCount >= 2 ? children[..<firstSmall] : children[...]

        var angle = start
        var hue = hueStart
        for child in visible {
            let size = tree.size(child)
            let span = Double(size) * anglePerByte
            let hueSpan = Double(size) * huePerByte
            let isDirectory = tree.isDirectory(child)
            rings[depth - 1].append(SunburstSegment(
                key: .node(child), kind: isDirectory ? .directory : .file, depth: depth,
                start: angle, end: angle + span, hue: hue + hueSpan / 2, size: size, mergedCount: 0))
            if isDirectory && span >= options.minAngle {
                layoutChildren(of: child, tree: tree, start: angle, end: angle + span,
                               hueStart: hue, hueEnd: hue + hueSpan, depth: depth + 1,
                               options: options, into: &rings)
            }
            angle += span
            hue += hueSpan
        }
        if smallCount >= 2 {
            let size = children[firstSmall...].reduce(UInt64(0)) { $0 + tree.size($1) }
            rings[depth - 1].append(SunburstSegment(
                key: .smaller(parent), kind: .smallerObjects, depth: depth,
                start: angle, end: end, hue: (hue + hueEnd) / 2, size: size, mergedCount: smallCount,
                firstMerged: children[firstSmall]))
        }
    }

    /// The slice of the global color wheel owned by `node`: its byte offset within the root scan.
    public static func hueRange(tree: FileTree, node: NodeRef, hiddenBytes: UInt64) -> ClosedRange<Double> {
        let denominator = Double(max(1, tree.size(tree.root) + hiddenBytes))
        var offset: UInt64 = 0
        let chain = tree.ancestry(node)
        for (parent, child) in zip(chain, chain.dropFirst()) {
            for sibling in tree.sortedChildren(parent) {
                if sibling == child { break }
                if !tree.flags(sibling).contains(.removed) { offset += tree.size(sibling) }
            }
        }
        let lower = Double(offset) / denominator
        return lower...(lower + Double(tree.size(node)) / denominator)
    }

    // MARK: - Geometry of arbitrary descendants (for zoom transitions)

    /// Angular range of `node` in this layout's coordinates, computed from sizes — works even when the
    /// node itself isn't drawn (too deep or merged). Returns nil if `node` is not `focus` or below it.
    public func angleRange(of node: NodeRef, in tree: FileTree) -> ClosedRange<Double>? {
        let chain = tree.ancestry(node)
        guard let focusIndex = chain.firstIndex(of: focus) else { return nil }
        let focusSize = tree.size(focus) - skippedBytes
        guard focusSize > 0 else { return 0...0 }
        var lower = 0.0
        var width = sweep * Double(focusSize) / Double(max(1, totalBytes))
        var parentSize = Double(focusSize)
        for (parent, child) in zip(chain[focusIndex...], chain[(focusIndex + 1)...]) {
            var offset: UInt64 = 0
            for sibling in tree.sortedChildren(parent) {
                if sibling == child { break }
                if !tree.flags(sibling).contains(.removed) { offset += tree.size(sibling) }
            }
            if parent == focus {
                // In a subset layout, children before the subset aren't drawn; nodes outside it have no range.
                guard offset >= skippedBytes else { return nil }
                offset -= skippedBytes
            }
            let scale = width / max(1, parentSize)
            lower += Double(offset) * scale
            width = Double(tree.size(child)) * scale
            parentSize = Double(tree.size(child))
        }
        return lower...(lower + width)
    }

    /// Depth of `node` below `focus` (0 for the focus itself), or nil if it isn't a descendant.
    public func relativeDepth(of node: NodeRef, in tree: FileTree) -> Int? {
        let chain = tree.ancestry(node)
        guard let index = chain.firstIndex(of: focus) else { return nil }
        return chain.count - 1 - index
    }
}
