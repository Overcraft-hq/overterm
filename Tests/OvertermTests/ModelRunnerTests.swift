import Foundation
import XCTest

@testable import Overterm

/// Docker Model Runner's models: what its API answers, read as the Models
/// section and `docker_models` read them; where the runner is found; and
/// both ways to it against the fake engine — Docker Desktop's, under
/// `/exp/vDD4.40` on the engine's socket, and a runner container's port.
/// Never `docker model`, which installs a runner on an engine with none.
@MainActor
final class ModelRunnerTests: XCTestCase {
    func testTheRunnersAnswersRead() throws {
        let json = """
            [{"id":"sha256:354bf30d0aa3af413d2aa5ae4f23c66d78980072d1e07a5b0d776e9606a2f0b9","tags":["ai/smollm2:latest"],"created":1742816981,
              "config":{"format":"gguf","quantization":"IQ2_XXS/Q4_K_M","parameters":"361.82 M","architecture":"llama","size":"256.35 MiB","context_size":8192}},
             {"id":"sha256:0123456789abcdef0123","created":1742816000,"config":null}]
            """
        let models = try JSONDecoder().decode([RunnerModel].self, from: Data(json.utf8))
        XCTAssertEqual(models.map(\.name), ["smollm2", "0123456789ab"], "ai/ and :latest dropped, as docker model list shows it; else the short id")
        XCTAssertEqual(models[0].reference, "ai/smollm2:latest", "what run and rm take")
        XCTAssertEqual(models[0].summary, "361.82 M · IQ2_XXS/Q4_K_M · 256.35 MiB · llama")
        XCTAssertEqual(models[1].summary, "")
        XCTAssertEqual(RunnerModel.display("hf.co/bartowski/llama:Q4"), "hf.co/bartowski/llama:Q4")
        let loaded = try JSONDecoder().decode(
            [RunningModel].self, from: Data(#"[{"backend_name":"llama.cpp","model_name":"ai/smollm2","mode":"completion","in_use":true}]"#.utf8))
        XCTAssertTrue(loaded[0].runs(models[0]), "a tag without :latest is the same model")
        XCTAssertFalse(loaded[0].runs(models[1]))
        XCTAssertNil(try JSONDecoder().decode([RunnerModel]?.self, from: Data("null".utf8)), "what the CLI's filter prints for none")
    }

    func testWhereTheRunnerIs() {
        let runner = ContainerSummary(
            Id: "mr", Names: ["/docker-model-runner"], Image: "docker/model-runner:latest", Created: 1,
            Ports: [DockerPort(IP: "127.0.0.1", PrivatePort: 12434, PublicPort: 12434, Type: "tcp")], Labels: [:], State: "running", Status: "Up")
        XCTAssertEqual(ModelRunner.place(runtime: .dockerDesktop, remote: false, containers: []), .desktop)
        XCTAssertEqual(ModelRunner.place(runtime: .dockerDesktop, remote: true, containers: []), .remote)
        XCTAssertEqual(ModelRunner.place(runtime: .orbStack, remote: false, containers: []), .absent(command: "docker model install-runner"))
        XCTAssertEqual(ModelRunner.place(runtime: .colima, remote: false, containers: [runner]), .container(id: "mr", port: 12434))
        var stopped = runner
        stopped.State = "exited"
        XCTAssertEqual(ModelRunner.place(runtime: .engine, remote: false, containers: [stopped]), .stopped(id: "mr", name: "docker-model-runner"))
        XCTAssertEqual(ModelRunner.endpoints(.desktop)?.containers, "http://model-runner.docker.internal/engines/v1")
        XCTAssertNil(ModelRunner.endpoints(.desktop)?.mac)
        XCTAssertEqual(ModelRunner.endpoints(.container(id: "mr", port: 12434))?.mac, "http://localhost:12434/engines/v1")
        XCTAssertNil(ModelRunner.endpoints(.absent(command: nil)))
    }

    // MARK: Against the fake

    private var fake: FakeDockerEngine!
    private var engine: DockerEngine!

    override func setUp() async throws {
        let socket = "/tmp/ot-docker-\(UUID().uuidString.prefix(8)).sock"
        fake = FakeDockerEngine(socket: socket)
        try fake.start()
        engine = DockerEngine(endpoint: DockerEndpoint(address: .unix(socket), context: nil, source: "test"))
    }

    override func tearDown() async throws {
        fake.stop()
        fake = nil
        engine = nil
    }

    func testDockerDesktopsRunnerOverTheEnginesSocket() async throws {
        let off = try await ModelRunner.read(.desktop, engine: engine)
        XCTAssertNil(off, "503 while Docker Desktop's runner is off")
        fake.setModelRunner([.init(tag: "ai/smollm2:latest", loaded: true), .init(tag: "ai/gemma3:4B-Q4_K_M", parameters: "3.88 B", size: "2.31 GiB")])
        let read = try await ModelRunner.read(.desktop, engine: engine)
        let contents = try XCTUnwrap(read)
        XCTAssertEqual(contents.models.map(\.name), ["gemma3:4B-Q4_K_M", "smollm2"])
        XCTAssertEqual(contents.running.map(\.model_name), ["ai/smollm2:latest"])
        XCTAssertEqual(contents.usage?.models_disk_usage, 536_000_000)
        XCTAssertTrue(fake.requests.contains("GET /exp/vDD4.40/models"), "\(fake.requests)")
        XCTAssertFalse(fake.requests.contains { $0.contains("/v1.") && $0.contains("models") }, "not the Engine API's own paths")
        try await ModelRunner.remove(contents.models[0], place: .desktop, engine: engine)
        XCTAssertEqual(fake.modelRunnerTags, ["ai/smollm2:latest"])
        XCTAssertTrue(fake.requests.contains("DELETE /exp/vDD4.40/models/ai/gemma3:4B-Q4_K_M"), "\(fake.requests)")
    }

    func testAnEnginesRunnerAtItsContainersPort() async throws {
        let port = try fake.listenTCP()
        fake.setModelRunner([.init(tag: "ai/qwen3:latest")])
        let read = try await ModelRunner.read(.container(id: "mr", port: port), engine: engine)
        let contents = try XCTUnwrap(read)
        XCTAssertEqual(contents.models.map(\.reference), ["ai/qwen3:latest"])
        XCTAssertTrue(fake.requests.contains("GET /models"), "at the root: \(fake.requests)")
    }

    func testAgentsAreToldTheModelsAndWhereToReachThem() async throws {
        let port = try fake.listenTCP()
        fake.setModelRunner([.init(tag: "ai/smollm2:latest", loaded: true)])
        let socket = fake.socket
        let model = DockerModel(endpoint: { DockerEndpoint(address: .unix(socket), context: nil, source: "test") }, retries: [.milliseconds(50)])
        defer { model.stop() }
        func ask() async throws -> String {
            let result = try await DockerMCP.call("docker_models", [:], docker: model)
            return ((result["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        }
        model.start()
        var deadline = Date().addingTimeInterval(5)
        while !model.connection.isRunning, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        let none = try await ask()
        XCTAssertTrue(none.contains("no Docker Model Runner"), none)
        fake.add(
            name: "docker-model-runner", image: "docker/model-runner:latest",
            ports: [DockerPort(IP: "127.0.0.1", PrivatePort: 12434, PublicPort: port, Type: "tcp")])
        deadline = Date().addingTimeInterval(5)
        while model.containers.isEmpty, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        let text = try await ask()
        XCTAssertTrue(text.contains("- ai/smollm2:latest (360M · Q4_K_M · 256.35 MiB · llama) — loaded in llama.cpp"), text)
        XCTAssertTrue(text.contains("from this Mac: http://localhost:\(port)/engines/v1"), text)
    }
}
