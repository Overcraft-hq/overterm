import Combine
import Foundation

/// Log lines as the Logs tab shows them — one container's, or a compose
/// project's services' merged by time. The text view draws only what is
/// added at the end; anything else bumps `revision` and it draws it all.
@MainActor
final class DockerLogFeed: ObservableObject {
    @Published private(set) var lines: [DockerLogLine] = []
    @Published private(set) var revision = 0
    /// Something is followed now (a stream is open).
    @Published var following = false
    /// What follows the same log in a terminal tab, if anything does.
    var terminalCommand: String?

    static let keep = 5000

    /// Lines in the order they came: after the ones there.
    func append(_ added: [DockerLogLine]) {
        guard !added.isEmpty else { return }
        if lines.count + added.count > Self.keep {
            lines = Array((lines + added).suffix(Self.keep))
            revision += 1
        } else {
            lines += added
        }
    }

    /// Lines from one of several streams, in time order among the rest: at
    /// the end when they are the newest (the usual case), else merged and
    /// drawn again.
    func merge(_ added: [DockerLogLine]) {
        guard !added.isEmpty else { return }
        let last = lines.last.flatMap(\.timestamp).map(Self.sortable) ?? ""
        let first = added.first?.timestamp.map(Self.sortable) ?? ""
        if first >= last {
            append(added)
            return
        }
        lines = Array(Self.merged(lines, added).suffix(Self.keep))
        revision += 1
    }

    func clear() {
        lines = []
        revision += 1
    }

    /// Both in time order, stable for equal times. Pure.
    nonisolated static func merged(_ a: [DockerLogLine], _ b: [DockerLogLine]) -> [DockerLogLine] {
        var out: [DockerLogLine] = []
        out.reserveCapacity(a.count + b.count)
        var i = 0
        var j = 0
        while i < a.count || j < b.count {
            if j >= b.count || (i < a.count && sortable(a[i].timestamp ?? "") <= sortable(b[j].timestamp ?? "")) {
                out.append(a[i])
                i += 1
            } else {
                out.append(b[j])
                j += 1
            }
        }
        return out
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
}

/// One container's log followed into a feed: the last lines, then what
/// comes; followed again after a restart from where it stopped, nothing
/// twice. A container's session has one; a project's, one a service.
@MainActor
final class DockerLogFollower {
    let id: String
    let service: String?
    private let feed: DockerLogFeed
    private let docker: DockerModel
    private let merging: Bool
    private var task: Task<Void, Never>?
    private(set) var following = false
    /// The newest line's time, so a log followed again starts after it.
    private var lastStamp: String?
    var onChange: () -> Void = {}

    init(id: String, service: String? = nil, feed: DockerLogFeed, docker: DockerModel, merging: Bool) {
        self.id = id
        self.service = service
        self.feed = feed
        self.docker = docker
        self.merging = merging
    }

    func start(tail: Int, tty: Bool?) {
        task?.cancel()
        let since = lastStamp.flatMap(DockerLogFeed.seconds)
        task = Task { [weak self, docker, id, service] in
            guard let engine = docker.engine else { return }
            // A TTY's output comes plain, the rest framed; the detail says.
            var tty = tty
            if tty == nil { tty = try? await engine.container(id).Config.Tty }
            // Stopped while that was read: no stream is opened after all.
            guard !Task.isCancelled else { return }
            let stream = engine.logs(id, tty: tty ?? false, tail: since == nil ? tail : 1000, follow: true, since: since)
            self?.set(following: true)
            do {
                for try await chunks in stream {
                    guard let self else { return }
                    var added = chunks.flatMap { DockerLogLine.lines(of: $0, timestamps: true, service: service) }
                    // `since` is whole seconds: the lines already shown that second come again.
                    if let last = self.lastStamp.map(DockerLogFeed.sortable) { added.removeAll { DockerLogFeed.sortable($0.timestamp ?? "") <= last } }
                    guard !added.isEmpty else { continue }
                    self.lastStamp = added.last?.timestamp ?? self.lastStamp
                    if self.merging { self.feed.merge(added) } else { self.feed.append(added) }
                }
            } catch {}
            guard !Task.isCancelled else { return }
            self?.set(following: false)
            // Ended by a restart whose start came first: followed again.
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, (try? await engine.container(id).State.Running) == true else { return }
            self?.start(tail: tail, tty: tty)
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        set(following: false)
    }

    private func set(following: Bool) {
        self.following = following
        onChange()
    }
}
