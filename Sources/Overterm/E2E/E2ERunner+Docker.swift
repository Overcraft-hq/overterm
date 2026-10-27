import AppKit

/// The Docker page against the fake engine (FakeDockerEngine) on a socket
/// of its own: never the user's Docker. What would reach a real `docker` —
/// compose, a shell, a log followed — is recorded rather than typed; one
/// harmless command checks the tab it would go to.
extension E2ERunner {
    /// OVERTERM_DUMP_PNG's picture of the page, `-<name>` before `.png`.
    private func capture(_ name: String) async {
        guard let png = ProcessInfo.processInfo.environment["OVERTERM_DUMP_PNG"], !png.isEmpty else { return }
        await pause(0.8)
        app.captureWindow(to: png.replacingOccurrences(of: ".png", with: "-\(name).png"))
    }

    /// The panel and the right-hand pane, for OVERTERM_DUMP_PNG.
    private func capturePanel() async {
        guard ProcessInfo.processInfo.environment["OVERTERM_DUMP_PNG"]?.isEmpty == false, let web = DockerModel.shared.container("ot-shop-web-1") else {
            return
        }
        app.showDockerPanel(nil)
        app.showContainer(web)
        await capture("panel")
        app.toggleDiff(nil)
        app.sidebarPanel.panel = .files
    }

    /// Images, volumes, networks, Clean Up — on the page, which shows.
    private func resourcesChecks(_ fake: FakeDockerEngine) async {
        let page = app.dockerPage
        let docker = DockerModel.shared
        let debian = fake.addImage("debian:bookworm-slim", size: 80 << 20)
        let dangling = fake.addImage(nil, size: 10 << 20)
        let redis = fake.addImage("redis:7", size: 40 << 20)
        let old = fake.add(name: "ot-old", image: "debian:bookworm-slim", state: .exited, imageID: debian, volumes: ["ot-old-data"])
        fake.addVolume("ot-old-data", size: 5 << 20, refCount: 1)
        fake.addVolume(String(repeating: "f", count: 64), size: 7 << 20, refCount: 0, anonymous: true)
        fake.addNetwork("bridge")
        fake.addNetwork("ot-shop_default", members: [docker.container("ot-shop-web-1")?.Id ?? ""])
        fake.buildCache = 30 << 20

        page.press("2")
        check("2 is Images", page.section == .images)
        check("read when their section shows", await eventually(5) { docker.images.count == 3 }, "\(docker.images.map(\.tags))")
        check(
            "what uses one is known", await eventually(3) { docker.images.first { $0.Id == debian }.map { docker.containers(using: $0).map(\.Id) } == [old] },
            "\(docker.containers.map { "\($0.name) \($0.ImageID ?? "")" }) vs \(debian)")
        check("and their sizes on the left", await eventually(5) { docker.diskUsage != nil })
        page.pull("busybox:1.36")
        check(
            "a pull shows its progress, then the image",
            await eventually(5) { page.pulls["busybox:1.36"]?.done == true && docker.images.contains { $0.tags.contains("busybox:1.36") } },
            page.pulls["busybox:1.36"]?.summary ?? "no pull")
        page.pull("private/thing")
        check(
            "one the engine may not pull says where it can be",
            await eventually(5) { page.pulls["private/thing"]?.error?.contains("terminal tab") == true }, page.pulls["private/thing"]?.error ?? "")
        if let image = docker.images.first(where: { $0.Id == redis }) { page.tag(image, as: "ot/cache:1") }
        check("a tag is added", await eventually(5) { docker.images.first { $0.Id == redis }?.tags.contains("ot/cache:1") == true })
        page.imageSelection = [redis]
        page.press("\u{7F}")
        let asked = await eventually(2) { self.window.attachedSheet != nil }
        let clicked = asked && clickSheetButton("Remove")
        let gone = await eventually(5) { !docker.images.contains { $0.Id == redis } }
        check(
            "⌫ removes an image, asked first", clicked && gone,
            "asked \(asked), clicked \(clicked), gone \(gone), \(page.error ?? ""), \(fake.requests.filter { $0.hasPrefix("DELETE /v1.47/images") })")

        page.press("3")
        check("3 is Volumes, with their sizes", await eventually(5) { docker.volumes.count == 2 && docker.volumes.allSatisfy { $0.UsageData != nil } })
        check("an anonymous one goes by its start", docker.volumes.last?.shortName == String(repeating: "f", count: 12))
        check("what mounts one is known", docker.volumes.first.map { docker.containers(mounting: $0).map(\.Id) } == [old])

        page.press("4")
        check("4 is Networks, Docker's own last", await eventually(5) { docker.networks.map(\.Name) == ["ot-shop_default", "bridge"] })
        check("with who is on them", docker.networks.first.map { docker.containers(on: $0).map(\.name) } == ["ot-shop-web-1"])

        // Clean Up: listed, then done.
        page.press("c")
        check("c opens Clean Up", await eventually(2) { self.window.attachedSheet != nil })
        let plan = page.cleanPlan
        check("it lists the stopped container", plan.containers.map(\.Id) == [old], "\(plan.containers.map(\.name))")
        check("the untagged image, not the tagged ones", plan.images.map(\.Id) == [dangling], "\(plan.images.map(\.tags))")
        check("no volume unless asked", plan.volumes.isEmpty)
        check("and the build cache", await eventually(3) { page.cleanPlan.buildCache == 30 << 20 }, "\(page.cleanPlan.buildCache)")
        page.cleanUp()
        check(
            "Clean Up removes what it listed",
            await eventually(5) { fake.summary(old) == nil && !docker.images.contains { $0.Id == dangling } && fake.buildCache == 0 },
            page.error ?? "")
        check("and says what it freed", await eventually(3) { page.cleaned?.contains("freed") == true }, page.cleaned ?? "")
        check("its sheet closed", await eventually(2) { self.window.attachedSheet == nil })
        page.press("2")
        await capture("images")
        page.press("1")
        check("1 is Containers again", page.section == .containers)
    }

