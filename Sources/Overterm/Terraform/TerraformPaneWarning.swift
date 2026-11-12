import AppKit
import Combine
import Darwin

/// A terraform-family process, as its argv, folder and environment say
/// (analysis 3.2): only the names a header shows are read from its
/// environment — `TF_WORKSPACE`, `TF_DATA_DIR` and the profile's name in
/// `AWS_PROFILE` — never a credential's value.
struct TerraformProcess: Equatable, Sendable {
    var pid: pid_t
    var line: TerraformCommandLine
    var cwd: String?
    var workspaceVariable: String?
    var dataDirVariable: String?
    var awsProfile: String?
    /// When it started, µs since 1970.
    var started: UInt64?
    /// Its `terraform-provider-*` children.
    var providers = 0

    /// The folder it works in: its cwd, then `-chdir` — unless the cwd is
    /// there already: terraform changes its own folder to `-chdir`'s first
    /// thing, so a running one's cwd is the root.
    var folder: URL? {
        guard let cwd else { return nil }
        let base = URL(fileURLWithPath: cwd, isDirectory: true)
        guard let chdir = line.chdir, !chdir.isEmpty else { return base.standardizedFileURL }
        let named = chdir.split(separator: "/").filter { $0 != "." }.joined(separator: "/")
        if !chdir.hasPrefix("/"), !named.contains(".."), !named.isEmpty, base.standardizedFileURL.path.hasSuffix("/" + named) {
            return base.standardizedFileURL
        }
        return (chdir.hasPrefix("/") ? URL(fileURLWithPath: chdir, isDirectory: true) : base.appendingPathComponent(chdir, isDirectory: true))
            .standardizedFileURL
    }

    /// The names read from a process's environment: nothing else is kept.
    static func environmentNames(_ environment: [String: String]) -> (workspace: String?, dataDir: String?, profile: String?) {
        func value(_ name: String) -> String? { environment[name].flatMap { $0.isEmpty ? nil : $0 } }
        return (value("TF_WORKSPACE"), value("TF_DATA_DIR"), value("AWS_PROFILE"))
    }
}

/// Finding terraform in a pane's tree (3.2): one `proc_listchildpids` walk
/// from the pane's `login`, a name each; argv, folder and environment are
/// read only for a terraform, tofu or terragrunt (or a script of that name
/// a shell runs: the recording wrapper). Never `pkill -f`, never a pattern:
/// by pid. Blocking: a GCD thread's.
enum TerraformProcesses {
    static let scriptShells: Set<String> = ["bash", "sh", "dash"]

    /// The descendants of `root`, breadth first, at most `limit`.
    static func descendants(of root: pid_t, limit: Int = 2_000) -> [pid_t] {
        // `found` is the queue too: an index walks it, a set answers "seen".
        var found: [pid_t] = []
        var seen: Set<pid_t> = [root]
        var next = -1
        var buffer = [pid_t](repeating: 0, count: 512)
        while found.count < limit {
            let parent: pid_t
            if next < 0 {
                parent = root
            } else if next < found.count {
                parent = found[next]
            } else {
                break
            }
            next += 1
            let count = buffer.withUnsafeMutableBytes { raw in
                proc_listchildpids(parent, raw.baseAddress, Int32(raw.count))
            }
            guard count > 0 else { continue }
            for pid in buffer.prefix(Int(count)) where pid > 0 && found.count < limit && seen.insert(pid).inserted {
                found.append(pid)
            }
        }
        return found
    }

