import XCTest

@testable import Overterm
@testable import OvertermCore

/// Onboarding stage 1's rule, kept (DISC-U4, DISC-N3): a key on screen is
/// the key bound now. A string literal in `Sources` that writes a modifier
/// and a letter (⌥⌘G, ⌘W, ⇧A) is a key written into the text, which goes
/// wrong the moment its command is rebound — it reads the binding instead
/// (`KeyHints.help`, `KeyHints.text`, `KeyHint`). The scenarios
/// (`OvertermE2E`) and comments are not UI and aren't read.
///
/// What stays written is in `allowed`, each with why: keys that aren't
/// Overterm's commands, so Settings ▸ Keyboard Shortcuts can't rebind them.
final class KeysInTextTests: XCTestCase {
    private let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources", isDirectory: true)

    /// A key that may stay written, and where (a path's part; nil: anywhere).
    private struct Allowed {
        let keys: Set<String>
        let path: String?
        let why: String
    }

    private let allowed: [Allowed] = [
        Allowed(
            keys: ["⌃C", "⌃Z"], path: nil,
            why: "Control characters typed into a terminal: the job's and the shell's, not a command of Overterm's."),
        Allowed(keys: ["⌥o", "⌥r"], path: "OvertermActivity/", why: "The Activity list's own keys (`ActivityKey`), fixed like j/k."),
        Allowed(keys: ["⇧A"], path: "OvertermTerraform/TerraformPlanPaneView.swift", why: "The plan pane's own list key, fixed."),
        Allowed(
            keys: ["⌘T", "⌘W", "⌘L", "⌘R"], path: "Overterm/ResourcePage/KeySheet.swift",
            why: "The browser column's Safari keys, fixed in `BrowserViewController.handleKey`."),
        Allowed(
            keys: ["⌘T", "⌘W"], path: "Overterm/Browser/BrowserViewController.swift",
            why: "The browser column's own New Tab and Close Tab: Safari's keys, fixed in its `handleKey`."),
        Allowed(
            keys: ["⌘R"], path: "OvertermKubernetes/KubeGitOpsView.swift",
            why: "The Kubernetes page's own ⌘R on GitOps (`KubernetesPageModel.commandPress`), not a KeyCommand."),
    ]

    func testNoKeyForARebindableCommandIsWrittenIntoTheText() throws {
        let files = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var written: [String] = []
        var scanned = 0
        for case let url as URL in files where url.pathExtension == "swift" {
            // The path under Sources, however the folder was spelled to get there.
            let path = url.path.components(separatedBy: "/Sources/").last ?? url.path
            guard !path.hasPrefix("OvertermE2E/") else { continue }
            scanned += 1
            let text = try String(contentsOf: url, encoding: .utf8)
            for (line, key) in Self.keys(in: text) where !isAllowed(key, path: path) {
                written.append("\(path):\(line) \(key)")
            }
        }
        XCTAssertGreaterThan(scanned, 100, "Sources wasn't found at \(sources.path)")
        XCTAssertEqual(written, [], "Read the bound key (KeyHints.help/text, KeyHint) instead, or allow it here with why.")
    }

    /// The scanner itself: strings only, comments and code passed over.
    func testItReadsStringsOnly() {
        let text = """
            // A comment says ⌥⌘G, which isn't shown.
            let a = "Overgit (⌥⌘G)" // ⌘W in a trailing comment
            let b = "\\"quoted\\" ⇧⌘R"
            let c = 1  /* not a string */ + 2
            let d = \"""
                Save (⌘S)
                \"""
            let e = "⇧ and ⌘ to pick several, ⌘↩ sends"
            """
        XCTAssertEqual(Self.keys(in: text).map(\.key), ["⌥⌘G", "⇧⌘R", "⌘S"])
    }

    private func isAllowed(_ key: String, path: String) -> Bool {
        allowed.contains { entry in entry.keys.contains(key) && (entry.path.map { part in path.contains(part) } ?? true) }
    }

