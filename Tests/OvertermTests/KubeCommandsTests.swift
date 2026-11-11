import Foundation
import XCTest

@testable import Overterm

/// A pod's commands in a tab — a shell, attach, a log followed: the lines
/// built (`--context` and `-n` always, quoted for zsh), the process class
/// check for every verb on every class, the container picked, `kubectl
/// auth can-i` asked (parsed, cached a minute), a refused verb greyed with
/// why, and a shell on production asked first. Nothing here reads ~/.kube
/// or runs a kubectl but a stand-in script of the test's own.
@MainActor
final class KubeCommandsTests: XCTestCase {
    private static func context(_ name: String, namespace: String? = nil, settings: KubeContextSettings = KubeContextSettings()) -> KubeContext {
        KubeContext(
            name: name, cluster: name, server: "http://127.0.0.1:1", namespace: namespace, user: "anonymous", auth: KubeAuth.none, file: nil,
            contextClass: KubeClassifier.classify(context: name, cluster: name, set: settings.contextClass), settings: settings)
    }

    // MARK: The command lines

    func testTheLinesNameTheContextAndNamespaceAlways() {
        XCTAssertEqual(
            KubeCommands.line(.shell, context: "fake-dev", namespace: "shop", pod: "web-7d9", container: "app"),
            "kubectl exec -it web-7d9 -c app --context fake-dev -n shop -- sh -c 'command -v bash >/dev/null && exec bash || exec sh'")
        XCTAssertEqual(
            KubeCommands.line(.attach, context: "fake-dev", namespace: "shop", pod: "web-7d9", container: "app"),
            "kubectl attach -it web-7d9 -c app --context fake-dev -n shop")
        XCTAssertEqual(
            KubeCommands.line(.followLogs, context: "fake-dev", namespace: "shop", pod: "web-7d9", container: nil),
            "kubectl logs -f --tail=200 web-7d9 --context fake-dev -n shop", "no container: kubectl's own choice")
        for verb in [KubeProcessVerb.shell, .attach, .followLogs] {
            let line = KubeCommands.line(verb, context: "c", namespace: "n", pod: "p", container: nil) ?? ""
            XCTAssertTrue(line.contains(" --context c -n n"), line)
        }
        XCTAssertNil(KubeCommands.line(.drain, context: "c", namespace: "n", pod: "p", container: nil), "not a pod's tab")
    }