    static func name(of pid: pid_t) -> String? {
        var buffer = [UInt8](repeating: 0, count: 256)
        let length = proc_name(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)), as: UTF8.self)
    }

    /// `pid` as a terraform process, or nil when it is none.
    static func inspect(_ pid: pid_t, name: String? = nil, children: [pid_t]? = nil) -> TerraformProcess? {
        let name = name ?? self.name(of: pid) ?? ""
        guard TerraformCommandLine.tools.contains(name) || scriptShells.contains(name) else { return nil }
        guard let args = ProcessInspector.procArgs(pid), let line = TerraformCommandLine.parse(arguments: args.arguments) else { return nil }
        let names = TerraformProcess.environmentNames(args.environment)
        var process = TerraformProcess(
            pid: pid, line: line, cwd: ProcessInspector.workingDirectory(of: pid), workspaceVariable: names.workspace, dataDirVariable: names.dataDir,
            awsProfile: names.profile, started: ProcessInspector.kinfo(pid)?.start)
        let below = children ?? descendants(of: pid, limit: 64)
        process.providers = below.filter { (self.name(of: $0) ?? "").hasPrefix("terraform-provider-") }.count
        return process
    }

    /// The terraform processes under `root` (a pane's `login`), outermost first.
    static func find(under root: pid_t) -> [TerraformProcess] {
        var found: [TerraformProcess] = []
        let all = descendants(of: root)
        for pid in all {
            guard let name = name(of: pid), TerraformCommandLine.tools.contains(name) || scriptShells.contains(name) else { continue }
            // A wrapper script and the terraform it `exec`s are one pid; a
            // terragrunt's terraform is its child: the outermost is kept.
            if let process = inspect(pid, name: name), !found.contains(where: { $0.pid == pid }) { found.append(process) }
            if found.count >= 4 { break }
        }
        return found
    }

    /// The repository `folder` is in: the nearest folder above with a
    /// `.git`, bounded, stopping at `/` (CLAUDE.md).
    static func checkout(of folder: URL) -> URL? {
        var dir = folder.standardizedFileURL
        for _ in 0..<64 where dir.pathComponents.count > 1 {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent(".git").path) { return dir }
            dir = dir.deletingLastPathComponent().standardizedFileURL
        }
        return nil
    }

    /// Whether `folder` holds Terraform's files: a configuration or Terragrunt's.
    static func hasConfiguration(_ folder: URL) -> Bool {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.prefix(2_000).contains { TerraformRootGuess.isConfigFile($0) || $0 == "terragrunt.hcl" || $0 == "root.hcl" }
    }
}

/// The pane header over a pane where terraform runs (3.2): root, workspace,
/// backend, the profile, the operation — red on production. A notice, not
/// a guard: it shows once the command has started. "probably" when the
/// command is `make`, `just`, `task`, `./deploy*.sh` or `atlantis` and the
/// folder's files are all that say it. Pure.
struct TerraformPaneWarning: Equatable, Sendable {
    var tool: String
    var operation: String?
    var root: String
    var workspace: String
    var backend: String
    var awsProfile: String?
    var rootClass: TerraformClass
    var reason: String
    var probably = false
    /// `TF_WORKSPACE` or `TF_DATA_DIR` in the process's environment: each decides silently.
    var inheritedWorkspace: String?
    var inheritedDataDir = false
    var isWrite = false
    /// The state identity to keep as production (`TerraformRootCard.identityToRemember`):
    /// production by the root's own signals, the run's var files among them.
    var rememberIdentity: TerraformStateIdentity?

    var isProduction: Bool { rootClass == .production }

    /// `⛰ envs/prod · workspace prod · s3 acme-tfstate/prod/network.tfstate · AWS_PROFILE acme-prod-admin · apply`.
    var label: String {
        var parts = ["⛰ " + (probably ? "probably " : "") + root, "workspace \(workspace)", backend]
        if let awsProfile { parts.append("AWS_PROFILE \(awsProfile)") }
        if let operation { parts.append(operation) }
        return parts.joined(separator: " · ")
    }

    var help: String {
        var lines = [
            "\(tool)\(operation.map { " " + $0 } ?? "") \(probably ? "probably runs" : "runs") in \(root) — \(rootClass.title.uppercased()): \(reason)."
        ]
        if let inheritedWorkspace { lines.append("TF_WORKSPACE=\(inheritedWorkspace) is set in its environment: it decides the workspace, whatever the root selects.") }
        if inheritedDataDir { lines.append("TF_DATA_DIR is set in its environment: its backend and workspace come from there, not the root's .terraform.") }
        lines.append("A notice, not a guard: Overterm can't stop a terraform typed in a terminal.")
        return lines.joined(separator: "\n")
    }

