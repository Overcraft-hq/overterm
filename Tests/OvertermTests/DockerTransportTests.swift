import Foundation
import XCTest

@testable import Overterm

/// The engine's calls over a real unix socket, against the fake engine:
/// answers, errors, streams that go on, streams left early. Never the
/// user's Docker; with OVERTERM_DOCKER_TESTS=1 a few calls go to it as
/// well: reads (`testTheRealEngineAnswers`), and exec, files, a volume's
/// export and import, and a container's limits and name changed, on a
/// container and a volume of their own —
/// labelled `overterm.test`, from an image already there (nothing is
/// pulled), removed after.
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
        XCTAssertEqual(engine.version(wanting: "1.48"), "1.47", "an engine of 1.47: no later")
        fake.apiVersion = "1.51"
        let newer = try await engine.ping()
        XCTAssertEqual(newer, "1.47", "every call as Overterm is written")
        XCTAssertEqual(engine.version(wanting: "1.48"), "1.48", "a call that wants a later one, as far as it wants")
        _ = try await engine.containers()
        XCTAssertTrue(fake.requests.contains("GET /v1.48/containers/json?all=1"), "\(fake.requests)")
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

    /// A volume's Files tab lists through a helper that runs — `sh` as
    /// root, no network, gone by itself — with the volume at /volume, and
    /// labelled as Overterm's.
    func testAVolumeIsListedThroughAHelperThatRuns() async throws {
        let busybox = fake.addImage("busybox:1.36", size: 4 << 20)
        fake.setVolumeFile("pgdata", "PG_VERSION", Data("16\n".utf8))
        fake.setVolumeFile("pgdata", "base/1/123", Data(count: 8192))
        let id = try await engine.filesHelper(mounting: "pgdata", image: busybox)
        let made = try XCTUnwrap(fake.created(id))
        XCTAssertEqual(made.Entrypoint, ["sh", "-c", "exec sleep 1800"])
        XCTAssertEqual(made.User, "0:0")
        XCTAssertEqual(made.WorkingDir, "/volume")
        XCTAssertEqual(made.HostConfig?.AutoRemove, true)
        XCTAssertEqual(made.HostConfig?.NetworkMode, "none")
        XCTAssertEqual(made.HostConfig?.Binds, ["pgdata:/volume"])
        XCTAssertEqual(made.Labels?["overterm.helper"], "1")
        XCTAssertEqual(made.Labels?["overterm.volume"], "pgdata")
        XCTAssertTrue(fake.summary(id)?.name.hasPrefix("overterm-files-") == true, fake.summary(id)?.name ?? "")
        XCTAssertEqual(fake.summary(id)?.state, .running)
        XCTAssertEqual(DockerHelpers.ids(on: engine), [id])
        let top = try await engine.list(id, folder: "/volume")
        XCTAssertEqual(top.map(\.name), ["base", "PG_VERSION"], "folders first")
        let base = try await engine.list(id, folder: "/volume/base")
        XCTAssertEqual(base.map(\.name), ["1"])
        await engine.removeHelper(id)
        XCTAssertEqual(fake.helperIDs, [])
        XCTAssertEqual(DockerHelpers.ids(on: engine), [])
    }

    /// A volume's file read and written through a helper made for the
    /// call, which goes whatever the call did — and keeps its owner.
    func testAVolumesFileKeepsItsOwner() async throws {
        let engine: DockerEngine = engine
        fake.addImage("debian:bookworm-slim", size: 80 << 20)
        fake.setVolumeFile("pgdata", "pg_hba.conf", Data("local all all trust\n".utf8), uid: 999, gid: 999)
        let entry = try await engine.reaching(.volume("pgdata"), "/pg_hba.conf") { id, at in try await engine.readEntry(id, file: at) }
        XCTAssertEqual(String(decoding: entry.data, as: UTF8.self), "local all all trust\n")
        XCTAssertEqual(entry.uid, 999)
        XCTAssertEqual(fake.helperIDs, [], "the helper goes after the call")
        let stat = try await engine.reaching(.volume("pgdata"), "/pg_hba.conf") { id, at in
            try await engine.write(id, file: at, data: Data("host all all all md5\n".utf8), uid: entry.uid, gid: entry.gid)
            return try await engine.stat(id, path: at)
        }
        XCTAssertEqual(stat.size, 21)
        XCTAssertEqual(fake.volumeContents("pgdata")["pg_hba.conf"], Data("host all all all md5\n".utf8))
        XCTAssertEqual(fake.volumeOwner("pgdata", "pg_hba.conf")?.uid, 999)
        XCTAssertEqual(fake.volumeOwner("pgdata", "pg_hba.conf")?.gid, 999)
        XCTAssertEqual(fake.helperIDs, [])
        do {
            _ = try await engine.reaching(.volume("pgdata"), "/nope") { id, at in try await engine.stat(id, path: at) }
            XCTFail("no such file")
        } catch let error as DockerError {
            XCTAssertEqual(error.status, 404)
            XCTAssertEqual(DockerVolumeFiles.said(error.message), "/nope isn't there.", "said as the volume's path")
        }
        XCTAssertEqual(fake.helperIDs, [], "and after one that threw")
        let folder = try await engine.reaching(.volume("pgdata"), "/") { id, at in try await engine.stat(id, path: at) }
        XCTAssertTrue(folder.isDirectory, "its top is a folder")
    }

    /// Without `sh` its start fails: nothing is left of it.
    func testAStartThatFailsLeavesNoHelper() async throws {
        let distroless = fake.addImage("gcr.io/distroless/static:nonroot", size: 2 << 20, shell: false)
        fake.addVolume("pgdata", size: 0, refCount: 0)
        do {
            _ = try await engine.filesHelper(mounting: "pgdata", image: distroless)
            XCTFail("no sh to start")
        } catch let error as DockerError {
            XCTAssertEqual(error.status, 400)
            XCTAssertTrue(error.message.contains("executable file not found"), error.message)
        }
        XCTAssertEqual(fake.helperIDs, [])
        XCTAssertEqual(DockerHelpers.ids(on: engine), [])
    }

    /// What is left at quit is removed: waited for off any cooperative
    /// thread, as the main thread waits at quit.
    func testHelpersLeftAtQuitAreRemoved() async throws {
        let busybox = fake.addImage("busybox:1.36", size: 4 << 20)
        fake.addVolume("pgdata", size: 0, refCount: 0)
        fake.addVolume("cache", size: 0, refCount: 0)
        _ = try await engine.filesHelper(mounting: "pgdata", image: busybox)
        _ = try await engine.filesHelper(mounting: "cache", image: busybox)
        XCTAssertEqual(fake.helperIDs.count, 2)
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                DockerHelpers.removeAll(waiting: 2)
                done.resume()
            }
        }
        XCTAssertEqual(fake.helperIDs, [])
        XCTAssertEqual(DockerHelpers.ids(on: engine), [])
    }

    /// One removal, however many ask, and returned from only once the
    /// engine no longer has it: a second DELETE would be refused at once
    /// (409) while the first still kills it — and it still holds its
    /// volume. Its anonymous volumes go with it (`v=1`).
    func testAHelperIsRemovedOnceAndWaitedFor() async throws {
        let engine: DockerEngine = engine
        let busybox = fake.addImage("busybox:1.36", size: 4 << 20)
        fake.addVolume("pgdata", size: 0, refCount: 0)
        fake.removalDelay = 300
        let id = try await engine.filesHelper(mounting: "pgdata", image: busybox)
        async let first: Void = engine.removeHelper(id)
        async let second: Void = engine.removeHelper(id)
        _ = await (first, second)
        XCTAssertNil(fake.summary(id), "gone when either returns")
        let deletes = fake.requests.filter { $0.hasPrefix("DELETE /v1.47/containers/\(id)") }
        XCTAssertEqual(deletes, ["DELETE /v1.47/containers/\(id)?force=1&v=1"], "once, with its anonymous volumes")
        XCTAssertEqual(DockerHelpers.ids(on: engine), [])
        try await engine.remove(volume: "pgdata")
        XCTAssertFalse(fake.volumeNames.contains("pgdata"), "free at once")

        // Removed by someone else meanwhile (a 409): waited for all the same.
        fake.removalDelay = 0
        fake.addVolume("cache", size: 0, refCount: 0)
        let other = try await engine.filesHelper(mounting: "cache", image: busybox)
        fake.refuseRemoval(of: other, 409, "removal of container \(other) is already in progress")
        let stub: FakeDockerEngine = fake
        Task.detached {
            try? await Task.sleep(for: .milliseconds(250))
            stub.expire(other)
        }
        await engine.removeHelper(other)
        XCTAssertNil(fake.summary(other), "returned once it was gone")
    }

    /// A helper is made only for a volume the engine has: bound by its
    /// name, one would make it again, empty — as the engine does (the
    /// fake too, below), and a save would land in it.
    func testAVolumeGoneGetsNoHelper() async throws {
        let engine: DockerEngine = engine
        let busybox = fake.addImage("busybox:1.36", size: 4 << 20)
        let creates = { self.fake.requests.filter { $0.contains("/containers/create") }.count }
        for attempt in 0..<3 {
            do {
                switch attempt {
                case 0: _ = try await engine.filesHelper(mounting: "pgdata", image: busybox)
                case 1: _ = try await engine.helper(mounting: "pgdata", image: busybox)
                default:
                    _ = try await engine.reaching(.volume("pgdata"), "/pg_hba.conf") { id, at in
                        try await engine.write(id, file: at, data: Data("x".utf8))
                    }
                }
                XCTFail("made for a volume there isn't")
            } catch let error as DockerError {
                XCTAssertEqual(error, DockerError.volumeGone("pgdata"))
                XCTAssertEqual(error.message, "The volume pgdata is gone.")
            }
        }
        XCTAssertEqual(creates(), 0)
        XCTAssertFalse(fake.volumeNames.contains("pgdata"), "not made again")
        // What the check keeps from happening: the engine makes a name it
        // doesn't know, bound.
        let body = try JSONSerialization.data(withJSONObject: ["Image": busybox, "HostConfig": ["Binds": ["other:/volume"]]])
        try await engine.send(.POST, "/containers/create", body: body, headers: [("Content-Type", "application/json")])
        XCTAssertTrue(fake.volumeNames.contains("other"))
    }

    /// A helper the run doesn't know — left by a crash, or by a version
    /// before this one — is found by its mount and removed before its
    /// volume, which the engine would refuse to remove while it is there.
    func testAHelperNobodyRecordedIsFoundByItsMount() async throws {
        fake.addImage("busybox:1.36", size: 4 << 20)
        fake.addVolume("pgdata", size: 0, refCount: 0)
        fake.addVolume("cache", size: 0, refCount: 0)
        let old = fake.add(
            name: "helper-0ld", image: "busybox:1.36", state: .created, volumes: ["pgdata"], labels: ["overterm.helper": "1"],
            created: Int(Date().timeIntervalSince1970) - 3600)
        let elsewhere = fake.add(name: "overterm-helper-ca", image: "busybox:1.36", state: .created, volumes: ["cache"], labels: ["overterm.helper": "1"])
        fake.addVolume("logs", size: 0, refCount: 0)
        let theirs = fake.add(name: "db", image: "postgres:16", state: .exited, volumes: ["logs"])
        do {
            try await engine.remove(volume: "pgdata")
            XCTFail("in use")
        } catch let error as DockerError {
            XCTAssertEqual(error.status, 409)
            XCTAssertTrue(error.message.contains("volume is in use"), error.message)
        }
        await DockerHelpers.remove(mounting: "pgdata", on: engine)
        XCTAssertNil(fake.summary(old), "found through the engine")
        XCTAssertNotNil(fake.summary(elsewhere), "another volume's stays")
        XCTAssertNotNil(fake.summary(theirs), "and nobody's but a helper is touched")
        XCTAssertTrue(fake.requests.contains { $0.contains("/containers/json?all=1&filters=") }, "asked by its label")
        try await engine.remove(volume: "pgdata")
        XCTAssertFalse(fake.volumeNames.contains("pgdata"), "free now")
    }

    /// The same against the real engine: a helper that runs `sh` as root
    /// lists a volume, reads a file's owner, and is gone once removed. A
    /// volume of our own, from an image already here; removed after.
    func testAVolumeIsBrowsedOnTheRealEngine() async throws {
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
        tar += DockerTar.header(name: "volume/conf/", size: 0, mode: 0o755, modified: Date(), type: "5")!
        tar += DockerTar.archive(name: "volume/conf/a.txt", data: Data("owned\n".utf8), uid: 999, gid: 999)!
        let source = folder.appendingPathComponent("in.tar")
        try tar.write(to: source)
        var helper: String?
        do {
            try await real.import(volume: name, from: source, using: image)
            let id = try await real.filesHelper(mounting: name, image: image, labels: ["overterm.test": "1"])
            helper = id
            let conf = try await real.list(id, folder: "/volume/conf")
            XCTAssertEqual(conf.map(\.name), ["a.txt"])
            let entry = try await real.readEntry(id, file: "/volume/conf/a.txt")
            XCTAssertEqual(entry.uid, 999)
            await real.removeHelper(id)
            helper = nil
            do {
                _ = try await real.send(.GET, "/containers/\(id)/json")
                XCTFail("the helper is gone")
            } catch let error as DockerError {
                XCTAssertEqual(error.status, 404)
            }
        } catch {
            if let helper { await real.removeHelper(helper) }
            try? await real.remove(volume: name, force: true)
            throw error
        }
        try await Task.sleep(for: .milliseconds(300))
        try await real.remove(volume: name, force: true)
    }

    /// `docker update` as the engine takes it: a memory limit only with a
    /// swap when it has none, CPUs the way they were given, no restart
    /// policy for a `--rm` one — and what the sheet sends, it takes.
    func testSettingsChangeAsTheEngineAllows() async throws {
        let plain = fake.add(name: "ot-tune")
        func draft(_ id: String) async throws -> DockerContainerSettings {
            let summary = try await engine.containers().first { $0.Id == id }
            return DockerContainerSettings(try XCTUnwrap(summary), try await engine.container(id), engine: try await engine.info())
        }
        func refusal(_ id: String, _ change: DockerEngine.ContainerUpdate) async -> DockerError? {
            do {
                try await engine.update(container: id, change)
                return nil
            } catch {
                return error as? DockerError
            }
        }
        let swapless = await refusal(plain, .init(Memory: 1 << 30))
        XCTAssertEqual(swapless?.status, 409, "a limit above a swap of 0, and no swap with it")
        XCTAssertTrue(swapless?.message.contains("memoryswap") == true, swapless?.message ?? "taken")

        let events = engine.events()
        let heard = Task {
            for try await event in events where event.verb == "update" { return event.Actor.ID }
            return ""
        }
        try await waitUntil { $0.listening == 1 }
        var settings = try await draft(plain)
        settings.memory = "1g"
        settings.cpus = "1.5"
        try await engine.update(container: plain, try XCTUnwrap(settings.update))
        XCTAssertEqual(fake.hostConfig(plain)?.Memory, 1 << 30)
        XCTAssertEqual(fake.hostConfig(plain)?.MemorySwap, 2 << 30)
        XCTAssertEqual(fake.hostConfig(plain)?.NanoCpus, 1_500_000_000)
        let updated = try await heard.value
        XCTAssertEqual(updated, plain, "an update event")
        let read = try await draft(plain)
        XCTAssertEqual([read.memory, read.cpus], ["1g", "1.5"], "inspect says it back")

        let quota = fake.add(name: "ot-quota")
        fake.setHostConfig(quota) {
            $0.CpuQuota = 50_000
            $0.CpuPeriod = 100_000
        }
        let conflicting = await refusal(quota, .init(NanoCpus: 1_000_000_000))
        XCTAssertEqual(conflicting?.status, 409)
        XCTAssertTrue(conflicting?.message.contains("Conflicting options") == true, conflicting?.message ?? "taken")
        var byQuota = try await draft(quota)
        byQuota.cpus = "1"
        try await engine.update(container: quota, try XCTUnwrap(byQuota.update))
        XCTAssertEqual(fake.hostConfig(quota)?.CpuQuota, 100_000, "by its quota, as it was made")

        let small = await refusal(plain, .init(Memory: 4 << 20, MemorySwap: 8 << 20))
        XCTAssertEqual(small?.status, 400)
        let many = await refusal(plain, .init(NanoCpus: 9_000_000_000))
        XCTAssertEqual(many?.status, 400)
        XCTAssertTrue(many?.message.contains("only 4 CPUs") == true, many?.message ?? "taken")
        fake.setHostConfig(plain) { $0.AutoRemove = true }
        let removed = await refusal(plain, .init(RestartPolicy: .init(Name: "always", MaximumRetryCount: 0)))
        XCTAssertEqual(removed?.status, 409)
        XCTAssertTrue(removed?.message.contains("AutoRemove") == true, removed?.message ?? "taken")
    }

    func testRenameAndCommit() async throws {
        let web = fake.add(name: "web", env: ["API_TOKEN=s3cr3t"])
        fake.add(name: "db")
        let events = engine.events()
        let heard = Task {
            for try await event in events where event.verb == "rename" { return event.Actor.Attributes?["oldName"] ?? "" }
            return ""
        }
        try await waitUntil { $0.listening == 1 }
        try await engine.rename(container: web, to: "web-2")
        XCTAssertEqual(fake.summary(web)?.name, "web-2")
        let old = try await heard.value
        XCTAssertEqual(old, "/web", "a rename event, with the old name")
        for (name, status) in [("x", 400), ("db", 409), ("web-2", 400)] {
            do {
                try await engine.rename(container: web, to: name)
                XCTFail("\(name) taken")
            } catch let error as DockerError {
                XCTAssertEqual(error.status, status, "\(name): \(error.message)")
            }
        }
        let id = try await engine.commit(container: web, repository: "ot/web", tag: "1", comment: "c", changes: [#"ENV A="""#])
        let images = try await engine.images()
        XCTAssertEqual(images.first { $0.tags.contains("ot/web:1") }?.Id, id)
        XCTAssertEqual(fake.commits.last?.changes, #"ENV A="""#)
        XCTAssertNil(fake.commits.last?.pause, "paused, as the engine does by default")
        XCTAssertTrue(
            fake.requests.contains("POST /v1.47/commit?changes=ENV%20A%3D%22%22&comment=c&container=\(web)&repo=ot/web&tag=1"),
            "\(fake.requests.filter { $0.contains("commit") })")
    }

    /// Saved as an image on the classic store, which keeps the committed
    /// container's own config in the image (`docker save` and `push`
    /// carry it): committed twice, the second time from a container of
    /// the first, so neither the image's config nor the container's it
    /// keeps holds the secret or Compose's labels. The first stays as the
    /// image's parent, out of the list; the helper goes.
    func testASavedImageKeepsNoSecretOnTheClassicStore() async throws {
        let web = fake.add(name: "web", project: "shop", service: "web", env: ["API_TOKEN=s3cr3t", "PORT=80"])
        let detail = try await engine.container(web)
        let changes = DockerCommit.changes(env: detail.Config.Env ?? [], imageEnv: [], labels: detail.Config.Labels ?? [:])
        let info = try await engine.info()
        XCTAssertFalse(info.containerdStore, "the fake's classic store")

        // Once, as the CLI does: the secret stays in what the image keeps.
        _ = try await engine.commit(container: web, repository: "ot/once", tag: "1", changes: changes)
        let once = try XCTUnwrap(fake.imageRecord("ot/once:1"))
        XCTAssertTrue(once.config.Env?.contains("API_TOKEN=") == true)
        XCTAssertTrue(once.containerConfig?.Env?.contains("API_TOKEN=s3cr3t") == true, "why it is done twice")

        let before = fake.allImages.count
        let commits = fake.commits.count
        let id = try await engine.commitAnew(container: web, helper: "web-saving-1", repository: "ot/web", tag: "1", comment: "c", changes: changes)
        let saved = try XCTUnwrap(fake.imageRecord("ot/web:1"))
        for config in [saved.config, try XCTUnwrap(saved.containerConfig)] {
            XCTAssertTrue(config.Env?.contains("API_TOKEN=") == true, "\(config.Env ?? [])")
            XCTAssertFalse(config.Env?.contains { $0.contains("s3cr3t") } == true, "\(config.Env ?? [])")
            XCTAssertTrue(config.Env?.contains("PORT=80") == true, "the rest stays")
            XCTAssertEqual(config.Labels?["com.docker.compose.project"], "", "emptied")
        }
        let made = Array(fake.commits.dropFirst(commits))
        XCTAssertEqual(made.map(\.repo), ["", "ot/web"], "untagged, then under the name")
        XCTAssertEqual(made.map(\.changes), [changes.joined(separator: "\n"), ""])
        XCTAssertEqual(made.last?.comment, "c")
        XCTAssertNotEqual(made.last?.container, web, "the second from the helper")
        let containers = try await engine.containers()
        XCTAssertFalse(containers.contains { $0.name == "web-saving-1" }, "the helper is removed")
        let images = try await engine.images()
        XCTAssertEqual(images.first { $0.tags.contains("ot/web:1") }?.Id, id)
        XCTAssertFalse(images.contains { $0.isDangling }, "the first is the image's parent, out of the list")
        XCTAssertEqual(fake.allImages.count, before + 2)

        // A container run from it: no secret, and no service of Compose's.
        let run = try await engine.create(fromImage: "ot/web:1", name: "from-snapshot")
        let listed = try await engine.containers()
        let summary = try XCTUnwrap(listed.first { $0.Id == run })
        XCTAssertNil(summary.composeProject)
        XCTAssertNil(summary.composeService)
        XCTAssertTrue(ComposeProjects.group([summary]).projects.isEmpty)
        let env = try await engine.container(run).Config.Env ?? []
        XCTAssertFalse(env.contains { $0.contains("s3cr3t") }, "\(env)")

        // A helper that can't be made: nothing left behind.
        fake.add(name: "web-saving-2")
        let count = fake.allImages.count
        do {
            _ = try await engine.commitAnew(container: web, helper: "web-saving-2", repository: "ot/web", tag: "2", comment: "", changes: changes)
            XCTFail("the name is taken")
        } catch let error as DockerError {
            XCTAssertEqual(error.status, 409)
        }
        XCTAssertEqual(fake.allImages.count, count, "the first image removed")
        XCTAssertNil(fake.imageRecord("ot/web:2"))
    }

    /// The containerd store keeps nothing of the container in the image:
    /// one commit is enough, and the engine says which store it is.
    func testTheContainerdStoreKeepsNoContainerConfig() async throws {
        fake.containerdStore = true
        defer { fake.containerdStore = false }
        let web = fake.add(name: "web", env: ["API_TOKEN=s3cr3t"])
        let info = try await engine.info()
        XCTAssertTrue(info.containerdStore)
        _ = try await engine.commit(container: web, repository: "ot/web", tag: "1", changes: [#"ENV API_TOKEN="""#])
        let saved = try XCTUnwrap(fake.imageRecord("ot/web:1"))
        XCTAssertNil(saved.containerConfig)
        XCTAssertEqual(saved.config.Env, ["API_TOKEN="])
    }

    /// A container's limits and name changed on the real engine: the swap
    /// sent with a limit is what lets one go above the old swap. A
    /// container of our own, labelled, from an image already here; removed
    /// after. No commit: it would make an image.
    func testSettingsAndANameOnTheRealEngine() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["OVERTERM_DOCKER_TESTS"] == "1", "OVERTERM_DOCKER_TESTS=1 runs it")
        let real = DockerEngine(endpoint: .current())
        try await real.ping()
        let image = "debian:bookworm-slim"
        guard (try? await real.send(.GET, "/images/\(image)/json")) != nil else { throw XCTSkip("\(image) isn't on this Mac; nothing is pulled") }
        let name = "overterm-test-\(UUID().uuidString.prefix(8).lowercased())"
        let create = try JSONSerialization.data(withJSONObject: ["Image": image, "Cmd": ["sleep", "120"], "Labels": ["overterm.test": "1"]])
        struct Created: Decodable { var Id: String }
        let made = try JSONDecoder().decode(
            Created.self,
            from: try await real.send(.POST, "/containers/create", ["name": name], body: create, headers: [("Content-Type", "application/json")]).body)
        func draft() async throws -> DockerContainerSettings {
            let summary = try await real.containers().first { $0.Id == made.Id }
            return DockerContainerSettings(try XCTUnwrap(summary), try await real.container(made.Id), engine: try await real.info())
        }
        do {
            try await real.perform(.start, on: made.Id)
            var settings = try await draft()
            settings.memory = "64m"
            settings.cpus = "0.5"
            settings.restart = "on-failure"
            settings.retries = 2
            try await real.update(container: made.Id, try XCTUnwrap(settings.update))
            let host = try await real.container(made.Id).HostConfig
            XCTAssertEqual(host?.Memory, 64 << 20)
            XCTAssertEqual(host?.MemorySwap, 128 << 20)
            XCTAssertEqual(host?.NanoCpus, 500_000_000)
            XCTAssertEqual(host?.RestartPolicy, .init(Name: "on-failure", MaximumRetryCount: 2))
            var higher = try await draft()
            higher.memory = "256m"
            try await real.update(container: made.Id, try XCTUnwrap(higher.update))
            let raised = try await real.container(made.Id).HostConfig?.Memory
            XCTAssertEqual(raised, 256 << 20, "above the old swap: taken, its swap with it")
            try await real.rename(container: made.Id, to: name + "-2")
            let renamed = try await real.container(made.Id).name
            XCTAssertEqual(renamed, name + "-2")
        } catch {
            try? await real.remove(container: made.Id, force: true)
            throw error
        }
        try await real.remove(container: made.Id, force: true)
    }

    func testHubIsSearchedThroughTheEngine() async throws {
        let found = try await engine.search("redis")
        XCTAssertEqual(found.map(\.name), ["redis", "bitnami/redis"])
        XCTAssertEqual(found.first?.is_official, true)
        XCTAssertTrue(fake.requests.contains { $0.contains("/images/search?limit=10&term=redis") }, "\(fake.requests)")
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

    /// What an image is built for, from its inspect, and the engine's own
    /// machine from `/info`.
    func testAnImageSaysItsPlatform() async throws {
        let info = try await engine.info()
        XCTAssertEqual(info.Architecture, "aarch64")
        XCTAssertEqual(info.OSType, "linux")
        let legacy = fake.addImage("legacy:1", size: 1, architecture: "amd64")
        let arm = fake.addImage("arm:1", size: 1, architecture: "arm", variant: "v7")
        let platform = try await engine.platform(ofImage: legacy)
        XCTAssertEqual(platform, DockerPlatform(os: "linux", architecture: "amd64", variant: nil))
        let armPlatform = try await engine.platform(ofImage: arm)
        XCTAssertEqual(armPlatform?.description, "linux/arm/v7")
        do {
            _ = try await engine.platform(ofImage: "sha256:nope")
            XCTFail("no such image")
        } catch let error as DockerError {
            XCTAssertEqual(error.status, 404)
        }
        let both = await engine.platforms(ofImages: [legacy, arm, "sha256:nope"])
        XCTAssertEqual(Set(both.keys), [legacy, arm])
    }

    /// A pull for a platform asks the engine for it; the tag then names
    /// that image. One with no such variant says so.
    func testAPullForAPlatform() async throws {
        let legacy = fake.addImage("legacy:1", size: 1, architecture: "amd64")
        for try await _ in engine.pull("legacy:1", platform: "linux/arm64") {}
        XCTAssertTrue(fake.requests.contains { $0.hasSuffix("/images/create?fromImage=legacy&platform=linux/arm64&tag=1") }, "\(fake.requests)")
        let images = try await engine.images()
        let tagged = try XCTUnwrap(images.first { $0.tags.contains("legacy:1") })
        XCTAssertNotEqual(tagged.Id, legacy)
        let pulled = try await engine.platform(ofImage: tagged.Id)
        XCTAssertEqual(pulled?.architecture, "arm64")
        XCTAssertEqual(images.first { $0.Id == legacy }?.isDangling, true, "the old one is <none>")
        do {
            for try await _ in engine.pull("amd64only/tool:1", platform: "linux/arm64") {}
            XCTFail("no arm64 variant")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("no matching manifest"), error.localizedDescription)
        }
    }

    /// The fake's ids are the whole tag's: long tags alike in their first
    /// 32 bytes are two images, and a platform pull of one leaves the
    /// other platform's image `<none>`.
    func testLongTagsAreImagesOfTheirOwn() async throws {
        let a = fake.addImage("registry.example.com/team/service-a:1", size: 1)
        let b = fake.addImage("registry.example.com/team/service-b:1", size: 1)
        XCTAssertNotEqual(a, b)
        let long = "ghcr.io/overcraft-hq/overterm-api:1"
        let amd = fake.addImage(long, size: 1, architecture: "amd64")
        for try await _ in engine.pull(long, platform: "linux/arm64") {}
        let images = try await engine.images()
        XCTAssertTrue(images.contains { $0.Id == a } && images.contains { $0.Id == b }, "both listed")
        let tagged = try XCTUnwrap(images.first { $0.tags.contains(long) })
        XCTAssertNotEqual(tagged.Id, amd)
        XCTAssertEqual(images.first { $0.Id == amd }?.isDangling, true, "the old one is <none>")
        let old = try await engine.platform(ofImage: amd)
        XCTAssertEqual(old?.architecture, "amd64")
        XCTAssertEqual(FakeDockerEngine.imageID("legacy:1"), FakeDockerEngine.imageID("legacy:1"))
        XCTAssertEqual(FakeDockerEngine.imageID(long).count, "sha256:".count + 64)
    }

    /// The containerd store: a pull adds its platform to the tag's index,
    /// whose inspect then says the host's. From API 1.48 a container says
    /// the platform it was made for, in the list and in inspect; the
    /// classic store's never does.
    func testTheContainerdStore() async throws {
        fake.containerdStore = true
        fake.apiVersion = "1.48"
        let index = fake.addImage("legacy:1", size: 1, architecture: "amd64")
        let made = fake.add(name: "old", image: "legacy:1", imageID: index)
        for try await _ in engine.pull("legacy:1", platform: "linux/arm64") {}
        let images = try await engine.images()
        XCTAssertEqual(images.filter { $0.tags.contains("legacy:1") }.map(\.Id), [index], "one index")
        XCTAssertFalse(images.contains { $0.isDangling })
        let now = try await engine.platform(ofImage: index)
        XCTAssertEqual(now?.architecture, "arm64", "the host's, once the index holds it")
        let before = try await engine.containers()
        XCTAssertNil(before.first { $0.Id == made }?.ownPlatform, "not pinged: 1.47, which doesn't say")
        _ = try await engine.ping()
        let listed = try await engine.containers()
        XCTAssertEqual(listed.first { $0.Id == made }?.ownPlatform?.description, "linux/amd64", "what it was made for")
        let detail = try await engine.container(made)
        XCTAssertEqual(detail.ImageManifestDescriptor?.dockerPlatform?.short, "amd64")
        let after = fake.add(name: "new", image: "legacy:1", imageID: index)
        let again = try await engine.containers()
        XCTAssertEqual(again.first { $0.Id == after }?.ownPlatform?.short, "arm64", "made after: the host's")

        fake.containerdStore = false
        let classic = try await engine.containers()
        XCTAssertNil(classic.first { $0.Id == made }?.ownPlatform, "the classic store's say none")
    }

    /// Read-only, against the Docker this Mac runs — only when asked.
    func testTheRealEngineAnswers() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["OVERTERM_DOCKER_TESTS"] == "1", "OVERTERM_DOCKER_TESTS=1 runs it")
        let real = DockerEngine(endpoint: .current())
        let version = try await real.ping()
        XCTAssertFalse(version.isEmpty)
        let info = try await real.info()
        XCTAssertNotNil(DockerPlatform(engine: info.Architecture), info.Architecture ?? "no Architecture")
        _ = try await real.containers()
        let images = try await real.images()
        if let first = images.first {
            let platform = try await real.platform(ofImage: first.Id)
            XCTAssertNotNil(platform, first.Id)
        }
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
