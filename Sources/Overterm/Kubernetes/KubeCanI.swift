import Darwin
import Foundation

/// What `kubectl auth can-i` said.
enum KubeCanIAnswer: Equatable, Sendable {
    case yes
    /// No, with the server's reason when kubectl printed one (`no - RBAC: …`).
    case no(String?)
    /// It couldn't be asked: no kubectl, a credential failure, a timeout.
    case failed(String)

    var allowed: Bool { self == .yes }
}

/// `kubectl auth can-i <verb> <resource> --context C -n NS` — a short-lived
/// process with Overterm's `KUBECONFIG` (the proxy's environment): its
/// arguments and what it says. kubectl prints `yes` and exits 0, or `no`
/// (with a reason after ` - `) and exits 1; an error goes to stderr. Pure.
enum KubeCanI {
    static func arguments(_ access: KubeAccess, context: String, namespace: String, cacheDirectory: String? = nil) -> [String] {
        var arguments = ["auth", "can-i", access.verb, access.resource, "--context", context, "-n", namespace]
        if let cacheDirectory { arguments += ["--cache-dir", cacheDirectory] }
        return arguments + ["--request-timeout=15s"]
    }

    static func parse(status: Int32, stdout: String, stderr: String) -> KubeCanIAnswer {
        let said = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let first = said.split(separator: "\n").first.map(String.init) ?? ""
        if status == 0, first.lowercased() == "yes" || first.lowercased().hasPrefix("yes ") { return .yes }
        let lower = first.lowercased()
        if lower == "no" || lower.hasPrefix("no ") || lower.hasPrefix("no-") {
            let reason = first.dropFirst(2).trimmingCharacters(in: CharacterSet(charactersIn: " -"))
            return .no(reason.isEmpty ? nil : reason)
        }
        let error = KubeProxyProblem.lastLine(of: stderr).map(Self.trimmed) ?? (said.isEmpty ? nil : first)
        return .failed(error ?? "kubectl auth can-i exited (\(status)).")
    }

    /// kubectl's `error: ` taken off the front.
    private static func trimmed(_ line: String) -> String {
        line.hasPrefix("error: ") ? String(line.dropFirst("error: ".count)) : line
    }
}

/// One question asked of `kubectl auth can-i`: a verb on a context's namespace.
struct KubeAccessKey: Hashable, Sendable {
    var context: String
    var namespace: String
    var access: KubeAccess
}

/// The answers, each kept a minute (a failure ten seconds: a sign-in put
/// right is seen soon). Pure over the clock it is given.
struct KubeAccessCache: Equatable, Sendable {
    static let answerLife: TimeInterval = 60
    static let failureLife: TimeInterval = 10

    private var entries: [KubeAccessKey: (answer: KubeCanIAnswer, at: Date)] = [:]

    func answer(for key: KubeAccessKey, now: Date) -> KubeCanIAnswer? {
        guard let entry = entries[key] else { return nil }
        return now.timeIntervalSince(entry.at) < Self.life(of: entry.answer) ? entry.answer : nil
    }

    /// Kept, and what has run out dropped: the cache holds only answers
    /// that still count.
    mutating func store(_ answer: KubeCanIAnswer, for key: KubeAccessKey, at now: Date) {
        entries = entries.filter { now.timeIntervalSince($0.value.at) < Self.life(of: $0.value.answer) }
        entries[key] = (answer, now)
    }

    var count: Int { entries.count }

    private static func life(of answer: KubeCanIAnswer) -> TimeInterval {
        if case .failed = answer { failureLife } else { answerLife }
    }

    /// Everything about a context goes (it is gone, or its kubeconfig changed).
    mutating func forget(context: String) {
        entries = entries.filter { $0.key.context != context }
    }

    static func == (lhs: KubeAccessCache, rhs: KubeAccessCache) -> Bool {
        lhs.entries.mapValues(\.answer) == rhs.entries.mapValues(\.answer) && lhs.entries.mapValues(\.at) == rhs.entries.mapValues(\.at)
    }
}

/// Where a verb stands for a context's namespace, as a menu greys it.
enum KubeAccessState: Equatable {
    /// Not asked yet, or asked over a minute ago.
    case unknown
    case checking
    case answered(KubeCanIAnswer)

