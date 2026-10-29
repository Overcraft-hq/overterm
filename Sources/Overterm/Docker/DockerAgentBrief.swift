import Foundation

/// What an agent is asked about a container: why it failed, or lines
/// picked out of a log — a container's, or a compose project's merged.
enum DockerAgentQuestion {
    case failure(ContainerSummary)
    case logLines(String, ContainerSummary)
    case projectLogLines(String, ComposeProject)
}

/// What the Ask Agent sheet opens with (`AskAgentModel.begin`): the
/// question already typed, what the fixed chip calls the text, the text
/// always sent, what else goes as a chip each, and where a new agent tab
/// opens. Every word in it has been scrubbed (`DockerSecrets.scrub`).
struct DockerAgentBrief: Equatable {
    var message: String
    var subject: String?
    var text: String
    var parts: [AskAgentModel.Part]
    var folder: String?
}

/// The brief's words, from what the engine and Compose said. Pure.
enum DockerAgentText {
    /// The log lines a failure brings: read fresh from the engine, not the
    /// Logs tab's feed, so they are there when the tab never opened.
    static let logLines = 80
    /// What goes into a prompt typed into a terminal: bounded.
    static let maxLogBytes = 12 << 10
    static let maxServiceBytes = 8 << 10
    static let maxEnv = 50
    static let maxCheckOutput = 2_000

    /// What an exit code means, when it says more than "it failed": the
    /// shell's 126 and 127, and 128 + a signal's number.
    static func exitMeaning(_ code: Int, outOfMemory: Bool = false) -> String? {
        switch code {
        case 126: return "the command couldn't be run (not executable)"
        case 127: return "a command wasn't found (its entrypoint, or one its script ran)"
        case 129...159:
            let number = code - 128
            let name = signals[number].map { " (SIG\($0))" } ?? ""
            var meaning = "killed by signal \(number)\(name)"
            switch number {
            case 9 where !outOfMemory: meaning += ", not by the kernel for memory: something killed it (docker kill, or a stop that ran out of time)"
            case 11: meaning += ": it crashed, a segmentation fault"
            case 15: meaning += ", as docker stop asks a process to end"
            default: break
            }
            return meaning
        default: return nil
        }
    }

    /// Linux's signal numbers: the container's, not the Mac's.
    private static let signals: [Int: String] = [
        1: "HUP", 2: "INT", 3: "QUIT", 4: "ILL", 5: "TRAP", 6: "ABRT", 7: "BUS", 8: "FPE", 9: "KILL", 10: "USR1", 11: "SEGV", 12: "USR2", 13: "PIPE",
        14: "ALRM", 15: "TERM", 16: "STKFLT", 17: "CHLD", 18: "CONT", 19: "STOP", 20: "TSTP", 21: "TTIN", 22: "TTOU", 23: "URG", 24: "XCPU",
        25: "XFSZ", 26: "VTALRM", 27: "PROF", 28: "WINCH", 29: "IO", 30: "PWR", 31: "SYS",
    ]

