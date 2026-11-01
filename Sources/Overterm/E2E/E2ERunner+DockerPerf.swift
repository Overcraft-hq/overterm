import AppKit

/// The Docker page with many containers — 160 in 20 compose projects —
/// timed as its list scrolls, by the page's own views (no system events).
extension E2ERunner {
    func dockerPerfScenario() async {
        await settledPrompt()
        let socket = "/tmp/ot-e2e-dperf-\(UUID().uuidString.prefix(6)).sock"
        let fake = FakeDockerEngine(socket: socket)
        do { try fake.start() } catch { return check("the fake engine starts", false, "\(error)") }
        defer { fake.stop() }
        for project in 0..<20 {
            let folder = scratch.appendingPathComponent("perf-\(project)", isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? "services:\n  web:\n    image: nginx\n".write(to: folder.appendingPathComponent("compose.yaml"), atomically: true, encoding: .utf8)
            let real = FileTreeModel.realPath(folder)
            for service in 0..<8 {
                _ = fake.add(
                    name: "perf-\(project)-svc\(service)-1", image: "nginx:1.27", project: "perf-\(project)", workingDir: real, service: "svc\(service)",
                    ports: [DockerPort(IP: "0.0.0.0", PrivatePort: 80, PublicPort: 40000 + project * 10 + service, Type: "tcp")])
            }
        }
        let docker = DockerModel.shared
        docker.use(DockerEndpoint(address: .unix(socket), context: nil, source: "OVERTERM_DOCKER_HOST"))
        docker.usage.interval = .milliseconds(300)
        docker.usage.first = .milliseconds(100)
        let page = app.dockerPage
        app.toggleDockerPage(nil)
        check(
            "160 containers listed", await eventually(10) { page.groups.flatMap(\.containers).count == 160 },
            "\(page.groups.flatMap(\.containers).count)")
        await pause(1.5)
        guard let view = app.dockerView else { return check("the page's view", false) }

        // The list scrolled top to bottom.
        var scrollViews: [NSScrollView] = []
        func walk(_ view: NSView) {
            if let scroll = view as? NSScrollView, !scroll.isHidden, scroll.documentView is NSTableView { scrollViews.append(scroll) }
            view.subviews.forEach(walk)
        }
        walk(view)
        if let scroll = scrollViews.max(by: { $0.frame.height < $1.frame.height }) {
            var samples: [Double] = []
            var y: CGFloat = 0
            for _ in 0..<200 {
                let height = scroll.documentView?.frame.height ?? 0
                let visible = scroll.contentView.bounds.height
                guard y + visible < height else { break }
                y += visible / 3
                let start = CACurrentMediaTime()
                scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
                scroll.reflectScrolledClipView(scroll.contentView)
                view.layoutSubtreeIfNeeded()
                view.displayIfNeeded()
                samples.append((CACurrentMediaTime() - start) * 1000)
                await Task.yield()
            }
            let scrolled = Self.summary(samples)
            note("docker list scrolled: \(samples.count) steps, \(scrolled)")
            // A third of a screen a step — seven rows new at once, where a
            // trackpad brings one or two a frame. As a SwiftUI List: 39 ms
            // (30 with its menus off the rows); as a table of the same
            // SwiftUI rows, reused: ~22.
            check("the list scrolls in under 35 ms a step (p95)", scrolled.p95 < 35, "\(scrolled)")
        } else {
            check("the list's table", false)
        }
        // A table's clicks, as a person's (sent to this window, nowhere
        // else): on a row's text it is selected; on a project's chevron
        // the project folds — the row's SwiftUI button gets that one.
        if let table = scrollViews.first?.documentView as? NSTableView {
            table.scrollRowToVisible(0)
            view.layoutSubtreeIfNeeded()
            let rows = DockerTableRow.rows(page.groups, collapsed: page.collapsed)
            if let index = rows.firstIndex(where: { if case .container = $0 { true } else { false } }) {
                let cell = table.frameOfCell(atColumn: 0, row: index)
                await click(table, at: NSPoint(x: cell.minX + 70, y: cell.midY))
                check(
                    "a click on a container's row selects it", await eventually(2) { page.selection == [rows[index].id] },
                    "\(page.selection) table \(Array(table.selectedRowIndexes)) row \(index) hit \(String(describing: table.window?.contentView?.superview?.hitTest(table.convert(NSPoint(x: cell.minX + 70, y: cell.midY), to: nil)).map { type(of: $0) }))"
                )
                func isContainer(_ row: DockerTableRow) -> Bool {
                    if case .container = row { return true }
                    return false
                }
                let second = rows.indices.first { $0 > index + 1 && isContainer(rows[$0]) }
                if let second {
                    let other = table.frameOfCell(atColumn: 0, row: second)
                    await pause(0.3)
                    await click(table, at: NSPoint(x: other.minX + 70, y: other.midY))
                    check(
                        "another click selects another", await eventually(2) { page.selection == [rows[second].id] },
                        "\(page.selection) wanted \(rows[second].id)")
                    await pause(0.3)
                    await click(table, at: NSPoint(x: cell.minX + 70, y: cell.midY), modifiers: .command)
                    check(
                        "⌘-click adds one", await eventually(2) { page.selection == [rows[index].id, rows[second].id] }, "\(page.selection)")
                }
            }
            let project = page.groups[0].id
            let top = table.frameOfCell(atColumn: 0, row: 0)
            await click(table, at: NSPoint(x: top.minX + 14, y: top.midY))
            check("a click on a project's chevron folds it", await eventually(2) { page.collapsed.contains(project) }, "\(page.collapsed)")
            check("and the list follows", await eventually(2) { table.numberOfRows == DockerTableRow.rows(page.groups, collapsed: page.collapsed).count })
            check("the list has a right-click menu", table.menu != nil)
        }
        app.closeOverlay(.docker)
    }

    /// A press and its release on `view`, in this window's own queue: the
    /// release posted first, for the table's tracking loop to find.
    /// Waits until the release has been handled: a next press sent before
    /// it reached the view under the release meant for this one.
    private func click(_ view: NSView, at point: NSPoint, modifiers: NSEvent.ModifierFlags = []) async {
        guard let window = view.window else { return }
        let location = view.convert(point, to: nil)
        func event(_ type: NSEvent.EventType) -> NSEvent? {
            NSEvent.mouseEvent(
                with: type, location: location, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)
        }
        guard let down = event(.leftMouseDown), let up = event(.leftMouseUp) else { return }
        NSApp.postEvent(up, atStart: false)
        window.sendEvent(down)
        await pause(0.3)
    }
}
