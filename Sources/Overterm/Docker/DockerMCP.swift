import AppKit

/// Docker's MCP tools, beside the browser's, the API client's, the notes'
/// and the databases' on the same server (BrowserBridge): an agent sees
/// the containers and compose projects, reads a container's logs, its
/// inspect data and its use — and, when Settings ▸ Docker lets agents act,
/// starts, stops, restarts, runs compose and execs, each asked about in
/// the window first. Secrets stay out of every answer: env values that
/// look like secrets are masked, and taken out of logs and exec output.
@MainActor
enum DockerMCP {
    /// Compose's up and down go to a terminal tab (the window sets this):
    /// the user sees them run.
    static var runInTab: ((String, URL?) -> Void)?
    /// Set by tests and the E2E runner: answers instead of the alert.
    static var askOverride: ((String) -> Bool)?

    static let writes: Set<String> = ["docker_action", "docker_update", "docker_compose", "docker_exec"]

    /// `updates`: what the user's last Check for Updates found — read,
    /// never asked again: a registry's answer spends the user's pulls.
    /// `scans`: what Docker Scout found in the images the user scanned —
    /// read, never started: a scan sends an image's packages away.
    static func call(
        _ name: String, _ arguments: [String: Any], docker: DockerModel, updates: DockerImageUpdates = .shared, scans: DockerScoutScans = .shared
    ) async throws -> [String: Any] {
        func string(_ key: String) -> String? { (arguments[key] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        // From memory: no engine needed, nothing run.
        if name == "docker_vulnerabilities" {
            guard let image = string("image") else {
                throw BrowserMCP.ToolError(message: "docker_vulnerabilities needs “image” — its name, as the Docker page's Images list it.")
            }
            return BrowserMCP.textResult(describeVulnerabilities(scans.scan(matching: image, images: docker.images), image: image))
        }
        let engine = try await ready(docker)
        func container() throws -> ContainerSummary {
            guard let wanted = string("container") else { throw BrowserMCP.ToolError(message: "\(name) needs “container” — docker_containers lists them.") }
            guard let found = docker.container(wanted) else {
                throw BrowserMCP.ToolError(message: "No container “\(wanted)”. There are: \(docker.containers.map(\.name).joined(separator: ", ")).")
            }
            return found
        }
        if writes.contains(name), !Settings.shared.dockerAgentWrites {
            throw BrowserMCP.ToolError(message: "Agents only read Docker here. The user can let agents act in Settings ▸ Docker.")
        }
        switch name {
        case "docker_containers":
            let all = arguments["all"] as? Bool ?? true
            let project = string("project")
            let list = docker.containers.filter { (all || $0.state.isUp) && (project == nil || $0.composeProject == project) }
            await docker.readPlatforms(for: list)
            return BrowserMCP.textResult(describe(list, remoteHost: docker.publishedHost) { docker.emulation(of: $0) })
        case "docker_projects":
            let ports = ComposePortStore.shared
            return BrowserMCP.textResult(
                describe(docker.projects, overrides: ports.overrides(of: docker.projects)) { ports.command($0, "up -d", endpoint: docker.endpoint) })
        case "docker_logs":
            let target = try container()
            let detail = try await engine.container(target.Id)
            let tail = min(max(arguments["tail"] as? Int ?? 200, 1), 2000)
            var lines: [DockerLogLine] = []
            for try await chunks in engine.logs(target.Id, tty: detail.Config.Tty ?? false, tail: tail, follow: false) {
                lines += chunks.flatMap { DockerLogLine.lines(of: $0, timestamps: true) }
            }
            var filter = DockerLogFilter(text: string("contains") ?? "")
            if let level = string("level") { filter.level = level.hasPrefix("err") ? .errors : level.hasPrefix("warn") ? .warnings : .all }
            let secrets = DockerSecrets.values(in: detail.env)
            let text = lines.filter(filter.matches).map(\.plain).joined(separator: "\n")
            return BrowserMCP.textResult(bounded(DockerSecrets.redact(text.isEmpty ? "(no lines)" : text, values: secrets)))
        case "docker_inspect":
            let target = try container()
            let detail = try await engine.container(target.Id)
            // What it runs: its own word (API 1.48), else its image's.
            var platform = detail.ImageManifestDescriptor?.dockerPlatform
            if platform == nil {
                await docker.readPlatforms(for: [target])
                platform = docker.platform(of: target)
            }
            return BrowserMCP.textResult(
                describe(
                    target, detail, remoteHost: docker.publishedHost, platform: platform,
                    emulation: DockerEmulation(image: platform, engine: docker.enginePlatform)))
        case "docker_stats":
            let target = try container()
            guard target.state == .running else { return BrowserMCP.textResult("\(target.name) isn't running.") }
            let sample = try await engine.get(ContainerStatsSample.self, "/containers/\(target.Id)/stats", ["stream": "false"])
            let usage = DockerUsage(sample)
            return BrowserMCP.textResult(
                String(
                    format: "%@: CPU %.1f%% (of one core), memory %@ of %@, network in %@ out %@, %d processes", target.name, usage.cpuPercent,
                    DockerBytes.string(usage.memoryBytes, memory: true), DockerBytes.string(usage.memoryLimit, memory: true),
                    DockerBytes.string(usage.networkIn), DockerBytes.string(usage.networkOut), usage.processes))
        case "docker_models":
            return BrowserMCP.textResult(try await describeModels(docker, engine: engine))
        case "docker_image_updates":
            let project = string("project")
            if let project, !docker.projects.contains(where: { $0.name == project }) {
                throw BrowserMCP.ToolError(message: "“project” is one of: \(docker.projects.map(\.name).joined(separator: ", ")).")
            }
            return BrowserMCP.textResult(describeUpdates(updates, docker: docker, project: project))
        case "docker_action":
            let target = try container()
            guard let action = string("action"), ["start", "stop", "restart", "pause", "unpause", "remove"].contains(action) else {
                throw BrowserMCP.ToolError(message: "“action” is one of start, stop, restart, pause, unpause, remove.")
            }
            guard await allow("An agent wants to \(action) “\(target.name)”", target.Image + " — " + target.Status) else {
                throw BrowserMCP.ToolError(message: "The user declined.")
            }
            if action == "remove" {
                try await docker.remove(target.Id, force: true)
            } else if let verb = DockerEngine.ContainerAction(rawValue: action) {
                try await docker.perform(verb, on: target.Id)
            }
            return BrowserMCP.textResult("\(target.name): \(action) done — \(docker.container(target.Id)?.Status ?? "gone").")
        case "docker_update":
            return try await update(try container(), arguments, docker: docker, engine: engine)
        case "docker_compose":
            guard let wanted = string("project"), let project = docker.projects.first(where: { $0.name == wanted }) else {
                throw BrowserMCP.ToolError(message: "“project” is one of: \(docker.projects.map(\.name).joined(separator: ", ")).")
            }
            let action = string("action") ?? ""
            let service = string("service")
            // Up and rebuild read the files: a stack on ports of its own
            // goes up with its override, as Overterm's Up does — written
            // again first if the files changed since.
            await ComposePortStore.shared.refresh(for: project, endpoint: docker.endpoint)
            let command = try composeCommand(
                project, action: action, service: service, endpoint: docker.endpoint, files: ComposePortStore.shared.files(for: project))
            guard await allow("An agent wants to run compose \(action) on “\(project.name)”" + (service.map { " (\($0))" } ?? ""), command) else {
                throw BrowserMCP.ToolError(message: "The user declined.")
            }
            let lasting = project.containers.filter { !$0.isOneOff && (service == nil || $0.composeService == service) }
            switch action {
            case "up", "rebuild", "down":
                guard let runInTab else { throw BrowserMCP.ToolError(message: "No window to run it in.") }
                runInTab(command, project.workingDir.map { URL(fileURLWithPath: $0) })
                return BrowserMCP.textResult("Running in a terminal tab the user sees: \(command)")
            default:
                for container in lasting {
                    if let verb = DockerEngine.ContainerAction(rawValue: action) { try await docker.perform(verb, on: container.Id) }
                }
                return BrowserMCP.textResult("\(project.name)\(service.map { "/\($0)" } ?? ""): \(action) done.")
            }
        case "docker_exec":
            let target = try container()
            let command: [String]
            if let list = arguments["command"] as? [String], !list.isEmpty {
                command = list
            } else if let line = string("command") {
                command = ["sh", "-c", line]
            } else {
                throw BrowserMCP.ToolError(message: "docker_exec needs “command”.")
            }
            guard await allow("An agent wants to run this in “\(target.name)”", command.joined(separator: " ")) else {
                throw BrowserMCP.ToolError(message: "The user declined.")
            }
            let result = try await engine.exec(target.Id, command)
            let secrets = DockerSecrets.values(in: try await engine.container(target.Id).env)
            let text = "exit \(result.exitCode)\n" + result.stdout + (result.stderr.isEmpty ? "" : "\nstderr:\n" + result.stderr)
            return BrowserMCP.textResult(bounded(DockerSecrets.redact(text, values: secrets)))
        default:
            throw BrowserMCP.ToolError(message: "Unknown tool: \(name)")
        }
    }

    /// What `docker_compose` runs: up and rebuild (`up -d --build`) in a
    /// tab, the rest named for the tab or the question. `service` narrows
    /// it to one of the project's; down takes the whole project. `files`:
    /// the store's (`ComposePortStore.files(for:)`). Pure.
    static func composeCommand(
        _ project: ComposeProject, action: String, service: String?, endpoint: DockerEndpoint?, files: [String]? = nil
    ) throws -> String {
        let actions = ["up", "rebuild", "down", "restart", "stop", "start"]
        guard actions.contains(action) else { throw BrowserMCP.ToolError(message: "“action” is one of \(actions.joined(separator: ", ")).") }
        if let service {
            guard action != "down" else {
                throw BrowserMCP.ToolError(message: "“service” goes with up, rebuild, restart, stop and start; down takes the whole project.")
            }
            guard project.services.contains(where: { $0.name == service }) else {
                throw BrowserMCP.ToolError(message: "“service” is one of: \(project.services.map(\.name).joined(separator: ", ")).")
            }
        }
        let verb = action == "up" ? "up -d" : action == "rebuild" ? "up -d --build" : action
        return DockerCommands.compose(project, verb, services: service.map { [$0] } ?? [], endpoint: endpoint, files: files)
    }

    /// The engine, connected — started if nothing had started it yet.
    private static func ready(_ docker: DockerModel) async throws -> DockerEngine {
        docker.start()
        for _ in 0..<30 {
            if docker.connection.isRunning, let engine = docker.engine { return engine }
            if case .off = docker.connection { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw BrowserMCP.ToolError(
            message: {
                switch docker.connection {
                case .down(let reason): return reason
                case .off: return "Docker is off in Overterm's settings."
                default: return "Docker isn't answering yet."
                }
            }())
    }

    /// Asks in the window. An agent's write runs only on a yes.
    /// `docker_update`: what the agent asks for, checked as the Settings
    /// sheet checks it, then asked of the user with the `docker update` it
    /// is. `on-failure:N` tries N times at most; a count that isn't one is
    /// refused, never read as no limit.
    static func update(_ target: ContainerSummary, _ arguments: [String: Any], docker: DockerModel, engine: DockerEngine) async throws -> [String: Any] {
        func string(_ key: String) -> String? { (arguments[key] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        var settings = DockerContainerSettings(target, try await engine.container(target.Id), engine: docker.info)
        if let memory = string("memory") { settings.memory = memory }
        if let cpus = (arguments["cpus"] as? NSNumber)?.stringValue ?? string("cpus") { settings.cpus = cpus }
        if let restart = string("restart") {
            let parts = restart.split(separator: ":", maxSplits: 1).map(String.init)
            settings.restart = parts.first ?? restart
            settings.retries = parts.count > 1 ? Int(parts[1]) ?? -1 : 0
        }
        if let problem = settings.problem { throw BrowserMCP.ToolError(message: problem) }
        guard let change = settings.update else { return BrowserMCP.textResult("\(target.name) already has those settings.") }
        guard await allow("An agent wants to change “\(target.name)”", settings.line(prefix: DockerCommands.prefix(for: docker.endpoint))) else {
            throw BrowserMCP.ToolError(message: "The user declined.")
        }
        let warnings = try await engine.update(container: target.Id, change)
        let compose = settings.project.map { " Compose puts back what \($0)'s file says when it makes it again." } ?? ""
        return BrowserMCP.textResult(
            "\(target.name): \(settings.summary)." + compose + (warnings.isEmpty ? "" : " Docker says: " + warnings.joined(separator: " ")))
    }

    static func allow(_ title: String, _ detail: String) async -> Bool {
        if let answer = askOverride { return answer(title + "\n" + detail) }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = String(detail.prefix(2000))
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Don't")
        alert.alertStyle = .warning
        guard let window = NSApp.mainWindow ?? NSApp.windows.first(where: \.isVisible) else { return alert.runModal() == .alertFirstButtonReturn }
        NSApp.activate(ignoringOtherApps: true)
        return await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { continuation.resume(returning: $0 == .alertFirstButtonReturn) }
        }
    }

    // MARK: Answers

    static func bounded(_ text: String, max: Int = 60_000) -> String {
        text.count > max ? String(text.suffix(max)) + "\n… (the last \(max) characters)" : text
    }

    /// `emulation`: what runs translated here (an amd64 image on Apple
    /// silicon), said on its line.
    static func describe(
        _ containers: [ContainerSummary], remoteHost: String? = nil, emulation: (ContainerSummary) -> DockerEmulation? = { _ in nil }
    ) -> String {
        guard !containers.isEmpty else { return "No containers." }
        return containers.map { container in
            var line = "- \(container.name): \(container.Image), \(container.Status)"
            if let project = container.composeProject { line += " — compose \(project)/\(container.composeService ?? "")" }
            if let run = testRun(of: container) { line += " — " + run }
            let ports = PublishedPort.of(container.Ports ?? [], remoteHost: remoteHost)
            if !ports.isEmpty { line += " — ports " + ports.map(\.spoken).joined(separator: ", ") }
            if let emulated = emulation(container) { line += " — emulated: \(emulated.image.description) on this \(emulated.engine.description) engine" }
            return line
        }.joined(separator: "\n")
    }

    /// The test run a container of Testcontainers' is for, as its line
    /// says it; nil for one that isn't Testcontainers'.
    static func testRun(of container: ContainerSummary) -> String? {
        guard let run = Testcontainers.groupID(of: container) else { return nil }
        if Testcontainers.isReaper(container) { return "Testcontainers' reaper (Ryuk)" }
        if !run.isEmpty { return "Testcontainers run \(run.prefix(8))" }
        return Testcontainers.isReused(container) ? "Testcontainers, kept for reuse" : "Testcontainers, in no run"
    }

    /// Each project, its services and their containers — and, for a stack
    /// Overterm put on ports of its own (`overrides`, by name), what moved
    /// and the command its Up runs: an agent's own `docker compose up`
    /// there would ask for the file's ports again.
    static func describe(
        _ projects: [ComposeProject], overrides: [String: ComposePortOverride] = [:], upCommand: (ComposeProject) -> String = { _ in "" }
    ) -> String {
        guard !projects.isEmpty else { return "No compose projects." }
        return projects.map { project in
            var lines = [
                "- \(project.name) (\(project.running)/\(project.containers.filter { !$0.isOneOff }.count) running)"
                    + (project.workingDir.map { " in \($0)" } ?? "")
            ]
            lines += project.services.map { service in
                "  - \(service.name): " + service.containers.map { "\($0.name) \($0.Status)" }.joined(separator: "; ")
                    + (service.dependsOn.isEmpty ? "" : " (after \(service.dependsOn.joined(separator: ", ")))")
            }
            if let kept = overrides[project.name] {
                let command = upCommand(project)
                let run = command.isEmpty ? "" : " Overterm's Up runs: \(command)"
                lines.append(
                    kept.moves.isEmpty
                        ? "  A project name of its own (Overterm's, for this checkout; its files say \(kept.fileName)).\(run)"
                        : "  Ports of its own (Overterm moved them for this checkout): \(kept.moves.map(\.label).joined(separator: ", ")). Reach them there.\(run)")
            }
            return lines.joined(separator: "\n")
        }.joined(separator: "\n")
    }

    /// What Inspect says, as an agent needs it: secrets masked. `platform`:
    /// its image's, and `emulation` when this engine translates it — what
    /// runs it natively said with it.
    static func describe(
        _ container: ContainerSummary, _ detail: ContainerDetail, remoteHost: String? = nil, platform: DockerPlatform? = nil,
        emulation: DockerEmulation? = nil
    ) -> String {
        var lines = ["\(container.name): \(container.Image)", "State: \(container.Status)"]
        if let emulation {
            lines.append(
                "Platform: \(emulation.image.description) — emulated on this \(emulation.engine.description) engine (Rosetta or QEMU): slower; "
                    + "its image's \(emulation.engine.description) variant, if it has one, runs natively.")
        } else if let platform {
            lines.append("Platform: \(platform.description)")
        }
        if let error = detail.State.Error, !error.isEmpty { lines.append("Error: \(error)") }
        if detail.State.OOMKilled == true { lines.append("Killed: out of memory") }
        // What it may use: why the kernel killed it, or why it is slow.
        let limits = DockerContainerSettings.Current(detail.HostConfig)
        let said = [
            limits.memory > 0 ? "memory \(DockerBytes.string(limits.memory, memory: true))" : nil,
            limits.cpus.map { "\(DockerContainerSettings.number($0)) CPU\($0 == 1 ? "" : "s")" },
        ].compactMap { $0 }
        if !said.isEmpty { lines.append("Limits: " + said.joined(separator: ", ")) }
        if limits.restart != "no" { lines.append("Restart: \(limits.restart)" + (limits.retries > 0 ? ":\(limits.retries)" : "")) }
        if let health = detail.State.Health, let status = health.Status {
            lines.append("Health: \(status)" + (health.Log?.last?.Output.map { " — last check: \($0.trimmingCharacters(in: .whitespacesAndNewlines))" } ?? ""))
        }
        // Compose has put .env's values into it: its flags say which.
        lines.append("Command: " + DockerSecrets.maskArguments((detail.Config.Entrypoint ?? []) + (detail.Config.Cmd ?? [])).joined(separator: " "))
        let ports = PublishedPort.of(container.Ports ?? [], remoteHost: remoteHost)
        if !ports.isEmpty { lines.append("Ports: " + ports.map(\.spoken).joined(separator: ", ")) }
        for mount in detail.Mounts ?? [] { lines.append("Mount: \(mount.Name ?? mount.Source ?? "") → \(mount.Destination)") }
        if let networks = detail.NetworkSettings?.Networks {
            lines.append("Networks: " + networks.keys.sorted().map { "\($0) \(networks[$0]?.IPAddress ?? "")" }.joined(separator: ", "))
        }
        if !detail.env.isEmpty { lines.append("Env:\n" + detail.env.map { "  \($0.key)=\(DockerSecrets.masked($0.key, $0.value))" }.joined(separator: "\n")) }
        return lines.joined(separator: "\n")
    }

    /// The last Check for Updates' answers, each with what it means, its
    /// age and who uses the image (`project/service`, else a container's
    /// name); only `project`'s services' when given.
    static func describeUpdates(_ updates: DockerImageUpdates, docker: DockerModel, project: String? = nil, now: Date = Date()) -> String {
        var users: [String: [String]] = [:]
        for compose in docker.projects {
            for (service, reference) in updates.references(of: compose).sorted(by: { $0.key < $1.key }) {
                if let key = DockerImageReference(reference)?.key { users[key, default: []].append(compose.name + "/" + service) }
            }
        }
        for container in docker.containers where container.composeProject == nil {
            if let key = DockerImageReference(container.Image)?.key { users[key, default: []].append(container.name) }
        }
        var keys = updates.checks.keys.sorted()
        if let project {
            keys = keys.filter { users[$0]?.contains { $0.hasPrefix(project + "/") } == true }
        }
        guard !keys.isEmpty else {
            return updates.checks.isEmpty
                ? "Nothing checked yet. The user checks on the Docker page (Images ▸ Check for Updates, or a project's)."
                : "None of \(project ?? "its")'s images was checked. The user checks on the Docker page (Images ▸ Check for Updates, or a project's)."
        }
        var lines = ["The user's last Check for Updates (each image's registry asked through their docker CLI):"]
        for key in keys {
            guard let check = updates.checks[key] else { continue }
            let state: String
            switch updates.state(of: check.reference) {
            case .available:
                state = "newer in its registry (\(check.remote?.digest ?? "")) — pulling it updates it; a compose service then needs an Up"
            case .differs:
                state =
                    "its registry has another image (\(check.remote?.digest ?? "")); this one was built here or pulled before it moved on — the image store doesn't say which"
            case .current: state = "up to date"
            case .notInRegistry(let why): state = "not in its registry: built or tagged here (" + why + ")"
            case .failed(let why): state = "couldn't be checked: " + why
            case .local:
                state = updates.local[key] == nil ? "no longer here" : updates.builtKeys.contains(key) ? "built by its project's files" : "built or tagged here now"
            case .unchecked, .checking: state = "being checked"
            }
            let used = users[key].map { " — used by " + $0.joined(separator: ", ") } ?? ""
            lines.append("- \(check.reference): \(state) — checked \(UsageFormat.age(check.at, now: now))\(used)")
        }
        return lines.joined(separator: "\n")
    }

    /// The user's last scan of an image, as Scout found it: the worst
    /// first, 300 at most and `max` characters at most — the end cut, not
    /// the head (`bounded` keeps a log's end) — or why there is none.
    /// Never a scan.
    static func describeVulnerabilities(_ scan: DockerScoutScans.Scan?, image: String, now: Date = Date(), max: Int = 60_000) -> String {
        guard let scan else {
            return "\(image) hasn't been scanned. Docker Scout sends an image's packages to Docker's service, so only the user starts a scan: "
                + "the Docker page ▸ Images ▸ the image ▸ Vulnerabilities ▸ Scan."
        }
        switch scan.state {
        case .scanning(let since, _):
            return "Docker Scout is scanning \(scan.image) now (started \(Int(now.timeIntervalSince(since))) s ago)."
        case .failed(let failure, _):
            return "The last scan of \(scan.image) failed: \(failure.message)"
        case .done(let report, let at):
            let version = report.scoutVersion.map { " \($0)" } ?? ""
            var text = "\(scan.image) — Docker Scout\(version), scanned \(UsageFormat.age(at, now: now)): \(report.sentence)."
            let findings = DockerScoutFilter().groups(report.findings).flatMap(\.findings)
            if !findings.isEmpty { text += "\n" + report.lines(findings, limit: 300, characters: Swift.max(0, max - text.count - 1)) }
            return text
        }
    }

    /// Model Runner's models and where a program reaches them — read
    /// from the runner, never `docker model` (which would install one).
    static func describeModels(_ docker: DockerModel, engine: DockerEngine) async throws -> String {
        let place = ModelRunner.place(runtime: docker.runtime, remote: docker.publishedHost != nil, containers: docker.containers)
        switch place {
        case .remote: return "The engine is remote; its Model Runner isn't read from here."
        case .stopped(_, let name): return "Model Runner's container, \(name), is stopped."
        case .absent: return "This engine has no Docker Model Runner. The user can install it (docker model install-runner)."
        case .desktop, .container: break
        }
        guard let contents = try await ModelRunner.read(place, engine: engine) else {
            return "Docker Desktop's Model Runner is off. The user can turn it on (docker desktop enable model-runner)."
        }
        var lines: [String] = []
        if let endpoints = ModelRunner.endpoints(place) {
            lines.append("OpenAI-compatible API — from a container: \(endpoints.containers)" + (endpoints.mac.map { "; from this Mac: \($0)" } ?? ""))
        }
        if contents.models.isEmpty { lines.append("No models pulled.") }
        for model in contents.models {
            let loaded = contents.running.first { $0.runs(model) }.map { " — loaded in \($0.backend_name)" } ?? ""
            lines.append("- \(model.reference)" + (model.summary.isEmpty ? "" : " (\(model.summary))") + loaded)
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Tools

    static var tools: [[String: Any]] {
        var tools = [
            tool(
                "docker_containers",
                "The user's Docker containers: name, image, status, compose project and service, the Testcontainers run it belongs to, published ports.",
                [
                    "project": ["type": "string", "description": "Only this compose project's."],
                    "all": ["type": "boolean", "description": "Stopped ones too (default true)."],
                ]),
            tool(
                "docker_projects", "The compose projects: their services, which run, where each was started, and the ports Overterm moved for a worktree.",
                [:]),
            tool(
                "docker_logs", "A container's last log lines, levels read; secrets taken out.",
                [
                    "container": ["type": "string", "description": "Its name, from docker_containers."],
                    "tail": ["type": "integer", "description": "Lines (default 200, at most 2000)."],
                    "contains": ["type": "string", "description": "Only lines with this."],
                    "level": ["type": "string", "description": "error or warning: only those (and stderr's unlevelled lines for warning)."],
                ], required: ["container"]),
            tool(
                "docker_inspect",
                "Why a container is as it is: its state and error, health check, memory and CPU limits, restart policy, platform (emulated or not), command, ports, mounts, networks, env (secrets masked).",
                ["container": ["type": "string", "description": "Its name, from docker_containers."]], required: ["container"]),
            tool(
                "docker_stats", "A running container's CPU, memory and network now.",
                ["container": ["type": "string", "description": "Its name, from docker_containers."]], required: ["container"]),
            tool(
                "docker_models",
                "Docker Model Runner's local LLMs: which are pulled and loaded, and the OpenAI-compatible base URL to use from a container or this Mac.",
                [:]),
            tool(
                "docker_image_updates",
                "Which local images have a newer image under the same tag in their registry, as the user's last Check for Updates found — with when it was checked and which compose services use them. It never asks a registry itself.",
                ["project": ["type": "string", "description": "Only this compose project's images."]]),
            tool(
                "docker_vulnerabilities",
                "The vulnerabilities Docker Scout found in an image, from a scan the user ran on the Docker page — each CVE with its severity, Scout's score, the package, the version installed, the fixed version and the advisory's link, the worst first. It never scans.",
                ["image": ["type": "string", "description": "Its name (nginx:1.27) or ID."]], required: ["image"]),
        ]
        if Settings.shared.dockerAgentWrites {
            tools += [
                tool(
                    "docker_action", "Start, stop, restart, pause, unpause or remove a container. The user is asked first.",
                    [
                        "container": ["type": "string", "description": "Its name, from docker_containers."],
                        "action": ["type": "string", "enum": ["start", "stop", "restart", "pause", "unpause", "remove"]],
                    ], required: ["container", "action"]),
                tool(
                    "docker_update",
                    "Change a container's memory limit, CPUs or restart policy in place (docker update); it keeps running. A compose service's container gets its compose file's again when Compose makes it anew. The user is asked first.",
                    [
                        "container": ["type": "string", "description": "Its name, from docker_containers."],
                        "memory": ["type": "string", "description": "A memory limit: 512m, 2g (6m at least). A limit can be changed, not taken away."],
                        "cpus": ["type": "number", "description": "CPUs it may use: 0.5, 2 (at most the engine's)."],
                        "restart": ["type": "string", "description": "no, always, unless-stopped, on-failure or on-failure:N (N tries at most)."],
                    ], required: ["container"]),
                tool(
                    "docker_compose",
                    "Compose up, rebuild (up --build), down, restart, stop or start a project, or one of its services. Up, rebuild and down run in a terminal tab the user sees. The user is asked first.",
                    [
                        "project": ["type": "string", "description": "Its name, from docker_projects."],
                        "action": ["type": "string", "enum": ["up", "rebuild", "down", "restart", "stop", "start"]],
                        "service": ["type": "string", "description": "Only this service (not with down)."],
                    ], required: ["project", "action"]),
                tool(
                    "docker_exec", "Run a command in a running container (no TTY, no input) and get its output and exit code. The user is asked first.",
                    [
                        "container": ["type": "string", "description": "Its name, from docker_containers."],
                        "command": ["type": "string", "description": "A shell command line (run with sh -c)."],
                    ], required: ["container", "command"]),
            ]
        }
        return tools
    }

    static let instructions =
        "Docker as the user runs it (Overterm's Docker page): docker_containers and docker_projects show what runs, docker_logs, docker_inspect and docker_stats say why a container failed — read them before guessing. docker_inspect says when a container runs emulated (an amd64 image on Apple silicon: slow). docker_models lists the local LLMs Docker Model Runner serves, with the base URL to use. docker_image_updates says which images are newer in their registries, as of the user's last Check for Updates — it never asks a registry. docker_vulnerabilities lists the CVEs Docker Scout found in an image the user scanned — it never starts a scan, which sends the image's packages to Docker's service."

    private static func tool(_ name: String, _ description: String, _ properties: [String: Any], required: [String] = []) -> [String: Any] {
        [
            "name": name, "description": description,
            "inputSchema": ["type": "object", "properties": properties, "required": required] as [String: Any],
        ]
    }
}
