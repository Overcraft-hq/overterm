import Foundation
import XCTest

@testable import Overterm

private func digest(_ character: Character) -> String { "sha256:" + String(repeating: character, count: 64) }

/// buildx's default output (`util/imagetools/printers.go`): a tabwriter
/// padded with spaces, an index's children indented under `Manifests:`.
private func indexAnswer(_ name: String, _ top: String, children: [(digest: String, platform: String)], attestation: String? = nil) -> String {
    var text = "Name:      docker.io/library/\(name)\nMediaType: application/vnd.oci.image.index.v1+json\nDigest:    \(top)\n           \nManifests: \n"
    for child in children {
        text += "  Name:        docker.io/library/\(name)@\(child.digest)\n  MediaType:   application/vnd.oci.image.manifest.v1+json\n"
        text += "  Platform:    \(child.platform)\n               \n"
    }
    if let attestation {
        text += "  Name:        docker.io/library/\(name)@\(attestation)\n  MediaType:   application/vnd.oci.image.manifest.v1+json\n"
        text += "  Platform:    unknown/unknown\n  Annotations: \n    vnd.docker.reference.digest: \(children.first?.digest ?? "")\n"
        text += "    vnd.docker.reference.type:   attestation-manifest\n"
    }
    return text
}

private func manifestAnswer(_ name: String, _ top: String) -> String {
    "Name:      docker.io/library/\(name)\nMediaType: application/vnd.docker.distribution.manifest.v2+json\nDigest:    \(top)\n"
}

/// An image's name as the CLI reads it. Pure.
final class DockerImageReferenceTests: XCTestCase {
    func testNamesAsTheCLIReadsThem() {
        XCTAssertEqual(DockerImageReference("nginx")?.key, "docker.io/library/nginx:latest")
        let keys = ["nginx:1.27", "docker.io/library/nginx:1.27", "index.docker.io/library/nginx:1.27", "library/nginx:1.27"].map {
            DockerImageReference($0)?.key
        }
        XCTAssertEqual(Set(keys), ["docker.io/library/nginx:1.27"], "one image, however it is written")
        XCTAssertEqual(DockerImageReference("bitnami/redis:7")?.key, "docker.io/bitnami/redis:7")
        XCTAssertEqual(DockerImageReference("ghcr.io/acme/web:1.2")?.key, "ghcr.io/acme/web:1.2")
        XCTAssertEqual(DockerImageReference("ghcr.io/acme/web:1.2")?.domain, "ghcr.io")
        XCTAssertEqual(DockerImageReference("localhost:5000/app")?.key, "localhost:5000/app:latest", "a port is no tag")
        XCTAssertEqual(DockerImageReference("registry:5000/a/b:1")?.key, "registry:5000/a/b:1")
        XCTAssertEqual(DockerImageReference("registry:5000/a/b:1")?.path, "a/b")
        let pinned = DockerImageReference("nginx@" + digest("a"))
        XCTAssertNotNil(pinned)
        XCTAssertNil(pinned?.key, "pinned by digest: it can't move")
        XCTAssertNil(DockerImageReference("nginx:1.27@" + digest("a"))?.key)
        for bad in ["-rf", "", "Nginx", "a b", "nginx:", "nginx@sha256:short", "a//b"] { XCTAssertNil(DockerImageReference(bad), bad) }
        XCTAssertEqual(DockerImageReference("nginx:1.27")?.familiar, "nginx:1.27")
        XCTAssertEqual(DockerImageReference("docker.io/library/nginx:1.27")?.familiar, "nginx:1.27", "as the CLI is given it")
        XCTAssertEqual(DockerImageReference("docker.io/bitnami/redis:7")?.familiar, "bitnami/redis:7")
        XCTAssertEqual(DockerImageReference("ghcr.io/acme/web:1.2")?.familiar, "ghcr.io/acme/web:1.2")
        XCTAssertEqual(DockerImageReference("redis")?.familiar, "redis:latest")
    }

    func testRepoDigests() {
        let found = DockerImageReference.digested("nginx@" + digest("a"))
        XCTAssertEqual(found?.repository, "docker.io/library/nginx")
        XCTAssertEqual(found?.digest, digest("a"))
        XCTAssertEqual(DockerImageReference.digested("ghcr.io/x/y@" + digest("b"))?.repository, "ghcr.io/x/y")
        XCTAssertNil(DockerImageReference.digested(digest("a")), "containerd with no platform match: a bare digest")
        XCTAssertNil(DockerImageReference.digested("nginx:1.27"))
    }
}

