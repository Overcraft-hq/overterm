import Combine
import Foundation
import XCTest

@testable import Overterm

/// The app's Docker model against the fake engine: what it lists and how it
/// groups it, kept current by events, an engine that goes and comes back.
@MainActor
final class DockerModelTests: XCTestCase {
    private var fake: FakeDockerEngine!
    private var model: DockerModel!
    private var socket = ""

    override func setUp() async throws {
        socket = "/tmp/ot-docker-\(UUID().uuidString.prefix(8)).sock"
        fake = FakeDockerEngine(socket: socket)
        try fake.start()
        let endpoint = DockerEndpoint(address: .unix(socket), context: nil, source: "test")
        model = DockerModel(endpoint: { endpoint }, retries: [.milliseconds(50)], poll: .milliseconds(200))
    }

    override func tearDown() async throws {
        model.stop()
        fake.stop()
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

    private func shop(in folder: String = "/Users/me/shop") {
        fake.add(name: "shop-web-1", project: "shop", workingDir: folder, service: "web")
        fake.add(name: "shop-db-1", image: "postgres:16", project: "shop", workingDir: folder, service: "db", health: "healthy")
        fake.add(name: "redis", image: "redis:7")
    }

    func testItListsAndGroups() async throws {
        shop()
        model.start()
        try await eventually("three containers") { model.containers.count == 3 }
        XCTAssertEqual(model.connection, .running("1.47"))
        XCTAssertEqual(model.info?.ServerVersion, "29.0.0")
        XCTAssertEqual(model.projects.map(\.name), ["shop"])
        XCTAssertEqual(model.projects.first?.services.map(\.name), ["db", "web"])
        XCTAssertEqual(model.projects.first?.status, .running)
        XCTAssertEqual(model.loose.map(\.name), ["redis"])
        XCTAssertEqual(model.container("shop-db-1")?.health, "healthy")
    }

    func testEventsKeepItCurrent() async throws {
        shop()
        var heard: [String] = []
        let listening = model.events.sink { heard.append($0.verb) }
        defer { listening.cancel() }
        model.start()
        try await eventually("listed") { model.containers.count == 3 }
        try await eventually("listening") { fake.listening == 1 }
        let db = try XCTUnwrap(model.container("shop-db-1")).Id
        fake.set(db, state: .exited, exitCode: 1)
        try await eventually("the exit seen") { model.container(db)?.state == .exited }
        XCTAssertEqual(model.projects.first?.status, .partial)
        XCTAssertEqual(model.projects.first?.failing.map(\.name), ["shop-db-1"])
        XCTAssertEqual(heard, ["die"])
        fake.add(name: "new-one")
        try await eventually("a new container") { model.container("new-one") != nil }
        XCTAssertEqual(heard, ["die", "create"])
    }

    func testAnEngineThatGoesAwayIsRetried() async throws {
        shop()
        model.start()
        try await eventually("listed") { model.containers.count == 3 }
        fake.stop()
        try await eventually("down") {
            if case .down = model.connection { return true }
            return false
        }
        XCTAssertTrue(model.containers.isEmpty, "a stopped engine's containers aren't shown as if they were there")
        XCTAssertTrue(model.projects.isEmpty)
        try fake.start()
        try await eventually("back") { model.connection.isRunning && model.containers.count == 3 }
    }

    func testAnActionShowsAtOnce() async throws {
        shop()
        model.start()
        try await eventually("listed") { model.containers.count == 3 }
        let web = try XCTUnwrap(model.container("shop-web-1")).Id
        try await model.perform(.stop, on: web)
        XCTAssertEqual(model.container(web)?.state, .exited)
        do {
            try await model.remove(try XCTUnwrap(model.container("redis")).Id)
            XCTFail("a running container needs force")
        } catch let error as DockerError {
            XCTAssertEqual(error.status, 409)
        }
        try await model.remove(try XCTUnwrap(model.container("redis")).Id, force: true)
        XCTAssertNil(model.container("redis"))
    }

    /// Compose writes the folder resolved (`/private/var/…`); the tab's
    /// folder may not be.
    func testACheckoutsProjectsAreFoundByItsRealPath() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ot-checkout-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("api"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let real = FileTreeModel.realPath(folder)
        XCTAssertNotEqual(real, folder.path, "the temporary folder is behind /var → /private/var")
        shop(in: real + "/api")
        fake.add(name: "other-web-1", project: "other", workingDir: "/Users/me/other", service: "web")
        model.start()
        try await eventually("listed") { model.containers.count == 4 }
        XCTAssertEqual(model.projects(in: folder).map(\.name), ["shop"])
        XCTAssertEqual(model.projects(in: URL(fileURLWithPath: "/Users/me")).map(\.name), ["other"])
    }

    func testNoEndpointIsOff() async throws {
        let off = DockerModel(endpoint: { nil })
        off.start()
        try await eventually("off") { off.connection == .off }
        XCTAssertTrue(off.containers.isEmpty)
        off.stop()
    }

    func testAMissingSocketSaysSo() async throws {
        let gone = DockerModel(
            endpoint: { DockerEndpoint(address: .unix("/tmp/ot-nothing-here.sock"), context: nil, source: "test") }, retries: [.seconds(60)])
        gone.start()
        try await eventually("down") {
            if case .down = gone.connection { return true }
            return false
        }
        XCTAssertEqual(gone.connection, .down("Docker Engine isn't running — no socket at /tmp/ot-nothing-here.sock."))
        gone.stop()
        XCTAssertEqual(gone.connection, .off)
    }

    /// The poll runs only while something shows Docker.
    func testThePollRunsWhileShown() async throws {
        shop()
        model.start()
        try await eventually("listed") { model.containers.count == 3 }
        let lists = { self.fake.requests.filter { $0.contains("/containers/json") }.count }
        model.show()
        let before = lists()
        try await eventually("two polls") { lists() - before >= 2 }
        model.hide()
        // A poll already on its way when it was hidden still lands.
        try await Task.sleep(for: .milliseconds(150))
        let after = lists()
        try await Task.sleep(for: .milliseconds(450))
        XCTAssertEqual(lists(), after, "no poll once hidden")
    }
}

/// Which events are a container going wrong on its own. Pure.
final class DockerAttentionTests: XCTestCase {
    private func event(_ action: String, _ id: String = "c1", _ attributes: [String: String] = [:]) -> DockerEvent {
        var all = ["name": "shop-web-1", "com.docker.compose.project.working_dir": "/w/shop"]
        all.merge(attributes) { $1 }
        return DockerEvent(Type: "container", Action: action, Actor: .init(ID: id, Attributes: all))
    }

