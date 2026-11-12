import AppKit
import XCTest

@testable import Overterm

final class SyntaxDocumentTests: XCTestCase {
    private func spans(_ text: String, _ file: String) -> [(String, String)] {
        let language = EditorLanguage.language(for: URL(fileURLWithPath: file))!
        let document = SyntaxDocument(language: language)
        document.reset(Array(text.utf16), version: 1)
        let ns = text as NSString
        return document.highlightsNow(in: NSRange(location: 0, length: ns.length)).map { (ns.substring(with: $0.range), $0.capture) }
    }

    /// What a token ends up painted as: the last span over it wins.
    private func winner(_ token: String, in found: [(String, String)]) -> String? {
        found.last { $0.0 == token }?.1
    }

    func testEveryLanguagesQueriesCompile() {
        XCTAssertNotNil(EditorLanguage.queriesDirectory, "make treesitter first")
        for language in EditorLanguage.all {
            XCTAssertNotNil(language.highlights, "\(language.id) highlights")
            if EditorLanguage.querySource(language.id, "injections") != nil {
                XCTAssertNotNil(language.injections, "\(language.id) injections")
            }
        }
    }

    func testSwift() {
        let found = spans("// note\nfunc greet(name: String) -> Int {\n    return \"hi \\(name)\".count + 42\n}\n", "a.swift")
        XCTAssertEqual(winner("// note", in: found).map { $0.hasPrefix("comment") }, true)
        XCTAssertEqual(winner("func", in: found).map { $0.hasPrefix("keyword") }, true)
        XCTAssertEqual(winner("greet", in: found).map { $0.hasPrefix("function") }, true)
        XCTAssertEqual(winner("String", in: found).map { $0.hasPrefix("type") }, true)
        XCTAssertEqual(winner("42", in: found).map { $0.hasPrefix("constant.numeric") }, true)
        XCTAssertEqual(winner("return", in: found).map { $0.hasPrefix("keyword") }, true)
    }

    func testGoAndTypeScript() {
        let go = spans("package main\n\nimport \"fmt\"\n\nfunc main() { fmt.Println(\"x\") }\n", "main.go")
        XCTAssertEqual(winner("package", in: go).map { $0.hasPrefix("keyword") }, true)
        XCTAssertEqual(winner("\"fmt\"", in: go).map { $0.hasPrefix("string") }, true)
        let ts = spans("const x: number = 1;\ninterface A { b: string }\n", "a.ts")
        XCTAssertEqual(winner("const", in: ts).map { $0.hasPrefix("keyword") }, true)
        XCTAssertEqual(winner("interface", in: ts).map { $0.hasPrefix("keyword") }, true)
        XCTAssertEqual(winner("number", in: ts).map { $0.hasPrefix("type") }, true)
    }

    /// Markdown is two grammars: the blocks, and the inline text injected
    /// into every paragraph — and a fence's code is its own language.
    func testMarkdownInjectsInlineAndFencedCode() {
        let text = "# Title\n\nSome **bold** and [a link](https://x.dev).\n\n```swift\nlet a = 1\n```\n"
        let found = spans(text, "README.md")
        XCTAssertTrue(found.contains { $0.0 == "# Title\n" && $0.1.hasPrefix("markup.heading") }, "\(found)")
        XCTAssertTrue(found.contains { $0.0 == "**bold**" && $0.1.hasPrefix("markup.bold") }, "\(found)")
        XCTAssertTrue(found.contains { $0.0 == "https://x.dev" && $0.1.hasPrefix("markup.link.url") }, "\(found)")
        XCTAssertEqual(winner("let", in: found).map { $0.hasPrefix("keyword") }, true, "the fence is Swift: \(found)")
    }

    func testIncrementalEditMatchesAFreshParse() {
        let language = EditorLanguage.language(for: URL(fileURLWithPath: "a.swift"))!
        let document = SyntaxDocument(language: language)
        let before = "let a = 1\nlet b = 2\n"
        document.reset(Array(before.utf16), version: 1)
        // Type a comment opener at the start of line 2, then a word.
        var edit = SyntaxEdit(location: 10, oldLength: 0, newLength: 3)
        edit.merge(location: 13, oldLength: 0, newLength: 4)
        let after = "let a = 1\n// note let b = 2\n"
        XCTAssertEqual(edit, SyntaxEdit(location: 10, oldLength: 0, newLength: 7))
        document.update(Array(after.utf16), edit: edit, version: 2)
        let ns = after as NSString
        let incremental = document.highlightsNow(in: NSRange(location: 0, length: ns.length))
        let fresh = SyntaxDocument(language: language)
        fresh.reset(Array(after.utf16), version: 1)
        XCTAssertEqual(incremental, fresh.highlightsNow(in: NSRange(location: 0, length: ns.length)))
        XCTAssertTrue(incremental.contains { ns.substring(with: $0.range) == "// note let b = 2" && $0.capture.hasPrefix("comment") })
    }

