import Combine
import Foundation

/// Where Apple's `container` is: where its installer puts it, else
/// Homebrew's — never a `container` found on the PATH, which may be any
/// other program of that name. A guarded run (isolated, or a unit test)
/// reaches none but the stand-in a test names: a scenario must never list
/// the user's containers, let alone stop one.
package enum AppleContainerCLI {
    package static let installed = ["/usr/local/bin/container", "/opt/homebrew/bin/container"]

    /// A unit test's stand-in, used only while guarded.
    package nonisolated(unsafe) static var override: URL?

    /// `variable`: OVERTERM_APPLE_CONTAINER, an absolute path to an
    /// executable — read only while guarded, ignored in the user's app.
    package static func binary(
        variable: String?, guarded: Bool, isExecutable: (String) -> Bool = FileManager.default.isExecutableFile
    ) -> URL? {
        if guarded {
            if let override { return override }
            guard let variable, variable.hasPrefix("/"), isExecutable(variable) else { return nil }
            return URL(fileURLWithPath: variable)
        }
        return installed.first(where: isExecutable).map { URL(fileURLWithPath: $0) }
    }

    /// Runs it, its stdout back. `success`: `system status` exits 1 when
    /// its service isn't running, and says so in JSON.
    package static func run(_ tool: URL, _ arguments: [String], success: Set<Int32> = [0], timeout: TimeInterval = 20) async throws -> Data {
        let output = try await DockerCLI(executable: tool, endpoint: nil).run(arguments, success: success, timeout: timeout)
        return Data(output.utf8)
    }
}

extension AppEnvironment {
    /// Apple's `container`, as `AppleContainerCLI.binary` finds it.
    package static var appleContainerBinary: URL? {
        AppleContainerCLI.binary(variable: env["OVERTERM_APPLE_CONTAINER"], guarded: isIsolated || isUnitTest)
    }
}

/// Apple's containers, images and volumes, for the Docker page's Apple
/// Containers section: one for the app. Read only while a page shows the
/// section (`want`): the tool sends no events, so the lists are read again
/// every few seconds then — a process a read, three at most — and after
/// each thing done here. Nothing is read while nobody looks.
@MainActor
package final class AppleContainerModel: ObservableObject {
    package static let shared = AppleContainerModel()

    package enum Part: Hashable, Sendable { case containers, images, volumes }

    /// The tool, found again when a page comes to the section: installed
    /// or removed while the app runs.
    @Published package private(set) var tool: URL?
    /// Its service: nil before the first read.
    @Published package private(set) var service: AppleContainers.Service?
    @Published package private(set) var containers: [AppleContainers.Container] = []
    @Published package private(set) var images: [AppleContainers.Image] = []
    @Published package private(set) var volumes: [AppleContainers.Volume] = []
    /// Which parts have been read since the service last came up.
    @Published package private(set) var read: Set<Part> = []
    /// What the last read or action said when it failed, until dismissed
    /// or the next read that works.
    @Published package var error: String?
    /// Containers, images or volumes with an action on its way, by id.
    @Published package private(set) var busy: Set<String> = []

    private let locate: () -> URL?
    /// Between reads while wanted; a test's shorter.
    package var interval: Duration
    private var wants: [Part: Int] = [:]
    private var poll: Task<Void, Never>?

    package init(locate: @escaping () -> URL? = { AppEnvironment.appleContainerBinary }, interval: Duration = .seconds(3)) {
        self.locate = locate
        self.interval = interval
        tool = locate()
    }

    /// Whether the tool is there: the section is listed only then.
    package var isInstalled: Bool { tool != nil }

    /// Looks for the tool again — a page coming to the section.
    package func relocate() {
        let found = locate()
        if found != tool { tool = found }
    }

    // MARK: Reading

    /// A page shows `part`: read now, and every few seconds until nobody does.
    package func want(_ part: Part) {
        wants[part, default: 0] += 1
        relocate()
        refresh()
        startPolling()
    }

    package func unwant(_ part: Part) {
        guard let count = wants[part] else { return }
        wants[part] = count > 1 ? count - 1 : nil
        if wants.isEmpty {
            poll?.cancel()
            poll = nil
        }
    }

    package var wanted: Set<Part> { Set(wants.keys) }

    private func startPolling() {
        guard poll == nil else { return }
        poll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: self?.interval ?? .seconds(3))
                guard !Task.isCancelled, let self else { return }
                await self.readNow()
            }
        }
    }

    private var reading: Task<Void, Never>?

    package func refresh() {
        Task { await readNow() }
    }

    /// Asked while a read ran: that read may have started before what is
    /// asked for now (an action's result, a part just wanted).
    private var readAgain = false

    /// Reads what is wanted now. One read at a time: asked while one runs,
    /// it waits for that one and for one more, started after it was asked.
    package func readNow() async {
        if let reading {
            readAgain = true
            return await reading.value
        }
        // The read lets go of itself as it ends — not its first caller once
        // it resumes, after which a call could find it finished and read
        // nothing.
        let task = Task {
            repeat {
                readAgain = false
                await read(wanted)
            } while readAgain
            reading = nil
        }
        reading = task
        await task.value
    }

    private func read(_ parts: Set<Part>) async {
        guard let tool else {
            service = nil
            clear()
            return
        }
        let service: AppleContainers.Service
        do {
            service = AppleContainers.service(from: try await AppleContainerCLI.run(tool, AppleContainerCommands.status, success: [0, 1], timeout: 15))
        } catch {
            service = .unreadable(Self.said(error))
        }
        if self.service != service { self.service = service }
        guard case .running = service else { return clear() }
        // Containers always: the section's count, and what images and
        // volumes are used by.
        var failed: String?
        do {
            let listed = AppleContainers.containers(from: try await AppleContainerCLI.run(tool, AppleContainerCommands.list))
            if listed != containers { containers = listed }
            read.insert(.containers)
        } catch { failed = "Containers: " + Self.said(error) }
        if parts.contains(.images) {
            do {
                let listed = AppleContainers.images(from: try await AppleContainerCLI.run(tool, AppleContainerCommands.images, timeout: 60))
                if listed != images { images = listed }
                read.insert(.images)
            } catch { failed = "Images: " + Self.said(error) }
        }
        if parts.contains(.volumes) {
            do {
                let listed = AppleContainers.volumes(from: try await AppleContainerCLI.run(tool, AppleContainerCommands.volumes))
                if listed != volumes { volumes = listed }
                read.insert(.volumes)
            } catch { failed = "Volumes: " + Self.said(error) }
        }
        if let failed {
            error = failed
        } else if error?.hasPrefix("Containers: ") == true || error?.hasPrefix("Images: ") == true || error?.hasPrefix("Volumes: ") == true {
            error = nil
        }
    }

    private func clear() {
        if !containers.isEmpty { containers = [] }
        if !images.isEmpty { images = [] }
        if !volumes.isEmpty { volumes = [] }
        if !read.isEmpty { read = [] }
    }

    /// What a failed run said: its own last lines, not the arguments.
    package nonisolated static func said(_ error: Error) -> String {
        if let error = error as? GitError {
            let text = error.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { return String(text.split(separator: "\n").last ?? Substring(text)) }
            return "container exited with \(error.status)"
        }
        return error.localizedDescription
    }

    // MARK: Acting

    /// Runs `arguments` for `id` (shown busy meanwhile), then reads again.
    /// `what`: how a failure begins — "Stop web".
    package func perform(_ arguments: [String], on id: String, what: String) {
        guard let tool else { return }
        busy.insert(id)
        Task {
            do {
                _ = try await AppleContainerCLI.run(tool, arguments, timeout: 60)
            } catch {
                self.error = "\(what): \(Self.said(error))"
            }
            self.busy.remove(id)
            await self.readNow()
        }
    }

    /// `container prune` and its kin: what they said, once done.
    package func prune(_ arguments: [String], then said: @escaping @MainActor (String) -> Void) {
        guard let tool else { return }
        Task {
            do {
                let output = String(decoding: try await AppleContainerCLI.run(tool, arguments, timeout: 120), as: UTF8.self)
                said(output.trimmingCharacters(in: .whitespacesAndNewlines))
            } catch {
                self.error = "Clean up: \(Self.said(error))"
            }
            await self.readNow()
        }
    }

    // MARK: Who uses what

    /// The containers made from `image`.
    package func containers(using image: AppleContainers.Image) -> [AppleContainers.Container] {
        containers.filter { $0.image == image.reference }
    }

    /// The containers that mount `volume`: by its source on the Mac, or
    /// its name where the tool puts a volume's.
    package func containers(mounting volume: AppleContainers.Volume) -> [AppleContainers.Container] {
        containers.filter { container in
            container.mounts.contains { mount in (volume.source.map { mount.source == $0 } ?? false) || mount.source == volume.name }
        }
    }
}

