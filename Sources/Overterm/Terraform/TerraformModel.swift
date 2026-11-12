import Combine
import Darwin
import Foundation

/// One plan Overterm made, in memory only (analysis 4.6): the masked
/// model, the plan file held by its descriptor and its SHA-256, the
/// absolute binary and its version, the run's whole environment as built
/// for the plan (what stage 2a's apply runs in, so the plan and its apply
/// can't target two places), the workspace and data dir, the prior
/// state's lineage and serial. Never written anywhere; the descriptor
/// closes when the record goes.
struct TerraformPlanRecord: Sendable {
    var plan: TerraformPlan
    var file: TerraformPlanFile
    var binary: URL
    var version: String?
    var environment: [String: String]
    var dataDir: String
    var workspace: String
    var zip: TerraformPlanZip?
    /// 0: no changes; 2: changes.
    var status: Int32
    /// The values the plan marks sensitive, for what its apply prints in
    /// clear (5.6): provisioner output, an error's detail. Memory only.
    var mask: TerraformValueMask = .none
}

/// The app's one register of Overterm's Terraform runs (analysis 3.6): one
/// run per state identity at a time, a second waiting in a queue that
/// says so; the plans of this session, in memory; the writes to a state
/// seen since — a terraform apply typed in any pane — that make every
/// other plan of that state stale at once, before Terraform's own refusal;
/// what was asked this session (production's first plan, an agent's
/// first `tf_plan` per root); each remote backend's last `workspace list`.
@MainActor
final class TerraformRunRegistry: ObservableObject {
    static let shared = TerraformRunRegistry()

    struct StateWrite: Equatable, Sendable {
        /// The checkout the write came from (its folder's name).
        var worktree: String
        var at: Date
        var operation: String
    }

    @Published private(set) var stateWrites: [TerraformStateIdentity: StateWrite] = [:]
    /// The runs of this session, oldest first; at most `keep`, a dropped one's plan file closed.
    @Published private(set) var runs: [TerraformPlanRun] = []
    static let keep = 40
    /// The applies of this session (6.4, "a runs row in memory"): time, who
    /// started it, counts, result — and those followed again after a
    /// crash or a quit (4.7).
    @Published private(set) var applies: [TerraformApplyRun] = []

    /// Who holds each identity's turn, by its key; a waiting run's
    /// continuation, resumed true with the turn or false when it left the queue.
    private var holders: [String: String] = [:]
    private var waiting: [String: [(id: String, continuation: CheckedContinuation<Bool, Never>)]] = [:]
    /// Production roots planned this session: the first one asks (5.3).
    var productionPlanned: Set<String> = []
    /// Roots an agent's `tf_plan` was allowed on this session (D-12), with
    /// what their code ran or reached when the person said yes: a risk
    /// that isn't in it asks again (`TerraformPlanGate.agentAsks`).
    var agentAllowed: [String: Set<TerraformRunRisk>] = [:]
    /// Production roots whose writes are on for this session (5.3), by
    /// `sessionKey`: turned on from the root's card, asked, never by a
    /// setting; gone at quit.
    @Published var sessionWrites: Set<String> = []
    /// A remote backend's workspaces, by identity of its default workspace.
    var workspaceLists: [String: [String]] = [:]

    func add(_ run: TerraformPlanRun) {
        runs.append(run)
        if runs.count > Self.keep, let drop = runs.firstIndex(where: { !$0.isGoing }) { runs.remove(at: drop) }
    }

    func run(id: String) -> TerraformPlanRun? { runs.last { $0.id == id } }

    /// A root and workspace's key for its session switch (5.3).
    static func sessionKey(checkout: URL, root: String, workspace: String) -> String {
        TerraformRootStore.key(checkout: checkout, root: root) + "\u{0}" + workspace
    }

    func hasSessionWrites(checkout: URL, root: String, workspace: String) -> Bool {
        sessionWrites.contains(Self.sessionKey(checkout: checkout, root: root, workspace: workspace))
    }

    func addApply(_ apply: TerraformApplyRun) {
        applies.append(apply)
        if applies.count > Self.keep, let drop = applies.firstIndex(where: { !$0.isGoing }) { applies.remove(at: drop) }
    }

