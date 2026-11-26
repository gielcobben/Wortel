import CoreGraphics
import Foundation

/// How a session's area is divided: a tree of rows and columns whose leaves
/// are tab rows. One leaf is always the main row (`.main`, the session's own
/// terminal and whatever shares its row). The side column (`.side`) and the
/// strip (`.bottom`) are leaves while they have tabs, and every other leaf
/// is a pane the user split off, with a row of its own
/// (`WorkspaceTabs.panes`).
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
/// - A leaf can be hidden (`hidden`, handed to everything that measures):
///   it takes no room and has no divider, and what is beside it shares its
///   room. Its weight stays what it was, so shown again it has the share it
///   had. Hiding is not this value's to remember: `WorkspaceTabs` says which
///   leaves are.
/// - The column and the strip come with a size of their own, so "the same
///   size as its siblings" is about the others: one more split among equals
///   leaves those two what they had, so does `equalize`, and a leaf removed
///   beside one of them gives its room to the others.
///
/// Geometry is in a top-left coordinate space (y grows downward), which is
/// what the view that draws it uses: "down" is a larger y.
struct SplitLayout: Equatable, Sendable {
    enum Leaf: Hashable, Sendable {
        case main
        /// The side column, while it has tabs.
        case side
        /// The strip, while it has tabs.
        case bottom
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

    /// Whether there is more than the main row: any other leaf at all, the
    /// column and the strip among them, shown or hidden.
    var isSplit: Bool {
        if case .leaf = root { return false }
        return true
    }

    /// Whether any leaf is a pane somebody split off: more than the main
    /// row, the column and the strip.
    var hasPanes: Bool {
        leaves.contains { if case .pane = $0 { return true } else { return false } }
    }

    func contains(_ leaf: Leaf) -> Bool { Self.contains(leaf, in: root) }

    private static func contains(_ leaf: Leaf, in node: Node) -> Bool {
        switch node {
        case .leaf(let own): return own == leaf
        case .split(_, let parts): return parts.contains { contains(leaf, in: $0.node) }
        }
    }

    /// How much of the whole `leaf` has along `axis`, by weight: its part of
    /// every split on the way down that runs that way. Gaps, minimums and
    /// hidden leaves are left out of it. nil when it isn't in the tree.
    func share(of leaf: Leaf, along axis: Axis) -> Double? {
        Self.share(of: leaf, along: axis, in: root)
    }

    private static func share(of leaf: Leaf, along axis: Axis, in node: Node) -> Double? {
        switch node {
        case .leaf(let own):
            return own == leaf ? 1 : nil
        case .split(let own, let parts):
            let total = parts.reduce(0) { $0 + $1.weight }
            for part in parts {
                guard let inner = share(of: leaf, along: axis, in: part.node) else { continue }
                return own == axis && total > 0 ? inner * part.weight / total : inner
            }
            return nil
        }
    }

    /// The way down to `leaf`: an index into each split's parts. Empty when
    /// the leaf is the root, nil when it isn't in the tree.
    private static func path(to leaf: Leaf, in node: Node) -> [Int]? {
        switch node {
        case .leaf(let own):
            return own == leaf ? [] : nil
        case .split(_, let parts):
            for (index, part) in parts.enumerated() {
                if let rest = path(to: leaf, in: part.node) { return [index] + rest }
            }
            return nil
        }
    }

    /// The column and the strip: a part that is one of them keeps the share
    /// it has when its siblings are made equal.
    private static func keepsItsShare(_ node: Node) -> Bool {
        node == .leaf(.side) || node == .leaf(.bottom)
    }

    /// Whether `weights` are all the same share of their sum.
    private static func isEven(_ weights: [Double]) -> Bool {
        let total = weights.reduce(0, +)
        guard total > 0 else { return true }
        let share = 1 / Double(weights.count)
        return weights.allSatisfy { abs($0 / total - share) < 0.001 }
    }

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
        root = Self.tidied(Self.inserting(new, beside: target, on: edge, share: nil, in: root))
        return true
    }

    /// The same, with `new` taking exactly `share` of the room `target` had
    /// (0…1, held to 0.05…0.95) and nobody else moving: the rule that keeps
    /// equal siblings equal is not applied.
    @discardableResult
    mutating func insert(_ new: Leaf, beside target: Leaf, on edge: Edge, share: Double) -> Bool {
        guard contains(target), !contains(new) else { return false }
        root = Self.tidied(Self.inserting(new, beside: target, on: edge, share: Self.held(share), in: root))
        return true
    }

