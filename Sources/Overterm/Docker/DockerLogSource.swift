import Foundation

/// A container's log as a follower reads it (`LogFollower`): the engine's
/// stream, its frames read and its lines parsed off the main actor; after
/// a time, from that second (`since` is whole seconds) — the follower
/// drops what it already has.
@MainActor
final class DockerLogSource: LogSource {
    let id: String
    /// Its compose service, in a project's merged logs.
    let service: String?
    /// A TTY's output comes plain, the rest framed; the detail says, or
    /// the engine is asked once.
    var tty: Bool?
    private let docker: DockerModel

    init(id: String, service: String? = nil, tty: Bool? = nil, docker: DockerModel) {
        self.id = id
        self.service = service
        self.tty = tty
        self.docker = docker
    }

    func follow(tail: Int, after: String?) async -> AsyncThrowingStream<[LogLine], any Error>? {
        guard let engine = docker.engine else { return nil }
        if tty == nil { tty = try? await engine.container(id).Config.Tty }
        // Stopped while that was read: no stream is opened after all.
        guard !Task.isCancelled else { return nil }
        let since = after.flatMap(LogFeed.seconds)
        let chunks = engine.logs(id, tty: tty ?? false, tail: since == nil ? tail : 1000, follow: true, since: since)
        return Self.lines(of: chunks, service: service)
    }

    /// Ended by a restart whose start came first: followed again.
    func followsAgain() async -> Bool {
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled, let engine = docker.engine else { return false }
        return (try? await engine.container(id).State.Running) == true
    }

    /// `chunks` as lines — nonisolated, so parsed on the cooperative pool
    /// (JSON, nine patterns a line). Its consumer cancelled, the engine's
    /// stream is too.
    nonisolated private static func lines(
        of chunks: AsyncThrowingStream<[DockerLogChunk], any Error>, service: String?
    ) -> AsyncThrowingStream<[LogLine], any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await piece in chunks {
                        continuation.yield(piece.flatMap { LogLine.lines(of: $0, timestamps: true, source: service) })
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }
}