    /// Forgets an apply without touching its process: the scenario's
    /// crash, after `detach`.
    func forgetApply(_ apply: TerraformApplyRun) {
        apply.detach()
        applies.removeAll { $0 === apply }
        if holders[apply.key] == apply.id { release(apply.key) }
    }

    /// The applies still going, the app's: what quitting asks about.
    var goingApplies: [TerraformApplyRun] { applies.filter(\.isGoing) }

    /// The apply holding `key`'s turn, if one does.
    func applyHolder(of key: String) -> TerraformApplyRun? { holders[key].flatMap { id in applies.last { $0.id == id } } }

    /// Why a run on `key` can't go now — another holds its turn — or nil.
    func busy(_ key: String, except id: String? = nil) -> String? {
        guard let holder = holders[key], holder != id else { return nil }
        if let apply = applyHolder(of: key) { return "An apply of \(apply.marker.name) in \(apply.worktree) is running on this state." }
        if let run = run(id: holder) {
            return "The \(run.kind == .plan ? "plan" : "init") of \(run.card.name) in \(run.checkout.lastPathComponent) is running on this state."
        }
        return "Another run holds this state."
    }

    /// Takes `key`'s turn for `id` now, or false when another holds it: an
    /// apply never queues — it is pressed again.
    func take(_ key: String, id: String) -> Bool {
        guard holders[key] == nil else { return holders[key] == id }
        holders[key] = id
        return true
    }

    /// The newest plan run of `root` (its path in the checkout) in
    /// `checkout`; `drift`: its newest drift check instead (2d), never
    /// counted as its last plan.
    func latest(checkout: URL, root: String, kind: TerraformPlanRun.Kind = .plan, drift: Bool = false) -> TerraformPlanRun? {
        let path = checkout.standardizedFileURL.path
        return runs.last { $0.kind == kind && $0.mode.isRefreshOnly == drift && $0.card.path == root && $0.checkout.standardizedFileURL.path == path }
    }

    /// The run going on `key` now, if another one is.
    func holder(of key: String) -> TerraformPlanRun? { holders[key].flatMap { run(id: $0) } }

    /// Takes `key`'s turn for `run`, waiting while another holds it: true
    /// with the turn, false when the run left the queue (`cancelWaiting`)
    /// — it holds nothing then, and releases nothing.
    @discardableResult
    func acquire(_ key: String, for run: TerraformPlanRun) async -> Bool {
        if holders[key] == nil {
            holders[key] = run.id
            return true
        }
        return await withCheckedContinuation { continuation in waiting[key, default: []].append((run.id, continuation)) }
    }

    /// Gives `key`'s turn to the next run waiting.
    func release(_ key: String) {
        if var queue = waiting[key], !queue.isEmpty {
            let next = queue.removeFirst()
            waiting[key] = queue.isEmpty ? nil : queue
            holders[key] = next.id
            next.continuation.resume(returning: true)
        } else {
            holders[key] = nil
        }
    }

    /// Takes run `id` out of every queue it waits in, at once: its
    /// `acquire` answers false while the holder still holds.
    func cancelWaiting(_ id: String) {
        for (key, queue) in waiting {
            guard let index = queue.firstIndex(where: { $0.id == id }) else { continue }
            var rest = queue
            let entry = rest.remove(at: index)
            waiting[key] = rest.isEmpty ? nil : rest
            entry.continuation.resume(returning: false)
        }
    }

    /// Whether run `id` waits for a turn.
    func isWaiting(_ id: String) -> Bool { waiting.values.contains { $0.contains { $0.id == id } } }

    /// A terraform write to `identity` was seen — a pane's apply, destroy,
    /// import or state change — from `worktree`: every plan of it made
    /// before is stale.
    func stateWritten(_ identity: TerraformStateIdentity, by worktree: String, operation: String, at date: Date = Date()) {
        if let known = stateWrites[identity], abs(known.at.timeIntervalSince(date)) < 5, known.worktree == worktree { return }
        stateWrites[identity] = StateWrite(worktree: worktree, at: date, operation: operation)
    }

    /// Forgets a run: its plan file closes with it.
    func discard(_ run: TerraformPlanRun) {
        run.stop()
        runs.removeAll { $0 === run }
    }
}