    func testEveryWordNotOursIsQuotedForZsh() {
        let arn = "arn:aws:eks:eu-west-1:123456789012:cluster/acme-dev"
        XCTAssertEqual(
            KubeCommands.line(.followLogs, context: arn, namespace: "shop", pod: "web", container: "app"),
            "kubectl logs -f --tail=200 web -c app --context \(arn) -n shop", "an ARN stays bare: nothing in it zsh reads")
        XCTAssertEqual(
            KubeCommands.line(.attach, context: "it's prod", namespace: "$HOME", pod: "-rf", container: "a b"),
            #"kubectl attach -it '-rf' -c 'a b' --context 'it'\''s prod' -n '$HOME'"#)
        XCTAssertEqual(
            KubeCommands.line(.shell, context: "fake-dev", namespace: "*", pod: "web!", container: nil),
            "kubectl exec -it 'web!' --context fake-dev -n '*' -- sh -c '\(KubeCommands.shellScript)'")
    }

    func testABuiltCommandGoesThroughTheProcessCheck() throws {
        let off = Self.context("fake-dev", settings: KubeContextSettings(shells: false))
        XCTAssertThrowsError(try KubeCommands.command(.shell, in: off, namespace: "shop", pod: "web", container: nil)) { error in
            XCTAssertTrue("\(error)".contains("off for this context"), "\(error)")
        }
        XCTAssertThrowsError(try KubeCommands.command(.attach, in: off, namespace: "shop", pod: "web", container: nil))
        XCTAssertEqual(
            try KubeCommands.command(.followLogs, in: off, namespace: "shop", pod: "web", container: nil),
            "kubectl logs -f --tail=200 web --context fake-dev -n shop", "logs aren't a shell")
        let prod = Self.context("fake-prod")
        XCTAssertEqual(
            try KubeCommands.command(.shell, in: prod, namespace: "payments", pod: "api-0", container: "app"),
            "kubectl exec -it api-0 -c app --context fake-prod -n payments -- sh -c '\(KubeCommands.shellScript)'",
            "built on production: it is confirmed before, and allowed after can-i")
        XCTAssertThrowsError(try KubeCommands.command(.drain, in: prod, namespace: "n", pod: "p", container: nil), "a writing process on read-only")
    }

    func testATabInAPodSaysSo() {
        for verb in [KubeProcessVerb.shell, .attach] {
            for container in [nil, "app"] as [String?] {
                let line = KubeCommands.line(verb, context: "arn:aws:eks:eu-west-1:1:cluster/acme-prod", namespace: "shop", pod: "web", container: container)!
                XCTAssertEqual(TabKind.of(agent: nil, title: line, hasPort: false, pinned: true), .pod, line)
                XCTAssertEqual(TabKind.of(agent: nil, title: line, hasPort: false), .pod, line)
            }
        }
        let follow = KubeCommands.line(.followLogs, context: "fake-dev", namespace: "shop", pod: "web", container: "app")!
        XCTAssertEqual(TabKind.of(agent: nil, title: follow, hasPort: false, pinned: true), .kubernetes, "a log followed: the pinned tab's own")
        XCTAssertEqual(TabKind.of(agent: nil, title: "kubectl --context fake-dev -n shop exec -ti web -- bash", hasPort: false), .pod)
        XCTAssertEqual(TabKind.of(agent: nil, title: "KUBECONFIG=/tmp/x /opt/homebrew/bin/kubectl attach --stdin web", hasPort: false), .pod)
        XCTAssertEqual(TabKind.of(agent: nil, title: "kubectl exec web -- ls -i", hasPort: false), .shell, "no stdin: one command")
        XCTAssertEqual(TabKind.of(agent: nil, title: "kubectl get pods -n shop", hasPort: false, pinned: true), .kubernetes)
        XCTAssertEqual(TabKind.of(agent: .claude, title: "kubectl exec -it web -- sh", hasPort: false), .agent)
        XCTAssertEqual(TabKind.pod.symbol, "shippingbox.circle")
        XCTAssertEqual(TabKind.pod.name, "Pod")
    }

    // MARK: The process class check (Section 5's table)

    func testEveryProcessVerbAgainstEveryClass() {
        let settings = KubeContextSettings()
        let readOnly = { (kind: KubeContextClass) in KubeProcessCheck.readOnly(kind) }
        for kind in KubeContextClass.allCases {
            for writable in [false, true] where !(kind == .production && writable) {
                for verb in KubeProcessVerb.allCases {
                    let rule = KubeProcessCheck.rule(verb, class: kind, writable: writable, settings: settings)
                    let label = "\(verb) on \(kind) \(writable ? "writable" : "read-only")"
                    switch verb {
                    case .followLogs:
                        XCTAssertEqual(rule, KubeProcessRule(access: .logs, confirm: kind == .production), "\(label): its tab a pinned shell after")
                    case .portForward:
                        XCTAssertEqual(rule, KubeProcessRule(access: .portForward), label)
                    case .shell:
                        XCTAssertEqual(rule, KubeProcessRule(access: .exec, confirm: kind == .production), label)
                    case .attach:
                        XCTAssertEqual(rule, KubeProcessRule(access: .attach, confirm: kind == .production), label)
                    case .copyOut:
                        XCTAssertEqual(rule, KubeProcessRule(access: .exec, confirm: true), "\(label): tar through exec, every copy asked")
                    case .copyIn:
                        if writable {
                            XCTAssertEqual(rule, KubeProcessRule(access: .exec, confirm: true), label)
                        } else {
                            XCTAssertEqual(rule.refused, readOnly(kind), "\(label): it writes the container's files")
                        }
                    case .debug, .drain, .rolloutUndo, .helmRollback, .helmUpgrade, .helmUninstall, .argoSync, .fluxReconcile:
                        if writable {
                            XCTAssertNil(rule.refused, label)
                            XCTAssertTrue(rule.confirm, label)
                        } else {
                            XCTAssertEqual(rule.refused, readOnly(kind), label)
                        }
                    case .nodeShell:
                        XCTAssertNotNil(rule.refused, label)
                        if !writable { XCTAssertEqual(rule.refused, readOnly(kind), label) }
                    case .canI, .whoami, .version, .kustomize, .helmTemplate:
                        XCTAssertEqual(rule, KubeProcessRule(), "\(label): changes nothing")
                    case .terminal:
                        XCTAssertEqual(rule, KubeProcessRule(confirm: kind == .production), label)
                    }
                    if verb.writes && !writable { XCTAssertNotNil(rule.refused, "\(label): a writing process on a read-only context") }
                }
            }
        }
        // Production with its writes on for the session (a later stage): a typed name where rule 4 says.
        let session = KubeProcessCheck.rule(.drain, class: .production, writable: true, settings: settings)
        XCTAssertEqual(session, KubeProcessRule(confirm: true, typedName: true))
        XCTAssertTrue(KubeProcessCheck.rule(.helmUpgrade, class: .production, writable: true, settings: settings).typedName, "an upgrade on production")
        XCTAssertFalse(KubeProcessCheck.rule(.helmUpgrade, class: .local, writable: true, settings: settings).typedName)
        XCTAssertTrue(KubeProcessCheck.rule(.helmUninstall, class: .local, writable: true, settings: settings).typedName, "every class")
        XCTAssertFalse(KubeProcessCheck.rule(.drain, class: .local, writable: true, settings: settings).typedName)
        XCTAssertTrue(KubeProcessCheck.rule(.argoSync, class: .production, writable: true, settings: settings).typedName, "a sync on production")
        XCTAssertFalse(KubeProcessCheck.rule(.argoSync, class: .local, writable: true, settings: settings).typedName)
        XCTAssertFalse(KubeProcessCheck.rule(.fluxReconcile, class: .production, writable: true, settings: settings).typedName, "a reconcile: asked, not typed")
    }

    func testAContextCanTurnShellsOff() {
        let off = KubeContextSettings(shells: false)
        for kind in KubeContextClass.allCases {
            XCTAssertNotNil(KubeProcessCheck.rule(.shell, class: kind, writable: false, settings: off).refused)
            XCTAssertNotNil(KubeProcessCheck.rule(.attach, class: kind, writable: true, settings: off).refused)
            XCTAssertNil(KubeProcessCheck.rule(.followLogs, class: kind, writable: false, settings: off).refused)
            XCTAssertNil(KubeProcessCheck.rule(.portForward, class: kind, writable: false, settings: off).refused)
        }
        XCTAssertEqual(KubeContextSettings(fields: ["shells": .bool(false)]).shells, false, "read from kubernetes.contexts")
        XCTAssertNil(KubeContextSettings(fields: [:]).shells)
        XCTAssertTrue(KubeContextSettings.fields.contains { $0.name == "shells" }, "the setting checks it")
    }

    func testTheContextsOfThisMacAreReadOnlyForEveryWritingProcess() {
        for name in [
            "arn:aws:eks:eu-west-1:123456789012:cluster/acme-dev", "arn:aws:eks:eu-west-1:123456789012:cluster/acme-prod", "globex-eu-west-1-dev",
            "globex-eu-west-1-prod", "kubernetes-admin@k8s-cluster", "fake-dev", "fake-prod",
        ] {
            let context = Self.context(name)
            for verb in KubeProcessVerb.allCases where verb.writes {
                XCTAssertNotNil(KubeProcessCheck.rule(verb, for: context).refused, "\(verb) on \(name)")
            }
            XCTAssertEqual(KubeProcessCheck.rule(.shell, for: context).confirm, context.isProduction, name)
        }
        XCTAssertNil(KubeProcessCheck.rule(.drain, for: Self.context("kind-fake")).refused, "local: writable")
    }

    // MARK: The container

    private static func pod(_ containers: [String], init inits: [String] = [], annotation: String? = nil) -> [String: Any] {
        var pod: [String: Any] = [
            "spec": ["containers": containers.map { ["name": $0] }, "initContainers": inits.map { ["name": $0] }]
        ]
        if let annotation { pod["metadata"] = ["annotations": [KubePodContainers.defaultAnnotation: annotation]] }
        return pod
    }

    func testTheContainerIsTheLogsTabsDefaultAndSeveralArePicked() {
        XCTAssertEqual(KubeContainerPick.of(Self.pod(["app"]), for: .shell), .one("app"))
        XCTAssertEqual(KubeContainerPick.of(Self.pod(["app", "sidecar"]), for: .shell), .several(["app", "sidecar"], default: "app"))
        XCTAssertEqual(
            KubeContainerPick.of(Self.pod(["app", "sidecar"], annotation: "sidecar"), for: .attach), .several(["sidecar", "app"], default: "sidecar"),
            "kubectl's default-container annotation, first")
        XCTAssertEqual(
            KubeContainerPick.of(Self.pod(["app", "sidecar"], annotation: "gone"), for: .shell), .several(["app", "sidecar"], default: "app"))
        XCTAssertEqual(KubeContainerPick.of(Self.pod(["app"], init: ["migrate"]), for: .shell), .one("app"), "no shell in an init container")
        XCTAssertEqual(
            KubeContainerPick.of(Self.pod(["app"], init: ["migrate"]), for: .followLogs), .several(["app", "migrate"], default: "app"),
            "an init container's log is offered")
        XCTAssertEqual(KubeContainerPick.of([:], for: .shell), .none)
    }

    // MARK: kubectl auth can-i

    func testCanIsArgumentsNameTheContextAndNamespace() {
        XCTAssertEqual(
            KubeCanI.arguments(.exec, context: "fake-dev", namespace: "shop"),
            ["auth", "can-i", "create", "pods/exec", "--context", "fake-dev", "-n", "shop", "--request-timeout=15s"])
        XCTAssertEqual(
            KubeCanI.arguments(.logs, context: "c", namespace: "n", cacheDirectory: "/tmp/x"),
            ["auth", "can-i", "get", "pods/log", "--context", "c", "-n", "n", "--cache-dir", "/tmp/x", "--request-timeout=15s"])
        XCTAssertEqual("\(KubeAccess.attach)", "create pods/attach")
        XCTAssertEqual("\(KubeAccess.portForward)", "create pods/portforward")
    }

    func testCanIsAnswersAreRead() {
        XCTAssertEqual(KubeCanI.parse(status: 0, stdout: "yes\n", stderr: ""), .yes)
        XCTAssertEqual(KubeCanI.parse(status: 1, stdout: "no\n", stderr: ""), .no(nil))
        XCTAssertEqual(
            KubeCanI.parse(status: 1, stdout: "no - RBAC: role.rbac.authorization.k8s.io \"viewer\" not found\n", stderr: ""),
            .no("RBAC: role.rbac.authorization.k8s.io \"viewer\" not found"))
        XCTAssertEqual(
            KubeCanI.parse(status: 1, stdout: "", stderr: "error: context \"nope\" does not exist\n"), .failed("context \"nope\" does not exist"))
        XCTAssertEqual(
            KubeCanI.parse(status: 1, stdout: "", stderr: "W1104 warning\nerror: You must be logged in to the server (Unauthorized)\n"),
            .failed("You must be logged in to the server (Unauthorized)"))
        XCTAssertEqual(KubeCanI.parse(status: 255, stdout: "", stderr: ""), .failed("kubectl auth can-i exited (255)."))
        XCTAssertEqual(KubeCanI.parse(status: 0, stdout: "maybe", stderr: ""), .failed("maybe"), "anything else isn't a yes")
        XCTAssertFalse(KubeCanI.parse(status: 1, stdout: "yes", stderr: "").allowed, "a yes that failed isn't one")
    }

    func testAnswersAreKeptAMinuteFailuresTenSeconds() {
        var cache = KubeAccessCache()
        let start = Date()
        let key = KubeAccessKey(context: "fake-dev", namespace: "shop", access: .exec)
        let other = KubeAccessKey(context: "fake-dev", namespace: "payments", access: .exec)
        cache.store(.yes, for: key, at: start)
        XCTAssertEqual(cache.answer(for: key, now: start.addingTimeInterval(59)), .yes)
        XCTAssertNil(cache.answer(for: key, now: start.addingTimeInterval(60)), "asked again after a minute")
        XCTAssertNil(cache.answer(for: other, now: start), "per namespace")
        XCTAssertNil(cache.answer(for: KubeAccessKey(context: "fake-dev", namespace: "shop", access: .attach), now: start), "per verb")
        cache.store(.failed("expired"), for: other, at: start)
        XCTAssertEqual(cache.answer(for: other, now: start.addingTimeInterval(9)), .failed("expired"))
        XCTAssertNil(cache.answer(for: other, now: start.addingTimeInterval(10)))
        cache.forget(context: "fake-dev")
        XCTAssertNil(cache.answer(for: key, now: start))
        cache.store(.yes, for: key, at: start)
        cache.store(.failed("expired"), for: other, at: start.addingTimeInterval(30))
        XCTAssertEqual(cache.count, 2)
        cache.store(.yes, for: KubeAccessKey(context: "kind-fake", namespace: "a", access: .logs), at: start.addingTimeInterval(61))
        XCTAssertEqual(cache.count, 1, "what has run out goes as another is kept")
    }

    func testOneQuestionIsAskedOnceAMinute() async {
        let counter = Counter()
        var now = Date()
        let checks = KubeAccessChecks { context, namespace, access in
            await counter.add("\(context.name) \(namespace) \(access)")
            return access == .attach ? .no(nil) : .yes
        }
        checks.now = { now }
        let dev = Self.context("fake-dev")
        XCTAssertEqual(checks.state("fake-dev", namespace: "shop", .exec), .unknown)
        checks.check(dev, namespace: "shop", .exec)
        XCTAssertEqual(checks.state("fake-dev", namespace: "shop", .exec), .checking)
        async let first = checks.answer(dev, namespace: "shop", .exec)
        async let second = checks.answer(dev, namespace: "shop", .exec)
        let answers = await [first, second]
        XCTAssertEqual(answers, [.yes, .yes])
        XCTAssertEqual(checks.state("fake-dev", namespace: "shop", .exec), .answered(.yes))
        let refused = await checks.answer(dev, namespace: "shop", .attach)
        XCTAssertEqual(refused, .no(nil))
        _ = await checks.answer(dev, namespace: "shop", .exec)
        var asked = await counter.items
        XCTAssertEqual(asked, ["fake-dev shop create pods/exec", "fake-dev shop create pods/attach"], "one each, the rest from the cache")
        now = now.addingTimeInterval(61)
        XCTAssertEqual(checks.state("fake-dev", namespace: "shop", .exec), .unknown)
        _ = await checks.answer(dev, namespace: "shop", .exec)
        asked = await counter.items
        XCTAssertEqual(asked.count, 3, "a minute on, asked again")
    }

    func testARefusedVerbSaysWhy() {
        XCTAssertEqual(KubeAccessState.answered(.yes).unavailable(.exec, namespace: "shop"), nil)
        XCTAssertEqual(
            KubeAccessState.answered(.no(nil)).unavailable(.attach, namespace: "shop"), "Refused: kubectl auth can-i create pods/attach in shop.")
        XCTAssertEqual(
            KubeAccessState.answered(.no("RBAC: denied")).unavailable(.exec, namespace: "shop"),
            "Refused: kubectl auth can-i create pods/exec in shop: RBAC: denied")
        XCTAssertEqual(
            KubeAccessState.answered(.failed("no kubectl")).unavailable(.logs, namespace: "shop"),
            "Couldn't ask kubectl auth can-i get pods/log: no kubectl")
        XCTAssertEqual(KubeAccessState.checking.unavailable(.exec, namespace: "shop"), "Checking kubectl auth can-i create pods/exec in shop…")
        XCTAssertEqual(KubeAccessState.unknown.unavailable(.exec, namespace: "shop"), KubeAccessState.checking.unavailable(.exec, namespace: "shop"))
    }

    /// The real runner, with a stand-in kubectl that records what it was
    /// given: Overterm's KUBECONFIG (a temporary file, guarded), the run's
    /// own HOME, `--context` and `-n`, and its answer read.
    func testCanIRunsAShortLivedKubectlWithOvertermsKubeconfig() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("otcani-\(UUID().uuidString.prefix(6))", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let kubeconfig = folder.appendingPathComponent("config.yaml")
        try "apiVersion: v1\nkind: Config\n".write(to: kubeconfig, atomically: true, encoding: .utf8)
        let log = folder.appendingPathComponent("log")
        let stand = folder.appendingPathComponent("kubectl")
        try """
        #!/bin/sh
        printf '%s|%s|%s\\n' "$KUBECONFIG" "$HOME" "$*" >> '\(log.path)'
        case "$4" in pods/attach) echo no; exit 1;; pods/log) echo 'error: Unauthorized' >&2; exit 1;; *) echo yes; exit 0;; esac
        """.write(to: stand, atomically: true, encoding: .utf8)
        chmod(stand.path, 0o755)
        let sockets = KubeSocketFolder(base: folder)
        let planner = KubeProxyPlanner(
            folder: sockets, guarded: true, home: FileManager.default.homeDirectoryForCurrentUser, kubeconfigs: { _ in [kubeconfig] },
            baseEnvironment: { ["PATH": "/usr/bin:/bin"] })
        var configuration = KubeProxies.Configuration()
        configuration.kubectlPath = stand.path
        let dev = Self.context("fake-dev")
        let yes = await KubeCanIRunner.run(dev, namespace: "shop", .exec, configuration: configuration, planner: planner)
        let no = await KubeCanIRunner.run(dev, namespace: "shop", .attach, configuration: configuration, planner: planner)
        let failed = await KubeCanIRunner.run(dev, namespace: "shop", .logs, configuration: configuration, planner: planner)
        XCTAssertEqual(yes, .yes)
        XCTAssertEqual(no, .no(nil))
        XCTAssertEqual(failed, .failed("Unauthorized"))
        let lines = try String(contentsOf: log, encoding: .utf8).split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 3)
        for line in lines {
            let parts = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            XCTAssertEqual(parts.first, kubeconfig.path, "only Overterm's kubeconfig: \(line)")
            XCTAssertEqual(parts[1], sockets.isolatedHome, "the run's own HOME")
            XCTAssertTrue(parts[2].hasPrefix("auth can-i ") && parts[2].contains("--context fake-dev -n shop"), line)
        }
        sockets.remove()
        var none = configuration
        none.kubectlPath = folder.appendingPathComponent("nothing").path
        let missing = await KubeCanIRunner.run(dev, namespace: "shop", .exec, configuration: none, planner: planner)
        guard case .failed = missing else { return XCTFail("no kubectl: \(missing)") }
        sockets.remove()
    }
}