    /// The warning for `process` (or, `probable`, a command that probably
    /// runs terraform) in `folder`, from the folder's facts. `runFiles` are
    /// the var files and backend-config files the run itself names
    /// (`TerraformCommandLine.namedFiles`): signal 4 of 5.1.
    static func make(
        tool: String, operation: String?, isWrite: Bool, folder: URL, checkout: URL?, facts: TerraformRootFacts, workspaceVariable: String?,
        dataDirVariable: String?, awsProfile: String?, runFiles: [String] = [], probably: Bool, settings: TerraformClassSettings,
        identities: Set<TerraformStateIdentity>
    ) -> TerraformPaneWarning {
        let top = checkout?.standardizedFileURL.path
        let full = folder.standardizedFileURL.path
        let path: String
        if let top, full == top {
            path = ""
        } else if let top, full.hasPrefix(top + "/") {
            path = String(full.dropFirst(top.count + 1))
        } else {
            path = folder.lastPathComponent
        }
        let workspace = workspaceVariable ?? facts.workspace
        let names =
            ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter {
                $0 == "terraform.tfvars" || $0 == "terraform.tfvars.json" || $0.hasSuffix(".auto.tfvars") || $0.hasSuffix(".auto.tfvars.json")
            } + runFiles
        let terragruntTree = checkout.map { FileManager.default.fileExists(atPath: $0.appendingPathComponent("root.hcl").path) } ?? false
        let (verdict, identity) = TerraformRootCard.verdict(
            path: path, folder: folder, facts: facts, workspace: workspace, varFiles: names, awsProfile: awsProfile, terragruntTree: terragruntTree,
            settings: settings, productionIdentities: identities)
        let remember = TerraformRootCard.identityToRemember(
            verdict: verdict, identity: identity, awsProfile: awsProfile, path: path, folder: folder, facts: facts, workspace: workspace,
            varFiles: names, terragruntTree: terragruntTree, settings: settings, productionIdentities: identities)
        return TerraformPaneWarning(
            tool: tool, operation: operation, root: settings.roots[path]?.displayName ?? (path.isEmpty ? folder.lastPathComponent : path),
            workspace: workspace, backend: TerraformStateIdentity.summary(of: facts.backend, workspace: workspace), awsProfile: awsProfile,
            rootClass: verdict.rootClass, reason: verdict.reason, probably: probably, inheritedWorkspace: workspaceVariable,
            inheritedDataDir: dataDirVariable != nil, isWrite: isWrite, rememberIdentity: remember)
    }

    /// The checkout `folder` is in, of the tab's: the same folder or one
    /// below it — `/w/acme-live-bump` is not in `/w/acme-live`.
    static func contains(_ checkout: URL, _ folder: URL) -> Bool {
        let top = checkout.standardizedFileURL.path
        let path = folder.standardizedFileURL.path
        return path == top || path.hasPrefix(top + "/")
    }
}

/// Walks the process trees of the panes where something runs, every 2 s,
/// for terraform (3.2): a stated exception to "read only on screen", with
/// a budget. A pane at its prompt isn't walked (an agent's always is: it
/// runs commands as its own children); only panes of a checkout with
/// roots are — settled once per checkout by one bounded listing
/// (`TerraformCheckouts.settle`), so a tab outside a repository, or in
/// one with no Terraform, is never walked; the walk is
/// `proc_listchildpids` and a name a pid, no file read — a root's files
/// are read only when a terraform appears. Off with `terraform.enabled` —
/// a security setting: an agent that writes `false` to settings.json is
/// held until confirmed (5.8), so it can't take the header away before an
/// apply. One for the app; what it finds, by pane (`processTag`).
@MainActor
final class TerraformPaneMonitor: ObservableObject {
    static let shared = TerraformPaneMonitor()

    @Published private(set) var warnings: [String: TerraformPaneWarning] = [:]
    /// The terraform processes found, by pane: Tab Info and the close guard (2a) read them.
    private(set) var processes: [String: [TerraformProcess]] = [:]
    private var loop: Task<Void, Never>?
    static let interval: Duration = .seconds(2)
    /// Walks done: a scenario checks a pane at its prompt costs none.
    private(set) var walks = 0

