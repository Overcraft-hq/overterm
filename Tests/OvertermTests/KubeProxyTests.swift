import Darwin
import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import XCTest

@testable import Overterm

/// What a context's `kubectl proxy` is told and given: the flags per class,
/// the socket's folder and path, the environment (never the user's
/// kubeconfig here), which kubectl, the errors in plain words. A stand-in
/// kubectl (a script that writes its argv and makes the socket) shows what
/// is started; the real kubectl, when installed, runs against a tiny
/// server of the test's own on 127.0.0.1 through a kubeconfig of the
/// test's own — this Mac's current context is production, and nothing here
/// reads ~/.kube.
final class KubeProxyTests: XCTestCase {
    private var dir: URL!
    /// Short, under /tmp: a unix socket's path is 104 bytes at most.
    private var base: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("overterm-kubeproxy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        base = URL(fileURLWithPath: "/tmp").appendingPathComponent("otkp-\(UInt32.random(in: 0...UInt32.max))", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDown() {
        ManagedProcess.closeAll()
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.removeItem(at: base)
    }

    private static func context(
        _ name: String, server: String = "http://127.0.0.1:1", auth: KubeAuth? = KubeAuth.none, writable: Bool? = nil
    ) -> KubeContext {
        KubeContext(
            name: name, cluster: name, server: server, namespace: nil, user: name, auth: auth, file: nil,
            contextClass: KubeClassifier.classify(context: name, cluster: name, set: nil), settings: KubeContextSettings(writable: writable))
    }

    // MARK: Flags

    func testEveryProxyRefusesWhatReachesInsideTheClusterAndAReadOnlyOneEveryWrite() {
        let readOnly = KubeProxyFlags.arguments(context: "fake-prod", socket: "/tmp/x.sock", readOnly: true)
        XCTAssertEqual(
            readOnly,
            [
                "--context=fake-prod", "proxy", "--unix-socket=/tmp/x.sock", "--disable-filter=false", "--accept-hosts=^localhost$",
                "--reject-paths=^/api/.*/pods/.*/(exec|attach|portforward|proxy),^/api/.*/services/.*/proxy,^/api/.*/nodes/.*/proxy,^/apis/subresources\\.kubevirt\\.io/",
                "--reject-methods=^(?:[^G]|G$|G[^E]|GE$|GE[^T]|GET.)",
            ])
        // GET and nothing else: kubectl matches the method as sent, and the
        // apiserver behind it is handed any token the filter lets by.
        let method = try! NSRegularExpression(pattern: KubeProxyFlags.rejectedMethods)
        func refusesMethod(_ name: String) -> Bool { method.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil }
        XCTAssertFalse(refusesMethod("GET"))
        for name in ["POST", "PUT", "PATCH", "DELETE", "CONNECT", "post", "Delete", "patch", "get", "Get", "GETX", "GE", "G", "HEAD", "OPTIONS", "TRACE", "PROPFIND"] {
            XCTAssertTrue(refusesMethod(name), name)
        }
        let writable = KubeProxyFlags.arguments(context: "kind-fake", socket: "/tmp/x.sock", readOnly: false, cacheDirectory: "/tmp/c")
        XCTAssertEqual(writable.prefix(2), ["--context=kind-fake", "--cache-dir=/tmp/c"])
        XCTAssertTrue(writable.contains { $0.hasPrefix("--reject-paths=") }, "a writable context's proxy refuses the paths too")
        XCTAssertFalse(writable.contains { $0.hasPrefix("--reject-methods") }, "and writes")
        XCTAssertTrue(writable.contains("--disable-filter=false"), "no kuberc default turns the filters off")
        // Each filter is one pattern a comma (kubectl splits on them): none may hold one.
        XCTAssertFalse((KubeProxyFlags.rejectedPaths + [KubeProxyFlags.rejectedMethods]).contains { $0.contains(",") })
        XCTAssertTrue(KubeProxyFlags.rejectedPaths.allSatisfy { $0.hasPrefix("^") }, "kubectl matches unanchored")
        // What the patterns refuse, as kubectl matches them (on the decoded path).
        let refused = [
            "/api/v1/namespaces/a/pods/p/exec", "/api/v1/namespaces/a/pods/p/attach", "/api/v1/namespaces/a/pods/p/portforward",
            "/api/v1/namespaces/a/pods/p:8080/proxy/x", "/api/v1/namespaces/a/services/s:80/proxy/", "/api/v1/nodes/n/proxy/run",
            "/api/v1/nodes/n/proxy/stats/summary", "/apis/subresources.kubevirt.io/v1/namespaces/a/virtualmachineinstances/v/console",
        ]
        let passed = ["/api/v1/namespaces/a/pods", "/api/v1/namespaces/a/pods/p/log", "/apis/apps/v1/deployments", "/version"]
        let patterns = KubeProxyFlags.rejectedPaths.map { try! NSRegularExpression(pattern: $0) }
        func matches(_ path: String) -> Bool { patterns.contains { $0.firstMatch(in: path, range: NSRange(path.startIndex..., in: path)) != nil } }
        for path in refused { XCTAssertTrue(matches(path), path) }
        for path in passed { XCTAssertFalse(matches(path), path) }
        XCTAssertTrue(KubeProxyFlags.isReady("Starting to serve on /tmp/x.sock"))
    }