    /// Put `new` at the outer edge of the whole tree, taking `share` of the
    /// whole along that edge's axis (0…1, held to 0.05…0.95), everything
    /// else scaled to the rest. A root that already runs that way gets one
    /// more part, at its start or its end; any other root becomes a split of
    /// itself and the new leaf. False, and nothing changes, when `new` is
    /// already in the tree.
    @discardableResult
    mutating func insert(_ new: Leaf, atRootEdge edge: Edge, share: Double) -> Bool {
        guard !contains(new) else { return false }
        let share = Self.held(share)
        let added = Part(node: .leaf(new), weight: share)
        if case .split(let axis, let parts) = root, axis == edge.axis, !parts.isEmpty {
            let total = parts.reduce(0) { $0 + $1.weight }
            let rest = parts.map { part in
                Part(node: part.node,
                     weight: (total > 0 ? part.weight / total : 1 / Double(parts.count)) * (1 - share))
            }
            root = .split(axis, edge.isLeading ? [added] + rest : rest + [added])
        } else {
            let old = Part(node: root, weight: 1 - share)
            root = .split(edge.axis, edge.isLeading ? [added, old] : [old, added])
        }
        root = Self.tidied(root)
        return true
    }

    /// A share somebody asked for, as one that leaves both sides something.
    private static func held(_ share: Double) -> Double {
        share.isFinite ? min(max(share, 0.05), 0.95) : 0.5
    }

