import XCTest

@testable import Overterm

/// The real terraform against `FakeTerraformBackend`, through the recording
/// wrapper, in a sandbox of its own: that the fake answers as Terraform's
/// http backend client needs — a plan and apply that lock and write, a held
/// lock named in Terraform's own words, force-unlock's empty UNLOCK, the
/// lock probe of analysis 4.10, refused credentials.
///
/// Opt-in (`OVERTERM_TF_TESTS=1`), like the Docker and Kubernetes suites:
///
///     OVERTERM_TF_TESTS=1 swift test --filter TerraformRealBackendTests
///
/// The terraform is `OVERTERM_TF_TEST_TERRAFORM`, else Homebrew's. It runs
/// only in a temporary folder made here, with the guarded environment —
/// nothing of the shell's, a HOME and a CLI config of the sandbox (no
/// provider fetched), proxies at a dead port — and only `terraform_data`,
/// which is built in. The suite refuses to start when its own environment
/// carries any credential variable, rather than unsetting it.
final class TerraformRealBackendTests: XCTestCase {
    private var sandbox: URL!
    private var backend: FakeTerraformBackend!
    private var recorder: TerraformRecorder!
    private var environment: [String: String] = [:]

    override func setUpWithError() throws {
        let process = ProcessInfo.processInfo.environment
        try XCTSkipUnless(process["OVERTERM_TF_TESTS"] == "1", "OVERTERM_TF_TESTS=1 runs it")
        let credentials = TerraformGuards.credentials(in: process)
        guard credentials.isEmpty else {
            XCTFail("Refusing to run terraform: this environment sets \(credentials.joined(separator: ", ")).")
            throw XCTSkip("credential variables set")
        }
        let candidates = [process["OVERTERM_TF_TEST_TERRAFORM"], "/opt/homebrew/bin/terraform", "/usr/local/bin/terraform"].compactMap { $0 }
        guard let terraform = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw XCTSkip("no terraform installed")
        }
        sandbox = FileManager.default.temporaryDirectory.appendingPathComponent("overterm-tf-real-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let scratch = try TerraformGuards.prepareScratch(at: sandbox.appendingPathComponent("scratch"))
        environment = scratch.environment
        recorder = try TerraformRecorder.make(in: sandbox.appendingPathComponent("recorder"), target: terraform)
        backend = FakeTerraformBackend()
        try backend.start()
    }

    override func tearDownWithError() throws {
        backend?.stop()
        if let sandbox { try? FileManager.default.removeItem(at: sandbox) }
    }