/// One run of Overterm's in a root: a plan (analysis 4.3–4.6) or an init
/// (4.13). In the app's process group, its stream read as it comes, its
/// log in memory only (2,000 lines, scrubbed); the plan's JSON decoded
/// through the allow-list off the main thread, then dropped. A plan that
/// exited 0 or 2 is held by its descriptor in `record`.
@MainActor
final class TerraformPlanRun: ObservableObject, Identifiable {
    enum Kind: String, Sendable { case plan, initialize }

    enum Phase: Equatable, Sendable {
        case preparing
        case waiting(String)
        case running
        /// A plan with changes (exit 2), or an init done.
        case planned
        case noChanges
        case failed(String)
        /// Refused before anything ran: why.
        case refused(String)
        case stopped
        /// Planned (exit 0 or 2), but the plan is past `maxPlanBytes`:
        /// the stream's counts only, in words (Section 10).
        case tooLarge(String)
    }

    static let maxLog = 2_000
    /// A plan older than this greys Apply (5.4 check 5, `terraform.planMaxAgeMinutes`).
    static let maxAge: TimeInterval = 30 * 60

    let id: String
    let kind: Kind
    let checkout: URL
    let card: TerraformRootCard
    /// Who asked, when an agent's `tf_plan` did: its tab and agent.
    let agent: String?
    let lockWait: TerraformCommands.LockWait
    let varFiles: [String]
    let pluginCache: String?
    /// Destroy, only some addresses, some replaced (2a): said in the header.
    let mode: TerraformPlanMode
    /// The checkout's branch @ commit, as the chip says it.
    let branch: String?
    /// What its code runs or reaches (5.4), listed in the header.
    var risks: [TerraformRunRisk] = []
    /// The lines of the root's files this branch added (`git diff -U0
    /// <merge base>`), by path in the checkout: what "changed in this
    /// branch" reads, whatever the changes pane shows (3.1).
    var changedLines: [String: Set<Int>] = [:]

    @Published private(set) var phase: Phase = .preparing
    @Published private(set) var log: [String] = []
    @Published private(set) var refreshed = 0
    @Published private(set) var plannedChanges = 0
    @Published private(set) var diagnostics: [TerraformDiagnostic] = []
    @Published private(set) var lock: TerraformLockInfo?
    @Published private(set) var record: TerraformPlanRecord?
    /// Its apply (6.4): the plan view becomes its progress in place.
    @Published var apply: TerraformApplyRun?
    /// A file of its root changed after it finished.
    @Published var configChanged = false
    @Published private(set) var workspace: String
    let started = Date()
    @Published private(set) var finished: Date?
    /// The run's inputs (2.2): the auto-loaded var files, the `TF_VAR_`
    /// names in its environment (never values), the profile's and region's names.
    private(set) var autoVarFiles: [String] = []
    private(set) var variableNames: [String] = []
    private(set) var profile: String?
    private(set) var region: String?
    /// The identity it plans, once its workspace was checked.
    private(set) var identity: TerraformStateIdentity?
    /// "The lock is held by this Mac, and no Terraform runs here": said (4.10).
    @Published private(set) var lockNote: String?
    /// The root's var files a failed plan offers (2.2), read off the main thread with the run.
    @Published private(set) var offeredVarFiles: [String] = []
    /// `change_summary`'s counts from the stream: all a plan past `maxPlanBytes` shows.
    private(set) var streamSummary: (add: Int, change: Int, remove: Int, importing: Int)?
    private var pid: pid_t?
    private var stopping = false
    private weak var registry: TerraformRunRegistry?

    init(
        kind: Kind, checkout: URL, card: TerraformRootCard, agent: String? = nil, lockWait: TerraformCommands.LockWait = .person, varFiles: [String] = [],
        pluginCache: String? = nil, branch: String? = nil, mode: TerraformPlanMode = .normal
    ) {
        self.id = "tf-" + UUID().uuidString.prefix(8).lowercased()
        self.mode = mode
        self.kind = kind
        self.checkout = checkout
        self.card = card
        self.agent = agent
        self.lockWait = lockWait
        self.varFiles = varFiles
        self.pluginCache = pluginCache
        self.branch = branch
        self.workspace = card.workspace
        self.identity = card.identity
    }

    var isGoing: Bool {
        switch phase {
        case .preparing, .waiting, .running: true
        default: false
        }
    }

    var plan: TerraformPlan? { record?.plan }

    /// The plan's stream warned that provider development overrides are on (4.5).
    var devOverrides: Bool { TerraformApplyCheck.hasDevOverrides(diagnostics) }