    /// What is always sent: what the container is and how it ended, a line
    /// each, a line only when there is something to say. `logs`: how many
    /// lines it wrote, when they were read (0 says so). Scrubbed where a
    /// secret can be — the error, the command, the health check and its
    /// output, the env's values; the names, the paths and the states come
    /// from the engine and Compose's labels, and are said as they are.
    static func about(
        _ container: ContainerSummary, _ detail: ContainerDetail, trouble: DockerAttention.Trouble?, ports: [PublishedPort], project: ComposeProject?,
        engine: String, memoryTotal: Int?, logs: Int? = nil
    ) -> String {
        let env = detail.env
        let secrets = DockerSecrets.values(in: env, besides: names(of: container, image: detail.Config.Image))
        func scrubbed(_ text: String) -> String { DockerSecrets.redact(text, values: secrets) }
        var lines: [String] = []
        var head = "Container \(container.name)"
        if let name = container.composeProject { head += " — compose project \(name)" + (container.composeService.map { ", service \($0)" } ?? "") }
        lines.append(head)
        lines.append("Image: \(nonEmpty(detail.Config.Image) ?? container.Image)")

        let state = detail.State
        let code: Int? =
            container.exitCode ?? ([.exited, .dead, .restarting].contains(container.state) ? state.ExitCode : nil)
        lines.append("State: " + stateLine(container, state, trouble: trouble, code: code))
        let outOfMemory = state.OOMKilled == true
        if let code, code != 0, let meaning = exitMeaning(code, outOfMemory: outOfMemory) { lines.append("Exit \(code): \(meaning).") }
        let limit = detail.HostConfig?.Memory ?? 0
        if outOfMemory {
            var line = "Out of memory: the kernel killed it (OOMKilled)."
            if limit > 0 {
                line += " Memory limit \(DockerBytes.string(limit, memory: true))."
            } else if let memoryTotal, memoryTotal > 0 {
                line += " No memory limit of its own; the engine has \(DockerBytes.string(memoryTotal, memory: true))."
            }
            lines.append(line)
        } else if limit > 0 {
            lines.append("Memory limit \(DockerBytes.string(limit, memory: true)).")
        }
        let restarts = detail.RestartCount ?? 0
        let policy = detail.HostConfig?.RestartPolicy
        let policyName = nonEmpty(policy?.Name).flatMap { $0 == "no" ? nil : $0 }
        if restarts > 0 || policyName != nil {
            var said = "Restarts: \(restarts)"
            if let policyName {
                said += " (restart policy \(policyName)" + ((policy?.MaximumRetryCount ?? 0) > 0 ? ", at most \(policy?.MaximumRetryCount ?? 0)" : "") + ")"
            }
            lines.append(said)
        }
        if let error = nonEmpty(state.Error?.trimmingCharacters(in: .whitespacesAndNewlines)) { lines.append("Error: \(scrubbed(error))") }

        if let health = state.Health, let status = nonEmpty(health.Status), status != "none" {
            let streak = health.FailingStreak ?? 0
            let failing = "\(streak) failed check\(streak == 1 ? "" : "s") in a row"
            if [.running, .paused].contains(container.state) {
                lines.append("Health: \(status)" + (streak > 0 ? ", " + failing : ""))
            } else if streak > 0 {
                // Stopped, the engine says unhealthy whatever the checks
                // said (moby, "for compatibility"): only a streak is news.
                lines.append("Health: \(failing) before it stopped")
            }
        }
        if let check = detail.Config.Healthcheck, let test = check.Test, !test.isEmpty, test != ["NONE"] {
            var options: [String] = []
            if let every = check.Interval, every > 0 { options.append("every \(duration(every))") }
            if let timeout = check.Timeout, timeout > 0 { options.append("timeout \(duration(timeout))") }
            if let retries = check.Retries, retries > 0 { options.append("\(retries) retr\(retries == 1 ? "y" : "ies")") }
            if let start = check.StartPeriod, start > 0 { options.append("start period \(duration(start))") }
            let said = DockerSecrets.maskArguments(test).joined(separator: " ")
            lines.append("Health check: " + scrubbed(said) + (options.isEmpty ? "" : " (\(options.joined(separator: ", ")))"))
        }
        if let probe = state.Health?.Log?.last, let output = nonEmpty(probe.Output?.trimmingCharacters(in: .whitespacesAndNewlines)) {
            let shown = output.count > maxCheckOutput ? String(output.prefix(maxCheckOutput)) + " …" : output
            lines.append("Last check" + (probe.ExitCode.map { " (exit \($0))" } ?? "") + ": " + scrubbed(shown))
        }

        let command = DockerSecrets.maskArguments((detail.Config.Entrypoint ?? []) + (detail.Config.Cmd ?? [])).joined(separator: " ")
        if !command.isEmpty { lines.append("Command: \(scrubbed(command))") }
        if let dir = nonEmpty(detail.Config.WorkingDir) { lines.append("Working dir: \(dir)") }
        if let user = nonEmpty(detail.Config.User) { lines.append("User: \(user)") }
        // The list's ports exist only while it runs; stopped, what it
        // publishes is its bindings — the very thing a port conflict is.
        let bindings = detail.HostConfig?.PortBindings ?? [:]
        if !ports.isEmpty {
            lines.append("Ports: " + ports.map(\.spoken).joined(separator: ", "))
        } else {
            let planned = bindings.keys.sorted().flatMap { key in ((bindings[key] ?? nil) ?? []).map { spoken($0, key) } }
            if !planned.isEmpty { lines.append("Ports it publishes when it runs: " + planned.joined(separator: ", ")) }
        }
        let published = Set(ports.map { "\($0.containerPort)/\($0.proto)" }).union(bindings.keys)
        let exposed = (detail.Config.ExposedPorts ?? [:]).keys.filter { !published.contains($0) }.sorted()
        if !exposed.isEmpty, detail.HostConfig?.PublishAllPorts != true { lines.append("Exposed, not published: " + exposed.joined(separator: ", ")) }
        let mounts = (detail.Mounts ?? []).map { mount in
            "\(mount.Name ?? mount.Source ?? "?") → \(mount.Destination)" + (mount.RW == false ? " (read-only)" : "")
        }
        if !mounts.isEmpty { lines.append("Mounts: " + mounts.joined(separator: "; ")) }
        if let networks = detail.NetworkSettings?.Networks, !networks.isEmpty {
            lines.append(
                "Networks: "
                    + networks.keys.sorted().map { name in nonEmpty(networks[name]?.IPAddress).map { "\(name) (\($0))" } ?? name }.joined(separator: ", "))
        }

        if let project {
            let service = project.services.first { $0.name == container.composeService }
            if let waits = service?.dependsOn, !waits.isEmpty { lines.append("Waits for: " + waits.joined(separator: ", ")) }
            let others = project.containers.filter { !$0.isOneOff && $0.Id != container.Id }
            if !others.isEmpty {
                lines.append("Other services: " + others.map { "\($0.composeService ?? $0.name) \($0.Status)" }.joined(separator: "; "))
            }
        }
        let files = project?.configFiles ?? (container.labels["com.docker.compose.project.config_files"]?.split(separator: ",").map(String.init) ?? [])
        let folder = project?.workingDir ?? container.composeWorkingDir
        if !files.isEmpty {
            lines.append("Compose files: " + files.joined(separator: ", ") + (folder.map { " — run in \($0)" } ?? ""))
        } else if let folder {
            lines.append("Compose folder: \(folder)")
        }
        lines.append("Engine: \(engine)")
        if logs == 0 { lines.append("It wrote no log lines.") }
        if !env.isEmpty {
            var said = env.prefix(maxEnv).map { "  \($0.key)=\(scrubbed(DockerSecrets.masked($0.key, $0.value)))" }
            if env.count > maxEnv { said.append("  … \(env.count - maxEnv) more") }
            lines.append("Env:\n" + said.joined(separator: "\n"))
        }
        return DockerSecrets.maskURLs(in: lines.joined(separator: "\n"))
    }

