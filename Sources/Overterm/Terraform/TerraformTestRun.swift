import Combine
import Darwin
import Foundation

extension Notification.Name {
    /// A root's `terraform test` ended: the editors lay its failures over
    /// the test files they name. `userInfo["files"]`: absolute paths, the
    /// ones marked before and now.
    static let terraformTestDiagnostics = Notification.Name("overterm.terraformTestDiagnostics")
}

/// One `terraform test` of a root (analysis 2.9, stage 2d, D-19): every
/// test file, or one, in the right slot — its runs listed before they
/// start, then each run's status, its failures at their lines, and the
/// same failures as diagnostics in the editor. Its stream read as it
/// comes (`TerraformStreamRun`), in the app's process group, its log in
/// memory only, scrubbed.
///
/// Only test files whose every provider is mocked run as a read: in the
/// stripped environment (no credential, `HOME` a scratch folder — the
/// providers start for their schemas, as validate's do), on any class. A
/// test with a real provider creates real infrastructure with the root's
/// credentials, so it is a write: refused on a read-only root, asked
/// everywhere else (the caller asks — `TerminalWindowController`), and run
/// in the user's environment. It takes no lock and touches none of the
/// root's state: a test's state lives in memory.
@MainActor
final class TerraformTestRun: ObservableObject, Identifiable {
    enum Phase: Equatable, Sendable {
        case preparing
        case running
        case passed(String)
        case failed(String)
        /// Refused before anything ran: why.
        case refused(String)
        case stopped
    }

    static let maxLog = 2_000

    let id = "tft-" + UUID().uuidString.prefix(8).lowercased()
    let checkout: URL
    let card: TerraformRootCard
    /// One test file, relative to the root; nil: all of them.
    let file: String?
    /// Who asked, when an agent's `tf_test` did.
    let agent: String?
    @Published private(set) var phase: Phase = .preparing
    @Published private(set) var report = TerraformTestReport()
    @Published private(set) var log: [String] = []
    /// What the files said before it ran: mocked, or why not.
    @Published private(set) var mocking: TerraformTestFiles.Mocking?
    let started = Date()
    @Published private(set) var finished: Date?
    private var pid: pid_t?
    private var stopping = false

    init(checkout: URL, card: TerraformRootCard, file: String? = nil, agent: String? = nil, mocking: TerraformTestFiles.Mocking? = nil) {
        self.checkout = checkout
        self.card = card
        self.file = file
        self.agent = agent
        self.mocking = mocking
    }

    /// A test with real providers (or whose code runs commands) still
    /// going: quitting would cut its cleanup off (`TerraformCloseGuard.testQuestion`).
    /// Not yet read counts as real.
    var isGoingReal: Bool { isGoing && mocking?.isMocked != true }

    var isGoing: Bool { phase == .preparing || phase == .running }

    var failed: Bool {
        if case .failed = phase { return true }
        return false
    }

    func age(now: Date = Date()) -> String {
        let seconds = Int(max(0, now.timeIntervalSince(finished ?? started)))
        if seconds < 60 { return "just now" }
        if seconds < 3_600 { return "\(seconds / 60) min ago" }
        return "\(seconds / 3_600) h ago"
    }

    /// The card's line about it at `now`, its age always said.
    func line(now: Date = Date()) -> String {
        switch phase {
        case .preparing, .running: "Testing…"
        case .passed(let said): "Tests passed — \(said) · \(age(now: now))"
        case .failed(let said): "Tests failed — \(said) · \(age(now: now))"
        case .refused(let why): "Test not run \(age(now: now)): \(why)"
        case .stopped: "Test stopped \(age(now: now))"
        }
    }

    /// What it runs, said: "tests/acme.tftest.hcl" or "every test file".
    var scope: String { file ?? "every test file" }

    /// Stops it: one SIGINT to its group, as Ctrl-C does.
    func stop() {
        guard isGoing else { return }
        stopping = true
        if let pid { TerraformStreamRun.interrupt(pid) }
    }

    func refuse(_ why: String) {
        phase = .refused(why)
        finished = Date()
        append(["Refused: " + why])
    }

    private func append(_ lines: [String]) {
        log.append(contentsOf: lines.map(TerraformPlan.scrub))
        if log.count > Self.maxLog { log.removeFirst(log.count - Self.maxLog) }
    }

    func absorb(_ messages: [TerraformUIMessage]) {
        var lines: [String] = []
        var report = self.report
        for message in messages {
            switch message {
            case .test(let test): report.absorb(test)
            case .diagnostic(let diagnostic): report.absorb(.diagnostic(file: nil, run: nil, diagnostic))
            default: break
            }
            lines.append(message.logLine)
        }
        if report != self.report { self.report = report }
        log.append(contentsOf: lines)
        if log.count > Self.maxLog { log.removeFirst(log.count - Self.maxLog) }
    }

