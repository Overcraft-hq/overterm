import Foundation

/// A pod's or a workload's container on the Docker page (3.12, stage 4):
/// Run Locally — the Run window filled in with its image, its env that
/// isn't secret, its ports and its command — and Scan — its image on the
/// Images section's Vulnerabilities tab. Pure: the object is what one GET
/// answered (never a Secret's, never a ConfigMap's — those are named,
/// not read).
enum KubeRunLocally {
    /// The kinds whose objects carry a pod spec: a pod, a workload's
    /// template, a CronJob's Job's.
    static func offers(_ kind: KubeResourceKind) -> Bool {
        guard let root = KubeTree.Root.of(kind) else { return false }
        return [.pod, .deployment, .statefulSet, .daemonSet, .replicaSet, .job, .cronJob].contains(root)
    }

    /// What its pods are, as a pod reads: a pod as it is; a workload's
    /// template's metadata and spec (no status — nothing ran yet).
    static func podLike(_ object: [String: Any], kind: KubeResourceKind) -> [String: Any]? {
        guard offers(kind), let root = KubeTree.Root.of(kind) else { return nil }
        if root == .pod { return object }
        let template = KubeTree.podTemplate(root, object)
        guard template["spec"] is [String: Any] else { return nil }
        return ["metadata": template["metadata"] ?? [:], "spec": template["spec"] ?? [:]]
    }

    /// The pod spec's container by `name` (its containers only — an init
    /// container runs before, not instead).
    static func container(_ pod: [String: Any], named name: String) -> [String: Any]? {
        KubeAgentText.list(KubeAgentText.map(pod["spec"])["containers"]).first { $0["name"] as? String == name }
    }

    // MARK: Scan

    /// The image to scan: the spec's name, and the digest the kubelet ran
    /// (`status.containerStatuses[].imageID`, `…@sha256:…`) when it says one.
    struct Image: Equatable, Sendable {
        var name: String
        var digest: String?
    }

    static func image(_ pod: [String: Any], container name: String) -> Image? {
        guard let spec = container(pod, named: name), let image = spec["image"] as? String, !image.isEmpty else { return nil }
        let statuses = KubeAgentText.list(KubeAgentText.map(pod["status"])["containerStatuses"])
        let ran = statuses.first { $0["name"] as? String == name }?["imageID"] as? String
        let digest = ran.flatMap { id -> String? in
            guard let at = id.lastIndex(of: "@") else { return nil }
            let digest = String(id[id.index(after: at)...])
            return DockerImageReference.isDigest(digest) ? digest : nil
        }
        return Image(name: image, digest: digest)
    }

    // MARK: Run Locally

