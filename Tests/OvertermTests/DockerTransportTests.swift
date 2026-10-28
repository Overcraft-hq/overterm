import Foundation
import XCTest

@testable import Overterm

/// The engine's calls over a real unix socket, against the fake engine:
/// answers, errors, streams that go on, streams left early. Never the
/// user's Docker; with OVERTERM_DOCKER_TESTS=1 a few read-only calls go to
/// it as well (`testTheRealEngineAnswers`).
final class DockerTransportTests: XCTestCase {
    private var fake: FakeDockerEngine!
    private var engine: DockerEngine!

    override func setUpWithError() throws {
        // A unix socket's path must stay under 104 bytes: not the test's
        // temporary folder, which is long.
        let socket = "/tmp/ot-docker-\(UUID().uuidString.prefix(8)).sock"
        fake = FakeDockerEngine(socket: socket)
        try fake.start()
        engine = DockerEngine(endpoint: DockerEndpoint(address: .unix(socket), context: nil, source: "test"))
    }

    override func tearDown() {
        fake.stop()
        fake = nil
        engine = nil
    }

    func testPingSettlesTheVersion() async throws {
        let version = try await engine.ping()
        XCTAssertEqual(version, "1.47")
        XCTAssertTrue(engine.path("/info").hasPrefix("/v1.47/"))
    }

    func testListsAndDetails() async throws {
        let web = fake.add(
            name: "shop-web-1", project: "shop", workingDir: "/Users/me/shop", service: "web",
            ports: [DockerPort(IP: "0.0.0.0", PrivatePort: 80, PublicPort: 8080, Type: "tcp")], env: ["DB_PASSWORD=hunter2", "PORT=80"])
        fake.add(name: "old", state: .exited)
        let running = try await engine.containers(all: false)
        XCTAssertEqual(running.map(\.name), ["shop-web-1"])
        let all = try await engine.containers()
        XCTAssertEqual(all.map(\.name), ["old", "shop-web-1"])
        XCTAssertEqual(all.last?.composeWorkingDir, "/Users/me/shop")
        let detail = try await engine.container(web)
        XCTAssertEqual(detail.name, "shop-web-1")
        XCTAssertEqual(detail.env.first?.key, "DB_PASSWORD")
        let json = try await engine.containerJSON("shop-web-1")
        XCTAssertTrue(json.contains("\n  \"Config\" : {"), json)
        let info = try await engine.info()
        XCTAssertEqual(info.ContainersRunning, 1)
    }

    func testTheEnginesErrorIsWhatIsThrown() async throws {
        let id = fake.add(name: "busy")
        do {
            try await engine.remove(container: id)
            XCTFail("a running container isn't removed without force")
        } catch let error as DockerError {
            XCTAssertEqual(error.status, 409)
            XCTAssertTrue(error.localizedDescription.contains("container is running"), error.localizedDescription)
        }
        try await engine.remove(container: id, force: true)
        let left = try await engine.containers()
        XCTAssertTrue(left.isEmpty)
        do {
            _ = try await engine.container("nope")
            XCTFail("no such container")
        } catch let error as DockerError {
            XCTAssertEqual(error.status, 404)
            XCTAssertEqual(error.localizedDescription, "No such container: nope")
        }
    }

    func testAnEngineThatIsntThereSaysSo() async {
        let gone = DockerEngine(endpoint: DockerEndpoint(address: .unix("/tmp/ot-no-docker-here.sock"), context: nil, source: "test"))
        do {
            _ = try await gone.ping()
            XCTFail("nothing listens there")
        } catch {
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }
    }

    func testActionsChangeTheContainerAndSendEvents() async throws {
        let id = fake.add(name: "api")
        let events = engine.events()
        let received = Task {
            var actions: [String] = []
            for try await event in events {
                actions.append(event.verb)
                if actions.count == 4 { break }
            }
            return actions
        }
        try await waitUntil { $0.listening == 1 }
        try await engine.perform(.stop, on: id)
        try await engine.perform(.start, on: id)
        try await engine.perform(.pause, on: id)
        let actions = try await received.value
        XCTAssertEqual(actions, ["kill", "die", "start", "pause"], "a stop asked for is a kill, then a die")
        XCTAssertEqual(fake.summary(id)?.state, .paused)
        XCTAssertTrue(fake.requests.contains { $0.hasSuffix("/containers/\(id)/stop?t=10") }, "\(fake.requests)")
    }