    fileprivate func began(_ pid: pid_t) {
        self.pid = pid
        if stopping { TerraformStreamRun.interrupt(pid) }
    }

    // MARK: Before it runs

    /// What a run needs, read off the main thread: the test files and
    /// whether every provider they start is mocked, the binary, the
    /// environment's base and its scratch folder.
    struct Prepared: Sendable {
        var read: TerraformTestFiles.Read
        var binary: URL?
        var base: [String: String]?
        var scratch: TerraformGuards.Scratch?
    }

    /// Reads what `prepare` says, for `card`'s root. `binary`: a test's.
    nonisolated static func prepare(card: TerraformRootCard, checkout: URL, file: String?, settingPath: String, binary given: URL? = nil) async -> Prepared {
        let root = card.folder
        let hasVersionFile = card.facts.hasVersionFile
        return await TerraformPanelModel.blocking { () -> Prepared in
            Prepared(
                read: TerraformTestFiles.read(root: root, checkout: checkout, files: file.map { [$0] }),
                binary: given ?? TerraformCLI.binary(forRoot: root, settingPath: settingPath, hasVersionFile: hasVersionFile),
                base: try? AppEnvironment.terraformBaseEnvironment(),
                scratch: try? TerraformGuards.prepareScratch(at: AppEnvironment.terraformScratchDirectory))
        }
    }

    /// Why a test of `prepared` may not start in a root of `rootClass`,
    /// or nil; `real`: a real provider runs, which the caller asks about.
    static func refusal(_ prepared: Prepared, file: String?, rootClass: TerraformClass, writable: Bool, sessionWrites: Bool) -> String? {
        if let file, !TerraformCommands.isTestFile(file) { return "\(file) isn't a test file of the root (a .tftest.hcl inside it)." }
        if let outside = prepared.read.outside.first {
            return "\(outside) resolves outside the checkout (a link out of it): not read, not run."
        }
        guard !prepared.read.files.isEmpty || !prepared.read.unread.isEmpty else {
            return file.map { "\($0) isn't there, or couldn't be read." }
                ?? "No test files: terraform test reads *.tftest.hcl beside the root's files and under tests/."
        }
        if case .real = prepared.read.mocking,
            let why = TerraformProcessCheck.refused(.testRealProviders, rootClass: rootClass, writable: writable, sessionWrites: sessionWrites)
        {
            return "A test with real providers creates real infrastructure: \(why)"
        }
        return nil
    }

    /// What starting a test of `prepared` takes (5.3, 5.10, D-21).
    enum Gate: Equatable, Sendable {
        /// Every provider mocked, nothing in its code run: at once.
        case run
        /// Asked first, every time: what it says, and the name to type on production.
        case ask(TerraformPlanGate.Question)
        case refused(String)
    }

    /// Whether a test of `prepared` runs at once, is asked, or is refused.
    /// A real provider, or code that runs commands whatever is mocked, is
    /// a write: refused on a read-only root (`refusal`), never an agent's
    /// on production, asked everywhere else — naming the files, what is
    /// real, that quitting cuts its cleanup off — with the root's name
    /// typed on production.
    static func gate(_ prepared: Prepared, card: TerraformRootCard, file: String?, agent: String?, writable: Bool, sessionWrites: Bool) -> Gate {
        if let why = refusal(prepared, file: file, rootClass: card.rootClass, writable: writable, sessionWrites: sessionWrites) { return .refused(why) }
        guard case .real(let why) = prepared.read.mocking else { return .run }
        if agent != nil, card.isProduction {
            return .refused("\(card.name) is production: an agent's test with real providers isn't run there (\(why)).")
        }
        let typed = card.isProduction ? TerraformApplySheet.typedName(root: card.name, workspace: card.workspace) : nil
        var lines = [
            "\(why).",
            "terraform test then creates real infrastructure with the root's credentials (AWS_PROFILE and the rest of your environment), and runs what its code runs on this Mac; it destroys what it created after each file — unless a run fails to clean up.",
            "Quitting Overterm while it runs interrupts it: its cleanup may be cut off, leaving what it created.",
            "Files: " + (prepared.read.files.map(\.path) + prepared.read.unread).joined(separator: ", "),
        ]
        if !prepared.read.risks.isEmpty {
            lines.append("What its code runs or reaches:\n" + prepared.read.risks.prefix(20).map { "• " + $0.said }.joined(separator: "\n"))
        }
        if let agent { lines.append("Asked by \(agent), through MCP.") }
        if let typed { lines.append("Type \(typed) to run it.") }
        return .ask(
            TerraformPlanGate.Question(
                title: "Run \(card.name)'s tests with real providers?", detail: lines.joined(separator: "\n"), button: "Run Tests",
                production: card.isProduction, typedName: typed))
    }