    /// Each modifier run followed by a letter inside a string literal —
    /// one line, or a multi-line literal's — with its line number.
    static func keys(in text: String) -> [(line: Int, key: String)] {
        let modifiers: Set<Character> = ["⌃", "⌥", "⇧", "⌘"]
        var found: [(line: Int, key: String)] = []
        var inBlock = false
        for (index, raw) in text.components(separatedBy: "\n").enumerated() {
            if !inBlock, raw.trimmingCharacters(in: .whitespaces).hasPrefix("//") { continue }
            let (strings, open) = literals(in: Array(raw), inBlock: inBlock)
            inBlock = open
            for string in strings {
                let characters = Array(string)
                var at = 0
                while at < characters.count {
                    guard modifiers.contains(characters[at]) else {
                        at += 1
                        continue
                    }
                    var end = at
                    while end < characters.count, modifiers.contains(characters[end]) { end += 1 }
                    if end < characters.count, characters[end].isASCII, characters[end].isLetter {
                        found.append((index + 1, String(characters[at...end])))
                    }
                    at = end + 1
                }
            }
        }
        return found
    }

    /// The string literals' contents on one line, and whether a `"""` block is still open after it.
    private static func literals(in line: [Character], inBlock: Bool) -> ([String], Bool) {
        var out: [String] = []
        var at = 0
        func triple(_ index: Int) -> Bool {
            index + 2 < line.count && line[index] == "\"" && line[index + 1] == "\"" && line[index + 2] == "\""
        }
        if inBlock {
            guard let close = line.indices.first(where: triple) else { return ([String(line)], true) }
            out.append(String(line[..<close]))
            at = close + 3
        }
        var current: String?
        while at < line.count {
            let character = line[at]
            if var string = current {
                if character == "\\", at + 1 < line.count {
                    string.append(character)
                    string.append(line[at + 1])
                    current = string
                    at += 2
                } else if character == "\"" {
                    out.append(string)
                    current = nil
                    at += 1
                } else {
                    string.append(character)
                    current = string
                    at += 1
                }
                continue
            }
            if character == "/", at + 1 < line.count, line[at + 1] == "/" { break }
            if triple(at) {
                let rest = Array(line[(at + 3)...])
                guard let close = rest.indices.first(where: { index in index + 2 < rest.count && rest[index] == "\"" && rest[index + 1] == "\"" && rest[index + 2] == "\"" })
                else { return (out + [String(rest)], true) }
                out.append(String(rest[..<close]))
                at += 3 + close + 3
                continue
            }
            if character == "\"" { current = "" }
            at += 1
        }
        return (out, false)
    }
}

/// The words that used to carry a key: each says the one bound now, and
/// nothing — no gap — while it is unbound.
@MainActor
final class KeysReadAsBoundTests: XCTestCase {
    private var file: URL!

    override func setUp() {
        file = FileManager.default.temporaryDirectory.appendingPathComponent("keys-\(UUID().uuidString).json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: file)
    }

    private func keys(_ text: String = "[]") throws -> Keybindings {
        try text.write(to: file, atomically: true, encoding: .utf8)
        return Keybindings(url: file, ghosttyDefault: { _ in nil }, watch: false)
    }

    func testAListsFootSaysCopysKeyOrNone() throws {
        XCTAssertEqual(ResourceKeys.listNote(keys: try keys()), "↑↓ to move, ⇧ and ⌘ to pick several, ⌘C copies their names.")
        let unbound = try keys(#"[{ "key": "cmd+c", "command": "-edit.copy" }]"#)
        XCTAssertEqual(ResourceKeys.listNote(keys: unbound), "↑↓ to move, ⇧ and ⌘ to pick several.")
    }

    func testTooltipsFollowARebinding() throws {
        let rebound = try keys(#"[{ "key": "ctrl+alt+cmd+d", "command": "splits.right" }]"#)
        XCTAssertEqual(KeyHints.help("Split Right", command: "splits.right", keys: rebound), "Split Right (⌃⌥⌘D)")
        XCTAssertEqual(KeyHints.help("Simulator", command: "simulator.toggle", keys: rebound), "Simulator", "no key by default: the name alone")
    }

    func testTheEditorHeadersTips() {
        let before = EditorHeaderView.boundKey
        defer { EditorHeaderView.boundKey = before }
        EditorHeaderView.boundKey = { id in id == "editor.toggleZoom" ? "⇧⎋" : nil }
        XCTAssertEqual(EditorHeaderView.tip("Zoom Editor", command: "editor.toggleZoom"), "Zoom Editor — ⇧⎋")
        XCTAssertEqual(EditorHeaderView.tip("Unsaved", command: "file.save"), "Unsaved", "unbound: the words alone")
    }
}
