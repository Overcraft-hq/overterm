import Foundation
import XCTest

@testable import Overterm

/// A remote engine (`ssh://`): its URL, the forward's ssh arguments and
/// what ssh says back, always; a real forward through a throwaway sshd on
/// 127.0.0.1 to the fake engine's socket — its own keys, known_hosts and
/// no ~/.ssh/config — whenever this Mac has /usr/sbin/sshd.
final class DockerSSHTests: XCTestCase {
    func testAnSSHHostIsParsedAsTheCLIWritesIt() throws {
        XCTAssertEqual(DockerSSHTarget.parse("ssh://me@box"), DockerSSHTarget(user: "me", host: "box"))
        XCTAssertEqual(DockerSSHTarget.parse("ssh://box:2222"), DockerSSHTarget(host: "box", port: 2222))
        XCTAssertEqual(DockerSSHTarget.parse("ssh://ops@[fd00::5]:22"), DockerSSHTarget(user: "ops", host: "fd00::5", port: 22))
        XCTAssertEqual(DockerSSHTarget.parse("ssh://fd00::5"), DockerSSHTarget(host: "fd00::5"), "an unbracketed IPv6 host has no port")
        XCTAssertEqual(
            DockerSSHTarget.parse("ssh://me@box/run/user/1000/docker.sock"), DockerSSHTarget(user: "me", host: "box", socket: "/run/user/1000/docker.sock"))
        XCTAssertEqual(DockerSSHTarget.parse("ssh://box/"), DockerSSHTarget(host: "box"))
        XCTAssertNil(DockerSSHTarget.parse("ssh://"))
        XCTAssertNil(DockerSSHTarget.parse("tcp://box:2375"))
        for url in ["ssh://me@box:2222", "ssh://ops@[fd00::5]:22", "ssh://box/run/user/1000/docker.sock"] {
            XCTAssertEqual(DockerSSHTarget.parse(url)?.url, url)
        }
        XCTAssertEqual(DockerSSHTarget(user: "me", host: "box", port: 2222).destination, ["-l", "me", "-p", "2222", "box"])
        XCTAssertEqual(DockerSSHTarget(host: "box", port: 22).destination, ["box"], "the default port says nothing")
    }

    func testAnSSHEndpointIsRemoteAndTheCLIGetsItAsWritten() {
        let endpoint = DockerEndpoint.resolve(environment: ["DOCKER_HOST": "ssh://me@box"], currentContext: nil) { _ in nil }
        XCTAssertEqual(endpoint.address, .ssh(DockerSSHTarget(user: "me", host: "box")))
        XCTAssertEqual(endpoint.environment, ["DOCKER_HOST": "ssh://me@box"], "the CLI reaches it with its own ssh")
        XCTAssertEqual(endpoint.remoteHost, "box")
        XCTAssertEqual(DockerRuntime.of(endpoint, operatingSystem: "Docker Desktop"), .engine, "never this Mac's Docker Desktop's commands")
        let context = DockerEndpoint.resolve(environment: [:], currentContext: "prod") { _ in "ssh://deploy@prod.example.com" }
        XCTAssertEqual(context.environment, ["DOCKER_CONTEXT": "prod"])
        XCTAssertNil(DockerEndpoint(address: .unix("/var/run/docker.sock"), context: nil, source: "default").remoteHost)
        XCTAssertNil(DockerEndpoint(address: .tcp(host: "127.0.0.1", port: 2375), context: nil, source: "DOCKER_HOST").remoteHost)
        XCTAssertEqual(DockerEndpoint(address: .tcp(host: "10.0.0.7", port: 2375), context: nil, source: "DOCKER_HOST").remoteHost, "10.0.0.7")
    }

    func testTheForwardsArguments() {
        let target = DockerSSHTarget(user: "deploy", host: "box", port: 2222)
        let arguments = DockerSSHForward.arguments(target, localSocket: "/tmp/ot.sock", remoteSocket: "/var/run/docker.sock")
        XCTAssertEqual(arguments[arguments.firstIndex(of: "-L")! + 1], "/tmp/ot.sock:/var/run/docker.sock")
        for option in ["BatchMode=yes", "ExitOnForwardFailure=yes", "StreamLocalBindUnlink=yes", "StreamLocalBindMask=0177", "ControlMaster=no"] {
            XCTAssertTrue(arguments.contains(option), option)
        }
        XCTAssertEqual(Array(arguments.suffix(5)), ["-l", "deploy", "-p", "2222", "box"])
        let query = DockerSSHForward.socketQuery(target)
        XCTAssertEqual(query.last, "docker context inspect --format '{{.Endpoints.docker.Host}}'", "one word for the host's shell")
        XCTAssertEqual(query[query.count - 2], "--")
        let local = DockerSSHForward.localSocket(for: target)
        XCTAssertLessThan(local.utf8.count, 104, "a unix socket's path")
        XCTAssertEqual(local, DockerSSHForward.localSocket(for: target), "one a host")
    }