    /// The Run window, filled in from `container`:
    /// - its image;
    /// - `env`: a value given is copied, unless its name or value looks
    ///   secret (`Secrets`) — then asked; a Secret's key is asked, hidden;
    ///   a ConfigMap's key is asked, named, never read; the pod's own name,
    ///   namespace, node and service account filled in, other fields left
    ///   out and said; `$(VAR)` expanded from the values copied before it,
    ///   as the kubelet does;
    /// - `envFrom`: Secrets and ConfigMaps named, their keys not read;
    /// - its ports, published on 127.0.0.1 only (a reproduction, not a
    ///   server for the network), UDP and SCTP said;
    /// - `command` as the entrypoint and its first words, `args` after,
    ///   `$(VAR)` expanded in them too — an asked one as `"$VAR"`, and a
    ///   secret flag's value (`--requirepass x`) asked, never copied;
    /// - what can't come along (volumes, probes' and resources' limits) said.
    static func plan(
        _ pod: [String: Any], container name: String, context: String, namespace: String, object: String
    ) -> DockerRunSpec? {
        guard let spec = container(pod, named: name), let image = spec["image"] as? String, !image.isEmpty else { return nil }
        var run = DockerRunSpec(image: image)
        run.removeWhenStopped = true
        run.notes.append("From \(object), container \(name), in \(context) · namespace \(namespace).")

        // Env, in order: a later entry of the same name wins, as in the pod.
        var copied: [(key: String, value: String)] = []
        var asked: [DockerRunSpec.Ask] = []
        var leftOut: [String] = []
        func drop(_ key: String) {
            copied.removeAll { $0.key == key }
            asked.removeAll { $0.key == key }
            leftOut.removeAll { $0.hasPrefix(key + " ") }
        }
        func ask(_ key: String, _ from: String, secret: Bool) {
            if DockerRunSpec.Ask.reserved(key) {
                leftOut.append("\(key) (\(from)): a name the shell running docker, or docker itself, reads — pass it with an --env-file")
                return
            }
            guard DockerRunSpec.Ask.askable(key) else {
                leftOut.append("\(key) (\(from)): a name a shell can't ask for")
                return
            }
            asked.append(DockerRunSpec.Ask(key: key, from: from, secret: secret))
        }
        let metadata = KubeAgentText.map(pod["metadata"])
        let podSpec = KubeAgentText.map(pod["spec"])
        for entry in KubeAgentText.list(spec["env"]) {
            guard let key = entry["name"] as? String, !key.isEmpty else { continue }
            drop(key)
            if let source = entry["valueFrom"] as? [String: Any] {
                if let ref = source["secretKeyRef"] as? [String: Any] {
                    ask(key, "Secret \(ref["name"] as? String ?? "?"), key \(ref["key"] as? String ?? "?")", secret: true)
                } else if let ref = source["configMapKeyRef"] as? [String: Any] {
                    ask(key, "ConfigMap \(ref["name"] as? String ?? "?"), key \(ref["key"] as? String ?? "?") — not read", secret: false)
                } else if let path = (source["fieldRef"] as? [String: Any])?["fieldPath"] as? String {
                    let value: String? =
                        switch path {
                        case "metadata.name": metadata["name"] as? String
                        case "metadata.namespace": namespace
                        case "spec.nodeName": podSpec["nodeName"] as? String
                        case "spec.serviceAccountName": podSpec["serviceAccountName"] as? String
                        default: nil
                        }
                    if let value, !value.isEmpty {
                        copied.append((key, value))
                    } else {
                        leftOut.append("\(key) (the pod's \(path))")
                    }
                } else if let resource = (source["resourceFieldRef"] as? [String: Any])?["resource"] as? String {
                    leftOut.append("\(key) (the container's \(resource))")
                } else {
                    leftOut.append("\(key) (set by the cluster)")
                }
                continue
            }
            let value = expand(entry["value"] as? String ?? "", with: copied)
            if Secrets.isSecret(key) && !value.isEmpty {
                ask(key, "its value looks secret — not copied", secret: true)
            } else if Secrets.maskURL(value) != value {
                ask(key, "a URL with a password — not copied", secret: true)
            } else if Secrets.scrubCredentials(value) != value {
                // A token under a harmless name: `ghp_…`, `AKIA…`, a JWT,
                // `-Dspring.datasource.password=…`, a base64 key.
                ask(key, "its value looks like a credential — not copied", secret: true)
            } else {
                copied.append((key, value))
            }
        }
        // envFrom's keys are the Secret's or ConfigMap's: not known unread.
        var named: [String] = []
        for source in KubeAgentText.list(spec["envFrom"]) {
            let prefix = (source["prefix"] as? String).flatMap { $0.isEmpty ? nil : " (prefix \($0))" } ?? ""
            if let secret = (source["secretRef"] as? [String: Any])?["name"] as? String {
                named.append("Secret \(secret)\(prefix)")
            } else if let map = (source["configMapRef"] as? [String: Any])?["name"] as? String {
                named.append("ConfigMap \(map)\(prefix)")
            }
        }
        run.env = copied.map { "\($0.key)=\($0.value)" }
        run.asked = asked
        if !named.isEmpty {
            run.notes.append(
                "Its env also takes every key of \(named.joined(separator: ", ")) — not read here: add the ones it needs under Environment, "
                    + "a KEY alone to pass it from the tab's shell.")
        }
        if !leftOut.isEmpty { run.notes.append("Left out, set by the cluster: \(leftOut.joined(separator: ", ")).") }

        // Ports: each container port on the same port of 127.0.0.1.
        var ports: [String] = []
        for port in KubeAgentText.list(spec["ports"]) {
            guard let number = KubeRollout.int(port["containerPort"]), (1...65535).contains(number) else { continue }
            let proto = (port["protocol"] as? String ?? "TCP").lowercased()
            let line = "127.0.0.1:\(number):\(number)" + (proto == "tcp" ? "" : "/\(proto)")
            if !ports.contains(line) { ports.append(line) }
        }
        run.ports = ports
        if !ports.isEmpty { run.notes.append("Its ports are published on 127.0.0.1 only, each on its own number: change one that is taken.") }

        // command is the entrypoint; args the image's command.
        let command = (spec["command"] as? [Any] ?? []).compactMap { $0 as? String }
        let args = (spec["args"] as? [Any] ?? []).compactMap { $0 as? String }
        if !command.isEmpty || !args.isEmpty {
            let reads = Set(asked.filter { DockerRunSpec.Ask.askable($0.key) && $0.env }.map(\.key))
            if let (words, secrets) = Self.words(command + args, copied: copied, asked: reads),
                command.isEmpty || words.first.flatMap(Self.plain) != nil
            {
                for (index, flag) in secrets.enumerated() {
                    asked.append(DockerRunSpec.Ask(key: Self.argumentKey(index + 1), from: "\(flag) in its command — not copied", secret: true, env: false))
                }
                if !command.isEmpty, let first = words.first, let program = Self.plain(first) {
                    run.entrypoint = program
                    run.command = words.dropFirst().map(Self.render).joined(separator: " ")
                } else {
                    run.command = words.map(Self.render).joined(separator: " ")
                }
                run.asked = asked
            } else {
                run.notes.append(
                    "Its command and args carry secret values that can't be asked for one by one: not copied — type them under Command, "
                        + "\"$NAME\" for a value from the tab's shell.")
            }
        }
        if spec["tty"] as? Bool == true, spec["stdin"] as? Bool == true { run.detached = false }

        let mounts = KubeAgentText.list(spec["volumeMounts"]).compactMap { $0["mountPath"] as? String }
        if !mounts.isEmpty {
            run.notes.append("Not mounted: \(mounts.joined(separator: ", ")) — its volumes are the cluster's; add one under Volumes.")
        }
        return run
    }

