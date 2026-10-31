import Combine
import Foundation

/// The container a detail shows, read as long as it shows: its inspect
/// data, read again when the list says its state changed; its logs while
/// the Logs tab is open, its stats while Stats is.
@MainActor
final class ContainerSession: ObservableObject {
    let id: String
    @Published private(set) var detail: ContainerDetail?
    @Published private(set) var error: String?

    /// Its log, as the Logs tab shows it.
    let feed = DockerLogFeed()
    var lines: [DockerLogLine] { feed.lines }
    /// Whether the log is followed now — false once the container stops
    /// (the engine ends the stream), true again when it starts.
    var following: Bool { feed.following }
    @Published private(set) var usage: DockerUsage?
    /// The last minute of samples, for the sparklines.
    @Published private(set) var history: [DockerUsage] = []
    /// Inspect as the engine wrote it, secrets taken out.
    @Published private(set) var json: String?
    /// The Files tab: the folder shown, its entries, what went wrong.
    @Published private(set) var folder: String?
    @Published private(set) var entries: [DockerFiles.Entry] = []
    @Published private(set) var filesError: String?
    @Published private(set) var listing = false
    /// Its processes, as `top` says them, while Stats shows.
    @Published private(set) var processes: (titles: [String], rows: [[String]])?
    /// What changed in its filesystem since it started (Files ▸ Changes).
    @Published private(set) var changes: [DockerEngine.Change]?

    /// It couldn't start: its host port is taken, and by whom.
    @Published private(set) var conflict: DockerPortConflict?
    /// The windows' tab holding a port: its id, title and process (the app
    /// sets it).
    static var tabHolding: (Int) -> (UUID, String, String)? = { _ in nil }

    static let tail = 500

    let docker: DockerModel
    private var watching: AnyCancellable?
    private var starts: AnyCancellable?
    private var loading: Task<Void, Never>?
    private var follower: DockerLogFollower?
    private var sampling: Task<Void, Never>?
    private var lastState: String?
    private var wantsLogs = false
    private var wantsStats = false

