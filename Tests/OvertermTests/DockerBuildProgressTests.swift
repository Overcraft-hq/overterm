import XCTest

@testable import Overterm

/// BuildKit's `--progress rawjson`, folded as its plain printer folds it.
/// The fixtures are recorded shapes — SolveStatus as client/graph.go's
/// json tags and Go's encoder write them — and the expected values are a
/// reference fold of progressui's printer over them.
final class DockerBuildProgressTests: XCTestCase {
    private static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")

    private func lines(_ name: String) throws -> [String] {
        let text = try String(contentsOf: Self.fixtures.appendingPathComponent(name), encoding: .utf8)
        return text.split(separator: "\n").map(String.init)
    }

    private func fold(_ lines: [String], ended: Bool = true) -> DockerBuildProgress {
        var progress = DockerBuildProgress()
        for line in lines { progress.add(line) }
        if ended { progress.end() }
        return progress
    }

    private func step(_ progress: DockerBuildProgress, _ number: Int, file: StaticString = #filePath, line: UInt = #line) throws -> DockerBuildProgress.Step {
        try XCTUnwrap(progress.steps.first { $0.number == number }, "#\(number)", file: file, line: line)
    }

    func testABuildReadsAsPlainProgressReadsIt() throws {
        let progress = fold(try lines("buildkit-rawjson-built.jsonl"))
        XCTAssertEqual(progress.steps.map(\.number), Array(1...11))
        XCTAssertEqual(
            progress.steps.map(\.name),
            [
                "[internal] load build definition from Dockerfile", "[internal] load metadata for docker.io/library/node:20-alpine",
                "[internal] load .dockerignore",
                // FROM was seen before it started: it takes the number it starts with.
                "[internal] load build context",
                "[web 1/6] FROM docker.io/library/node:20-alpine@sha256:4f8a4f8a4f8a4f8a4f8a4f8a4f8a4f8a4f8a4f8a4f8a4f8a4f8a4f8a4f8a4f8a",
                "[web 2/6] WORKDIR /app", "[web 3/6] COPY package.json .", "[web 4/6] RUN npm ci", "[web 5/6] COPY . .", "[web 6/6] RUN npm run build",
                "exporting to image",
            ])
        XCTAssertEqual(progress.steps.map { progress.state(of: $0) }, [.done, .done, .done, .done, .done, .cached, .cached, .done, .done, .done, .done])
        XCTAssertTrue(try step(progress, 1).isInternal)
        XCTAssertFalse(try step(progress, 8).isInternal)
        // The repeated copy of #5 without `started` didn't reset it; its
        // two overlapping intervals merge.
        let end = Date()
        for (number, seconds) in [(2, 1.20), (5, 0.60), (8, 3.40), (10, 1.90), (11, 0.30)] {
            XCTAssertEqual(try step(progress, number).duration(until: end), seconds, accuracy: 0.005, "#\(number)")
        }

        let from = try step(progress, 5)
        XCTAssertEqual(
            from.statuses.map(\.id),
            [
                "resolve docker.io/library/node:20-alpine@sha256:4f8a4f8a4f8a4f8a4f8a4f8a4f8a4f8a4f8a4f8a4f8a4f8a4f8a4f8a4f8a4f8a",
                "sha256:aa11aa11aa11aa11aa11aa11aa11aa11aa11aa11aa11aa11aa11aa11aa11aa11",
                "extracting sha256:aa11aa11aa11aa11aa11aa11aa11aa11aa11aa11aa11aa11aa11aa11aa11aa11",
            ])
        let layer = from.statuses[1]
        XCTAssertEqual(layer.current, 3_640_000)
        XCTAssertEqual(layer.total, 3_640_000)
        XCTAssertNotNil(layer.completed)
        XCTAssertTrue(layer.plain.hasSuffix(" 3.64MB / 3.64MB 0.4s done"), layer.plain)

        let npm = try step(progress, 8)
        XCTAssertEqual(npm.log.map(\.offsetText), ["0.230", "2.930", "2.930", "2.930", "2.950"])
        XCTAssertEqual(
            npm.log.map(\.text),
            [
                "npm warn deprecated inflight@1.0.6: This module is not supported", "progress 100%", "",
                // A half line continued by the next message.
                "added 120 packages, and audited 121 packages in 3s",
                // Colour codes and the carriage return gone.
                "found 0 vulnerabilities",
            ])
        XCTAssertEqual(npm.log.map(\.stderr), [true, false, false, false, false])
        // A three-byte character split across two messages, whole.
        XCTAssertEqual(try step(progress, 10).log.last?.text, "✓ built in 812ms")

        XCTAssertEqual(progress.warnings.count, 1, "said twice, one warning")
        let warning = try XCTUnwrap(progress.warnings.first)
        XCTAssertTrue(warning.short.hasPrefix("SecretsUsedInArgOrEnv"))
        XCTAssertEqual(warning.detail, ["Sensitive data should not be used in the ARG or ENV commands"])
        XCTAssertEqual(warning.line, 2)
        XCTAssertEqual(warning.file, "Dockerfile")
        XCTAssertEqual(warning.source, "ARG NPM_TOKEN")
        XCTAssertTrue(warning.url?.hasSuffix("secrets-used-in-arg-or-env/") == true)
        XCTAssertEqual(try step(progress, 1).warnings.count, 1, "its step carries it")

        let summary = progress.summary
        XCTAssertEqual(summary.steps, 11)
        XCTAssertEqual(summary.cached, 2)
        XCTAssertEqual(summary.failed, 0)
        XCTAssertEqual(summary.running, 0)
        XCTAssertEqual(try XCTUnwrap(progress.elapsed(now: Date())), 7.60, accuracy: 0.005)
        XCTAssertEqual(progress.automaticStep?.number, 10, "the last step that wrote anything")
        XCTAssertNil(progress.failedStep)

        let plain = progress.plainText()
        XCTAssertTrue(plain.hasPrefix("#1 [internal] load build definition from Dockerfile\n"), plain)
        for expected in ["#1 WARN: SecretsUsedInArgOrEnv", "#5 DONE 0.6s", "#6 CACHED", "#8 0.230 npm warn deprecated", "#1 transferring dockerfile: 214B"] {
            XCTAssertTrue(plain.contains(expected), expected)
        }
    }

