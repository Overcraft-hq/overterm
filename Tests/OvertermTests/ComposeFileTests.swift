import Foundation
import XCTest

@testable import Overterm

/// What Compose says of a checkout's compose files, read for the project
/// before it runs: kept without its secrets, its errors in its own words,
/// its stamp watching only what Compose reads. Pure, but for the last one,
/// which asks this Mac's `docker compose config` (OVERTERM_DOCKER_TESTS=1).
final class ComposeConfigTests: XCTestCase {
    /// What Compose v5.6 answered for a project with an override, an
    /// include, `.env` and an env file — trimmed, the secrets kept in.
    static let answer = """
        {
          "name": "myshop",
          "networks": {"default": {"name": "myshop_default", "ipam": {}}},
          "services": {
            "base": {"command": ["true"], "entrypoint": null, "image": "busybox", "networks": {"default": null}},
            "cache": {"image": "redis:7", "deploy": {"replicas": 2}, "networks": {"default": null}},
            "db": {
              "environment": {"POSTGRES_PASSWORD": "hunter2"},
              "image": "postgres:15",
              "ports": [{"mode": "ingress", "target": 5432, "published": "5432", "protocol": "tcp"}]
            },
            "mail": {"image": "mailhog/mailhog", "env_file": [{"path": "/w/My.Shop/mail.env", "required": true}]},
            "web": {
              "environment": {"DEBUG": "1", "API_TOKEN": "s3cr3t"},
              "build": {"context": "/w/My.Shop", "dockerfile": "Dockerfile"},
              "depends_on": {"db": {"condition": "service_healthy", "required": true}},
              "ports": [{"mode": "ingress", "target": 80, "published": "8080", "protocol": "tcp"}, {"target": 9000, "protocol": "udp"}]
            }
          }
        }
        """

    func testWhatComposeSaysIsRead() throws {
        let config = try ComposeConfig.parse(Self.answer)
        XCTAssertEqual(config.name, "myshop")
        XCTAssertEqual(config.services.map(\.name), ["base", "cache", "db", "mail", "web"])
        let byName = Dictionary(uniqueKeysWithValues: config.services.map { ($0.name, $0) })
        XCTAssertEqual(byName["db"]?.image, "postgres:15")
        XCTAssertEqual(byName["db"]?.ports, [ComposeConfig.Port(published: "5432", target: 5432, proto: "tcp")])
        XCTAssertNil(byName["web"]?.image, "built, not tagged")
        XCTAssertEqual(byName["web"]?.buildContext, "/w/My.Shop")
        XCTAssertEqual(byName["web"]?.dependsOn, ["db"])
        XCTAssertEqual(byName["web"]?.ports.map(\.label), ["8080→80", "9000/udp"])
        XCTAssertEqual(byName["cache"]?.replicas, 2)
        XCTAssertEqual(byName["base"]?.replicas, 1)
        XCTAssertEqual(byName["web"]?.summary(in: "/w/My.Shop"), "built from ./ · after db")
        XCTAssertEqual(byName["db"]?.summary(in: "/w/My.Shop"), "postgres:15")
        XCTAssertEqual(ComposeConfig.relative("/w/My.Shop/api", to: "/w/My.Shop"), "./api")
        XCTAssertEqual(ComposeConfig.relative("/w/other", to: "/w/My.Shop"), "/w/other")
        let kept = String(describing: config)
        XCTAssertFalse(kept.contains("hunter2"), "environment is never read")
        XCTAssertFalse(kept.contains("s3cr3t"))
        XCTAssertFalse(kept.contains("mail.env"), "nor env_file")
    }