    func testWhatSSHSays() {
        XCTAssertEqual(DockerSSHForward.remoteSocket(fromOutput: "unix:///run/user/1000/docker.sock\n"), "/run/user/1000/docker.sock")
        XCTAssertNil(DockerSSHForward.remoteSocket(fromOutput: "ssh://elsewhere\n"))
        XCTAssertNil(DockerSSHForward.remoteSocket(fromOutput: ""))
        XCTAssertEqual(DockerSSHForward.hostName(fromConfig: "user deploy\nhostname 10.0.0.7\nport 22\n"), "10.0.0.7")
        XCTAssertEqual(
            DockerSSHForward.refusal(in: "channel 2: open failed: connect failed: Permission denied\r\nchannel 3: open failed: connect failed: No such file\r\n"),
            "connect failed: No such file")
        XCTAssertNil(DockerSSHForward.refusal(in: "Warning: Permanently added 'box' (ED25519) to the list of known hosts.\r\n"))
        let endpoint = DockerEndpoint(address: .ssh(DockerSSHTarget(host: "box")), context: nil, source: "DOCKER_HOST")
        XCTAssertEqual(
            DockerModel.reason(DockerError.unreachable("x"), endpoint: endpoint, runtime: .engine, refusal: "connect failed: Permission denied"),
            "box's engine refused the connection (connect failed: Permission denied).")
        XCTAssertEqual(
            DockerModel.reason(DockerError.unreachable("SSH: Permission denied (publickey)."), endpoint: endpoint, runtime: .engine),
            "SSH: Permission denied (publickey).")
    }

    func testARemoteEnginesPortsAreOnItsHost() {
        let ports = [
            DockerPort(IP: "0.0.0.0", PrivatePort: 80, PublicPort: 8080, Type: "tcp"),
            DockerPort(IP: "127.0.0.1", PrivatePort: 5432, PublicPort: 5432, Type: "tcp"),
        ]
        XCTAssertEqual(PublishedPort.of(ports).map(\.url?.absoluteString), ["http://127.0.0.1:5432", "http://localhost:8080"])
        let remote = PublishedPort.of(ports, remoteHost: "10.0.0.7")
        XCTAssertEqual(remote.map(\.url?.absoluteString), [nil, "http://10.0.0.7:8080"], "the host's loopback is the host's alone")
        let commands = DockerSSHTarget(user: "me", host: "box").commands.map(\.command)
        XCTAssertEqual(commands.first, "ssh -l me box")
        XCTAssertTrue(commands.contains("ssh -t -l me box sudoedit /etc/docker/daemon.json"), "\(commands)")
    }

    func testARemoteDatabaseIsReachedThroughTheHost() throws {
        let container = ContainerSummary(
            Id: "pg", Names: ["/pg"], Image: "postgres:16", Created: 1, Ports: [DockerPort(IP: "127.0.0.1", PrivatePort: 5432, PublicPort: 15432, Type: "tcp")],
            Labels: [:], State: "running", Status: "Up")
        let endpoint = DockerEndpoint(address: .ssh(DockerSSHTarget(user: "deploy", host: "box", port: 2222)), context: nil, source: "DOCKER_HOST")
        let guess = try XCTUnwrap(DockerDatabaseGuess.guess(container, env: [("POSTGRES_PASSWORD", "pw")], endpoint: endpoint))
        XCTAssertEqual(guess.connection.host, "127.0.0.1", "as the host sees it")
        XCTAssertEqual(guess.connection.port, 15432)
        XCTAssertTrue(guess.connection.sshEnabled)
        XCTAssertEqual(guess.connection.sshHost, "box")
        XCTAssertEqual(guess.connection.sshUser, "deploy")
        XCTAssertEqual(guess.connection.sshPort, 2222)
        let tcp = DockerEndpoint(address: .tcp(host: "10.0.0.7", port: 2375), context: nil, source: "DOCKER_HOST")
        var open = container
        open.Ports = [DockerPort(IP: "0.0.0.0", PrivatePort: 5432, PublicPort: 15432, Type: "tcp")]
        XCTAssertEqual(DockerDatabaseGuess.guess(open, env: [], endpoint: tcp)?.connection.host, "10.0.0.7")
        XCTAssertEqual(DockerDatabaseGuess.guess(open, env: [], endpoint: tcp)?.connection.sshEnabled, false)
    }

