import CryptoKit
import Darwin
import Foundation

/// A terminal tab pinned to a context — **Terminal in this context**
/// (docs/design/kubernetes/analysis.md, 3.11). Its shell starts with
/// `KUBECONFIG=<a small file of Overterm's>:<Overterm's kubeconfig files>`,
/// so a plain `kubectl` (or `helm`, `k9s`) there goes to the pinned
/// context, in its namespace, while the user's current context — every
/// other tab's — is never changed. It is the user's own kubectl with the
/// user's rights: a read-only context is not read-only in it; the pin and
/// the production band are the guard there.
///
/// What a pane carries: the names it was pinned to, and the files its
/// `KUBECONFIG` was built from (paths only, for a restored session). Never
/// a credential: a kubeconfig's cluster and user are named, not copied.
struct KubeTerminalPin: Codable, Equatable, Sendable {
    var context: String
    /// The context's cluster and user, by name — the pin's context entry
    /// points at the user's own entries, which hold the server and the
    /// credentials.
    var cluster: String
    var user: String
    /// The tab's namespace; nil, kubectl's `default`.
    var namespace: String?
    var displayName: String
    var isProduction: Bool
    /// The kubeconfig files after the pin's, in kubectl's order.
    var kubeconfigs: [String]

    init(
        context: String, cluster: String, user: String, namespace: String?, displayName: String, isProduction: Bool, kubeconfigs: [String] = []
    ) {
        self.context = context
        self.cluster = cluster
        self.user = user
        self.namespace = namespace.flatMap { $0.isEmpty ? nil : $0 }
        self.displayName = displayName
        self.isProduction = isProduction
        self.kubeconfigs = kubeconfigs
    }

    /// Pinned to `context`, in `namespace` — else the one the page opens
    /// it on (`defaultNamespace`), else the context's own.
    init(_ context: KubeContext, namespace: String? = nil, kubeconfigs: [URL] = []) {
        self.init(
            context: context.name, cluster: context.cluster, user: context.user,
            namespace: namespace ?? context.settings.defaultNamespace ?? context.namespace, displayName: context.displayName,
            isProduction: context.isProduction, kubeconfigs: kubeconfigs.map(\.path))
    }

    /// The tab strip's and the pane header's words: `⎈ fake-dev · shop`.
    var label: String { "⎈ " + displayName + (namespace.map { " · " + $0 } ?? "") }

    /// The tooltip: what a plain kubectl in the tab reaches.
    var help: String {
        let scope = namespace.map { "namespace \($0)" } ?? "the default namespace"
        return "Pinned to \(context)\(isProduction ? " — PRODUCTION" : ""), \(scope): a plain kubectl here goes there. Your current context is unchanged."
    }
}

/// The pin's file, pure: a kubeconfig that sets `current-context`, and the
/// context's own entry naming the user's cluster and user with the tab's
/// namespace. kubectl merges `KUBECONFIG`'s files first file first — the
/// first `current-context` wins, and a context entry is taken whole from
/// the first file that names it — so a plain kubectl in the tab uses the
/// pin's context, its namespace, and the cluster's server and the user's
/// credentials from the user's own files (checked with the real kubectl,
/// helm and k9s: `KubeTerminalMergeTests`, analysis 3.11).
///
/// The entry is there for the namespace, and so that a `kubectl config
/// set-context --current --namespace=…` typed in the tab writes the pin's
/// file rather than the user's: kubectl writes a change to the file that
/// holds the entry. A `use-context` typed there writes the pin's too.
enum KubeTerminalConfig {
    static func text(for pin: KubeTerminalPin) -> String {
        var lines = [
            "# Overterm: a terminal tab pinned to this context. No credentials here:",
            "# the cluster and the user are your own kubeconfig's.",
            "apiVersion: v1",
            "kind: Config",
            "current-context: \(quoted(pin.context))",
        ]
        // Always the entry, even for a context naming no cluster or no user
        // (copied as they are, empty — what the user's own entry says):
        // without it the namespace is lost, and a set-context typed in the
        // tab writes the user's file.
        lines += [
            "contexts:",
            "- name: \(quoted(pin.context))",
            "  context:",
            "    cluster: \(quoted(pin.cluster))",
            "    user: \(quoted(pin.user))",
        ]
        if let namespace = pin.namespace { lines.append("    namespace: \(quoted(namespace))") }
        return lines.joined(separator: "\n") + "\n"
    }

