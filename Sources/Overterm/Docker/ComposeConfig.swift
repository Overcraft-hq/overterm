import Foundation

/// A checkout's compose project as Compose itself makes it of the files —
/// `docker compose config --format json`, run in the checkout without
/// `-f`, so `up` there gets the same: the name Compose settles on, the
/// override merged, `include` and `extends` resolved, `.env` filled in,
/// only the active profiles' services. Compose keeps no record of a
/// project before its containers exist; this is it before it runs.
///
/// Only what a list shows is kept — never `environment`, `env_file`,
/// `secrets`, `configs` or `labels`: Compose answers with the variables'
/// values filled in. Pure, but for `stamp(of:)` and `dotEnvSecrets(in:)`.
struct ComposeConfig: Equatable, Sendable {
    struct Port: Hashable, Sendable {
        /// The host's port, as Compose writes it (`"8080"`, a range); nil
        /// when it publishes none.
        var published: String?
        var target: Int
        var proto: String

        var label: String { (published.map { "\($0)→" } ?? "") + "\(target)" + (proto == "tcp" ? "" : "/\(proto)") }
    }

    struct Service: Equatable, Sendable {
        var name: String
        /// Nil when it is built and not tagged.
        var image: String?
        /// The folder it is built from, absolute (or a git URL).
        var buildContext: String?
        var dependsOn: [String]
        var profiles: [String]
        var ports: [Port]
        /// The containers `up` makes of it.
        var replicas: Int
        var containerName: String?

        /// What it runs, as a row says it: its image, the folder it is built
        /// from (relative to the checkout), the services it waits for.
        func summary(in folder: String?) -> String {
            var parts: [String] = []
            if let image { parts.append(image) }
            if let buildContext { parts.append("built from " + ComposeConfig.relative(buildContext, to: folder)) }
            if !dependsOn.isEmpty { parts.append("after " + dependsOn.joined(separator: ", ")) }
            return parts.joined(separator: " · ")
        }
    }

    var name: String
    /// By name.
    var services: [Service]

    /// What `docker compose config` is asked for the list: JSON. Profiles
    /// before the command, as Compose takes them. `DockerCLI.composeConfig`
    /// adds `--no-env-resolution`.
    static func arguments(profiles: [String] = []) -> [String] {
        ["compose"] + profiles.flatMap { ["--profile", $0] } + ["config", "--format", "json"]
    }

    /// Leaves env files' contents out of the answer (Compose 2.35 and later).
    static let noEnvResolution = "--no-env-resolution"

    /// Compose before 2.35 doesn't know the flag: asked again without it.
    static func lacksEnvResolution(_ stderr: String) -> Bool {
        stderr.contains("unknown flag: --no-env-resolution")
    }

    /// What Compose answered, read for what a list shows and nothing else.
    static func parse(_ output: String) throws -> ComposeConfig {
        let notAProject = DockerError(status: 0, message: "Compose's answer isn't a project.")
        guard let start = output.firstIndex(of: "{"),
            let json = try? JSONSerialization.jsonObject(with: Data(output[start...].utf8)) as? [String: Any],
            let name = json["name"] as? String, !name.isEmpty
        else { throw notAProject }
        let services = (json["services"] as? [String: Any] ?? [:]).compactMap { name, value -> Service? in
            guard let service = value as? [String: Any] else { return nil }
            return Self.service(name, service)
        }
        return ComposeConfig(name: name, services: services.sorted { $0.name < $1.name })
    }

    private static func service(_ name: String, _ json: [String: Any]) -> Service {
        let build: String? =
            if let build = json["build"] as? [String: Any] { build["context"] as? String } else { json["build"] as? String }
        let dependsOn: [String] =
            if let map = json["depends_on"] as? [String: Any] { Array(map.keys) } else { json["depends_on"] as? [String] ?? [] }
        let ports = (json["ports"] as? [Any] ?? []).compactMap { value -> Port? in
            guard let port = value as? [String: Any], let target = number(port["target"]) else { return nil }
            let published = (port["published"] as? String) ?? number(port["published"]).map(String.init)
            return Port(published: published?.isEmpty == true ? nil : published, target: target, proto: port["protocol"] as? String ?? "tcp")
        }
        let deploy = json["deploy"] as? [String: Any]
        return Service(
            name: name, image: json["image"] as? String, buildContext: build, dependsOn: dependsOn.sorted(),
            profiles: json["profiles"] as? [String] ?? [], ports: ports,
            replicas: number(deploy?["replicas"]) ?? number(json["scale"]) ?? 1, containerName: json["container_name"] as? String)
    }

