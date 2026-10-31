import Foundation

/// An Excalidraw drawing as Obsidian Excalidraw keeps it in the vault, so
/// one drawn here opens there and one drawn there opens here.
///
/// A `.excalidraw.md` is markdown: what you wrote above `# Excalidraw Data`
/// (the frontmatter that marks it, and any notes of your own), the text of
/// every text element under `## Text Elements` — so search and links see
/// it — then the plugin's own sections, and the scene itself under
/// `## Drawing`, as JSON or as lz-string's base64 (`compressed-json`) in
/// lines of 256. A plain `.excalidraw` is the scene's JSON alone.
///
/// Pure. Only the text elements and the scene are ever written again;
/// every other byte — your notes, `## Element Links`, `## Embedded Files`
/// — is kept as it was. The scene's encoding is the page's to do
/// (Resources/notes/draw.js has lz-string); here it is opaque text.
struct DrawingFile: Equatable, Sendable {
    enum Encoding: String, Sendable {
        case json
        case compressed = "compressed-json"
    }

    /// What `## Text Elements` lists: a text element's text, and its id.
    struct Text: Equatable, Sendable {
        let id: String
        let text: String
    }

    /// Markdown (`.excalidraw.md`), or a plain `.excalidraw`.
    let isMarkdown: Bool
    /// Up to `# Excalidraw Data`: the frontmatter, the plugin's notice,
    /// your own notes.
    var head = ""
    /// From `# Excalidraw Data` to the end of the `## Text Elements` line.
    var dataHeader = DrawingFile.standardDataHeader
    /// The text elements as written: `text ^id`, a blank line after each.
    var textSection = ""
    /// `## Element Links` and `## Embedded Files`, as they were.
    var otherSections = ""
    /// `%%\n` before `## Drawing`, which hides the scene in Obsidian's
    /// reading view — empty when the plugin put it above the whole data.
    var drawingComment = "%%\n"
    var encoding = Encoding.compressed
    /// The scene, as `encoding` has it.
    var scene = ""
    /// After the scene's closing fence: `\n%%`, and anything after that.
    var tail = "\n%%"

    static let standardDataHeader = "# Excalidraw Data\n\n## Text Elements\n"

    /// The plugin's frontmatter and its notice, as it writes them for a
    /// new drawing (`FRONTMATTER` in its main.js).
    static let frontmatter =
        "---\n\nexcalidraw-plugin: parsed\ntags: [excalidraw]\n\n---\n"
        + "==⚠  Switch to EXCALIDRAW VIEW in the MORE OPTIONS menu of this document. ⚠== "
        + "You can decompress Drawing data with the command palette: 'Decompress current Excalidraw file'. "
        + "For more info check in plugin settings under 'Saving'\n\n"

    // MARK: Which files

    /// A drawing by its name: `.excalidraw.md`, or `.excalidraw`.
    static func isDrawing(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        return name.hasSuffix(".excalidraw.md") || name.hasSuffix(".excalidraw")
    }

    /// A drawing by its name or its content: the plugin can be set to name
    /// them plain `.md`, and then only the frontmatter says so.
    static func isDrawing(_ url: URL, text: String) -> Bool {
        if isDrawing(url) { return true }
        guard url.pathExtension.lowercased() == "md", text.hasPrefix("---") else { return false }
        let start = text.prefix(1024)
        guard let end = start.dropFirst(3).range(of: "\n---") else { return false }
        return start[start.startIndex..<end.lowerBound].contains("excalidraw-plugin:")
    }

    /// The name a drawing goes by: without `.excalidraw.md` or `.excalidraw`.
    static func title(of url: URL) -> String {
        var name = url.lastPathComponent
        for suffix in [".excalidraw.md", ".excalidraw", ".md"] where name.lowercased().hasSuffix(suffix) {
            name.removeLast(suffix.count)
            break
        }
        return name
    }

    // MARK: Reading

    /// The file's parts; nil when a markdown file isn't laid out as the
    /// plugin lays them out (it is then shown as text, never rewritten).
    static func parse(_ text: String, markdown: Bool) -> DrawingFile? {
        guard markdown else {
            var file = DrawingFile(isMarkdown: false)
            file.encoding = .json
            file.scene = text
            file.tail = ""
            return file
        }
        guard let data = lineRange(of: "# Excalidraw Data", in: text),
            let texts = lineRange(of: "## Text Elements", in: text, from: data.upperBound),
            let drawing = lineRange(of: "## Drawing", in: text, from: texts.upperBound)
        else { return nil }
        // ```json or ```compressed-json, the scene, the closing fence.
        let afterDrawing = text[drawing.upperBound...]
        guard afterDrawing.hasPrefix("```"), let fenceEnd = afterDrawing.firstIndex(of: "\n") else { return nil }
        let language = afterDrawing[afterDrawing.index(afterDrawing.startIndex, offsetBy: 3)..<fenceEnd]
        guard let encoding = Encoding(rawValue: String(language).trimmingCharacters(in: .whitespaces)) else { return nil }
        let sceneStart = text.index(after: fenceEnd)
        guard let close = text.range(of: "\n```", range: sceneStart..<text.endIndex) else { return nil }

        var file = DrawingFile(isMarkdown: true)
        file.head = String(text[..<data.lowerBound])
        file.dataHeader = String(text[data.lowerBound..<texts.upperBound])
        var between = String(text[texts.upperBound..<drawing.lowerBound])
        if between.hasSuffix("%%\n") {
            between.removeLast(3)
            file.drawingComment = "%%\n"
        } else {
            file.drawingComment = ""
        }
        // The plugin's other sections, kept whole; the text elements before them.
        let others = ["## Element Links", "## Embedded Files"].compactMap { lineRange(of: $0, in: between)?.lowerBound }.min()
        file.textSection = String(others.map { between[..<$0] } ?? between[...])
        file.otherSections = String(others.map { between[$0...] } ?? "")
        file.encoding = encoding
        file.scene = String(text[sceneStart..<close.lowerBound])
        file.tail = String(text[close.upperBound...])
        return file
    }

