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

    private func text(_ name: String, _ arguments: [String: Any] = [:]) async throws -> String {
        let result = try await DockerMCP.call(name, arguments, docker: model)
        return ((result["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
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
        let logs = try await text("docker_logs", ["container": "shop-web-1"])
        XCTAssertTrue(logs.contains("booting"), logs)
        XCTAssertFalse(logs.contains("s3cr3t-value"), "a secret from its env is taken out: \(logs)")
        XCTAssertTrue(logs.contains("token •••••• failed"), logs)
        let errors = try await text("docker_logs", ["container": "shop-web-1", "level": "error"])
        XCTAssertFalse(errors.contains("booting"), errors)
    }

    func testInspectMasksTheEnv() async throws {
        let inspect = try await text("docker_inspect", ["container": "shop-web-1"])
        XCTAssertTrue(inspect.contains("API_TOKEN=••••••"), inspect)
        XCTAssertTrue(inspect.contains("DATABASE_URL=postgres://app:••••••@db/app"), inspect)
        XCTAssertTrue(inspect.contains("PORT=80"), inspect)
        XCTAssertFalse(inspect.contains("hunter2") || inspect.contains("s3cr3t"), inspect)
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