// MARK: can-i under the proxies' credential rules, and its processes

final class KubeCanIProcessTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("otcanip-\(UUID().uuidString.prefix(6))", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
    }

    private static func context(_ name: String, auth: KubeAuth? = KubeAuth.none) -> KubeContext {
        KubeContext(
            name: name, cluster: name, server: "http://127.0.0.1:1", namespace: "shop", user: "u-\(name)", auth: auth, file: nil,
            contextClass: KubeClassifier.classify(context: name, cluster: name, set: nil), settings: KubeContextSettings())
    }

    private static let oidc = KubeAuth.exec(KubeExec(command: "kubectl", arguments: ["oidc-login", "get-token"]))

    /// A stand-in kubectl (and the plugins' names, never run) in the
    /// test's folder, a temporary kubeconfig, the planner guarded.
    private func tool(_ body: String) throws -> (KubeProxies.Configuration, KubeProxyPlanner, URL) {
        let kubeconfig = folder.appendingPathComponent("config.yaml")
        try "apiVersion: v1\nkind: Config\n".write(to: kubeconfig, atomically: true, encoding: .utf8)
        let stand = folder.appendingPathComponent("kubectl")
        try "#!/bin/sh\n\(body)\n".write(to: stand, atomically: true, encoding: .utf8)
        chmod(stand.path, 0o755)
        for plugin in ["kubectl-oidc_login", "aws"] {
            let path = folder.appendingPathComponent(plugin)
            try "#!/bin/sh\nexit 1\n".write(to: path, atomically: true, encoding: .utf8)
            chmod(path.path, 0o755)
        }
        let path = folder.path
        let planner = KubeProxyPlanner(
            folder: KubeSocketFolder(base: folder), guarded: true, home: FileManager.default.homeDirectoryForCurrentUser,
            kubeconfigs: { _ in [kubeconfig] }, baseEnvironment: { ["PATH": "\(path):/usr/bin:/bin"] })
        var configuration = KubeProxies.Configuration()
        configuration.kubectlPath = stand.path
        return (configuration, planner, folder.appendingPathComponent("log"))
    }

    /// On oidc contexts: a context's three questions one after another,
    /// and no two browser sign-ins (each context's first run) at once.
    @MainActor
    func testCanIOnOIDCContextsNeverOverlapsASignIn() async throws {
        let (configuration, planner, log) = try tool(
            """
            [ "$2" = can-i ] || { echo yes; exit 0; }
            echo "s $6 $4" >> '\(folder.appendingPathComponent("log").path)'
            sleep 0.3
            echo "e $6 $4" >> '\(folder.appendingPathComponent("log").path)'
            echo yes
            """)
        let proxies = KubeProxies()
        let checks = KubeAccessChecks { context, namespace, access in
            await KubeCanIRunner.run(context, namespace: namespace, access, configuration: configuration, planner: planner, proxies: proxies)
        }
        let contexts = [Self.context("fake-dev", auth: Self.oidc), Self.context("kind-fake", auth: Self.oidc)]
        let verbs: [KubeAccess] = [.exec, .attach, .logs]
        for context in contexts { for access in verbs { checks.check(context, namespace: "shop", access) } }
        for context in contexts {
            for access in verbs {
                let answer = await checks.answer(context, namespace: "shop", access)
                XCTAssertEqual(answer, .yes, "\(context.name) \(access)")
            }
        }
        let lines = try String(contentsOf: log, encoding: .utf8).split(separator: "\n").map { $0.split(separator: " ").map(String.init) }
        XCTAssertEqual(lines.count, 12, "six runs")
        var running: [String: Int] = [:]
        var signingIn: Set<String> = []
        var started: Set<String> = []
        for line in lines {
            let (what, context) = (line[0], line[1])
            if what == "s" {
                running[context, default: 0] += 1
                XCTAssertEqual(running[context], 1, "\(context): one question at a time")
                if !started.contains(context) {
                    XCTAssertTrue(signingIn.isEmpty, "\(context)'s sign-in while \(signingIn)'s runs")
                    signingIn.insert(context)
                    started.insert(context)
                }
            } else {
                running[context, default: 1] -= 1
                signingIn.remove(context)
            }
        }
        let status = await proxies.status(of: "fake-dev")
        XCTAssertEqual(status, .closed, "no proxy started for it")
    }

    /// A context the proxies stopped (a credential failure) starts no
    /// kubectl; a can-i's own credential failure stops it as a proxy's does.
    func testCanIOnAStoppedContextStartsNothing() async throws {
        let (configuration, planner, log) = try tool(
            """
            [ "$2" = can-i ] || { echo yes; exit 0; }
            echo "$6" >> '\(folder.appendingPathComponent("log").path)'
            echo 'error: getting credentials: exec: executable aws failed with exit code 255' >&2
            exit 1
            """)
        let stopped = KubeProxies(plan: { _, _, _ in throw KubeProxyProblem.signInFailed("Token has expired") })
        let dev = Self.context("fake-dev", auth: Self.oidc)
        _ = try? await stopped.send(dev, .GET, "/version")
        guard case .stopped = await stopped.status(of: "fake-dev") else { return XCTFail("the proxy's failure stops the context") }
        let answer = await KubeCanIRunner.run(dev, namespace: "shop", .exec, configuration: configuration, planner: planner, proxies: stopped)
        XCTAssertEqual(answer, .failed(KubeProxyProblem.signInFailed("Token has expired").reason))
        XCTAssertFalse(FileManager.default.fileExists(atPath: log.path), "no kubectl started")

        let proxies = KubeProxies()
        let aws = Self.context("acme-dev", auth: .exec(KubeExec(command: "aws", arguments: ["eks", "get-token", "--cluster-name", "acme-dev"])))
        let first = await KubeCanIRunner.run(aws, namespace: "shop", .exec, configuration: configuration, planner: planner, proxies: proxies)
        guard case .failed = first else { return XCTFail("\(first)") }
        let status = await proxies.status(of: "acme-dev")
        XCTAssertEqual(status, .stopped(.awsSignIn(profile: nil)), "the plugin's failure stops the context")
        _ = await KubeCanIRunner.run(aws, namespace: "shop", .attach, configuration: configuration, planner: planner, proxies: proxies)
        let asked = try String(contentsOf: log, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(asked, ["acme-dev"], "not asked again: each would run the plugin again")
        XCTAssertNil(KubeCanI.credentialProblem(stderr: "error: You must be logged in to the server (Unauthorized)", signIn: .none))
    }

    /// Timed out: kubectl and what it started (an exec plugin's child)
    /// both end — its process group — and nothing is left running.
    func testATimedOutRunEndsItsWholeGroup() throws {
        let leader = folder.appendingPathComponent("leader")
        let child = folder.appendingPathComponent("child")
        let script = folder.appendingPathComponent("plugin-like")
        try "#!/bin/sh\necho $$ > '\(leader.path)'\nsleep 30 &\necho $! > '\(child.path)'\nsleep 30\n".write(
            to: script, atomically: true, encoding: .utf8)
        chmod(script.path, 0o755)
        let result = KubeProcessRun.run(script, [], environment: ["PATH": "/usr/bin:/bin"], timeout: 0.5)
        XCTAssertNil(result, "timed out")
        XCTAssertEqual(KubeProcessRun.livePIDs, [])
        let pids = [leader, child].compactMap { try? String(contentsOf: $0, encoding: .utf8) }.compactMap {
            pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        XCTAssertEqual(pids.count, 2)
        XCTAssertTrue(gone(pids), "kubectl and its child are gone: \(pids)")
    }

    /// At quit, a run still going is ended with its group.
    func testStopAllEndsARunningOneAndItsChildren() async throws {
        let child = folder.appendingPathComponent("child")
        let script = folder.appendingPathComponent("plugin-like")
        try "#!/bin/sh\nsleep 30 &\necho $! > '\(child.path)'\nsleep 30\n".write(to: script, atomically: true, encoding: .utf8)
        chmod(script.path, 0o755)
        let running = Task.detached { KubeProcessRun.run(script, [], environment: ["PATH": "/usr/bin:/bin"], timeout: 30) }
        let deadline = Date().addingTimeInterval(5)
        while (KubeProcessRun.livePIDs.isEmpty || !FileManager.default.fileExists(atPath: child.path)) && Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try await Task.sleep(for: .milliseconds(100))
        let pid = KubeProcessRun.livePIDs.first
        XCTAssertNotNil(pid)
        KubeProcessRun.stopAll()
        let result = await running.value
        XCTAssertEqual(result?.status, 128 + SIGKILL)
        let childPID = (try? String(contentsOf: child, encoding: .utf8)).flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        XCTAssertTrue(gone([pid, childPID].compactMap { $0 }), "both gone")
        XCTAssertEqual(KubeProcessRun.livePIDs, [])
    }

    func testAnExitStatusIsTheShells() {
        XCTAssertEqual(KubeProcessRun.exitStatus(0), 0)
        XCTAssertEqual(KubeProcessRun.exitStatus(1 << 8), 1)
        XCTAssertEqual(KubeProcessRun.exitStatus(SIGKILL), 137)
        let result = KubeProcessRun.run(URL(fileURLWithPath: "/bin/sh"), ["-c", "echo out; echo err >&2; exit 3"], environment: [:], timeout: 5)
        XCTAssertEqual(result?.status, 3)
        XCTAssertEqual(result?.stdout, "out\n")
        XCTAssertEqual(result?.stderr, "err\n")
    }

    private func gone(_ pids: [pid_t], within timeout: TimeInterval = 3) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if pids.allSatisfy({ kill($0, 0) != 0 }) { return true }
            usleep(50_000)
        }
        return false
    }
}

