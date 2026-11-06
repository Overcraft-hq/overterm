import Foundation

// MARK: Helm upgrade from the checkout (stage 3a — docs/design/kubernetes/analysis.md, 2.12, 3.1, 3.3, Section 5, decision 15)

/// A bound release upgraded from the checkout's own chart. First its diff:
/// the chart rendered here by `helm template` — from its files and the
/// release's own values on stdin, `KUBECONFIG=/dev/null`, no cluster asked
/// (`KubeHelmTemplate`) — against the manifest the release holds now, both
/// sides masked as `kubectl diff` masks (a Secret's values `***`, `***
/// (before)`, `*** (after)`; secret-looking env values; credentials in
/// text), in the changes pane. Then `helm upgrade` in a tab pinned to the
/// context, by the path every tab write takes: refused on a read-only
/// context, its access reviewed, confirmed naming the context and
/// namespace, the release's name typed on production. Pure.
enum KubeHelmUpgrade {
    /// The chart in the checkout that installs `release`: a `Chart.yaml`
    /// whose `name` is the release's, else the only one there — its folder.
    static func chart(in files: [KubeCheckoutFile], release: String, root: URL) -> URL? {
        let charts = files.filter { $0.kind == .chart }
        func folder(_ file: KubeCheckoutFile) -> URL {
            root.appendingPathComponent(file.path).deletingLastPathComponent().standardizedFileURL
        }
        if let named = charts.first(where: { (YAMLReader.parse($0.text) as? [String: Any])?["name"] as? String == release }) { return folder(named) }
        return charts.count == 1 ? folder(charts[0]) : nil
    }

    /// The chart's own name and version, from its `Chart.yaml`.
    static func chartInfo(_ text: String) -> KubeHelmChart {
        let chart = YAMLReader.parse(text) as? [String: Any] ?? [:]
        func string(_ key: String) -> String? {
            switch chart[key] {
            case let text as String: text.isEmpty ? nil : text
            case let number as NSNumber: number.stringValue
            default: nil
            }
        }
        return KubeHelmChart(chart: string("name"), version: string("version"), appVersion: string("appVersion"))
    }

    // MARK: The diff

    /// One object of the release's manifest or the chart's render.
    struct Document {
        var key: String
        var kind: String
        var name: String
        var namespace: String?
        var object: [String: Any]
        /// Its `apiVersion`'s group: `apps`, or empty for the core group.
        var group: String {
            guard let apiVersion = object["apiVersion"] as? String, let slash = apiVersion.firstIndex(of: "/") else { return "" }
            return String(apiVersion[..<slash])
        }
    }

    /// A manifest's `---` documents read as objects, each known by its
    /// kind, namespace (the release's when it says none) and name; a
    /// document that can't be read whole is counted, never shown — what it
    /// holds can't be masked.
    static func documents(_ manifest: String, namespace: String) -> (documents: [Document], withheld: Int) {
        var chunks: [[Substring]] = [[]]
        for line in manifest.split(separator: "\n", omittingEmptySubsequences: false) {
            if line == "---" || line.hasPrefix("--- ") { chunks.append([]) } else { chunks[chunks.count - 1].append(line) }
        }
        var out: [Document] = []
        var withheld = 0
        var seen: [String: Int] = [:]
        for lines in chunks {
            let content = lines.filter { !$0.hasPrefix("#") }.joined(separator: "\n")
            if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            guard let parsed = YAMLReader.documents(lines.joined(separator: "\n"))?.filter({ !($0 is NSNull) }), parsed.count == 1,
                let object = parsed.first as? [String: Any]
            else {
                withheld += 1
                continue
            }
            let kind = object["kind"] as? String ?? "?"
            let metadata = object["metadata"] as? [String: Any] ?? [:]
            let name = metadata["name"] as? String ?? "?"
            let place = metadata["namespace"] as? String ?? namespace
            var key = "\(kind)/\(place)/\(name)"
            // Two of the same (a template's mistake): kept apart.
            seen[key, default: 0] += 1
            if let count = seen[key], count > 1 { key += "#\(count)" }
            out.append(Document(key: key, kind: kind, name: name, namespace: metadata["namespace"] as? String, object: object))
        }
        return (out, withheld)
    }

    /// The release's manifest against the chart's render, object by object,
    /// masked: what is new, gone, changed or the same. Neither side is kept
    /// whole — only the masked diffs.
    static func diff(current: String, rendered: String, namespace: String, revision: Int) -> KubeHelmDiff {
        diff(current: current, rendered: rendered, namespace: namespace, from: "revision \(revision)", to: "checkout")
    }

