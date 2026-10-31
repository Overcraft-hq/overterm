import Foundation

/// A host port by protocol: what one bind takes.
struct ComposePortKey: Hashable, Sendable {
    var port: Int
    var proto: String
}

/// A host port Up on Free Ports moved: what a service's file asks for
/// (`from`), published on `to` instead.
struct ComposePortMove: Codable, Hashable, Sendable {
    var service: String
    var target: Int
    var proto: String
    var from: Int
    var to: Int

    /// `web 8080 → 18080`, `/udp` when it isn't TCP.
    var label: String { "\(service) \(from) → \(to)" + (proto == "tcp" ? "" : "/\(proto)") }
}

/// A checkout's stack on ports of its own, as Overterm keeps it
/// (`ComposePortStore`): the name it runs as and what moved, written as an
/// override file passed after the checkout's own.
struct ComposePortOverride: Codable, Equatable, Sendable {
    /// Compose's project folder — its first file's, as a real path: the key.
    var folder: String
    /// The name it runs as.
    var project: String
    /// The name its own files give it.
    var fileName: String
    /// The checkout's compose files (real paths, in Compose's order).
    var baseFiles: [String]
    var moves: [ComposePortMove]
    var made: Date
    /// What its base files and their folder's `.env` were when it was
    /// written, by size and date (`ComposePortStore.stamp`): when they
    /// differ, it is written again from them before a command reads it.
    /// Nil in one written before it was kept.
    var stamp: [String: String]? = nil

    /// `web 8080 → 18080 · db 5432 → 15432`; with nothing moved, the name.
    var summary: String {
        moves.isEmpty ? "its own name, “\(project)” (its files say “\(fileName)”)" : moves.map(\.label).joined(separator: " · ")
    }
}

/// A port a stack wants that something holds.
struct ComposePortConflict: Equatable, Sendable {
    var service: String
    var port: Int
    var proto: String
    var holder: DockerPortConflict.Holder
}

/// What an Up of a checkout's stack would run into, and what Up on Free
/// Ports would do about it: which ports go where, under which name. Pure.
struct ComposePortPlan: Equatable, Sendable {
    /// The name the files give the project…
    var fileName: String
    /// …and the one it would run as.
    var name: String
    /// Another checkout's folder, when its stack has the files' name: an Up
    /// as written would take that stack's containers over.
    var nameHolder: String?
    var moves: [ComposePortMove]
    /// Taken ports of services this Up starts: what makes it ask.
    var blocking: [ComposePortConflict]
    /// Taken ports with no free one near: they stay as written.
    var unmovable: [ComposePortConflict]
    /// The project's own volumes, new (empty) under another name.
    var ownVolumes: [String]
    /// Services with a `container_name`, which collides whatever the
    /// project is called.
    var fixedNames: [String]

    var needsAsking: Bool { !blocking.isEmpty || nameHolder != nil }
    /// Whether an override would change anything.
    var changes: Bool { !moves.isEmpty || name != fileName }

