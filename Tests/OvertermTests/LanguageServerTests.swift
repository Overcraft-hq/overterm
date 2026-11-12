import XCTest

@testable import Overterm

/// What servers answer, decoded; text edits applied in UTF-16; finding a
/// server and its root; and a whole session with a fake server
/// (Fixtures/fake-lsp.py): requests, diagnostics, timeouts, a crash.
final class LanguageServerTests: XCTestCase {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    private func range(_ l1: Int, _ c1: Int, _ l2: Int, _ c2: Int) -> LSP.Range {
        LSP.Range(start: LSP.Position(line: l1, character: c1), end: LSP.Position(line: l2, character: c2))
    }

    // MARK: - Decoding

    func testCompletionListAndArrayAndNull() throws {
        // gopls: a CompletionList with plain TextEdits.
        let list = try decode(
            LSP.CompletionList.self,
            """
            {"isIncomplete":true,"items":[{"label":"Println","kind":3,"detail":"func(a ...any) (n int, err error)",
            "documentation":"Println formats.","sortText":"00000","filterText":"Println","insertTextFormat":2,
            "textEdit":{"range":{"start":{"line":5,"character":5},"end":{"line":5,"character":7}},"newText":"Println(${1:})"}}]}
            """)
        XCTAssertTrue(list.isIncomplete)
        let item = try XCTUnwrap(list.items.first)
        XCTAssertEqual(item.label, "Println")
        XCTAssertEqual(item.kind, 3)
        XCTAssertEqual(item.documentation, "Println formats.")
        XCTAssertTrue(item.isSnippet)
        XCTAssertEqual(item.textEdit, LSP.TextEdit(range: range(5, 5, 5, 7), newText: "Println(${1:})"))
        XCTAssertEqual(item.text, "Println(${1:})")
        XCTAssertEqual(item.sortText, "00000")

        // A bare array; one item without a label is dropped, not the list.
        let array = try decode(LSP.CompletionList.self, #"[{"label":"a","insertText":"a()"},{"kind":1},{"label":"b"}]"#)
        XCTAssertEqual(array.items.map(\.label), ["a", "b"])
        XCTAssertEqual(array.items[0].text, "a()")
        XCTAssertEqual(array.items[1].text, "b")
        XCTAssertFalse(array.isIncomplete)

        XCTAssertTrue(try decode(LSP.CompletionList.self, "null").items.isEmpty)
    }

    func testInsertReplaceEditUsesTheInsertRangeAndMarkupDocumentation() throws {
        // vtsls / rust-analyzer shape.
        let list = try decode(
            LSP.CompletionList.self,
            """
            {"isIncomplete":false,"items":[{"label":"useState","kind":3,
            "documentation":{"kind":"markdown","value":"Returns a **stateful** value."},
            "textEdit":{"newText":"useState","insert":{"start":{"line":0,"character":9},"end":{"line":0,"character":12}},
            "replace":{"start":{"line":0,"character":9},"end":{"line":0,"character":15}}},
            "additionalTextEdits":[{"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":0}},"newText":"import x\\n"}],
            "data":{"opaque":[1,2,3]}}]}
            """)
        let item = try XCTUnwrap(list.items.first)
        XCTAssertEqual(item.textEdit?.range, range(0, 9, 0, 12))
        XCTAssertEqual(item.documentation, "Returns a **stateful** value.")
        XCTAssertEqual(item.additionalTextEdits, [LSP.TextEdit(range: range(0, 0, 0, 0), newText: "import x\n")])
        XCTAssertFalse(item.isSnippet)
    }

    func testLocationsLinksSingleAndNull() throws {
        let links = try decode(
            LSP.Locations.self,
            """
            [{"originSelectionRange":{"start":{"line":1,"character":1},"end":{"line":1,"character":4}},
            "targetUri":"file:///Users/me/My%20Project/main.go",
            "targetRange":{"start":{"line":10,"character":0},"end":{"line":20,"character":1}},
            "targetSelectionRange":{"start":{"line":10,"character":5},"end":{"line":10,"character":9}}}]
            """)
        XCTAssertEqual(links.items, [LSP.Location(url: URL(fileURLWithPath: "/Users/me/My Project/main.go"), range: range(10, 5, 10, 9))])

        let single = try decode(
            LSP.Locations.self, #"{"uri":"file:///a/b.rs","range":{"start":{"line":2,"character":0},"end":{"line":2,"character":3}}}"#)
        XCTAssertEqual(single.items.map(\.url.path), ["/a/b.rs"])

        let many = try decode(
            LSP.Locations.self,
            #"[{"uri":"file:///a.ts","range":{"start":{"line":0,"character":0},"end":{"line":0,"character":1}}},{"bogus":true}]"#)
        XCTAssertEqual(many.items.count, 1)
        XCTAssertTrue(try decode(LSP.Locations.self, "null").items.isEmpty)
        XCTAssertTrue(try decode(LSP.Locations.self, "[]").items.isEmpty)
    }

    func testHoverContentsInEveryShape() throws {
        let markup = try decode(
            LSP.Hover.self,
            #"{"contents":{"kind":"markdown","value":"```go\nfunc main()\n```"},"range":{"start":{"line":0,"character":5},"end":{"line":0,"character":9}}}"#
        )
        XCTAssertEqual(markup.contents, "```go\nfunc main()\n```")
        XCTAssertEqual(markup.range, range(0, 5, 0, 9))

        let marked = try decode(LSP.Hover.self, #"{"contents":[{"language":"python","value":"def f(x)"},"","Docs here."]}"#)
        XCTAssertEqual(marked.contents, "```python\ndef f(x)\n```\n\nDocs here.")
        XCTAssertNil(marked.range)

        XCTAssertEqual(try decode(LSP.Hover.self, #"{"contents":"plain *markdown*"}"#).contents, "plain *markdown*")
        XCTAssertEqual(try decode(LSP.Hover.self, #"{"contents":{"language":"rust","value":"fn x()"}}"#).contents, "```rust\nfn x()\n```")
        XCTAssertEqual(try decode(LSP.Hover.self, #"{"contents":{"kind":"plaintext","value":"int x"}}"#).contents, "int x")
        XCTAssertNil(try decode(LSP.Hover?.self, "null"))
    }

    func testDocumentSymbolsFlattenWithDepth() throws {
        let symbols = try decode(
            LSP.Symbols.self,
            """
            [{"name":"Server","kind":23,"detail":"struct","range":{"start":{"line":0,"character":0},"end":{"line":9,"character":1}},
            "selectionRange":{"start":{"line":0,"character":5},"end":{"line":0,"character":11}},
            "children":[{"name":"start","kind":6,"range":{"start":{"line":2,"character":1},"end":{"line":4,"character":1}},
            "selectionRange":{"start":{"line":2,"character":6},"end":{"line":2,"character":11}},
            "children":[{"name":"inner","kind":13,"range":{"start":{"line":3,"character":2},"end":{"line":3,"character":9}},
            "selectionRange":{"start":{"line":3,"character":2},"end":{"line":3,"character":7}}}]}]},
            {"name":"main","kind":12,"range":{"start":{"line":11,"character":0},"end":{"line":13,"character":1}},
            "selectionRange":{"start":{"line":11,"character":5},"end":{"line":11,"character":9}}}]
            """)
        XCTAssertEqual(symbols.items.map(\.name), ["Server", "start", "inner", "main"])
        XCTAssertEqual(symbols.items.map(\.depth), [0, 1, 2, 0])
        XCTAssertEqual(symbols.items[0].detail, "struct")
        XCTAssertEqual(symbols.items[1].selectionRange, range(2, 6, 2, 11))
    }

    func testSymbolInformationIsSortedFlat() throws {
        let symbols = try decode(
            LSP.Symbols.self,
            """
            [{"name":"b","kind":12,"containerName":"x","location":{"uri":"file:///f.sh","range":{"start":{"line":8,"character":0},"end":{"line":9,"character":1}}}},
            {"name":"a","kind":12,"location":{"uri":"file:///f.sh","range":{"start":{"line":2,"character":0},"end":{"line":4,"character":1}}}}]
            """)
        XCTAssertEqual(symbols.items.map(\.name), ["a", "b"])
        XCTAssertEqual(symbols.items.map(\.depth), [0, 0])
        XCTAssertEqual(symbols.items[0].selectionRange, range(2, 0, 4, 1))
        XCTAssertTrue(try decode(LSP.Symbols.self, "null").items.isEmpty)
    }

    func testDiagnosticsCodesAndSeverity() throws {
        let published = try decode(
            LSP.PublishDiagnostics.self,
            """
            {"uri":"file:///p/a%20b.py","version":3,"diagnostics":[
            {"range":{"start":{"line":1,"character":0},"end":{"line":1,"character":4}},"severity":1,"code":"reportUndefinedVariable",
            "codeDescription":{"href":"https://x"},"source":"basedpyright","message":"\\"foo\\" is not defined"},
            {"range":{"start":{"line":2,"character":0},"end":{"line":2,"character":1}},"code":2304,"message":"Cannot find name"},
            {"message":"no range"}]}
            """)
        XCTAssertEqual(published.url, URL(fileURLWithPath: "/p/a b.py"))
        XCTAssertEqual(published.version, 3)
        XCTAssertEqual(published.diagnostics.count, 2)
        XCTAssertEqual(published.diagnostics[0].code, "reportUndefinedVariable")
        XCTAssertEqual(published.diagnostics[0].level, .error)
        XCTAssertEqual(published.diagnostics[0].source, "basedpyright")
        XCTAssertEqual(published.diagnostics[1].code, "2304")
        XCTAssertNil(published.diagnostics[1].severity)
        XCTAssertEqual(published.diagnostics[1].level, .error)
    }

    func testCapabilitiesInTheirShapes() {
        let numeric = LanguageServer.Capabilities(json: [
            "textDocumentSync": 2, "hoverProvider": true, "definitionProvider": ["workDoneProgress": true],
            "completionProvider": ["triggerCharacters": ["."]], "referencesProvider": false,
        ])
        XCTAssertEqual(numeric.textDocumentSync, 2)
        XCTAssertTrue(numeric.openClose)
        XCTAssertTrue(numeric.hover)
        XCTAssertTrue(numeric.definition)
        XCTAssertFalse(numeric.references)
        XCTAssertFalse(numeric.formatting)
        XCTAssertEqual(numeric.completionTriggerCharacters, ["."])

        let object = LanguageServer.Capabilities(json: ["textDocumentSync": ["openClose": true, "change": 1, "save": true]])
        XCTAssertEqual(object.textDocumentSync, 1)
        XCTAssertTrue(object.save)
        XCTAssertFalse(object.saveIncludesText)
        XCTAssertFalse(object.completion)
    }

    func testURIsRoundTripWithSpacesAndUnicode() {
        let url = URL(fileURLWithPath: "/Users/me/Çalışma Alanı/a#b.go")
        let uri = LSP.uri(for: url)
        XCTAssertTrue(uri.hasPrefix("file:///Users/me/"))
        XCTAssertFalse(uri.contains(" "))
        XCTAssertEqual(LSP.url(fromURI: uri), url)
        // A directory gets no trailing slash.
        XCTAssertFalse(LSP.uri(for: FileManager.default.temporaryDirectory).hasSuffix("/"))
    }

    // MARK: - Text edits

    func testEditsApplyFromTheEndBackwards() {
        let text = "let a = 1\nlet b = 2\n"
        let edits = [
            LSP.TextEdit(range: range(0, 4, 0, 5), newText: "alpha"),
            LSP.TextEdit(range: range(1, 4, 1, 5), newText: "beta"),
            LSP.TextEdit(range: range(0, 8, 1, 3), newText: "1;\nvar"),
        ]
        XCTAssertEqual(LSP.apply(edits, to: text), "let alpha = 1;\nvar beta = 2\n")
    }

    func testInsertsAtOnePlaceKeepTheirOrder() {
        let edits = [
            LSP.TextEdit(range: range(0, 0, 0, 0), newText: "A"),
            LSP.TextEdit(range: range(0, 0, 0, 0), newText: "B"),
        ]
        XCTAssertEqual(LSP.apply(edits, to: "x"), "ABx")
    }

    func testEditsCountUTF16AndCRLF() {
        // 🎉 is two UTF-16 units; ü one.
        let text = "a🎉b\r\nüx\r\n"
        XCTAssertEqual(LSP.apply([LSP.TextEdit(range: range(0, 3, 0, 4), newText: "B")], to: text), "a🎉B\r\nüx\r\n")
        XCTAssertEqual(LSP.apply([LSP.TextEdit(range: range(1, 1, 1, 2), newText: "y")], to: text), "a🎉b\r\nüy\r\n")
        // Past a line's end clamps to it (before \r\n); past the last line, the end.
        XCTAssertEqual(LSP.apply([LSP.TextEdit(range: range(1, 50, 1, 50), newText: "!")], to: text), "a🎉b\r\nüx!\r\n")
        XCTAssertEqual(LSP.apply([LSP.TextEdit(range: range(9, 0, 9, 0), newText: "end")], to: text), "a🎉b\r\nüx\r\nend")
    }

    func testFormattingAWholeDocument() {
        let text = "func main() {\n  x()\n}"
        let edit = LSP.TextEdit(range: range(0, 0, 3, 0), newText: "func main() {\n\tx()\n}\n")
        XCTAssertEqual(LSP.apply([edit], to: text), "func main() {\n\tx()\n}\n")
        XCTAssertEqual(LSP.apply([], to: text), text)
    }

    func testOffsetsAndPositions() {
        let text = "a🎉\nbc\rd" as NSString
        XCTAssertEqual(LSP.lineStarts(in: text), [0, 4, 7])
        XCTAssertEqual(LSP.offset(of: LSP.Position(line: 1, character: 1), in: text), 5)
        XCTAssertEqual(LSP.position(ofOffset: 5, in: text), LSP.Position(line: 1, character: 1))
        XCTAssertEqual(LSP.position(ofOffset: 8, in: text), LSP.Position(line: 2, character: 1))
        XCTAssertEqual(LSP.position(ofOffset: 0, in: text), LSP.Position(line: 0, character: 0))
        XCTAssertEqual(LSP.position(ofOffset: 4, in: text), LSP.Position(line: 1, character: 0))
        XCTAssertEqual(LSP.nsRange(of: range(0, 1, 0, 3), in: text), NSRange(location: 1, length: 2))
        XCTAssertEqual(LSP.offset(of: LSP.Position(line: 0, character: 0), in: "" as NSString), 0)
    }

    // MARK: - Finding a server

    func testLanguageIDs() {
        func id(_ name: String) -> String? { LanguageServers.languageID(for: URL(fileURLWithPath: "/p/\(name)")) }
        XCTAssertEqual(id("main.go"), "go")
        XCTAssertEqual(id("a.ts"), "typescript")
        XCTAssertEqual(id("a.tsx"), "typescriptreact")
        XCTAssertEqual(id("a.mjs"), "javascript")
        XCTAssertEqual(id("a.jsx"), "javascriptreact")
        XCTAssertEqual(id("a.py"), "python")
        XCTAssertEqual(id("lib.rs"), "rust")
        XCTAssertEqual(id("App.swift"), "swift")
        XCTAssertEqual(id("x.c"), "c")
        XCTAssertEqual(id("x.cpp"), "cpp")
        XCTAssertEqual(id("x.m"), "objective-c")
        XCTAssertEqual(id("package.json"), "json")
        XCTAssertEqual(id("tsconfig.json"), "jsonc")
        XCTAssertEqual(id("a.JSONC"), "jsonc")
        XCTAssertEqual(id("ci.yml"), "yaml")
        XCTAssertEqual(id("build.sh"), "shellscript")
        XCTAssertEqual(id(".zshrc"), "shellscript")
        XCTAssertNil(id("README.md"))
        XCTAssertNil(id("Makefile"))
        XCTAssertEqual(LanguageServers.spec(for: URL(fileURLWithPath: "/p/a.tsx"))?.id, "typescript")
        XCTAssertEqual(LanguageServers.spec(for: URL(fileURLWithPath: "/p/a.h"))?.id, "c")
    }

    func testRootIsTheNearestMarkerElseTheCheckoutElseTheFolder() throws {
        let base = try scratch()
        let repo = base.appendingPathComponent("repo")
        try mkdir(repo.appendingPathComponent(".git"))
        try mkdir(repo.appendingPathComponent("svc/pkg"))
        try mkdir(repo.appendingPathComponent("web"))
        try mkdir(base.appendingPathComponent("loose"))
        try Data().write(to: repo.appendingPathComponent("svc/go.mod"))

        let go = ["go.work", "go.mod"]
        XCTAssertEqual(LanguageServers.root(for: repo.appendingPathComponent("svc/pkg/a.go"), markers: go).path, repo.appendingPathComponent("svc").path)
        XCTAssertEqual(LanguageServers.root(for: repo.appendingPathComponent("web/x.go"), markers: go).path, repo.path)
        XCTAssertEqual(LanguageServers.root(for: repo.appendingPathComponent("web/x.yml"), markers: []).path, repo.path)
        XCTAssertEqual(LanguageServers.root(for: base.appendingPathComponent("loose/a.sh"), markers: []).path, base.appendingPathComponent("loose").path)
    }

    func testDiscoveryLooksInTheSearchDirectoriesThenZed() throws {
        let home = try scratch()
        let bin = home.appendingPathComponent("bin")
        try mkdir(bin)
        let zed = home.appendingPathComponent("Library/Application Support/Zed")
        let gopls = zed.appendingPathComponent("languages/gopls")
        try mkdir(gopls.appendingPathComponent("gobin"))
        try executable(gopls.appendingPathComponent("gopls_0.9.0_go_1.20"))
        try executable(gopls.appendingPathComponent("gopls_0.23.0_go_1.27.0"))
        try executable(gopls.appendingPathComponent("gopls_0.16.0_go_1.22"))
        let discovery = ServerDiscovery(home: home, searchDirectories: [bin], toolchainDirectories: [], runsXcrun: false)
        let goSpec = try XCTUnwrap(LanguageServers.specs.first { $0.id == "go" })
        XCTAssertEqual(discovery.command(for: goSpec)?.executable.lastPathComponent, "gopls_0.23.0_go_1.27.0")
        // One on the search path wins over Zed's, and gets the search path on its PATH.
        try executable(bin.appendingPathComponent("gopls"))
        let found = try XCTUnwrap(discovery.command(for: goSpec))
        XCTAssertEqual(found.executable.path, bin.appendingPathComponent("gopls").path)
        XCTAssertTrue(found.environment["PATH"]?.hasPrefix(bin.path + ":") ?? false)

        // A Zed node script, run with Zed's node when there is no other.
        let tsSpec = try XCTUnwrap(LanguageServers.specs.first { $0.id == "typescript" })
        XCTAssertNil(discovery.command(for: tsSpec))
        let script = zed.appendingPathComponent("languages/vtsls/node_modules/@vtsls/language-server/bin/vtsls.js")
        try mkdir(script.deletingLastPathComponent())
        try Data().write(to: script)
        XCTAssertNil(discovery.command(for: tsSpec), "a script without node")
        let node = zed.appendingPathComponent("node/node-v22.5.1-darwin-arm64/bin/node")
        try mkdir(node.deletingLastPathComponent())
        try executable(node)
        let ts = try XCTUnwrap(discovery.command(for: tsSpec))
        XCTAssertEqual(ts.executable.path, node.path)
        XCTAssertEqual(ts.arguments, [script.path, "--stdio"])

        // An override is taken as is.
        let pinned = LanguageServer.Command(executable: URL(fileURLWithPath: "/x/gopls"))
        XCTAssertEqual(ServerDiscovery(home: home, overrides: ["go": pinned], searchDirectories: []).command(for: goSpec), pinned)
    }

    func testARustupProxyWithoutRustAnalyzerIsNotAServer() throws {
        let home = try scratch()
        let cargo = home.appendingPathComponent(".cargo/bin")
        try mkdir(cargo)
        try executable(cargo.appendingPathComponent("rustup"))
        try FileManager.default.createSymbolicLink(at: cargo.appendingPathComponent("rust-analyzer"), withDestinationURL: cargo.appendingPathComponent("rustup"))
        let discovery = ServerDiscovery(home: home, searchDirectories: [cargo], toolchainDirectories: [], runsXcrun: false)
        let rust = try XCTUnwrap(LanguageServers.specs.first { $0.id == "rust" })
        XCTAssertNil(discovery.command(for: rust))
        let toolchain = home.appendingPathComponent(".rustup/toolchains/stable-aarch64-apple-darwin/bin")
        try mkdir(toolchain)
        try executable(toolchain.appendingPathComponent("rust-analyzer"))
        XCTAssertEqual(discovery.command(for: rust)?.executable.lastPathComponent, "rust-analyzer")
    }

    func testZedsTerraformLSTheNewestVersion() throws {
        let home = try scratch()
        let work = home.appendingPathComponent("Library/Application Support/Zed/extensions/work/terraform")
        let spec = LanguageServers.Spec(
            id: "terraform", extensions: ["tf": "terraform"], launch: [.executable("terraform-ls", ["serve"]), .zedTerraformLS])
        let discovery = ServerDiscovery(home: home, searchDirectories: [home.appendingPathComponent("bin")], toolchainDirectories: [], runsXcrun: false)
        XCTAssertNil(discovery.command(for: spec), "none installed, none downloaded")
        for version in ["terraform-ls-0.9.0", "terraform-ls-v0.36.4", "terraform-ls-0.34.2"] {
            try mkdir(work.appendingPathComponent(version))
            try executable(work.appendingPathComponent("\(version)/terraform-ls"))
        }
        // A newer folder without its binary (a download cut short) is passed over.
        try mkdir(work.appendingPathComponent("terraform-ls-0.40.0"))
        let found = try XCTUnwrap(discovery.command(for: spec))
        XCTAssertEqual(found.executable.path, work.appendingPathComponent("terraform-ls-v0.36.4/terraform-ls").path)
        XCTAssertEqual(found.arguments, ["serve"])
        // One on the search path comes first.
        try mkdir(home.appendingPathComponent("bin"))
        try executable(home.appendingPathComponent("bin/terraform-ls"))
        XCTAssertEqual(discovery.command(for: spec)?.executable.path, home.appendingPathComponent("bin/terraform-ls").path)
    }

    func testRemovedNamesWinOverTheAppsAndTheCommands() {
        let environment = LanguageServer.environment(
            ["PATH": "/usr/bin", "AWS_PROFILE": "acme-prod", "AWS_SECRET_ACCESS_KEY": "acme-hunter2-SECRET", "TF_LOG": "trace", "HOME": "/Users/acme"],
            adding: ["PATH": "/opt/homebrew/bin:/usr/bin", "TF_LOG": "debug", "ACME_TOKEN": "tok-acme-123"],
            removing: ["AWS_*", "TF_LOG", "ACME_TOKEN"])
        XCTAssertEqual(environment, ["PATH": "/opt/homebrew/bin:/usr/bin", "HOME": "/Users/acme"])
        XCTAssertEqual(LanguageServer.environment(["A": "1"], adding: ["B": "2"], removing: []), ["A": "1", "B": "2"])
        // The spec's variables over the app's and the command's; a removed
        // name still wins over them.
        let set = LanguageServer.environment(
            ["PATH": "/usr/bin", "HOME": "/Users/acme", "CHECKPOINT_DISABLE": "", "AWS_PROFILE": "acme-prod"],
            adding: ["HOME": "/Users/globex"],
            setting: ["HOME": "/private/tmp/acme-scratch", "CHECKPOINT_DISABLE": "1", "AWS_REGION": "eu-west-1", "TF_LOG": "trace"],
            removing: ["AWS_*", "TF_LOG"])
        XCTAssertEqual(set, ["PATH": "/usr/bin", "HOME": "/private/tmp/acme-scratch", "CHECKPOINT_DISABLE": "1"])
    }

    func testSpecsAreKeysWithTheirOptions() {
        let plain = LanguageServers.Spec(id: "terraform", extensions: ["tf": "terraform"], launch: [.zedTerraformLS])
        var options = plain
        options.initializationOptions = ["experimentalFeatures": ["validateOnSave": false]]
        options.environmentRemoved = ["AWS_*"]
        XCTAssertNotEqual(plain, options)
        var added = options
        added.environmentAdded = ["CHECKPOINT_DISABLE": "1"]
        XCTAssertNotEqual(added, options)
        XCTAssertEqual(Set([plain, options, options, added]).count, 3)
        XCTAssertTrue(
            LanguageServers.specs.filter { $0.id != "terraform" }.allSatisfy {
                $0.initializationOptions == nil && $0.environmentAdded.isEmpty && $0.environmentRemoved.isEmpty
            })
    }

    /// terraform-ls (analysis 4.14): its files, its validate on save off, and
    /// what it and the `terraform validate` it runs never get — a hostile
    /// shell's credentials, the variables that inject flags or log values —
    /// with a scratch HOME and CLI config, and no call home.
    func testTerraformLSSpec() throws {
        func id(_ name: String) -> String? { LanguageServers.languageID(for: URL(fileURLWithPath: "/acme/envs/dev/\(name)")) }
        XCTAssertEqual(id("main.tf"), "terraform")
        XCTAssertEqual(id("prod.tfvars"), "terraform-vars")
        XCTAssertEqual(id("main.tofu"), "opentofu")
        XCTAssertNil(id(".terraform.lock.hcl"))
        XCTAssertNil(id("terragrunt.hcl"))
        XCTAssertEqual(id("main.tf.json"), "json")
        let spec = try XCTUnwrap(LanguageServers.specs.first { $0.id == "terraform" })
        XCTAssertEqual(spec.rootMarkers, [], "rooted at the checkout's top: one server a worktree")
        XCTAssertEqual(spec.launch, [.executable("terraform-ls", ["serve"]), .zedTerraformLS])
        guard case .object(let options)? = spec.initializationOptions, case .object(let features)? = options["experimentalFeatures"] else {
            return XCTFail("initializationOptions: \(String(describing: spec.initializationOptions))")
        }
        XCTAssertEqual(features["validateOnSave"], .bool(false))
        let hostile = [
            "PATH": "/usr/bin", "HOME": "/Users/acme", "AWS_PROFILE": "acme-prod-admin", "AWS_SECRET_ACCESS_KEY": "acme-hunter2-SECRET",
            "GOOGLE_APPLICATION_CREDENTIALS": "/Users/acme/key.json", "ARM_CLIENT_SECRET": "globex-BKPW", "TF_TOKEN_app_terraform_io": "tok-acme-123",
            "GITHUB_TOKEN": "tok-acme-123", "ACME_CLIENT_SECRET_ID": "x", "KUBECONFIG": "/Users/acme/.kube/config",
            "TF_CLI_ARGS_apply": "-auto-approve", "TF_CLI_ARGS": "-lock=false", "TF_LOG": "trace", "TF_LOG_PATH": "/tmp/acme.log",
            "TF_REATTACH_PROVIDERS": "{}", "TF_WORKSPACE": "acme-prod", "TF_DATA_DIR": "/tmp/acme", "TF_VAR_db_password": "acme-hunter2-SECRET",
            "TF_CLI_CONFIG_FILE": "/Users/acme/.terraformrc", "LANG": "en_US.UTF-8",
            "KUBE_CONFIG_PATH": "/Users/acme/.kube/acme-prod", "KUBE_CTX": "acme-prod", "KUBE_CLIENT_KEY_DATA": "acme-hunter2-SECRET",
            "KUBE_HOST": "https://acme-prod.example", "HELM_KUBETOKEN": "tok-acme-123",
            "aws_secret_access_key": "acme-hunter2-SECRET", "vault_token": "tok-acme-123", "acme_client_secret": "globex-BKPW",
        ]
        let environment = LanguageServer.environment(hostile, adding: [:], setting: spec.environmentAdded, removing: spec.environmentRemoved)
        let scratch = AppEnvironment.terraformScratchDirectory
        XCTAssertEqual(environment["HOME"], scratch.appendingPathComponent("home").path)
        XCTAssertEqual(environment["TF_CLI_CONFIG_FILE"], scratch.appendingPathComponent("terraformrc").path)
        XCTAssertEqual(environment["CHECKPOINT_DISABLE"], "1")
        XCTAssertEqual(Set(environment.keys), ["PATH", "HOME", "LANG", "CHECKPOINT_DISABLE", "TF_CLI_CONFIG_FILE"])
        XCTAssertEqual(
            Set(hostile.keys.filter(TerraformGuards.isCredential)).intersection(environment.keys), [], "the same names validate's environment loses")
        // terraform.path: the terraform Overterm runs, added at launch.
        guard case .object(let launched)? = LanguageServers.launchOptions(spec, terraformPath: "/opt/acme/bin/terraform") else {
            return XCTFail("launch options")
        }
        XCTAssertEqual(launched["terraform"], .object(["path": .string("/opt/acme/bin/terraform")]))
        XCTAssertEqual(launched["experimentalFeatures"], options["experimentalFeatures"])
        XCTAssertNotNil(launched["indexing"])
        XCTAssertEqual(LanguageServers.launchOptions(spec, terraformPath: nil), spec.initializationOptions)
        let go = try XCTUnwrap(LanguageServers.specs.first { $0.id == "go" })
        XCTAssertNil(LanguageServers.launchOptions(go, terraformPath: "/opt/acme/bin/terraform"), "only terraform-ls is told")
    }

    func testRemovalPatterns() {
        XCTAssertTrue(LanguageServer.pattern("AWS_*", matches: "AWS_PROFILE"))
        XCTAssertFalse(LanguageServer.pattern("AWS_*", matches: "MY_AWS_PROFILE"))
        XCTAssertTrue(LanguageServer.pattern("*_TOKEN", matches: "GITHUB_TOKEN"))
        XCTAssertFalse(LanguageServer.pattern("*_TOKEN", matches: "GITHUB_TOKEN_PATH"))
        XCTAssertTrue(LanguageServer.pattern("*_SECRET*", matches: "ACME_SECRET_ID"))
        XCTAssertTrue(LanguageServer.pattern("TF_LOG", matches: "TF_LOG"))
        XCTAssertFalse(LanguageServer.pattern("TF_LOG", matches: "TF_LOG_PATH"))
        XCTAssertFalse(LanguageServer.pattern("*", matches: "PATH"), "a lone star removes nothing")
        XCTAssertTrue(LanguageServer.pattern("AWS_*", matches: "aws_secret_access_key"), "a name in lower case too")
        XCTAssertTrue(LanguageServer.pattern("*_TOKEN", matches: "vault_token"))
    }

    @MainActor
    func testServerNamesWithoutVersions() {
        XCTAssertEqual(EditorViewController.displayName(ofServer: "gopls_0.23.0_go_1.27.0"), "gopls")
        XCTAssertEqual(EditorViewController.displayName(ofServer: "vtsls.js"), "vtsls")
        XCTAssertEqual(EditorViewController.displayName(ofServer: "rust-analyzer"), "rust-analyzer")
        XCTAssertEqual(EditorViewController.displayName(ofServer: "basedpyright-langserver"), "basedpyright-langserver")
    }

    @MainActor
    func testATestProcessNeverLaunchesRealServers() {
        XCTAssertFalse(LanguageServers.mayLaunchRealServers)
        XCTAssertNil(LanguageServers().server(for: URL(fileURLWithPath: "/tmp/x/main.go")))
    }

    // MARK: - A session with the fake server

    private var started: [LanguageServer] = []

    override func tearDown() {
        // stop() kills only the process it started.
        for server in started { server.stop() }
        started = []
        super.tearDown()
    }

    private struct Fake {
        let server: LanguageServer
        let log: URL
        let file: URL
        var logText: String { (try? String(contentsOf: log, encoding: .utf8)) ?? "" }
    }

    private static let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/fake-lsp.py")

    private func fakeCommand(log: URL, watch: Bool = false, environment: [String: String] = [:]) -> LanguageServer.Command {
        LanguageServer.Command(
            executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: [Self.script.path, log.path] + (watch ? ["watch"] : []),
            environment: environment)
    }

    private func fake() throws -> Fake {
        let dir = try scratch()
        let log = dir.appendingPathComponent("log.txt")
        let server = LanguageServer(name: "fake", command: fakeCommand(log: log), root: dir)
        started.append(server)
        return Fake(server: server, log: log, file: dir.appendingPathComponent("main.go"))
    }

    /// Two windows share a server: one closing the file keeps it open for
    /// the other, and its versions keep rising whoever counts lower.
    @MainActor
    func testTwoEditorsShareADocument() async throws {
        let fake = try fake()
        let server = fake.server
        try server.start()
        _ = try await server.waitUntilReady()
        server.didOpen(fake.file, languageID: "go", version: 5, text: "package a\n")
        server.didOpen(fake.file, languageID: "go", version: 1, text: "package b\n")
        server.didClose(fake.file)
        server.didChange(fake.file, version: 2, text: "package c\n")
        try await Self.eventually { fake.logText.contains("package c") }
        var log = fake.logText
        XCTAssertEqual(log.components(separatedBy: "textDocument/didOpen").count - 1, 1, log)
        XCTAssertFalse(log.contains("textDocument/didClose"), "the other editor still has it: \(log)")
        XCTAssertTrue(log.contains("change 6 [{\"text\": \"package b\\n\"}]"), log)
        XCTAssertTrue(log.contains("change 7 [{\"text\": \"package c\\n\"}]"), log)
        server.didClose(fake.file)
        try await Self.eventually { fake.logText.contains("textDocument/didClose") }
        log = fake.logText
        XCTAssertEqual(log.components(separatedBy: "textDocument/didClose").count - 1, 1, log)
    }

    @MainActor
    func testAWholeSession() async throws {
        let fake = try fake()
        let server = fake.server
        var published: [(URL, [LSP.Diagnostic])] = []
        server.onDiagnostics = { published.append(($0, $1)) }
        try server.start()
        // Opened while it initializes: sent once it has.
        server.didOpen(fake.file, languageID: "go", version: 1, text: "package main\n\tfmt.Pr\n")
        let capabilities = try await server.waitUntilReady()
        XCTAssertEqual(server.state, .running)
        XCTAssertEqual(capabilities.completionTriggerCharacters, [".", ":"])
        XCTAssertEqual(capabilities.textDocumentSync, 2)
        XCTAssertTrue(capabilities.saveIncludesText)

        let list = try await server.completion(fake.file, at: LSP.Position(line: 1, character: 6), trigger: nil)
        XCTAssertTrue(list.isIncomplete)
        XCTAssertEqual(list.items.map(\.label), ["Println", "fmt.Sprintf"])
        XCTAssertEqual(list.items[0].textEdit?.range, range(1, 4, 1, 6))
        XCTAssertTrue(list.items[1].isSnippet)
        XCTAssertEqual(list.items[1].documentation, "Formats **things**.")
        XCTAssertEqual(list.items[1].additionalTextEdits.first?.newText, "import \"fmt\"\n")
        let triggered: [LSP.CompletionItem] = try await server.completion(fake.file, at: LSP.Position(line: 1, character: 5), trigger: ".").items
        XCTAssertEqual(triggered.first?.detail, "trigger=.")

        let hover = try await server.hover(fake.file, at: LSP.Position(line: 1, character: 6))
        XCTAssertEqual(hover?.contents, "```go\nfunc Println(a ...any)\n```\n\nPrints.")
        XCTAssertEqual(hover?.range, range(1, 4, 1, 11))

        let definition = try await server.definition(fake.file, at: LSP.Position(line: 1, character: 6))
        XCTAssertEqual(definition, [LSP.Location(url: URL(fileURLWithPath: "/tmp/fake dir/def.go"), range: range(10, 5, 10, 12))])

        let references = try await server.references(fake.file, at: LSP.Position(line: 1, character: 6))
        XCTAssertEqual(references.map(\.url), [fake.file, fake.file])
        XCTAssertEqual(references.map(\.range.start.line), [1, 3])

        let symbols = try await server.documentSymbols(fake.file)
        XCTAssertEqual(symbols.map(\.name), ["Server", "Start"])
        XCTAssertEqual(symbols.map(\.depth), [0, 1])

        let edits = try await server.formatting(fake.file, tabSize: 4, insertSpaces: false)
        XCTAssertEqual(edits, [LSP.TextEdit(range: range(0, 0, 0, 2), newText: "\t")])

        try await Self.eventually { !published.isEmpty }
        XCTAssertEqual(published[0].0, fake.file)
        XCTAssertEqual(published[0].1.first?.code, "42")
        XCTAssertEqual(published[0].1.first?.level, .warning)
        XCTAssertEqual(published[0].1.first?.message, "unused")

        server.didChange(fake.file, version: 2, text: "package main\n")
        try await Self.eventually { published.count >= 2 }
        XCTAssertEqual(published.last?.1, [])
        server.didSave(fake.file, text: "package main\n")
        server.didClose(fake.file)
        try await Self.eventually { fake.logText.contains("textDocument/didClose") }

        let log = fake.logText
        XCTAssertTrue(log.contains("rootUri \(LSP.uri(for: server.root))\n"), log)
        XCTAssertTrue(log.contains("initialized\n"), log)
        XCTAssertTrue(log.contains("open \(LSP.uri(for: fake.file)) go 1\n"), log)
        XCTAssertTrue(log.contains("response cfg-1 [null, null]\n"), log)
        XCTAssertTrue(log.contains("change 2 [{\"text\": \"package main\\n\"}]\n"), log)
        XCTAssertTrue(log.contains("save package main\n"), log)
        XCTAssertTrue(log.contains("format 4 False\n"), log)
        XCTAssertTrue(server.stderrLines.contains("fake-lsp: started"), "\(server.stderrLines)")
        // initialize must come first, initialized before any document.
        let methods = log.split(separator: "\n").filter { !$0.hasPrefix("rootUri") }
        XCTAssertEqual(methods.prefix(3), ["initialize", "initialized", "textDocument/didOpen"])

        let pid = try XCTUnwrap(server.processIdentifier)
        server.stop()
        XCTAssertEqual(server.state, .stopped)
        XCTAssertTrue(fake.logText.contains("shutdown\n"))
        XCTAssertTrue(fake.logText.contains("exit\n"))
        XCTAssertNil(server.processIdentifier)
        XCTAssertNotEqual(kill(pid, 0), 0, "the server process is gone")
        do {
            _ = try await server.hover(fake.file, at: LSP.Position(line: 0, character: 0))
            XCTFail("a stopped server answered")
        } catch let error as LanguageServerError {
            XCTAssertEqual(error, .notRunning)
        }
    }

    func testARequestTimesOutAndIsCancelledAtTheServer() async throws {
        let fake = try fake()
        try fake.server.start()
        _ = try await fake.server.waitUntilReady()
        let params: JSONValue = ["textDocument": ["uri": .string(LSP.uri(for: fake.file))], "position": ["line": 99, "character": 0]]
        let start = Date()
        do {
            _ = try await fake.server.request("textDocument/hover", params, as: LSP.Hover?.self, timeout: 0.5)
            XCTFail("a request the server never answers returned")
        } catch let error as LanguageServerError {
            XCTAssertEqual(error, .timedOut("textDocument/hover"))
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
        try await Self.eventually { fake.logText.contains("$/cancelRequest") }
        // Still usable.
        let hover = try await fake.server.hover(fake.file, at: LSP.Position(line: 1, character: 0))
        XCTAssertNotNil(hover)
    }

    func testCancellingTheTaskCancelsTheRequest() async throws {
        let fake = try fake()
        try fake.server.start()
        _ = try await fake.server.waitUntilReady()
        let server = fake.server
        let file = fake.file
        let task = Task { try await server.hover(file, at: LSP.Position(line: 99, character: 0)) }
        try await Self.eventually { fake.logText.contains("textDocument/hover") }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("a cancelled request returned")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        try await Self.eventually { fake.logText.contains("$/cancelRequest") }
    }

    /// The server's options and environment as its spec says; then what it
    /// registered is watched — a file written beside it is told to it, under
    /// the root as it was given (not /private/var), created, changed, deleted
    /// — and its death stops the watching.
    @MainActor
    func testWatchedFilesOptionsAndEnvironment() async throws {
        let dir = try scratch()
        let log = dir.appendingPathComponent("log.txt")
        let server = LanguageServer(
            name: "fake",
            command: fakeCommand(log: log, watch: true, environment: ["ACME_TOKEN": "tok-acme-123", "ACME_REGION": "eu-west-1", "AWS_PROFILE": "acme-prod"]),
            root: dir, initializationOptions: ["indexing": ["ignorePaths": ["envs/scratch"]], "experimentalFeatures": ["validateOnSave": false]],
            environmentAdded: [
                "CHECKPOINT_DISABLE": "1", "HOME": dir.appendingPathComponent("scratch-home").path, "AWS_REGION": "eu-west-1",
                "ACME_TOKEN": "tok-acme-456",
            ],
            environmentRemoved: ["ACME_TOKEN", "AWS_*"])
        started.append(server)
        func logText() -> String { (try? String(contentsOf: log, encoding: .utf8)) ?? "" }
        try server.start()
        _ = try await server.waitUntilReady()
        try await Self.eventually { logText().contains("response watch-1 null") }
        let text = logText()
        XCTAssertTrue(text.contains(#"initializationOptions {"experimentalFeatures": {"validateOnSave": false}, "indexing": {"ignorePaths": ["envs/scratch"]}}"#), text)
        XCTAssertTrue(
            text.contains("env ACME_REGION,CHECKPOINT_DISABLE\n"), "the removed names, the app's, the command's and the added, aren't there: \(text)")
        XCTAssertTrue(
            text.contains("envValues CHECKPOINT_DISABLE=1 HOME=\(dir.appendingPathComponent("scratch-home").path)\n"), "the spec's variables are set: \(text)")
        XCTAssertTrue(text.contains(#"watchCapability {"dynamicRegistration": true, "relativePatternSupport": true}"#), text)
        try await Self.eventually { server.watchedFileFolders == [LSPWatchedFiles.realPath(dir.path)] }
        // FSEvents reports only what happens after the stream is live.
        try await Task.sleep(nanoseconds: 300_000_000)

        let module = dir.appendingPathComponent("modules/acme-net")
        try mkdir(module)
        let tf = module.appendingPathComponent("main.tf")
        let go = dir.appendingPathComponent("main.go")
        try Data("package main\n".utf8).write(to: go)
        try Data("variable \"acme\" {}\n".utf8).write(to: tf)
        try Data("notes\n".utf8).write(to: dir.appendingPathComponent("README.md"))
        try await Self.eventually { logText().contains("watched \(LSP.uri(for: go)) 1") }
        try FileManager.default.removeItem(at: tf)
        try await Self.eventually { logText().contains("watched \(LSP.uri(for: tf)) 3") }
        let watched = logText().components(separatedBy: "\n").filter { $0.hasPrefix("watched ") }
        XCTAssertFalse(watched.contains { $0.contains("README.md") }, "\(watched)")
        XCTAssertTrue(watched.contains { $0.hasSuffix("main.tf 1") }, "\(watched)")
        XCTAssertFalse(watched.contains { $0.hasSuffix("main.tf 2") }, "*.tf is registered for creates and deletes only: \(watched)")
        XCTAssertFalse(watched.contains { $0.contains("/private/var/") && !dir.path.hasPrefix("/private/var/") }, "\(watched)")

        // Stopped: nothing watched any more.
        server.stop()
        try await Self.eventually { server.watchedFileFolders.isEmpty }
    }

    /// A folder a server registered outside its root, spelled through a
    /// link (and /var, not /private/var): it is watched at its real path,
    /// and its files are told to the server as the server spelled them.
    @MainActor
    func testAFolderOutsideTheRootIsToldInTheServersSpelling() async throws {
        let dir = try scratch()
        let root = dir.appendingPathComponent("acme-app")
        let library = dir.appendingPathComponent("acme-lib-real")
        let linked = dir.appendingPathComponent("acme-lib")
        try mkdir(root)
        try mkdir(library)
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: library)
        let log = dir.appendingPathComponent("log.txt")
        let server = LanguageServer(
            name: "fake", command: fakeCommand(log: log, watch: true, environment: ["FAKE_LSP_EXTRA_BASE": linked.path]), root: root)
        started.append(server)
        func logText() -> String { (try? String(contentsOf: log, encoding: .utf8)) ?? "" }
        try server.start()
        _ = try await server.waitUntilReady()
        try await Self.eventually { logText().contains("response watch-1 null") }
        let real = LSPWatchedFiles.realPath(library.path)
        XCTAssertNotEqual(real, linked.path)
        try await Self.eventually { server.watchedFileFolders == [LSPWatchedFiles.realPath(root.path), real].sorted() }
        try await Task.sleep(nanoseconds: 300_000_000)

        try Data("x = 1\n".utf8).write(to: library.appendingPathComponent("acme.py"))
        let spelled = LSP.uri(for: URL(fileURLWithPath: linked.path + "/acme.py", isDirectory: false))
        try await Self.eventually { logText().contains("watched \(spelled) 1") }
        XCTAssertFalse(logText().contains("acme-lib-real"), logText())
        server.stop()
        try await Self.eventually { server.watchedFileFolders.isEmpty }
    }

    func testDeathFailsWhatIsPending() async throws {
        let fake = try fake()
        try fake.server.start()
        _ = try await fake.server.waitUntilReady()
        let server = fake.server
        let file = fake.file
        let waiting = Task { try await server.hover(file, at: LSP.Position(line: 99, character: 0)) }
        try await Self.eventually { fake.logText.contains("textDocument/hover") }
        let pid = try XCTUnwrap(server.processIdentifier)
        do {
            _ = try await server.hover(file, at: LSP.Position(line: 666, character: 0))
            XCTFail("a crashing server answered")
        } catch let error as LanguageServerError {
            guard case .exited = error else { return XCTFail("\(error)") }
        }
        do {
            _ = try await waiting.value
            XCTFail("a request pending at the crash returned")
        } catch let error as LanguageServerError {
            guard case .exited = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(server.state, .dead)
        try await Self.eventually { kill(pid, 0) != 0 }
    }

    @MainActor
    func testTheRegistryRestartsADeadServerOnceThenGivesUp() async throws {
        let dir = try scratch()
        try Data().write(to: dir.appendingPathComponent("go.mod"))
        try mkdir(dir.appendingPathComponent("cmd"))
        let file = dir.appendingPathComponent("cmd/main.go")
        let log = dir.appendingPathComponent("log.txt")
        let registry = LanguageServers(discovery: ServerDiscovery(home: dir, searchDirectories: []), launchesRealServers: false)
        registry.discoveryOverride = { [command = fakeCommand(log: log)] spec in spec.id == "go" ? command : nil }
        defer { registry.stopAll() }
        var published: [URL] = []
        registry.onDiagnostics = { url, _ in published.append(url) }

        XCTAssertNil(registry.server(for: dir.appendingPathComponent("a.py")), "no command for python")
        let server = try XCTUnwrap(registry.server(for: file))
        started.append(server)
        XCTAssertTrue(registry.server(for: dir.appendingPathComponent("other.go")) === server, "one server per root")
        XCTAssertEqual(server.root.path, dir.path)
        server.didOpen(file, languageID: "go", version: 7, text: "package main\n")
        _ = try await server.waitUntilReady()
        try await Self.eventually { published == [file] }

        // Crash: the next use restarts it, with the document opened again.
        _ = try? await server.hover(file, at: LSP.Position(line: 666, character: 0))
        try await Self.eventually { server.state == .dead }
        XCTAssertTrue(registry.server(for: file) === server)
        XCTAssertEqual(server.restartCount, 1)
        _ = try await server.waitUntilReady()
        try await Self.eventually {
            (try? String(contentsOf: log, encoding: .utf8))?.components(separatedBy: "open \(LSP.uri(for: file)) go 7").count == 3
        }

        // A second crash: left alone.
        _ = try? await server.hover(file, at: LSP.Position(line: 666, character: 0))
        try await Self.eventually { server.state == .dead }
        XCTAssertNil(registry.server(for: file))
        XCTAssertNil(registry.server(for: dir.appendingPathComponent("x.go")))
        XCTAssertEqual(server.restartCount, 1)
    }

    // MARK: - Helpers

    private struct NeverHappened: Error {}

    private static func eventually(
        timeout: TimeInterval = 5, file: StaticString = #filePath, line: UInt = #line, _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while await !condition() {
            if Date() > deadline {
                XCTFail("never happened", file: file, line: line)
                throw NeverHappened()
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lsp-\(UUID().uuidString)")
        try mkdir(dir)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func mkdir(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    private func executable(_ url: URL) throws {
        try Data("#!/bin/sh\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
}