    func dockerScenario() async {
        await settledPrompt()
        let socket = "/tmp/ot-e2e-docker-\(UUID().uuidString.prefix(6)).sock"
        let fake = FakeDockerEngine(socket: socket)
        do { try fake.start() } catch { return check("the fake engine starts", false, "\(error)") }
        defer { fake.stop() }
        let folder = scratch.appendingPathComponent("ot-shop", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let real = FileTreeModel.realPath(folder)
        let web = fake.add(
            name: "ot-shop-web-1", image: "nginx:1.27", project: "ot-shop", workingDir: real, service: "web",
            ports: [DockerPort(IP: "0.0.0.0", PrivatePort: 80, PublicPort: 58080, Type: "tcp"), DockerPort(IP: "::", PrivatePort: 80, PublicPort: 58080, Type: "tcp")],
            env: ["NGINX_PORT=80", "API_TOKEN=s3cr3t-value"])
        let db = fake.add(name: "ot-shop-db-1", image: "postgres:16", project: "ot-shop", workingDir: real, service: "db", health: "healthy")
        let loose = fake.add(name: "ot-scratch", image: "debian:bookworm-slim", state: .exited)
        let docker = DockerModel.shared
        docker.use(DockerEndpoint(address: .unix(socket), context: nil, source: "OVERTERM_DOCKER_HOST"))

        // ⌥⌘P: the page, over the body, in its turn with Settings.
        let page = app.dockerPage
        app.toggleDockerPage(nil)
        check("⌥⌘P opens the Docker page", app.store.showingOverlay == .docker && app.dockerView?.isHidden == false)
        check("it sits in the strip as a page", app.store.openOverlays.contains(.docker))
        check("it reaches the engine", await eventually(5) { docker.connection.isRunning }, "\(docker.connection)")
        check(
            "and lists a compose project, then the rest",
            await eventually(5) { page.groups.map(\.id) == ["project:ot-shop", "loose"] }, "\(page.groups.map(\.id))")
        check("its services by name", page.groups.first?.containers.map(\.composeService) == ["db", "web"])
        check("the list has the keyboard", await eventually(3) { self.app.dockerListHasKeyboard() }, "\(String(describing: window.firstResponder))")
        if let png = ProcessInfo.processInfo.environment["OVERTERM_DUMP_PNG"], !png.isEmpty {
            page.selection = [web]
            await pause(1)
            app.captureWindow(to: png)
        }

        // A container's detail, secrets hidden.
        page.selection = [web]
        check("one selected is detailed", page.detailed?.Id == web)
        await pause(0.3)
        check(
            "and the list keeps the keyboard as the detail comes in", app.dockerListHasKeyboard(), "\(String(describing: window.firstResponder))")
        check("its inspect data is read", await eventually(5) { page.session?.detail?.name == "ot-shop-web-1" })
        check("a port listed once, not per address family", PublishedPort.of(page.detailed?.Ports ?? []).map(\.label) == ["58080→80"])

        // Logs: the last lines, then what comes, levels read.
        fake.log(web, "booting nginx")
        fake.log(web, "[ERROR] upstream timed out", stream: .stderr)
        page.press("l")
        check("l opens its logs", page.detailTab == .logs)
        check(
            "the last lines are read", await eventually(5) { page.session?.lines.map(\.message) == ["booting nginx", "[ERROR] upstream timed out"] },
            "\(page.session?.lines.map(\.message) ?? [])")
        check("an error line is an error", page.session?.lines.last?.level == .error)
        check("and the log is followed", await eventually(3) { page.session?.following == true })
        fake.log(web, "GET / 200")
        check("a new line arrives as it is written", await eventually(5) { page.session?.lines.last?.message == "GET / 200" })
        func logText() -> String {
            (Self.find(NSTextView.self, in: app.dockerView) { $0.accessibilityIdentifier() == "docker.text" })?.string ?? ""
        }
        check("and shows in the text", await eventually(3) { logText().contains("GET / 200") }, logText())
        await capture("logs")
        // A restart ends the followed log; it is followed again, nothing twice.
        fake.set(web, state: .exited)
        check("a stopped container's log stops", await eventually(5) { page.session?.following == false })
        fake.log(web, "worker exiting")
        fake.set(web, state: .running)
        let again = await eventually(5) { page.session?.lines.last?.message == "worker exiting" }
        check(
            "and is followed again when it starts", again,
            "following \(page.session?.following == true), \(page.session?.lines.map(\.message) ?? []), \(page.session?.error ?? ""), state \(docker.container(web)?.State ?? ""), \(fake.requests.filter { $0.contains("/logs") })"
        )
        check(
            "with no line twice", page.session?.lines.filter { $0.message == "GET / 200" }.count == 1, "\(page.session?.lines.map(\.message) ?? [])")

        // Stats while their tab shows; Inspect with secrets hidden.
        page.detailTab = .stats
        check("stats are read while their tab shows", await eventually(5) { (page.session?.history.count ?? 0) >= 2 })
        await capture("stats")
        check("CPU as docker stats works it out", abs((page.session?.usage?.cpuPercent ?? 0) - 8) < 0.01, "\(page.session?.usage?.cpuPercent ?? -1)")
        page.press("i")
        check("i opens Inspect, the engine's JSON", await eventually(5) { page.session?.json?.contains("\"Config\"") == true })
        check("with its secrets hidden", page.session?.json?.contains("s3cr3t-value") == false && page.session?.json?.contains("API_TOKEN") == true)
        page.detailTab = .overview
        check(
            "leaving the tabs closes their streams", await eventually(3) { fake.openStreams == 1 },
            fake.streams + " " + fake.requests.filter { $0.contains("/logs") }.map { String($0.suffix(60)) }.joined(separator: " | "))

        // Keys: `s` stops it, `s` again starts it, as the engine says.
        let pressed = page.press("s")
        let stopped = await eventually(5) { docker.container(web)?.state == .exited }
        check("s stops the selected container", pressed && stopped)
        check("and the engine stopped it", fake.summary(web)?.state == .exited)
        check("the project is partly up", docker.projects.first?.status == .partial)
        // A key as typed, through what the window's key monitor asks (the
        // monitor sees the system's events, not a window's sendEvent).
        func key(_ character: String, _ modifiers: NSEvent.ModifierFlags = []) -> NSEvent? {
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: character, charactersIgnoringModifiers: character, isARepeat: false,
                keyCode: 1)
        }
        check("⌘S is not the list's", key("s", .command).map { !app.handleDockerKey($0) } == true)
        let typed = key("s").map { app.handleDockerKey($0) } == true
        let started = await eventually(5) { docker.container(web)?.state == .running }
        check("typed s starts it again", typed && started, "\(docker.container(web)?.State ?? "")")

        // An exit the engine reports by itself reaches the list.
        fake.set(db, state: .exited, exitCode: 1)
        check("an exit is seen without asking", await eventually(5) { docker.container(db)?.exitCode == 1 })
        check("and the project shows the failure", docker.projects.first?.failing.map(\.Id) == [db])

        // The filter.
        page.filter = "status:running"
        check("status:running", page.groups.flatMap(\.containers).map(\.Id) == [web], "\(page.groups.flatMap(\.containers).map(\.name))")
        page.filter = "-project:ot-shop"
        check("-project: leaves the others", page.groups.map(\.id) == ["loose"])
        page.filter = ""
        page.runningOnly = true
        check("Running only", !page.groups.flatMap(\.containers).contains { $0.Id == loose })
        page.runningOnly = false
        _ = page.press("/")
        check("/ goes to the filter", await eventually(2) { !self.app.dockerListHasKeyboard() })
        page.focusList += 1
        check("and back", await eventually(2) { self.app.dockerListHasKeyboard() })

        // What would run in a terminal: recorded, with the fake engine's host.
        var commands: [String] = []
        let actions = page.actions
        page.actions?.run = { command, _ in commands.append(command) }
        page.selection = [DockerPageModel.projectTag("ot-shop")]
        _ = page.press("u")
        check(
            "u is compose up for the project, told which engine",
            commands.last?.hasPrefix("DOCKER_HOST=unix://\(socket) docker compose -p ot-shop -f ") == true && commands.last?.hasSuffix(" up -d") == true,
            commands.last ?? "nothing")
        page.selection = [web]
        _ = page.press("e")
        check("e is a shell in it", commands.last?.contains("docker exec -it ot-shop-web-1 sh -c") == true, commands.last ?? "")
        page.actions = actions

        // Remove asks first.
        page.selection = [loose]
        _ = page.press("\u{7F}")
        check("⌫ asks before removing", await eventually(2) { self.window.attachedSheet != nil })
        let clicked = clickSheetButton("Remove")
        let removed = await eventually(5) { docker.container(loose) == nil }
        check("and removes on yes", clicked && removed)
        check("in the engine too", fake.summary(loose) == nil)

        // The engine going away is said, and its return noticed.
        fake.stop()
        check(
            "an engine that went away is said",
            await eventually(5) {
                if case .down = docker.connection { return true }
                return false
            }, "\(docker.connection)")
        check("its containers aren't shown as if there", docker.containers.isEmpty)
        try? fake.start()
        check("its return is noticed", await eventually(8) { docker.connection.isRunning && docker.containers.count == 2 })

        // A command really typed into a tab, out from under the page.
        let mark = scratch.appendingPathComponent("docker-command.txt")
        let tabs = app.store.tabs.count
        app.runDockerCommand("echo docker-e2e-$((40 + 2)) > '\(mark.path)'", in: folder)
        check("a command goes to a new tab", app.store.tabs.count == tabs + 1 && app.store.showingOverlay == nil)
        check(
            "which runs it in the project's folder",
            await eventually(8) { (try? String(contentsOf: mark, encoding: .utf8))?.contains("docker-e2e-42") == true }
                && app.store.selected?.workingDirectory == folder.path)

        // The rail's panel: this checkout's stack, then what runs elsewhere.
        let elsewhere = fake.add(name: "ot-elsewhere", image: "redis:7")
        app.showDockerPanel(nil)
        check("the rail opens on the Docker panel", app.sidebarPanel.panel == .docker && app.sidebarItem?.isCollapsed == false)
        check(
            "it follows the selected tab's checkout",
            await eventually(5) { app.dockerPanel.checkout.map(FileTreeModel.realPath) == real }, app.dockerPanel.checkout?.path ?? "nil")
        check("and lists its compose project", await eventually(5) { app.dockerPanel.here.map(\.name) == ["ot-shop"] })
        check("then what runs elsewhere", await eventually(5) { app.dockerPanel.others.map(\.Id) == [elsewhere] }, "\(app.dockerPanel.others.map(\.name))")
        if let container = docker.container(web) { app.showContainer(container) }
        check("a container picked opens on the right", app.rightPane.mode == .container && app.diffItem?.isCollapsed == false)
        check("with its detail", await eventually(5) { app.dockerPanel.session?.detail?.name == "ot-shop-web-1" })
        let followed = await eventually(5) { app.dockerPanel.session?.following == true }
        check(
            "on its logs, followed", followed,
            "visible \(app.dockerPanel.slotVisible), tab \(app.dockerPanel.tab), panelVisible \(app.diff.panelVisible), lines \(app.dockerPanel.session?.lines.count ?? -1), \(fake.streams)")
        app.toggleDiff(nil)
        check("closing the pane closes its log", await eventually(3) { fake.openStreams == 1 }, fake.streams)
        app.sidebarPanel.panel = .files
        check("the panel off the rail lets the poll go", await eventually(2) { !app.dockerPanelShown })
        await capturePanel()

        // ⇧⌥⌘P: the palette, on containers and compose projects.
        app.showDockerSwitcher(nil)
        check("⇧⌥⌘P opens the palette on Docker", app.paletteView?.isHidden == false && app.palette.scope == .container)
        check(
            "listing its projects and containers",
            Set(app.palette.results.map(\.title)).isSuperset(of: ["ot-shop", "ot-shop-web-1", "ot-shop-db-1", "ot-elsewhere"])
                && app.palette.results.allSatisfy { $0.group == .container }, "\(app.palette.results.map(\.title))")
        app.palette.query = "elsew"
        check("found by part of its name", app.palette.selected?.title == "ot-elsewhere", app.palette.selected?.title ?? "nothing")
        if let item = app.palette.selected {
            app.hidePalette()
            item.perform(true, [:])
        }
        check("↩ shows it on the page, selected", app.store.showingOverlay == .docker && page.selection == [elsewhere], "\(page.selection)")
        app.showDockerSwitcher(nil)
        app.palette.query = "ot-shop-db"
        if let item = app.palette.selected, item.title == "ot-shop-db-1" {
            app.hidePalette()
            item.perform(false, [:])
        }
        check("⌥↩ starts a stopped one", await eventually(5) { docker.container(db)?.state == .running })
        app.showDockerSwitcher(nil)
        app.showDockerSwitcher(nil)
        check("⇧⌥⌘P again puts it away", app.paletteView?.isHidden == true)
        await resourcesChecks(fake)
        app.hideOverlay()

        // ⌥⌘P twice: back to the terminal, the page kept in the strip.
        app.toggleDockerPage(nil)
        app.toggleDockerPage(nil)
        check("⌥⌘P again goes back to the terminal", app.store.showingOverlay == nil && app.store.openOverlays.contains(.docker))
        app.closeOverlay(.docker)
        check("its ✕ closes it", !app.store.openOverlays.contains(.docker) && app.dockerView?.isHidden == true)
        docker.use(nil)
        check("an isolated run left alone reaches no Docker", await eventually(3) { docker.connection == .off })
    }
}