    func testMergingEdits() {
        // Replace 2 chars at 5 with 4, then delete 3 chars at 1 (before it).
        var edit = SyntaxEdit(location: 5, oldLength: 2, newLength: 4)
        edit.merge(location: 1, oldLength: 3, newLength: 0)
        XCTAssertEqual(edit, SyntaxEdit(location: 1, oldLength: 6, newLength: 5))
        // An edit after the first, past its end.
        var later = SyntaxEdit(location: 2, oldLength: 0, newLength: 1)
        later.merge(location: 10, oldLength: 2, newLength: 0)
        XCTAssertEqual(later, SyntaxEdit(location: 2, oldLength: 9, newLength: 8))
    }

    func testThemeFallsBackToTheNearestName() {
        let theme = EditorTheme(dark: true, background: .black)
        XCTAssertEqual(theme.style(for: "keyword.control.return"), theme.style(for: "keyword"))
        XCTAssertNotNil(theme.style(for: "markup.heading.1"))
        XCTAssertNil(theme.style(for: "something.else"))
    }

    /// Terraform (analysis 4.14): HCL's grammar at Helix's pin, its comments'
    /// `comment` injection — no grammar here — skipped, not a failure.
    func testHCL() {
        let text = "# acme\nresource \"terraform_data\" \"acme\" {\n  input = var.acme_name\n  count = 2\n  enabled = true\n}\n"
        let found = spans(text, "main.tf")
        XCTAssertEqual(winner("# acme", in: found).map { $0.hasPrefix("comment") }, true, "\(found)")
        XCTAssertEqual(winner("terraform_data", in: found).map { $0.hasPrefix("string") }, true, "\(found)")
        XCTAssertEqual(winner("resource", in: found).map { $0.hasPrefix("type") || $0.hasPrefix("keyword") }, true, "\(found)")
        XCTAssertEqual(winner("var", in: found), "variable.builtin", "\(found)")
        XCTAssertEqual(winner("2", in: found).map { $0.hasPrefix("constant.numeric") }, true, "\(found)")
        XCTAssertEqual(winner("true", in: found).map { $0.hasPrefix("constant") }, true, "\(found)")
        XCTAssertNotNil(EditorLanguage.named("hcl")?.injections, "the injections query compiles")
        let tfvars = spans("acme_name = \"acme-prod\" # the env\n", "prod.tfvars")
        XCTAssertEqual(winner("acme-prod", in: tfvars).map { $0.hasPrefix("string") }, true, "\(tfvars)")
        XCTAssertEqual(winner("# the env", in: tfvars), "comment", "\(tfvars)")
    }

    func testLanguageByFile() {
        for name in ["main.tf", "prod.tfvars", "main.tofu", "acme.tftest.hcl", ".terraform.lock.hcl", "terragrunt.hcl", "root.hcl", "job.nomad"] {
            XCTAssertEqual(EditorLanguage.language(for: URL(fileURLWithPath: "/acme/\(name)"))?.id, "hcl", name)
        }
        XCTAssertEqual(EditorLanguage.language(for: URL(fileURLWithPath: "/acme/main.tf.json"))?.id, "json")
        XCTAssertEqual(EditorLanguage.named("terraform")?.id, "hcl")
        XCTAssertEqual(EditCommands.commentPrefix(forLanguageID: EditCommands.languageID(forFileName: "main.tf")), .line("# "))
        XCTAssertEqual(EditorLanguage.language(for: URL(fileURLWithPath: "/r/Dockerfile"))?.id, "dockerfile")
        XCTAssertEqual(EditorLanguage.language(for: URL(fileURLWithPath: "/r/Makefile"))?.id, "make")
        XCTAssertEqual(EditorLanguage.language(for: URL(fileURLWithPath: "/r/x.tsx"))?.id, "tsx")
        XCTAssertEqual(EditorLanguage.named("sh")?.id, "bash")
        XCTAssertEqual(EditorLanguage.named("markdown.inline")?.id, "markdown_inline")
        XCTAssertNil(EditorLanguage.language(for: URL(fileURLWithPath: "/r/notes.xyz")))
    }
}