    /// A binding as `HostIp:HostPort→port`: `3000→3000`,
    /// `127.0.0.1:5432→5432`, `a port the engine picks→9229`.
    private static func spoken(_ binding: ContainerDetail.HostConfigDetail.PortBinding, _ key: String) -> String {
        let parts = key.split(separator: "/", maxSplits: 1)
        let port = parts.first.map(String.init) ?? key
        let proto = parts.count > 1 && parts[1] != "tcp" ? "/\(parts[1])" : ""
        let address = nonEmpty(binding.HostIp).flatMap { ["0.0.0.0", "::"].contains($0) ? nil : $0 }
        let host =
            nonEmpty(binding.HostPort).map { (address.map { "\($0):" } ?? "") + $0 }
            ?? (address.map { "\($0), " } ?? "") + "a port the engine picks"
        return "\(host)→\(port)\(proto)"
    }

    /// What a brief names anyway — the project, the service, the container,
    /// its image's repository — kept out of what scrubbing takes out
    /// (`DockerSecrets.values`): `POSTGRES_PASSWORD=postgres` would blank
    /// `shop-postgres-1`, `postgres:16` and every line of its log.
    static func names(of container: ContainerSummary, image: String? = nil) -> Set<String> {
        var names: Set<String> = [container.name]
        if let project = container.composeProject { names.insert(project) }
        if let service = container.composeService { names.insert(service) }
        for reference in [image, container.Image].compactMap({ $0 }) {
            // `registry:5000/team/postgres:16@sha256:…` → its path's names.
            var repository = reference.split(separator: "@").first.map(String.init) ?? reference
            if let colon = repository.lastIndex(of: ":"), !repository[colon...].contains("/") { repository = String(repository[..<colon]) }
            names.insert(repository)
            names.formUnion(repository.split(separator: "/").map(String.init))
        }
        return names
    }