    /// Why the verb can't be used now (`ResourceVerb.unavailable`); nil when it can.
    /// `review`: asked of the API's access review (a write), not kubectl.
    func unavailable(_ access: KubeAccess, namespace: String, review: Bool = false) -> String? {
        if review {
            let place = namespace.isEmpty ? "cluster-wide" : "in \(namespace)"
            switch self {
            case .unknown, .checking: return "Checking whether you may \(access) \(place)…"
            case .answered(.yes): return nil
            case .answered(.no(let reason)):
                return "The cluster's access review says you may not \(access) \(place)" + (reason.map { ": \($0)" } ?? ".")
            case .answered(.failed(let reason)): return "Couldn't review access to \(access): \(reason)"
            }
        }
        switch self {
        case .unknown, .checking: return "Checking kubectl auth can-i \(access) in \(namespace)…"
        case .answered(.yes): return nil
        case .answered(.no(let reason)):
            return "kubectl auth can-i \(access) says no in \(namespace)" + (reason.map { ": \($0)" } ?? ".")
        case .answered(.failed(let reason)): return "Couldn't ask kubectl auth can-i \(access): \(reason)"
        }
    }
}

/// The app's `kubectl auth can-i` answers, a minute each per context,
/// namespace and verb: asked as a short-lived process (`run`), once per
/// question, its answer published for the verbs that wait on it. A
/// context's questions are asked one after another, never at once: each
/// runs the context's exec plugin, and three kubelogins at once is three
/// browser sign-ins (the third failing to bind its port). Forgotten for a
/// context the kubeconfig no longer has, or now names another cluster,
/// user, credential or class (`KubernetesModel`).
@MainActor
final class KubeAccessChecks: ObservableObject {
    typealias Run = @Sendable (KubeContext, String, KubeAccess) async -> KubeCanIAnswer

    @Published private(set) var cache = KubeAccessCache()
    /// Asks kubectl; a test's or a scenario's stands in.
    var run: Run
    var now: () -> Date = { Date() }
    /// How many times kubectl was asked, for the tests.
    private(set) var asked = 0
    private var asking: [KubeAccessKey: Task<KubeCanIAnswer, Never>] = [:]
    /// Each context's last question: the next waits for it.
    private var lastAsked: [String: Task<KubeCanIAnswer, Never>] = [:]

    init(run: @escaping Run) {
        self.run = run
    }

    func state(_ context: String, namespace: String, _ access: KubeAccess) -> KubeAccessState {
        let key = KubeAccessKey(context: context, namespace: namespace, access: access)
        if let answer = cache.answer(for: key, now: now()) { return .answered(answer) }
        return asking[key] != nil ? .checking : .unknown
    }

    /// Asked, unless it is known or being asked. Publishes nothing until
    /// the answer comes: safe from inside a view's update.
    func check(_ context: KubeContext, namespace: String, _ access: KubeAccess) {
        _ = task(context, namespace: namespace, access)
    }

    /// The answer, asked when it isn't known.
    func answer(_ context: KubeContext, namespace: String, _ access: KubeAccess) async -> KubeCanIAnswer {
        await task(context, namespace: namespace, access).value
    }

    private func task(_ context: KubeContext, namespace: String, _ access: KubeAccess) -> Task<KubeCanIAnswer, Never> {
        let key = KubeAccessKey(context: context.name, namespace: namespace, access: access)
        if let answer = cache.answer(for: key, now: now()) { return Task { answer } }
        if let running = asking[key] { return running }
        asked += 1
        let run = self.run
        let previous = lastAsked[context.name]
        let task = Task { [weak self] () -> KubeCanIAnswer in
            _ = await previous?.value
            let answer = await run(context, namespace, access)
            guard let self else { return answer }
            self.asking[key] = nil
            self.cache.store(answer, for: key, at: self.now())
            return answer
        }
        asking[key] = task
        lastAsked[context.name] = task
        return task
    }

    func forget(context: String) {
        cache.forget(context: context)
    }
}

/// `kubectl auth can-i` run for real: the kubectl and the environment a
/// context's proxy would get (`KubeProxyPlanner.tool` — Overterm's
/// kubeconfig files, guarded only OVERTERM_KUBECONFIG's, the run's own
/// HOME), `--context` and `-n` always, on a GCD thread, given 20 seconds.
/// Under the proxies' credential rules when given them
/// (`KubeProxies.beginShortLived`): a stopped context starts nothing, an
/// oidc sign-in waits for any other, and a credential failure stops the
/// context as a proxy's does.
enum KubeCanIRunner {
    static let timeout: TimeInterval = 20

