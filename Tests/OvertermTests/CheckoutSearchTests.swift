import XCTest

@testable import Overterm

final class CheckoutSearchTests: XCTestCase {
    private var repo: URL!

    override func setUp() async throws {
        repo = FileManager.default.temporaryDirectory.appendingPathComponent("overterm-search-\(UUID().uuidString)")
        for dir in ["src", "node_modules/pkg"] {
            try FileManager.default.createDirectory(at: repo.appendingPathComponent(dir), withIntermediateDirectories: true)
        }
        try "let a = 1\n\nlet NeedleWord = 3\n".write(to: repo.appendingPathComponent("src/main.swift"), atomically: true, encoding: .utf8)
        try "needleword in notes\n".write(to: repo.appendingPathComponent("notes.md"), atomically: true, encoding: .utf8)
        try "needleword hidden\n".write(to: repo.appendingPathComponent("node_modules/pkg/index.js"), atomically: true, encoding: .utf8)
        try "node_modules/\n".write(to: repo.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        _ = try await Git.run(["init", "-q", "-b", "main"], in: repo)
        _ = try await Git.run(["add", "src/main.swift", ".gitignore"], in: repo)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: repo)
    }

    func testFilesIncludeUntrackedButNotIgnored() async {
        let files = await CheckoutSearch.files(in: repo)
        XCTAssertEqual(files, [".gitignore", "notes.md", "src/main.swift"])
    }

    func testGrepFindsLinesCaseInsensitivelyRespectingIgnores() async {
        let matches = await CheckoutSearch.grep("needleword", in: repo)
        XCTAssertEqual(Set(matches.map(\.path)), ["notes.md", "src/main.swift"], "untracked included, node_modules not")
        let swift = matches.first { $0.path == "src/main.swift" }
        XCTAssertEqual(swift?.line, 3)
        XCTAssertEqual(swift?.text, "let NeedleWord = 3")
    }

    func testShortQueriesDontGrep() async {
        let none = await CheckoutSearch.grep("n", in: repo)
        XCTAssertTrue(none.isEmpty)
    }

    func testRankPrefersFileNames() {
        let files = ["notes/readme.md", "src/notes.swift", "docs/other.md"]
        XCTAssertEqual(CheckoutSearch.rank(files, query: "notes").first, "src/notes.swift")
        XCTAssertTrue(CheckoutSearch.rank(files, query: "").isEmpty)
    }

    func testParseGrep() {
        let output = "a b/c.swift\u{0}12\u{0}  let x = 1\nd.md\u{0}3\u{0}hi\n"
        XCTAssertEqual(
            CheckoutSearch.parse(grep: output),
            [ContentMatch(path: "a b/c.swift", line: 12, text: "let x = 1"), ContentMatch(path: "d.md", line: 3, text: "hi")])
    }
}
