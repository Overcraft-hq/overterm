import Combine
import Foundation

/// One root's lock file against the same root's in another worktree (2.8,
/// stage 2b): "aws 5.80.0 here, 6.2.0 in `main`". Read from the files
/// themselves — what each worktree's `init` and plan use, committed or
/// not — never written. Pure but for `versions(at:)`'s bounded read.
enum TerraformLockDrift {
    struct Difference: Equatable, Sendable {
        /// The provider as a person says it: `aws`, `globex/acme` off the
        /// `hashicorp` namespace, the whole address off the public registry.
        var provider: String
        /// The version this worktree locks, nil when it locks none.
        var here: String?
        var there: String?
    }

    /// The differences with one other worktree.
    struct Drift: Equatable, Sendable, Identifiable {
        var worktree: String
        var differences: [Difference]
        /// This worktree has no lock file, or the other has none.
        var missingHere = false
        var missingThere = false
        /// The other worktree's path: names repeat (two detached HEADs).
        var worktreePath = ""

        var id: String { worktreePath.isEmpty ? worktree : worktreePath }

        var sentence: String {
            if missingHere {
                let locked = differences.compactMap { d in d.there.map { "\(d.provider) \($0)" } }
                return "no lock file here; \(worktree)'s locks " + locked.prefix(4).joined(separator: ", ") + (locked.count > 4 ? ", \(locked.count - 4) more" : "")
            }
            if missingThere { return "\(worktree) has no lock file" }
            return differences.prefix(4).map { d in
                switch (d.here, d.there) {
                case (let here?, let there?): "\(d.provider) \(here) here, \(there) in \(worktree)"
                case (nil, let there?): "\(d.provider) only in \(worktree) (\(there))"
                case (let here?, nil): "\(d.provider) only here (\(here))"
                case (nil, nil): d.provider
                }
            }.joined(separator: "; ") + (differences.count > 4 ? "; \(differences.count - 4) more" : "")
        }
    }

    /// `registry.terraform.io/hashicorp/aws` → `aws`.
    static func shortName(_ address: String) -> String {
        let parts = address.lowercased().split(separator: "/").map(String.init)
        guard parts.count == 3 else { return address }
        guard parts[0] == "registry.terraform.io" || parts[0] == "registry.opentofu.org" else { return address }
        return parts[1] == "hashicorp" || parts[1] == "opentofu" ? parts[2] : parts[1] + "/" + parts[2]
    }

    /// Each provider's locked version, by address; nil without a lock file.
    static func versions(in text: String) -> [String: String] {
        var result: [String: String] = [:]
        for (address, version) in TerraformLockFile.versions(in: text) { result[address.lowercased()] = version }
        return result
    }

    /// A root's drifts as one line: the first, and how many other
    /// worktrees differ too — up to 12 worktrees would make 12 lines.
    static func summary(_ drifts: [Drift]) -> String? {
        guard let first = drifts.first else { return nil }
        let rest = drifts.count - 1
        return first.sentence + (rest > 0 ? " — and \(rest) other worktree\(rest == 1 ? "" : "s")" : "")
    }

    /// What differs between `here` and `there` (each nil without a lock
    /// file), or nil when nothing does — or neither has one.
    static func drift(here: [String: String]?, there: [String: String]?, worktree: String) -> Drift? {
        switch (here, there) {
        case (nil, nil): return nil
        case (nil, let there?):
            guard !there.isEmpty else { return nil }
            return Drift(
                worktree: worktree, differences: there.keys.sorted().map { Difference(provider: shortName($0), here: nil, there: there[$0]) }, missingHere: true)
        case (let here?, nil):
            guard !here.isEmpty else { return nil }
            return Drift(worktree: worktree, differences: [], missingThere: true)
        case (let here?, let there?):
            let differences = Set(here.keys).union(there.keys).sorted().compactMap { address -> Difference? in
                here[address] == there[address] ? nil : Difference(provider: shortName(address), here: here[address], there: there[address])
            }
            return differences.isEmpty ? nil : Drift(worktree: worktree, differences: differences)
        }
    }