    static func run(
        _ context: KubeContext, namespace: String, _ access: KubeAccess, configuration: KubeProxies.Configuration,
        planner: KubeProxyPlanner = KubeProxyPlanner(), proxies: KubeProxies? = nil
    ) async -> KubeCanIAnswer {
        let holds: Bool
        do {
            holds = try await proxies?.beginShortLived(context) ?? false
        } catch let problem as KubeProxyProblem {
            return .failed(problem.reason)
        } catch {
            return .failed(error.localizedDescription)
        }
        let (answer, problem) = await ask(context, namespace: namespace, access, configuration: configuration, planner: planner)
        let answered = if case .failed = answer { false } else { true }
        await proxies?.endShortLived(context.name, holds: holds, problem: problem, answered: answered)
        return answer
    }

    /// The answer, and the credential problem kubectl's failure was, if any.
    private static func ask(
        _ context: KubeContext, namespace: String, _ access: KubeAccess, configuration: KubeProxies.Configuration, planner: KubeProxyPlanner
    ) async -> (KubeCanIAnswer, KubeProxyProblem?) {
        let tool: KubectlTool
        do {
            tool = try await planner.tool(context, configuration: configuration, serverMinor: nil)
        } catch let problem as KubeProxyProblem {
            return (.failed(problem.reason), problem)
        } catch {
            return (.failed(error.localizedDescription), nil)
        }
        let arguments = KubeCanI.arguments(access, context: context.name, namespace: namespace, cacheDirectory: tool.cacheDirectory)
        let result = await KubeBlocking.run { KubeProcessRun.run(tool.kubectl, arguments, environment: tool.environment, timeout: timeout) }
        guard let result else { return (.failed("kubectl auth can-i didn't answer in \(Int(timeout)) seconds."), nil) }
        let answer = KubeCanI.parse(status: result.status, stdout: result.stdout, stderr: result.stderr)
        guard case .failed = answer else { return (answer, nil) }
        return (answer, KubeCanI.credentialProblem(stderr: result.stderr, signIn: KubeSignIn(context.auth)))
    }
}

extension KubeCanI {
    /// kubectl's stderr read as the proxy's error is (`KubeProxyProblem.classify`):
    /// the credential failures that stop a context; nil for anything else
    /// (a 401 from the server, the network).
    static func credentialProblem(stderr: String, signIn: KubeSignIn) -> KubeProxyProblem? {
        guard let line = KubeProxyProblem.lastLine(of: stderr) else { return nil }
        let said = line.hasPrefix("error: ") ? String(line.dropFirst("error: ".count)) : line
        let problem = KubeProxyProblem.classify(status: 500, contentType: nil, text: said, stderr: stderr, signIn: signIn)
        return problem?.stopsRequests == true ? problem : nil
    }
}

/// A short-lived process: its exit status and what it wrote, or nil when
/// it couldn't start or didn't end in time. It starts in a process group
/// of its own — an exec plugin it runs (kubelogin listening on
/// 127.0.0.1:8000, aws, gke-gcloud-auth-plugin) is in it too — and the
/// group is ended when it is done, timed out (SIGTERM, then SIGKILL) or
/// not, so nothing it started outlives it. Every one running is known
/// (`livePIDs`) and ended at quit (`stopAll`), by its group's id — never
/// by a pattern.
enum KubeProcessRun {
    struct Result: Sendable {
        var status: Int32
        var stdout: String
        var stderr: String
        /// Its output went past the limit: what came is the start of it.
        var truncated = false
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var running: Set<pid_t> = []

    /// The ones running now (each its group's id), for tests.
    static var livePIDs: [pid_t] { lock.withLock { running.sorted() } }

    /// Every one still running, its whole group: at quit.
    static func stopAll() {
        // Under the lock: a run reaps its process only after taking it out
        // of `running`, so the group's id can't be another's yet.
        lock.withLock {
            for pid in running { killpg(pid, SIGKILL) }
            running = []
        }
    }

