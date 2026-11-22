import XCTest

@testable import Overterm
@testable import OvertermCore

/// Scripts/affected-tests.sh, which picks the unit tests a change reaches
/// (`make test-changed`, CI's `changes` job). It runs for real with macOS's
/// /bin/bash — 3.2, which once couldn't parse it, so every change ran the
/// whole suite — over a scratch tree of sources and tests, never this one.
final class AffectedTestsTests: XCTestCase {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func write(_ text: String, to file: String, in dir: URL) throws {
        let url = dir.appendingPathComponent(file)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func testClass(_ name: String, body: String = "") -> String {
        "import XCTest\n\nfinal class \(name): XCTestCase {\n    func testIt() {\(body)}\n}\n"
    }

    /// The script beside a few sources and enough test classes that two of
    /// them reached stay a filter (under 70% of the suite).
    private func scratchTree() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("overterm-affected-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let script = try String(contentsOf: Self.root.appendingPathComponent("Scripts/affected-tests.sh"), encoding: .utf8)
        try write(script, to: "Scripts/affected-tests.sh", in: dir)

        try write("struct Leaf {\n    struct Command {}\n}\n", to: "Sources/Overterm/Leaf.swift", in: dir)
        try write("extension Leaf {\n    var other: Int { 1 }\n}\n", to: "Sources/Overterm/Leaf+Other.swift", in: dir)
        try write("@MainActor\nfinal class Model {}\ntypealias Shown = Model\n", to: "Sources/Overterm/Model.swift", in: dir)
        try write("struct Tool {}\n\nfunc helper() -> Int { 1 }\n", to: "Sources/Overterm/Helpers.swift", in: dir)
        try write("struct Tool2 {}\n\nnonisolated(unsafe) var shared = 0\n", to: "Sources/Overterm/Shared.swift", in: dir)

        let tests = "Tests/OvertermTests/"
        try write(testClass("LeafTests", body: " _ = Leaf() "), to: tests + "LeafTests.swift", in: dir)
        try write(testClass("ShownTests", body: " _ = Shown.self "), to: tests + "ShownTests.swift", in: dir)
        try write("final class TestChild {}\n\nfunc spawnChild() -> TestChild { TestChild() }\n", to: tests + "TestChildren.swift", in: dir)
        try write(testClass("ChildTests", body: " _ = TestChild() "), to: tests + "ChildTests.swift", in: dir)
        try write(testClass("SpawnTests", body: " _ = spawnChild() "), to: tests + "SpawnTests.swift", in: dir)
        try write(
            testClass("BoxTests") + "\nprivate final class Box {}\n", to: tests + "BoxTests.swift", in: dir)
        try write(testClass("OtherBoxTests", body: " _ = \"Box\" "), to: tests + "OtherBoxTests.swift", in: dir)
        for index in 1...8 {
            try write(testClass("Unrelated\(index)Tests"), to: tests + "Unrelated\(index)Tests.swift", in: dir)
        }
        return dir
    }

    /// The script's one line for `changed`, run by /bin/bash with the paths on stdin.
    private func affected(_ changed: [String], in dir: URL) async throws -> String {
        try write(changed.map { $0 + "\n" }.joined(), to: "changed.txt", in: dir)
        let output = try await Git.run(
            URL(fileURLWithPath: "/bin/bash"), ["-c", "exec /bin/bash Scripts/affected-tests.sh < changed.txt"], in: dir)
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func filter(_ classes: String...) -> String { "OvertermTests\\.(\(classes.joined(separator: "|")))/" }

    func testASourceFilePicksTheTestsThatNameItsTypes() async throws {
        let dir = try scratchTree()
        let picked = try await affected(["Sources/Overterm/Leaf.swift"], in: dir)
        XCTAssertFalse(picked.isEmpty, "bash 3.2 parsed the script")
        XCTAssertEqual(picked, filter("LeafTests"), "a nested Command reaches nobody")
        let extended = try await affected(["Sources/Overterm/Leaf+Other.swift"], in: dir)
        XCTAssertEqual(extended, filter("LeafTests"), "an extension's file reaches its type's tests")
        let aliased = try await affected(["Sources/Overterm/Model.swift"], in: dir)
        XCTAssertEqual(aliased, filter("ShownTests"), "a typealias is a name too")
    }

    func testATestHelpersDeclarationsReachTheTestsThatUseThem() async throws {
        let dir = try scratchTree()
        let picked = try await affected(["Tests/OvertermTests/TestChildren.swift"], in: dir)
        XCTAssertEqual(picked, filter("ChildTests", "SpawnTests"), "its class and its function")
    }

    func testATestFilesPrivateTypesAreItsOwn() async throws {
        let dir = try scratchTree()
        let picked = try await affected(["Tests/OvertermTests/BoxTests.swift"], in: dir)
        XCTAssertEqual(picked, filter("BoxTests"))
    }

    func testATopLevelFunctionOrGlobalInASourceFileRunsEverything() async throws {
        let dir = try scratchTree()
        let function = try await affected(["Sources/Overterm/Helpers.swift"], in: dir)
        XCTAssertEqual(function, "all")
        let global = try await affected(["Sources/Overterm/Shared.swift"], in: dir)
        XCTAssertEqual(global, "all")
    }

    /// `let first = 1, second = 2` declares two names one match can't see
    /// both of: the file runs everything. A private one is still its own.
    func testATestFileSharingSeveralBindingsInOneDeclarationRunsEverything() async throws {
        let dir = try scratchTree()
        try write("let first = 1, second = 2\n", to: "Tests/OvertermTests/Shared.swift", in: dir)
        let shared = try await affected(["Tests/OvertermTests/Shared.swift"], in: dir)
        XCTAssertEqual(shared, "all")
        try write("let (left, right) = (1, 2)\n", to: "Tests/OvertermTests/Tuple.swift", in: dir)
        let tuple = try await affected(["Tests/OvertermTests/Tuple.swift"], in: dir)
        XCTAssertEqual(tuple, "all")
        try write(testClass("PairTests") + "\nprivate let a = 1, b = 2\n", to: "Tests/OvertermTests/PairTests.swift", in: dir)
        let own = try await affected(["Tests/OvertermTests/PairTests.swift"], in: dir)
        XCTAssertEqual(own, filter("PairTests"))
    }

    /// A rename, as `git diff --no-renames` gives it: the old path gone, the new one there.
    func testASourceFileMovedAwayRunsEverything() async throws {
        let dir = try scratchTree()
        let picked = try await affected(["Sources/Overterm/Gone.swift", "Sources/Overterm/Leaf.swift"], in: dir)
        XCTAssertEqual(picked, "all")
    }

    func testDocsReachNoTestAndScriptsReachEvery() async throws {
        let dir = try scratchTree()
        let docs = try await affected(["docs/testing.md", "CHANGELOG.md"], in: dir)
        XCTAssertEqual(docs, "none")
        let scripts = try await affected(["Scripts/make-app.sh"], in: dir)
        XCTAssertEqual(scripts, "all")
        let nothing = try await affected([], in: dir)
        XCTAssertEqual(nothing, "none")
    }
}
