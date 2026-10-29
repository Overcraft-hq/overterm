import Foundation
import XCTest

@testable import Overterm

/// The Docker page's pure parts: the filter, the commands it types, its
/// keys, how the list is grouped and what a selection means.
final class DockerPageTests: XCTestCase {
    private func container(
        _ name: String, image: String = "nginx:1.27", project: String? = nil, service: String? = nil, state: String = "running",
        status: String = "Up 1 minute", ports: [DockerPort] = []
    ) -> ContainerSummary {
        var labels: [String: String] = [:]
        if let project {
            labels["com.docker.compose.project"] = project
            labels["com.docker.compose.service"] = service ?? name
            labels["com.docker.compose.project.config_files"] = "/w/\(project)/compose.yaml"
            labels["com.docker.compose.project.working_dir"] = "/w/\(project)"
        }
        return ContainerSummary(
            Id: name + "-0123456789", Names: ["/" + name], Image: image, Created: 1, Ports: ports, Labels: labels, State: state, Status: status)
    }

    // MARK: Filter

    func testFilterWords() {
        let web = container(
            "shop-web-1", project: "shop", service: "web", ports: [DockerPort(IP: "0.0.0.0", PrivatePort: 80, PublicPort: 8080, Type: "tcp")])
        let db = container("shop-db-1", image: "postgres:16", project: "shop", service: "db", state: "exited", status: "Exited (1) 1 minute ago")
        let redis = container("redis", image: "redis:7", status: "Up 1 minute (unhealthy)")
        func names(_ text: String) -> [String] { [web, db, redis].filter(DockerFilter(text).matches).map(\.name) }
        XCTAssertEqual(names(""), ["shop-web-1", "shop-db-1", "redis"])
        XCTAssertEqual(names("SHOP"), ["shop-web-1", "shop-db-1"], "any case")
        XCTAssertEqual(names("status:running"), ["shop-web-1", "redis"])
        XCTAssertEqual(names("is:stopped"), ["shop-db-1"])
        XCTAssertEqual(names("status:unhealthy"), ["redis"])
        XCTAssertEqual(names("image:postgres"), ["shop-db-1"])
        XCTAssertEqual(names("p:shop s:web"), ["shop-web-1"])
        XCTAssertEqual(names("port:8080"), ["shop-web-1"])
        XCTAssertEqual(names("port:80"), ["shop-web-1"], "the container's own port too")
        XCTAssertEqual(names("-project:shop"), ["redis"])
        XCTAssertEqual(names("-status:running shop"), ["shop-db-1"])
        XCTAssertEqual(names("redis-0123"), ["redis"], "an id's start")
        XCTAssertEqual(names("http://x"), [], "an unknown key is just text")
        XCTAssertEqual(names("status:"), names(""), "an empty value is nothing")
        XCTAssertEqual(names("-"), ["shop-web-1", "shop-db-1"], "a lone dash is text")

        // Testcontainers': by what marks them, and by their run.
        var pg = container("tc-pg", image: "postgres:16-alpine")
        pg.Labels = ["org.testcontainers": "true", "org.testcontainers.sessionId": "3f2a9c1e-0b5d-4c8e-9a7f-2d6e1b0c4a11"]
        func found(_ text: String) -> [String] { [web, db, redis, pg].filter(DockerFilter(text).matches).map(\.name) }
        XCTAssertEqual(found("is:test"), ["tc-pg"])
        XCTAssertEqual(found("is:tc"), ["tc-pg"])
        XCTAssertEqual(found("status:testcontainers"), ["tc-pg"])
        XCTAssertEqual(found("-is:test"), ["shop-web-1", "shop-db-1", "redis"])
        XCTAssertEqual(found("session:3F2A"), ["tc-pg"], "any case")
        XCTAssertEqual(found("tc:3f2a"), ["tc-pg"])
        XCTAssertEqual(found("session:ffff"), [])
    }

    // MARK: Commands