    /// Its plan applied (or its apply started): the record and its
    /// descriptor dropped — a plan is applied once (6.4).
    func dropRecord() { record = nil }

    /// The root's class decided now, by the same classifier, settings and
    /// sticky identities as a card's, over `facts` (the plan's own when
    /// nil): what an apply is guarded as, never the card's alone (5.1).
    func classNow(_ classing: Classing, facts: TerraformRootFacts? = nil) -> TerraformClassifier.Verdict {
        TerraformRootCard.verdict(
            path: card.path, folder: card.folder, facts: facts ?? card.facts, workspace: workspace, varFiles: autoVarFiles, awsProfile: profile,
            terragruntTree: card.terragruntTree, settings: classing.settings, productionIdentities: classing.identities
        ).0
    }

    /// Why Apply is greyed now (6.4), or nil: what needs nothing read.
    func applyGreyed(_ registry: TerraformRunRegistry, writable: Bool, now: Date = Date(), classing: Classing? = nil) -> String? {
        if apply != nil { return "Applied: plan again for another apply." }
        if let why = TerraformApplyCheck.risen(name: card.name, planned: card.rootClass, now: classNow(classing ?? .current)) { return why }
        let sessionWrites = registry.hasSessionWrites(checkout: checkout, root: card.path, workspace: workspace)
        let key = identity?.description ?? card.folder.path
        return TerraformApplyCheck.greyed(
            plan: plan, rootClass: card.rootClass, writable: writable, sessionWrites: sessionWrites, mode: mode, devOverrides: devOverrides,
            staleReason: staleReason(registry, now: now), busy: registry.busy(key))
    }

    /// The variables a failed plan said have no value: offered the root's var files (2.2).
    var missingVariables: [String] {
        diagnostics.filter { $0.summary == "No value for required variable" }.compactMap { diagnostic in
            diagnostic.detail.range(of: #"variable "([^"]+)""#, options: .regularExpression).map {
                String(diagnostic.detail[$0].dropFirst("variable \"".count).dropLast())
            }
        }
    }

    /// Why the plan on screen isn't what applying would do now, or nil
    /// (6.3: "envs/prod changed after this plan", "applied from `bump-eks`").
    /// A plan no longer held (applied, discarded) has nothing to apply —
    /// unless `held` is false: what a drift check found is "then" once its
    /// own Accept wrote the state (2.6).
    func staleReason(_ registry: TerraformRunRegistry, now: Date = Date(), held: Bool = true) -> String? {
        guard kind == .plan, let finished, record != nil || !held else { return nil }
        if let identity, let write = registry.stateWrites[identity], write.at > finished {
            return "\(write.operation) from \(write.worktree) at \(Self.clock(write.at)): plan again"
        }
        if configChanged { return "\(card.name) changed after this plan: plan again" }
        if now.timeIntervalSince(finished) > Self.maxAge { return "older than 30 minutes: plan again" }
        return nil
    }

