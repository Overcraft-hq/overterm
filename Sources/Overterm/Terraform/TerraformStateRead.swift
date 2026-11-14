import Combine
import Foundation

/// One read of a root's state (analysis 2.4, 4.1, 5.6; stage 2c): `state
/// list` first — the addresses at once —, then `show -json` of the state,
/// decoded through `TerraformState`'s allow-list off the main thread, the
/// raw JSON dropped once read. Memory only: nothing of it is written
/// anywhere. Both are short reads (`TerraformRun.short`): they take no
/// lock and change nothing — but a workspace that doesn't exist is still
/// refused before either starts (4.9: `state pull` creates the one
/// `TF_WORKSPACE` names, spike 13), and a backend changed since init too.
///
/// A person's read runs in the user's environment (`Purpose.run`: a
/// remote backend's state needs its credentials, passed through unread);
/// an agent's (`tf_state_list`, `tf_state_show`, `tf_outputs`) in the
/// stripped one (`agentRead`), as every agent read is (5.10) — and of a
/// local backend only: initialising any other uses what its init record
/// holds, `-backend-config` credentials in clear (spike 4).
@MainActor
final class TerraformStateRead: ObservableObject, Identifiable {
    enum Phase: Equatable, Sendable {
        case preparing
        /// `state list` ran: the addresses are in; `show -json` reads the values.
        case listing
        case reading
        case read
        case failed(String)
        /// Refused before anything ran: why.
        case refused(String)
    }

    enum Reader: Equatable, Sendable {
        case person
        case agent
    }

    let id = "tfs-" + UUID().uuidString.prefix(8).lowercased()
    let checkout: URL
    let card: TerraformRootCard
    let reader: Reader
    /// `show -json` too; false: `state list` alone (`tf_state_list`, which starts no provider).
    let values: Bool
    @Published private(set) var phase: Phase = .preparing
    /// `state list`'s, then the decoded state's.
    @Published private(set) var addresses: [String] = []
    /// The addresses by module, and each address's object: built off the
    /// main thread when they come, so the view only filters (analysis 10 —
    /// 20,000 addresses grouped, and each row a linear search, on every
    /// keystroke, was the main thread's).
    @Published private(set) var groups: [TerraformStateRows.Group] = []
    private(set) var resources: [String: TerraformState.Resource] = [:]
    @Published private(set) var capped = false
    @Published private(set) var state: TerraformState?
    /// The workspace it read, as checked.
    @Published private(set) var workspace: String
    let started = Date()
    @Published private(set) var finished: Date?
    /// Where each resource's block is in the root's files (and its
    /// modules', through `modules.json`): "Open block", read once the state is.
    @Published private(set) var blocks: [String: TerraformCauseChain.Location] = [:]
    /// The view's: the resources open on their attributes, the modules folded.
    @Published var expanded: Set<String> = []
    @Published var folded: Set<String> = []
    /// The task `begin` started: cancelled by `stop`.
    private(set) var task: Task<Void, Never>?
    /// Stopped: whatever is still on its way is dropped.
    private(set) var stopped = false

    init(checkout: URL, card: TerraformRootCard, reader: Reader = .person, values: Bool = true) {
        self.checkout = checkout
        self.card = card
        self.reader = reader
        self.values = values
        self.workspace = card.workspace
    }

    var isGoing: Bool {
        switch phase {
        case .preparing, .listing, .reading: true
        default: false
        }
    }

    /// The workspace has no state yet: nothing to list.
    var isEmpty: Bool { phase == .read && addresses.isEmpty && (state?.outputs.isEmpty ?? true) }

    func age(now: Date = Date()) -> String {
        let seconds = Int(max(0, now.timeIntervalSince(finished ?? started)))
        if seconds < 60 { return "just now" }
        if seconds < 3_600 { return "\(seconds / 60) min ago" }
        return "\(seconds / 3_600) h ago"
    }

    /// Starts it in a task of its own, kept so `stop` can end it.
    /// `registry`, `binary`: a test's.
    func begin(settingPath: String, registry: TerraformRunRegistry = .shared, binary: URL? = nil) {
        task = Task { @MainActor [weak self] in await self?.start(registry: registry, settingPath: settingPath, binary: binary) }
    }

    /// Stops it, when it is still going: the slot closed, or another read
    /// took it. The terraform it runs is interrupted (`TerraformRun.short`),
    /// the decode and the blocks' scan never start, nothing lands after.
    func stop() {
        guard isGoing else { return }
        stopped = true
        task?.cancel()
        phase = .failed("Stopped before it finished. Read Again reads it.")
        finished = Date()
    }

    func refuse(_ why: String) {
        guard !stopped else { return }
        phase = .refused(why)
        finished = Date()
    }

