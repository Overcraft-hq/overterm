import Foundation
import XCTest

@testable import Overterm

/// What runs emulated: an image's platform against the engine's, the words
/// for it, and the commands that run it natively. Pure.
final class DockerPlatformTests: XCTestCase {
    private func container(
        _ name: String, image: String = "postgres:16", imageID: String = "sha256:" + String(repeating: "b", count: 64), project: String? = nil,
        service: String? = nil, state: String = "running", status: String = "Up 1 minute"
    ) -> ContainerSummary {
        var labels: [String: String] = [:]
        if let project {
            labels["com.docker.compose.project"] = project
            labels["com.docker.compose.service"] = service ?? name
            labels["com.docker.compose.project.config_files"] = "/w/\(project)/compose.yaml"
            labels["com.docker.compose.project.working_dir"] = "/w/\(project)"
        }
        return ContainerSummary(
            Id: name + "-0123456789", Names: ["/" + name], Image: image, ImageID: imageID, Created: 1, Labels: labels, State: state, Status: status)
    }

    private let arm = DockerPlatform(architecture: "arm64")
    private let intel = DockerPlatform(architecture: "amd64")

    func testTheEnginesMachineAsAnImageSaysIt() {
        XCTAssertEqual(DockerPlatform(engine: "aarch64")?.description, "linux/arm64")
        XCTAssertEqual(DockerPlatform(engine: "arm64")?.short, "arm64")
        XCTAssertEqual(DockerPlatform(engine: "x86_64")?.short, "amd64")
        XCTAssertEqual(DockerPlatform(engine: "armv7l")?.short, "arm/v7")
        XCTAssertEqual(DockerPlatform(engine: "i686")?.short, "386")
        XCTAssertEqual(DockerPlatform(engine: "riscv64")?.short, "riscv64", "one it doesn't know, as it is")
        XCTAssertNil(DockerPlatform(engine: ""))
        XCTAssertNil(DockerPlatform(engine: nil))
        XCTAssertEqual(DockerPlatform(engine: "x86_64", os: "linux")?.os, "linux")
        XCTAssertEqual(DockerPlatform(engine: "x86_64", os: nil)?.os, "linux")
    }

    func testAnImagesPlatform() {
        let arm64 = DockerPlatform(os: "linux", architecture: "arm64", variant: "v8")
        XCTAssertEqual(arm64?.description, "linux/arm64", "arm64's v8 says nothing more")
        XCTAssertEqual(arm64?.short, "arm64")
        XCTAssertEqual(DockerPlatform(os: "linux", architecture: "arm", variant: "v7")?.description, "linux/arm/v7")
        XCTAssertEqual(DockerPlatform(os: "linux", architecture: "amd64", variant: "v3")?.description, "linux/amd64")
        XCTAssertEqual(DockerPlatform(os: nil, architecture: "amd64", variant: nil)?.os, "linux")
        XCTAssertNil(DockerPlatform(os: "linux", architecture: "", variant: nil))
        XCTAssertNil(DockerPlatform(os: "linux", architecture: nil, variant: nil))
    }

    func testWhatRunsEmulated() {
        XCTAssertEqual(DockerEmulation(image: intel, engine: arm)?.image.short, "amd64")
        XCTAssertNil(DockerEmulation(image: arm, engine: arm))
        XCTAssertNil(DockerEmulation(image: DockerPlatform(os: "linux", architecture: "arm64", variant: "v8"), engine: arm))
        XCTAssertEqual(DockerEmulation(image: DockerPlatform(architecture: "arm", variant: "v7"), engine: arm)?.image.short, "arm/v7", "Apple silicon has no 32-bit arm")
        XCTAssertEqual(DockerEmulation(image: arm, engine: intel)?.engine.short, "amd64")
        XCTAssertNil(DockerEmulation(image: DockerPlatform(architecture: "386"), engine: intel))
        XCTAssertNil(DockerEmulation(image: DockerPlatform(architecture: "amd64", os: "windows"), engine: intel), "another os isn't emulation")
        XCTAssertNil(DockerEmulation(image: nil, engine: arm))
        XCTAssertNil(DockerEmulation(image: intel, engine: nil))
        let emulated = DockerEmulation(image: intel, engine: arm)
        XCTAssertEqual(emulated?.title, "Emulated: linux/amd64 on a linux/arm64 engine")
        XCTAssertTrue(emulated?.summary.contains("Rosetta or QEMU") == true)
        XCTAssertTrue(emulated?.imageAdvice.contains("linux/arm64") == true)
    }

