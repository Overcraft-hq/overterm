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

    /// The command, each word quoted as the shell needs; `command` goes
    /// last as typed.
    func line(prefix: String = "") -> String {
        var words = ["docker", "run", detached ? "-d" : "-it"]
        if removeWhenStopped { words.append("--rm") }
        if !name.isEmpty { words += ["--name", DockerCommands.quote(name)] }
        if !restart.isEmpty, restart != "no" { words += ["--restart", restart] }
        if !network.isEmpty { words += ["--network", DockerCommands.quote(network)] }
        for port in ports where !port.isEmpty { words += ["-p", DockerCommands.quote(port)] }
        for entry in env where !entry.isEmpty { words += ["-e", DockerCommands.quote(entry)] }
        for volume in volumes where !volume.isEmpty { words += ["-v", DockerCommands.quote(volume)] }
        words.append(DockerCommands.quote(image))
        let trimmed = command.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { words.append(trimmed) }
        return prefix + words.joined(separator: " ")
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
        spec.env = (detail.Config.Env ?? []).filter { !inherited.contains($0) }
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
