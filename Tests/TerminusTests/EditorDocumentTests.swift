import XCTest

@testable import Terminus

final class EditorDocumentTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("terminus-editor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    @MainActor
    func testLoadEditSave() throws {
        let url = dir.appendingPathComponent("a.swift")
        try "let x = 1\n".write(to: url, atomically: true, encoding: .utf8)
        let doc = EditorDocument()
        doc.load(url)
        XCTAssertEqual(doc.text, "let x = 1\n")
        XCTAssertFalse(doc.isDirty)
        doc.markEdited()
        XCTAssertTrue(doc.isDirty)
        try doc.save("let x = 2\n")
        XCTAssertFalse(doc.isDirty)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "let x = 2\n")
        XCTAssertFalse(doc.changedOnDisk)
    }

    @MainActor
    func testBinaryAndNonUTF8AreNotEditable() throws {
        let bin = dir.appendingPathComponent("logo.png")
        try Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x01]).write(to: bin)
        let doc = EditorDocument()
        doc.load(bin)
        XCTAssertEqual(doc.unavailable, "Binary file.")
        doc.markEdited()
        XCTAssertFalse(doc.isDirty, "nothing to edit")

        let latin = dir.appendingPathComponent("old.txt")
        try Data([0x63, 0x61, 0x66, 0xE9]).write(to: latin)
        doc.load(latin)
        XCTAssertEqual(doc.unavailable, "Not UTF-8 text.")
    }

    @MainActor
    func testNoticesOutsideChanges() throws {
        let url = dir.appendingPathComponent("b.txt")
        try "one".write(to: url, atomically: true, encoding: .utf8)
        let doc = EditorDocument()
        doc.load(url)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: url.path)
        XCTAssertTrue(doc.changedOnDisk)
    }

    func testLineIndex() {
        let starts = LineIndex.starts(of: "ab\ncd\n\nef" as NSString)
        XCTAssertEqual(starts, [0, 3, 6, 7])
        XCTAssertEqual(LineIndex.line(of: 0, in: starts), 1)
        XCTAssertEqual(LineIndex.line(of: 2, in: starts), 1)
        XCTAssertEqual(LineIndex.line(of: 3, in: starts), 2)
        XCTAssertEqual(LineIndex.line(of: 6, in: starts), 3)
        XCTAssertEqual(LineIndex.line(of: 8, in: starts), 4)
    }
}
