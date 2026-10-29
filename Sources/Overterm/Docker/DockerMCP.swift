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

    static let writes: Set<String> = ["docker_action", "docker_compose", "docker_exec"]

    static func call(_ name: String, _ arguments: [String: Any], docker: DockerModel) async throws -> [String: Any] {
        func string(_ key: String) -> String? { (arguments[key] as? String).flatMap { $0.isEmpty ? nil : $0 } }
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
            return BrowserMCP.textResult(describe(list, remoteHost: docker.publishedHost))
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
            return BrowserMCP.textResult(describe(target, try await engine.container(target.Id), remoteHost: docker.publishedHost))
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

    static func describe(_ containers: [ContainerSummary], remoteHost: String? = nil) -> String {
        guard !containers.isEmpty else { return "No containers." }
        return containers.map { container in
            var line = "- \(container.name): \(container.Image), \(container.Status)"
            if let project = container.composeProject { line += " — compose \(project)/\(container.composeService ?? "")" }
            let ports = PublishedPort.of(container.Ports ?? [], remoteHost: remoteHost)
            if !ports.isEmpty { line += " — ports " + ports.map(\.spoken).joined(separator: ", ") }
            return line
        }.joined(separator: "\n")
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

    /// What Inspect says, as an agent needs it: secrets masked.
    static func describe(_ container: ContainerSummary, _ detail: ContainerDetail, remoteHost: String? = nil) -> String {
        var lines = ["\(container.name): \(container.Image)", "State: \(container.Status)"]
        if let error = detail.State.Error, !error.isEmpty { lines.append("Error: \(error)") }
        if detail.State.OOMKilled == true { lines.append("Killed: out of memory") }
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
                "docker_containers", "The user's Docker containers: name, image, status, compose project and service, published ports.",
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
                "docker_inspect", "Why a container is as it is: its state and error, health check, command, ports, mounts, networks, env (secrets masked).",
                ["container": ["type": "string", "description": "Its name, from docker_containers."]], required: ["container"]),
            tool(
                "docker_stats", "A running container's CPU, memory and network now.",
                ["container": ["type": "string", "description": "Its name, from docker_containers."]], required: ["container"]),
            tool(
                "docker_models",
                "Docker Model Runner's local LLMs: which are pulled and loaded, and the OpenAI-compatible base URL to use from a container or this Mac.",
                [:]),
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
        "Docker as the user runs it (Overterm's Docker page): docker_containers and docker_projects show what runs, docker_logs, docker_inspect and docker_stats say why a container failed — read them before guessing. docker_models lists the local LLMs Docker Model Runner serves, with the base URL to use."

    private static func tool(_ name: String, _ description: String, _ properties: [String: Any], required: [String] = []) -> [String: Any] {
        [
            "name": name, "description": description,
            "inputSchema": ["type": "object", "properties": properties, "required": required] as [String: Any],
        ]
    }
}