    private static func number(_ value: Any?) -> Int? {
        if let number = value as? Int { return number }
        if let text = value as? String { return Int(text) }
        return nil
    }

    /// The project before it runs: its services have no containers, and
    /// `up` runs in its folder without `-f`, so it reads what this did.
    func project(in folder: String) -> ComposeProject {
        ComposeProject(
            name: name, workingDir: folder, configFiles: [],
            services: services.map { ComposeService(project: name, name: $0.name, containers: [], dependsOn: $0.dependsOn, spec: $0) }, planned: true)
    }

    /// What Compose said when it couldn't, in its own words: its warnings
    /// (an unset variable) left out, `msg="…"` unwrapped, three lines at most.
    static func message(_ error: Error) -> String {
        guard let error = error as? GitError else { return error.localizedDescription }
        if error.status == -1 { return "docker compose config didn't answer in time." }
        let lines = error.stderr.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            guard !line.contains("level=warning") else { return nil }
            var text = String(line)
            if let range = text.range(of: "msg=\"") {
                text = String(text[range.upperBound...])
                if text.hasSuffix("\"") { text.removeLast() }
                text = text.replacingOccurrences(of: "\\\"", with: "\"")
            }
            text = text.trimmingCharacters(in: .whitespaces)
            return text.isEmpty ? nil : text
        }
        return lines.isEmpty ? "docker compose config failed (\(error.status))." : lines.prefix(3).joined(separator: "\n")
    }

    // MARK: The resolved config, in the editor

    /// `docker compose config`'s YAML with what it filled in from the
    /// variables taken out again, since the editor's copy is a file: in
    /// `environment` and a build's `args`, a secret-looking variable's value
    /// masked and a URL's password (`DockerSecrets`, as a container's env
    /// is shown); anywhere else (`command`, a healthcheck), each of
    /// `secrets` — the project's `.env` ones (`dotEnvSecrets`).
    static func masked(_ yaml: String, secrets: [String] = []) -> String {
        var lines: [String] = []
        // The indent of the `environment:` or `args:` the lines are under.
        var block: Int?
        // The entry before, for the lines of a block scalar under it.
        var entry: (indent: Int, secret: Bool)?
        for line in yaml.components(separatedBy: "\n") {
            let indent = line.prefix { $0 == " " }.count
            let body = line.dropFirst(indent).trimmingCharacters(in: .whitespaces)
            if let open = block, !body.isEmpty, indent <= open {
                block = nil
                entry = nil
            }
            if block != nil, !body.isEmpty {
                let pad = String(repeating: " ", count: indent)
                if let last = entry, indent > last.indent {
                    lines.append(last.secret ? pad + DockerSecrets.mask(body) : line)
                    continue
                }
                let masked = maskedEntry(body)
                entry = (indent, masked.secret)
                lines.append(pad + masked.text)
                continue
            }
            if body == "environment:" || body == "args:" { block = indent }
            lines.append(line)
        }
        return redact(lines.joined(separator: "\n"), secrets)
    }

    /// One `KEY: value` (or `- KEY=value`) of an `environment` or `args`.
    private static func maskedEntry(_ body: String) -> (text: String, secret: Bool) {
        if body.hasPrefix("- "), let equals = body.firstIndex(of: "=") {
            let key = body[body.index(body.startIndex, offsetBy: 2)..<equals].trimmingCharacters(in: .whitespaces)
            return ("- \(key)=" + DockerSecrets.masked(key, String(body[body.index(after: equals)...])), DockerSecrets.isSecret(key))
        }
        guard let colon = body.range(of: ": ") ?? (body.hasSuffix(":") ? body.range(of: ":", options: .backwards) : nil) else {
            return (body, false)
        }
        var key = String(body[..<colon.lowerBound])
        if let quote = key.first, quote == "\"" || quote == "'", key.count >= 2, key.last == quote { key = String(key.dropFirst().dropLast()) }
        let secret = DockerSecrets.isSecret(key)
        var value = body[colon.upperBound...].trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty, value != "null", value != "~", !value.hasPrefix("|"), !value.hasPrefix(">") else { return (body, secret) }
        var quote = ""
        if let first = value.first, first == "\"" || first == "'", value.count >= 2, value.last == first {
            quote = String(first)
            value = String(value.dropFirst().dropLast())
        }
        let masked = DockerSecrets.masked(key, value)
        return masked == value ? (body, secret) : (String(body[..<colon.upperBound]) + quote + masked + quote, secret)
    }

    /// Each of `values` taken out of `text` where it stands on its own —
    /// not inside a longer word.
    static func redact(_ text: String, _ values: [String]) -> String {
        values.sorted { $0.count > $1.count }.reduce(text) { text, value in
            let pattern = "(?<![A-Za-z0-9_])" + NSRegularExpression.escapedPattern(for: value) + "(?![A-Za-z0-9_])"
            guard let expression = try? NSRegularExpression(pattern: pattern) else { return text }
            return expression.stringByReplacingMatches(
                in: text, range: NSRange(text.startIndex..., in: text), withTemplate: NSRegularExpression.escapedTemplate(for: DockerSecrets.mask(value)))
        }
    }

    /// The secrets a project's `.env` holds, which Compose fills in wherever
    /// the files name them: secret-looking variables' values, long enough
    /// not to be a word found anywhere (`true`).
    static func dotEnvSecrets(in folder: URL) -> [String] {
        guard let text = try? String(contentsOf: folder.appendingPathComponent(".env"), encoding: .utf8) else { return [] }
        return DockerSecrets.values(in: DotEnv.parse(text).map { (key: $0.key, value: $0.value) }).filter { $0.count >= 6 }
    }

    /// A build folder as a row says it: `./api` inside the checkout.
    static func relative(_ path: String, to folder: String?) -> String {
        guard let folder, !folder.isEmpty else { return (path as NSString).abbreviatingWithTildeInPath }
        let base = folder.hasSuffix("/") ? String(folder.dropLast()) : folder
        if path == base { return "./" }
        if path.hasPrefix(base + "/") { return "./" + path.dropFirst(base.count + 1) }
        return (path as NSString).abbreviatingWithTildeInPath
    }

    // MARK: When to read it again

    /// The files at a checkout's top that Compose reads, each with its size
    /// and modification time: a read is due when this changes.
    struct Stamp: Equatable, Sendable {
        var files: [String: String]
    }

    static func stamp(of folder: URL) -> Stamp {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        let entries = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys)) ?? []
        var files: [String: String] = [:]
        for entry in entries where isComposeInput(entry.lastPathComponent) {
            let values = try? entry.resourceValues(forKeys: Set(keys))
            files[entry.lastPathComponent] = "\(values?.fileSize ?? -1):\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        }
        return Stamp(files: files)
    }

    /// The compose files, their overrides and `COMPOSE_FILE`'s, and `.env`.
    static func isComposeInput(_ name: String) -> Bool {
        name == ".env" || name.hasSuffix(".env") || name.hasSuffix(".yaml") || name.hasSuffix(".yml")
    }

    /// Whether FSEvents' paths include the folder itself — a change among
    /// its own entries, not deeper. `/var` and `/tmp` are `/private`'s.
    static func touches(_ paths: [String], folder: String) -> Bool {
        paths.contains { path in
            var path = path
            while path.count > 1, path.hasSuffix("/") { path.removeLast() }
            if path.hasPrefix("/var/") || path.hasPrefix("/tmp/") { path = "/private" + path }
            return path == folder
        }
    }
}

extension DockerCLI {
    /// `docker compose … config` in `folder`, env files' contents left out
    /// where Compose can. Compose before 2.35 doesn't know the flag and is
    /// asked again without it: its answer holds them then, and what reads
    /// it keeps none (the list) or masks them (the editor's copy).
    func composeConfig(_ arguments: [String], in folder: URL, timeout: TimeInterval) async throws -> String {
        do {
            return try await run(arguments + [ComposeConfig.noEnvResolution], in: folder, timeout: timeout)
        } catch let error as GitError where ComposeConfig.lacksEnvResolution(error.stderr) {
            return try await run(arguments, in: folder, timeout: timeout)
        }
    }
}
