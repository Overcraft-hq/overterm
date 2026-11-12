import Combine
import Foundation

/// Which checkouts have Terraform roots, as the rail found them: the pane
/// header walks the process trees of a checkout's panes only while it may
/// (3.2) — a checkout read and found to have none is never walked. One for
/// the app; in memory.
@MainActor
final class TerraformCheckouts {
    static let shared = TerraformCheckouts()
    private var known: [String: Bool] = [:]

    private var settling: Set<String> = []

    func record(_ checkout: URL, hasRoots: Bool) { known[checkout.standardizedFileURL.path] = hasRoots }

    /// Unknown again: a Terraform file appeared or went (`TerraformPanelModel.filesChanged`).
    func forget(_ checkout: URL) { known[checkout.standardizedFileURL.path] = nil }

    /// Settles whether `checkout` has roots, once, by the panel's own
    /// listing (one bounded `git ls-files` of the patterns, 2.1's budget —
    /// no file read): the pane header walks only checkouts that do (3.2),
    /// whether or not the panel was ever shown. A folder that isn't a
    /// repository has none.
    func settle(_ checkout: URL) {
        let key = checkout.standardizedFileURL.path
        guard known[key] == nil, settling.insert(key).inserted else { return }
        Task { [weak self] in
            let listing = await TerraformRootScan.list(checkout)
            guard let self else { return }
            self.settling.remove(key)
            // The panel's read may have landed meanwhile: it knows more.
            guard self.known[key] == nil else { return }
            self.known[key] = listing.map(Self.mayHaveRoots) ?? false
        }
    }

    /// A listing with a configuration or Terragrunt's file somewhere: roots,
    /// as far as the header cares — the guess's finer kinds are the panel's.
    nonisolated static func mayHaveRoots(_ listing: TerraformRootScan.Listing) -> Bool {
        listing.folders.values.contains { files in files.contains { TerraformRootGuess.isConfigFile($0) || $0.hasSuffix("terragrunt.hcl") } }
    }

    /// False only when it was read and has none; nil when never read.
    func hasRoots(_ checkout: URL?) -> Bool? {
        guard let checkout else { return nil }
        return known[checkout.standardizedFileURL.path]
    }

    /// Every checkout read that has roots, for the switcher.
    var checkoutsWithRoots: [String] { known.filter(\.value).map(\.key).sorted() }
}

/// Another worktree of the checkout's repository, as the window's
/// `WorktreeModel` lists it — the panel never asks git a second time (CLAUDE.md).
struct TerraformWorktree: Equatable, Sendable {
    var url: URL
    var name: String

    /// The worktrees of `listed` other than `checkout`: none bare or
    /// prunable, at most 12; none at all when the list isn't this
    /// checkout's repository's (the window's list may lag a tab switch).
    static func others(_ listed: [Worktree], of checkout: URL?) -> [TerraformWorktree] {
        guard let checkout else { return [] }
        let me = checkout.resolvingSymlinksInPath().standardizedFileURL.path
        let paths = listed.map { $0.path.resolvingSymlinksInPath().standardizedFileURL.path }
        guard paths.contains(me) else { return [] }
        return zip(listed, paths).filter { !$0.0.isBare && !$0.0.isPrunable && $0.1 != me }.prefix(12)
            .map { TerraformWorktree(url: $0.0.path, name: $0.0.displayName) }
    }
}

/// A module of the checkout and the roots that call it (4.12, 2.1:
/// "modules/network: 5 roots").
struct TerraformModuleRow: Equatable, Sendable, Identifiable {
    var path: String
    var callers: [String]
    var touched: Bool
    var id: String { path }
}

/// The rail's Terraform panel (analysis 6.1, stage 1b): the selected tab's
/// checkout's roots — each with its class, workspace, backend, version —
/// its modules and who calls them, its examples and Terragrunt's folders.
/// It reads files only while it is the panel on screen (CLAUDE.md): a
/// change while hidden marks it stale, read when it shows. It starts no
/// terraform but `version -json`, once per binary and root.
@MainActor
final class TerraformPanelModel: ObservableObject {
    enum State: Equatable {
        case idle, reading, read
        case notGit
    }

