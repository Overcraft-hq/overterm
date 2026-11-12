import XCTest

@testable import Overterm

/// LSP's glob patterns, and the watched files each server asks for: what it
/// registers once the client says it can watch (`dynamicRegistration`), and
/// which file events reach it then.
///
/// The registrations are the servers' own: gopls v0.21.1 and sourcekit-lsp
/// (Xcode 27.2) captured from the real servers on 2026-11-12, clangd (Apple
/// clangd 21) registering nothing; rust-analyzer's as its `reload.rs` builds
/// them; pyright's as its `languageServerBase.ts` builds them and vtsls's as
/// VS Code's TypeScript `fileWatchingManager` asks for tsserver's watches
/// (neither installed here, nothing downloaded to capture them);
/// terraform-ls's (not installed here) modelled on what #953 has it rely on
/// the client for — its files, the init's records, a folder gone.
final class LSPWatchedFilesTests: XCTestCase {
    private func glob(_ pattern: String, base: String? = nil) throws -> LSPGlob {
        try XCTUnwrap(LSPGlob(pattern, base: base), pattern)
    }

    // MARK: - Globs

    func testStarsQuestionMarksAndGlobstars() throws {
        let go = try glob("**/*.go")
        XCTAssertTrue(go.matches("/acme/api/main.go"))
        XCTAssertTrue(go.matches("/main.go"))
        XCTAssertFalse(go.matches("/acme/api/main.go.orig"))
        XCTAssertFalse(go.matches("/acme/api/maingo"), "the dot is literal")

        let star = try glob("*.go")
        XCTAssertFalse(star.matches("/acme/api/main.go"), "* stays in one segment")
        XCTAssertTrue(star.matches("/acme/api/main.go", root: "/acme/api"), "a relative pattern is below the root")
        XCTAssertFalse(star.matches("/acme/api/cmd/main.go", root: "/acme/api"))

        let question = try glob("**/v?.tf")
        XCTAssertTrue(question.matches("/acme/v1.tf"))
        XCTAssertFalse(question.matches("/acme/v10.tf"))
        XCTAssertFalse(try glob("a?b").matches("a/b", root: nil), "? is not a slash")

        let all = try glob("**")
        XCTAssertTrue(all.matches("/anything/at/all"))
        let everything = try glob("**/*")
        XCTAssertTrue(everything.matches("/acme/.terraform/environment"))

        let folder = try glob("/acme/envs/**")
        XCTAssertTrue(folder.matches("/acme/envs"), "dir/** is the folder itself too")
        XCTAssertTrue(folder.matches("/acme/envs/prod/main.tf"))
        XCTAssertFalse(folder.matches("/acme/envs-old/main.tf"))

        let middle = try glob("/acme/**/modules.json")
        XCTAssertTrue(middle.matches("/acme/modules.json"), "**/ is no folder too")
        XCTAssertTrue(middle.matches("/acme/envs/prod/.terraform/modules/modules.json"))
    }

    func testBracesAndClasses() throws {
        let gopls = try glob("**/*.{go,mod,sum,work}")
        for name in ["a.go", "go.mod", "go.sum", "go.work"] { XCTAssertTrue(gopls.matches("/acme/" + name), name) }
        XCTAssertFalse(gopls.matches("/acme/go.works"))
        XCTAssertFalse(gopls.matches("/acme/a.rs"))

        let nested = try glob("**/{Cargo.{toml,lock},rust-analyzer.toml}")
        XCTAssertTrue(nested.matches("/acme/Cargo.lock"))
        XCTAssertTrue(nested.matches("/acme/rust-analyzer.toml"))
        XCTAssertFalse(nested.matches("/acme/Cargo.json"))

        let range = try glob("**/file[0-9].txt")
        XCTAssertTrue(range.matches("/acme/file7.txt"))
        XCTAssertFalse(range.matches("/acme/fileA.txt"))
        let negated = try glob("**/file[!0-9].txt")
        XCTAssertTrue(negated.matches("/acme/fileA.txt"))
        XCTAssertFalse(negated.matches("/acme/file7.txt"))
        XCTAssertFalse(try glob("a[!x]b").matches("a/b", root: nil), "a negated class is still not a slash")

        // Regular expression characters are literal.
        let odd = try glob("**/a+b (copy).$x")
        XCTAssertTrue(odd.matches("/acme/a+b (copy).$x"))
        XCTAssertFalse(odd.matches("/acme/aab (copy).$x"))
        XCTAssertTrue(try glob("**/[ab").matches("/acme/[ab"), "an unclosed [ is literal")

        XCTAssertNil(LSPGlob("**/*.{go,mod"), "an unclosed { matches nothing")
        XCTAssertNil(LSPGlob(""))
    }