    /// `$(VAR)` as the kubelet expands it: from a value defined before,
    /// else left as written; `$$` is a `$`.
    static func expand(_ value: String, with defined: [(key: String, value: String)]) -> String {
        parts(value, with: defined, asked: []).map { part in
            switch part {
            case .text(let text): text
            case .ask(let key): "$(" + key + ")"
            }
        }.joined()
    }

    /// A command's word: text, and the values asked in the tab it names.
    enum Part: Equatable, Sendable {
        case text(String)
        /// `"$KEY"` in the shell that runs it.
        case ask(String)
    }

    /// `value` expanded as the kubelet does: a value copied put in, an
    /// asked one (`asked`) left for the tab's shell to put in.
    static func parts(_ value: String, with defined: [(key: String, value: String)], asked: Set<String>) -> [Part] {
        var parts: [Part] = []
        var text = ""
        func flush() {
            if !text.isEmpty { parts.append(.text(text)) }
            text = ""
        }
        var rest = Substring(value)
        while let dollar = rest.firstIndex(of: "$") {
            text += rest[..<dollar]
            let after = rest[rest.index(after: dollar)...]
            if after.hasPrefix("$") {
                text += "$"
                rest = after.dropFirst()
            } else if after.hasPrefix("("), let close = after.firstIndex(of: ")") {
                let name = String(after[after.index(after: after.startIndex)..<close])
                if let found = defined.last(where: { $0.key == name }) {
                    text += found.value
                } else if asked.contains(name) {
                    flush()
                    parts.append(.ask(name))
                } else {
                    text += "$(" + name + ")"
                }
                rest = after[after.index(after: close)...]
            } else {
                text += "$"
                rest = after
            }
        }
        text += rest
        flush()
        return parts
    }