    private func fail(_ why: String) {
        guard !stopped else { return }
        phase = .failed(TerraformPlan.scrub(why))
        finished = Date()
    }

    struct Prepared: Sendable {
        var facts: TerraformRootFacts
        var binary: URL?
        var base: [String: String]?
        var scratch: TerraformGuards.Scratch?
    }

    /// Runs it: checks, `state list`, `show -json`, decoded. `binary`: a
    /// test's terraform, in place of the one the setting resolves; `setup`
    /// New Task's, whose init in the root refuses it.
    func start(registry: TerraformRunRegistry = .shared, setup: TerraformWorktreeSetup = .shared, settingPath: String, binary given: URL? = nil) async {
        let root = card.folder
        let checkout = self.checkout
        let hasVersionFile = card.facts.hasVersionFile
        let prepared = await TerraformPanelModel.blocking { () -> Prepared in
            Prepared(
                facts: TerraformRootFacts.read(root: root, checkout: checkout),
                binary: given ?? TerraformCLI.binary(forRoot: root, settingPath: settingPath, hasVersionFile: hasVersionFile),
                base: try? AppEnvironment.terraformBaseEnvironment(),
                scratch: try? TerraformGuards.prepareScratch(at: AppEnvironment.terraformScratchDirectory))
        }
        guard !stopped else { return }
        // New Task's init without a backend writes this .terraform now (2b).
        if let why = setup.refusal(root) { return refuse(why) }
        let facts = prepared.facts
        guard let binary = prepared.binary else { return refuse("No terraform found: set Settings ▸ Terraform ▸ terraform, or install it.") }
        guard let base = prepared.base, let scratch = prepared.scratch else { return refuse("The environment for terraform couldn't be read.") }
        if let why = TerraformProcessCheck.refused(.stateList, rootClass: card.rootClass) { return refuse(why) }
        if reader == .agent, facts.backend.type != "local" {
            return refuse("An agent's read reaches only a local backend's state; this one is \(facts.backend.type)'s. The person's State read answers it.")
        }
        // A local state outside the checkout (`path`, `workspace_dir`, a link out) is never an agent's to read (5.10).
        if reader == .agent, let why = Self.agentLocalRefusal(backend: facts.backend, workspace: facts.workspace, root: root, checkout: checkout) {
            return refuse(why)
        }
        if TerraformStateIdentity.changedSinceInit(config: facts.config.backend, record: facts.initRecord) {
            return refuse("The backend changed since init: run init in a terminal (with -migrate-state or -reconfigure, as you mean it).")
        }
        let pinned = facts.workspace
        workspace = pinned
        // The workspace it reads exists (4.9), whichever file or variable names it.
        let backend = facts.backend
        var listed: [String]?
        let listKey = TerraformStateIdentity.of(backend: backend, workspace: "default", root: root)?.description ?? root.path
        if backend.type != "local", backend.workspaceName == nil {
            listed = registry.workspaceLists[listKey]
            if listed?.contains(pinned) != true {
                let environment = self.environment(base: base, workspace: nil, root: root, scratch: scratch)
                let result = try? await TerraformRun.short(binary, TerraformCommands.workspaceList, in: root, environment: environment, timeout: 60)
                guard !stopped else { return }
                if let result, result.status == 0 {
                    listed = TerraformWorkspaceCheck.parseList(String(decoding: result.stdout, as: UTF8.self))
                    registry.workspaceLists[listKey] = listed
                } else if pinned != "default" {
                    return refuse("Workspace \(pinned) can't be checked: terraform workspace list failed.")
                }
            }
        }
        if let why = TerraformWorkspaceCheck.refusal(workspace: pinned, backend: backend, localWorkspaces: facts.localWorkspaces, listed: listed) {
            return refuse(why)
        }
        let environment = self.environment(base: base, workspace: pinned, root: root, scratch: scratch)
        phase = .listing
        let listing: TerraformRun.Result
        do {
            listing = try await TerraformRun.short(binary, TerraformCommands.stateList, in: root, environment: environment, timeout: 60, limit: 4 << 20)
        } catch {
            return fail("\(error)")
        }
        guard !stopped else { return }
        guard listing.status == 0 else {
            return fail("terraform state list failed: " + (TerraformEditorModel.firstError(listing.stderr) ?? "exit \(listing.status)"))
        }
        let parsed = TerraformStateList.parse(String(decoding: listing.stdout, as: UTF8.self))
        let arrangedList = await TerraformPanelModel.blocking { Self.arrange(parsed.addresses, state: nil) }
        guard !stopped else { return }
        addresses = arrangedList.addresses
        groups = arrangedList.groups
        capped = parsed.capped || listing.truncated
        guard values else {
            phase = .read
            finished = Date()
            return
        }
        phase = .reading
        let secretName: @Sendable (String) -> Bool = reader == .agent ? TerraformSecretNames.forAgents : TerraformSecretNames.isSecret
        let read = await Self.show(binary, in: root, environment: environment, secretName: secretName)
        guard !stopped else { return }
        switch read {
        case .failure(let failure): fail(failure.message)
        case .success(let state):
            let listedAddresses = addresses
            let listedCapped = capped
            let arranged = await TerraformPanelModel.blocking { Self.arrange(state, listed: listedAddresses, listedCapped: listedCapped) }
            guard !stopped else { return }
            landed(state, arranged: arranged)
            guard reader == .person else { return }
            let prefix = card.path.isEmpty ? "" : card.path + "/"
            let found = await TerraformPanelModel.blocking { TerraformPlanPaneModel.sources(folder: root, prefix: prefix, varFiles: []).blocks }
            guard !stopped else { return }
            blocks = found
        }
    }

