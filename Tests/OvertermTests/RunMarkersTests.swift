import Darwin
import XCTest

@testable import Overterm
@testable import OvertermCore
@testable import OvertermDatabase
@testable import OvertermDocker
@testable import OvertermKubernetes
@testable import OvertermTerraform
@testable import OvertermShell
@testable import OvertermOvergit
@testable import OvertermAPI
@testable import OvertermNotes
@testable import OvertermSimulator
@testable import OvertermUsage
@testable import OvertermSettingsPage
@testable import OvertermAgents

/// Which Overterm started a process (docs/design/activity/analysis.md, 6.9,
/// D-15, 10.5): the run's marker, the argv signs that name it, the
/// leftover check's rules, and every spawn path's markers — each checked
/// where it builds its child's environment, and on a real child of the
/// test's where the path can start one harmlessly. Names are invented.
final class RunMarkersTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: "/tmp").appendingPathComponent("ot-rm-\(UInt32.random(in: 0...UInt32.max))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        ManagedProcess.closeAll()
        SSHTunnel.executable = URL(fileURLWithPath: "/usr/bin/ssh")
        SSHTunnel.closeAll()
        try? FileManager.default.removeItem(at: dir)
    }

    private let run = OvertermRun(kind: .release, identity: ActivityProcessID(pid: 4242, start: 1_700_000_000_123_456))

    // MARK: The run

    func testTheMarkerNamesTheKindThePidAndTheStart() {
        XCTAssertEqual(run.marker, "release.4242.1700000000123456")
        XCTAssertEqual(OvertermRun(marker: run.marker), run)
        XCTAssertNil(OvertermRun(marker: "app.4242.1"), "an unknown kind")
        XCTAssertNil(OvertermRun(marker: "dev.0.1"))
        XCTAssertNil(OvertermRun(marker: "dev.12.x"))
        XCTAssertNil(OvertermRun(marker: "dev.12.1.9"))
        XCTAssertEqual(OvertermRun.fromBase36(Substring(run.start36)), run.start, "the start in base 36, exactly")
        XCTAssertNil(OvertermRun.fromBase36("Zz"))
        XCTAssertNil(OvertermRun.fromBase36(""))
    }

    func testThisRunIsIsolatedAndItsIdentityThisProcesss() {
        XCTAssertEqual(OvertermRun.current.kind, .isolated, "a unit test is an isolated run")
        XCTAssertEqual(OvertermRun.current.pid, getpid())
        XCTAssertEqual(OvertermRun.current.start, ProcessInspector.kinfo(getpid())?.start)
    }

    func testTheKindIsTheInstalledAppOrADevelopmentBuild() {
        let home = "/Users/acme"
        XCTAssertEqual(OvertermRun.Kind.of(isolated: false, bundlePath: "/Applications/Overterm.app", home: home), .release)
        XCTAssertEqual(OvertermRun.Kind.of(isolated: false, bundlePath: "/Users/acme/Applications/Overterm.app", home: home), .release)
        XCTAssertEqual(OvertermRun.Kind.of(isolated: false, bundlePath: "/Applications/Overterm Dev.app", home: home), .dev)
        XCTAssertEqual(OvertermRun.Kind.of(isolated: false, bundlePath: "/Users/acme/src/overterm/Overterm.app", home: home), .dev)
        XCTAssertEqual(OvertermRun.Kind.of(isolated: true, bundlePath: "/Applications/Overterm.app", home: home), .isolated)
    }

    func testMarkingSetsBothOverWhatWasInheritedAndUnmarkingTakesBoth() {
        let inherited = ["PATH": "/usr/bin", "OVERTERM_RUN": "release.1.1", "OVERTERM_HELPER": "git", "OVERTERM_TAB_ID": "acme-tab"]
        let marked = run.marking(inherited, helper: .kubectlProxy)
        XCTAssertEqual(marked["OVERTERM_RUN"], run.marker, "an Overterm started from another's pane names itself")
        XCTAssertEqual(marked["OVERTERM_HELPER"], "kubectl-proxy")
        XCTAssertEqual(marked["PATH"], "/usr/bin")
        XCTAssertEqual(OvertermRun.unmarked(marked).keys.sorted(), ["OVERTERM_TAB_ID", "PATH"])
        // The names the census scans for, exactly (ProcessMarkers).
        XCTAssertEqual([OvertermRun.variable, OvertermRun.helperVariable], Array(ProcessMarkers.names[1...2]))
    }

    // MARK: The argv signs

    func testEachSignNamesItsRunByPidAndStart() {
        let id = run.identity
        let kube = "/tmp/" + ArgvSign.kubeFolder(uid: 501, run: id) + "/0a1b2c3d4e5f-ro-3.sock"
        XCTAssertEqual(ArgvSign.signs(in: "kubectl proxy --unix-socket=\(kube) --context fake-dev"), [.kubectl(id)])
        let docker = "/var/folders/xy/T/" + ArgvSign.dockerSocket(run: id, key: "1a2b3c")
        XCTAssertEqual(ArgvSign.signs(in: "ssh -N -T -L \(docker):/var/run/docker.sock acme-build"), [.dockerSSH(id)])
        let tunnel = "/var/folders/xy/T/" + ArgvSign.runFolder(run: id) + "/db-1a2b3c4d"
        XCTAssertEqual(ArgvSign.signs(in: "ssh -o ControlPath=\(tunnel) acme-bastion"), [.databaseTunnel(id)])
        let scratch = UUID().uuidString
        XCTAssertEqual(
            ArgvSign.signs(in: "/usr/bin/perl /var/folders/xy/T/overterm-e2e-\(scratch)/stand-in-bin/port-forward.pl 127.0.0.1 8080"),
            [.testScratch(scratch)])
        // Nothing that only looks like one.
        for text in [
            "ot-kube-501-4242-abc/x.sock", "/tmp/ot-kube-501-4242/x.sock", "/tmp/ot-kube-501-4242-ABC/x", "ot-docker-4242-1a2b.sock",
            "/x/ot-run-4242-abc/other", "/x/overterm-e2e-not-a-uuid/stand-in", "",
        ] {
            XCTAssertEqual(ArgvSign.signs(in: text), [], text)
        }
    }

    func testTheSignsSurviveTheMasking() {
        let id = run.identity
        let socket = "/tmp/" + ArgvSign.kubeFolder(uid: 501, run: id) + "/0a1b2c3d4e5f-1.sock"
        XCTAssertEqual(ArgvSign.signs(in: ActivityText.command(["kubectl", "proxy", "--unix-socket=\(socket)"])), [.kubectl(id)])
    }

    // MARK: The leftover check

    func testARunsProcessIsKnownOnlyByItsStartAndWhatSaysItIsTheRuns() {
        let later = ActivityProcessID(pid: 5000, start: run.start + 1)
        let earlier = ActivityProcessID(pid: 5000, start: run.start - 1)
        func why(_ id: ActivityProcessID, marker: String? = nil, command: String? = nil, recorded: UInt64? = nil, scratch: String? = nil) -> RunLeftover.Why? {
            RunLeftovers.why(id, run: run, scratch: scratch, marker: marker, command: command, recordedBy: recorded)
        }
        XCTAssertEqual(why(later, marker: run.marker), .marker)
        XCTAssertNil(why(earlier, marker: run.marker), "started before the run: another's, whatever it carries")
        XCTAssertNil(why(run.identity, marker: run.marker), "the run itself")
        XCTAssertNil(why(later, marker: "release.4242.1"), "a run with the same pid, another start")
        XCTAssertNil(why(later), "nothing says it is the run's: never the pid alone")
        XCTAssertEqual(why(later, recorded: later.start), .recorded)
        XCTAssertNil(why(later, recorded: later.start - 1), "started after its record: the pid taken again")
        let kube = "/tmp/" + ArgvSign.kubeFolder(uid: 501, run: run.identity) + "/a.sock"
        XCTAssertEqual(why(later, command: "kubectl proxy --unix-socket=\(kube)"), .sign(.kubectl(run.identity)))
        let other = "/tmp/" + ArgvSign.kubeFolder(uid: 501, run: ActivityProcessID(pid: 4242, start: 9)) + "/a.sock"
        XCTAssertNil(why(later, command: "kubectl proxy --unix-socket=\(other)"), "the same pid, an earlier run's folder")
        let id = UUID().uuidString
        let script = "/usr/bin/perl /var/folders/xy/T/overterm-e2e-\(id)/stand-in-bin/port-forward.pl"
        XCTAssertEqual(why(later, command: script, scratch: id), .sign(.testScratch(id)))
        XCTAssertNil(why(later, command: script, scratch: UUID().uuidString), "another test run's")
    }

    func testTheCheckReadsOnlyTheUsersOwnAndSaysOnlyTheRunsOwn() {
        let mac = FakeActivityKernel(uid: 501)
        func add(_ pid: pid_t, start: UInt64, uid: uid_t = 501, name: String, words: [String], environment: [String] = [], status: Int32 = SRUN) {
            mac.add(
                FakeActivityKernel.Process(
                    record: FakeActivityKernel.record(pid: pid, start: start, parent: 1, uid: uid, status: status, name: name),
                    arguments: FakeActivityKernel.arguments(executable: "/usr/local/bin/\(name)", words, environment: environment)))
        }
        let after = run.start + 10
        add(6001, start: after, name: "acme-server", words: ["acme-server"], environment: ["OVERTERM_RUN=\(run.marker)", "AWS_SECRET_ACCESS_KEY=x"])
        add(6002, start: after, name: "globex-tool", words: ["globex-tool"], environment: ["OVERTERM_RUN=release.1.2"])
        add(6003, start: run.start - 10, name: "acme-old", words: ["acme-old"], environment: ["OVERTERM_RUN=\(run.marker)"])
        add(6004, start: after, uid: 0, name: "fake-root", words: ["fake-root"], environment: ["OVERTERM_RUN=\(run.marker)"])
        add(6005, start: after, name: "acme-zombie", words: [], environment: ["OVERTERM_RUN=\(run.marker)"], status: SZOMB)
        let kube = "/tmp/" + ArgvSign.kubeFolder(uid: 501, run: run.identity)
        add(6006, start: after, name: "kubectl", words: ["kubectl", "proxy", "--unix-socket=\(kube)/a-1.sock"])
        let left = RunLeftovers.find(run: run, scratch: nil, kernel: mac)
        XCTAssertEqual(left.map(\.identity.pid), [6001, 6006])
        XCTAssertEqual(left.map(\.why), [.marker, .sign(.kubectl(run.identity))])
        XCTAssertEqual(left.first?.said, "acme-server (pid 6001): carries the run's OVERTERM_RUN — acme-server")
        XCTAssertFalse(left.map(\.said).joined().contains("AWS"), "nothing of its environment but the marker")
    }

    /// Lineage before any match counts: an argv naming the run's scratch
    /// folder or socket folder is the run's only when its parents lead to
    /// the run or launchd, each started since — a person's own `grep`,
    /// under a shell older than the run, is never found, nor said.
    func testOnlyWhatDescendsFromTheRunOrLaunchdIsFound() {
        let mac = FakeActivityKernel(uid: 501)
        func add(_ pid: pid_t, start: UInt64, parent: pid_t, name: String, words: [String] = [], environment: [String] = []) {
            mac.add(
                FakeActivityKernel.Process(
                    record: FakeActivityKernel.record(pid: pid, start: start, parent: parent, uid: 501, status: SRUN, name: name),
                    arguments: FakeActivityKernel.arguments(executable: "/usr/local/bin/\(name)", words, environment: environment)))
        }
        let after = run.start + 10
        let id = UUID().uuidString
        let scratch = URL(fileURLWithPath: "/var/folders/xy/T/overterm-e2e-\(id)")
        let named = "/var/folders/xy/T/overterm-e2e-\(id)/stand-in-forwards.log"
        let kube = "/tmp/" + ArgvSign.kubeFolder(uid: 501, run: run.identity) + "/"
        add(4242, start: run.start, parent: 1, name: "Overterm")
        // The person's: a terminal and its shell older than the run.
        add(7000, start: run.start - 100, parent: 1, name: "acme-term")
        add(7001, start: run.start - 50, parent: 7000, name: "zsh")
        add(7002, start: after, parent: 7001, name: "tail", words: ["tail", "-f", named])
        add(7003, start: after, parent: 7001, name: "ls", words: ["ls", kube])
        add(7004, start: after, parent: 7002, name: "grep", words: ["grep", "x", named], environment: ["OVERTERM_RUN=\(run.marker)"])
        // The run's: under it, an orphan, an orphan's child; and one whose parent's pid was taken again.
        add(7010, start: after, parent: 4242, name: "perl", words: ["perl", named])
        add(7011, start: after, parent: 1, name: "kubectl", words: ["kubectl", "proxy", "--unix-socket=\(kube)a.sock"])
        add(7012, start: after + 1, parent: 7011, name: "acme-plugin", environment: ["OVERTERM_RUN=\(run.marker)"])
        add(7013, start: after + 5, parent: 1, name: "acme-late")
        add(7014, start: after, parent: 7013, name: "perl", words: ["perl", named])
        // Under the run with nothing to say: only while the app lives, and
        // a helper registry's pid.
        add(7020, start: after, parent: 4242, name: "sleep", words: ["/bin/sleep", "152"])
        add(7021, start: after, parent: 1, name: "terraform", words: ["terraform", "validate"])
        add(7022, start: after, parent: 7001, name: "terraform", words: ["terraform", "plan"])

        let outside = RunLeftovers.find(run: run, scratch: scratch, kernel: mac)
        XCTAssertEqual(outside.map(\.identity.pid).sorted(), [7010, 7011, 7012])
        let inside = RunLeftovers.find(run: run, scratch: scratch, kernel: mac, registered: [7021, 7022], descendants: true)
        XCTAssertEqual(inside.map(\.identity.pid).sorted(), [7010, 7011, 7012, 7020, 7021])
        XCTAssertEqual(inside.first { $0.identity.pid == 7020 }?.why, .descendant)
        XCTAssertEqual(inside.first { $0.identity.pid == 7021 }?.why, .registered)
        let said = inside.map(\.said).joined(separator: " ")
        for theirs in ["tail", "ls", "grep", "acme-term", "zsh"] { XCTAssertFalse(said.contains(theirs), theirs) }
        XCTAssertFalse(said.contains("pid 7022"), "a registry's pid under the person's shell: its pid taken again")
    }

    func testAStandInsRecordIsItsPidAndTheTimeItWroteIt() throws {
        let scratch = dir.appendingPathComponent("overterm-e2e-\(UUID().uuidString)")
        let line = RunLeftovers.recordLine(in: scratch)
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-c", line]
        try shell.run()
        shell.waitUntilExit()
        let recorded = RunLeftovers.recorded(in: scratch)
        XCTAssertEqual(Array(recorded.keys), [shell.processIdentifier])
        XCTAssertNotNil(recorded[shell.processIdentifier])
        XCTAssertEqual(RunLeftovers.scratchID(of: scratch).map { UUID(uuidString: $0) != nil }, true)
    }

    /// A real child of the test's whose argv names this run: found, by the
    /// live kernel, among the Mac's processes — its parent the run.
    func testTheLiveCheckFindsARealChildBySign() throws {
        let run = OvertermRun.current
        let controlPath = SSHTunnel.controlPath(for: UUID(), run: run.identity, folder: dir)
        // perl keeps its arguments in its argv: the path stays there.
        let child = try TestChild("/usr/bin/perl", ["-e", "sleep 30", controlPath])
        defer { child.stop() }
        let left = RunLeftovers.find(run: run, scratch: nil)
        XCTAssertEqual(left.filter { $0.identity == child.identity }.map(\.why), [.sign(.databaseTunnel(run.identity))])
    }

    // MARK: Every spawn path's markers

    private func expectMarked(_ environment: [String: String]?, _ helper: OvertermRun.Helper, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(environment?["OVERTERM_RUN"], OvertermRun.current.marker, file: file, line: line)
        XCTAssertEqual(environment?["OVERTERM_HELPER"], helper.rawValue, file: file, line: line)
    }

    /// What a child prints of its own two markers.
    private static let printMarkers = #"printf '%s|%s' "$OVERTERM_RUN" "$OVERTERM_HELPER""#
    private var expected: String { "\(OvertermRun.current.marker)|" }

    func testAPanesEnvironmentCarriesItsTagAndTheRunNeverAHelper() {
        let markers = TerminalView.paneMarkers(tag: "acme-tag")
        XCTAssertEqual(markers.map(\.key), ["OVERTERM_TAB_ID", "OVERTERM_RUN"])
        XCTAssertEqual(markers.map(\.value), ["acme-tag", OvertermRun.current.marker])
    }

    func testManagedProcessesAreMarkedByTheirKind() async throws {
        let target = DockerSSHTarget(user: "deploy", host: "acme-build", port: 2222)
        XCTAssertEqual(DockerSSHForward.launch(target, localSocket: "/tmp/ot.sock", remoteSocket: "/var/run/docker.sock").helper, .dockerSSH)
        let forward = KubePortForwardCommand.launch(kubectl: URL(fileURLWithPath: "/usr/local/bin/kubectl"), arguments: [], environment: ["PATH": "/usr/bin"])
        XCTAssertEqual(forward.helper, .kubectlPortForward)
        expectMarked(forward.markedEnvironment, .kubectlPortForward)
        XCTAssertEqual(forward.markedEnvironment["PATH"], "/usr/bin")
        // A real one: what it was started with.
        let process = try await ManagedProcess.start(
            ManagedProcess.Launch(
                executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", Self.printMarkers + "; echo; echo ready; exec /bin/sleep 30"],
                readiness: .line { $0 == "ready" }, helper: .kubectlProxy))
        defer { process.close() }
        XCTAssertTrue(process.stdout.text.contains("\(OvertermRun.current.marker)|kubectl-proxy"), process.stdout.text)
    }

    func testAKubectlProxyIsMarked() throws {
        let spec = KubeProxySpec(
            context: "fake-dev", readOnly: true, kubectl: URL(fileURLWithPath: "/usr/local/bin/kubectl"), socket: "/tmp/ot-x.sock",
            environment: ["PATH": "/usr/bin"], cacheDirectory: nil, signIn: .none)
        XCTAssertEqual(spec.launch.helper, .kubectlProxy)
        expectMarked(spec.launch.markedEnvironment, .kubectlProxy)
    }

    func testAShortKubectlOrHelmIsMarkedOnItsChild() throws {
        let kubectl = try XCTUnwrap(KubeProcessRun.run(URL(fileURLWithPath: "/bin/sh"), ["-c", Self.printMarkers], environment: ["PATH": "/usr/bin"], timeout: 10))
        XCTAssertEqual(kubectl.stdout, expected + "kubectl")
        let helm = try XCTUnwrap(
            KubeProcessRun.run(URL(fileURLWithPath: "/bin/sh"), ["-c", Self.printMarkers], environment: [:], timeout: 10, helper: .helm))
        XCTAssertEqual(helm.stdout, expected + "helm")
    }

    func testTerraformsChildrenAreMarked() throws {
        let script = dir.appendingPathComponent("terraform")
        try "#!/bin/sh\n\(Self.printMarkers)\n".write(to: script, atomically: true, encoding: .utf8)
        chmod(script.path, 0o755)
        let result = try TerraformRun.runBlocking(script, TerraformCommands.validate, in: dir, environment: ["PATH": "/usr/bin:/bin"], input: nil, timeout: 10)
        XCTAssertEqual(String(decoding: result.stdout, as: UTF8.self), expected + "terraform")
        expectMarked(TerraformRun.childEnvironment(["HOME": "/tmp/acme"]), .terraform)
        let apply = TerraformApplyLaunch.launchedEnvironment(["HOME": "/tmp/acme", "TF_LOG": "trace"])
        expectMarked(apply, .terraformApply)
        XCTAssertNil(apply["TF_LOG"], "still stripped of what logs values")
    }

    /// A stand-in executable of the test's: `body` after a shebang.
    private func standIn(_ name: String, _ body: String) throws -> URL {
        let url = dir.appendingPathComponent("bin/\(name)")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        chmod(url.path, 0o700)
        return url
    }

    /// A plan's stream, at its spawn: both ways it starts (straight, and
    /// through the umask launcher) hand terraform the run's markers.
    func testATerraformStreamIsMarkedOnItsChild() throws {
        let terraform = try standIn("terraform", Self.printMarkers + " >&2")
        let folder = try TerraformRunFolder.makeRun(base: dir.appendingPathComponent("runs"))
        let plan = try XCTUnwrap(TerraformCommands.plan(out: folder.appendingPathComponent("plan").path))
        for planFile in [nil, folder.appendingPathComponent("plan")] {
            let outcome = try TerraformStreamRun.run(terraform, plan, in: dir, environment: ["PATH": "/usr/bin:/bin"], planFile: planFile, batch: { _ in })
            XCTAssertEqual(outcome.stderr, expected + "terraform", "\(String(describing: planFile))")
        }
    }

    /// A detached apply, at its spawn: the launcher and the terraform it
    /// starts carry the run's markers.
    func testADetachedApplyIsMarkedOnItsChild() async throws {
        let terraform = try standIn("terraform", Self.printMarkers)
        let folder = dir.appendingPathComponent("runs/apply", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let planURL = dir.appendingPathComponent("plan")
        try Data("PK\u{3}\u{4}acme-plan".utf8).write(to: planURL)
        let plan = open(planURL.path, O_RDONLY | O_CLOEXEC)
        defer { close(plan) }
        let made = try TerraformApplyLaunch.spawn(
            binary: terraform, root: dir, environment: ["PATH": "/usr/bin:/bin"], plan: plan, folder: folder,
            marker: { pid, started in
                TerraformApplyMarker(
                    pid: pid, started: started, executable: TerraformApplyLaunch.shell, checkout: "/acme", root: "envs/dev", name: "envs/dev",
                    workspace: "default", rootClass: "local", identity: nil, at: TerraformApplyMarker.now)
            })
        // Reaped once it exits.
        _ = ProcessGroup.Child(pid: made.pid)
        let end = Date().addingTimeInterval(10)
        while TerraformApplyLaunch.status(in: folder) == nil, Date() < end { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertEqual(TerraformApplyLaunch.status(in: folder), 0)
        let printed = try String(contentsOf: folder.appendingPathComponent(TerraformApplyMarker.stdout), encoding: .utf8)
        XCTAssertEqual(printed, expected + "terraform-apply")
    }

    /// Docker's CLI followed line by line, at its spawn.
    func testDockersStreamedCLIIsMarkedOnItsChild() async throws {
        let docker = try standIn("docker", Self.printMarkers + "; echo")
        var lines: [String] = []
        for try await batch in DockerCLI(executable: docker, endpoint: nil).lines([], from: .stdout) { lines += batch }
        XCTAssertEqual(lines, [expected + "docker-cli"])
    }

    /// The database tunnel's ssh, at its spawn: a stand-in that says what
    /// it was started with, then fails, which the tunnel reports.
    func testTheTunnelsSSHIsMarkedOnItsChild() async throws {
        SSHTunnel.executable = try standIn("ssh", Self.printMarkers + " >&2; echo >&2; exit 1")
        do {
            _ = try await SSHTunnel.open(tunnelled(), secret: nil)
            XCTFail("the stand-in never forwards")
        } catch {
            XCTAssertEqual(error.localizedDescription, "SSH: " + expected + "database-tunnel")
        }
    }

    func testGitAndDockersCLIAreMarked() async throws {
        expectMarked(Git.environment(from: ["PATH": "/usr/bin"]), .git)
        let printed = try await Git.run(URL(fileURLWithPath: "/bin/sh"), ["-c", Self.printMarkers], in: dir)
        XCTAssertEqual(printed, expected + "git")
        let docker = URL(fileURLWithPath: "/usr/local/bin/docker")
        let words = DockerCLI.environment(for: nil, executable: docker)
        XCTAssertEqual(words.last, "OVERTERM_HELPER=docker-cli", "over Git.run's: env sets it")
        // The way DockerCLI runs it: env with those words before the tool.
        let viaEnv = try await Git.run(URL(fileURLWithPath: "/usr/bin/env"), words + ["/bin/sh", "-c", Self.printMarkers], in: dir)
        XCTAssertEqual(viaEnv, expected + "docker-cli")
    }

    func testTheLoginShellIsMarkedAndItsAnswerUnmarked() throws {
        let launched = ShellEnvironment.launchEnvironment(["PATH": "/usr/bin:/bin"])
        expectMarked(launched, .loginShell)
        let data = try XCTUnwrap(ShellEnvironment.run(URL(fileURLWithPath: "/bin/sh"), ["-c", Self.printMarkers], environment: launched, timeout: 10))
        XCTAssertEqual(String(decoding: data, as: UTF8.self), expected + "login-shell")
        let answer = "\(ShellEnvironment.marker)\0PATH=/usr/bin\0OVERTERM_RUN=\(OvertermRun.current.marker)\0OVERTERM_HELPER=login-shell\0"
        let parsed = try XCTUnwrap(ShellEnvironment.parse(Data(answer.utf8)))
        XCTAssertEqual(OvertermRun.unmarked(parsed), ["PATH": "/usr/bin"], "the next child sets its own")
    }

    func testALanguageServerTheTunnelAndTheUsageAskAreMarked() {
        let server = LanguageServer(
            name: "fake", command: LanguageServer.Command(executable: URL(fileURLWithPath: "/usr/local/bin/fake-ls")), root: dir,
            environmentRemoved: ["OVERTERM_*"])
        expectMarked(server.processEnvironment(["PATH": "/usr/bin"]), .languageServer)
        expectMarked(SSHTunnel.environment(["PATH": "/usr/bin"]), .databaseTunnel)
        expectMarked(AgentUsageCommand.environment(["PATH": "/usr/bin"]), .agentUsage)
    }

    // MARK: The tunnel's ControlPath

    private func tunnelled() -> DatabaseConnection {
        var connection = DatabaseConnection(name: "Behind", kind: .postgres)
        connection.host = "acme-db"
        connection.port = 5432
        connection.sshEnabled = true
        connection.sshHost = "acme-bastion"
        return connection
    }

    func testTheTunnelsControlPathNamesTheRunAndIsNeverMade() throws {
        let connection = tunnelled()
        let words = SSHTunnel.arguments(connection, localPort: 61000, batch: true)
        XCTAssertTrue(words.contains("ControlMaster=no"), "only ever a client, of a master nothing makes")
        let path = SSHTunnel.controlPath(for: connection.id)
        XCTAssertTrue(words.contains("ControlPath=\(path)"))
        XCTAssertLessThan(path.utf8.count, 104, "a unix socket's path")
        XCTAssertTrue(path.hasPrefix(try XCTUnwrap(SSHTunnel.userTemporaryDirectory).path), "the system's temporary folder for this user")
        XCTAssertFalse(FileManager.default.fileExists(atPath: (path as NSString).deletingLastPathComponent), "nothing creates it")
        // Folders of the test's own, private: only the path itself refused.
        let long = dir.appendingPathComponent(String(repeating: "d", count: 90))
        let expanded = dir.appendingPathComponent("a%b")
        for made in [long, expanded] {
            try FileManager.default.createDirectory(at: made, withIntermediateDirectories: true)
            chmod(made.path, 0o700)
        }
        XCTAssertEqual(SSHTunnel.controlPath(for: connection.id, folder: long), "none", "too long for ssh: no path rather than a refusal")
        XCTAssertEqual(SSHTunnel.controlPath(for: connection.id, folder: expanded), "none", "ssh would expand it")
        // Its sign, through the masking every reader sees argv by.
        XCTAssertEqual(ArgvSign.signs(in: ActivityText.command(["/usr/bin/ssh"] + words)), [.databaseTunnel(OvertermRun.current.identity)])
    }

    /// ssh never checks who made a master's socket: a folder another user
    /// could write in — a world-writable or sticky one, as `/tmp` is — or
    /// a link to one gives no ControlPath at all.
    func testTheControlPathIsOnlyInAFolderNoOneElseCanWrite() throws {
        let id = UUID()
        let own = dir.appendingPathComponent("own")
        try FileManager.default.createDirectory(at: own, withIntermediateDirectories: true)
        chmod(own.path, 0o700)
        XCTAssertTrue(SSHTunnel.controlPath(for: id, folder: own).hasPrefix(own.path + "/ot-run-"))
        let open = dir.appendingPathComponent("open")
        try FileManager.default.createDirectory(at: open, withIntermediateDirectories: true)
        chmod(open.path, 0o777)
        XCTAssertEqual(SSHTunnel.controlPath(for: id, folder: open), "none", "world-writable")
        chmod(open.path, 0o1777)
        XCTAssertEqual(SSHTunnel.controlPath(for: id, folder: open), "none", "sticky, as /tmp is")
        chmod(open.path, 0o770)
        XCTAssertEqual(SSHTunnel.controlPath(for: id, folder: open), "none", "its group's to write")
        let link = dir.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: own)
        XCTAssertEqual(SSHTunnel.controlPath(for: id, folder: link), "none", "a link, whatever it points at")
        XCTAssertEqual(SSHTunnel.controlPath(for: id, folder: URL(fileURLWithPath: "/tmp")), "none")
        XCTAssertEqual(SSHTunnel.controlPath(for: id, folder: nil), "none")
        XCTAssertEqual(SSHTunnel.controlPath(for: id, folder: dir.appendingPathComponent("missing")), "none")
    }

    // MARK: The kubectl socket folder

    func testTheSocketFolderNamesTheStartAndASweepKeepsOnlyLiveRuns() throws {
        let parent = getppid()
        let parentStart = try XCTUnwrap(ProcessInspector.kinfo(parent)?.start)
        let folder = KubeSocketFolder(base: dir)
        XCTAssertEqual((folder.path as NSString).lastPathComponent, "ot-kube-\(getuid())-\(getpid())-\(OvertermRun.current.start36)")
        let live = dir.appendingPathComponent(ArgvSign.kubeFolder(uid: getuid(), run: ActivityProcessID(pid: parent, start: parentStart)))
        let reused = dir.appendingPathComponent(ArgvSign.kubeFolder(uid: getuid(), run: ActivityProcessID(pid: parent, start: parentStart - 1)))
        let dead = dir.appendingPathComponent(ArgvSign.kubeFolder(uid: getuid(), run: ActivityProcessID(pid: 99_999, start: 7)))
        let older = dir.appendingPathComponent("ot-kube-\(getuid())-\(parent)")
        for made in [live, reused, dead, older] { try FileManager.default.createDirectory(at: made, withIntermediateDirectories: true) }
        try folder.prepare()
        XCTAssertTrue(FileManager.default.fileExists(atPath: live.path), "a live run's")
        XCTAssertFalse(FileManager.default.fileExists(atPath: reused.path), "its pid another process's now")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dead.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: older.path), "the older form, its pid running: kept")
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))
    }
}