    struct Candidate: Sendable {
        var tag: String
        var login: pid_t
        var command: String?
        var commandFolder: String?
        var checkout: URL?
    }

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(for: Self.interval)
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
    }

    /// One look at every pane that may run terraform.
    func tick() async {
        guard Settings.shared.terraformEnabled else {
            if !warnings.isEmpty { warnings = [:] }
            processes = [:]
            return
        }
        var candidates: [Candidate] = []
        for controller in NSApp.windows.compactMap({ $0.windowController as? TerminalWindowController }) {
            for tab in controller.store.tabs {
                guard let checkout = tab.checkoutSource?.root, TerraformCheckouts.shared.hasRoots(checkout) != false else { continue }
                // Paired once (a scan of the app's children), then kept.
                let running = tab.terminals.compactMap { pane -> (TerminalView, CommandBlock?, pid_t)? in
                    let command = controller.blocks(of: pane).ledger.running
                    guard command != nil || tab.agent != nil, let login = SurfaceProcesses.shared.loginPID(of: pane) else { return nil }
                    return (pane, command, login)
                }
                guard !running.isEmpty else { continue }
                // Not settled yet: listed once (something runs there), walked from the next look.
                guard TerraformCheckouts.shared.hasRoots(checkout) == true else {
                    TerraformCheckouts.shared.settle(checkout)
                    continue
                }
                for (pane, command, login) in running {
                    candidates.append(
                        Candidate(
                            tag: pane.processTag, login: login, command: command?.command, commandFolder: controller.blocks(of: pane).commandFolder,
                            checkout: checkout))
                }
            }
        }
        walks += candidates.count
        guard !candidates.isEmpty else {
            if !warnings.isEmpty { warnings = [:] }
            processes = [:]
            return
        }
        let settings = TerraformClassSettings.current
        let identities = TerraformRootStore.shared.productionIdentities
        let asked = candidates
        let found = await TerraformPanelModel.blocking { Self.look(at: asked, settings: settings, identities: identities) }
        processes = found.processes
        if warnings != found.warnings { warnings = found.warnings }
        TerraformRootStore.shared.rememberProduction(found.warnings.values.compactMap(\.rememberIdentity))
    }

    /// Facts read for a folder, kept a few seconds: a terraform running
    /// minutes is not read again every 2 s.
    private nonisolated static let factsLock = NSLock()
    private nonisolated(unsafe) static var factsCache: [String: (at: Date, facts: TerraformRootFacts)] = [:]

    nonisolated static func facts(of folder: URL, checkout: URL) -> TerraformRootFacts {
        let key = folder.path
        if let cached = factsLock.withLock({ factsCache[key] }), Date().timeIntervalSince(cached.at) < 10 { return cached.facts }
        let facts = TerraformRootFacts.read(root: folder, checkout: checkout)
        factsLock.withLock {
            factsCache = factsCache.filter { Date().timeIntervalSince($0.value.at) < 60 }
            factsCache[key] = (Date(), facts)
        }
        return facts
    }

    nonisolated static func look(
        at candidates: [Candidate], settings: TerraformClassSettings, identities: Set<TerraformStateIdentity>
    ) -> (warnings: [String: TerraformPaneWarning], processes: [String: [TerraformProcess]]) {
        var warnings: [String: TerraformPaneWarning] = [:]
        var processes: [String: [TerraformProcess]] = [:]
        for candidate in candidates {
            let found = TerraformProcesses.find(under: candidate.login)
            if !found.isEmpty { processes[candidate.tag] = found }
            // The one that writes, else the first.
            if let process = found.first(where: \.line.isWrite) ?? found.first, let folder = process.folder,
                TerraformProcesses.hasConfiguration(folder)
            {
                let checkout =
                    candidate.checkout.flatMap { TerraformPaneWarning.contains($0, folder) ? $0 : nil }
                    ?? TerraformProcesses.checkout(of: folder) ?? folder
                warnings[candidate.tag] = TerraformPaneWarning.make(
                    tool: process.line.tool, operation: process.line.operation, isWrite: process.line.isWrite, folder: folder, checkout: checkout,
                    facts: facts(of: folder, checkout: checkout), workspaceVariable: process.workspaceVariable, dataDirVariable: process.dataDirVariable,
                    awsProfile: process.awsProfile, runFiles: process.line.namedFiles, probably: false, settings: settings, identities: identities)
                continue
            }
            // Nothing named terraform: `make apply` in a root, probably.
            guard let command = candidate.command, let line = TerraformCommandLine.parse(command), line.probably,
                let cwd = candidate.commandFolder
            else { continue }
            let folder = URL(fileURLWithPath: cwd, isDirectory: true).standardizedFileURL
            guard TerraformProcesses.hasConfiguration(folder) else { continue }
            let checkout = TerraformProcesses.checkout(of: folder) ?? folder
            warnings[candidate.tag] = TerraformPaneWarning.make(
                tool: line.tool, operation: line.operation, isWrite: false, folder: folder, checkout: checkout,
                facts: facts(of: folder, checkout: checkout), workspaceVariable: nil, dataDirVariable: nil, awsProfile: nil, probably: true,
                settings: settings, identities: identities)
        }
        return (warnings, processes)
    }
}