    func testLogsAreDemuxedAndFollowed() async throws {
        let id = fake.add(name: "worker")
        fake.log(id, "booting")
        fake.log(id, "warning: slow disk", stream: .stderr)
        let past = engine.logs(id, tty: false, tail: 10, follow: false)
        var lines: [DockerLogLine] = []
        for try await chunks in past {
            lines += chunks.flatMap { DockerLogLine.lines(of: $0, timestamps: true) }
        }
        XCTAssertEqual(lines.map(\.message), ["booting", "warning: slow disk"])
        XCTAssertEqual(lines.map(\.stream), [.stdout, .stderr])
        XCTAssertNotNil(lines.first?.timestamp)

        let followed = engine.logs(id, tty: false, tail: 1, follow: true)
        let reader = Task {
            var messages: [String] = []
            for try await chunks in followed {
                messages += chunks.flatMap { DockerLogLine.lines(of: $0, timestamps: true) }.map(\.message)
                if messages.count == 2 { break }
            }
            return messages
        }
        try await waitUntil { $0.openStreams == 1 }
        fake.log(id, "ready")
        let messages = try await reader.value
        XCTAssertEqual(messages, ["warning: slow disk", "ready"])
    }

    /// A stream left early closes its connection, so the engine stops
    /// sending (a stats stream left open would sample forever).
    func testLeavingAStreamClosesIt() async throws {
        let id = fake.add(name: "hot")
        var samples: [DockerUsage] = []
        for try await sample in engine.stats(id) {
            samples.append(DockerUsage(sample))
            if samples.count == 2 { break }
        }
        XCTAssertEqual(samples.last?.processes, 3)
        XCTAssertEqual(samples.last?.memoryBytes, 48 << 20)
        XCTAssertEqual(samples.last?.cpuPercent ?? 0, 8, accuracy: 0.001)
        try await waitUntil { $0.openStreams == 0 }
    }

    func testAStreamCancelledWhileItConnectsIsClosed() async throws {
        let id = fake.add(name: "quick")
        for _ in 0..<20 {
            let stats = engine.stats(id)
            let task = Task {
                for try await _ in stats {}
            }
            task.cancel()
            _ = await task.result
        }
        try await waitUntil { $0.openStreams == 0 }
        let containers = try await engine.containers()
        XCTAssertEqual(containers.count, 1)
    }

    /// A followed log whose reader's task is cancelled — a tab left —
    /// closes its connection.
    func testACancelledLogFollowIsClosed() async throws {
        let id = fake.add(name: "chatty")
        fake.log(id, "one")
        let logs = engine.logs(id, tty: false, tail: 10, follow: true)
        let reader = Task {
            for try await _ in logs {}
        }
        try await waitUntil { $0.openStreams == 1 }
        reader.cancel()
        _ = await reader.result
        try await waitUntil { $0.openStreams == 0 }
    }

    func testFilesAreReadAndWrittenThroughTar() async throws {
        let id = fake.add(name: "nginx")
        fake.setFile(id, "/etc/nginx/nginx.conf", Data("worker_processes 1;\n".utf8))
        let stat = try await engine.stat(id, path: "/etc/nginx/nginx.conf")
        XCTAssertEqual(stat.size, 20)
        XCTAssertFalse(stat.isDirectory)
        let read = try await engine.read(id, file: "/etc/nginx/nginx.conf")
        XCTAssertEqual(String(decoding: read, as: UTF8.self), "worker_processes 1;\n")
        try await engine.write(id, file: "/etc/nginx/nginx.conf", data: Data("worker_processes 4;\n".utf8))
        XCTAssertEqual(fake.file(id, "/etc/nginx/nginx.conf"), Data("worker_processes 4;\n".utf8))
        do {
            _ = try await engine.stat(id, path: "/nope")
            XCTFail("no such file")
        } catch let error as DockerError {
            XCTAssertEqual(error.status, 404)
        }
    }

