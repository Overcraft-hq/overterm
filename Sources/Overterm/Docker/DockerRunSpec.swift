import Foundation

/// A `docker run`, as the Run window fills it in and as Copy as `docker
/// run` reads it off a container: written out as the command a terminal
/// tab runs, where the user sees it pull and start. Pure.
struct DockerRunSpec: Equatable, Sendable {
    var image: String
    var name = ""
    /// `8080:80`, `127.0.0.1:5432:5432`, `53:53/udp`.
    var ports: [String] = []
    /// `KEY=value`.
    var env: [String] = []
    /// `name:/data`, `/host/path:/in:ro`.
    var volumes: [String] = []
    /// What runs instead of the image's command, as typed.
    var command = ""
    /// In the background (`-d`), else in the tab with a terminal (`-it`).
    var detached = true
    var removeWhenStopped = false
    /// `no` (unset), `always`, `unless-stopped`, `on-failure`.
    var restart = ""
    var network = ""
    /// What runs instead of the image's entrypoint: one program, as
    /// `--entrypoint` takes it (its other words lead `command`).
    var entrypoint = ""
    /// Env asked for in the tab as it runs, never filled in here: a value
    /// a Secret holds, one that looks secret, a ConfigMap's that isn't read
    /// (a pod's Run Locally — docs/design/kubernetes/analysis.md, 3.12).
    var asked: [Ask] = []
    /// What the window says about where this came from and what was left out.
    var notes: [String] = []

    /// One env value asked for when the command runs: its name, where the
    /// cluster takes it from, and whether what is typed is hidden.
    struct Ask: Equatable, Sendable, Identifiable {
        var key: String
        /// `Secret db-auth, key password`.
        var from: String
        var secret: Bool
        /// Passed to the container by name (`-e KEY`); false for a value
        /// its command takes (`"$KEY"` among Command's words), not its env.
        var env = true

        var id: String { key }

        /// A name a POSIX shell can read into, and one neither the shell
        /// running `docker` nor `docker` itself reads: the value is read
        /// into a variable of that name and exported before `exec docker`,
        /// so an asked `PATH`, `HOME`, `IFS`, `LD_PRELOAD` or `DOCKER_HOST`
        /// would change which docker runs, or what it reaches.
        static func askable(_ key: String) -> Bool {
            guard let first = key.unicodeScalars.first, first == "_" || (first.isASCII && CharacterSet.letters.contains(first)) else { return false }
            return key.unicodeScalars.allSatisfy { $0 == "_" || ($0.isASCII && CharacterSet.alphanumerics.contains($0)) } && !reserved(key)
        }

        /// What the wrapper shell or the docker CLI reads from its env.
        static func reserved(_ key: String) -> Bool {
            let upper = key.uppercased()
            let names: Set<String> = [
                "PATH", "HOME", "IFS", "ENV", "BASH_ENV", "CDPATH", "PS1", "PS2", "PS4", "OPTIND", "OPTARG", "PWD", "OLDPWD", "PPID", "SHELL",
                "TMPDIR", "USER", "LOGNAME", "TERM", "HTTP_PROXY", "HTTPS_PROXY", "NO_PROXY", "ALL_PROXY", "SSH_AUTH_SOCK", "XDG_CONFIG_HOME",
            ]
            return names.contains(upper) || ["LD_", "DYLD_", "DOCKER_", "BUILDX_", "COMPOSE_"].contains { upper.hasPrefix($0) }
        }
    }