    /// Whether a service is built is its files' word (`built`), never its
    /// image's name: `image:` names what `build:` makes, and a tag moves.
    func testWhatToDoAboutIt() throws {
        let emulation = try XCTUnwrap(DockerEmulation(image: intel, engine: arm))
        let loose = container("tool")
        let service = container("shop-db-1", project: "shop", service: "db")
        let api = container("shop-api-1", image: "ghcr.io/org/api:dev", project: "shop", service: "api")
        XCTAssertEqual(emulation.verbTitle(for: loose, built: false), "Pull the arm64 Variant in a Tab")
        XCTAssertEqual(emulation.verbTitle(for: loose, built: nil), "Pull the arm64 Variant in a Tab")
        XCTAssertEqual(emulation.verbTitle(for: service, built: false), "Recreate as arm64 in a Tab")
        XCTAssertEqual(emulation.verbTitle(for: api, built: true), "Rebuild as arm64 in a Tab", "build: with an image: name")
        XCTAssertEqual(emulation.verbTitle(for: api, built: nil), "Recreate as arm64 in a Tab", "not read yet")
        XCTAssertEqual(
            emulation.verbTitle(for: container("shop-web-1", image: "shop-web", project: "shop", service: "web"), built: false), "Recreate as arm64 in a Tab",
            "a name like Compose's own says nothing")
        XCTAssertEqual(emulation.imageVerbTitle, "Pull the arm64 Variant")
        XCTAssertEqual(DockerEmulation(image: arm, engine: intel)?.verbTitle(for: loose, built: false), "Pull the amd64 Variant in a Tab", "an Intel engine's words")
        var oneOff = container("shop-api-run-1", project: "shop", service: "api")
        oneOff.Labels?["com.docker.compose.oneoff"] = "True"
        XCTAssertEqual(emulation.verbTitle(for: oneOff, built: true), "Pull the arm64 Variant in a Tab", "a one-off is no service")

        let composed = emulation.advice(for: service, built: false)
        XCTAssertTrue(composed.contains("“platform: linux/amd64”") && composed.contains("DOCKER_DEFAULT_PLATFORM"), composed)
        XCTAssertTrue(emulation.advice(for: loose, built: false).contains("Run Another Like It"), emulation.advice(for: loose, built: false))
        XCTAssertTrue(emulation.advice(for: api, built: true).contains("Compose built it for amd64"), emulation.advice(for: api, built: true))
        let unread = emulation.advice(for: api, built: nil)
        XCTAssertTrue(unread.contains("built again, if its compose file builds it"), unread)
        let failed = container("tool", state: "exited", status: "Exited (1) 2 seconds ago")
        XCTAssertTrue(emulation.advice(for: failed, built: false).contains("exec format error"), emulation.advice(for: failed, built: false))
        XCTAssertFalse(emulation.advice(for: loose, built: false).contains("exec format error"))

        XCTAssertEqual(DockerPlatform.nameToPull(loose), "postgres:16")
        XCTAssertNil(DockerPlatform.nameToPull(container("tool", image: "sha256:" + String(repeating: "b", count: 64))), "the list says its id")
        XCTAssertNil(DockerPlatform.nameToPull(container("tool", image: "bbbbbbbbbbbb")), "an id's start")
        XCTAssertEqual(
            DockerPlatform.nameToPull(container("tool", image: "sha256:" + String(repeating: "b", count: 64)), reference: "postgres:16"), "postgres:16",
            "inspect still names it")
    }