    // MARK: A real forward

    private var host: FakeSSHHost?

    override func tearDown() {
        DockerSSHForwards.closeAll()
        DockerSSHForward.testOptions = []
        host?.stop()
        host = nil
    }

    /// The throwaway sshd, and the forward told to reach it with its key alone.
    private func startHost() throws -> FakeSSHHost {
        do {
            let host = try FakeSSHHost.start()
            self.host = host
            DockerSSHForward.testOptions = host.options
            return host
        } catch let error as FakeSSHHost.Unavailable {
            throw XCTSkip(error.description)
        }
    }

    func testAnEngineThroughTheForward() async throws {
        let host = try startHost()
        let socket = host.folder.appendingPathComponent("engine.sock").path
        let fake = FakeDockerEngine(socket: socket)
        try fake.start()
        defer { fake.stop() }
        let id = fake.add(name: "far-web-1", ports: [DockerPort(IP: "0.0.0.0", PrivatePort: 80, PublicPort: 8080, Type: "tcp")])
        fake.log(id, "listening on 80")
        let target = DockerSSHTarget(host: "127.0.0.1", port: host.port, socket: socket)
        let engine = DockerEngine(endpoint: DockerEndpoint(address: .ssh(target), context: nil, source: "test"))
        let version = try await engine.ping()
        XCTAssertEqual(version, "1.47")
        let containers = try await engine.containers()
        XCTAssertEqual(containers.map(\.name), ["far-web-1"])
        // A stream and requests at once, over the one ssh.
        var lines: [String] = []
        for try await chunks in engine.logs(id, tty: false, tail: 10, follow: false) { lines += chunks.map(\.text) }
        XCTAssertTrue(lines.joined().contains("listening on 80"), "\(lines)")
        let forwarded = try await DockerSSHForwards.shared.socket(for: target)
        XCTAssertEqual(forwarded, DockerSSHForward.localSocket(for: target))
        let mode = try FileManager.default.attributesOfItem(atPath: forwarded)[.posixPermissions] as? Int
        XCTAssertEqual(mode.map { $0 & 0o077 }, 0, "the local end is this user's alone")
        let name = await DockerSSHForward.hostName(of: target)
        XCTAssertEqual(name, "127.0.0.1")
    }

    func testAMissingRemoteSocketSaysWhy() async throws {
        let host = try startHost()
        let target = DockerSSHTarget(host: "127.0.0.1", port: host.port, socket: host.folder.appendingPathComponent("nothing.sock").path)
        let endpoint = DockerEndpoint(address: .ssh(target), context: nil, source: "test")
        do {
            _ = try await DockerEngine(endpoint: endpoint).ping()
            XCTFail("an engine answered where there is none")
        } catch {
            try? await Task.sleep(for: .milliseconds(200))
            let refusal = await DockerSSHForwards.shared.refusal(target)
            XCTAssertNotNil(refusal, "ssh said why")
            let reason = DockerModel.reason(error, endpoint: endpoint, runtime: .engine, refusal: refusal)
            XCTAssertTrue(reason.hasPrefix("127.0.0.1's engine refused the connection ("), reason)
        }
    }

    func testAHostThatWontLetUsInSaysWhatSSHSaid() async throws {
        let host = try startHost()
        try host.refuseEveryone()
        let target = DockerSSHTarget(host: "127.0.0.1", port: host.port, socket: "/var/run/docker.sock")
        do {
            _ = try await DockerSSHForward.open(target)
            XCTFail("let in without a key")
        } catch {
            XCTAssertTrue(error.localizedDescription.hasPrefix("SSH: "), error.localizedDescription)
            XCTAssertTrue(error.localizedDescription.contains("Permission denied"), error.localizedDescription)
        }
    }
}
