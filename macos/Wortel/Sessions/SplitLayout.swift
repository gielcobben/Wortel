import CoreGraphics
import Foundation

/// How the main area is divided: a tree of rows and columns whose leaves are
/// tab rows. One leaf is always the main row (`.main`, the session's own
/// terminal and whatever shares its row); every other leaf is a pane the user
/// split off, with a row of its own (`WorkspaceTabs.panes`).
///
/// A pure value, like `WorkspaceTabs`, so the rules can be tested without a
/// window:
///
/// - A split divides the leaf it is asked about in two, along one axis. Along
///   the axis its parent already runs, the new leaf becomes a sibling; across
///   it, the leaf is replaced by a split of the two. So three panes side by
///   side are one row of three, not a row inside a row, and dragging one
///   divider moves one edge.
/// - Siblings that were all the same size stay the same size when one more
///   joins them: a second split right gives three thirds, not a half and two
///   quarters, which is what every split halving its source comes to. Once a
///   divider has been dragged the sizes are somebody's choice, and then the
///   new leaf only halves the one it was split from.
/// - Removing a leaf gives its room to its siblings, in proportion. A split
///   left with one part is replaced by that part, and a split inside a split
///   of the same axis is folded into it.
/// - `.main` is never removed.
/// - Sizes are weights, not points: a window resize keeps every pane's share.
///   Points only appear in `frames(in:)`, where a pane is never laid out
///   smaller than its minimum while there is room to avoid it.
///
/// Geometry is in a top-left coordinate space (y grows downward), which is
/// what the view that draws it uses: "down" is a larger y.
struct SplitLayout: Equatable, Sendable {
    enum Leaf: Hashable, Sendable {
        case main
        case pane(UUID)
    }

    /// `row`: parts side by side, left to right. `column`: stacked, top down.
    enum Axis: String, Sendable, Codable {
        case row, column

        var crossed: Axis { self == .row ? .column : .row }
    }

    enum Edge: String, Sendable, CaseIterable {
        case left, right, up, down

        /// The axis a split on this edge runs along.
        var axis: Axis { self == .left || self == .right ? .row : .column }
        /// Whether the new part goes before the one it is split from.
        var isLeading: Bool { self == .left || self == .up }
    }

    indirect enum Node: Equatable, Sendable {
        case leaf(Leaf)
        case split(Axis, [Part])
    }

    struct Part: Equatable, Sendable {
        var node: Node
        var weight: Double
    }

    var root: Node = .leaf(.main)

    init(root: Node = .leaf(.main)) {
        self.root = root
    }

    // MARK: - Reading

    /// Every leaf, in reading order: left to right, top down.
    var leaves: [Leaf] { Self.leaves(of: root) }

    /// Whether the main area is more than the main row.
    var isSplit: Bool {
        if case .leaf = root { return false }
        return true
    }

    func contains(_ leaf: Leaf) -> Bool { leaves.contains(leaf) }

    private static func leaves(of node: Node) -> [Leaf] {
        switch node {
        case .leaf(let leaf): return [leaf]
        case .split(_, let parts): return parts.flatMap { leaves(of: $0.node) }
        }
    }

    // MARK: - Changing

    /// Put `new` beside `target`, on `edge` of it, the two sharing the room
    /// `target` had. False, and nothing changes, when `target` isn't in the
    /// tree or `new` already is.
    @discardableResult
    mutating func insert(_ new: Leaf, beside target: Leaf, on edge: Edge) -> Bool {
        guard contains(target), !contains(new) else { return false }
        root = Self.inserting(new, beside: target, on: edge, in: root, parentAxis: nil)
        root = Self.tidied(root)
        return true
    }

    private static func inserting(_ new: Leaf, beside target: Leaf, on edge: Edge,
                                  in node: Node, parentAxis: Axis?) -> Node {
        switch node {
        case .leaf(let leaf):
            guard leaf == target else { return node }
            // Reached only when the parent runs the other way (or there is
            // none): the leaf becomes a split of the two.
            let old = Part(node: node, weight: 0.5)
            let added = Part(node: .leaf(new), weight: 0.5)
            return .split(edge.axis, edge.isLeading ? [added, old] : [old, added])
        case .split(let axis, var parts):
            if axis == edge.axis,
               let index = parts.firstIndex(where: { $0.node == .leaf(target) }) {
                // A sibling. Among equals, one more equal; otherwise the two
                // halve what the one had and nobody else moves.
                let even = unevenness(of: .split(axis, parts.map { Part(node: .leaf(.main), weight: $0.weight) })) < 0.001
                let half = parts[index].weight / 2
                parts[index].weight = half
                parts.insert(Part(node: .leaf(new), weight: half),
                             at: edge.isLeading ? index : index + 1)
                if even {
                    let share = 1 / Double(parts.count)
                    for part in parts.indices { parts[part].weight = share }
                }
                return .split(axis, parts)
            }
            for index in parts.indices {
                parts[index].node = inserting(new, beside: target, on: edge,
                                              in: parts[index].node, parentAxis: axis)
            }
            return .split(axis, parts)
        }
    }