    /// The asked value a command's secret word becomes: `OVERTERM_ARG_1`.
    static func argumentKey(_ number: Int) -> String { "OVERTERM_ARG_\(number)" }

    /// The container's command and args, expanded (`parts`), each word
    /// a secret flag gives (`Secrets.maskArguments`: `--requirepass x`,
    /// `--db-password=x`, `-px`) made an ask of its own — the flag's name
    /// back for each, in order. Nil when one word holds more than one
    /// secret, or an asked value is part of one: then nothing is copied.
    static func words(_ raw: [String], copied: [(key: String, value: String)], asked: Set<String>) -> ([[Part]], [String])? {
        var words = raw.map { parts($0, with: copied, asked: asked) }
        // An asked value as a reference, which masking keeps as written.
        let shown = words.map(Self.shown)
        let masked = Secrets.maskArguments(shown)
        var flags: [String] = []
        for index in words.indices where masked[index] != shown[index] {
            let word = Array(shown[index])
            let mask = Array(masked[index])
            var head = 0
            while head < word.count, head < mask.count, word[head] == mask[head] { head += 1 }
            var tail = 0
            while tail < word.count - head, tail < mask.count - head, word[word.count - 1 - tail] == mask[mask.count - 1 - tail] { tail += 1 }
            guard String(mask[head..<(mask.count - tail)]) == Secrets.mask("x"), head < word.count - tail else { return nil }
            guard let replaced = replace(words[index], from: head, to: word.count - tail, with: argumentKey(flags.count + 1)) else { return nil }
            words[index] = replaced
            let before = String(word[..<head]).trimmingCharacters(in: CharacterSet(charactersIn: "=\"'"))
            let flag = before.split(whereSeparator: \.isWhitespace).last.map(String.init) ?? ""
            flags.append(flag.isEmpty ? (index > 0 ? shown[index - 1] : "a word") : flag)
        }
        return (words, flags)
    }

    /// A word as masking reads it: an asked value as `${KEY}`.
    private static func shown(_ word: [Part]) -> String {
        word.map { part in
            switch part {
            case .text(let text): text
            case .ask(let key): "${" + key + "}"
            }
        }.joined()
    }

    /// `word` with the characters `from..<to` of its text (as `shown`
    /// spells it) asked as `key`; nil when they aren't one text's.
    private static func replace(_ word: [Part], from: Int, to: Int, with key: String) -> [Part]? {
        var offset = 0
        var out: [Part] = []
        var done = false
        for part in word {
            let length = shown([part]).count
            defer { offset += length }
            guard !done, case .text(let text) = part, from >= offset, to <= offset + length else {
                if !done, from < offset + length, to > offset { return nil }
                out.append(part)
                continue
            }
            let characters = Array(text)
            let head = String(characters[..<(from - offset)])
            let tail = String(characters[(to - offset)...])
            if !head.isEmpty { out.append(.text(head)) }
            out.append(.ask(key))
            if !tail.isEmpty { out.append(.text(tail)) }
            done = true
        }
        return done ? out : nil
    }

    /// The word as typed: its text alone, nothing asked.
    static func plain(_ word: [Part]) -> String? {
        var text = ""
        for part in word {
            guard case .text(let piece) = part else { return nil }
            text += piece
        }
        return text
    }

    /// The word as the shell takes it: text quoted, an asked value
    /// `"$KEY"` — the tab's shell puts it in, never the command line.
    static func render(_ word: [Part]) -> String {
        let rendered = word.map { part in
            switch part {
            case .text(let text): DockerCommands.quote(text)
            case .ask(let key): "\"$" + key + "\""
            }
        }.joined()
        return rendered.isEmpty ? "''" : rendered
    }
}
