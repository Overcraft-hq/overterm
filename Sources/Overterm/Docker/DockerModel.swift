import Combine
import Foundation

/// Docker for the app, one like `DatabaseModel`: whether the engine
/// answers, its containers and the compose projects among them, kept
/// current by the engine's events. Images, volumes and networks are read
/// when a list asks for them.
///
/// While nothing shows Docker, only the event stream (idle until something
/// changes) and a list per change run. A list on screen (`show`) adds a
/// slow poll, for what events don't carry ("Up 2 minutes" ageing). An
/// engine that goes away is retried at growing intervals, its runtime asked
/// whether it is starting or stopped while someone is looking.
@MainActor
final class DockerModel: ObservableObject {
    static let shared = DockerModel()

    enum Connection: Equatable, Sendable {
        /// Docker is off in Settings, or this run must not reach the user's.
        case off
        case connecting
        /// The API version both sides speak.
        case running(String)
        /// The engine didn't answer; what was said.
        case down(String)

        var isRunning: Bool {
            if case .running = self { return true }
            return false
        }
    }

    @Published private(set) var connection: Connection = .off
    @Published private(set) var endpoint: DockerEndpoint?
    @Published private(set) var runtime: DockerRuntime = .engine
    /// Asked of the runtime while the engine is down and Docker is on screen.
    @Published private(set) var runtimeStatus: DockerRuntime.Status = .unknown
    @Published private(set) var info: EngineInfo?
    /// Every container, stopped ones too, by name.
    @Published private(set) var containers: [ContainerSummary] = []
    @Published private(set) var projects: [ComposeProject] = []
    /// The containers in no compose project.
    @Published private(set) var loose: [ContainerSummary] = []

    /// Each listed event as it comes — what the attention marks read.
    let events = PassthroughSubject<DockerEvent, Never>()

    private(set) var engine: DockerEngine?
    private let resolve: @MainActor () -> DockerEndpoint?
    private let retries: [Duration]
    private let poll: Duration
    private var watching: Task<Void, Never>?
    private var reloading: Task<Void, Never>?
    private var polling: Task<Void, Never>?
    private var viewers = 0
    private var attempt = 0

    /// - Parameter endpoint: where to look, asked at each (re)connection —
    ///   AppEnvironment's, by default.
    /// - Parameter retries: the waits between attempts while the engine is
    ///   away, the last one repeated.
    init(
        endpoint: @escaping @MainActor () -> DockerEndpoint? = {
            Settings.shared.dockerEnabled ? AppEnvironment.dockerEndpoint(setting: Settings.shared.dockerEndpoint) : nil
        },
        retries: [Duration] = [.seconds(1), .seconds(2), .seconds(5), .seconds(10), .seconds(30)], poll: Duration = .seconds(15)
    ) {
        resolve = endpoint
        self.retries = retries
        self.poll = poll
    }

    // MARK: Connecting

    /// Whether it watches an engine (or waits to retry one).
    var isWatching: Bool { watching != nil }

    /// Starts watching the engine, if it isn't already.
    func start() {
        guard watching == nil else { return }
        watching = Task { [weak self] in await self?.watch() }
    }

    /// Stops it: nothing is read, the lists empty.
    func stop() {
        watching?.cancel()
        watching = nil
        reloading?.cancel()
        reloading = nil
        engine = nil
        connection = .off
        clear()
    }

    /// Now rather than at the next retry: after "Start Docker Desktop",
    /// a context switched, the endpoint setting changed.
    func reconnect() {
        stop()
        attempt = 0
        start()
    }

    /// A scenario's own engine (the fake one), in place of the user's.
    private var override: DockerEndpoint?

    func use(_ endpoint: DockerEndpoint?) {
        override = endpoint
        reconnect()
    }

