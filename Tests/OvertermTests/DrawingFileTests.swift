import XCTest

@testable import Overterm

/// Obsidian Excalidraw's file, read and written: a drawing made here opens
/// there and the other way, and nothing but the scene and its texts is
/// ever written again.
final class DrawingFileTests: XCTestCase {
    /// As the plugin writes one (2.22): frontmatter, a note of the user's,
    /// two text elements, an element link, the scene compressed.
    private let pluginFile = """
        ---

        excalidraw-plugin: parsed
        tags: [excalidraw]

        ---
        ==⚠  Switch to EXCALIDRAW VIEW in the MORE OPTIONS menu of this document. ⚠== You can decompress Drawing data with the command palette: 'Decompress current Excalidraw file'. For more info check in plugin settings under 'Saving'

        My own note above the data.

        # Excalidraw Data

        ## Text Elements
        Login service ^a1B2c3D4

        two
        lines ^x9Y8z7W6

        ## Element Links
        a1B2c3D4: [[Plan]]

        %%
        ## Drawing
        ```compressed-json
        N4KAkARALgngDgUwgLgAQQQDwMYEMA2AlgCYBOuA7hADTgQBuCpAzoQPYB2KqATLZMzYBXUtiRoIACyhQ4zZAHoFAc0JRJQgEYA6bGwC2CgF7N6hbEcK4OCtptbErHALRY8RMpWdx8Q1TdIEfARcZgRmBShcZQUebTiARho6IIR9BA4kLm4yYDwsSGcSWAgRiDEEaV0BDKnVgQAUfaABRyMkEhYQH

        AwMbAAA=
        ```
        %%
        """

    func testReadsThePluginsFile() throws {
        let file = try XCTUnwrap(DrawingFile.parse(pluginFile, markdown: true))
        XCTAssertTrue(file.head.hasPrefix(DrawingFile.frontmatter))
        XCTAssertTrue(file.head.hasSuffix("My own note above the data.\n\n"))
        XCTAssertEqual(file.encoding, .compressed)
        XCTAssertTrue(file.scene.hasPrefix("N4KAkARALgngDgUwgLgAQQQ") && file.scene.hasSuffix("AwMbAAA="))
        XCTAssertEqual(file.texts, [.init(id: "a1B2c3D4", text: "Login service"), .init(id: "x9Y8z7W6", text: "two\nlines")])
        XCTAssertEqual(file.otherSections, "## Element Links\na1B2c3D4: [[Plan]]\n\n")
        XCTAssertEqual(file.drawingComment, "%%\n")
        XCTAssertEqual(file.tail, "\n%%")
    }

    /// Read and written again unchanged, it is the same file, byte for byte.
    func testWritesItBackByteForByte() throws {
        XCTAssertEqual(try XCTUnwrap(DrawingFile.parse(pluginFile, markdown: true)).text, pluginFile)
        // The text elements written as the plugin writes them, too.
        let file = try XCTUnwrap(DrawingFile.parse(pluginFile, markdown: true))
        XCTAssertEqual(file.updated(scene: file.scene, encoding: file.encoding, texts: file.texts).text, pluginFile)
    }

    /// A change replaces the scene and the text elements — the user's note,
    /// the element links and the frontmatter stay as they were.
    func testAChangeKeepsEverythingElse() throws {
        let file = try XCTUnwrap(DrawingFile.parse(pluginFile, markdown: true))
        let text = file.updated(scene: "{\"elements\":[]}", encoding: .json, texts: [.init(id: "new1", text: "Hello")]).text
        XCTAssertTrue(text.hasPrefix(file.head + "# Excalidraw Data\n\n## Text Elements\nHello ^new1\n\n## Element Links\na1B2c3D4: [[Plan]]\n\n"))
        XCTAssertTrue(text.hasSuffix("%%\n## Drawing\n```json\n{\"elements\":[]}\n```\n%%"))
    }

    /// The plugin can comment the whole data out (`%%` above it): kept so.
    func testTheDataCommentedOutWhole() throws {
        let text = DrawingFile.frontmatter + "%%\n# Excalidraw Data\n\n## Text Elements\n## Drawing\n```json\n{}\n```\n%%"
        let file = try XCTUnwrap(DrawingFile.parse(text, markdown: true))
        XCTAssertEqual(file.drawingComment, "")
        XCTAssertTrue(file.head.hasSuffix("%%\n"))
        XCTAssertEqual(file.text, text)
    }

    /// A markdown file not laid out as the plugin lays them out isn't one
    /// to rewrite.
    func testNotADrawing() {
        XCTAssertNil(DrawingFile.parse("# Notes\n\nJust a note.\n", markdown: true))
        XCTAssertNil(DrawingFile.parse("# Excalidraw Data\n\n## Text Elements\n## Drawing\n```yaml\nx\n```\n", markdown: true))
    }

