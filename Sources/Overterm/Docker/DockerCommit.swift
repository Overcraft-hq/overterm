import Foundation

/// A container saved as an image (`docker commit`), as Overterm makes one:
/// what it is called, and what of the container is left out of it. The
/// engine only lets a commit override the container's env and labels,
/// never remove them: a secret is blanked (`ENV KEY=""`), a label
/// neutralized (`LABEL key=""`). On the classic image store the image
/// keeps the container's own config besides, so it is committed twice
/// there (`DockerEngine.commitAnew`). What a command holds stays: a
/// commit can't change it without changing what runs, so it is said. Pure.
enum DockerCommit {
    /// What Compose and Testcontainers find their containers by. In an
    /// image, every container run from it would be counted as theirs:
    /// `compose up` would take it for a replica of the service, and Ryuk
    /// would reap it.
    static let bookkeeping = ["com.docker.compose.", "org.testcontainers"]

    /// `ot-shop-web-1` → `ot-shop-web-1:20261028-2321`, the time it is
    /// saved: a second save never writes over the first.
    static func suggestedName(for name: String, at date: Date) -> String {
        let repository = name.lowercased().replacingOccurrences(of: #"[._-]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd-HHmm"
        return (repository.isEmpty ? "snapshot" : repository) + ":" + formatter.string(from: date)
    }

    /// Why the engine would refuse `repository:tag`, said before it is
    /// asked; nil when it would take it. A registry's host may be in any
    /// case, the rest of the name only in lower case.
    static func problem(_ reference: String) -> String? {
        if reference.contains("@") { return "A tag, not a digest: name:tag." }
        if reference.contains(where: \.isWhitespace) { return "No spaces in an image's name." }
        let (name, tag) = DockerEngine.split(reference)
        let components = name.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if name.isEmpty || components.contains("") { return "An image's name, then its tag: shop/web:1." }
        let host = components.count > 1 && (components[0].contains(".") || components[0].contains(":") || components[0] == "localhost")
        if components.dropFirst(host ? 1 : 0).contains(where: { $0 != $0.lowercased() }) { return "An image's name is lower-case." }
        if tag.range(of: #"^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$"#, options: .regularExpression) == nil {
            return "A tag is letters, digits, “_”, “.” and “-”, 128 at most."
        }
        return nil
    }

    /// The env keys whose values look like secrets — by their name, or a
    /// URL's password in them — and that its image didn't set itself
    /// (an image's own `GPG_KEY` stays). Sorted, once each.
    static func secretKeys(env: [String], imageEnv: [String]) -> [String] {
        let inherited = Set(imageEnv)
        var keys = Set<String>()
        for entry in env where !inherited.contains(entry) {
            guard let equals = entry.firstIndex(of: "=") else { continue }
            let key = String(entry[..<equals])
            let value = String(entry[entry.index(after: equals)...])
            guard !value.isEmpty, DockerSecrets.isSecret(key) || DockerSecrets.maskURL(value) != value else { continue }
            keys.insert(key)
        }
        return keys.sorted()
    }

    /// The Dockerfile lines the commit puts over the container's config:
    /// its secrets blanked, Compose's and Testcontainers' labels emptied.
    /// None when there is nothing to leave out.
    static func changes(env: [String], imageEnv: [String], labels: [String: String]) -> [String] {
        var lines: [String] = []
        let secrets = secretKeys(env: env, imageEnv: imageEnv)
        if !secrets.isEmpty { lines.append("ENV " + secrets.map { "\($0)=\"\"" }.joined(separator: " ")) }
        let theirs = bookkeepingLabels(labels)
        if !theirs.isEmpty { lines.append("LABEL " + theirs.map { "\($0)=\"\"" }.joined(separator: " ")) }
        return lines
    }

    /// Compose's and Testcontainers' among `labels`, sorted.
    static func bookkeepingLabels(_ labels: [String: String]) -> [String] {
        labels.keys.filter { key in bookkeeping.contains { key.hasPrefix($0) } }.sorted()
    }

    /// Where its volumes and bind mounts are: not in the image.
    static func volumes(of container: ContainerSummary) -> [String] {
        (container.Mounts ?? []).filter { $0.Type == "volume" || $0.Type == "bind" }.map(\.Destination)
    }

    /// Whether a command's words hold a password — a secret flag's value,
    /// `KEY=value`, a URL's, or one of the env's secret values (Compose
    /// puts `.env`'s into a command, where the env doesn't name them).
    static func holdsSecret(_ words: [String], values: [String] = []) -> Bool {
        guard !words.isEmpty else { return false }
        if DockerSecrets.maskArguments(words).map(DockerSecrets.maskURLs) != words { return true }
        return words.contains { word in values.contains { word.contains($0) } }
    }

    /// What a save leaves out, and what it can't: read from its inspect
    /// before it is asked, so the question says it.
    struct Plan: Equatable, Sendable {
        /// The env keys blanked (`secretKeys`).
        var secrets: [String] = []
        /// Compose's and Testcontainers' labels emptied.
        var labels: [String] = []
        /// The Dockerfile lines put over its config (`changes`).
        var changes: [String] = []
        /// Where its volumes and bind mounts are.
        var volumes: [String] = []
        /// What holds a password a commit keeps — `command`, `health
        /// check`: taking it out would change what runs.
        var keeps: [String] = []
        /// A running one is paused while it is copied.
        var running = false
    }

    static func plan(_ container: ContainerSummary, _ detail: ContainerDetail, imageEnv: [String]) -> Plan {
        let env = detail.Config.Env ?? []
        let labels = detail.Config.Labels ?? [:]
        let secrets = secretKeys(env: env, imageEnv: imageEnv)
        let command = (detail.Config.Entrypoint ?? []) + (detail.Config.Cmd ?? [])
        // A dev stack's password is often a name it says anyway
        // (`POSTGRES_PASSWORD=postgres`, and `postgres` runs): no secret.
        let image = DockerEngine.split(container.Image).0
        let names = Set(
            [container.name, container.composeProject, container.composeService, String(image.split(separator: "/").last ?? "")].compactMap { $0 }
                + command.map { ($0 as NSString).lastPathComponent })
        let values = DockerSecrets.values(in: detail.env.filter { secrets.contains($0.key) }, besides: names)
        let keeps = [
            holdsSecret(command, values: values) ? "command" : nil,
            holdsSecret(detail.Config.Healthcheck?.Test ?? [], values: values) ? "health check" : nil,
        ].compactMap { $0 }
        return Plan(
            secrets: secrets, labels: bookkeepingLabels(labels), changes: changes(env: env, imageEnv: imageEnv, labels: labels),
            volumes: volumes(of: container), keeps: keeps, running: container.state == .running)
    }

    /// The question's detail: what is in the image, and what isn't.
    static func explanation(_ plan: Plan) -> String {
        let listed = plan.volumes.prefix(3).joined(separator: ", ") + (plan.volumes.count > 3 ? ", …" : "")
        var said = ["Its files as they are now, in a new image — not its volumes" + (plan.volumes.isEmpty ? "." : " (\(listed)).")]
        let compose = plan.labels.contains { $0.hasPrefix("com.docker.compose.") }
        let tests = plan.labels.contains { $0.hasPrefix("org.testcontainers") }
        let labels = compose && tests ? "Compose's and Testcontainers' labels" : compose ? "Compose's labels" : tests ? "Testcontainers' labels" : nil
        let secrets = plan.secrets.isEmpty ? nil : "its env's secrets (\(plan.secrets.joined(separator: ", ")))"
        let left = [secrets, labels].compactMap { $0 }.joined(separator: " and ")
        if !left.isEmpty { said.append(left.prefix(1).uppercased() + left.dropFirst() + " are left out.") }
        if !plan.keeps.isEmpty {
            said.append("A password in its \(plan.keeps.joined(separator: " and ")) stays in the image: a commit keeps what it runs as it is.")
        }
        if plan.running { said.append("It is paused while it is copied.") }
        return said.joined(separator: " ")
    }

    /// What the page says once it is saved.
    static func note(name: String, repository: String, tag: String, id: String, plan: Plan) -> String {
        let short = String(id.replacingOccurrences(of: "sha256:", with: "").prefix(12))
        let left = [
            plan.volumes.isEmpty ? nil : "without its volumes", plan.secrets.isEmpty ? nil : "its secrets left out (\(plan.secrets.joined(separator: ", ")))",
        ]
        .compactMap { $0 }
        let kept = plan.keeps.isEmpty ? "" : " The password in its \(plan.keeps.joined(separator: " and ")) is in it."
        return "\(name) is the image \(repository):\(tag) (\(short))" + (left.isEmpty ? "." : " — " + left.joined(separator: ", ") + ".") + kept
    }
}
