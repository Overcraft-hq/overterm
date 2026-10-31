import Foundation
import XCTest

@testable import Overterm

/// Docker's MCP tools, as an agent calls them, against the fake engine:
/// what they say, and that a secret never leaves in an answer. The writes
/// and the settings that gate them are the `docker` scenario's (an
/// isolated run, which may change settings).
@MainActor
final class DockerMCPTests: XCTestCase {
    private var fake: FakeDockerEngine!
    private var model: DockerModel!
    private var web = ""

    override func setUp() async throws {
        let socket = "/tmp/ot-docker-\(UUID().uuidString.prefix(8)).sock"
        fake = FakeDockerEngine(socket: socket)
        try fake.start()
        let endpoint = DockerEndpoint(address: .unix(socket), context: nil, source: "test")
        model = DockerModel(endpoint: { endpoint }, retries: [.milliseconds(50)])
        web = fake.add(
            name: "shop-web-1", image: "nginx:1.27", project: "shop", workingDir: "/w/shop", service: "web",
            ports: [DockerPort(IP: "0.0.0.0", PrivatePort: 80, PublicPort: 8080, Type: "tcp")],
            env: ["API_TOKEN=s3cr3t-value", "DATABASE_URL=postgres://app:hunter2@db/app", "PORT=80"])
        fake.add(name: "shop-db-1", image: "postgres:16", state: .exited, project: "shop", workingDir: "/w/shop", service: "db")
        model.start()
        let deadline = Date().addingTimeInterval(5)
        while model.containers.count < 2, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
    }

    override func tearDown() async throws {
        model.stop()
        fake.stop()
    }

