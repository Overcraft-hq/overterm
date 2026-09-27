import XCTest

@testable import Terminus

/// The process runner itself: a hung tool, a chatty one, a burst, and a
/// child left holding the pipes.
final class GitRunTests: XCTestCase {
    private let sh = URL(fileURLWithPath: "/bin/sh")
    private let tmp = FileManager.default.temporaryDirectory

    func testAHungToolIsKilledAtItsTimeout() async throws {
        let start = Date()
        do {
            _ = try await Git.run(sh, ["-c", "sleep 30"], in: tmp, timeout: 0.5)
            XCTFail("a 30 s sleep returned inside a 0.5 s timeout")
        } catch let error as GitError {
            XCTAssertTrue(error.stderr.contains("timed out"), error.stderr)
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }

    func testMuchStderrDoesNotBlockTheTool() async throws {
        // 1 MB on stderr, far past a pipe's 64 KB buffer, then stdout.
        let output = try await Git.run(sh, ["-c", "head -c 1048576 /dev/zero | tr '\\0' x >&2; echo done"], in: tmp, timeout: 20)
        XCTAssertEqual(output, "done\n")
    }

    func testFailureCarriesStderr() async throws {
        do {
            _ = try await Git.run(sh, ["-c", "echo nope >&2; exit 3"], in: tmp)
            XCTFail("exit 3 succeeded")
        } catch let error as GitError {
            XCTAssertEqual(error.status, 3)
            XCTAssertEqual(error.stderr, "nope\n")
        }
    }

    func testABurstBeyondTheCapFinishes() async throws {
        let count = Git.maxConcurrent * 4
        let sh = sh
        let tmp = tmp
        let outputs = try await withThrowingTaskGroup(of: String.self) { group in
            for index in 0..<count {
                group.addTask { try await Git.run(sh, ["-c", "sleep 0.05; echo \(index)"], in: tmp, timeout: 20) }
            }
            return try await group.reduce(into: [String]()) { $0.append($1) }
        }
        XCTAssertEqual(Set(outputs), Set((0..<count).map { "\($0)\n" }))
    }

    func testAChildHoldingThePipeDoesNotHangTheCall() async throws {
        // The shell exits at once; the backgrounded sleep keeps stdout open,
        // as ssh does under a killed fetch.
        let start = Date()
        let output = try await Git.run(sh, ["-c", "echo early; sleep 30 &"], in: tmp, timeout: 20)
        XCTAssertEqual(output, "early\n")
        XCTAssertLessThan(Date().timeIntervalSince(start), 10)
    }
}