    /// The same, its two sides named (`revision 2`, `revision 3`): two of a
    /// release's revisions against each other (the change timeline's).
    static func diff(current: String, rendered: String, namespace: String, from: String, to: String) -> KubeHelmDiff {
        let (before, beforeWithheld) = documents(current, namespace: namespace)
        let (after, afterWithheld) = documents(rendered, namespace: namespace)
        let old = Dictionary(before.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        var keys = after.map(\.key)
        keys += before.map(\.key).filter { key in !after.contains { $0.key == key } }
        var items: [KubeHelmDiffItem] = []
        var secrets = 0
        for key in keys {
            let a = old[key]
            let b = after.first { $0.key == key }
            guard let any = b ?? a else { continue }
            if [a, b].contains(where: { $0.map { KubeObjectStrip.isSecret($0.object) } == true }) { secrets += 1 }
            let (left, right) = sides(a?.object, b?.object)
            let file = "\(any.kind.lowercased())-\(any.name).yaml"
            let unified = KubeManifestDiff.unified(before: left, after: right, from: "\(from)/\(file)", to: "\(to)/\(file)")
            let change: KubeHelmDiffItem.Change = a == nil ? .added : b == nil ? .removed : unified.text.isEmpty ? .unchanged : .modified
            items.append(
                KubeHelmDiffItem(
                    id: key, kind: any.kind, name: any.name, namespace: any.namespace, file: file, change: change, diff: unified.text, added: unified.added,
                    removed: unified.removed, group: any.group))
        }
        return KubeHelmDiff(items: items, withheld: beforeWithheld + afterWithheld, secrets: secrets)
    }

    /// The two sides as the diff shows them: stripped, masked together —
    /// a changed Secret value says so without saying what it is — and
    /// credentials in text taken out; a list's items each masked alone.
    static func sides(_ before: [String: Any]?, _ after: [String: Any]?) -> (before: String, after: String) {
        func isList(_ object: [String: Any]?) -> Bool { (object?["kind"] as? String)?.hasSuffix("List") == true && object?["items"] is [Any] }
        var a: [String: Any]?
        var b: [String: Any]?
        if isList(before) || isList(after) {
            a = before.map { KubeObjectStrip.shown(KubeManifestDiff.stripped($0), full: false) }
            b = after.map { KubeObjectStrip.shown(KubeManifestDiff.stripped($0), full: false) }
            for side in [0, 1] {
                guard var object = side == 0 ? a : b, let items = object["items"] as? [Any] else { continue }
                object["items"] = items.map { ($0 as? [String: Any]).map { KubeObjectStrip.shown($0, full: false) } ?? $0 }
                if side == 0 { a = object } else { b = object }
            }
        } else {
            (a, b) = KubeManifestDiff.masked(before: before.map(KubeManifestDiff.stripped), after: after.map(KubeManifestDiff.stripped))
        }
        func text(_ object: [String: Any]?) -> String {
            guard let object else { return "" }
            return KubeYAML.text(KubeHelmMask.scrubbingStrings(object) as? [String: Any] ?? object)
        }
        return (text(a), text(b))
    }

    // MARK: The upgrade

    /// What an upgrade's access review asks, and what it couldn't.
    struct Review {
        var accesses: [(access: KubeAccess, namespace: String?)]
        /// Said in the confirmation when the review isn't the whole upgrade.
        var partial: String?
    }

    /// What the cluster's access review is asked first: the release's
    /// records (a new one made, the last marked superseded), then what the
    /// diff says helm will do to the objects, kind by kind as the server
    /// serves them — `create` for one added, `patch` for one changed,
    /// `delete` for one the chart no longer renders —, at most
    /// `KubeHelmWrite.reviewedKinds` of them. A chart that adds a kind (an
    /// HPA, a RoleBinding) or drops one would otherwise pass the review and
    /// fail halfway, leaving a FAILED revision. Without the server's kinds
    /// only the records are reviewed, and the confirmation says so.
    static func accesses(storage: KubeHelmStorage, namespace: String, diff: KubeHelmDiff, discovery: KubeDiscovery?) -> Review {
        let records = KubeHelmWrite.accesses(.helmRollback, storage: storage, namespace: namespace)
        let changed = diff.items.filter { $0.change != .unchanged }
        guard let discovery else {
            return Review(
                accesses: records,
                partial: changed.isEmpty ? nil : "Only its records' access was reviewed: the server's kinds couldn't be read, so its objects' wasn't.")
        }
        var seen = Set<String>()
        var resources: [(access: KubeAccess, namespace: String?)] = []
        var left = 0
        for item in changed {
            guard let served = discovery.kinds.first(where: { $0.group == item.group && $0.kind == item.kind }) else { continue }
            let verb =
                switch item.change {
                case .added: "create"
                case .removed: "delete"
                case .modified, .unchanged: "patch"
                }
            let access = KubeAccess(verb: verb, resource: served.fullName)
            guard seen.insert("\(access)").inserted else { continue }
            guard resources.count < KubeHelmWrite.reviewedKinds else {
                left += 1
                continue
            }
            resources.append((access, served.namespaced ? namespace : nil))
        }
        let partial = left == 0 ? nil : "\(left) more of its objects' kinds weren't reviewed: helm says if it may not."
        return Review(accesses: records + resources, partial: partial)
    }
}

/// What `helm template` is told of the cluster, read from it with GETs
/// already allowed: its version (`--kube-version`, its gitVersion as helm
/// itself takes it) and the group versions it serves (`--api-versions`,
/// each also with its kinds: `monitoring.coreos.com/v1/ServiceMonitor`),
/// over helm's built-in ones. Offline, helm renders with the version and
/// groups it was compiled with; a chart that switches on
/// `.Capabilities.KubeVersion` or `.Capabilities.APIVersions.Has` would
/// then diff adds and removes `helm upgrade` won't make. The render itself
/// still asks no cluster.
struct KubeHelmCapabilities: Equatable, Sendable {
    var kubeVersion: String?
    var apiVersions: [String] = []