    @Published var checkout: URL? {
        didSet {
            guard checkout?.standardizedFileURL != oldValue?.standardizedFileURL else { return }
            roots = []
            modules = []
            examples = []
            terragrunt = []
            state = .idle
            stale = true
            readIfShown()
        }
    }

    @Published var panelVisible = false {
        didSet {
            guard panelVisible != oldValue else { return }
            readIfShown()
        }
    }

    @Published private(set) var state = State.idle
    @Published private(set) var roots: [TerraformRootCard] = []
    @Published private(set) var modules: [TerraformModuleRow] = []
    @Published private(set) var examples: [TerraformRootFolder] = []
    @Published private(set) var terragrunt: [TerraformRootFolder] = []
    @Published private(set) var capped = false
    @Published private(set) var inherited = TerraformInheritedEnvironment([:])
    /// The root picked: its details and verbs show.
    @Published var selectedPath: String?
    /// The checkout's branch and HEAD, as the diff has them: the chip's
    /// `feature-x @ 3f2a91c` (6.2) — shown, never a signal (5.1).
    @Published var branchLabel: String?
    /// The repository's other worktrees, from the window's `WorktreeModel`.
    private(set) var otherWorktrees: [TerraformWorktree] = []

    /// The window's list changed: read again where shown — not when the
    /// checkout is about to change too (`read: false`), which reads anyway.
    func setOtherWorktrees(_ worktrees: [TerraformWorktree], read: Bool = true) {
        guard worktrees != otherWorktrees else { return }
        otherWorktrees = worktrees
        if read { refresh() }
    }
    /// The folders the last listing had, relative to the top: what a
    /// file event must be in to matter (10, Monorepos).
    private var listedFolders: Set<String> = []

    /// How many times the checkout was read: a scenario checks it doesn't
    /// move while the panel is hidden.
    private(set) var reads = 0
    private var stale = true
    private var reading: Task<Void, Never>?
    private var pending: Task<Void, Never>?
    /// The diff's files, uncommitted and on the branch, relative to the checkout.
    var changedFiles: [String] = [] {
        didSet {
            guard changedFiles != oldValue, panelVisible else { return }
            markTouched()
        }
    }

    func readIfShown() {
        guard panelVisible, stale, checkout != nil else { return }
        read()
    }