/// What a registry's answer means, and why one couldn't be had. Pure.
final class DockerImageUpdateTests: XCTestCase {
    func testTheRegistrysAnswerIsRead() {
        let index = DockerRegistryDigest.parse(
            indexAnswer("nginx:1.27", digest("a"), children: [(digest("b"), "linux/arm64/v8"), (digest("c"), "linux/amd64")], attestation: digest("d")))
        XCTAssertEqual(index?.digest, digest("a"))
        XCTAssertEqual(index?.mediaType, "application/vnd.oci.image.index.v1+json")
        XCTAssertEqual(index?.manifests, [digest("b"), digest("c"), digest("d")], "each child, the attestation's too")
        let single = DockerRegistryDigest.parse(manifestAnswer("postgres:16", digest("e")))
        XCTAssertEqual(single?.digest, digest("e"))
        XCTAssertEqual(single?.manifests, [], "a single manifest has no children")
        XCTAssertNil(DockerRegistryDigest.parse("garbage"))
        XCTAssertNil(DockerRegistryDigest.parse(""))
        let childOnly = "Manifests:\n  Name:      docker.io/library/nginx:1@\(digest("b"))\n  Digest:    \(digest("b"))\n"
        XCTAssertNil(DockerRegistryDigest.parse(childOnly), "a child's indented line is never the tag's digest")
        XCTAssertNil(DockerRegistryDigest.parse("Digest:    sha256:nothex\n"), "a digest that isn't one")
    }

    func testATagsDigestsAreItsRepositorys() {
        let images = [
            ImageSummary(Id: "sha256:1", RepoTags: ["nginx:1.27", "my/nginx:custom"], RepoDigests: ["nginx@" + digest("a")], Created: 1, Size: 1),
            ImageSummary(Id: "sha256:2", RepoTags: ["ghcr.io/x/y:1"], RepoDigests: ["ghcr.io/x/y@" + digest("b")], Created: 1, Size: 1),
            ImageSummary(Id: "sha256:3", RepoTags: ["<none>:<none>"], RepoDigests: ["nginx@" + digest("c")], Created: 1, Size: 1),
        ]
        let local = DockerImageUpdates.localDigests(images)
        XCTAssertEqual(local["docker.io/library/nginx:1.27"], [digest("a")])
        XCTAssertEqual(local["docker.io/my/nginx:custom"], [], "tagged here: no digest of its own name")
        XCTAssertEqual(local["ghcr.io/x/y:1"], [digest("b")])
        XCTAssertEqual(local.count, 3, "a dangling image is no tag's")
        XCTAssertEqual(DockerImageUpdates.taggedImages(images)["docker.io/library/nginx:1.27"], "sha256:1")
    }

    func testWhatAnAnswerMeans() {
        let at = Date()
        func check(_ remote: String, children: [String] = []) -> DockerImageCheck {
            DockerImageCheck(reference: "nginx:1.27", remote: DockerRegistryDigest(digest: remote, manifests: children), at: at)
        }
        XCTAssertEqual(DockerImageUpdateState.of(local: [digest("a")], check: check(digest("a")), checking: false), .current)
        XCTAssertEqual(DockerImageUpdateState.of(local: [digest("a")], check: check(digest("b")), checking: false), .available)
        XCTAssertEqual(
            DockerImageUpdateState.of(local: [digest("a")], check: check(digest("b"), children: [digest("a")]), checking: false), .current,
            "pulled by its platform's digest")
        let failed = DockerImageCheck(reference: "x:1", failure: "no", at: at)
        XCTAssertEqual(DockerImageUpdateState.of(local: [digest("a")], check: failed, checking: false), .failed("no"))
        XCTAssertEqual(DockerImageUpdateState.of(local: [], check: check(digest("b")), checking: false), .local, "built or tagged here")
        XCTAssertEqual(DockerImageUpdateState.of(local: nil, check: nil, checking: false), .local)
        XCTAssertEqual(DockerImageUpdateState.of(local: [digest("a")], check: nil, checking: false), .unchecked)
        XCTAssertEqual(DockerImageUpdateState.of(local: [digest("a")], check: check(digest("a")), checking: true), .checking)
        // The containerd store: a repo digest for every named image, a
        // build's too — another image in the registry isn't an update.
        XCTAssertEqual(DockerImageUpdateState.of(local: [digest("a")], check: check(digest("b")), checking: false, known: false), .differs)
        XCTAssertEqual(DockerImageUpdateState.of(local: [digest("a")], check: check(digest("a")), checking: false, known: false), .current)
        let absent = DockerImageCheck(reference: "shop-api:dev", failure: "Docker Hub has no such image.", absent: true, at: at)
        XCTAssertEqual(
            DockerImageUpdateState.of(local: [digest("a")], check: absent, checking: false, known: false), .notInRegistry("Docker Hub has no such image."),
            "built here: not a failure")
        XCTAssertEqual(
            DockerImageUpdateState.of(local: [digest("a")], check: absent, checking: false), .failed("Docker Hub has no such image."),
            "pulled from it, and gone there: a failure")
    }

