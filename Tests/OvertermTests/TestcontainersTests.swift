import Foundation
import XCTest

@testable import Overterm

/// Testcontainers' containers found by their labels, as each library
/// writes them, and put in a run each. Pure.
final class TestcontainersTests: XCTestCase {
    private func container(
        _ name: String, image: String = "postgres:16-alpine", labels: [String: String] = [:], created: Int = 1, state: String = "running"
    ) -> ContainerSummary {
        ContainerSummary(
            Id: name + "-0123456789", Names: ["/" + name], Image: image, Created: created, Labels: labels, State: state,
            Status: state == "running" ? "Up 1 minute" : "Exited (143) 1 minute ago")
    }

    private let java = ["org.testcontainers": "true", "org.testcontainers.lang": "java", "org.testcontainers.version": "1.21.3"]

    func testRunsAreFoundByEveryLibrarysLabels() {
        let a = "3f2a9c1e-0b5d-4c8e-9a7f-2d6e1b0c4a11"
        let b = "7d1e2f30-1111-4c8e-9a7f-2d6e1b0c4a11"
        let c = "c0ffee00-2222-4c8e-9a7f-2d6e1b0c4a11"
        let go = "9b2d4f6a8c0e1f3a5b7d9e1f3a5b7d9e1f3a5b7d9e1f3a5b7d9e1f3a5b7d9e1f"
        let kafka = container("kafka", image: "confluentinc/cp-kafka:7.6.0", labels: java.merging(["org.testcontainers.sessionId": a]) { $1 }, created: 120)
        let pg = container("pg", labels: java.merging(["org.testcontainers.sessionId": a]) { $1 }, created: 100)
        // Java's Ryuk carries no session: its name says it.
        let ryuk = container("testcontainers-ryuk-\(a)", image: "testcontainers/ryuk:0.14.0", labels: ["org.testcontainers": "true"], created: 90)
        let node = container(
            "mongo", image: "mongo:7", labels: ["org.testcontainers": "true", "org.testcontainers.lang": "node", "org.testcontainers.session-id": b],
            created: 300)
        let goReaper = container(
            "reaper_\(go)", image: "testcontainers/ryuk:0.11.0",
            labels: [
                "org.testcontainers": "true", "org.testcontainers.reaper": "true", "org.testcontainers.ryuk": "true",
                "org.testcontainers.sessionId": go, "org.testcontainers.lang": "go",
            ], created: 200)
        let goRedis = container(
            "redis", image: "redis:7", labels: ["org.testcontainers": "true", "org.testcontainers.lang": "go", "org.testcontainers.sessionId": go],
            created: 201)
        let dotnet = container(
            "sql", image: "mcr.microsoft.com/mssql/server:2022-latest",
            labels: [
                "org.testcontainers": "true", "org.testcontainers.lang": "dotnet", "org.testcontainers.session-id": c,
                "org.testcontainers.resource-reaper-session": c,
            ], created: 50)
        let plain = container("plain", image: "nginx:1.27")
        let compose = container(
            "shop-web-1", image: "nginx:1.27", labels: ["com.docker.compose.project": "shop", "com.docker.compose.service": "web"])

        let (sessions, rest) = Testcontainers.sessions([kafka, plain, pg, ryuk, node, goReaper, compose, goRedis, dotnet])
        XCTAssertEqual(sessions.map(\.id), [b, go, a, c], "the newest run first")
        let javaRun = sessions[2]
        XCTAssertEqual(javaRun.containers.map(\.name), ["pg", "kafka", "testcontainers-ryuk-\(a)"], "by when they were made, Ryuk last")
        XCTAssertEqual(javaRun.members.map(\.name), ["pg", "kafka"])
        XCTAssertEqual(javaRun.reaper?.name, ryuk.name)
        XCTAssertEqual(javaRun.lang, "java")
        XCTAssertEqual(javaRun.version, "1.21.3")
        XCTAssertEqual(javaRun.started, 90, "its first container, Ryuk")
        XCTAssertEqual(javaRun.running, 2)
        XCTAssertEqual(javaRun.shortID, "3f2a9c1e")
        XCTAssertEqual(javaRun.subtitle, "java · 3f2a9c1e")
        XCTAssertEqual(sessions[1].containers.map(\.name), ["redis", "reaper_\(go)"])
        XCTAssertEqual(sessions[1].reaper?.name, "reaper_\(go)")
        XCTAssertEqual(sessions[1].lang, "go")
        XCTAssertEqual(sessions[0].lang, "node")
        XCTAssertNil(sessions[0].reaper)
        XCTAssertNil(sessions[0].version)
        XCTAssertEqual(sessions[3].members.map(\.name), ["sql"])
        XCTAssertEqual(rest.map(\.name), ["plain", "shop-web-1"], "the rest as they came")
        XCTAssertTrue(sessions.allSatisfy { !$0.reused })
    }