    /// Take a leaf out, its room going to its siblings. Never `.main`. False
    /// when it wasn't there.
    @discardableResult
    mutating func remove(_ leaf: Leaf) -> Bool {
        guard leaf != .main, contains(leaf) else { return false }
        root = Self.tidied(Self.removing(leaf, from: root) ?? .leaf(.main))
        return true
    }

    private static func removing(_ leaf: Leaf, from node: Node) -> Node? {
        switch node {
        case .leaf(let own):
            return own == leaf ? nil : node
        case .split(let axis, let parts):
            let kept = parts.compactMap { part -> Part? in
                removing(leaf, from: part.node).map { Part(node: $0, weight: part.weight) }
            }
            return kept.isEmpty ? nil : .split(axis, kept)
        }
    }

    /// Every part of every split the same size as its siblings.
    mutating func equalize() {
        root = Self.equalized(root)
    }

    private static func equalized(_ node: Node) -> Node {
        guard case .split(let axis, let parts) = node, !parts.isEmpty else { return node }
        let weight = 1 / Double(parts.count)
        return .split(axis, parts.map { Part(node: equalized($0.node), weight: weight) })
    }

    /// Whether any split's parts differ in size: whether `equalize` would
    /// change anything.
    var isEqualized: Bool { Self.unevenness(of: root) < 0.001 }

    /// The furthest any part's weight is from an equal share of its split.
    private static func unevenness(of node: Node) -> Double {
        guard case .split(_, let parts) = node, !parts.isEmpty else { return 0 }
        let total = parts.reduce(0) { $0 + $1.weight }
        let share = 1 / Double(parts.count)
        let own = parts.map { abs((total > 0 ? $0.weight / total : share) - share) }.max() ?? 0
        return max(own, parts.map { unevenness(of: $0.node) }.max() ?? 0)
    }

    /// The same tree with what a file, or a careless edit, could have got
    /// wrong put right: no split of one, no split inside a split of the same
    /// axis, each leaf once, `.main` present, and every split's weights
    /// positive and summing to 1.
    func normalized() -> SplitLayout {
        var seen = Set<Leaf>()
        // Nothing left of it (a split with no parts): the main row alone.
        // Not a main row put beside itself, which is what falling through
        // to the check below would make of it.
        guard var node = Self.deduplicated(root, seen: &seen) else { return SplitLayout() }
        if !seen.contains(.main) {
            node = .split(.row, [Part(node: .leaf(.main), weight: 0.5), Part(node: node, weight: 0.5)])
        }
        return SplitLayout(root: Self.tidied(node))
    }

    private static func deduplicated(_ node: Node, seen: inout Set<Leaf>) -> Node? {
        switch node {
        case .leaf(let leaf):
            return seen.insert(leaf).inserted ? node : nil
        case .split(let axis, let parts):
            var kept: [Part] = []
            for part in parts {
                if let child = deduplicated(part.node, seen: &seen) {
                    kept.append(Part(node: child, weight: part.weight))
                }
            }
            return kept.isEmpty ? nil : .split(axis, kept)
        }
    }

    /// Fold away splits of one and splits nested in their own axis, and bring
    /// the weights of each split back to a sum of 1.
    private static func tidied(_ node: Node) -> Node {
        guard case .split(let axis, let parts) = node else { return node }
        var flat: [Part] = []
        let usable = parts.map { Part(node: tidied($0.node), weight: $0.weight.isFinite && $0.weight > 0 ? $0.weight : 0) }
        let total = usable.reduce(0) { $0 + $1.weight }
        for part in usable {
            // A part with no weight (a damaged file) gets an equal share.
            let weight = total > 0 && part.weight > 0 ? part.weight / total : 1 / Double(usable.count)
            if case .split(let inner, let innerParts) = part.node, inner == axis {
                for innerPart in innerParts {
                    flat.append(Part(node: innerPart.node, weight: innerPart.weight * weight))
                }
            } else {
                flat.append(Part(node: part.node, weight: weight))
            }
        }
        if flat.count == 1 { return flat[0].node }
        let sum = flat.reduce(0) { $0 + $1.weight }
        return .split(axis, flat.map { Part(node: $0.node, weight: sum > 0 ? $0.weight / sum : 1 / Double(flat.count)) })
    }

