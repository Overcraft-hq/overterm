import Combine
import Foundation

/// The build a detail shows, followed while it shows: BuildKit's progress
/// through `docker buildx history logs --progress rawjson <ref>` — a
/// finished record's replayed, a running one's from its start until it
/// ends. BuildKit answers from the record once it is written, from the
/// running job before; either way it replays from the start, so a follow
/// stopped (the detail hidden) reads it all again when it shows.
@MainActor
final class DockerBuildSession: ObservableObject {
    enum State: Equatable {
        case idle, reading, ended, stopped
        case failed(String)
    }

    /// The record's own id (`DockerBuildRecord.shortRef`).
    let ref: String
    @Published private(set) var state: State = .idle
    /// `buildx history inspect`'s answer. Until it has come, nothing of
    /// the steps is drawn or copied: a secret build arg's value is taken
    /// out of them by what it says (`secretsKnown`).
    @Published private(set) var detail: DockerBuildDetail?
    /// The inspect didn't answer, asked again and again: the steps stay
    /// hidden, and showing the detail again asks once more.
    @Published private(set) var detailFailed = false
    /// What the list says of the record: polled, so fresher than the
    /// detail's status, and there when the detail isn't.
    @Published private(set) var recordRunning: Bool
    /// Bumped when `progress` changed — at most every `publishInterval`:
    /// a big build sends hundreds of messages a second.
    @Published private(set) var revision = 0
    /// A step the user chose; nil follows the build.
    @Published var picked: String?
    /// Not @Published: one owner, and no copy of every step's output each
    /// time it is.
    private(set) var progress = DockerBuildProgress()
    /// Bumped by each read: the log view draws its text again rather than
    /// adding to what an earlier read drew.
    private(set) var generation = 0
    /// The stream ended: the list reads the record's end at once.
    var onEnd: (() -> Void)?

    static let publishInterval: TimeInterval = 0.2
    /// Between two asks of the inspect: one that didn't answer, or one
    /// that still said running once the stream had ended.
    static let detailRetry: TimeInterval = 0.5

    private let cli: DockerCLI?
    private var reading: Task<Void, Never>?
    private var detailRead: Task<Void, Never>?
    /// Which detail read is the last: an older one that ends says nothing.
    private var detailReads = 0
    private var lastPublish = Date.distantPast
    private var publishPending = false

    /// `running`: what the list says of its record.
    init(ref: String, cli: DockerCLI?, running: Bool = false) {
        self.ref = ref
        self.cli = cli
        self.recordRunning = running
    }

    /// Reads while `shown`; hidden, the follow stops — its process
    /// terminated. An ended stream is final. The inspect is asked until it
    /// answers; shown again, once more if it never did.
    func follow(shown: Bool) {
        guard shown else {
            if state == .reading {
                reading?.cancel()
                reading = nil
                state = .stopped
            }
            return
        }
        if detail == nil, detailRead == nil { readDetail() }
        switch state {
        case .idle, .stopped, .failed: read()
        case .reading, .ended: break
        }
    }

    /// The list read again: what the record says now. One seen running
    /// that is over has its inspect asked again once the stream is too —
    /// BuildKit writes the error into the record only after the stream
    /// has ended, and an inspect asked before that says "running".
    func record(running: Bool) {
        guard running != recordRunning else { return }
        recordRunning = running
        guard !running, streamOver, detail == nil || detail?.status == "running" else { return }
        readDetail(settling: true)
    }

    private var streamOver: Bool {
        switch state {
        case .ended, .failed: true
        case .idle, .reading, .stopped: false
        }
    }

    func close() {
        follow(shown: false)
        detailRead?.cancel()
        onEnd = nil
    }

    /// The step the detail shows: the one picked, else the build's own
    /// (`automaticStep`).
    var shownStep: DockerBuildProgress.Step? {
        picked.flatMap(progress.step) ?? progress.automaticStep
    }

    /// Whether the build args have been read, so a secret one's value can
    /// be taken out of what the steps say: nothing of them is drawn or
    /// copied before.
    var secretsKnown: Bool { detail != nil }

    /// Text of the build as shown: a secret build arg's value taken out.
    func shown(_ text: String) -> String { DockerSecrets.redact(text, values: detail?.secrets ?? []) }

    /// Copy Log's: the steps as plain progress, secrets out. Nil until
    /// they are known.
    var plainText: String? { secretsKnown ? progress.plainText(redacting: detail?.secrets ?? []) : nil }

    /// Whether BuildKit is still at it: the stream goes on and the record
    /// says so — a finished record's replay is not a build running, nor
    /// one whose inspect hasn't answered.
    var isRunning: Bool { state == .reading && (recordRunning || detail?.status == "running") }