    func testOlderShapesAreRead() throws {
        let config = try ComposeConfig.parse(
            #"{"name":"x","services":{"a":{"build":"./a","depends_on":["b"],"scale":3,"ports":[{"target":80,"published":8080}],"container_name":"the-a"}}}"#)
        let a = try XCTUnwrap(config.services.first)
        XCTAssertEqual(a.buildContext, "./a")
        XCTAssertEqual(a.dependsOn, ["b"])
        XCTAssertEqual(a.replicas, 3)
        XCTAssertEqual(a.ports, [ComposeConfig.Port(published: "8080", target: 80, proto: "tcp")])
        XCTAssertEqual(a.containerName, "the-a")
    }

    func testAProjectBeforeItRuns() throws {
        let project = try ComposeConfig.parse(Self.answer).project(in: "/w/shop")
        XCTAssertTrue(project.planned)
        XCTAssertEqual(project.workingDir, "/w/shop")
        XCTAssertEqual(project.configFiles, [])
        XCTAssertTrue(project.services.allSatisfy { $0.containers.isEmpty && $0.spec != nil && $0.project == "myshop" })
        XCTAssertEqual(project.services.first { $0.name == "web" }?.dependsOn, ["db"])
        XCTAssertEqual(project.status, .stopped)
        XCTAssertEqual(project.running, 0)
        XCTAssertTrue(project.failing.isEmpty)
        XCTAssertEqual(project.expected, 6, "replicas counted")
        XCTAssertEqual(
            DockerCommands.compose(project, "up -d"), "docker compose up -d",
            "no -f: the override loads as it did for the read; no -p: the name is the files' when it runs, never one read earlier")
        let fake = DockerEndpoint(address: .unix("/tmp/fake.sock"), context: nil, source: "OVERTERM_DOCKER_HOST")
        XCTAssertEqual(DockerCommands.compose(project, "up -d", endpoint: fake), "DOCKER_HOST=unix:///tmp/fake.sock docker compose up -d")
        XCTAssertEqual(DockerCommands.compose(project, "pull"), "docker compose pull")
    }

    func testTheArguments() {
        XCTAssertEqual(ComposeConfig.arguments(), ["compose", "config", "--format", "json"])
        XCTAssertEqual(ComposeConfig.arguments(profiles: ["dev"]), ["compose", "--profile", "dev", "config", "--format", "json"])
        XCTAssertEqual(ComposeConfig.noEnvResolution, "--no-env-resolution")
        XCTAssertTrue(ComposeConfig.lacksEnvResolution("unknown flag: --no-env-resolution\nSee 'docker compose config --help'."))
        XCTAssertFalse(ComposeConfig.lacksEnvResolution("error while interpolating"))
    }

    /// A stub `docker` that is Compose before 2.35: the flag unknown. It is
    /// asked again without it; another error is not asked again.
    func testComposeBefore235IsAskedAgainWithoutTheFlag() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ot-compose-old-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let stub = root.appendingPathComponent("docker")
        let script = #"""
            #!/bin/sh
            echo "$*" >> "$(dirname "$0")/calls"
            case "$*" in
              *--no-env-resolution*)
                if [ -f .broken ]; then echo "error while interpolating services.web.image: required variable TAG is missing a value" >&2; exit 1; fi
                echo "unknown flag: --no-env-resolution" >&2; echo "See 'docker compose config --help'." >&2; exit 1 ;;
              "compose config --format json") echo '{"name":"old","services":{"web":{"image":"nginx","environment":{"API_TOKEN":"s3cr3t"}}}}' ;;
              *) echo "unexpected: $*" >&2; exit 1 ;;
            esac
            """#
        try script.write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        DockerCLI.override = stub
        defer { DockerCLI.override = nil }
        func calls() -> [String] {
            ((try? String(contentsOf: root.appendingPathComponent("calls"), encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        }

        let output = try await ComposeFileModel.compose(in: root, endpoint: nil)
        let config = try ComposeConfig.parse(try XCTUnwrap(output))
        XCTAssertEqual(config.name, "old")
        XCTAssertEqual(config.services.map(\.name), ["web"])
        XCTAssertFalse(String(describing: config).contains("s3cr3t"), "the env files are in that answer, and still not kept")
        XCTAssertEqual(calls(), ["compose config --format json --no-env-resolution", "compose config --format json"])

        FileManager.default.createFile(atPath: root.appendingPathComponent(".broken").path, contents: Data())
        do {
            _ = try await ComposeFileModel.compose(in: root, endpoint: nil)
            XCTFail("Compose's own error is thrown")
        } catch {
            XCTAssertEqual(ComposeConfig.message(error), "error while interpolating services.web.image: required variable TAG is missing a value")
        }
        XCTAssertEqual(calls().count, 3, "another error isn't asked again")
    }

    /// The resolved config is a file in the editor: what Compose filled in
    /// from the variables is masked before it is written.
    func testTheResolvedConfigsSecretsAreMasked() {
        let yaml = """
            name: shop
            services:
              api:
                build:
                  context: /w/shop
                  args:
                    NODE_VERSION: "20"
                    NPM_TOKEN: npm_abcdef123
                command:
                  - --requirepass
                  - hunter22
                environment:
                  DATABASE_URL: postgres://app:pa55word@db:5432/app
                  DEBUG: "1"
                  POSTGRES_PASSWORD: hunter22
                  PRIVATE_KEY: |-
                    -----BEGIN KEY-----
                    abc
                  QUOTED_SECRET: "s3cr3t value"
                  UNSET: null
                env_file:
                  - path: /w/shop/api.env
                image: api
              db:
                environment:
                  - API_TOKEN=tok123456
                  - LANG=C
            secrets:
              token:
                environment: API_TOKEN
            """
        let masked = ComposeConfig.masked(yaml, secrets: ["hunter22"])
        for secret in ["hunter22", "npm_abcdef123", "pa55word", "BEGIN KEY", "s3cr3t", "tok123456"] {
            XCTAssertFalse(masked.contains(secret), secret)
        }
        for kept in [
            "DATABASE_URL: postgres://app:••••••@db:5432/app", #"DEBUG: "1""#, #"NODE_VERSION: "20""#, "NPM_TOKEN: ••••••",
            "POSTGRES_PASSWORD: ••••••", #"QUOTED_SECRET: "••••••""#, "UNSET: null", "- API_TOKEN=••••••", "- LANG=C",
            "      - ••••••", "    environment: API_TOKEN", "    image: api", "      - path: /w/shop/api.env",
        ] {
            XCTAssertTrue(masked.contains(kept), kept)
        }
        XCTAssertEqual(masked.components(separatedBy: "\n").count, yaml.components(separatedBy: "\n").count, "line for line")
        XCTAssertEqual(
            ComposeConfig.redact("hunter22x hunter22 xhunter22 :hunter22@", ["hunter22"]), "hunter22x •••••• xhunter22 :••••••@",
            "a secret inside a longer word isn't that secret")
    }

    func testTheSecretsOfAProjectsDotEnv() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ot-dotenv-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        XCTAssertEqual(ComposeConfig.dotEnvSecrets(in: folder), [], "no .env")
        try "DB_PASSWORD=hunter22\nAUTH_REQUIRED=true\nTAG=1.2.3\nAPI_KEY=short\n# SECRET=commented\n"
            .write(to: folder.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
        XCTAssertEqual(ComposeConfig.dotEnvSecrets(in: folder), ["hunter22"], "secret-looking names only, and no common word")
    }

    /// A project from labels takes the plan's place when it has its name, or
    /// was made from the same compose file under another.
    func testWhatTakesThePlansPlace() throws {
        let plan = try ComposeConfig.parse(#"{"name":"my-shop","services":{"web":{"image":"nginx"}}}"#).project(in: "/w/my-shop")
        func labels(_ name: String, _ folder: String?, _ files: [String]) -> ComposeProject {
            ComposeProject(name: name, workingDir: folder, configFiles: files, services: [])
        }
        XCTAssertTrue(ComposeProjects.replaces(labels("my-shop", "/elsewhere", ["/elsewhere/compose.yaml"]), plan), "its name, from anywhere")
        XCTAssertTrue(
            ComposeProjects.replaces(labels("shop", "/w/my-shop", ["/w/my-shop/compose.yaml", "/w/my-shop/compose.override.yaml"]), plan),
            "its files, under another name (-p, COMPOSE_PROJECT_NAME)")
        XCTAssertTrue(ComposeProjects.replaces(labels("shop", "/w", ["/w/my-shop/docker-compose.yml"]), plan), "-f from elsewhere")
        XCTAssertTrue(ComposeProjects.replaces(labels("shop", "/w/my-shop", []), plan), "no files said: its folder")
        XCTAssertFalse(ComposeProjects.replaces(labels("tools", "/w/my-shop", ["/w/my-shop/tools.yaml"]), plan), "another file at its top")
        XCTAssertFalse(ComposeProjects.replaces(labels("api", "/w/my-shop/api", ["/w/my-shop/api/compose.yaml"]), plan), "a compose file below")
        XCTAssertFalse(ComposeProjects.replaces(labels("shop", "/w/my-shop-2", ["/w/my-shop-2/compose.yaml"]), plan), "another worktree")
    }

    func testComposesErrorsInItsOwnWords() {
        let warned = GitError(
            arguments: [], status: 1,
            stderr: #"time="2026-10-28T22:59:03+03:00" level=warning msg="The \"TAG\" variable is not set. Defaulting to a blank string.""# + "\n"
                + "error while interpolating services.api.image: required variable TAG is missing a value\n")
        XCTAssertEqual(ComposeConfig.message(warned), "error while interpolating services.api.image: required variable TAG is missing a value")
        XCTAssertEqual(ComposeConfig.message(GitError(arguments: [], status: 1, stderr: #"time="x" level=error msg="boom""#)), "boom")
        XCTAssertEqual(ComposeConfig.message(GitError(arguments: [], status: 1, stderr: "a\nb\nc\nd\n")), "a\nb\nc", "three lines at most")
        XCTAssertEqual(ComposeConfig.message(GitError(arguments: [], status: -1, stderr: "env timed out after 15 s")), "docker compose config didn't answer in time.")
        XCTAssertEqual(ComposeConfig.message(GitError(arguments: [], status: 1, stderr: "")), "docker compose config failed (1).")
        XCTAssertEqual(ComposeConfig.message(DockerError(status: 0, message: "docker isn't on this Mac")), "docker isn't on this Mac")
    }

    func testAnAnswerThatIsntAProjectThrows() {
        for output in ["", "[]", #"{"services":{}}"#, "not json {"] {
            XCTAssertThrowsError(try ComposeConfig.parse(output), output)
        }
        XCTAssertNoThrow(try ComposeConfig.parse("WARN something\n" + #"{"name":"x","services":{}}"#), "read from the first brace")
    }

    func testWhatTheStampWatches() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ot-stamp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("src"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try "services: {}\n".write(to: folder.appendingPathComponent("compose.yaml"), atomically: true, encoding: .utf8)
        var stamp = ComposeConfig.stamp(of: folder)
        XCTAssertEqual(Array(stamp.files.keys), ["compose.yaml"])
        try "# readme\n".write(to: folder.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try "a: 1\n".write(to: folder.appendingPathComponent("src/x.yaml"), atomically: true, encoding: .utf8)
        XCTAssertEqual(ComposeConfig.stamp(of: folder), stamp, "only the top folder's compose inputs count")
        for (name, text) in [("compose.yaml", "services:\n  web: {}\n"), (".env", "TAG=1\n"), ("compose.dev.yaml", "services: {}\n"), ("api.env", "X=1\n")] {
            try text.write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8)
            let now = ComposeConfig.stamp(of: folder)
            XCTAssertNotEqual(now, stamp, name)
            stamp = now
        }
        XCTAssertTrue(ComposeConfig.isComposeInput("docker-compose.yml"))
        XCTAssertFalse(ComposeConfig.isComposeInput("Dockerfile"))
    }

    func testWhichEventsAreTheTopFolders() {
        let folder = "/private/var/x/repo"
        XCTAssertTrue(ComposeConfig.touches(["/private/var/x/repo/"], folder: folder))
        XCTAssertTrue(ComposeConfig.touches(["/var/x/repo"], folder: folder))
        XCTAssertTrue(ComposeConfig.touches(["/private/var/x/repo/src", "/private/var/x/repo"], folder: folder))
        XCTAssertFalse(ComposeConfig.touches(["/private/var/x/repo/src"], folder: folder))
        XCTAssertFalse(ComposeConfig.touches(["/private/var/x/repo-other"], folder: folder))
        XCTAssertFalse(ComposeConfig.touches([], folder: folder))
    }

    /// This Mac's Compose on a project of its own, told an engine that isn't
    /// there: it still answers what the plan reads, secrets left out.
    func testComposeItselfReadsAProject() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["OVERTERM_DOCKER_TESTS"] == "1" && DockerCLI.locate("docker") != nil,
            "OVERTERM_DOCKER_TESTS=1 runs this Mac's docker compose config")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ot-compose-live-\(UUID().uuidString.prefix(8))")
        let folder = root.appendingPathComponent("My.Shop", isDirectory: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("sub"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let files = [
            "compose.yaml": """
            include:
              - sub/extra.yaml
            services:
              db:
                image: postgres:${PG_TAG:-16}
                environment:
                  POSTGRES_PASSWORD: ${DB_PASSWORD}
                ports:
                  - "5432:5432"
              web:
                build: .
                depends_on:
                  db:
                    condition: service_healthy
                ports:
                  - "${WEB_PORT:-8080}:80"
              base:
                image: busybox
                command: ["true"]
              worker:
                extends:
                  service: base
                profiles: [jobs]
              admin:
                image: adminer
                profiles: [tools]

            """,
            "compose.override.yaml": "services:\n  mail:\n    image: mailhog/mailhog\n    env_file: [mail.env]\n",
            ".env": "DB_PASSWORD=hunter2\nPG_TAG=15\n",
            "mail.env": "MAIL_SECRET=s3cr3t-mail\n",
            "sub/extra.yaml": "services:\n  cache:\n    image: redis:7\n",
            "Dockerfile": "FROM busybox\n",
        ]
        for (name, text) in files { try text.write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8) }
        let nowhere = DockerEndpoint(address: .unix(root.appendingPathComponent("none.sock").path), context: nil, source: "test")
        let output = try await ComposeFileModel.compose(in: folder, endpoint: nowhere)
        let config = try ComposeConfig.parse(try XCTUnwrap(output))
        XCTAssertEqual(config.name, "myshop", "the folder's name, as Compose makes it a project's")
        XCTAssertEqual(config.services.map(\.name), ["base", "cache", "db", "mail", "web"], "the override and the include in, the profiles' out")
        XCTAssertEqual(config.services.first { $0.name == "db" }?.image, "postgres:15", ".env filled in")
        XCTAssertEqual(config.services.first { $0.name == "web" }?.buildContext, FileTreeModel.realPath(folder))
        XCTAssertFalse(String(describing: config).contains("hunter2"))
        XCTAssertFalse(output?.contains("s3cr3t-mail") ?? true, "an env file's contents aren't even asked for")
    }
}

/// When a checkout's compose files are read: only while Docker shows, again
/// when one changes, never for a file Compose doesn't read — and what is
/// shown meanwhile. Compose is a stub here.
@MainActor
final class ComposeFileModelTests: XCTestCase {
    private var root: URL!
    private var calls: [String] = []
    /// The stub's answer for a folder; nil: not asked.
    private var answer: (URL) -> String? = { ComposeFileModelTests.config($0.lastPathComponent) }
    private var failure: Error?
    private var model: ComposeFileModel!

    nonisolated static func config(_ name: String, services: [String] = ["web"]) -> String {
        let entries = services.map { #""\#($0)":{"image":"nginx:1.27"}"# }.joined(separator: ",")
        return #"{"name":"\#(name)","services":{\#(entries)}}"#
    }

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ot-compose-\(UUID().uuidString.prefix(8))")
        for name in ["a", "b"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
            try write("services:\n  web:\n    image: nginx\n", to: name)
        }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("empty"), withIntermediateDirectories: true)
        calls = []
        failure = nil
        model = ComposeFileModel(docker: DockerModel(endpoint: { nil }), latency: 0.05) { [weak self] folder, _ in
            guard let self else { return nil }
            self.calls.append(folder.path)
            if let failure = self.failure { throw failure }
            return self.answer(folder)
        }
    }

    override func tearDown() async throws {
        model.update(checkout: nil, shown: false)
        try? FileManager.default.removeItem(at: root)
    }

    private func folder(_ name: String) -> URL { root.appendingPathComponent(name) }

    private func write(_ text: String, to name: String, file: String = "compose.yaml") throws {
        try text.write(to: folder(name).appendingPathComponent(file), atomically: true, encoding: .utf8)
    }

    private func eventually(_ what: String, timeout: TimeInterval = 5, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("timed out: \(what)")
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    /// Shown, read, and its FSEvents stream live.
    private func show(_ name: String) async throws {
        let before = calls.count
        model.update(checkout: folder(name), shown: true)
        try await eventually("\(name) read") { calls.count > before && !model.reading }
        try await Task.sleep(for: .milliseconds(200))
    }

    /// An override of Overterm's came or went: read again while shown, and
    /// every other checkout's read is stale; nothing while hidden.
    func testAnOverrideComingOrGoingIsReadAgain() async throws {
        try await show("a")
        let before = calls.count
        model.readAgain()
        try await eventually("read again") { calls.count == before + 1 && !model.reading }
        XCTAssertTrue(model.isCurrent)
        model.update(checkout: folder("a"), shown: false)
        model.readAgain()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(calls.count, before + 1, "hidden: nothing read")
        model.update(checkout: folder("a"), shown: true)
        try await eventually("read when it shows") { calls.count == before + 2 && !model.reading }
    }

    func testNothingIsReadUntilShown() async throws {
        model.update(checkout: folder("a"), shown: false)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(calls, [])
        XCTAssertNil(model.project)
        try await show("a")
        XCTAssertEqual(calls, [FileTreeModel.realPath(folder("a"))], "asked once, in the checkout's real path")
        XCTAssertEqual(model.project?.name, "a")
        XCTAssertEqual(model.project?.workingDir, FileTreeModel.realPath(folder("a")))
        XCTAssertEqual(model.project?.planned, true)
        XCTAssertEqual(model.reads, 1)
    }

    func testAnEditToTheComposeFileIsReadAgain() async throws {
        try await show("a")
        answer = { _ in Self.config("a", services: ["web", "worker"]) }
        try write("services:\n  web:\n    image: nginx\n  worker:\n    image: busybox\n", to: "a")
        try await eventually("read again") { model.project?.services.map(\.name) == ["web", "worker"] }
        XCTAssertEqual(calls.count, 2)
    }

    func testAFileComposeDoesntReadIsnt() async throws {
        try await show("a")
        try write("# a\n", to: "a", file: "README.md")
        try FileManager.default.createDirectory(at: folder("a").appendingPathComponent("src"), withIntermediateDirectories: true)
        try "x: 1\n".write(to: folder("a").appendingPathComponent("src/deep.yaml"), atomically: true, encoding: .utf8)
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(calls.count, 1)
        try write("TAG=2\n", to: "a", file: ".env")
        try await eventually(".env is one") { calls.count == 2 }
    }

    func testHiddenReadsNothingAndShownAgainReads() async throws {
        try await show("a")
        model.update(checkout: folder("a"), shown: false)
        try write("services:\n  api:\n    image: nginx\n", to: "a")
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(calls.count, 1, "nothing read while hidden")
        XCTAssertEqual(model.project?.name, "a", "what was read stays")
        model.update(checkout: folder("a"), shown: true)
        try await eventually("shown again, read again") { calls.count == 2 }
    }

    func testAnotherCheckoutShowsItsOwnAtOnce() async throws {
        try await show("a")
        model.update(checkout: folder("b"), shown: true)
        XCTAssertNil(model.project, "a's plan doesn't linger over b")
        try await eventually("b read") { model.project?.name == "b" }
        XCTAssertEqual(calls.count, 2)
        model.update(checkout: folder("a"), shown: true)
        XCTAssertEqual(model.project?.name, "a", "known: shown at once")
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(calls.count, 2, "and not asked again: its files didn't change")
        model.update(checkout: folder("b"), shown: true)
        XCTAssertEqual(model.project?.name, "b")
        try write("services:\n  api:\n    image: nginx\n", to: "a")
        model.update(checkout: folder("a"), shown: true)
        try await eventually("a read again: it changed meanwhile") { calls.count == 3 }
    }

    func testAnErrorKeepsTheLastPlanAndSaysWhy() async throws {
        try await show("a")
        failure = GitError(
            arguments: [], status: 1,
            stderr: #"time="x" level=warning msg="The \"TAG\" variable is not set.""# + "\nerror while interpolating services.api.image: required variable TAG is missing a value\n")
        try write("services:\n  api:\n    image: ${TAG:?}\n", to: "a")
        try await eventually("Compose's words") { model.error == "error while interpolating services.api.image: required variable TAG is missing a value" }
        XCTAssertEqual(model.project?.name, "a", "the last good read stays")
        failure = nil
        try write("services:\n  api:\n    image: nginx\n", to: "a")
        try await eventually("a good read clears it") { model.error == nil }
        XCTAssertEqual(model.project?.name, "a")
    }

    func testNoComposeFileNothingRead() async throws {
        model.update(checkout: folder("empty"), shown: true)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(calls, [])
        XCTAssertNil(model.project)
        XCTAssertEqual(model.reads, 0)
        try write("services:\n  web:\n    image: nginx\n", to: "empty")
        try await eventually("a compose file made is read") { model.project?.name == "empty" }
        XCTAssertEqual(calls.count, 1)
    }

    /// Every service under a profile that isn't on: Compose answers no
    /// service, and there is nothing for `up` to make.
    func testNoServiceIsNoPlan() async throws {
        answer = { _ in #"{"name":"prof","services":{}}"# }
        try await show("a")
        XCTAssertNil(model.project, "no project of 0/0 whose Up can only fail")
        XCTAssertNil(model.error)
    }

    /// What the View menu acts on while nothing shows Docker: only a plan
    /// read from the files as they are.
    func testWhetherWhatShowsIsCurrent() async throws {
        XCTAssertFalse(model.isCurrent, "nothing read")
        try await show("a")
        XCTAssertTrue(model.isCurrent)
        model.update(checkout: folder("a"), shown: false)
        XCTAssertTrue(model.isCurrent, "hidden, its files unchanged")
        try write("services:\n  api:\n    image: nginx\n    ports: [\"8080:80\"]\n", to: "a")
        XCTAssertNotNil(model.project, "what was read stays")
        XCTAssertFalse(model.isCurrent, "but it isn't what the files say now")
        model.update(checkout: folder("b"), shown: false)
        XCTAssertFalse(model.isCurrent, "another checkout, never read")
        model.update(checkout: folder("a"), shown: true)
        try await eventually("shown, read again") { model.isCurrent }
    }

    func testANotAskedAnswerSaysNothing() async throws {
        answer = { _ in nil }
        try await show("a")
        XCTAssertNil(model.project)
        XCTAssertNil(model.error)
    }

    /// Against the fake engine: the plan until one of its containers exists,
    /// the labels' project then, the plan again after; one of its name from
    /// another folder is the page's row, and Up from here asks first.
    func testThePlanGivesWayToItsContainers() async throws {
        let socket = "/tmp/ot-compose-\(UUID().uuidString.prefix(8)).sock"
        let fake = FakeDockerEngine(socket: socket)
        try fake.start()
        defer { fake.stop() }
        let endpoint = DockerEndpoint(address: .unix(socket), context: nil, source: "test")
        let docker = DockerModel(endpoint: { endpoint }, retries: [.milliseconds(50)], poll: .milliseconds(200))
        docker.start()
        defer { docker.stop() }
        let compose = ComposeFileModel(docker: docker, latency: 0.05) { _, _ in Self.config("shop", services: ["db", "web"]) }
        defer { compose.update(checkout: nil, shown: false) }
        let panel = DockerPanelModel(docker: docker, checkoutCompose: compose)
        let page = DockerPageModel(docker: docker)
        page.checkoutCompose = compose
        let checkout = folder("a")
        let real = FileTreeModel.realPath(checkout)
        panel.checkout = checkout
        try await eventually("connected") { docker.connection.isRunning }
        compose.update(checkout: checkout, shown: true)
        try await eventually("the plan") { panel.plan?.name == "shop" }
        let planned = page.groups.first { $0.id == "project:shop" }
        XCTAssertEqual(planned?.project?.planned, true)
        XCTAssertEqual(planned?.services.map(\.name), ["db", "web"])
        XCTAssertEqual(planned?.containers, [])

        let web = fake.add(name: "shop-web-1", project: "shop", workingDir: real, service: "web")
        try await eventually("its containers' project takes over") { panel.plan == nil && panel.here.map(\.name) == ["shop"] }
        XCTAssertEqual(page.groups.filter { $0.id == "project:shop" }.map { $0.project?.planned }, [false], "one row, not two")
        try await docker.remove(web, force: true)
        try await eventually("gone again, the plan is back") { panel.plan != nil && page.planned != nil }

        // Started from its files under another name (`-p`, the shell's
        // COMPOSE_PROJECT_NAME): that is the stack, not a second one to make.
        let custom = fake.add(name: "custom-web-1", project: "custom", workingDir: real, service: "web")
        try await eventually("its files' project takes over") { panel.plan == nil && panel.here.map(\.name) == ["custom"] }
        XCTAssertNil(page.planned, "no second row whose Up makes the services again")
        XCTAssertEqual(page.groups.map(\.id), ["project:custom"])
        try await docker.remove(custom, force: true)
        try await eventually("gone, the plan is back") { panel.plan != nil && page.planned != nil }

        let elsewhere = fake.add(name: "shop-db-1", state: .exited, project: "shop", workingDir: "/elsewhere/shop", service: "db")
        try await eventually("one of its name from another folder") { docker.projects.map(\.name) == ["shop"] }
        XCTAssertNil(page.planned, "the page lists that one: a row a name")
        XCTAssertEqual(page.groups.filter { $0.id == "project:shop" }.map { $0.project?.workingDir }, ["/elsewhere/shop"])
        XCTAssertEqual(panel.plan?.workingDir, real, "the panel still has this checkout's")
        XCTAssertEqual(panel.planElsewhere?.workingDir, "/elsewhere/shop")

        var commands: [(String, URL?)] = []
        var asked: [String] = []
        page.actions = DockerActions(
            run: { commands.append(($0, $1)) },
            confirm: { title, _, _, then in
                asked.append(title)
                then()
            }, open: { _ in }, copy: { _ in }, settings: {})
        let plan = try XCTUnwrap(panel.plan)
        page.verbs(for: plan).first { $0.key == "u" }?.perform()
        XCTAssertEqual(asked, ["Up “shop” from this checkout?"], "Compose would take that stack over")
        XCTAssertEqual(commands.map(\.0), ["docker compose up -d"])
        XCTAssertEqual(commands.first?.1.map(FileTreeModel.realPath), real, "in the checkout")
        try await docker.remove(elsewhere, force: true)
    }
}

/// What a project's files say that its labels don't — what Compose
/// watches, its profiles — asked of a stub `docker` as Compose v5.6
/// answers; and the page asking once a change of its files.
final class ComposeFactsTests: XCTestCase {
    /// What Compose v5.6.0 printed for `config --format json`, trimmed.
    static let config = """
        {"name":"shop","services":{"db":{"image":"postgres:16","environment":{"POSTGRES_PASSWORD":"hunter2"}},\
        "web":{"build":{"context":"/w/shop","dockerfile":"Dockerfile"},"develop":{"watch":[\
        {"path":"/w/shop/src","action":"sync","target":"/app/src"},{"path":"/w/shop/package.json","action":"rebuild"}]}},\
        "api":{"develop":{}},"job":{"develop":{"watch":[]}}}}
        """

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ot-facts-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        DockerCLI.override = nil
        try FileManager.default.removeItem(at: root)
    }

    /// A project as its containers' labels say it, its files in `folder`.
    private func project(_ name: String = "shop", in folder: String, files: [String] = ["compose.yaml"]) -> ComposeProject {
        let labels = [
            "com.docker.compose.project": name, "com.docker.compose.service": "web", "com.docker.compose.container-number": "1",
            "com.docker.compose.oneoff": "False", "com.docker.compose.project.working_dir": folder,
            "com.docker.compose.project.config_files": files.map { folder + "/" + $0 }.joined(separator: ","),
        ]
        let web = ContainerSummary(Id: "\(name)-web-1-id", Names: ["/\(name)-web-1"], Image: "x", Created: 1, Labels: labels, State: "running", Status: "Up")
        return ComposeProjects.group([web]).projects[0]
    }

    /// A stub `docker` in the test's folder: `script` is its case's arms.
    private func stub(_ script: String) throws -> URL {
        let tool = root.appendingPathComponent("bin-\(UUID().uuidString.prefix(4))/docker")
        try FileManager.default.createDirectory(at: tool.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\necho \"$*\" >> \"\(root.path)/calls\"\ncase \"$*\" in\n\(script)\n*) echo \"unexpected: $*\" >&2; exit 1 ;;\nesac\n"
            .write(to: tool, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        return tool
    }

    private var calls: [String] {
        ((try? String(contentsOf: root.appendingPathComponent("calls"), encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    private var answering: String {
        try! Self.config.write(to: root.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)
        return """
            *" config --format json"*) cat "\(root.path)/config.json" ;;
            *" config --profiles"*) printf 'jobs\\ndebug\\n' ;;
            """
    }

    func testWhatComposeWatches() {
        XCTAssertEqual(ComposeFacts.watched(fromConfig: Self.config), ["web"], "a develop with no watch rule watches nothing")
        XCTAssertNil(ComposeFacts.watched(fromConfig: "not json"))
        XCTAssertEqual(ComposeFacts.watched(fromConfig: #"{"name":"x","services":{}}"#), [])
        let parsed = try? ComposeConfig.parse(Self.config)
        XCTAssertFalse(String(describing: parsed).contains("hunter2"), "only names are kept")
    }

    func testProfilesOneALine() {
        XCTAssertEqual(ComposeFacts.profiles(fromList: "jobs\ndebug\n\n tools \njobs\n"), ["debug", "jobs", "tools"])
        XCTAssertEqual(ComposeFacts.profiles(fromList: ""), [])
    }

    func testTheArgumentsNameTheFiles() {
        let shop = project(in: "/w/shop", files: ["compose.yaml", "compose.override.yaml"])
        XCTAssertEqual(ComposeFacts.arguments(shop), ["compose", "-p", "shop", "-f", "/w/shop/compose.yaml", "-f", "/w/shop/compose.override.yaml"])
    }

    func testTheStampFollowsTheFilesAndEnv() throws {
        let folder = root.path
        let file = root.appendingPathComponent("compose.yaml")
        try "services:\n  web:\n    image: nginx\n".write(to: file, atomically: true, encoding: .utf8)
        let shop = project(in: folder)
        let first = try XCTUnwrap(ComposeFacts.stamp(shop))
        XCTAssertEqual(ComposeFacts.stamp(shop), first, "nothing changed, the same")
        try "COMPOSE_PROFILES=jobs\n".write(to: root.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
        let withEnv = try XCTUnwrap(ComposeFacts.stamp(shop))
        XCTAssertNotEqual(withEnv, first, ".env counts")
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(3600)], ofItemAtPath: file.path)
        XCTAssertNotEqual(ComposeFacts.stamp(shop), withEnv, "a file saved again counts")
        XCTAssertNil(ComposeFacts.stamp(project(in: "/nowhere/shop")), "none of its files on this Mac: Compose isn't asked")
        var planned = shop
        planned.planned = true
        XCTAssertNil(ComposeFacts.stamp(planned), "a project before it runs is its plan's")
    }

    /// Compose names a linked file by the link; it is the target that is
    /// edited, so the target is what is stamped.
    func testALinkedFileIsStampedByItsTarget() throws {
        let folder = root.appendingPathComponent("linked", isDirectory: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("docker"), withIntermediateDirectories: true)
        let target = folder.appendingPathComponent("docker/compose.dev.yaml")
        let env = folder.appendingPathComponent(".env.local")
        try "services:\n  web:\n    image: nginx\n".write(to: target, atomically: true, encoding: .utf8)
        try "COMPOSE_PROFILES=jobs\n".write(to: env, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: folder.appendingPathComponent("compose.yaml").path, withDestinationPath: "docker/compose.dev.yaml")
        try FileManager.default.createSymbolicLink(atPath: folder.appendingPathComponent(".env").path, withDestinationPath: ".env.local")
        let shop = project(in: folder.path)
        let first = try XCTUnwrap(ComposeFacts.stamp(shop))
        XCTAssertEqual(Set(first.files.keys), [folder.path + "/compose.yaml", folder.path + "/.env"], "kept by the names Compose gave")
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(3600)], ofItemAtPath: target.path)
        let edited = try XCTUnwrap(ComposeFacts.stamp(shop))
        XCTAssertNotEqual(edited, first, "the linked compose file edited")
        try "COMPOSE_PROFILES=jobs,debug\n".write(to: env, atomically: true, encoding: .utf8)
        XCTAssertNotEqual(ComposeFacts.stamp(shop), edited, "the linked .env edited")
    }

    func testReadAsksComposeForBoth() async throws {
        let shop = project(in: "/w/shop")
        let stamp = ComposeFacts.Stamp(files: [:])
        let facts = await ComposeFacts.read(shop, stamp: stamp, cli: DockerCLI(executable: try stub(answering), endpoint: nil))
        XCTAssertEqual(facts.watched, ["web"])
        XCTAssertEqual(facts.built, ["web"], "the services with a build:")
        XCTAssertEqual(facts.profiles, ["debug", "jobs"])
        XCTAssertNil(facts.problem)
        XCTAssertEqual(
            Set(calls),
            [
                "compose -p shop -f /w/shop/compose.yaml config --format json --no-env-resolution",
                "compose -p shop -f /w/shop/compose.yaml config --profiles --no-env-resolution",
            ], "env files' contents left out")

        let broken = try stub(#"*) echo 'yaml: line 3: did not find expected node content' >&2; exit 1 ;;"#)
        let failed = await ComposeFacts.read(shop, stamp: stamp, cli: DockerCLI(executable: broken, endpoint: nil))
        XCTAssertEqual(failed.problem, "yaml: line 3: did not find expected node content", "Compose's own words")
        XCTAssertEqual(failed.watched, [])
        XCTAssertNil(failed.built, "not known: neither built nor pulled")
        XCTAssertEqual(failed.profiles, [])
        XCTAssertNil(failed.retry, "the files' problem stands until they change")
    }

    /// No answer in time, or a `docker` that doesn't start, isn't the
    /// files' problem: it is asked again.
    func testAProblemThatIsntTheFilesPasses() async throws {
        let shop = project(in: "/w/shop")
        let stamp = ComposeFacts.Stamp(files: [:])
        let slow = try stub(#"*) exec sleep 5 ;;"#)
        let started = Date()
        let late = await ComposeFacts.read(shop, stamp: stamp, cli: DockerCLI(executable: slow, endpoint: nil), timeout: 0.3)
        XCTAssertLessThan(Date().timeIntervalSince(started), 4, "not waited out")
        XCTAssertEqual(late.problem, "docker compose config didn't answer in time.")
        XCTAssertNotNil(late.retry)
        let missing = root.appendingPathComponent("nowhere/docker")
        let gone = await ComposeFacts.read(shop, stamp: stamp, cli: DockerCLI(executable: missing, endpoint: nil))
        XCTAssertNotNil(gone.problem)
        XCTAssertNotNil(gone.retry, "env's 127: no docker there")
        XCTAssertFalse(ComposeFacts.isTheFiles(GitError(arguments: [], status: -1, stderr: "")))
        XCTAssertFalse(ComposeFacts.isTheFiles(CancellationError()))
        XCTAssertTrue(ComposeFacts.isTheFiles(GitError(arguments: [], status: 15, stderr: "")))
    }

    /// The page asks when a project's verbs are drawn — once, not at every
    /// draw — and again when its files change; Watch and Up With
    /// Profiles… are offered from the answer, and do what they say.
    @MainActor
    func testThePageAsksOnceAChangeAndOffersWhatTheFilesSay() async throws {
        let file = root.appendingPathComponent("compose.yaml")
        try "services:\n  web:\n    build: .\n".write(to: file, atomically: true, encoding: .utf8)
        DockerCLI.override = try stub(answering)
        let shop = project(in: root.path)
        let page = DockerPageModel(docker: DockerModel(endpoint: { nil }))
        var commands: [(String, URL?)] = []
        page.actions = DockerActions(run: { commands.append(($0, $1)) }, confirm: { _, _, _, _ in }, open: { _ in }, copy: { _ in }, settings: {})
        func titles() -> [String] { page.verbs(for: shop).map(\.title) }
        func until(_ what: String, _ condition: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(5)
            while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
            XCTAssertTrue(condition(), what)
        }

        XCTAssertFalse(titles().contains("Watch in a Tab"), "not known yet: a read starts, nothing is published from a body")
        try await until("read") { page.composeFacts["shop"] != nil }
        XCTAssertEqual(page.composeFacts["shop"]?.watched, ["web"])
        _ = titles()
        _ = titles()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(calls.count, 2, "read once, not at every draw")
        let verbs = page.verbs(for: shop)
        XCTAssertEqual(verbs.first { $0.title == "Watch in a Tab" }?.place, .button)
        XCTAssertEqual(verbs.first { $0.title == "Watch in a Tab" }?.key, "w")
        XCTAssertTrue(verbs.contains { $0.title == "Up With Profiles…" })

        let why = await page.watch(shop)
        XCTAssertNil(why)
        XCTAssertEqual(commands.last?.0, "docker compose -p shop -f \(root.path)/compose.yaml watch")
        XCTAssertEqual(commands.last?.1?.path, root.path, "in the project's folder")

        page.chooseProfiles(shop, ["debug", "jobs"])
        XCTAssertEqual(page.profileChoice?.chosen, [], "nothing ticked the first time")
        page.upWithProfiles()
        XCTAssertEqual(commands.count, 1, "nothing ticked, nothing to up")
        page.profileChoice?.chosen = ["jobs"]
        XCTAssertEqual(page.profileChoice?.command(page.ports, endpoint: nil), "docker compose -p shop -f \(root.path)/compose.yaml --profile jobs up -d")
        page.upWithProfiles()
        XCTAssertNil(page.profileChoice)
        XCTAssertEqual(commands.last?.0, "docker compose -p shop -f \(root.path)/compose.yaml --profile jobs up -d")
        page.chooseProfiles(shop, ["debug", "jobs"])
        XCTAssertEqual(page.profileChoice?.chosen, ["jobs"], "ticked as last time")
        page.profileChoice = nil

        // The files changed: asked again; none watched, Watch says why.
        try #"{"name":"shop","services":{"web":{"image":"nginx"}}}"#.write(to: root.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: file.path)
        _ = titles()
        try await until("read again") { page.composeFacts["shop"]?.watched == [] }
        XCTAssertEqual(calls.count, 4)
        XCTAssertFalse(titles().contains("Watch in a Tab"))
        let refused = await page.watch(shop)
        XCTAssertEqual(refused, "No service of shop has develop.watch: Compose watches only those.")
        XCTAssertEqual(commands.count, 2, "nothing typed")

        // Compose couldn't read them: kept, said, asked again once they change.
        DockerCLI.override = try stub(#"*) echo 'yaml: line 3: did not find expected node content' >&2; exit 1 ;;"#)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(120)], ofItemAtPath: file.path)
        let facts = await page.loadComposeFacts(shop)
        XCTAssertEqual(facts?.problem, "yaml: line 3: did not find expected node content")
        let unreadable = await page.watch(shop)
        XCTAssertEqual(unreadable, "Compose couldn't read shop's files: yaml: line 3: did not find expected node content")
    }

    /// A problem that isn't the files' is kept a while, not for the
    /// session: a view asks again once it is due, a key or a menu at once.
    @MainActor
    func testAProblemThatIsntTheFilesIsAskedAgain() async throws {
        try "services:\n  web:\n    build: .\n".write(to: root.appendingPathComponent("compose.yaml"), atomically: true, encoding: .utf8)
        DockerCLI.override = root.appendingPathComponent("nowhere/docker")
        let shop = project(in: root.path)
        let page = DockerPageModel(docker: DockerModel(endpoint: { nil }))
        page.actions = DockerActions(run: { _, _ in }, confirm: { _, _, _, _ in }, open: { _ in }, copy: { _ in }, settings: {})
        let failed = await page.loadComposeFacts(shop)
        XCTAssertNotNil(failed?.problem)
        XCTAssertNotNil(failed?.retry)
        _ = page.verbs(for: shop)
        XCTAssertNil(page.composeFactReads["shop"], "not due yet: a view's draw doesn't ask again")

        DockerCLI.override = try stub(answering)
        let asked = await page.loadComposeFacts(shop)
        XCTAssertEqual(asked?.watched, ["web"], "a key or a menu item asks at once")
        XCTAssertNil(asked?.retry)
        XCTAssertNil(page.composeFacts["shop"]?.problem)

        // Due again: the next draw asks.
        page.composeFacts["shop"] = ComposeFacts(stamp: try XCTUnwrap(ComposeFacts.stamp(shop)), problem: "late", retry: .distantPast)
        let before = calls.count
        XCTAssertFalse(page.verbs(for: shop).contains { $0.title == "Watch in a Tab" })
        XCTAssertNotNil(page.composeFactReads["shop"], "due: a draw asks again")
        let deadline = Date().addingTimeInterval(5)
        while page.composeFacts["shop"]?.problem != nil, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(page.composeFacts["shop"]?.watched, ["web"])
        XCTAssertEqual(calls.count, before + 2)
        XCTAssertTrue(page.verbs(for: shop).contains { $0.title == "Watch in a Tab" })
    }
}