    /// A root's lock file's versions, nil when it has none: bounded (1 MB),
    /// kept by the file's size and modification time, so a read of the
    /// panel stats another worktree's file rather than reading it again.
    static func versions(at root: URL) -> [String: String]? {
        let url = root.appendingPathComponent(".terraform.lock.hcl")
        var info = stat()
        guard stat(url.path, &info) == 0 else { return nil }
        let signature = "\(info.st_size):\(info.st_mtimespec.tv_sec).\(info.st_mtimespec.tv_nsec)"
        let key = url.standardizedFileURL.path
        if let cached = cacheLock.withLock({ cache[key] }), cached.signature == signature { return cached.versions }
        guard let data = TerraformRootFacts.smallFile(url, limit: 1 << 20) else { return nil }
        let versions = versions(in: String(decoding: data, as: UTF8.self))
        cacheLock.withLock {
            if cache.count > 2_000 { cache.removeAll() }
            cache[key] = (signature, versions)
        }
        return versions
    }

    private static let cacheLock = NSLock()
    private nonisolated(unsafe) static var cache: [String: (signature: String, versions: [String: String])] = [:]
}

/// What New Task did and found for one root of the worktree it made (3.7,
/// stage 2b): whose checkout has its state, the workspace another
/// worktree selects — never copied here —, how its lock file differs,
/// and its init without the backend, for validate and the editor. Pure.
struct TerraformWorktreeRoot: Equatable, Sendable, Identifiable {
    enum Preparation: Equatable, Sendable {
        /// `terraform.newWorktreeInit` is off.
        case off
        case waiting
        case running
        /// Initialised without its backend: validate and the editor work.
        case ready
        case skipped(String)
        case failed(String)

        var words: String {
            switch self {
            case .off: "Not initialised: New Task's init is off in Settings ▸ Terraform."
            case .waiting: "Waiting to initialise without its backend…"
            case .running: "Initialising without its backend (no credentials, the lock file read only)…"
            case .ready: "Initialised without its backend: validate and the editor work. A plan needs Init… first."
            case .skipped(let why): "Not initialised: \(why)"
            case .failed(let why): "init -backend=false failed: \(why)"
            }
        }

        var isProblem: Bool {
            switch self {
            case .skipped, .failed: true
            default: false
            }
        }
    }

    /// Another worktree's workspace for the same root.
    struct SourceWorkspace: Equatable, Sendable {
        var worktree: String
        var workspace: String
    }

    var path: String
    var name: String
    var folder: URL
    var stateElsewhere: String?
    /// Another worktree selects a workspace other than `default` for this
    /// root: its name and the workspace. This one starts at `default`.
    var sourceWorkspace: SourceWorkspace?
    var lockDrift: [TerraformLockDrift.Drift] = []
    var preparation: Preparation

    var id: String { path }

    /// What the root needs before New Task initialises it: `.waiting`, or
    /// why it isn't (2.1, 4.13, 5.9). Only where init fetches nothing the
    /// panel's Init would flag — every provider the root or a local module
    /// it calls names, required or implied by a resource or a `provider`
    /// block, in the root's lock file; every module local or at an exact
    /// registry version, none fetched from anywhere else whatever its ref
    /// (git with the user's keys, a mutable tag) — and never on an HCP
    /// root. `modules`: the local modules' configs (`localModules`), nil
    /// when they couldn't all be read. Anything else is the person's
    /// Init…, which shows its fetch list first.
    static func preparation(for card: TerraformRootCard, enabled: Bool, modules: [TerraformConfigFacts]? = []) -> Preparation {
        guard enabled else { return .off }
        if let why = TerraformProcessCheck.refused(.initialize, backendType: card.facts.backend.type) { return .skipped(why) }
        let lock = card.facts.lockProviders
        for config in [card.facts.config] + (modules ?? []) {
            if let why = refusal(config: config, lockProviders: lock) { return .skipped(why) }
        }
        guard modules != nil else { return .skipped("its local modules couldn't all be read. Init… in the panel shows what it fetches.") }
        return .waiting
    }