    /// A plain `.excalidraw` is the scene alone.
    func testAPlainExcalidrawFile() throws {
        let file = try XCTUnwrap(DrawingFile.parse(DrawingFile.emptyScene, markdown: false))
        XCTAssertEqual(file.encoding, .json)
        XCTAssertEqual(file.text, DrawingFile.emptyScene)
        XCTAssertEqual(file.updated(scene: "{}", encoding: .compressed, texts: [.init(id: "a", text: "b")]).text, "{}", "never compressed, no texts")
    }

    /// A new drawing is the plugin's frontmatter over an empty scene — or
    /// the template, when the plugin names one that reads.
    func testANewDrawing() throws {
        let text = DrawingFile.new(markdown: true)
        XCTAssertTrue(text.hasPrefix(DrawingFile.frontmatter + "# Excalidraw Data\n\n## Text Elements\n%%\n## Drawing\n```json\n"))
        XCTAssertEqual(try XCTUnwrap(DrawingFile.parse(text, markdown: true)).scene, DrawingFile.emptyScene)
        XCTAssertEqual(DrawingFile.new(markdown: true, template: pluginFile), pluginFile)
        XCTAssertEqual(DrawingFile.new(markdown: true, template: "not a drawing"), text, "a template that isn't one is passed over")
        XCTAssertEqual(DrawingFile.new(markdown: false), DrawingFile.emptyScene)
    }

    /// Which files are drawings: by name, or a plain `.md` by its frontmatter.
    func testWhichFilesAreDrawings() {
        XCTAssertTrue(DrawingFile.isDrawing(URL(fileURLWithPath: "/v/Excalidraw/Drawing 1.excalidraw.md")))
        XCTAssertTrue(DrawingFile.isDrawing(URL(fileURLWithPath: "/v/board.excalidraw")))
        XCTAssertFalse(DrawingFile.isDrawing(URL(fileURLWithPath: "/v/Plan.md")))
        XCTAssertTrue(DrawingFile.isDrawing(URL(fileURLWithPath: "/v/Board.md"), text: pluginFile))
        XCTAssertFalse(DrawingFile.isDrawing(URL(fileURLWithPath: "/v/Plan.md"), text: "---\ntags: [x]\n---\nexcalidraw-plugin: in the body\n"))
        XCTAssertEqual(DrawingFile.title(of: URL(fileURLWithPath: "/v/Drawing 1.excalidraw.md")), "Drawing 1")
        XCTAssertEqual(NoteItem.Kind(URL(fileURLWithPath: "/v/Drawing 1.excalidraw.md")), .drawing)
        XCTAssertEqual(NoteItem.Kind(URL(fileURLWithPath: "/v/a.excalidraw")), .drawing)
        XCTAssertEqual(NoteItem.Kind(URL(fileURLWithPath: "/v/a.canvas")), .canvas)
        XCTAssertEqual(NoteItem(url: URL(fileURLWithPath: "/v/Drawing 1.excalidraw.md"), kind: .drawing).name, "Drawing 1")
    }
}

/// What Obsidian Excalidraw's settings say about a new drawing.
final class ExcalidrawSettingsTests: XCTestCase {
    private let root = FileManager.default.temporaryDirectory.appendingPathComponent("overterm-excalidraw-\(UUID().uuidString)")

    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    func testThePluginsDefaultsWithoutIt() {
        let settings = ExcalidrawSettings.read(from: root)
        XCTAssertEqual(settings, ExcalidrawSettings())
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let date = calendar.date(from: DateComponents(year: 2026, month: 10, day: 31, hour: 14, minute: 20, second: 5))!
        let name = settings.fileName(at: date)
        XCTAssertEqual(name.base, "Drawing 2026-10-31 14.20.05")
        XCTAssertEqual(name.extension, "excalidraw.md")
    }

    func testReadsItsDataJSON() throws {
        let folder = root.appendingPathComponent(".obsidian/plugins/obsidian-excalidraw-plugin")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try #"{"folder": "Art", "drawingFilenamePrefix": "Sketch-", "drawingFilenameDateTime": "YYYY", "useExcalidrawExtension": false, "compress": false, "templateFilePath": "Art/T.excalidraw"}"#
            .write(to: folder.appendingPathComponent("data.json"), atomically: true, encoding: .utf8)
        let settings = ExcalidrawSettings.read(from: root)
        XCTAssertEqual(settings.folder, "Art")
        XCTAssertFalse(settings.compress)
        XCTAssertEqual(settings.fileName(at: Date(timeIntervalSince1970: 1_800_000_000)).extension, "md")
        XCTAssertTrue(settings.fileName(at: Date(timeIntervalSince1970: 1_800_000_000)).base.hasPrefix("Sketch-20"))
        XCTAssertNil(settings.template(in: root), "no template there")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Art"), withIntermediateDirectories: true)
        try "x".write(to: root.appendingPathComponent("Art/T.excalidraw.md"), atomically: true, encoding: .utf8)
        XCTAssertEqual(settings.template(in: root)?.lastPathComponent, "T.excalidraw.md", "found with .md, as the plugin finds it")
    }
}