    func testCommandsAreQuotedAndToldTheEngine() {
        let project = ComposeProjects.group([
            container("my app-web-1", project: "my app", service: "web")
        ]).projects[0]
        XCTAssertEqual(DockerCommands.compose(project, "up -d"), "docker compose -p 'my app' -f '/w/my app/compose.yaml' up -d")
        XCTAssertEqual(DockerCommands.compose(project, "down"), "docker compose -p 'my app' down", "down finds it by name")
        let fake = DockerEndpoint(address: .unix("/tmp/fake.sock"), context: nil, source: "OVERTERM_DOCKER_HOST")
        XCTAssertEqual(DockerCommands.compose(project, "logs -f", endpoint: fake), "DOCKER_HOST=unix:///tmp/fake.sock docker compose -p 'my app' logs -f")
        let context = DockerEndpoint(address: .unix("/o.sock"), context: "orbstack", source: "context orbstack")
        XCTAssertEqual(DockerCommands.prefix(for: context), "", "the shell reads the same context")
        XCTAssertEqual(
            DockerCommands.shell(in: container("api")), "docker exec -it api sh -c 'command -v bash >/dev/null 2>&1 && exec bash || exec sh'")
        XCTAssertEqual(DockerCommands.followLogs(of: container("it's")), #"docker logs -f --tail 200 'it'\''s'"#)
        XCTAssertEqual(DockerCommands.quote("tcp://10.0.0.2:2375"), "tcp://10.0.0.2:2375")
        XCTAssertEqual(
            DockerCommands.debugShell(beside: container("api"), image: "nicolaka/netshoot"),
            "docker run --rm -it --pid container:api --network container:api --volumes-from api nicolaka/netshoot")
        XCTAssertEqual(DockerCommands.quote(""), "''")
        // A service's verbs, profiles: -f wherever Compose reads the files.
        XCTAssertEqual(
            DockerCommands.compose(project, "up -d --build", services: ["web"]), "docker compose -p 'my app' -f '/w/my app/compose.yaml' up -d --build web")
        XCTAssertEqual(DockerCommands.compose(project, "run --rm", services: ["web"]), "docker compose -p 'my app' -f '/w/my app/compose.yaml' run --rm web")
        XCTAssertEqual(
            DockerCommands.compose(project, "pull", services: ["web", "my svc"]), "docker compose -p 'my app' -f '/w/my app/compose.yaml' pull web 'my svc'",
            "Pull Updates: the services with one")
        XCTAssertEqual(
            TabKind.of(agent: nil, title: DockerCommands.compose(project, "run --rm", services: ["web"]), hasPort: false), .container,
            "the one-off's tab is a container's, its path quoted")
        XCTAssertEqual(DockerCommands.compose(project, "watch"), "docker compose -p 'my app' -f '/w/my app/compose.yaml' watch")
        XCTAssertEqual(
            DockerCommands.compose(project, "up -d", profiles: ["debug", "jobs"]),
            "docker compose -p 'my app' -f '/w/my app/compose.yaml' --profile debug --profile jobs up -d", "profiles before the verb")
        XCTAssertEqual(
            DockerCommands.compose(project, "logs -f --tail 100", services: ["web"]), "docker compose -p 'my app' logs -f --tail 100 web",
            "logs finds it by name")
        XCTAssertEqual(DockerCommands.compose(project, "pull", services: ["web"]), "docker compose -p 'my app' -f '/w/my app/compose.yaml' pull web")
        XCTAssertEqual(DockerCommands.compose(project, "restart", services: ["my web"]), "docker compose -p 'my app' restart 'my web'")
        // A stack on ports of its own: the files given, its override after the checkout's.
        let override = "/x/Application Support/Overterm/Compose/Ports/my-app-1a2b3c4d.yaml"
        XCTAssertEqual(
            DockerCommands.compose(project, "up -d", files: ["/w/my app/compose.yaml", override]),
            "docker compose -p 'my app' -f '/w/my app/compose.yaml' -f '\(override)' up -d")
        XCTAssertEqual(DockerCommands.compose(project, "down", files: [override]), "docker compose -p 'my app' down", "down ignores the files")
        XCTAssertEqual(
            DockerCommands.compose(name: "shop-wt-x", files: ["/w/x/compose.yaml", "/o/x.yaml"], "up -d", profiles: ["tools"], endpoint: fake),
            "DOCKER_HOST=unix:///tmp/fake.sock docker compose -p shop-wt-x -f /w/x/compose.yaml -f /o/x.yaml --profile tools up -d")
        XCTAssertEqual(DockerCommands.compose(name: nil, files: [], "up -d"), "docker compose up -d", "a checkout's: Compose names it")
    }

    // MARK: Keys

    func testKeys() {
        XCTAssertEqual(DockerKey.of("s"), .startStop)
        XCTAssertEqual(DockerKey.of("D"), .composeDown)
        XCTAssertEqual(DockerKey.of("d"), .database, "lower-case d is the Database panel, D compose down")
        XCTAssertEqual(DockerKey.of("\r"), .details)
        XCTAssertEqual(DockerKey.of(" "), .toggleDetail)
        XCTAssertEqual(DockerKey.of("\u{7F}"), .remove)
        XCTAssertEqual(DockerKey.of("?"), .help)
        XCTAssertEqual(DockerKey.of("b"), .rebuild)
        XCTAssertEqual(DockerKey.of("w"), .watch)
        XCTAssertEqual(DockerKey.of("U"), .composeUpFreePorts)
        XCTAssertEqual(DockerKey.of("u"), .composeUp)
        XCTAssertEqual(DockerKey.of("q"), .client)
        XCTAssertEqual(DockerKey.of("a"), .askAgent)
        XCTAssertEqual(DockerKey.of(","), .settings)
        XCTAssertEqual(DockerKey.of("f"), .files)
        XCTAssertEqual(DockerKey.of("C"), .checkUpdates, "C checks for updates, c cleans up")
        XCTAssertEqual(DockerKey.of("c"), .cleanUp)
        XCTAssertEqual(DockerKey.of("v"), .vulnerabilities)
        XCTAssertNil(DockerKey.of("x"))
        XCTAssertEqual(Set(DockerKey.allCases.map(\.key)).count, DockerKey.allCases.count, "no key twice")
    }

    // MARK: Logs

    func testTheLogFilter() {
        func line(_ message: String, _ level: DockerLogLine.Level?, _ stream: DockerLogChunk.Stream = .stdout) -> DockerLogLine {
            DockerLogLine(stream: stream, timestamp: nil, level: level, message: message, fields: [("user", "ayşe")], service: nil)
        }
        let lines = [
            line("GET / 200", .info), line("slow query", .warning), line("db down", .error), line("plain", nil), line("panic: x", nil, .stderr),
        ]
        func shown(_ filter: DockerLogFilter) -> [String] { lines.filter(filter.matches).map(\.message) }
        XCTAssertEqual(shown(DockerLogFilter()).count, 5)
        XCTAssertEqual(shown(DockerLogFilter(level: .warnings)), ["slow query", "db down", "panic: x"], "stderr's unlevelled lines count")
        XCTAssertEqual(shown(DockerLogFilter(level: .errors)), ["db down"])
        XCTAssertEqual(shown(DockerLogFilter(text: "DB")), ["db down"])
        XCTAssertEqual(shown(DockerLogFilter(text: "AYŞE")).count, 5, "a JSON line's fields are searched too")

        func said(_ message: String, by service: String) -> DockerLogLine {
            DockerLogLine(stream: .stdout, timestamp: nil, level: nil, message: message, fields: [], service: service)
        }
        let merged = [said("GET /", by: "web"), said("ready", by: "db"), said("GET /health", by: "web")]
        let web = DockerLogFilter(service: "web")
        XCTAssertFalse(web.isEmpty)
        XCTAssertEqual(merged.filter(web.matches).map(\.message), ["GET /", "GET /health"], "one service's lines")
        XCTAssertEqual(merged.filter(DockerLogFilter(text: "health", service: "web").matches).map(\.message), ["GET /health"], "with a word too")
        XCTAssertEqual(merged.filter(DockerLogFilter(text: "ready", service: "web").matches), [])

        // A service picked with nothing to show says so; a word that
        // matches nothing in all of them is the empty text, as before.
        func note(_ lines: Int, _ shown: Int, _ filter: DockerLogFilter = DockerLogFilter(), following: Bool = true) -> String? {
            DockerLogsPane.note(lines: lines, shown: shown, filter: filter, following: following)
        }
        XCTAssertEqual(note(0, 0), "Nothing written yet.")
        XCTAssertEqual(note(0, 0, following: false), "No logs.")
        XCTAssertNil(note(3, 3))
        XCTAssertNil(note(3, 0, DockerLogFilter(text: "nope")))
        XCTAssertEqual(note(3, 0, DockerLogFilter(service: "db")), "Nothing from db yet.")
        XCTAssertEqual(note(3, 0, DockerLogFilter(level: .errors, service: "db")), "Nothing from db matches.")
        XCTAssertNil(note(3, 1, DockerLogFilter(service: "db")))
    }

    /// A project's services' lines, interleaved by time.
    func testLinesMergeByTime() {
        func line(_ at: String, _ service: String) -> DockerLogLine {
            DockerLogLine(stream: .stdout, timestamp: "2026-10-27T10:00:\(at)Z", level: nil, message: service + at, fields: [], service: service)
        }
        let web = [line("01.1", "web"), line("03", "web"), line("05.25", "web")]
        let db = [line("00.5", "db"), line("03", "db"), line("04", "db")]
        XCTAssertEqual(DockerLogFeed.merged(web, db).map(\.message), ["db00.5", "web01.1", "web03", "db03", "db04", "web05.25"], "equal times keep their order")
        XCTAssertEqual(DockerLogFeed.merged([], db).map(\.message), db.map(\.message))
    }

    @MainActor
    func testANewestLineIsAddedAndAnOlderOneMerged() {
        let feed = DockerLogFeed()
        func line(_ at: String) -> DockerLogLine {
            DockerLogLine(stream: .stdout, timestamp: "2026-10-27T10:00:\(at)Z", level: nil, message: at, fields: [], service: nil)
        }
        feed.merge([line("01"), line("03")])
        let revision = feed.revision
        feed.merge([line("04")])
        XCTAssertEqual(feed.revision, revision, "the newest: added at the end, nothing drawn again")
        feed.merge([line("02")])
        XCTAssertEqual(feed.lines.map(\.message), ["01", "02", "03", "04"])
        XCTAssertGreaterThan(feed.revision, revision, "an older one: merged, drawn again")
    }

    /// A busy service doesn't push a quiet one's lines out of its
    /// project's feed: each keeps its last few, whatever the others write.
    @MainActor
    func testAQuietServiceKeepsItsLines() {
        func said(_ message: String, by service: String?) -> DockerLogLine {
            DockerLogLine(stream: .stdout, timestamp: nil, level: nil, message: message, fields: [], service: service)
        }
        let lines = [said("db1", by: "db"), said("db2", by: "db")] + (0..<10).map { said("web\($0)", by: "web") }
        XCTAssertEqual(DockerLogFeed.trimmed(lines, keep: 5, keepEach: 1)?.map(\.message), ["db2", "web5", "web6", "web7", "web8", "web9"])
        XCTAssertNil(DockerLogFeed.trimmed(Array(lines.prefix(5)), keep: 5, keepEach: 1), "under keep, nothing goes")
        XCTAssertNil(DockerLogFeed.trimmed(Array(lines.prefix(7)), keep: 5, keepEach: 2), "over keep, but each service within its own")
        let one = (0..<8).map { said("\($0)", by: nil) }
        XCTAssertEqual(DockerLogFeed.trimmed(one, keep: 5, keepEach: 2)?.map(\.message), ["3", "4", "5", "6", "7"], "one container's: the last keep")

        let feed = DockerLogFeed()
        feed.append([said("ready", by: "db")])
        feed.append((0..<(DockerLogFeed.keep + 10)).map { said("GET \($0)", by: "web") })
        XCTAssertEqual(feed.lines.first?.message, "ready", "the quiet one's line stays")
        XCTAssertEqual(feed.lines.count, DockerLogFeed.keep + 1)
        XCTAssertEqual(feed.lines.last?.message, "GET \(DockerLogFeed.keep + 9)")
    }

    /// Docker trims a fraction's trailing zeros; padded, the times sort.
    func testLogTimesSortAsTheyHappened() {
        XCTAssertLessThan(DockerLogFeed.sortable("2026-10-27T10:00:00.115Z"), DockerLogFeed.sortable("2026-10-27T10:00:00.12Z"))
        XCTAssertLessThan(DockerLogFeed.sortable("2026-10-27T10:00:00Z"), DockerLogFeed.sortable("2026-10-27T10:00:00.000000001Z"))
        XCTAssertEqual(DockerLogFeed.sortable("2026-10-27T10:00:00.5Z"), "2026-10-27T10:00:00.500000000Z")
        XCTAssertEqual(DockerLogFeed.seconds("1970-01-01T00:01:40.999999Z"), 100)
        XCTAssertNil(DockerLogFeed.seconds("yesterday"))
    }

    // MARK: The list

    func testGroupsKeepAProjectWhileAnyOfItMatches() {
        let (projects, loose) = ComposeProjects.group([
            container("shop-web-1", project: "shop", service: "web"),
            container("shop-db-1", project: "shop", service: "db", state: "exited", status: "Exited (0) 1 hour ago"),
            container("blog-app-1", project: "blog", service: "app", state: "exited", status: "Exited (0) 1 hour ago"),
            container("redis"),
        ])
        let all = DockerPageModel.groups(projects: projects, loose: loose, filter: DockerFilter(""), runningOnly: false)
        XCTAssertEqual(all.map(\.id), ["project:blog", "project:shop", "loose"])
        let running = DockerPageModel.groups(projects: projects, loose: loose, filter: DockerFilter(""), runningOnly: true)
        XCTAssertEqual(running.map(\.id), ["project:shop", "loose"], "a project with nothing running goes")
        XCTAssertEqual(running.first?.containers.map(\.name), ["shop-web-1"])
        let filtered = DockerPageModel.groups(projects: projects, loose: loose, filter: DockerFilter("db"), runningOnly: false)
        XCTAssertEqual(filtered.map(\.id), ["project:shop"])
        XCTAssertEqual(filtered.first?.project?.services.count, 2, "the project stays whole; only the rows are filtered")
    }

    func testTestcontainersRunsComeLast() {
        let tc = ["org.testcontainers": "true", "org.testcontainers.sessionId": "A"]
        var pg = container("tc-pg", image: "postgres:16-alpine")
        pg.Labels = tc
        var done = container("tc-old", state: "exited", status: "Exited (143) 1 hour ago")
        done.Labels = ["org.testcontainers": "true", "org.testcontainers.sessionId": "B"]
        let (sessions, rest) = Testcontainers.sessions([container("shop-web-1", project: "shop", service: "web"), container("redis"), pg, done])
        let (projects, loose) = ComposeProjects.group(rest)
        func groups(_ filter: String = "", runningOnly: Bool = false) -> [DockerListGroup] {
            DockerPageModel.groups(projects: projects, loose: loose, sessions: sessions, filter: DockerFilter(filter), runningOnly: runningOnly)
        }
        XCTAssertEqual(groups().map(\.id), ["project:shop", "loose", "testcontainers:A", "testcontainers:B"])
        XCTAssertEqual(groups(runningOnly: true).map(\.id), ["project:shop", "loose", "testcontainers:A"], "a run with nothing up goes")
        XCTAssertEqual(groups("-is:test").map(\.id), ["project:shop", "loose"])
        XCTAssertEqual(groups("is:test").map(\.id), ["testcontainers:A", "testcontainers:B"])
        XCTAssertEqual(groups().last?.id, DockerPageModel.sessionTag("B"))
        XCTAssertEqual(groups().first { $0.session?.id == "A" }?.containers.map(\.name), ["tc-pg"])
    }

    func testSortingPutsTheBusiestFirst() {
        func usage(_ cpu: Double, _ memory: Int) -> DockerUsage {
            DockerUsage(cpuPercent: cpu, memoryBytes: memory, memoryLimit: 1 << 30, networkIn: 0, networkOut: 0, diskRead: 0, diskWrite: 0, processes: 0)
        }
        let web = container("shop-web-1", project: "shop", service: "web")
        let db = container("shop-db-1", project: "shop", service: "db")
        let old = container("shop-old-1", project: "shop", service: "old", state: "exited", status: "Exited (0) 1 hour ago")
        let redis = container("redis", image: "redis:7")
        let (projects, loose) = ComposeProjects.group([web, db, old, redis])
        // A stopped one's entry, left from before it stopped, counts for nothing.
        let used = [web.Id: usage(40, 32 << 20), db.Id: usage(12.5, 96 << 20), old.Id: usage(99, 900 << 20), redis.Id: usage(90, 8 << 20)]
        func groups(_ sort: DockerListSort, _ usage: [String: DockerUsage] = used) -> [DockerListGroup] {
            DockerPageModel.groups(projects: projects, loose: loose, filter: DockerFilter(""), runningOnly: false, sort: sort, usage: usage)
        }
        XCTAssertEqual(groups(.cpu).map(\.id), ["loose", "project:shop"], "90% alone beats 52.5% together")
        XCTAssertEqual(groups(.cpu).last?.containers.map(\.name), ["shop-web-1", "shop-db-1", "shop-old-1"], "the stopped one last")
        XCTAssertEqual(groups(.memory).map(\.id), ["project:shop", "loose"])
        XCTAssertEqual(groups(.memory).first?.containers.map(\.name), ["shop-db-1", "shop-web-1", "shop-old-1"])
        XCTAssertEqual(groups(.name).map(\.id), ["project:shop", "loose"])
        XCTAssertEqual(groups(.name).first?.containers.map(\.name), ["shop-db-1", "shop-old-1", "shop-web-1"], "as without a sort")
        let unread = groups(.cpu, [db.Id: usage(12.5, 96 << 20)])
        XCTAssertEqual(unread.first?.containers.map(\.name), ["shop-db-1", "shop-old-1", "shop-web-1"], "what isn't read yet after, in its order")
        XCTAssertEqual(unread.map(\.id), ["project:shop", "loose"])
    }

    func testAColumnClickedAgainSortsByNameAgain() {
        XCTAssertEqual(DockerListSort.name.clicked(.cpu), .cpu)
        XCTAssertEqual(DockerListSort.cpu.clicked(.memory), .memory, "another column: by it")
        XCTAssertEqual(DockerListSort.memory.clicked(.memory), .name, "the same again: back by name")
        XCTAssertEqual(DockerListSort.cpu.clicked(.name), .name)
        XCTAssertEqual(DockerListSort.name.clicked(.name), .name)
    }

    /// The checkout's project before it runs, as the page lists it.
    private func planned(_ name: String = "shop") -> ComposeProject {
        ComposeConfig(
            name: name,
            services: [
                .init(name: "cache", image: "redis:7", buildContext: nil, dependsOn: [], profiles: [], ports: [], replicas: 1, containerName: nil),
                .init(
                    name: "db", image: "postgres:16", buildContext: nil, dependsOn: [], profiles: [],
                    ports: [.init(published: "55433", target: 5432, proto: "tcp")], replicas: 1, containerName: nil),
            ]
        ).project(in: "/w/\(name)")
    }

    func testAPlannedProjectIsListedUntilOneOfItsNameExists() {
        let (projects, loose) = ComposeProjects.group([
            container("blog-app-1", project: "blog", service: "app"), container("zoo-app-1", project: "zoo", service: "app"),
            container("redis", image: "redis:7"),
        ])
        func groups(_ filter: String = "", runningOnly: Bool = false, projects: [ComposeProject] = projects) -> [DockerListGroup] {
            DockerPageModel.groups(projects: projects, planned: planned(), loose: loose, filter: DockerFilter(filter), runningOnly: runningOnly)
        }
        XCTAssertEqual(groups().map(\.id), ["project:blog", "project:shop", "project:zoo", "loose"], "among the projects, by name")
        let shop = groups().first { $0.id == "project:shop" }
        XCTAssertEqual(shop?.project?.planned, true)
        XCTAssertEqual(shop?.services.map(\.name), ["cache", "db"])
        XCTAssertEqual(shop?.containers, [])
        let running = ComposeProjects.group([container("shop-web-1", project: "shop", service: "web")]).projects
        XCTAssertEqual(groups(projects: running).map(\.id), ["project:shop", "loose"])
        XCTAssertEqual(groups(projects: running).first?.project?.planned, false, "one of its name, from anywhere, is the row")
        var custom = ComposeProjects.group([container("custom-web-1", project: "custom", service: "web")]).projects
        custom[0].workingDir = "/w/shop"
        custom[0].configFiles = ["/w/shop/compose.yaml"]
        XCTAssertEqual(groups(projects: custom).map(\.id), ["project:custom", "loose"], "one made from its files under another name is too")
        XCTAssertEqual(groups(runningOnly: true).map(\.id), ["project:blog", "project:zoo", "loose"], "nothing of it runs")
        XCTAssertEqual(groups("image:redis").first { $0.id == "project:shop" }?.services.map(\.name), ["cache"])
        XCTAssertEqual(groups("image:redis").map(\.id), ["project:shop", "loose"])
        XCTAssertFalse(groups("-project:shop").contains { $0.id == "project:shop" })
        XCTAssertEqual(groups("db").map(\.id), ["project:shop"])
        XCTAssertEqual(groups("db").first?.services.map(\.name), ["db"])
        XCTAssertEqual(groups("port:55433").first?.services.map(\.name), ["db"])
        XCTAssertEqual(groups("status:stopped").first { $0.id == "project:shop" }?.services.count, 2)
        XCTAssertNil(groups("status:running").first { $0.id == "project:shop" })
    }

    @MainActor
    func testAPlannedProjectsVerbsAndKeys() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ot-plan-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try "services:\n  db:\n    image: postgres:16\n".write(to: folder.appendingPathComponent("compose.yaml"), atomically: true, encoding: .utf8)
        let real = FileTreeModel.realPath(folder)
        let docker = DockerModel(endpoint: { nil })
        let config = try ComposeConfig.parse(#"{"name":"shop","services":{"cache":{"image":"redis:7"},"db":{"image":"postgres:16"}}}"#)
        let compose = ComposeFileModel(docker: docker, latency: 0.05) { _, _ in #"{"name":"shop","services":{"cache":{"image":"redis:7"},"db":{"image":"postgres:16"}}}"# }
        defer { compose.update(checkout: nil, shown: false) }
        let page = DockerPageModel(docker: docker)
        page.checkoutCompose = compose
        compose.update(checkout: folder, shown: true)
        let deadline = Date().addingTimeInterval(5)
        while compose.project == nil, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        let plan = try XCTUnwrap(page.planned)
        XCTAssertEqual(plan, config.project(in: real))
        XCTAssertEqual(page.groups.map(\.id), ["project:shop"], "listed with no container at all")
        XCTAssertFalse(page.isEmpty, "not “No containers”: the plan is listed")
        page.runningOnly = true
        XCTAssertTrue(page.isEmpty, "Running only leaves it out: “No containers”, not a blank list")
        page.runningOnly = false

        let verbs = page.verbs(for: plan)
        XCTAssertEqual(verbs.filter { $0.place == .button }.map(\.title), ["Up (in a Tab)", "Pull Images in a Tab"])
        XCTAssertEqual(
            verbs.filter { $0.place == .more }.map(\.title), ["Check for Updates", "Up on Free Ports", "Open Compose File", "Show Resolved Config", "Copy Folder"])
        XCTAssertNil(verbs.first { $0.title == "Check for Updates" }?.unavailable, "its files name its images")
        XCTAssertTrue(verbs.allSatisfy { $0.place != .remove }, "nothing to take down")

        var commands: [(String, URL?)] = []
        page.actions = DockerActions(
            run: { commands.append(($0, $1)) }, confirm: { _, _, _, _ in XCTFail("nothing to ask") }, open: { _ in }, copy: { _ in }, settings: {})
        page.selection = [DockerPageModel.projectTag("shop")]
        XCTAssertEqual(page.detailedProject?.planned, true)
        page.press("u")
        XCTAssertEqual(commands.map(\.0), ["docker compose up -d"], "no -p: Compose names it from the files then")
        XCTAssertEqual(commands.first?.1?.path, real, "in the checkout")

        let db = try XCTUnwrap(plan.services.first { $0.name == "db" })
        page.selection = [DockerPageModel.serviceTag(db)]
        XCTAssertEqual(page.selectedProject?.name, "shop", "a service row stands for its project")
        XCTAssertEqual(page.detailedProject?.name, "shop")
        XCTAssertTrue(page.selectedContainers.isEmpty)
        XCTAssertNil(page.detailed)
        page.press("D")
        page.press("s")
        page.press("r")
        XCTAssertEqual(commands.count, 1, "no down, start or restart for what isn't there")
        XCTAssertEqual(page.rows, ["project:shop", "service:shop/cache", "service:shop/db"])

        XCTAssertEqual(DockerPageModel.serviceTag(db), "service:shop/db")
        XCTAssertEqual(DockerPageModel.service(of: "service:my app/db").map { [$0.project, $0.service] }, ["my app", "db"])
        XCTAssertNil(DockerPageModel.service(of: "project:shop"))
    }

    /// `b`: a project's row is all of it, a container its service; a
    /// one-off is no service's, a container in no project nothing.
    func testWhatBRebuilds() {
        var oneOff = container("shop-web-run-1a2b", project: "shop", service: "web")
        oneOff.Labels?["com.docker.compose.oneoff"] = "True"
        let projects = ComposeProjects.group([
            container("shop-web-1", project: "shop", service: "web"), container("shop-db-1", project: "shop", service: "db"),
            container("api-app-1", project: "api", service: "app"), oneOff, container("redis"),
        ]).projects
        let (api, shop) = (projects[0], projects[1])
        func ids(_ names: String...) -> Set<String> { Set(names.map { $0.hasPrefix("project:") ? $0 : $0 + "-0123456789" }) }
        XCTAssertEqual(
            DockerPageModel.rebuilds(of: ids("shop-web-1", "shop-web-run-1a2b", "redis", "project:api"), in: projects),
            [ComposeRebuild(project: api, services: []), ComposeRebuild(project: shop, services: ["web"])])
        XCTAssertEqual(DockerPageModel.rebuilds(of: ids("project:shop", "shop-db-1"), in: projects), [ComposeRebuild(project: shop, services: [])])
        XCTAssertEqual(DockerPageModel.rebuilds(of: ids("shop-web-run-1a2b"), in: projects), [], "a one-off is no service's")
        XCTAssertEqual(DockerPageModel.rebuilds(of: ids("redis"), in: projects), [])
    }

    /// A project's services' verbs, and what `b`, a service's Restart and
    /// Show Its Logs do.
    @MainActor
    func testAServicesVerbs() throws {
        let docker = DockerModel(endpoint: { nil })
        let page = DockerPageModel(docker: docker)
        var commands: [(String, URL?)] = []
        page.actions = DockerActions(run: { commands.append(($0, $1)) }, confirm: { _, _, _, _ in }, open: { _ in }, copy: { _ in }, settings: {})
        let shop = ComposeProjects.group([container("shop-web-1", project: "shop", service: "web")]).projects[0]
        let web = try XCTUnwrap(shop.services.first)
        let verbs = page.verbs(for: web, in: shop)
        XCTAssertEqual(verbs.filter { $0.place == .button }.map(\.title), ["Rebuild and Start in a Tab", "Restart", "Show Its Logs"])
        XCTAssertEqual(verbs.filter { $0.place == .more }.map(\.title), ["Follow Its Logs in a Tab", "Pull in a Tab", "Run a One-Off in a Tab", "Copy Name"])
        XCTAssertTrue(verbs.allSatisfy { $0.unavailable == nil })
        for title in ["Rebuild and Start in a Tab", "Run a One-Off in a Tab", "Pull in a Tab", "Follow Its Logs in a Tab"] {
            verbs.first { $0.title == title }?.perform()
        }
        XCTAssertEqual(
            commands.map(\.0),
            [
                "docker compose -p shop -f /w/shop/compose.yaml up -d --build web", "docker compose -p shop -f /w/shop/compose.yaml run --rm web",
                "docker compose -p shop -f /w/shop/compose.yaml pull web", "docker compose -p shop logs -f --tail 100 web",
            ])
        XCTAssertEqual(Set(commands.map(\.1?.path)), ["/w/shop"], "in the project's folder")

        let none = ComposeService(project: "shop", name: "worker", containers: [], dependsOn: [])
        let idle = page.verbs(for: none, in: shop)
        XCTAssertEqual(idle.first { $0.title == "Restart" }?.unavailable, "Compose hasn't made it yet.")
        XCTAssertEqual(idle.first { $0.title == "Show Its Logs" }?.unavailable, "Nothing of it has run yet.")

        // A project's row and its containers: `b` from the list, and the menus.
        XCTAssertEqual(page.verbs(for: shop).first { $0.key == "b" }?.title, "Rebuild and Up in a Tab")
        XCTAssertFalse(page.verbs(for: shop).contains { $0.title == "Watch in a Tab" || $0.title == "Up With Profiles…" }, "nothing known of its files")
        let container = try XCTUnwrap(web.containers.first)
        XCTAssertEqual(page.verbs(for: container).first { $0.key == "b" }?.title, "Rebuild and Start Its Service in a Tab")
        XCTAssertNil(page.verbs(for: self.container("redis")).first { $0.key == "b" }, "a container in no project has no service")

        // Show Its Logs: the project's Logs tab, narrowed to it, and its tab's command follows.
        page.selection = [DockerPageModel.projectTag("shop")]
        page.projectTab = .services
        verbs.first { $0.title == "Show Its Logs" }?.perform()
        XCTAssertEqual(page.projectTab, .logs)
        XCTAssertTrue(page.showDetail)
        XCTAssertEqual(page.projectSession?.service, "web")
    }

    /// A container run from an image Overterm saved: Compose's labels are
    /// there, emptied (a commit can't take a label away) — and it is no
    /// service of a project called "", wherever it is read.
    @MainActor
    func testEmptiedComposeLabelsAreNoProject() {
        var run = container("snapshot-run")
        run.Labels = [
            "com.docker.compose.project": "", "com.docker.compose.service": "", "com.docker.compose.oneoff": "",
            "com.docker.compose.project.working_dir": "", "com.docker.compose.project.config_files": "", "org.testcontainers.hash": "",
        ]
        XCTAssertNil(run.composeProject)
        XCTAssertNil(run.composeService)
        XCTAssertNil(run.composeWorkingDir)
        XCTAssertFalse(DockerEmulation.isService(run))
        XCTAssertFalse(Testcontainers.isReused(run))
        XCTAssertEqual(ComposeProjects.group([run]).loose.map(\.name), ["snapshot-run"])
        XCTAssertFalse(DockerMCP.describe([run]).contains("compose"), DockerMCP.describe([run]))
        let page = DockerPageModel(docker: DockerModel(endpoint: { nil }))
        XCTAssertNil(page.verbs(for: run).first { $0.key == "b" }, "no service to rebuild")
    }

    /// Settings…, Rename… and Save as Image… from the panel or the
    /// right-hand pane: the page comes up first, where what they say as
    /// they go — and when they fail — is shown. One Docker is removing
    /// has no settings, by its verb or its key.
    @MainActor
    func testAContainersSettingsVerbsBringThePageUp() throws {
        let page = DockerPageModel(docker: DockerModel(endpoint: { nil }))
        var opened = 0
        var asked: [String] = []
        page.actions = DockerActions(run: { _, _ in }, confirm: { _, _, _, _ in }, open: { _ in }, copy: { _ in }, settings: {})
        page.actions?.openPage = { opened += 1 }
        page.actions?.askName = { title, _, _, _ in asked.append(title) }
        XCTAssertFalse(page.visible)
        let web = container("web")
        let verbs = page.verbs(for: web)
        for title in ["Settings…", "Rename…", "Save as Image…"] { try XCTUnwrap(verbs.first { $0.title == title }).perform() }
        XCTAssertEqual(opened, 3, "each brings the page up")
        XCTAssertEqual(asked, ["Rename “web”"])
        page.visible = true
        try XCTUnwrap(page.verbs(for: web).first { $0.title == "Rename…" }).perform()
        XCTAssertEqual(opened, 3, "already on screen")
        let removing = container("old", state: "removing", status: "Removal In Progress")
        let settings = page.verbs(for: removing).first { $0.key == DockerKey.settings.key }
        XCTAssertEqual(settings?.unavailable, "Docker is removing it.")
        XCTAssertEqual(page.verbs(for: removing).first { $0.title == "Save as Image…" }?.unavailable, "Docker is removing it.")
    }

    /// Docker Scout on an image: Scan for Vulnerabilities first in its
    /// menu, then the tab's three; `v` opens the image's Vulnerabilities
    /// tab and scans nothing; a page of another engine than the app's has
    /// a store of its own, which in a test runs no Scout.
    @MainActor
    func testAnImagesVulnerabilitiesAreScannedOnlyWhenAsked() throws {
        let override = DockerCLI.override
        DockerCLI.override = nil
        defer { DockerCLI.override = override }
        let page = DockerPageModel(docker: DockerModel(endpoint: { nil }))
        XCTAssertFalse(page.scans === DockerScoutScans.shared)
        var commands: [String] = []
        page.actions = DockerActions(run: { command, _ in commands.append(command) }, confirm: { _, _, _, _ in }, open: { _ in }, copy: { _ in }, settings: {})
        page.hasScout = true
        let image = ImageSummary(Id: "sha256:" + String(repeating: "b", count: 64), RepoTags: ["redis:7"], Created: 0, Size: 1)
        let scout = try XCTUnwrap(page.verbs(for: image).first { $0.title == "Docker Scout" })
        XCTAssertEqual(
            scout.children.map(\.title), ["Scan for Vulnerabilities", "Quickview in a Tab", "Vulnerabilities in a Tab", "Base Image Updates in a Tab"])
        XCTAssertEqual(scout.children.map(\.group), [0, 1, 1, 1], "set apart from the tab's")
        page.section = .images
        page.showDetail = false
        XCTAssertTrue(page.press("v"))
        XCTAssertTrue(page.showDetail)
        XCTAssertEqual(page.imageTab, .vulnerabilities)
        XCTAssertTrue(page.scans.scans.isEmpty, "a key scans nothing")
        // ↩, out of habit (Logs, in Containers): not the list's here, and
        // nothing on the tab is the window's default button (the scenario).
        XCTAssertFalse(page.press("\r"))
        XCTAssertTrue(page.scans.scans.isEmpty, "nor does Return")
        scout.children.first?.perform()
        XCTAssertEqual(page.imageSelection, [image.Id])
        guard case .failed(.isolated, _) = page.scans.scan(for: image.Id)?.state else {
            return XCTFail("\(String(describing: page.scans.scan(for: image.Id)))")
        }
        page.signInToDocker()
        XCTAssertEqual(commands, ["docker login"])
        let untagged = ImageSummary(Id: "sha256:" + String(repeating: "c", count: 64), RepoTags: ["<none>:<none>"], Created: 0, Size: 1)
        page.scanVulnerabilities(untagged)
        XCTAssertNil(page.scans.scan(for: untagged.Id), "Scout scans by name")
        XCTAssertNil(page.verbs(for: untagged).first { $0.title == "Docker Scout" })
    }

    /// A project before it runs is watched from its plan: Compose's own
    /// reading of the files, nothing asked again.
    @MainActor
    func testAPlannedProjectIsWatchedFromItsPlan() async throws {
        let config = try ComposeConfig.parse(
            #"{"name":"shop","services":{"db":{"image":"postgres:16"},"web":{"build":{"context":"/w/shop"},"develop":{"watch":[{"path":"/w/shop/src","action":"sync","target":"/app"}]}}}}"#
        )
        let plan = config.project(in: "/w/shop")
        XCTAssertEqual(config.services.filter(\.watched).map(\.name), ["web"])
        let page = DockerPageModel(docker: DockerModel(endpoint: { nil }))
        var commands: [(String, URL?)] = []
        page.actions = DockerActions(run: { commands.append(($0, $1)) }, confirm: { _, _, _, _ in }, open: { _ in }, copy: { _ in }, settings: {})
        XCTAssertEqual(page.verbs(for: plan).filter { $0.place == .button }.map(\.title), ["Up (in a Tab)", "Watch in a Tab", "Pull Images in a Tab"])
        let why = await page.watch(plan)
        XCTAssertNil(why)
        XCTAssertEqual(commands.map(\.0), ["docker compose watch"], "no -p, no -f: its folder's files")
        XCTAssertEqual(commands.first?.1?.path, "/w/shop")
        let unwatched = try ComposeConfig.parse(#"{"name":"shop","services":{"db":{"image":"postgres:16"}}}"#).project(in: "/w/shop")
        XCTAssertFalse(page.verbs(for: unwatched).contains { $0.title == "Watch in a Tab" })
        let refused = await page.watch(unwatched)
        XCTAssertEqual(refused, "No service of shop has develop.watch: Compose watches only those.")
    }

    /// A container that failed — what the list paints red — offers to ask
    /// an agent why, as a button after Start; one that is fine doesn't.
    @MainActor
    func testAFailedContainerOffersToAskWhy() {
        let page = DockerPageModel(docker: DockerModel(endpoint: { nil }))
        func ask(_ container: ContainerSummary, detail: ContainerDetail? = nil) -> DockerVerb? {
            page.verbs(for: container, detail: detail).first { $0.title == "Ask an Agent Why…" }
        }
        let failed = container("worker", state: "exited", status: "Exited (1) 3 seconds ago")
        let verb = ask(failed)
        XCTAssertEqual(verb?.place, .button)
        XCTAssertEqual(verb?.key, "a")
        XCTAssertEqual(verb?.label, "Ask Why")
        XCTAssertEqual(page.verbs(for: failed).filter { $0.place == .button }.map(\.title).prefix(2), ["Start", "Ask an Agent Why…"])
        XCTAssertNil(ask(container("web")), "a running one")
        XCTAssertNil(ask(container("job", state: "exited", status: "Exited (0) 3 seconds ago")), "one done with its work")
        // Running again, but inspect says the kernel killed it.
        let running = container("api")
        let killed = ContainerDetail(
            Id: running.Id, Name: "/api", State: .init(Status: "running", OOMKilled: true), Config: .init(Image: "nginx:1.27"))
        XCTAssertNotNil(ask(running, detail: killed))
        XCTAssertFalse(page.askWhySelected(), "nothing selected")
        page.selection = [running.Id]
        XCTAssertFalse(page.askWhySelected(), "the model doesn't list it: nothing to ask about")
    }

    @MainActor
    func testWhatASelectionMeans() {
        let docker = DockerModel(endpoint: { nil })
        let page = DockerPageModel(docker: docker)
        XCTAssertTrue(page.selectedContainers.isEmpty)
        XCTAssertNil(page.detailed)
        page.selection = [DockerPageModel.projectTag("shop")]
        XCTAssertNil(page.detailed, "a project's row isn't a container")
        XCTAssertEqual(DockerPageModel.project(of: "project:my app"), "my app")
        XCTAssertNil(DockerPageModel.project(of: "abc123"))
        XCTAssertEqual(DockerPageModel.session(of: "testcontainers:abc"), "abc")
        XCTAssertNil(DockerPageModel.session(of: "project:x"))
        page.selection = [DockerPageModel.sessionTag("abc")]
        XCTAssertNil(page.detailed, "a run's row isn't a container")
        XCTAssertNil(page.detailedSession, "nor a run the model doesn't list")
        XCTAssertTrue(page.selectedContainers.isEmpty)
        XCTAssertFalse(page.press("x"), "a key that means nothing goes on to the list")
        XCTAssertTrue(page.press("?"))
        XCTAssertTrue(page.cheatSheet)
        XCTAssertTrue(page.press("s"), "any key closes the sheet first")
        XCTAssertFalse(page.cheatSheet)
        page.press(" ")
        XCTAssertFalse(page.showDetail)
    }
}

/// Clean Up's preview, and an image's pull. Pure.
final class DockerPrunePlanTests: XCTestCase {
    private func container(_ name: String, image: String, state: String, volumes: [String] = [], networks: [String] = []) -> ContainerSummary {
        ContainerSummary(
            Id: name, Names: ["/" + name], Image: image, ImageID: image, Created: 1, State: state, Status: "",
            Mounts: volumes.map { DockerMountPoint(Type: "volume", Name: $0, Destination: "/data") },
            NetworkSettings: .init(Networks: Dictionary(uniqueKeysWithValues: networks.map { ($0, .init(NetworkID: $0 + "-id")) })))
    }

    private func image(_ id: String, tags: [String], size: Int) -> ImageSummary {
        ImageSummary(Id: id, RepoTags: tags, Created: 1, Size: size)
    }

    private func volume(_ name: String, anonymous: Bool, size: Int) -> VolumeSummary {
        VolumeSummary(
            Name: name, Driver: "local", Mountpoint: "/v", Labels: anonymous ? ["com.docker.volume.anonymous": ""] : [:],
            UsageData: .init(Size: size, RefCount: 0))
    }


    func testWhatGoesAndWhatStays() {
        let containers = [
            container("web", image: "nginx", state: "running", volumes: ["shop_data"], networks: ["shop_default"]),
            container("old", image: "node", state: "exited", volumes: ["abc"], networks: ["old_default"]),
        ]
        let images = [
            image("nginx", tags: ["nginx:1.27"], size: 100), image("node", tags: ["node:20"], size: 1000), image("none", tags: [], size: 10),
            image("redis", tags: ["redis:7"], size: 50),
        ]
        let volumes = [volume("shop_data", anonymous: false, size: 5), volume("abc", anonymous: true, size: 7), volume("named", anonymous: false, size: 9)]
        let networks = [
            NetworkSummary(Name: "bridge", Id: "bridge-id"), NetworkSummary(Name: "shop_default", Id: "shop_default-id"),
            NetworkSummary(Name: "old_default", Id: "old_default-id"), NetworkSummary(Name: "lonely", Id: "lonely-id"),
        ]
        let cache = [
            DockerDiskUsage.BuildCacheEntry(ID: "a", Size: 30, InUse: false, Shared: false),
            DockerDiskUsage.BuildCacheEntry(ID: "b", Size: 40, InUse: true, Shared: false),
        ]
        func plan(_ choice: DockerPrunePlan.Choice) -> DockerPrunePlan {
            DockerPrunePlan.make(choice, containers: containers, images: images, volumes: volumes, networks: networks, buildCache: cache)
        }
        let standard = plan(DockerPrunePlan.Choice())
        XCTAssertEqual(standard.containers.map(\.name), ["old"])
        XCTAssertEqual(standard.images.map(\.Id), ["none"], "untagged only, by default")
        XCTAssertTrue(standard.volumes.isEmpty, "volumes only when asked")
        XCTAssertEqual(standard.networks.map(\.Name), ["old_default", "lonely"], "its stopped container goes, so its network is unused")
        XCTAssertEqual(standard.buildCache, 30)
        XCTAssertEqual(standard.reclaimable, 40)

        var everything = DockerPrunePlan.Choice()
        everything.allImages = true
        everything.volumes = true
        let wide = plan(everything)
        XCTAssertEqual(wide.images.map(\.Id), ["node", "none", "redis"], "node is unused once the stopped container goes")
        XCTAssertEqual(wide.volumes.map(\.Name), ["abc"], "anonymous only unless named ones are asked for")
        everything.namedVolumes = true
        XCTAssertEqual(plan(everything).volumes.map(\.Name), ["abc", "named"], "a running container's volume stays")

        var keepContainers = DockerPrunePlan.Choice()
        keepContainers.containers = false
        keepContainers.allImages = true
        XCTAssertEqual(plan(keepContainers).images.map(\.Id), ["none", "redis"], "a stopped container that stays keeps its image")
        XCTAssertEqual(plan(keepContainers).networks.map(\.Name), ["lonely"], "and its network")
    }

    func testAPullSumsItsLayers() {
        var pull = DockerPull(image: "redis:7")
        pull.add(.init(id: nil, status: "Pulling from library/redis"))
        pull.add(.init(id: "a", status: "Pulling fs layer"))
        pull.add(.init(id: "b", status: "Pulling fs layer"))
        pull.add(.init(id: "a", status: "Downloading", current: 1_000_000, total: 4_000_000))
        pull.add(.init(id: "b", status: "Already exists"))
        XCTAssertEqual(pull.downloaded.current, 1_000_000)
        XCTAssertEqual(pull.downloaded.total, 4_000_000)
        XCTAssertTrue(pull.summary.hasPrefix("1 of 2 layers — "), pull.summary)
        pull.add(.init(id: "a", status: "Pull complete"))
        XCTAssertEqual(pull.downloaded.current, pull.downloaded.total)
        XCTAssertTrue(pull.summary.hasPrefix("2 of 2 layers"), pull.summary)
        pull.add(.init(id: nil, status: "Status: Downloaded newer image for redis:7"))
        pull.done = true
        XCTAssertEqual(pull.summary, "Status: Downloaded newer image for redis:7")
    }

    func testVolumesAndImagesSayWhatTheyAre() {
        XCTAssertEqual(volume(String(repeating: "a", count: 64), anonymous: true, size: 0).shortName, String(repeating: "a", count: 12))
        XCTAssertEqual(volume("shop_pgdata", anonymous: false, size: 0).shortName, "shop_pgdata")
        XCTAssertEqual(DockerImageDetailSteps.step("/bin/sh -c #(nop)  CMD [\"nginx\" \"-g\"]"), "CMD [\"nginx\" \"-g\"]")
        XCTAssertEqual(DockerImageDetailSteps.step("/bin/sh -c apt-get update &&     apt-get install -y curl"), "RUN apt-get update && apt-get install -y curl")
        XCTAssertEqual(DockerImageDetailSteps.step("RUN /bin/sh -c echo hi # buildkit"), "RUN /bin/sh -c echo hi # buildkit")
    }
}

/// A container's folders, as the Files tab lists them. Pure.
final class DockerFilesTests: XCTestCase {
    func testTheListingIsRead() {
        let entries = DockerFiles.parse("f\t20\tnginx.conf\nd\t-\tconf.d\nl\t-\tlogs\nf\t-\twith\ttab\nbroken line\n")
        XCTAssertEqual(entries.map(\.name), ["conf.d", "logs", "nginx.conf", "with\ttab"])
        XCTAssertEqual(entries.first { $0.name == "nginx.conf" }?.size, 20)
        XCTAssertNil(entries.first { $0.name == "with\ttab" }?.size, "a size it couldn't read")
        XCTAssertEqual(entries.first { $0.name == "logs" }?.kind, .link)
    }

    func testPaths() {
        XCTAssertEqual(DockerFiles.join("/", "etc"), "/etc")
        XCTAssertEqual(DockerFiles.join("/etc", "nginx"), "/etc/nginx")
        XCTAssertEqual(DockerFiles.parent("/etc/nginx"), "/etc")
        XCTAssertEqual(DockerFiles.parent("/etc"), "/")
        XCTAssertEqual(DockerFiles.parent("/"), "/", "the root is its own parent, once")
        XCTAssertEqual(DockerFiles.crumbs("/etc/nginx").map(\.path), ["/", "/etc", "/etc/nginx"])
        XCTAssertEqual(DockerFiles.command(listing: "/srv").suffix(2), ["overterm-ls", "/srv"])
    }

    /// A typed `..` can't take a copy out of Overterm's folder.
    func testACopyStaysInItsFolder() {
        let root = URL(fileURLWithPath: "/support")
        XCTAssertEqual(DockerFiles.localCopy(of: "/etc/nginx/nginx.conf", in: "web", under: root).path, "/support/Containers/web/etc/nginx/nginx.conf")
        XCTAssertEqual(DockerFiles.localCopy(of: "/../../../etc/passwd", in: "web", under: root).path, "/support/Containers/web/etc/passwd")
        XCTAssertEqual(DockerFiles.localCopy(of: "/a/./b", in: "x/y", under: root).path, "/support/Containers/x_y/a/b")
    }

    /// A file saved back keeps its owner: the engine gives what it extracts
    /// the tar's, and a database won't read a config root owns.
    func testATarKeepsItsOwner() throws {
        let owned = try XCTUnwrap(DockerTar.archive(name: "pg_hba.conf", data: Data("local all all trust\n".utf8), uid: 999, gid: 70))
        let entry = try XCTUnwrap(DockerTar.entries(of: owned).first)
        XCTAssertEqual(entry.uid, 999)
        XCTAssertEqual(entry.gid, 70)
        XCTAssertEqual(String(decoding: entry.data, as: UTF8.self), "local all all trust\n")
        let plain = try XCTUnwrap(DockerTar.entries(of: try XCTUnwrap(DockerTar.archive(name: "a", data: Data("x".utf8)))).first)
        XCTAssertEqual(plain.uid, 0, "root's unless said")
        XCTAssertEqual(plain.gid, 0)
        let long = String(repeating: "folder/", count: 20) + "file.conf"
        let deep = try XCTUnwrap(DockerTar.entries(of: try XCTUnwrap(DockerTar.archive(name: long, data: Data("y".utf8), uid: 1000, gid: 1000))).first)
        XCTAssertEqual(deep.name, long, "a name past 100 bytes, through its prefix")
        XCTAssertEqual(deep.uid, 1000)
    }

    func testAHelperIsOverterms() {
        func summary(_ labels: [String: String]) -> ContainerSummary {
            ContainerSummary(Id: "x", Names: ["/overterm-files-1a2b3c4d"], Image: "busybox", Created: 1, Labels: labels, State: "running", Status: "")
        }
        XCTAssertTrue(summary(["overterm.helper": "1", "overterm.volume": "pgdata"]).isHelper)
        XCTAssertFalse(summary([:]).isHelper)
        XCTAssertFalse(summary(["overterm.test": "1"]).isHelper)
    }
}

/// A volume's files: its paths in the helper, which images can run one.
/// Pure.
final class DockerVolumeFilesTests: XCTestCase {
    func testPathsInTheHelper() {
        XCTAssertEqual(DockerVolumeFiles.helperPath("/"), "/volume")
        XCTAssertEqual(DockerVolumeFiles.helperPath("/conf/app.conf"), "/volume/conf/app.conf")
        XCTAssertEqual(DockerVolumeFiles.helperPath("/../../etc/passwd"), "/volume/etc/passwd", "a typed .. stays in the volume")
        XCTAssertEqual(DockerVolumeFiles.helperPath(""), "/volume")
        XCTAssertEqual(DockerVolumeFiles.said("No such folder: /volume/x"), "No such folder: /x")
        XCTAssertEqual(DockerVolumeFiles.said("No such folder: /volume"), "No such folder: /")
        XCTAssertEqual(
            DockerVolumeFiles.said("Could not find the file /volume/conf/a.conf in container 1a2b"), "Could not find the file /conf/a.conf in container 1a2b")
        XCTAssertEqual(DockerVolumeFiles.said("/var/lib/docker/volumes/x/_data"), "/var/lib/docker/volumes/x/_data", "not another path")
    }

    func testWhichImagesAreTried() {
        func image(_ tags: [String], _ size: Int) -> ImageSummary {
            ImageSummary(Id: "sha256:" + (tags.first ?? "none-\(size)"), RepoTags: tags.isEmpty ? ["<none>:<none>"] : tags, Created: 1, Size: size)
        }
        let postgres = image(["postgres:16"], 400 << 20)
        let busybox = image(["busybox:1.36"], 4 << 20)
        let dangling = image([], 1 << 20)
        let netshoot = image(["nicolaka/netshoot:latest"], 300 << 20)
        let alpine = image(["alpine:3.20"], 8 << 20)
        let distroless = image(["gcr.io/distroless/static:nonroot"], 2 << 20)
        let node = image(["node:20"], 1 << 30)
        let images = [postgres, busybox, dangling, netshoot, alpine, distroless, node]
        let db = ContainerSummary(Id: "db", Names: ["/db"], Image: "postgres:16", ImageID: postgres.Id, Created: 1, State: "running", Status: "")
        func tried(_ images: [ImageSummary], worked: String? = nil, limit: Int = 3) -> [String] {
            DockerVolumeFiles.shellImages(images, debugImage: "nicolaka/netshoot", mountedBy: [db], worked: worked, limit: limit)
        }
        XCTAssertEqual(tried(images), [busybox.Id, alpine.Id, netshoot.Id], "the small shells first, then the debug shell's")
        XCTAssertEqual(
            tried(images, limit: 10), [busybox.Id, alpine.Id, netshoot.Id, postgres.Id, node.Id],
            "then what mounts it, then the rest — never <none>, never distroless")
        let hub = image(["docker.io/library/busybox:latest"], 4 << 20)
        XCTAssertEqual(tried([node, hub]).first, hub.Id, "Docker Hub's full name is busybox")
        let both = image(["busybox:1.36", "alpine:3.20"], 5 << 20)
        XCTAssertEqual(tried([both, node]), [both.Id, node.Id], "an image of two names once")
        XCTAssertEqual(tried(images, worked: node.Id), [node.Id, busybox.Id, alpine.Id], "the one that worked last first")
        XCTAssertEqual(tried(images, worked: "sha256:gone").first, busybox.Id, "unless it is gone")
        XCTAssertEqual(tried([]), [])
    }

    func testAVolumesCopyStaysInItsFolder() {
        let root = URL(fileURLWithPath: "/support")
        XCTAssertEqual(DockerFiles.localCopy(of: "/conf/../app.conf", from: .volume("pgdata"), under: root).path, "/support/Volumes/pgdata/conf/app.conf")
        XCTAssertEqual(
            DockerFiles.localCopy(of: "/etc/hosts", from: .container(id: "abc", name: "web"), under: root).path, "/support/Containers/web/etc/hosts")
        XCTAssertEqual(DockerFileSource.volume("pgdata").title, "the volume pgdata")
        XCTAssertEqual(DockerFileSource.container(id: "abc", name: "web").title, "web")
    }

    func testTheMountedNote() {
        XCTAssertEqual(VolumeFilesPane.mountedNote(["db"]), "Mounted by db, running: it sees a saved file at once.")
        XCTAssertEqual(VolumeFilesPane.mountedNote(["db", "backup"]), "Mounted by db, backup, running: they see a saved file at once.")
    }

    /// A copy saves only to the engine it was read from: a volume's name
    /// is on every engine, and the context may have changed since.
    func testACopySavesOnlyWhereItCameFrom() {
        let desktop = DockerEndpoint(address: .unix("/Users/me/.docker/run/docker.sock"), context: "desktop-linux", source: "context desktop-linux")
        let remote = DockerEndpoint(address: .tcp(host: "dev.example", port: 2376), context: nil, source: "DOCKER_HOST")
        let stat = DockerTar.PathStat(name: "pg_hba.conf", size: 1, mode: 0o600, mtime: "2026-01-01T00:00:00Z", linkTarget: "")
        let copy = DockerFileCopy(source: .volume("pgdata"), path: "/pg_hba.conf", stat: stat, uid: 999, gid: 999, endpoint: desktop)
        XCTAssertNil(copy.refusal(through: desktop))
        var renamed = desktop
        renamed.source = "DOCKER_CONTEXT"
        XCTAssertNil(copy.refusal(through: renamed), "the same socket however it was found")
        XCTAssertEqual(
            copy.refusal(through: remote), "It was opened from the context desktop-linux, and Docker is now tcp://dev.example:2376: switch back to save it there.")
    }

    /// The helpers a run before this one left: Overterm's, another run's
    /// (or none's, before the label), not running, and made over ten
    /// minutes ago.
    func testWhichHelpersWereLeftBehind() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func helper(_ id: String, _ state: String = "created", run: String? = "earlier", ago: Int = 3600, helper: Bool = true) -> ContainerSummary {
            var labels = helper ? ["overterm.helper": "1"] : [:]
            labels["overterm.run"] = run
            return ContainerSummary(
                Id: id, Names: ["/" + id], Image: "busybox", Created: 1_800_000_000 - ago, Labels: labels, State: state, Status: "")
        }
        let helpers = [
            helper("left"), helper("unlabelled", "exited", run: nil), helper("running", "running"), helper("ours", run: DockerHelpers.run),
            helper("recent", ago: 60), helper("web", helper: false),
        ]
        XCTAssertEqual(DockerHelpers.leftBehind(helpers, now: now), ["left", "unlabelled"])
    }
}

/// A database container as a Database connection. Pure.
final class DockerDatabaseGuessTests: XCTestCase {
    private func container(_ image: String, ports: [DockerPort], project: String? = "shop") -> ContainerSummary {
        var labels: [String: String] = [:]
        if let project {
            labels["com.docker.compose.project"] = project
            labels["com.docker.compose.service"] = "db"
        }
        return ContainerSummary(Id: "x", Names: ["/shop-db-1"], Image: image, Created: 1, Ports: ports, Labels: labels, State: "running", Status: "")
    }

    private let pg = [
        DockerPort(IP: "0.0.0.0", PrivatePort: 5432, PublicPort: 55432, Type: "tcp"), DockerPort(IP: "::", PrivatePort: 5432, PublicPort: 55432, Type: "tcp"),
    ]

    func testPostgres() throws {
        let guess = try XCTUnwrap(
            DockerDatabaseGuess.guess(
                container("postgres:16-alpine", ports: pg), env: [("POSTGRES_USER", "shop"), ("POSTGRES_PASSWORD", "hunter2"), ("POSTGRES_DB", "orders")]))
        XCTAssertEqual(guess.connection.kind, .postgres)
        XCTAssertEqual(guess.connection.name, "shop db")
        XCTAssertEqual(guess.connection.host, "127.0.0.1")
        XCTAssertEqual(guess.connection.port, 55432)
        XCTAssertEqual(guess.connection.user, "shop")
        XCTAssertEqual(guess.connection.database, "orders")
        XCTAssertEqual(guess.connection.sslMode, .disable)
        XCTAssertEqual(guess.password, "hunter2")
        let defaults = try XCTUnwrap(DockerDatabaseGuess.guess(container("ghcr.io/acme/postgis:16", ports: pg), env: []))
        XCTAssertEqual(defaults.connection.user, "postgres", "the image's defaults")
        XCTAssertEqual(defaults.connection.database, "postgres")
        XCTAssertNil(defaults.password)
    }

    func testMySQLAndClickHouse() throws {
        let port = [DockerPort(IP: "127.0.0.1", PrivatePort: 3306, PublicPort: 53306, Type: "tcp")]
        let root = try XCTUnwrap(DockerDatabaseGuess.guess(container("mariadb:11", ports: port), env: [("MARIADB_ROOT_PASSWORD", "r00t")]))
        XCTAssertEqual(root.connection.kind, .mysql)
        XCTAssertEqual(root.connection.user, "root")
        XCTAssertEqual(root.password, "r00t")
        let user = try XCTUnwrap(
            DockerDatabaseGuess.guess(
                container("mysql:8", ports: port), env: [("MYSQL_ROOT_PASSWORD", "r00t"), ("MYSQL_USER", "app"), ("MYSQL_PASSWORD", "pw"), ("MYSQL_DATABASE", "shop")]))
        XCTAssertEqual(user.connection.user, "app", "the app's own user over root")
        XCTAssertEqual(user.password, "pw")
        XCTAssertEqual(user.connection.database, "shop")
        let unmade = try XCTUnwrap(
            DockerDatabaseGuess.guess(container("mysql:8", ports: port), env: [("MYSQL_ROOT_PASSWORD", "r00t"), ("MYSQL_USER", "app")]))
        XCTAssertEqual(unmade.connection.user, "root", "no password, no app user: the image didn't make it")
        XCTAssertEqual(unmade.password, "r00t")
        let clickhouse = try XCTUnwrap(
            DockerDatabaseGuess.guess(
                container("clickhouse/clickhouse-server:24", ports: [DockerPort(IP: "0.0.0.0", PrivatePort: 8123, PublicPort: 58123, Type: "tcp")]), env: []))
        XCTAssertEqual(clickhouse.connection.kind, .clickhouse)
        XCTAssertEqual(clickhouse.connection.user, "default")
    }

    func testNoGuessForWhatCantBeReached() {
        XCTAssertNil(DockerDatabaseGuess.guess(container("postgres:16", ports: []), env: []), "not published: not reachable from the Mac")
        XCTAssertNil(DockerDatabaseGuess.guess(container("redis:7", ports: pg), env: []))
        XCTAssertNil(DockerDatabaseGuess.kind(of: "nginx"))
        XCTAssertEqual(DockerDatabaseGuess.kind(of: "bitnami/postgresql:16")?.0, .postgres)
        for tool in ["postgrest/postgrest", "prometheuscommunity/postgres-exporter", "clickhouse/clickhouse-keeper"] {
            XCTAssertNil(DockerDatabaseGuess.kind(of: tool), "\(tool) is a tool beside a database, not one")
        }
        XCTAssertEqual(DockerDatabaseGuess.kind(of: "percona/percona-server:8")?.0, .mysql)
        XCTAssertEqual(DockerDatabaseGuess.kind(of: "percona/percona-server:8")?.port, 3306)
        // A worktree's project carries its branch; Compose names a built image after it.
        XCTAssertNil(DockerDatabaseGuess.guess(container("shop-wt-postgres-upgrade-api", ports: pg, project: "shop-wt-postgres-upgrade"), env: []))
    }

    func testAGuessOfAnImageListedByItsID() throws {
        var listed = container("sha256:" + String(repeating: "b", count: 64), ports: pg)
        listed.ImageID = listed.Image
        XCTAssertNil(DockerDatabaseGuess.guess(listed, env: []))
        XCTAssertEqual(DockerDatabaseGuess.guess(listed, env: [], reference: "postgres:16")?.connection.kind, .postgres)
    }
}

/// A database container's own client in a terminal tab: which, from its
/// image's name; signed in by its env's names, expanded inside. Pure — and
/// the scripts run for real under a shell, with stub clients.
final class DockerClientTests: XCTestCase {
    private func db(_ image: String = "postgres:16", name: String = "shop-db-1") -> ContainerSummary {
        ContainerSummary(Id: "x", Names: ["/" + name], Image: image, Created: 1, State: "running", Status: "")
    }

    private func command(_ kind: DockerClient.Kind, _ env: Set<String> = []) -> String { DockerClient.command(kind, in: db(), env: env) }

    func testImagesAreKnownByTheirNames() {
        let known: [DockerClient.Kind: [String]] = [
            .postgres: [
                "postgres:16-alpine", "bitnami/postgresql:16", "postgis/postgis:16-3.4", "timescale/timescaledb-ha:pg16", "pgvector/pgvector:pg17",
                "supabase/postgres:15.8.1", "docker.io/library/postgres@sha256:abc", "localhost:5000/postgres:16", "percona/percona-distribution-postgresql:16",
            ],
            .mysql: ["mysql:8.4", "percona/percona-server:8.0", "container-registry.oracle.com/mysql/community-server:9.1"],
            .mariadb: ["mariadb:11", "MariaDB:10.3"],
            .redis: ["redis:7-alpine", "redis/redis-stack-server"],
            .valkey: ["valkey/valkey:8"],
            .mongo: ["mongo:7", "mongodb/mongodb-community-server:7.0-ubi8", "percona/percona-server-mongodb:7.0"],
            .clickhouse: ["clickhouse/clickhouse-server:24.8"],
            .cassandra: ["cassandra:5", "scylladb/scylla:6.2"],
            .neo4j: ["neo4j:5"],
            .mssql: ["mcr.microsoft.com/mssql/server:2022-latest"],
        ]
        for (kind, images) in known {
            for image in images { XCTAssertEqual(DockerClient.kind(of: image), kind, image) }
        }
        let none = [
            "nginx:1.27", "postgrest/postgrest", "prometheuscommunity/postgres-exporter", "mongo-express", "rediscommander/redis-commander", "redis/redisinsight",
            "clickhouse/clickhouse-keeper", "dpage/pgadmin4", "mysql/mysql-router", "supabase/postgres-meta", "bitnami/redis-sentinel", "percona/pmm-server",
            "oliver006/redis_exporter", "sha256:0123abcd", "",
        ]
        for image in none { XCTAssertNil(DockerClient.kind(of: image), image) }
        XCTAssertEqual(DockerClient.words(of: "docker.io/library/postgres:16@sha256:abc"), ["library", "postgres"])
        XCTAssertEqual(DockerClient.components(of: "localhost:5000/acme/shop-api:dev"), ["acme", "shop-api"])
        XCTAssertEqual(DockerClient.words(of: "localhost:5000/timescale/timescaledb-ha:pg16"), ["timescale", "timescaledb", "ha"])
        XCTAssertEqual(
            DockerClient.Kind.allCases.map(\.program),
            [
                "psql", "mysql", "mariadb", "redis-cli", "valkey-cli", "mongosh", "clickhouse-client", "cqlsh", "cypher-shell", "sqlcmd",
            ])
    }

    private func service(_ image: String, project: String, service: String, imageID: String? = nil) -> ContainerSummary {
        ContainerSummary(
            Id: "x", Names: ["/\(project)-\(service)-1"], Image: image, ImageID: imageID, Created: 1,
            Labels: ["com.docker.compose.project": project, "com.docker.compose.service": service], State: "running", Status: "")
    }

    /// New Task names a worktree's project after its branch, and Compose a
    /// built image after the project and the service: the project's name
    /// says nothing about the image.
    func testAComposeProjectsNameSaysNothingOfItsImages() {
        let branch = "shop-wt-fix-redis-timeout"
        XCTAssertNil(DockerClient.kind(of: service("\(branch)-api", project: branch, service: "api")), "a built service is no Redis")
        XCTAssertNil(DockerClient.kind(of: service("\(branch)_api", project: branch, service: "api")), "Compose v1's name")
        XCTAssertNil(DockerClient.kind(of: service("localhost:5000/\(branch)-worker:dev", project: branch, service: "jobs")))
        XCTAssertEqual(DockerClient.kind(of: service("redis:7", project: branch, service: "cache")), .redis)
        XCTAssertEqual(
            DockerClient.kind(of: service("admin-panel-postgres", project: "admin-panel", service: "postgres")), .postgres,
            "a built database, in a project named for a tool")
        XCTAssertNil(DockerClient.kind(of: service("admin-panel-web", project: "admin-panel", service: "web")))
        XCTAssertEqual(
            DockerClient.kind(of: service("clickhouse/clickhouse-server:24.8", project: "clickhouse", service: "server")), .clickhouse,
            "the project's name, not the image's namespace")
        XCTAssertEqual(DockerClient.kind(of: service("redis/redis-stack-server", project: "redis", service: "redis")), .redis)
        XCTAssertEqual(DockerClient.kind(of: service("postgres:16", project: "postgres", service: "db")), .postgres)
        XCTAssertEqual(DockerClient.kind(of: db("mongo:7")), .mongo, "no project")
    }

    /// Docker lists a container's image by its ID once the tag it was made
    /// from names a newer image: inspect's name says then.
    func testAnImageListedByItsIDIsKnownByInspectsName() {
        let id = "sha256:" + String(repeating: "b", count: 64)
        var listed = db(id)
        XCTAssertTrue(DockerClient.listsImageByID(listed))
        XCTAssertNil(DockerClient.kind(of: listed))
        XCTAssertEqual(DockerClient.kind(of: listed, reference: "postgres:16"), .postgres)
        XCTAssertNil(
            DockerClient.kind(of: service(id, project: "shop-wt-redis", service: "api", imageID: id), reference: "shop-wt-redis-api"),
            "the same rule for inspect's name")
        listed.Image = "postgres:16"
        listed.ImageID = id
        XCTAssertFalse(DockerClient.listsImageByID(listed))
        XCTAssertEqual(DockerClient.kind(of: listed, reference: "redis:7"), .postgres, "the list's name, while it has one")
    }

    func testOnlyTheNamesOfTheEnvGoOn() {
        XCTAssertEqual(DockerClient.names(in: [("POSTGRES_USER", "shop"), ("POSTGRES_PASSWORD", ""), ("PATH", "/bin")]), ["POSTGRES_USER", "PATH"])
        XCTAssertEqual(DockerClient.word("POSTGRES_PASSWORD", "POSTGRESQL_PASSWORD", in: ["POSTGRESQL_PASSWORD"]), #""$POSTGRESQL_PASSWORD""#)
        XCTAssertEqual(
            DockerClient.word("POSTGRES_PASSWORD", "POSTGRESQL_PASSWORD", in: ["POSTGRES_PASSWORD_FILE", "POSTGRESQL_PASSWORD"]),
            #""$(cat "$POSTGRES_PASSWORD_FILE")""#, "a name's secret file before the next name")
        XCTAssertNil(DockerClient.word("POSTGRES_PASSWORD", in: ["PGPASSWORD"]))
    }

    func testPostgres() {
        XCTAssertEqual(
            command(.postgres, ["POSTGRES_USER", "POSTGRES_PASSWORD", "POSTGRES_DB"]),
            #"docker exec -it shop-db-1 sh -c 'export PGPASSWORD="$POSTGRES_PASSWORD"; exec psql -U "$POSTGRES_USER" -d "$POSTGRES_DB"'"#)
        XCTAssertEqual(command(.postgres, ["POSTGRES_PASSWORD"]), #"docker exec -it shop-db-1 sh -c 'export PGPASSWORD="$POSTGRES_PASSWORD"; exec psql -U postgres -d postgres'"#)
        XCTAssertEqual(command(.postgres), "docker exec -it shop-db-1 psql -U postgres -d postgres", "nothing to expand: no shell")
        XCTAssertEqual(command(.postgres, ["POSTGRES_USER"]), #"docker exec -it shop-db-1 sh -c 'exec psql -U "$POSTGRES_USER" -d "$POSTGRES_USER"'"#, "the image's own default")
        XCTAssertEqual(
            command(.postgres, ["POSTGRES_PASSWORD_FILE"]),
            #"docker exec -it shop-db-1 sh -c 'export PGPASSWORD="$(cat "$POSTGRES_PASSWORD_FILE")"; exec psql -U postgres -d postgres'"#)
        XCTAssertEqual(
            command(.postgres, ["POSTGRESQL_USERNAME", "POSTGRESQL_PASSWORD", "POSTGRESQL_DATABASE"]),
            #"docker exec -it shop-db-1 sh -c 'export PGPASSWORD="$POSTGRESQL_PASSWORD"; exec psql -U "$POSTGRESQL_USERNAME" -d "$POSTGRESQL_DATABASE"'"#, "Bitnami's")
        XCTAssertEqual(
            command(.postgres, ["POSTGRESQL_USERNAME", "POSTGRESQL_PASSWORD"]),
            #"docker exec -it shop-db-1 sh -c 'export PGPASSWORD="$POSTGRESQL_PASSWORD"; exec psql -U "$POSTGRESQL_USERNAME" -d postgres'"#,
            "Bitnami's database is postgres whoever the user")
        XCTAssertEqual(
            command(.postgres, ["POSTGRES_USER_FILE"]), #"docker exec -it shop-db-1 sh -c 'exec psql -U "$(cat "$POSTGRES_USER_FILE")" -d "$(cat "$POSTGRES_USER_FILE")"'"#)
    }

    func testMySQLAndMariaDB() {
        XCTAssertEqual(command(.mysql, ["MYSQL_ROOT_PASSWORD"]), #"docker exec -it shop-db-1 sh -c 'exec mysql -u root -p"$MYSQL_ROOT_PASSWORD"'"#)
        XCTAssertEqual(
            command(.mysql, ["MYSQL_ROOT_PASSWORD", "MYSQL_USER", "MYSQL_PASSWORD", "MYSQL_DATABASE"]),
            #"docker exec -it shop-db-1 sh -c 'exec mysql -u "$MYSQL_USER" -p"$MYSQL_PASSWORD" "$MYSQL_DATABASE"'"#, "the app's own user over root")
        XCTAssertEqual(
            command(.mysql, ["MYSQL_ROOT_PASSWORD", "MYSQL_DATABASE"]), #"docker exec -it shop-db-1 sh -c 'exec mysql -u root -p"$MYSQL_ROOT_PASSWORD" "$MYSQL_DATABASE"'"#)
        XCTAssertEqual(command(.mysql, ["MYSQL_ALLOW_EMPTY_PASSWORD"]), "docker exec -it shop-db-1 mysql -u root")
        XCTAssertEqual(command(.mysql, ["MYSQL_RANDOM_ROOT_PASSWORD"]), "docker exec -it shop-db-1 mysql -u root -p", "asks for it")
        XCTAssertEqual(command(.mysql, ["MYSQL_USER"]), "docker exec -it shop-db-1 mysql -u root -p", "no password: the image made no user")
        XCTAssertEqual(
            command(.mysql, ["MYSQL_USER", "MYSQL_ROOT_PASSWORD", "MYSQL_DATABASE"]),
            #"docker exec -it shop-db-1 sh -c 'exec mysql -u root -p"$MYSQL_ROOT_PASSWORD" "$MYSQL_DATABASE"'"#, "root, whose password is there")
        XCTAssertEqual(
            command(.mariadb, ["MARIADB_USER", "MARIADB_ROOT_PASSWORD"]),
            #"docker exec -it shop-db-1 sh -c 'exec "$(command -v mariadb || echo mysql)" -u root -p"$MARIADB_ROOT_PASSWORD"'"#)
        XCTAssertEqual(
            command(.mariadb, ["MARIADB_ROOT_PASSWORD"]), #"docker exec -it shop-db-1 sh -c 'exec "$(command -v mariadb || echo mysql)" -u root -p"$MARIADB_ROOT_PASSWORD"'"#)
        XCTAssertEqual(
            command(.mariadb, ["MYSQL_ROOT_PASSWORD"]), #"docker exec -it shop-db-1 sh -c 'exec "$(command -v mariadb || echo mysql)" -u root -p"$MYSQL_ROOT_PASSWORD"'"#,
            "MariaDB's images take MySQL's names too")
        XCTAssertEqual(
            command(.mariadb, ["MARIADB_ALLOW_EMPTY_ROOT_PASSWORD"]), #"docker exec -it shop-db-1 sh -c 'exec "$(command -v mariadb || echo mysql)" -u root'"#)
        XCTAssertEqual(
            command(.mariadb, ["MARIADB_USER", "MARIADB_PASSWORD", "MARIADB_DATABASE"]),
            #"docker exec -it shop-db-1 sh -c 'exec "$(command -v mariadb || echo mysql)" -u "$MARIADB_USER" -p"$MARIADB_PASSWORD" "$MARIADB_DATABASE"'"#)
    }

    func testRedisAndValkey() {
        XCTAssertEqual(command(.redis), "docker exec -it shop-db-1 redis-cli")
        XCTAssertEqual(command(.redis, ["REDIS_PASSWORD"]), #"docker exec -it shop-db-1 sh -c 'export REDISCLI_AUTH="$REDIS_PASSWORD"; exec redis-cli'"#)
        XCTAssertEqual(
            command(.redis, ["REDIS_PASSWORD", "REDIS_PORT_NUMBER"]),
            #"docker exec -it shop-db-1 sh -c 'export REDISCLI_AUTH="$REDIS_PASSWORD"; exec redis-cli -p "$REDIS_PORT_NUMBER"'"#)
        XCTAssertEqual(command(.valkey), "docker exec -it shop-db-1 valkey-cli")
        XCTAssertEqual(command(.valkey, ["VALKEY_PASSWORD"]), #"docker exec -it shop-db-1 sh -c 'export REDISCLI_AUTH="$VALKEY_PASSWORD"; exec valkey-cli'"#)
        XCTAssertEqual(command(.valkey, ["REDIS_PASSWORD"]), #"docker exec -it shop-db-1 sh -c 'export REDISCLI_AUTH="$REDIS_PASSWORD"; exec valkey-cli'"#)
    }

    func testMongo() {
        let mongosh = #""$(command -v mongosh || echo mongo)""#
        XCTAssertEqual(command(.mongo), "docker exec -it shop-db-1 sh -c 'exec \(mongosh)'")
        XCTAssertEqual(
            command(.mongo, ["MONGO_INITDB_ROOT_USERNAME", "MONGO_INITDB_ROOT_PASSWORD"]),
            #"docker exec -it shop-db-1 sh -c 'exec "#
                + mongosh + #" -u "$MONGO_INITDB_ROOT_USERNAME" -p "$MONGO_INITDB_ROOT_PASSWORD" --authenticationDatabase admin'"#)
        XCTAssertEqual(
            command(.mongo, ["MONGO_INITDB_ROOT_USERNAME", "MONGO_INITDB_ROOT_PASSWORD", "MONGO_INITDB_DATABASE"]),
            #"docker exec -it shop-db-1 sh -c 'exec "#
                + mongosh + #" -u "$MONGO_INITDB_ROOT_USERNAME" -p "$MONGO_INITDB_ROOT_PASSWORD" --authenticationDatabase admin "$MONGO_INITDB_DATABASE"'"#)
        XCTAssertEqual(
            command(.mongo, ["MONGODB_ROOT_PASSWORD"]),
            #"docker exec -it shop-db-1 sh -c 'exec "# + mongosh + #" -u root -p "$MONGODB_ROOT_PASSWORD" --authenticationDatabase admin'"#, "Bitnami's root")
        XCTAssertEqual(
            command(.mongo, ["MONGO_INITDB_ROOT_USERNAME_FILE", "MONGO_INITDB_ROOT_PASSWORD_FILE"]),
            #"docker exec -it shop-db-1 sh -c 'exec "#
                + mongosh + #" -u "$(cat "$MONGO_INITDB_ROOT_USERNAME_FILE")" -p "$(cat "$MONGO_INITDB_ROOT_PASSWORD_FILE")" --authenticationDatabase admin'"#)
        XCTAssertEqual(
            command(.mongo, ["MONGO_INITDB_ROOT_USERNAME"]),
            #"docker exec -it shop-db-1 sh -c 'exec "# + mongosh + #" -u "$MONGO_INITDB_ROOT_USERNAME" --authenticationDatabase admin'"#, "asks for it")
    }

    func testClickHouse() {
        XCTAssertEqual(command(.clickhouse), "docker exec -it shop-db-1 clickhouse-client")
        XCTAssertEqual(
            command(.clickhouse, ["CLICKHOUSE_USER", "CLICKHOUSE_PASSWORD", "CLICKHOUSE_DB"]),
            #"docker exec -it shop-db-1 sh -c 'exec clickhouse-client --database "$CLICKHOUSE_DB"'"#, "it reads its own variables")
        XCTAssertEqual(command(.clickhouse, ["CLICKHOUSE_USER", "CLICKHOUSE_PASSWORD"]), "docker exec -it shop-db-1 clickhouse-client")
        XCTAssertEqual(
            command(.clickhouse, ["CLICKHOUSE_PASSWORD_FILE"]),
            #"docker exec -it shop-db-1 sh -c 'export CLICKHOUSE_PASSWORD="$(cat "$CLICKHOUSE_PASSWORD_FILE")"; exec clickhouse-client'"#)
        XCTAssertEqual(
            command(.clickhouse, ["CLICKHOUSE_ADMIN_USER", "CLICKHOUSE_ADMIN_PASSWORD"]),
            #"docker exec -it shop-db-1 sh -c 'export CLICKHOUSE_USER="$CLICKHOUSE_ADMIN_USER"; export CLICKHOUSE_PASSWORD="$CLICKHOUSE_ADMIN_PASSWORD"; exec clickhouse-client'"#,
            "Bitnami's")
    }

    func testCassandraNeo4jAndSQLServer() {
        XCTAssertEqual(command(.cassandra), "docker exec -it shop-db-1 cqlsh")
        XCTAssertEqual(command(.cassandra, ["CASSANDRA_USER", "CASSANDRA_PASSWORD"]), #"docker exec -it shop-db-1 sh -c 'exec cqlsh -u "$CASSANDRA_USER"'"#, "cqlsh asks")
        XCTAssertEqual(command(.neo4j), "docker exec -it shop-db-1 cypher-shell")
        let split = #"[ "$NEO4J_AUTH" = none ] || export NEO4J_USERNAME="${NEO4J_AUTH%%/*}" NEO4J_PASSWORD="${NEO4J_AUTH#*/}""#
        XCTAssertEqual(command(.neo4j, ["NEO4J_AUTH"]), "docker exec -it shop-db-1 sh -c '\(split); exec cypher-shell'")
        XCTAssertEqual(
            command(.neo4j, ["NEO4J_AUTH_FILE"]), #"docker exec -it shop-db-1 sh -c 'NEO4J_AUTH="$(cat "$NEO4J_AUTH_FILE")"; "# + split + "; exec cypher-shell'")
        let sqlcmd = #"c=/opt/mssql-tools18/bin/sqlcmd; [ -x "$c" ] || c=/opt/mssql-tools/bin/sqlcmd"#
        let run = #"exec "$c" -S localhost -U sa -C"#
        XCTAssertEqual(command(.mssql), "docker exec -it shop-db-1 sh -c '\(sqlcmd); \(run)'")
        XCTAssertEqual(command(.mssql, ["MSSQL_SA_PASSWORD"]), "docker exec -it shop-db-1 sh -c '\(sqlcmd); export SQLCMDPASSWORD=\"$MSSQL_SA_PASSWORD\"; \(run)'")
        XCTAssertEqual(command(.mssql, ["SA_PASSWORD"]), "docker exec -it shop-db-1 sh -c '\(sqlcmd); export SQLCMDPASSWORD=\"$SA_PASSWORD\"; \(run)'")
    }

    /// Every name any client reads.
    private static let everyName: Set<String> = [
        "POSTGRES_USER", "POSTGRESQL_USERNAME", "POSTGRES_DB", "POSTGRESQL_DATABASE", "POSTGRES_PASSWORD", "POSTGRESQL_PASSWORD", "MYSQL_USER", "MYSQL_PASSWORD",
        "MYSQL_ROOT_PASSWORD", "MYSQL_DATABASE", "MYSQL_ALLOW_EMPTY_PASSWORD", "MARIADB_USER", "MARIADB_PASSWORD", "MARIADB_ROOT_PASSWORD", "MARIADB_DATABASE",
        "MARIADB_ALLOW_EMPTY_ROOT_PASSWORD", "REDIS_PASSWORD", "REDIS_PORT_NUMBER", "VALKEY_PASSWORD", "VALKEY_PORT_NUMBER", "MONGO_INITDB_ROOT_USERNAME",
        "MONGODB_ROOT_USER", "MONGO_INITDB_ROOT_PASSWORD", "MONGODB_ROOT_PASSWORD", "MONGO_INITDB_DATABASE", "MONGODB_DATABASE", "CLICKHOUSE_USER",
        "CLICKHOUSE_ADMIN_USER", "CLICKHOUSE_PASSWORD", "CLICKHOUSE_ADMIN_PASSWORD", "CLICKHOUSE_DB", "CASSANDRA_USER", "NEO4J_AUTH", "MSSQL_SA_PASSWORD",
        "SA_PASSWORD",
    ]

    func testTheCommandsReachTheEngineAndAreQuoted() {
        let endpoint = DockerEndpoint(address: .unix("/tmp/fake.sock"), context: nil, source: "OVERTERM_DOCKER_HOST")
        XCTAssertEqual(
            DockerClient.command(.postgres, in: db(), env: [], endpoint: endpoint), "DOCKER_HOST=unix:///tmp/fake.sock docker exec -it shop-db-1 psql -U postgres -d postgres")
        XCTAssertEqual(DockerClient.command(.redis, in: db("redis:7", name: "it's"), env: []), #"docker exec -it 'it'\''s' redis-cli"#)
        let files = Set(Self.everyName.map { $0 + "_FILE" })
        for env in [Self.everyName, files, []] {
            for kind in DockerClient.Kind.allCases {
                let arguments = DockerClient.arguments(kind, env: env)
                let command = DockerClient.command(kind, in: db(), env: env)
                if arguments.first == "sh" {
                    XCTAssertEqual(arguments.count, 3, "\(kind)")
                    XCTAssertFalse(arguments[2].contains("'"), "\(kind): one single-quoted word")
                    XCTAssertTrue(command.hasSuffix(" sh -c '\(arguments[2])'"), command)
                } else {
                    XCTAssertTrue(arguments.allSatisfy { DockerCommands.quote($0) == $0 }, "\(kind): \(arguments)")
                }
            }
        }
    }

    /// The scripts as the container's shell runs them — sh and dash, with
    /// stub clients that print what they were given and the variables
    /// they sign in with — and a password no shell would like.
    func testTheContainersShellSignsIn() async throws {
        let files = FileManager.default
        let folder = files.temporaryDirectory.appendingPathComponent("ot-clients-\(UUID().uuidString)")
        let bin = folder.appendingPathComponent("bin"), old = folder.appendingPathComponent("old")
        try files.createDirectory(at: bin, withIntermediateDirectories: true)
        try files.createDirectory(at: old, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: folder) }
        let stub = #"""
            #!/bin/sh
            echo "${0##*/}"
            for a in "$@"; do printf '%s\n' "$a"; done
            env | grep -E '^(PGPASSWORD|REDISCLI_AUTH|CLICKHOUSE_USER|CLICKHOUSE_PASSWORD|NEO4J_USERNAME|NEO4J_PASSWORD)=' | sort

            """#
        func write(_ name: String, in place: URL) throws {
            let file = place.appendingPathComponent(name)
            try stub.write(to: file, atomically: true, encoding: .utf8)
            try files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }
        for name in ["psql", "mysql", "mariadb", "redis-cli", "valkey-cli", "mongosh", "clickhouse-client", "cypher-shell"] { try write(name, in: bin) }
        try write("mysql", in: old)
        let password = #"p@ss w$rd'""#
        let secret = folder.appendingPathComponent("secret")
        try (password + "\n").write(to: secret, atomically: true, encoding: .utf8)
        let shells = ["/bin/sh", "/bin/dash"].filter { files.isExecutableFile(atPath: $0) }
        XCTAssertFalse(shells.isEmpty)

        func signs(_ kind: DockerClient.Kind, _ env: [String: String], in place: URL? = nil, _ expected: [String], line: UInt = #line) async throws {
            // The names as openClient makes them, from inspect's values.
            let names = DockerClient.names(in: env.map { ($0.key, $0.value) })
            let arguments = DockerClient.arguments(kind, env: names)
            let command = DockerClient.command(kind, in: db(), env: names)
            XCTAssertFalse(command.contains("p@ss") || command.contains("pa/ss") || command.contains(secret.path), "only names: \(command)", line: line)
            let variables = ["PATH=\((place ?? bin).path):/usr/bin:/bin"] + env.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
            for shell in shells {
                let words = arguments.first == "sh" ? [shell] + arguments.dropFirst() : arguments
                let output = try await Git.run(URL(fileURLWithPath: "/usr/bin/env"), ["-i"] + variables + words, in: folder)
                XCTAssertEqual(output.split(separator: "\n", omittingEmptySubsequences: false).dropLast().map(String.init), expected, "\(kind) under \(shell)", line: line)
            }
        }

        try await signs(.postgres, ["POSTGRES_USER": "shop", "POSTGRES_PASSWORD": password, "POSTGRES_DB": "orders"], ["psql", "-U", "shop", "-d", "orders", "PGPASSWORD=" + password])
        try await signs(.postgres, ["POSTGRES_PASSWORD_FILE": secret.path], ["psql", "-U", "postgres", "-d", "postgres", "PGPASSWORD=" + password])
        try await signs(.postgres, [:], ["psql", "-U", "postgres", "-d", "postgres"])
        // An empty value is no name: nothing exported.
        try await signs(.postgres, ["POSTGRES_USER": "shop", "POSTGRES_PASSWORD": ""], ["psql", "-U", "shop", "-d", "shop"])
        try await signs(
            .postgres, ["POSTGRESQL_USERNAME": "shop", "POSTGRESQL_PASSWORD": password], ["psql", "-U", "shop", "-d", "postgres", "PGPASSWORD=" + password])
        try await signs(.mysql, ["MYSQL_USER": "app", "MYSQL_ROOT_PASSWORD": password], ["mysql", "-u", "root", "-p" + password])
        try await signs(.mysql, ["MYSQL_USER": "shop", "MYSQL_PASSWORD": password, "MYSQL_DATABASE": "orders"], ["mysql", "-u", "shop", "-p" + password, "orders"])
        try await signs(.mariadb, ["MARIADB_ROOT_PASSWORD": password], ["mariadb", "-u", "root", "-p" + password])
        try await signs(.mariadb, ["MARIADB_ROOT_PASSWORD": password], in: old, ["mysql", "-u", "root", "-p" + password])
        try await signs(.redis, ["REDIS_PASSWORD": password, "REDIS_PORT_NUMBER": "6380"], ["redis-cli", "-p", "6380", "REDISCLI_AUTH=" + password])
        try await signs(.valkey, ["VALKEY_PASSWORD": password], ["valkey-cli", "REDISCLI_AUTH=" + password])
        try await signs(
            .mongo, ["MONGO_INITDB_ROOT_USERNAME": "admin", "MONGO_INITDB_ROOT_PASSWORD": password, "MONGO_INITDB_DATABASE": "shop"],
            ["mongosh", "-u", "admin", "-p", password, "--authenticationDatabase", "admin", "shop"])
        try await signs(.mongo, ["MONGO_INITDB_ROOT_PASSWORD_FILE": secret.path], ["mongosh", "-u", "root", "-p", password, "--authenticationDatabase", "admin"])
        try await signs(
            .clickhouse, ["CLICKHOUSE_ADMIN_USER": "boss", "CLICKHOUSE_ADMIN_PASSWORD": password], ["clickhouse-client", "CLICKHOUSE_PASSWORD=" + password, "CLICKHOUSE_USER=boss"])
        try await signs(
            .clickhouse, ["CLICKHOUSE_USER": "boss", "CLICKHOUSE_PASSWORD": password, "CLICKHOUSE_DB": "shop"],
            ["clickhouse-client", "--database", "shop", "CLICKHOUSE_PASSWORD=" + password, "CLICKHOUSE_USER=boss"])
        try await signs(.neo4j, ["NEO4J_AUTH": "neo4j/pa/ss"], ["cypher-shell", "NEO4J_PASSWORD=pa/ss", "NEO4J_USERNAME=neo4j"])
        try await signs(.neo4j, ["NEO4J_AUTH": "neo4j/" + password], ["cypher-shell", "NEO4J_PASSWORD=" + password, "NEO4J_USERNAME=neo4j"])
        try await signs(.neo4j, ["NEO4J_AUTH": "none"], ["cypher-shell"])
    }
}

/// Who has the port a container couldn't start on. Pure.
final class PortConflictsTests: XCTestCase {
    func testThePortFromTheEnginesWords() {
        XCTAssertEqual(PortConflicts.port(in: "driver failed programming external connectivity on endpoint shop-db-1 (abc): Bind for 0.0.0.0:5432 failed: port is already allocated"), 5432)
        XCTAssertEqual(PortConflicts.port(in: "Error starting userland proxy: listen tcp4 0.0.0.0:8080: bind: address already in use"), 8080)
        XCTAssertEqual(
            PortConflicts.port(in: "ports are not available: exposing port TCP 0.0.0.0:3000 -> 127.0.0.1:0: listen tcp 0.0.0.0:3000: bind: address already in use"), 3000)
        XCTAssertEqual(PortConflicts.port(in: "Bind for [::]:9000 failed: port is already allocated"), 9000)
        XCTAssertNil(PortConflicts.port(in: "OCI runtime create failed: exec: \"nope\": executable file not found"))
    }

    func testTheContainerHoldingIt() {
        func container(_ id: String, state: String, port: Int?) -> ContainerSummary {
            ContainerSummary(
                Id: id, Names: ["/" + id], Image: "x", Created: 1, Ports: port.map { [DockerPort(IP: "0.0.0.0", PrivatePort: 80, PublicPort: $0, Type: "tcp")] },
                State: state, Status: "")
        }
        let all = [container("me", state: "created", port: nil), container("old", state: "exited", port: 5432), container("main-db", state: "running", port: 5432)]
        XCTAssertEqual(PortConflicts.container(holding: 5432, among: all, except: "me")?.Id, "main-db", "a stopped one holds nothing")
        XCTAssertNil(PortConflicts.container(holding: 5432, among: all, except: "main-db"))
        XCTAssertEqual(
            PortConflicts.holderText(.container(id: "x", name: "shop-db-1", project: "shop", folder: "/w/shop")),
            "shop-db-1 publishes it — compose project shop in /w/shop.")
    }
}

/// The Run window's command, and a container's as a `docker run`. Pure.
final class DockerRunSpecTests: XCTestCase {
    func testTheCommand() {
        var spec = DockerRunSpec(image: "postgres:16")
        XCTAssertEqual(spec.line(), "docker run -d postgres:16")
        spec.name = "pg"
        spec.ports = ["55432:5432"]
        spec.env = ["POSTGRES_PASSWORD=it's"]
        spec.volumes = ["pgdata:/var/lib/postgresql/data"]
        spec.restart = "unless-stopped"
        spec.removeWhenStopped = true
        XCTAssertEqual(
            spec.line(prefix: "DOCKER_CONTEXT=orbstack "),
            #"DOCKER_CONTEXT=orbstack docker run -d --rm --name pg --restart unless-stopped -p 55432:5432 -e 'POSTGRES_PASSWORD=it'\''s' -v pgdata:/var/lib/postgresql/data postgres:16"#)
        spec = DockerRunSpec(image: "debian:bookworm-slim", detached: false)
        spec.command = "bash -lc 'echo hi'"
        XCTAssertEqual(spec.line(), "docker run -it debian:bookworm-slim bash -lc 'echo hi'", "the command as typed")
        XCTAssertEqual(DockerRunSpec.lines("8080:80\n\n 9090:90 \n"), ["8080:80", "9090:90"])
    }

    func testAContainerAsADockerRun() {
        let container = ContainerSummary(
            Id: "x", Names: ["/shop-db-1"], Image: "postgres:16", Created: 1,
            Ports: [DockerPort(IP: "127.0.0.1", PrivatePort: 5432, PublicPort: 55432, Type: "tcp"), DockerPort(IP: "0.0.0.0", PrivatePort: 53, PublicPort: 5353, Type: "udp")],
            State: "running", Status: "")
        let detail = ContainerDetail(
            Id: "x", Name: "/shop-db-1", State: .init(Status: "running"),
            Config: .init(
                Image: "postgres:16", Env: ["PATH=/usr/bin", "PG_MAJOR=16", "POSTGRES_PASSWORD=pw"], Cmd: ["postgres"], Tty: false),
            HostConfig: .init(RestartPolicy: .init(Name: "unless-stopped"), NetworkMode: "shop_default"),
            Mounts: [
                DockerMountPoint(Type: "volume", Name: "shop_pgdata", Destination: "/var/lib/postgresql/data", RW: true),
                DockerMountPoint(Type: "bind", Source: "/w/shop/init.sql", Destination: "/docker-entrypoint-initdb.d/init.sql", RW: false),
            ])
        let spec = DockerRunSpec.from(container, detail, imageEnv: ["PATH=/usr/bin", "PG_MAJOR=16"], imageCommand: ["postgres"])
        XCTAssertEqual(spec.env, ["POSTGRES_PASSWORD=pw"], "the image's own env left out")
        XCTAssertEqual(spec.ports, ["5353:53/udp", "127.0.0.1:55432:5432"])
        XCTAssertEqual(spec.volumes, ["shop_pgdata:/var/lib/postgresql/data", "/w/shop/init.sql:/docker-entrypoint-initdb.d/init.sql:ro"])
        XCTAssertEqual(spec.restart, "unless-stopped")
        XCTAssertEqual(spec.network, "shop_default")
        XCTAssertEqual(spec.command, "", "the image's command isn't repeated")
        XCTAssertEqual(spec.name, "shop-db-1")
    }
}

/// Builds as `buildx history` lists and inspects them. Pure.
final class DockerBuildsTests: XCTestCase {
    func testTheList() {
        let output = """
            {"cached_steps":4,"completed_at":"2026-10-27T23:46:12.690946503Z","completed_steps":16,"created_at":"2026-10-27T23:46:05.810768264Z","name":"cloudgate/images/pricing","ref":"desktop-linux/desktop-linux/7a1qpic0olvq2psgkzi3giark","status":"Completed","total_steps":16}
            not json
            {"cached_steps":0,"completed_at":"2026-10-28T09:00:03Z","completed_steps":2,"created_at":"2026-10-28T09:00:00Z","name":"shop/api","ref":"default/default/def456","status":"Error","total_steps":4}
            """
        let builds = DockerBuildRecord.parse(output)
        XCTAssertEqual(builds.map(\.name), ["shop/api", "cloudgate/images/pricing"], "newest first")
        XCTAssertEqual(builds.last?.shortRef, "7a1qpic0olvq2psgkzi3giark")
        XCTAssertEqual(builds.last?.duration ?? 0, 6.88, accuracy: 0.01)
        XCTAssertTrue(builds.first?.failed == true)
        XCTAssertEqual(DockerBuildRecord.duration(6.88), "6.9 s")
        XCTAssertEqual(DockerBuildRecord.duration(134), "2 min 14 s")
    }

    func testADetailMasksItsSecrets() throws {
        let context = FileManager.default.temporaryDirectory.appendingPathComponent("ot-build-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: context.appendingPathComponent("images/web"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: context) }
        try Data("FROM scratch\n".utf8).write(to: context.appendingPathComponent("images/web/Dockerfile"))
        let json = """
            {"Context":"\(context.path)","Dockerfile":"images/web/Dockerfile","BuildArgs":[{"Name":"NPM_TOKEN","Value":"npm_abc"},{"Name":"GOPROXY","Value":"http://proxy"}],"VCSRepository":"git@github.com:me/shop.git","VCSRevision":"4264981635"}
            """
        let detail = try XCTUnwrap(DockerBuildDetail.parse(json))
        XCTAssertEqual(detail.buildArgs.map { "\($0.key)=\($0.value)" }, ["NPM_TOKEN=••••••", "GOPROXY=http://proxy"])
        XCTAssertEqual(detail.dockerfileURL?.path, context.appendingPathComponent("images/web/Dockerfile").path)
        XCTAssertEqual(detail.repository, "git@github.com:me/shop.git")
        XCTAssertEqual(detail.secrets, ["npm_abc"], "kept to take out of step names, in memory only")
        XCTAssertNil(DockerBuildDetail.parse("nope"))

        // BuildKit expands an ARG into a RUN step's name, which the error names.
        let sources = Data("Dockerfile:4\n>>> RUN echo $NPM_TOKEN\n".utf8).base64EncodedString()
        let failed = try XCTUnwrap(
            DockerBuildDetail.parse(
                #"{"BuildArgs":[{"Name":"NPM_TOKEN","Value":"npm_abc"}],"Status":"failed","Error":{"Code":2,"Message":"process \"/bin/sh -c echo npm_abc\" did not complete","Name":"[web 2/2] RUN echo npm_abc","Sources":"\#(sources)"}}"#
            ))
        XCTAssertEqual(failed.status, "failed")
        XCTAssertEqual(failed.errorStep, "[web 2/2] RUN echo ••••••")
        XCTAssertFalse(failed.error?.contains("npm_abc") ?? true, failed.error ?? "")
        XCTAssertTrue(failed.errorSource?.contains(">>> RUN") == true, failed.errorSource ?? "")
        XCTAssertEqual(failed.secrets, ["npm_abc"])
    }

    func testARunningRecord() throws {
        let output = """
            {"cached_steps":0,"completed_at":"2026-10-28T10:00:07Z","completed_steps":5,"created_at":"2026-10-28T10:00:00Z","name":"shop/web","ref":"default/default/abc123","status":"Completed","total_steps":5}
            {"cached_steps":1,"completed_steps":2,"created_at":"2026-10-28T09:00:00.5Z","name":"shop/worker","ref":"default/default/run789","status":"Running","total_steps":4}
            """
        let builds = DockerBuildRecord.parse(output)
        XCTAssertEqual(builds.map(\.name), ["shop/worker", "shop/web"], "a running one first, older or not")
        let running = try XCTUnwrap(builds.first)
        XCTAssertTrue(running.running)
        XCTAssertNil(running.duration)
        let created = try XCTUnwrap(DockerBuildRecord.date(running.createdAt))
        XCTAssertEqual(running.elapsed(now: created.addingTimeInterval(12)), 12, accuracy: 0.01)
        XCTAssertEqual(running.elapsed(now: created.addingTimeInterval(-3)), 0, "a clock ahead of this Mac's")
    }

    func testTheTabsCommand() {
        let build = DockerBuildRecord(
            ref: "default/default/abc123", name: "shop/web", status: "Running", createdAt: "", completedAt: nil, totalSteps: 0, cachedSteps: 0,
            completedSteps: 0)
        let orbstack = DockerEndpoint(address: .unix("/o.sock"), context: "orbstack", source: "docker.context")
        XCTAssertEqual(DockerCommands.buildLog(build, endpoint: orbstack), "DOCKER_CONTEXT=orbstack docker buildx history logs abc123")
        XCTAssertEqual(DockerCommands.buildLog(build), "docker buildx history logs abc123")
    }

    /// `buildx history ls` is read every few seconds, but only while the
    /// Builds section is on screen; a running build is selected once.
    @MainActor
    func testTheBuildsSectionReadsOnlyWhileItShows() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ot-builds-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let tool = folder.appendingPathComponent("docker")
        let record = #"{"cached_steps":0,"completed_steps":1,"created_at":"2026-10-28T10:00:00Z","name":"shop/worker","ref":"default/default/run789","status":"Running","total_steps":4}"#
        let script = """
            #!/bin/sh
            dir="$(dirname "$0")"
            case "$*" in
              "buildx history ls --format json") echo >> "$dir/count"; echo '\(record)' ;;
              *) exit 0 ;;
            esac
            """
        try Data(script.utf8).write(to: tool)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        func reads() -> Int { ((try? String(contentsOf: folder.appendingPathComponent("count"), encoding: .utf8)) ?? "").filter { $0 == "\n" }.count }
        func until(_ timeout: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while !condition() {
                if Date() > deadline { return false }
                try? await Task.sleep(for: .milliseconds(20))
            }
            return true
        }

        let page = DockerPageModel(docker: DockerModel(endpoint: { nil }))
        // Before anything shows: never the user's Docker.
        page.buildsCLIOverride = DockerCLI(executable: tool, endpoint: nil)
        page.buildPoll = 0.1
        page.showDetail = false
        defer { page.close() }
        page.section = .builds
        page.visible = true
        let listed = await until { page.builds.count == 1 }
        XCTAssertTrue(listed, page.buildsError ?? "nothing listed")
        let selected = await until { page.buildSelection == ["default/default/run789"] }
        XCTAssertTrue(selected, "a running build is selected, since nothing was")
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertGreaterThanOrEqual(reads(), 3, "read again while it shows")

        page.visible = false
        try await Task.sleep(for: .milliseconds(150))
        let hidden = reads()
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(reads(), hidden, "nothing read while hidden")

        page.buildSelection = []
        page.visible = true
        let readAgain = await until { reads() > hidden + 1 }
        XCTAssertTrue(readAgain)
        XCTAssertEqual(page.buildSelection, [], "selected once only")
    }

    /// No test, and no isolated run, reaches the user's Docker for builds.
    @MainActor
    func testATestReadsBuildsOnlyFromAStub() {
        let page = DockerPageModel(docker: DockerModel(endpoint: { nil }))
        XCTAssertNil(DockerCLI.override)
        XCTAssertNil(page.buildsCLI)
    }

    /// A running build's record can't be removed; `t` is its log in a tab.
    @MainActor
    func testARunningBuildsVerbs() throws {
        let page = DockerPageModel(docker: DockerModel(endpoint: { nil }))
        var ran: [String] = []
        page.actions = DockerActions(run: { command, _ in ran.append(command) }, confirm: { _, _, _, _ in }, open: { _ in }, copy: { _ in }, settings: {})
        let running = DockerBuildRecord(
            ref: "default/default/run789", name: "shop/worker", status: "Running", createdAt: "2026-10-28T10:00:00Z", completedAt: nil, totalSteps: 4,
            cachedSteps: 0, completedSteps: 1)
        let verbs = page.verbs(for: running)
        XCTAssertEqual(verbs.filter { $0.place == .button }.map(\.title), ["Log in a Tab", "Copy Ref"])
        XCTAssertEqual(verbs.first { $0.place == .remove }?.unavailable, "It's still running.")
        XCTAssertNil(verbs.first { $0.title == "Copy Log" }, "nothing read yet to copy")
        page.builds = [running]
        page.buildSelection = [running.id]
        page.section = .builds
        XCTAssertTrue(page.press("t"))
        XCTAssertEqual(ran, ["docker buildx history logs run789"])
    }

    /// ⌫ asks first, as its key says — a record is BuildKit's only account
    /// of how a build went — and never for one still running.
    @MainActor
    func testRemovingARecordAsksFirst() {
        let page = DockerPageModel(docker: DockerModel(endpoint: { nil }))
        var asked: [String] = []
        page.actions = DockerActions(run: { _, _ in }, confirm: { title, _, _, _ in asked.append(title) }, open: { _ in }, copy: { _ in }, settings: {})
        let done = DockerBuildRecord(
            ref: "default/default/abc123", name: "shop/web", status: "Completed", createdAt: "2026-10-28T10:00:00Z", completedAt: "2026-10-28T10:00:07Z",
            totalSteps: 5, cachedSteps: 2, completedSteps: 5)
        let running = DockerBuildRecord(
            ref: "default/default/run789", name: "shop/worker", status: "Running", createdAt: "2026-10-28T10:00:00Z", completedAt: nil, totalSteps: 4,
            cachedSteps: 0, completedSteps: 1)
        page.builds = [running, done]
        page.section = .builds
        page.buildSelection = [running.id]
        XCTAssertTrue(page.press("\u{7F}"))
        XCTAssertEqual(asked, [], "a running one's record is BuildKit's")
        page.buildSelection = [running.id, done.id]
        XCTAssertTrue(page.press("\u{7F}"))
        XCTAssertEqual(asked, ["Remove the record of “shop/web”?"])
        page.verbs(for: done).first { $0.place == .remove }?.perform()
        XCTAssertEqual(asked.count, 2, "its button asks too")
    }

    /// buildx 0.20's `history inspect`, which has no `--format`: what the
    /// steps' secrets are taken from.
    func testThePlainInspect() throws {
        let plain = """
            Context:\t\t/Users/me/shop
            Dockerfile:\tDockerfile
            VCS Repository:\tgit@github.com:me/shop.git
            VCS Revision:\t4264981635

            Started:\t2026-10-28 10:00:00
            Duration:\t1m 4s
            Error:\tUnknown process "/bin/sh -c echo npm_abc" did not complete successfully: exit code: 2
            Build Steps:\t3/5 (40% cached)

            BUILD ARG\tVALUE
            GOPROXY\t\thttp://proxy
            NPM_TOKEN\tnpm_abc

            Print build logs: docker buildx history logs abc123

            """
        let detail = try XCTUnwrap(DockerBuildDetail.parsePlain(plain))
        XCTAssertEqual(detail.buildArgs.map { "\($0.key)=\($0.value)" }, ["GOPROXY=http://proxy", "NPM_TOKEN=••••••"])
        XCTAssertEqual(detail.secrets, ["npm_abc"])
        XCTAssertEqual(detail.context, "/Users/me/shop")
        XCTAssertEqual(detail.repository, "git@github.com:me/shop.git")
        XCTAssertEqual(detail.status, "failed")
        XCTAssertEqual(detail.error, #"process "/bin/sh -c echo ••••••" did not complete successfully: exit code: 2"#)

        let running = try XCTUnwrap(DockerBuildDetail.parsePlain("Context:\t.\nStarted:\t2026-10-28 10:00:00\nDuration:\t4.5s (running)\n"))
        XCTAssertEqual(running.status, "running")
        XCTAssertEqual(running.buildArgs.count, 0, "no table: no build args")
        XCTAssertEqual(DockerBuildDetail.parsePlain("Context:\t.\nStatus:\tCanceled\nDuration:\t2s\n")?.status, "canceled")
        XCTAssertNil(DockerBuildDetail.parsePlain("ERROR: no record found\n"), "not one: its secrets never taken as none")
    }

    /// A list read that fails puts its error in place of the list and the
    /// detail: the follow stops with them. The next read that works — Read
    /// Again — brings back both, and the poll.
    @MainActor
    func testAFailedReadStopsTheFollowUntilOneWorks() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ot-builds-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/buildkit-rawjson-failed.jsonl")
        let tool = folder.appendingPathComponent("docker")
        let record = #"{"cached_steps":0,"completed_steps":1,"created_at":"2026-10-28T10:00:00Z","name":"shop/worker","ref":"default/default/run789","status":"Running","total_steps":4}"#
        let script = """
            #!/bin/sh
            dir="$(dirname "$0")"
            case "$*" in
              "buildx history ls --format json")
                echo >> "$dir/count"
                if [ -f "$dir/fail" ]; then echo 'error: timed out' >&2; exit 1; fi
                echo '\(record)' ;;
              "buildx history inspect run789 --format json") echo '{"Status":"running"}' ;;
              "buildx history logs --progress rawjson run789")
                echo $$ > "$dir/pid"; head -n 6 '\(fixture.path)' >&2
                n=0; while [ $n -lt 200 ]; do sleep 0.05; n=$((n+1)); done ;;
              *) echo "unexpected: $*" >&2; exit 1 ;;
            esac
            """
        try Data(script.utf8).write(to: tool)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        func reads() -> Int { ((try? String(contentsOf: folder.appendingPathComponent("count"), encoding: .utf8)) ?? "").filter { $0 == "\n" }.count }
        func pid() -> Int32? {
            (try? String(contentsOf: folder.appendingPathComponent("pid"), encoding: .utf8)).flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
        func until(_ timeout: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while !condition() {
                if Date() > deadline { return false }
                try? await Task.sleep(for: .milliseconds(20))
            }
            return true
        }

        let page = DockerPageModel(docker: DockerModel(endpoint: { nil }))
        page.buildsCLIOverride = DockerCLI(executable: tool, endpoint: nil)
        page.buildPoll = 0.1
        defer { page.close() }
        page.section = .builds
        page.visible = true
        let following = await until { page.buildSession?.state == .reading && page.buildSession?.progress.steps.count == 7 && pid() != nil }
        XCTAssertTrue(following, "\(String(describing: page.buildSession?.state))")
        XCTAssertEqual(page.buildSession?.ref, "run789", "made by the page, not by a view")
        XCTAssertTrue(page.buildSession?.recordRunning == true)
        let first = try XCTUnwrap(pid())

        FileManager.default.createFile(atPath: folder.appendingPathComponent("fail").path, contents: Data())
        let failed = await until { page.buildsError != nil && page.buildSession?.state == .stopped }
        XCTAssertTrue(failed, "\(page.buildsError ?? "no error"), \(String(describing: page.buildSession?.state))")
        let gone = await until { kill(first, 0) == -1 && errno == ESRCH }
        XCTAssertTrue(gone, "nothing read for a detail the error stands in for")
        let stopped = await until { page.buildWatch == nil }
        XCTAssertTrue(stopped, "the poll stops at a read that failed")
        let before = reads()
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(reads(), before, "and reads no more")

        try FileManager.default.removeItem(at: folder.appendingPathComponent("fail"))
        page.loadBuilds()
        let back = await until { page.buildsError == nil && page.buildSession?.state == .reading && pid() != first }
        XCTAssertTrue(back, "\(page.buildsError ?? "no error"), \(String(describing: page.buildSession?.state))")
        let polled = await until { reads() >= before + 4 }
        XCTAssertTrue(polled, "the poll again: \(before) → \(reads())")
    }
}
