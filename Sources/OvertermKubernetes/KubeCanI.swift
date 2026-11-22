import Darwin
import Foundation

/// What `kubectl auth can-i` said.
package enum KubeCanIAnswer: Equatable, Sendable {
    case yes
    /// No, with the server's reason when kubectl printed one (`no - RBAC: …`).
    case no(String?)
    /// It couldn't be asked: no kubectl, a credential failure, a timeout.
    case failed(String)

    package var allowed: Bool { self == .yes }
}

/// `kubectl auth can-i <verb> <resource> --context C -n NS` — a short-lived
/// process with Overterm's `KUBECONFIG` (the proxy's environment): its
/// arguments and what it says. kubectl prints `yes` and exits 0, or `no`
/// (with a reason after ` - `) and exits 1; an error goes to stderr. Pure.
package enum KubeCanI {
    package static func arguments(_ access: KubeAccess, context: String, namespace: String, cacheDirectory: String? = nil) -> [String] {
        var arguments = ["auth", "can-i", access.verb, access.resource, "--context", context, "-n", namespace]
        if let cacheDirectory { arguments += ["--cache-dir", cacheDirectory] }
        return arguments + ["--request-timeout=15s"]
    }

    package static func parse(status: Int32, stdout: String, stderr: String) -> KubeCanIAnswer {
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
package struct KubeAccessKey: Hashable, Sendable {
    package var context: String
    package var namespace: String
    package var access: KubeAccess
}

/// The answers, each kept a minute (a failure ten seconds: a sign-in put
/// right is seen soon). Pure over the clock it is given.
package struct KubeAccessCache: Equatable, Sendable {
    package static let answerLife: TimeInterval = 60
    package static let failureLife: TimeInterval = 10

    private var entries: [KubeAccessKey: (answer: KubeCanIAnswer, at: Date)] = [:]

    package func answer(for key: KubeAccessKey, now: Date) -> KubeCanIAnswer? {
        guard let entry = entries[key] else { return nil }
        return now.timeIntervalSince(entry.at) < Self.life(of: entry.answer) ? entry.answer : nil
    }

    /// Kept, and what has run out dropped: the cache holds only answers
    /// that still count.
    package mutating func store(_ answer: KubeCanIAnswer, for key: KubeAccessKey, at now: Date) {
        entries = entries.filter { now.timeIntervalSince($0.value.at) < Self.life(of: $0.value.answer) }
        entries[key] = (answer, now)
    }

    package var count: Int { entries.count }

    private static func life(of answer: KubeCanIAnswer) -> TimeInterval {
        if case .failed = answer { failureLife } else { answerLife }
    }

    /// Everything about a context goes (it is gone, or its kubeconfig changed).
    package mutating func forget(context: String) {
        entries = entries.filter { $0.key.context != context }
    }

    package static func == (lhs: KubeAccessCache, rhs: KubeAccessCache) -> Bool {
        lhs.entries.mapValues(\.answer) == rhs.entries.mapValues(\.answer) && lhs.entries.mapValues(\.at) == rhs.entries.mapValues(\.at)
    }
}

/// Where a verb stands for a context's namespace, as a menu greys it.
package enum KubeAccessState: Equatable {
    /// Not asked yet, or asked over a minute ago.
    case unknown
    case checking
    case answered(KubeCanIAnswer)

    /// Why the verb can't be used now (`ResourceVerb.unavailable`); nil when it can.
    /// `review`: asked of the API's access review (a write), not kubectl.
    package func unavailable(_ access: KubeAccess, namespace: String, review: Bool = false) -> String? {
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
            // The verdict first: a header cut at its end still says it was refused.
            return "Refused: kubectl auth can-i \(access) in \(namespace)" + (reason.map { ": \($0)" } ?? ".")
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
package final class KubeAccessChecks: ObservableObject {
    package typealias Run = @Sendable (KubeContext, String, KubeAccess) async -> KubeCanIAnswer

    @Published package private(set) var cache = KubeAccessCache()
    /// Asks kubectl; a test's or a scenario's stands in.
    package var run: Run
    package var now: () -> Date = { Date() }
    /// How many times kubectl was asked, for the tests.
    package private(set) var asked = 0
    private var asking: [KubeAccessKey: Task<KubeCanIAnswer, Never>] = [:]
    /// Each context's last question: the next waits for it.
    private var lastAsked: [String: Task<KubeCanIAnswer, Never>] = [:]

    package init(run: @escaping Run) {
        self.run = run
    }

    package func state(_ context: String, namespace: String, _ access: KubeAccess) -> KubeAccessState {
        let key = KubeAccessKey(context: context, namespace: namespace, access: access)
        if let answer = cache.answer(for: key, now: now()) { return .answered(answer) }
        return asking[key] != nil ? .checking : .unknown
    }

    /// Asked, unless it is known or being asked. Publishes nothing until
    /// the answer comes: safe from inside a view's update.
    package func check(_ context: KubeContext, namespace: String, _ access: KubeAccess) {
        _ = task(context, namespace: namespace, access)
    }

    /// The answer, asked when it isn't known.
    package func answer(_ context: KubeContext, namespace: String, _ access: KubeAccess) async -> KubeCanIAnswer {
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

    package func forget(context: String) {
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
package enum KubeCanIRunner {
    package static let timeout: TimeInterval = 20

    package static func run(
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
    package static func credentialProblem(stderr: String, signIn: KubeSignIn) -> KubeProxyProblem? {
        guard let line = KubeProxyProblem.lastLine(of: stderr) else { return nil }
        let said = line.hasPrefix("error: ") ? String(line.dropFirst("error: ".count)) : line
        let problem = KubeProxyProblem.classify(status: 500, contentType: nil, text: said, stderr: stderr, signIn: signIn)
        return problem?.stopsRequests == true ? problem : nil
    }
}