    func testAReaperIsKnownByItsImageOrName() {
        for image in [
            "docker.io/testcontainers/ryuk:0.11.0", "testcontainers/ryuk:0.14.0@sha256:7c1a0bd1f5c3b4e2d8f9a6b7c5d4e3f2a1b0c9d8e7f6a5b4c3d2e1f0a9b8c7d6",
            "registry.corp/hub/testcontainers/ryuk:0.6.0", "registry.corp:5000/testcontainers/ryuk", "Testcontainers/Ryuk:0.5.1",
        ] {
            XCTAssertTrue(Testcontainers.isRyukImage(image), image)
            XCTAssertTrue(Testcontainers.isReaper(container("r", image: image)), image)
        }
        for image in ["myorg/ryukish:1", "ryuk:1", "testcontainers/ryuk-helper:1", "testcontainers/sshd:1.2.0"] {
            XCTAssertFalse(Testcontainers.isRyukImage(image), image)
        }
        // A custom Ryuk image, as TESTCONTAINERS_RYUK_CONTAINER_IMAGE names one.
        let custom = container("testcontainers-ryuk-X", image: "corp/reaper:2")
        XCTAssertTrue(Testcontainers.isReaper(custom))
        XCTAssertTrue(Testcontainers.isMember(custom), "a reaper is Testcontainers' with no label at all")
        XCTAssertEqual(Testcontainers.session(of: custom), "X")
        XCTAssertNil(Testcontainers.session(of: container("reaper_x", image: "nginx:1")), "a name alone isn't a reaper's")
        XCTAssertFalse(Testcontainers.isMember(container("reaper_x", image: "nginx:1")))
        XCTAssertNil(Testcontainers.session(of: container("testcontainers-ryuk-", image: "testcontainers/ryuk:0.14.0")), "no session after the prefix")
    }

    func testReusedContainersAreABlockOfTheirOwn() {
        let reused = container("kept", labels: java.merging(["org.testcontainers.hash": "a1b2"]) { $1 }, created: 10)
        let run = container("pg", labels: java.merging(["org.testcontainers.sessionId": "A"]) { $1 }, created: 5)
        let (sessions, rest) = Testcontainers.sessions([reused, run])
        XCTAssertEqual(sessions.map(\.id), ["A", ""], "the ones in no run last, however new")
        XCTAssertTrue(sessions[1].reused)
        XCTAssertEqual(sessions[1].shortID, "")
        XCTAssertEqual(sessions[1].subtitle, "java · reused")
        XCTAssertTrue(rest.isEmpty)
        XCTAssertEqual(Testcontainers.groupID(of: reused), "")
        XCTAssertNil(Testcontainers.groupID(of: container("plain")))
        let marked = Testcontainers.sessions([container("bare", labels: ["org.testcontainers": "true"])]).sessions
        XCTAssertEqual(marked.map(\.id), [""])
        XCTAssertFalse(marked[0].reused, "marked, but kept for nothing")
        XCTAssertEqual(marked[0].subtitle, "no session", "no library said")
        XCTAssertTrue(Testcontainers.isReused(container("n", labels: ["org.testcontainers.container-hash": "x"])), "Node's")
        XCTAssertTrue(Testcontainers.isReused(container("d", labels: ["org.testcontainers.reuse-hash": "x"])), ".NET's")
    }

    func testATestsComposeStackIsItsRun() {
        // Go's compose module labels a stack both ways.
        var labels = [
            "com.docker.compose.project": "tc-stack", "com.docker.compose.service": "db", "com.docker.compose.project.working_dir": "/Users/me/shop/src/test",
        ]
        labels.merge(["org.testcontainers": "true", "org.testcontainers.lang": "go", "org.testcontainers.sessionId": "B"]) { $1 }
        let stack = container("tc-stack-db-1", labels: labels)
        let shop = container("shop-web-1", labels: ["com.docker.compose.project": "shop", "com.docker.compose.service": "web"])
        let (sessions, rest) = Testcontainers.sessions([stack, shop])
        XCTAssertEqual(sessions.map(\.id), ["B"])
        XCTAssertEqual(sessions[0].members.map(\.name), ["tc-stack-db-1"])
        XCTAssertEqual(ComposeProjects.group(rest).projects.map(\.name), ["shop"], "not a compose project of its own")
    }