    func testACrashIsNewsAndAStopAskedForIsNot() {
        var attention = DockerAttention()
        let now = Date()
        XCTAssertEqual(
            attention.note(event("die", "c1", ["exitCode": "1"]), at: now),
            .init(container: "shop-web-1", detail: "exited (1)", workingDir: "/w/shop"))
        XCTAssertNil(attention.note(event("die", "c1", ["exitCode": "0"]), at: now), "done with its work")
        XCTAssertNil(attention.note(event("kill", "c2", ["signal": "15"]), at: now))
        XCTAssertNil(attention.note(event("die", "c2", ["exitCode": "143"]), at: now.addingTimeInterval(10)), "docker stop")
        XCTAssertNil(attention.note(event("kill", "c3"), at: now))
        XCTAssertNotNil(attention.note(event("die", "c3", ["exitCode": "1"]), at: now.addingTimeInterval(60)), "a kill long before isn't this die's")
        XCTAssertNotNil(attention.note(event("die", "c2", ["exitCode": "1"]), at: now.addingTimeInterval(11)), "a kill is used up by its die")
    }

    func testOutOfMemoryAndUnhealthy() {
        var attention = DockerAttention()
        XCTAssertEqual(attention.note(event("oom", "c4"))?.detail, "ran out of memory")
        XCTAssertNil(attention.note(event("die", "c4", ["exitCode": "137"])), "said once, not twice")
        XCTAssertEqual(attention.note(event("health_status: unhealthy"))?.note, "shop-web-1 is unhealthy")
        XCTAssertNil(attention.note(event("health_status: healthy")))
        XCTAssertNil(attention.note(DockerEvent(Type: "image", Action: "delete", Actor: .init(ID: "x", Attributes: nil))))
    }