    func testTheProxysFlagsFollowTheContextsClass() throws {
        let kubeconfig = try write("apiVersion: v1\nkind: Config\n", to: "kc.yaml")
        let planner = planner(kubeconfigs: [kubeconfig], kubectl: try standIn())
        let configuration = KubeProxies.Configuration(kubectlPath: try standIn().path)
        for (name, readOnly) in [("fake-prod", true), ("fake-dev", true), ("kind-fake", false)] {
            let spec = try awaitResult { try await planner.plan(Self.context(name), configuration: configuration, serverMinor: nil) }
            XCTAssertEqual(spec.readOnly, readOnly, name)
            XCTAssertEqual(spec.arguments.contains("--reject-methods=\(KubeProxyFlags.rejectedMethods)"), readOnly, name)
        }
        let writableDev = try awaitResult {
            try await planner.plan(Self.context("fake-dev", writable: true), configuration: configuration, serverMinor: nil)
        }
        XCTAssertFalse(writableDev.readOnly, "a remote context made writable by its flag")
        let prod = try awaitResult { try await planner.plan(Self.context("fake-prod", writable: true), configuration: configuration, serverMinor: nil) }
        XCTAssertTrue(prod.readOnly, "production ignores the flag")
    }

    // MARK: The socket

    func testTheSocketIsShortPrivateAndNamedByAHash() throws {
        let folder = KubeSocketFolder(base: base)
        let arn = "arn:aws:eks:eu-west-1:111122223333:cluster/" + String(repeating: "acme-production-", count: 20)
        let socket = try folder.socket(for: arn)
        XCTAssertLessThanOrEqual(socket.utf8.count, 103, "a unix socket's path is 104 bytes with its NUL")
        XCTAssertEqual(KubeSocketFolder.name(for: arn).count, 12 + ".sock".count)
        XCTAssertNotEqual(KubeSocketFolder.name(for: "fake-dev"), KubeSocketFolder.name(for: "fake-prod"))
        XCTAssertEqual(KubeSocketFolder.name(for: "fake-dev"), KubeSocketFolder.name(for: "fake-dev"), "the same name every run")
        XCTAssertFalse(socket.contains("acme"), "never the context's name")
        XCTAssertEqual(try folder.prepare(), folder.path)
        XCTAssertEqual(try mode(folder.path), 0o700)
        // The app's own folder fits too, under /tmp.
        XCTAssertLessThanOrEqual(try KubeSocketFolder.app.socket(for: arn).utf8.count, 103)
        XCTAssertTrue(KubeSocketFolder.app.path.hasPrefix("/tmp/ot-kube-\(getuid())-\(getpid())"))

        // A deep base folder (the support folder made 132 bytes) is refused before kubectl's bind fails.
        let deep = KubeSocketFolder(base: base.appendingPathComponent(String(repeating: "d", count: 90)))
        XCTAssertThrowsError(try deep.socket(for: "fake-dev")) { error in
            guard case .socket(let reason) = error as? KubeProxyProblem else { return XCTFail("\(error)") }
            XCTAssertTrue(reason.contains("103"), reason)
        }
    }

    func testAFolderOpenToOthersIsMadePrivateAndALinkRefused() throws {
        let folder = KubeSocketFolder(base: base)
        XCTAssertEqual(mkdir(folder.path, 0o755), 0)
        chmod(folder.path, 0o755)
        try folder.prepare()
        XCTAssertEqual(try mode(folder.path), 0o700)
        try FileManager.default.removeItem(atPath: folder.path)
        try FileManager.default.createSymbolicLink(atPath: folder.path, withDestinationPath: dir.path)
        XCTAssertThrowsError(try folder.prepare(), "a link someone put there is never followed")
    }

