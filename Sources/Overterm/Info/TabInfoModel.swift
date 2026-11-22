import Combine
import Foundation

/// What Tab Info shows for one tab, refreshed while the popover is open:
/// the census's light slice for its tab, every second while it is open
/// (docs/design/activity/analysis.md, 6.12) — its panes' trees, what left
/// their terminals, their listening ports, read with every other reader's
/// in one tick, no scan of its own and no lsof.
@MainActor
package final class TabInfoModel: ObservableObject {
    package struct Location: Equatable {
        package var directory: String
        /// The enclosing checkout, when in one.
        package var checkout: URL?
        package var branch: String?
        /// The main worktree's folder name, when this is a linked worktree.
        package var worktreeOf: String?
        package var changedFiles: Int?
    }

    /// One pane's processes: a split tab shows one group per pane (6.12).
    package struct PaneGroup: Identifiable, Equatable {
        /// The pane's tag.
        package let id: String
        /// What the group is called in a split tab: the command the pane
        /// runs (`CommandLedger.running`), else its title — masked as a
        /// command, since a title is one (9.3).
        package let label: String
        /// Its tree under the `login`: the shell, what runs under it.
        package let processes: [ProcessNode]
        /// What carries the pane's tag outside its tree, with what it
        /// started: what left its terminal (nohup, disown, reparented to
        /// launchd). A place for display — a tag reaches past the pane.
        package let leftTerminal: [ProcessNode]
    }

    /// One row of Running, flattened for the list.
    package struct Row: Identifiable, Equatable {
        package enum Kind: Equatable {
            /// A split tab's pane, by its label.
            case pane(String)
            /// A process: the shell is its group's dimmed root.
            case process(ProcessNode, depth: Int, isShell: Bool, leftTerminal: Bool)
        }
        package let id: String
        package let kind: Kind
    }

    @Published package private(set) var panes: [PaneGroup] = []
    /// A snapshot that read the tab has come: before it, nothing is known.
    @Published package private(set) var hasRead = false
    /// The terraform processes in the tab (analysis 8): what each does, where, for how long.
    @Published package private(set) var terraform: [TerraformInfoRow] = []
    @Published package private(set) var ports: [ListeningPort] = []
    /// The Claude Code session in this tab, if there is one.
    @Published package private(set) var claude: ClaudeUsage?
    /// True while a transcript is being read for the first time (a big one
    /// takes a moment).
    @Published package private(set) var readingClaude = false
    /// Disk use of the tab's checkout (never measured outside one: a home
    /// directory is hundreds of GB of walking).
    @Published package private(set) var disk: DiskReport?
    @Published package private(set) var measuringDisk = false
    private var diskCancellation: Cancellation?
    /// Recent measurements, so reopening the popover doesn't walk again.
    private static var diskCache: [URL: (at: Date, report: DiskReport)] = [:]
    package static let diskCacheLifetime: TimeInterval = 60
    @Published package private(set) var location: Location?

    /// How often its slice is read while it is open (6.12).
    package static let interval: Duration = .seconds(1)
    /// The most rows read in focus — their folders and start times for the
    /// tooltips (7.3: Tab Info's rows on screen).
    package static let focusLimit = 64

    package let tab: Tab
    package let monitor: ActivityMonitor
    private let claudeReader: ClaudeUsageReader
    /// What a pane runs now, by its ledger — a split tab's group labels.
    private let running: (TerminalView) -> String?
    private var loop: Task<Void, Never>?
    private var snapshots: AnyCancellable?
    private var focus: Set<ActivityProcessID> = []
    private var readingTerraform = false

    package init(
        tab: Tab, monitor: ActivityMonitor = .shared, claudeReader: ClaudeUsageReader, running: @escaping (TerminalView) -> String? = { _ in nil }
    ) {
        self.tab = tab
        self.monitor = monitor
        self.claudeReader = claudeReader
        self.running = running
    }

    /// Every pane's processes, then what left each pane's terminal: the
    /// whole tab's.
    package var processes: [ProcessNode] { panes.flatMap { $0.processes + $0.leftTerminal } }

    /// The tab's CPU: the processes that have a rate; nil while none has.
    package var totalCPU: Double? {
        let rates = processes.compactMap(\.totalCPU)
        return rates.isEmpty ? nil : rates.reduce(0, +)
    }
    /// What Activity Monitor would call the tab's Memory: the footprints.
    package var totalFootprint: UInt64 { processes.reduce(0) { $0 + $1.totalFootprint } }
    /// Its real memory, resident (RSS).
    package var totalMemory: UInt64 { processes.reduce(0) { $0 + $1.totalMemory } }

    /// The rows of Running: in a split tab each pane under its label.
    package var rows: [Row] { Self.rows(panes, split: panes.count > 1) }

    /// Reads now and then every second until `stop()`: the census's slice
    /// for its tab, the location and the disk once, the Claude session
    /// every 3 s.
    package func start() {
        loop?.cancel()
        // @Published emits before it changes, and a new subscriber gets the
        // current value at once: the emitted value.
        snapshots = monitor.$snapshot.compactMap { $0 }.sink { [weak self] snapshot in self?.take(snapshot) }
        loop = Task { [weak self] in
            // Its panes paired with their logins before its first want, so
            // the first tick reads their trees: the app's children listed
            // off the main thread — a read of the whole table — and paired
            // on it (docs/design/activity/analysis.md, 7.7). The census pairs
            // from each snapshot that lands too, a tick later.
            await SurfaceProcesses.shared.pairWaiting()
            guard !Task.isCancelled else { return }
            self?.monitor.contextChanged()
            self?.want()
            await self?.refreshLocation()
            self?.measureDisk()
            while !Task.isCancelled {
                await self?.refreshClaude()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    package func stop() {
        loop?.cancel()
        loop = nil
        snapshots = nil
        monitor.unwant(self)
        diskCancellation?.cancel()
    }

    /// Its tab at the light level, its rows in focus, every second.
    private func want() {
        monitor.want(self, .light(tabs: [tab.id]), .focus(focus), every: Self.interval)
    }

    /// A snapshot that read its tab: each pane's group, the ports, the
    /// terraform rows; its rows in focus from the next tick.
    package func take(_ snapshot: ActivitySnapshot) {
        guard snapshot.covers(ActivityDemand(.light(tabs: [tab.id]))) else { return }
        let groups = tab.terminals.enumerated().map { index, pane -> PaneGroup in
            let label = ActivityText.title(running(pane) ?? pane.title ?? "Pane \(index + 1)")
            guard let slice = snapshot.pane(pane.processTag), slice.tab == tab.id else {
                return PaneGroup(id: pane.processTag, label: label, processes: [], leftTerminal: [])
            }
            return PaneGroup(
                id: pane.processTag, label: label, processes: ProcessInspector.nodes(slice.tree, in: snapshot),
                leftTerminal: ProcessInspector.nodes(slice.tagged, in: snapshot))
        }
        if groups != panes { panes = groups }
        hasRead = true
        let members = tab.terminals.flatMap { snapshot.pane($0.processTag)?.placed ?? [] }
        let found = ListeningPorts.of(members, in: snapshot) + tab.containerPorts + tab.forwardPorts
        if found != ports { ports = found }
        let wanted = Set(processes.flatMap(\.flattened).prefix(Self.focusLimit).map(\.identity))
        if wanted != focus {
            focus = wanted
            want()
        }
        readTerraform()
    }

    /// The rows of Running from the panes' groups (6.12): in a split tab
    /// each pane under its label; the shell its group's dimmed root, what
    /// it runs below it, what left its terminal under the pane, marked.
    package nonisolated static func rows(_ panes: [PaneGroup], split: Bool) -> [Row] {
        var rows: [Row] = []
        func walk(_ nodes: [ProcessNode], depth: Int, pane: String, root: Bool, left: Bool) {
            for node in nodes {
                rows.append(Row(id: "\(pane)/\(node.id)", kind: .process(node, depth: depth, isShell: root, leftTerminal: left)))
                walk(node.children, depth: depth + 1, pane: pane, root: false, left: false)
            }
        }
        for pane in panes {
            if split { rows.append(Row(id: "pane:\(pane.id)", kind: .pane(pane.label))) }
            walk(pane.processes, depth: 0, pane: pane.id, root: true, left: false)
            walk(pane.leftTerminal, depth: 1, pane: pane.id, root: false, left: true)
        }
        return rows
    }

    /// The terraform processes among its rows, read off the main thread
    /// (their argv, folder and three names: `TerraformProcesses.inspect`),
    /// one read at a time.
    private func readTerraform() {
        let candidates = processes.flatMap(\.flattened).filter {
            TerraformCommandLine.tools.contains($0.name) || TerraformProcesses.scriptShells.contains($0.name)
        }.map { (pid: $0.pid, name: $0.name, children: $0.children.map(\.pid)) }
        guard !candidates.isEmpty else {
            if !terraform.isEmpty { terraform = [] }
            return
        }
        guard !readingTerraform else { return }
        readingTerraform = true
        let settings = TerraformClassSettings.current
        let identities = TerraformRootStore.shared.productionIdentities
        Task { [weak self] in
            let rows = await TerraformPanelModel.blocking {
                candidates.compactMap { node -> TerraformInfoRow? in
                    guard let process = TerraformProcesses.inspect(node.pid, name: node.name, children: node.children) else { return nil }
                    return TerraformInfoRow.make(process, settings: settings, identities: identities)
                }
            }
            guard let self else { return }
            self.readingTerraform = false
            if self.terraform != rows { self.terraform = rows }
            TerraformRootStore.shared.rememberProduction(rows.compactMap(\.rememberIdentity))
        }
    }

    /// Walks the checkout in the background (cached for a minute).
    package func measureDisk() {
        guard let root = location?.checkout else { return }
        if let cached = Self.diskCache[root], Date().timeIntervalSince(cached.at) < Self.diskCacheLifetime {
            disk = cached.report
            return
        }
        let cancellation = Cancellation()
        diskCancellation = cancellation
        measuringDisk = true
        Task { [weak self] in
            let report = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    continuation.resume(returning: DiskUsage.measure(root, cancellation: cancellation))
                }
            }
            guard let self else { return }
            self.measuringDisk = false
            if let report {
                Self.diskCache[root] = (Date(), report)
                self.disk = report
            }
        }
    }

    /// Its processes' ports, as the latest snapshot that read the tab has
    /// them, then what its checkout's containers publish, then its
    /// Kubernetes forwards.
    package func refreshPorts() async {
        var found: [ListeningPort] = []
        if let snapshot = monitor.snapshot, snapshot.covers(ActivityDemand(.light(tabs: [tab.id]))) {
            found = ListeningPorts.of(tab.terminals.flatMap { snapshot.pane($0.processTag)?.placed ?? [] }, in: snapshot)
        }
        ports = found + tab.containerPorts + tab.forwardPorts
    }

    /// Where Claude Code runs in this tab: a running `claude`'s directory,
    /// else — for a Claude tab — the tab's.
    package var claudeDirectory: String? {
        let running = processes.flatMap(\.flattened).first { node in
            node.name == "claude" || (node.maskedCommand.split(separator: " ").first.map { $0 == "claude" || $0.hasSuffix("/claude") } ?? false)
        }
        if let cwd = running?.workingDirectory { return cwd }
        return tab.agent == .claude ? (tab.workingDirectory ?? tab.terminal.workingDirectory) : nil
    }

    package func refreshClaude() async {
        guard let directory = claudeDirectory else {
            claude = nil
            return
        }
        if claude == nil { readingClaude = true }
        let reader = claudeReader
        let usage = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async { continuation.resume(returning: reader.usage(for: directory)) }
        }
        claude = usage
        readingClaude = false
    }

    package func refreshLocation() async {
        let directory = tab.workingDirectory ?? tab.terminal.workingDirectory ?? NSHomeDirectory()
        var location = Location(directory: directory)
        let root = FileTreeModel.treeRoot(for: directory)
        if FileManager.default.fileExists(atPath: root.appendingPathComponent(".git").path) {
            location.checkout = root
            location.branch =
                (try? await Git.run(["branch", "--show-current"], in: root))?
                .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            // A linked worktree's .git is a file; its common dir is the main repo's .git.
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: root.appendingPathComponent(".git").path, isDirectory: &isDirectory)
            if !isDirectory.boolValue, let common = try? await Git.run(["rev-parse", "--path-format=absolute", "--git-common-dir"], in: root) {
                location.worktreeOf = URL(fileURLWithPath: common.trimmingCharacters(in: .whitespacesAndNewlines)).deletingLastPathComponent().lastPathComponent
            }
            if let status = try? await Git.run(["status", "--porcelain=v1", "-z", "--untracked-files=all"], in: root) {
                location.changedFiles = GitStatus.parse(porcelainZ: status).count
            }
        }
        self.location = location
    }
}

extension String {
    package var nilIfEmpty: String? { isEmpty ? nil : self }
}
