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

    /// Docker's MCP tools as an agent calls them: reads open, secrets kept
    /// out, each write asked first, writes gone when Settings says so.
    private func agentChecks(_ fake: FakeDockerEngine, web: String) async {
        func call(_ name: String, _ arguments: [String: Any] = [:]) async -> (text: String, isError: Bool) {
            let message: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": name, "arguments": arguments]]
            let answer = await BrowserMCP.handle(message, browser: { nil })
            if let error = answer?["error"] as? [String: Any] { return (error["message"] as? String ?? "", true) }
            let result = answer?["result"] as? [String: Any]
            return (((result?["content"] as? [[String: Any]])?.first?["text"] as? String) ?? "", result?["isError"] as? Bool == true)
        }
        func listed() async -> [String] {
            let answer = await BrowserMCP.handle(["jsonrpc": "2.0", "id": 1, "method": "tools/list"], browser: { nil })
            return ((answer?["result"] as? [String: Any])?["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
        }
        let docker = DockerModel.shared
        let tools = await listed()
        check("agents are offered Docker's tools", tools.contains("docker_logs") && tools.contains("docker_action"), "\(tools)")
        let containers = await call("docker_containers")
        check("docker_containers lists them with their ports", containers.text.contains("ot-shop-web-1") && containers.text.contains("localhost:58080→80"), containers.text)
        let inspect = await call("docker_inspect", ["container": "ot-shop-web-1"])
        check("docker_inspect masks a secret", inspect.text.contains("API_TOKEN=••••••") && !inspect.text.contains("s3cr3t-value"), inspect.text)

        DockerMCP.askOverride = { _ in false }
        let declined = await call("docker_action", ["container": "ot-shop-web-1", "action": "stop"])
        check("a write the user declines doesn't happen", declined.isError && declined.text.contains("declined") && fake.summary(web)?.state == .running, declined.text)
        var asked = ""
        DockerMCP.askOverride = { question in
            asked = question
            return true
        }
        let stopped = await call("docker_action", ["container": "ot-shop-web-1", "action": "stop"])
        check("one allowed does", !stopped.isError && fake.summary(web)?.state == .exited, stopped.text)
        check("asked about by name", asked.contains("stop") && asked.contains("ot-shop-web-1"), asked)
        _ = await call("docker_action", ["container": "ot-shop-web-1", "action": "start"])
        check("and back", await eventually(5) { docker.container(web)?.state == .running })
        let exec = await call("docker_exec", ["container": "ot-shop-web-1", "command": "cat /etc/hostname"])
        check("docker_exec says the exit code", exec.text.hasPrefix("exit 127"), exec.text)

        Settings.shared.set("docker.agentWrites", .bool(false))
        let without = await listed()
        check("with writes off, no write is offered", without.contains("docker_logs") && !without.contains("docker_action"), "\(without)")
        let refused = await call("docker_action", ["container": "ot-shop-web-1", "action": "stop"])
        check("nor done", refused.isError && refused.text.contains("Settings ▸ Docker") && fake.summary(web)?.state == .running, refused.text)
        Settings.shared.set("docker.agentWrites", nil)
        DockerMCP.askOverride = nil
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

        // A project selected: its services' logs merged by time, each named.
        fake.log(db, "database system is ready to accept connections")
        fake.log(web, "GET /health 200")
        page.selection = [DockerPageModel.projectTag("ot-shop")]
        page.projectTab = .logs
        let merged = await eventually(5) {
            let lines = page.projectSession?.feed.lines ?? []
            return lines.contains { $0.service == "db" && $0.message.contains("ready to accept") } && lines.contains { $0.service == "web" && $0.message == "GET /health 200" }
        }
        let stamps = (page.projectSession?.feed.lines ?? []).compactMap(\.timestamp).map(DockerLogFeed.sortable)
        check("a project's logs merge its services'", merged, "\(page.projectSession?.feed.lines.map { "\($0.service ?? "") \($0.message)" } ?? [])")
        check("in time order", stamps == stamps.sorted())
        await capture("project")
        page.selection = [web]
        page.detailTab = .logs
        check("the project's streams close as it goes", await eventually(3) { fake.openStreams == 2 }, fake.streams)

        // Stats while their tab shows; Inspect with secrets hidden.
        page.detailTab = .stats
        check("stats are read while their tab shows", await eventually(5) { (page.session?.history.count ?? 0) >= 2 })
        check(
            "its processes, as top says them", await eventually(5) { page.session?.processes?.rows.contains { $0.last == "nginx: worker process" } == true },
            "\(String(describing: page.session?.processes))")
        await capture("stats")
        check("CPU as docker stats works it out", abs((page.session?.usage?.cpuPercent ?? 0) - 8) < 0.01, "\(page.session?.usage?.cpuPercent ?? -1)")
        page.press("i")
        check("i opens Inspect, the engine's JSON", await eventually(5) { page.session?.json?.contains("\"Config\"") == true })
        check("with its secrets hidden", page.session?.json?.contains("s3cr3t-value") == false && page.session?.json?.contains("API_TOKEN") == true)
        page.detailTab = .overview
        check(
            "leaving the tabs closes their streams", await eventually(3) { fake.openStreams == 1 },
            fake.streams + " " + fake.requests.filter { $0.contains("/logs") }.map { String($0.suffix(60)) }.joined(separator: " | "))

        // Files: a folder at a time through exec; a file to the editor and back.
        fake.setFile(web, "/etc/nginx/nginx.conf", Data("worker_processes 1;\n".utf8))
        fake.setFile(web, "/etc/nginx/conf.d/default.conf", Data("server {}\n".utf8))
        fake.setFile(web, "/usr/share/nginx/html/index.html", Data("<h1>hi</h1>\n".utf8))
        page.detailTab = .files
        check(
            "Files lists its working folder", await eventually(5) { page.session?.entries.map(\.name) == ["etc", "usr"] },
            "\(page.session?.entries.map(\.name) ?? []) \(page.session?.filesError ?? "")")
        page.session?.loadChanges()
        check(
            "what changed since it started", await eventually(5) { page.session?.changes?.contains { $0.Path == "/etc/nginx/nginx.conf" && $0.Kind == .added } == true },
            "\(page.session?.changes?.map(\.Path) ?? [])")
        page.session?.open("/etc/nginx")
        check("a folder opens, folders first", await eventually(5) { page.session?.entries.map(\.name) == ["conf.d", "nginx.conf"] })
        if let container = docker.container(web) { app.openContainerFile(container, "/etc/nginx/nginx.conf") }
        let opened = await eventually(5) { self.app.editor?.active?.url?.path.hasSuffix("Containers/ot-shop-web-1/etc/nginx/nginx.conf") == true }
        check("a file opens in the editor", opened, app.editor?.active?.url?.path ?? "nothing")
        check("as the container has it", app.editor?.textView?.string.contains("worker_processes 1;") == true)
        if opened, let editor = app.editor, let text = editor.textView {
            text.setSelectedRange(NSRange(location: 0, length: (text.string as NSString).length))
            text.insertText("worker_processes 4;\n", replacementRange: text.selectedRange())
            editor.saveDocument(nil)
            check(
                "saving writes it back into the container",
                await eventually(5) { fake.file(web, "/etc/nginx/nginx.conf") == Data("worker_processes 4;\n".utf8) },
                String(decoding: fake.file(web, "/etc/nginx/nginx.conf") ?? Data(), as: UTF8.self))
            // Written in the container since: asked before it is replaced.
            await pause(0.05)
            fake.setFile(web, "/etc/nginx/nginx.conf", Data("worker_processes auto;\n".utf8))
            text.setSelectedRange(NSRange(location: 0, length: (text.string as NSString).length))
            text.insertText("worker_processes 8;\n", replacementRange: text.selectedRange())
            editor.saveDocument(nil)
            check("a change made in the container since is asked about", await eventually(5) { self.window.attachedSheet != nil })
            check("not written over unasked", fake.file(web, "/etc/nginx/nginx.conf") == Data("worker_processes auto;\n".utf8))
            let replaced = clickSheetButton("Replace")
            let written = await eventually(5) { fake.file(web, "/etc/nginx/nginx.conf") == Data("worker_processes 8;\n".utf8) }
            check("and replaced when you say so", replaced && written)
        }
        page.detailTab = .overview
        app.toggleDockerPage(nil)
        // The editor takes the keyboard as its file opens, maybe after the
        // page is back: the list is given it until it has it.
        let back = await eventually(5) {
            if !self.app.dockerListHasKeyboard() { self.app.focusDockerList() }
            return self.app.dockerListHasKeyboard()
        }
        check("the page comes back with the keyboard in its list", back, "\(String(describing: window.firstResponder))")

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
        _ = page.press("E")
        check(
            "E is a debug shell beside it",
            commands.last?.contains("docker run --rm -it --pid container:ot-shop-web-1 --network container:ot-shop-web-1") == true, commands.last ?? "")
        // Run: a container as a docker run, and another like it.
        var copied: [String] = []
        page.actions?.copy = { copied.append($0) }
        if let container = docker.container(web) {
            page.copyRunCommand(container)
            check(
                "Copy as docker run writes the container's own settings",
                await eventually(5) { copied.last?.contains("docker run -d --name ot-shop-web-1") == true && copied.last?.contains("-p 58080:80") == true },
                copied.last ?? "nothing")
            page.runAnother(like: container)
            check("Run Another Like It opens the Run window, without the name", await eventually(5) { page.runSpec?.ports == ["58080:80"] && page.runSpec?.name == "" })
            check("as a sheet", await eventually(3) { self.window.attachedSheet != nil })
            if let spec = page.runSpec { page.run(spec) }
            check("Run goes to a tab", commands.last?.contains("docker run -d -p 58080:80") == true && commands.last?.contains(" nginx:1.27") == true, commands.last ?? "")
            check("and the sheet away", await eventually(3) { self.window.attachedSheet == nil })
        }
        page.actions = actions

        // d: a database container, in the Database panel's form, filled in.
        let pgID = fake.add(
            name: "ot-pg", image: "postgres:16", ports: [DockerPort(IP: "0.0.0.0", PrivatePort: 5432, PublicPort: 55432, Type: "tcp")],
            env: ["POSTGRES_USER=shop", "POSTGRES_PASSWORD=hunter2", "POSTGRES_DB=orders"])
        _ = await eventually(5) { docker.container(pgID) != nil }
        page.selection = [pgID]
        page.press("d")
        check("d opens a database container in the connection form", await eventually(5) { self.window.attachedSheet != nil })
        let draft = app.dockerDatabaseDraft?.connection
        check(
            "filled in from its image, env and port",
            draft?.kind == .postgres && draft?.port == 55432 && draft?.user == "shop" && draft?.database == "orders"
                && app.dockerDatabaseDraft?.password == "hunter2", "\(String(describing: draft))")
        if let sheet = window.attachedSheet { window.endSheet(sheet) }
        _ = await eventually(2) { self.window.attachedSheet == nil }
        try? await docker.remove(pgID, force: true)

        // Another worktree's stack couldn't get 58080: who has it, and the way out.
        let other = scratch.appendingPathComponent("ot-shop-2", isDirectory: true)
        try? FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let clash = fake.add(
            name: "ot-shop-2-web-1", image: "nginx:1.27", state: .created, project: "ot-shop-2", workingDir: FileTreeModel.realPath(other), service: "web")
        fake.set(clash, state: .created, error: "driver failed programming external connectivity: Bind for 0.0.0.0:58080 failed: port is already allocated")
        _ = await eventually(5) { docker.container(clash) != nil }
        page.selection = [clash]
        let holder = await eventually(5) {
            if case .container(let id, _, let project, _) = page.session?.conflict?.holder { return id == web && project == "ot-shop" }
            return false
        }
        check("a port taken by another worktree's stack says whose", holder, "\(String(describing: page.session?.conflict))")
        try? await docker.perform(.stop, on: web)
        page.act(.start, on: docker.container(clash).map { [$0] } ?? [])
        check(
            "stopping that one starts this one",
            await eventually(5) { docker.container(clash)?.state == .running && docker.container(web)?.state == .exited })
        try? await docker.remove(clash, force: true)
        try? await docker.perform(.start, on: web)
        _ = await eventually(5) { docker.container(web)?.state == .running }

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

        // The project's compose file, and what Compose makes of it, in the editor.
        let composeFile = URL(fileURLWithPath: real).appendingPathComponent("compose.yaml")
        try? "services:\n  web:\n    image: nginx:1.27\n    ports: [\"${WEB_PORT:-58080}:80\"]\n".write(to: composeFile, atomically: true, encoding: .utf8)
        if let project = docker.projects.first(where: { $0.name == "ot-shop" }) {
            page.editComposeFile(project)
            check(
                "a project's compose file opens in the editor",
                await eventually(5) { self.app.editor?.active?.url?.path == composeFile.path }, app.editor?.active?.url?.path ?? "nothing")
            if DockerCLI.locate("docker") != nil {
                page.showResolvedConfig(project)
                check(
                    "and what Compose makes of it",
                    await eventually(15) {
                        self.app.editor?.active?.url?.lastPathComponent == "ot-shop.resolved.yaml"
                            && self.app.editor?.textView?.string.contains("published: \"58080\"") == true
                    }, "\(page.error ?? "") \(app.editor?.textView?.string.prefix(300) ?? "")")
            }
        }
        page.editEngineConfig()
        check("an engine with no settings file of its own says so", page.error?.contains("keeps its settings elsewhere") == true, page.error ?? "")
        page.error = nil

        // A context picked for Overterm reconnects; this run's engine stays its own.
        Settings.shared.set("docker.context", .string("default"))
        check("picking a context reconnects", await eventually(5) { docker.connection.isRunning && docker.containers.count == 2 })
        Settings.shared.set("docker.context", nil)
        _ = await eventually(5) { docker.connection.isRunning }

        // A command really typed into a tab, out from under the page.
        let mark = scratch.appendingPathComponent("docker-command.txt")
        let tabs = app.store.tabs.count
        app.runDockerCommand("echo docker-e2e-$((40 + 2)) > '\(mark.path)'", in: folder)
        check("a command goes to a new tab", app.store.tabs.count == tabs + 1 && app.store.showingOverlay == nil)
        check(
            "which runs it in the project's folder",
            await eventually(8) { (try? String(contentsOf: mark, encoding: .utf8))?.contains("docker-e2e-42") == true }
                && app.store.selected?.workingDirectory == folder.path)

        // Its ports in the tab's pane headers, though Docker's process holds them.
        if let tab = app.store.selected {
            app.updateContainerPorts(of: tab)
            check("a checkout's container ports reach its tab", await eventually(5) { tab.containerPorts.map(\.port) == [58080] }, "\(tab.containerPorts)")
            check("and don't make it a server", tab.kind != .server)
        }

        // A checkout's container failing on its own marks the checkout's tab.
        if let projectTab = app.store.selected, let elsewhereTab = app.store.tabs.first(where: { $0 !== projectTab }) {
            projectTab.activity.seen()
            app.store.select(elsewhereTab)
            fake.set(web, state: .exited, exitCode: 2)
            check(
                "a checkout's container crashing marks its tab", await eventually(5) { projectTab.activity.mark == .failed },
                "\(projectTab.activity.mark)")
            check("saying which and how", projectTab.activity.note == "ot-shop-web-1 exited (2)", projectTab.activity.note ?? "")
            projectTab.activity.seen()
            fake.set(web, state: .running)
            _ = await eventually(5) { docker.container(web)?.state == .running }
            page.act(.stop, on: docker.container(web).map { [$0] } ?? [])
            _ = await eventually(5) { docker.container(web)?.state == .exited }
            await pause(0.3)
            check("a stop asked for doesn't", projectTab.activity.mark == .none, "\(projectTab.activity.note ?? "")")
            page.act(.start, on: docker.container(web).map { [$0] } ?? [])
            _ = await eventually(5) { docker.container(web)?.state == .running }
            app.store.select(projectTab)
        }

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
        await agentChecks(fake, web: web)
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