    static func clock(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    /// "2 min ago".
    func age(now: Date = Date()) -> String {
        let seconds = Int(max(0, now.timeIntervalSince(finished ?? started)))
        if seconds < 60 { return "just now" }
        if seconds < 3_600 { return "\(seconds / 60) min ago" }
        return "\(seconds / 3_600) h ago"
    }

    /// Stops it: one SIGINT to its group (D-3), or out of the queue at
    /// once — a run waiting for another's turn ends while that one holds.
    func stop() {
        guard isGoing else { return }
        stopping = true
        if let pid { TerraformStreamRun.interrupt(pid) }
        if let registry, registry.isWaiting(id) { registry.cancelWaiting(id) }
    }

    func refuse(_ why: String) {
        phase = .refused(why)
        finished = Date()
        appendLog("Refused: " + why)
    }

    private func appendLog(_ line: String) {
        log.append(TerraformPlan.scrub(line))
        if log.count > Self.maxLog { log.removeFirst(log.count - Self.maxLog) }
    }

    func absorb(_ messages: [TerraformUIMessage]) {
        var lines: [String] = []
        for message in messages {
            switch message {
            case .refresh(_, let done): if done { refreshed += 1 }
            case .plannedChange: plannedChanges += 1
            case .summary(let add, let change, let remove, let importing, let operation):
                if operation == "plan" { streamSummary = (add, change, remove, importing) }
            case .diagnostic(let diagnostic):
                diagnostics.append(diagnostic)
                if lock == nil, let parsed = TerraformLockInfo.parse(summary: diagnostic.summary, detail: diagnostic.detail) { lock = parsed }
            default: break
            }
            lines.append(message.logLine)
        }
        log.append(contentsOf: lines)
        if log.count > Self.maxLog { log.removeFirst(log.count - Self.maxLog) }
    }

    fileprivate func began(_ pid: pid_t) {
        self.pid = pid
        if stopping { TerraformStreamRun.interrupt(pid) }
    }

    // MARK: The run

    struct Prepared: Sendable {
        var facts: TerraformRootFacts
        var names: [String]
        var binary: URL?
        var base: [String: String]?
        var scratch: TerraformGuards.Scratch?
    }

    /// What the class is decided from now, taken on the main thread:
    /// the same classifier, settings and sticky identities as the card's.
    struct Classing: Sendable {
        var settings: TerraformClassSettings
        var identities: Set<TerraformStateIdentity>

        @MainActor static var current: Classing { Classing(settings: .current, identities: TerraformRootStore.shared.productionIdentities) }
    }

    /// Runs it: checks, the queue, the process, the plan read as data.
    func start(registry: TerraformRunRegistry = .shared, settingPath: String, classing: Classing? = nil) async {
        self.registry = registry
        let root = card.folder
        let checkout = self.checkout
        let hasVersionFile = card.facts.hasVersionFile
        let classing = classing ?? .current
        let prepared = await TerraformPanelModel.blocking { () -> Prepared in
            let facts = TerraformRootFacts.read(root: root, checkout: checkout)
            let names = Array(((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).prefix(TerraformRootGuess.maxFilesPerFolder))
            let binary = TerraformCLI.binary(forRoot: root, settingPath: settingPath, hasVersionFile: hasVersionFile)
            let base = try? AppEnvironment.terraformBaseEnvironment()
            let scratch = try? TerraformGuards.prepareScratch(at: AppEnvironment.terraformScratchDirectory)
            return Prepared(facts: facts, names: names, binary: binary, base: base, scratch: scratch)
        }
        guard !stopping else { return finish(.stopped) }
        // New Task's init without a backend writes this .terraform now (2b).
        if TerraformWorktreeSetup.shared.isInitializing(root) {
            return refuse("New Task is initialising this root without its backend: press again once it is done.")
        }
        let facts = prepared.facts
        let folder = TerraformRootFolder(path: card.path, kind: .root, files: prepared.names)
        autoVarFiles = folder.autoVarFiles
        offeredVarFiles = Self.offered(prepared.names)
        // HCP's roots run there, not here (2.8, D-20).
        if let why = TerraformProcessCheck.refused(kind == .plan ? .plan : .initialize, backendType: facts.backend.type) { return refuse(why) }
        // What is planned is what the root says now: its workspace, its
        // backend and its class decided again, never the card's alone.
        if let why = changedSinceCard(facts, varFiles: folder.autoVarFiles, profile: prepared.base?["AWS_PROFILE"], classing: classing) { return refuse(why) }
        guard let binary = prepared.binary else { return refuse("No terraform found: set Settings ▸ Terraform ▸ terraform, or install it.") }
        guard let base = prepared.base, let scratch = prepared.scratch else { return refuse("The environment for terraform couldn't be read.") }
        workspace = facts.workspace
        identity = TerraformStateIdentity.of(backend: facts.backend, workspace: facts.workspace, root: root)
        if TerraformStateIdentity.changedSinceInit(config: facts.config.backend, record: facts.initRecord) {
            return refuse("The backend changed since init: run init in a terminal (with -migrate-state or -reconfigure, as you mean it).")
        }
        variableNames = TerraformEnvironment.variableNames(in: base)
        profile = base["AWS_PROFILE"].flatMap { $0.isEmpty ? nil : $0 }
        region = (base["AWS_REGION"] ?? base["AWS_DEFAULT_REGION"]).flatMap { $0.isEmpty ? nil : $0 }
        let pinned = kind == .plan || facts.workspaceFromFile ? facts.workspace : nil
        // Every run checks its workspace exists first (4.9).
        if let pinned {
            let backend = facts.backend
            var listed: [String]?
            let listKey = TerraformStateIdentity.of(backend: backend, workspace: "default", root: root)?.description ?? root.path
            if backend.type != "local", backend.workspaceName == nil {
                listed = registry.workspaceLists[listKey]
                if listed?.contains(pinned) != true {
                    let environment = TerraformEnvironment.build(base: base, purpose: .run(workspace: nil, pluginCache: nil), root: root, scratch: scratch)
                    let result = await Self.short(binary, TerraformCommands.workspaceList, in: root, environment: environment)
                    if let result, result.status == 0 {
                        listed = TerraformWorkspaceCheck.parseList(String(decoding: result.stdout, as: UTF8.self))
                        registry.workspaceLists[listKey] = listed
                    } else if pinned != "default" {
                        return refuse("Workspace \(pinned) can't be checked: terraform workspace list failed" + (kind == .initialize ? " — run init in a terminal." : "."))
                    }
                }
            }
            if let why = TerraformWorkspaceCheck.refusal(workspace: pinned, backend: backend, localWorkspaces: facts.localWorkspaces, listed: listed) {
                return refuse(why)
            }
        }
        let environment = TerraformEnvironment.build(
            base: base, purpose: .run(workspace: pinned, pluginCache: pluginCache), root: root, scratch: scratch)
        // One run per state at a time, app-wide; inits one at a time per plugin cache.
        let key = kind == .initialize && pluginCache != nil ? "cache:" + (pluginCache ?? "") : (identity?.description ?? root.path)
        guard await waitTurn(key, registry: registry) else { return }
        defer { registry.release(key) }
        guard !stopping else { return finish(.stopped) }
        phase = .running
        switch kind {
        case .initialize:
            let outcome = await Self.stream(binary, TerraformCommands.initialize, in: root, environment: environment, planFile: nil, run: self)
            switch outcome {
            case .failure(let error): return finish(.failed(TerraformPlan.scrub("\(error)")))
            case .success(let result):
                if stopping { return finish(.stopped) }
                if result.status != 0 { return finish(.failed(failureText(result.stderr))) }
                TerraformWorktreeSetup.shared.forget(checkout: checkout, root: card.path)
                finish(.planned)
            }
        case .plan:
            let folder: URL
            do { folder = try TerraformRunFolder.makeRun() } catch { return refuse("\(error)") }
            defer { TerraformRunFolder.remove(folder) }
            let planFile = folder.appendingPathComponent("plan")
            guard let arguments = TerraformCommands.plan(out: planFile.path, varFiles: varFiles, lock: lockWait, mode: mode) else {
                return refuse("A var file outside the root, or an address that isn't one, can't be passed: \(varFiles.joined(separator: ", "))")
            }
            let outcome = await Self.stream(binary, arguments, in: root, environment: environment, planFile: planFile, run: self)
            let result: TerraformStreamRun.Outcome
            switch outcome {
            case .failure(let error): return finish(.failed(TerraformPlan.scrub("\(error)")))
            case .success(let got): result = got
            }
            if stopping, result.status != 0, result.status != 2 { return finish(.stopped) }
            if result.status == 0 || result.status == 2, result.tooLarge { return finish(.tooLarge(tooLargeText())) }
            guard result.status == 0 || result.status == 2, let file = result.file else {
                noteLockOnThisMac()
                return finish(.failed(failureText(result.stderr)))
            }
            let read = await Self.read(binary, in: root, environment: environment, file: file)
            switch read {
            case .failure(let why): return finish(why.tooLarge ? .tooLarge(tooLargeText()) : .failed(why.message))
            case .success(let pair):
                TerraformWorktreeSetup.shared.forget(checkout: checkout, root: card.path)
                landed(
                    TerraformPlanRecord(
                        plan: pair.plan, file: file, binary: binary, version: pair.plan.terraformVersion, environment: environment,
                        dataDir: environment["TF_DATA_DIR"] ?? root.appendingPathComponent(".terraform").path, workspace: pinned ?? "default", zip: pair.zip,
                        status: result.status, mask: pair.mask))
            }
        }
    }

    /// Takes `key`'s turn in `registry`, saying whose run it waits for:
    /// false — and stopped — when `stop()` took it out of the queue first.
    func waitTurn(_ key: String, registry: TerraformRunRegistry) async -> Bool {
        self.registry = registry
        if let other = registry.holder(of: key) {
            phase = .waiting("Waiting for the \(other.kind == .plan ? "plan" : "init") of \(other.card.name) in \(other.checkout.lastPathComponent)")
        } else if let apply = registry.applyHolder(of: key) {
            phase = .waiting("Waiting for the apply of \(apply.marker.name) in \(apply.worktree)")
        }
        guard await registry.acquire(key, for: self) else {
            finish(.stopped)
            return false
        }
        return true
    }

    private func finish(_ phase: Phase) {
        self.phase = phase
        finished = Date()
    }

    /// The plan read: held, and the run done at `date`.
    func landed(_ record: TerraformPlanRecord, at date: Date = Date()) {
        self.record = record
        phase = record.status == 0 ? .noChanges : .planned
        finished = date
    }

    /// The stream's counts and why there is nothing more (Section 10).
    func tooLargeText() -> String {
        let limit = "over \(TerraformStreamRun.maxPlanBytes >> 20) MB"
        guard let counts = streamSummary else { return "Planned, but the plan is \(limit): too large to show attribute diffs." }
        let importing = counts.importing > 0 ? "\(counts.importing) to import, " : ""
        return "Plan: \(importing)\(counts.add) to add, \(counts.change) to change, \(counts.remove) to destroy. The plan is \(limit): too large to show attribute diffs."
    }

    /// The var files a failed plan offers: the root's own, not those it loads anyway.
    nonisolated static func offered(_ names: [String]) -> [String] {
        names.filter { ($0.hasSuffix(".tfvars") || $0.hasSuffix(".tfvars.json")) && !$0.hasSuffix(".auto.tfvars") && !$0.hasSuffix(".auto.tfvars.json") }
            .filter { $0 != "terraform.tfvars" && $0 != "terraform.tfvars.json" }.sorted()
    }

    /// Why the root, read again now, isn't what its card said when the
    /// person (or the agent) chose it, or nil: another workspace selected
    /// since (`terraform workspace select prod` in a pane of the
    /// worktree), its backend edited, or its class now production where
    /// the card's wasn't. An agent never plans production (D-12).
    func changedSinceCard(_ facts: TerraformRootFacts, varFiles: [String], profile: String?, classing: Classing) -> String? {
        let root = card.folder
        let identity = TerraformStateIdentity.of(backend: facts.backend, workspace: facts.workspace, root: root)
        if facts.workspace != card.workspace {
            // A workspace that doesn't exist says so first: that is the trap (4.9).
            if facts.backend.type == "local",
                let why = TerraformWorkspaceCheck.refusal(workspace: facts.workspace, backend: facts.backend, localWorkspaces: facts.localWorkspaces, listed: nil)
            {
                return why
            }
            return "\(card.name)'s workspace is now \(facts.workspace), not \(card.workspace) as when it was chosen: look at it again, then plan."
        }
        if identity != card.identity {
            return "\(card.name)'s backend changed since it was chosen: look at it again, then plan."
        }
        let (verdict, _) = TerraformRootCard.verdict(
            path: card.path, folder: root, facts: facts, varFiles: varFiles, awsProfile: profile.flatMap { $0.isEmpty ? nil : $0 },
            terragruntTree: card.terragruntTree, settings: classing.settings, productionIdentities: classing.identities)
        guard verdict.rootClass == .production else { return nil }
        if agent != nil { return "\(card.name) is production now (\(verdict.reason)): an agent doesn't plan it — the person does, from Overterm's Terraform panel." }
        if !card.isProduction { return "\(card.name) is production now (\(verdict.reason)): plan it again from the panel, which asks first." }
        return nil
    }

    private func failureText(_ stderr: String) -> String {
        if let lock { return lock.said() }
        if let error = diagnostics.first(where: { $0.severity == .error }) { return error.summary }
        let first = stderr.split(separator: "\n").first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return first.map { String($0.prefix(300)) } ?? "terraform failed"
    }

    private func noteLockOnThisMac() {
        guard let lock, lock.isThisMac() else { return }
        let root = card.folder.standardizedFileURL.path
        let running = TerraformPaneMonitor.shared.processes.values.joined().contains { $0.folder?.standardizedFileURL.path == root }
        if !running {
            lockNote = "No terraform in Overterm's panes runs in \(card.name)" + (lock.age().map { "; the lock is \($0) old" } ?? "") + "."
        }
    }

    // MARK: Off the main thread

    /// Builds, off any actor, what a run's thread hands back on the main one.
    nonisolated private static func hand(_ run: TerraformPlanRun) -> (pid: @Sendable (pid_t) -> Void, batch: @Sendable ([TerraformUIMessage]) -> Void) {
        let pid: @Sendable (pid_t) -> Void = { pid in DispatchQueue.main.async { MainActor.assumeIsolated { run.began(pid) } } }
        let batch: @Sendable ([TerraformUIMessage]) -> Void = { messages in DispatchQueue.main.async { MainActor.assumeIsolated { run.absorb(messages) } } }
        return (pid, batch)
    }

    nonisolated private static func stream(
        _ binary: URL, _ arguments: [String], in root: URL, environment: [String: String], planFile: URL?, run: TerraformPlanRun
    ) async -> Result<TerraformStreamRun.Outcome, Error> {
        let handlers = hand(run)
        let result = await withCheckedContinuation { (continuation: CheckedContinuation<Result<TerraformStreamRun.Outcome, Error>, Never>) in
            let work: @Sendable () -> Void = {
                continuation.resume(
                    returning: Result {
                        try TerraformStreamRun.run(
                            binary, arguments, in: root, environment: environment, planFile: planFile, started: handlers.pid, batch: handlers.batch)
                    })
            }
            DispatchQueue.global(qos: .userInitiated).async(execute: work)
        }
        // The last batches were queued on the main queue before this: let them land.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let done: @Sendable () -> Void = { continuation.resume() }
            DispatchQueue.main.async(execute: done)
        }
        return result
    }

    nonisolated private static func short(_ binary: URL, _ arguments: [String], in root: URL, environment: [String: String]) async -> TerraformRun.Result? {
        try? await TerraformRun.short(binary, arguments, in: root, environment: environment, timeout: 60)
    }

    struct Read: Sendable {
        var plan: TerraformPlan
        var zip: TerraformPlanZip?
        var mask: TerraformValueMask
    }

    /// `show -json /dev/fd/3` of the held plan, decoded through the
    /// allow-list off the main thread; the raw JSON dropped once read.
    nonisolated private static func read(_ binary: URL, in root: URL, environment: [String: String], file: TerraformPlanFile) async -> Result<
        Read, TerraformReadFailure
    > {
        await TerraformPanelModel.blocking { () -> Result<Read, TerraformReadFailure> in
            let shown: TerraformRun.Result
            do {
                shown = try TerraformRun.runBlocking(
                    binary, TerraformCommands.showPlanDescriptor, in: root, environment: environment, input: nil, timeout: 300, file: file.descriptor,
                    limit: TerraformStreamRun.maxPlanBytes)
            } catch {
                return .failure(.init(message: TerraformPlan.scrub("\(error)")))
            }
            guard shown.status == 0 else {
                return .failure(
                    .init(message: "terraform show couldn't read the plan: " + (TerraformEditorModel.firstError(shown.stderr) ?? "exit \(shown.status)")))
            }
            guard !shown.truncated else {
                return .failure(
                    .init(message: "The plan's JSON is over \(TerraformStreamRun.maxPlanBytes >> 20) MB: too large to show attribute diffs.", tooLarge: true))
            }
            do {
                guard let object = try? JSONSerialization.jsonObject(with: shown.stdout, options: [.fragmentsAllowed]) as? [String: Any] else {
                    throw TerraformPlan.DecodeError.notJSON
                }
                // The sensitive values, read once: the decode masks by them,
                // and the apply masks what it prints in clear (5.6).
                let secrets = TerraformSensitiveValues(TerraformPlan.sensitiveValues(in: object))
                let plan = try TerraformPlan.decode(object, scrub: TerraformPlan.scrub, secrets: secrets)
                return .success(Read(plan: plan, zip: TerraformPlanZip.read(descriptor: file.descriptor), mask: TerraformValueMask(secrets)))
            } catch {
                return .failure(.init(message: "\(error)"))
            }
        }
    }
}

/// Why a plan couldn't be read, in words.
struct TerraformReadFailure: Error, Sendable {
    var message: String
    /// Past `maxPlanBytes`: the run planned, there is only too much to show.
    var tooLarge = false
}
