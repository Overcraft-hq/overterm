import Foundation

/// What Tab Info shows for one tab, refreshed while the popover is open.
@MainActor
final class TabInfoModel: ObservableObject {
    struct Location: Equatable {
        var directory: String
        /// The enclosing checkout, when in one.
        var checkout: URL?
        var branch: String?
        /// The main worktree's folder name, when this is a linked worktree.
        var worktreeOf: String?
        var changedFiles: Int?
    }

    @Published private(set) var processes: [ProcessNode] = []
    @Published private(set) var ports: [ListeningPort] = []
    @Published private(set) var location: Location?

    let tab: Tab
    private let inspector: ProcessInspector
    private var loop: Task<Void, Never>?

    init(tab: Tab, inspector: ProcessInspector) {
        self.tab = tab
        self.inspector = inspector
    }

    var totalCPU: Double { processes.reduce(0) { $0 + $1.totalCPU } }
    var totalMemory: UInt64 { processes.reduce(0) { $0 + $1.totalMemory } }

    /// Refreshes now and then every second until `stop()`.
    func start() {
        loop?.cancel()
        loop = Task { [weak self] in
            await self?.refreshLocation()
            var tick = 0
            while !Task.isCancelled {
                await self?.refreshProcesses()
                // lsof is slower than a process scan; every third tick is plenty.
                if tick % 3 == 0 { await self?.refreshPorts() }
                tick += 1
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
    }

    func refreshProcesses() async {
        let root = SurfaceProcesses.shared.loginPID(of: tab.terminal)
        let tag = tab.terminal.processTag
        let inspector = self.inspector
        // Scanning every process takes a few ms: off the main thread, on GCD.
        let tree = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: inspector.tree(root: root, tag: tag))
            }
        }
        processes = tree
    }

    func refreshPorts() async {
        ports = await ListeningPorts.of(processes.flatMap(\.flattened).map(\.pid))
    }

    func refreshLocation() async {
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
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