    private func watch() async {
        while !Task.isCancelled {
            guard let endpoint = override ?? resolve() else {
                self.endpoint = nil
                connection = .off
                clear()
                return
            }
            self.endpoint = endpoint
            if !connection.isRunning { connection = .connecting }
            let engine = DockerEngine(endpoint: endpoint)
            do {
                let version = try await engine.ping()
                // Events first, so a change while the list is read is not
                // missed: the stream connects as it is made.
                let events = engine.events()
                self.engine = engine
                info = try? await engine.info()
                runtime = DockerRuntime.of(endpoint, operatingSystem: info?.OperatingSystem)
                runtimeStatus = .running
                connection = .running(version)
                attempt = 0
                await reload()
                for try await event in events {
                    self.events.send(event)
                    scheduleReload()
                }
                // Stopped (the stream ends when its task is cancelled), or
                // the engine went away: Docker Desktop quit.
                guard !Task.isCancelled else { return }
                connection = .down("\(runtime.name) stopped answering.")
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                runtime = DockerRuntime.of(endpoint, operatingSystem: info?.OperatingSystem)
                connection = .down(Self.reason(error, endpoint: endpoint, runtime: runtime))
            }
            self.engine = nil
            clear()
            if viewers > 0 { runtimeStatus = await DockerCLI.status(of: runtime, endpoint: endpoint) }
            let wait = retries.isEmpty ? .seconds(30) : retries[min(attempt, retries.count - 1)]
            attempt += 1
            try? await Task.sleep(for: wait)
        }
    }

    /// What the bar says when the engine doesn't answer.
    static func reason(_ error: Error, endpoint: DockerEndpoint, runtime: DockerRuntime) -> String {
        if case .unix(let path) = endpoint.address, !FileManager.default.fileExists(atPath: path) {
            return "\(runtime.name) isn't running — no socket at \(path)."
        }
        if let error = error as? DockerError, error.status > 0 { return error.message }
        return "\(runtime.name) isn't answering at \(endpoint.host)."
    }

    private func clear() {
        info = nil
        if !containers.isEmpty { containers = [] }
        if !projects.isEmpty { projects = [] }
        if !loose.isEmpty { loose = [] }
    }

    // MARK: Reading

    /// The containers again, now.
    func reload() async {
        guard let engine else { return }
        guard let list = try? await engine.containers(all: true), self.engine === engine else { return }
        let sorted = list.sorted { $0.name < $1.name }
        guard sorted != containers else { return }
        containers = sorted
        let grouped = ComposeProjects.group(sorted)
        if grouped.projects != projects { projects = grouped.projects }
        if grouped.loose != loose { loose = grouped.loose }
    }

    /// Events come in bursts (`compose up` makes, starts and checks a dozen
    /// containers): one list for a burst, read soon after it starts.
    private func scheduleReload() {
        guard reloading == nil else { return }
        reloading = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            await self?.reload()
            self?.reloading = nil
        }
    }

    /// Something shows Docker: the slow poll runs until the last `hide`.
    func show() {
        viewers += 1
        start()
        guard polling == nil else { return }
        polling = Task { [weak self, poll] in
            while !Task.isCancelled {
                try? await Task.sleep(for: poll)
                guard !Task.isCancelled else { return }
                await self?.reload()
            }
        }
    }

    func hide() {
        viewers = max(0, viewers - 1)
        guard viewers == 0 else { return }
        polling?.cancel()
        polling = nil
    }

    func container(_ idOrName: String) -> ContainerSummary? {
        containers.first { $0.Id == idOrName || $0.name == idOrName } ?? containers.first { $0.Id.hasPrefix(idOrName) }
    }

    /// The projects a checkout holds — its compose stack.
    func projects(in checkout: URL) -> [ComposeProject] {
        ComposeProjects.projects(projects, in: FileTreeModel.realPath(checkout))
    }

    // MARK: Acting

    /// An action, then the list at once rather than at the event.
    func perform(_ action: DockerEngine.ContainerAction, on id: String) async throws {
        guard let engine else { throw DockerError.unreachable("Docker isn't running.") }
        try await engine.perform(action, on: id)
        await reload()
    }

    func remove(_ id: String, force: Bool = false, volumes: Bool = false) async throws {
        guard let engine else { throw DockerError.unreachable("Docker isn't running.") }
        try await engine.remove(container: id, force: force, volumes: volumes)
        await reload()
    }
}