    /// Every host port of every service, in the services' order (by name)
    /// and each one's: a range and one Docker picks are left to Docker; a
    /// port has one `to` in the plan, whichever service or address family
    /// asks for it. For each: the move already made, while its `to` is
    /// free and no other override has it (`reserved`: two windows can
    /// answer the question at once) — so a URL doesn't change once its
    /// first holder has gone — else as written while it isn't taken, else
    /// the first free candidate (`candidates`) that no other override has
    /// and the files don't want themselves. Only services that start (no
    /// profile, or an active one, `*` all) ask; every service's is moved.
    static func make(
        config: ComposeConfig, active: Set<String>, taken: [ComposePortKey: DockerPortConflict.Holder], isFree: (Int, String) -> Bool,
        reserved: Set<Int>, keep: [ComposePortMove], name: String, nameHolder: String?
    ) -> ComposePortPlan {
        var wanted = Set<ComposePortKey>()
        for service in config.services {
            for port in service.ports {
                if let host = port.hostPort { wanted.insert(ComposePortKey(port: host, proto: port.proto)) }
            }
        }
        var chosen: [ComposePortKey: Int] = [:]
        var stays = Set<ComposePortKey>()
        var used = Set<ComposePortKey>()
        var moves: [ComposePortMove] = []
        var blocking: [ComposePortConflict] = []
        var unmovable: [ComposePortConflict] = []
        func available(_ port: Int, _ proto: String) -> Bool {
            let key = ComposePortKey(port: port, proto: proto)
            return !wanted.contains(key) && !used.contains(key) && isFree(port, proto)
        }
        for service in config.services {
            let starts = service.profiles.isEmpty || active.contains("*") || !active.isDisjoint(with: service.profiles)
            var seen = Set<ComposePortKey>()
            for port in service.ports {
                guard let from = port.hostPort else { continue }
                let key = ComposePortKey(port: from, proto: port.proto)
                guard seen.insert(key).inserted else { continue }
                func move(to: Int) {
                    chosen[key] = to
                    used.insert(ComposePortKey(port: to, proto: port.proto))
                    moves.append(ComposePortMove(service: service.name, target: port.target, proto: port.proto, from: from, to: to))
                }
                if let to = chosen[key] {
                    moves.append(ComposePortMove(service: service.name, target: port.target, proto: port.proto, from: from, to: to))
                    if let holder = taken[key], starts { blocking.append(ComposePortConflict(service: service.name, port: from, proto: port.proto, holder: holder)) }
                    continue
                }
                if !stays.contains(key),
                    let kept = keep.first(where: { $0.service == service.name && $0.proto == port.proto && $0.from == from && $0.target == port.target }),
                    !reserved.contains(kept.to), available(kept.to, port.proto)
                {
                    move(to: kept.to)
                    continue
                }
                guard let holder = taken[key] else {
                    stays.insert(key)
                    continue
                }
                if starts { blocking.append(ComposePortConflict(service: service.name, port: from, proto: port.proto, holder: holder)) }
                if stays.contains(key) { continue }
                if let to = candidates(for: from).first(where: { !reserved.contains($0) && available($0, port.proto) }) {
                    move(to: to)
                } else {
                    stays.insert(key)
                    unmovable.append(ComposePortConflict(service: service.name, port: from, proto: port.proto, holder: holder))
                }
            }
        }
        let fixed = config.services.filter { service in
            service.containerName != nil && (service.profiles.isEmpty || active.contains("*") || !active.isDisjoint(with: service.profiles))
        }
        return ComposePortPlan(
            fileName: config.name, name: name, nameHolder: nameHolder, moves: moves, blocking: blocking, unmovable: unmovable,
            ownVolumes: name == config.name ? [] : config.projectVolumes, fixedNames: fixed.map(\.name))
    }

    /// A kept override against the files as they are now, nothing looked
    /// at: each move kept while its service still publishes that port and
    /// the files don't want its `to` themselves, the rest as the files
    /// say. A command that isn't an Up reads the override this way
    /// (`ComposePortStore.refresh`); only an Up moves ports.
    static func refreshed(_ kept: ComposePortOverride, config: ComposeConfig) -> ComposePortPlan {
        make(config: config, active: [], taken: [:], isFree: { _, _ in true }, reserved: [], keep: kept.moves, name: kept.project, nameHolder: nil)
    }

    /// Where a taken port may go, in order: 10 000 up at a time while that
    /// stays below the ephemeral range (49152, the system's own), so 8080
    /// is 18080, then 28080 for a third worktree; then the next hundred.
    static func candidates(for port: Int) -> [Int] {
        var list: [Int] = []
        for step in 1...4 where port + step * 10_000 <= 49_151 { list.append(port + step * 10_000) }
        let top = min(port + 100, 65_535)
        if port < top { list += Array((port + 1)...top) }
        return list
    }

    /// The name it runs as: the one it runs as already (`running`), else
    /// its files' — unless another checkout's stack has that (a project of
    /// it from another folder, or another override's, `reserved`: name →
    /// folder). Then the worktree's folder's (`shop-wt-feat-x`), else
    /// `<name>-<folder>`, `-2`… while another folder has it. The holder is
    /// that other folder.
    static func projectName(
        fileName: String, folder: String, running: String?, projects: [ComposeProject], reserved: [String: String]
    ) -> (name: String, holder: String?) {
        if let running { return (running, nil) }
        func holding(_ name: String) -> String? {
            if let other = projects.first(where: { $0.name == name && $0.workingDir != folder }) { return other.workingDir ?? "a folder Compose didn't say" }
            return reserved[name]
        }
        guard let holder = holding(fileName) else { return (fileName, nil) }
        let last = slug((folder as NSString).lastPathComponent)
        let base = last.hasPrefix(fileName) ? last : fileName + "-" + last
        var name = base
        var number = 2
        while holding(name) != nil || name == fileName, number <= 100 {
            name = base + "-\(number)"
            number += 1
        }
        return (name, holder)
    }