    /// The text elements as `## Text Elements` lists them: each is its text
    /// then ` ^id`, with a blank line after.
    var texts: [Text] {
        textSection.components(separatedBy: "\n\n").compactMap { entry in
            let entry = entry.trimmingCharacters(in: .newlines)
            guard let caret = entry.range(of: " ^", options: .backwards) else { return nil }
            let id = String(entry[caret.upperBound...])
            guard !id.isEmpty, !id.contains(where: \.isWhitespace) else { return nil }
            return Text(id: id, text: String(entry[..<caret.lowerBound]))
        }
    }

    // MARK: Writing

    /// The file's text.
    var text: String {
        guard isMarkdown else { return scene }
        return head + dataHeader + textSection + otherSections + drawingComment + "## Drawing\n```" + encoding.rawValue + "\n" + scene
            + "\n```" + tail
    }

    /// This drawing with the page's scene and the text elements in it.
    func updated(scene: String, encoding: Encoding, texts: [Text]) -> DrawingFile {
        var file = self
        file.scene = scene
        guard isMarkdown else { return file }
        file.encoding = encoding
        file.textSection = Self.textSection(texts)
        return file
    }

    /// `## Text Elements`'s body, as the plugin writes it.
    static func textSection(_ texts: [Text]) -> String {
        texts.map { "\($0.text) ^\($0.id)\n\n" }.joined()
    }

    /// A new, empty drawing: the plugin's frontmatter, or `template`'s
    /// text when the plugin names one and it is there.
    static func new(markdown: Bool, template: String? = nil) -> String {
        if let template, parse(template, markdown: markdown) != nil { return template }
        guard markdown else { return emptyScene }
        var file = DrawingFile(isMarkdown: true)
        file.head = frontmatter
        // The page compresses when it saves; until then, plain JSON reads.
        file.encoding = .json
        file.scene = emptyScene
        return file.text
    }

    /// A scene with nothing in it, as Excalidraw writes one.
    static let emptyScene = """
        {
        \t"type": "excalidraw",
        \t"version": 2,
        \t"source": "https://github.com/Overcraft-hq/overterm",
        \t"elements": [],
        \t"appState": {
        \t\t"gridSize": null,
        \t\t"viewBackgroundColor": "#ffffff"
        \t},
        \t"files": {}
        }
        """

    /// The range of a line that is exactly `line`, with its newline.
    private static func lineRange(of line: String, in text: some StringProtocol, from start: String.Index? = nil) -> Range<String.Index>? {
        var from = start ?? text.startIndex
        while let found = text.range(of: line + "\n", range: from..<text.endIndex) {
            if found.lowerBound == text.startIndex || text[text.index(before: found.lowerBound)] == "\n" { return found }
            from = found.upperBound
        }
        return nil
    }
}

/// What Obsidian Excalidraw's settings say about new drawings — its own
/// `data.json`, read and never written; the plugin's defaults without it.
struct ExcalidrawSettings: Equatable, Sendable {
    var folder = "Excalidraw"
    var prefix = "Drawing "
    /// A moment.js format, the date in a new drawing's name.
    var dateTime = "YYYY-MM-DD HH.mm.ss"
    /// `.excalidraw.md`, else plain `.md`.
    var useExcalidrawExtension = true
    var compress = true
    /// A drawing a new one starts as, when it is there.
    var templatePath = "Excalidraw/Template.excalidraw"

    static func read(from root: URL) -> ExcalidrawSettings {
        var settings = ExcalidrawSettings()
        let file = root.appendingPathComponent(".obsidian/plugins/obsidian-excalidraw-plugin/data.json")
        guard let data = try? Data(contentsOf: file), let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return settings
        }
        if let folder = json["folder"] as? String { settings.folder = folder }
        if let prefix = json["drawingFilenamePrefix"] as? String { settings.prefix = prefix }
        if let format = json["drawingFilenameDateTime"] as? String { settings.dateTime = format }
        if let flag = json["useExcalidrawExtension"] as? Bool { settings.useExcalidrawExtension = flag }
        if let flag = json["compress"] as? Bool { settings.compress = flag }
        if let path = json["templateFilePath"] as? String { settings.templatePath = path }
        return settings
    }

    /// A new drawing's name, without its folder: `Drawing 2026-10-31 14.20.05.excalidraw.md`.
    func fileName(at date: Date) -> (base: String, extension: String) {
        let base = prefix + (dateTime.isEmpty ? "" : MomentFormat.string(from: date, format: dateTime))
        return (base.isEmpty ? "Drawing" : base, useExcalidrawExtension ? "excalidraw.md" : "md")
    }

    /// The template, as the plugin finds it: the path, or the path with `.md`.
    func template(in root: URL) -> URL? {
        guard !templatePath.isEmpty else { return nil }
        let path = templatePath.hasPrefix("/") ? String(templatePath.dropFirst()) : templatePath
        for spelling in [path, path + ".md"] {
            let url = root.appendingPathComponent(spelling)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }
}