    /// The state read: its own addresses (a deposed object listed once), done at `date`.
    func landed(_ state: TerraformState, at date: Date = Date(), arranged given: Arranged? = nil) {
        let arranged = given ?? Self.arrange(state, listed: addresses, listedCapped: capped)
        self.state = state
        addresses = arranged.addresses
        groups = arranged.groups
        resources = arranged.resources
        capped = capped || state.capped
        phase = .read
        finished = date
    }

    /// What the view draws from: the addresses, grouped, and each one's object.
    struct Arranged: Sendable {
        var addresses: [String]
        var groups: [TerraformStateRows.Group]
        var resources: [String: TerraformState.Resource]
    }

    /// The state's own addresses, unless either list was cut short (then
    /// `state list`'s stay); each address's object, the current one before
    /// a deposed one (`TerraformState.resource`). Pure: off the main thread.
    /// Why an agent's own read of a local backend's state is refused: the
    /// files it reads — `path` (default `terraform.tfstate`),
    /// `workspace_dir` (default `terraform.tfstate.d`), the workspace's
    /// state — resolved through every symlink, land outside `checkout`
    /// (5.10: a tf_ tool stays inside the pane's checkout, realpath, no link
    /// out). An agent can write the backend block and the init record both.
    /// Nil: all inside. Blocking file reads (realpath), bounded.
    nonisolated static func agentLocalRefusal(backend: TerraformConfigFacts.Backend, workspace: String, root: URL, checkout: URL) -> String? {
        guard backend.type == "local" else { return nil }
        let settings = backend.settings
        let named = [settings["path"] ?? "terraform.tfstate", settings["workspace_dir"] ?? "terraform.tfstate.d"]
        let refusal =
            "its local state is outside the checkout (\(TerraformStateIdentity.summary(of: backend, workspace: workspace))), which an agent's read never reaches. Ask the person to open State in Overterm's Terraform panel: tf_ tools then answer from what they read, for 15 minutes."
        guard let top = physical(checkout) else { return refusal }
        for path in named where path.isEmpty || path.hasPrefix("~") || path.contains("${") { return refusal }
        let files =
            named.map { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : root.appendingPathComponent($0) }
            + [TerraformStateIdentity.localStatePath(backend: backend, workspace: workspace, root: root)]
        for file in files {
            guard let resolved = physical(file), resolved == top || resolved.hasPrefix(top + "/") else { return refusal }
        }
        return nil
    }

    /// `url` as the system reaches it: its longest existing part through
    /// realpath (every link, `..` taken physically), the rest — which
    /// doesn't exist yet — appended as written. Nil past 256 parts, or
    /// through a link whose target isn't there.
    nonisolated static func physical(_ url: URL) -> String? {
        let parts = url.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard parts.count <= 256 else { return nil }
        var count = parts.count
        while count >= 0 {
            let prefix = "/" + parts.prefix(count).joined(separator: "/")
            if let real = realpath(prefix, nil) {
                defer { free(real) }
                let base = String(cString: real)
                let rest = parts.dropFirst(count)
                guard !rest.isEmpty else { return base }
                return URL(fileURLWithPath: base).appendingPathComponent(rest.joined(separator: "/")).standardizedFileURL.path
            }
            // A link whose target isn't there: where it would write can't be said.
            var info = stat()
            if lstat(prefix, &info) == 0, info.st_mode & S_IFMT == S_IFLNK { return nil }
            count -= 1
        }
        return nil
    }

    nonisolated static func arrange(_ state: TerraformState, listed: [String], listedCapped: Bool) -> Arranged {
        var addresses = listed
        if !state.capped, !listedCapped {
            var seen = Set<String>()
            addresses = state.resources.map(\.address).filter { seen.insert($0).inserted }
        }
        return arrange(addresses, state: state)
    }

