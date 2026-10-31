import AppKit
import SwiftUI
import UniformTypeIdentifiers
import Vision

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
        check(
            "agents are offered Docker's tools", tools.contains("docker_logs") && tools.contains("docker_action") && tools.contains("docker_update"),
            "\(tools)")
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
        var memoryWhenAsked: Int?
        DockerMCP.askOverride = { question in
            asked = question
            memoryWhenAsked = fake.hostConfig(web)?.Memory
            return true
        }
        let updated = await call("docker_update", ["container": "ot-shop-web-1", "memory": "768m", "restart": "always"])
        let limits = fake.hostConfig(web)
        check(
            "docker_update changes its limits, asked first",
            !updated.isError && limits?.Memory == 768 << 20 && limits?.RestartPolicy?.Name == "always" && asked.contains("--memory 768m")
                && memoryWhenAsked != 768 << 20, "\(updated.text) | \(asked) | \(memoryWhenAsked ?? -1)")
        let tooSmall = await call("docker_update", ["container": "ot-shop-web-1", "memory": "1m"])
        check("and says what Docker would refuse", tooSmall.isError && tooSmall.text.contains("6m"), tooSmall.text)
        let exec = await call("docker_exec", ["container": "ot-shop-web-1", "command": "cat /etc/hostname"])
        check("docker_exec says the exit code", exec.text.hasPrefix("exit 127"), exec.text)
        // One service, rebuilt: in a tab, recorded here.
        let runInTab = DockerMCP.runInTab
        var typed: [String] = []
        DockerMCP.runInTab = { command, _ in typed.append(command) }
        let rebuilt = await call("docker_compose", ["project": "ot-shop", "action": "rebuild", "service": "web"])
        check(
            "docker_compose rebuilds one service, in a tab", !rebuilt.isError && typed.last?.hasSuffix(" up -d --build web") == true,
            "\(rebuilt.text) \(typed)")
        check("asked about with the service", asked.contains("compose rebuild") && asked.contains("(web)"), asked)
        let unknown = await call("docker_compose", ["project": "ot-shop", "action": "restart", "service": "nope"])
        check("and names the services there are", unknown.isError && unknown.text.contains("db, web"), unknown.text)
        DockerMCP.runInTab = runInTab

        Settings.shared.set("docker.agentWrites", .bool(false))
        let without = await listed()
        check(
            "with writes off, no write is offered",
            without.contains("docker_logs") && !without.contains("docker_action") && !without.contains("docker_update"), "\(without)")
        let refused = await call("docker_action", ["container": "ot-shop-web-1", "action": "stop"])
        check("nor done", refused.isError && refused.text.contains("Settings ▸ Docker") && fake.summary(web)?.state == .running, refused.text)
        Settings.shared.set("docker.agentWrites", nil)
        DockerMCP.askOverride = nil
    }

    /// The list's CPU and memory: each running container's, read while
    /// Containers shows and only then; a project's added up; sorted by
    /// either. web, db and ot-elsewhere run.
    private func usageChecks(_ fake: FakeDockerEngine, web: String, db: String, elsewhere: String) async {
        let page = app.dockerPage
        let docker = DockerModel.shared
        if app.store.showingOverlay != .docker { app.toggleDockerPage(nil) }
        page.section = .containers
        page.sort = .name
        func reads(_ id: String? = nil) -> Int {
            fake.requests.filter { request in request.contains("/stats?one-shot=true&stream=false") && (id.map { request.contains($0) } ?? true) }
                .count
        }
        func near(_ a: Double?, _ b: Double) -> Bool { abs((a ?? -1) - b) < 0.01 }
        fake.setUsage(web, cpuPercent: 40, memory: 32 << 20)
        fake.setUsage(db, cpuPercent: 12.5, memory: 96 << 20)
        fake.setUsage(elsewhere, cpuPercent: 90, memory: 8 << 20)
        let read = await eventually(5) {
            near(page.usage[web]?.cpuPercent, 40) && near(page.usage[db]?.cpuPercent, 12.5) && page.usage[db]?.memoryBytes == 96 << 20
                && near(page.usage[elsewhere]?.cpuPercent, 90)
        }
        check(
            "the list reads what each running container uses", read,
            page.usage.map { "\(docker.container($0.key)?.name ?? $0.key) \($0.value.cpuLabel) \($0.value.memoryLabel)" }.joined(separator: ", "))
        check("as one-shot reads", reads(web) > 0, fake.requests.filter { $0.contains("/stats") }.suffix(3).joined(separator: " | "))
        let shop = page.groups.first { $0.id == DockerPageModel.projectTag("ot-shop") }
        let summed = shop.flatMap { page.usage(of: $0) }
        check(
            "a project's row adds its containers up", near(summed?.cpuPercent, 52.5) && summed?.memoryBytes == 128 << 20,
            summed.map { "\($0.cpuLabel) \($0.memoryLabel)" } ?? "nothing")
        // The two blocks this run has; others (none read) would come after.
        func order() -> [String] { page.groups.map(\.id).filter { $0 == "loose" || $0 == DockerPageModel.projectTag("ot-shop") } }
        func shopOrder() -> [String] { page.groups.first { $0.id == DockerPageModel.projectTag("ot-shop") }?.containers.map(\.Id) ?? [] }
        // As the header's clicks change it.
        page.sort = page.sort.clicked(.cpu)
        check(
            "sorted by CPU, the busiest first", page.sort == .cpu && order() == ["loose", "project:ot-shop"] && shopOrder() == [web, db],
            "\(page.sort) \(page.groups.map(\.id)) \(shopOrder().compactMap { docker.container($0)?.name })")
        await capture("usage")
        page.sort = page.sort.clicked(.memory)
        check(
            "by memory, a project by what its containers add up to",
            page.sort == .memory && order() == ["project:ot-shop", "loose"] && shopOrder() == [db, web],
            "\(page.sort) \(page.groups.map(\.id)) \(shopOrder().compactMap { docker.container($0)?.name })")
        // From CPU, whose order isn't the names': clicked again, by name.
        page.sort = page.sort.clicked(.cpu)
        page.sort = page.sort.clicked(.cpu)
        check(
            "CPU clicked again sorts by name again", page.sort == .name && order() == ["project:ot-shop", "loose"] && shopOrder() == [db, web],
            "\(page.sort) \(page.groups.map(\.id)) \(shopOrder().compactMap { docker.container($0)?.name })")

        fake.set(elsewhere, state: .exited)
        check("a stopped container drops out", await eventually(5) { page.usage[elsewhere] == nil })
        await pause(0.4)
        let stoppedReads = reads(elsewhere)
        await pause(0.8)
        check("and isn't read", reads(elsewhere) == stoppedReads, "\(reads(elsewhere) - stoppedReads) more")
        fake.set(elsewhere, state: .running)
        _ = await eventually(5) { docker.container(elsewhere)?.state == .running }

        page.press("2")
        await pause(0.4)
        var count = reads()
        await pause(0.8)
        check(
            "another section stops the reads", reads() == count && page.usage.isEmpty && !docker.usage.isPolling,
            "\(reads() - count) more, \(page.usage.count) kept, polling \(docker.usage.isPolling)")
        page.press("1")
        check("Containers again reads them again", await eventually(5) { page.usage[web] != nil })
        // What the window says when it is under another app's, minimized
        // or hidden (an isolated run's window says nothing: it is set).
        page.windowVisible = false
        await pause(0.4)
        count = reads()
        await pause(0.8)
        check(
            "a window nobody can see reads nothing", reads() == count && page.usage.isEmpty && !docker.usage.isPolling,
            "\(reads() - count) more, \(page.usage.count) kept, polling \(docker.usage.isPolling)")
        page.windowVisible = true
        check("on screen again, it reads them again", await eventually(5) { page.usage[web] != nil })
        app.toggleDockerPage(nil)
        await pause(0.4)
        count = reads()
        await pause(0.8)
        check(
            "a hidden page reads nothing", app.store.showingOverlay != .docker && reads() == count && !docker.usage.isPolling,
            "\(reads() - count) more, polling \(docker.usage.isPolling)")
        app.toggleDockerPage(nil)
        _ = await eventually(3) { page.visible }
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
        let hub = await page.searchHub("redis")
        check("Docker Hub is searched through the engine", hub.first.map { $0.name == "redis" && $0.is_official == true } == true, "\(hub)")
        let searches = fake.requests.filter { $0.contains("/images/search") }.count
        let registry = await page.searchHub("ghcr.io/ot/private")
        check(
            "a registry's name never goes to Docker Hub",
            registry.isEmpty && fake.requests.filter { $0.contains("/images/search") }.count == searches, "\(fake.requests.suffix(3))")
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

        // Export and import: a volume through a helper that never runs, a
        // container's filesystem, an image.
        fake.setVolumeFile("ot-old-data", "data.txt", Data("kept\n".utf8))
        let volumeTar = scratch.appendingPathComponent("ot-old-data.tar")
        if let volume = docker.volumes.first(where: { $0.Name == "ot-old-data" }) { page.exportVolume(volume, to: volumeTar) }
        check(
            "a volume exports as a tar",
            await eventually(5) { DockerTar.entries(of: (try? Data(contentsOf: volumeTar)) ?? Data()).contains { $0.name == "volume/data.txt" } },
            page.error ?? "")
        page.importVolume("ot-imported", from: volumeTar)
        check("and imports into a new volume", await eventually(5) { fake.volumeContents("ot-imported")["data.txt"] == Data("kept\n".utf8) }, page.error ?? "")
        if let volume = docker.volumes.first(where: { $0.Name == "ot-old-data" }) { page.cloneVolume(volume, as: "ot-clone") }
        check("a clone has its files", await eventually(5) { fake.volumeContents("ot-clone")["data.txt"] == Data("kept\n".utf8) }, page.error ?? "")
        let containerTar = scratch.appendingPathComponent("web.tar")
        if let container = docker.containers.first(where: { $0.name == "ot-shop-web-1" }) { page.exportContainer(container, to: containerTar) }
        check(
            "a container's filesystem exports",
            await eventually(5) { DockerTar.entries(of: (try? Data(contentsOf: containerTar)) ?? Data()).contains { $0.name == "etc/nginx/nginx.conf" } })
        let imageTar = scratch.appendingPathComponent("image.tar")
        if let image = docker.images.first { page.saveImage(image, to: imageTar) }
        check("an image saves", await eventually(5) { ((try? Data(contentsOf: imageTar))?.count ?? 0) > 0 })
        // Labelled, and never listed: the fake's own list says.
        check("its helpers are gone", await eventually(5) { fake.helperIDs.isEmpty }, "\(fake.helperIDs)")
        page.cleaned = nil

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
        // Docker Scout sends an image's packages away: only asked, in a tab.
        var scouted: [String] = []
        let actions = page.actions
        page.actions?.run = { command, _ in scouted.append(command) }
        page.scout("cves", "redis:7")
        page.actions = actions
        check("Scout on an image is a tab's command", scouted.last?.hasSuffix("docker scout cves redis:7") == true, scouted.last ?? "nothing")
        page.press("1")
        check("1 is Containers again", page.section == .containers)
    }

    /// Builds, as a stub `docker` answers `buildx history`: a recorded one
    /// replayed from its record, then one started elsewhere listed and
    /// followed while it runs — let go while the page is hidden, read from
    /// its start when it shows again — until its step fails.
    private func buildsChecks() async {
        let page = app.dockerPage
        let dir = scratch.appendingPathComponent("builds-stub", isDirectory: true)
        let context = scratch.appendingPathComponent("build-context", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: context, withIntermediateDirectories: true)
        try? "FROM nginx:1.27\n".write(to: context.appendingPathComponent("Dockerfile"), atomically: true, encoding: .utf8)
        let stamps = ISO8601DateFormatter()
        stamps.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func json(_ object: Any) -> String { String(decoding: (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data(), as: UTF8.self) }
        // BuildKit's rawjson: one SolveStatus a line, its bytes base64.
        func solveStatus(vertexes: [[String: Any]] = [], logs: [[String: Any]] = []) -> String {
            var status: [String: Any] = [:]
            if !vertexes.isEmpty { status["vertexes"] = vertexes }
            if !logs.isEmpty { status["logs"] = logs }
            return json(status)
        }
        func vertex(_ digest: String, _ name: String, started: Date, completed: Date? = nil, cached: Bool = false, error: String? = nil) -> [String: Any] {
            var vertex: [String: Any] = ["digest": "sha256:" + digest, "name": name, "started": stamps.string(from: started)]
            if let completed { vertex["completed"] = stamps.string(from: completed) }
            if cached { vertex["cached"] = true }
            if let error { vertex["error"] = error }
            return vertex
        }
        func log(_ digest: String, _ text: String, stream: Int = 1, at: Date) -> [String: Any] {
            ["vertex": "sha256:" + digest, "stream": stream, "data": Data(text.utf8).base64EncodedString(), "timestamp": stamps.string(from: at)]
        }
        func write(_ text: String, _ name: String) { try? text.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8) }
        let t0 = Date()
        func at(_ seconds: Double) -> Date { t0.addingTimeInterval(seconds) }
        write(
            [
                solveStatus(vertexes: [vertex("b1", "[internal] load build definition from Dockerfile", started: at(0), completed: at(0.02))]),
                solveStatus(vertexes: [vertex("b2", "[web 1/2] FROM docker.io/library/nginx:1.27", started: at(0.1), completed: at(0.1), cached: true)]),
                solveStatus(vertexes: [vertex("b3", "[web 2/2] RUN make", started: at(0.2))]),
                solveStatus(logs: [log("b3", "built\n", at: at(1))]),
                solveStatus(vertexes: [vertex("b3", "[web 2/2] RUN make", started: at(0.2), completed: at(1.2))]),
            ].joined(separator: "\n") + "\n", "abc123.jsonl")
        let failure = #"process "/bin/sh -c echo $NPM_TOKEN > .npmrc && make" did not complete successfully: exit code: 2"#
        let make = "[worker 2/2] RUN echo npm-secret > .npmrc && make"
        write(
            [
                solveStatus(vertexes: [vertex("r1", "[internal] load build definition from Dockerfile", started: at(0), completed: at(0.02))]),
                solveStatus(vertexes: [vertex("r2", "[worker 1/2] FROM docker.io/library/alpine:3.20", started: at(0.1), completed: at(0.1), cached: true)]),
                solveStatus(vertexes: [vertex("r3", "[deps 1/1] RUN go mod download", started: at(0.2)), vertex("r4", make, started: at(0.2))]),
                solveStatus(logs: [log("r4", "cc -o worker main.c\n", at: at(0.5))]),
            ].joined(separator: "\n") + "\n", "run789-1.jsonl")
        write(
            [
                solveStatus(logs: [log("r4", "make: *** [Makefile:2: worker] Error 1\n", stream: 2, at: at(1))]),
                solveStatus(vertexes: [vertex("r4", make, started: at(0.2), completed: at(1.1), error: failure)]),
                solveStatus(vertexes: [vertex("r3", "[deps 1/1] RUN go mod download", started: at(0.2), completed: at(1.1), error: "context canceled")]),
            ].joined(separator: "\n") + "\n", "run789-2.jsonl")
        let inspect: [String: Any] = ["Context": context.path, "Dockerfile": "Dockerfile", "BuildArgs": [["Name": "NPM_TOKEN", "Value": "npm-secret"]]]
        write(json(inspect.merging(["VCSRevision": "4264981635"]) { a, _ in a }), "abc123-inspect.json")
        write(json(inspect.merging(["Status": "running"]) { a, _ in a }), "run789-running.json")
        let excerpt = "Dockerfile:4\n--------------------\n   3 |     FROM alpine:3.20 AS worker\n   4 | >>> RUN echo $NPM_TOKEN > .npmrc && make\n--------------------\n"
        let error: [String: Any] = ["Code": 2, "Message": failure, "Name": make, "Sources": Data(excerpt.utf8).base64EncodedString()]
        write(json(inspect.merging(["Status": "failed", "Error": error]) { a, _ in a }), "run789-failed.json")
        let now = stamps.string(from: t0)
        let worker: [String: Any] = [
            "name": "shop/worker", "ref": "default/default/run789", "created_at": now, "total_steps": 4, "completed_steps": 2, "cached_steps": 1,
        ]
        write(json(worker.merging(["status": "Running"]) { a, _ in a }), "worker-running.json")
        write(json(worker.merging(["status": "Error", "completed_at": stamps.string(from: at(2))]) { a, _ in a }), "worker-failed.json")
        write(
            #"{"cached_steps":2,"completed_at":"2026-10-28T10:00:07Z","completed_steps":5,"created_at":"2026-10-28T10:00:00Z","name":"shop/web","ref":"default/default/abc123","status":"Completed","total_steps":5}"#,
            "web.json")
        write(
            #"{"cached_steps":0,"completed_at":"2026-10-28T09:00:03Z","completed_steps":2,"created_at":"2026-10-28T09:00:00Z","name":"shop/api","ref":"default/default/def456","status":"Error","total_steps":4}"#,
            "api.json")
        // Every payload through cat: no shell quoting.
        let script = """
            #!/bin/sh
            dir="$(dirname "$0")"
            case "$*" in
              "buildx history ls --format json")
                echo >> "$dir/ls.count"
                if [ -f "$dir/done" ]; then cat "$dir/worker-failed.json"; echo; elif [ -f "$dir/started" ]; then cat "$dir/worker-running.json"; echo; fi
                [ -f "$dir/removed" ] || { cat "$dir/web.json"; echo; }
                cat "$dir/api.json"; echo ;;
              "buildx history inspect abc123 --format json") cat "$dir/abc123-inspect.json" ;;
              "buildx history inspect run789 --format json") if [ -f "$dir/done" ]; then cat "$dir/run789-failed.json"; else cat "$dir/run789-running.json"; fi ;;
              "buildx history logs --progress rawjson abc123") cat "$dir/abc123.jsonl" >&2 ;;
              "buildx history logs --progress rawjson run789")
                echo $$ > "$dir/follower.pid"; cat "$dir/run789-1.jsonl" >&2
                n=0; while [ ! -f "$dir/finish" ] && [ $n -lt 300 ]; do sleep 0.1; n=$((n+1)); done
                cat "$dir/run789-2.jsonl" >&2; touch "$dir/done" ;;
              "buildx history rm abc123") touch "$dir/removed" ;;
              *) echo "unexpected: $*" >&2; exit 1 ;;
            esac
            """
        let stub = dir.appendingPathComponent("docker")
        write(script, "docker")
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        func touch(_ name: String) { FileManager.default.createFile(atPath: dir.appendingPathComponent(name).path, contents: Data()) }
        func file(_ name: String) -> String { (try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)) ?? "" }
        func reads() -> Int { file("ls.count").filter { $0 == "\n" }.count }
        func follower() -> Int32? { Int32(file("follower.pid").trimmingCharacters(in: .whitespacesAndNewlines)) }
        func logText() -> String { Self.find(NSTextView.self, in: app.dockerView) { $0.accessibilityIdentifier() == "docker.text" }?.string ?? "" }
        func numbers() -> [Int] { page.buildSession?.progress.steps.map(\.number) ?? [] }
        func step(_ number: Int) -> DockerBuildProgress.Step? { page.buildSession?.progress.steps.first { $0.number == number } }
        func state(_ number: Int) -> DockerBuildProgress.Step.State? { step(number).flatMap { page.buildSession?.progress.state(of: $0) } }

        DockerCLI.override = stub
        page.buildPoll = 0.5
        var commands: [String] = []
        var copied: [String] = []
        let actions = page.actions
        page.actions?.run = { command, _ in commands.append(command) }
        page.actions?.copy = { copied.append($0) }
        page.showDetail = true
        defer {
            page.actions = actions
            page.buildPoll = nil
            DockerCLI.override = nil
        }

        page.press("5")
        check("5 is Builds, as buildx history keeps them", await eventually(5) { page.builds.map(\.name) == ["shop/web", "shop/api"] }, page.buildsError ?? "\(page.builds)")
        guard let recorded = page.builds.first else { return }
        page.buildSelection = [recorded.id]
        check(
            "a recorded build's steps are replayed from its record", await eventually(5) { page.buildSession?.state == .ended && numbers() == [1, 2, 3] },
            "\(String(describing: page.buildSession?.state)) \(numbers())")
        check("a cached step says so", state(2) == .cached, "\(String(describing: state(2)))")
        check(
            "the step with output is shown, its output in the text",
            await eventually(3) { page.buildSession?.shownStep?.number == 3 && logText().contains("built") }, logText())
        check(
            "a build's detail masks its secrets",
            await eventually(3) { page.buildSession?.detail?.buildArgs.first.map { $0.key == "NPM_TOKEN" && $0.value == "••••••" } == true })
        check("and finds its Dockerfile", page.buildSession?.detail?.dockerfileURL?.lastPathComponent == "Dockerfile")

        page.buildSelection = []
        touch("started")
        check(
            "a build started elsewhere is listed within a poll, first",
            await eventually(5) { page.builds.first.map { $0.name == "shop/worker" && $0.running } == true }, "\(page.builds.map(\.name))")
        let running = page.builds.first
        check("and selected, since nothing was", await eventually(3) { page.buildSelection == Set([running?.id].compactMap { $0 }) }, "\(page.buildSelection)")
        check(
            "its steps come as BuildKit sends them", await eventually(5) { numbers() == [1, 2, 3, 4] && page.buildSession?.state == .reading },
            "\(numbers()) \(String(describing: page.buildSession?.state))")
        check("two run at once", [3, 4].allSatisfy { state($0) == .running }, "\(String(describing: state(3))) \(String(describing: state(4)))")
        check(
            "the running one with output is shown, as it writes",
            await eventually(3) { page.buildSession?.shownStep?.number == 4 && logText().contains("cc -o worker main.c") }, logText())
        check(
            "a secret build arg's value is out of a step's name",
            await eventually(3) {
                let name = page.buildSession.flatMap { session in step(4).map { session.shown($0.name) } } ?? ""
                return name.contains("••••••") && !name.contains("npm-secret")
            })
        if let running {
            let removal = page.verbs(for: running).first { $0.place == .remove }
            check("its removal waits for it to end", removal?.unavailable == "It's still running.", removal?.unavailable ?? "available")
        }
        // The steps are a table too, but not the list: ⌫ there would remove
        // the build.
        let list = Self.find(NSTableView.self, in: app.dockerView) { _ in true }
        if let steps = Self.find(NSTableView.self, in: app.dockerView, where: { $0 !== list }) {
            window.makeFirstResponder(steps)
            check("the steps' table doesn't take the list's keys", window.firstResponder === steps && !app.dockerListHasKeyboard())
            app.focusDockerList()
            check("the list does", await eventually(2) { self.app.dockerListHasKeyboard() })
        } else {
            check("the steps are a table", false)
        }
        page.press("t")
        check("t follows its log in a tab, as plain progress", commands.last?.hasSuffix("docker buildx history logs run789") == true, commands.last ?? "nothing")
        await capture("build")

        let first = follower()
        app.toggleDockerPage(nil)
        check(
            "a hidden page lets the build go",
            await eventually(3) { first.map { kill($0, 0) != 0 } == true && page.buildSession?.state == .stopped },
            "pid \(String(describing: first)), \(String(describing: page.buildSession?.state))")
        let before = reads()
        await pause(1.5)
        check("and reads no more builds", reads() == before, "\(before) → \(reads())")
        app.toggleDockerPage(nil)
        check(
            "shown again, it is followed from the start, nothing twice",
            await eventually(5) { follower() != nil && follower() != first && numbers() == [1, 2, 3, 4] && page.buildSession?.state == .reading },
            "\(numbers()) \(String(describing: page.buildSession?.state))")
        check(
            "its output once", await eventually(3) { step(4)?.log.map(\.text) == ["cc -o worker main.c"] },
            "\(step(4)?.log.map(\.text) ?? [])")
        check(
            "and once in the text", await eventually(3) { logText().components(separatedBy: "cc -o worker main.c").count == 2 }, logText())

        touch("finish")
        check(
            "a failed step is red, with BuildKit's error",
            await eventually(5) { state(4) == .failed && step(4)?.error?.contains("exit code: 2") == true }, "\(String(describing: state(4)))")
        check("the one beside it was canceled", state(3) == .canceled, "\(String(describing: state(3)))")
        check(
            "the failed step is the one shown", await eventually(3) { page.buildSession?.shownStep?.number == 4 && logText().contains("Error 1") }, logText())
        check("the list says it failed", await eventually(3) { page.builds.first?.failed == true }, "\(page.builds.map(\.status))")
        check(
            "with where in the Dockerfile", await eventually(3) { page.buildSession?.detail?.errorSource?.contains(">>> RUN") == true },
            page.buildSession?.detail?.errorSource ?? "none")
        if let build = page.detailedBuild { page.verbs(for: build).first { $0.title == "Copy Log" }?.perform() }
        let log = copied.last ?? ""
        check(
            "Copy Log copies the steps as plain progress, secrets out",
            ["#4 ERROR:", "#2 CACHED", "#3 CANCELED"].allSatisfy(log.contains) && !log.contains("npm-secret"), log)
        var asked: [String] = []
        page.actions?.confirm = { title, _, _, then in
            asked.append(title)
            then()
        }
        page.buildSelection = [recorded.id]
        page.press("\u{7F}")
        check("⌫ asks before a record goes", asked == ["Remove the record of “shop/web”?"], "\(asked)")
        check("a record goes", await eventually(5) { !page.builds.map(\.name).contains("shop/web") }, "\(page.builds.map(\.name))")

        page.buildSelection = []
        page.press("1")
        DockerCLI.override = nil
        check("an isolated run reads builds only from a stub", page.buildsCLI == nil)
    }

    /// Each detail's verbs — the list its right-click menu draws too — do
    /// what they say: a volume browsed, an image tagged, a container put on
    /// a network and taken off it, the panel's container restarted as the
    /// panel.
    private func verbsChecks(_ fake: FakeDockerEngine, web: String) async {
        let page = app.dockerPage
        let docker = DockerModel.shared
        var commands: [String] = []
        let actions = page.actions
        page.actions?.run = { command, _ in commands.append(command) }
        page.actions?.askName = { _, _, _, then in then("ot/tagged:2") }
        defer { page.actions = actions }
        func titles(_ verbs: [DockerVerb], _ place: DockerVerb.Place) -> [String] { verbs.filter { $0.place == place }.map(\.title) }
        page.showDetail = true

        // A volume: the used verbs as buttons, the rest behind More.
        page.press("3")
        guard let volume = docker.volumes.first(where: { $0.Name == "ot-old-data" }) else { return check("a volume to act on", false) }
        page.volumeSelection = [volume.Name]
        let volumeVerbs = page.verbs(for: volume)
        check(
            "a volume's detail has its verbs as buttons", titles(volumeVerbs, .button) == ["Browse Files", "Export…", "Clone…"],
            "\(titles(volumeVerbs, .button))")
        check(
            "the rest behind More",
            titles(volumeVerbs, .more) == ["Open a Shell on It in a Tab", "Import Into a New Volume…", "Copy Name", "Copy Mountpoint"],
            "\(titles(volumeVerbs, .more))")
        check("and removal last", titles(volumeVerbs, .remove) == ["Remove…"])
        volumeVerbs.first { $0.title == "Open a Shell on It in a Tab" }?.perform()
        check("a shell on it opens in a tab", commands.last?.contains("-v ot-old-data:/volume") == true, commands.last ?? "nothing")
        await capture("volume")

        // An image: Tag… asks for the name.
        page.press("2")
        if let image = docker.images.first(where: { $0.tags.contains("debian:bookworm-slim") }) {
            page.imageSelection = [image.Id]
            page.verbs(for: image).first { $0.title == "Tag…" }?.perform()
            check(
                "an image's Tag… adds the name asked for",
                await eventually(5) { docker.images.first { $0.Id == image.Id }?.tags.contains("ot/tagged:2") == true },
                "\(docker.images.map(\.tags))")
        }

        // A network: a container put on it from its detail, then taken off.
        fake.addNetwork("ot-net")
        page.press("4")
        docker.load(.networks)
        guard await eventually(5, { docker.networks.contains { $0.Name == "ot-net" } }),
            let network = docker.networks.first(where: { $0.Name == "ot-net" }), let container = docker.container(web)
        else { return check("a network to act on", false) }
        page.networkSelection = [network.Id]
        let connect = page.verbs(for: network).first { $0.title == "Connect a Container" }
        check("Connect lists the containers not on it", connect?.children.map(\.title).contains(container.name) == true, "\(connect?.children.map(\.title) ?? [])")
        connect?.children.first { $0.title == container.name }?.perform()
        func members() -> [String] { docker.networks.first { $0.Name == "ot-net" }.map { docker.containers(on: $0).map(\.name) } ?? [] }
        check("connects one", await eventually(5) { members() == [container.name] }, "\(members()) \(page.error ?? "")")
        let removal = docker.networks.first { $0.Name == "ot-net" }.flatMap { page.verbs(for: $0).first { $0.place == .remove } }
        check("a network in use can't be removed, and says why", removal?.unavailable == "\(container.name) is on it.", removal?.unavailable ?? "available")
        await capture("network")
        if let network = docker.networks.first(where: { $0.Name == "ot-net" }) { page.disconnect(container, from: network) }
        check("and Disconnect takes it off", await eventually(5) { members().isEmpty }, "\(members())")

        // The panel: the page's verbs, acting as the panel.
        let panelVerbs = app.dockerPanel.verbs(container)
        check("the panel's verbs are the page's", panelVerbs.map(\.title) == page.verbs(for: container).map(\.title))
        panelVerbs.first { $0.title == "Restart" }?.perform()
        check("and act through it", await eventually(5) { fake.requests.contains { $0.contains("/containers/\(container.Id)/restart") } })
        page.press("1")
    }

    /// Docker Scout's Vulnerabilities tab, as a stub `docker` plays Scout:
    /// nothing runs in an isolated run without the stub, nor for `v`; Scan
    /// asks Scout for SARIF of the engine's own copy, for the image's
    /// platform, on the page's engine; its progress shows, then its CVEs by
    /// severity, each with its package, the version here and the fix, and
    /// the filters narrow them; signed out is said, with `docker login` in
    /// a tab; agents read the user's scan and never start one.
    private func scoutChecks(_ fake: FakeDockerEngine) async {
        let page = app.dockerPage
        let docker = DockerModel.shared
        let scans = page.scans
        let scanned = fake.addImage("ot/scanned:1", size: 20 << 20)
        let locked = fake.addImage("ot/private:1", size: 5 << 20)
        var commands: [String] = []
        let actions = page.actions
        let hadScout = page.hasScout
        let imageTab = page.imageTab
        let filter = page.scoutFilter
        let selection = page.selection
        let override = DockerCLI.override
        page.actions?.run = { command, _ in commands.append(command) }
        page.hasScout = true
        page.scoutFilter = DockerScoutFilter()
        defer {
            page.actions = actions
            page.hasScout = hadScout
            page.imageTab = imageTab
            page.scoutFilter = filter
            page.selection = selection
            DockerCLI.override = override
            scans.forget(scanned)
            scans.forget(locked)
        }
        func state(_ id: String) -> DockerScoutScans.State? { scans.scan(for: id)?.state }
        func described(_ id: String) -> String { scans.scan(for: id).map { "\($0.state)" } ?? "no scan" }
        func drawn(_ name: String, _ line: (text: String, frame: CGRect)?) async {
            var detail = line?.text ?? ""
            if line == nil { detail = await readWindow().map(\.text).joined(separator: " | ") }
            check(name, line != nil, detail)
        }
        if app.store.showingOverlay != .docker { app.showOverlay(.docker) }
        page.press("2")
        docker.load(.images)
        guard await eventually(5, { [scanned, locked].allSatisfy { id in docker.images.contains { $0.Id == id } } }),
            let image = docker.images.first(where: { $0.Id == scanned }), let privateImage = docker.images.first(where: { $0.Id == locked })
        else { return check("images to scan", false, "\(docker.images.map(\.tags))") }

        DockerCLI.override = nil
        page.scanVulnerabilities(image)
        var isolated = false
        if case .failed(.isolated, _) = state(scanned) { isolated = true }
        check("no Scout in an isolated run without a stub", isolated, described(scanned))
        scans.forget(scanned)

        // Scout, as a stub plays it: its progress on stderr, SARIF on stdout.
        let bin = scratch.appendingPathComponent("scout-stub-bin", isDirectory: true)
        try? FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let stub = bin.appendingPathComponent("docker")
        let script = """
            #!/bin/sh
            dir="$(dirname "$0")"
            echo "$DOCKER_HOST|$*" >> "$dir/calls"
            case "$*" in
              "scout cves --format sarif"*" local://ot/scanned:1")
                echo '    ✓ SBOM of image already cached, 3 packages indexed' >&2; sleep 1
                echo '    ✗ Detected 4 vulnerable packages with a total of 4 vulnerabilities' >&2
                cat "$dir/report.sarif.json" ;;
              "scout cves --format sarif"*" local://ot/private:1")
                echo 'Log in with your Docker ID or email address to use docker scout.' >&2; exit 1 ;;
              *) echo "unexpected: $*" >&2; exit 1 ;;
            esac
            """
        try? FakeDockerEngine.scoutReport.write(to: bin.appendingPathComponent("report.sarif.json"), atomically: true, encoding: .utf8)
        try? script.write(to: stub, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        func calls() -> [String] {
            ((try? String(contentsOf: bin.appendingPathComponent("calls"), encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        }
        DockerCLI.override = stub

        page.imageSelection = [scanned]
        page.imageTab = .overview
        page.press("v")
        check(
            "v opens an image's Vulnerabilities, scanning nothing",
            page.showDetail && page.imageTab == .vulnerabilities && scans.scan(for: scanned) == nil && calls().isEmpty, described(scanned))
        // Return, out of habit (↩ is Logs in Containers), as AppKit routes
        // it: the page's key monitor, then the window's key equivalents. A
        // scan takes its button — nothing there is the default one.
        let intro = await shownText { $0.contains("In a Tab") }
        _ = await eventually(5) {
            if !self.app.dockerListHasKeyboard() { self.app.focusDockerList() }
            return self.app.dockerListHasKeyboard()
        }
        if let returnKey = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36), !app.handleDockerKey(returnKey)
        {
            _ = window.performKeyEquivalent(with: returnKey)
        }
        await pause(0.5)
        check(
            "and Return there scans nothing", intro != nil && app.dockerListHasKeyboard() && scans.scan(for: scanned) == nil && calls().isEmpty,
            "\(intro?.text ?? "no intro drawn") \(described(scanned)) \(calls())")
        scans.forget(scanned)
        // A container's `v`: its image's tab.
        let user = fake.add(name: "ot-scanned-user", image: "ot/scanned:1", imageID: scanned)
        page.press("1")
        if await eventually(5, { docker.container(user) != nil }) {
            page.selection = [user]
            page.imageTab = .overview
            page.press("v")
            check(
                "on a container, v goes to its image's",
                page.section == .images && page.imageSelection == [scanned] && page.imageTab == .vulnerabilities && scans.scan(for: scanned) == nil,
                "\(page.section) \(page.imageSelection)")
        } else {
            check("a container of the image", false)
        }
        try? await docker.remove(user, force: true)
        page.press("2")
        page.imageSelection = [scanned]

        let scout = page.verbs(for: image).first { $0.title == "Docker Scout" }
        check(
            "Scan for Vulnerabilities is in its Docker Scout menu", scout?.children.first?.title == "Scan for Vulnerabilities",
            "\(scout?.children.map(\.title) ?? [])")
        scout?.children.first?.perform()
        let progressed = await eventually(5) {
            if case .scanning(_, let progress) = state(scanned) { return progress == "SBOM of image already cached, 3 packages indexed" }
            return false
        }
        check("a scan says how far Scout has got", progressed, described(scanned))
        check(
            "and its verb waits for it",
            page.verbs(for: image).first { $0.title == "Docker Scout" }?.children.first?.unavailable == "Scanning…")
        let finished = await eventually(10) { state(scanned)?.report != nil }
        check(
            "as SARIF, of the engine's own copy, for its platform, on the page's engine",
            calls() == ["unix://\(fake.socket)|scout cves --format sarif --platform linux/arm64 local://ot/scanned:1"], "\(calls())")
        let report = state(scanned)?.report
        let findings = report?.findings ?? []
        check(
            "its CVEs by severity, the worst first", finished && page.scoutFilter.groups(findings).map(\.severity) == [.critical, .high, .medium, .low],
            described(scanned))
        let openssl = findings.first { $0.severity == .critical }
        let zlib = findings.first { $0.package.name == "zlib" }
        check(
            "each with its package, the version here and the fix",
            openssl?.package.displayName == "openssl" && openssl?.package.version == "3.0.11-1~deb12u1" && openssl?.fixedIn == "3.0.13-1~deb12u1"
                && openssl?.advisory?.host == "scout.docker.com" && zlib?.fixedIn == nil && zlib?.package.version == "1:1.2.13.dfsg-1",
            "\(String(describing: openssl)) \(String(describing: zlib))")
        check("and how many packages Scout indexed", report?.packagesIndexed == 3, "\(String(describing: report?.packagesIndexed))")
        page.showDetail = false
        await drawn("the image's row says what a scan found", await shownText { $0.contains("1C 1H 1M 1L") })
        page.showDetail = true
        page.imageTab = .vulnerabilities
        await drawn("the tab lists them, by CVE", await shownText { $0.contains("2024-0727") })
        await capture("vulnerabilities")
        // The filters, clicked as a person would: what they leave is what
        // is drawn. zlib's high CVE has no fix; openssl's critical one has.
        func lists(_ kept: String, not left: String) async -> Bool {
            let deadline = Date().addingTimeInterval(5)
            repeat {
                let lines = await readWindow().map(\.text)
                if lines.contains(where: { $0.contains(kept) }), !lines.contains(where: { $0.contains(left) }) { return true }
                await pause(0.3)
            } while Date() < deadline
            return false
        }
        let unfixed = await shownText { $0.contains("2023-45853") }
        let fixableBox = await shownText { $0.contains("Fixable only") }
        if let fixableBox { await click(at: CGPoint(x: fixableBox.frame.midX, y: fixableBox.frame.midY)) }
        let onlyFixable = await lists("2024-0727", not: "2023-45853")
        check(
            "Fixable only leaves out what has no fix", unfixed != nil && page.scoutFilter.fixableOnly && onlyFixable,
            "\(fixableBox?.text ?? "no checkbox read") \(page.scoutFilter)")
        page.scoutFilter = DockerScoutFilter()
        _ = await shownText { $0.contains("2023-45853") }
        let highChip = await wordFrame("High")
        if let highChip { await click(at: CGPoint(x: highChip.midX, y: highChip.midY)) }
        let withoutHigh = await lists("2024-0727", not: "2023-45853")
        check(
            "a severity can be left out",
            !page.scoutFilter.severities.contains(.high) && page.scoutFilter.severities.contains(.critical) && withoutHigh,
            "\(highChip.map { "\($0)" } ?? "no chip read") \(page.scoutFilter)")
        page.scoutFilter = DockerScoutFilter()

        page.scanVulnerabilities(privateImage)
        let signedOut = await eventually(5) {
            if case .failed(.signedOut, _) = state(locked) { return true }
            return false
        }
        check("signed out, it says so", signedOut, described(locked))
        await drawn("in so many words", await shownText { $0.contains("signed in to Docker") })
        page.signInToDocker()
        check("and signs in in a tab", commands.last == "docker login", commands.last ?? "nothing")

        func told(_ image: String) async -> String {
            let result = try? await DockerMCP.call("docker_vulnerabilities", ["image": image], docker: docker)
            return ((result?["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        }
        let read = await told("ot/scanned:1")
        check("agents read the user's scan", read.contains("CVE-2024-0727 critical") && read.contains("fixed in 3.0.13-1~deb12u1"), read)
        let unscanned = await told("debian:bookworm-slim")
        check("and never start one", unscanned.contains("hasn't been scanned") && calls().count == 2, unscanned + " \(calls())")

        for id in [scanned, locked] { try? await docker.engine?.remove(image: id, force: true) }
        docker.load(.images)
        page.press("1")
    }

    /// Check for Updates: each image's registry asked once, only when asked,
    /// through a stub `docker` answering as buildx would — a newer digest an
    /// update, the same one current, a registry wanting credentials said so,
    /// an image built here never asked. Pull Updates pulls Docker Hub's
    /// through the engine with no second question, another registry's in a
    /// tab; a project's runs compose pull in a tab, and a pull made there is
    /// seen as the engine says it — which, once a tag moves, lists a
    /// container by its image's ID. Agents read the answers.
    private func imageUpdatesChecks(_ fake: FakeDockerEngine) async {
        let page = app.dockerPage
        let docker = DockerModel.shared
        let updates = page.updates
        var commands: [(command: String, folder: URL?)] = []
        let actions = page.actions
        page.actions?.run = { commands.append(($0, $1)) }
        let web = docker.container("ot-shop-web-1")
        let db = docker.container("ot-shop-db-1")
        fake.refreshesImages = true
        defer {
            page.actions = actions
            DockerCLI.override = nil
            updates.forget()
            fake.refreshesImages = false
            for container in [web, db].compactMap({ $0 }) { fake.setImageID(container.Id, container.ImageID ?? "") }
        }
        func digest(_ character: Character) -> String { "sha256:" + String(repeating: character, count: 64) }
        /// A check of what is drawn: failed, what the window shows.
        func drawn(_ name: String, _ line: (text: String, frame: CGRect)?) async {
            var detail = line?.text ?? ""
            if line == nil { detail = await readWindow().map(\.text).joined(separator: " | ") }
            check(name, line != nil, detail)
        }
        page.imageSelection = []
        let nginx = fake.addImage("nginx:1.27", size: 60 << 20, digest: digest("1"))
        let postgres = fake.addImage("postgres:16", size: 150 << 20, digest: digest("4"))
        let thing = fake.addImage("private/thing:1", size: 5 << 20, digest: digest("5"))
        let elsewhere = fake.addImage("ghcr.io/ot/app:1", size: 12 << 20, digest: digest("7"))
        let built = fake.addImage("ot/built:dev", size: 8 << 20)
        fake.setRegistryDigest("nginx:1.27", digest("2"))
        // The project's containers run the images they were made from.
        if let web { fake.setImageID(web.Id, nginx) }
        if let db { fake.setImageID(db.Id, postgres) }
        let bin = scratch.appendingPathComponent("updates-stub-bin", isDirectory: true)
        try? FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let stub = bin.appendingPathComponent("docker")
        let script = """
            #!/bin/sh
            dir="$(dirname "$0")"
            echo "$*" >> "$dir/calls"
            case "$*" in
              "buildx imagetools inspect nginx:1.27")
                printf 'Name:      docker.io/library/nginx:1.27\\nMediaType: application/vnd.oci.image.index.v1+json\\nDigest:    %s\\n           \\nManifests: \\n  Name:        docker.io/library/nginx:1.27@\(digest("6"))\\n  MediaType:   application/vnd.oci.image.manifest.v1+json\\n  Platform:    linux/arm64\\n' "$(cat "$dir/nginx-digest")" ;;
              "buildx imagetools inspect postgres:16")
                printf 'Name:      docker.io/library/postgres:16\\nMediaType: application/vnd.docker.distribution.manifest.v2+json\\nDigest:    \(digest("4"))\\n' ;;
              "buildx imagetools inspect ghcr.io/ot/app:1")
                printf 'Name:      ghcr.io/ot/app:1\\nMediaType: application/vnd.oci.image.manifest.v1+json\\nDigest:    \(digest("8"))\\n' ;;
              "buildx imagetools inspect private/thing:1")
                echo 'ERROR: failed to authorize: failed to fetch oauth token: unexpected status from GET request to https://auth.docker.io/token: 401 Unauthorized' >&2; exit 1 ;;
              *) echo "unexpected: $*" >&2; exit 1 ;;
            esac
            """
        try? script.write(to: stub, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        // Other reads go through the same stub (a project's files): only
        // the registries' questions are counted.
        func asked() -> [String] {
            ((try? String(contentsOf: bin.appendingPathComponent("calls"), encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
                .filter { $0.hasPrefix("buildx imagetools inspect ") }
        }
        func image(_ id: String) -> ImageSummary? { docker.images.first { $0.Id == id } }
        func shop() -> ComposeProject? { docker.projects.first { $0.name == "ot-shop" } }
        /// The chip's word, as Vision reads it ("(update )"): not the
        /// header's "2 updates", nor a button's "Update".
        func chip(_ text: String) -> Bool { text.contains("update") && !text.contains("updates") }

        page.press("2")
        guard await eventually(5, { [nginx, postgres, thing, elsewhere, built].allSatisfy { image($0) != nil } }) else {
            return check("images to check", false, "\(docker.images.map(\.tags))")
        }
        DockerCLI.override = nil
        page.checkUpdates(images: docker.images)
        check(
            "an isolated run asks no registry without a stub", await eventually(3) { page.error?.contains("asks no registry") == true } && updates.checks.isEmpty,
            page.error ?? "no error")
        page.error = nil
        try? digest("2").write(to: bin.appendingPathComponent("nginx-digest"), atomically: true, encoding: .utf8)
        DockerCLI.override = stub
        await pause(0.3)
        check("nothing is asked of a registry until asked", asked().isEmpty, "\(asked())")

        page.press("C")
        let ran = await eventually(10) { updates.lastRun != nil && !updates.running }
        check(
            "C asks each image's registry once — not what was built here",
            ran && asked().sorted() == ["ghcr.io/ot/app:1", "nginx:1.27", "postgres:16", "private/thing:1"].map { "buildx imagetools inspect " + $0 },
            "\(asked())")
        check("a newer digest in its registry is an update", updates.state(of: "nginx:1.27") == .available, "\(updates.state(of: "nginx:1.27"))")
        check("the same digest is current, a single manifest too", updates.state(of: "postgres:16") == .current, "\(updates.state(of: "postgres:16"))")
        let refused = updates.state(of: "private/thing:1")
        check("a registry that wants credentials says so", { if case .failed(let why) = refused { why.contains("docker login") } else { false } }(), "\(refused)")
        check("an image built here isn't asked", updates.state(of: "ot/built:dev") == .local)
        let headline = DockerImageUpdates.headline(updates.counts(of: docker.images))
        check("the header counts them", headline == "2 updates · 1 couldn't be checked", headline)
        await drawn("and draws it", await shownText { $0.contains("2 updates") && $0.contains("be checked") })
        check(
            "their rows are marked", Set(updates.images(withUpdates: docker.images).map(\.Id)) == [nginx, elsewhere],
            "\(updates.images(withUpdates: docker.images).map(\.tags))")
        await drawn("with a chip", await shownText(15, chip))
        check(
            "nothing pulled yet: Up recreates nothing", shop().map { updates.summary(of: $0).recreate.isEmpty } == true,
            "\(shop().map(updates.summary(of:)).map { "\($0)" } ?? "no project")")
        if let image = image(nginx) {
            let verbs = page.verbs(for: image)
            check(
                "its detail offers Pull Update as a button",
                verbs.contains { $0.title == "Pull Update" && $0.place == .button } && !verbs.contains { $0.title == "Pull Again" }, "\(verbs.map(\.title))")
        }
        if let image = image(elsewhere) {
            let verbs = page.verbs(for: image)
            check("another registry's in a tab, where docker signs in", verbs.contains { $0.title == "Pull Update in a Tab" }, "\(verbs.map(\.title))")
        }
        check(
            "the answers are kept with their time",
            updates.checks["docker.io/library/nginx:1.27"].map { abs($0.at.timeIntervalSinceNow) < 60 } == true && updates.lastRun != nil)
        page.imageSelection = [nginx]
        page.showDetail = true
        await drawn("its detail's Registry says it is newer", await shownText { $0.contains("Newer in its registry") })
        _ = docker.images.map { page.verbs(for: $0) }
        check("and reading them asks nothing", asked().count == 4, "\(asked())")
        await capture("updates")

        page.pullUpdates(images: docker.images)
        check(
            "Pull Updates pulls Docker Hub's through the engine, and it is current",
            await eventually(5) { page.pulls["nginx:1.27"]?.done == true && updates.state(of: "nginx:1.27") == .current },
            "\(page.pulls["nginx:1.27"]?.summary ?? "no pull") \(updates.state(of: "nginx:1.27"))")
        check(
            "and another registry's in a tab", commands.last.map { $0.command.hasSuffix("docker pull ghcr.io/ot/app:1") && $0.folder == nil } == true,
            "\(commands.last?.command ?? "nothing")")
        check(
            "the old image is left untagged, as Docker leaves it",
            await eventually(3) { docker.images.contains { $0.isDangling && $0.RepoDigests?.contains("nginx@" + digest("1")) == true } })
        check("with no second question to its registry", asked().count == 4, "\(asked())")
        check(
            "the project's container is listed by its image's ID now, as the engine lists it",
            await eventually(5) { docker.container("ot-shop-web-1").map { $0.Image == nginx } == true }, docker.container("ot-shop-web-1")?.Image ?? "none")
        check(
            "and the project says Up recreates web — what its services name was kept",
            shop().map { updates.summary(of: $0).recreate == ["web"] } == true, "\(shop().map(updates.summary(of:)).map { "\($0)" } ?? "no project")")
        page.dismissPull("nginx:1.27")
        page.imageSelection = []

        // A project's: its services' images, as its containers name them.
        try? digest("3").write(to: bin.appendingPathComponent("nginx-digest"), atomically: true, encoding: .utf8)
        fake.setRegistryDigest("nginx:1.27", digest("3"))
        page.press("1")
        page.selection = [DockerPageModel.projectTag("ot-shop")]
        page.showDetail = true
        let before = updates.lastRun
        page.press("C")
        let again = await eventually(10) { updates.lastRun != before && !updates.running }
        check(
            "C on a project asks of its services' images",
            again && asked().dropFirst(4).sorted() == ["buildx imagetools inspect nginx:1.27", "buildx imagetools inspect postgres:16"], "\(asked())")
        guard let project = shop() else { return check("a project to check", false) }
        let summary = updates.summary(of: project)
        check("the project says which service has one", summary.available.map(\.service) == ["web"], "\(summary)")
        await drawn("its row has a chip", await shownText(15, chip))
        await drawn("its detail says which", await shownText { $0.contains("Newer in the registry") })
        let pullVerb = page.verbs(for: project).first { $0.title == "Pull Updates in a Tab" }
        check("Pull Updates is a button on the project", pullVerb?.place == .button)
        pullVerb?.perform()
        check(
            "which is compose pull of that service, in its folder",
            await eventually(3) {
                commands.last.map { $0.command.contains("docker compose -p ot-shop -f ") && $0.command.hasSuffix(" pull web") } == true
            } && commands.last?.folder?.path == project.workingDir, "\(commands.last.map { "\($0.command) in \($0.folder?.path ?? "-")" } ?? "nothing")")
        if let engine = docker.engine {
            do { for try await _ in engine.pull("nginx:1.27") {} } catch { check("the tab's pull", false, "\(error)") }
        }
        check(
            "a pull made in a tab is seen without asking again",
            await eventually(5) { shop().map { updates.summary(of: $0).available.isEmpty } == true } && asked().count == 6, "\(asked())")
        let pulled = shop().map(updates.summary(of:))
        check(
            "and the project says Up recreates web alone — db runs its image",
            pulled?.recreate == ["web"] && pulled?.line { _ in "now" }?.contains("Up recreates web") == true, "\(String(describing: pulled))")
        await drawn("its detail says so", await shownText { $0.contains("Up recreates") })

        let message: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": "docker_image_updates", "arguments": [:]]]
        let answer = await BrowserMCP.handle(message, browser: { nil })
        let told = (((answer?["result"] as? [String: Any])?["content"] as? [[String: Any]])?.first?["text"] as? String) ?? "\(answer ?? [:])"
        check(
            "agents read what the check found", told.contains("nginx:1.27") && told.contains("private/thing:1") && told.contains("ot-shop/web") && asked().count == 6,
            told)

        await capture("updates-project")
        page.press("1")
        page.selection = []
        // Out of the later checks' way.
        for id in docker.images.filter({ image in
            image.tags.contains { ["nginx:1.27", "postgres:16", "private/thing:1", "ghcr.io/ot/app:1", "ot/built:dev"].contains($0) }
                || (image.isDangling && image.RepoDigests?.isEmpty == false)
        }).map(\.Id) {
            try? await docker.engine?.remove(image: id, force: true)
        }
        docker.load(.images)
    }

    /// A volume's Files tab: its folders listed through a helper that
    /// runs only while the tab shows — as root, without a network, out of
    /// every list — a file to the editor and saved back with its owner
    /// through a helper made for the call, a helper gone under it made
    /// again, and what is left at quit removed.
    private func volumeFilesChecks(_ fake: FakeDockerEngine) async {
        let page = app.dockerPage
        let docker = DockerModel.shared
        let volume = "ot-old-data"
        fake.setVolumeFile(volume, "conf/app.conf", Data("level = info\n".utf8), uid: 999, gid: 999)
        page.press("3")
        page.showDetail = true
        page.volumeSelection = [volume]
        page.volumeTab = .overview
        await pause(0.3)
        check("a volume's Overview makes no helper", fake.helperIDs.isEmpty, "\(fake.helperIDs)")
        page.press("f")
        check("f opens a volume's Files", page.volumeTab == .files)
        page.volumeTab = .overview
        if let summary = docker.volumes.first(where: { $0.Name == volume }) { page.verbs(for: summary).first { $0.title == "Browse Files" }?.perform() }
        check("and so does Browse Files", page.volumeTab == .files && page.section == .volumes && page.volumeSelection == [volume])
        func names() -> [String] { page.volumeFiles?.entries.map(\.name) ?? [] }
        check(
            "its top is listed through a helper that runs", await eventually(5) { names() == ["conf", "data.txt"] },
            "\(names()) \(page.volumeFiles?.filesError ?? "")")
        let helper = fake.helperIDs.first ?? ""
        let made = fake.created(helper)
        check(
            "one helper, running, as root, no network, removing itself",
            fake.helperIDs.count == 1 && fake.summary(helper)?.state == .running && made?.User == "0:0" && made?.HostConfig?.NetworkMode == "none"
                && made?.HostConfig?.AutoRemove == true, "\(fake.helperIDs) \(String(describing: made))")
        // Read again since the helper was made: the model reloads a beat
        // after its event, and a list from before would pass anyway.
        let lists = fake.requests.filter { $0.contains("/containers/json?all=1") && !$0.contains("filters") }.count
        await docker.reload()
        check(
            "which the lists don't show",
            fake.requests.filter { $0.contains("/containers/json?all=1") && !$0.contains("filters") }.count > lists
                && !docker.containers.contains { fake.helperIDs.contains($0.Id) } && docker.containers(mountingVolume: volume).isEmpty
                && !docker.containers.isEmpty, "\(docker.containers.map(\.name))")
        page.volumeFiles?.open("/conf")
        check("a folder opens", await eventually(5) { names() == ["app.conf"] }, "\(names())")
        await capture("volume-files")

        app.openDockerFile(.volume(volume), "/conf/app.conf")
        let opened = await eventually(5) { self.app.editor?.active?.url?.path.hasSuffix("Volumes/\(volume)/conf/app.conf") == true }
        check("a volume's file opens in the editor", opened, app.editor?.active?.url?.path ?? "nothing")
        check("as the volume has it", app.editor?.textView?.string.contains("level = info") == true)
        check("the page hidden, its helper goes", await eventually(5) { fake.helperIDs.isEmpty }, "\(fake.helperIDs)")
        if opened, let editor = app.editor, let text = editor.textView {
            text.setSelectedRange(NSRange(location: 0, length: (text.string as NSString).length))
            text.insertText("level = debug\n", replacementRange: text.selectedRange())
            editor.saveDocument(nil)
            check(
                "saving writes it back into the volume",
                await eventually(5) { fake.volumeContents(volume)["conf/app.conf"] == Data("level = debug\n".utf8) },
                String(decoding: fake.volumeContents(volume)["conf/app.conf"] ?? Data(), as: UTF8.self) + " " + (page.error ?? ""))
            let owner = fake.volumeOwner(volume, "conf/app.conf")
            check("its owner kept", owner?.uid == 999 && owner?.gid == 999, "\(String(describing: owner))")
            check("and the save's helper is gone", await eventually(5) { fake.helperIDs.isEmpty }, "\(fake.helperIDs)")

            // The context switched since it was opened: the same name there
            // is another volume, so the save says so and writes nothing.
            if let local = editor.active?.url?.path, let copy = app.dockerFileCopies[local] {
                app.dockerFileCopies[local]?.endpoint = DockerEndpoint(address: .unix("/tmp/ot-elsewhere.sock"), context: "elsewhere", source: "test")
                let creates = fake.requests.filter { $0.contains("/containers/create") }.count
                page.error = nil
                text.insertText("# elsewhere\n", replacementRange: NSRange(location: 0, length: 0))
                editor.saveDocument(nil)
                check(
                    "a copy from another engine isn't saved here",
                    await eventually(5) { page.error?.contains("opened from the context elsewhere") == true }
                        && fake.volumeContents(volume)["conf/app.conf"] == Data("level = debug\n".utf8)
                        && fake.requests.filter { $0.contains("/containers/create") }.count == creates, page.error ?? "no error")
                if let sheet = window.attachedSheet { window.endSheet(sheet) }
                app.dockerFileCopies[local] = copy
                page.error = nil
            }
        }

        app.toggleDockerPage(nil)
        check(
            "back on the page, the same folder through a new helper",
            await eventually(5) { page.volumeFiles?.folder == "/conf" && names() == ["app.conf"] && fake.helperIDs.count == 1 && fake.helperIDs != [helper] },
            "\(page.volumeFiles?.folder ?? "nil") \(names()) \(fake.helperIDs)")
        let second = fake.helperIDs
        second.forEach(fake.expire)
        page.volumeFiles?.open("/")
        check(
            "a helper whose time was up is made again",
            await eventually(5) { names() == ["conf", "data.txt"] && fake.helperIDs.count == 1 && fake.helperIDs != second },
            "\(names()) \(fake.helperIDs) \(page.volumeFiles?.filesError ?? "")")
        // While one runs: Overview takes it away, the folder kept.
        page.volumeTab = .overview
        check(
            "leaving Files removes its helper", await eventually(5) { fake.helperIDs.isEmpty && page.volumeFiles?.listing != true },
            "\(fake.helperIDs)")
        await pause(0.3)
        check("and makes none again", fake.helperIDs.isEmpty, "\(fake.helperIDs)")
        page.volumeTab = .files
        check("Files again, a helper again", await eventually(5) { fake.helperIDs.count == 1 && names() == ["conf", "data.txt"] }, "\(fake.helperIDs)")
        // A drop into a volume's folder: through a helper made for the
        // copy, gone after it — the tab's own stays.
        let browsing = fake.helperIDs
        let dropped = scratch.appendingPathComponent("volume-drop/notes.txt")
        try? FileManager.default.createDirectory(at: dropped.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data("from the Mac\n".utf8).write(to: dropped)
        page.volumeFiles?.copyIn([dropped], into: "/", of: .volume(volume), actions: app.dockerActions)
        check(
            "a volume takes a drop too", await eventually(5) { fake.volumeContents(volume)["notes.txt"] == Data("from the Mac\n".utf8) },
            DockerFileTransfers.shared.transfers(for: .volume(volume)).first?.error ?? "\(fake.volumeContents(volume).keys.sorted())")
        check("listed again with it", await eventually(5) { names() == ["conf", "data.txt", "notes.txt"] }, "\(names())")
        check("and the copy's helper is gone", await eventually(5) { fake.helperIDs == browsing }, "\(fake.helperIDs) \(browsing)")
        DockerHelpers.removeAll(waiting: 2)
        check("what is left at quit is removed", fake.helperIDs.isEmpty, "\(fake.helperIDs)")
        page.volumeTab = .overview
        await pause(0.2)

        // Remove… from a volume's Files tab, on an engine slow to kill a
        // container: its helper waited for, then the volume goes — and
        // isn't made again when Files shows once more.
        let gone = "ot-files-gone"
        fake.setVolumeFile(gone, "a.txt", Data("a\n".utf8))
        docker.load(.volumes)
        _ = await eventually(5) { docker.volumes.contains { $0.Name == gone } }
        page.volumeSelection = [gone]
        page.volumeTab = .files
        check("another volume's Files", await eventually(5) { names() == ["a.txt"] && fake.helperIDs.count == 1 }, "\(names()) \(fake.helperIDs)")
        fake.removalDelay = 300
        page.error = nil
        let confirm = page.actions?.confirm
        page.actions?.confirm = { _, _, _, then in then() }
        if let summary = docker.volumes.first(where: { $0.Name == gone }) { page.verbs(for: summary).first { $0.title == "Remove…" }?.perform() }
        check(
            "Remove from its Files tab removes it, its helper first",
            await eventually(5) { !fake.volumeNames.contains(gone) || page.error != nil } && page.error == nil && fake.helperIDs.isEmpty,
            page.error ?? "\(fake.volumeNames)")
        fake.removalDelay = 0
        if let confirm { page.actions?.confirm = confirm }
        page.volumeSelection = [gone]
        await pause(0.3)
        check("and a Files tab on it makes it no more", !fake.volumeNames.contains(gone) && fake.helperIDs.isEmpty, "\(fake.volumeNames) \(fake.helperIDs)")
        page.volumeSelection = []
        page.volumeTab = .overview
        page.press("1")
    }

    /// Files dragged into and out of a container's Files tab, on the page.
    /// A scenario can't drag, so what a drop and a drag run is called: a
    /// copy in through the session (asked first when a name is there), a
    /// promise written through its delegate as Finder asks for it. What
    /// the rows are is looked at, and a click on one, queued as a person's
    /// is, still opens it. Nothing goes to a terminal tab.
    private func filesTransferChecks(_ fake: FakeDockerEngine, web: String) async {
        let page = app.dockerPage
        let html = "/usr/share/nginx/html"
        guard let container = DockerModel.shared.container(web) else { return check("the container for its files", false) }
        let source = DockerFileSource.of(container)
        let transfers = DockerFileTransfers.shared
        let root = scratch.appendingPathComponent("files-dnd", isDirectory: true)
        func write(_ text: String, _ path: String, mode: Int = 0o644) -> URL {
            let url = root.appendingPathComponent(path)
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data(text.utf8).write(to: url)
            try? FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
            return url
        }
        func text(_ url: URL) -> String? { (try? Data(contentsOf: url)).map { String(decoding: $0, as: UTF8.self) } }
        func names() -> [String] { page.session?.entries.map(\.name) ?? [] }
        // The rows drawn: a lazy stack keeps the views of rows it took
        // away, hidden, to use again.
        func sources() -> [DockerFileDragSourceView] {
            var found: [DockerFileDragSourceView] = []
            func walk(_ view: NSView) {
                if let source = view as? DockerFileDragSourceView, !source.isHiddenOrHasHiddenAncestor { found.append(source) }
                view.subviews.forEach(walk)
            }
            if let view = app.dockerView { walk(view) }
            return found
        }

        // The rows: an AppKit drag source over each file and folder.
        let rows = await eventually(3) { Set(sources().map(\.item.path)) == ["/etc/nginx/conf.d", "/etc/nginx/nginx.conf"] }
        check("a Files row is an AppKit drag source", rows, "\(sources().map(\.item.path))")
        check("and the way up isn't one", !sources().contains { $0.item.path == "/etc" })
        if let conf = sources().first(where: { $0.item.path == "/etc/nginx/conf.d" }) {
            let frame = conf.convert(conf.bounds, to: nil)
            await click(at: CGPoint(x: frame.midX, y: frame.midY))
            check(
                "a click on a folder row still opens it", await eventually(5) { page.session?.folder == "/etc/nginx/conf.d" && names() == ["default.conf"] },
                "\(page.session?.folder ?? "nil") \(names())")
        }
        page.session?.open("/etc/nginx")
        _ = await eventually(5) { names() == ["conf.d", "nginx.conf"] }

        // Out: the promise Finder would be handed, written as Finder asks.
        let out = root.appendingPathComponent("out", isDirectory: true)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let (folder, folderPromise) = DockerFileDragSourceView.provider(for: DockerFileItem(source: source, path: "/etc/nginx", isFolder: true))
        check(
            "a drag out promises a folder as a folder",
            folder.fileType == UTType.folder.identifier && folderPromise.filePromiseProvider(folder, fileNameForType: folder.fileType) == "nginx",
            folder.fileType)
        var folderDone = false
        var folderError: String?
        folderPromise.filePromiseProvider(folder, writePromiseTo: out.appendingPathComponent("nginx")) { error in
            folderDone = true
            folderError = error?.localizedDescription
        }
        check(
            "and its row is in the pane's strip", await eventually(3) { transfers.transfers(for: source).contains { $0.direction == .out && $0.name == "nginx" } },
            "\(transfers.transfers(for: source))")
        let tree = await eventually(5) {
            folderDone && text(out.appendingPathComponent("nginx/nginx.conf")) == "worker_processes 1;\n"
                && text(out.appendingPathComponent("nginx/conf.d/default.conf")) == "server {}\n"
        }
        check("and writes it through the archive", tree && folderError == nil, folderError ?? "\(folderDone)")
        let (file, filePromise) = DockerFileDragSourceView.provider(for: DockerFileItem(source: source, path: "/etc/nginx/nginx.conf", isFolder: false))
        var fileDone = false
        filePromise.filePromiseProvider(file, writePromiseTo: out.appendingPathComponent("nginx.conf")) { _ in fileDone = true }
        check(
            "a file comes out as the container has it",
            await eventually(5) { fileDone && text(out.appendingPathComponent("nginx.conf")) == "worker_processes 1;\n" })
        check("copies out go from the strip once done", await eventually(6) { transfers.transfers(for: source).isEmpty }, "\(transfers.transfers(for: source))")

        // In: a drop on the folder shown.
        page.session?.open(html)
        _ = await eventually(5) { names() == ["index.html"] }
        _ = write("<h1>site</h1>\n", "drop/site/index.html")
        _ = write("body {}\n", "drop/site/css/app.css")
        _ = write("#!/bin/sh\nnginx -s reload\n", "drop/site/run.sh", mode: 0o755)
        _ = write("finder", "drop/site/.DS_Store")
        // A few MB, so the bar has somewhere between to be.
        _ = write(String(repeating: "0123456789abcdef", count: 4 << 16), "drop/site/big.bin")
        let notes = write("notes\n", "drop/notes.txt")
        var actions = app.dockerActions
        var asked: [String] = []
        var accept = false
        actions.confirm = { title, _, _, then in
            asked.append(title)
            if accept { then() }
        }
        // Every value the row's bar is given while it runs.
        var bar: [(done: Int, total: Int)] = []
        let watching = transfers.$transfers.sink { rows in
            for row in rows where row.direction == .into && row.running && row.source.target == source.target {
                if let total = row.total { bar.append((row.done, total)) }
            }
        }
        page.session?.copyIn([root.appendingPathComponent("drop/site"), notes], into: html, of: source, actions: actions)
        let copied = await eventually(5) {
            fake.file(web, html + "/site/css/app.css") == Data("body {}\n".utf8) && fake.file(web, html + "/notes.txt") == Data("notes\n".utf8)
        }
        check("a drop copies files and folders into the folder shown", copied, transfers.transfers(for: source).first?.error ?? "\(asked)")
        check(
            "sent as docker cp sends it",
            fake.requests.contains { $0.hasPrefix("PUT ") && $0.contains("/containers/\(web)/archive") && $0.contains("noOverwriteDirNonDir=true") },
            "\(fake.requests.filter { $0.hasPrefix("PUT") })")
        check("an executable stays executable", fake.fileMode(web, html + "/site/run.sh") == 0o755, "\(fake.fileMode(web, html + "/site/run.sh") ?? -1)")
        check(".DS_Store stays on the Mac", fake.file(web, html + "/site/.DS_Store") == nil)
        check("nothing there was asked about", asked.isEmpty, "\(asked)")
        check("the folder is listed again with them", await eventually(5) { names() == ["site", "index.html", "notes.txt"] }, "\(names())")
        let shown = await eventually(3) {
            transfers.transfers(for: source).contains { $0.direction == .into && $0.finished && $0.total != nil && $0.done == $0.total }
        }
        let gone = await eventually(6) { transfers.transfers(for: source).isEmpty }
        watching.cancel()
        let moved = bar.contains { $0.done > 0 && $0.done < $0.total }
        check("the copy shows its progress, then goes", moved && shown && gone, "\(bar) \(transfers.transfers(for: source))")

        // A name there already: asked first, replaced only when said.
        let index = write("<h1>new</h1>\n", "drop2/index.html")
        page.session?.copyIn([index], into: html, of: source, actions: actions)
        check("one already there is asked about first", await eventually(5) { asked.contains { $0.contains("“index.html”") } }, "\(asked)")
        await pause(0.3)
        check("and isn't replaced unasked", fake.file(web, html + "/index.html") == Data("<h1>hi</h1>\n".utf8))
        accept = true
        page.session?.copyIn([index], into: html, of: source, actions: actions)
        check("and is replaced when you say so", await eventually(5) { fake.file(web, html + "/index.html") == Data("<h1>new</h1>\n".utf8) })
        _ = await eventually(6) { transfers.transfers(for: source).isEmpty }

        // Refused by the engine: its words stay in the strip until OK.
        fake.setReadOnly(web, true)
        page.session?.copyIn([notes], into: html, of: source, actions: actions)
        let refused = await eventually(5) { transfers.transfers(for: source).first?.error?.contains("read-only") == true }
        let since = Date()
        check("the engine's refusal stays to be read", refused, "\(transfers.transfers(for: source))")
        let drawn = await shownText { $0.contains("read-only") }
        let seen = drawn == nil ? await readWindow().map(\.text).joined(separator: " | ") : ""
        check("in the Files tab's strip", drawn != nil, seen)
        await pause(max(0, 4 - Date().timeIntervalSince(since)))
        check("past the time a finished copy has", transfers.transfers(for: source).first?.error != nil)
        await capture("files")
        fake.setReadOnly(web, false)
        if let row = transfers.transfers(for: source).first { transfers.dismiss(row.id) }
        check("and goes at OK", transfers.transfers(for: source).isEmpty)
        page.session?.open("/etc/nginx")
        _ = await eventually(5) { names() == ["conf.d", "nginx.conf"] }
    }

    /// A container's Settings… (`,`), Rename… and Save as Image…, from its
    /// verbs: the sheet reads what it has and applies through the engine,
    /// saying first what the engine would refuse; a name Docker would
    /// refuse, or one taken, is asked again; a compose service's container
    /// is warned about first; its image leaves its secrets and Compose's
    /// labels out. Nothing goes to a terminal tab.
    private func settingsChecks(_ fake: FakeDockerEngine, web: String) async {
        let page = app.dockerPage
        let docker = DockerModel.shared
        let actions = page.actions
        defer { page.actions = actions }
        var commands: [String] = []
        var confirmed: [String] = []
        var asked: [String] = []
        var answers: [String] = []
        page.actions?.run = { command, _ in commands.append(command) }
        // Declined: the compose service's container keeps its name.
        page.actions?.confirm = { title, _, _, _ in confirmed.append(title) }
        // A queue: a name asked again with the same answer would ask forever.
        page.actions?.askName = { title, detail, _, then in
            asked.append(title + "\n" + detail)
            if !answers.isEmpty { then(answers.removeFirst()) }
        }
        page.cleaned = nil
        if app.store.showingOverlay != .docker { app.showOverlay(.docker) }
        page.section = .containers
        let tune = fake.add(name: "ot-tune", image: "redis:7")
        guard await eventually(5, { docker.container(tune) != nil }), let container = docker.container(tune) else {
            return check("a container to tune", false)
        }
        page.selection = [tune]
        page.showDetail = true
        let more = page.verbs(for: container).filter { $0.place == .more }.map(\.title)
        check(
            "a container's More has Settings, Rename and Save as Image", ["Settings…", "Rename…", "Save as Image…"].allSatisfy(more.contains), "\(more)")

        page.press(",")
        check(
            ", opens its settings as a sheet", await eventually(5) { page.containerSettings?.id == tune && self.window.attachedSheet != nil },
            page.error ?? "")
        let opened = page.containerSettings
        check(
            "with no limits and no restart policy, as inspect says", opened?.memory == "" && opened?.cpus == "" && opened?.restart == "no",
            "\(String(describing: opened))")
        check("and what it uses now", opened?.inUse == 48 << 20, "\(opened?.inUse ?? -1)")
        await capture("settings")
        if let png = ProcessInfo.processInfo.environment["OVERTERM_DUMP_PNG"], !png.isEmpty, let shown = window.attachedSheet {
            app.captureWindow(to: png.replacingOccurrences(of: ".png", with: "-settings-sheet.png"), window: shown)
        }
        guard var settings = opened else { return }
        settings.memory = "1g"
        settings.cpus = "1.5"
        settings.restart = "unless-stopped"
        let line = settings.line(prefix: DockerCommands.prefix(for: docker.endpoint))
        check(
            "the change written out as docker update", line.hasSuffix("docker update --memory 1g --memory-swap 2g --cpus 1.5 --restart unless-stopped ot-tune"),
            line)
        let failed = await page.applySettings(settings)
        let host = fake.hostConfig(tune)
        check(
            "Apply changes it through the engine, with the swap Docker needs",
            failed == nil && host?.Memory == 1 << 30 && host?.MemorySwap == 2 << 30 && host?.NanoCpus == 1_500_000_000
                && host?.RestartPolicy?.Name == "unless-stopped", "\(failed ?? "") \(String(describing: host))")
        check("not in a terminal tab", commands.isEmpty, "\(commands)")
        check(
            "the sheet goes, and says what changed",
            await eventually(5) { self.window.attachedSheet == nil && page.cleaned?.contains("1.5 CPUs") == true }, page.cleaned ?? "nothing said")
        check(
            "the detail reads its new limits at the engine's update event", await eventually(5) { page.session?.detail?.HostConfig?.Memory == 1 << 30 },
            "\(page.session?.detail?.HostConfig?.Memory ?? -1)")

        page.press(",")
        if await eventually(5, { page.containerSettings?.memory == "1g" }), var again = page.containerSettings {
            if let png = ProcessInfo.processInfo.environment["OVERTERM_DUMP_PNG"], !png.isEmpty, await eventually(3, { self.window.attachedSheet != nil }),
                let shown = window.attachedSheet
            {
                await pause(0.5)
                app.captureWindow(to: png.replacingOccurrences(of: ".png", with: "-settings-applied.png"), window: shown)
            }
            again.memory = ""
            check("a memory limit can't be emptied, and says why", again.problem?.contains("not take one away") == true, again.problem ?? "")
            again.memory = "4m"
            check("under 6m is refused before the engine", again.problem?.contains("6m") == true, again.problem ?? "")
            again.memory = "2g"
            again.cpus = "9"
            check("more CPUs than the engine has are refused", again.problem?.contains("4 CPUs") == true && again.update == nil, again.problem ?? "")
        } else {
            check("its settings again, as it has them now", false, "\(String(describing: page.containerSettings))")
        }
        page.containerSettings = nil
        _ = await eventually(3) { self.window.attachedSheet == nil }

        // One Docker is removing: its verb says so, and its key does nothing.
        fake.set(tune, state: .removing)
        if await eventually(5, { docker.container(tune)?.state == .removing }) {
            page.selection = [tune]
            page.press(",")
            await pause(0.5)
            check("no settings for one Docker is removing, by its key", page.containerSettings == nil && window.attachedSheet == nil)
        } else {
            check("a container Docker is removing", false, docker.container(tune)?.State ?? "gone")
        }
        fake.set(tune, state: .running)
        _ = await eventually(5) { docker.container(tune)?.state == .running }

        // Rename: one Docker refuses, then one taken, then one it takes.
        answers = ["x", "ot-shop-db-1", "ot-tuned"]
        page.verbs(for: container).first { $0.title == "Rename…" }?.perform()
        check(
            "Rename… asks again when Docker would refuse the name", await eventually(3) { asked.contains { $0.contains("two or more") } },
            asked.joined(separator: " | "))
        check("and when another container has it", await eventually(5) { asked.contains { $0.contains("ot-shop-db-1") } }, asked.joined(separator: " | "))
        check(
            "then renames it, through the engine",
            await eventually(5) { docker.container(tune)?.name == "ot-tuned" && fake.summary(tune)?.name == "ot-tuned" },
            "\(docker.container(tune)?.name ?? "gone") \(page.error ?? "")")
        check("without a warning for a container of no project", confirmed.isEmpty, "\(confirmed)")
        let asks = asked.count
        if let service = docker.container(web) { page.verbs(for: service).first { $0.title == "Rename…" }?.perform() }
        await pause(0.3)
        check(
            "renaming a compose service's container warns first",
            confirmed.last?.contains("Compose") == true && asked.count == asks && docker.container(web)?.name == "ot-shop-web-1", "\(confirmed)")

        // Save as Image: what is and isn't in it, asked once its inspect is
        // read; committed twice on this classic store, which keeps the
        // container's own config in the image too.
        answers = ["ot/web-snapshot:1"]
        let questions = asked.count
        if let service = docker.container(web) { page.verbs(for: service).first { $0.title == "Save as Image…" }?.perform() }
        _ = await eventually(5) { asked.count > questions }
        let question = asked.last ?? ""
        check(
            "it is asked what goes in", question.contains("volumes") && question.contains("API_TOKEN") && question.contains("Compose's labels"),
            question)
        check(
            "Save as Image commits it under the name asked",
            await eventually(5) { fake.commits.last.map { $0.repo == "ot/web-snapshot" && $0.tag == "1" } == true }, page.error ?? "no commit")
        let saved = fake.imageRecord("ot/web-snapshot:1")
        let kept = [saved?.config, saved?.containerConfig].compactMap { $0 }
        let blanked = kept.allSatisfy { config in
            let env = config.Env ?? []
            return env.contains("API_TOKEN=") && !env.contains { $0.contains("s3cr3t-value") } && env.contains("NGINX_PORT=80")
        }
        check("its secrets left out of the image, and of what it keeps of the container", kept.count == 2 && blanked, "\(kept.map { $0.Env ?? [] })")
        check(
            "the image is listed, and said",
            await eventually(5) { docker.images.contains { $0.tags.contains("ot/web-snapshot:1") } && page.cleaned?.contains("ot/web-snapshot:1") == true },
            page.cleaned ?? page.error ?? "")
        check("the container it was saved through is gone", !docker.containers.contains { $0.name.contains("-saving-") }, "\(docker.containers.map(\.name))")
        // Run from it: Compose's labels are there, emptied — no project's.
        if let run = try? await docker.engine?.create(fromImage: "ot/web-snapshot:1", name: "ot-from-snapshot"),
            await eventually(5, { docker.container(run) != nil }), let made = docker.container(run)
        {
            let joined = docker.projects.contains { $0.containers.contains { $0.Id == run } }
            check(
                "and a container run from it joins no project",
                made.composeProject == nil && !joined && page.verbs(for: made).first { $0.key == "b" } == nil
                    && !DockerMCP.describe([made]).contains("compose"), "\(made.Labels ?? [:]) \(DockerMCP.describe([made]))")
            try? await docker.remove(run, force: true)
        } else {
            check("a container run from the image", false, page.error ?? "")
        }

        // A password in its command: no commit can take it out, so it is said.
        let cache = fake.add(name: "ot-cache", image: "redis:7")
        fake.setCommand(cache, ["redis-server", "--requirepass", "p4ssw0rd"])
        if await eventually(5, { docker.container(cache) != nil }), let redis = docker.container(cache) {
            page.cleaned = nil
            answers = ["ot/cache:1"]
            let before = asked.count
            page.verbs(for: redis).first { $0.title == "Save as Image…" }?.perform()
            _ = await eventually(5) { asked.count > before }
            check(
                "a password in its command is said to stay", asked.last?.contains("A password in its command stays in the image") == true,
                asked.last ?? "")
            check(
                "and said again once it is saved", await eventually(5) { page.cleaned?.contains("The password in its command is in it.") == true },
                page.cleaned ?? page.error ?? "")
        } else {
            check("a container with a password in its command", false)
        }
        try? await docker.remove(cache, force: true)
        try? await docker.remove(tune, force: true)
        page.cleaned = nil
    }

    /// A Testcontainers run, as Java's makes one: its containers apart from
    /// the rest, at the list's end, folded at first, Ryuk among them by its
    /// name; found by `is:test` and `session:`, and unfolded when one of
    /// them is revealed; the panel sums it up in a row, which opens it on
    /// the page. Its row is its own detail, and Remove All asks first, then
    /// does what Ryuk does when a run ends — containers with their
    /// anonymous volumes, the networks, volumes and images labelled with
    /// the run, Ryuk last. All of it through the fake: nothing typed.
    private func testcontainersChecks(_ fake: FakeDockerEngine) async {
        let page = app.dockerPage
        let session = "3f2a9c1e-0b5d-4c8e-9a7f-2d6e1b0c4a11"
        let tc = ["org.testcontainers": "true", "org.testcontainers.lang": "java", "org.testcontainers.version": "1.21.3"]
        let labelled = tc.merging(["org.testcontainers.sessionId": session]) { $1 }
        let started = Int(Date().timeIntervalSince1970) - 300
        let pg = fake.add(name: "ot-tc-pg", image: "postgres:16-alpine", labels: labelled, created: started)
        let kafka = fake.add(name: "ot-tc-kafka", image: "confluentinc/cp-kafka:7.6.0", labels: labelled, created: started + 20)
        // As Java starts it: no session of its own, its name says it.
        let ryuk = fake.add(name: "testcontainers-ryuk-\(session)", image: "testcontainers/ryuk:0.14.0", labels: tc, created: started)
        fake.addNetwork("ot-tc-net", labels: labelled)
        fake.addNetwork("ot-keep-net")
        let (volumes, images) = (Set(fake.volumeNames), Set(fake.imageIDs))
        fake.addVolume("ot-tc-data", size: 1 << 20, refCount: 0, labels: labelled)
        // As Java's ImageFromDockerfile names and labels what it builds.
        let built = fake.addImage("localhost/testcontainers/ot-tc-built:latest", size: 5 << 20, labels: labelled)
        page.filter = ""
        page.runningOnly = false
        page.selection = []
        let tag = DockerPageModel.sessionTag(session)
        func shown() -> Set<String> { Set(page.groups.flatMap(\.containers).map(\.Id)) }
        /// A check of what is drawn: failed, what the window shows.
        func drawn(_ name: String, _ line: (text: String, frame: CGRect)?) async {
            var detail = line?.text ?? ""
            if line == nil { detail = await readWindow().map(\.text).joined(separator: " | ") }
            check(name, line != nil, detail)
        }

        check(
            "Testcontainers' containers are a run of their own, after the rest", await eventually(5) { page.groups.last?.id == tag },
            "\(page.groups.map(\.id))")
        let loose = page.groups.first { $0.id == DockerPageModel.looseTag }?.containers.map(\.Id) ?? []
        check("not among the other containers", !loose.contains(pg) && !loose.contains(kafka) && !loose.contains(ryuk), "\(loose)")
        let run = page.groups.last?.session
        check("its reaper with them, found by its name", run?.reaper?.Id == ryuk, run?.reaper?.name ?? "none")
        check(
            "with a count and when it started",
            run.map { $0.members.count == 2 && $0.started == started && UsageFormat.age($0.startedDate) == "5 min ago" } == true,
            run.map { "\($0.members.count) \($0.started) vs \(started)" } ?? "no run")
        check("folded at first", page.collapsed.contains(tag) && !page.rows.contains(pg), "\(page.rows)")
        // Its row's own words, and the session's start drawn: Vision reads
        // "java" as "iava" and the 1 of "3f2a9c1e" as an l.
        check("its row says the library and the session", run?.subtitle == "java · 3f2a9c1e", run?.subtitle ?? "no run")
        await drawn("and draws them", await shownText { $0.contains("3f2a9c") })
        await drawn("and how long ago the run started", await shownText { $0.contains("5 min ago") })
        page.toggleFold(tag)
        check("unfolded with a click", page.rows.contains(pg) && page.rows.contains(kafka), "\(page.rows)")
        // Its row's own word: Vision reads a short title over its image's
        // line unreliably.
        let ryukRow = (page.groups.last?.containers.first { $0.Id == ryuk }).flatMap { container in
            app.theme.map { DockerContainerRow(container: container, inProject: true, busy: false, docker: DockerModel.shared, theme: $0, open: { _ in }) }
        }
        check("Ryuk among them, by its own name", page.rows.last == ryuk && ryukRow?.title == "Ryuk", ryukRow?.title ?? "no row")
        page.toggleFold(tag)
        page.filter = "is:test"
        check("is:test keeps only them", page.groups.map(\.id) == [tag], "\(page.groups.map(\.id))")
        page.filter = "-is:test"
        check("-is:test hides them", !page.groups.contains { $0.id == tag } && !page.groups.isEmpty, "\(page.groups.map(\.id))")
        page.filter = "session:3f2a"
        check("session: finds the run", shown() == [pg, kafka, ryuk], "\(shown().count)")
        page.filter = ""

        app.revealOnDockerPage(pg)
        check("a container of it revealed unfolds its run", !page.collapsed.contains(tag) && page.selection == [pg], "\(page.selection)")
        check(
            "the panel's elsewhere leaves them out, and says them in one row",
            !app.dockerPanel.others.contains { $0.Id == pg || $0.Id == ryuk } && app.dockerPanel.runs.map(\.id) == [session],
            "\(app.dockerPanel.others.map(\.name)) \(app.dockerPanel.runs.map(\.id))")
        // The panel's row, drawn; a click on it shows the run on the page
        // — folded first, so it is the reveal that unfolds it.
        page.collapsed.insert(tag)
        app.hideOverlay(focus: false)
        let sidebar = app.sidebarPanel.panel
        app.showDockerPanel(nil)
        await drawn("the panel's row says how many run, in how many runs", await shownText { $0.contains("2 running in 1 run") })
        page.selection = []
        app.dockerPanel.showRun(session)
        check(
            "a click on it shows the run on the page, unfolded and selected",
            app.store.showingOverlay == .docker && page.selection == [tag] && !page.collapsed.contains(tag), "\(page.selection) \(page.collapsed)")
        app.sidebarPanel.panel = sidebar

        page.showDetail = true
        page.selection = [tag]
        check("a run selected is its own detail", page.detailedSession?.id == session && page.detailed == nil)
        check("the selection means its containers, not Ryuk", Set(page.selectedContainers.map(\.Id)) == [pg, kafka], "\(page.selectedContainers.map(\.name))")
        let verbs = page.detailedSession.map { page.verbs(for: $0) } ?? []
        func titles(_ place: DockerVerb.Place) -> [String] { verbs.filter { $0.place == place }.map(\.title) }
        check(
            "its verbs as buttons, Remove All last", titles(.button) == ["Stop All", "Copy Session ID"] && titles(.remove) == ["Remove All…"],
            "\(verbs.map(\.title))")
        await drawn("its detail has them", await shownText { $0.contains("Stop All") })
        await capture("testcontainers")

        // Asked, with what goes; nothing yet.
        let actions = page.actions
        var asked: (title: String, detail: String, button: String)?
        page.actions?.confirm = { title, detail, button, _ in asked = (title, detail, button) }
        verbs.first { $0.title == "Remove All…" }?.perform()
        page.actions = actions
        check(
            "Remove All says what goes",
            asked.map {
                $0.title == "Remove this run's 2 containers?" && $0.detail.contains("then the networks, volumes and images labelled with the run")
                    && $0.detail.contains("Ryuk itself last") && $0.button == "Remove All"
            } == true && fake.summary(pg) != nil, asked.map { "\($0.title) \($0.detail) \($0.button)" } ?? "not asked")

        // Folded again, so the end checks that a run gone takes its fold.
        page.collapsed.insert(tag)
        page.selection = [tag]
        page.press("\u{7F}")
        check("⌫ on a run asks first", await eventually(3) { self.window.attachedSheet != nil })
        let clicked = clickSheetButton("Remove All")
        let gone = await eventually(5) { fake.summary(pg) == nil && fake.summary(kafka) == nil && fake.summary(ryuk) == nil }
        check("and removes all of it on yes", clicked && gone, "clicked \(clicked), gone \(gone), \(page.error ?? "")")
        check(
            "with their anonymous volumes, as Ryuk does", fake.requests.contains { $0.hasPrefix("DELETE /v1.47/containers/\(pg)?force=1&v=1") },
            "\(fake.requests.filter { $0.hasPrefix("DELETE") })")
        check(
            "then what the run labelled — its networks, volumes and images — not others",
            await eventually(5) {
                !fake.networkNames.contains("ot-tc-net") && fake.networkNames.contains("ot-keep-net") && Set(fake.volumeNames) == volumes
                    && Set(fake.imageIDs) == images
            }, "\(fake.networkNames) \(Set(fake.volumeNames).subtracting(volumes)) \(Set(fake.imageIDs).subtracting(images))")
        let index = { (path: String) in fake.requests.lastIndex { $0.hasPrefix("DELETE /v1.47/" + path) } ?? -1 }
        check(
            "Ryuk last",
            index("containers/\(ryuk)")
                > max(
                    index("containers/\(pg)"), index("containers/\(kafka)"), index("networks/ot-tc-net-id"), index("volumes/ot-tc-data"),
                    index("images/\(built)")),
            "\(fake.requests.filter { $0.hasPrefix("DELETE") })")
        check(
            "the run leaves the list, its fold forgotten",
            await eventually(5) { !page.groups.contains { $0.id == tag } && !page.collapsed.contains(tag) && page.selection.isEmpty && page.error == nil },
            "\(page.groups.map(\.id)) \(page.error ?? "")")
        try? await DockerModel.shared.engine?.remove(network: "ot-keep-net")
        page.selection = []
    }

    /// A container that failed, to an agent: Ask Why opens Overterm's own
    /// Ask Agent sheet with how it ended, its health check, its last lines
    /// and its compose service, secrets out of all of it; ⌘L hands lines
    /// picked out of its log over the same way. The window's own path,
    /// nothing recorded: no agent starts (the agent tabs are shells), and
    /// Compose is a stub.
    private func askAgentChecks(_ fake: FakeDockerEngine, web: String, folder: URL, real: String) async {
        let page = app.dockerPage
        let docker = DockerModel.shared
        let config = #"""
            {"name":"ot-shop","services":{"web":{"image":"nginx:1.27"},"worker":{"image":"node:22","command":["node","server.js"],"environment":{"DB_PASSWORD":"compose-literal-pw","STRIPE_SECRET_KEY":"${STRIPE_SECRET_KEY}"},"depends_on":{"db":{"condition":"service_started","required":true}}}}}
            """#
        let bin = composeStub("ask-stub-bin", json: config)
        DockerCLI.override = bin.appendingPathComponent("docker")
        defer { DockerCLI.override = nil }
        func asked() -> String { (try? String(contentsOf: bin.appendingPathComponent("stub.log"), encoding: .utf8)) ?? "" }

        let worker = fake.add(
            name: "ot-shop-worker-1", image: "node:22", project: "ot-shop", workingDir: real, service: "worker",
            env: ["NODE_ENV=production", "DATABASE_URL=postgres://shop:hunter2@db:5432/shop", "STRIPE_SECRET_KEY=sk_test_abc123"])
        fake.log(worker, "connecting to postgres://shop:hunter2@db:5432/shop")
        fake.log(worker, "stripe key sk_test_abc123 loaded")
        fake.log(worker, "Error: Cannot find module 'express'", stream: .stderr)
        fake.setFailure(
            worker, oomKilled: true, restarts: 3, restartPolicy: "on-failure", memory: 256 << 20, healthcheck: ["CMD-SHELL", "curl -f http://localhost:3000/"],
            probes: ["curl: (7) Failed to connect to localhost port 3000"], failingStreak: 3)
        fake.set(worker, state: .exited, exitCode: 137, health: "unhealthy")
        guard await eventually(5, { docker.container(worker)?.exitCode == 137 }), let failed = docker.container(worker) else {
            return check("a container that failed, to ask about", false, "\(docker.containers.map(\.name))")
        }
        // Agent tabs, their agents not started: one in the home folder
        // first in the strip, then one in the container's checkout — only
        // the ranking puts the checkout's first.
        let home = FileManager.default.homeDirectoryForCurrentUser
        app.newTab(in: home, agent: .codex, startAgent: false)
        guard let homeTab = app.store.selected else { return check("an agent tab elsewhere", false) }
        homeTab.customTitle = "home · codex"
        app.newTab(in: folder, agent: .claude, startAgent: false)
        guard let shopTab = app.store.selected, homeTab !== shopTab else { return check("an agent tab in the checkout", false) }
        shopTab.customTitle = "shop · claude"
        func position(_ tab: Tab) -> Int { app.store.tabs.firstIndex { $0 === tab } ?? -1 }
        app.revealOnDockerPage(worker)
        page.showDetail = true
        page.detailTab = .overview
        _ = await eventually(3) { self.app.dockerListHasKeyboard() }

        func askWhy(_ verbs: [DockerVerb]) -> DockerVerb? { verbs.first { $0.title == "Ask an Agent Why…" } }
        // The sheet's SwiftUI buttons are no NSButtons to click: what each
        // runs, the sheet's own closures.
        func sheet() -> AskAgentView? { (window.attachedSheet?.contentViewController as? NSHostingController<AskAgentView>)?.rootView }
        check("a failed container offers to ask an agent why, as a button", askWhy(page.verbs(for: failed))?.place == .button)
        check("a running one doesn't", docker.container(web).map { askWhy(page.verbs(for: $0)) == nil } == true)
        check("and the panel's menu has it too", askWhy(app.dockerPanel.verbs(failed)) != nil)

        askWhy(page.verbs(for: failed))?.perform()
        check("Ask Why opens the Ask Agent sheet", await eventually(5) { self.window.attachedSheet != nil })
        let model = app.askAgent
        check(
            "the checkout's agent tab is offered first, and chosen, though the strip has the home one first",
            position(homeTab) < position(shopTab) && model.targets.first?.title == "shop · claude" && model.chosen == shopTab.id
                && model.targets.last?.id == nil,
            "\(model.targets.map(\.title)) chosen \(String(describing: model.chosen)), strip \(position(homeTab)) \(position(shopTab))")
        check(
            "the question is started for you",
            model.message == "Why did ot-shop-worker-1 run out of memory?" && model.subject == "ot-shop-worker-1 ran out of memory",
            "\(model.message) / \(model.subject ?? "no subject")")
        let prompt = await app.askAgentPrompt()
        check(
            "it says how it ended",
            prompt.hasPrefix(model.message) && prompt.contains("Out of memory") && prompt.contains("Memory limit 256 MB")
                && prompt.contains("Restarts: 3 (restart policy on-failure") && prompt.contains("Image: node:22"), prompt)
        check("and its health check's last output", prompt.contains("Last check (exit 1): curl: (7) Failed to connect"), prompt)
        check(
            "its last log lines, secrets taken out",
            prompt.contains("Cannot find module 'express'") && prompt.contains("stripe key •••••• loaded") && !prompt.contains("sk_test_abc123")
                && !prompt.contains("hunter2"), prompt)
        check("a connection string's password masked", prompt.contains("postgres://shop:••••••@db:5432/shop"), prompt)
        check(
            "Compose is asked for the project's own files, variables as written",
            asked().contains("-p ot-shop -f \(real)/compose.yaml config --no-interpolate --format json --no-env-resolution"), asked())
        let service = model.parts.first { $0.title == "compose service" }?.text ?? ""
        check(
            "its compose service, a secret in it masked",
            service.contains("node:22") && service.contains("${STRIPE_SECRET_KEY}") && !service.contains("compose-literal-pw") && !service.contains("nginx:1.27"),
            service.isEmpty ? "\(model.parts.map(\.title))" : service)
        if let logs = model.parts.firstIndex(where: { $0.title.hasSuffix("log lines") }) { model.parts[logs].on = false }
        let without = await app.askAgentPrompt()
        check("a chip leaves the logs out", !without.contains("Cannot find module") && without.contains("Out of memory"))
        await capture("ask-why")
        if let png = ProcessInfo.processInfo.environment["OVERTERM_DUMP_PNG"], !png.isEmpty, let shown = window.attachedSheet {
            app.captureWindow(to: png.replacingOccurrences(of: ".png", with: "-ask-sheet.png"), window: shown)
        }
        let cancelled = sheet().map { $0.cancel() } != nil
        let away = await eventually(3) { self.window.attachedSheet == nil }
        check("Cancel puts the sheet away", cancelled && away)
        check(
            "and gives the keyboard back to the list", await eventually(3) { self.app.dockerListHasKeyboard() },
            "\(String(describing: window.firstResponder))")

        // The list's key, and what it doesn't ask about.
        page.selection = [worker]
        page.press("a")
        let keyed = await eventually(5) { self.window.attachedSheet != nil }
        check("a asks the same from the list's keyboard", keyed && model.message.contains("run out of memory"), model.message)
        sheet()?.cancel()
        _ = await eventually(3) { self.window.attachedSheet == nil }
        page.selection = [web]
        page.press("a")
        await pause(0.5)
        check("not for a container that is fine", window.attachedSheet == nil)
        if let sheet = window.attachedSheet { window.endSheet(sheet) }

        // ⌘L over the page: the selected container that failed, never what
        // is selected in the terminal hidden under the page.
        page.selection = [worker]
        app.store.selected?.terminal.perform(binding: "select_all")
        app.focusDockerList()
        _ = await eventually(3) { self.app.dockerListHasKeyboard() }
        let fromList = menuItem("Edit", "Ask an Agent About the Selection").map { perform($0) } == true
        let overPage = await eventually(5) { self.window.attachedSheet != nil }
        check(
            "⌘L over the page asks why the selected container failed",
            fromList && overPage && model.message == "Why did ot-shop-worker-1 run out of memory?" && model.subject == "ot-shop-worker-1 ran out of memory"
                && model.command == nil, "\(fromList) \(overPage) \(model.message) / \(model.subject ?? "no subject")")
        sheet()?.cancel()
        _ = await eventually(3) { self.window.attachedSheet == nil }
        if let sheet = window.attachedSheet { window.endSheet(sheet) }

        // ⌘L on lines picked out of its log: whole lines, the container as context.
        page.selection = [worker]
        page.detailTab = .logs
        func logView() -> DockerLogTextView? {
            Self.find(DockerLogTextView.self, in: app.dockerView) { $0.accessibilityIdentifier() == "docker.text" }
        }
        let shown = await eventually(5) { logView()?.string.contains("Cannot find module") == true }
        check("its log is a view that answers ⌘L itself", shown, logView()?.string ?? "no DockerLogTextView")
        if shown, let text = logView() {
            // Nothing picked: the log passes ⌘L on, to the container.
            text.setSelectedRange(NSRange(location: 0, length: 0))
            window.makeFirstResponder(text)
            let passed = menuItem("Edit", "Ask an Agent About the Selection").map { perform($0) } == true
            let reached = await eventually(5) { self.window.attachedSheet != nil }
            check(
                "a log with nothing picked passes ⌘L on, to the container",
                passed && reached && model.message == "Why did ot-shop-worker-1 run out of memory?" && model.subject != nil,
                "\(passed) \(reached) \(model.message)")
            sheet()?.cancel()
            _ = await eventually(3) { self.window.attachedSheet == nil }
            if let sheet = window.attachedSheet { window.endSheet(sheet) }

            let string = text.string as NSString
            let from = string.range(of: "stripe key").location + 4
            let to = string.range(of: "Cannot find").location + 5
            text.setSelectedRange(NSRange(location: from, length: to - from))
            window.makeFirstResponder(text)
            let chosen = menuItem("Edit", "Ask an Agent About the Selection").map { perform($0) } == true
            let opened = await eventually(5) { self.window.attachedSheet != nil }
            let picked = model.selection
            check(
                "⌘L on picked log lines asks about them, whole lines",
                chosen && opened && picked.contains("Error: Cannot find module 'express'") && picked.contains("stripe key •••••• loaded")
                    && !picked.contains("connecting to") && !picked.contains("sk_test_abc123"), "\(chosen) \(opened) \(picked.debugDescription)")
            check(
                "with the container as context",
                model.parts.first?.title == "ot-shop-worker-1" && model.parts.first?.text.contains("Image: node:22") == true && model.subject == nil
                    && model.lines == 2, "\(model.parts.map(\.title)) \(model.lines)")
            model.chosen = shopTab.id
            sheet()?.send()
            check(
                "Send hides the page and types into the agent's tab",
                await eventually(3) { self.app.store.showingOverlay == nil && self.app.store.selected?.id == shopTab.id },
                "\(String(describing: app.store.showingOverlay)) \(app.store.selected?.title ?? "none")")
        }
        if let sheet = window.attachedSheet { window.endSheet(sheet) }

        // As it was: the detail on Overview (no log followed), the worker
        // gone, the tabs closed, the page back with its list's keyboard.
        page.detailTab = .overview
        page.selection = []
        try? await docker.remove(worker, force: true)
        app.closeTabsWithoutAsking([shopTab, homeTab])
        if app.store.showingOverlay != .docker { app.toggleDockerPage(nil) }
        _ = await eventually(3) { self.app.dockerListHasKeyboard() }
    }

    /// A folder with a stub `docker` answering as Compose 2.29 does: its
    /// version (the `version` file beside it, which a check may change),
    /// its JSON for the stack (`config.json`), a line of YAML for Show
    /// Resolved Config; every call logged (`stub.log`), anything else
    /// refused. Never an engine.
    private func composeStub(_ name: String, json: String, version: String = "2.29.7") -> URL {
        let bin = scratch.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try? json.write(to: bin.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)
        try? (version + "\n").write(to: bin.appendingPathComponent("version"), atomically: true, encoding: .utf8)
        let stub = bin.appendingPathComponent("docker")
        let script = #"""
            #!/bin/sh
            dir="$(dirname "$0")"
            echo "$*" >> "$dir/stub.log"
            case "$*" in
              *"compose version --short"*) cat "$dir/version" ;;
              *" config "*"--format json"*) cat "$dir/config.json" ;;
              *" config --no-env-resolution") echo "name: resolved" ;;
              *) echo "unexpected: $*" >&2; exit 1 ;;
            esac
            """#
        try? script.write(to: stub, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        return bin
    }

    /// The lines of text the window shows, read off its pixels as a person
    /// reads them (Vision), each where it is in the window's points (origin
    /// bottom left, as an event's location) — for what SwiftUI draws itself,
    /// which no AppKit view holds and, without an assistive app, no
    /// accessibility element either.
    private func readWindow() async -> [(text: String, frame: CGRect)] {
        guard let image = app.windowImage(window) else { return [] }
        let pixels = WindowPixels(image: image)
        let size = window.frame.size
        return await Task.detached { Self.recognize(pixels, size: size) }.value
    }

    private struct WindowPixels: @unchecked Sendable {
        let image: CGImage
    }

    nonisolated private static func recognize(_ pixels: WindowPixels, size: CGSize) -> [(text: String, frame: CGRect)] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try? VNImageRequestHandler(cgImage: pixels.image).perform([request])
        return (request.results ?? []).compactMap { observation in
            guard let text = observation.topCandidates(1).first?.string else { return nil }
            let box = observation.boundingBox
            return (text, CGRect(x: box.minX * size.width, y: box.minY * size.height, width: box.width * size.width, height: box.height * size.height))
        }
    }

    /// Where `word` is drawn, read again until it shows: its own frame
    /// within the line Vision reads it in — a row of chips is one line.
    private func wordFrame(_ word: String, timeout: TimeInterval = 15) async -> CGRect? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let image = app.windowImage(window) {
                let pixels = WindowPixels(image: image)
                let size = window.frame.size
                if let frame = await Task.detached(operation: { Self.locate(word, in: pixels, size: size) }).value { return frame }
            }
            await pause(0.3)
        } while Date() < deadline
        return nil
    }

    nonisolated private static func locate(_ word: String, in pixels: WindowPixels, size: CGSize) -> CGRect? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try? VNImageRequestHandler(cgImage: pixels.image).perform([request])
        for observation in request.results ?? [] {
            guard let candidate = observation.topCandidates(1).first, let range = candidate.string.range(of: word),
                let box = (try? candidate.boundingBox(for: range))?.boundingBox
            else { continue }
            return CGRect(x: box.minX * size.width, y: box.minY * size.height, width: box.width * size.width, height: box.height * size.height)
        }
        return nil
    }

    /// The window's line of text that `match` picks, read again until it
    /// shows (SwiftUI draws a moment later). A Vision pass can take seconds
    /// on a busy machine, so the wait is long — it only runs out when
    /// something isn't drawn.
    private func shownText(_ timeout: TimeInterval = 15, _ match: @escaping (String) -> Bool) async -> (text: String, frame: CGRect)? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let line = await readWindow().first(where: { match($0.text) }) { return line }
            await pause(0.3)
        } while Date() < deadline
        return nil
    }

    /// A click where a person would click, for the window itself. Both
    /// events are queued, not sent: a mouse-down that tracks the mouse
    /// until it is up (a disabled button passes it on) takes its mouse-up
    /// off the queue, where one sent after it would never come.
    private func click(at point: CGPoint) async {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            NSApp.postEvent(
                NSEvent.mouseEvent(
                    with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!, atStart: false)
        }
        await pause(0.2)
    }

    /// Two worktrees of one repository, one compose file whose `name:` is the
    /// main checkout's: before New Task's Up of the new worktree's stack,
    /// its ports are looked at — one published by the main checkout's stack,
    /// one held by a program on this Mac (the fake's own listener) — and its
    /// name, which the main checkout's stack has. Up on Free Ports writes an
    /// override into Overterm's folder, never the repository, and runs the
    /// stack under a name of its own on free ports; every later Up uses it;
    /// the detail, the pills and the agents say what moved; Back to the
    /// File's Ports forgets it. A stub `docker` answers as Compose 2.29 does;
    /// what would run is recorded, never typed — but for Compose's own
    /// reading of the override, `config`, which reaches no engine.
    private func worktreePortsChecks(_ fake: FakeDockerEngine, socket: String) async {
        let docker = DockerModel.shared
        let page = app.dockerPage
        // Below the ephemeral range, as a stack's own ports are: one the
        // system hands out is next to ports other programs' connections
        // take any moment, so the free one found beside it wouldn't stay so.
        var held: Int?
        for port in stride(from: 31_000 + Int(getpid()) % 500, to: 39_000, by: 37) {
            if let bound = try? fake.listenTCP(port: port) {
                held = bound
                break
            }
        }
        guard let held else { return check("a port held on this Mac", false) }
        let main = scratch.appendingPathComponent("ot-main", isDirectory: true)
        try? FileManager.default.createDirectory(at: main, withIntermediateDirectories: true)
        let mainWeb = fake.add(
            name: "ot-main-web-1", image: "nginx:1.27", project: "ot-main", workingDir: FileTreeModel.realPath(main), service: "web",
            ports: [DockerPort(IP: "0.0.0.0", PrivatePort: 80, PublicPort: 38080, Type: "tcp")])
        let repo = scratch.appendingPathComponent("ot-ports-repo", isDirectory: true)
        try? FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        let file =
            "name: ot-main\nservices:\n  web:\n    image: nginx:1.27\n    ports:\n      - \"38080:80\"\n  db:\n    image: postgres:16\n    ports:\n"
            + "      - \"127.0.0.1:\(held):5432\"\n"
        try? file.write(to: repo.appendingPathComponent("compose.yaml"), atomically: true, encoding: .utf8)
        try? await git(["init", "-q", "-b", "main"], in: repo)
        try? await git(["add", "compose.yaml"], in: repo)
        try? await git(["commit", "-q", "-m", "stack"], in: repo)

        // A stub `docker`: Compose 2.29's version, its JSON for the stack.
        let json =
            #"{"name":"ot-main","services":{"db":{"image":"postgres:16","ports":[{"mode":"ingress","host_ip":"127.0.0.1","target":5432,"published":"\#(held)","protocol":"tcp"}]},"#
            + #""web":{"image":"nginx:1.27","ports":[{"mode":"ingress","target":80,"published":"38080","protocol":"tcp"}]}}}"#
        let bin = composeStub("ports-stub-bin", json: json)
        let stub = bin.appendingPathComponent("docker")
        func log() -> String { (try? String(contentsOf: bin.appendingPathComponent("stub.log"), encoding: .utf8)) ?? "" }
        DockerCLI.override = stub
        page.composeVersion = nil

        var commands: [(command: String, folder: URL?)] = []
        var asked: (title: String, detail: String, buttons: [String])?
        var confirms = 0
        var alerts: [String] = []
        let actions = page.actions
        page.actions?.run = { commands.append(($0, $1)) }
        page.actions?.alert = { alerts.append($0 + ": " + $1) }
        page.actions?.choose = { title, detail, buttons, then in
            asked = (title, detail, buttons)
            then(0)
        }
        page.actions?.confirm = { _, _, _, then in
            confirms += 1
            then()
        }
        let previous = app.store.selected
        defer {
            page.actions = actions
            DockerCLI.override = nil
            page.composeVersion = nil
            page.error = nil
            page.cleaned = nil
            Settings.shared.set("docker.checkPorts", nil)
        }

        // New Task with its stack: asked first.
        do {
            try await app.createTask(repo: repo, branch: "feat/ports", base: "main", agent: nil, startStack: true)
        } catch {
            return check("New Task in a repository with a stack", false, error.localizedDescription)
        }
        let worktree = TaskCreator.worktreePath(repo: repo, branch: "feat/ports", location: Settings.shared.worktreeLocation)
        let real = FileTreeModel.realPath(worktree)
        let base = real + "/compose.yaml"
        let tab = app.store.selected
        check(
            "New Task looks at a stack's ports before its Up", asked?.buttons == ["Up on Free Ports", "Up as Written"],
            "\(asked.map { "\($0)" } ?? "nothing asked") \(page.error ?? "")")
        let detail = asked?.detail ?? ""
        check(
            "the question says who holds them",
            detail.contains("38080 (web): ot-main-web-1 publishes it") && detail.contains("\(held) (db): ") && detail.contains("pid \(getpid())"), detail)
        check("and whose the project's name is", detail.contains("“ot-main” runs in "), detail)
        check(
            "Compose is asked from the worktree's own files",
            log().contains("-f \(base) --profile * config") && log().contains("--no-env-resolution"), log())
        // The answer looks at the ports once more before it writes anything.
        _ = await eventually(5) { page.ports.override(in: real) != nil && !commands.isEmpty }
        guard let kept = page.ports.override(in: real) else { return check("Up on Free Ports keeps an override", false, page.error ?? "") }
        let name = kept.project
        let override = page.ports.file(of: kept).path
        check(
            "Up on Free Ports runs its own project on its own files",
            name.hasPrefix("ot-main-")
                && commands.last?.command
                    == "DOCKER_HOST=unix://\(socket) docker compose -p \(name) -f \(DockerCommands.quote(base)) -f \(DockerCommands.quote(override)) up -d"
                && commands.last?.folder.map(FileTreeModel.realPath) == real, "\(commands.last.map { "\($0)" } ?? "nothing")")
        check(
            "the override is kept in Overterm's folder",
            FileManager.default.fileExists(atPath: override) && override.hasPrefix(AppEnvironment.supportDirectory.path), override)
        let status = (try? await Git.run(["status", "--porcelain"], in: worktree)) ?? "git failed"
        check("the repository isn't touched", status.isEmpty, status)
        let yaml = (try? String(contentsOfFile: override, encoding: .utf8)) ?? ""
        let webTo = kept.moves.first { $0.service == "web" }?.to ?? 0
        let dbTo = kept.moves.first { $0.service == "db" }?.to ?? 0
        check(
            "it replaces the ports it moves",
            yaml.contains("ports: !override") && yaml.contains(#"published: "\#(webTo)""#) && yaml.contains(#"host_ip: "127.0.0.1""#)
                && yaml.contains(#"name: "ot-main-"#), yaml)
        check(
            "a taken port goes 10 000 up, else to the next one",
            kept.moves.map(\.from) == [held, 38080] && (webTo == 48080 || ListeningPorts.isBound(48080)) && dbTo > held && !ListeningPorts.isBound(dbTo),
            "\(kept.moves.map(\.label))")
        // Compose itself, where there is one: the override moves the port.
        DockerCLI.override = nil
        if let compose = DockerCLI.locate("docker") {
            let cli = DockerCLI(executable: compose, endpoint: DockerEndpoint(address: .unix(socket), context: nil, source: "OVERTERM_DOCKER_HOST"))
            let read = try? await cli.run(["compose", "-f", base, "-f", override, "config", "--format", "json"], timeout: 30)
            let merged = read.flatMap { try? ComposeConfig.parse($0) }
            check(
                "Compose reads the override as moving the port, not adding one",
                merged?.name == name && merged?.services.first { $0.name == "web" }?.ports.map(\.published) == ["\(webTo)"]
                    && merged?.services.first { $0.name == "db" }?.ports.map(\.hostIP) == ["127.0.0.1"], read ?? "no answer")
        }
        DockerCLI.override = stub

        // Its containers made: the detail says what moved.
        let ownWeb = fake.add(
            name: "\(name)-web-1", image: "nginx:1.27", project: name, workingDir: real, service: "web",
            ports: [DockerPort(IP: "0.0.0.0", PrivatePort: 80, PublicPort: webTo, Type: "tcp")], configFiles: [base, override])
        let tag = DockerPageModel.projectTag(name)
        _ = await eventually(5) { docker.projects.contains { $0.name == name } }
        if app.store.showingOverlay != .docker { app.showOverlay(.docker) }
        page.section = .containers
        page.showDetail = true
        page.selection = [tag]
        let project = docker.projects.first { $0.name == name }
        // As the detail draws it, read the way VoiceOver would.
        let line = "Own ports: db \(held) → \(dbTo) · web 38080 → \(webTo)"
        var drawn = ""
        let drawnLine = await eventually(5) {
            // SwiftUI's selectable Text is an AppKit text field.
            drawn = Self.find(NSTextField.self, in: self.app.dockerView) { $0.stringValue.hasPrefix("Own ports") }?.stringValue ?? ""
            return drawn == line
        }
        check("the project's detail says what moved", drawnLine, drawn.isEmpty ? "nothing drawn" : drawn)
        await capture("ports")

        // What its Up runs, copied; what Compose makes of it, with the override.
        var copied: [String] = []
        var shownCopies: [URL] = []
        page.actions?.copy = { copied.append($0) }
        page.actions?.showCopy = { shownCopies.append($0) }
        if let project {
            page.verbs(for: project).first { $0.title == "Copy Up Command" }?.perform()
            page.showResolvedConfig(project)
        }
        let upCommand = "DOCKER_HOST=unix://\(socket) docker compose -p \(name) -f \(DockerCommands.quote(base)) -f \(DockerCommands.quote(override)) up -d"
        check("Copy Up Command is what its Up runs", await eventually(5) { copied.last == upCommand }, copied.last ?? "nothing copied")
        check(
            "Show Resolved Config reads it with its override",
            await eventually(5) { !shownCopies.isEmpty } && log().contains("compose -p \(name) -f \(base) -f \(override) config --no-env-resolution"),
            log())
        for copy in shownCopies { try? FileManager.default.removeItem(at: copy) }
        asked = nil
        var count = commands.count
        page.press("u")
        check(
            "its Up uses the same files and asks nothing",
            await eventually(5) { commands.count == count + 1 } && commands.last?.command.contains("-f \(DockerCommands.quote(override)) up -d") == true
                && asked == nil, "\(commands.last.map { "\($0)" } ?? "nothing") \(asked?.title ?? "")")
        fake.set(mainWeb, state: .exited)
        _ = await eventually(5) { docker.container(mainWeb)?.state == .exited }
        count = commands.count
        page.press("u")
        _ = await eventually(5) { commands.count == count + 1 }
        check(
            "a moved port stays put once its first holder has gone",
            ((try? String(contentsOfFile: override, encoding: .utf8)) ?? "").contains(#"published: "\#(webTo)""#)
                && page.ports.override(in: real)?.moves == kept.moves, "\(page.ports.override(in: real)?.moves.map(\.label) ?? [])")
        page.press("D")
        check("Down finds it by name", commands.last?.command == "DOCKER_HOST=unix://\(socket) docker compose -p \(name) down", commands.last?.command ?? "")

        // The pane header's pill, and the agents.
        if let tab {
            check(
                "the pane header's pill says where it came from",
                await eventually(5) {
                    self.app.updateContainerPorts(of: tab)
                    return tab.containerPorts.contains { $0.port == webTo && $0.movedFrom == 38080 }
                }, "\(tab.containerPorts.map { "\($0.port) \($0.movedFrom ?? 0)" })")
        }
        let told =
            (try? await DockerMCP.call("docker_projects", [:], docker: .shared))
            .flatMap { (($0["content"] as? [[String: Any]])?.first?["text"] as? String) } ?? ""
        check("agents are told the moved ports", told.contains("web 38080 → \(webTo)") && told.contains("Overterm's Up runs: "), told)

        // Back to the file's ports: forgotten, and the next Up asks again.
        if let project = docker.projects.first(where: { $0.name == name }) {
            page.verbs(for: project).first { $0.title == "Back to the File's Ports…" }?.perform()
        }
        check(
            "Back to the File's Ports forgets it",
            confirms == 2 && page.ports.override(in: real) == nil && !FileManager.default.fileExists(atPath: override), "\(confirms) confirmed")
        fake.set(mainWeb, state: .running)
        _ = await eventually(5) { docker.container(mainWeb)?.state == .running }
        page.actions?.choose = actions?.choose ?? { _, _, _, _ in }
        count = commands.count
        page.press("u")
        let sheet = await eventually(5) { self.window.attachedSheet != nil }
        let clicked = sheet && clickSheetButton("Up as Written")
        let upped = clicked ? await eventually(5) { commands.count == count + 1 } : false
        check(
            "and asks again at the next Up, through the window's own sheet",
            upped
                && commands.last?.command.hasSuffix("-p \(name) -f \(DockerCommands.quote(base)) up -d") == true
                && commands.last?.command.contains("Compose/Ports") == false && page.ports.override(in: real) == nil,
            "\(sheet) \(commands.last?.command ?? "nothing")")
        _ = await eventually(3) { self.window.attachedSheet == nil }
        page.actions?.choose = { title, detail, buttons, then in
            asked = (title, detail, buttons)
            then(0)
        }

        // An older Compose isn't asked to; with the check off, as written.
        try? "2.20.0\n".write(to: bin.appendingPathComponent("version"), atomically: true, encoding: .utf8)
        page.composeVersion = nil
        count = commands.count
        page.press("U")
        check(
            "an older Compose isn't asked to",
            await eventually(5) { page.error?.contains("2.24.4") == true } && commands.count == count + 1
                && commands.last?.command.hasSuffix("-p \(name) -f \(DockerCommands.quote(base)) up -d") == true && page.ports.override(in: real) == nil,
            "\(page.error ?? "") \(commands.last?.command ?? "")")
        page.error = nil
        Settings.shared.set("docker.checkPorts", .bool(false))
        asked = nil
        await page.up(.checkout(worktree))
        check(
            "with the check off, an Up runs as written",
            commands.last?.command == "DOCKER_HOST=unix://\(socket) docker compose up -d" && commands.last?.folder == worktree && asked == nil,
            commands.last?.command ?? "")
        Settings.shared.set("docker.checkPorts", nil)

        // A container of it that couldn't start: its conflict's own Up on
        // Free Ports, pressed as a person would.
        try? "2.29.7\n".write(to: bin.appendingPathComponent("version"), atomically: true, encoding: .utf8)
        page.composeVersion = nil
        fake.set(ownWeb, state: .created, error: "driver failed programming external connectivity: Bind for 0.0.0.0:38080 failed: port is already allocated")
        _ = await eventually(5) { docker.container(ownWeb)?.state == .created }
        if app.store.showingOverlay != .docker { app.showOverlay(.docker) }
        page.selection = [ownWeb]
        page.detailTab = .overview
        let conflicted = await eventually(5) {
            if case .container(let id, _, _, _) = page.session?.conflict?.holder { return id == mainWeb }
            return false
        }
        count = commands.count
        // The words' own place: Vision may read the box's two buttons as one
        // line, whose middle is between them.
        let button = conflicted ? await wordFrame("Up on Free Ports") : nil
        if let button { await click(at: CGPoint(x: button.midX, y: button.midY)) }
        // Its Up asks Compose (the stub) and lsof first: seconds on a busy machine.
        let movedAgain = button != nil ? await eventually(15) { commands.count == count + 1 } : false
        check(
            "a conflict's own Up on Free Ports moves its stack",
            movedAgain && commands.last?.command == upCommand && page.ports.override(in: real)?.moves.map(\.from) == [held, 38080] && alerts.isEmpty,
            "\(conflicted) \(button.map { "button at \($0)" } ?? "no button read") \(commands.last?.command ?? "nothing") \(page.error ?? "") \(alerts)")
        page.ports.forget(real)

        try? await docker.remove(ownWeb, force: true)
        try? await docker.remove(mainWeb, force: true)
        page.selection = []
        if let previous { app.store.select(previous) }
        if let tab, tab !== previous { app.closeTabsWithoutAsking([tab]) }
        // The changes pane finds the tab's repository a moment later.
        _ = await eventually(5) { self.app.diff.root.map(FileTreeModel.realPath) != real && !self.app.dockerPanelStack().isEmpty }
    }

    /// A compose project's services and what its files say, as a stub
    /// `docker` answers `compose config` the way Compose v5.6 does: what
    /// Watch watches and the profiles, read once a change of the files (the
    /// palette restocked when they come, View ▸ Compose Watch, the panel's
    /// menu); a service rebuilt, run once, pulled (recorded, never typed),
    /// restarted through the engine, its logs narrowed to it by the picker.
    private func composeServicesChecks(_ fake: FakeDockerEngine, web: String) async {
        let page = app.dockerPage
        let docker = DockerModel.shared
        guard let project = docker.projects.first(where: { $0.name == "ot-shop" }), let folder = project.workingDir,
            let db = docker.containers.first(where: { $0.name == "ot-shop-db-1" })?.Id
        else { return check("a compose project to act on", false, "\(docker.projects.map(\.name))") }
        let bin = scratch.appendingPathComponent("services-stub-bin", isDirectory: true)
        try? FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let stub = bin.appendingPathComponent("docker")
        let watched = #""web":{"build":{"context":"\#(folder)","dockerfile":"Dockerfile"},"develop":{"watch":[{"action":"sync","path":"\#(folder)/src","target":"/app/src"}]}}"#
        let script = #"""
            #!/bin/sh
            dir="$(dirname "$0")"
            echo "$*" >> "$dir/calls"
            case "$*" in
              *" config --format json"*)
                if [ -f "$dir/nowatch" ]; then echo '{"name":"ot-shop","services":{"db":{"image":"postgres:16"},"web":{"image":"nginx:1.27"}}}'
                else echo '{"name":"ot-shop","services":{"db":{"image":"postgres:16"},\#(watched)}}'; fi ;;
              *" config --profiles"*) printf 'debug\njobs\n' ;;
              *) echo "unexpected: $*" >&2; exit 1 ;;
            esac
            """#
        try? script.write(to: stub, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        DockerCLI.override = stub
        defer { DockerCLI.override = nil }
        /// What the stub was asked about this project.
        func calls() -> [String] {
            let calls = (try? String(contentsOf: bin.appendingPathComponent("calls"), encoding: .utf8)) ?? ""
            return calls.split(separator: "\n").map(String.init).filter { $0.hasPrefix("compose -p ot-shop ") }
        }
        var commands: [(command: String, folder: URL?)] = []
        let actions = page.actions
        page.actions?.run = { commands.append(($0, $1)) }
        defer { page.actions = actions }
        func offersWatch() -> Bool { app.palette.results.contains { $0.id == "a.composeWatch" } }

        // The window's Compose Watch, the page hidden: the palette asks
        // Compose, and is restocked when it answers — not shown again.
        app.hideOverlay(focus: false)
        check("the selected tab's stack is the project", app.dockerPanelStack().map(\.name) == ["ot-shop"], "\(app.dockerPanelStack().map(\.name))")
        // Saved again: whatever was read before the stub answered is stale.
        let file = URL(fileURLWithPath: folder).appendingPathComponent("compose.yaml")
        try? "services:\n  web:\n    build: .\n    develop:\n      watch:\n        - action: sync\n          path: ./src\n          target: /app/src\n  db:\n    image: postgres:16\n"
            .write(to: file, atomically: true, encoding: .utf8)
        app.showPalette(nil)
        let notYet = !offersWatch()
        let restocked = await eventually(5) { offersWatch() }
        check(
            "the palette offers Compose Watch once Compose answers, restocked", notYet && restocked,
            "\(notYet) \(app.palette.results.map(\.title)) \(String(describing: page.composeFacts["ot-shop"]))")
        check("for the stack's project", app.palette.results.first { $0.id == "a.composeWatch" }?.subtitle == "ot-shop")
        app.hidePalette()
        app.composeWatch(nil)
        check(
            "View ▸ Compose Watch is compose watch in a tab, in the project's folder",
            await eventually(5) { commands.last?.command.hasSuffix("\(folder)/compose.yaml watch") == true } && commands.last?.folder?.path == folder,
            "\(commands.map(\.command))")
        app.showOverlay(.docker)
        let tag = DockerPageModel.projectTag("ot-shop")
        page.showDetail = true
        page.selection = [tag]
        page.projectTab = .services
        func titles(_ verbs: [DockerVerb], _ place: DockerVerb.Place) -> [String] { verbs.filter { $0.place == place }.map(\.title) }

        _ = page.verbs(for: project)
        check(
            "a project's files say what Compose watches", await eventually(5) { page.composeFacts["ot-shop"]?.watched == ["web"] },
            "\(String(describing: page.composeFacts["ot-shop"])) \(calls())")
        check("and its profiles, as config --profiles lists them", page.composeFacts["ot-shop"]?.profiles == ["debug", "jobs"])
        for _ in 0..<3 { _ = page.verbs(for: project) }
        await pause(0.3)
        check("read once, not at every draw", calls().count == 2, "\(calls())")
        let verbs = page.verbs(for: project)
        check("Watch is offered for develop.watch, as a button", verbs.first { $0.title == "Watch in a Tab" }?.place == .button, "\(verbs.map(\.title))")
        await capture("services")
        var count = commands.count
        verbs.first { $0.title == "Watch in a Tab" }?.perform()
        check(
            "Watch is compose watch in a tab, in the project's folder",
            await eventually(5) { commands.count == count + 1 }
                && commands.last.map { $0.command.contains("docker compose -p ot-shop -f ") && $0.command.hasSuffix("\(folder)/compose.yaml watch") } == true
                && commands.last?.folder?.path == folder, "\(commands.last.map { "\($0)" } ?? "nothing")")
        count = commands.count
        page.press("w")
        check(
            "w watches the selected project", await eventually(5) { commands.count == count + 1 } && commands.last?.command.hasSuffix(" watch") == true,
            "\(commands.map(\.command))")

        verbs.first { $0.title == "Up With Profiles…" }?.perform()
        check(
            "Up With Profiles… lists the profiles",
            await eventually(5) { page.profileChoice?.profiles == ["debug", "jobs"] && self.window.attachedSheet != nil },
            "\(String(describing: page.profileChoice))")
        await capture("profiles")
        page.profileChoice?.chosen = ["jobs"]
        count = commands.count
        page.upWithProfiles()
        let closed = await eventually(3) { self.window.attachedSheet == nil }
        let upped = await eventually(5) { commands.count == count + 1 }
        check(
            "and ups with the ones ticked",
            closed && upped
                && commands.last.map { $0.command.hasSuffix(" --profile jobs up -d") && $0.command.contains(" -f ") } == true,
            commands.last?.command ?? "nothing")

        // The rail's panel menu: what the files say there too.
        let panelVerbs = app.dockerPanel.projectVerbs(project)
        check(
            "the panel's project menu has Watch, Rebuild and Up, and Up With Profiles…",
            ["Watch in a Tab", "Rebuild and Up in a Tab", "Up With Profiles…"].allSatisfy { title in panelVerbs.contains { $0.title == title } },
            "\(panelVerbs.map(\.title))")
        count = commands.count
        panelVerbs.first { $0.title == "Watch in a Tab" }?.perform()
        check(
            "its Watch is compose watch in a tab", await eventually(5) { commands.count == count + 1 } && commands.last?.command.hasSuffix(" watch") == true,
            "\(commands.map(\.command))")
        count = commands.count
        panelVerbs.first { $0.title == "Rebuild and Up in a Tab" }?.perform()
        check(
            "its Rebuild and Up is up --build of all of it",
            await eventually(5) { commands.count == count + 1 } && commands.last?.command.hasSuffix("/compose.yaml up -d --build") == true,
            commands.last?.command ?? "")

        // A service's verbs.
        guard let fresh = docker.projects.first(where: { $0.name == "ot-shop" }), let service = fresh.services.first(where: { $0.name == "web" }) else {
            return check("its web service", false)
        }
        let serviceVerbs = page.verbs(for: service, in: fresh)
        check(
            "a service's verbs as buttons, the rest behind More",
            titles(serviceVerbs, .button) == ["Rebuild and Start in a Tab", "Restart", "Show Its Logs"]
                && titles(serviceVerbs, .more) == ["Follow Its Logs in a Tab", "Pull in a Tab", "Run a One-Off in a Tab", "Copy Name"],
            "\(serviceVerbs.map(\.title))")
        count = commands.count
        serviceVerbs.first { $0.title == "Rebuild and Start in a Tab" }?.perform()
        check(
            "Rebuild is up --build of that service alone",
            await eventually(5) { commands.count == count + 1 }
                && commands.last.map { $0.command.hasSuffix(" up -d --build web") && $0.command.contains(" -f ") } == true, commands.last?.command ?? "")
        count = commands.count
        page.selection = [web]
        page.press("b")
        check(
            "b rebuilds the selected container's service",
            await eventually(5) { commands.count == count + 1 } && commands.last?.command.hasSuffix(" up -d --build web") == true,
            "\(commands.map(\.command))")
        page.selection = [tag]
        serviceVerbs.first { $0.title == "Run a One-Off in a Tab" }?.perform()
        check("Run a One-Off is compose run --rm", commands.last?.command.hasSuffix(" run --rm web") == true, commands.last?.command ?? "")
        serviceVerbs.first { $0.title == "Pull in a Tab" }?.perform()
        check("Pull pulls that service's image", commands.last?.command.hasSuffix(" pull web") == true, commands.last?.command ?? "")
        let before = fake.requests.count
        serviceVerbs.first { $0.title == "Restart" }?.perform()
        let restarted = await eventually(5) { fake.requests.dropFirst(before).contains { $0.contains("/containers/\(web)/restart") } }
        check(
            "Restart restarts that service's containers, not the rest",
            restarted && fake.requests.dropFirst(before).filter { $0.contains("/restart") }.allSatisfy { $0.contains(web) },
            "\(fake.requests.dropFirst(before).filter { $0.contains("/restart") })")
        _ = await eventually(5) { docker.container(web)?.state == .running }

        // Its logs: the project's, narrowed to it.
        func logText() -> String {
            (Self.find(NSTextView.self, in: app.dockerView) { $0.accessibilityIdentifier() == "docker.text" })?.string ?? ""
        }
        fake.log(web, "web-line-e2e")
        fake.log(db, "db-line-e2e")
        serviceVerbs.first { $0.title == "Show Its Logs" }?.perform()
        check("Show Its Logs opens the project's logs, on that service", page.projectTab == .logs && page.projectSession?.service == "web")
        // Both lines in the feed first: db's merely late would pass for filtered.
        func fed() -> [String] { page.projectSession?.feed.lines.map(\.message) ?? [] }
        let both = await eventually(5) { fed().contains("web-line-e2e") && fed().contains("db-line-e2e") }
        await pause(0.3)
        check("filtered to it", both && logText().contains("web-line-e2e") && !logText().contains("db-line-e2e"), "\(fed()) | \(logText().suffix(300))")
        check(
            "and the tab it follows in is that service's",
            page.projectSession?.feed.terminalCommand?.hasSuffix(" logs -f --tail 100 web") == true, page.projectSession?.feed.terminalCommand ?? "nil")
        // The picker over the log, as a click picks in it.
        func picker() -> NSPopUpButton? { Self.find(NSPopUpButton.self, in: app.dockerView) { $0.itemTitles.contains("All services") } }
        func pick(_ title: String) {
            guard let popup = picker(), let menu = popup.menu else { return }
            let index = popup.indexOfItem(withTitle: title)
            if index >= 0 { menu.performActionForItem(at: index) }
        }
        func wiring() -> String {
            guard let popup = picker() else { return "no picker" }
            return "button \(popup.action.map(NSStringFromSelector) ?? "-"), items \(popup.itemArray.map { $0.action.map(NSStringFromSelector) ?? "-" })"
        }
        check(
            "the log's picker lists the services, on the one shown", picker()?.itemTitles == ["All services", "db", "web"] && picker()?.titleOfSelectedItem == "web",
            "\(picker()?.itemTitles ?? []) \(picker()?.titleOfSelectedItem ?? "no picker")")
        pick("db")
        check(
            "db picked there shows db's lines alone",
            await eventually(5) { page.projectSession?.service == "db" && logText().contains("db-line-e2e") && !logText().contains("web-line-e2e") },
            "\(page.projectSession?.service ?? "all") \(wiring()) | \(logText().suffix(300))")
        check(
            "and follows db in a tab", page.projectSession?.feed.terminalCommand?.hasSuffix(" logs -f --tail 100 db") == true,
            page.projectSession?.feed.terminalCommand ?? "nil")
        pick("All services")
        check(
            "All services merges them again",
            await eventually(5) { page.projectSession?.service == nil && logText().contains("web-line-e2e") && logText().contains("db-line-e2e") },
            "\(page.projectSession?.service ?? "all") | \(logText().suffix(300))")
        // A service with nothing in the feed says so, not a blank pane.
        page.projectSession?.feed.clear()
        fake.log(web, "web-after-clear")
        _ = await eventually(5) { fed() == ["web-after-clear"] }
        pick("db")
        check(
            "a service with nothing to show says so, in place of the text",
            await eventually(5) {
                page.projectSession?.service == "db" && Self.find(NSTextView.self, in: self.app.dockerView) { $0.accessibilityIdentifier() == "docker.text" } == nil
            }, "\(fed()) | \(logText().suffix(100))")
        pick("All services")
        check("all of them shown again", await eventually(5) { logText().contains("web-after-clear") }, logText().suffix(100).description)

        // The files changed: read again; nothing to watch, Watch goes.
        FileManager.default.createFile(atPath: bin.appendingPathComponent("nowatch").path, contents: Data())
        try? "services:\n  web:\n    image: nginx:1.27\n  db:\n    image: postgres:16\n".write(to: file, atomically: true, encoding: .utf8)
        _ = page.verbs(for: fresh)
        check(
            "a change to its files is read again, and Watch goes without develop.watch",
            await eventually(5) { page.composeFacts["ot-shop"]?.watched == [] } && calls().count == 4
                && !page.verbs(for: fresh).contains { $0.title == "Watch in a Tab" }, "\(calls())")
        page.press("w")
        check("w says why it can't watch", await eventually(5) { page.error?.contains("develop.watch") == true }, page.error ?? "nothing")
        page.error = nil
        check("the panel's Watch goes with it", !app.dockerPanel.projectVerbs(fresh).contains { $0.title == "Watch in a Tab" })
        app.hideOverlay(focus: false)
        app.showPalette(nil)
        check("and the palette's", !offersWatch(), "\(app.palette.results.map(\.title))")
        app.hidePalette()
        count = commands.count
        app.composeWatch(nil)
        await pause(0.5)
        check("View ▸ Compose Watch types nothing then", commands.count == count, "\(commands.map(\.command).suffix(2))")
        app.showOverlay(.docker)
        page.projectTab = .logs
        page.press("1")
    }

    /// Emulation: amd64 images on the fake's arm64 engine, in the
    /// containerd store (Docker Desktop's), where an image's id is its
    /// index. A row shown asks for its image's platform, once; an emulated
    /// container says so on its row and its detail, whose box runs it
    /// natively in a tab — a service its files build built again, one they
    /// pull pulled and recreated, a lone container's image pulled. An
    /// image's own box pulls the variant through the engine: the image
    /// then says arm64, the containers made before still amd64. Hidden,
    /// the page asks nothing; the sidebar's panel asks for what it shows.
    /// What is drawn is read off the window. Commands recorded, pulls the
    /// fake's, Compose a stub.
    private func emulationChecks(_ fake: FakeDockerEngine) async {
        let page = app.dockerPage
        let docker = DockerModel.shared
        fake.containerdStore = true
        defer { fake.containerdStore = false }
        var commands: [(command: String, folder: URL?)] = []
        let actions = page.actions
        page.actions?.run = { commands.append(($0, $1)) }
        defer { page.actions = actions }
        let legacy = fake.addImage("ot/legacy:1", size: 30 << 20, architecture: "amd64")
        let native = fake.addImage("ot/native:1", size: 20 << 20, architecture: "arm64", variant: "v8")
        let spare = fake.addImage("ot/spare:1", size: 10 << 20, architecture: "amd64")
        // Its api is built (build: with an image: name), its worker pulled:
        // as its files say, which a stub Compose reads.
        let folder = scratch.appendingPathComponent("ot-legacy", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let real = FileTreeModel.realPath(folder)
        try? "services:\n  api:\n    build: .\n    image: ot/legacy:1\n  worker:\n    image: ot/legacy:1\n"
            .write(to: folder.appendingPathComponent("compose.yaml"), atomically: true, encoding: .utf8)
        let bin = scratch.appendingPathComponent("emulation-stub-bin", isDirectory: true)
        try? FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let stub = bin.appendingPathComponent("docker")
        let config = #"{"name":"ot-legacy","services":{"api":{"build":{"context":"\#(real)"},"image":"ot/legacy:1"},"worker":{"image":"ot/legacy:1"}}}"#
        let script = #"""
            #!/bin/sh
            case "$*" in
              *"-p ot-legacy "*" config --format json"*) echo '\#(config)' ;;
              *"-p ot-legacy "*" config --profiles"*) ;;
              *) echo "unexpected: $*" >&2; exit 1 ;;
            esac
            """#
        try? script.write(to: stub, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        DockerCLI.override = stub
        defer { DockerCLI.override = nil }
        let api = fake.add(name: "ot-legacy-api-1", image: "ot/legacy:1", project: "ot-legacy", workingDir: real, service: "api", imageID: legacy)
        let worker = fake.add(name: "ot-legacy-worker-1", image: "ot/legacy:1", project: "ot-legacy", workingDir: real, service: "worker", imageID: legacy)
        let tool = fake.add(name: "ot-legacy-tool", image: "ot/legacy:1", imageID: legacy)
        let fresh = fake.add(name: "ot-native", image: "ot/native:1", imageID: native)
        var late: String?
        var images = [legacy, native, spare]
        defer {
            page.filter = ""
            page.imageSelection = []
            page.selection = []
        }
        if app.store.showingOverlay != .docker { app.showOverlay(.docker) }
        page.press("1")
        page.selection = []
        // Only these rows: the list is shorter than the window.
        page.filter = "image:ot/"
        guard await eventually(5, { [api, worker, tool, fresh].allSatisfy { docker.container($0) != nil } }) else {
            return check("four containers to look at", false, "\(docker.containers.map(\.name))")
        }
        func summary(_ id: String) -> ContainerSummary? { docker.container(id) }
        func inspects(_ image: String) -> Int { fake.requests.filter { $0.hasSuffix("/images/\(image)/json") }.count }
        func allInspects() -> Int { fake.requests.filter { $0.contains("/images/sha256:") && $0.hasSuffix("/json") }.count }
        /// A check of what is drawn: failed, what the window shows.
        func drawn(_ name: String, _ line: (text: String, frame: CGRect)?, _ ok: (String) -> Bool = { _ in true }) async {
            let passed = line.map { ok($0.text) } ?? false
            var detail = line?.text ?? ""
            if line == nil { detail = await readWindow().map(\.text).joined(separator: " | ") }
            check(name, passed, detail)
        }

        check("the engine says its platform", docker.enginePlatform?.description == "linux/arm64", "\(docker.info?.Architecture ?? "none")")
        check(
            "an amd64 container on an arm64 engine is marked once its row shows",
            await eventually(5) { summary(api).flatMap(docker.emulation(of:))?.image.description == "linux/amd64" }, "\(docker.platforms)")
        await drawn("its row says amd64", await shownText { $0.contains("amd64") })
        check(
            "a native one isn't", await eventually(5) { docker.platforms[native] != nil } && summary(fresh).flatMap(docker.emulation(of:)) == nil,
            "\(docker.platforms[native]?.description ?? "not read")")
        await docker.reload()
        await docker.reload()
        page.selection = [api]
        page.detailTab = .overview
        await pause(0.3)
        check("an image is read once, not at every reload", inspects(legacy) == 1, "\(inspects(legacy)) reads")

        guard let apiSummary = summary(api), let workerSummary = summary(worker), let toolSummary = summary(tool), let freshSummary = summary(fresh) else {
            return check("the containers are still there", false)
        }
        // Built, as its files say once Compose has read them — not by its image's name.
        let rebuildTitle = "Rebuild as arm64 in a Tab"
        check(
            "a service its files build offers to build it again as arm64",
            await eventually(5) { page.verbs(for: apiSummary).contains { $0.title == rebuildTitle } },
            "\(page.verbs(for: apiSummary).map(\.title)) \(String(describing: page.composeFacts["ot-legacy"]))")
        check(
            "and so does the panel's menu", app.dockerPanel.verbs(apiSummary).contains { $0.title == rebuildTitle },
            "\(app.dockerPanel.verbs(apiSummary).map(\.title))")
        await drawn("its detail says it runs emulated", await shownText { $0.hasPrefix("Emulated:") }) { $0.contains("linux/amd64") }
        await drawn("and its Platform row", await shownText { $0.contains("emulated here") }) { $0.contains("linux/amd64") }
        await capture("emulated")
        let button = await shownText { $0.contains("Rebuild as arm64") }
        if let button { await click(at: CGPoint(x: button.frame.midX, y: button.frame.midY)) }
        let clicked = button != nil ? await eventually(5) { !commands.isEmpty } : false
        check("its box's button is that verb", clicked, button?.text ?? "no button read")
        if !clicked { page.verbs(for: apiSummary).first { $0.title == rebuildTitle }?.perform() }
        check(
            "which builds the service again for arm64, nothing pulled",
            await eventually(5) { !commands.isEmpty }
                && commands.last.map {
                    $0.command.hasPrefix("DOCKER_DEFAULT_PLATFORM=linux/arm64 ") && !$0.command.contains("docker pull")
                        && $0.command.hasSuffix(" -p ot-legacy -f \(real)/compose.yaml up -d --no-deps --force-recreate --build api")
                } == true,
            "\(button?.text ?? "no button read"): \(commands.last?.command ?? "nothing")")
        check("in its folder", commands.last?.folder.map(FileTreeModel.realPath) == real, commands.last?.folder?.path ?? "none")
        var count = commands.count
        page.verbs(for: workerSummary).first { $0.title == "Recreate as arm64 in a Tab" }?.perform()
        check(
            "a service its files pull pulls the variant and recreates the service alone",
            await eventually(5) { commands.count > count }
                && commands.last?.command.contains("docker pull --platform linux/arm64 ot/legacy:1 && DOCKER_DEFAULT_PLATFORM=linux/arm64 ") == true
                && commands.last?.command.hasSuffix(" up -d --no-deps --force-recreate worker") == true,
            "\(page.verbs(for: workerSummary).map(\.title)): \(commands.last?.command ?? "nothing")")
        count = commands.count
        page.verbs(for: toolSummary).first { $0.title == "Pull the arm64 Variant in a Tab" }?.perform()
        check(
            "a lone container's pulls the variant",
            commands.count > count && commands.last?.command.hasSuffix("docker pull --platform linux/arm64 ot/legacy:1") == true, commands.last?.command ?? "nothing")
        check("a native container has none", !page.verbs(for: freshSummary).contains { $0.title.contains("arm64") })
        page.selection = []

        // The images: their platforms, the image's own box.
        page.press("2")
        page.filter = "ot/"
        check(
            "the image list knows each one's platform, an image no container uses too",
            await eventually(5) { docker.platforms[spare]?.description == "linux/amd64" && docker.emulation(ofImage: legacy) != nil },
            "\(docker.platforms)")
        await drawn("and says it under its name", await shownText { $0.contains("linux/amd64") })
        page.imageSelection = [legacy]
        await drawn("an emulated image's detail says so", await shownText { $0.hasPrefix("Emulated:") }) { $0.contains("linux/amd64") }
        // Vision reads the row's parts as lines of their own — the label,
        // "linux/amd64 -", "emulated" — so they are looked for side by side.
        let platformLabel = await shownText { $0 == "Platform" }
        var platformRow = false
        var platformRead: [String] = []
        if let label = platformLabel {
            platformRead = await readWindow().filter { abs($0.frame.midY - label.frame.midY) < label.frame.height }.map(\.text)
            platformRow = platformRead.contains { $0.contains("linux/amd64") } && platformRead.contains { $0.contains("emulated") }
        }
        check("with its Platform row", platformRow, platformLabel == nil ? "not drawn" : "\(platformRead)")
        await capture("emulated-image")
        let read = inspects(legacy)
        let pullButton = await shownText { $0.contains("Pull the arm64") }
        if let pullButton { await click(at: CGPoint(x: pullButton.frame.midX, y: pullButton.frame.midY)) }
        let key = "ot/legacy:1 (linux/arm64)"
        let pulled = await eventually(5) {
            fake.requests.contains { $0.hasPrefix("POST /v1.47/images/create?") && $0.contains("platform=linux/arm64") }
                && page.pulls[key]?.done == true && page.pulls[key]?.error == nil
        }
        check("its box's button pulls the arm64 variant through the engine", pullButton != nil && pulled, "\(pullButton?.text ?? "no button read"): \(page.pulls[key]?.summary ?? "no pull")")
        check(
            "the image then says arm64: its index holds the variant now",
            await eventually(5) { inspects(legacy) > read && docker.platforms[legacy]?.architecture == "arm64" && docker.emulation(ofImage: legacy) == nil },
            "\(inspects(legacy)) reads, \(docker.platforms[legacy]?.description ?? "none")")
        await pause(0.3)
        let gone = await readWindow()
        check("and its box is gone", !gone.contains { $0.text.hasPrefix("Emulated:") }, gone.map(\.text).joined(separator: " | "))
        page.imageSelection = []

        // The containers made from it before still run amd64, and say so.
        page.press("1")
        page.filter = "image:ot/"
        check(
            "while the containers made from it before still run amd64",
            await eventually(5) { [api, worker, tool].allSatisfy { summary($0).flatMap(docker.emulation(of:)) != nil } },
            "\(docker.containerPlatforms)")
        await drawn("their rows say so", await shownText { $0.contains("amd64") })
        page.pull("amd64only/tool:1", platform: docker.enginePlatform)
        let refused = "amd64only/tool:1 (linux/arm64)"
        check(
            "an image with no arm64 variant says so",
            await eventually(5) { page.pulls[refused]?.error?.contains("no linux/arm64 variant") == true }, page.pulls[refused]?.error ?? "")

        // Hidden, the page asks nothing: not at an image event, nor for a
        // container new since. The sidebar's panel asks for what it shows.
        page.press("2")
        page.filter = "ot/"
        _ = await eventually(3) { docker.images.contains { $0.Id == legacy } }
        await pause(0.4)
        app.hideOverlay(focus: false)
        let sidebar = app.sidebarPanel.panel
        if sidebar == .docker { app.sidebarPanel.panel = .files }
        _ = await eventually(3) { !self.app.dockerPanelShown && !self.app.dockerPanel.slotVisible }
        let before = allInspects()
        if let engine = docker.engine {
            do { for try await _ in engine.pull("ot/other:1") {} } catch { check("an image pulled", false, error.localizedDescription) }
        }
        let lateImage = fake.addImage("ot/late:1", size: 5 << 20, architecture: "amd64")
        images += [lateImage]
        late = fake.add(name: "ot-late", image: "ot/late:1", imageID: lateImage)
        _ = await eventually(3) { late.flatMap(docker.container) != nil }
        await pause(0.8)
        check(
            "hidden, the page asks nothing again at an image event, nor for what is new",
            allInspects() == before && !self.app.dockerPanelShown, "\(allInspects() - before) reads, panel shown \(app.dockerPanelShown)")
        app.showDockerPanel(nil)
        check(
            "the sidebar's panel asks for what it shows",
            await eventually(5) { late.flatMap(docker.container).flatMap(docker.emulation(of:)) != nil }, "\(allInspects() - before) reads")
        app.sidebarPanel.panel = sidebar == .docker ? .docker : .files
        let panelRead = allInspects()
        app.showOverlay(.docker)
        check("shown again, the page's rows ask again", await eventually(5) { allInspects() > panelRead }, "\(allInspects() - panelRead) reads")

        page.dismissPull(key)
        page.dismissPull(refused)
        for id in [api, worker, tool, fresh] + [late].compactMap({ $0 }) { try? await docker.remove(id, force: true) }
        for image in images { try? await docker.engine?.remove(image: image, force: true) }
        if let other = docker.images.first(where: { $0.tags.contains("ot/other:1") }) { try? await docker.engine?.remove(image: other.Id, force: true) }
        page.filter = ""
        page.press("1")
    }

    /// Model Runner's models: an engine with none says what installs one;
    /// a runner container's are listed, chatted with, removed — its API at
    /// the container's port, never `docker model` (which installs one).
    private func modelsChecks(_ fake: FakeDockerEngine) async {
        let page = app.dockerPage
        let docker = DockerModel.shared
        var commands: [String] = []
        let actions = page.actions
        page.actions?.run = { command, _ in commands.append(command) }
        page.actions?.confirm = { _, _, _, then in then() }
        defer { page.actions = actions }
        page.press("6")
        check("6 is Models", page.section == .models)
        check(
            "an engine with no runner says so",
            await eventually(5) { page.modelsPlace == .absent(command: "docker model install-runner") && page.models == nil },
            "\(String(describing: page.modelsPlace))")
        page.startModelRunner()
        check("and installs one only when asked, in a tab", commands.last?.hasSuffix("docker model install-runner") == true, commands.last ?? "")
        guard let port = try? fake.listenTCP() else { return check("the runner's port", false) }
        fake.setModelRunner([.init(tag: "ai/smollm2:latest", loaded: true), .init(tag: "ai/gemma3:latest")])
        let runner = fake.add(
            name: "docker-model-runner", image: "docker/model-runner:latest",
            ports: [DockerPort(IP: "127.0.0.1", PrivatePort: 12434, PublicPort: port, Type: "tcp")])
        check("a runner's container is found", await eventually(5) { docker.container(runner) != nil })
        page.loadModels()
        check(
            "and its models listed", await eventually(5) { page.models?.models.map(\.name) == ["gemma3", "smollm2"] },
            "\(page.models?.models.map(\.name) ?? []) \(page.modelsError ?? "")")
        check("which of them is loaded", page.models?.running.map(\.model_name) == ["ai/smollm2:latest"])
        check("where a program reaches them", ModelRunner.endpoints(page.modelsPlace ?? .remote)?.mac == "http://localhost:\(port)/engines/v1")
        page.modelSelection = Set(page.models?.models.filter { $0.name == "smollm2" }.map(\.id) ?? [])
        _ = page.press("n")
        check("n chats with it in a tab", commands.last?.hasSuffix("docker model run ai/smollm2:latest") == true, commands.last ?? "")
        page.showDetail = true
        if let model = page.selectedModels.first {
            check("a model's detail has Chat and Copy as buttons", page.verbs(for: model).filter { $0.place == .button }.map(\.title) == ["Chat in a Tab", "Copy Name"])
        }
        await capture("model")
        _ = page.press("\u{7F}")
        check(
            "⌫ removes it, asked first", await eventually(5) { fake.modelRunnerTags == ["ai/gemma3:latest"] && page.models?.models.count == 1 },
            "\(fake.modelRunnerTags ?? [])")
        try? await docker.remove(runner, force: true)
        page.press("1")
    }

    /// Docker's MCP Toolkit beside the agents, as a stub `docker` answers
    /// `docker mcp client ls`; connecting one is a tab's command.
    private func mcpToolkitChecks() async {
        let page = app.dockerPage
        check("no Toolkit read in an isolated run without a stub", page.mcpClients == nil)
        let bin = scratch.appendingPathComponent("mcp-stub-bin", isDirectory: true)
        try? FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let stub = bin.appendingPathComponent("docker")
        let script = """
            #!/bin/sh
            case "$*" in
              "mcp client ls --global --json") echo '{"claude-code":{"displayName":"Claude Code","dockerMCPCatalogConnected":true,"isInstalled":true},"codex":{"displayName":"Codex","dockerMCPCatalogConnected":false,"isInstalled":true}}' ;;
              *) echo "unexpected: $*" >&2; exit 1 ;;
            esac
            """
        try? script.write(to: stub, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        DockerCLI.override = stub
        defer { DockerCLI.override = nil }
        page.loadMCPToolkit()
        check(
            "the Toolkit says which agents reach its servers",
            await eventually(5) { page.mcpClients?.map { "\($0.id) \($0.connected)" } == ["claude-code true", "codex false"] },
            "\(page.mcpClients ?? [])")
        var commands: [String] = []
        let actions = page.actions
        page.actions?.run = { command, _ in commands.append(command) }
        if let codex = page.mcpClients?.last { page.toggleMCP(codex) }
        page.actions = actions
        check("Connect is the Toolkit's own command, in a tab", commands == ["docker mcp client connect --global codex"], "\(commands)")
        page.press("6")
        await capture("models")
        page.press("1")
    }

    /// A checkout's compose project before any of it runs: read through a
    /// stub `docker` answering `compose config` as Compose would, only while
    /// Docker shows, again when a compose file changes; listed in the panel
    /// and on the page as a stopped project, until one of its name exists.
    private func plannedChecks(_ fake: FakeDockerEngine, socket: String) async {
        let docker = DockerModel.shared
        let page = app.dockerPage
        let panel = app.dockerPanel
        let compose = panel.checkoutCompose
        let plan = scratch.appendingPathComponent("ot-plan", isDirectory: true)
        try? FileManager.default.createDirectory(at: plan, withIntermediateDirectories: true)
        try? await git(["init", "-q", "-b", "main"], in: plan)
        let real = FileTreeModel.realPath(plan)
        func write(_ text: String, _ name: String) {
            try? text.write(to: plan.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        /// What the stub answers: Compose's JSON, the secrets in it as Compose gives them.
        func config(worker: Bool = false, watch: Bool = false) -> String {
            let develop = watch ? #""develop":{"watch":[{"action":"sync","path":"\#(real)/src","target":"/app"}]},"# : ""
            let services =
                [
                    #""api":{"build":{"context":"\#(real)","dockerfile":"Dockerfile"},"# + develop + #""environment":{"API_TOKEN":"s3cr3t-plan"},"#
                        + #""ports":[{"mode":"ingress","target":8080,"published":"58081","protocol":"tcp"}]}"#,
                    #""cache":{"image":"redis:7"}"#,
                    #""db":{"image":"postgres:16","environment":{"POSTGRES_PASSWORD":"hunter2"},"#
                        + #""ports":[{"mode":"ingress","target":5432,"published":"55433","protocol":"tcp"}]}"#,
                    #""web":{"image":"nginx:1.27","deploy":{"replicas":2},"#
                        + #""depends_on":{"api":{"condition":"service_started","required":true},"db":{"condition":"service_healthy","required":true}}}"#,
                ] + (worker ? [#""worker":{"image":"busybox"}"#] : [])
            return #"{"name":"ot-plan","services":{\#(services.joined(separator: ","))}}"#
        }
        write("services:\n  web:\n    build: .\n", "compose.yaml")
        write(config(), ".ot-config.json")
        let bin = scratch.appendingPathComponent("compose-stub-bin", isDirectory: true)
        try? FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let stub = bin.appendingPathComponent("docker")
        let script = #"""
            #!/bin/sh
            dir="$(dirname "$0")"
            here="$(pwd -P)"
            echo "$*|$here" >> "$dir/calls"
            case "$*" in
              "compose config --format json --no-env-resolution")
                if [ -f "$here/.broken" ]; then
                  echo 'time="2026-10-29T00:00:00Z" level=warning msg="The \"TAG\" variable is not set. Defaulting to a blank string."' >&2
                  echo "error while interpolating services.api.image: required variable TAG is missing a value" >&2
                  exit 1
                fi
                if [ -f "$here/.old-compose" ]; then echo "unknown flag: --no-env-resolution" >&2; exit 1; fi
                cat "$here/.ot-config.json" ;;
              "compose config --format json") cat "$here/.ot-config.json" ;;
              "compose config --no-env-resolution") cat "$here/.ot-resolved.txt" ;;
              *) echo "unexpected: $*" >&2; exit 1 ;;
            esac
            """#
        try? script.write(to: stub, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        DockerCLI.override = stub
        defer { DockerCLI.override = nil }
        /// What the stub was asked in the checkout, in order.
        func calls() -> [String] {
            let calls = (try? String(contentsOf: bin.appendingPathComponent("calls"), encoding: .utf8)) ?? ""
            return calls.split(separator: "\n").filter { $0.hasSuffix("|" + real) }.map { String($0.dropLast(real.count + 1)) }
        }
        func reads() -> Int { calls().filter { $0.hasPrefix("compose config --format json") }.count }
        /// Whether a file under Overterm's own folder holds `text`.
        func supportHolds(_ text: String) -> Bool {
            let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
            let files = FileManager.default.enumerator(at: AppEnvironment.supportDirectory, includingPropertiesForKeys: keys)
            while let file = files?.nextObject() as? URL {
                let values = try? file.resourceValues(forKeys: Set(keys))
                guard values?.isRegularFile == true, (values?.fileSize ?? 0) < 8_000_000, let data = try? Data(contentsOf: file) else { continue }
                if data.range(of: Data(text.utf8)) != nil { return true }
            }
            return false
        }
        var commands: [(command: String, folder: URL?)] = []
        var confirmed: [String] = []
        let actions = page.actions
        page.actions?.run = { commands.append(($0, $1)) }
        page.actions?.confirm = { title, _, _, then in
            confirmed.append(title)
            then()
        }
        defer { page.actions = actions }
        let previous = app.store.selected
        app.newTab(in: plan)
        let tab = app.store.selected
        defer {
            if let previous { app.store.select(previous) }
            if let tab, tab !== previous { app.closeTabsWithoutAsking([tab]) }
        }

        check(
            "a new tab's checkout is the panel's", await eventually(5) { panel.checkout.map(FileTreeModel.realPath) == real },
            panel.checkout?.path ?? "nil")
        await pause(0.5)
        check("its compose file isn't read while nothing shows Docker", reads() == 0 && compose.project == nil, "\(reads()) reads")
        app.showDockerPanel(nil)
        check("the panel shows it: Compose reads the file", await eventually(5) { panel.plan?.name == "ot-plan" }, compose.error ?? "nothing")
        let read = panel.plan
        check(
            "a stopped project with its services, none created",
            read?.services.map(\.name) == ["api", "cache", "db", "web"] && read?.planned == true && read?.containers.isEmpty == true
                && read?.status == .stopped && read?.expected == 5, "\(read.map { "\($0.services.map(\.name)) \($0.expected)" } ?? "nil")")
        check("read once", reads() == 1, "\(reads())")
        let service = { (name: String) in read?.services.first { $0.name == name } }
        check(
            "what each runs, its secrets not kept",
            service("db")?.spec?.image == "postgres:16" && service("db")?.spec?.ports.first?.published == "55433"
                && service("api")?.spec?.buildContext == real && service("web")?.dependsOn == ["api", "db"]
                && !String(describing: read).contains("hunter2") && !String(describing: read).contains("s3cr3t-plan"))
        await capture("panel-planned")
        if let read { panel.projectVerbs(read).first { $0.key == "u" }?.perform() }
        // An Up looks at its ports first: the stub's Compose doesn't say its
        // version, so it goes up as written.
        check(
            "the panel's Up is compose up in the checkout, told which engine, the name left to the files",
            await eventually(5) { !commands.isEmpty } && commands.last?.command == "DOCKER_HOST=unix://\(socket) docker compose up -d"
                && commands.last?.folder.map(FileTreeModel.realPath) == real && confirmed.isEmpty, "\(commands.last.map { "\($0)" } ?? "nothing")")
        let verbs = read.map { page.verbs(for: $0) } ?? []
        check(
            "a planned project's verbs are what can be done before it runs",
            verbs.filter { $0.place == .button }.map(\.title) == ["Up (in a Tab)", "Pull Images in a Tab"] && !verbs.contains { $0.place == .remove },
            "\(verbs.map(\.title))")

        // The page lists it among the projects.
        app.toggleDockerPage(nil)
        page.section = .containers
        let tag = DockerPageModel.projectTag("ot-plan")
        func group() -> DockerListGroup? { page.groups.first { $0.id == tag } }
        check(
            "the page lists it among the projects",
            await eventually(5) { group()?.project?.planned == true && group()?.services.map(\.name) == ["api", "cache", "db", "web"] },
            "\(page.groups.map(\.id))")
        await capture("page-planned")
        page.selection = [tag]
        check("selected, its detail is the plan", page.detailedProject?.planned == true)
        await capture("project-planned")
        let before = commands.count
        page.press("u")
        check(
            "u brings it up from the page",
            await eventually(5) { commands.count == before + 1 } && commands.last?.command.hasSuffix(" docker compose up -d") == true,
            "\(commands.map(\.command))")
        if let db = group()?.services.first(where: { $0.name == "db" }) { page.selection = [DockerPageModel.serviceTag(db)] }
        page.press("D")
        check(
            "a service row stands for its project, and D has nothing to take down",
            page.selectedProject?.name == "ot-plan" && commands.count == before + 1, "\(page.selection)")
        page.selection = []
        page.filter = "image:redis"
        check("the filter reads its services", group()?.services.map(\.name) == ["cache"], "\(group()?.services.map(\.name) ?? [])")
        page.filter = ""
        page.runningOnly = true
        check("Running only leaves it out", group() == nil)
        page.runningOnly = false

        // An edit is read again; a file Compose doesn't read isn't.
        var count = reads()
        write(config(worker: true), ".ot-config.json")
        write("services:\n  web:\n    build: .\n  worker:\n    image: busybox\n", "compose.yaml")
        check(
            "an edit to the compose file is read again",
            await eventually(5) { panel.plan?.services.map(\.name).contains("worker") == true } && reads() == count + 1, "\(reads() - count) reads")
        count = reads()
        write("# ot-plan\n", "README.md")
        await pause(1.2)
        check("a file Compose doesn't read isn't", reads() == count, "\(reads() - count) reads")

        // What Compose says when it can't: its own words, the last services kept.
        FileManager.default.createFile(atPath: plan.appendingPathComponent(".broken").path, contents: Data())
        write("services:\n  web:\n    image: ${TAG:?}\n", "compose.yaml")
        check(
            "what Compose says when it can't, its warnings left out",
            await eventually(5) { compose.error == "error while interpolating services.api.image: required variable TAG is missing a value" },
            compose.error ?? "nothing")
        check("the services it read last stay", panel.plan?.services.map(\.name).contains("worker") == true)
        try? FileManager.default.removeItem(at: plan.appendingPathComponent(".broken"))
        write("services:\n  web:\n    build: .\n", "compose.yaml")
        check("and a good read clears it", await eventually(5) { compose.error == nil }, compose.error ?? "")

        // Compose before 2.35 doesn't know --no-env-resolution: asked again without it.
        var asked = calls().count
        FileManager.default.createFile(atPath: plan.appendingPathComponent(".old-compose").path, contents: Data())
        write(config(), ".ot-config.json")
        write("services:\n  web:\n    image: nginx\n", "compose.yaml")
        check(
            "Compose before 2.35 is asked again without --no-env-resolution",
            await eventually(5) { panel.plan?.services.map(\.name) == ["api", "cache", "db", "web"] && compose.error == nil }
                && Array(calls().dropFirst(asked)) == ["compose config --format json --no-env-resolution", "compose config --format json"],
            "\(calls().dropFirst(asked)) \(compose.error ?? "")")
        try? FileManager.default.removeItem(at: plan.appendingPathComponent(".old-compose"))

        // What Compose makes of it, in the editor: a copy, its secrets masked, gone with its tab.
        write("DB_PASSWORD=hunter2-plan\n", ".env")
        write(
            "name: ot-plan\nservices:\n  db:\n    command:\n      - --requirepass\n      - hunter2-plan\n    environment:\n"
                + "      POSTGRES_PASSWORD: hunter2-plan\n      POSTGRES_DB: shop\n    image: postgres:16\n", ".ot-resolved.txt")
        _ = await eventually(5) { !compose.reading && compose.isCurrent }
        asked = calls().count
        if let mine = panel.plan { page.showResolvedConfig(mine) }
        let shown = await eventually(10) {
            self.app.editor?.active?.url?.lastPathComponent == "ot-plan.resolved.yaml"
                && self.app.editor?.textView?.string.contains("POSTGRES_PASSWORD: ••••••") == true
        }
        let text = app.editor?.textView?.string ?? ""
        check(
            "its resolved config opens in the editor, what .env filled in masked",
            shown && !text.contains("hunter2-plan") && text.contains("POSTGRES_DB: shop") && text.contains("      - ••••••"),
            "\(page.error ?? "") \(text.prefix(400))")
        check(
            "asked in the checkout without -p, env files left out", Array(calls().dropFirst(asked)) == ["compose config --no-env-resolution"],
            "\(calls().dropFirst(asked))")
        check("nothing under Overterm's folder holds a secret from .env", !supportHolds("hunter2-plan"))
        let copy = app.editor?.active?.url
        if let editor = app.editor, let index = editor.buffers.firstIndex(where: { $0.url == copy }) { editor.closeBuffer(at: index) }
        check(
            "closing its tab removes the copy", await eventually(3) { copy.map { !FileManager.default.fileExists(atPath: $0.path) } ?? false },
            copy?.path ?? "no copy")
        if app.store.showingOverlay != .docker { app.toggleDockerPage(nil) }
        page.section = .containers

        // Its containers made, the labels' project takes over; gone, the plan is back.
        let made = fake.add(name: "ot-plan-db-1", image: "postgres:16", project: "ot-plan", workingDir: real, service: "db")
        check(
            "once its containers exist, the labels' project takes over",
            await eventually(5) {
                panel.here.map(\.name) == ["ot-plan"] && panel.plan == nil
                    && page.groups.filter { $0.id == tag }.map { $0.project?.planned } == [false]
            }, "\(page.groups.map(\.id))")
        try? await docker.remove(made, force: true)
        check("gone again, the plan is back", await eventually(5) { panel.plan != nil && page.planned != nil })

        // Started from its files under another name (`-p`, the shell's
        // COMPOSE_PROJECT_NAME): that is its stack, not a second one to make.
        let custom = fake.add(name: "ot-custom-web-1", image: "nginx:1.27", project: "ot-custom", workingDir: real, service: "web")
        check(
            "one made from its files under another name takes its place too",
            await eventually(5) { panel.here.map(\.name) == ["ot-custom"] && panel.plan == nil && page.planned == nil && group() == nil },
            "\(panel.here.map(\.name)) \(page.groups.map(\.id))")
        try? await docker.remove(custom, force: true)
        _ = await eventually(5) { panel.plan != nil && page.planned != nil }

        // One of its name from another folder: the page's row; Up from here asks.
        let other = fake.add(name: "ot-plan-db-1", image: "postgres:16", state: .exited, project: "ot-plan", workingDir: "/elsewhere/ot-plan", service: "db")
        check(
            "a stack of its name from another folder is the page's row",
            await eventually(5) { page.planned == nil && page.groups.filter { $0.id == tag }.count == 1 && docker.container(other) != nil })
        check(
            "the panel still lists this checkout's, saying where the other runs",
            panel.plan != nil && panel.planElsewhere?.workingDir == "/elsewhere/ot-plan", panel.planElsewhere?.workingDir ?? "nil")
        let ran = commands.count
        if let mine = panel.plan { panel.projectVerbs(mine).first { $0.key == "u" }?.perform() }
        check(
            "Up asks first: it would take that stack over",
            await eventually(5) { commands.count == ran + 1 } && confirmed.last?.contains("ot-plan") == true, "\(confirmed)")
        try? await docker.remove(other, force: true)
        _ = await eventually(5) { docker.container(other) == nil }

        // A service of the plan with develop.watch: Compose Watch with no
        // stack is the plan's, as Compose Up is.
        write(config(watch: true), ".ot-config.json")
        write("services:\n  api:\n    build: .\n    develop:\n      watch:\n        - action: sync\n          path: ./src\n          target: /app\n", "compose.yaml")
        check(
            "a plan with develop.watch offers Watch",
            await eventually(5) { panel.currentPlan?.services.contains { $0.spec?.watched == true } == true }
                && panel.currentPlan.map { page.verbs(for: $0).contains { $0.title == "Watch in a Tab" } } == true,
            "\(panel.currentPlan?.services.map(\.name) ?? [])")
        app.showPalette(nil)
        check(
            "the palette's Compose Watch is the plan's", app.palette.results.first { $0.id == "a.composeWatch" }?.subtitle == "ot-plan",
            "\(app.palette.results.map(\.title))")
        app.hidePalette()
        let watching = commands.count
        app.composeWatch(nil)
        check(
            "and View ▸ Compose Watch is compose watch in the checkout, the name left to the files",
            await eventually(5) { commands.count == watching + 1 } && commands.last?.command == "DOCKER_HOST=unix://\(socket) docker compose watch"
                && commands.last?.folder.map(FileTreeModel.realPath) == real, "\(commands.last.map { "\($0)" } ?? "nothing")")
        write(config(), ".ot-config.json")

        // Nothing read while nothing shows Docker; shown again, read again.
        app.hideOverlay()
        app.sidebarPanel.panel = .files
        _ = await eventually(3) { !self.app.dockerPanelShown }
        count = reads()
        write("services:\n  web:\n    build: .\n  # hidden\n", "compose.yaml")
        await pause(1.0)
        check("nothing read while nothing shows Docker", reads() == count, "\(reads() - count) reads")
        check(
            "and the menus don't act on what was read before the files changed", panel.plan != nil && panel.currentPlan == nil,
            "\(panel.currentPlan?.name ?? "nil")")
        app.showDockerPanel(nil)
        check("shown again, it is read again", await eventually(5) { reads() == count + 1 }, "\(reads() - count) reads")
        app.sidebarPanel.panel = .files
        _ = await eventually(3) { !self.app.dockerPanelShown }
    }

    /// The same engine as a remote one, `ssh://` to a throwaway sshd on
    /// 127.0.0.1 with its socket forwarded — what an ssh context does.
    private func remoteChecks(socket: String, web: String, folder: URL) async {
        let host: FakeSSHHost
        do {
            host = try FakeSSHHost.start()
        } catch {
            return note("no remote engine checks: \(error)")
        }
        DockerSSHForward.testOptions = host.options
        defer {
            DockerSSHForwards.closeAll()
            DockerSSHForward.testOptions = []
            host.stop()
        }
        let docker = DockerModel.shared
        let page = app.dockerPage
        let target = DockerSSHTarget(host: "127.0.0.1", port: host.port, socket: socket)
        docker.use(DockerEndpoint(address: .ssh(target), context: nil, source: "OVERTERM_DOCKER_HOST"))
        check("an ssh:// engine is reached through its host", await eventually(10) { docker.connection.isRunning }, "\(docker.connection)")
        check(
            "and lists what a local one does", await eventually(5) { page.groups.map(\.id) == ["project:ot-shop", "loose"] }, "\(page.groups.map(\.id))")
        check(
            "as an engine on that host, never this Mac's Docker Desktop", docker.runtime == .engine && docker.publishedHost == "127.0.0.1",
            "\(docker.runtime) \(docker.publishedHost ?? "nil")")
        check(
            "its ports open on the host", docker.container(web).flatMap { docker.ports(of: $0).first?.url?.absoluteString } == "http://127.0.0.1:58080")
        if let tab = app.store.tabs.first(where: { $0.workingDirectory == folder.path }) {
            app.updateContainerPorts(of: tab)
            check("and aren't the checkout's own servers", tab.containerPorts.isEmpty, "\(tab.containerPorts)")
        }
        page.selection = []
        page.selection = [web]
        page.detailTab = .logs
        check("its logs come over the same ssh", await eventually(5) { page.session?.lines.isEmpty == false })
        page.section = .containers
        check("and what they use, over the same ssh", await eventually(5) { page.usage[web] != nil }, "polling \(docker.usage.isPolling)")
        docker.use(DockerEndpoint(address: .unix(socket), context: nil, source: "OVERTERM_DOCKER_HOST"))
        let forwarded = DockerSSHForward.localSocket(for: target)
        check("switched away, its ssh is closed", await eventually(3) { !FileManager.default.fileExists(atPath: forwarded) })
        check("and the local engine is back", await eventually(5) { docker.connection.isRunning && docker.publishedHost == nil })
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
        // The list's CPU and memory, read faster than a person needs.
        docker.usage.interval = .milliseconds(300)
        docker.usage.first = .milliseconds(100)

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
        await filesTransferChecks(fake, web: web)
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
        // The editor focuses itself a moment after a file opens: under load
        // that can land after the page came back. The list has it now.
        _ = await eventually(5) {
            if !self.app.dockerListHasKeyboard() { self.app.focusDockerList() }
            return self.app.dockerListHasKeyboard()
        }
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
            await eventually(5) { !commands.isEmpty }
                && commands.last?.hasPrefix("DOCKER_HOST=unix://\(socket) docker compose -p ot-shop -f ") == true && commands.last?.hasSuffix(" up -d") == true,
            commands.last ?? "nothing")
        page.selection = [web]
        _ = page.press("e")
        check("e is a shell in it", commands.last?.contains("docker exec -it ot-shop-web-1 sh -c") == true, commands.last ?? "")
        // New Task can start the new worktree's own stack.
        let repo = scratch.appendingPathComponent("ot-stack-repo", isDirectory: true)
        try? FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try? "services:\n  web:\n    image: nginx:1.27\n".write(to: repo.appendingPathComponent("compose.yaml"), atomically: true, encoding: .utf8)
        try? await git(["init", "-q", "-b", "main"], in: repo)
        try? await git(["add", "."], in: repo)
        try? await git(["-c", "user.email=e2e@overterm", "-c", "user.name=e2e", "commit", "-q", "-m", "stack"], in: repo)
        var stackFolder: URL?
        let recorder = page.actions?.run
        page.actions?.run = { command, folder in
            commands.append(command)
            stackFolder = folder
        }
        // Compose (a stub) says the stack's port, which nothing holds.
        let free = (41_000...41_999).first { !ListeningPorts.isBound($0) } ?? 41_000
        let freeStub = composeStub(
            "free-ports-stub-bin",
            json: #"{"name":"ot-free-stack","services":{"web":{"image":"nginx:1.27","ports":[{"mode":"ingress","target":80,"published":"\#(free)","protocol":"tcp"}]}}}"#)
        DockerCLI.override = freeStub.appendingPathComponent("docker")
        page.composeVersion = nil
        var questions = 0
        let chooser = page.actions?.choose
        page.actions?.choose = { _, _, _, _ in questions += 1 }
        do {
            try await app.createTask(repo: repo, branch: "feat/stack", base: "main", agent: nil, startStack: true)
            check(
                "New Task starts the new worktree's stack",
                commands.last?.hasSuffix("docker compose up -d") == true && stackFolder.map { ComposeProjects.composeFile(in: $0) != nil } == true
                    && stackFolder?.path != repo.path, "\(commands.last ?? "") in \(stackFolder?.path ?? "nothing")")
            let asked = (try? String(contentsOf: freeStub.appendingPathComponent("stub.log"), encoding: .utf8)) ?? ""
            check(
                "a stack whose ports are free starts without a question",
                asked.contains(" config --format json") && questions == 0 && window.attachedSheet == nil, asked.isEmpty ? "Compose wasn't asked" : asked)
        } catch {
            check("New Task with its stack", false, error.localizedDescription)
        }
        DockerCLI.override = nil
        page.composeVersion = nil
        page.actions?.choose = chooser ?? { _, _, _, _ in }
        page.actions?.run = recorder ?? { _, _ in }
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
        // The page on screen again (New Task's tab took it down), the list
        // with the keyboard: the form's sheet is over the page.
        let pageWasShown = app.store.showingOverlay == .docker
        if !pageWasShown { app.toggleDockerPage(nil) }
        _ = await eventually(3) {
            if !self.app.dockerListHasKeyboard() { self.app.focusDockerList() }
            return self.app.dockerListHasKeyboard()
        }
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
        check(
            "the form put away gives the keyboard back to the list, not the terminal under the page",
            await eventually(3) { self.app.dockerListHasKeyboard() },
            "\(String(describing: window.firstResponder)), page \(String(describing: app.store.showingOverlay))")
        if !pageWasShown { app.toggleDockerPage(nil) }
        // q: its own client in a tab, signed in inside the container.
        var clients: [String] = []
        let saved = page.actions
        page.actions?.run = { command, _ in clients.append(command) }
        if let pg = docker.container(pgID) {
            let verb = page.verbs(for: pg).first { $0.title == "Open psql in a Tab" }
            check("a database container has its client as a button", verb?.place == .button && verb?.label == "psql", "\(page.verbs(for: pg).map(\.title))")
        }
        page.selection = [pgID]
        if app.store.showingOverlay != .docker { app.showOverlay(.docker) }
        page.showDetail = true
        // A window wide enough for the detail at its widest, whatever the
        // run opened with: narrower, the last buttons say no words.
        let openedFrame = window.frame
        if let area = (window.screen ?? NSScreen.main)?.visibleFrame {
            let size = CGSize(width: min(1_400, area.width), height: min(880, area.height))
            window.setFrame(NSRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2, width: size.width, height: size.height), display: true)
        }
        let drawn = await shownText { $0.contains("psql") }
        let seen = drawn == nil ? await readWindow().map(\.text).joined(separator: " | ") + " at \(window.frame.size)" : ""
        check("its detail draws it, by the client's name", drawn != nil, seen)
        window.setFrame(openedFrame, display: true)
        _ = page.press("q")
        let psql = #"DOCKER_HOST=unix://\#(socket) docker exec -it ot-pg sh -c 'export PGPASSWORD="$POSTGRES_PASSWORD"; exec psql -U "$POSTGRES_USER" -d "$POSTGRES_DB"'"#
        check("q opens psql in it, signed in by its env's names", await eventually(5) { clients.last == psql }, clients.last ?? "nothing")
        check("with no secret on the tab's command line", clients.last?.contains("hunter2") == false)
        // A pull moved its tag on: the list names its image by ID, and
        // the inspect its detail read names it still.
        fake.supersedeImage(of: pgID)
        let byID = await eventually(5) { docker.container(pgID).map(DockerClient.listsImageByID) == true }
        let kept = docker.container(pgID).map { page.verbs(for: $0).contains { $0.label == "psql" } } == true
        check("an image listed by its ID keeps its client", byID && kept, docker.container(pgID)?.Image ?? "gone")
        clients.removeAll()
        _ = page.press("q")
        check("and q opens it still", await eventually(5) { clients.last == psql }, clients.last ?? "nothing")
        let cache = fake.add(name: "ot-cache", image: "redis:7", env: ["REDIS_PASSWORD=s3cr3t-cache"])
        _ = await eventually(5) { docker.container(cache) != nil }
        docker.container(cache).flatMap { container in page.verbs(for: container).first { $0.title == "Open redis-cli in a Tab" } }?.perform()
        let redis = #"docker exec -it ot-cache sh -c 'export REDISCLI_AUTH="$REDIS_PASSWORD"; exec redis-cli'"#
        check(
            "redis-cli signs in through REDISCLI_AUTH",
            await eventually(5) { clients.last?.hasSuffix(redis) == true } && clients.last?.contains("s3cr3t") == false, clients.last ?? "nothing")
        fake.set(cache, state: .exited)
        _ = await eventually(5) { docker.container(cache)?.state == .exited }
        check(
            "a stopped one's client says why it can't",
            docker.container(cache).flatMap { container in page.verbs(for: container).first { $0.label == "redis-cli" } }?.unavailable == "It isn't running.")
        check("a container that is no database has no client", docker.container(web).map { page.verbs(for: $0).contains { $0.key == "q" } } == false)
        try? await docker.remove(cache, force: true)
        page.actions = saved
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
        // On screen, as a person would see it.
        if app.store.showingOverlay != .docker { app.showOverlay(.docker) }
        page.showDetail = true
        page.detailTab = .overview
        let clashProject = docker.projects.first { $0.name == "ot-shop-2" }
        let reason = clashProject.flatMap { app.dockerActions.freePortsUnavailable($0) }
        let offered = await wordFrame("Up on Free Ports")
        var clashTyped: [String] = []
        let typing = page.actions?.run
        page.actions?.run = { command, _ in clashTyped.append(command) }
        if let offered { await click(at: CGPoint(x: offered.midX, y: offered.midY)) }
        await pause(0.5)
        page.actions?.run = typing ?? { _, _ in }
        check(
            "its stack's Up on Free Ports can't help without its files here",
            offered != nil && reason == "Its compose files aren't on this Mac." && clashTyped.isEmpty && page.error == nil,
            "\(offered.map { "drawn at \($0)" } ?? "not drawn") \(reason ?? "no reason") \(clashTyped) \(page.error ?? "")")
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
            let info = TabInfoModel(tab: tab, inspector: ProcessInspector(), claudeReader: ClaudeUsageReader())
            await info.refreshPorts()
            check("Tab Info lists them", info.ports.contains { $0.port == 58080 && $0.container == "ot-shop-web-1" }, "\(info.ports)")
            check("and the API client looks for an OpenAPI document on them", app.apiWorkspace.ports().contains(58080))
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
        await plannedChecks(fake, socket: socket)

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
        await usageChecks(fake, web: web, db: db, elsewhere: elsewhere)
        await resourcesChecks(fake)
        await buildsChecks()
        await verbsChecks(fake, web: web)
        await scoutChecks(fake)
        await imageUpdatesChecks(fake)
        await volumeFilesChecks(fake)
        await settingsChecks(fake, web: web)
        await testcontainersChecks(fake)
        await askAgentChecks(fake, web: web, folder: folder, real: real)
        await worktreePortsChecks(fake, socket: socket)
        await composeServicesChecks(fake, web: web)
        await emulationChecks(fake)
        await modelsChecks(fake)
        await mcpToolkitChecks()
        await agentChecks(fake, web: web)
        await remoteChecks(socket: socket, web: web, folder: folder)
        app.hideOverlay()

        // ⌥⌘P twice: back to the terminal, the page kept in the strip.
        app.toggleDockerPage(nil)
        app.toggleDockerPage(nil)
        check("⌥⌘P again goes back to the terminal", app.store.showingOverlay == nil && app.store.openOverlays.contains(.docker))
        app.closeOverlay(.docker)
        check("its ✕ closes it", !app.store.openOverlays.contains(.docker) && app.dockerView?.isHidden == true)
        docker.usage.interval = .seconds(3)
        docker.usage.first = .seconds(1)
        docker.use(nil)
        check("an isolated run left alone reaches no Docker", await eventually(3) { docker.connection == .off })
    }
}