    /// The checkout's files changed (the diff's watcher's paths): read
    /// again shortly while shown, else when it next shows — only for a
    /// path that can change what the panel says (`isRelevant`): a `.swift`
    /// edit, `node_modules` or a build's output never redo the read.
    func filesChanged(_ paths: [String]) {
        guard let checkout else { return }
        // FSEvents says the real path (`/private/var/…`).
        let tops = [checkout.standardizedFileURL.path, FileTreeModel.realPath(checkout.standardizedFileURL)]
        var relevant = false
        var terraformFile = false
        var looked = 0
        for path in paths {
            guard let top = tops.first(where: { path == $0 || path.hasPrefix($0 + "/") }) else { continue }
            let relative = path == top ? "" : String(path.dropFirst(top.count + 1))
            // The diff's watcher says folders: one listing of an unlisted
            // folder's names (no file read, a few a batch) says whether a
            // Terraform file is in it now.
            let found = Self.isRelevant(relative, listed: listedFolders) { folder in
                looked += 1
                guard looked <= 32 else { return false }
                let url = folder.isEmpty ? top : top + "/" + folder
                return ((try? FileManager.default.contentsOfDirectory(atPath: url)) ?? []).prefix(2_000).contains(where: TerraformRootGuess.isTerraformName)
            }
            guard found.relevant else { continue }
            relevant = true
            if found.terraform { terraformFile = true }
        }
        guard relevant else { return }
        // A configuration came or went: whether the checkout has roots is
        // open again, for the pane header too (3.2) — shown or not.
        if terraformFile {
            TerraformCheckouts.shared.forget(checkout)
            TerraformAgentGuards.shared.forget(checkout)
        }
        stale = true
        guard panelVisible else { return }
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            self?.readIfShown()
        }
    }

    /// Whether a changed path (relative to the checkout's top; a file, or a
    /// folder as FSEvents says one, with or without its `/`) can change
    /// what the panel says, and whether it may be a Terraform file (`terraform`):
    /// a Terraform file anywhere, a version file, a listed folder or a file
    /// in one (a local state, `terraform.tfstate.d`), a folder above one
    /// (moved, removed), `.terraform` and, under it, only `environment`,
    /// `terraform.tfstate` and `modules/` (4.12 step 6); any other folder
    /// only when `folderHasTerraform` finds a Terraform file in it now (a
    /// new root). Never `.git`, `node_modules`, `.terragrunt-cache`. Pure
    /// but for the closure.
    nonisolated static func isRelevant(
        _ path: String, listed: Set<String>, folderHasTerraform: (String) -> Bool = { _ in false }
    ) -> (relevant: Bool, terraform: Bool) {
        let relative = path.hasSuffix("/") ? String(path.dropLast()) : path
        let parts = relative.split(separator: "/").map(String.init)
        if parts.contains(".git") || parts.contains(".terragrunt-cache") || parts.contains("node_modules") { return (false, false) }
        if let data = parts.firstIndex(of: ".terraform") {
            guard data + 1 < parts.count else { return (true, false) }
            return (["environment", "terraform.tfstate", "modules"].contains(parts[data + 1]), false)
        }
        let name = parts.last ?? ""
        if TerraformRootGuess.isTerraformName(name) { return (true, true) }
        if [".terraform-version", ".tool-versions", "mise.toml"].contains(name) { return (true, false) }
        if let state = parts.firstIndex(of: "terraform.tfstate.d") {
            return (listed.contains(parts[..<state].joined(separator: "/")), false)
        }
        // A listed folder: one of its files changed, perhaps a configuration.
        if listed.contains(relative) { return (true, true) }
        let parent = (relative as NSString).deletingLastPathComponent
        if !relative.isEmpty, listed.contains(parent) { return (true, false) }
        // A folder above a listed one: moved or removed.
        if !relative.isEmpty, listed.contains(where: { $0.hasPrefix(relative + "/") }) { return (true, true) }
        if folderHasTerraform(relative) { return (true, true) }
        return (false, false)
    }

    func refresh() {
        stale = true
        readIfShown()
    }

    /// Read now, shown or not: a person asked (the switcher, ⌃⌘E).
    func readNow() {
        guard checkout != nil else { return }
        read()
    }

    private func read() {
        guard let checkout else { return }
        stale = false
        reads += 1
        if roots.isEmpty { state = .reading }
        reading?.cancel()
        let settings = TerraformClassSettings.current
        let identities = TerraformRootStore.shared.productionIdentities
        let guarded = AppEnvironment.guardsTerraform
        let shell = guarded ? [:] : (ShellEnvironment.known() ?? [:])
        let changed = changedFiles
        let settingPath = Settings.shared.terraformPath
        let worktrees = otherWorktrees
        inherited = TerraformInheritedEnvironment(shell)
        reading = Task { [weak self] in
            guard let listing = await TerraformRootScan.list(checkout) else {
                guard let self, !Task.isCancelled, self.checkout == checkout else { return }
                self.state = .notGit
                self.listedFolders = []
                TerraformCheckouts.shared.record(checkout, hasRoots: false)
                return
            }
            let result = await Self.blocking {
                Self.assemble(
                    checkout: checkout, listing: listing, worktrees: worktrees, settings: settings, identities: identities,
                    awsProfile: shell["AWS_PROFILE"], changed: changed)
            }
            guard let self, !Task.isCancelled, self.checkout == checkout else { return }
            self.roots = result.roots
            self.modules = result.modules
            self.examples = result.examples
            self.terragrunt = result.terragrunt
            self.capped = listing.capped
            self.listedFolders = Set(listing.folders.keys)
            self.state = .read
            TerraformCheckouts.shared.record(checkout, hasRoots: !result.roots.isEmpty)
            // Whether an agent started here gets Terraform's writes denied (3.4).
            TerraformAgentGuards.shared.record(
                checkout, roots: result.roots, complete: !listing.capped, settings: settings, identities: identities)
            // Every production workspace's identity the root's own signals
            // say — never the shell's AWS_PROFILE alone (`identityToRemember`).
            TerraformRootStore.shared.rememberProduction(result.roots.flatMap(\.rememberedIdentities))
            await self.askVersions(settingPath: settingPath)
        }
    }

    /// Each root's binary and its version: one `version -json` per binary
    /// (per root where a version file lets a shim choose), remembered for the run.
    private func askVersions(settingPath: String) async {
        let wanted = roots.map { ($0.path, $0.folder, $0.facts.hasVersionFile) }
        for (path, folder, hasVersionFile) in wanted {
            let version = await Self.blocking { () -> String? in
                guard let binary = TerraformCLI.binary(forRoot: folder, settingPath: settingPath, hasVersionFile: hasVersionFile) else { return nil }
                let key = binary.path + (hasVersionFile ? "\u{0}" + folder.path : "")
                if let known = Self.cachedVersion(key) { return known }
                let found = TerraformCLI.version(of: binary, in: folder)
                if let found { Self.cacheVersion(key, found) }
                return found
            }
            guard !Task.isCancelled, let index = roots.firstIndex(where: { $0.path == path }) else { return }
            roots[index].version = version
            roots[index].versionMismatch = roots[index].facts.pins.mismatch(version.flatMap(TerraformVersion.init))
        }
    }

    /// Versions asked, by binary and (where a version file decides) root.
    private nonisolated static let versionLock = NSLock()
    private nonisolated(unsafe) static var versionCache: [String: String] = [:]
    nonisolated static func cachedVersion(_ key: String) -> String? { versionLock.withLock { versionCache[key] } }
    nonisolated static func cacheVersion(_ key: String, _ value: String) { versionLock.withLock { versionCache[key] = value } }

    private func markTouched() {
        let callers = Dictionary(uniqueKeysWithValues: modules.map { ($0.path, $0.callers) })
        let touched = TerraformRootGuess.touched(roots: roots.map(\.path), changed: changedFiles, moduleCallers: callers)
        for index in roots.indices where roots[index].touched != touched.contains(roots[index].path) {
            roots[index].touched = touched.contains(roots[index].path)
        }
        for index in modules.indices {
            let module = modules[index].path
            let hit = changedFiles.contains { ($0 as NSString).deletingLastPathComponent == module || $0.hasPrefix(module + "/") }
            if modules[index].touched != hit { modules[index].touched = hit }
        }
    }

    nonisolated static func blocking<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { (continuation: CheckedContinuation<T, Never>) in
            let job: @Sendable () -> Void = { continuation.resume(returning: work()) }
            DispatchQueue.global(qos: .userInitiated).async(execute: job)
        }
    }

    struct Assembled: Sendable {
        var roots: [TerraformRootCard] = []
        var modules: [TerraformModuleRow] = []
        var examples: [TerraformRootFolder] = []
        var terragrunt: [TerraformRootFolder] = []
    }

    /// Everything the panel shows, from the listing: blocking file reads,
    /// bounded (4.12). Pure but for the reads.
    nonisolated static func assemble(
        checkout: URL, listing: TerraformRootScan.Listing, worktrees: [TerraformWorktree], settings: TerraformClassSettings,
        identities: Set<TerraformStateIdentity>, awsProfile: String?, changed: [String]
    ) -> Assembled {
        var facts: [String: TerraformConfigFacts] = [:]
        var terragruntTexts: [String: String] = [:]
        var modulesJSON: [String: [String]] = [:]
        for (folder, files) in listing.folders {
            let url = folder.isEmpty ? checkout : checkout.appendingPathComponent(folder, isDirectory: true)
            if files.contains(where: TerraformRootGuess.isConfigFile) {
                facts[folder] = TerraformConfigFacts.read(TerraformRootFacts.configTexts(in: url, names: files))
                if let data = TerraformRootFacts.smallFile(url.appendingPathComponent(".terraform/modules/modules.json"), limit: 4 << 20) {
                    modulesJSON[folder] = TerraformModulesManifest.directories(from: data)
                }
            }
            if files.contains("terragrunt.hcl"), let data = TerraformRootFacts.smallFile(url.appendingPathComponent("terragrunt.hcl")) {
                terragruntTexts[folder] = String(decoding: data, as: UTF8.self)
            }
        }
        let folders = TerraformRootGuess.classify(folders: listing.folders, facts: facts, terragrunt: terragruntTexts, modulesJSON: modulesJSON)
        let terragruntTree =
            listing.folders[""]?.contains { $0 == "root.hcl" || $0 == "terragrunt.hcl" } == true
            || listing.folders.values.contains { $0.contains("root.hcl") }
        var calls: [String: Set<String>] = [:]
        for (folder, config) in facts {
            var targets = Set(config.moduleSources.compactMap { TerraformRootGuess.localSource($0, from: folder) })
            for dir in modulesJSON[folder] ?? [] {
                if let target = TerraformRootGuess.localSource(dir.hasPrefix(".") ? dir : "./" + dir, from: folder) { targets.insert(target) }
            }
            calls[folder] = targets.filter { listing.folders[$0] != nil }
        }
        var result = Assembled()
        let rootFolders = folders.filter { $0.kind == .root }.prefix(200)
        let moduleFolders = folders.filter { $0.kind == .module }
        let callers = TerraformRootGuess.callers(of: moduleFolders.map(\.path), roots: rootFolders.map(\.path), calls: calls)
        let touched = TerraformRootGuess.touched(roots: rootFolders.map(\.path), changed: changed, moduleCallers: callers)
        for folder in rootFolders {
            let url = folder.path.isEmpty ? checkout : checkout.appendingPathComponent(folder.path, isDirectory: true)
            let rootFacts = TerraformRootFacts.read(root: url, checkout: checkout, config: facts[folder.path])
            var card = TerraformRootCard.make(
                folder: folder, at: url, facts: rootFacts, awsProfile: awsProfile, terragruntTree: terragruntTree, settings: settings,
                productionIdentities: identities)
            card.touched = touched.contains(folder.path)
            card.modules = (calls[folder.path] ?? []).sorted()
            // The same root in the repository's other worktrees (3.6, 3.7).
            for worktree in worktrees {
                let other = folder.path.isEmpty ? worktree.url : worktree.url.appendingPathComponent(folder.path, isDirectory: true)
                guard FileManager.default.fileExists(atPath: other.path) else { continue }
                // Its backend and workspace only, kept by the files' times.
                let otherFacts = TerraformRootFacts.readIdentity(root: other)
                if let identity = card.identity, TerraformStateIdentity.of(backend: otherFacts.backend, workspace: otherFacts.workspace, root: other) == identity {
                    card.sharedWith.append(worktree.name)
                }
                if card.facts.backend.type == "local", !card.facts.localStateExists, card.stateElsewhere == nil {
                    let state = TerraformStateIdentity.localStatePath(backend: otherFacts.backend, workspace: card.workspace, root: other)
                    if FileManager.default.fileExists(atPath: state.path) { card.stateElsewhere = worktree.name }
                }
            }
            result.roots.append(card)
        }
        result.modules = moduleFolders.map { module in
            TerraformModuleRow(
                path: module.path, callers: callers[module.path] ?? [],
                touched: changed.contains { ($0 as NSString).deletingLastPathComponent == module.path || $0.hasPrefix(module.path + "/") })
        }
        result.examples = folders.filter { $0.kind == .example }
        result.terragrunt = folders.filter { $0.kind == .terragruntUnit || $0.kind == .terragruntConfig }
        return result
    }
}
