import Foundation

/// A collection or a folder run from top to bottom, as Bruno's runner runs
/// it: each request with its scripts and tests, the runtime variables one
/// sets reaching the next, `bru.setNextRequest` jumping, `skipRequest`
/// and `stopExecution` honoured. What ran, and how, stays for the pane.
@MainActor
final class APIRunner: ObservableObject {
    struct Entry: Identifiable, Equatable {
        enum State: Equatable { case waiting, running, done, skipped }
        let url: URL
        let name: String
        let method: String
        /// Where it sits, for the row: "Users / Admin".
        let folder: String
        var state: State = .waiting
        var result: APIExecution.Result?
        var id: String { url.path }

        var passed: Bool { result?.succeeded == true }
    }

    enum Filter: String, CaseIterable, Identifiable {
        case all, passed, failed
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
    }

    @Published private(set) var entries: [Entry] = []
    @Published private(set) var title = ""
    @Published private(set) var isRunning = false
    @Published private(set) var started: Date?
    @Published private(set) var duration: TimeInterval = 0
    @Published var filter: Filter = .all
    /// What a run that was asked for covers, to run it again.
    private(set) var lastItems: [APIItem] = []
    private(set) var collectionRoot: URL?
    /// The environment the run was asked for (an agent's), nil for the panel's.
    private(set) var lastEnvironment: String?
    /// The environment the run uses, fixed when it starts: the picker
    /// changed mid-run must not send the rest elsewhere. Shown in the pane.
    @Published private(set) var environment: String?
    private var task: Task<Void, Never>?
    /// Which run the state is: a cancelled one that wakes up after another
    /// has started must not touch it.
    private(set) var runID = UUID()

    var hasRun: Bool { !entries.isEmpty }
    var done: Int { entries.filter { $0.state == .done || $0.state == .skipped }.count }
    var passedCount: Int { entries.filter(\.passed).count }
    var failedCount: Int { entries.filter { $0.state == .done && !$0.passed }.count }
    var testsPassed: Int { entries.compactMap(\.result).reduce(0) { $0 + $1.passed } }
    var testsTotal: Int { entries.compactMap(\.result).reduce(0) { $0 + $1.tests.count } }

    var shown: [Entry] {
        switch filter {
        case .all: entries
        case .passed: entries.filter(\.passed)
        case .failed: entries.filter { $0.state == .done && !$0.passed }
        }
    }

    /// A ceiling on steps: setNextRequest can send a run round in a circle.
    static let maxSteps = 1000

    /// Runs `items` (requests, folders) through `workspace`, in order;
    /// the run's identity, to wait on it.
    @discardableResult
    func run(
        _ items: [APIItem], title: String, in collection: BrunoCollection, workspace: APIWorkspace, environment: String? = nil
    ) -> UUID {
        cancel()
        let id = UUID()
        runID = id
        lastEnvironment = environment
        // An agent's, or the one picked now — for the whole run, "none" too.
        let pinned = workspace.fixed(environment.map(APIWorkspace.EnvironmentChoice.named) ?? .panel, for: collection)
        if case .named(let name) = pinned { self.environment = name } else { self.environment = nil }
        lastItems = items
        collectionRoot = collection.root
        self.title = title
        let requests = items.flatMap(\.allRequests)
        entries = requests.map { item in
            Entry(url: item.url, name: item.name, method: item.method ?? "GET", folder: Self.folderLabel(item.url, in: collection))
        }
        started = Date()
        duration = 0
        isRunning = true
        task = Task { [weak self] in
            await self?.loop(workspace, id: id, environment: pinned)
        }
        return id
    }

    func isRunning(_ id: UUID) -> Bool { runID == id && isRunning }

    /// The entries of run `id`, or none once another has replaced it.
    func entries(of id: UUID) -> [Entry] { runID == id ? entries : [] }

    func runAgain(workspace: APIWorkspace) {
        guard let collection = workspace.collections.first(where: { $0.root == collectionRoot }) else { return }
        // Fresh items: names and order may have changed since.
        let items = lastItems.compactMap { collection.item(at: $0.url) }
        // The panel's pick, not an agent's environment of the run before.
        run(items.isEmpty ? lastItems : items, title: title, in: collection, workspace: workspace)
    }

    func cancel() {
        task?.cancel()
        task = nil
        if isRunning { finish(runID) }
    }

    func clear() {
        cancel()
        entries = []
        title = ""
    }

    private func loop(_ workspace: APIWorkspace, id: UUID, environment: APIWorkspace.EnvironmentChoice) async {
        var index = 0
        var steps = 0
        while runID == id, index < entries.count, steps < Self.maxSteps, !Task.isCancelled {
            steps += 1
            entries[index].state = .running
            let url = entries[index].url
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                entries[index].state = .done
                entries[index].result = APIExecution.Result(error: "The file can't be read.")
                index += 1
                continue
            }
            let result = await workspace.run(BruFile(parsing: text), at: url, environment: environment)
            guard !Task.isCancelled, runID == id else { break }
            entries[index].result = result
            entries[index].state = result.skipped ? .skipped : .done
            duration = Date().timeIntervalSince(started ?? Date())
            if result.stop { break }
            if let next = result.nextRequest, let target = entries.firstIndex(where: { $0.name == next }) {
                index = target
                // A request visited again shows its latest run.
                entries[target].state = .waiting
            } else {
                index += 1
            }
        }
        finish(id)
    }

    private func finish(_ id: UUID) {
        guard id == runID else { return }
        isRunning = false
        duration = Date().timeIntervalSince(started ?? Date())
        for index in entries.indices where entries[index].state == .running { entries[index].state = .waiting }
    }

    private static func folderLabel(_ url: URL, in collection: BrunoCollection) -> String {
        collection.folders(containing: url).map { folder in
            BrunoCollection.folderFile(folder).map(\.name).flatMap { $0.isEmpty ? nil : $0 } ?? folder.lastPathComponent
        }.joined(separator: " / ")
    }

    // MARK: bru

    /// `bru` on this machine — for collections whose scripts need npm
    /// packages, which run under Bruno's own CLI, in a terminal tab.
    static func bruExecutable() -> String? {
        let paths = ["/opt/homebrew/bin/bru", "/usr/local/bin/bru", NSHomeDirectory() + "/.npm-global/bin/bru"]
        if let found = paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) { return found }
        for dir in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") {
            let candidate = "\(dir)/bru"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    /// The command that runs the same thing under bru, from the collection's folder.
    static func bruCommand(for items: [APIItem], in collection: BrunoCollection, environment: String?) -> String {
        func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let rootPath = collection.root.standardizedFileURL.path
        let targets = items.map { item -> String in
            let path = item.url.standardizedFileURL.path
            return path == rootPath ? "" : quote(String(path.dropFirst(rootPath.count + 1)))
        }.filter { !$0.isEmpty }
        var command = "bru run"
        if !targets.isEmpty { command += " " + targets.joined(separator: " ") }
        if items.contains(where: \.isFolder) { command += " -r" }
        if let environment { command += " --env \(quote(environment))" }
        return command
    }
}
