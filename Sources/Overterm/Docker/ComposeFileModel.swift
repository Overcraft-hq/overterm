import Combine
import Foundation

/// The selected tab's checkout's compose project before it runs, one per
/// window: its compose files as Compose reads them (`ComposeConfig`), so
/// the rail's panel and the page can show the stack and offer `up` before
/// any of it exists.
///
/// Read only while Docker is on screen in the window (the window says,
/// `update`): when it comes up, when the checkout changes and its files
/// did, and when a compose file, an override or `.env` at the checkout's
/// top changes (FSEvents). What each checkout read last is kept for the
/// window's life, so switching tabs shows a known one at once.
@MainActor
final class ComposeFileModel: ObservableObject {
    /// Compose's JSON for a folder; nil when it wasn't asked (an isolated
    /// run without a scenario's stub).
    typealias Reader = @MainActor (URL, DockerEndpoint?) async throws -> String?

    @Published private(set) var project: ComposeProject?
    /// What Compose said when it couldn't read the files; the project read
    /// before stays.
    @Published private(set) var error: String?
    @Published private(set) var reading = false
    /// How many times Compose was asked — what the tests count.
    private(set) var reads = 0

    private struct Known {
        var project: ComposeProject?
        var error: String?
        var stamp: ComposeConfig.Stamp
    }

    private let docker: DockerModel
    private let latency: TimeInterval
    private let reader: Reader
    /// The checkout, as a real path.
    private var folder: String?
    private var shown = false
    private var watcher: DirectoryWatcher?
    private var task: Task<Void, Never>?
    /// The stamp of the read on its way.
    private var pending: ComposeConfig.Stamp?
    private var known: [String: Known] = [:]

    init(docker: DockerModel = .shared, latency: TimeInterval = 0.5, reader: @escaping Reader = ComposeFileModel.compose) {
        self.docker = docker
        self.latency = latency
        self.reader = reader
    }

    /// Which checkout, and whether Docker shows in the window.
    func update(checkout: URL?, shown: Bool) {
        let folder = checkout.map(FileTreeModel.realPath)
        let moved = folder != self.folder
        let appeared = shown && !self.shown
        self.folder = folder
        self.shown = shown
        if moved {
            // Another checkout's plan never lingers: this one's, if known.
            cancel()
            watcher?.stop()
            watcher = nil
            let cached = folder.flatMap { known[$0] }
            publish(cached?.project, cached?.error)
        }
        guard shown, let folder else {
            // Nothing is read while nothing shows Docker.
            watcher?.stop()
            watcher = nil
            cancel()
            return
        }
        if watcher == nil {
            watcher = DirectoryWatcher(root: URL(fileURLWithPath: folder), latency: latency) { [weak self] in self?.changed($0) }
        }
        guard moved || appeared else { return }
        // Coming on screen always reads (an included file may have changed
        // unwatched); another checkout only when its top files did.
        let stamp = ComposeConfig.stamp(of: URL(fileURLWithPath: folder))
        if appeared || known[folder]?.stamp != stamp { read(stamp) }
    }

    private func changed(_ paths: [String]) {
        guard shown, let folder, ComposeConfig.touches(paths, folder: folder) else { return }
        let stamp = ComposeConfig.stamp(of: URL(fileURLWithPath: folder))
        if stamp != (pending ?? known[folder]?.stamp) { read(stamp) }
    }

    private func read(_ stamp: ComposeConfig.Stamp) {
        guard let folder else { return }
        let url = URL(fileURLWithPath: folder)
        task?.cancel()
        guard ComposeProjects.composeFile(in: url) != nil else {
            task = nil
            return finish(folder, project: nil, error: nil, stamp: stamp)
        }
        reads += 1
        reading = true
        pending = stamp
        let reader = self.reader
        let endpoint = docker.endpoint
        task = Task { [weak self] in
            do {
                let output = try await reader(url, endpoint)
                try Task.checkCancellation()
                // No service to make (each under a profile not on, or none):
                // nothing for `up` to do, so no project before it runs.
                let config = try output.map(ComposeConfig.parse)
                let project = config.flatMap { $0.services.isEmpty ? nil : $0.project(in: folder) }
                self?.finish(folder, project: project, error: nil, stamp: stamp)
            } catch {
                guard !Task.isCancelled, !(error is CancellationError), let self else { return }
                // A half-saved file doesn't make the stack vanish.
                self.finish(folder, project: self.known[folder]?.project, error: ComposeConfig.message(error), stamp: stamp)
            }
        }
    }

    private func finish(_ folder: String, project: ComposeProject?, error: String?, stamp: ComposeConfig.Stamp) {
        known[folder] = Known(project: project, error: error, stamp: stamp)
        guard folder == self.folder else { return }
        publish(project, error)
        pending = nil
        if reading { reading = false }
    }

    /// Whether what shows was read from the checkout's top files as they
    /// are now. Nothing reads them while Docker is hidden, so a menu that
    /// acts on the project then asks this first.
    var isCurrent: Bool {
        guard let folder, !reading, let known = known[folder] else { return false }
        return known.stamp == ComposeConfig.stamp(of: URL(fileURLWithPath: folder))
    }

    private func cancel() {
        task?.cancel()
        task = nil
        pending = nil
        if reading { reading = false }
    }

    private func publish(_ project: ComposeProject?, _ error: String?) {
        if self.project != project { self.project = project }
        if self.error != error { self.error = error }
    }

    /// `docker compose config` in the checkout, as `up` there would read
    /// it. It reaches no engine; it is told Overterm's anyway, as every
    /// `docker` it runs is.
    static func compose(in folder: URL, endpoint: DockerEndpoint?) async throws -> String? {
        // An isolated run asks only a scenario's stub.
        guard !AppEnvironment.isIsolated || DockerCLI.override != nil else { return nil }
        guard let cli = DockerCLI(endpoint: endpoint) else {
            throw DockerError(status: 0, message: "docker isn't on this Mac, so Compose can't read the compose file.")
        }
        return try await cli.composeConfig(ComposeConfig.arguments(), in: folder, timeout: 15)
    }
}
