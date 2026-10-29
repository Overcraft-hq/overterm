import Combine
import Foundation

/// What Scout has said on stderr so far — its last 32 KB, for its progress
/// and, when it fails, its last words. Fed on FileHandle's queue.
final class DockerScoutOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var said: String?
    private static let kept = 32 << 10

    /// Scout's latest line, when it changed.
    func append(_ chunk: Data) -> String? {
        lock.withLock {
            buffer.append(chunk)
            if buffer.count > Self.kept { buffer = Data(buffer.suffix(Self.kept)) }
            let line = DockerScout.progress(in: String(decoding: buffer, as: UTF8.self))
            guard let line, line != said else { return nil }
            said = line
            return line
        }
    }

    var text: String { lock.withLock { String(decoding: buffer, as: UTF8.self) } }
}

extension DockerScout {
    /// One scan: `docker scout cves --format sarif local://<image>` through
    /// `cli`, its progress handed over line by line, the report read off
    /// the main actor. Nil when it was cancelled. Every closure is made
    /// here, outside any actor: stderr is read on FileHandle's queue.
    nonisolated static func run(
        _ cli: DockerCLI, image: String, platform: String?, timeout: TimeInterval, progress: @escaping @Sendable (String) -> Void
    ) async -> Result<DockerScoutReport, DockerScoutFailure>? {
        let said = DockerScoutOutput()
        let minutes = max(1, Int((timeout / 60).rounded(.up)))
        do {
            let out = try await cli.run(
                arguments(for: image, platform: platform), timeout: timeout,
                stderr: { chunk in
                    if let line = said.append(chunk) { progress(line) }
                })
            guard var report = DockerScoutReport.parse(out) else {
                // Not a report: whatever it said instead — a sign-in, most likely.
                let failure = DockerScoutFailure.classify(status: 0, stderr: said.text, stdout: out, image: image, timeoutMinutes: minutes)
                if case .failed = failure, !out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .failure(.unreadable) }
                return .failure(failure)
            }
            report.packagesIndexed = indexedPackages(in: clean(said.text))
            return .success(report)
        } catch is CancellationError {
            return nil
        } catch let error as GitError {
            let stderr = error.stderr.isEmpty ? said.text : error.stderr
            return .failure(DockerScoutFailure.classify(status: error.status, stderr: stderr, stdout: "", image: image, timeoutMinutes: minutes))
        } catch {
            return .failure(.failed(error.localizedDescription))
        }
    }
}

/// The app's scans, by image ID: one at a time per image, several images
/// at once. Each only when the user asks — Scout sends the image's
/// packages to Docker's service, signed in as the user — and kept in
/// memory for the app's run: every window shows the same, and a rebuilt
/// image (another ID) starts unscanned. A scan goes on while the page
/// hides, as a pull does; Cancel stops it, and quitting stops them all.
@MainActor
final class DockerScoutScans: ObservableObject {
    static let shared = DockerScoutScans()

    struct Scan: Equatable {
        var imageID: String
        /// The name it was scanned by.
        var image: String
        var state: State
    }

    enum State: Equatable {
        case scanning(since: Date, progress: String?)
        case done(DockerScoutReport, at: Date)
        case failed(DockerScoutFailure, at: Date)

        var report: DockerScoutReport? {
            if case .done(let report, _) = self { return report }
            return nil
        }

        var isScanning: Bool {
            if case .scanning = self { return true }
            return false
        }

        /// When it started, or ended.
        var at: Date {
            switch self {
            case .scanning(let since, _): since
            case .done(_, let at), .failed(_, let at): at
            }
        }
    }

    @Published private(set) var scans: [String: Scan] = [:]
    /// A test's shorter one.
    var timeout = DockerScout.timeout
    /// The `docker` to run, nil when none may be: an isolated run's and a
    /// test's only a stub (`DockerScout.mayRunReal`).
    var locate: (DockerEndpoint?) -> DockerCLI? = { DockerScout.mayRunReal ? DockerCLI(endpoint: $0) : nil }
    private var tasks: [String: Task<Void, Never>] = [:]

    func scan(for imageID: String) -> Scan? { scans[imageID] }