    func testAFailedBuild() throws {
        let progress = fold(try lines("buildkit-rawjson-failed.jsonl"))
        let make = try step(progress, 7)
        XCTAssertEqual(progress.state(of: make), .failed)
        XCTAssertTrue(make.error?.contains("exit code: 2") == true)
        XCTAssertEqual(progress.state(of: try step(progress, 6)), .canceled)
        XCTAssertEqual(progress.failedStep?.number, 7)
        XCTAssertEqual(progress.automaticStep?.number, 7)
        XCTAssertEqual(
            make.log.map(\.text), ["cc -o worker main.c", "main.c:3:10: fatal error: 'missing.h' file not found", "make: *** [Makefile:2: worker] Error 1"])
        XCTAssertEqual(progress.summary.failed, 1)
        XCTAssertEqual(progress.summary.canceled, 1)

        let plain = progress.plainText()
        XCTAssertTrue(plain.contains(#"#7 ERROR: process "/bin/sh -c echo $NPM_TOKEN > .npmrc && make""#), plain)
        XCTAssertTrue(plain.contains("#6 CANCELED"), plain)
        // BuildKit expands an ARG into a RUN step's name.
        let redacted = progress.plainText(redacting: ["npm-secret"])
        XCTAssertFalse(redacted.contains("npm-secret"))
        XCTAssertTrue(redacted.contains("RUN echo •••••• > .npmrc && make"), redacted)
    }

    func testWhileItRuns() throws {
        let progress = fold(Array(try lines("buildkit-rawjson-failed.jsonl").prefix(6)), ended: false)
        XCTAssertEqual(progress.state(of: try step(progress, 6)), .running)
        XCTAssertEqual(progress.state(of: try step(progress, 7)), .running)
        XCTAssertEqual(progress.summary.running, 2)
        XCTAssertEqual(progress.automaticStep?.number, 7, "the running step that wrote last")
        let make = try step(progress, 7)
        let started = try XCTUnwrap(make.startedAt)
        XCTAssertEqual(make.duration(until: started.addingTimeInterval(5)), 5.0, accuracy: 0.001)
        XCTAssertFalse(progress.plainText().contains("#7 DONE"), "a running step has no end yet")

        var ended = progress
        ended.end()
        XCTAssertEqual(ended.state(of: try step(ended, 6)), .canceled, "stopped with the build")
        XCTAssertEqual(ended.state(of: try step(ended, 7)), .canceled)
    }

    func testItTakesLinesInAnyPieces() throws {
        let data = try Data(contentsOf: Self.fixtures.appendingPathComponent("buildkit-rawjson-built.jsonl"))
        var splitter = DockerLineSplitter()
        var pieces = DockerBuildProgress()
        var offset = 0
        while offset < data.count {
            let chunk = data[offset..<min(offset + 7, data.count)]
            for line in splitter.feed(Data(chunk)) { pieces.add(String(decoding: line, as: UTF8.self)) }
            offset += 7
        }
        if let rest = splitter.finish() { pieces.add(String(decoding: rest, as: UTF8.self)) }
        pieces.end()
        let whole = fold(try lines("buildkit-rawjson-built.jsonl"))
        XCTAssertEqual(pieces.steps.map(\.number), whole.steps.map(\.number))
        XCTAssertEqual(pieces.steps.map(\.name), whole.steps.map(\.name))
        XCTAssertEqual(pieces.steps.map { pieces.state(of: $0) }, whole.steps.map { whole.state(of: $0) })
        XCTAssertEqual(pieces.steps.map(\.log), whole.steps.map(\.log))
    }

    func testWhatIsNotASolveStatus() {
        var progress = DockerBuildProgress()
        progress.add(#"ERROR: no record found for ref "zzz""#)
        progress.add("")
        progress.add("   ")
        XCTAssertEqual(progress.said, [#"ERROR: no record found for ref "zzz""#])
        XCTAssertTrue(progress.steps.isEmpty)
        XCTAssertEqual(progress.plainText(), "")
    }

    func testALogPastItsLimitIsClipped() throws {
        var progress = DockerBuildProgress(logLimit: 1024)
        progress.add(#"{"vertexes":[{"digest":"sha256:a","name":"RUN noisy","started":"2026-10-28T10:00:00Z"}]}"#)
        let chunk = Data((String(repeating: "x", count: 63) + "\n").utf8)
        let message = Array(repeating: chunk, count: 8).reduce(Data(), +)
        for second in 0..<8 {
            progress.add(
                #"{"logs":[{"vertex":"sha256:a","stream":1,"data":"\#(message.base64EncodedString())","timestamp":"2026-10-28T10:00:0\#(second).5Z"}]}"#)
        }
        let step = try XCTUnwrap(progress.step("sha256:a"))
        XCTAssertTrue(step.clipped)
        XCTAssertLessThanOrEqual(step.logBytes, 1024)
        XCTAssertEqual(step.log.count, 16, "1024 bytes of 64-byte lines")
    }

    func testEndKeepsAHalfLine() throws {
        var progress = DockerBuildProgress()
        progress.add(#"{"vertexes":[{"digest":"sha256:a","name":"RUN printf","started":"2026-10-28T10:00:00Z"}]}"#)
        progress.add(#"{"logs":[{"vertex":"sha256:a","stream":1,"data":"\#(Data("no newline".utf8).base64EncodedString())","timestamp":"2026-10-28T10:00:01Z"}]}"#)
        XCTAssertEqual(progress.step("sha256:a")?.log.count, 0, "a half line waits for the rest")
        progress.end()
        XCTAssertEqual(progress.step("sha256:a")?.log.map(\.text), ["no newline"])
        XCTAssertEqual(progress.step("sha256:a")?.log.first?.offsetText, "1.000")
    }

    func testTimesAsGoWritesThem() throws {
        let base = try XCTUnwrap(DockerSolveStatus.date("2026-10-28T10:00:00Z"))
        XCTAssertEqual(try XCTUnwrap(DockerSolveStatus.date("2026-10-28T10:00:00.01Z")).timeIntervalSince(base), 0.01, accuracy: 1e-6)
        XCTAssertEqual(try XCTUnwrap(DockerSolveStatus.date("2026-10-28T10:00:00.123456789Z")).timeIntervalSince(base), 0.123456789, accuracy: 1e-6)
        XCTAssertEqual(try XCTUnwrap(DockerSolveStatus.date("2026-10-28T12:00:00.5+02:00")).timeIntervalSince(base), 0.5, accuracy: 1e-6)
        XCTAssertEqual(DockerSolveStatus.date("0001-01-01T00:00:00Z"), .distantPast)
        guard
            case .status(let status)? = DockerBuildProgress.decode(
                #"{"statuses":[{"id":"x","vertex":"sha256:a","current":0,"timestamp":"0001-01-01T00:00:00Z","started":"2026-10-28T10:00:00.123456789Z"}]}"#)
        else { return XCTFail("a SolveStatus") }
        XCTAssertEqual(status.statuses?.first?.timestamp, .distantPast)
        // Go's zero time is no time to the fold.
        var progress = DockerBuildProgress()
        progress.add(#"{"vertexes":[{"digest":"sha256:a","name":"RUN x","started":"2026-10-28T10:00:00Z"}]}"#)
        progress.add(#"{"statuses":[{"id":"x","vertex":"sha256:a","current":0,"timestamp":"0001-01-01T00:00:00Z"}]}"#)
        XCTAssertNil(progress.step("sha256:a")?.statuses.first?.timestamp)
        XCTAssertEqual(progress.lastSeen, base)
    }

    func testBytesAsPlainProgressSaysThem() {
        XCTAssertEqual(DockerBuildProgress.bytes(214), "214B")
        XCTAssertEqual(DockerBuildProgress.bytes(1203), "1.20kB")
        XCTAssertEqual(DockerBuildProgress.bytes(3_640_000), "3.64MB")
    }
}
