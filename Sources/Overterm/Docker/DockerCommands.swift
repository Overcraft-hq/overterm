import Foundation

/// The `docker` commands Overterm types into a terminal tab rather than
/// running itself: what takes long, prints as it goes, asks for input or
/// for credentials — `compose up`, a shell in a container, a log followed.
/// The user sees them and can run them again. Pure.
enum DockerCommands {
    /// What the shell needs to reach Overterm's engine. Nothing when the
    /// shell finds the same one by itself (the CLI's own rules).
    static func prefix(for endpoint: DockerEndpoint?) -> String {
        guard let endpoint else { return "" }
        switch endpoint.source {
        case "docker.context": return endpoint.context.map { "DOCKER_CONTEXT=\(quote($0)) " } ?? ""
        case "docker.endpoint", "OVERTERM_DOCKER_HOST": return "DOCKER_HOST=\(quote(endpoint.host)) "
        default: return ""
        }
    }

    /// A compose verb for a project Compose knows by its labels. `up`,
    /// `pull` and `build` need the files it came from; `down`, `stop`,
    /// `restart` and `logs` find it by name. One before it runs (`planned`)
    /// is its folder's files, where the command runs: no `-p`, no `-f`, so
    /// Compose names it from the files as they are then — a name read
    /// earlier may be stale, and `-p` would make a project of it.
    static func compose(_ project: ComposeProject, _ verb: String, endpoint: DockerEndpoint? = nil) -> String {
        let needsFiles = ["up", "pull", "build", "config", "create"].contains(verb.split(separator: " ").first.map(String.init) ?? verb)
        var parts = ["docker", "compose"]
        if !project.planned {
            parts += ["-p", quote(project.name)]
            if needsFiles { parts += project.configFiles.flatMap { ["-f", quote($0)] } }
        }
        parts.append(verb)
        return prefix(for: endpoint) + parts.joined(separator: " ")
    }

    /// A shell in it: bash where there is one, else sh.
    static func shell(in container: ContainerSummary, endpoint: DockerEndpoint? = nil) -> String {
        prefix(for: endpoint) + "docker exec -it \(quote(container.name)) sh -c 'command -v bash >/dev/null 2>&1 && exec bash || exec sh'"
    }

    /// A shell with tools beside a container — for an image with none of
    /// its own (distroless, scratch): a toolbox container sharing its
    /// processes and network, its volumes mounted; its own files are at
    /// `/proc/1/root`. Docker Debug's work, without its subscription.
    static func debugShell(beside container: ContainerSummary, image: String, endpoint: DockerEndpoint? = nil) -> String {
        let name = quote(container.name)
        return prefix(for: endpoint) + "docker run --rm -it --pid container:\(name) --network container:\(name) --volumes-from \(name) \(quote(image))"
    }

    /// Docker Scout on an image: `quickview` (its vulnerabilities, its base
    /// image's), `cves` (each, by package), `recommendations` (a newer
    /// base). It sends the image's packages to Docker's service, so only
    /// when asked, where the user sees it work.
    static func scout(_ verb: String, image: String, endpoint: DockerEndpoint? = nil) -> String {
        prefix(for: endpoint) + "docker scout \(verb) \(quote(image))"
    }

    static func followLogs(of container: ContainerSummary, endpoint: DockerEndpoint? = nil) -> String {
        prefix(for: endpoint) + "docker logs -f --tail 200 \(quote(container.name))"
    }

    /// A word as the shell reads it: as it is when it is plain, else in
    /// single quotes.
    static func quote(_ word: String) -> String {
        let plain = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_./:=@%+,"))
        if !word.isEmpty, word.unicodeScalars.allSatisfy(plain.contains) { return word }
        return "'" + word.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }
}