    func testWhyACheckFailed() {
        func failure(_ stderr: String, _ reference: String = "nginx:1.27", _ registry: String = "docker.io") -> DockerImageUpdateFailure {
            DockerImageUpdateFailure.of(stderr, reference: reference, registry: registry)
        }
        func reason(_ stderr: String, _ reference: String = "nginx:1.27", _ registry: String = "docker.io") -> String {
            failure(stderr, reference, registry).words ?? "no buildx"
        }
        XCTAssertEqual(failure("docker: 'buildx' is not a docker command.\nSee 'docker --help'"), .noBuildx)
        XCTAssertEqual(failure("unknown command: docker buildx"), .noBuildx)
        let oauth = "ERROR: failed to authorize: failed to fetch oauth token: unexpected status from POST request to https://ghcr.io/token: 401 Unauthorized"
        XCTAssertEqual(
            failure(oauth, "ghcr.io/acme/api:1", "ghcr.io"),
            .reason("ghcr.io wants credentials, or has no such image: docker login in a terminal tab if it's private."), "signed in, and refused")
        let anonymous =
            "ERROR: failed to authorize: failed to fetch anonymous token: unexpected status from GET request to https://auth.docker.io/token?scope=repository%3Alibrary%2Fshop-api%3Apull&service=registry.docker.io: 401 Unauthorized"
        guard case .absent(let why) = failure(anonymous, "shop-api:dev") else { return XCTFail("\(failure(anonymous, "shop-api:dev"))") }
        XCTAssertTrue(why.contains("no such image"), "asked without credentials, a registry says this of an image it doesn't have")
        XCTAssertTrue(reason("ERROR: unexpected status: 429 Too Many Requests: toomanyrequests: You have reached your pull rate limit").contains("pull limit"))
        XCTAssertEqual(reason("429 Too Many Requests", "quay.io/x/y:1", "quay.io"), "quay.io is limiting requests.")
        XCTAssertEqual(failure("ERROR: docker.io/library/nginx:9.9: not found", "nginx:9.9"), .absent("Docker Hub has no such tag."))
        XCTAssertEqual(failure("ERROR: dial tcp: lookup ghcr.io: no such host", "ghcr.io/x/y:1", "ghcr.io"), .unreachable("ghcr.io didn't answer."))
        XCTAssertEqual(failure("env timed out after 30 s", "ghcr.io/x/y:1", "ghcr.io"), .unreachable("ghcr.io didn't answer."), "Git.run's own word for a timeout")
        XCTAssertEqual(reason("ERROR: x"), "x", "anything else, in its own words")
        XCTAssertEqual(reason(String(repeating: "y", count: 300)).count, 200)
        // A tag's digits are no status code: the reference, the URLs and
        // the digests are taken out first.
        XCTAssertEqual(
            failure("ERROR: ghcr.io/acme/app:nightly-20240429: not found", "ghcr.io/acme/app:nightly-20240429", "ghcr.io"), .absent("ghcr.io has no such tag."))
        XCTAssertEqual(failure("ERROR: docker.io/acme/app:20250401: not found", "acme/app:20250401"), .absent("Docker Hub has no such tag."))
        XCTAssertEqual(
            failure(
                #"ERROR: Head "https://registry-1.docker.io/v2/jenkins/jenkins/manifests/2.401.3": dial tcp: lookup registry-1.docker.io: no such host"#,
                "jenkins/jenkins:2.401.3"), .unreachable("Docker Hub didn't answer."), "jenkins' 2.401.3 offline: no credentials asked for")
        XCTAssertEqual(
            failure("ERROR: dial tcp 10.0.0.1:443: i/o timeout", "acme/app:2.429"), .unreachable("Docker Hub didn't answer."), "nor a pull limit for 2.429")
        XCTAssertEqual(
            failure("ERROR: docker.io/acme/app@sha256:4291a0f0e1d2c3b4a5f6e7d8c9b0a1f2e3d4c5b6a7f8e9d0c1b2a3f4e5d6c7b8: not found", "acme/app:1"),
            .absent("Docker Hub has no such tag."))
        // A credential helper that isn't there says "not found" too.
        let helper = #"ERROR: error getting credentials - err: exec: "docker-credential-desktop": executable file not found in $PATH, out: ``"#
        XCTAssertEqual(reason(helper), "docker-credential-desktop isn't on this Mac — ~/.docker/config.json names it to sign in.")
        XCTAssertEqual(DockerImageUpdateFailure.scrub("x nginx:1.27 y", reference: "nginx:1.27"), "x   y")
    }

    func testAProjectsImagesAreItsContainers() {
        func container(_ name: String, image: String, imageID: String? = nil, service: String, oneOff: Bool = false) -> ContainerSummary {
            let labels = [
                "com.docker.compose.project": "shop", "com.docker.compose.service": service, "com.docker.compose.oneoff": oneOff ? "True" : "False",
            ]
            return ContainerSummary(
                Id: name, Names: ["/" + name], Image: image, ImageID: imageID, Created: 1, Labels: labels, State: "running", Status: "Up 1 minute")
        }
        let moved = digest("2")
        let project = ComposeProjects.group([
            container("shop-web-1", image: "nginx:1.27", imageID: digest("1"), service: "web"),
            container("shop-db-1", image: moved, imageID: moved, service: "db"),
            container("shop-cache-1", image: "redis@" + digest("3"), service: "cache"),
            container("shop-job-run-1", image: "busybox:1", service: "job", oneOff: true),
        ]).projects[0]
        XCTAssertEqual(
            DockerImageUpdates.references(of: project, recorded: ["db": "postgres:16"]), ["web": "nginx:1.27", "db": "postgres:16"],
            "one listed by its image's ID keeps what it was checked as; one pinned by digest or a one-off is no question")
        XCTAssertEqual(DockerImageUpdates.references(of: project, recorded: [:]), ["web": "nginx:1.27"])
        XCTAssertEqual(
            DockerImageUpdates.references(of: project, recorded: ["db": "postgres:16", "worker": "node:22"]), ["web": "nginx:1.27", "db": "postgres:16"],
            "a service it no longer has is no longer its")
        XCTAssertTrue(project.services.first { $0.name == "db" }?.containers.first?.imageMovedOn == true)
        XCTAssertFalse(project.services.first { $0.name == "web" }?.containers.first?.imageMovedOn == true)
        // A project before it runs: its files' images; what they build too,
        // which `specBuilt` names.
        let api = ComposeConfig.Service(name: "api", image: "ghcr.io/acme/api:2", dependsOn: [], profiles: [], ports: [], replicas: 1)
        let web = ComposeConfig.Service(name: "web", image: "ghcr.io/acme/web:dev", buildContext: "/w/plan", dependsOn: [], profiles: [], ports: [], replicas: 1)
        let planned = ComposeProject(
            name: "plan", workingDir: "/w/plan", configFiles: [],
            services: [api, web].map { ComposeService(project: "plan", name: $0.name, containers: [], dependsOn: [], spec: $0) }, planned: true)
        XCTAssertEqual(DockerImageUpdates.references(of: planned, recorded: [:]), ["api": "ghcr.io/acme/api:2", "web": "ghcr.io/acme/web:dev"])
        XCTAssertEqual(DockerImageUpdates.specBuilt(planned), ["web"])
    }