    /// Starts a test of `card`'s root (every file, or `file`), its checks
    /// done: a run of the root still going — whatever its file — is
    /// shown again, and one being prepared refuses another, so none starts
    /// twice; an agent's starts no provider a committed, unchanged lock
    /// file doesn't pin (5.9, 5.10: every name its tests and modules
    /// start, mocked ones too); then `gate`, `ask` answering a question
    /// (false: declined, a failure with no message). `show` puts the run
    /// in the window's slot.
    static func begin(
        card: TerraformRootCard, checkout: URL, file: String?, agent: String?, writable: Bool, settingPath: String, binary: URL? = nil,
        results: TerraformTestResults = .shared, registry: TerraformRunRegistry = .shared, setup: TerraformWorktreeSetup = .shared,
        ask: (TerraformPlanGate.Question) async -> Bool, show: (TerraformTestRun) -> Void
    ) async -> Result<TerraformTestRun, TerraformReadFailure> {
        if let going = results.latest(checkout: checkout, root: card.path), going.isGoing {
            show(going)
            return .success(going)
        }
        // New Task's init without a backend is installing its providers now (2b).
        if let why = setup.refusal(card.folder) { return .failure(TerraformReadFailure(message: why)) }
        let key = TerraformRootStore.key(checkout: checkout, root: card.path)
        guard results.starting.insert(key).inserted else {
            return .failure(TerraformReadFailure(message: "A test of \(card.name) is starting already."))
        }
        defer { results.starting.remove(key) }
        let prepared = await prepare(card: card, checkout: checkout, file: file, settingPath: settingPath, binary: binary)
        let sessionWrites = registry.hasSessionWrites(checkout: checkout, root: card.path, workspace: card.workspace)
        let gate = gate(prepared, card: card, file: file, agent: agent, writable: writable, sessionWrites: sessionWrites)
        if case .refused(let why) = gate { return .failure(TerraformReadFailure(message: why)) }
        if agent != nil, !prepared.read.complete || !prepared.read.providerNames.subtracting(TerraformTestFiles.builtin).isEmpty,
            let why = await TerraformMCP.providersRefusal(root: card.folder, checkout: checkout)
        {
            return .failure(TerraformReadFailure(message: "needs init: \(why). Ask the person to run terraform init there — no tool runs it."))
        }
        if case .ask(let question) = gate, !(await ask(question)) { return .failure(TerraformReadFailure(message: "")) }
        let run = TerraformTestRun(checkout: checkout, card: card, file: file, agent: agent, mocking: prepared.read.mocking)
        results.add(run)
        show(run)
        Task { @MainActor in await run.start(prepared, results: results) }
        return .success(run)
    }

    // MARK: The run

    /// Runs it, its checks done and its question asked (the caller's):
    /// the stream read, the report built, the failures handed to the editor.
    func start(_ prepared: Prepared, results: TerraformTestResults = .shared) async {
        results.add(self)
        mocking = prepared.read.mocking
        report = TerraformTestReport(planned: prepared.read.files)
        guard let binary = prepared.binary else { return refuse("No terraform found: set Settings ▸ Terraform ▸ terraform, or install it.") }
        guard let base = prepared.base, let scratch = prepared.scratch else { return refuse("The environment for terraform couldn't be read.") }
        guard let arguments = TerraformCommands.test(file: file) else { return refuse("\(file ?? "?") isn't a test file of the root.") }
        guard !stopping else { return end(.stopped, results: results) }
        let root = card.folder
        if let why = TerraformWorktreeSetup.shared.refusal(root) { return refuse(why) }
        // Mocked: nothing to reach a cloud with (validate's environment).
        // Real providers: the user's, which the person was asked about.
        let purpose: TerraformEnvironment.Purpose = prepared.read.mocking.isMocked ? .validate : .run(workspace: nil, pluginCache: nil)
        let environment = TerraformEnvironment.build(base: base, purpose: purpose, root: root, scratch: scratch)
        phase = .running
        append(["terraform " + arguments.joined(separator: " ") + (prepared.read.mocking.isMocked ? "  (every provider mocked: no credentials)" : "")])
        let outcome = await Self.stream(binary, arguments, in: root, environment: environment, run: self)
        switch outcome {
        case .failure(let error):
            end(.failed(TerraformPlan.scrub("\(error)")), results: results)
        case .success(let result):
            if !result.stderr.isEmpty { append(result.stderr.split(separator: "\n").suffix(20).map(String.init)) }
            if stopping, result.status != 0 { return end(.stopped, results: results) }
            let said = report.summary?.said ?? "\(report.runs.filter { $0.status == .pass }.count) passed"
            if result.status == 0, report.summary?.status != "fail", report.summary?.status != "error", !report.runs.contains(where: { $0.status.isFailure }) {
                end(.passed(said), results: results)
            } else {
                let first = report.failures.first.flatMap { $0.diagnostics.first?.summary } ?? report.diagnostics.first?.summary
                end(.failed(said + (first.map { " — \($0)" } ?? "")), results: results)
            }
        }
    }

