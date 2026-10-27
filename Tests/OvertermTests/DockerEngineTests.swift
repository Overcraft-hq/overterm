import Foundation
import XCTest

@testable import Overterm

/// The engine's pure parts: where it is, its frames and lines, its tar,
/// what a stats sample means, ports once each, secrets hidden.
final class DockerEngineTests: XCTestCase {
    // MARK: Where the engine is

    func testDockerHostWinsOverTheContext() {
        let endpoint = DockerEndpoint.resolve(
            environment: ["DOCKER_HOST": "unix:///tmp/x.sock", "DOCKER_CONTEXT": "orbstack"], currentContext: "desktop-linux"
        ) { _ in "unix:///never" }
        XCTAssertEqual(endpoint, DockerEndpoint(address: .unix("/tmp/x.sock"), context: nil, source: "DOCKER_HOST"))
    }

    func testTheContextComesFromTheEnvironmentThenTheConfig() {
        let hosts = ["orbstack": "unix:///Users/me/.orbstack/run/docker.sock", "desktop-linux": "unix:///Users/me/.docker/run/docker.sock"]
        let fromEnvironment = DockerEndpoint.resolve(environment: ["DOCKER_CONTEXT": "orbstack"], currentContext: "desktop-linux") { hosts[$0] }
        XCTAssertEqual(fromEnvironment.context, "orbstack")
        XCTAssertEqual(fromEnvironment.address, .unix("/Users/me/.orbstack/run/docker.sock"))
        let fromConfig = DockerEndpoint.resolve(environment: [:], currentContext: "desktop-linux") { hosts[$0] }
        XCTAssertEqual(fromConfig.source, "context desktop-linux")
        XCTAssertEqual(fromConfig.address, .unix("/Users/me/.docker/run/docker.sock"))
    }

    func testTheDefaultContextAndAMissingRecordFallBack() {
        let defaulted = DockerEndpoint.resolve(environment: [:], currentContext: "default") { _ in "unix:///never" }
        XCTAssertEqual(defaulted, DockerEndpoint(address: .unix("/var/run/docker.sock"), context: nil, source: "default"))
        let missing = DockerEndpoint.resolve(environment: ["DOCKER_HOST": ""], currentContext: "gone") { _ in nil }
        XCTAssertEqual(missing.source, "default")
    }

    func testAddresses() {
        XCTAssertEqual(DockerEndpoint.address(of: "tcp://192.168.1.4:2376"), .tcp(host: "192.168.1.4", port: 2376))
        XCTAssertEqual(DockerEndpoint.address(of: "tcp://localhost"), .tcp(host: "localhost", port: 2375))
        XCTAssertEqual(DockerEndpoint.address(of: "http://:2375/"), .tcp(host: "127.0.0.1", port: 2375))
        XCTAssertEqual(DockerEndpoint.address(of: "ssh://me@box"), .unsupported("ssh://me@box"))
    }