    /// `share` nil is a split somebody made: half of the target, or an equal
    /// share among equals.
    private static func inserting(_ new: Leaf, beside target: Leaf, on edge: Edge, share: Double?,
                                  in node: Node) -> Node {
        switch node {
        case .leaf(let leaf):
            guard leaf == target else { return node }
            // Reached only when the parent runs the other way (or there is
            // none): the leaf becomes a split of the two.
            let taken = share ?? 0.5
            let old = Part(node: node, weight: 1 - taken)
            let added = Part(node: .leaf(new), weight: taken)
            return .split(edge.axis, edge.isLeading ? [added, old] : [old, added])
        case .split(let axis, var parts):
            if axis == edge.axis,
               let index = parts.firstIndex(where: { $0.node == .leaf(target) }) {
                // A sibling. Among equals, one more equal; otherwise the two
                // divide what the one had and nobody else moves. The column
                // and the strip are not among the equals: they keep the
                // share they have, or a second split beside a column would
                // be a quarter where it is a third without one.
                let peers = parts.filter { !keepsItsShare($0.node) }
                let even = share == nil && !keepsItsShare(.leaf(new)) && !keepsItsShare(parts[index].node)
                    && isEven(peers.map(\.weight))
                let room = peers.reduce(0) { $0 + $1.weight }
                let taken = parts[index].weight * (share ?? 0.5)
                parts[index].weight -= taken
                parts.insert(Part(node: .leaf(new), weight: taken),
                             at: edge.isLeading ? index : index + 1)
                if even {
                    let each = room / Double(peers.count + 1)
                    for part in parts.indices where !keepsItsShare(parts[part].node) {
                        parts[part].weight = each
                    }
                }
                return .split(axis, parts)
            }
            for index in parts.indices {
                parts[index].node = inserting(new, beside: target, on: edge, share: share,
                                              in: parts[index].node)
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
            var kept = parts.compactMap { part -> Part? in
                removing(leaf, from: part.node).map { Part(node: $0, weight: part.weight) }
            }
            guard !kept.isEmpty else { return nil }
            // The room it leaves goes to the siblings that share room among
            // themselves, as it came from them when it was made: a pane
            // closed beside the column leaves the column the share it had.
            // With only the column or the strip left beside it, to those.
            let freed = parts.reduce(0) { $0 + $1.weight } - kept.reduce(0) { $0 + $1.weight }
            let sharing = kept.indices.filter { !keepsItsShare(kept[$0].node) }
            let had = sharing.reduce(0) { $0 + kept[$1].weight }
            if freed > 0, had > 0, sharing.count < kept.count {
                for index in sharing { kept[index].weight *= (had + freed) / had }
            }
            return .split(axis, kept)
        }
    }

    /// Every part of every split the same size as its siblings. The column
    /// and the strip keep the share they have: it is the others that share
    /// the rest equally.
    mutating func equalize() {
        root = Self.equalized(root)
    }

    private static func equalized(_ node: Node) -> Node {
        guard case .split(let axis, let parts) = node, !parts.isEmpty else { return node }
        let peers = parts.filter { !keepsItsShare($0.node) }
        guard peers.count < parts.count else {
            let weight = 1 / Double(parts.count)
            return .split(axis, parts.map { Part(node: equalized($0.node), weight: weight) })
        }
        let each = peers.isEmpty ? 0 : peers.reduce(0) { $0 + $1.weight } / Double(peers.count)
        return .split(axis, parts.map { part in
            Part(node: equalized(part.node), weight: keepsItsShare(part.node) ? part.weight : each)
        })
    }

    /// Whether any split's parts differ in size: whether `equalize` would
    /// change anything.
    var isEqualized: Bool { Self.unevenness(of: root) < 0.001 }

    /// The furthest any part's weight is from an equal share of its split,
    /// the column and the strip left out as `equalize` leaves them.
    private static func unevenness(of node: Node) -> Double {
        guard case .split(_, let parts) = node, !parts.isEmpty else { return 0 }
        let peers = parts.filter { !keepsItsShare($0.node) }
        let total = peers.reduce(0) { $0 + $1.weight }
        let share = 1 / Double(max(peers.count, 1))
        let own = peers.map { abs((total > 0 ? $0.weight / total : share) - share) }.max() ?? 0
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

    /// Where every leaf and every divider is, in `bounds`. A leaf in
    /// `hidden` has no frame, and neither has a divider beside a part with
    /// nothing in it to show: what is on screen shares the room, in
    /// proportion. With nothing to show at all there are no frames.
    func frames(in bounds: CGRect, metrics: Metrics = Metrics(), hidden: Set<Leaf> = []) -> Frames {
        var frames = Frames()
        Self.lay(root, in: bounds, path: [], metrics: metrics, hidden: hidden, into: &frames)
        return frames
    }

    /// Whether anything in `node` is on screen.
    private static func isShown(_ node: Node, hidden: Set<Leaf>) -> Bool {
        if hidden.isEmpty { return true }
        switch node {
        case .leaf(let leaf): return !hidden.contains(leaf)
        case .split(_, let parts): return parts.contains { isShown($0.node, hidden: hidden) }
        }
    }

    /// The parts of a split that are on screen, by their place in it.
    private static func shown(_ parts: [Part], hidden: Set<Leaf>) -> [Int] {
        hidden.isEmpty ? Array(parts.indices) : parts.indices.filter { isShown(parts[$0].node, hidden: hidden) }
    }

    private static func lay(_ node: Node, in rect: CGRect, path: [Int], metrics: Metrics,
                            hidden: Set<Leaf>, into frames: inout Frames) {
        switch node {
        case .leaf(let leaf):
            if !hidden.contains(leaf) { frames.leaves[leaf] = rect }
        case .split(let axis, let parts):
            let shown = shown(parts, hidden: hidden)
            guard !shown.isEmpty else { return }
            let extents = extents(of: shown.map { parts[$0] }, axis: axis, in: rect,
                                  metrics: metrics, hidden: hidden)
            var offset = axis == .row ? rect.minX : rect.minY
            for (place, index) in shown.enumerated() {
                let extent = extents[place]
                let child = axis == .row
                    ? CGRect(x: offset, y: rect.minY, width: extent, height: rect.height)
                    : CGRect(x: rect.minX, y: offset, width: rect.width, height: extent)
                lay(parts[index].node, in: child, path: path + [index], metrics: metrics,
                    hidden: hidden, into: &frames)
                offset += extent
                if place < shown.count - 1 {
                    let divider = axis == .row
                        ? CGRect(x: offset, y: rect.minY, width: metrics.gap, height: rect.height)
                        : CGRect(x: rect.minX, y: offset, width: rect.width, height: metrics.gap)
                    // Named for the part before it. The part after it is the
                    // next one on screen, which need not be the next one.
                    frames.dividers.append(Divider(path: path, index: index, axis: axis, rect: divider))
                    offset += metrics.gap
                }
            }
        }
    }

    /// How long each part is along `axis`: its share by weight, in whole
    /// points, with nobody under their minimum while the others can spare it.
    /// `parts` are the ones on screen; `hidden` is for what is inside them.
    private static func extents(of parts: [Part], axis: Axis, in rect: CGRect,
                                metrics: Metrics, hidden: Set<Leaf>) -> [CGFloat] {
        let total = axis == .row ? rect.width : rect.height
        let available = max(total - metrics.gap * CGFloat(parts.count - 1), 0)
        let minimums = parts.map { length(of: minimumSize(of: $0.node, metrics: metrics, hidden: hidden), along: axis) }
        let weightSum = parts.reduce(0) { $0 + $1.weight }
        var extents = parts.map { available * CGFloat(weightSum > 0 ? $0.weight / weightSum : 1 / Double(parts.count)) }
        if minimums.reduce(0, +) <= available {
            raise(&extents, to: minimums, within: available, holding: [])
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

    /// Raise whoever is under their minimum, and take it from the rest in
    /// proportion to what they have. `held` are parts that keep the extent
    /// they were given, whatever the others need.
    private static func raise(_ extents: inout [CGFloat], to minimums: [CGFloat], within available: CGFloat,
                              holding held: Set<Int>) {
        var fixed = held
        for _ in extents.indices {
            let under = extents.indices.filter { !fixed.contains($0) && extents[$0] < minimums[$0] }
            guard !under.isEmpty else { break }
            for index in under {
                extents[index] = minimums[index]
                fixed.insert(index)
            }
            let free = extents.indices.filter { !fixed.contains($0) }
            let room = available - fixed.reduce(0) { $0 + extents[$1] }
            let freeSum = free.reduce(0) { $0 + extents[$1] }
            for index in free {
                extents[index] = freeSum > 0 ? room * extents[index] / freeSum : room / CGFloat(free.count)
            }
        }
    }

    private static func length(of size: CGSize, along axis: Axis) -> CGFloat {
        axis == .row ? size.width : size.height
    }

    /// The least room a node needs for every leaf in it that is on screen to
    /// have its minimum. Nothing, for one with nothing on screen.
    static func minimumSize(of node: Node, metrics: Metrics, hidden: Set<Leaf> = []) -> CGSize {
        switch node {
        case .leaf(let leaf):
            return hidden.contains(leaf) ? .zero : metrics.minimum
        case .split(let axis, let parts):
            let sizes = shown(parts, hidden: hidden).map { minimumSize(of: parts[$0].node, metrics: metrics, hidden: hidden) }
            let gaps = metrics.gap * CGFloat(max(sizes.count - 1, 0))
            if axis == .row {
                return CGSize(width: sizes.reduce(0) { $0 + $1.width } + gaps,
                              height: sizes.map(\.height).max() ?? 0)
            }
            return CGSize(width: sizes.map(\.width).max() ?? 0,
                          height: sizes.reduce(0) { $0 + $1.height } + gaps)
        }
    }

    /// Change the split at `path`, handed its parts and the room it is laid
    /// out in. Nothing is changed when the path leads nowhere, or through a
    /// part that isn't on screen.
    private static func editing(_ node: Node, at path: ArraySlice<Int>, rect: CGRect, metrics: Metrics,
                                hidden: Set<Leaf>, _ body: (Axis, inout [Part], CGRect) -> Void) -> Node {
        guard case .split(let axis, var parts) = node else { return node }
        guard let step = path.first else {
            body(axis, &parts, rect)
            return .split(axis, parts)
        }
        let shown = shown(parts, hidden: hidden)
        guard let place = shown.firstIndex(of: step) else { return node }
        let extents = extents(of: shown.map { parts[$0] }, axis: axis, in: rect, metrics: metrics, hidden: hidden)
        var offset = axis == .row ? rect.minX : rect.minY
        for before in 0..<place { offset += extents[before] + metrics.gap }
        let child = axis == .row
            ? CGRect(x: offset, y: rect.minY, width: extents[place], height: rect.height)
            : CGRect(x: rect.minX, y: offset, width: rect.width, height: extents[place])
        parts[step].node = editing(parts[step].node, at: path.dropFirst(), rect: child, metrics: metrics,
                                   hidden: hidden, body)
        return .split(axis, parts)
    }

    /// The weights of the parts on screen (`shown`, with their `extents`)
    /// rewritten from those extents, within the weight they had between
    /// them. So parts that were being held at their minimum keep the size
    /// they are drawn at, and a hidden part keeps the share it had.
    private static func setWeights(of parts: inout [Part], shown: [Int], from extents: [CGFloat]) -> Bool {
        let available = extents.reduce(0, +)
        let weight = shown.reduce(0) { $0 + parts[$1].weight }
        guard available > 0, weight > 0 else { return false }
        for (place, index) in shown.enumerated() {
            parts[index].weight = weight * Double(extents[place] / available)
        }
        return true
    }

    /// Move the divider after part `index` of the split at `path` so that it
    /// starts at `position` (a coordinate along the split's axis, in the space
    /// `bounds` is in), no further than either neighbour's minimum allows.
    /// Only the two parts on screen either side of the divider change size,
    /// and a hidden part keeps its weight. False when nothing moved.
    @discardableResult
    mutating func moveDivider(at path: [Int], index: Int, to position: CGFloat,
                              in bounds: CGRect, metrics: Metrics = Metrics(),
                              hidden: Set<Leaf> = []) -> Bool {
        var changed = false
        root = Self.editing(root, at: path[...], rect: bounds, metrics: metrics, hidden: hidden) { axis, parts, rect in
            let shown = Self.shown(parts, hidden: hidden)
            guard let place = shown.firstIndex(of: index), place + 1 < shown.count else { return }
            var extents = Self.extents(of: shown.map { parts[$0] }, axis: axis, in: rect,
                                       metrics: metrics, hidden: hidden)
            var start = axis == .row ? rect.minX : rect.minY
            for before in 0..<place { start += extents[before] + metrics.gap }
            let both = extents[place] + extents[place + 1]
            let firstMinimum = Self.length(
                of: Self.minimumSize(of: parts[shown[place]].node, metrics: metrics, hidden: hidden), along: axis)
            let secondMinimum = Self.length(
                of: Self.minimumSize(of: parts[shown[place + 1]].node, metrics: metrics, hidden: hidden), along: axis)
            guard both > 0 else { return }
            // Too little room for both minimums: the divider may still move, each
            // side keeping at least a sliver, so it is never stuck.
            let low = both >= firstMinimum + secondMinimum ? firstMinimum : min(both, 1)
            let high = both >= firstMinimum + secondMinimum ? both - secondMinimum : max(both - 1, low)
            let first = min(max(position - start, low), high).rounded()
            guard abs(first - extents[place]) >= 0.5 else { return }
            extents[place] = first
            extents[place + 1] = both - first
            changed = Self.setWeights(of: &parts, shown: shown, from: extents)
        }
        return changed
    }

    /// Make `leaf`'s own part of the split it is in `extent` points long,
    /// along that split's axis, as laid out in `bounds`. Held so that it and
    /// its siblings on screen keep their minimums while there is room, the
    /// difference taken from or given to those siblings in proportion to
    /// what they have. Hidden parts keep their weight. How a leaf that
    /// opened at a guessed share is given the size it was meant to have.
    ///
    /// False when the leaf has no split to be a part of, isn't on screen,
    /// has nobody on screen beside it, or is already that long.
    @discardableResult
    mutating func resize(_ leaf: Leaf, to extent: CGFloat, in bounds: CGRect,
                         metrics: Metrics = Metrics(), hidden: Set<Leaf> = []) -> Bool {
        guard !hidden.contains(leaf), let path = Self.path(to: leaf, in: root),
              let index = path.last else { return false }
        var changed = false
        root = Self.editing(root, at: path.dropLast(), rect: bounds, metrics: metrics, hidden: hidden) { axis, parts, rect in
            let shown = Self.shown(parts, hidden: hidden)
            guard let place = shown.firstIndex(of: index), shown.count > 1 else { return }
            var extents = Self.extents(of: shown.map { parts[$0] }, axis: axis, in: rect,
                                       metrics: metrics, hidden: hidden)
            let minimums = shown.map {
                Self.length(of: Self.minimumSize(of: parts[$0].node, metrics: metrics, hidden: hidden), along: axis)
            }
            let total = extents.reduce(0, +)
            guard total > 0 else { return }
            let needed = minimums.reduce(0, +)
            let roomy = total >= needed
            let low = roomy ? minimums[place] : min(total, 1)
            let high = roomy ? total - (needed - minimums[place]) : max(total - 1, low)
            let own = min(max(extent, low), high).rounded()
            guard abs(own - extents[place]) >= 0.5 else { return }
            let had = total - extents[place]
            let rest = total - own
            for other in extents.indices where other != place {
                extents[other] = had > 0 ? rest * extents[other] / had : rest / CGFloat(extents.count - 1)
            }
            extents[place] = own
            if roomy { Self.raise(&extents, to: minimums, within: total, holding: [place]) }
            changed = Self.setWeights(of: &parts, shown: shown, from: extents)
        }
        return changed
    }

    // MARK: - Finding your way

    /// The leaf you get to by going from `leaf` toward `edge`: the one across
    /// that edge that lines up best with `leaf` (most shared edge), the upper
    /// or left one on a tie. nil at the area's own edge, and for a leaf that
    /// is hidden. A hidden leaf is nobody's neighbour.
    func neighbour(of leaf: Leaf, toward edge: Edge, in bounds: CGRect,
                   metrics: Metrics = Metrics(), hidden: Set<Leaf> = []) -> Leaf? {
        let frames = frames(in: bounds, metrics: metrics, hidden: hidden).leaves
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
        } else if rawValue == "side" {
            self = .side
        } else if rawValue == "bottom" {
            self = .bottom
        } else if let id = UUID(uuidString: rawValue) {
            self = .pane(id)
        } else {
            return nil
        }
    }

    var rawValue: String {
        switch self {
        case .main: return "main"
        case .side: return "side"
        case .bottom: return "bottom"
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