    func testWhoseCheckoutItIs() {
        XCTAssertTrue(DockerAttention.belongs("/w/shop", to: "/w/shop"))
        XCTAssertTrue(DockerAttention.belongs("/w/shop/deploy", to: "/w/shop"))
        XCTAssertTrue(DockerAttention.belongs("/w/shop", to: "/w/shop/services/api"), "a tab in a folder of the project")
        XCTAssertFalse(DockerAttention.belongs("/w/shop-2", to: "/w/shop"))
        XCTAssertFalse(DockerAttention.belongs("/w", to: "/"), "the root is nobody's checkout")
    }

    @MainActor
    func testAFailureMarksATabNotLooking() {
        var activity = TabActivity()
        XCTAssertFalse(activity.containerFailed("db exited (1)", visible: true), "seen as it happened")
        XCTAssertTrue(activity.containerFailed("db exited (1)", visible: false))
        XCTAssertEqual(activity.mark, .failed)
        XCTAssertEqual(activity.note, "db exited (1)")
        XCTAssertFalse(activity.containerFailed("db exited (1)", visible: false), "once until seen")
    }
}

/// Compose's labels, read into projects. Pure.
final class ComposeProjectsTests: XCTestCase {
    private func container(
        _ name: String, project: String? = nil, service: String? = nil, number: Int = 1, oneOff: Bool = false, state: String = "running",
        status: String = "Up 1 minute", created: Int = 1, dir: String? = nil, dependsOn: String? = nil
    ) -> ContainerSummary {
        var labels: [String: String] = [:]
        if let project {
            labels["com.docker.compose.project"] = project
            labels["com.docker.compose.service"] = service ?? name
            labels["com.docker.compose.container-number"] = "\(number)"
            labels["com.docker.compose.oneoff"] = oneOff ? "True" : "False"
            if let dir {
                labels["com.docker.compose.project.working_dir"] = dir
                labels["com.docker.compose.project.config_files"] = "\(dir)/compose.yaml,\(dir)/compose.override.yaml"
            }
            if let dependsOn { labels["com.docker.compose.depends_on"] = dependsOn }
        }
        return ContainerSummary(Id: name + "-id", Names: ["/" + name], Image: "x", Created: created, Labels: labels, State: state, Status: status)
    }

    func testProjectsServicesAndReplicas() {
        let (projects, loose) = ComposeProjects.group([
            container("shop-web-2", project: "shop", service: "web", number: 2, dir: "/w/shop", dependsOn: "db:service_healthy:false"),
            container("shop-web-1", project: "shop", service: "web", number: 1, dir: "/w/shop"),
            container("shop-web-run-1a2b", project: "shop", service: "web", oneOff: true, state: "exited", status: "Exited (0) 1 minute ago"),
            container("shop-db-1", project: "shop", service: "db", dir: "/w/shop"),
            container("blog-app-1", project: "blog", service: "app"),
            container("scratch"),
        ])
        XCTAssertEqual(projects.map(\.name), ["blog", "shop"])
        let shop = projects[1]
        XCTAssertEqual(shop.services.map(\.name), ["db", "web"])
        XCTAssertEqual(shop.services[1].containers.map(\.name), ["shop-web-1", "shop-web-2", "shop-web-run-1a2b"])
        XCTAssertEqual(shop.services[1].dependsOn, ["db"])
        XCTAssertEqual(shop.workingDir, "/w/shop")
        XCTAssertEqual(shop.configFiles, ["/w/shop/compose.yaml", "/w/shop/compose.override.yaml"])
        XCTAssertEqual(shop.status, .running, "a finished one-off doesn't make the stack partial")
        XCTAssertTrue(shop.failing.isEmpty)
        XCTAssertEqual(loose.map(\.name), ["scratch"])
    }

