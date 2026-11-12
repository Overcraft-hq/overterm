import Foundation

/// What a tab *is*, at a glance: the glyph in its icon tile.
///
/// Seven kinds, because in a window full of worktrees those are the things
/// a terminal turns out to be — an agent you are talking to, a server you
/// left running, a shell you type in, a machine you are on, a container
/// you are in (`docker exec`, what the Docker page opens), a pod you are in
/// (`kubectl exec -it`, `attach -it`, what the Kubernetes page opens), a
/// cluster a plain `kubectl` reaches (Terminal in this context,
/// `KubeTerminalPin`).
/// Shape carries it faster than the title does, and the title is often
/// truncated anyway.
///
/// Pure, so the rule can be read and tested without a process tree.
enum TabKind: String, Equatable {
    case agent, server, shell, ssh, container, pod, kubernetes

    /// The SF Symbol for the tile. An agent tab uses its own agent's symbol
    /// instead (`Agent.symbol`); this is the fallback.
    var symbol: String {
        switch self {
        case .agent: "sparkles"
        case .server: "cube"
        case .shell: "chevron.right"
        case .ssh: "globe"
        case .container: "shippingbox"
        case .pod: "shippingbox.circle"
        case .kubernetes: "helm"
        }
    }

    var name: String {
        switch self {
        case .agent: "Agent"
        case .server: "Server"
        case .shell: "Shell"
        case .ssh: "Remote"
        case .container: "Container"
        case .pod: "Pod"
        case .kubernetes: "Kubernetes context"
        }
    }

    /// `title` is what the shell last set — with shell integration that is
    /// the running command, which is the only cheap evidence there is.
    /// `hasPort` is whether anything in the tab's process tree listens
    /// (`ListeningPorts`), which is what makes a shell a server. `pinned`:
    /// its shell's `KUBECONFIG` pins a context — what that tab is, unless
    /// it is in a container, a pod or on another machine now.
    static func of(agent: Agent?, title: String, hasPort: Bool, pinned: Bool = false) -> TabKind {
        if agent != nil { return .agent }
        if isContainer(title) { return .container }
        if isPod(title) { return .pod }
        if isRemote(title) { return .ssh }
        if pinned { return .kubernetes }
        if hasPort { return .server }
        return .shell
    }

    /// A shell in a container: `docker exec -it`, `docker attach`, an
    /// interactive `docker run`, Compose's `exec` and `run`, `docker debug`
    /// — Podman's too. Whatever sets `DOCKER_HOST=…` first counts, and
    /// Compose's own options before its command (`-p shop -f compose.yaml`,
    /// as the Docker page types them). Read in the shell's words: a path
    /// with a space is quoted, and is one.
    private static func isContainer(_ title: String) -> Bool {
        var words = ShellCommandLine.words(title)
        while let first = words.first, first.contains("="), !first.hasPrefix("-") { words.removeFirst() }
        guard let tool = words.first, tool == "docker" || tool == "podman" else { return false }
        var rest = Array(words.dropFirst())
        if rest.first == "compose" {
            rest.removeFirst()
            while let option = rest.first, option.hasPrefix("-") {
                rest.removeFirst()
                if composeOptionsWithValues.contains(option), !rest.isEmpty { rest.removeFirst() }
            }
        } else if rest.first == "container" {
            rest.removeFirst()
        }
        guard let verb = rest.first else { return false }
        switch verb {
        case "exec", "attach", "debug": return true
        case "run": return rest.contains { $0 == "-it" || $0 == "-ti" || $0 == "-i" || $0 == "--interactive" } || words.contains("compose")
        default: return false
        }
    }

    /// A shell in a pod: `kubectl exec`, `attach` or `debug` with stdin
    /// (`-it`, `-i`, `--stdin`) — what `KubeCommands` types, its
    /// `--context` and `-n` wherever they are. Whatever sets a variable
    /// first counts. A `kubectl exec` without stdin runs one command and
    /// ends: not a shell.
    private static func isPod(_ title: String) -> Bool {
        var words = ShellCommandLine.words(title)
        while let first = words.first, first.contains("="), !first.hasPrefix("-") { words.removeFirst() }
        guard let tool = words.first, (tool as NSString).lastPathComponent == "kubectl" else { return false }
        var rest = Array(words.dropFirst())
        while let option = rest.first, option.hasPrefix("-") {
            rest.removeFirst()
            if kubectlOptionsWithValues.contains(option), !rest.isEmpty { rest.removeFirst() }
        }
        guard let verb = rest.first, ["exec", "attach", "debug"].contains(verb) else { return false }
        let options = rest.dropFirst().prefix { $0 != "--" }
        return options.contains { word in
            if ["--stdin", "--stdin=true", "-i=true"].contains(word) { return true }
            // Short flags together: -it, -ti, -i, -itq.
            guard word.hasPrefix("-"), !word.hasPrefix("--"), !word.contains("=") else { return false }
            let letters = word.dropFirst()
            return letters.contains("i") && letters.allSatisfy { "itq".contains($0) }
        }
    }

    /// kubectl's global options that take the next word.
    private static let kubectlOptionsWithValues: Set<String> = [
        "--context", "-n", "--namespace", "--kubeconfig", "--cluster", "--user", "-s", "--server", "--as", "--as-group", "--token",
        "--request-timeout", "--cache-dir", "-v",
    ]

    /// Compose's global options that take the next word (`--file=x` has
    /// it in itself).
    private static let composeOptionsWithValues: Set<String> = [
        "-p", "--project-name", "-f", "--file", "--profile", "--project-directory", "--env-file", "--ansi", "--progress", "--parallel",
    ]

    /// `ssh host`, `mosh host`, or a prompt a remote shell set — `user@host`
    /// before any space, which is what ssh leaves in the title.
    private static func isRemote(_ title: String) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        let first = trimmed.prefix { !$0.isWhitespace }
        if first == "ssh" || first == "mosh" { return true }
        guard let at = first.firstIndex(of: "@") else { return false }
        return at != first.startIndex && first.index(after: at) != first.endIndex && !first.contains("/")
    }
}