    init(kubeVersion: String? = nil, apiVersions: [String] = []) {
        self.kubeVersion = kubeVersion
        self.apiVersions = apiVersions
    }

    init(version: KubeServerVersion?, discovery: KubeDiscovery?) {
        kubeVersion = version?.gitVersion
        var all = Set<String>()
        for kind in discovery?.kinds ?? [] {
            all.insert(kind.groupVersion)
            all.insert("\(kind.groupVersion)/\(kind.kind)")
        }
        apiVersions = all.sorted()
    }

    var arguments: [String] {
        var words: [String] = []
        if let kubeVersion, !kubeVersion.isEmpty { words += ["--kube-version", kubeVersion] }
        if !apiVersions.isEmpty { words += ["--api-versions", apiVersions.joined(separator: ",")] }
        return words
    }
}

/// One object's diff, as the changes pane shows it.
struct KubeHelmDiffItem: Identifiable, Equatable, Sendable {
    enum Change: String, Equatable, Sendable {
        case added, removed, modified, unchanged
    }

    var id: String
    var kind: String
    var name: String
    var namespace: String?
    /// `deployment-web.yaml`.
    var file: String
    var change: Change
    /// Unified, masked; empty when unchanged.
    var diff: String
    var added: Int
    var removed: Int
    /// Its `apiVersion`'s group (the newer side's): which kind the server serves it as.
    var group: String = ""

    /// `Deployment web`.
    var spoken: String { "\(kind) \(name)" }
}

/// The release's manifest against the checkout's chart, object by object. Masked.
struct KubeHelmDiff: Equatable, Sendable {
    var items: [KubeHelmDiffItem]
    /// Documents left out of the diff: unreadable, so unmaskable.
    var withheld: Int
    /// Secrets among the objects: their values masked on both sides.
    var secrets: Int

    var changes: Int { items.count { $0.change != .unchanged } }
    var added: Int { items.reduce(0) { $0 + $1.added } }
    var removed: Int { items.reduce(0) { $0 + $1.removed } }

    /// `2 of 3 objects would change (+12 −3)`, or that nothing would.
    var said: String {
        if changes == 0 { return "Nothing in its objects would change: the chart renders what the release has." }
        return "\(changes) of \(items.count) object\(items.count == 1 ? "" : "s") would change (+\(added) −\(removed))."
    }
}

/// `helm upgrade` of a bound release from the checkout's chart, in a tab
/// pinned to the context: `--reset-then-reuse-values` — the chart's own
/// defaults with the release's values over them, as the diff rendered it
/// (`--reuse-values` would keep the old chart's defaults instead) —,
/// `--kube-context` and `-n` always, every word not ours quoted for zsh;
/// the driver always said and the shell's helm kube settings unset
/// (`KubeHelmWrite.prefix`). A Helm 2
/// release, or a name helm wouldn't give one, is refused.
struct KubeHelmUpgradeWrite: Equatable, Sendable, KubeTabCommand {
    var release: String
    var namespace: String
    var storage: KubeHelmStorage
    /// The chart's folder in the checkout.
    var chart: String
    /// `web-1.5.0`, as its Chart.yaml says it.
    var chartSaid: String?
    /// The revision it is at now.
    var from: Int
    /// What the diff said would change.
    var summary: String?
    /// What its access review couldn't cover (`KubeHelmUpgrade.Review.partial`).
    var reviewNote: String?

