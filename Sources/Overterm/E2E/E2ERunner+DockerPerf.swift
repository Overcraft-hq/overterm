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
            // SwiftUI's List makes each row again as it scrolls in: 39 ms a
            // step before its menus moved to the list, ~30 since. Held
            // there; an AppKit table, as the review's files are, is the
            // way under 16.
            check("the list scrolls in under 45 ms a step (p95)", scrolled.p95 < 45, "\(scrolled)")
        } else {
            check("the list's table", false)
        }
        app.closeOverlay(.docker)
    }
}