    func testWhatADeadRunLeftIsSwept() throws {
        // 99999 is past macOS's highest pid: never a running process.
        let dead = base.appendingPathComponent("ot-kube-\(getuid())-99999")
        let alive = base.appendingPathComponent("ot-kube-\(getuid())-\(getppid())")
        try FileManager.default.createDirectory(at: dead, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: alive, withIntermediateDirectories: true)
        let folder = KubeSocketFolder(base: base)
        try folder.prepare()
        XCTAssertFalse(FileManager.default.fileExists(atPath: dead.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: alive.path), "a running process's folder is its own")
        folder.remove()
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    }

    // MARK: The environment

    func testAGuardedRunNeverHandsKubectlTheUsersKubeconfig() throws {
        let home = dir.appendingPathComponent("home", isDirectory: true)
        let own = try write("apiVersion: v1\n", to: "fake.kubeconfig")
        let users = home.appendingPathComponent(".kube/config")
        let base = [
            "PATH": "/usr/bin:/bin", "KUBECONFIG": users.path, "AWS_PROFILE": "prod", "AWS_SESSION_TOKEN": "x", "HOME": home.path,
            "KUBERC": home.appendingPathComponent(".kube/kuberc").path, "KUBECTL_KUBERC": "true",
        ]

        let guarded = try XCTUnwrap(
            KubeProxyEnvironment.make(base: base, kubeconfigs: [own], guarded: true, home: home, isolatedHome: "/tmp/ot-kube-run/home"))
        XCTAssertEqual(guarded["KUBECONFIG"], own.path, "set to the run's file, never inherited")
        XCTAssertEqual(guarded["HOME"], "/tmp/ot-kube-run/home", "nothing under the user's home is read")
        XCTAssertEqual(guarded["KUBERC"], "off", "no kuberc sets a flag of the proxy's")
        XCTAssertEqual(guarded["KUBECTL_KUBERC"], "false")
        XCTAssertNil(guarded["AWS_PROFILE"])
        XCTAssertNil(guarded["AWS_SESSION_TOKEN"])
        XCTAssertEqual(guarded["PATH"], "/usr/bin:/bin")
        XCTAssertNil(KubeProxyEnvironment.make(base: base, kubeconfigs: [], guarded: true, home: home), "none to read: nothing starts")
        XCTAssertNil(KubeProxyEnvironment.make(base: base, kubeconfigs: [own, users], guarded: true, home: home), "~/.kube refused")

        let app = try XCTUnwrap(KubeProxyEnvironment.make(base: base, kubeconfigs: [users, own], guarded: false, home: home))
        XCTAssertEqual(app["KUBECONFIG"], users.path + ":" + own.path, "the app's files, in kubectl's order")
        XCTAssertEqual(app["AWS_PROFILE"], "prod", "the app's exec plugins get the shell's AWS settings")
        XCTAssertEqual(app["HOME"], home.path, "the app's own kubectl has the user's home")
        XCTAssertEqual(app["KUBERC"], "off", "but never the user's kuberc, whatever the shell exported")
        XCTAssertEqual(app["KUBECTL_KUBERC"], "false")
    }