    private func text(_ name: String, _ arguments: [String: Any] = [:], scans: DockerScoutScans? = nil) async throws -> String {
        let result = try await DockerMCP.call(name, arguments, docker: model, scans: scans ?? DockerScoutScans())
        return ((result["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
    }

    /// `docker_vulnerabilities`: a scan the user ran, read — never one
    /// started for an agent, whatever Settings lets agents do.
    func testVulnerabilitiesAreTheUsersScan() async throws {
        let scans = DockerScoutScans()
        scans.locate = { _ in
            XCTFail("an agent's question ran docker"); return nil
        }
        let before = try await text("docker_vulnerabilities", ["image": "nginx:1.27"], scans: scans)
        XCTAssertTrue(before.contains("nginx:1.27 hasn't been scanned"), before)
        XCTAssertTrue(scans.scans.isEmpty, "nothing started")
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/scout-cves.sarif.json")
        let report = try XCTUnwrap(DockerScoutReport.parse(try String(contentsOf: fixture, encoding: .utf8)))
        scans.finish("sha256:x", image: "nginx:1.27", .success(report))
        let after = try await text("docker_vulnerabilities", ["image": "nginx:1.27"], scans: scans)
        XCTAssertTrue(after.hasPrefix("nginx:1.27 — Docker Scout 1.17.1, scanned just now: 2 critical"), after)
        XCTAssertTrue(after.contains("CVE-2021-22945 critical 9.1"), after)
        XCTAssertTrue(after.contains("fixed in 7.74.0-1.3+deb11u2"), after)
        XCTAssertTrue(after.contains("https://scout.docker.com/v/CVE-2021-22945"), after)
        XCTAssertLessThan(after.range(of: "GHSA-67hx-6x53-jw92")!.lowerBound, after.range(of: "CVE-2023-5129")!.lowerBound, "the worst first")
        XCTAssertEqual(scans.scans.count, 1, "and still only the user's")
        scans.finish("sha256:y", image: "redis:7", .failure(.signedOut))
        let failed = try await text("docker_vulnerabilities", ["image": "redis:7"], scans: scans)
        XCTAssertTrue(failed.hasPrefix("The last scan of redis:7 failed: Docker Scout needs you signed in"), failed)
        do {
            _ = try await text("docker_vulnerabilities", [:], scans: scans)
            XCTFail("no image")
        } catch let error as BrowserMCP.ToolError {
            XCTAssertTrue(error.message.contains("“image”"), error.message)
        }
        let names = DockerMCP.tools.compactMap { $0["name"] as? String }
        XCTAssertTrue(names.contains("docker_vulnerabilities"))
        XCTAssertFalse(DockerMCP.writes.contains("docker_vulnerabilities"))
    }

    /// A long report — 400 findings, Go's long advisory links, as a full
    /// image has — fits the answer by its end: the image, the totals and
    /// the critical ones stay, and it says how many more there are.
    func testALongReportKeepsItsHead() throws {
        let findings = (0..<400).map { index in
            let severity: DockerScoutSeverity = index < 100 ? .critical : index < 200 ? .high : index < 300 ? .medium : .low
            return DockerScoutFinding(
                vulnerability: "CVE-2024-\(10_000 + index)", severity: severity, score: 9.1,
                package: DockerScoutPackage(purl: "pkg:golang/golang.org/x/net\(index)@v0.0.0-20220127200216-cd36cc0744dd") ?? DockerScoutPackage(name: "net"),
                fixedIn: "0.17.0",
                advisory: URL(
                    string: "https://scout.docker.com/v/CVE-2024-\(10_000 + index)?s=github&n=net&ns=golang.org%2Fx&t=golang&vr=%3C0.17.0&p="
                        + String(repeating: "x", count: 80)))
        }
        let report = DockerScoutReport(findings: findings, scoutVersion: "1.17.1")
        let scan = DockerScoutScans.Scan(imageID: "sha256:x", image: "app:latest", state: .done(report, at: Date()))
        let text = DockerMCP.describeVulnerabilities(scan, image: "app:latest")
        XCTAssertLessThanOrEqual(text.count, 60_000)
        XCTAssertTrue(text.hasPrefix("app:latest — Docker Scout 1.17.1, scanned just now: 100 critical, 100 high"), String(text.prefix(200)))
        let lines = text.split(separator: "\n")
        XCTAssertTrue(lines[1].hasPrefix("- CVE-2024-10000 critical 9.1: golang.org/x/net0"), String(lines[1]))
        let shown = lines.filter { $0.hasPrefix("- ") }.count
        XCTAssertLessThan(shown, 300, "cut by its length")
        XCTAssertEqual(lines.last.map(String.init), "… and \(400 - shown) more")
    }

    /// `docker_image_updates`: the user's last Check for Updates, read —
    /// never a registry asked for an agent.
    func testImageUpdatesAreTheUsersLastCheck() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ot-mcp-updates-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let tool = root.appendingPathComponent("docker")
        let newer = "sha256:" + String(repeating: "b", count: 64)
        try """
        #!/bin/sh
        echo "$*" >> "\(root.path)/calls"
        case "$*" in
          "buildx imagetools inspect nginx:1.27") printf 'Name:      docker.io/library/nginx:1.27\\nMediaType: application/vnd.docker.distribution.manifest.v2+json\\nDigest:    \(newer)\\n' ;;
          *) exit 1 ;;
        esac
        """.write(to: tool, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        fake.addImage("nginx:1.27", size: 1, digest: "sha256:" + String(repeating: "a", count: 64))
        let updates = DockerImageUpdates(docker: model, cli: { _ in DockerCLI(executable: tool, endpoint: nil) })
        func told(_ arguments: [String: Any] = [:]) async throws -> String {
            let result = try await DockerMCP.call("docker_image_updates", arguments, docker: model, updates: updates)
            return ((result["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        }
        let before = try await told()
        XCTAssertTrue(before.hasPrefix("Nothing checked yet"), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("calls").path), "an agent asks no registry")
        await updates.check(["nginx:1.27"])
        let after = try await told()
        XCTAssertTrue(after.contains("- nginx:1.27: newer in its registry (\(newer))"), after)
        XCTAssertTrue(after.contains("checked just now"), after)
        XCTAssertTrue(after.contains("used by shop/web"), after)
        let shop = try await told(["project": "shop"])
        XCTAssertTrue(shop.contains("nginx:1.27"), shop)
        let calls = (try? String(contentsOf: root.appendingPathComponent("calls"), encoding: .utf8)) ?? ""
        XCTAssertEqual(calls.split(separator: "\n").count, 1, "reading the answers asked nothing")
    }

    /// Which Testcontainers run a container is for, on its line.
    func testContainersSayTheirTestRun() {
        func summary(_ name: String, image: String = "postgres:16-alpine", _ labels: [String: String]) -> ContainerSummary {
            ContainerSummary(Id: name + "-id", Names: ["/" + name], Image: image, Created: 1, Labels: labels, State: "running", Status: "Up 1 minute")
        }
        let told = DockerMCP.describe([
            summary("tc-pg", ["org.testcontainers": "true", "org.testcontainers.sessionId": "3f2a9c1e-0b5d-4c8e-9a7f-2d6e1b0c4a11"]),
            summary("testcontainers-ryuk-3f2a9c1e", image: "testcontainers/ryuk:0.14.0", ["org.testcontainers": "true"]),
            summary("tc-kept", ["org.testcontainers": "true", "org.testcontainers.hash": "a1b2"]),
            summary("plain", [:]),
        ])
        let lines = told.split(separator: "\n").map(String.init)
        XCTAssertTrue(lines[0].hasSuffix(" — Testcontainers run 3f2a9c1e"), lines[0])
        XCTAssertTrue(lines[1].contains("Testcontainers' reaper (Ryuk)"), lines[1])
        XCTAssertTrue(lines[2].contains("Testcontainers, kept for reuse"), lines[2])
        XCTAssertFalse(lines[3].contains("Testcontainers"), lines[3])
    }

    func testContainersAndProjects() async throws {
        let list = try await text("docker_containers")
        XCTAssertTrue(list.contains("shop-web-1: nginx:1.27"), list)
        XCTAssertTrue(list.contains("localhost:8080→80"), list)
        XCTAssertTrue(list.contains("compose shop/web"), list)
        let running = try await text("docker_containers", ["all": false])
        XCTAssertFalse(running.contains("shop-db-1"), running)
        let projects = try await text("docker_projects")
        XCTAssertTrue(projects.contains("shop (1/2 running) in /w/shop"), projects)
        // A stack Overterm put on ports of its own: what moved, and its Up.
        let moved = ComposePortOverride(
            folder: "/w/shop", project: "shop", fileName: "shop", baseFiles: ["/w/shop/compose.yaml"],
            moves: [ComposePortMove(service: "web", target: 80, proto: "tcp", from: 8080, to: 18080)], made: Date())
        let told = DockerMCP.describe(model.projects, overrides: ["shop": moved]) { _ in "docker compose -p shop -f /w/shop/compose.yaml -f /o/shop.yaml up -d" }
        XCTAssertTrue(told.contains("Ports of its own (Overterm moved them for this checkout): web 8080 → 18080. Reach them there."), told)
        XCTAssertTrue(told.contains("Overterm's Up runs: docker compose -p shop -f /w/shop/compose.yaml -f /o/shop.yaml up -d"), told)
        XCTAssertFalse(DockerMCP.describe(model.projects).contains("of its own"), "none moved: nothing said")
    }

    /// What `docker_compose` runs: a service narrows it, rebuild is up
    /// --build, down takes the whole project.
    func testComposeOneServiceOrRebuild() throws {
        let deadline = Date().addingTimeInterval(5)
        while model.projects.first?.services.count != 2, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        let shop = try XCTUnwrap(model.projects.first { $0.name == "shop" })
        func command(_ action: String, _ service: String? = nil) throws -> String {
            try DockerMCP.composeCommand(shop, action: action, service: service, endpoint: nil)
        }
        XCTAssertEqual(try command("rebuild", "web"), "docker compose -p shop -f /w/shop/compose.yaml up -d --build web")
        XCTAssertEqual(try command("up"), "docker compose -p shop -f /w/shop/compose.yaml up -d")
        XCTAssertEqual(try command("restart", "db"), "docker compose -p shop restart db")
        XCTAssertThrowsError(try command("down", "web")) { XCTAssertTrue("\($0)".contains("down takes the whole project"), "\($0)") }
        XCTAssertThrowsError(try command("restart", "nope")) { XCTAssertTrue("\($0)".contains("db, web"), "\($0)") }
        XCTAssertThrowsError(try command("watch")) { XCTAssertTrue("\($0)".contains("up, rebuild, down"), "\($0)") }
    }

    func testLogsKeepSecretsOut() async throws {
        fake.log(web, "booting")
        fake.log(web, "[ERROR] auth with token s3cr3t-value failed", stream: .stderr)
        fake.log(web, "connecting to postgres://app:pa55word@db:5432/app")
        let logs = try await text("docker_logs", ["container": "shop-web-1"])
        XCTAssertFalse(logs.contains("pa55word"), "a URL's password, though no env holds it: \(logs)")
        XCTAssertTrue(logs.contains("postgres://app:••••••@db"), logs)
        XCTAssertTrue(logs.contains("booting"), logs)
        XCTAssertFalse(logs.contains("s3cr3t-value"), "a secret from its env is taken out: \(logs)")
        XCTAssertTrue(logs.contains("token •••••• failed"), logs)
        let errors = try await text("docker_logs", ["container": "shop-web-1", "level": "error"])
        XCTAssertFalse(errors.contains("booting"), errors)
    }

    /// `docker_exec`'s command may never end, or never stop writing: it
    /// is read so long and so much, and the answer says where it stopped.
    func testAnExecIsReadSoLongAndSoMuch() async throws {
        let engine = try XCTUnwrap(model.engine)
        let streams = fake.openStreams
        let endless = try await engine.exec(web, ["sh", "-c", "tail -f /dev/null"], limit: 1 << 20, timeout: .seconds(1))
        XCTAssertEqual(endless.stdout, "following\n")
        XCTAssertTrue(endless.running)
        XCTAssertTrue(endless.cut?.hasPrefix("not read past") == true, endless.cut ?? "read to its end")
        XCTAssertTrue(DockerMCP.execText(endless).hasPrefix("still running — not read past"), DockerMCP.execText(endless))
        let deadline = Date().addingTimeInterval(5)
        while fake.openStreams > streams, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(fake.openStreams, streams, "its connection closed")

        let flood = try await engine.exec(web, ["sh", "-c", "yes"], limit: 1 << 20, timeout: .seconds(10))
        XCTAssertTrue(flood.cut?.hasPrefix("output cut at") == true, flood.cut ?? "read whole")
        XCTAssertTrue(flood.stdout.hasPrefix("y\ny\n"))
        XCTAssertLessThan(flood.stdout.utf8.count, 2 << 20, "not the 4 MB it writes")
        XCTAssertTrue(DockerMCP.execText(flood).hasPrefix("exit 0 — output cut at"), DockerMCP.execText(flood))

        let quick = try await engine.exec(web, ["sh", "-c", "true"], limit: 1 << 20, timeout: .seconds(10))
        XCTAssertEqual(quick, .init(stdout: "", stderr: "", exitCode: 0))
        XCTAssertEqual(DockerMCP.execText(quick), "exit 0\n")
    }

    func testInspectMasksTheEnv() async throws {
        let inspect = try await text("docker_inspect", ["container": "shop-web-1"])
        XCTAssertTrue(inspect.contains("API_TOKEN=••••••"), inspect)
        XCTAssertTrue(inspect.contains("DATABASE_URL=postgres://app:••••••@db/app"), inspect)
        XCTAssertTrue(inspect.contains("PORT=80"), inspect)
        XCTAssertFalse(inspect.contains("hunter2") || inspect.contains("s3cr3t"), inspect)
    }

    /// Why a container was killed or is slow: its limits and restart
    /// policy, said with the rest — no secret with them.
    func testInspectSaysItsLimits() async throws {
        fake.setHostConfig(web) {
            $0.Memory = 512 << 20
            $0.NanoCpus = 1_500_000_000
            $0.RestartPolicy = .init(Name: "unless-stopped", MaximumRetryCount: 0)
        }
        let inspect = try await text("docker_inspect", ["container": "shop-web-1"])
        XCTAssertTrue(inspect.contains("Limits: memory \(DockerBytes.string(512 << 20, memory: true)), 1.5 CPUs"), inspect)
        XCTAssertTrue(inspect.contains("Restart: unless-stopped"), inspect)
        XCTAssertFalse(inspect.contains("s3cr3t-value"), inspect)
        fake.setHostConfig(web) { $0 = .init(RestartPolicy: .init(Name: "no", MaximumRetryCount: 0)) }
        let plain = try await text("docker_inspect", ["container": "shop-web-1"])
        XCTAssertFalse(plain.contains("Limits:") || plain.contains("Restart:"), "nothing set, nothing said")
    }

    /// `docker_update` past its setting's gate (Settings ▸ Docker is the
    /// scenario's): asked before anything is sent, nothing sent when
    /// declined or when nothing would change, `on-failure:N` read as N
    /// and a count that isn't one refused.
    func testAnUpdateIsAskedFirstAndReadAsTheCLIWouldSayIt() async throws {
        let target = try XCTUnwrap(model.container(web))
        let engine = try XCTUnwrap(model.engine)
        func update(_ arguments: [String: Any]) async throws -> String {
            let result = try await DockerMCP.update(target, arguments, docker: model, engine: engine)
            return ((result["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        }
        func refusal(_ arguments: [String: Any]) async -> String? {
            do {
                _ = try await update(arguments)
                return nil
            } catch {
                return (error as? BrowserMCP.ToolError)?.message ?? "\(error)"
            }
        }
        func updates() -> Int { fake.requests.filter { $0.hasPrefix("POST") && $0.contains("/update") }.count }
        defer { DockerMCP.askOverride = nil }

        var asked: [String] = []
        DockerMCP.askOverride = { question in
            asked.append(question)
            return false
        }
        let declined = await refusal(["restart": "on-failure:3"])
        XCTAssertTrue(declined?.contains("declined") == true, declined ?? "done")
        XCTAssertEqual(fake.hostConfig(web)?.RestartPolicy?.Name, "no", "declined: unchanged")
        XCTAssertEqual(updates(), 0, "nothing sent")
        XCTAssertTrue(asked.last?.contains("docker update --restart on-failure:3 shop-web-1") == true, asked.last ?? "not asked")

        var policyWhenAsked: String?
        DockerMCP.askOverride = { question in
            asked.append(question)
            policyWhenAsked = self.fake.hostConfig(self.web)?.RestartPolicy?.Name
            return true
        }
        let done = try await update(["restart": "on-failure:3"])
        XCTAssertEqual(policyWhenAsked, "no", "asked before it is sent")
        XCTAssertEqual(fake.hostConfig(web)?.RestartPolicy, .init(Name: "on-failure", MaximumRetryCount: 3))
        XCTAssertTrue(done.contains("restarts on failure, 3 times at most"), done)
        XCTAssertTrue(done.contains("Compose puts back what shop's file says"), done)

        let asks = asked.count
        let sent = updates()
        let same = try await update(["restart": "on-failure:3"])
        XCTAssertTrue(same.contains("already has those settings"), same)
        XCTAssertEqual(asked.count, asks, "nothing to ask")
        XCTAssertEqual(updates(), sent, "nothing sent")

        let unreadable = await refusal(["restart": "on-failure:x"])
        XCTAssertTrue(unreadable?.contains("0 or more times") == true, unreadable ?? "taken")
        XCTAssertEqual(fake.hostConfig(web)?.RestartPolicy?.MaximumRetryCount, 3, "never read as no limit")
        let huge = await refusal(["cpus": 1e12])
        XCTAssertTrue(huge?.contains("CPUs") == true, huge ?? "taken")
        XCTAssertEqual(updates(), sent)
    }

    /// An amd64 image on this arm64 engine: inspect says it runs
    /// emulated and what runs it natively; the list marks it.
    func testAnEmulatedContainerSaysSo() async throws {
        let legacy = fake.addImage("legacy:1", size: 1, architecture: "amd64")
        fake.add(name: "legacy", image: "legacy:1", imageID: legacy)
        let deadline = Date().addingTimeInterval(5)
        while model.container("legacy") == nil, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        let inspect = try await text("docker_inspect", ["container": "legacy"])
        XCTAssertTrue(inspect.contains("Platform: linux/amd64 — emulated on this linux/arm64 engine"), inspect)
        XCTAssertTrue(inspect.contains("linux/arm64 variant, if it has one, runs natively"), inspect)
        let list = try await text("docker_containers")
        XCTAssertTrue(list.contains("legacy: legacy:1") && list.contains("emulated: linux/amd64"), list)
        let web = list.split(separator: "\n").first { $0.contains("shop-web-1") } ?? ""
        XCTAssertFalse(web.contains("emulated"), "an image the engine doesn't hold says nothing: \(web)")
        let shop = try await text("docker_inspect", ["container": "shop-web-1"])
        XCTAssertFalse(shop.contains("Platform:"), shop)
    }

    func testStatsAndMistakes() async throws {
        let stats = try await text("docker_stats", ["container": "shop-web-1"])
        XCTAssertTrue(stats.contains("CPU 8.0%"), stats)
        let stopped = try await text("docker_stats", ["container": "shop-db-1"])
        XCTAssertEqual(stopped, "shop-db-1 isn't running.")
        do {
            _ = try await text("docker_logs", ["container": "nope"])
            XCTFail("no such container")
        } catch let error as BrowserMCP.ToolError {
            XCTAssertTrue(error.message.contains("shop-web-1"), "it names the ones there are: \(error.message)")
        }
    }
}