    /// A project name as Compose makes one: lower-case letters, digits,
    /// `_` and `-`, anything else a `-`, no `-` twice, starting with a
    /// letter or a digit.
    static func slug(_ text: String) -> String {
        var result = ""
        for character in text.lowercased() {
            let plain = character.isASCII && (character.isLetter || character.isNumber || character == "_")
            if plain {
                result.append(character)
            } else if !result.hasSuffix("-") {
                result.append("-")
            }
        }
        while let first = result.first, first == "-" || first == "_" { result.removeFirst() }
        return result
    }
}

/// Who holds the ports a stack wants: the other stacks' containers, then
/// this Mac. Pure; the bind probe is given (`ListeningPorts.isBound`).
enum ComposePortCensus {
    /// A port is the stack's own when its own containers publish it (Docker's
    /// process binds it for them); another's container publishing it is
    /// that one's; else what `isBound` meets is a process's, found later
    /// (`.unknown` here).
    static func taken(
        wanted: [ComposePortKey], containers: [ContainerSummary], own: (ContainerSummary) -> Bool, isBound: (Int, String) -> Bool
    ) -> [ComposePortKey: DockerPortConflict.Holder] {
        var taken: [ComposePortKey: DockerPortConflict.Holder] = [:]
        for key in wanted where taken[key] == nil {
            let publishing = containers.filter { $0.state.isUp && publishes($0, key) }
            if let other = publishing.first(where: { !own($0) }) {
                taken[key] = .container(id: other.Id, name: other.name, project: other.composeProject, folder: other.composeWorkingDir)
            } else if publishing.isEmpty, isBound(key.port, key.proto) {
                taken[key] = .unknown
            }
        }
        return taken
    }

    /// Whether a port can be given to the stack: no other container
    /// publishes it, and its own do or nothing else binds it.
    static func isFree(
        _ port: Int, _ proto: String, containers: [ContainerSummary], own: (ContainerSummary) -> Bool, isBound: (Int, String) -> Bool
    ) -> Bool {
        let key = ComposePortKey(port: port, proto: proto)
        let publishing = containers.filter { $0.state.isUp && publishes($0, key) }
        if publishing.contains(where: { !own($0) }) { return false }
        return !publishing.isEmpty || !isBound(port, proto)
    }

    private static func publishes(_ container: ContainerSummary, _ key: ComposePortKey) -> Bool {
        PublishedPort.of(container.Ports ?? []).contains { $0.hostPort == key.port && $0.proto == key.proto }
    }
}

/// Each worktree's stack on its own ports: Compose's version, the profiles
/// that start, the override file and the question. Pure.
enum ComposePorts {
    /// `!override` came in Docker Compose 2.24.4: before it an override's
    /// `ports` could only add to the file's.
    static let minimumVersion = [2, 24, 4]

    /// `5.6.0`, `v2.24.4`, `2.29.1-desktop.1` can; `2.24.3`, `1.29.2` and
    /// what isn't a version can't.
    static func supportsOverride(version: String) -> Bool {
        var text = version.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("v") { text.removeFirst() }
        let leading = text.prefix { $0.isNumber || $0 == "." }
        let parts = leading.split(separator: ".").map { Int($0) ?? 0 }
        guard !parts.isEmpty else { return false }
        let three = Array((parts + [0, 0, 0]).prefix(3))
        return !three.lexicographicallyPrecedes(minimumVersion)
    }

