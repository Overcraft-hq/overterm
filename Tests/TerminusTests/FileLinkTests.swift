import XCTest

@testable import Terminus

final class FileLinkTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("terminus-link-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root.appendingPathComponent("src"), withIntermediateDirectories: true)
        try "x\n".write(to: root.appendingPathComponent("src/main.swift"), atomically: true, encoding: .utf8)
        try "x\n".write(to: root.appendingPathComponent("notes:1"), atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var main: URL { root.appendingPathComponent("src/main.swift") }

    func testLineSuffixes() {
        for text in ["src/main.swift:12", "src/main.swift:12:5", "src/main.swift(12,5)", "src/main.swift(12)"] {
            XCTAssertEqual(FileLink.resolve(text, in: [root.path]), FileLink(url: main, line: 12), text)
        }
        XCTAssertEqual(FileLink.resolve("./src/main.swift", in: [root.path]), FileLink(url: main, line: nil))
    }

    func testTriesEachDirectoryInOrder() {
        let src = root.appendingPathComponent("src").path
        XCTAssertEqual(FileLink.resolve("main.swift:3", in: [src, root.path])?.url, main)
        // Repo-relative from a subdirectory shell: falls through to the checkout.
        XCTAssertEqual(FileLink.resolve("src/main.swift:3", in: [src, root.path])?.url, main)
    }

    func testAbsoluteAndFileURLs() {
        XCTAssertEqual(FileLink.resolve(main.path + ":7", in: []), FileLink(url: main, line: 7))
        XCTAssertEqual(FileLink.resolve(main.absoluteString, in: [])?.url, main)
    }

    func testAFileNamedLikeALineWinsOverTheSplit() {
        XCTAssertEqual(FileLink.resolve("notes:1", in: [root.path]), FileLink(url: root.appendingPathComponent("notes:1"), line: nil))
    }

    func testWhatIsNotAFileGoesElsewhere() {
        XCTAssertNil(FileLink.resolve("https://example.com/a.swift:3", in: [root.path]))
        XCTAssertNil(FileLink.resolve("src", in: [root.path]), "directories")
        XCTAssertNil(FileLink.resolve("src/missing.swift:3", in: [root.path]))
        try? Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x01]).write(to: root.appendingPathComponent("logo.png"))
        XCTAssertNil(FileLink.resolve("logo.png", in: [root.path]), "binaries")
    }
}
