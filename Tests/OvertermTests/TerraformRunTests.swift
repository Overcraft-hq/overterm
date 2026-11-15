import XCTest

@testable import Overterm

/// `TerraformRun.short` against stand-ins behind the recording wrapper:
/// what it passes, what it refuses before starting, its bounds.
final class TerraformRunTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("overterm-tf-run-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func script(_ name: String, _ body: String) throws -> URL {
        let url = folder.appendingPathComponent("bin/\(name)")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/bash -p\n\(body)\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }

    private func root() throws -> URL {
        let root = folder.appendingPathComponent("acme-infra/envs/dev", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// fmt over stdin: the text through, the line and environment recorded —
    /// a hostile shell's names absent (5.13 rule 3).
    func testFormatThroughTheWrapper() async throws {
        let echo = try script("echo-stdin", "/bin/cat")
        let recorder = try TerraformRecorder.make(in: folder.appendingPathComponent("recorder"), target: echo.path)
        let root = try root()
        let scratch = try TerraformGuards.prepareScratch(at: folder.appendingPathComponent("scratch"))
        var base = scratch.environment
        base["TF_CLI_ARGS"] = "-lock=false"
        base["TF_LOG"] = "trace"
        base["AWS_PROFILE"] = "acme-prod-admin"
        base["TF_VAR_db_password"] = "acme-hunter2-SECRET"
        let environment = TerraformEnvironment.build(base: base, purpose: .format, root: root, scratch: scratch)
        let text = "locals {\n  acme = \"é🌍\"\n}\n"
        let result = try await TerraformRun.short(
            recorder.wrapper, TerraformCommands.formatStandardInput, in: root, environment: environment, input: Data(text.utf8))
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(String(decoding: result.stdout, as: UTF8.self), text)
        XCTAssertFalse(result.truncated)
        let call = try XCTUnwrap(recorder.calls().first)
        XCTAssertEqual(call.arguments, TerraformCommands.formatStandardInput)
        XCTAssertEqual(call.cwd, realpath(root.path, nil).map { String(cString: $0) })
        for name in ["TF_CLI_ARGS", "TF_LOG", "AWS_PROFILE", "TF_VAR_db_password"] { XCTAssertFalse(call.names.contains(name), name) }
        XCTAssertEqual(call.values["HOME"], scratch.home.path)
        XCTAssertEqual(call.values["CHECKPOINT_DISABLE"], "1")
        XCTAssertEqual(call.values["TF_DATA_DIR"], root.appendingPathComponent(".terraform").path)
    }

    func testALineNoBuilderMadeNeverStarts() async throws {
        let standIn = folder.appendingPathComponent("stand-in/terraform")
        try TerraformRecorder.writeStandIn(at: standIn)
        let recorder = try TerraformRecorder.make(in: folder.appendingPathComponent("recorder"), target: standIn.path)
        for arguments in [["apply", "-auto-approve"], ["init"], ["validate", "-json", "-no-color", "-lock=false"]] {
            do {
                _ = try await TerraformRun.short(recorder.wrapper, arguments, in: try root(), environment: [:])
                XCTFail("ran \(arguments)")
            } catch let failure as TerraformRun.Failure {
                guard case .refused = failure else { return XCTFail("\(failure)") }
            }
        }
        XCTAssertEqual(recorder.calls(), [], "refused before anything started")
    }

    func testExitCodeAndStderr() async throws {
        let standIn = folder.appendingPathComponent("stand-in/terraform")
        try TerraformRecorder.writeStandIn(
            at: standIn, stdout: TerraformValidationTests.invalid, stderr: "acme warning\n", exitCode: 1)
        let result = try await TerraformRun.short(standIn, TerraformCommands.validate, in: try root(), environment: ["PATH": "/usr/bin:/bin"])
        XCTAssertEqual(result.status, 1)
        XCTAssertEqual(result.stderr, "acme warning\n")
        XCTAssertEqual(try TerraformValidation.decode(result.stdout).errors, 1)
    }

    func testTimeoutEndsTheGroup() async throws {
        let sleeper = try script("sleeper", "/bin/sleep 30 & wait")
        let started = Date()
        let result = try await TerraformRun.short(sleeper, TerraformCommands.validate, in: try root(), environment: ["PATH": "/usr/bin:/bin"], timeout: 0.5)
        XCTAssertTrue(result.timedOut)
        XCTAssertNotEqual(result.status, 0)
        XCTAssertLessThan(Date().timeIntervalSince(started), 6)
    }

    func testOutputIsBounded() async throws {
        let flood = try script("flood", "/usr/bin/head -c 3000000 /dev/zero")
        let result = try await TerraformRun.short(flood, TerraformCommands.validate, in: try root(), environment: ["PATH": "/usr/bin:/bin"])
        XCTAssertTrue(result.truncated)
        XCTAssertLessThan(result.stdout.count, TerraformRun.outputLimit + 300_000)
    }

    /// A child that exits without reading its stdin: no SIGPIPE in the app.
    func testAChildThatReadsNothing() async throws {
        let quitter = try script("quitter", "exit 0")
        let input = Data(repeating: 0x61, count: 4 << 20)
        let result = try await TerraformRun.short(quitter, TerraformCommands.formatStandardInput, in: try root(), environment: [:], input: input)
        XCTAssertEqual(result.status, 0)
    }

    private func eventually(_ seconds: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
        let deadline = Date() + seconds
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }

    private func gone(_ pid: pid_t, group: Bool = false) -> Bool {
        (group ? killpg(pid, 0) : kill(pid, 0)) == -1 && errno == ESRCH
    }

    /// Quitting (`endRun`) stops a run still going: SIGINT to its group, at
    /// once; then its group is swept, the stray child it started too
    /// (analysis 4.7).
    func testStopAllInterruptsARunAndItsGroupIsSwept() async throws {
        let childFile = folder.appendingPathComponent("child.pid")
        let sleeper = try script("sleeper", "/bin/sleep 30 >/dev/null 2>&1 &\necho $! > '\(childFile.path)'\nwait")
        let root = try root()
        let run = Task { try await TerraformRun.short(sleeper, TerraformCommands.validate, in: root, environment: ["PATH": "/usr/bin:/bin"]) }
        let running = await eventually { !TerraformRun.live.all.isEmpty && FileManager.default.fileExists(atPath: childFile.path) }
        XCTAssertTrue(running, "the run is recorded while it goes")
        let group = try XCTUnwrap(TerraformRun.live.all.first)
        try await Task.sleep(nanoseconds: 100_000_000)
        let child = try XCTUnwrap(pid_t(String(contentsOf: childFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        let stopped = Date()
        TerraformRun.stopAll()
        let result = try await run.value
        XCTAssertLessThan(Date().timeIntervalSince(stopped), 5, "stopped by the SIGINT, not the 30 s timeout")
        XCTAssertFalse(result.timedOut)
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(TerraformRun.live.all.isEmpty)
        let swept = await eventually { gone(child) && gone(group, group: true) }
        XCTAssertTrue(swept, "the background sleep (SIGINT ignored there) is swept with its group")
    }

    /// A cancelled task interrupts a read, never a run that writes or takes
    /// a lock (`interruptible` false: New Task's init, the lock probe,
    /// force-unlock): that one ends on its own, never half done.
    func testACancelledTaskLeavesAWriteToEnd() async throws {
        let slow = try script("slow", "/bin/sleep 1\necho acme-done")
        let root = try root()
        let write = Task { try await TerraformRun.short(slow, TerraformCommands.validate, in: root, environment: ["PATH": "/usr/bin:/bin"], interruptible: false) }
        let read = Task { try await TerraformRun.short(slow, TerraformCommands.validate, in: root, environment: ["PATH": "/usr/bin:/bin"]) }
        let both = await eventually { TerraformRun.live.all.count == 2 }
        XCTAssertTrue(both)
        write.cancel()
        read.cancel()
        let interruptedRead = try await read.value
        XCTAssertNotEqual(interruptedRead.status, 0, "the read is interrupted")
        let written = try await write.value
        XCTAssertEqual(written.status, 0, "the write ran to its end")
        XCTAssertEqual(String(decoding: written.stdout, as: UTF8.self), "acme-done\n")
    }

    /// Quitting gives a write its grace before interrupting it; a read is
    /// interrupted at once, and a write past the grace too.
    func testStopAllWaitsBrieflyForAWrite() async throws {
        let quick = try script("quick", "/bin/sleep 0.5\necho acme-done")
        let stuck = try script("stuck", "/bin/sleep 30")
        let root = try root()
        let write = Task { try await TerraformRun.short(quick, TerraformCommands.validate, in: root, environment: ["PATH": "/usr/bin:/bin"], interruptible: false) }
        let going = await eventually { TerraformRun.live.all.count == 1 }
        XCTAssertTrue(going)
        let generation = TerraformRun.live.generation
        TerraformRun.stopAll(grace: 5)
        XCTAssertEqual(TerraformRun.live.generation, generation + 1, "a write that went meanwhile can tell")
        let written = try await write.value
        XCTAssertEqual(written.status, 0, "the write ended on its own within the grace")
        let held = Task { try await TerraformRun.short(stuck, TerraformCommands.validate, in: root, environment: ["PATH": "/usr/bin:/bin"], interruptible: false) }
        let stuckGoing = await eventually { TerraformRun.live.all.count == 1 }
        XCTAssertTrue(stuckGoing)
        let stopped = Date()
        TerraformRun.stopAll(grace: 0.3)
        let interrupted = try await held.value
        XCTAssertLessThan(Date().timeIntervalSince(stopped), 5, "interrupted past the grace, not left to its timeout")
        XCTAssertNotEqual(interrupted.status, 0)
    }

    /// A run that exits leaving a child behind (a provider plugin): swept.
    func testAStrayChildIsSweptWhenTerraformExits() async throws {
        let childFile = folder.appendingPathComponent("stray.pid")
        let leaver = try script("leaver", "/bin/sleep 30 >/dev/null 2>&1 &\necho $! > '\(childFile.path)'\nexit 0")
        let result = try await TerraformRun.short(leaver, TerraformCommands.validate, in: try root(), environment: ["PATH": "/usr/bin:/bin"])
        XCTAssertEqual(result.status, 0)
        let child = try XCTUnwrap(pid_t(String(contentsOf: childFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        let swept = await eventually { gone(child) }
        XCTAssertTrue(swept)
        XCTAssertTrue(TerraformRun.live.all.isEmpty)
    }

    func testAMissingBinary() async throws {
        do {
            _ = try await TerraformRun.short(folder.appendingPathComponent("nope"), TerraformCommands.validate, in: try root(), environment: [:])
            XCTFail("started")
        } catch let failure as TerraformRun.Failure {
            guard case .spawn = failure else { return XCTFail("\(failure)") }
        }
    }
}