    func testStatusAndFailing() {
        let crashed = ComposeProjects.group([
            container("a-web-1", project: "a", service: "web"),
            container("a-db-1", project: "a", service: "db", state: "exited", status: "Exited (1) 5 seconds ago"),
            container("a-cache-1", project: "a", service: "cache", status: "Up 1 minute (unhealthy)"),
        ]).projects[0]
        XCTAssertEqual(crashed.status, .partial)
        XCTAssertEqual(Set(crashed.failing.map(\.name)), ["a-db-1", "a-cache-1"])
        let stopped = ComposeProjects.group([
            container("b-web-1", project: "b", service: "web", state: "exited", status: "Exited (0) 1 hour ago")
        ]).projects[0]
        XCTAssertEqual(stopped.status, .stopped)
        XCTAssertTrue(stopped.failing.isEmpty, "stopped cleanly is not failing")
    }

    /// A project made again elsewhere (another worktree with the folder's
    /// name) is where its newest container says.
    func testTheNewestContainerSaysWhereTheProjectIs() {
        let project = ComposeProjects.group([
            container("app-web-1", project: "app", service: "web", created: 10, dir: "/old/app"),
            container("app-db-1", project: "app", service: "db", created: 20, dir: "/new/app"),
        ]).projects[0]
        XCTAssertEqual(project.workingDir, "/new/app")
    }

    /// What a pane header shows for a checkout: running containers' TCP
    /// ports, each once, by number, named for their service.
    func testWhatACheckoutPublishes() {
        var web = container("a-web-1", project: "a", service: "web", dir: "/w/a")
        web.Ports = [
            DockerPort(IP: "0.0.0.0", PrivatePort: 80, PublicPort: 8080, Type: "tcp"), DockerPort(IP: "::", PrivatePort: 80, PublicPort: 8080, Type: "tcp"),
            DockerPort(IP: "0.0.0.0", PrivatePort: 53, PublicPort: 5353, Type: "udp"),
        ]
        var db = container("a-db-1", project: "a", service: "db", dir: "/w/a")
        db.Ports = [DockerPort(IP: "127.0.0.1", PrivatePort: 5432, PublicPort: 55432, Type: "tcp")]
        var stopped = container("a-cache-1", project: "a", service: "cache", state: "exited", status: "Exited (0) 1 minute ago", dir: "/w/a")
        stopped.Ports = [DockerPort(IP: "0.0.0.0", PrivatePort: 6379, PublicPort: 6379, Type: "tcp")]
        let ports = ComposeProjects.ports(of: ComposeProjects.group([web, db, stopped]).projects)
        XCTAssertEqual(ports.map(\.port), [8080, 55432])
        XCTAssertEqual(ports.map(\.process), ["web", "db"])
        XCTAssertEqual(ports.map(\.container), ["a-web-1", "a-db-1"])
        XCTAssertEqual(ports.first?.id, "a-web-1:8080", "not a pid's: there is none")
    }

    func testDependencies() {
        XCTAssertEqual(ComposeProjects.dependencies("db:service_started:false,cache:service_healthy:true"), ["db", "cache"])
        XCTAssertEqual(ComposeProjects.dependencies(""), [])
        XCTAssertEqual(ComposeProjects.dependencies(nil), [])
    }