    // MARK: - Geometry

    /// A divider between two parts of a split. `path` is the way down to the
    /// split from the root (an index into each split's parts on the way), and
    /// `index` the part before the divider.
    struct Divider: Equatable, Sendable {
        var path: [Int]
        var index: Int
        var axis: Axis
        var rect: CGRect
    }

    struct Frames: Equatable, Sendable {
        var leaves: [Leaf: CGRect] = [:]
        var dividers: [Divider] = []
    }

    struct Metrics: Equatable, Sendable {
        /// The room a divider takes between two parts.
        var gap: CGFloat = 1
        /// The least a pane is given while there is room to give it.
        var minimum = CGSize(width: 160, height: 100)
    }

    /// Where every leaf and every divider is, in `bounds`.
    func frames(in bounds: CGRect, metrics: Metrics = Metrics()) -> Frames {
        var frames = Frames()
        Self.lay(root, in: bounds, path: [], metrics: metrics, into: &frames)
        return frames
    }

    private static func lay(_ node: Node, in rect: CGRect, path: [Int], metrics: Metrics,
                            into frames: inout Frames) {
        switch node {
        case .leaf(let leaf):
            frames.leaves[leaf] = rect
        case .split(let axis, let parts):
            let extents = extents(of: parts, axis: axis, in: rect, metrics: metrics)
            var offset = axis == .row ? rect.minX : rect.minY
            for (index, part) in parts.enumerated() {
                let extent = extents[index]
                let child = axis == .row
                    ? CGRect(x: offset, y: rect.minY, width: extent, height: rect.height)
                    : CGRect(x: rect.minX, y: offset, width: rect.width, height: extent)
                lay(part.node, in: child, path: path + [index], metrics: metrics, into: &frames)
                offset += extent
                if index < parts.count - 1 {
                    let divider = axis == .row
                        ? CGRect(x: offset, y: rect.minY, width: metrics.gap, height: rect.height)
                        : CGRect(x: rect.minX, y: offset, width: rect.width, height: metrics.gap)
                    frames.dividers.append(Divider(path: path, index: index, axis: axis, rect: divider))
                    offset += metrics.gap
                }
            }
        }
    }

    /// How long each part is along `axis`: its share by weight, in whole
    /// points, with nobody under their minimum while the others can spare it.
    private static func extents(of parts: [Part], axis: Axis, in rect: CGRect,
                                metrics: Metrics) -> [CGFloat] {
        let total = axis == .row ? rect.width : rect.height
        let available = max(total - metrics.gap * CGFloat(parts.count - 1), 0)
        let minimums = parts.map { part -> CGFloat in
            let size = minimumSize(of: part.node, metrics: metrics)
            return axis == .row ? size.width : size.height
        }
        let weightSum = parts.reduce(0) { $0 + $1.weight }
        var extents = parts.map { available * CGFloat(weightSum > 0 ? $0.weight / weightSum : 1 / Double(parts.count)) }
        if minimums.reduce(0, +) <= available {
            // Raise whoever is under their minimum, and take it from the rest
            // in proportion to what they have to spare.
            var fixed = Set<Int>()
            for _ in parts.indices {
                let under = parts.indices.filter { !fixed.contains($0) && extents[$0] < minimums[$0] }
                guard !under.isEmpty else { break }
                for index in under {
                    extents[index] = minimums[index]
                    fixed.insert(index)
                }
                let free = parts.indices.filter { !fixed.contains($0) }
                let room = available - fixed.reduce(0) { $0 + extents[$1] }
                let freeSum = free.reduce(0) { $0 + extents[$1] }
                for index in free {
                    extents[index] = freeSum > 0 ? room * extents[index] / freeSum : room / CGFloat(free.count)
                }
            }
        }
        // Whole points, so two panes never share half a point and a
        // terminal's cells sit on pixels. Each part is rounded down and the
        // points that leaves over go to the parts that lost the most, one
        // each. Rounding to the nearest and giving the last part the rest
        // took that part a point under its minimum when the others rounded
        // up (three panes in 483pt, the last held at 160: 161, 161, 159).
        var whole = extents.map { ($0 + 0.0001).rounded(.down) }
        var spare = Int((available - whole.reduce(0, +) + 0.0001).rounded(.down))
        let byLoss = parts.indices.sorted {
            let first = extents[$0] - whole[$0], second = extents[$1] - whole[$1]
            return first == second ? $0 < $1 : first > second
        }
        for index in byLoss where spare > 0 {
            whole[index] += 1
            spare -= 1
        }
        // Less than a point can still be over, in bounds that aren't whole
        // themselves: the last part takes it, so the parts fill the room.
        if let last = whole.indices.last {
            whole[last] = max(whole[last] + available - whole.reduce(0, +), 0)
        }
        return whole
    }

