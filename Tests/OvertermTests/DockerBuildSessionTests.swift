import XCTest

@testable import Overterm

/// A build followed while its detail shows, through a stub `docker` that
/// answers as buildx would: no test runs buildx.
@MainActor
final class DockerBuildSessionTests: XCTestCase {
    private static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")

    private var folder: URL!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("ot-build-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let lines = try String(contentsOf: Self.fixtures.appendingPathComponent("buildkit-rawjson-failed.jsonl"), encoding: .utf8)
            .split(separator: "\n").map(String.init)
        try Data((lines.prefix(6).joined(separator: "\n") + "\n").utf8).write(to: folder.appendingPathComponent("part1.jsonl"))
        try Data((lines.dropFirst(6).joined(separator: "\n") + "\n").utf8).write(to: folder.appendingPathComponent("part2.jsonl"))
        try Data(#"{"Context":"/tmp","Dockerfile":"Dockerfile","BuildArgs":[{"Name":"NPM_TOKEN","Value":"npm-secret"}],"Status":"running"}"#.utf8)
            .write(to: folder.appendingPathComponent("inspect.json"))
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    /// `logs`: what `buildx history logs` does; `inspect`, what `history
    /// inspect --format json` does; `plain`, what `history inspect` alone
    /// does. Every loop is bounded.
    private func cli(logs: String, inspect: String = #"cat "$dir/inspect.json""#, plain: String = "exit 1") throws -> DockerCLI {
        let tool = folder.appendingPathComponent("docker")
        let script = """
            #!/bin/sh
            dir="$(dirname "$0")"
            case "$*" in
              "buildx history inspect run789 --format json") \(inspect) ;;
              "buildx history inspect run789") \(plain) ;;
              "buildx history logs --progress rawjson run789") \(logs) ;;
              *) echo "unexpected: $*" >&2; exit 1 ;;
            esac
            """
        try Data(script.utf8).write(to: tool)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        return DockerCLI(executable: tool, endpoint: nil)
    }

    private func until(_ timeout: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return false }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return true
    }

    private func pid() -> Int32? {
        (try? String(contentsOf: folder.appendingPathComponent("pid"), encoding: .utf8)).flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    func testItFollowsWhileShownAndLetsGoWhenHidden() async throws {
        let cli = try cli(
            logs: #"echo $$ > "$dir/pid"; cat "$dir/part1.jsonl" >&2; n=0; while [ ! -f "$dir/finish" ] && [ $n -lt 200 ]; do sleep 0.05; n=$((n+1)); done; cat "$dir/part2.jsonl" >&2"#
        )
        let session = DockerBuildSession(ref: "run789", cli: cli)
        var ends = 0
        session.onEnd = { ends += 1 }
        session.follow(shown: true)
        let read = await until { session.progress.steps.count == 7 }
        XCTAssertTrue(read, "\(session.progress.steps.count) steps, \(session.state)")
        XCTAssertEqual(session.state, .reading)
        XCTAssertEqual(session.shownStep?.number, 7, "the running step that wrote last")
        let detailed = await until { session.detail != nil }
        XCTAssertTrue(detailed)
        XCTAssertTrue(session.isRunning, "the inspect says so")
        let name = try XCTUnwrap(session.progress.steps.last?.name)
        XCTAssertTrue(session.shown(name).contains("••••••") && !session.shown(name).contains("npm-secret"), session.shown(name))
        XCTAssertTrue(session.summaryLine(now: Date()).hasPrefix("Running · "), session.summaryLine(now: Date()))

        let first = try XCTUnwrap(pid())
        session.follow(shown: false)
        XCTAssertEqual(session.state, .stopped)
        let gone = await until { kill(first, 0) == -1 && errno == ESRCH }
        XCTAssertTrue(gone, "hidden, its process is terminated")

        session.follow(shown: true)
        let again = await until { self.pid() != nil && self.pid() != first && session.progress.steps.count == 7 }
        XCTAssertTrue(again, "read from the start")
        XCTAssertEqual(session.progress.steps.count, 7, "nothing twice")
        // Steps are keyed by digest, so only the output would show a fold
        // that wasn't begun again.
        let replayed = await until { session.progress.steps.first { $0.number == 7 }?.log.isEmpty == false }
        XCTAssertTrue(replayed)
        XCTAssertEqual(session.progress.steps.first { $0.number == 7 }?.log.map(\.text), ["cc -o worker main.c"], "its output once")
        XCTAssertEqual(session.generation, 2)

        FileManager.default.createFile(atPath: folder.appendingPathComponent("finish").path, contents: Data())
        let ended = await until { session.state == .ended }
        XCTAssertTrue(ended, "\(session.state)")
        let failed = try XCTUnwrap(session.progress.steps.first { $0.number == 7 })
        XCTAssertEqual(session.progress.state(of: failed), .failed)
        XCTAssertEqual(ends, 1)
        XCTAssertTrue(session.plainText?.contains("#7 ERROR:") == true, session.plainText ?? "nothing")
        XCTAssertFalse(session.plainText?.contains("npm-secret") ?? true)
        session.close()
    }

    /// buildx stops mid-build — an ssh engine gone with the Mac's sleep,
    /// the builder restarted: the steps read stay, none of them spins on,
    /// and the detail says it stopped following rather than "Built".
    func testAFollowLostMidBuild() async throws {
        let session = DockerBuildSession(
            ref: "run789", cli: try cli(logs: #"cat "$dir/part1.jsonl" >&2; echo 'ERROR: rpc error: code = Unavailable desc = error reading from server: EOF' >&2; exit 1"#),
            running: true)
        session.follow(shown: true)
        let failed = await until { if case .failed = session.state { session.secretsKnown } else { false } }
        XCTAssertTrue(failed, "\(session.state)")
        XCTAssertEqual(session.state, .failed("ERROR: rpc error: code = Unavailable desc = error reading from server: EOF"))
        XCTAssertEqual(session.progress.steps.count, 7, "the steps read so far kept")
        let open = try XCTUnwrap(session.progress.steps.first { $0.number == 7 })
        XCTAssertEqual(session.progress.state(of: open), .unknown, "not running on: nothing would say when it stops")
        XCTAssertEqual(session.progress.summary.running, 0)
        XCTAssertFalse(session.isRunning)
        let line = session.summaryLine(now: Date().addingTimeInterval(3600))
        XCTAssertTrue(line.hasPrefix("Couldn't follow it · "), line)
        XCTAssertEqual(session.summaryLine(now: Date().addingTimeInterval(7200)), line, "its time stopped too")
        let text = try XCTUnwrap(session.plainText)
        XCTAssertTrue(text.contains("#7 0.340 cc -o worker main.c"), text)
        XCTAssertFalse(text.contains("#7 DONE") || text.contains("#7 CANCELED"), "no end made up for a step whose end isn't known")
    }

    /// BuildKit ends the stream, then writes the record's end: an inspect
    /// asked at once says "running", with no error. It is asked again
    /// until it says how the build ended.
    func testTheEndIsReadOnceBuildKitHasWrittenIt() async throws {
        try Data(
            #"{"Context":"/tmp","BuildArgs":[{"Name":"NPM_TOKEN","Value":"npm-secret"}],"Status":"failed","Error":{"Message":"exit code: 2","Name":"[worker 2/3] RUN echo npm-secret"}}"#
                .utf8
        ).write(to: folder.appendingPathComponent("failed.json"))
        // Running for the first three asks: the one at the start, two after the end.
        let inspect = #"echo >> "$dir/asked"; if [ "$(wc -l < "$dir/asked")" -gt 3 ]; then cat "$dir/failed.json"; else cat "$dir/inspect.json"; fi"#
        let session = DockerBuildSession(ref: "run789", cli: try cli(logs: #"cat "$dir/part1.jsonl" "$dir/part2.jsonl" >&2"#, inspect: inspect))
        session.follow(shown: true)
        let ended = await until { session.state == .ended }
        XCTAssertTrue(ended, "\(session.state)")
        let settled = await until { session.detail?.status == "failed" }
        XCTAssertTrue(settled, "\(String(describing: session.detail?.status))")
        XCTAssertEqual(session.detail?.error, "exit code: 2")
        XCTAssertEqual(session.detail?.errorStep, "[worker 2/3] RUN echo ••••••")
    }

    /// The list says the record is over after the inspect's asks gave up:
    /// it is asked once more.
    func testTheRecordsEndAsksTheInspectAgain() async throws {
        let inspect = #"echo >> "$dir/asked"; if [ -f "$dir/over" ]; then echo '{"Status":"completed"}'; else cat "$dir/inspect.json"; fi"#
        // The stream ends once the first ask is in: every ask counted.
        let logs = #"n=0; while [ ! -f "$dir/asked" ] && [ $n -lt 100 ]; do sleep 0.05; n=$((n+1)); done; cat "$dir/part1.jsonl" >&2"#
        let session = DockerBuildSession(ref: "run789", cli: try cli(logs: logs, inspect: inspect), running: true)
        session.follow(shown: true)
        func asks() -> Int { ((try? String(contentsOf: folder.appendingPathComponent("asked"), encoding: .utf8)) ?? "").filter { $0 == "\n" }.count }
        let gaveUp = await until(8) { session.state == .ended && asks() == 6 }
        XCTAssertTrue(gaveUp, "\(session.state), asked \(asks())")
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertEqual(asks(), 6, "bounded: once, then five after the end")
        XCTAssertEqual(session.detail?.status, "running")
        FileManager.default.createFile(atPath: folder.appendingPathComponent("over").path, contents: Data())
        session.record(running: false)
        let read = await until { session.detail?.status == "completed" }
        XCTAssertTrue(read, "\(String(describing: session.detail?.status))")
        session.record(running: false)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(asks(), 7, "once")
    }

    /// buildx 0.20 has no `inspect --format`: its plain table gives the
    /// build args, and so the secret to take out of the steps.
    func testBuildx020sPlainInspect() async throws {
        try Data(
            "Context:\t\t/tmp/shop\nDockerfile:\tDockerfile\n\nStarted:\t2026-10-28 10:00:00\nDuration:\t4.5s (running)\nBuild Steps:\t2/4 (25% cached)\n\nBUILD ARG\tVALUE\nGOPROXY\t\thttp://proxy\nNPM_TOKEN\tnpm-secret\n\n"
                .utf8
        ).write(to: folder.appendingPathComponent("plain.txt"))
        let session = DockerBuildSession(
            ref: "run789",
            cli: try cli(
                logs: #"cat "$dir/part1.jsonl" >&2"#, inspect: #"echo 'unknown flag: --format' >&2; echo "See 'docker buildx history inspect --help'." >&2; exit 1"#,
                plain: #"cat "$dir/plain.txt""#))
        session.follow(shown: true)
        let known = await until { session.secretsKnown && session.state == .ended }
        XCTAssertTrue(known, "\(session.state) \(session.detailFailed)")
        XCTAssertEqual(session.detail?.buildArgs.map { "\($0.key)=\($0.value)" }, ["GOPROXY=http://proxy", "NPM_TOKEN=••••••"])
        XCTAssertEqual(session.detail?.context, "/tmp/shop")
        let name = try XCTUnwrap(session.progress.steps.last?.name)
        XCTAssertEqual(session.shown(name), "[worker 2/3] RUN echo •••••• > .npmrc && make")
        XCTAssertFalse(session.plainText?.contains("npm-secret") ?? true)
    }

    /// An inspect that never answers: the steps are read, but nothing of
    /// them is given out — no step names, no Copy Log — and a replay is not
    /// taken for a build running.
    func testNoInspectNoSteps() async throws {
        let session = DockerBuildSession(ref: "run789", cli: try cli(logs: #"cat "$dir/part1.jsonl" "$dir/part2.jsonl" >&2"#, inspect: "exit 1"))
        session.follow(shown: true)
        let gaveUp = await until(8) { session.detailFailed && session.state == .ended }
        XCTAssertTrue(gaveUp, "\(session.state) \(session.detailFailed)")
        XCTAssertEqual(session.progress.steps.count, 7, "read, but not given out")
        XCTAssertFalse(session.secretsKnown)
        XCTAssertNil(session.plainText)
        XCTAssertFalse(session.isRunning)
    }

    /// Before the inspect has answered, a record the list says is over is
    /// no build running, whatever the replay is at.
    func testAReplayIsNoBuildRunning() async throws {
        let session = DockerBuildSession(
            ref: "run789", cli: try cli(logs: #"cat "$dir/part1.jsonl" >&2; n=0; while [ $n -lt 40 ]; do sleep 0.05; n=$((n+1)); done"#, inspect: "sleep 1; exit 1"))
        session.follow(shown: true)
        let read = await until { session.progress.steps.count == 7 }
        XCTAssertTrue(read)
        XCTAssertEqual(session.state, .reading)
        XCTAssertNil(session.detail)
        XCTAssertFalse(session.isRunning, "the record says it is over")
        XCTAssertFalse(session.summaryLine(now: Date()).hasPrefix("Running"), session.summaryLine(now: Date()))
        session.close()
    }

    func testARecordWithNoLog() async throws {
        let session = DockerBuildSession(ref: "run789", cli: try cli(logs: "exit 0"))
        session.follow(shown: true)
        let ended = await until { session.state == .ended }
        XCTAssertTrue(ended, "\(session.state)")
        XCTAssertTrue(session.progress.steps.isEmpty)
        XCTAssertEqual(session.summaryLine(now: Date()), "No steps recorded.")
    }

    func testAFailedFollow() async throws {
        let session = DockerBuildSession(ref: "run789", cli: try cli(logs: #"echo 'ERROR: no record found for ref "run789"' >&2; exit 1"#))
        session.follow(shown: true)
        let failed = await until { if case .failed = session.state { true } else { false } }
        XCTAssertTrue(failed, "\(session.state)")
        XCTAssertEqual(session.state, .failed(#"ERROR: no record found for ref "run789""#))
    }

    func testWithoutDocker() {
        let session = DockerBuildSession(ref: "run789", cli: nil)
        session.follow(shown: true)
        XCTAssertEqual(session.state, .failed("docker isn't on this Mac: builds are read with docker buildx."))
    }
}
