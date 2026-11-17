import Darwin
import XCTest

@testable import Overterm

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
