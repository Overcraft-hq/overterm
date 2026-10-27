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
        XCTAssertEqual(DockerCommands.quote(""), "''")
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
    }

    /// Docker trims a fraction's trailing zeros; padded, the times sort.
    func testLogTimesSortAsTheyHappened() {
        XCTAssertLessThan(ContainerSession.sortable("2026-10-27T10:00:00.115Z"), ContainerSession.sortable("2026-10-27T10:00:00.12Z"))
        XCTAssertLessThan(ContainerSession.sortable("2026-10-27T10:00:00Z"), ContainerSession.sortable("2026-10-27T10:00:00.000000001Z"))
        XCTAssertEqual(ContainerSession.sortable("2026-10-27T10:00:00.5Z"), "2026-10-27T10:00:00.500000000Z")
        XCTAssertEqual(ContainerSession.seconds("1970-01-01T00:01:40.999999Z"), 100)
        XCTAssertNil(ContainerSession.seconds("yesterday"))
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
    }
}