    private static func stateLine(_ container: ContainerSummary, _ state: ContainerDetail.StateDetail, trouble: DockerAttention.Trouble?, code: Int?) -> String {
        let finished = nonEmpty(state.FinishedAt).flatMap { $0.hasPrefix("0001") ? nil : $0 }
        switch container.state {
        case .exited: return "exited" + (code.map { " (\($0))" } ?? "") + (finished.map { " at \($0)" } ?? "")
        case .restarting:
            if case .restarting(let exit?) = trouble { return "restarting — last exit \(exit)" }
            return "restarting" + (code.map { " — last exit \($0)" } ?? "")
        case .running: return "running"
        case .created: return "created, never started"
        case .dead: return "dead" + (code.map { " (\($0))" } ?? "")
        default: return container.State
        }
    }

    /// Nanoseconds, as a person says them: `30s`, `1.5s`, `2m`.
    static func duration(_ nanoseconds: Int) -> String {
        let seconds = Double(nanoseconds) / 1_000_000_000
        if seconds >= 60, seconds.truncatingRemainder(dividingBy: 60) == 0 { return "\(Int(seconds / 60))m" }
        if seconds == seconds.rounded() { return "\(Int(seconds))s" }
        return String(format: "%.1fs", seconds)
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        return text
    }

    /// Its last lines, newest last, scrubbed (but `keeping`, see
    /// `names`) — the newest that fit in `maxLogBytes`, saying when
    /// earlier ones were left out. The newest alone too long (a stack
    /// trace in one JSON line) is cut, not dropped: it is the crash. Nil
    /// for none.
    static func logs(
        _ lines: [DockerLogLine], env: [(key: String, value: String)], keeping names: Set<String> = []
    ) -> (count: Int, text: String)? {
        guard !lines.isEmpty else { return nil }
        let secrets = DockerSecrets.values(in: env, besides: names)
        var kept: [String] = []
        var size = 0
        for line in lines.reversed() {
            var text = DockerSecrets.maskURLs(in: DockerSecrets.redact(line.plain, values: secrets))
            let fits = size + text.utf8.count + 1 <= maxLogBytes
            if !fits {
                guard kept.isEmpty else { break }
                text = cut(text, bytes: maxLogBytes - 64) + " … (line cut)"
            }
            kept.append(text)
            size += text.utf8.count + 1
            if !fits { break }
        }
        let heading = "Its last \(kept.count) log line\(kept.count == 1 ? "" : "s") (newest last, secrets taken out):\n"
        let cut = kept.count < lines.count ? "… earlier lines left out\n" : ""
        return (kept.count, heading + cut + kept.reversed().joined(separator: "\n"))
    }

