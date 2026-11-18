import Foundation

/// What a forward typed in a terminal reaches (docs/design/activity/
/// analysis.md, 6.8 Owners rule 6, stage 4): a `kubectl port-forward` or an
/// `ssh -L` the person ran in a pane — not Overterm's own, which its
/// registries name — says its target from its argv, masked as every
/// command is (`ActivityText.command`): "port-forward → svc/web:80", "ssh
/// -L → db.internal:5432 via bastion". And a tunnel client: an `ssh -R`
/// says where the listener it reaches is published. Read from the masked
/// argv's words, past an interpreter that runs the tool's script
/// (`python3 …/kubectl …`), never run. Pure.
enum ActivityTypedForwards {
    /// `kubectl`'s options that take the next word.
    private static let kubectlValued: Set<String> = [
        "-n", "--namespace", "--context", "--kubeconfig", "--cluster", "--user", "--address", "--pod-running-timeout", "-s", "--server",
        "--token", "--as", "--as-group", "--request-timeout", "-v", "--v",
    ]
    /// `ssh`'s option letters that take a value (the rest of the word, or
    /// the next).
    private static let sshValued = Set("BbcDEeFIiJLlmOoPpQRSWw")

    /// The words from the tool's on: nil when no word's file is `tool`.
    private static func words(_ command: String, tool: String) -> [String]? {
        let words = ShellCommandLine.words(command)
        guard let index = words.prefix(4).firstIndex(where: { ($0 as NSString).lastPathComponent == tool }) else { return nil }
        return Array(words[(index + 1)...])
    }

    /// What `command`'s forward on local `port` reaches; nil when it is
    /// neither, or forwards another port.
    static func target(of command: String?, port: Int) -> String? {
        guard let command, port > 0 else { return nil }
        if let arguments = words(command, tool: "kubectl") { return kubectl(arguments, port: port) }
        if let arguments = words(command, tool: "ssh") { return sshLocal(arguments, port: port) }
        return nil
    }

    /// `kubectl port-forward [flags] TYPE/NAME [LOCAL:]REMOTE…`.
    static func kubectl(_ arguments: [String], port: Int) -> String? {
        var positionals: [String] = []
        var namespace: String?
        var context: String?
        var index = 0
        while index < arguments.count {
            let word = arguments[index]
            index += 1
            if word.hasPrefix("-") {
                let (name, inline) = split(word)
                var value = inline
                if value == nil, kubectlValued.contains(name), index < arguments.count {
                    value = arguments[index]
                    index += 1
                }
                if name == "-n" || name == "--namespace" { namespace = value }
                if name == "--context" { context = value }
                continue
            }
            positionals.append(word)
        }
        guard positionals.first == "port-forward", positionals.count >= 3 else { return nil }
        let resource = positionals[1]
        for spec in positionals.dropFirst(2) {
            let parts = spec.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            let local: Int?
            let remote: String
            switch parts.count {
            case 1:
                local = Int(parts[0])
                remote = parts[0]
            case 2:
                local = Int(parts[0])
                remote = parts[1]
            default:
                continue
            }
            guard local == port else { continue }
            var text = "port-forward → \(resource):\(remote)"
            var place: [String] = []
            if let namespace { place.append("namespace \(namespace)") }
            if let context { place.append("context \(context)") }
            if !place.isEmpty { text += " · " + place.joined(separator: ", ") }
            return text
        }
        return nil
    }

    /// `ssh -L [bind:]port:host:hostport destination`: the spec whose
    /// local port is `port`.
    static func sshLocal(_ arguments: [String], port: Int) -> String? {
        let (options, destination) = ssh(arguments)
        for spec in options["-L"] ?? [] {
            let parts = spec.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 3, Int(parts[parts.count - 3]) == port else { continue }
            let host = parts[parts.count - 2]
            let remote = parts[parts.count - 1]
            return "ssh -L → \(host):\(remote)" + (destination.map { " via \($0)" } ?? "")
        }
        if (options["-D"] ?? []).contains(where: { Int($0.split(separator: ":").last ?? "") == port }) {
            return "ssh -D: a SOCKS proxy" + (destination.map { " via \($0)" } ?? "")
        }
        return nil
    }

    /// An `ssh -R`'s published side for the local `port` it reaches:
    /// "ssh -R to bastion:8080"; nil when it doesn't reach that port.
    static func remoteForward(of command: String?, port: Int) -> String? {
        guard let command, let arguments = words(command, tool: "ssh") else { return nil }
        let (options, destination) = ssh(arguments)
        for spec in options["-R"] ?? [] {
            let parts = spec.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 3, Int(parts[parts.count - 1]) == port else { continue }
            let published = parts[parts.count - 3]
            return "ssh -R to \(destination ?? "a remote host"):\(published)"
        }
        return nil
    }

    /// ssh's options by name (each value, joined forms too: `-L5432:h:5432`,
    /// clustered ones as ssh reads them: `-fNL 5432:h:5432` — each letter a
    /// flag until the first that takes a value, which takes the rest of the
    /// word or the next) and its destination, the first word that isn't an
    /// option's.
    private static func ssh(_ arguments: [String]) -> (options: [String: [String]], destination: String?) {
        var options: [String: [String]] = [:]
        var destination: String?
        var index = 0
        while index < arguments.count {
            let word = arguments[index]
            index += 1
            if word == "--" {
                if index < arguments.count, destination == nil { destination = arguments[index] }
                break
            }
            if word.hasPrefix("-"), word.count >= 2 {
                let letters = word.dropFirst()
                guard let valued = letters.firstIndex(where: { sshValued.contains($0) }) else { continue }
                let name = "-\(letters[valued])"
                let rest = letters[letters.index(after: valued)...]
                if !rest.isEmpty {
                    options[name, default: []].append(String(rest))
                } else if index < arguments.count {
                    options[name, default: []].append(arguments[index])
                    index += 1
                }
                continue
            }
            if destination == nil { destination = word }
            break
        }
        return (options, destination)
    }

    /// `--name=value` as its name and value.
    private static func split(_ word: String) -> (String, String?) {
        guard let equals = word.firstIndex(of: "=") else { return (word, nil) }
        return (String(word[..<equals]), String(word[word.index(after: equals)...]))
    }
}