    /// A root on state `name`, with one `terraform_data`.
    private func root(_ folder: String, state name: String) throws -> URL {
        let root = sandbox.appendingPathComponent(folder, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let main =
            backend.backendBlock(name) + """
                resource "terraform_data" "acme" {
                  input = "acme-net"
                }

                """
        try Data(main.utf8).write(to: root.appendingPathComponent("main.tf"))
        return root
    }

    private func terraform(_ arguments: [String], in root: URL) throws -> (status: Int32, out: String, err: String) {
        let process = Process()
        process.executableURL = recorder.wrapper
        process.arguments = arguments
        process.currentDirectoryURL = root
        process.environment = environment
        let out = sandbox.appendingPathComponent("out-\(UUID().uuidString)")
        let err = sandbox.appendingPathComponent("err-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: out.path, contents: nil)
        FileManager.default.createFile(atPath: err.path, contents: nil)
        process.standardOutput = try FileHandle(forWritingTo: out)
        process.standardError = try FileHandle(forWritingTo: err)
        process.standardInput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return (process.terminationStatus, try String(contentsOf: out, encoding: .utf8), try String(contentsOf: err, encoding: .utf8))
    }

    func testAPlanAndItsApplyLockAndWriteTheFakesState() throws {
        let root = try root("envs/dev", state: "acme-dev")
        XCTAssertEqual(try terraform(["init", "-input=false", "-no-color"], in: root).status, 0)
        let plan = try terraform(["plan", "-input=false", "-no-color", "-detailed-exitcode", "-lock=true", "-lock-timeout=0s", "-out=plan"], in: root)
        XCTAssertEqual(plan.status, 2, plan.err)
        XCTAssertNil(backend.heldLock("acme-dev"), "the plan's lock released")
        XCTAssertFalse(backend.writes.contains { $0.method == "POST" }, "a plan writes no state")
        backend.forgetRequests()

        let apply = try terraform(["apply", "-input=false", "-no-color", "-lock=true", "-lock-timeout=0s", "plan"], in: root)
        XCTAssertEqual(apply.status, 0, apply.err)
        let state = try XCTUnwrap(backend.state("acme-dev"))
        let decoded = try XCTUnwrap(try JSONSerialization.jsonObject(with: state) as? [String: Any])
        XCTAssertEqual((decoded["resources"] as? [Any])?.count, 1)
        let methods = backend.requests.map(\.method)
        XCTAssertEqual(methods.first { $0 != "GET" }, "LOCK")
        XCTAssertEqual(methods.last, "UNLOCK")
        let lockID = try XCTUnwrap(backend.requests.first { $0.method == "LOCK" }?.lock?.id)
        // The real lock's Created has the shape the fake's holdLock writes (FakeTerraformBackend.goTime).
        let created = try XCTUnwrap(backend.requests.first { $0.method == "LOCK" }?.lock?.created)
        XCTAssertNotNil(created.range(of: #"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(\.\d{1,9})?Z$"#, options: .regularExpression), created)
        XCTAssertTrue(backend.requests.filter { $0.method == "POST" }.allSatisfy { $0.query["ID"] == lockID })
        XCTAssertNil(backend.heldLock("acme-dev"))

        // Every call through the wrapper, in the sandbox's environment only.
        let calls = recorder.calls()
        XCTAssertEqual(calls.map(\.subcommand), ["init", "plan", "apply"])
        for call in calls {
            XCTAssertEqual(TerraformGuards.credentials(in: Dictionary(uniqueKeysWithValues: call.names.map { ($0, "") })), [])
            XCTAssertEqual(call.values["CHECKPOINT_DISABLE"], "1")
            XCTAssertEqual(call.values["HOME"], environment["HOME"])
        }
    }

    /// A lock held elsewhere is said in Terraform's words, with who holds
    /// it; the probe (`state rm -dry-run`) fails on it and changes nothing;
    /// force-unlock's UNLOCK is empty and takes it away.
    func testAHeldLockIsNamedProbedAndForced() throws {
        let root = try root("envs/prod", state: "acme-prod")
        XCTAssertEqual(try terraform(["init", "-input=false", "-no-color"], in: root).status, 0)
        // Another machine's apply left a state: the probe needs one to lock.
        let state = #"{"version":4,"terraform_version":"1.17.1","serial":3,"lineage":"acme-prod-lineage","outputs":{},"resources":[]}"#
        backend.setState("acme-prod", Data(state.utf8))
        let held = backend.holdLock("acme-prod", who: "ci@globex-runner-7")

        let plan = try terraform(["plan", "-input=false", "-no-color", "-lock=true", "-lock-timeout=0s"], in: root)
        XCTAssertEqual(plan.status, 1)
        XCTAssertTrue(plan.err.contains("Error acquiring the state lock"), plan.err)
        XCTAssertTrue(plan.err.contains("HTTP remote state already locked"), plan.err)
        XCTAssertTrue(plan.err.contains("ci@globex-runner-7"), plan.err)
        XCTAssertTrue(plan.err.contains(held.id), plan.err)

        backend.forgetRequests()
        let probe = try terraform(["state", "rm", "-dry-run", "-lock-timeout=0s", "-no-color", "terraform_data.overterm_lock_probe"], in: root)
        XCTAssertNotEqual(probe.status, 0)
        XCTAssertTrue(probe.err.contains(held.id), probe.err)
        XCTAssertFalse(backend.requests.contains { $0.method == "POST" || $0.method == "DELETE" })
        XCTAssertEqual(backend.heldLock("acme-prod"), held)

        let forced = try terraform(["force-unlock", "-force", held.id], in: root)
        XCTAssertEqual(forced.status, 0, forced.err)
        let unlock = try XCTUnwrap(backend.requests.last { $0.method == "UNLOCK" })
        XCTAssertEqual(unlock.body, Data(), "force-unlock sends no lock info")
        XCTAssertNil(backend.heldLock("acme-prod"))

        backend.forgetRequests()
        let free = try terraform(["state", "rm", "-dry-run", "-lock-timeout=0s", "-no-color", "terraform_data.overterm_lock_probe"], in: root)
        XCTAssertEqual(free.status, 0, free.err)
        XCTAssertTrue(free.out.contains("Would have removed nothing"), free.out)
        XCTAssertEqual(backend.state("acme-prod"), Data(state.utf8), "the probe changed nothing")
        XCTAssertEqual(backend.requests.filter { $0.method != "GET" }.map(\.method), ["LOCK", "UNLOCK"])
    }

    /// Two "worktrees" on one state: the second sees the first's apply.
    func testTwoRootsShareOneState() throws {
        let first = try root("acme-a/envs/dev", state: "acme-shared")
        let second = try root("acme-b/envs/dev", state: "acme-shared")
        for root in [first, second] { XCTAssertEqual(try terraform(["init", "-input=false", "-no-color"], in: root).status, 0) }
        XCTAssertEqual(try terraform(["plan", "-input=false", "-no-color", "-detailed-exitcode", "-lock-timeout=0s"], in: second).status, 2)
        XCTAssertEqual(try terraform(["plan", "-input=false", "-no-color", "-out=plan", "-lock-timeout=0s"], in: first).status, 0)
        XCTAssertEqual(try terraform(["apply", "-input=false", "-no-color", "-lock-timeout=0s", "plan"], in: first).status, 0)
        XCTAssertEqual(try terraform(["plan", "-input=false", "-no-color", "-detailed-exitcode", "-lock-timeout=0s"], in: second).status, 0)
    }

    func testRefusedCredentialsFailTheRun() throws {
        let root = try root("envs/stage", state: "acme-stage")
        XCTAssertEqual(try terraform(["init", "-input=false", "-no-color"], in: root).status, 0)
        backend.failCredentials = 401
        let plan = try terraform(["plan", "-input=false", "-no-color", "-lock-timeout=0s"], in: root)
        XCTAssertEqual(plan.status, 1)
        XCTAssertTrue(plan.err.contains("requires auth"), plan.err)
    }
}