    /// The command, each word quoted as the shell needs; `command` goes
    /// last as typed. With env asked for, the run is a `sh -c` that reads
    /// each value from the tab first — hidden for a secret — and passes it
    /// by name (`-e KEY`): typed into the tab, it never reaches Overterm,
    /// the command line, the shell's history or a file.
    func line(prefix: String = "") -> String {
        var words = ["docker", "run", detached ? "-d" : "-it"]
        if removeWhenStopped { words.append("--rm") }
        if !name.isEmpty { words += ["--name", DockerCommands.quote(name)] }
        if !restart.isEmpty, restart != "no" { words += ["--restart", restart] }
        if !network.isEmpty { words += ["--network", DockerCommands.quote(network)] }
        let program = entrypoint.trimmingCharacters(in: .whitespaces)
        if !program.isEmpty { words += ["--entrypoint", DockerCommands.quote(program)] }
        for port in ports where !port.isEmpty { words += ["-p", DockerCommands.quote(port)] }
        for entry in env where !entry.isEmpty { words += ["-e", DockerCommands.quote(entry)] }
        let reads = asked.filter { Ask.askable($0.key) }
        for ask in reads where ask.env { words += ["-e", ask.key] }
        for volume in volumes where !volume.isEmpty { words += ["-v", DockerCommands.quote(volume)] }
        words.append(DockerCommands.quote(image))
        let trimmed = command.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { words.append(trimmed) }
        guard !reads.isEmpty else { return prefix + words.joined(separator: " ") }
        // `DOCKER_HOST=… ` before `exec` is no assignment: exported first.
        let trimmedPrefix = prefix.trimmingCharacters(in: .whitespaces)
        // Interrupted or ended (^C, ^D), nothing runs and the echo is back.
        var script = ["trap 'stty echo 2>/dev/null' EXIT", "trap 'stty echo 2>/dev/null; exit 130' INT TERM"]
        if !trimmedPrefix.isEmpty { script.append("export \(trimmedPrefix)") }
        for ask in reads {
            let prompt = DockerCommands.quote("\(ask.key) (\(ask.from)): ")
            script.append(
                "printf '%s' \(prompt); "
                    + (ask.secret
                        ? "stty -echo 2>/dev/null; IFS= read -r \(ask.key) || exit 1; stty echo 2>/dev/null; echo"
                        : "IFS= read -r \(ask.key) || exit 1")
                    + "; if [ -n \"$\(ask.key)\" ]; then export \(ask.key); else unset \(ask.key); fi")
        }
        script.append("exec " + words.joined(separator: " "))
        return "sh -c " + DockerCommands.quote(script.joined(separator: "; "))
    }

    /// A secret's entry as its name alone: `-e POSTGRES_PASSWORD` passes the
    /// value from the shell running it, if it has one. Copied whole, the
    /// password went to the clipboard, the tab's command line, the
    /// shell's history and `ps` — what CLAUDE.md says a secret never does.
    /// A URL's password the same way (`DATABASE_URL=postgres://u:p@db`).
    static func withoutSecret(_ entry: String) -> String {
        guard let equals = entry.firstIndex(of: "=") else { return entry }
        let key = String(entry[..<equals])
        let value = String(entry[entry.index(after: equals)...])
        let secret = DockerSecrets.isSecret(key) || DockerSecrets.maskURL(value) != value
        return secret && !value.isEmpty ? key : entry
    }

    /// One a line, blank lines dropped: what the window's text boxes hold.
    static func lines(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// What made `container`, as far as its own settings go: the env the
    /// image sets (`imageEnv`) and Compose's own labels left out, its
    /// published ports, mounts, restart policy and network, its command
    /// when it isn't the image's.
    static func from(_ container: ContainerSummary, _ detail: ContainerDetail, imageEnv: [String], imageCommand: [String]) -> DockerRunSpec {
        var spec = DockerRunSpec(image: detail.Config.Image ?? container.Image)
        spec.name = container.name
        let inherited = Set(imageEnv)
        spec.env = (detail.Config.Env ?? []).filter { !inherited.contains($0) }.map(Self.withoutSecret)
        spec.ports = PublishedPort.of(container.Ports ?? []).map { port in
            // An IPv6 address in brackets, as -p reads it: `[::1]:8080:80`.
            (port.hostIP.map { ($0.contains(":") ? "[\($0)]" : $0) + ":" } ?? "") + "\(port.hostPort):\(port.containerPort)"
                + (port.proto == "tcp" ? "" : "/\(port.proto)")
        }
        spec.volumes = (detail.Mounts ?? []).compactMap { mount in
            let source = mount.Type == "volume" ? mount.Name : mount.Source
            guard let source, !source.isEmpty else { return nil }
            return "\(source):\(mount.Destination)" + (mount.RW == false ? ":ro" : "")
        }
        if let policy = detail.HostConfig?.RestartPolicy?.Name, !policy.isEmpty, policy != "no" { spec.restart = policy }
        if let mode = detail.HostConfig?.NetworkMode, !["default", "bridge", ""].contains(mode) { spec.network = mode }
        let cmd = detail.Config.Cmd ?? []
        if !cmd.isEmpty, cmd != imageCommand { spec.command = cmd.map(DockerCommands.quote).joined(separator: " ") }
        spec.detached = detail.Config.Tty != true
        return spec
    }
}
