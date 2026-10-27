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

    /// The log's lines, the newest last, at most `keep`.
    @Published private(set) var lines: [DockerLogLine] = []
    /// Bumped when `lines` is something other than the old ones with more
    /// after them (cleared, trimmed): the text view draws it all again.
    @Published private(set) var linesRevision = 0
    /// Whether the log is followed now — false once the container stops
    /// (the engine ends the stream), true again when it starts.
    @Published private(set) var following = false
    @Published private(set) var usage: DockerUsage?
    /// The last minute of samples, for the sparklines.
    @Published private(set) var history: [DockerUsage] = []
    /// Inspect as the engine wrote it, secrets taken out.
    @Published private(set) var json: String?

    static let keep = 5000
    static let tail = 500

    private let docker: DockerModel
    private var watching: AnyCancellable?
    private var starts: AnyCancellable?
    private var loading: Task<Void, Never>?
    private var logging: Task<Void, Never>?
    private var sampling: Task<Void, Never>?
    private var lastState: String?
    private var wantsLogs = false
    private var wantsStats = false
    /// The newest line's time, so a log followed again starts after it.
    private var lastStamp: String?

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
        // may look as it did before it.
        starts = docker.events
            .filter { $0.Actor.ID == id && ["start", "restart", "unpause"].contains($0.verb) }
            .sink { [weak self] _ in self?.started() }
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
            } catch {
                guard !Task.isCancelled else { return }
                self?.error = error.localizedDescription
            }
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
        logging?.cancel()
        logging = nil
        following = false
    }

    /// The view's lines go; what comes after now still shows.
    func clearLogs() {
        lines = []
        linesRevision += 1
    }

    private func followLogs() {
        logging?.cancel()
        let since = lastStamp.flatMap(Self.seconds)
        logging = Task { [weak self, docker, id] in
            guard let engine = docker.engine else { return }
            // A TTY's output comes plain, the rest framed; the detail says.
            var tty = self?.detail?.Config.Tty
            if tty == nil { tty = try? await engine.container(id).Config.Tty }
            let stream = engine.logs(id, tty: tty ?? false, tail: since == nil ? Self.tail : 1000, follow: true, since: since)
            self?.following = true
            do {
                for try await chunks in stream {
                    guard let self else { return }
                    var added = chunks.flatMap { DockerLogLine.lines(of: $0, timestamps: true) }
                    // `since` is whole seconds: the lines already shown that second come again.
                    if let last = self.lastStamp.map(Self.sortable) { added.removeAll { Self.sortable($0.timestamp ?? "") <= last } }
                    self.append(added)
                }
            } catch {
                if !Task.isCancelled { self?.error = error.localizedDescription }
            }
            guard !Task.isCancelled else { return }
            self?.following = false
            // Ended by a restart whose start came first: followed again.
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, self?.wantsLogs == true, self?.following == false,
                (try? await engine.container(id).State.Running) == true
            else { return }
            self?.followLogs()
        }
    }

    func append(_ added: [DockerLogLine]) {
        guard !added.isEmpty else { return }
        lastStamp = added.last?.timestamp ?? lastStamp
        if lines.count + added.count > Self.keep {
            lines = Array((lines + added).suffix(Self.keep))
            linesRevision += 1
        } else {
            lines += added
        }
    }

    /// A timestamp that sorts as text: Docker trims a fraction's trailing
    /// zeros (`.12Z` is later than `.115Z`), so it is padded to nine digits.
    nonisolated static func sortable(_ stamp: String) -> String {
        // The fraction starts after `THH:mm:ss`; a whole second has none.
        guard let t = stamp.firstIndex(of: "T"), let end = stamp.index(t, offsetBy: 9, limitedBy: stamp.endIndex) else { return stamp }
        var rest = stamp[end...]
        var digits = ""
        if rest.first == "." {
            rest = rest.dropFirst()
            digits = String(rest.prefix { $0.isNumber })
            rest = rest.dropFirst(digits.count)
        }
        return String(stamp[..<end]) + "." + digits.padding(toLength: 9, withPad: "0", startingAt: 0) + rest
    }

    /// `2026-10-27T10:00:00.123456789Z` → its Unix second.
    nonisolated static func seconds(_ stamp: String) -> Int? {
        let whole = stamp.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        return ISO8601DateFormatter().date(from: whole).map { Int($0.timeIntervalSince1970) }
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
                for try await sample in engine.stats(id) {
                    guard let self else { return }
                    let usage = DockerUsage(sample)
                    self.usage = usage
                    self.history = Array((self.history + [usage]).suffix(60))
                }
            } catch {}
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