    func testAProjectsLine() {
        let at = Date(timeIntervalSince1970: 1_000)
        func ago(_ date: Date) -> String { "5 min ago" }
        var updates = DockerProjectUpdates()
        XCTAssertNil(updates.line(ago: ago), "nothing checked: nothing said")
        updates.available = [.init(service: "web", reference: "nginx:1.27")]
        updates.checkedAt = at
        XCTAssertEqual(updates.line(ago: ago), "Newer in the registry: web (nginx:1.27) — checked 5 min ago")
        updates.failed = [.init(service: "db", reference: "x:1", reason: "x wants credentials.")]
        XCTAssertEqual(
            updates.line(ago: ago), "Newer in the registry: web (nginx:1.27) — checked 5 min ago  ·  Couldn't check db (x:1): x wants credentials.")
        var pulled = DockerProjectUpdates(current: [.init(service: "web", reference: "nginx:1.27")], recreate: ["web"], checkedAt: at)
        XCTAssertEqual(pulled.line(ago: ago), "Pulled: Up recreates web on the new image")
        pulled.recreate = []
        XCTAssertEqual(pulled.line(ago: ago), "Its images are current — checked 5 min ago")
        pulled.differs = [.init(service: "api", reference: "acme/api:dev")]
        XCTAssertEqual(pulled.line(ago: ago), "Not as in the registry: api (acme/api:dev) — built here, or pulled before it moved on")
    }

    func testTheHeadline() {
        func headline(_ available: Int, differs: Int = 0, failed: Int = 0, unchecked: Int = 0) -> String {
            DockerImageUpdates.headline(DockerImageUpdateCounts(available: available, differs: differs, failed: failed, unchecked: unchecked))
        }
        XCTAssertEqual(headline(0), "Up to date", "every image there was to ask is current")
        XCTAssertEqual(headline(1), "1 update")
        XCTAssertEqual(headline(3), "3 updates")
        XCTAssertEqual(headline(0, failed: 2), "No updates · 2 couldn't be checked")
        XCTAssertEqual(headline(0, unchecked: 28), "No updates · 28 not checked", "a partial check isn't the list's")
        XCTAssertEqual(headline(1, differs: 1, failed: 1, unchecked: 2), "1 update · 1 differs · 1 couldn't be checked · 2 not checked")
        XCTAssertEqual(headline(1234, failed: 1), "1234 updates · 1 couldn't be checked", "never a localized number")
    }
}