    /// Why New Task doesn't initialise for `config`, or nil.
    static func refusal(config: TerraformConfigFacts, lockProviders: [TerraformLockFile.Provider]?) -> String? {
        let suffix = " Init… in the panel shows what it fetches."
        let flagged = TerraformInitPlan.items(config: config, lockProviders: lockProviders).filter { $0.flag != nil }
        if let first = flagged.first {
            let what = first.kind == .provider ? "provider \(first.name)" : "module \(first.name)"
            return "\(what) — \(first.flag ?? "")." + suffix
        }
        for source in Set(config.moduleSources).sorted() where !TerraformRunRisks.isLocal(source) && !TerraformInitPlan.isRegistry(source) {
            return "module \(TerraformInitPlan.moduleName(source)) — fetched from outside the registry, perhaps with your keys." + suffix
        }
        if let name = unlockedImplied(config: config, lockProviders: lockProviders) {
            return "provider \(name) — not in .terraform.lock.hcl: init would fetch whichever version is newest." + suffix
        }
        return nil
    }

    /// A provider the configuration uses without `required_providers` — a
    /// resource's prefix, a `provider` block — that the lock file doesn't
    /// pin, or nil. `terraform` is the builtin.
    static func unlockedImplied(config: TerraformConfigFacts, lockProviders: [TerraformLockFile.Provider]?) -> String? {
        let lockedTypes = Set((lockProviders ?? []).map { $0.type.lowercased() })
        return config.providerNames.subtracting(config.requiredProviders.keys).subtracting(["terraform"]).sorted()
            .first { !lockedTypes.contains($0.lowercased()) }
    }

    /// The configs of the local modules `config` calls from `root`, and
    /// theirs, bounded: nil past `limit` folders, or one that isn't there
    /// or leaves the checkout. Blocking file reads.
    static func localModules(of config: TerraformConfigFacts, at root: URL, checkout: URL, limit: Int = 24) -> [TerraformConfigFacts]? {
        let top = checkout.resolvingSymlinksInPath().standardizedFileURL.path
        var seen: Set<String> = [root.resolvingSymlinksInPath().standardizedFileURL.path]
        var queue: [(URL, TerraformConfigFacts)] = [(root, config)]
        var found: [TerraformConfigFacts] = []
        while !queue.isEmpty {
            let (folder, facts) = queue.removeFirst()
            for source in Set(facts.moduleSources).sorted() where TerraformRunRisks.isLocal(source) {
                let called = folder.appendingPathComponent(source, isDirectory: true).resolvingSymlinksInPath().standardizedFileURL
                guard called.path == top || called.path.hasPrefix(top + "/") else { return nil }
                guard seen.insert(called.path).inserted else { continue }
                guard found.count < limit else { return nil }
                var isFolder: ObjCBool = false
                guard FileManager.default.fileExists(atPath: called.path, isDirectory: &isFolder), isFolder.boolValue else { return nil }
                let read = TerraformConfigFacts.read(TerraformRootFacts.configTexts(in: called))
                found.append(read)
                queue.append((called, read))
            }
        }
        return found
    }

    /// The other worktree that selects a workspace for this root, if one does.
    static func sourceWorkspace(card: TerraformRootCard, others: [(name: String, facts: TerraformRootFacts)]) -> SourceWorkspace? {
        guard card.workspace == "default" else { return nil }
        let other = others.first { $0.facts.workspaceFromFile && $0.facts.workspace != "default" }
        return other.map { SourceWorkspace(worktree: $0.name, workspace: $0.facts.workspace) }
    }

    static func make(
        card: TerraformRootCard, enabled: Bool, others: [(name: String, facts: TerraformRootFacts)], modules: [TerraformConfigFacts]? = []
    ) -> TerraformWorktreeRoot {
        TerraformWorktreeRoot(
            path: card.path, name: card.name, folder: card.folder, stateElsewhere: card.stateElsewhere,
            sourceWorkspace: sourceWorkspace(card: card, others: others), lockDrift: card.lockDrift,
            preparation: preparation(for: card, enabled: enabled, modules: modules))
    }

    /// The warnings, in the panel's words.
    var notes: [String] {
        var notes: [String] = []
        if let source = sourceWorkspace {
            notes.append("Workspace default here: \(source.worktree) selects \(source.workspace), which New Task doesn't copy — select it here if you mean it.")
        }
        return notes
    }
}