    /// The least room a node needs for every leaf in it to have its minimum.
    static func minimumSize(of node: Node, metrics: Metrics) -> CGSize {
        switch node {
        case .leaf:
            return metrics.minimum
        case .split(let axis, let parts):
            let sizes = parts.map { minimumSize(of: $0.node, metrics: metrics) }
            let gaps = metrics.gap * CGFloat(max(parts.count - 1, 0))
            if axis == .row {
                return CGSize(width: sizes.reduce(0) { $0 + $1.width } + gaps,
                              height: sizes.map(\.height).max() ?? 0)
            }
            return CGSize(width: sizes.map(\.width).max() ?? 0,
                          height: sizes.reduce(0) { $0 + $1.height } + gaps)
        }
    }

    /// Move the divider after part `index` of the split at `path` so that it
    /// starts at `position` (a coordinate along the split's axis, in the space
    /// `bounds` is in), no further than either neighbour's minimum allows.
    /// Only the two parts beside the divider change size. False when nothing
    /// moved.
    @discardableResult
    mutating func moveDivider(at path: [Int], index: Int, to position: CGFloat,
                              in bounds: CGRect, metrics: Metrics = Metrics()) -> Bool {
        var changed = false
        root = Self.movingDivider(in: root, rect: bounds, path: path[...], index: index,
                                  position: position, metrics: metrics, changed: &changed)
        return changed
    }

    private static func movingDivider(in node: Node, rect: CGRect, path: ArraySlice<Int>, index: Int,
                                      position: CGFloat, metrics: Metrics, changed: inout Bool) -> Node {
        guard case .split(let axis, var parts) = node else { return node }
        let extents = extents(of: parts, axis: axis, in: rect, metrics: metrics)
        if let step = path.first {
            guard parts.indices.contains(step) else { return node }
            var offset = axis == .row ? rect.minX : rect.minY
            for before in 0..<step { offset += extents[before] + metrics.gap }
            let child = axis == .row
                ? CGRect(x: offset, y: rect.minY, width: extents[step], height: rect.height)
                : CGRect(x: rect.minX, y: offset, width: rect.width, height: extents[step])
            parts[step].node = movingDivider(in: parts[step].node, rect: child, path: path.dropFirst(),
                                             index: index, position: position, metrics: metrics,
                                             changed: &changed)
            return .split(axis, parts)
        }
        guard index >= 0, index + 1 < parts.count else { return node }
        var start = axis == .row ? rect.minX : rect.minY
        for before in 0..<index { start += extents[before] + metrics.gap }
        let both = extents[index] + extents[index + 1]
        let firstMinimum = axis == .row ? minimumSize(of: parts[index].node, metrics: metrics).width
                                        : minimumSize(of: parts[index].node, metrics: metrics).height
        let secondMinimum = axis == .row ? minimumSize(of: parts[index + 1].node, metrics: metrics).width
                                         : minimumSize(of: parts[index + 1].node, metrics: metrics).height
        guard both > 0 else { return node }
        // Too little room for both minimums: the divider may still move, each
        // side keeping at least a sliver, so it is never stuck.
        let low = both >= firstMinimum + secondMinimum ? firstMinimum : min(both, 1)
        let high = both >= firstMinimum + secondMinimum ? both - secondMinimum : max(both - 1, low)
        let first = min(max(position - start, low), high).rounded()
        guard abs(first - extents[index]) >= 0.5 else { return node }
        // The weights are rewritten from the extents on screen, so parts that
        // were being held at their minimum keep the size they are drawn at.
        let available = extents.reduce(0, +)
        guard available > 0 else { return node }
        var updated = extents
        updated[index] = first
        updated[index + 1] = both - first
        for part in parts.indices { parts[part].weight = Double(updated[part] / available) }
        changed = true
        return .split(axis, parts)
    }

    // MARK: - Finding your way