private actor Counter {
    private(set) var items: [String] = []
    func add(_ item: String) { items.append(item) }
}

/// The page: `e`, `A` and `t` on a pod against `FakeKubeAPI` — its
/// container read with one GET, the command handed to the window (never
/// typed here), a refused verb greyed with why, and on production a shell
/// asked first, naming the context, once per pod.
@MainActor
final class KubePodCommandsPageTests: XCTestCase {
    private var api: FakeKubeAPI!
    private var socket: String!

    override func setUp() async throws {
        socket = "/tmp/otkc-\(UInt32.random(in: 0...UInt32.max)).sock"
        api = FakeKubeAPI(socket: socket)
        try api.start()
        api.addNamespace("shop")
        var web = FakeKubeAPI.Pod()
        web.env = ["DB_PASSWORD": "acme-s3cret-value"]
        api.addPod("web-1", namespace: "shop", web)
        var two = FakeKubeAPI.Pod()
        two.containers = 2
        api.addPod("api-1", namespace: "shop", two, annotations: [KubePodContainers.defaultAnnotation: "sidecar-1"])
    }

    override func tearDown() async throws {
        if let api {
            XCTAssertEqual(api.writes, [], "only GETs")
            XCTAssertEqual(api.subresourceRequests, [], "no exec, attach or log through the API")
            api.stop()
        }
    }