    /// The scan of what an agent names: the image a tag means now (any of
    /// its tags), an image's ID (short, with or without `sha256:`), or —
    /// when no image holds the name any more — the latest scan by it. A
    /// tag that moved (a rebuild, a pull) means the new image, scanned or
    /// not: the old one's report is not its.
    func scan(matching wanted: String, images: [ImageSummary]) -> Scan? {
        let wanted = wanted.trimmingCharacters(in: .whitespaces)
        guard !wanted.isEmpty else { return nil }
        // A name without a tag is `:latest`, as Docker reads it (a
        // registry's port is not a tag).
        let tagged = wanted.split(separator: "/").last?.contains(":") == true
        let names = tagged ? [wanted] : [wanted, wanted + ":latest"]
        if let image = images.first(where: { $0.tags.contains(where: names.contains) }) { return scans[image.Id] }
        let bare = wanted.hasPrefix("sha256:") ? String(wanted.dropFirst("sha256:".count)) : wanted
        if bare.count >= 12, bare.allSatisfy(\.isHexDigit),
            let scan = scans.values.first(where: { $0.imageID.replacingOccurrences(of: "sha256:", with: "").hasPrefix(bare.lowercased()) })
        {
            return scan
        }
        return scans.values.filter { names.contains($0.image) }.max { $0.state.at < $1.state.at }
    }

    /// Scans it by `name`, unless it is being scanned. `platform`: the
    /// image's, when known; else its inspect is asked.
    func scan(imageID: String, name: String, endpoint: DockerEndpoint?, engine: DockerEngine?, platform: DockerPlatform? = nil) {
        guard scans[imageID]?.state.isScanning != true else { return }
        guard let cli = locate(endpoint) else {
            scans[imageID] = Scan(imageID: imageID, image: name, state: .failed(DockerScout.mayRunReal ? .noDocker : .isolated, at: Date()))
            return
        }
        scans[imageID] = Scan(imageID: imageID, image: name, state: .scanning(since: Date(), progress: nil))
        let timeout = timeout
        let progress = Self.progressSink(self, imageID)
        tasks[imageID] = Task { [weak self] in
            var known = platform
            if known == nil, let engine { known = try? await engine.platform(ofImage: imageID) }
            let outcome = await DockerScout.run(cli, image: name, platform: known?.description, timeout: timeout, progress: progress)
            guard !Task.isCancelled else { return }
            self?.finish(imageID, image: name, outcome)
        }
    }

    /// Stops it — Git.run's cancellation terminates Scout — and forgets it.
    func cancel(_ imageID: String) {
        tasks.removeValue(forKey: imageID)?.cancel()
        scans.removeValue(forKey: imageID)
    }

    /// At quit: no Scout outlives the app.
    func cancelAll() {
        for task in tasks.values { task.cancel() }
        tasks = [:]
        scans = scans.filter { !$0.value.state.isScanning }
    }

    /// Its result gone (a test's).
    func forget(_ imageID: String) { cancel(imageID) }

    /// The scan's end: nil (cancelled) forgets it. Internal for tests.
    func finish(_ imageID: String, image: String, _ outcome: Result<DockerScoutReport, DockerScoutFailure>?) {
        tasks.removeValue(forKey: imageID)
        guard let outcome else {
            scans.removeValue(forKey: imageID)
            return
        }
        switch outcome {
        case .success(let report): scans[imageID] = Scan(imageID: imageID, image: image, state: .done(report, at: Date()))
        case .failure(let failure): scans[imageID] = Scan(imageID: imageID, image: image, state: .failed(failure, at: Date()))
        }
    }

    /// Scout's latest line, while it scans.
    func update(_ imageID: String, progress: String) {
        guard var scan = scans[imageID], case .scanning(let since, let said) = scan.state, said != progress else { return }
        scan.state = .scanning(since: since, progress: progress)
        scans[imageID] = scan
    }

    /// Made outside the actor: Git's queue and FileHandle's call it
    /// (CLAUDE.md, completion handlers). The main queue keeps the lines
    /// in the order Scout said them.
    nonisolated private static func progressSink(_ scans: DockerScoutScans, _ id: String) -> @Sendable (String) -> Void {
        { [weak scans] line in
            let hop: @Sendable () -> Void = {
                MainActor.assumeIsolated { scans?.update(id, progress: line) }
            }
            DispatchQueue.main.async(execute: hop)
        }
    }
}