    /// A unit test is guarded: without OVERTERM_KUBECONFIG it reads no
    /// kubeconfig, so the planner refuses before anything starts — not
    /// ~/.kube/config, not KUBECONFIG, not the setting's extras.
    func testAUnitTestsPlannerReadsNoKubeconfigOfTheUsers() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["OVERTERM_KUBECONFIG"] != nil, "a run of its own fake clusters")
        XCTAssertTrue(AppEnvironment.guardsKubeconfig)
        XCTAssertEqual(AppEnvironment.kubeconfigs(extra: ["~/.kube/config", "~/.kube"]), [])
        var planner = KubeProxyPlanner(folder: KubeSocketFolder(base: base))
        planner.baseEnvironment = {
            XCTFail("no environment is asked for")
            return [:]
        }
        let configuration = KubeProxies.Configuration(kubectlPath: "/usr/local/bin/kubectl", extraKubeconfigs: ["~/.kube/config"])
        let guardedPlanner = planner
        XCTAssertThrowsError(try awaitResult { try await guardedPlanner.plan(Self.context("fake-dev"), configuration: configuration, serverMinor: nil) }) {
            XCTAssertEqual($0 as? KubeProxyProblem, .noKubeconfig)
        }
        XCTAssertTrue(planner.guarded)
    }

    // MARK: Which kubectl

    func testWhichKubectl() {
        let home = URL(fileURLWithPath: "/Users/u")
        let installed: Set<String> = [
            "/usr/local/bin/kubectl", "/Applications/Docker.app/Contents/Resources/bin/kubectl", "/Users/u/bin/kubectl", "/opt/k/kubectl",
        ]
        // /usr/local/bin's is Docker Desktop's, as on this Mac: one copy.
        let resolve: (URL) -> URL = {
            $0.path == "/usr/local/bin/kubectl" ? URL(fileURLWithPath: "/Applications/Docker.app/Contents/Resources/bin/kubectl") : $0
        }
        let found = KubectlLocator.candidates(
            configured: "", guarded: false, loginPath: "/Users/u/bin:/usr/bin", home: home, isExecutable: installed.contains, resolve: resolve)
        XCTAssertEqual(found.map(\.path), ["/usr/local/bin/kubectl", "/Users/u/bin/kubectl"])
        let configured = KubectlLocator.candidates(
            configured: "/opt/k/kubectl", guarded: false, loginPath: nil, home: home, isExecutable: installed.contains, resolve: resolve)
        XCTAssertEqual(configured.first?.path, "/opt/k/kubectl", "the setting first")
        XCTAssertEqual(
            KubectlLocator.candidates(configured: "", guarded: true, loginPath: "/Users/u/bin", home: home, isExecutable: installed.contains), [],
            "an isolated run looks nowhere but the setting")
        XCTAssertEqual(
            KubectlLocator.candidates(configured: "/opt/k/kubectl", guarded: true, loginPath: "/Users/u/bin", home: home, isExecutable: installed.contains)
                .map(\.path), ["/opt/k/kubectl"])

        let a = URL(fileURLWithPath: "/a/kubectl")
        let b = URL(fileURLWithPath: "/b/kubectl")
        let c = URL(fileURLWithPath: "/c/kubectl")
        let versions: [(url: URL, minor: Int?)] = [(a, 36), (b, 31), (c, nil)]
        XCTAssertEqual(KubectlLocator.choose(versions, serverMinor: 30, configured: false), b, "closest to the server")
        XCTAssertEqual(KubectlLocator.choose(versions, serverMinor: 36, configured: false), a)
        XCTAssertEqual(KubectlLocator.choose(versions, serverMinor: nil, configured: false), a, "unknown: the first")
        XCTAssertEqual(KubectlLocator.choose(versions, serverMinor: 30, configured: true), a, "the setting overrides")
        XCTAssertEqual(KubectlLocator.choose([(c, nil), (a, nil)], serverMinor: 30, configured: false), c)
        XCTAssertNil(KubectlLocator.choose([], serverMinor: 30, configured: false))

        XCTAssertEqual(KubeVersion.minor(Data(#"{"major":"1","minor":"30+","gitVersion":"v1.30.4-eks"}"#.utf8)), 30)
        XCTAssertEqual(KubeVersion.minor(Data(#"{"clientVersion":{"major":"1","minor":"36"}}"#.utf8), under: "clientVersion"), 36)
        XCTAssertNil(KubeVersion.minor(Data("nope".utf8)))
    }

    // MARK: Errors

    func testWhatTheProxysErrorsMean() {
        let aws = "getting credentials: exec: executable aws failed with exit code 255"
        XCTAssertEqual(
            KubeProxyProblem.classify(status: 500, contentType: "text/plain; charset=utf-8", text: aws, stderr: "Token has expired", signIn: .aws(profile: "dev")),
            .awsSignIn(profile: "dev"))
        XCTAssertEqual(KubeProxyProblem.awsSignIn(profile: "dev").reason, "Sign in again: aws sso login --profile dev")
        XCTAssertEqual(KubeProxyProblem.awsSignIn(profile: nil).reason, "Sign in again: aws sso login")
        XCTAssertEqual(KubeProxyProblem.awsSignIn(profile: "my profile").command, "aws sso login --profile 'my profile'")
        XCTAssertTrue(KubeProxyProblem.awsSignIn(profile: nil).stopsRequests, "no retries: each runs aws again")

        let oidc = "getting credentials: exec: executable kubectl failed with exit code 1"
        XCTAssertEqual(
            KubeProxyProblem.classify(status: 500, contentType: "text/plain", text: oidc, stderr: "error: get-token: context deadline exceeded", signIn: .oidc),
            .signInTimedOut)
        XCTAssertEqual(KubeProxyProblem.signInTimedOut.reason, "The browser sign-in timed out. Try again to sign in.")
        XCTAssertEqual(
            KubeProxyProblem.classify(status: 500, contentType: "text/plain", text: oidc, stderr: "error: invalid_grant", signIn: .oidc),
            .signInFailed(oidc))
        XCTAssertEqual(
            KubeProxyProblem.classify(
                status: 500, contentType: "text/plain",
                text: #"getting credentials: exec: executable gke-gcloud-auth-plugin not found"# + "\n\nIt looks like…", stderr: "",
                signIn: .plugin("gke-gcloud-auth-plugin")),
            .credentials(#"getting credentials: exec: executable gke-gcloud-auth-plugin not found"# + "\n\nIt looks like…"))
        XCTAssertEqual(
            KubeProxyProblem.classify(
                status: 500, contentType: "text/plain", text: #"getting credentials: exec: executable aws not found: exec: "aws": executable file not found in $PATH"#,
                stderr: "", signIn: .aws(profile: nil)),
            .pluginMissing("aws", hint: nil))

        let dial = "dial tcp 10.0.0.10:6443: i/o timeout"
        XCTAssertEqual(KubeProxyProblem.classify(status: 500, contentType: "text/plain", text: dial, stderr: "", signIn: .none), .unreachable(dial))
        XCTAssertFalse(KubeProxyProblem.unreachable(dial).stopsRequests, "the VPN comes back")
        XCTAssertEqual(KubeProxyProblem.unreachable(dial).reason, "The cluster can't be reached (VPN?).")

        // The server's own answers are answers, not the proxy's failures.
        let status = #"{"kind":"Status","code":500,"message":"etcdserver: request timed out"}"#
        XCTAssertNil(KubeProxyProblem.classify(status: 500, contentType: "application/json", text: status, stderr: "", signIn: .none))
        XCTAssertNil(KubeProxyProblem.classify(status: 500, contentType: nil, text: status, stderr: "", signIn: .none))
        XCTAssertNil(KubeProxyProblem.classify(status: 403, contentType: "text/plain", text: "Forbidden\n", stderr: "", signIn: .none))
        XCTAssertNil(KubeProxyProblem.classify(status: 200, contentType: "text/plain", text: aws, stderr: "", signIn: .aws(profile: nil)))

        XCTAssertEqual(KubeSignIn(.exec(KubeExec(command: "aws", arguments: ["eks", "get-token", "--cluster-name", "c", "--profile=ops"]))), .aws(profile: "ops"))
        XCTAssertEqual(KubeSignIn(.exec(KubeExec(command: "kubectl", arguments: ["oidc-login", "get-token"]))), .oidc)
        XCTAssertEqual(KubeSignIn(.clientCertificate), .none)
        XCTAssertEqual(KubeProxyProblem.needsTerminal(context: "arn:aws:eks:x:1:cluster/a b").command, "kubectl --context 'arn:aws:eks:x:1:cluster/a b' version")
    }

    func testAPluginThatNeedsATerminalOrIsntInstalledStartsNothing() throws {
        let kubeconfig = try write("apiVersion: v1\n", to: "kc.yaml")
        let kubectl = try standIn()
        let planner = planner(kubeconfigs: [kubeconfig], kubectl: kubectl, path: dir.path)
        let configuration = KubeProxies.Configuration(kubectlPath: kubectl.path)
        let always = Self.context("fake-dev", auth: .exec(KubeExec(command: "aws", interactiveMode: "Always")))
        XCTAssertThrowsError(try awaitResult { try await planner.plan(always, configuration: configuration, serverMinor: nil) }) {
            XCTAssertEqual($0 as? KubeProxyProblem, .needsTerminal(context: "fake-dev"))
        }
        let missing = Self.context("fake-dev", auth: .exec(KubeExec(command: "kubectl", arguments: ["oidc-login", "get-token"], installHint: "brew install kubelogin")))
        XCTAssertThrowsError(try awaitResult { try await planner.plan(missing, configuration: configuration, serverMinor: nil) }) {
            XCTAssertEqual($0 as? KubeProxyProblem, .pluginMissing("kubectl oidc-login", hint: "brew install kubelogin"))
            XCTAssertEqual(($0 as? KubeProxyProblem)?.reason, "kubectl oidc-login isn't installed. brew install kubelogin")
        }
        // kubectl's plugin on the PATH is enough.
        let plugin = dir.appendingPathComponent("kubectl-oidc_login")
        try "#!/bin/sh\n".write(to: plugin, atomically: true, encoding: .utf8)
        chmod(plugin.path, 0o755)
        XCTAssertNoThrow(try awaitResult { try await planner.plan(missing, configuration: configuration, serverMinor: nil) })
    }

    // MARK: Started

    /// The stand-in kubectl writes what it was given and makes the socket:
    /// that is what the app would start.
    func testTheProxyStartedIsTheStandInWithItsArgumentsAndEnvironment() async throws {
        let kubeconfig = try write("apiVersion: v1\nkind: Config\n", to: "kc.yaml")
        let kubectl = try standIn()
        let folder = KubeSocketFolder(base: base)
        var planner = planner(kubeconfigs: [kubeconfig], kubectl: kubectl)
        planner.folder = folder
        let spec = try await planner.plan(
            Self.context("arn:aws:eks:eu-west-1:111122223333:cluster/fake-prod"), configuration: KubeProxies.Configuration(kubectlPath: kubectl.path),
            serverMinor: nil)
        XCTAssertEqual(spec.socket, try folder.socket(for: "arn:aws:eks:eu-west-1:111122223333:cluster/fake-prod"))
        XCTAssertEqual(spec.environment["KUBECONFIG"], kubeconfig.path)
        XCTAssertNotNil(spec.cacheDirectory, "a guarded run's own cache")

        let proxy = try await KubeProxy.open(spec)
        let pid = try XCTUnwrap(proxy.pid)
        XCTAssertTrue(proxy.isOpen)
        XCTAssertTrue(ManagedProcess.livePIDs.contains(pid))
        let argv = try String(contentsOf: dir.appendingPathComponent("argv"), encoding: .utf8).split(separator: "\n").map(String.init)
        XCTAssertEqual(argv, spec.arguments)
        XCTAssertEqual(argv.first, "--context=arn:aws:eks:eu-west-1:111122223333:cluster/fake-prod")
        XCTAssertTrue(argv.contains("--reject-methods=\(KubeProxyFlags.rejectedMethods)"), "production is read-only")
        XCTAssertTrue(argv.contains("--disable-filter=false"), "the filters can't be switched off by a kuberc")
        let environment = try String(contentsOf: dir.appendingPathComponent("env"), encoding: .utf8)
        XCTAssertTrue(environment.contains("KUBECONFIG=\(kubeconfig.path)\n"))
        XCTAssertTrue(environment.contains("\nKUBERC=off\n") || environment.hasPrefix("KUBERC=off\n"), "kuberc off")
        XCTAssertTrue(environment.contains("HOME=\(folder.isolatedHome)\n"), "the run's own HOME")
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.isolatedHome))
        XCTAssertEqual(try mode(folder.isolatedHome), 0o700)
        XCTAssertFalse(environment.contains(".kube/config"))
        try await until { FileManager.default.fileExists(atPath: spec.socket) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: spec.socket))

        proxy.close()
        try await until { kill(pid, 0) != 0 }
        XCTAssertNotEqual(kill(pid, 0), 0, "closed by its own pid")
        XCTAssertFalse(FileManager.default.fileExists(atPath: spec.socket), "its socket removed")
    }

    func testAProxyThatExitsSaysWhy() async throws {
        let script = dir.appendingPathComponent("kubectl-fails")
        try "#!/bin/sh\necho 'error: context \"nope\" does not exist' >&2\nexit 1\n".write(to: script, atomically: true, encoding: .utf8)
        chmod(script.path, 0o755)
        let spec = KubeProxySpec(
            context: "nope", readOnly: true, kubectl: script, socket: base.appendingPathComponent("x.sock").path, environment: [:], cacheDirectory: nil,
            signIn: .none)
        do {
            _ = try await KubeProxy.open(spec)
            XCTFail("it exited")
        } catch {
            XCTAssertEqual(error as? KubeProxyProblem, .proxyFailed(#"error: context "nope" does not exist"#))
        }
    }

    // MARK: The real kubectl

    /// The real `kubectl proxy`, started as the app starts it, against a
    /// server of the test's own on 127.0.0.1 through a kubeconfig of the
    /// test's own: what the flags let through, and what they don't. Skipped
    /// without kubectl.
    func testTheRealKubectlProxyEnforcesTheFlags() async throws {
        let kubectl = URL(fileURLWithPath: "/usr/local/bin/kubectl")
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: kubectl.path), "no kubectl")
        let server = RecordingServer()
        let port = try server.start()
        defer { server.stop() }
        let kubeconfig = try write(
            """
            apiVersion: v1
            kind: Config
            clusters:
            - name: fake
              cluster: {server: "http://127.0.0.1:\(port)"}
            users:
            - name: anonymous
              user: {}
            contexts:
            - name: fake-dev
              context: {cluster: fake, user: anonymous}
            - name: kind-fake
              context: {cluster: fake, user: anonymous}
            current-context: fake-dev
            """, to: "fake.kubeconfig")
        var planner = planner(kubeconfigs: [kubeconfig], kubectl: kubectl)
        planner.folder = KubeSocketFolder(base: base)
        let real = planner
        let proxies = KubeProxies(
            configuration: KubeProxies.Configuration(kubectlPath: kubectl.path), plan: { try await real.plan($0, configuration: $1, serverMinor: $2) })
        defer { proxies.closeAll() }
        let dev = Self.context("fake-dev", server: "http://127.0.0.1:\(port)")
        let kind = Self.context("kind-fake", server: "http://127.0.0.1:\(port)")
        XCTAssertFalse(dev.isWritable, "remote although its server is 127.0.0.1")
        XCTAssertTrue(kind.isWritable)

        let listed = try await proxies.send(dev, .GET, "/api/v1/namespaces/default/pods")
        XCTAssertEqual(listed.status, 200)
        XCTAssertEqual(server.requests, ["GET /api/v1/namespaces/default/pods"])
        let version = try await proxies.send(dev, .GET, "/version")
        XCTAssertEqual(version.status, 200)

        // A read-only context: no write method, no subresource that reaches inside.
        // Every method but GET: kubectl matches the method as sent, so a
        // lowercase or unknown one is refused by name too.
        for method in [HTTPMethod.POST, .PUT, .PATCH, .DELETE, .OPTIONS, .RAW(value: "post"), .RAW(value: "Delete"), .RAW(value: "PROPFIND")] {
            let refused = try await proxies.send(dev, method, "/api/v1/namespaces/default/pods", body: Data("{}".utf8))
            XCTAssertEqual(refused.status, 403, "\(method)")
        }
        let reaching = [
            "/api/v1/namespaces/default/pods/p/exec?command=sh", "/api/v1/namespaces/default/pods/p/attach",
            "/api/v1/namespaces/default/pods/p/portforward", "/api/v1/namespaces/default/pods/p:80/proxy/",
            "/api/v1/namespaces/default/services/s:80/proxy/", "/api/v1/nodes/n/proxy/stats/summary",
            "/api/v1/namespaces/default/pods/a%2Fb/exec",
        ]
        for path in reaching {
            let refused = try await proxies.send(dev, .GET, path)
            XCTAssertEqual(refused.status, 403, path)
        }
        // Path variants are redirected by kubectl's mux, never proxied.
        for path in ["//api/v1/namespaces/default/pods/p/exec", "/api/v1/namespaces/default/pods/p/./exec", "/api/v1/namespaces/default/pods/x/../p/exec"] {
            let variant = try await proxies.send(dev, .GET, path)
            XCTAssertFalse((200..<300).contains(variant.status), "\(path): \(variant.status)")
        }
        // Any Host but localhost is refused.
        let socket = try planner.folder.socket(for: "fake-dev")
        for host in ["example.com", "127.0.0.1", "localhost.evil"] {
            let other = UnixHTTPTransport(address: .unix(socket), host: host, readinessPath: "/version", service: "test")
            let refused = try await other.send(.GET, "/api/v1/namespaces/default/pods", body: nil, headers: [])
            XCTAssertEqual(refused.status, 403, host)
        }
        XCTAssertEqual(server.requests, ["GET /api/v1/namespaces/default/pods", "GET /version"], "nothing else reached the server")

        // A writable context: writes pass; what reaches inside still doesn't.
        let created = try await proxies.send(kind, .POST, "/api/v1/namespaces/default/pods", body: Data("{}".utf8))
        XCTAssertEqual(created.status, 200)
        let exec = try await proxies.send(kind, .POST, "/api/v1/namespaces/default/pods/p/exec")
        XCTAssertEqual(exec.status, 403)
        XCTAssertEqual(server.requests.last, "POST /api/v1/namespaces/default/pods")
        XCTAssertEqual(server.requests.count, 3)
        let connected = await proxies.connected
        XCTAssertEqual(connected, ["fake-dev", "kind-fake"])
    }

    // MARK: Helpers

    @discardableResult
    private func write(_ text: String, to name: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// A stand-in kubectl: writes its arguments and environment beside it,
    /// says it serves, and listens on its socket until it is ended.
    private func standIn() throws -> URL {
        let url = dir.appendingPathComponent("kubectl")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let script = """
            #!/bin/sh
            out="$(dirname "$0")"
            : > "$out/argv"
            socket=""
            for argument in "$@"; do
              printf '%s\\n' "$argument" >> "$out/argv"
              case "$argument" in --unix-socket=*) socket="${argument#--unix-socket=}" ;; esac
            done
            /usr/bin/env > "$out/env"
            echo "Starting to serve on $socket"
            exec /usr/bin/nc -lkU "$socket"
            """
        try script.write(to: url, atomically: true, encoding: .utf8)
        chmod(url.path, 0o755)
        return url
    }

    private func planner(kubeconfigs: [URL], kubectl: URL, path: String = "/usr/bin:/bin") -> KubeProxyPlanner {
        var planner = KubeProxyPlanner(folder: KubeSocketFolder(base: base))
        planner.guarded = true
        planner.home = dir.appendingPathComponent("home", isDirectory: true)
        planner.kubeconfigs = { _ in kubeconfigs }
        planner.baseEnvironment = { ["PATH": path, "HOME": NSTemporaryDirectory()] }
        return planner
    }

    private func mode(_ path: String) throws -> mode_t {
        var info = stat()
        guard lstat(path, &info) == 0 else { throw CocoaError(.fileNoSuchFile) }
        return info.st_mode & 0o777
    }

    private func until(_ ok: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !ok(), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
    }

    /// An async call's result in a synchronous test.
    private func awaitResult<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) throws -> T {
        let box = ResultBox<T>()
        let done = expectation(description: "done")
        Task {
            do { box.result = .success(try await work()) } catch { box.result = .failure(error) }
            done.fulfill()
        }
        wait(for: [done], timeout: 15)
        return try box.result!.get()
    }
}

private final class ResultBox<T>: @unchecked Sendable {
    var result: Result<T, Error>?
}

/// A tiny API server on 127.0.0.1: answers every request 200 with an empty
/// Status and records it — what reached it is what the proxy let through.
private final class RecordingServer: @unchecked Sendable {
    private let lock = NSLock()
    private var asked: [String] = []
    private var channel: Channel?

    var requests: [String] { lock.withLock { asked } }
    fileprivate func record(_ line: String) { lock.withLock { asked.append(line) } }

    func start() throws -> Int {
        let bootstrap = ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.configureHTTPServerPipeline(withPipeliningAssistance: false, withErrorHandling: true)
                    try channel.pipeline.syncOperations.addHandler(Handler(server: self))
                }
            }
        let bound = try bootstrap.bind(host: "127.0.0.1", port: 0).wait()
        channel = bound
        return bound.localAddress?.port ?? 0
    }

    func stop() { try? channel?.close().wait() }

    private final class Handler: ChannelInboundHandler, @unchecked Sendable {
        typealias InboundIn = HTTPServerRequestPart
        typealias OutboundOut = HTTPServerResponsePart

        let server: RecordingServer
        private var head: HTTPRequestHead?

        init(server: RecordingServer) {
            self.server = server
        }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            switch unwrapInboundIn(data) {
            case .head(let head): self.head = head
            case .body: break
            case .end:
                guard let head else { return }
                server.record("\(head.method.rawValue) \(head.uri.split(separator: "?").first.map(String.init) ?? head.uri)")
                let body = head.uri == "/version" ? #"{"major":"1","minor":"30+"}"# : #"{"kind":"Status","apiVersion":"v1","status":"Success"}"#
                var headers = HTTPHeaders()
                headers.add(name: "Content-Type", value: "application/json")
                headers.add(name: "Content-Length", value: "\(body.utf8.count)")
                context.write(wrapOutboundOut(.head(HTTPResponseHead(version: .http1_1, status: .ok, headers: headers))), promise: nil)
                context.write(wrapOutboundOut(.body(.byteBuffer(ByteBuffer(string: body)))), promise: nil)
                context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
            }
        }
    }
}