    /// The CLI's folder for a context is its name's SHA-256, and the files
    /// are read the way the CLI writes them.
    func testContextsAreReadFromTheirRecords() throws {
        XCTAssertEqual(DockerEndpoint.metaFolder(for: "default"), "37a8eec1ce19687d132fe29051dca629d164e2c4958ba141d5f4133a33f0688f")
        let docker = FileManager.default.temporaryDirectory.appendingPathComponent("docker-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: docker) }
        for (name, host) in [("orbstack", "unix:///o.sock"), ("colima-work", "unix:///c.sock")] {
            let folder = docker.appendingPathComponent("contexts/meta/\(DockerEndpoint.metaFolder(for: name))")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let meta = #"{"Name":"\#(name)","Metadata":{},"Endpoints":{"docker":{"Host":"\#(host)","SkipTLSVerify":false}}}"#
            try Data(meta.utf8).write(to: folder.appendingPathComponent("meta.json"))
        }
        try Data(#"{"auths":{},"currentContext":"colima-work"}"#.utf8).write(to: docker.appendingPathComponent("config.json"))
        let endpoint = DockerEndpoint.current(environment: [:], docker: docker)
        XCTAssertEqual(endpoint.address, .unix("/c.sock"))
        XCTAssertEqual(endpoint.context, "colima-work")
        let contexts = DockerEndpoint.contexts(docker: docker).map(\.name)
        XCTAssertEqual(contexts.first, "default")
        XCTAssertEqual(Set(contexts), ["default", "orbstack", "colima-work"])
    }

    func testRuntimes() {
        func runtime(_ path: String, context: String? = nil, os: String? = nil) -> DockerRuntime {
            DockerRuntime.of(DockerEndpoint(address: .unix(path), context: context, source: ""), operatingSystem: os)
        }
        XCTAssertEqual(runtime("/Users/me/.docker/run/docker.sock"), .dockerDesktop)
        XCTAssertEqual(runtime("/var/run/docker.sock", os: "Docker Desktop"), .dockerDesktop)
        XCTAssertEqual(runtime("/Users/me/.orbstack/run/docker.sock"), .orbStack)
        XCTAssertEqual(runtime("/Users/me/.colima/default/docker.sock", context: "colima"), .colima)
        XCTAssertEqual(runtime("/var/run/docker.sock", os: "Ubuntu 24.04"), .engine)
        XCTAssertEqual(DockerRuntime.colima.command(.start, context: "colima-work"), "colima start --profile work")
        XCTAssertEqual(DockerRuntime.dockerDesktop.command(.restart), "docker desktop restart")
        XCTAssertNil(DockerRuntime.engine.command(.stop))
    }

    // MARK: Paths and versions

    func testPathsCarryTheVersionAndASortedQuery() {
        let engine = DockerEngine(endpoint: DockerEndpoint(address: .unix("/nowhere"), context: nil, source: ""))
        XCTAssertEqual(
            engine.path("/containers/json", ["all": "1", "filters": #"{"label":["a=b"]}"#]),
            "/v\(DockerEngine.clientVersion)/containers/json?all=1&filters=%7B%22label%22:%5B%22a%3Db%22%5D%7D")
        XCTAssertEqual(engine.path("/images/create", ["fromImage": "a+b"]), "/v\(DockerEngine.clientVersion)/images/create?fromImage=a%2Bb")
    }

    func testTheOlderVersionIsSpoken() {
        XCTAssertEqual(DockerEngine.older("1.52", "1.47"), "1.47")
        XCTAssertEqual(DockerEngine.older("1.41", "1.47"), "1.41")
        XCTAssertEqual(DockerEngine.older("1.9", "1.47"), "1.9")
    }

    func testImageNames() {
        XCTAssertTrue(DockerEngine.split("postgres:16") == ("postgres", "16"))
        XCTAssertTrue(DockerEngine.split("postgres") == ("postgres", "latest"))
        XCTAssertTrue(DockerEngine.split("localhost:5000/app") == ("localhost:5000/app", "latest"))
        XCTAssertTrue(DockerEngine.split("ghcr.io/a/b:1.2") == ("ghcr.io/a/b", "1.2"))
        XCTAssertTrue(DockerEngine.split("redis@sha256:abc") == ("redis", "sha256:abc"))
    }

    // MARK: Frames and lines

    func testFramesCutAnywhereComeOutWhole() {
        let stream = FakeDockerEngine.frame(.stdout, "hello\n") + FakeDockerEngine.frame(.stderr, "boom\n") + FakeDockerEngine.frame(.stdout, "")
        for cut in 0...stream.count {
            var demuxer = DockerLogDemuxer(framed: true)
            let chunks = demuxer.feed(stream.prefix(cut)) + demuxer.feed(stream.dropFirst(cut))
            XCTAssertEqual(chunks.filter { !$0.text.isEmpty }, [.init(stream: .stdout, text: "hello\n"), .init(stream: .stderr, text: "boom\n")], "cut at \(cut)")
        }
    }

    func testATTYsBytesArePlain() {
        var demuxer = DockerLogDemuxer(framed: false)
        XCTAssertEqual(demuxer.feed(Data("\u{1B}[32mok\u{1B}[0m\r\n".utf8)), [.init(stream: .stdout, text: "\u{1B}[32mok\u{1B}[0m\r\n")])
    }

    func testLinesAreSplitAcrossPieces() {
        var splitter = DockerLineSplitter()
        XCTAssertEqual(splitter.feed(Data(#"{"a":1}"#.utf8) + Data("\n{\"b\"".utf8)), [Data(#"{"a":1}"#.utf8)])
        XCTAssertEqual(splitter.feed(Data(":2}\n\n".utf8)), [Data(#"{"b":2}"#.utf8)])
        XCTAssertEqual(splitter.feed(Data()), [])
    }

    func testJSONLogLinesShowTheirMessage() {
        let line = DockerLogLine.parse(
            #"2026-10-27T10:00:00.123456789Z {"level":"error","msg":"db down","attempt":3,"time":"x"}"#, stream: .stdout, timestamps: true)
        XCTAssertEqual(line.timestamp, "2026-10-27T10:00:00.123456789Z")
        XCTAssertEqual(line.level, .error)
        XCTAssertEqual(line.message, "db down")
        XCTAssertEqual(line.fields.map { "\($0.0)=\($0.1)" }, ["attempt=3"])
        let pino = DockerLogLine.parse(#"{"level":40,"msg":"slow"}"#, stream: .stdout, timestamps: false)
        XCTAssertEqual(pino.level, .warning)
    }

    func testPlainLinesKeepTheirTextAndSayTheirLevel() {
        XCTAssertEqual(DockerLogLine.inlineLevel(#"time="x" level=warning msg="disk""#), .warning)
        XCTAssertEqual(DockerLogLine.inlineLevel("[ERROR] could not connect"), .error)
        XCTAssertEqual(DockerLogLine.inlineLevel("2026-10-27 10:00:00 UTC [1] FATAL:  role \"x\" does not exist"), .fatal)
        XCTAssertNil(DockerLogLine.inlineLevel("INFORMATION_SCHEMA is fine"))
        XCTAssertNil(DockerLogLine.inlineLevel("listening on :8080"))
        let coloured = DockerLogLine.parse("\u{1B}[31mERROR:\u{1B}[0m nope", stream: .stderr, timestamps: false)
        XCTAssertEqual(coloured.message, "ERROR: nope")
        XCTAssertEqual(coloured.level, .error)
    }

    func testAChunkHoldsSeveralLines() {
        let lines = DockerLogLine.lines(of: .init(stream: .stdout, text: "2026-10-27T10:00:00Z one\r\n2026-10-27T10:00:01Z two\n"), timestamps: true, service: "web")
        XCTAssertEqual(lines.map(\.message), ["one", "two"])
        XCTAssertEqual(lines.map(\.service), ["web", "web"])
    }

    // MARK: Tar

    func testAFileRoundTrips() throws {
        let data = Data((0..<1500).map { UInt8($0 % 251) })
        let archive = try XCTUnwrap(DockerTar.archive(name: "app.conf", data: data, mode: 0o600, modified: Date(timeIntervalSince1970: 1_700_000_000)))
        XCTAssertEqual(archive.count % DockerTar.block, 0)
        let entries = DockerTar.entries(of: archive)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.name, "app.conf")
        XCTAssertEqual(entries.first?.mode, 0o600)
        XCTAssertEqual(entries.first?.data, data)
        XCTAssertEqual(entries.first?.modified, Date(timeIntervalSince1970: 1_700_000_000))
    }

    /// What the system's tar would read: the checksum is right.
    func testTheHeaderSumsAsTarSumsIt() throws {
        let header = try XCTUnwrap(DockerTar.header(name: "a", size: 3, mode: 0o644, modified: Date(), type: "0"))
        var unsummed = header
        for i in 148..<156 { unsummed[i] = 0x20 }
        let written = String(decoding: header[148..<154], as: UTF8.self)
        XCTAssertEqual(Int(written, radix: 8), unsummed.reduce(0) { $0 + Int($1) })
        XCTAssertEqual(String(decoding: header[257..<262], as: UTF8.self), "ustar")
    }

    func testLongNamesUseThePrefixOrFail() throws {
        let folder = String(repeating: "f", count: 120)
        let long = folder + "/" + String(repeating: "n", count: 90)
        let archive = try XCTUnwrap(DockerTar.archive(name: long, data: Data("x".utf8)))
        XCTAssertEqual(DockerTar.entries(of: archive).first?.name, long)
        XCTAssertNil(DockerTar.archive(name: String(repeating: "n", count: 150), data: Data()))
    }

    func testGNUAndPAXNamesAreRead() throws {
        let name = String(repeating: "g", count: 130)
        var gnu = try XCTUnwrap(DockerTar.header(name: "././@LongLink", size: name.utf8.count + 1, mode: 0, modified: Date(), type: "L"))
        gnu.append(Data(name.utf8) + Data([0]))
        gnu.append(Data(count: (DockerTar.block - (name.utf8.count + 1) % DockerTar.block) % DockerTar.block))
        gnu.append(try XCTUnwrap(DockerTar.archive(name: "short", data: Data("gnu".utf8))))
        XCTAssertEqual(DockerTar.entries(of: gnu).map(\.name), [name])

        let record = "path=/etc/\(name)\n"
        let pax = "\(record.utf8.count + 3) \(record)"
        var paxed = try XCTUnwrap(DockerTar.header(name: "PaxHeader", size: pax.utf8.count, mode: 0, modified: Date(), type: "x"))
        paxed.append(Data(pax.utf8))
        paxed.append(Data(count: (DockerTar.block - pax.utf8.count % DockerTar.block) % DockerTar.block))
        paxed.append(try XCTUnwrap(DockerTar.archive(name: "short", data: Data("pax".utf8))))
        XCTAssertEqual(DockerTar.entries(of: paxed).first?.name, "/etc/\(name)")
        XCTAssertEqual(DockerTar.entries(of: paxed).first?.data, Data("pax".utf8))
    }

    func testAPathStatSaysWhatAPathIs() throws {
        let folder = #"{"name":"etc","size":4096,"mode":2147484141,"mtime":"2026-10-27T10:00:00Z","linkTarget":""}"#
        let stat = try XCTUnwrap(DockerTar.pathStat(Data(folder.utf8).base64EncodedString()))
        XCTAssertTrue(stat.isDirectory)
        XCTAssertFalse(stat.isSymlink)
        XCTAssertEqual(stat.mode & 0o777, 0o755)
        XCTAssertNil(DockerTar.pathStat("not base64"))
    }

    // MARK: Stats, ports, secrets

    func testUsageIsWorkedOutAsDockerStatsDoes() {
        let sample = ContainerStatsSample(
            read: nil,
            cpu_stats: .init(cpu_usage: .init(total_usage: 300_000_000), system_cpu_usage: 2_000_000_000, online_cpus: 4),
            precpu_stats: .init(cpu_usage: .init(total_usage: 100_000_000), system_cpu_usage: 1_000_000_000, online_cpus: 4),
            memory_stats: .init(usage: 100 << 20, limit: 1 << 30, stats: ["inactive_file": 20 << 20]),
            networks: ["eth0": .init(rx_bytes: 10, tx_bytes: 20), "eth1": .init(rx_bytes: 1, tx_bytes: 2)],
            blkio_stats: .init(io_service_bytes_recursive: [.init(op: "read", value: 5), .init(op: "write", value: 7), .init(op: "Read", value: 1)]),
            pids_stats: .init(current: 9))
        let usage = DockerUsage(sample)
        XCTAssertEqual(usage.cpuPercent, 80, accuracy: 0.001)
        XCTAssertEqual(usage.memoryBytes, 80 << 20)
        XCTAssertEqual(usage.memoryPercent, 7.8125, accuracy: 0.001)
        XCTAssertEqual(usage.networkIn, 11)
        XCTAssertEqual(usage.networkOut, 22)
        XCTAssertEqual(usage.diskRead, 6)
        XCTAssertEqual(usage.diskWrite, 7)
        XCTAssertEqual(usage.processes, 9)
        XCTAssertEqual(DockerUsage(ContainerStatsSample()).cpuPercent, 0, "the first sample has nothing before it")
    }

    func testPortsAreListedOnce() {
        let ports = PublishedPort.of([
            DockerPort(IP: "0.0.0.0", PrivatePort: 5432, PublicPort: 55432, Type: "tcp"),
            DockerPort(IP: "::", PrivatePort: 5432, PublicPort: 55432, Type: "tcp"),
            DockerPort(IP: "::1", PrivatePort: 80, PublicPort: 8080, Type: "tcp"),
            DockerPort(IP: "127.0.0.1", PrivatePort: 80, PublicPort: 8080, Type: "tcp"),
            DockerPort(IP: nil, PrivatePort: 9000, PublicPort: nil, Type: "tcp"),
            DockerPort(IP: "0.0.0.0", PrivatePort: 53, PublicPort: 5353, Type: "udp"),
        ])
        XCTAssertEqual(ports.map(\.label), ["5353→53/udp", "8080→80", "55432→5432"])
        XCTAssertEqual(ports.first { $0.hostPort == 8080 }?.url?.absoluteString, "http://127.0.0.1:8080")
        XCTAssertEqual(ports.first { $0.hostPort == 55432 }?.url?.absoluteString, "http://localhost:55432")
    }

    func testSecretsAreHidden() {
        XCTAssertTrue(DockerSecrets.isSecret("POSTGRES_PASSWORD"))
        XCTAssertTrue(DockerSecrets.isSecret("stripe_api_key"))
        XCTAssertTrue(DockerSecrets.isSecret("SENTRY_DSN"))
        XCTAssertFalse(DockerSecrets.isSecret("KEYBOARD"))
        XCTAssertFalse(DockerSecrets.isSecret("PGDATA"))
        XCTAssertEqual(DockerSecrets.masked("POSTGRES_PASSWORD", "hunter2"), "••••••")
        XCTAssertEqual(DockerSecrets.masked("DATABASE_URL", "postgres://app:hunter2@db:5432/app"), "postgres://app:••••••@db:5432/app")
        XCTAssertEqual(DockerSecrets.masked("HOME", "/root"), "/root")
        let values = DockerSecrets.values(in: [("API_TOKEN", "abcd1234"), ("PIN_KEY", "123"), ("HOME", "/root")])
        XCTAssertEqual(values, ["abcd1234"])
        XCTAssertEqual(DockerSecrets.redact("auth abcd1234 ok", values: values), "auth •••••• ok")
    }

    // MARK: Models

    func testASummaryReadsItsStatus() throws {
        let json = #"""
            {"Id":"0123456789abcdef0123","Names":["/shop-db-1"],"Image":"postgres:16","Created":1,"State":"exited",
             "Status":"Exited (137) 2 minutes ago","Labels":{"com.docker.compose.project":"shop","com.docker.compose.service":"db",
             "com.docker.compose.oneoff":"False"}}
            """#
        let summary = try JSONDecoder().decode(ContainerSummary.self, from: Data(json.utf8))
        XCTAssertEqual(summary.name, "shop-db-1")
        XCTAssertEqual(summary.shortID, "0123456789ab")
        XCTAssertEqual(summary.state, .exited)
        XCTAssertEqual(summary.exitCode, 137)
        XCTAssertEqual(summary.composeProject, "shop")
        XCTAssertEqual(summary.composeService, "db")
        XCTAssertFalse(summary.isOneOff)
        XCTAssertNil(summary.health)
        var healthy = summary
        healthy.State = "running"
        healthy.Status = "Up 3 minutes (health: starting)"
        XCTAssertEqual(healthy.health, "starting")
        XCTAssertNil(healthy.exitCode)
    }

    func testAHealthcheckIsNotAnEvent() {
        let exec = DockerEvent(Type: "container", Action: "exec_start: pg_isready", Actor: .init(ID: "x", Attributes: nil))
        let health = DockerEvent(Type: "container", Action: "health_status: healthy", Actor: .init(ID: "x", Attributes: nil))
        XCTAssertFalse(DockerEvent.listed.contains(exec.verb))
        XCTAssertTrue(DockerEvent.listed.contains(health.verb))
    }
}
