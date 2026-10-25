import SwiftUI

/// The graph in the right-hand pane: the open note and what it links (or
/// the whole vault), a dot a note — bigger the more it links — a click
/// opening it. Scroll or pinch to zoom, drag to move.
struct NotesGraphView: View {
    @ObservedObject var model: NotesModel
    @ObservedObject var theme: ChromeTheme
    let open: (URL) -> Void

    @State private var graph = NotesGraph(nodes: [], edges: [])
    @State private var local = true
    @State private var depth = 1
    @State private var scale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var dragStart: CGSize?
    @State private var hovered: Int?
    @State private var generation = 0
    @State private var layout: Task<NotesGraph, Never>?

    private var center: String? { local ? model.current.map(model.path(of:)) : nil }

    var body: some View {
        VStack(spacing: 0) {
            controls
            GeometryReader { geometry in
                canvas(size: geometry.size)
            }
        }
        .onAppear { relayout() }
        // Every reload: a link added between two notes changes no name.
        .onChange(of: model.revision) { _ in relayout() }
        .onChange(of: model.current) { _ in if local { relayout() } }
        .onChange(of: local) { _ in relayout() }
        .onChange(of: depth) { _ in relayout() }
    }

    private var controls: some View {
        HStack(spacing: 8) {
            Picker("", selection: $local) {
                Text("This Note").tag(true)
                Text("Whole Vault").tag(false)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            if local {
                Stepper(value: $depth, in: 1...3) {
                    Text(verbatim: "\(depth) link\(depth == 1 ? "" : "s") away").font(.system(size: 11)).foregroundStyle(theme.dimText)
                }
                .fixedSize()
            }
            Spacer(minLength: 0)
            Text(verbatim: "\(graph.nodes.count)").font(.system(size: 11)).foregroundStyle(theme.dimText)
                .help("Notes in the graph")
            Button {
                scale = 1
                offset = .zero
            } label: {
                Image(systemName: "scope").font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.dimText)
            .help("Fit")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    /// The layout's own space onto the view: fitted, then zoomed and moved.
    private func transform(size: CGSize) -> (CGPoint) -> CGPoint {
        let box = graph.bounds.insetBy(dx: -30, dy: -30)
        let fit = min(size.width / max(box.width, 1), size.height / max(box.height, 1), 2.5) * scale
        return { point in
            CGPoint(
                x: (point.x - box.midX) * fit + size.width / 2 + offset.width,
                y: (point.y - box.midY) * fit + size.height / 2 + offset.height)
        }
    }

    private func radius(_ node: NotesGraph.Node) -> CGFloat { 3.5 + min(CGFloat(node.degree), 20) * 0.6 }

    private func canvas(size: CGSize) -> some View {
        let place = transform(size: size)
        let current = model.current.map(model.path(of:))
        let accent = theme.accentText
        let text = theme.text
        let dim = theme.dimText
        let neighbours: Set<Int> =
            hovered.map { h in
                Set(graph.edges.compactMap { $0[0] == h ? $0[1] : $0[1] == h ? $0[0] : nil })
            } ?? []
        return Canvas { context, _ in
            for edge in graph.edges {
                var line = Path()
                line.move(to: place(graph.nodes[edge[0]].position))
                line.addLine(to: place(graph.nodes[edge[1]].position))
                let lit = hovered != nil && (edge[0] == hovered || edge[1] == hovered)
                context.stroke(line, with: .color(lit ? accent.opacity(0.8) : dim.opacity(0.35)), lineWidth: lit ? 1.4 : 0.8)
            }
            for (i, node) in graph.nodes.enumerated() {
                let point = place(node.position)
                let r = radius(node)
                let isCurrent = node.path == current
                let faded = hovered != nil && hovered != i && !neighbours.contains(i)
                let fill = isCurrent || hovered == i ? accent : text.opacity(faded ? 0.25 : 0.7)
                context.fill(Path(ellipseIn: CGRect(x: point.x - r, y: point.y - r, width: 2 * r, height: 2 * r)), with: .color(fill))
                // Names where they can be read: the open note's, the one under
                // the pointer and its neighbours, and all of them up close.
                if isCurrent || hovered == i || neighbours.contains(i) || scale > 1.6 || graph.nodes.count <= 30 {
                    let name = ((node.path as NSString).lastPathComponent as NSString).deletingPathExtension
                    context.draw(
                        Text(verbatim: name).font(.system(size: 10.5, weight: isCurrent ? .semibold : .regular))
                            .foregroundColor(faded ? dim.opacity(0.4) : text),
                        at: CGPoint(x: point.x, y: point.y + r + 8))
                }
            }
        }
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            switch phase {
            case .active(let location): hovered = node(at: location, place: place)
            case .ended: hovered = nil
            }
        }
        .gesture(
            DragGesture(minimumDistance: 3)
                .onChanged { value in
                    if dragStart == nil { dragStart = offset }
                    offset = CGSize(width: dragStart!.width + value.translation.width, height: dragStart!.height + value.translation.height)
                }
                .onEnded { _ in dragStart = nil }
        )
        .simultaneousGesture(MagnificationGesture().onChanged { value in scale = min(max(value, 0.2), 8) })
        .onTapGesture { location in
            if let i = node(at: location, place: place) { open(model.url(of: graph.nodes[i].path)) }
        }
        .overlay(alignment: .center) {
            if graph.nodes.isEmpty {
                Text(local ? "Open a note to see what it links to" : "No notes yet")
                    .font(.system(size: 12)).foregroundStyle(theme.dimText)
            }
        }
    }

    private func node(at location: CGPoint, place: (CGPoint) -> CGPoint) -> Int? {
        var best: (Int, CGFloat)?
        for (i, node) in graph.nodes.enumerated() {
            let p = place(node.position)
            let distance = hypot(p.x - location.x, p.y - location.y)
            if distance <= radius(node) + 6, distance < (best?.1 ?? .infinity) { best = (i, distance) }
        }
        return best?.0
    }

    /// Laid out off the main thread: a big vault takes a moment.
    private func relayout() {
        model.whenLoaded {
            generation += 1
            let token = generation
            let index = model.index
            let center = self.center
            let depth = self.depth
            let local = self.local
            // The one before is stopped, not only ignored: a whole vault's
            // layout is a lot of work to finish for nothing.
            layout?.cancel()
            let task = Task.detached(priority: .userInitiated) {
                local && center == nil ? NotesGraph(nodes: [], edges: []) : NotesGraph.make(from: index, center: center, depth: depth)
            }
            layout = task
            Task {
                let made = await task.value
                guard token == generation, !task.isCancelled else { return }
                graph = made
                hovered = nil
            }
        }
    }
}