    /// Its service of `docker compose config --format json`'s model: picked
    /// here, since Compose renders the whole model with --no-interpolate.
    /// A secret-looking key's value masked (a `${VAR}` it names kept), an
    /// `environment` or `args` entry by its key, every URL's password;
    /// then scrubbed and bounded. Nil when it isn't there.
    static func service(
        _ name: String, inConfig json: Data, env: [(key: String, value: String)], keeping names: Set<String> = []
    ) -> String? {
        guard let model = try? JSONSerialization.jsonObject(with: json) as? [String: Any], let services = model["services"] as? [String: Any],
            let service = services[name] as? [String: Any],
            let data = try? JSONSerialization.data(withJSONObject: masked(service, under: nil), options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else { return nil }
        var text = DockerSecrets.scrub(String(decoding: data, as: UTF8.self), env: env, keeping: names)
        if text.utf8.count > maxServiceBytes { text = cut(text, bytes: maxServiceBytes) + "\n… the rest left out" }
        return "Its service in the compose file, as Compose reads it (variables as written):\n" + text
    }

    /// The keys whose words are a command: a literal password in one
    /// (`--requirepass hunter2`) is masked as the inspect's is.
    private static let commands: Set<String> = ["command", "entrypoint", "test"]

    private static func masked(_ value: Any, under key: String?) -> Any {
        switch value {
        case let map as [String: Any]:
            var out: [String: Any] = [:]
            for (inner, item) in map {
                if DockerSecrets.isSecret(inner), item is String || item is NSNumber {
                    let text = "\(item)"
                    out[inner] = DockerSecrets.isReference(text) ? text : DockerSecrets.mask(text)
                } else {
                    out[inner] = masked(item, under: inner)
                }
            }
            return out
        case let list as [Any]:
            if let key, commands.contains(key), let words = list as? [String] {
                return DockerSecrets.maskArguments(words).map(DockerSecrets.maskURLs(in:))
            }
            return list.map { item -> Any in
                guard key == "environment" || key == "args", let entry = item as? String, let equals = entry.firstIndex(of: "=") else {
                    return masked(item, under: nil)
                }
                let name = String(entry[..<equals])
                let value = String(entry[entry.index(after: equals)...])
                return name + "=" + (DockerSecrets.isReference(value) ? value : DockerSecrets.masked(name, value))
            }
        case let text as String:
            if let key, commands.contains(key) { return DockerSecrets.maskURLs(in: DockerSecrets.maskArguments([text])[0]) }
            return DockerSecrets.maskURLs(in: text)
        default:
            return value
        }
    }

    /// At most `bytes` of UTF-8, cut between characters.
    static func cut(_ text: String, bytes: Int) -> String {
        guard text.utf8.count > bytes else { return text }
        var end = text.startIndex
        var size = 0
        for index in text.indices {
            size += text[index].utf8.count
            guard size <= bytes else { break }
            end = text.index(after: index)
        }
        return String(text[..<end])
    }

    /// A selection widened to the whole lines it touches.
    static func wholeLines(of text: String, _ range: NSRange) -> String {
        let string = text as NSString
        let clamped = NSIntersectionRange(range, NSRange(location: 0, length: string.length))
        return string.substring(with: string.lineRange(for: clamped)).trimmingCharacters(in: .newlines)
    }
}

/// Reading what a brief says: the container's inspect data, its last log
/// lines, its compose service — once, when asked. A brief that can't be
/// scrubbed (no engine, no inspect: no env to take out) isn't made.
@MainActor
enum DockerAgentBriefing {
    /// `composeConfig`: the project's `docker compose config` JSON (a
    /// test's canned one); `composeConfig(of:endpoint:)` by default.
    static func brief(
        _ question: DockerAgentQuestion, docker: DockerModel, composeConfig: ((ComposeProject, DockerEndpoint?) async -> Data?)? = nil
    ) async throws -> DockerAgentBrief {
        guard let engine = docker.engine else { throw DockerError.unreachable("Docker isn't answering, so its secrets can't be taken out.") }
        let host = docker.publishedHost
        let engineName = host.map { "a remote engine at \($0)" } ?? docker.runtime.name
        switch question {
        case .failure(let asked):
            let container = docker.container(asked.Id) ?? asked
            let detail = try await engine.container(container.Id)
            let env = detail.env
            // A log that can't be read drops its chip, not the brief.
            var lines: [DockerLogLine]?
            do {
                var read: [DockerLogLine] = []
                for try await chunks in engine.logs(container.Id, tty: detail.Config.Tty ?? false, tail: DockerAgentText.logLines, follow: false) {
                    read += chunks.flatMap { DockerLogLine.lines(of: $0, timestamps: true) }
                }
                lines = read
            } catch {
                lines = nil
            }
            let project = docker.projects.first { $0.name == container.composeProject }
            let trouble = DockerAttention.trouble(of: container, detail: detail)
            let names = DockerAgentText.names(of: container, image: detail.Config.Image)
            var parts: [AskAgentModel.Part] = []
            if let logs = lines.flatMap({ DockerAgentText.logs($0, env: env, keeping: names) }) {
                parts.append(AskAgentModel.Part(title: logs.count == 1 ? "last log line" : "last \(logs.count) log lines", text: logs.text))
            }
            if let service = container.composeService, let project {
                let read = composeConfig ?? { await Self.composeConfig(of: $0, endpoint: $1) }
                if let json = await read(project, docker.endpoint), let text = DockerAgentText.service(service, inConfig: json, env: env, keeping: names) {
                    parts.append(AskAgentModel.Part(title: "compose service", text: text))
                }
            }
            let text = DockerAgentText.about(
                container, detail, trouble: trouble, ports: docker.ports(of: container), project: project, engine: engineName,
                memoryTotal: docker.info?.MemTotal, logs: lines?.count)
            return DockerAgentBrief(
                message: trouble?.question(container.name) ?? "", subject: "\(container.name) \(trouble?.detail ?? DockerStatusStyle.status(container))",
                text: text, parts: parts, folder: container.composeWorkingDir)
        case .logLines(let picked, let asked):
            let container = docker.container(asked.Id) ?? asked
            let detail = try await engine.container(container.Id)
            let project = docker.projects.first { $0.name == container.composeProject }
            let about = DockerAgentText.about(
                container, detail, trouble: DockerAttention.trouble(of: container, detail: detail), ports: docker.ports(of: container), project: project,
                engine: engineName, memoryTotal: docker.info?.MemTotal)
            return DockerAgentBrief(
                message: "", subject: nil,
                text: DockerSecrets.scrub(picked, env: detail.env, keeping: DockerAgentText.names(of: container, image: detail.Config.Image)),
                parts: [AskAgentModel.Part(title: container.name, text: "They come from this container's log:\n" + about)], folder: container.composeWorkingDir)
        case .projectLogLines(let picked, let asked):
            let project = docker.projects.first { $0.name == asked.name } ?? asked
            // Every service's secrets: a line can come from any of them.
            var env: [(key: String, value: String)] = []
            var names: Set<String> = [project.name]
            for container in project.containers where !container.isOneOff {
                let detail = try await engine.container(container.Id)
                env += detail.env
                names.formUnion(DockerAgentText.names(of: container, image: detail.Config.Image))
            }
            var about = "They come from compose project \(project.name)'s logs, each line after its service:\n" + DockerMCP.describe([project])
            if !project.configFiles.isEmpty { about += "\nCompose files: " + project.configFiles.joined(separator: ", ") }
            about += "\nEngine: \(engineName)"
            return DockerAgentBrief(
                message: "", subject: nil, text: DockerSecrets.scrub(picked, env: env, keeping: names),
                parts: [AskAgentModel.Part(title: project.name, text: DockerSecrets.scrub(about, env: env, keeping: names))], folder: project.workingDir)
        }
    }