    func testACheckoutHoldsWhatIsRunInItOrFromItsFiles() {
        let projects = ComposeProjects.group([
            container("a-web-1", project: "a", service: "web", dir: "/w/repo"),
            container("b-web-1", project: "b", service: "web", dir: "/w/repo/services/b"),
            container("c-web-1", project: "c", service: "web", dir: "/w/repo-other"),
            container("d-web-1", project: "d", service: "web", dir: "/elsewhere"),
        ]).projects
        var fromFile = projects[3]
        fromFile.configFiles = ["/w/repo/deploy/compose.yaml"]
        let all = Array(projects.prefix(3)) + [fromFile]
        XCTAssertEqual(ComposeProjects.projects(all, in: "/w/repo").map(\.name), ["a", "b", "d"])
        XCTAssertEqual(ComposeProjects.projects(all, in: "/w/repo/").map(\.name), ["a", "b", "d"])
        XCTAssertEqual(ComposeProjects.projects(all, in: "/w/repo/services/b").map(\.name), ["b"])
        XCTAssertTrue(ComposeProjects.projects(all, in: "/").isEmpty, "the root holds nothing in particular")
    }
}

/// Finding `docker` without a shell's PATH, telling it which engine, and
/// what the runtimes say of themselves.
final class DockerCLITests: XCTestCase {
    func testToolsAreLookedForWhereInstallersPutThem() {
        let home = URL(fileURLWithPath: "/Users/me")
        let folders = DockerCLI.folders(home: home, path: "/usr/bin:/bin:/usr/local/bin")
        XCTAssertEqual(Array(folders.prefix(3)), ["/usr/bin", "/bin", "/usr/local/bin"])
        XCTAssertEqual(folders.filter { $0 == "/usr/local/bin" }.count, 1)
        XCTAssertTrue(folders.contains("/Users/me/.docker/bin"))
        XCTAssertTrue(folders.contains("/Users/me/.orbstack/bin"))
        let found = DockerCLI.locate("docker", home: home, path: "/usr/bin") { $0 == "/Users/me/.orbstack/bin/docker" }
        XCTAssertEqual(found?.path, "/Users/me/.orbstack/bin/docker")
        XCTAssertNil(DockerCLI.locate("docker", home: home, path: nil) { _ in false })
    }

    func testTheCommandIsToldWhichEngine() {
        let docker = URL(fileURLWithPath: "/Users/me/.docker/bin/docker")
        let context = DockerEndpoint(address: .unix("/o.sock"), context: "orbstack", source: "context orbstack")
        XCTAssertEqual(DockerCLI.environment(for: context, executable: docker).first, "DOCKER_CONTEXT=orbstack")
        let host = DockerEndpoint(address: .tcp(host: "10.0.0.2", port: 2375), context: nil, source: "docker.endpoint")
        XCTAssertEqual(DockerCLI.environment(for: host, executable: docker).first, "DOCKER_HOST=tcp://10.0.0.2:2375")
        let plain = DockerCLI.environment(for: DockerEndpoint(address: .unix("/var/run/docker.sock"), context: nil, source: "default"), executable: docker)
        XCTAssertEqual(plain.count, 1)
        XCTAssertTrue(plain[0].hasPrefix("PATH=/Users/me/.docker/bin:"), "plugins and credential helpers beside it are found")
    }

