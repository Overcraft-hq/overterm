import XCTest

@testable import Overterm
@testable import OvertermCore
@testable import OvertermDocker

/// Apple's `container` as the Docker page reads it: its JSON as 1.7.1
/// wrote it (the fixtures are its own output, a home folder renamed), the
/// commands Overterm gives it, where it is looked for, and the section's
/// model against a stand-in that answers from those fixtures — no test
/// runs the real tool but `testTheRealToolReads`, opted into.
@MainActor
final class AppleContainersTests: XCTestCase {
    private static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")

    private func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: Self.fixtures.appendingPathComponent("apple-container-\(name).json"))
    }

    // MARK: Reading

    func testContainersAsTheToolListsThem() throws {
        let containers = AppleContainers.containers(from: try fixture("list"))
        XCTAssertEqual(containers.map(\.id), ["overterm-probe-web", "overterm-probe-stopped"])
        let web = try XCTUnwrap(containers.first)
        XCTAssertEqual(web.state, .running)
        XCTAssertEqual(web.image, "docker.io/library/nginx:alpine")
        XCTAssertEqual(AppleContainers.shortReference(web.image), "nginx:alpine")
        XCTAssertEqual(web.command, ["/docker-entrypoint.sh", "nginx", "-g", "daemon off;"])
        XCTAssertEqual(web.ports.map(\.label), ["127.0.0.1:18080→80/tcp"])
        XCTAssertEqual(web.ports.first?.url?.absoluteString, "http://127.0.0.1:18080")
        XCTAssertEqual(web.address, "192.168.64.2")
        XCTAssertEqual(web.networks.first?.name, "default")
        XCTAssertEqual(web.mounts, [.init(source: "/Users/dev/Library/Application Support/com.apple.container/volumes/overterm-probe-vol/volume.img", destination: "/data")])
        XCTAssertEqual(web.labels, ["app": "probe"])
        XCTAssertEqual(web.platform, "linux/arm64/v8")
        XCTAssertEqual(web.cpus, 4)
        XCTAssertEqual(web.memoryBytes, 1_073_741_824)
        XCTAssertNotNil(web.started)
        XCTAssertNotNil(web.created)
        // A secret-looking value never reaches the page.
        XCTAssertTrue(web.environment.contains("MODE=demo"))
        XCTAssertFalse(web.environment.joined().contains("probe-not-secret"), "\(web.environment)")
        XCTAssertTrue(web.environment.contains { $0.hasPrefix("API_TOKEN=") })

        let stopped = containers[1]
        XCTAssertEqual(stopped.state, .stopped)
        XCTAssertFalse(stopped.state.isUp)
        XCTAssertNil(stopped.address)
        XCTAssertNil(stopped.started)
    }

    /// Before 1.7 a container's status was a word, its networks beside it,
    /// an address called `address`: still read.
    func testTheOlderShapeStillReads() {
        let json = #"""
            [{"configuration":{"id":"old","image":{"reference":"docker.io/library/redis:7"},"initProcess":{"executable":"redis-server","arguments":[]},
              "publishedPorts":[{"hostAddress":"0.0.0.0","hostPort":6379,"containerPort":6379,"proto":"tcp"}],"creationDate":752000000},
              "status":"running","networks":[{"network":"default","hostname":"old","address":"192.168.64.9/24"}]}]
            """#
        let containers = AppleContainers.containers(from: Data(json.utf8))
        XCTAssertEqual(containers.count, 1)
        XCTAssertEqual(containers.first?.state, .running)
        XCTAssertEqual(containers.first?.address, "192.168.64.9")
        XCTAssertEqual(containers.first?.ports.first?.label, "6379→6379/tcp")
        XCTAssertEqual(containers.first?.ports.first?.url?.absoluteString, "http://localhost:6379")
        XCTAssertEqual(containers.first?.created, Date(timeIntervalSinceReferenceDate: 752_000_000))
    }

    func testWhatItCantReadIsLeftOut() {
        XCTAssertEqual(AppleContainers.containers(from: Data()), [])
        XCTAssertEqual(AppleContainers.containers(from: Data("\n".utf8)), [])
        XCTAssertEqual(AppleContainers.containers(from: Data("not json".utf8)), [])
        // One without an id is no container; the others stay.
        let json = #"[{"configuration":{}},{"id":"kept","configuration":{"id":"kept"},"status":{"state":"weird"}}]"#
        let containers = AppleContainers.containers(from: Data(json.utf8))
        XCTAssertEqual(containers.map(\.id), ["kept"])
        XCTAssertEqual(containers.first?.state, .unknown)
    }

    func testImagesAsTheToolListsThem() throws {
        let images = AppleContainers.images(from: try fixture("images"))
        XCTAssertEqual(images.map(\.shortName), ["alpine:latest", "nginx:alpine"])
        let alpine = images[0]
        XCTAssertEqual(alpine.id, "docker.io/library/alpine:latest", "a row a tag")
        XCTAssertEqual(alpine.digestID, "f59abe656b692d901e184be3445e084786602108599d2a51d229c0f5a48c71bf")
        XCTAssertEqual(alpine.digest, "sha256:" + alpine.digestID)
        XCTAssertEqual(alpine.platforms, ["linux/arm64/v8"])
        XCTAssertEqual(alpine.size, 4_192_247)
        XCTAssertNotNil(alpine.created)
    }

    func testVolumesAsTheToolListsThem() throws {
        let volumes = AppleContainers.volumes(from: try fixture("volumes"))
        XCTAssertEqual(volumes.map(\.name), ["overterm-probe-vol"])
        XCTAssertEqual(volumes.first?.format, "ext4")
        XCTAssertEqual(volumes.first?.sizeBytes, 549_755_813_888)
        XCTAssertEqual(volumes.first?.source, "/Users/dev/Library/Application Support/com.apple.container/volumes/overterm-probe-vol/volume.img")
    }

    func testTheService() throws {
        XCTAssertEqual(AppleContainers.service(from: try fixture("status")), .running(version: "1.7.1"))
        XCTAssertEqual(AppleContainers.service(from: Data(#"{"status":"not running"}"#.utf8)), .stopped)
        XCTAssertEqual(AppleContainers.service(from: Data(#"{"status":"unregistered"}"#.utf8)), .stopped)
        XCTAssertEqual(AppleContainers.service(from: Data("Error: XPC connection error".utf8)), .unreadable("Error: XPC connection error"))
    }

    // MARK: Commands

    func testTheCommands() {
        let tool = URL(fileURLWithPath: "/usr/local/bin/container")
        XCTAssertEqual(AppleContainerCommands.shell(tool, in: "web"), "/usr/local/bin/container exec -it web sh")
        XCTAssertEqual(AppleContainerCommands.followLogs(tool, of: "web"), "/usr/local/bin/container logs --follow -n 200 web")
        XCTAssertEqual(AppleContainerCommands.run(tool, image: "docker.io/library/nginx:alpine"), "/usr/local/bin/container run -it --rm docker.io/library/nginx:alpine")
        XCTAssertEqual(AppleContainerCommands.startService(tool), "/usr/local/bin/container system start")
        // A name with what a shell would read, quoted.
        XCTAssertEqual(AppleContainerCommands.pull(tool, image: "a b;rm"), "/usr/local/bin/container image pull 'a b;rm'")
        XCTAssertEqual(AppleContainerCommands.delete("web"), ["delete", "--force", "web"])
        XCTAssertEqual(AppleContainerCommands.list, ["list", "--all", "--format", "json"])
    }

    // MARK: Where it is

    /// Guarded (a test, a scenario): only the stand-in a run names, an
    /// absolute path — never the installed tool, which lists the user's.
    func testAGuardedRunReachesOnlyItsStandIn() {
        let everything: (String) -> Bool = { _ in true }
        XCTAssertNil(AppleContainerCLI.binary(variable: nil, guarded: true, isExecutable: everything))
        XCTAssertNil(AppleContainerCLI.binary(variable: "container", guarded: true, isExecutable: everything))
        XCTAssertEqual(AppleContainerCLI.binary(variable: "/tmp/stand-in", guarded: true, isExecutable: everything)?.path, "/tmp/stand-in")
        XCTAssertNil(AppleContainerCLI.binary(variable: "/tmp/stand-in", guarded: true, isExecutable: { _ in false }))
        // The user's app: where the installer puts it, the variable ignored.
        XCTAssertEqual(AppleContainerCLI.binary(variable: "/tmp/stand-in", guarded: false, isExecutable: everything)?.path, "/usr/local/bin/container")
        XCTAssertEqual(
            AppleContainerCLI.binary(variable: nil, guarded: false, isExecutable: { $0 == "/opt/homebrew/bin/container" })?.path, "/opt/homebrew/bin/container")
        XCTAssertNil(AppleContainerCLI.binary(variable: nil, guarded: false, isExecutable: { _ in false }))
        // This test process is guarded.
        XCTAssertNotEqual(AppEnvironment.appleContainerBinary?.path, "/usr/local/bin/container")
    }

    func testTheFilter() {
        XCTAssertTrue(DockerPageModel.appleMatches("", ["anything"]))
        XCTAssertTrue(DockerPageModel.appleMatches("web nginx", ["overterm-probe-web", "docker.io/library/nginx:alpine"]))
        XCTAssertFalse(DockerPageModel.appleMatches("web redis", ["overterm-probe-web", "docker.io/library/nginx:alpine"]))
        XCTAssertFalse(DockerPageModel.appleMatches("-nginx", ["web", "nginx:alpine"]))
        XCTAssertTrue(DockerPageModel.appleMatches("-redis", ["web", "nginx:alpine"]))
    }

    // MARK: The model, against a stand-in

    private var folder: URL!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("ot-apple-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in ["list", "images", "volumes", "status"] {
            try fixture(name).write(to: folder.appendingPathComponent("\(name).json"))
        }
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    /// A `container` that answers from the fixtures and writes down every
    /// call; `stopped` makes its service say it isn't running.
    private func standIn(stopped: Bool = false, slowList: Bool = false) throws -> URL {
        let tool = folder.appendingPathComponent("container")
        let status = stopped ? #"echo '{"status":"not running"}'; exit 1"# : #"cat "$dir/status.json""#
        let list = slowList ? #"sleep 0.4; cat "$dir/list.json""# : #"cat "$dir/list.json""#
        let script = """
            #!/bin/sh
            dir="$(dirname "$0")"
            echo "$*" >> "$dir/calls"
            case "$*" in
              "system status --format json") \(status) ;;
              "list --all --format json") \(list) ;;
              "image list --format json") cat "$dir/images.json" ;;
              "volume list --format json") cat "$dir/volumes.json" ;;
              "stop overterm-probe-web") ;;
              "delete --force overterm-probe-stopped") echo "Error: it is gone already" >&2; exit 1 ;;
              "logs --follow -n 500 overterm-probe-web") echo "first line"; echo "second line" ;;
              *) echo "unexpected: $*" >&2; exit 1 ;;
            esac
            """
        try Data(script.utf8).write(to: tool)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        return tool
    }

    private func calls() -> [String] {
        ((try? String(contentsOf: folder.appendingPathComponent("calls"), encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    private func until(_ timeout: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return false }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return true
    }

    func testItReadsOnlyWhatIsWantedAndActs() async throws {
        let tool = try standIn()
        let model = AppleContainerModel(locate: { tool }, interval: .seconds(60))
        XCTAssertTrue(model.isInstalled)
        XCTAssertTrue(calls().isEmpty, "nothing is read before a page wants it")

        model.want(.containers)
        let read = await until { model.read.contains(.containers) }
        XCTAssertTrue(read)
        XCTAssertEqual(model.service, .running(version: "1.7.1"))
        XCTAssertEqual(model.containers.count, 2)
        XCTAssertFalse(calls().contains("image list --format json"), "images aren't read while only containers show: \(calls())")

        model.want(.volumes)
        let volumes = await until { model.read.contains(.volumes) }
        XCTAssertTrue(volumes)
        let volume = try XCTUnwrap(model.volumes.first)
        XCTAssertEqual(model.containers(mounting: volume).map(\.id), ["overterm-probe-web"])

        model.perform(AppleContainerCommands.stop("overterm-probe-web"), on: "overterm-probe-web", what: "Stop overterm-probe-web")
        let stopped = await until { self.calls().contains("stop overterm-probe-web") && model.busy.isEmpty }
        XCTAssertTrue(stopped, "\(calls())")
        XCTAssertNil(model.error)

        // A failure says the tool's own words.
        model.perform(AppleContainerCommands.delete("overterm-probe-stopped"), on: "overterm-probe-stopped", what: "Remove overterm-probe-stopped")
        let failed = await until { model.error != nil }
        XCTAssertTrue(failed)
        XCTAssertEqual(model.error, "Remove overterm-probe-stopped: Error: it is gone already")

        model.unwant(.containers)
        model.unwant(.volumes)
        XCTAssertTrue(model.wanted.isEmpty)
    }

    /// Asked while a read runs — after an action, say — it waits for one
    /// more read, started after it was asked: the one running may predate
    /// what was done.
    func testAReadAskedDuringOneReadsAgain() async throws {
        let tool = try standIn(slowList: true)
        let model = AppleContainerModel(locate: { tool }, interval: .seconds(60))
        model.want(.containers)
        let started = await until { self.calls().contains("list --all --format json") }
        XCTAssertTrue(started)
        await model.readNow()
        XCTAssertEqual(calls().filter { $0 == "list --all --format json" }.count, 2, "\(calls())")
        // Nothing overlapping: one read.
        await model.readNow()
        XCTAssertEqual(calls().filter { $0 == "list --all --format json" }.count, 3, "\(calls())")
        model.unwant(.containers)
    }

    /// Two tags of one image share its digest: each its own row.
    func testTwoTagsOfOneImageAreTwoRows() throws {
        let json = #"""
            [{"id":"f59a","configuration":{"name":"docker.io/library/alpine:latest","descriptor":{"digest":"sha256:f59a"}},"variants":[]},
             {"id":"f59a","configuration":{"name":"docker.io/library/mine:1","descriptor":{"digest":"sha256:f59a"}},"variants":[]}]
            """#
        let images = AppleContainers.images(from: Data(json.utf8))
        XCTAssertEqual(Set(images.map(\.id)).count, 2)
        XCTAssertEqual(images.map(\.digestID), ["f59a", "f59a"])
    }

    func testAStoppedServiceEmptiesTheLists() async throws {
        let tool = try standIn(stopped: true)
        let model = AppleContainerModel(locate: { tool }, interval: .seconds(60))
        model.want(.containers)
        let said = await until { model.service != nil }
        XCTAssertTrue(said)
        XCTAssertEqual(model.service, .stopped)
        XCTAssertTrue(model.containers.isEmpty)
        XCTAssertEqual(calls(), ["system status --format json"], "nothing else is asked of a stopped service")
        model.unwant(.containers)
    }

    func testWithoutTheToolNothingRuns() async {
        let model = AppleContainerModel(locate: { nil }, interval: .seconds(60))
        XCTAssertFalse(model.isInstalled)
        model.want(.containers)
        await model.readNow()
        XCTAssertNil(model.service)
        XCTAssertTrue(model.containers.isEmpty)
        model.unwant(.containers)
    }

    func testTheLogsTabFollowsItsLog() async throws {
        let tool = try standIn()
        let session = AppleContainerSession(id: "overterm-probe-web")
        session.follow(shown: true, running: true, tool: tool)
        let lines = await until { session.feed.lines.count == 2 }
        XCTAssertTrue(lines)
        XCTAssertEqual(session.feed.lines.map(\.message), ["first line", "second line"])
        XCTAssertEqual(session.feed.terminalCommand, AppleContainerCommands.followLogs(tool, of: "overterm-probe-web"))
        // Looked at again while nothing changed: not read twice.
        session.follow(shown: true, running: true, tool: tool)
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(calls().filter { $0.hasPrefix("logs") }.count, 1)
        // Stopped and started again: read afresh, the old lines gone.
        session.follow(shown: true, running: false, tool: tool)
        session.follow(shown: true, running: true, tool: tool)
        let again = await until { self.calls().filter { $0.hasPrefix("logs") }.count == 2 && session.feed.lines.count == 2 }
        XCTAssertTrue(again, "\(calls()) \(session.feed.lines.count)")
        session.close()
    }

    // MARK: The page

    func testTheSectionIsThereOnlyWithTheTool() throws {
        let tool = try standIn()
        let page = DockerPageModel(docker: DockerModel(endpoint: { nil }), apple: AppleContainerModel(locate: { tool }, interval: .seconds(60)))
        XCTAssertTrue(page.press("7"))
        XCTAssertEqual(page.section, .apple)
        XCTAssertEqual(DockerPageModel.Section.apple.title, "Apple Containers")

        let without = DockerPageModel(docker: DockerModel(endpoint: { nil }), apple: AppleContainerModel(locate: { nil }, interval: .seconds(60)))
        XCTAssertFalse(without.press("7"))
        XCTAssertEqual(without.section, .containers)
    }

    /// Images or Volumes shown, the selected container's log isn't
    /// followed any more; back on Containers, it is again.
    func testLeavingContainersStopsTheLog() async throws {
        let tool = try standIn()
        let apple = AppleContainerModel(locate: { tool }, interval: .seconds(60))
        let page = DockerPageModel(docker: DockerModel(endpoint: { nil }), apple: apple)
        page.visible = true
        page.section = .apple
        let read = await until { apple.read.contains(.containers) }
        XCTAssertTrue(read)
        page.showDetail = true
        page.appleSelection = ["overterm-probe-web"]
        page.appleDetailTab = .logs
        let following = await until { page.appleSession != nil && self.calls().contains("logs --follow -n 500 overterm-probe-web") }
        XCTAssertTrue(following, "\(calls())")
        page.appleTab = .images
        let stopped = await until { page.appleSession == nil }
        XCTAssertTrue(stopped)
        page.appleTab = .containers
        let again = await until { page.appleSession != nil }
        XCTAssertTrue(again)
        page.close()
    }

    func testRemovalIsAskedFirst() async throws {
        let tool = try standIn()
        let apple = AppleContainerModel(locate: { tool }, interval: .seconds(60))
        let page = DockerPageModel(docker: DockerModel(endpoint: { nil }), apple: apple)
        var asked: [String] = []
        page.actions = DockerActions(run: { _, _ in }, confirm: { title, _, _, _ in asked.append(title) }, open: { _ in }, copy: { _ in }, settings: {})
        apple.want(.containers)
        let read = await until { apple.read.contains(.containers) }
        XCTAssertTrue(read)
        page.section = .apple
        page.appleSelection = ["overterm-probe-web"]
        XCTAssertTrue(page.press("\u{7F}"))
        XCTAssertEqual(asked, ["Remove “overterm-probe-web”?"])
        XCTAssertFalse(calls().contains { $0.hasPrefix("delete") }, "nothing removed before the answer")
        // An image a container is made from can't be removed.
        apple.want(.images)
        let images = await until { apple.read.contains(.images) }
        XCTAssertTrue(images)
        let nginx = try XCTUnwrap(apple.images.first { $0.shortName == "nginx:alpine" })
        XCTAssertNotNil(page.verbs(for: nginx).first { $0.place == .remove }?.unavailable)
        apple.unwant(.containers)
        apple.unwant(.images)
    }

    /// The real tool, read only: `OVERTERM_APPLE_CONTAINER_TESTS=1` on a Mac
    /// that has it. Nothing is made, started or removed.
    func testTheRealToolReads() async throws {
        guard ProcessInfo.processInfo.environment["OVERTERM_APPLE_CONTAINER_TESTS"] == "1" else { throw XCTSkip("OVERTERM_APPLE_CONTAINER_TESTS=1 reads the real tool") }
        let tool = URL(fileURLWithPath: "/usr/local/bin/container")
        guard FileManager.default.isExecutableFile(atPath: tool.path) else { throw XCTSkip("container isn't installed") }
        let model = AppleContainerModel(locate: { tool }, interval: .seconds(60))
        model.want(.images)
        let said = await until(30) { model.service != nil }
        XCTAssertTrue(said)
        if case .running = model.service {
            let read = await until(30) { model.read.isSuperset(of: [.containers, .images]) }
            XCTAssertTrue(read, model.error ?? "")
            XCTAssertNil(model.error)
        }
        model.unwant(.images)
    }
}