    /// `Running · 14.2 s · 6 done, 2 cached, 1 running`, `Failed at #7 ·
    /// 1.7 s · 7 steps, 2 cached`.
    func summaryLine(now: Date) -> String {
        let summary = progress.summary
        guard summary.steps > 0 else {
            switch state {
            case .idle, .reading: return "Reading the build…"
            case .failed(let why): return shown(why)
            case .ended, .stopped: return "No steps recorded."
            }
        }
        // Why is said above the steps (`DockerBuildStepsView`): a line
        // this short has no room for buildx's error.
        if case .failed = state {
            return ["Couldn't follow it", progress.elapsed(now: now).map(DockerBuildRecord.duration), Self.steps(summary)].compactMap { $0 }
                .joined(separator: " · ")
        }
        let running = isRunning
        let time = (running ? progress.elapsed(now: now) : progress.elapsed(now: summary.finished ?? now)).map(DockerBuildRecord.duration)
        let counts: String
        let head: String
        if running {
            head = "Running"
            counts = [
                "\(summary.done) done", summary.cached > 0 ? "\(summary.cached) cached" : nil, "\(summary.running) running",
                summary.failed > 0 ? "\(summary.failed) failed" : nil,
            ]
            .compactMap { $0 }.joined(separator: ", ")
        } else {
            if let failed = progress.failedStep {
                head = "Failed at #\(failed.number)"
            } else if summary.canceled > 0 || detail?.status == "canceled" {
                head = "Canceled"
            } else if detail?.status == "failed" {
                // Before any step: the frontend, a missing context.
                head = "Failed"
            } else if state == .stopped {
                head = "Stopped following"
            } else {
                head = state == .reading ? "Reading" : "Built"
            }
            counts = Self.steps(summary)
        }
        return [head, time, counts].compactMap { $0 }.joined(separator: " · ")
    }

    /// `7 steps, 2 cached`.
    private static func steps(_ summary: DockerBuildProgress.Summary) -> String {
        "\(summary.steps) \(summary.steps == 1 ? "step" : "steps")" + (summary.cached > 0 ? ", \(summary.cached) cached" : "")
    }

    // MARK: Reading

    private func read() {
        progress = DockerBuildProgress()
        generation += 1
        state = .reading
        publish()
        guard let cli else {
            state = .failed("docker isn't on this Mac: builds are read with docker buildx.")
            return
        }
        let generation = generation
        let ref = ref
        reading = Task.detached { [weak self] in
            do {
                for try await lines in cli.lines(["buildx", "history", "logs", "--progress", "rawjson", ref]) {
                    // JSON, base64 and times decoded here, off the main thread.
                    let updates = lines.compactMap(DockerBuildProgress.decode)
                    guard !updates.isEmpty else { continue }
                    guard let self else { return }
                    await self.apply(updates, generation: generation)
                }
                await self?.finished(generation: generation)
            } catch is CancellationError {
            } catch {
                let said = error.localizedDescription
                await self?.failed(generation: generation, said: said)
            }
        }
    }

    private func apply(_ updates: [DockerBuildProgress.Update], generation: Int) {
        guard generation == self.generation, state == .reading else { return }
        for update in updates { progress.apply(update) }
        schedulePublish()
    }

    /// buildx gave up: its last words, the steps read so far kept — those
    /// still open no longer drawn as running, since nothing would say when
    /// they stop.
    private func failed(generation: Int, said: String) {
        guard generation == self.generation, state == .reading else { return }
        reading = nil
        progress.lose()
        state = .failed(progress.said.last ?? said)
        publish()
    }

    private func finished(generation: Int) {
        guard generation == self.generation, state == .reading else { return }
        reading = nil
        progress.end()
        publish()
        state = .ended
        // How it ended: its error, where in the Dockerfile — once BuildKit
        // has written them, after the stream's end.
        readDetail(settling: true)
        onEnd?()
    }

    /// Now, if `publishInterval` has passed since the last; else once, then.
    private func schedulePublish() {
        let since = Date().timeIntervalSince(lastPublish)
        if since >= Self.publishInterval { return publish() }
        guard !publishPending else { return }
        publishPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + (Self.publishInterval - since)) { [weak self] in
            guard let self else { return }
            self.publishPending = false
            self.publish()
        }
    }

    private func publish() {
        lastPublish = Date()
        revision += 1
    }

    /// Asks the inspect up to three times, `detailRetry` apart, until it
    /// answers; `settling`, up to five, until it says the build is over —
    /// BuildKit writes the record's end a moment after the stream's.
    private func readDetail(settling: Bool = false) {
        guard let cli else { return }
        let ref = ref
        detailRead?.cancel()
        detailReads += 1
        let token = detailReads
        if detailFailed { detailFailed = false }
        detailRead = Task { [weak self] in
            for attempt in 0..<(settling ? 5 : 3) {
                if attempt > 0 { try? await Task.sleep(for: .seconds(Self.detailRetry)) }
                guard !Task.isCancelled else { return }
                let read = await DockerBuildDetail.read(ref, cli: cli)
                guard !Task.isCancelled, let self else { return }
                if let read {
                    // `==` leaves the secrets out: compared apart.
                    if read != self.detail || self.detail?.secrets != read.secrets { self.detail = read }
                    if !settling || read.status != "running" { break }
                }
            }
            guard let self, self.detailReads == token else { return }
            self.detailRead = nil
            if self.detail == nil { self.detailFailed = true }
        }
    }
}