    func testAFolderIsListedThroughExec() async throws {
        let id = fake.add(name: "web")
        fake.setFile(id, "/etc/nginx/nginx.conf", Data("worker_processes 1;\n".utf8))
        fake.setFile(id, "/etc/nginx/conf.d/default.conf", Data("server {}\n".utf8))
        let entries = try await engine.list(id, folder: "/etc/nginx")
        XCTAssertEqual(entries.map(\.name), ["conf.d", "nginx.conf"], "folders first")
        XCTAssertEqual(entries.map(\.kind), [.folder, .file])
        XCTAssertEqual(entries.last?.size, 20)
        do {
            _ = try await engine.list(id, folder: "/nope")
            XCTFail("no such folder")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("No such folder"), error.localizedDescription)
        }
        let missing = try await engine.exec(id, ["bash", "-c", "true"])
        XCTAssertEqual(missing.exitCode, 127)
        let stopped = fake.add(name: "stopped", state: .exited)
        do {
            _ = try await engine.list(stopped, folder: "/")
            XCTFail("a stopped container runs nothing")
        } catch let error as DockerError {
            XCTAssertEqual(error.status, 409)
        }
    }

    /// Exec, write and read against the real engine — its `exec start`
    /// hijacks the connection, which the fake can't show. A container of
    /// our own, labelled, from an image already here; removed after.
    func testExecAndFilesOnTheRealEngine() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["OVERTERM_DOCKER_TESTS"] == "1", "OVERTERM_DOCKER_TESTS=1 runs it")
        let real = DockerEngine(endpoint: .current())
        try await real.ping()
        let image = "debian:bookworm-slim"
        guard (try? await real.send(.GET, "/images/\(image)/json")) != nil else { throw XCTSkip("\(image) isn't on this Mac; nothing is pulled") }
        let create = try JSONSerialization.data(withJSONObject: ["Image": image, "Cmd": ["sleep", "120"], "Labels": ["overterm.test": "1"]])
        struct Created: Decodable { var Id: String }
        let made = try JSONDecoder().decode(
            Created.self,
            from: try await real.send(
                .POST, "/containers/create", ["name": "overterm-test-\(UUID().uuidString.prefix(8))"], body: create,
                headers: [("Content-Type", "application/json")]
            ).body)
        do {
            try await real.perform(.start, on: made.Id)
            let etc = try await real.list(made.Id, folder: "/etc")
            XCTAssertTrue(etc.contains { $0.name == "hostname" && $0.kind == .file }, "\(etc.map(\.name))")
            XCTAssertTrue(etc.contains { $0.name == "apt" && $0.kind == .folder })
            try await real.write(made.Id, file: "/tmp/overterm.txt", data: Data("hello\n".utf8))
            let back = try await real.read(made.Id, file: "/tmp/overterm.txt")
            XCTAssertEqual(String(decoding: back, as: UTF8.self), "hello\n")
            let missing = try await real.exec(made.Id, ["no-such-command"])
            XCTAssertTrue([126, 127].contains(missing.exitCode), "\(missing)")
            let top = try await real.top(made.Id)
            XCTAssertTrue(top.processes.contains { $0.joined(separator: " ").contains("sleep 120") }, "\(top)")
            let changes = try await real.changes(made.Id)
            XCTAssertTrue(changes.contains { $0.Path == "/tmp/overterm.txt" && $0.Kind == .added }, "\(changes)")
        } catch {
            try? await real.remove(container: made.Id, force: true)
            throw error
        }
        try await real.remove(container: made.Id, force: true)
    }

    /// A volume in and out through a helper container that never starts —
    /// the engine mounts it for the archive endpoint. A volume of our own,
    /// labelled, from an image already here; removed after.
    func testAVolumeExportsAndImportsOnTheRealEngine() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["OVERTERM_DOCKER_TESTS"] == "1", "OVERTERM_DOCKER_TESTS=1 runs it")
        let real = DockerEngine(endpoint: .current())
        try await real.ping()
        let image = "debian:bookworm-slim"
        guard (try? await real.send(.GET, "/images/\(image)/json")) != nil else { throw XCTSkip("\(image) isn't on this Mac; nothing is pulled") }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ot-volume-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let name = "overterm-test-\(UUID().uuidString.prefix(8).lowercased())"
        var tar = DockerTar.header(name: "volume/", size: 0, mode: 0o755, modified: Date(), type: "5")!
        tar += DockerTar.archive(name: "volume/hello.txt", data: Data("hi from a volume\n".utf8))!
        let source = folder.appendingPathComponent("in.tar")
        try tar.write(to: source)
        do {
            try await real.import(volume: name, from: source, using: image)
            let out = folder.appendingPathComponent("out.tar")
            let bytes = try await real.export(volume: name, to: out, using: image)
            XCTAssertGreaterThan(bytes, 0)
            let entries = DockerTar.entries(of: try Data(contentsOf: out))
            XCTAssertEqual(entries.first { $0.name == "volume/hello.txt" }.map { String(decoding: $0.data, as: UTF8.self) }, "hi from a volume\n", "\(entries.map(\.name))")
        } catch {
            try? await real.remove(volume: name, force: true)
            throw error
        }
        try await Task.sleep(for: .milliseconds(300))
        try await real.remove(volume: name, force: true)
    }

    func testImagesVolumesNetworksAndPrunes() async throws {
        fake.addImage("postgres:16", size: 400 << 20, containers: 1)
        fake.addImage("node:20", size: 1 << 30)
        fake.addVolume("shop_pgdata", size: 50 << 20, refCount: 1, project: "shop")
        fake.addVolume("loose", size: 10 << 20, refCount: 0)
        fake.addNetwork("shop_default")
        let images = try await engine.images()
        XCTAssertEqual(images.map(\.tags), [["postgres:16"], ["node:20"]])
        let volumes = try await engine.volumes()
        XCTAssertEqual(volumes.first?.composeProject, "shop")
        let networks = try await engine.networks()
        XCTAssertEqual(networks.map(\.Name), ["shop_default"])
        let usage = try await engine.diskUsage()
        XCTAssertEqual(usage.LayersSize, (400 << 20) + (1 << 30))

        let images0 = try await engine.prune(.images, everythingUnused: true)
        XCTAssertEqual(images0.SpaceReclaimed, 1 << 30)
        XCTAssertTrue(fake.requests.contains { $0.contains("/images/prune?filters=") }, "\(fake.requests)")
        let volumes0 = try await engine.prune(.volumes, everythingUnused: true)
        XCTAssertEqual(volumes0.VolumesDeleted, ["loose"])
        let remaining = try await engine.volumes()
        XCTAssertEqual(remaining.map(\.Name), ["shop_pgdata"])
    }

    /// Read-only, against the Docker this Mac runs — only when asked.
    func testTheRealEngineAnswers() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["OVERTERM_DOCKER_TESTS"] == "1", "OVERTERM_DOCKER_TESTS=1 runs it")
        let real = DockerEngine(endpoint: .current())
        let version = try await real.ping()
        XCTAssertFalse(version.isEmpty)
        _ = try await real.info()
        _ = try await real.containers()
        _ = try await real.images()
        _ = try await real.volumes()
        _ = try await real.networks()
        // Its runtime says it is up, through its own command.
        let runtime = DockerRuntime.of(real.endpoint, operatingSystem: try await real.info().OperatingSystem)
        if runtime.statusCommand() != nil {
            let status = await DockerCLI.status(of: runtime, endpoint: real.endpoint)
            XCTAssertTrue([.running, .paused].contains(status), "\(runtime.name): \(status)")
        }
    }

    /// Until the fake engine says so.
    private func waitUntil(_ condition: (FakeDockerEngine) -> Bool, timeout: Duration = .seconds(3)) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition(fake) {
            guard ContinuousClock.now < deadline else { throw DockerError(status: 0, message: "timed out waiting") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