    func testItRunsWithThatEnvironment() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ot-cli-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let tool = folder.appendingPathComponent("docker")
        try Data("#!/bin/sh\necho \"$DOCKER_CONTEXT|$*\"\n".utf8).write(to: tool)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        let cli = DockerCLI(executable: tool, endpoint: DockerEndpoint(address: .unix("/c.sock"), context: "colima", source: "context colima"))
        let output = try await cli.run(["desktop", "status", "--format", "json"])
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "colima|desktop status --format json")
    }

    func testWhatEachRuntimesOwnCLIDoesForIt() {
        let desktop = DockerRuntime.dockerDesktop.extras().map(\.command)
        XCTAssertTrue(desktop.contains("docker desktop update --check-only"))
        XCTAssertTrue(desktop.contains("docker desktop kubernetes status"))
        XCTAssertEqual(DockerRuntime.colima.extras(context: "colima-work").first?.command, "colima status --profile work")
        XCTAssertTrue(DockerRuntime.engine.extras().isEmpty)
    }

    func testWhereEachEngineKeepsItsSettings() {
        let home = URL(fileURLWithPath: "/Users/me")
        XCTAssertEqual(DockerRuntime.dockerDesktop.configFile(home: home)?.path, "/Users/me/.docker/daemon.json")
        XCTAssertEqual(DockerRuntime.orbStack.configFile(home: home)?.path, "/Users/me/.orbstack/config/docker.json")
        XCTAssertEqual(DockerRuntime.colima.configFile(context: "colima-work", home: home)?.path, "/Users/me/.colima/work/colima.yaml")
        XCTAssertEqual(DockerRuntime.colima.configFile(context: "colima", home: home)?.path, "/Users/me/.colima/default/colima.yaml")
        XCTAssertNil(DockerRuntime.engine.configFile(home: home))
    }

    func testRuntimesSayWhetherTheyAreUp() {
        XCTAssertEqual(DockerRuntime.dockerDesktop.status(fromOutput: #"{"PauseType":"","SessionID":"x","Status":"running"}"#), .running)
        XCTAssertEqual(DockerRuntime.dockerDesktop.status(fromOutput: #"{"PauseType":"","Status":"stopped"}"#), .stopped)
        XCTAssertEqual(DockerRuntime.dockerDesktop.status(fromOutput: #"{"PauseType":"resource-saver","Status":"running"}"#), .paused)
        XCTAssertEqual(DockerRuntime.dockerDesktop.status(fromOutput: "unknown command"), .unknown)
        XCTAssertEqual(DockerRuntime.orbStack.status(fromOutput: "Running\n"), .running)
        XCTAssertEqual(DockerRuntime.orbStack.status(fromOutput: "Stopped"), .stopped)
        XCTAssertEqual(DockerRuntime.colima.status(fromOutput: #"{"display_name":"colima","runtime":"docker"}"#), .running)
        XCTAssertEqual(DockerRuntime.colima.status(fromOutput: ""), .stopped)
        XCTAssertEqual(DockerRuntime.podman.status(fromOutput: "running"), .running)
        XCTAssertNil(DockerRuntime.engine.statusCommand())
        XCTAssertEqual(DockerRuntime.colima.statusCommand(context: "colima-work")?.arguments, ["status", "--json", "--profile", "work"])
    }

    /// Rancher Desktop through rdctl: its app's API says the VM's state.
    func testRancherDesktopThroughRdctl() {
        let rancher = DockerRuntime.rancherDesktop
        XCTAssertEqual(rancher.command(.start), "rdctl start")
        XCTAssertEqual(rancher.command(.stop), "rdctl shutdown")
        XCTAssertEqual(rancher.command(.restart), "rdctl shutdown && rdctl start")
        XCTAssertEqual(rancher.statusCommand()?.tool, "rdctl")
        XCTAssertEqual(rancher.statusCommand()?.arguments, ["api", "/v1/backend_state"])
        XCTAssertEqual(rancher.status(fromOutput: #"{"vmState":"STARTED","locked":false}"#), .running)
        XCTAssertEqual(rancher.status(fromOutput: #"{"vmState":"DISABLED","locked":false}"#), .running, "up, with Kubernetes off")
        XCTAssertEqual(rancher.status(fromOutput: #"{"vmState":"STARTING","locked":true}"#), .starting)
        XCTAssertEqual(rancher.status(fromOutput: #"{"vmState":"STOPPED","locked":false}"#), .stopped)
        XCTAssertEqual(rancher.status(fromOutput: #"{"vmState":"ERROR","locked":false}"#), .unknown)
        XCTAssertEqual(rancher.status(fromOutput: "Error: connection refused"), .unknown)
        XCTAssertEqual(rancher.extras().map(\.command), ["rdctl list-settings", "rdctl version"])
    }
}