    /// `input`, when given, is its stdin — written through a pipe, never a
    /// file (a release's values for `helm template --values -`); else stdin
    /// is /dev/null.
    static func run(
        _ executable: URL, _ arguments: [String], environment: [String: String], timeout: TimeInterval, outputLimit: Int = 64 * 1024,
        input: Data? = nil
    ) -> Result? {
        let out = Pipe()
        let err = Pipe()
        let stdin = input.map { _ in Pipe() }
        let outReader = PipeReader(out, limit: outputLimit)
        let errReader = PipeReader(err, limit: 64 * 1024)
        let pid = lock.withLock { () -> pid_t? in
            guard
                let pid = spawn(
                    executable, arguments, environment, stdout: out.fileHandleForWriting.fileDescriptor,
                    stderr: err.fileHandleForWriting.fileDescriptor, stdin: stdin?.fileHandleForReading.fileDescriptor)
            else { return nil }
            running.insert(pid)
            return pid
        }
        try? out.fileHandleForWriting.close()
        try? err.fileHandleForWriting.close()
        if let stdin {
            try? stdin.fileHandleForReading.close()
            if pid != nil, let input { feed(input, to: stdin.fileHandleForWriting) } else { try? stdin.fileHandleForWriting.close() }
        }
        guard let pid else {
            outReader.finish(waitingUntil: .now())
            errReader.finish(waitingUntil: .now())
            return nil
        }
        let ended = waitForExit(pid, until: Date().addingTimeInterval(timeout))
        if !ended {
            lock.withLock { _ = killpg(pid, SIGTERM) }
            _ = waitForExit(pid, until: Date().addingTimeInterval(2))
        }
        // Whatever it started and left: the group goes with it. The leader
        // isn't reaped yet, so the group's id is still its own.
        lock.withLock {
            if running.remove(pid) != nil { killpg(pid, SIGKILL) }
        }
        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
        guard ended else {
            outReader.finish(waitingUntil: .now())
            errReader.finish(waitingUntil: .now())
            return nil
        }
        outReader.finish(waitingUntil: .now() + 2)
        errReader.finish(waitingUntil: .now() + 2)
        return Result(
            status: exitStatus(status), stdout: String(decoding: outReader.data, as: UTF8.self), stderr: String(decoding: errReader.data, as: UTF8.self),
            truncated: outReader.reachedLimit)
    }

    /// `data` written to a child's stdin and the pipe closed, on a thread of
    /// its own (a pipe holds 64 KB: the child reads as it is written). A
    /// child that exits first only ends the write (EPIPE: SIGPIPE is
    /// ignored for writes to a pipe here, `F_SETNOSIGPIPE`).
    private static func feed(_ data: Data, to handle: FileHandle) {
        _ = fcntl(handle.fileDescriptor, F_SETNOSIGPIPE, 1)
        let block: @Sendable () -> Void = {
            data.withUnsafeBytes { buffer in
                guard var base = buffer.baseAddress else { return }
                var left = buffer.count
                while left > 0 {
                    let wrote = write(handle.fileDescriptor, base, left)
                    if wrote < 0 {
                        if errno == EINTR { continue }
                        break
                    }
                    left -= wrote
                    base = base.advanced(by: wrote)
                }
            }
            try? handle.close()
        }
        DispatchQueue.global(qos: .userInitiated).async(execute: block)
    }

    /// The exit code, or 128 + the signal that ended it, as a shell says it.
    static func exitStatus(_ status: Int32) -> Int32 {
        let signal = status & 0x7f
        return signal == 0 ? (status >> 8) & 0xff : 128 + signal
    }

    /// Whether it has exited by `deadline` — left unreaped (`WNOWAIT`).
    private static func waitForExit(_ pid: pid_t, until deadline: Date) -> Bool {
        while true {
            var info = siginfo_t()
            if waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT) == 0, info.si_pid == pid { return true }
            if Date() >= deadline { return false }
            usleep(20_000)
        }
    }

    /// posix_spawn into a new process group: stdin /dev/null, the two
    /// pipes for stdout and stderr, no other descriptor of the app's, the
    /// signals as a new process has them.
    private static func spawn(
        _ executable: URL, _ arguments: [String], _ environment: [String: String], stdout: Int32, stderr: Int32, stdin: Int32? = nil
    ) -> pid_t? {
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        if let stdin {
            posix_spawn_file_actions_adddup2(&actions, stdin, 0)
        } else {
            posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        }
        posix_spawn_file_actions_adddup2(&actions, stdout, 1)
        posix_spawn_file_actions_adddup2(&actions, stderr, 2)
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(
            &attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        posix_spawnattr_setpgroup(&attributes, 0)
        var defaults = sigset_t()
        sigemptyset(&defaults)
        for signal in [SIGPIPE, SIGINT, SIGTERM, SIGHUP, SIGQUIT, SIGTSTP, SIGTTIN, SIGTTOU, SIGCHLD, SIGALRM, SIGUSR1, SIGUSR2] {
            sigaddset(&defaults, signal)
        }
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        var unblocked = sigset_t()
        sigemptyset(&unblocked)
        posix_spawnattr_setsigmask(&attributes, &unblocked)
        let argv = ([executable.path] + arguments).map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        var pid: pid_t = 0
        let failed = posix_spawn(&pid, executable.path, &actions, &attributes, argv, envp)
        return failed == 0 ? pid : nil
    }
}