    private func end(_ phase: Phase, results: TerraformTestResults) {
        self.phase = phase
        finished = Date()
        results.ended(self)
    }

    nonisolated private static func stream(
        _ binary: URL, _ arguments: [String], in root: URL, environment: [String: String], run: TerraformTestRun
    ) async -> Result<TerraformStreamRun.Outcome, Error> {
        let pid: @Sendable (pid_t) -> Void = { pid in DispatchQueue.main.async { MainActor.assumeIsolated { run.began(pid) } } }
        let batch: @Sendable ([TerraformUIMessage]) -> Void = { messages in DispatchQueue.main.async { MainActor.assumeIsolated { run.absorb(messages) } } }
        let result = await withCheckedContinuation { (continuation: CheckedContinuation<Result<TerraformStreamRun.Outcome, Error>, Never>) in
            let work: @Sendable () -> Void = {
                continuation.resume(
                    returning: Result { try TerraformStreamRun.run(binary, arguments, in: root, environment: environment, started: pid, batch: batch) })
            }
            DispatchQueue.global(qos: .userInitiated).async(execute: work)
        }
        // The last batches were queued on the main queue before this: let them land.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let done: @Sendable () -> Void = { continuation.resume() }
            DispatchQueue.main.async(execute: done)
        }
        return result
    }
}

/// The app's `terraform test` runs (2.9), in memory: the newest of each
/// root, and the failures of each root's last finished run by the file
/// they name — what the editor lays over a test file's lines.
@MainActor
final class TerraformTestResults: ObservableObject {
    static let shared = TerraformTestResults()

    @Published private(set) var runs: [TerraformTestRun] = []
    static let keep = 20
    /// The roots (`key`) whose test is being prepared or asked about: one at a time.
    var starting: Set<String> = []

    /// Tests with real providers still going: what quitting asks about.
    var goingReal: [TerraformTestRun] { runs.filter(\.isGoingReal) }
    /// By absolute path (standardised): the last run's diagnostics of that file.
    private(set) var diagnostics: [String: [TerraformDiagnostic]] = [:]
    /// Which files each root's last run marked, by its run's root key.
    private var marked: [String: Set<String>] = [:]

    func add(_ run: TerraformTestRun) {
        guard !runs.contains(where: { $0 === run }) else { return }
        runs.append(run)
        if runs.count > Self.keep, let drop = runs.firstIndex(where: { !$0.isGoing }) { runs.remove(at: drop) }
    }

    /// The newest run of `root` in `checkout`.
    func latest(checkout: URL, root: String) -> TerraformTestRun? {
        let path = checkout.standardizedFileURL.path
        return runs.last { $0.card.path == root && $0.checkout.standardizedFileURL.path == path }
    }

    static func key(_ run: TerraformTestRun) -> String { TerraformRootStore.key(checkout: run.checkout, root: run.card.path) }

    /// A run ended: its failures replace its root's last ones, said to the editors.
    func ended(_ run: TerraformTestRun) {
        objectWillChange.send()
        let key = Self.key(run)
        let before = marked[key] ?? []
        for path in before { diagnostics[path] = nil }
        var now: Set<String> = []
        // A refused or stopped run read no file: the last run's marks go, nothing new comes.
        for (file, found) in run.report.placed {
            let path = run.card.folder.appendingPathComponent(file).standardizedFileURL.path
            diagnostics[path, default: []].append(contentsOf: found)
            now.insert(path)
        }
        marked[key] = now
        let files = Array(before.union(now))
        guard !files.isEmpty else { return }
        NotificationCenter.default.post(name: .terraformTestDiagnostics, object: self, userInfo: ["files": files])
    }

    /// The last run's diagnostics of `file`.
    func diagnostics(for file: URL) -> [TerraformDiagnostic] { diagnostics[file.standardizedFileURL.path] ?? [] }

    /// Forgets every run: a test's, a scenario's.
    func reset() {
        runs = []
        starting = []
        let files = Array(diagnostics.keys)
        diagnostics = [:]
        marked = [:]
        if !files.isEmpty { NotificationCenter.default.post(name: .terraformTestDiagnostics, object: self, userInfo: ["files": files]) }
    }
}