/// One terraform process as Tab Info lists it (analysis 8): its operation,
/// root and workspace, how long it has run, its provider plugins, and the
/// root's `.terraform` on disk (`DiskUsage`, kept a minute).
struct TerraformInfoRow: Equatable, Sendable {
    var pid: pid_t
    var operation: String
    var root: String
    var workspace: String
    var production: Bool
    var started: UInt64?
    var providers: Int
    var dataBytes: UInt64?
    /// What Tab Info's caller keeps as production (`TerraformRootStore`).
    var rememberIdentity: TerraformStateIdentity?

    private static let sizeLock = NSLock()
    nonisolated(unsafe) private static var sizes: [String: (at: Date, bytes: UInt64)] = [:]

    /// `.terraform`'s size, measured at most once a minute per root. Blocking.
    static func dataSize(of folder: URL) -> UInt64? {
        let data = folder.appendingPathComponent(".terraform", isDirectory: true)
        if let cached = sizeLock.withLock({ sizes[data.path] }), Date().timeIntervalSince(cached.at) < 60 { return cached.bytes }
        guard FileManager.default.fileExists(atPath: data.path), let report = DiskUsage.measure(data, top: 1) else { return nil }
        sizeLock.withLock { sizes[data.path] = (Date(), report.total) }
        return report.total
    }

    static func make(_ process: TerraformProcess, settings: TerraformClassSettings, identities: Set<TerraformStateIdentity>) -> TerraformInfoRow {
        let operation = process.line.tool + (process.line.operation.map { " " + $0 } ?? "")
        guard let folder = process.folder else {
            return TerraformInfoRow(
                pid: process.pid, operation: operation, root: "?", workspace: process.workspaceVariable ?? "default", production: false,
                started: process.started, providers: process.providers)
        }
        let checkout = TerraformProcesses.checkout(of: folder) ?? folder
        let facts = TerraformPaneMonitor.facts(of: folder, checkout: checkout)
        let warning = TerraformPaneWarning.make(
            tool: process.line.tool, operation: process.line.operation, isWrite: process.line.isWrite, folder: folder, checkout: checkout, facts: facts,
            workspaceVariable: process.workspaceVariable, dataDirVariable: process.dataDirVariable, awsProfile: process.awsProfile,
            runFiles: process.line.namedFiles, probably: false, settings: settings, identities: identities)
        return TerraformInfoRow(
            pid: process.pid, operation: operation, root: warning.root, workspace: warning.workspace, production: warning.isProduction,
            started: process.started, providers: process.providers, dataBytes: dataSize(of: folder), rememberIdentity: warning.rememberIdentity)
    }

    /// "2m 14s", from a start in µs since 1970.
    static func elapsed(since started: UInt64, now: Date = Date()) -> String {
        let seconds = max(0, Int(now.timeIntervalSince1970 - Double(started) / 1_000_000))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m \(seconds % 60)s" }
        return "\(seconds / 3600)h \(seconds % 3600 / 60)m"
    }
}