    var verb: KubeProcessVerb { .helmUpgrade }
    var name: String { release }

    var refused: String? {
        if let refused = KubeHelmWrite.refusal(name: release, storage: storage) { return refused }
        return chart.hasPrefix("/") ? nil : "The chart's folder isn't a path helm can be given: Overterm types nothing for it."
    }

    /// `env -u HELM_KUBEAPISERVER … HELM_DRIVER=secret helm upgrade 'web' '/repo/chart' --reset-then-reuse-values --kube-context C -n NS`
    /// (`KubeHelmWrite.prefix`).
    func line(context: String) -> String {
        let q = KubeCommands.quoted
        var words = KubeHelmWrite.prefix(storage)
        words += ["helm", "upgrade", q(release), q(chart), "--reset-then-reuse-values", "--kube-context", q(context), "-n", q(namespace)]
        return words.joined(separator: " ")
    }

    var spoken: String { "Helm release \(namespace)/\(release)" }

    func confirmation(context: KubeContext, rule: KubeProcessRule) -> KubeWriteConfirmation {
        let command = line(context: context.name)
        let place = (context.isProduction ? KubeWriteConfirmation.productionMark : "") + context.name + " · namespace \(namespace)"
        var lines = [
            "helm makes revision \(from + 1) from the checkout's chart"
                + (chartSaid.map { " (\($0))" } ?? "") + " with revision \(from)'s values over its defaults, and rolls the resources out to it; "
                + "helm history keeps both, so it can be rolled back."
        ]
        if let summary { lines.append(summary) }
        if let reviewNote { lines.append(reviewNote) }
        if storage == .configMap { lines.append("Its records are ConfigMaps, so helm is told so (HELM_DRIVER=configmap).") }
        lines.append("Runs in a new tab pinned to \(context.displayName): \(command)")
        let typed = rule.typedName ? release : nil
        if let typed { lines.append("Type \(typed) to confirm.") }
        return KubeWriteConfirmation(
            verb: nil, title: "Upgrade \(spoken) from the checkout's chart?", scope: place, detail: lines.joined(separator: "\n"),
            button: "Upgrade in a Tab", typedName: typed, production: context.isProduction, kubectl: command)
    }

    func opened(context: String) -> String { "Upgrading \(spoken) from the checkout's chart in a new tab, in \(context)." }
}

// MARK: Rendering the chart

/// Which helm `helm template` runs: `kubernetes.helmPath` (which, set,
/// overrides), where installers put it, then the login shell's PATH. An
/// isolated run or a unit test uses only the configured path. Never downloaded.
enum KubeHelmLocator {
    static func candidates(
        configured: String, guarded: Bool, loginPath: String?, home: URL, isExecutable: (String) -> Bool = FileManager.default.isExecutableFile
    ) -> [URL] {
        let own = KubeconfigSources.expand(configured.trimmingCharacters(in: .whitespaces), home: home)
        if guarded { return own.map { isExecutable($0.path) ? [$0] : [] } ?? [] }
        let folders = ["/usr/local/bin", "/opt/homebrew/bin"] + (loginPath ?? "").split(separator: ":").map(String.init)
        var found: [URL] = own.map { [$0] } ?? []
        found += folders.filter { !$0.isEmpty }.map { URL(fileURLWithPath: $0).appendingPathComponent("helm") }
        var seen = Set<String>()
        return found.filter { isExecutable($0.path) && seen.insert($0.resolvingSymlinksInPath().path).inserted }
    }
}

/// `helm template` of the checkout's chart, run by Overterm itself: it
/// changes nothing and reaches no cluster (Section 5: started on every
/// class) — rendered from the chart's files with the release's values on
/// stdin (`--values -`: never a file), `--is-upgrade`, given
/// `KUBECONFIG=/dev/null` and none of helm's kube settings, so not even a
/// `lookup` can ask a cluster. Guarded (an isolated run, a unit test),
/// helm's own folders are the run's.
enum KubeHelmTemplate {
    static let timeout: TimeInterval = 60
    static let outputLimit = 8 << 20

    struct Problem: Error, Equatable, CustomStringConvertible {
        var description: String
        init(_ description: String) { self.description = description }
    }

    /// `template NAME CHART --namespace NS --values - --is-upgrade [--kube-version V] [--api-versions …]`.
    static func arguments(release: String, chart: String, namespace: String, capabilities: KubeHelmCapabilities = KubeHelmCapabilities()) -> [String] {
        ["template", release, chart, "--namespace", namespace, "--values", "-", "--is-upgrade"] + capabilities.arguments
    }