    private static func context(_ name: String, settings: KubeContextSettings = KubeContextSettings()) -> KubeContext {
        KubeContext(
            name: name, cluster: name, server: "http://127.0.0.1:1", namespace: "shop", user: "anonymous", auth: KubeAuth.none, file: nil,
            contextClass: KubeClassifier.classify(context: name, cluster: name, set: settings.contextClass), settings: settings)
    }

    private struct Recorded {
        var commands: [(String, String, String)] = []
        var envs: [[String: String]] = []
        var confirms: [(String, String, () -> Void)] = []
        var choices: [([String], (Int) -> Void)] = []
    }

    private final class Box { var recorded = Recorded() }

    private func page(_ name: String, settings: KubeContextSettings = KubeContextSettings()) async throws -> (KubernetesPageModel, Box) {
        let model = KubernetesModel(proxies: KubeProxies())
        let list = KubeContextList(contexts: [Self.context(name, settings: settings)], current: name)
        model.load = { _ in list }
        model.readConfiguration = { KubernetesModel.Configuration() }
        model.watchesSettings = false
        model.remembersSelection = false
        model.flushInterval = .milliseconds(20)
        model.statusInterval = .milliseconds(50)
        let socket = self.socket!
        model.connectOverride = { context in KubeSocketConnection(socket: socket, context: context.name) }
        model.statusOverride = { _ in .open }
        model.access.run = { _, _, access in access == .attach ? .no("RBAC: attach denied") : .yes }
        let page = KubernetesPageModel(model: model)
        let box = Box()
        var actions = KubernetesActions(run: { _ in }, settings: {}, copy: { _ in }, copySecret: { _ in })
        actions.runInTab = { command, context, namespace in box.recorded.commands.append((command, context.name, namespace)) }
        actions.runPodInTab = { command, context, namespace, env in
            box.recorded.commands.append((command, context.name, namespace))
            box.recorded.envs.append(Dictionary(env.map { ($0.key, $0.value) }, uniquingKeysWith: { first, _ in first }))
        }
        actions.confirm = { _, detail, button, then in box.recorded.confirms.append((detail, button, then)) }
        actions.choose = { _, _, buttons, then in box.recorded.choices.append((buttons, then)) }
        page.actions = actions
        model.show()
        try await until("listed") { model.rows.count == 2 }
        return (page, box)
    }