    /// The project's model as Compose reads its files: `config
    /// --no-interpolate` keeps `${VAR}` as written, `--no-env-resolution`
    /// keeps env files unread (`DockerCLI.composeConfig` adds it where
    /// Compose knows it), so a `.env` password never comes in. Nil when
    /// Compose can't be asked here — no docker, its files not on this Mac,
    /// an isolated run without a stub — or doesn't answer in 5 s.
    static func composeConfig(of project: ComposeProject, endpoint: DockerEndpoint?) async -> Data? {
        guard DockerPageModel.mayAskCompose, let cli = DockerCLI(endpoint: endpoint) else { return nil }
        let files = ComposePortStore.shared.files(for: project)
        guard !files.isEmpty, files.allSatisfy({ FileManager.default.fileExists(atPath: $0) }) else { return nil }
        let folder = project.workingDir.flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil }
        let arguments =
            ["compose"] + (folder.map { ["--project-directory", $0] } ?? []) + ["-p", project.name] + files.flatMap { ["-f", $0] }
            + ["config", "--no-interpolate", "--format", "json"]
        guard let output = try? await cli.composeConfig(arguments, in: FileManager.default.homeDirectoryForCurrentUser, timeout: 5),
            let start = output.firstIndex(of: "{")
        else { return nil }
        return Data(output[start...].utf8)
    }
}