    init(id: String, docker: DockerModel = .shared) {
        self.id = id
        self.docker = docker
        load()
        // A list that says something else (started, exited, renamed) is a
        // reason to read the rest again — and to follow the log again.
        watching = docker.$containers
            .map { containers in containers.first { $0.Id == id }.map { "\($0.State)|\($0.Status)|\($0.name)" } }
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] state in
                guard let self, state != nil, state != self.lastState else { return }
                self.lastState = state
                self.load()
            }
        // Its own start, from the engine: a list read after a quick restart
        // may look as it did before it. Its settings changed (`docker
        // update`, here or from the CLI): nothing the list says changes, so
        // its inspect is read again at the event.
        starts = docker.events
            .filter { $0.Actor.ID == id && ["start", "restart", "unpause", "update"].contains($0.verb) }
            .sink { [weak self] event in
                if event.verb == "update" { self?.load() } else { self?.started() }
            }
    }

    private func started() {
        load()
        if wantsLogs, !following { followLogs() }
        if wantsStats, sampling == nil { sample(running: true) }
    }

    private var container: ContainerSummary? { docker.container(id) }

    func load() {
        loading?.cancel()
        loading = Task { [weak self, docker, id] in
            guard let engine = docker.engine else { return }
            do {
                let detail = try await engine.container(id)
                guard !Task.isCancelled else { return }
                self?.detail = detail
                self?.error = nil
                if self?.json != nil { self?.loadJSON() }
                await self?.findConflict(detail)
            } catch {
                guard !Task.isCancelled else { return }
                self?.error = error.localizedDescription
            }
        }
    }

    /// Who has the port its start failed on, when that is why.
    private func findConflict(_ detail: ContainerDetail) async {
        guard detail.State.Running != true, let port = detail.State.Error.flatMap(PortConflicts.port(in:)) else {
            if conflict != nil { conflict = nil }
            return
        }
        if let holder = PortConflicts.container(holding: port, among: docker.containers, except: id) {
            conflict = DockerPortConflict(
                port: port, holder: .container(id: holder.Id, name: holder.name, project: holder.composeProject, folder: holder.composeWorkingDir))
        } else if docker.publishedHost != nil {
            // A remote engine's port is its host's: nothing here holds it.
            conflict = DockerPortConflict(port: port, holder: .unknown)
        } else if let (tab, title, process) = Self.tabHolding(port) {
            conflict = DockerPortConflict(port: port, holder: .tab(id: tab, title: title, process: process))
        } else if let process = await ListeningPorts.holder(of: port) {
            conflict = DockerPortConflict(port: port, holder: .process(pid: process.pid, command: process.process))
        } else {
            conflict = DockerPortConflict(port: port, holder: .unknown)
        }
    }

    /// Logs read only while Logs shows, stats while Stats does — on
    /// screen. Its owner calls this as those change.
    func follow(_ tab: ContainerTab, shown: Bool) {
        if shown && tab == .logs { showLogs() } else { hideLogs() }
        if shown && tab == .stats { showStats() } else { hideStats() }
        if shown && tab == .files && folder == nil { open(detail?.Config.WorkingDir.flatMap { $0.isEmpty ? nil : $0 } ?? "/") }
    }

    // MARK: Files

    func loadChanges() {
        Task { [weak self, docker, id] in
            guard let engine = docker.engine else { return }
            let changes = (try? await engine.changes(id)) ?? []
            self?.changes = changes.sorted { $0.Path < $1.Path }
        }
    }

    /// A folder of the container, listed (a running one: `exec`). Another
    /// folder's entries go at once: under its path, a row would name a
    /// file that isn't there — opened, dragged out, or taken for one a
    /// drop replaces.
    func open(_ folder: String) {
        if folder != self.folder { entries = [] }
        self.folder = folder
        listing = true
        Task { [weak self, docker, id] in
            guard let engine = docker.engine else { return }
            do {
                let entries = try await engine.list(id, folder: folder)
                guard self?.folder == folder else { return }
                self?.entries = entries
                self?.filesError = nil
            } catch {
                guard self?.folder == folder else { return }
                self?.entries = []
                let stopped = (error as? DockerError)?.status == 409
                self?.filesError = stopped ? "It isn't running: start it to see its folders. A file can still be opened by its path, and files dropped here still go in." : error.localizedDescription
            }
            self?.listing = false
        }
    }

    // MARK: Logs

    /// The Logs tab is open: the last lines, then what comes.
    func showLogs() {
        wantsLogs = true
        if !following { followLogs() }
    }

    func hideLogs() {
        wantsLogs = false
        follower?.stop()
    }

    /// The view's lines go; what comes after now still shows.
    func clearLogs() { feed.clear() }

    private func followLogs() {
        if follower == nil {
            let follower = DockerLogFollower(id: id, feed: feed, docker: docker, merging: false)
            follower.onChange = { [weak self, weak follower] in self?.feed.following = follower?.following ?? false }
            self.follower = follower
        }
        if let container { feed.terminalCommand = DockerCommands.followLogs(of: container, endpoint: docker.endpoint) }
        follower?.start(tail: Self.tail, tty: detail?.Config.Tty)
    }

    // MARK: Stats

    func showStats() {
        wantsStats = true
        if sampling == nil { sample(running: container?.state == .running) }
    }

    func hideStats() {
        wantsStats = false
        sampling?.cancel()
        sampling = nil
    }

    private func sample(running: Bool) {
        guard running else { return }
        sampling = Task { [weak self, docker, id] in
            guard let engine = docker.engine else { return }
            do {
                var tick = 0
                for try await sample in engine.stats(id) {
                    guard let self else { return }
                    let usage = DockerUsage(sample)
                    self.usage = usage
                    self.history = Array((self.history + [usage]).suffix(60))
                    // Its processes every other sample: `ps` in the container is no free read.
                    if tick % 2 == 0, let top = try? await engine.top(id) { self.processes = (top.titles, top.processes) }
                    tick += 1
                }
            } catch {}
            // Cancelled, it was let go already (hideStats), and a newer one
            // may be in `sampling` now: only an end of its own clears it.
            guard !Task.isCancelled else { return }
            self?.sampling = nil
        }
    }

    // MARK: Inspect

    func loadJSON() {
        Task { [weak self, docker, id] in
            guard let engine = docker.engine, let text = try? await engine.containerJSON(id) else { return }
            let secrets = DockerSecrets.values(in: self?.detail?.env ?? [])
            self?.json = DockerSecrets.redact(text, values: secrets)
        }
    }

    func close() {
        loading?.cancel()
        hideLogs()
        hideStats()
        watching = nil
        starts = nil
    }
}
