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
        XCTAssertNil(DockerKey.of("d"), "lower-case d is kept for later")
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