    func testARelativePatternMatchesOnlyBelowItsBase() throws {
        let relative = try glob("**/*.tf", base: "/acme/infra/")
        XCTAssertEqual(relative.base, "/acme/infra")
        XCTAssertTrue(relative.matches("/acme/infra/envs/prod/main.tf"))
        XCTAssertFalse(relative.matches("/acme/infra-old/main.tf"))
        XCTAssertFalse(relative.matches("/globex/infra/main.tf"))
        XCTAssertFalse(try glob("main.tf", base: "/acme").matches("/acme/envs/main.tf"))
    }

    func testTheFolderBeforeTheFirstWildcard() {
        XCTAssertEqual(LSPGlob.literalFolder(of: "/acme/go/**/*.{go,mod}"), "/acme/go")
        XCTAssertEqual(LSPGlob.literalFolder(of: "/acme/Cargo.toml"), "/acme")
        XCTAssertEqual(LSPGlob.literalFolder(of: "/*.go"), "/")
        XCTAssertNil(LSPGlob.literalFolder(of: "**/*.go"))
    }

    // MARK: - Registrations, per server

    private let root = "/acme/repo"

    private func registered(_ json: String, resolve: @escaping (String) -> String = { $0 }) throws -> LSPWatchedFiles {
        var watched = LSPWatchedFiles()
        let params = try JSONSerialization.jsonObject(with: Data(json.utf8))
        XCTAssertTrue(watched.register(params, resolve: resolve))
        return watched
    }

    private func event(_ path: String, _ flags: DirectoryWatcher.Flags) -> DirectoryWatcher.Event {
        DirectoryWatcher.Event(path: path, flags: flags.union(.isFile))
    }

    /// What each event becomes: the files there now exist.
    private func changes(_ watched: LSPWatchedFiles, _ events: [DirectoryWatcher.Event], existing: Set<String>) -> [String] {
        watched.changes(for: events, root: root) { existing.contains($0) }.map { "\($0.path) \($0.type.rawValue)" }
    }

    func testGopls() throws {
        let watched = try registered(
            """
            {"registrations": [{"id": "workspace/didChangeWatchedFiles-0", "method": "workspace/didChangeWatchedFiles",
              "registerOptions": {"watchers": [
                {"globPattern": "**/*.{mod,work}", "kind": 7},
                {"globPattern": {"baseUri": "file:///acme/repo", "pattern": "**/*.{go,mod,sum,work}"}, "kind": 7}]}}]}
            """)
        XCTAssertEqual(watched.folders(root: root, home: "/Users/acme"), [root])
        let events = [
            event("/acme/repo/cmd/main.go", .created), event("/acme/repo/go.sum", .modified), event("/acme/repo/old.go", .removed),
            event("/acme/repo/README.md", .modified), event("/acme/repo/.git/objects/ab/cdef", .created),
            event("/acme/repo/cmd/main.go", [.created, .modified]),
        ]
        XCTAssertEqual(
            changes(watched, events, existing: ["/acme/repo/cmd/main.go", "/acme/repo/go.sum"]),
            ["/acme/repo/cmd/main.go 1", "/acme/repo/go.sum 2", "/acme/repo/old.go 3"])
    }