    /// A YAML double-quoted scalar: JSON's escapes, which YAML reads the
    /// same — an EKS ARN's `:` and `/`, a quote, a newline stay one name.
    static func quoted(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            case "\r": out += "\\r"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7f {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    /// The file's name: the context's SHA-256 (its first 12 hex digits) —
    /// never the name, an ARN —, the tab's own id, so a `use-context`
    /// typed in one tab changes no other, and the pid of the Overterm that
    /// wrote it, so another Overterm on the same folder (a dev build beside
    /// the installed one) never sweeps a file a live tab of this one uses.
    static func fileName(for context: String, id: UUID, pid: pid_t = getpid()) -> String {
        let hash = SHA256.hash(data: Data(context.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
        return "\(hash)-\(id.uuidString.prefix(8).lowercased())-\(pid).yaml"
    }

    /// The pid a file's name says wrote it; nil for a name that isn't one of these.
    static func owner(ofFile name: String) -> pid_t? {
        guard name.hasSuffix(".yaml") else { return nil }
        let parts = name.dropLast(5).split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 12, parts[1].count == 8, let pid = pid_t(parts[2]), pid > 0 else { return nil }
        return pid
    }
}

/// What the pinned shell is given, pure: `KUBECONFIG`, the pin's file
/// first, then exactly Overterm's kubeconfig files (`AppEnvironment.kubeconfigs`,
/// the proxies' list — `KubeProxyEnvironment`), nothing else of Overterm's.
/// Guarded — an isolated run or a unit test — the files are only
/// `OVERTERM_KUBECONFIG`'s, never one under `~/.kube`; none is no
/// environment, and no tab opens.
enum KubeTerminalEnvironment {
    static func make(pinFile: URL, kubeconfigs: [URL], guarded: Bool, home: URL) -> [String: String]? {
        guard !kubeconfigs.isEmpty else { return nil }
        if guarded, kubeconfigs.contains(where: { KubeconfigSources.isUsersOwn($0, home: home) }) { return nil }
        var seen: Set<String> = [pinFile.standardizedFileURL.path]
        let rest = kubeconfigs.filter { seen.insert($0.standardizedFileURL.path).inserted }.map(\.path)
        return ["KUBECONFIG": ([pinFile.path] + rest).joined(separator: ":")]
    }

    /// The first file of a `KUBECONFIG`, as kubectl reads it.
    static func firstFile(of value: String?) -> String? {
        value?.split(separator: ":").first.map(String.init)
    }
}

/// Where the tab starts: the context's `terminalDirectory` when it is a
/// folder, else the checkout bound to the context (`KubeBinding`), else
/// the home folder. Pure.
enum KubeTerminalDirectory {
    static func choose(
        setting: String?, checkout: URL?, home: URL,
        isFolder: (String) -> Bool = { path in
            var folder: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &folder) && folder.boolValue
        }
    ) -> URL {
        if let setting, let url = KubeconfigSources.expand(setting.trimmingCharacters(in: .whitespaces), home: home), isFolder(url.path) {
            return url
        }
        if let checkout, isFolder(checkout.path) { return checkout }
        return home
    }
}

/// The pins' files, in Overterm's own support folder
/// (`AppEnvironment.supportDirectory`/Kubernetes/Contexts, 0700; each file
/// 0600). A file is its tab's for the tab's life — a pane moved to another
/// tab takes it along, and a missing first file would send kubectl to the
/// current context — so none is removed while its Overterm runs: before
/// this run writes its first, only the files of an Overterm that is gone
/// (the pid in the name) go; another one's, alive on the same folder, stay
/// (a restored tab gets a new file).
struct KubeTerminalFiles: Sendable {
    let folder: URL

    init(folder: URL = KubeTerminalFiles.defaultFolder) {
        self.folder = folder
    }

    /// The support folder's — but in a unit test's process, a folder of its
    /// own in the temporary directory: `supportDirectory` is the user's real
    /// one there (only isolated runs move it), where the running app's pins
    /// live.
    static var defaultFolder: URL {
        let base =
            AppEnvironment.isUnitTest && !AppEnvironment.isIsolated
            ? FileManager.default.temporaryDirectory.appendingPathComponent("overterm-unit-test-\(getpid())", isDirectory: true)
            : AppEnvironment.supportDirectory
        return base.appendingPathComponent("Kubernetes/Contexts", isDirectory: true)
    }

    nonisolated(unsafe) private static var swept: Set<String> = []
    private static let lock = NSLock()

    /// Writes `pin`'s file for the tab `id` and gives its URL.
    func write(_ pin: KubeTerminalPin, id: UUID = UUID()) throws -> URL {
        try prepare()
        let file = folder.appendingPathComponent(KubeTerminalConfig.fileName(for: pin.context, id: id))
        let data = Data(KubeTerminalConfig.text(for: pin).utf8)
        // Made 0600 before a byte is in it; never through a link.
        let fd = open(file.path, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Self.error("Overterm couldn't write \(file.path): \(String(cString: strerror(errno))).") }
        defer { close(fd) }
        guard fchmod(fd, 0o600) == 0 else { throw Self.error("\(file.path) couldn't be made private.") }
        let written = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        guard written == data.count else { throw Self.error("Overterm couldn't write \(file.path).") }
        return file
    }

    /// The folder, 0700 — and, once a run, the files of Overterms that are
    /// gone removed. A file whose name says no pid is left alone.
    func prepare(isAlive: (pid_t) -> Bool = KubeTerminalFiles.isAlive) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard chmod(folder.path, 0o700) == 0 else { throw Self.error("\(folder.path) couldn't be made private.") }
        Self.lock.lock()
        let first = Self.swept.insert(folder.standardizedFileURL.path).inserted
        Self.lock.unlock()
        guard first else { return }
        for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] {
            guard let pid = KubeTerminalConfig.owner(ofFile: name), pid != getpid(), !isAlive(pid) else { continue }
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
    }

    /// Whether a process `pid` runs: one of another user's answers EPERM.
    static func isAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    private static func error(_ text: String) -> NSError {
        NSError(domain: "Overterm.KubeTerminal", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
    }
}

/// A pinned tab made ready: its file written, its shell's environment.
enum KubeTerminalLaunch {
    enum Problem: LocalizedError, Equatable, CustomStringConvertible {
        /// No kubeconfig to read — guarded, none but `OVERTERM_KUBECONFIG`'s.
        case noKubeconfig
        /// Guarded, and a file under `~/.kube` came: refused, nothing written.
        case usersOwn
        case file(String)

        var description: String {
            switch self {
            case .noKubeconfig: "There is no kubeconfig to pin a terminal to."
            case .usersOwn: "An isolated run never hands the user's own kubeconfig to a terminal."
            case .file(let text): text
            }
        }

        var errorDescription: String? { description }
    }

    /// What `prepare` refuses before it writes anything: no kubeconfig,
    /// or — guarded — one under `~/.kube`.
    static func check(
        kubeconfigs: [URL], guarded: Bool = AppEnvironment.guardsKubeconfig, home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws {
        guard !kubeconfigs.isEmpty else { throw Problem.noKubeconfig }
        if guarded, kubeconfigs.contains(where: { KubeconfigSources.isUsersOwn($0, home: home) }) { throw Problem.usersOwn }
    }

    /// `pin` with the files its `KUBECONFIG` names after its own, its file
    /// written, and what the shell is given. Checked before anything is
    /// written: guarded, only files outside `~/.kube`.
    static func prepare(
        _ pin: KubeTerminalPin, kubeconfigs: [URL], files: KubeTerminalFiles = KubeTerminalFiles(),
        guarded: Bool = AppEnvironment.guardsKubeconfig, home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws -> (environment: [String: String], pin: KubeTerminalPin) {
        try check(kubeconfigs: kubeconfigs, guarded: guarded, home: home)
        var pin = pin
        pin.kubeconfigs = kubeconfigs.map(\.path)
        let file: URL
        do {
            file = try files.write(pin)
        } catch {
            throw Problem.file(error.localizedDescription)
        }
        guard let environment = KubeTerminalEnvironment.make(pinFile: file, kubeconfigs: kubeconfigs, guarded: guarded, home: home) else {
            throw Problem.noKubeconfig
        }
        return (environment, pin)
    }

    /// The line typed into a pinned tab for Overterm's own command (a
    /// write, a shell, a log followed, helm, argocd, a snippet): the pin's
    /// `KUBECONFIG` exported on the line first. The tab is started with it,
    /// but the user's startup files run after and may export another —
    /// and `--context C` means whatever C is in the files `KUBECONFIG`
    /// names: a context of the same name elsewhere is another cluster,
    /// with the user's credentials, than the one reviewed and confirmed.
    /// Only the line itself can be sure. Nil without one to export.
    static func pinnedLine(_ command: String, environment: [String: String]) -> String? {
        guard let kubeconfig = environment["KUBECONFIG"], !kubeconfig.isEmpty else { return nil }
        return "export KUBECONFIG=" + KubectlLine.quoted(kubeconfig) + "; " + command
    }
}

/// A pane that was pinned and couldn't be pinned again at launch — its
/// context gone from Overterm's kubeconfigs, no kubeconfig, a file that
/// couldn't be written. It never comes back a plain shell to the current
/// context: its `KUBECONFIG` is `/dev/null`, which reaches no cluster (and
/// takes a `use-context` nowhere), and its header and tab say the pin is
/// lost. Saved again as it was, so the next launch tries again.
struct KubeTerminalLost: Equatable, Sendable {
    var pin: KubeTerminalPin
    var reason: String

    /// What its shell is given: nothing a kubectl can reach.
    static let environment = ["KUBECONFIG": "/dev/null"]

    var label: String { "⎈ " + pin.displayName + " — pin lost" }

    var help: String {
        "This pane was pinned to \(pin.context) and couldn't be pinned again: \(reason) "
            + "Its KUBECONFIG is /dev/null, so a plain kubectl here reaches no cluster. Open a new Terminal in this context."
    }
}

/// A saved pin at launch, pure but for the file it writes: the context
/// looked up again by name in Overterm's kubeconfigs as they are now —
/// their files, the context's cluster, user and class (production now, the
/// band now) — never as the session file had them. A context no longer
/// there, or a pin that can't be written, is a lost pane.
enum KubeTerminalRestore {
    enum Outcome: Equatable {
        case pinned(environment: [String: String], pin: KubeTerminalPin)
        case lost(KubeTerminalLost)

        var environment: [String: String] {
            switch self {
            case .pinned(let environment, _): environment
            case .lost: KubeTerminalLost.environment
            }
        }
        var pin: KubeTerminalPin? {
            if case .pinned(_, let pin) = self { return pin }
            return nil
        }
        var lost: KubeTerminalLost? {
            if case .lost(let lost) = self { return lost }
            return nil
        }
    }

    /// `list` is `kubeconfigs` read now (`KubeContextList.load`).
    static func pane(
        _ saved: KubeTerminalPin, list: KubeContextList, kubeconfigs: [URL], files: KubeTerminalFiles = KubeTerminalFiles(),
        guarded: Bool = AppEnvironment.guardsKubeconfig, home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Outcome {
        guard !kubeconfigs.isEmpty else { return .lost(KubeTerminalLost(pin: saved, reason: "There is no kubeconfig to pin it to.")) }
        guard let context = list.context(named: saved.context) else {
            return .lost(KubeTerminalLost(pin: saved, reason: "No kubeconfig of Overterm's names \(saved.context) any more."))
        }
        do {
            let ready = try KubeTerminalLaunch.prepare(
                KubeTerminalPin(context, namespace: saved.namespace), kubeconfigs: kubeconfigs, files: files, guarded: guarded, home: home)
            return .pinned(environment: ready.environment, pin: ready.pin)
        } catch {
            return .lost(KubeTerminalLost(pin: saved, reason: "\(error)"))
        }
    }
}

/// What a pinned pane's plain kubectl reaches *now*. A `kubectl config
/// use-context` or `set-context --current --namespace=…` typed in the tab
/// rewrites the pin's file (3.11), so the label and the band follow the
/// file: its `KUBECONFIG` read as kubectl merges it (`KubeContextList.load`
/// — the first `current-context`, the first entry naming it), the class
/// from the current settings. Pure over the list.
enum KubeTerminalFollow {
    /// The files a pane's `KUBECONFIG` names, in order.
    static func files(of value: String?) -> [URL] {
        (value ?? "").split(separator: ":").map { URL(fileURLWithPath: String($0)) }
    }

    static func pin(from list: KubeContextList, was: KubeTerminalPin, settings: [String: KubeContextSettings]) -> KubeTerminalPin {
        guard let current = list.current else {
            // Unset in the tab: kubectl has no context — none is reached.
            return KubeTerminalPin(
                context: "", cluster: "", user: "", namespace: nil, displayName: "no context", isProduction: false, kubeconfigs: was.kubeconfigs)
        }
        if let context = list.context(named: current) {
            return KubeTerminalPin(
                context: context.name, cluster: context.cluster, user: context.user, namespace: context.namespace, displayName: context.displayName,
                isProduction: context.isProduction, kubeconfigs: was.kubeconfigs)
        }
        // A name no file has: kubectl refuses it. Classed by its name all the same.
        let own = settings[current] ?? KubeContextSettings()
        return KubeTerminalPin(
            context: current, cluster: "", user: "", namespace: nil, displayName: own.displayName ?? current,
            isProduction: KubeClassifier.classify(context: current, cluster: "", set: own.contextClass) == .production,
            kubeconfigs: was.kubeconfigs)
    }
}

/// What a tab's strip says about its panes' contexts, pure. A pane moved
/// from another tab keeps its own pin, so a tab's panes may differ: then
/// it says `mixed` (red if any of them is production) rather than one
/// pane's context — an unpinned pane among pinned ones reaches the
/// current context.
struct KubeTabBadge: Equatable {
    var text: String
    var help: String
    /// In the page's red: production, a lost pin, or a mix holding either.
    var alert: Bool

    struct Pane: Equatable {
        var pin: KubeTerminalPin?
        var lost: KubeTerminalLost?
    }

    static func of(_ panes: [Pane]) -> KubeTabBadge? {
        guard panes.contains(where: { $0.pin != nil || $0.lost != nil }) else { return nil }
        if let lost = panes.lazy.compactMap(\.lost).first {
            return KubeTabBadge(text: "⎈ pin lost", help: lost.help, alert: true)
        }
        let pins = panes.map(\.pin)
        if let first = pins.first ?? nil, pins.allSatisfy({ $0?.context == first.context && $0?.namespace == first.namespace }) {
            return KubeTabBadge(text: "⎈ " + first.displayName, help: first.help, alert: first.isProduction)
        }
        let names = pins.map { $0.map { $0.label + ($0.isProduction ? " (PRODUCTION)" : "") } ?? "unpinned (your current context)" }
        return KubeTabBadge(
            text: "⎈ mixed", help: "Its panes reach different contexts: " + names.joined(separator: ", ") + ".",
            alert: pins.contains { $0?.isProduction != false })
    }
}

/// New Task's pin (3.11): the new task's tab opened as Terminal in this
/// context opens one, so the agent's own kubectl goes to a dev context by
/// default rather than to the user's current one — production, often.
/// Production is never offered here: an agent's tab pinned there is a
/// Terminal in this context of its own, asked first. Pure.
enum KubeTaskPin {
    struct Choice: Identifiable, Equatable, Sendable {
        var context: String
        var title: String
        /// The binding's namespace on its context; nil, the context's own.
        var namespace: String?
        var id: String { context }
    }

    struct Offer: Equatable, Sendable {
        var choices: [Choice] = []
        /// Picked as the sheet opens: the checkout's bound context, when it isn't production.
        var suggested: String?
        /// Said under the picker: why the bound context isn't offered.
        var note: String?
    }

    /// The contexts a task may pin to — every one but production, the
    /// checkout's bound one first and suggested.
    static func offer(_ list: KubeContextList, binding: KubeBinding?) -> Offer {
        var offer = Offer()
        var bound: Choice?
        for context in list.contexts where !context.isProduction {
            let namespace = binding?.context == context.name ? binding?.namespace : nil
            let choice = Choice(
                context: context.name, title: context.displayName + ((namespace ?? context.namespace).map { " · " + $0 } ?? ""), namespace: namespace)
            if binding?.context == context.name { bound = choice } else { offer.choices.append(choice) }
        }
        if let bound {
            offer.choices.insert(bound, at: 0)
            offer.suggested = bound.context
        } else if let binding, let context = list.context(named: binding.context), context.isProduction {
            offer.note =
                "The checkout is bound to \(context.displayName), production: not offered here. The agent's kubectl goes to your current context unless pinned."
        }
        return offer
    }

    /// Whether `name` may be pinned to — read again as the task is made:
    /// a context that became production since the sheet opened is refused.
    static func refused(_ name: String, in list: KubeContextList) -> String? {
        guard let context = list.context(named: name) else { return "No kubeconfig of Overterm's names \(name) any more." }
        return context.isProduction ? "\(context.displayName) is production: a task's tab isn't pinned there." : nil
    }
}