/// A container's log as `container logs --follow` writes it: plain lines,
/// no timestamps — so followed once, never again from a time (it would
/// show them all again); the section starts it afresh when the container
/// starts again.
@MainActor
package final class AppleContainerLogSource: LogSource {
    package let id: String
    private let tool: URL

    package init(id: String, tool: URL) {
        self.id = id
        self.tool = tool
    }

    package func follow(tail: Int, after: String?) async -> AsyncThrowingStream<[LogLine], any Error>? {
        Self.lines(DockerCLI(executable: tool, endpoint: nil).lines(["logs", "--follow", "-n", "\(tail)", id], from: .stdout))
    }

    package func followsAgain() async -> Bool { false }

    nonisolated private static func lines(_ raw: AsyncThrowingStream<[String], Error>) -> AsyncThrowingStream<[LogLine], any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await lines in raw {
                        continuation.yield(lines.map { LogLine.parse($0, stream: .stdout, timestamps: false) })
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

/// The selected container's Logs tab: its feed, followed while it shows.
@MainActor
package final class AppleContainerSession {
    package static let tail = 500
    package let id: String
    package let feed = LogFeed()
    private var follower: LogFollower?
    /// Whether it ran at the last look: a start follows its log afresh.
    private var wasRunning: Bool?

    package init(id: String) {
        self.id = id
    }

    /// Whether its log is being read for the tab now (or was, and ended).
    private var started = false

    /// Follows its log while `shown`: its last lines, then what comes.
    /// Shown again, or the container started again since the last look,
    /// it is read afresh, the old lines gone — without timestamps, lines
    /// read twice couldn't be told apart.
    package func follow(shown: Bool, running: Bool, tool: URL?) {
        let restarted = wasRunning == false && running
        wasRunning = running
        guard shown, let tool else {
            follower?.stop()
            started = false
            return
        }
        guard !started || restarted else { return }
        if follower == nil {
            let follower = LogFollower(source: AppleContainerLogSource(id: id, tool: tool), feed: feed, merging: false)
            follower.onChange = { [weak self, weak follower] in self?.feed.following = follower?.following ?? false }
            self.follower = follower
        }
        follower?.stop()
        feed.clear()
        feed.terminalCommand = AppleContainerCommands.followLogs(tool, of: id)
        started = true
        follower?.start(tail: Self.tail)
    }

    package func close() {
        follower?.stop()
        follower = nil
        started = false
    }
}