/// New Task's Terraform (analysis 2.1, 3.7, stage 2b), one for the app:
/// once `git worktree add` made a checkout, its roots are read as the
/// panel reads them, against the repository's other worktrees — the
/// no-state warning, the lock files compared, the workspace another
/// worktree selects named and not copied —, then each root whose init
/// fetches nothing flagged is initialised without its backend
/// (`init -backend=false -lockfile=readonly`, validate's environment: no
/// credential, no workspace, nothing in the lock file written), one at a
/// time, so validate and the editor work there; the panel's Init and Plan
/// of that root wait while it runs. Never a plan, never the backend: a
/// plan there needs Init… first. In memory, a root's entry forgotten once
/// the person's own Init or a plan ran there.
@MainActor
final class TerraformWorktreeSetup: ObservableObject {
    static let shared = TerraformWorktreeSetup()

    struct Report: Equatable, Sendable {
        var roots: [TerraformWorktreeRoot]
        var finished = false
    }

    /// By the worktree's path, symlinks resolved (`key`): New Task's URL
    /// and the panel's checkout spell `/var` and `/private/var` apart.
    @Published private(set) var reports: [String: Report] = [:]
    private var tasks: [String: (id: UUID, task: Task<Void, Never>)] = [:]

    /// One root's init without its backend, given the plugin cache: the
    /// real one (`initialize`) but in unit tests, which record instead.
    typealias Initializer = @MainActor (URL, String?) async -> TerraformWorktreeRoot.Preparation
    private let initializer: Initializer
    private let registry: TerraformRunRegistry

    init(registry: TerraformRunRegistry = .shared, initializer: Initializer? = nil) {
        self.registry = registry
        self.initializer = initializer ?? { root, cache in await TerraformWorktreeSetup.initialize(root, cache: cache) }
    }

    static func key(_ url: URL) -> String { url.resolvingSymlinksInPath().standardizedFileURL.path }

    func report(_ checkout: URL?) -> Report? { checkout.flatMap { reports[Self.key($0)] } }

    func root(_ checkout: URL?, path: String) -> TerraformWorktreeRoot? { report(checkout)?.roots.first { $0.path == path } }

    /// Whether New Task's init is running in `root` (a root's folder): the
    /// panel's Init, Plan, Check Drift, Test and State wait for it — they
    /// write its `.terraform`, or read the providers it is installing.
    func isInitializing(_ root: URL) -> Bool {
        let path = Self.key(root)
        return reports.values.contains { $0.roots.contains { $0.preparation == .running && Self.key($0.folder) == path } }
    }

    /// What a run of `root` that would read or write its `.terraform` says
    /// while New Task initialises it — Plan, Init, Check Drift, Test, a
    /// state read, the person's or an agent's —, or nil.
    func refusal(_ root: URL) -> String? {
        isInitializing(root) ? Self.initializingRefusal : nil
    }

    static let initializingRefusal = "New Task is initialising this root without its backend: press again once it is done."

    /// Forgets what New Task said of `checkout`'s `root` once the person's
    /// own Init or a plan ran there: it no longer says what the root is.
    func forget(checkout: URL, root: String) {
        let key = Self.key(checkout)
        guard let index = reports[key]?.roots.firstIndex(where: { $0.path == root }) else { return }
        guard reports[key]?.roots[index].preparation != .running else { return }
        reports[key]?.roots.remove(at: index)
    }