    /// What helm is given: `base` without any kube setting — `KUBECONFIG`
    /// is /dev/null —; guarded, its config, cache and data folders `scratch`'s.
    static func environment(base: [String: String], guarded: Bool, scratch: String) -> [String: String] {
        var environment = base.filter { !$0.key.hasPrefix("HELM_KUBE") && !$0.key.hasPrefix("AWS_") && $0.key != "HELM_DRIVER" }
        environment["KUBECONFIG"] = "/dev/null"
        if guarded {
            environment["HELM_CONFIG_HOME"] = (scratch as NSString).appendingPathComponent("config")
            environment["HELM_CACHE_HOME"] = (scratch as NSString).appendingPathComponent("cache")
            environment["HELM_DATA_HOME"] = (scratch as NSString).appendingPathComponent("data")
        }
        return environment
    }

    /// The chart rendered; `values` (the release's, JSON) on stdin. Guarded,
    /// helm's folders are a run's own, removed after it.
    static func render(
        chart: URL, release: String, namespace: String, values: Data, context: KubeContext, configured: String,
        capabilities: KubeHelmCapabilities = KubeHelmCapabilities()
    ) async throws -> String {
        if let refused = KubeProcessCheck.rule(.helmTemplate, for: context).refused { throw Problem(refused) }
        let guarded = AppEnvironment.guardsKubeconfig
        let home = FileManager.default.homeDirectoryForCurrentUser
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("overterm-helm-\(getpid())-\(UUID().uuidString)", isDirectory: true)
            .path
        defer { if guarded { try? FileManager.default.removeItem(atPath: scratch) } }
        let found = await KubeBlocking.run { () -> (URL?, [String: String]) in
            let base = guarded ? ProcessInfo.processInfo.environment : ShellEnvironment.environment()
            let helm = KubeHelmLocator.candidates(configured: configured, guarded: guarded, loginPath: base["PATH"], home: home).first
            return (helm, environment(base: base, guarded: guarded, scratch: scratch))
        }
        guard let helm = found.0 else {
            throw Problem(guarded ? "No helm: kubernetes.helmPath names none." : "helm isn't installed (or set kubernetes.helmPath in Settings ▸ Kubernetes).")
        }
        let environment = found.1
        let arguments = arguments(release: release, chart: chart.path, namespace: namespace, capabilities: capabilities)
        let result = await KubeBlocking.run {
            KubeProcessRun.run(helm, arguments, environment: environment, timeout: timeout, outputLimit: outputLimit, input: values)
        }
        guard let result else { throw Problem("helm template didn't finish in \(Int(timeout)) seconds.") }
        guard result.status == 0 else {
            // helm's own words, scrubbed: a template's error may quote a value.
            let said = KubeProxyProblem.lastLine(of: result.stderr).map(KubeHelmMask.scrubbed) ?? "it exited with \(result.status)"
            throw Problem("helm template \(chart.lastPathComponent) failed: \(said)")
        }
        guard !result.truncated else { throw Problem("The chart renders to more than \(outputLimit >> 20) MB: too much to diff here.") }
        return result.stdout
    }
}

extension KubeHelm {
    /// What a release's newest record gives an upgrade's diff: its values
    /// (the user's `config`, as JSON for `helm template`'s stdin) and its
    /// manifest — raw, so the diff can say a Secret's value changed; held
    /// only while the diff is made, never kept, logged or written.
    struct UpgradeInputs: Sendable, CustomStringConvertible {
        var values: Data
        var manifest: String
        var revision: Int
        var chart: KubeHelmChart

        /// Never a value: printed, it says only which revision it is.
        var description: String { "Helm revision \(revision) (\(chart.said ?? "?"))" }
    }

    static func upgradeInputs(_ body: Data, storage: KubeHelmStorage) throws -> UpgradeInputs {
        let payload = try payload(body, storage: storage)
        guard let release = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else { throw KubeHelmProblem.unreadable }
        let config = release["config"] as? [String: Any] ?? [:]
        let metadata = (release["chart"] as? [String: Any])?["metadata"] as? [String: Any] ?? [:]
        let values = (try? JSONSerialization.data(withJSONObject: config, options: [.sortedKeys])) ?? Data("{}".utf8)
        return UpgradeInputs(
            values: values, manifest: release["manifest"] as? String ?? "", revision: (release["version"] as? NSNumber)?.intValue ?? 0,
            chart: KubeHelmChart(chart: metadata["name"] as? String, version: metadata["version"] as? String, appVersion: metadata["appVersion"] as? String))
    }
}