    /// The leaf you get to by going from `leaf` toward `edge`: the one across
    /// that edge that lines up best with `leaf` (most shared edge), the upper
    /// or left one on a tie. nil at the main area's own edge.
    func neighbour(of leaf: Leaf, toward edge: Edge, in bounds: CGRect,
                   metrics: Metrics = Metrics()) -> Leaf? {
        let frames = frames(in: bounds, metrics: metrics).leaves
        guard let own = frames[leaf] else { return nil }
        let slack = metrics.gap + 1
        var best: (leaf: Leaf, shared: CGFloat, start: CGFloat)?
        for candidate in leaves where candidate != leaf {
            guard let other = frames[candidate] else { continue }
            let touches: Bool
            let shared: CGFloat
            let start: CGFloat
            switch edge {
            case .left:
                touches = abs(other.maxX - own.minX) <= slack
                shared = min(own.maxY, other.maxY) - max(own.minY, other.minY)
                start = other.minY
            case .right:
                touches = abs(other.minX - own.maxX) <= slack
                shared = min(own.maxY, other.maxY) - max(own.minY, other.minY)
                start = other.minY
            case .up:
                touches = abs(other.maxY - own.minY) <= slack
                shared = min(own.maxX, other.maxX) - max(own.minX, other.minX)
                start = other.minX
            case .down:
                touches = abs(other.minY - own.maxY) <= slack
                shared = min(own.maxX, other.maxX) - max(own.minX, other.minX)
                start = other.minX
            }
            guard touches, shared > 0 else { continue }
            if let current = best, current.shared > shared
                || (current.shared == shared && current.start <= start) { continue }
            best = (candidate, shared, start)
        }
        return best?.leaf
    }

    // MARK: - Dropping a tab on a pane

    /// What a tab let go at `point` over a pane at `frame` asks for: a split
    /// on the edge it is nearest, within a band along each edge, or nil for
    /// the middle, which means "into this pane". The band is a quarter of the
    /// pane, at least 32pt and at most 160pt, so a small pane still has a
    /// middle and a large one doesn't need a long reach. In a corner, the
    /// edge the point is deeper into wins.
    static func dropEdge(at point: CGPoint, in frame: CGRect) -> Edge? {
        guard frame.contains(point), frame.width > 0, frame.height > 0 else { return nil }
        let bandX = min(max(frame.width / 4, 32), 160, frame.width / 3)
        let bandY = min(max(frame.height / 4, 32), 160, frame.height / 3)
        // How far into each band, 0 at its inner edge and 1 at the pane's.
        let depths: [(Edge, CGFloat)] = [
            (.left, 1 - (point.x - frame.minX) / bandX),
            (.right, 1 - (frame.maxX - point.x) / bandX),
            (.up, 1 - (point.y - frame.minY) / bandY),
            (.down, 1 - (frame.maxY - point.y) / bandY),
        ]
        return depths.filter { $0.1 > 0 }.max { $0.1 < $1.1 }?.0
    }

    /// The half of `frame` a split on `edge` would give the new pane: what a
    /// drag lights up before the drop.
    static func half(of frame: CGRect, on edge: Edge) -> CGRect {
        switch edge {
        case .left: return CGRect(x: frame.minX, y: frame.minY, width: (frame.width / 2).rounded(), height: frame.height)
        case .right:
            let width = (frame.width / 2).rounded()
            return CGRect(x: frame.maxX - width, y: frame.minY, width: width, height: frame.height)
        case .up: return CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: (frame.height / 2).rounded())
        case .down:
            let height = (frame.height / 2).rounded()
            return CGRect(x: frame.minX, y: frame.maxY - height, width: frame.width, height: height)
        }
    }
}

// MARK: - Saving

extension SplitLayout.Leaf {
    init?(rawValue: String) {
        if rawValue == "main" {
            self = .main
        } else if let id = UUID(uuidString: rawValue) {
            self = .pane(id)
        } else {
            return nil
        }
    }

    var rawValue: String {
        switch self {
        case .main: return "main"
        case .pane(let id): return id.uuidString
        }
    }
}

extension SplitLayout.Node: Codable {
    private enum CodingKeys: String, CodingKey { case leaf, axis, parts }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let raw = try container.decodeIfPresent(String.self, forKey: .leaf) {
            guard let leaf = SplitLayout.Leaf(rawValue: raw) else {
                throw DecodingError.dataCorruptedError(forKey: .leaf, in: container,
                                                       debugDescription: "not a leaf: \(raw)")
            }
            self = .leaf(leaf)
        } else {
            self = .split(try container.decode(SplitLayout.Axis.self, forKey: .axis),
                          try container.decode([SplitLayout.Part].self, forKey: .parts))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .leaf(let leaf):
            try container.encode(leaf.rawValue, forKey: .leaf)
        case .split(let axis, let parts):
            try container.encode(axis, forKey: .axis)
            try container.encode(parts, forKey: .parts)
        }
    }
}

extension SplitLayout.Part: Codable {}

extension SplitLayout: Codable {
    init(from decoder: Decoder) throws {
        root = try decoder.singleValueContainer().decode(Node.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(root)
    }
}
