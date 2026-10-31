import Foundation

/// The containers Overterm makes for itself — a volume's helpers, both
/// the one a file is read through (never started) and the one a Files tab
/// lists with (running) — so none outlives what made it: one holds its
/// volume, which `docker volume rm` and a prune then refuse. Each is
/// labelled `overterm.helper=1`, which keeps it out of every list
/// (`ContainerSummary.isHelper`), and `overterm.run` with the run that
/// made it. Known two ways: what this run made, recorded here as each is
/// made, and what the engine lists with the label — one a crash or a
/// force quit left, or a version before this one, that nothing recorded.
enum DockerHelpers {
    /// This run's mark on what it makes (`overterm.run`).
    static let run = UUID().uuidString.lowercased()

    private struct Helper {
        var engine: DockerEngine
        var volume: String
    }

    nonisolated(unsafe) private static var live: [String: Helper] = [:]
    /// Removals on their way, by id: a second caller waits for the first's.
    /// The engine refuses a second at once (409, "already in progress")
    /// while the first still kills the container, which still holds its
    /// volume.
    nonisolated(unsafe) private static var removals: [String: Task<Void, Never>] = [:]
    private static let lock = NSLock()

    static func made(_ id: String, volume: String, on engine: DockerEngine) {
        lock.withLock { live[id] = Helper(engine: engine, volume: volume) }
    }

    static var count: Int { lock.withLock { live.count } }

    /// Those made on `engine`, for a test.
    static func ids(on engine: DockerEngine) -> [String] {
        lock.withLock { live.filter { $0.value.engine === engine }.map(\.key).sorted() }
    }

    /// Removed, once however many ask: returns when the engine no longer
    /// has it (`DockerEngine.deleteHelper`).
    static func remove(_ id: String, on engine: DockerEngine) async {
        await removal(of: id, on: engine).value
    }

    private static func removal(of id: String, on engine: DockerEngine) -> Task<Void, Never> {
        lock.withLock {
            if let running = removals[id] { return running }
            let removing = Task.detached {
                await engine.deleteHelper(id)
                finished(id)
            }
            removals[id] = removing
            return removing
        }
    }

    private static func finished(_ id: String) {
        lock.withLock {
            live.removeValue(forKey: id)
            removals.removeValue(forKey: id)
        }
    }

    /// Every helper holding `volume`, removed before it is: Remove and
    /// Clean Up would be refused while one is there. This run's, and what
    /// `engine` lists that mounts it — by the mount, as a helper from
    /// before `overterm.volume` doesn't say it.
    static func remove(mounting volume: String, on engine: DockerEngine?) async {
        var holding = lock.withLock { live.filter { $0.value.volume == volume }.map { ($0.key, $0.value.engine) } }
        if let engine, let listed = try? await engine.helpers() {
            for helper in listed where (helper.Mounts ?? []).contains(where: { $0.Name == volume }) && !holding.contains(where: { $0.0 == helper.Id }) {
                holding.append((helper.Id, engine))
            }
        }
        await withTaskGroup(of: Void.self) { group in
            for (id, engine) in holding { group.addTask { await remove(id, on: engine) } }
        }
    }

    /// What a run before this one left and that doesn't run: one never
    /// started (an export's, a save's) holds its volume for good, and no
    /// list shows it. Not one another Overterm on the same engine may be
    /// reading through still: made over ten minutes ago. Pure.
    static func leftBehind(_ helpers: [ContainerSummary], now: Date = Date()) -> [String] {
        let before = Int(now.timeIntervalSince1970) - 600
        return helpers.filter { $0.isHelper && $0.labels["overterm.run"] != run && $0.state != .running && $0.Created < before }.map(\.Id)
    }

    /// Those removed, as an engine connects (`DockerModel.reload` hands its
    /// first list over). Nobody waits for it.
    static func sweep(_ helpers: [ContainerSummary], on engine: DockerEngine) {
        for id in leftBehind(helpers) { _ = removal(of: id, on: engine) }
    }

    /// At quit: what is left removed, waiting at most `seconds` — a remote
    /// engine's forward is still open (`DockerSSHForwards.closeAll` comes
    /// after). Blocks the caller, the main thread at quit; the removal
    /// runs elsewhere, never on the main actor, so it can't wait on itself.
    static func removeAll(waiting seconds: Double = 2) {
        let helpers = lock.withLock { live.map { ($0.key, $0.value.engine) } }
        guard !helpers.isEmpty else { return }
        let done = DispatchSemaphore(value: 0)
        startRemoving(helpers, then: done)
        _ = done.wait(timeout: .now() + seconds)
    }

    /// Built here, out of any actor (CLAUDE.md: closures for other queues).
    nonisolated private static func startRemoving(_ helpers: [(String, DockerEngine)], then done: DispatchSemaphore) {
        Task.detached {
            await withTaskGroup(of: Void.self) { group in
                for (id, engine) in helpers { group.addTask { await remove(id, on: engine) } }
            }
            done.signal()
        }
    }
}