    func testGoplsWithoutRelativePatterns() throws {
        // What gopls sends a client without relativePatternSupport, the
        // folder as the server knows it (/tmp) made the one FSEvents names.
        let watched = try registered(
            """
            {"registrations": [{"id": "w", "method": "workspace/didChangeWatchedFiles", "registerOptions": {"watchers": [
              {"globPattern": "/tmp/acme/go/**/*.{go,mod,sum,work}", "kind": 7}]}}]}
            """, resolve: { $0 == "/tmp/acme/go" ? "/private/tmp/acme/go" : $0 })
        XCTAssertEqual(watched.watchers.first?.glob.pattern, "/private/tmp/acme/go/**/*.{go,mod,sum,work}")
        XCTAssertEqual(
            watched.changes(for: [event("/private/tmp/acme/go/a.go", .modified)], root: "/private/tmp/acme/go") { _ in true }.count, 1)
    }

    func testRustAnalyzer() throws {
        // reload.rs, with relativePatternSupport: its roots' sources and
        // manifests, kind left out (all three), and a manifest outside the
        // root named as a path.
        let watched = try registered(
            """
            {"registrations": [{"id": "workspace/didChangeWatchedFiles", "method": "workspace/didChangeWatchedFiles",
              "registerOptions": {"watchers": [
                {"globPattern": {"baseUri": "file:///acme/repo", "pattern": "**/*.rs"}},
                {"globPattern": {"baseUri": "file:///acme/repo", "pattern": "**/Cargo.{toml,lock}"}},
                {"globPattern": {"baseUri": "file:///acme/repo", "pattern": "**/rust-analyzer.toml"}},
                {"globPattern": "/acme/shared-crate/Cargo.toml"},
                {"globPattern": {"baseUri": "file:///acme/shared-crate", "pattern": "**/*.rs"}}]}}]}
            """)
        XCTAssertEqual(watched.folders(root: root, home: "/Users/acme"), [root, "/acme/shared-crate"])
        let events = [
            event("/acme/repo/src/lib.rs", .modified), event("/acme/repo/Cargo.lock", .modified),
            event("/acme/repo/target/debug/build.log", .created), event("/acme/shared-crate/src/a.rs", .removed),
            event("/acme/shared-crate/Cargo.toml", .modified),
        ]
        XCTAssertEqual(
            changes(watched, events, existing: ["/acme/repo/src/lib.rs", "/acme/repo/Cargo.lock", "/acme/repo/target/debug/build.log", "/acme/shared-crate/Cargo.toml"]),
            ["/acme/repo/src/lib.rs 2", "/acme/repo/Cargo.lock 2", "/acme/shared-crate/src/a.rs 3", "/acme/shared-crate/Cargo.toml 2"])
    }

    func testSourceKitLSP() throws {
        // Everything (create, change, delete), and Swift files' changes.
        let watched = try registered(
            """
            {"registrations": [{"id": "E8FAE6E1-BE02-4DC8-8E6F-D03D6AA24672", "method": "workspace/didChangeWatchedFiles",
              "registerOptions": {"watchers": [{"globPattern": "**/*", "kind": 7}, {"globPattern": "**/*.swift", "kind": 2}]}}]}
            """)
        let events = [
            event("/acme/repo/Sources/Acme/a.swift", .modified), event("/acme/repo/Package.resolved", .created),
            event("/acme/repo/node_modules/left-pad/index.js", .modified), event("/acme/repo/node_modules/left-pad", .created),
            event("/acme/repo/Sources/Acme/a.swift", .inodeMetadata),
        ]
        XCTAssertEqual(
            changes(watched, events, existing: ["/acme/repo/Sources/Acme/a.swift", "/acme/repo/Package.resolved", "/acme/repo/node_modules/left-pad"]),
            ["/acme/repo/Sources/Acme/a.swift 2", "/acme/repo/Package.resolved 1", "/acme/repo/node_modules/left-pad 1"],
            "VS Code's watcherExclude: inside a package in node_modules, and metadata-only events, aren't sent")
    }