    func testTheCommandsThatRunItNatively() throws {
        let byID = "sha256:" + String(repeating: "b", count: 64)
        let shop = ComposeProjects.group([
            container("shop-db-1", project: "shop", service: "db"), container("shop-api-1", image: "ghcr.io/org/api:dev", project: "shop", service: "api"),
            container("shop-web-1", image: byID, project: "shop", service: "web"),
        ]).projects.first
        let project = try XCTUnwrap(shop)
        let db = try XCTUnwrap(project.containers.first { $0.composeService == "db" })
        let api = try XCTUnwrap(project.containers.first { $0.composeService == "api" })
        let web = try XCTUnwrap(project.containers.first { $0.composeService == "web" })
        let rebuild = "DOCKER_DEFAULT_PLATFORM=linux/arm64 docker compose -p shop -f /w/shop/compose.yaml up -d --no-deps --force-recreate --build"
        XCTAssertEqual(DockerCommands.native(container("tool"), project: nil, platform: arm, built: false), "docker pull --platform linux/arm64 postgres:16")
        XCTAssertEqual(
            DockerCommands.native(db, project: project, platform: arm, built: false),
            "docker pull --platform linux/arm64 postgres:16 && DOCKER_DEFAULT_PLATFORM=linux/arm64 docker compose -p shop -f /w/shop/compose.yaml up -d --no-deps --force-recreate db"
        )
        XCTAssertEqual(
            DockerCommands.native(api, project: project, platform: arm, built: true), rebuild + " api",
            "built with an image: name: built again, nothing pulled from a registry")
        XCTAssertEqual(DockerCommands.native(web, project: project, platform: arm, built: true), rebuild + " web", "its tag moved on: still built")
        XCTAssertEqual(
            DockerCommands.native(db, project: project, platform: arm, built: nil), rebuild + " db", "not known: recreated with --build, nothing pulled")
        XCTAssertNil(DockerCommands.native(web, project: project, platform: arm, built: false), "pulled, by its id: no name to pull")
        XCTAssertEqual(
            DockerCommands.native(db, project: project, platform: arm, built: false, files: ["/w/shop/compose.yaml", "/o/shop.yaml"]),
            "docker pull --platform linux/arm64 postgres:16 && DOCKER_DEFAULT_PLATFORM=linux/arm64 docker compose -p shop -f /w/shop/compose.yaml -f /o/shop.yaml up -d --no-deps --force-recreate db",
            "a stack on ports of its own keeps its override")

        let fake = DockerEndpoint(address: .unix("/tmp/fake.sock"), context: nil, source: "OVERTERM_DOCKER_HOST")
        XCTAssertEqual(
            DockerCommands.native(container("tool"), project: nil, platform: arm, built: false, endpoint: fake),
            "DOCKER_HOST=unix:///tmp/fake.sock docker pull --platform linux/arm64 postgres:16")
        XCTAssertEqual(
            DockerCommands.native(db, project: project, platform: arm, built: false, endpoint: fake),
            "DOCKER_HOST=unix:///tmp/fake.sock docker pull --platform linux/arm64 postgres:16 && DOCKER_DEFAULT_PLATFORM=linux/arm64 DOCKER_HOST=unix:///tmp/fake.sock docker compose -p shop -f /w/shop/compose.yaml up -d --no-deps --force-recreate db"
        )
        XCTAssertEqual(
            DockerCommands.native(container("tool", image: "my app"), project: nil, platform: arm, built: false), "docker pull --platform linux/arm64 'my app'")
        XCTAssertNil(DockerCommands.native(container("tool", image: byID), project: nil, platform: arm, built: false))
        XCTAssertEqual(
            DockerCommands.native(container("tool", image: byID), reference: "redis:7", project: nil, platform: arm, built: false),
            "docker pull --platform linux/arm64 redis:7")
    }

    /// API 1.48's descriptor says what a container runs, whatever its
    /// image's index says now.
    func testAContainerSaysItsOwnPlatform() throws {
        let json = #"""
            [{"Id":"a","Names":["/a"],"Image":"nginx","ImageID":"sha256:x","Created":1,"State":"running","Status":"Up",
              "ImageManifestDescriptor":{"mediaType":"application/vnd.oci.image.manifest.v1+json","digest":"sha256:y","size":1,
                "platform":{"architecture":"amd64","os":"linux"}}},
             {"Id":"b","Names":["/b"],"Image":"nginx","Created":1,"State":"running","Status":"Up"}]
            """#
        let list = try JSONDecoder().decode([ContainerSummary].self, from: Data(json.utf8))
        XCTAssertEqual(list.first?.ownPlatform?.description, "linux/amd64")
        XCTAssertNil(list.last?.ownPlatform, "before 1.48, or the classic store")
    }

    func testAPullsFailureSaysWhy() {
        XCTAssertEqual(
            DockerPageModel.pullError("no matching manifest for linux/arm64/v8 in the manifest list entries", image: "tool:1", platform: arm),
            "tool:1 has no linux/arm64 variant — build one for it, or use another image.")
        XCTAssertEqual(
            DockerPageModel.pullError("no match for platform in manifest: not found", image: "tool:1", platform: arm),
            "tool:1 has no linux/arm64 variant — build one for it, or use another image.")
        XCTAssertTrue(DockerPageModel.pullError("pull access denied", image: "tool:1", platform: arm).contains("docker pull --platform linux/arm64 tool:1"))
        XCTAssertEqual(DockerPageModel.pullError("manifest unknown", image: "tool:1", platform: nil), "manifest unknown")
    }
}