    func testARunsNetworks() {
        func network(_ name: String, _ labels: [String: String]) -> NetworkSummary {
            NetworkSummary(Name: name, Id: name + "-id", Labels: labels)
        }
        let networks = [
            network("java", ["org.testcontainers": "true", "org.testcontainers.sessionId": "A"]),
            network("node", ["org.testcontainers.session-id": "A"]),
            network("other", ["org.testcontainers.sessionId": "B"]),
            network("plain", [:]),
        ]
        XCTAssertEqual(Testcontainers.networks(of: "A", in: networks).map(\.Name), ["java", "node"])
        XCTAssertEqual(Testcontainers.networks(of: "", in: networks).map(\.Name), [], "those kept for reuse made none")
    }

    /// The volumes and the images a run made, as Ryuk finds them after its
    /// networks: by the session's label, whichever library wrote it.
    func testARunsVolumesAndImages() {
        func volume(_ name: String, _ labels: [String: String]?) -> VolumeSummary {
            VolumeSummary(Name: name, Driver: "local", Mountpoint: "/var/lib/docker/volumes/\(name)/_data", Labels: labels)
        }
        let volumes = [
            volume("go-data", ["org.testcontainers": "true", "org.testcontainers.sessionId": "A"]),
            volume("dotnet-data", ["org.testcontainers.resource-reaper-session": "A"]),
            volume("other", ["org.testcontainers.session-id": "B"]),
            volume("unlabelled", nil),
        ]
        XCTAssertEqual(Testcontainers.volumes(of: "A", in: volumes).map(\.Name), ["go-data", "dotnet-data"])
        XCTAssertEqual(Testcontainers.volumes(of: "", in: volumes).map(\.Name), [])
        func image(_ tag: String, _ labels: [String: String]?) -> ImageSummary {
            ImageSummary(Id: "sha256:" + tag, RepoTags: [tag], Created: 1, Size: 1, Labels: labels)
        }
        let images = [
            image("localhost/testcontainers/abc:latest", ["org.testcontainers": "true", "org.testcontainers.sessionId": "A"]),
            image("postgres:16-alpine", nil),
            image("localhost/testcontainers/def:latest", ["org.testcontainers.sessionId": "B"]),
        ]
        XCTAssertEqual(Testcontainers.images(of: "A", in: images).map(\.tags), [["localhost/testcontainers/abc:latest"]], "a pulled one carries none")
    }

    func testFolding() {
        func run(_ id: String) -> TestcontainersSession { TestcontainersSession(id: id, containers: [container("pg-" + id, labels: java)]) }
        let a = DockerPageModel.sessionTag("A")
        let b = DockerPageModel.sessionTag("B")
        let shop = DockerPageModel.projectTag("shop")
        var (collapsed, seen) = DockerPageModel.folding([shop], seen: [], sessions: [run("A")])
        XCTAssertEqual(collapsed, [shop, a], "a new run folded")
        XCTAssertEqual(seen, [a])
        collapsed.remove(a)
        (collapsed, seen) = DockerPageModel.folding(collapsed, seen: seen, sessions: [run("A"), run("B")])
        XCTAssertEqual(collapsed, [shop, b], "one unfolded stays so; the next new one is folded")
        (collapsed, seen) = DockerPageModel.folding(collapsed, seen: seen, sessions: [run("A")])
        XCTAssertEqual(collapsed, [shop], "a run gone is forgotten")
        XCTAssertEqual(seen, [a])
        (collapsed, seen) = DockerPageModel.folding(collapsed, seen: seen, sessions: [])
        XCTAssertEqual(collapsed, [shop], "a project's fold is its own")
        XCTAssertEqual(seen, [])
    }

    func testAge() {
        let session = TestcontainersSession(
            id: "A", containers: [container("pg", labels: java, created: 1060), container("kafka", labels: java, created: 1000)])
        XCTAssertEqual(session.started, 1000)
        XCTAssertEqual(UsageFormat.age(session.startedDate, now: Date(timeIntervalSince1970: 1300)), "5 min ago")
    }
}
