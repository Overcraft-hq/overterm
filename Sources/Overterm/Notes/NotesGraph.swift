import CoreGraphics
import Foundation

/// The vault as Obsidian's graph draws it: notes as dots, links as lines,
/// laid out by force — linked notes pull together, every two push apart.
/// Pure and deterministic: the same vault lays out the same way.
struct NotesGraph: Equatable, Sendable {
    struct Node: Equatable, Sendable {
        var path: String
        var degree: Int
        var position: CGPoint
    }

    var nodes: [Node]
    /// Pairs of node indices.
    var edges: [[Int]]

    /// Every note, or the notes within `depth` links of `center`.
    static func make(from index: NotesIndex, center: String? = nil, depth: Int = 1, orphans: Bool = true) -> NotesGraph {
        var neighbours: [String: Set<String>] = [:]
        for path in index.paths {
            for link in index.document(path)?.links ?? [] {
                guard let target = index.resolve(link, from: path), target != path, index.notes[target] != nil else { continue }
                neighbours[path, default: []].insert(target)
                neighbours[target, default: []].insert(path)
            }
        }
        var paths: [String]
        if let center {
            var kept: Set<String> = [center]
            var frontier: Set<String> = [center]
            for _ in 0..<max(1, depth) {
                frontier = Set(frontier.flatMap { neighbours[$0] ?? [] }).subtracting(kept)
                kept.formUnion(frontier)
            }
            paths = kept.sorted()
        } else {
            paths = index.paths.filter { orphans || !(neighbours[$0]?.isEmpty ?? true) }
        }
        let position = Dictionary(uniqueKeysWithValues: paths.enumerated().map { ($1, $0) })
        var edges: [[Int]] = []
        for (a, path) in paths.enumerated() {
            // Sorted: a set's order changes run to run, and the layout with it.
            for other in (neighbours[path] ?? []).sorted() {
                if let b = position[other], a < b { edges.append([a, b]) }
            }
        }
        // A spiral to start from: spread, and the same every time.
        let nodes = paths.enumerated().map { i, path in
            let angle = Double(i) * 2.399963  // the golden angle
            let radius = 12 * sqrt(Double(i) + 1)
            return Node(path: path, degree: neighbours[path]?.count ?? 0, position: CGPoint(x: radius * cos(angle), y: radius * sin(angle)))
        }
        var graph = NotesGraph(nodes: nodes, edges: edges)
        graph.layout()
        return graph
    }

    /// Fruchterman–Reingold, its steps fewer as the graph grows (each is
    /// every pair).
    mutating func layout() {
        let n = nodes.count
        guard n > 1 else {
            if n == 1 { nodes[0].position = .zero }
            return
        }
        let ideal = 46.0
        let steps = max(n > 3000 ? 12 : 40, min(400, 30_000_000 / (n * n)))
        var temperature = 60.0
        var x = nodes.map { Double($0.position.x) }
        var y = nodes.map { Double($0.position.y) }
        var dx = [Double](repeating: 0, count: n)
        var dy = [Double](repeating: 0, count: n)
        for _ in 0..<steps {
            // A layout superseded (another note, another depth) stops here.
            if Task.isCancelled { return }
            for i in 0..<n {
                dx[i] = 0
                dy[i] = 0
            }
            for i in 0..<n {
                for j in (i + 1)..<n {
                    let ddx = x[i] - x[j]
                    let ddy = y[i] - y[j]
                    let distance2 = max(ddx * ddx + ddy * ddy, 0.01)
                    let force = ideal * ideal / distance2
                    dx[i] += ddx * force
                    dy[i] += ddy * force
                    dx[j] -= ddx * force
                    dy[j] -= ddy * force
                }
            }
            for edge in edges {
                let (a, b) = (edge[0], edge[1])
                let ddx = x[a] - x[b]
                let ddy = y[a] - y[b]
                let distance = max(sqrt(ddx * ddx + ddy * ddy), 0.01)
                let force = distance / ideal
                dx[a] -= ddx * force
                dy[a] -= ddy * force
                dx[b] += ddx * force
                dy[b] += ddy * force
            }
            for i in 0..<n {
                // A pull to the middle, so the unlinked don't drift away.
                dx[i] -= x[i] * 0.08
                dy[i] -= y[i] * 0.08
                let length = max(sqrt(dx[i] * dx[i] + dy[i] * dy[i]), 0.01)
                let step = min(length, temperature)
                x[i] += dx[i] / length * step
                y[i] += dy[i] / length * step
            }
            temperature = max(1, temperature * 0.97)
        }
        for i in 0..<n { nodes[i].position = CGPoint(x: x[i], y: y[i]) }
    }

    /// The box around every node.
    var bounds: CGRect {
        guard let first = nodes.first else { return .zero }
        var box = CGRect(origin: first.position, size: .zero)
        for node in nodes { box = box.union(CGRect(origin: node.position, size: .zero)) }
        return box
    }
}