    private func until(_ what: String, _ timeout: TimeInterval = 5, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return XCTFail("timed out: \(what)") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    func testEAndTOpenTheirCommandInATab() async throws {
        let (page, box) = try await page("fake-dev")
        defer { page.model.hide() }
        page.selection = ["shop/web-1"]
        XCTAssertTrue(page.press("e"))
        try await until("the shell") { box.recorded.commands.count == 1 }
        XCTAssertEqual(box.recorded.commands.first?.0, KubeCommands.line(.shell, context: "fake-dev", namespace: "shop", pod: "web-1", container: "app"))
        XCTAssertEqual(box.recorded.commands.first?.1, "fake-dev")
        XCTAssertEqual(box.recorded.commands.first?.2, "shop", "the tab pinned to the pod's namespace")
        XCTAssertTrue(box.recorded.confirms.isEmpty, "not production: not asked")
        XCTAssertEqual(box.recorded.envs.first?["DB_PASSWORD"], "acme-s3cret-value", "the pod's env, for ⌘L in its tab to scrub")
        XCTAssertTrue(page.press("t"))
        try await until("the log") { box.recorded.commands.count == 2 }
        XCTAssertEqual(box.recorded.commands.last?.0, "kubectl logs -f --tail=200 web-1 -c app --context fake-dev -n shop")
        XCTAssertTrue(api.requests.contains { $0.method == "GET" && $0.path == "/api/v1/namespaces/shop/pods/web-1" }, "its containers read")

        // Several containers: a picker, kubectl's default first.
        page.selection = ["shop/api-1"]
        XCTAssertTrue(page.press("e"))
        try await until("the picker") { box.recorded.choices.count == 1 }
        XCTAssertEqual(box.recorded.choices.first?.0, ["sidecar-1 (default)", "app"])
        box.recorded.choices.first?.1(1)
        try await until("the shell in app") { box.recorded.commands.count == 3 }
        XCTAssertTrue(box.recorded.commands.last?.0.contains("exec -it api-1 -c app --context fake-dev -n shop") == true)

        // Not a pod list: the keys mean nothing.
        page.selection = []
        XCTAssertFalse(page.press("e"), "nothing selected")
    }

    /// The context changes while the picker (or can-i, behind a browser
    /// sign-in) waits: made production, the shell isn't opened unasked —
    /// it is refused as another context; `shells: false`, refused.
    func testAContextChangedWhileItWaitedIsCheckedAgain() async throws {
        let (page, box) = try await page("fake-dev")
        defer { page.model.hide() }
        for (settings, said) in [
            (KubeContextSettings(contextClass: .production), KubernetesPageModel.contextChanged),
            (KubeContextSettings(shells: false), nil),
        ] {
            let plain = KubeContextList(contexts: [Self.context("fake-dev")], current: "fake-dev")
            page.model.load = { _ in plain }
            page.model.reloadContexts()
            try await until("as it was") { page.model.contexts.context(named: "fake-dev")?.settings == KubeContextSettings() }
            let choices = box.recorded.choices.count
            page.selection = ["shop/api-1"]
            XCTAssertTrue(page.press("e"))
            try await until("the picker") { box.recorded.choices.count == choices + 1 }
            let changed = KubeContextList(contexts: [Self.context("fake-dev", settings: settings)], current: "fake-dev")
            page.model.load = { _ in changed }
            page.model.reloadContexts()
            try await until("read again") { page.model.contexts.context(named: "fake-dev")?.settings == settings }
            box.recorded.choices.last?.1(1)
            XCTAssertTrue(box.recorded.commands.isEmpty, "nothing opened")
            XCTAssertTrue(box.recorded.confirms.isEmpty)
            if let said { XCTAssertEqual(page.commandProblem, said) } else { XCTAssertNotNil(page.commandProblem) }
        }
    }

    func testARefusedVerbIsGreyedWithTheReasonAndDoesNothing() async throws {
        let (page, box) = try await page("fake-dev")
        defer { page.model.hide() }
        page.selection = ["shop/web-1"]
        let titles = ["Shell in a Tab", "Attach in a Tab", "Follow Logs in a Tab"]
        try await until("asked as the pod was picked") {
            page.verbs(for: ["shop/web-1"]).filter { titles.contains($0.title) }.allSatisfy { verb in
                !(verb.unavailable ?? "").hasPrefix("Checking")
            }
        }
        let verbs = Dictionary(uniqueKeysWithValues: page.verbs(for: ["shop/web-1"]).map { ($0.title, $0) })
        XCTAssertNil(verbs["Shell in a Tab"]?.unavailable)
        XCTAssertNil(verbs["Follow Logs in a Tab"]?.unavailable)
        XCTAssertEqual(verbs["Attach in a Tab"]?.unavailable, "Refused: kubectl auth can-i create pods/attach in shop: RBAC: attach denied")
        XCTAssertEqual(verbs["Shell in a Tab"]?.key, "e")
        XCTAssertEqual(page.podVerbs(for: page.ref(for: "shop/web-1")!).map(\.title), titles, "the detail's buttons are the same verbs")
        XCTAssertTrue(page.press("A"))
        try await until("said") { page.commandProblem != nil }
        XCTAssertEqual(page.commandProblem, verbs["Attach in a Tab"]?.unavailable)
        XCTAssertTrue(box.recorded.commands.isEmpty, "nothing opened")
        XCTAssertEqual(page.model.access.asked, 4, "each verb asked once: exec, attach, a log, a port-forward")

        // Shells off for the context: greyed by the process check, kubectl not asked.
        let (off, offBox) = try await self.page("fake-dev", settings: KubeContextSettings(shells: false))
        defer { off.model.hide() }
        let shell = off.verbs(for: ["shop/web-1"]).first { $0.title == "Shell in a Tab" }
        XCTAssertEqual(shell?.unavailable, "Shells and attach are off for this context (its shells setting).")
        off.selection = ["shop/web-1"]
        XCTAssertTrue(off.press("e"))
        XCTAssertEqual(off.commandProblem, shell?.unavailable)
        XCTAssertTrue(offBox.recorded.commands.isEmpty)
    }

    func testAShellOnProductionIsAskedFirstOncePerPod() async throws {
        let (page, box) = try await page("fake-prod")
        defer { page.model.hide() }
        page.selection = ["shop/web-1"]
        XCTAssertTrue(page.press("e"))
        try await until("asked") { box.recorded.confirms.count == 1 }
        let (detail, button, _) = box.recorded.confirms[0]
        XCTAssertTrue(detail.contains("PRODUCTION · fake-prod · namespace shop"), detail)
        XCTAssertTrue(detail.contains("pod shop/web-1, container app"), detail)
        XCTAssertEqual(button, "Open Shell in fake-prod")
        XCTAssertTrue(box.recorded.commands.isEmpty, "nothing before the answer — Cancel opens nothing")
        box.recorded.confirms[0].2()
        XCTAssertEqual(box.recorded.commands.count, 1)
        XCTAssertEqual(box.recorded.commands.first?.0.hasSuffix("--context fake-prod -n shop -- sh -c '\(KubeCommands.shellScript)'"), true)
        XCTAssertTrue(page.press("e"))
        try await until("the second") { box.recorded.commands.count == 2 }
        XCTAssertEqual(box.recorded.confirms.count, 1, "once per pod and session")
        // A log followed: its tab is a pinned shell once the follow ends —
        // asked as Terminal in this context is, once for the context.
        XCTAssertTrue(page.press("t"))
        try await until("the log asked") { box.recorded.confirms.count == 2 }
        let (said, follow, _) = box.recorded.confirms[1]
        XCTAssertTrue(said.contains("PRODUCTION · fake-prod · namespace shop") && said.contains("a plain kubectl, helm or k9s in it goes to fake-prod"), said)
        XCTAssertEqual(follow, "Follow in fake-prod")
        XCTAssertEqual(box.recorded.commands.count, 2, "nothing before the answer")
        box.recorded.confirms[1].2()
        XCTAssertEqual(box.recorded.commands.last?.0, "kubectl logs -f --tail=200 web-1 -c app --context fake-prod -n shop")
        page.selection = ["shop/api-1"]
        XCTAssertTrue(page.press("t"))
        try await until("the picker") { box.recorded.choices.count == 1 }
        box.recorded.choices[0].1(0)
        try await until("another pod's log") { box.recorded.commands.count == 4 }
        XCTAssertEqual(box.recorded.confirms.count, 2, "once per context and session")
        XCTAssertTrue(page.model.shellConsent.isGranted(.shell, context: "fake-prod", namespace: "shop", pod: "web-1"))
        XCTAssertFalse(page.model.shellConsent.isGranted(.attach, context: "fake-prod", namespace: "shop", pod: "web-1"), "each verb its own")
    }

    /// With the detail open on another pod than the list's (a link
    /// followed), e means the pod the detail shows.
    func testTheKeysMeanThePodTheDetailShows() async throws {
        let (page, box) = try await page("fake-dev")
        defer { page.model.hide() }
        page.selection = ["shop/web-1"]
        XCTAssertTrue(page.openSelected())
        page.open(KubeObjectRef(context: "fake-dev", kind: .pods, namespace: "shop", name: "api-1"), from: .link)
        XCTAssertEqual(page.detail?.ref.name, "api-1")
        XCTAssertEqual(page.selection, ["shop/web-1"], "the list's selection stays")
        XCTAssertTrue(page.press("e"))
        try await until("the picker") { box.recorded.choices.count == 1 }
        box.recorded.choices[0].1(0)
        try await until("the shell") { box.recorded.commands.count == 1 }
        XCTAssertTrue(box.recorded.commands[0].0.hasPrefix("kubectl exec -it api-1 "), box.recorded.commands[0].0)
        page.goBack()
        XCTAssertEqual(page.detail?.ref.name, "web-1")
        XCTAssertTrue(page.press("t"))
        try await until("the log") { box.recorded.commands.count == 2 }
        XCTAssertTrue(box.recorded.commands[1].0.contains(" web-1 "), box.recorded.commands[1].0)
        // A detail on something that isn't a pod: no pod to run it in.
        page.open(KubeObjectRef(context: "fake-dev", kind: .namespaces, namespace: nil, name: "shop"), from: .link)
        XCTAssertFalse(page.press("e"))
        XCTAssertEqual(box.recorded.commands.count, 2)
    }

    /// Why the last command didn't open goes once it no longer applies:
    /// another pod picked, another namespace, another context.
    func testTheCommandsProblemGoesWithThePodItWasAbout() async throws {
        let (page, _) = try await page("fake-dev")
        defer { page.model.hide() }
        page.selection = ["shop/web-1"]
        XCTAssertTrue(page.press("A"))
        try await until("said") { page.commandProblem != nil }
        page.selection = ["shop/api-1"]
        XCTAssertNil(page.commandProblem, "another pod picked")
        page.selection = ["shop/web-1"]
        XCTAssertTrue(page.press("A"))
        try await until("said again") { page.commandProblem != nil }
        page.model.setScope(.all)
        try await until("another namespace") { page.commandProblem == nil }
    }

    /// can-i's answers go for a context whose user or class changed in
    /// the kubeconfig, and for one that is gone.
    func testCanIsAnswersGoWhenTheContextChanges() async throws {
        let (page, _) = try await page("fake-dev")
        defer { page.model.hide() }
        let model = page.model
        let dev = Self.context("fake-dev")
        _ = await model.access.answer(dev, namespace: "shop", .exec)
        XCTAssertEqual(model.access.state("fake-dev", namespace: "shop", .exec), .answered(.yes))
        let same = KubeContextList(contexts: [dev, Self.context("kind-fake")], current: "fake-dev")
        model.load = { _ in same }
        model.reloadContexts()
        try await until("read again") { model.contexts.contexts.count == 2 }
        XCTAssertEqual(model.access.state("fake-dev", namespace: "shop", .exec), .answered(.yes), "unchanged: kept")
        let other = KubeContext(
            name: "fake-dev", cluster: "fake-dev", server: dev.server, namespace: "shop", user: "admin", auth: dev.auth, file: nil,
            contextClass: dev.contextClass, settings: dev.settings)
        let changed = KubeContextList(contexts: [other], current: "fake-dev")
        model.load = { _ in changed }
        model.reloadContexts()
        try await until("read again") { model.contexts.contexts.count == 1 }
        XCTAssertEqual(model.access.state("fake-dev", namespace: "shop", .exec), .unknown, "another user: asked again")
    }

    func testTheKeysAreTheTables() {
        XCTAssertTrue(KubernetesKey.isWellFormed)
        XCTAssertEqual(KubernetesKey.of("e"), .shell)
        XCTAssertEqual(KubernetesKey.of("A"), .attach)
        XCTAssertEqual(KubernetesKey.of("t"), .followInTab)
        XCTAssertEqual(KubernetesKey.of("a"), .askWhy, "a is Ask Why's")
    }
}