    /// Reads `worktree`'s roots against `others` and initialises the ones it
    /// may; `finished` once every one is done (the panel reads again). A
    /// second prepare of the same worktree waits for the first's init to
    /// end — cancelling a task leaves its terraform running (the init isn't
    /// `interruptible`: never a half-written `.terraform`).
    func prepare(
        _ worktree: URL, others: [TerraformWorktree], initialize: Bool, finished: @escaping @MainActor () -> Void = {}
    ) {
        let key = Self.key(worktree)
        let previous = tasks[key]?.task
        previous?.cancel()
        let settings = TerraformClassSettings.current
        let identities = TerraformRootStore.shared.productionIdentities
        let shell = AppEnvironment.guardsTerraform ? [:] : (ShellEnvironment.known() ?? [:])
        let cache = Self.pluginCache(shell: shell)
        let id = UUID()
        let task = Task { [weak self] in
            await previous?.value
            guard !Task.isCancelled, let listing = await TerraformRootScan.list(worktree), !Task.isCancelled else { return }
            let roots = await TerraformPanelModel.blocking { () -> [TerraformWorktreeRoot] in
                let assembled = TerraformPanelModel.assemble(
                    checkout: worktree, listing: listing, worktrees: others, settings: settings, identities: identities, awsProfile: shell["AWS_PROFILE"],
                    changed: [])
                return assembled.roots.filter { $0.kind == .root }.map { card in
                    let otherFacts = others.compactMap { other -> (name: String, facts: TerraformRootFacts)? in
                        let folder = card.path.isEmpty ? other.url : other.url.appendingPathComponent(card.path, isDirectory: true)
                        guard FileManager.default.fileExists(atPath: folder.path) else { return nil }
                        return (other.name, TerraformRootFacts.readIdentity(root: folder))
                    }
                    let modules = initialize ? TerraformWorktreeRoot.localModules(of: card.facts.config, at: card.folder, checkout: worktree) : []
                    return TerraformWorktreeRoot.make(card: card, enabled: initialize, others: otherFacts, modules: modules)
                }
            }
            guard let self, !Task.isCancelled else { return }
            TerraformCheckouts.shared.record(worktree, hasRoots: !roots.isEmpty)
            self.reports[key] = Report(roots: roots)
            for root in roots where root.preparation == .waiting {
                guard !Task.isCancelled else { break }
                // The person's own run got there first: theirs, not ours.
                if self.registry.runs.contains(where: { $0.isGoing && Self.key($0.card.folder) == Self.key(root.folder) }) {
                    self.set(key, root.path, .skipped("an Init or a plan of yours is running here."))
                    continue
                }
                self.set(key, root.path, .running)
                let outcome = await self.initializer(root.folder, cache)
                self.set(key, root.path, outcome)
            }
            guard self.tasks[key]?.id == id else { return }
            self.reports[key]?.finished = true
            self.tasks[key] = nil
            finished()
        }
        tasks[key] = (id, task)
    }

    private func set(_ key: String, _ path: String, _ preparation: TerraformWorktreeRoot.Preparation) {
        guard let index = reports[key]?.roots.firstIndex(where: { $0.path == path }) else { return }
        reports[key]?.roots[index].preparation = preparation
    }

    /// The plugin cache, when the person took it and keeps no CLI config of
    /// their own (4.13); made 0700.
    private static func pluginCache(shell: [String: String]) -> String? {
        guard TerraformRootStore.shared.pluginCache == true, !AppEnvironment.terraformUserConfiguresCLI(shell: shell) else { return nil }
        let folder = AppEnvironment.terraformCacheDirectory
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return folder.path
    }

    /// The longest an init waits for its providers.
    static let initTimeout: TimeInterval = 300

    /// `init -backend=false` in `root`: its outcome. On a plugin cache, its
    /// turn taken as the panel's inits take it ("not concurrency safe").
    static func initialize(_ root: URL, cache: String?) async -> TerraformWorktreeRoot.Preparation {
        let registry = TerraformRunRegistry.shared
        let turn = cache.map { "cache:" + $0 }
        let id = "worktree-init-" + UUID().uuidString
        if let turn {
            var waited = 0
            while !registry.take(turn, id: id) {
                waited += 1
                // A prepare made again meanwhile takes the root over: not run, not failed.
                guard !Task.isCancelled else { return .waiting }
                guard waited < 600 else { return .failed("the provider cache stayed busy with another init") }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        defer { if let turn { registry.release(turn) } }
        let result = await TerraformEditorModel.run(
            TerraformCommands.initializeWithoutBackend, purpose: .worktreeInit(pluginCache: cache), in: root, timeout: initTimeout,
            interruptible: false)
        switch result {
        case .failure(.noTerraform): return .skipped("no terraform found — set Settings ▸ Terraform ▸ terraform, or install it.")
        case .failure(let failure): return .failed(TerraformPlan.scrub(failure.description))
        case .success(let run):
            if run.timedOut { return .failed("it took longer than \(Int(initTimeout)) s") }
            if run.status == 0 { return .ready }
            return .failed(TerraformPlan.scrub(TerraformEditorModel.firstError(run.stderr) ?? "terraform init exited \(run.status)"))
        }
    }
}