    /// The profiles that start: `.env`'s `COMPOSE_PROFILES` and the ones
    /// given.
    static func activeProfiles(dotEnv: [String: String], extra: [String] = []) -> Set<String> {
        let listed = (dotEnv["COMPOSE_PROFILES"] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return Set(listed + extra)
    }

    /// The override file: the name, and each moved service's ports in full
    /// under `!override` — merged plainly, an override's ports are added to
    /// the file's and the taken port would stay. Strings JSON-quoted (YAML's
    /// double quotes), `$` doubled: Compose interpolates an override too.
    static func overrideYAML(plan: ComposePortPlan, config: ComposeConfig, folder: String) -> String {
        func quoted(_ text: String) -> String {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.withoutEscapingSlashes]
            let data = (try? encoder.encode(text.replacingOccurrences(of: "$", with: "$$"))) ?? Data("\"\"".utf8)
            return String(decoding: data, as: UTF8.self)
        }
        let place = folder.components(separatedBy: .newlines).joined(separator: " ")
        var lines = [
            "# Overterm: \(place)'s stack on ports of its own (Up on Free Ports).",
            "# Written again before each Up from Overterm; the project's “Back to the File's Ports” removes it.",
            "# Nothing of it is in the repository.",
            "name: " + quoted(plan.name),
        ]
        let moved = Set(plan.moves.map(\.service))
        if !moved.isEmpty { lines.append("services:") }
        for service in config.services.sorted(by: { $0.name < $1.name }) where moved.contains(service.name) {
            lines += ["  " + quoted(service.name) + ":", "    ports: !override"]
            for port in service.ports {
                let move = plan.moves.first { $0.service == service.name && $0.proto == port.proto && $0.from == port.hostPort }
                lines.append("      - target: \(port.target)")
                if let published = move.map({ String($0.to) }) ?? port.published { lines.append("        published: " + quoted(published)) }
                if let hostIP = port.hostIP { lines.append("        host_ip: " + quoted(hostIP)) }
                lines.append("        protocol: " + quoted(port.proto))
                if let mode = port.mode { lines.append("        mode: " + quoted(mode)) }
                if let name = port.name { lines.append("        name: " + quoted(name)) }
                if let app = port.appProtocol { lines.append("        app_protocol: " + quoted(app)) }
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// What an Up changed of the ports kept for a stack, a phrase each: a
    /// port taken since, moved (again), and one back on the file's port —
    /// its own taken, the file's free again. A port the files no longer
    /// ask for goes unsaid.
    static func changes(from kept: [ComposePortMove], to now: [ComposePortMove], config: ComposeConfig) -> [String] {
        func same(_ a: ComposePortMove, _ b: ComposePortMove) -> Bool {
            a.service == b.service && a.target == b.target && a.proto == b.proto && a.from == b.from
        }
        func port(_ number: Int, _ proto: String) -> String { "\(number)" + (proto == "tcp" ? "" : "/\(proto)") }
        var said: [String] = []
        for move in now {
            let before = kept.first { same($0, move) }
            guard before?.to != move.to else { continue }
            said.append("\(move.service) \(port(before?.to ?? move.from, move.proto)) was taken — it is on \(move.to) now")
        }
        for old in kept where !now.contains(where: { same($0, old) }) {
            let asked = config.services.contains { service in
                service.name == old.service && service.ports.contains { $0.hostPort == old.from && $0.target == old.target && $0.proto == old.proto }
            }
            if asked { said.append("\(old.service) is back on \(port(old.from, old.proto)): \(old.to) is taken") }
        }
        return said
    }

    /// What the sheet asks before an Up that would run into another
    /// checkout's stack: who holds what, and what Up on Free Ports does.
    static func question(_ plan: ComposePortPlan) -> (title: String, detail: String) {
        let title: String =
            switch (plan.blocking.count, plan.nameHolder) {
            case (0, _): "“\(plan.fileName)” is another checkout's stack"
            case (1, nil): "\(plan.blocking[0].service)'s port \(plan.blocking[0].port) is taken"
            case (let count, nil): "\(count) of the stack's ports are taken"
            default: "This stack would run into another checkout's"
            }
        func port(_ conflict: ComposePortConflict) -> String { "\(conflict.port)" + (conflict.proto == "tcp" ? "" : "/\(conflict.proto)") }
        var lines = plan.blocking.map { "\(port($0)) (\($0.service)): " + PortConflicts.holderText($0.holder) }
        if let holder = plan.nameHolder {
            lines.append("“\(plan.fileName)” runs in \((holder as NSString).abbreviatingWithTildeInPath): up as written would replace its containers with this checkout's.")
        }
        if !plan.fixedNames.isEmpty {
            let names = plan.fixedNames.joined(separator: ", ")
            lines.append(
                plan.fixedNames.count == 1
                    ? "\(names) keeps container_name, so it can't run beside the other stack's either way."
                    : "\(names) keep container_name, so they can't run beside the other stack's either way.")
        }
        lines.append("")
        var offer = "Up on Free Ports runs it"
        if plan.name != plan.fileName { offer += " as “\(plan.name)”" }
        if !plan.moves.isEmpty { offer += " on " + plan.moves.map(\.label).joined(separator: ", ") }
        lines.append(offer + " — an override in Overterm's folder, not in the repository, which every Up from Overterm uses until you take it back.")
        if !plan.ownVolumes.isEmpty {
            lines.append("Its volumes are its own under that name (\(plan.ownVolumes.joined(separator: ", "))): their data starts empty.")
        }
        for conflict in plan.unmovable { lines.append("No free port near \(port(conflict)) for \(conflict.service): it stays as written.") }
        return (title, lines.joined(separator: "\n"))
    }
}