    nonisolated static func arrange(_ addresses: [String], state: TerraformState?) -> Arranged {
        var resources: [String: TerraformState.Resource] = [:]
        for resource in state?.resources ?? [] {
            if let kept = resources[resource.address], kept.deposed == nil || resource.deposed != nil { continue }
            resources[resource.address] = resource
        }
        return Arranged(addresses: addresses, groups: TerraformStateRows.groups(addresses), resources: resources)
    }

    /// The object at `address`: the current one, else a deposed one.
    func resource(_ address: String) -> TerraformState.Resource? { resources[address] }

    /// The block of `address` in the root's files: "Open block".
    func block(of address: String) -> TerraformCauseChain.Location? {
        blocks[address.replacingOccurrences(of: #"\[[^\]]*\]"#, with: "", options: .regularExpression)]
    }

    private func environment(base: [String: String], workspace: String?, root: URL, scratch: TerraformGuards.Scratch) -> [String: String] {
        switch reader {
        case .person:
            return TerraformEnvironment.build(base: base, purpose: .run(workspace: workspace, pluginCache: nil), root: root, scratch: scratch)
        case .agent:
            var environment = TerraformEnvironment.build(base: base, purpose: .agentRead, root: root, scratch: scratch)
            if let workspace { environment["TF_WORKSPACE"] = workspace }
            return environment
        }
    }

    /// `show -json` of the state, decoded off the main thread; the raw JSON dropped once read.
    nonisolated private static func show(_ binary: URL, in root: URL, environment: [String: String], secretName: @escaping @Sendable (String) -> Bool) async
        -> Result<TerraformState, TerraformReadFailure>
    {
        let shown: TerraformRun.Result
        do {
            shown = try await TerraformRun.short(
                binary, TerraformCommands.showState, in: root, environment: environment, timeout: 300, limit: TerraformStreamRun.maxPlanBytes)
        } catch {
            return .failure(.init(message: TerraformPlan.scrub("\(error)")))
        }
        guard !Task.isCancelled else { return .failure(.init(message: "Stopped before it finished.")) }
        guard shown.status == 0 else {
            return .failure(.init(message: "terraform show couldn't read the state: " + (TerraformEditorModel.firstError(shown.stderr) ?? "exit \(shown.status)")))
        }
        guard !shown.truncated else {
            return .failure(.init(message: "The state's JSON is over \(TerraformStreamRun.maxPlanBytes >> 20) MB: too large to show its values.", tooLarge: true))
        }
        let data = shown.stdout
        return await TerraformPanelModel.blocking { () -> Result<TerraformState, TerraformReadFailure> in
            do {
                return .success(try TerraformState.decode(data, scrub: TerraformPlan.scrub, secretName: secretName))
            } catch let error as TerraformState.DecodeError {
                return .failure(.init(message: error.description))
            } catch {
                return .failure(.init(message: "\(error)"))
            }
        }
    }
}

/// The app's state reads of this session, in memory (analysis 2.4, 5.6
/// rule 5): the last of each checkout's root, so the slot's view comes
/// back and an agent's `tf_` call can be answered from what the person
/// read (masked again for it) instead of reading once more.
@MainActor
final class TerraformStateReads: ObservableObject {
    static let shared = TerraformStateReads()
    static let keep = 24
    /// How long an agent is answered from the person's read.
    static let agentMaxAge: TimeInterval = 15 * 60

    @Published private(set) var reads: [TerraformStateRead] = []
    /// What an isolated run would have opened or added from an output
    /// (the scenarios' check): nothing of the user's is reached.
    var offerRecorder: ((TerraformOutputLinks.Offer) -> Void)?

    func add(_ read: TerraformStateRead) {
        reads.removeAll { $0.reader == read.reader && Self.same($0, read) }
        reads.append(read)
        if reads.count > Self.keep { reads.removeFirst(reads.count - Self.keep) }
    }

    /// The newest read of `root` in `checkout` by `reader`.
    func latest(checkout: URL, root: String, reader: TerraformStateRead.Reader? = nil) -> TerraformStateRead? {
        let path = checkout.resolvingSymlinksInPath().standardizedFileURL.path
        return reads.last {
            $0.card.path == root && $0.checkout.resolvingSymlinksInPath().standardizedFileURL.path == path && (reader == nil || $0.reader == reader)
        }
    }

    /// Forgets `root`'s reads by `reader`: tools then read for themselves
    /// (a scenario's check of the agent's own read).
    func forget(checkout: URL, root: String, reader: TerraformStateRead.Reader) {
        while let read = latest(checkout: checkout, root: root, reader: reader) { reads.removeAll { $0 === read } }
    }

    private static func same(_ a: TerraformStateRead, _ b: TerraformStateRead) -> Bool {
        a.card.path == b.card.path && a.checkout.resolvingSymlinksInPath().standardizedFileURL.path == b.checkout.resolvingSymlinksInPath().standardizedFileURL.path
    }
}