    func testClangdRegistersNothingAndCostsNothing() throws {
        var watched = LSPWatchedFiles()
        let unrelated = try JSONSerialization.jsonObject(
            with: Data(#"{"registrations": [{"id": "1", "method": "textDocument/semanticTokens", "registerOptions": {}}]}"#.utf8))
        XCTAssertFalse(watched.register(unrelated), "other registrations are acknowledged, not kept")
        XCTAssertTrue(watched.isEmpty)
        XCTAssertEqual(watched.changes(for: [event("/acme/repo/a.c", .modified)], root: root) { _ in true }, [])
    }

    func testTerraformLS() throws {
        // terraform-ls (#953): its files, the init's records, and folders
        // gone (a deleted module's directory).
        let watched = try registered(
            """
            {"registrations": [{"id": "tf-watch", "method": "workspace/didChangeWatchedFiles", "registerOptions": {"watchers": [
              {"globPattern": {"baseUri": {"uri": "file:///acme/repo", "name": "repo"}, "pattern": "**/*.{tf,tfvars,tf.json,tfvars.json}"}, "kind": 7},
              {"globPattern": {"baseUri": {"uri": "file:///acme/repo", "name": "repo"}, "pattern": "**/.terraform/modules/modules.json"}, "kind": 7},
              {"globPattern": {"baseUri": {"uri": "file:///acme/repo", "name": "repo"}, "pattern": "**/.terraform.lock.hcl"}, "kind": 7},
              {"globPattern": {"baseUri": {"uri": "file:///acme/repo", "name": "repo"}, "pattern": "**/"}, "kind": 4}]}}]}
            """)
        let events = [
            event("/acme/repo/envs/prod/main.tf", .modified), event("/acme/repo/envs/prod/prod.tfvars", .created),
            event("/acme/repo/envs/prod/.terraform/modules/modules.json", .created),
            event("/acme/repo/envs/prod/.terraform/providers/registry.terraform.io/hashicorp/null/3.2.4/darwin_arm64/terraform-provider-null", .created),
            event("/acme/repo/envs/prod/.terraform.lock.hcl", .modified),
            DirectoryWatcher.Event(path: "/acme/repo/modules/acme-net/", flags: [.removed, .isDirectory]),
        ]
        XCTAssertEqual(
            changes(
                watched, events,
                existing: [
                    "/acme/repo/envs/prod/main.tf", "/acme/repo/envs/prod/prod.tfvars", "/acme/repo/envs/prod/.terraform/modules/modules.json",
                    "/acme/repo/envs/prod/.terraform.lock.hcl",
                ]),
            [
                "/acme/repo/envs/prod/main.tf 2", "/acme/repo/envs/prod/prod.tfvars 1", "/acme/repo/envs/prod/.terraform/modules/modules.json 1",
                "/acme/repo/envs/prod/.terraform.lock.hcl 2", "/acme/repo/modules/acme-net 3",
            ],
            "the providers init writes aren't watched; a folder's event matches a folder pattern (**/), sent without the slash")
        // A kind filter: a watcher for deletes alone hears no change.
        let deletes = try registered(
            #"{"registrations": [{"id": "d", "method": "workspace/didChangeWatchedFiles", "registerOptions": {"watchers": [{"globPattern": "**/*.tf", "kind": 4}]}}]}"#
        )
        XCTAssertEqual(changes(deletes, [event("/acme/repo/a.tf", .modified), event("/acme/repo/b.tf", .removed)], existing: ["/acme/repo/a.tf"]), ["/acme/repo/b.tf 3"])
    }

    func testUnregisterAndReregister() throws {
        var watched = try registered(
            #"{"registrations": [{"id": "a", "method": "workspace/didChangeWatchedFiles", "registerOptions": {"watchers": [{"globPattern": "**/*.go"}]}}]}"#)
        XCTAssertTrue(
            watched.register(
                try JSONSerialization.jsonObject(
                    with: Data(#"{"registrations": [{"id": "b", "method": "workspace/didChangeWatchedFiles", "registerOptions": {"watchers": [{"globPattern": "**/*.rs"}]}}]}"#.utf8)),
                resolve: { $0 }))
        XCTAssertEqual(watched.watchers.map(\.glob.pattern), ["**/*.go", "**/*.rs"])
        // The spec's own spelling, "unregisterations".
        XCTAssertTrue(
            watched.unregister(
                try JSONSerialization.jsonObject(with: Data(#"{"unregisterations": [{"id": "a", "method": "workspace/didChangeWatchedFiles"}]}"#.utf8))))
        XCTAssertEqual(watched.watchers.map(\.glob.pattern), ["**/*.rs"])
        XCTAssertFalse(watched.unregister(["unregistrations": [["id": "zzz", "method": "workspace/didChangeWatchedFiles"]]]))
        XCTAssertTrue(watched.unregister(["unregistrations": [["id": "b", "method": "workspace/didChangeWatchedFiles"]]]))
        XCTAssertTrue(watched.isEmpty)
    }

    func testNeverTheWholeDiskOrTheHomeFolder() throws {
        let watched = try registered(
            """
            {"registrations": [{"id": "w", "method": "workspace/didChangeWatchedFiles", "registerOptions": {"watchers": [
              {"globPattern": "/**/*.go"},
              {"globPattern": {"baseUri": "file:///", "pattern": "**/*.go"}},
              {"globPattern": {"baseUri": "file:///Users", "pattern": "**/*.go"}},
              {"globPattern": {"baseUri": "file:///Users/acme", "pattern": "**/*.go"}},
              {"globPattern": {"baseUri": "file:///acme", "pattern": "**/*.go"}},
              {"globPattern": {"baseUri": "file:///acme/repo/sub", "pattern": "**/*.go"}},
              {"globPattern": {"baseUri": "file:///globex/lib", "pattern": "**/*.go"}},
              {"globPattern": {"baseUri": "file:///globex/lib/inner", "pattern": "**/*.go"}}]}}]}
            """)
        XCTAssertEqual(
            watched.folders(root: root, home: "/Users/acme"), [root, "/globex/lib"],
            "/, the home folder and above it, the root's parents and folders inside a watched one are not watched again")
    }

    func testPyright() throws {
        // pyright (and basedpyright): its config files and everything (`**`)
        // under the root, then each search path outside it — the standard
        // library, site-packages, the user's site — as a base with `**`; one
        // under the root (the venv) left out, `**` has it already.
        let watched = try registered(
            """
            {"registrations": [{"id": "3f2c9d0e-5a1b-4c7e-9f00-acme00000001", "method": "workspace/didChangeWatchedFiles",
              "registerOptions": {"watchers": [
                {"globPattern": "**/pyrightconfig.json", "kind": 7},
                {"globPattern": "**/pyproject.toml", "kind": 7},
                {"globPattern": "**", "kind": 7},
                {"globPattern": {"baseUri": "file:///opt/homebrew/Cellar/python@3.13/3.13.1/Frameworks/Python.framework/Versions/3.13/lib/python3.13", "pattern": "**"}, "kind": 7},
                {"globPattern": {"baseUri": "file:///opt/homebrew/lib/python3.13/site-packages", "pattern": "**"}, "kind": 7},
                {"globPattern": {"baseUri": "file:///Users/acme/Library/Python/3.13/lib/python/site-packages", "pattern": "**"}, "kind": 7}]}}]}
            """)
        let library = [
            "/Users/acme/Library/Python/3.13/lib/python/site-packages",
            "/opt/homebrew/Cellar/python@3.13/3.13.1/Frameworks/Python.framework/Versions/3.13/lib/python3.13",
            "/opt/homebrew/lib/python3.13/site-packages",
        ]
        XCTAssertEqual(watched.folders(root: root, home: "/Users/acme"), [root] + library, "three file-level roots besides the checkout")
        let events = [
            event("/acme/repo/acme/app.py", .modified), event("/acme/repo/.venv/lib/python3.13/site-packages/requests/api.py", .created),
            event("/opt/homebrew/lib/python3.13/site-packages/globex/__init__.py", .created),
        ]
        XCTAssertEqual(
            changes(watched, events, existing: Set(events.map(\.path))),
            [
                "/acme/repo/acme/app.py 2", "/acme/repo/.venv/lib/python3.13/site-packages/requests/api.py 1",
                "/opt/homebrew/lib/python3.13/site-packages/globex/__init__.py 1",
            ])
        // A .py opened from the home folder, with no marker and no .git: the
        // home folder is its root, and isn't watched — only the library
        // folders that pass the rule are, the user's site below home too.
        XCTAssertEqual(watched.folders(root: "/Users/acme", home: "/Users/acme"), library)
    }

    func testVtsls() throws {
        // vtsls is VS Code's TypeScript extension, which asks the client to
        // watch what tsserver watches (canUseWatchEvents): one registration
        // each, a folder's `*` or `**`, a file by its name — the project's
        // node_modules/@types, a missing lookup's parent beside the root,
        // its own TypeScript's lib files under the home folder.
        let watched = try registered(
            """
            {"registrations": [
              {"id": "w1", "method": "workspace/didChangeWatchedFiles", "registerOptions": {"watchers": [
                {"globPattern": {"baseUri": "file:///acme/repo", "pattern": "tsconfig.json"}, "kind": 7}]}},
              {"id": "w2", "method": "workspace/didChangeWatchedFiles", "registerOptions": {"watchers": [
                {"globPattern": {"baseUri": "file:///acme/repo/src", "pattern": "**"}, "kind": 7}]}},
              {"id": "w3", "method": "workspace/didChangeWatchedFiles", "registerOptions": {"watchers": [
                {"globPattern": {"baseUri": "file:///acme/repo/node_modules/@types", "pattern": "**"}, "kind": 7}]}},
              {"id": "w4", "method": "workspace/didChangeWatchedFiles", "registerOptions": {"watchers": [
                {"globPattern": {"baseUri": "file:///acme/node_modules", "pattern": "*"}, "kind": 7}]}},
              {"id": "w5", "method": "workspace/didChangeWatchedFiles", "registerOptions": {"watchers": [
                {"globPattern": {"baseUri": "file:///Users/acme/Library/Application%20Support/Zed/languages/vtsls/node_modules/typescript/lib", "pattern": "lib.es2022.d.ts"}, "kind": 7}]}}]}
            """)
        XCTAssertEqual(
            watched.folders(root: root, home: "/Users/acme"),
            [root, "/Users/acme/Library/Application Support/Zed/languages/vtsls/node_modules/typescript/lib", "/acme/node_modules"])
        let events = [
            event("/acme/repo/src/index.ts", .modified), event("/acme/repo/README.md", .modified),
            event("/acme/repo/node_modules/@types/node/index.d.ts", .created), event("/acme/node_modules/globex", .created),
        ]
        XCTAssertEqual(
            changes(watched, events, existing: Set(events.map(\.path))), ["/acme/repo/src/index.ts 2", "/acme/node_modules/globex 1"],
            "the inside of a package in node_modules isn't sent (VS Code's watcherExclude), nor what no watcher names")
    }

    func testNeverTheHomeFolderOrTheDiskAsTheRoot() throws {
        let watched = try registered(
            """
            {"registrations": [{"id": "w", "method": "workspace/didChangeWatchedFiles", "registerOptions": {"watchers": [
              {"globPattern": "**/*"},
              {"globPattern": {"baseUri": "file:///Users/acme", "pattern": "**/*.go"}},
              {"globPattern": {"baseUri": "file:///Users/acme/go/src/acme", "pattern": "**/*.go"}},
              {"globPattern": {"baseUri": "file:///Volumes/acme-disk", "pattern": "**/*.go"}},
              {"globPattern": {"baseUri": "file:///Volumes/acme-disk/src", "pattern": "**/*.go"}}]}}]}
            """)
        XCTAssertEqual(watched.folders(root: "/Users/acme", home: "/Users/acme"), ["/Users/acme/go/src/acme", "/Volumes/acme-disk/src"])
        XCTAssertEqual(watched.folders(root: "/", home: "/Users/acme"), ["/Users/acme/go/src/acme", "/Volumes/acme-disk/src"])
        XCTAssertEqual(
            watched.folders(root: "/Volumes/acme-disk", home: "/Users/acme"), ["/Users/acme/go/src/acme", "/Volumes/acme-disk/src"])
        XCTAssertEqual(watched.folders(root: "/Users", home: "/Users/acme"), ["/Users/acme/go/src/acme", "/Volumes/acme-disk/src"])
        for root in ["/", "/Users", "/Users/acme", "/Volumes/acme-disk"] {
            XCTAssertFalse(LSPWatchedFiles.watchable(root, home: "/Users/acme"), root)
            XCTAssertFalse(watched.folders(root: root, home: "/Users/acme").contains(root), root)
        }
        XCTAssertTrue(LSPWatchedFiles.watchable("/Users/acme/src/acme-app", home: "/Users/acme"))
        XCTAssertTrue(LSPWatchedFiles.watchable("/Volumes/acme-disk/src", home: "/Users/acme"))
        // Nothing registered with a folder of its own: nothing at all.
        let everything = try registered(
            #"{"registrations": [{"id": "w", "method": "workspace/didChangeWatchedFiles", "registerOptions": {"watchers": [{"globPattern": "**"}]}}]}"#)
        XCTAssertEqual(everything.folders(root: "/Users/acme", home: "/Users/acme"), [])
        XCTAssertEqual(everything.folders(root: root, home: "/Users/acme"), [root])
    }

    func testEventsGoBackInTheServersSpelling() throws {
        // A base through a link, and /tmp, as FSEvents names them; the root
        // under /var. Each event goes back as the server spelled it.
        let real = [
            "/tmp/acme-lib": "/private/tmp/acme-lib", "/acme/linked-lib": "/globex/vendored-lib", "/var/acme/repo": "/private/var/acme/repo",
        ]
        let watched = try registered(
            """
            {"registrations": [{"id": "w", "method": "workspace/didChangeWatchedFiles", "registerOptions": {"watchers": [
              {"globPattern": {"baseUri": "file:///tmp/acme-lib", "pattern": "**/*.py"}},
              {"globPattern": "/acme/linked-lib/**/*.py"},
              {"globPattern": {"baseUri": "file:///acme/plain-lib/", "pattern": "**/*.py"}}]}}]}
            """, resolve: { real[$0] ?? $0 })
        XCTAssertEqual(watched.watchers.map(\.spelled), ["/tmp/acme-lib", "/acme/linked-lib", nil])
        XCTAssertEqual(watched.watchers.map { $0.glob.base ?? $0.glob.pattern }, ["/private/tmp/acme-lib", "/globex/vendored-lib/**/*.py", "/acme/plain-lib"])
        XCTAssertEqual(
            watched.folders(root: "/private/var/acme/repo", home: "/Users/acme"),
            ["/private/var/acme/repo", "/acme/plain-lib", "/globex/vendored-lib", "/private/tmp/acme-lib"])
        func spelled(_ path: String) -> String { watched.serverPath(path, realRoot: "/private/var/acme/repo", rootSpelling: "/var/acme/repo") }
        XCTAssertEqual(spelled("/private/tmp/acme-lib/acme/x.py"), "/tmp/acme-lib/acme/x.py")
        XCTAssertEqual(spelled("/private/tmp/acme-lib"), "/tmp/acme-lib")
        XCTAssertEqual(spelled("/globex/vendored-lib/y.py"), "/acme/linked-lib/y.py")
        XCTAssertEqual(spelled("/private/var/acme/repo/main.py"), "/var/acme/repo/main.py")
        XCTAssertEqual(spelled("/acme/plain-lib/z.py"), "/acme/plain-lib/z.py", "spelled as it is: unchanged")
        XCTAssertEqual(spelled("/private/tmp/acme-lib-old/x.py"), "/private/tmp/acme-lib-old/x.py", "a sibling isn't below it")
        let events = [event("/private/tmp/acme-lib/acme/x.py", .modified), event("/globex/vendored-lib/y.py", .created)]
        XCTAssertEqual(changes(watched, events, existing: Set(events.map(\.path))), ["/private/tmp/acme-lib/acme/x.py 2", "/globex/vendored-lib/y.py 1"])
    }

    func testAChangeBatchIsBoundedPerNotification() {
        XCTAssertEqual(LSPWatchedFiles.batchLimit, 1000)
        XCTAssertTrue(LSPWatchedFiles.excluded("/acme/repo/.git/objects/12/34"))
        XCTAssertFalse(LSPWatchedFiles.excluded("/acme/repo/.git/HEAD"))
        XCTAssertFalse(LSPWatchedFiles.excluded("/acme/repo/node_modules/left-pad"))
        XCTAssertTrue(LSPWatchedFiles.excluded("/acme/repo/node_modules/left-pad/package.json"))
    }
}