/// Check for Updates against the fake engine, a stub `docker` answering as
/// buildx would: each registry asked once, only when asked, and a pull
/// made elsewhere seen without asking again.
@MainActor
final class DockerImageUpdatesTests: XCTestCase {
    private var fake: FakeDockerEngine!
    private var model: DockerModel!
    private var root: URL!
    private let at = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ot-updates-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let socket = "/tmp/ot-docker-\(UUID().uuidString.prefix(8)).sock"
        fake = FakeDockerEngine(socket: socket)
        try fake.start()
        let endpoint = DockerEndpoint(address: .unix(socket), context: nil, source: "test")
        model = DockerModel(endpoint: { endpoint }, retries: [.milliseconds(50)])
        model.start()
        let deadline = Date().addingTimeInterval(5)
        while model.engine == nil, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
    }

    override func tearDown() async throws {
        model.stop()
        fake.stop()
        try? FileManager.default.removeItem(at: root)
    }

    /// A stub `docker` logging each call: `arms` are its case's.
    private func stub(_ arms: String) throws -> URL {
        let tool = root.appendingPathComponent("bin/docker")
        try FileManager.default.createDirectory(at: tool.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\necho \"$*\" >> \"\(root.path)/calls\"\ncase \"$*\" in\n\(arms)\n*) echo \"unexpected: $*\" >&2; exit 1 ;;\nesac\n"
            .write(to: tool, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        return tool
    }

    /// An arm answering `reference` with `text`, kept in a file.
    private func answering(_ reference: String, _ text: String) throws -> String {
        let file = root.appendingPathComponent(reference.replacingOccurrences(of: "/", with: "_") + ".txt")
        try text.write(to: file, atomically: true, encoding: .utf8)
        return "\"buildx imagetools inspect \(reference)\") cat \"\(file.path)\" ;;"
    }

    private var calls: [String] {
        ((try? String(contentsOf: root.appendingPathComponent("calls"), encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    private func makeUpdates(_ tool: URL, parallel: Int = 4) -> DockerImageUpdates {
        DockerImageUpdates(docker: model, cli: { _ in DockerCLI(executable: tool, endpoint: nil) }, parallel: parallel, now: { [at] in at })
    }

    private func eventually(_ seconds: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(20)) }
        return condition()
    }

    func testACheckAsksEachRegistryOnce() async throws {
        XCTAssertNotNil(model.engine)
        fake.addImage("nginx:1.27", size: 1, digest: digest("a"))
        fake.addImage("postgres:16", size: 1, digest: digest("c"))
        fake.addImage("shop-api:dev", size: 1)
        let tool = try stub(
            try answering("nginx:1.27", indexAnswer("nginx:1.27", digest("b"), children: [(digest("e"), "linux/arm64"), (digest("f"), "linux/amd64")]))
                + "\n" + (try answering("postgres:16", manifestAnswer("postgres:16", digest("c")))))
        let updates = makeUpdates(tool)
        XCTAssertEqual(updates.state(of: "nginx:1.27"), .local, "nothing read, nothing known")
        let outcome = await updates.check(["nginx:1.27", "docker.io/library/nginx:1.27", "postgres:16", "shop-api:dev"])
        XCTAssertEqual(calls.sorted(), ["buildx imagetools inspect nginx:1.27", "buildx imagetools inspect postgres:16"], "each tag once, by its name")
        XCTAssertEqual(outcome, DockerImageUpdates.Outcome(asked: 2, skipped: 1, failure: nil), "the one built here isn't asked")
        XCTAssertEqual(updates.state(of: "nginx:1.27"), .available)
        XCTAssertEqual(updates.state(of: "docker.io/library/nginx:1.27"), .available)
        XCTAssertEqual(updates.state(of: "postgres:16"), .current, "a single manifest, the same digest")
        XCTAssertEqual(updates.state(of: "shop-api:dev"), .local)
        XCTAssertEqual(updates.checks["docker.io/library/nginx:1.27"]?.at, at)
        XCTAssertEqual(updates.lastRun, at)
        XCTAssertFalse(updates.running)
        let images = (try await model.engine?.images()) ?? []
        XCTAssertEqual(updates.counts(of: images), DockerImageUpdateCounts(available: 1))
        _ = updates.state(of: "postgres:16")
        _ = updates.summary(of: ComposeProject(name: "x", workingDir: nil, configFiles: [], services: []))
        XCTAssertEqual(calls.count, 2, "reading the answers asks nothing")
    }

    func testWithoutBuildxTheCheckStops() async throws {
        fake.addImage("nginx:1.27", size: 1, digest: digest("a"))
        fake.addImage("postgres:16", size: 1, digest: digest("c"))
        let tool = try stub("buildx*) echo \"docker: 'buildx' is not a docker command.\" >&2; echo \"See 'docker --help'\" >&2; exit 1 ;;")
        let updates = makeUpdates(tool, parallel: 1)
        let outcome = await updates.check(["nginx:1.27", "postgres:16"])
        XCTAssertEqual(calls.count, 1, "stopped at the first")
        XCTAssertTrue(outcome?.failure?.contains("docker buildx") == true, outcome?.failure ?? "no failure")
        XCTAssertEqual(updates.checks, [:])
        XCTAssertEqual(updates.state(of: "postgres:16"), .unchecked)
        XCTAssertNil(updates.lastRun, "nothing was checked")
    }

    /// Checked and pulled from the Images section, the project never
    /// checked itself: once the tag moves, the engine lists its container
    /// by its image's ID — what the service was made from is kept as the
    /// engine lists its projects.
    func testAPullElsewhereIsSeen() async throws {
        fake.refreshesImages = true
        let old = fake.addImage("nginx:1.27", size: 1, digest: digest("a"))
        let web = fake.add(name: "shop-web-1", image: "nginx:1.27", project: "shop", workingDir: "/w/shop", service: "web", imageID: old)
        let listed = await eventually { self.model.container(web) != nil && !self.model.projects.isEmpty }
        XCTAssertTrue(listed)
        let tool = try stub(try answering("nginx:1.27", manifestAnswer("nginx:1.27", digest("b"))))
        let updates = makeUpdates(tool)
        guard let project = model.projects.first else { return XCTFail("no project") }
        XCTAssertEqual(updates.references(of: project), ["web": "nginx:1.27"])
        await updates.check(["nginx:1.27"])
        XCTAssertEqual(updates.state(of: "nginx:1.27"), .available)
        XCTAssertEqual(updates.summary(of: project).available.map(\.service), ["web"])
        XCTAssertEqual(updates.summary(of: project).recreate, [], "it runs what its tag names")
        // Pulled in a terminal tab, say: the engine's events tell.
        fake.setRegistryDigest("nginx:1.27", digest("b"))
        guard let engine = model.engine else { return XCTFail("no engine") }
        for try await _ in engine.pull("nginx:1.27") {}
        XCTAssertFalse(model.isWanted(.images))
        let current = await eventually { updates.state(of: "nginx:1.27") == .current }
        XCTAssertTrue(current, "\(updates.local)")
        XCTAssertEqual(calls.count, 1, "no second question to its registry")
        let moved = await eventually { self.model.container(web)?.Image == old }
        XCTAssertTrue(moved, "listed by its image's ID: \(self.model.container(web)?.Image ?? "none")")
        let summary = updates.summary(of: model.projects.first ?? project)
        XCTAssertEqual(summary.recreate, ["web"], "web still runs the old image")
        XCTAssertTrue(summary.line { _ in "now" }?.contains("Pulled: Up recreates web") == true, summary.line { _ in "now" } ?? "")
    }

    /// A service its project's files build is the project's own: never
    /// asked about, from the project or from the Images section, and not
    /// in what the project says — though its tag has a repo digest.
    func testWhatAProjectBuildsIsntAsked() async throws {
        let api = fake.addImage("ghcr.io/acme/api:dev", size: 1, digest: digest("a"))
        fake.addImage("postgres:16", size: 1, digest: digest("c"))
        fake.add(name: "shop-api-1", image: "ghcr.io/acme/api:dev", project: "shop", workingDir: "/w/shop", service: "api", imageID: api)
        fake.add(name: "shop-db-1", image: "postgres:16", project: "shop", workingDir: "/w/shop", service: "db")
        let listed = await eventually { self.model.projects.first?.services.count == 2 }
        XCTAssertTrue(listed)
        let tool = try stub(
            try answering("ghcr.io/acme/api:dev", manifestAnswer("x", digest("b"))) + "\n" + (try answering("postgres:16", manifestAnswer("postgres:16", digest("c")))))
        let updates = makeUpdates(tool)
        guard let project = model.projects.first else { return XCTFail("no project") }
        XCTAssertEqual(updates.record(project, built: ["api"]), ["db": "postgres:16"])
        let outcome = await updates.check(Array(updates.references(of: project).values))
        XCTAssertEqual(calls, ["buildx imagetools inspect postgres:16"])
        XCTAssertEqual(outcome?.asked, 1)
        XCTAssertEqual(updates.summary(of: project).current.map(\.service), ["db"], "api isn't the registry's")
        XCTAssertEqual(updates.state(of: "ghcr.io/acme/api:dev"), .local)
        let here = (try await model.engine?.images()) ?? []
        let image = try XCTUnwrap(here.first { $0.Id == api })
        XCTAssertEqual(updates.uncheckable(image), "Its project's files build it: no registry to ask.")
        await updates.check(["ghcr.io/acme/api:dev", "postgres:16"])
        XCTAssertEqual(calls.filter { $0.contains("acme/api") }, [], "not from the Images section either")
        // A plan's files say what they build themselves.
        let web = ComposeConfig.Service(name: "web", image: "ghcr.io/acme/api:dev", buildContext: "/w/plan", dependsOn: [], profiles: [], ports: [], replicas: 1)
        let plan = ComposeProject(
            name: "plan", workingDir: "/w/plan", configFiles: [], services: [ComposeService(project: "plan", name: "web", containers: [], dependsOn: [], spec: web)],
            planned: true)
        XCTAssertEqual(updates.references(of: plan), [:])
        XCTAssertEqual(updates.record(plan), [:])
    }

    /// The containerd store records a repo digest for every named image,
    /// its own ID — a build's too. Asked, a tag built here comes back "not
    /// in its registry", not a failure; one whose registry has another
    /// image isn't an update until an answer has named the one here, and
    /// Pull Updates leaves it be.
    func testTheContainerdStoreRecordsADigestForEveryImage() async throws {
        fake.containerdStore = true
        defer { fake.containerdStore = false }
        let built = fake.addImage("shop-api:dev", size: 1)
        let local = fake.addImage("ghcr.io/acme/web:latest", size: 1)
        let pulled = fake.addImage("nginx:1.27", size: 1, digest: digest("a"))
        let images = (try await model.engine?.images()) ?? []
        XCTAssertEqual(images.first { $0.Id == built }?.RepoDigests, ["shop-api@" + built], "the fake records one as containerd does")
        XCTAssertEqual(pulled, digest("a"), "its ID is its index's digest")
        let anonymous = "ERROR: failed to authorize: failed to fetch anonymous token: unexpected status from GET request to https://auth.docker.io/token: 401 Unauthorized"
        let nginx = root.appendingPathComponent("nginx.txt")
        try manifestAnswer("nginx:1.27", digest("a")).write(to: nginx, atomically: true, encoding: .utf8)
        let tool = try stub(
            "\"buildx imagetools inspect shop-api:dev\") echo '\(anonymous)' >&2; exit 1 ;;\n"
                + (try answering("ghcr.io/acme/web:latest", manifestAnswer("x", digest("c")))) + "\n\"buildx imagetools inspect nginx:1.27\") cat \"\(nginx.path)\" ;;")
        let updates = makeUpdates(tool)
        let outcome = await updates.check(["shop-api:dev", "ghcr.io/acme/web:latest", "nginx:1.27"])
        XCTAssertEqual(outcome?.asked, 3, "nothing here says which were built")
        guard case .notInRegistry = updates.state(of: "shop-api:dev") else { return XCTFail("\(updates.state(of: "shop-api:dev"))") }
        XCTAssertEqual(updates.state(of: "ghcr.io/acme/web:latest"), .differs, "the registry's may be CI's, this one built here")
        XCTAssertEqual(updates.state(of: "nginx:1.27"), .current)
        let listed = (try await model.engine?.images()) ?? []
        XCTAssertEqual(updates.counts(of: listed), DockerImageUpdateCounts(differs: 1), "a build is no failure")
        XCTAssertEqual(updates.images(withUpdates: listed), [], "nothing to pull over a build")
        // nginx's answer named the one here: when its registry moves on,
        // that is an update.
        try manifestAnswer("nginx:1.27", digest("b")).write(to: nginx, atomically: true, encoding: .utf8)
        await updates.check(["nginx:1.27"])
        XCTAssertEqual(updates.state(of: "nginx:1.27"), .available)
        let page = DockerPageModel(docker: model, updates: updates)
        var commands: [String] = []
        page.actions = DockerActions(run: { command, _ in commands.append(command) }, confirm: { _, _, _, _ in }, open: { _ in }, copy: { _ in }, settings: {})
        page.pullUpdates(images: (try await model.engine?.images()) ?? [])
        XCTAssertEqual(Array(page.pulls.keys), ["nginx:1.27"], "only what came from the registry")
        XCTAssertEqual(commands, [])
        XCTAssertNil(page.verbs(for: try XCTUnwrap(listed.first { $0.Id == local })).first { $0.title.hasPrefix("Pull Update") })
    }

    /// Another registry's update is pulled in a tab, where the CLI signs
    /// in as it did for the check; Docker Hub's through the engine.
    func testAnotherRegistrysUpdateIsPulledInATab() async throws {
        fake.addImage("nginx:1.27", size: 1, digest: digest("a"))
        let private_ = fake.addImage("ghcr.io/acme/api:1", size: 1, digest: digest("c"))
        let tool = try stub(
            try answering("nginx:1.27", manifestAnswer("nginx:1.27", digest("b"))) + "\n"
                + (try answering("ghcr.io/acme/api:1", manifestAnswer("x", digest("d")))))
        let updates = makeUpdates(tool)
        await updates.check(["nginx:1.27", "ghcr.io/acme/api:1"])
        let page = DockerPageModel(docker: model, updates: updates)
        var commands: [(String, URL?)] = []
        page.actions = DockerActions(run: { commands.append(($0, $1)) }, confirm: { _, _, _, _ in }, open: { _ in }, copy: { _ in }, settings: {})
        let images = (try await model.engine?.images()) ?? []
        XCTAssertEqual(page.verbs(for: try XCTUnwrap(images.first { $0.Id == private_ })).first { $0.place == .button && $0.label == "Update" }?.title, "Pull Update in a Tab")
        page.pullUpdates(images: images)
        XCTAssertEqual(commands.map(\.0), ["docker pull ghcr.io/acme/api:1"])
        XCTAssertEqual(Array(page.pulls.keys), ["nginx:1.27"])
        XCTAssertEqual(DockerCommands.pull(["a:1", "b c"]), "docker pull a:1; docker pull 'b c'", "each tried")
    }

    /// Four at a time, never more: Docker Hub counts each.
    func testFourAtATime() async throws {
        var arms: [String] = []
        for index in 0..<9 {
            fake.addImage("ot/img\(index):1", size: 1, digest: digest(Character(String(index))))
            arms.append(
                "\"buildx imagetools inspect ot/img\(index):1\") mkdir -p \"\(root.path)/running\"; touch \"\(root.path)/running/$$\"; "
                    + "ls \"\(root.path)/running\" | wc -l >> \"\(root.path)/overlap\"; sleep 0.4; rm \"\(root.path)/running/$$\"; "
                    + "printf 'Digest:    \(digest(Character(String(index))))\\n' ;;")
        }
        let updates = makeUpdates(try stub(arms.joined(separator: "\n")), parallel: 4)
        let outcome = await updates.check((0..<9).map { "ot/img\($0):1" })
        XCTAssertEqual(outcome?.asked, 9)
        let overlap = ((try? String(contentsOf: root.appendingPathComponent("overlap"), encoding: .utf8)) ?? "").split(separator: "\n").compactMap {
            Int($0.trimmingCharacters(in: .whitespaces))
        }
        XCTAssertEqual(overlap.count, 9)
        XCTAssertEqual(overlap.max(), 4, "\(overlap)")
    }

    /// Stop: the questions on their way end, what was asked stays.
    func testStopEndsTheCheck() async throws {
        fake.addImage("nginx:1.27", size: 1, digest: digest("a"))
        let updates = makeUpdates(try stub("\"buildx imagetools inspect nginx:1.27\") sleep 20 ;;"))
        let started = Date()
        async let outcome = updates.check(["nginx:1.27"])
        let running = await eventually { !self.calls.isEmpty }
        XCTAssertTrue(running)
        let second = await updates.check(["nginx:1.27"])
        XCTAssertNil(second, "one at a time")
        updates.cancel()
        let result = await outcome
        XCTAssertEqual(result?.cancelled, true)
        XCTAssertLessThan(Date().timeIntervalSince(started), 10, "its process ended")
        XCTAssertEqual(updates.checks, [:])
        XCTAssertFalse(updates.running)
        XCTAssertNil(updates.lastRun)
        XCTAssertEqual(updates.state(of: "nginx:1.27"), .unchecked)
    }

    /// A registry that didn't answer isn't asked about its other tags.
    func testARegistryThatDidntAnswerIsAskedOnce() async throws {
        fake.addImage("ghcr.io/a/one:1", size: 1, digest: digest("a"))
        fake.addImage("ghcr.io/a/two:1", size: 1, digest: digest("b"))
        fake.addImage("nginx:1.27", size: 1, digest: digest("c"))
        let tool = try stub(
            "\"buildx imagetools inspect ghcr.io\"*) echo 'ERROR: dial tcp: lookup ghcr.io: i/o timeout' >&2; exit 1 ;;\n"
                + (try answering("nginx:1.27", manifestAnswer("nginx:1.27", digest("c")))))
        let updates = makeUpdates(tool, parallel: 1)
        let outcome = await updates.check(["ghcr.io/a/one:1", "ghcr.io/a/two:1", "nginx:1.27"])
        XCTAssertEqual(calls, ["buildx imagetools inspect ghcr.io/a/one:1", "buildx imagetools inspect nginx:1.27"])
        XCTAssertEqual(outcome?.asked, 2)
        XCTAssertEqual(updates.state(of: "ghcr.io/a/two:1"), .failed("ghcr.io didn't answer."))
        XCTAssertEqual(updates.done, 3)
    }

    /// The images gone: what was checked says so, the engine up.
    func testAnEmptyListIsTheEngines() async throws {
        let id = fake.addImage("nginx:1.27", size: 1, digest: digest("a"))
        let updates = makeUpdates(try stub(try answering("nginx:1.27", manifestAnswer("nginx:1.27", digest("b")))))
        await updates.check(["nginx:1.27"])
        XCTAssertEqual(updates.state(of: "nginx:1.27"), .available)
        try await model.engine?.remove(image: id, force: true)
        model.load(.images)
        let gone = await eventually { updates.local.isEmpty }
        XCTAssertTrue(gone, "\(updates.local)")
        XCTAssertEqual(updates.state(of: "nginx:1.27"), .local)
        XCTAssertTrue(DockerMCP.describeUpdates(updates, docker: model).contains("nginx:1.27: no longer here"))
    }

    /// The header says what wasn't checked: one image's answer isn't the
    /// list's.
    func testAPartialCheckIsntTheList() async throws {
        for index in 0..<3 { fake.addImage("ot/img\(index):1", size: 1, digest: digest(Character(String(index)))) }
        fake.addImage("ot/built:dev", size: 1)
        let updates = makeUpdates(try stub(try answering("ot/img0:1", manifestAnswer("x", digest("0")))))
        await updates.check(["ot/img0:1"])
        let images = (try await model.engine?.images()) ?? []
        XCTAssertEqual(updates.counts(of: images), DockerImageUpdateCounts(unchecked: 2))
        XCTAssertEqual(DockerImageUpdates.headline(updates.counts(of: images)), "No updates · 2 not checked")
    }

    /// The panel's Check for Updates says what it couldn't do on the
    /// panel's own line, not on a page that isn't on screen.
    func testThePanelHearsWhatItsCheckSays() async throws {
        let page = DockerPageModel(docker: model, updates: DockerImageUpdates(docker: model, cli: { _ in nil }))
        let spec = ComposeConfig.Service(name: "web", image: "nginx:1.27", dependsOn: [], profiles: [], ports: [], replicas: 1)
        let plan = ComposeProject(
            name: "plan", workingDir: "/w/plan", configFiles: [], services: [ComposeService(project: "plan", name: "web", containers: [], dependsOn: [], spec: spec)],
            planned: true)
        var said: [String] = []
        page.verbs(for: plan, report: { said.append($0) }).first { $0.title == "Check for Updates" }?.perform()
        let heard = await eventually { !said.isEmpty }
        XCTAssertTrue(heard)
        XCTAssertTrue(said.first?.hasPrefix("Check for Updates: ") == true, "\(said)")
        XCTAssertNil(page.error)
    }

    func testWithNoCLINothingIsAsked() async {
        fake.addImage("nginx:1.27", size: 1, digest: digest("a"))
        let updates = DockerImageUpdates(docker: model, cli: { _ in nil })
        let outcome = await updates.check(["nginx:1.27"])
        XCTAssertNotNil(outcome?.failure)
        XCTAssertEqual(updates.checks, [:])
        XCTAssertFalse(updates.running)
    }
}
