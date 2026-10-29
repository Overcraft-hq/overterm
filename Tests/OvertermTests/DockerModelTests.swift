import Combine
import Foundation
import XCTest

@testable import Overterm

/// The app's Docker model against the fake engine: what it lists and how it
/// groups it, kept current by events, an engine that goes and comes back.
@MainActor
final class DockerModelTests: XCTestCase {
    private var fake: FakeDockerEngine!
    private var model: DockerModel!
    private var socket = ""

    override func setUp() async throws {
        socket = "/tmp/ot-docker-\(UUID().uuidString.prefix(8)).sock"
        fake = FakeDockerEngine(socket: socket)
        try fake.start()
        let endpoint = DockerEndpoint(address: .unix(socket), context: nil, source: "test")
        model = DockerModel(endpoint: { endpoint }, retries: [.milliseconds(50)], poll: .milliseconds(200))
    }

    override func tearDown() async throws {
        model.stop()
        fake.stop()
    }

    private func eventually(_ what: String, timeout: TimeInterval = 5, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("timed out: \(what)")
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func shop(in folder: String = "/Users/me/shop") {
        fake.add(name: "shop-web-1", project: "shop", workingDir: folder, service: "web")
        fake.add(name: "shop-db-1", image: "postgres:16", project: "shop", workingDir: folder, service: "db", health: "healthy")
        fake.add(name: "redis", image: "redis:7")
    }

    func testItListsAndGroups() async throws {
        shop()
        model.start()
        try await eventually("three containers") { model.containers.count == 3 }
        XCTAssertEqual(model.connection, .running("1.47"))
        XCTAssertEqual(model.info?.ServerVersion, "29.0.0")
        XCTAssertEqual(model.projects.map(\.name), ["shop"])
        XCTAssertEqual(model.projects.first?.services.map(\.name), ["db", "web"])
        XCTAssertEqual(model.projects.first?.status, .running)
        XCTAssertEqual(model.loose.map(\.name), ["redis"])
        XCTAssertEqual(model.container("shop-db-1")?.health, "healthy")
    }

    func testEventsKeepItCurrent() async throws {
        shop()
        var heard: [String] = []
        let listening = model.events.sink { heard.append($0.verb) }
        defer { listening.cancel() }
        model.start()
        try await eventually("listed") { model.containers.count == 3 }
        try await eventually("listening") { fake.listening == 1 }
        let db = try XCTUnwrap(model.container("shop-db-1")).Id
        fake.set(db, state: .exited, exitCode: 1)
        try await eventually("the exit seen") { model.container(db)?.state == .exited }
        XCTAssertEqual(model.projects.first?.status, .partial)
        XCTAssertEqual(model.projects.first?.failing.map(\.name), ["shop-db-1"])
        XCTAssertEqual(heard, ["die"])
        fake.add(name: "new-one")
        try await eventually("a new container") { model.container("new-one") != nil }
        XCTAssertEqual(heard, ["die", "create"])
    }

    func testAnEngineThatGoesAwayIsRetried() async throws {
        shop()
        model.start()
        try await eventually("listed") { model.containers.count == 3 }
        fake.stop()
        try await eventually("down") {
            if case .down = model.connection { return true }
            return false
        }
        XCTAssertTrue(model.containers.isEmpty, "a stopped engine's containers aren't shown as if they were there")
        XCTAssertTrue(model.projects.isEmpty)
        try fake.start()
        try await eventually("back") { model.connection.isRunning && model.containers.count == 3 }
    }

    func testAnActionShowsAtOnce() async throws {
        shop()
        model.start()
        try await eventually("listed") { model.containers.count == 3 }
        let web = try XCTUnwrap(model.container("shop-web-1")).Id
        try await model.perform(.stop, on: web)
        XCTAssertEqual(model.container(web)?.state, .exited)
        do {
            try await model.remove(try XCTUnwrap(model.container("redis")).Id)
            XCTFail("a running container needs force")
        } catch let error as DockerError {
            XCTAssertEqual(error.status, 409)
        }
        try await model.remove(try XCTUnwrap(model.container("redis")).Id, force: true)
        XCTAssertNil(model.container("redis"))
    }

    /// A database's own client: who to sign in as read from its inspect by
    /// name, and only when asked; a stopped one's says why it can't.
    func testAClientSignsInByItsEnvsNames() async throws {
        fake.add(name: "shop-db-1", image: "postgres:16", env: ["POSTGRES_USER=shop", "POSTGRES_PASSWORD=hunter2"])
        fake.add(name: "old-db", image: "postgres:16", state: .exited)
        model.start()
        try await eventually("listed") { model.containers.count == 2 }
        let db = try XCTUnwrap(model.container("shop-db-1"))
        let old = try XCTUnwrap(model.container("old-db"))
        let page = DockerPageModel(docker: model)
        var ran: [String] = []
        page.actions = DockerActions(run: { command, _ in ran.append(command) }, confirm: { _, _, _, _ in }, open: { _ in }, copy: { _ in }, settings: {})
        let expected = #"docker exec -it shop-db-1 sh -c 'export PGPASSWORD="$POSTGRES_PASSWORD"; exec psql -U "$POSTGRES_USER" -d "$POSTGRES_USER"'"#
        page.openClient(db)
        try await eventually("psql in a tab") { ran == [expected] }
        XCTAssertFalse(ran.contains { $0.contains("hunter2") }, "no secret on the tab's command line")
        page.openClient(old)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(ran.count, 1, "a stopped one opens nothing")
        let verb = page.verbs(for: old).first { $0.title == "Open psql in a Tab" }
        XCTAssertEqual(verb?.place, .button)
        XCTAssertEqual(verb?.label, "psql")
        XCTAssertEqual(verb?.unavailable, "It isn't running.")
        let live = try XCTUnwrap(page.verbs(for: db).first { $0.key == "q" })
        XCTAssertNil(live.unavailable)
    }

    /// A pull moved its tag on to a newer image: Docker lists the image by
    /// its ID. Its client is known still by the name inspect keeps — read
    /// when q is pressed, or already by its open detail, never to draw.
    func testAnImageListedByItsIDKeepsItsClient() async throws {
        let id = fake.add(name: "shop-db-1", image: "postgres:16", ports: [DockerPort(IP: "0.0.0.0", PrivatePort: 5432, PublicPort: 55432, Type: "tcp")])
        fake.supersedeImage(of: id)
        model.start()
        try await eventually("listed by its ID") { model.container(id)?.Image.hasPrefix("sha256:") == true }
        let db = try XCTUnwrap(model.container(id))
        let page = DockerPageModel(docker: model)
        var ran: [String] = []
        page.actions = DockerActions(run: { command, _ in ran.append(command) }, confirm: { _, _, _, _ in }, open: { _ in }, copy: { _ in }, settings: {})
        XCTAssertNil(DockerClient.kind(of: db), "the ID says nothing")
        XCTAssertFalse(page.verbs(for: db).contains { $0.key == "q" || $0.key == "d" }, "inspect isn't read to draw")
        page.selection = [id]
        XCTAssertTrue(page.press("q"))
        try await eventually("q reads inspect, then opens psql") { ran == ["docker exec -it shop-db-1 psql -U postgres -d postgres"] }
        let session = page.session(for: id)
        try await eventually("its detail read") { session.detail != nil }
        XCTAssertEqual(page.verbs(for: db).first { $0.key == "q" }?.label, "psql", "its open detail names it")
        XCTAssertTrue(page.verbs(for: db).contains { $0.key == "d" }, "and Open in Database")
        let panel = DockerPageModel(docker: model)
        XCTAssertEqual(panel.verbs(for: db, detail: session.detail).first { $0.key == "q" }?.label, "psql", "or the panel's, given")
        XCTAssertNil(panel.verbs(for: db, detail: nil).first { $0.key == "q" })
    }

    /// Off the page — its verb in the panel's menu, or the right-hand
    /// pane — a client that can't be opened says so in an alert too.
    func testAClientThatCantOpenSaysWhyOffThePage() async throws {
        let id = fake.add(name: "shop-db-1", image: "postgres:16")
        model.start()
        try await eventually("listed") { model.container(id) != nil }
        let db = try XCTUnwrap(model.container(id))
        try await model.remove(id, force: true)
        let page = DockerPageModel(docker: model)
        var ran: [String] = []
        var alerts: [String] = []
        page.actions = DockerActions(run: { command, _ in ran.append(command) }, confirm: { _, _, _, _ in }, open: { _ in }, copy: { _ in }, settings: {})
        page.actions?.alert = { title, _ in alerts.append(title) }
        page.openClient(db)
        try await eventually("an alert") { alerts == ["psql in shop-db-1"] }
        XCTAssertEqual(page.error?.hasPrefix("psql in shop-db-1: "), true)
        XCTAssertEqual(ran, [], "nothing typed")
        page.visible = true
        page.error = nil
        page.openClient(db)
        try await eventually("on the page") { page.error != nil }
        XCTAssertEqual(alerts.count, 1, "on screen, the page says it")
    }

    /// Compose writes the folder resolved (`/private/var/…`); the tab's
    /// folder may not be.
    func testACheckoutsProjectsAreFoundByItsRealPath() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ot-checkout-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("api"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let real = FileTreeModel.realPath(folder)
        XCTAssertNotEqual(real, folder.path, "the temporary folder is behind /var → /private/var")
        shop(in: real + "/api")
        fake.add(name: "other-web-1", project: "other", workingDir: "/Users/me/other", service: "web")
        model.start()
        try await eventually("listed") { model.containers.count == 4 }
        XCTAssertEqual(model.projects(in: folder).map(\.name), ["shop"])
        XCTAssertEqual(model.projects(in: URL(fileURLWithPath: "/Users/me")).map(\.name), ["other"])
    }

    private let tc = ["org.testcontainers": "true", "org.testcontainers.lang": "java", "org.testcontainers.version": "1.21.3"]

    /// Testcontainers' containers are their runs', not the list's: a test's
    /// compose stack (Go's compose module) isn't the checkout's.
    func testTestcontainersAreTakenOutOfTheList() async throws {
        shop()
        fake.add(name: "tc-pg", image: "postgres:16-alpine", labels: tc.merging(["org.testcontainers.sessionId": "A"]) { $1 })
        fake.add(name: "testcontainers-ryuk-A", image: "testcontainers/ryuk:0.14.0", labels: tc)
        fake.add(
            name: "tc-stack-db-1", project: "tc-stack", workingDir: "/Users/me/shop/src/test", service: "db",
            labels: ["org.testcontainers": "true", "org.testcontainers.lang": "go", "org.testcontainers.sessionId": "B"])
        model.start()
        try await eventually("listed") { model.containers.count == 6 }
        XCTAssertEqual(model.projects.map(\.name), ["shop"])
        XCTAssertEqual(model.loose.map(\.name), ["redis"])
        XCTAssertEqual(Set(model.testcontainers.map(\.id)), ["A", "B"])
        XCTAssertEqual(model.testcontainers.first { $0.id == "A" }?.reaper?.name, "testcontainers-ryuk-A")
        XCTAssertEqual(model.projects(in: URL(fileURLWithPath: "/Users/me/shop")).map(\.name), ["shop"], "no tc-stack in the checkout's stack")
        model.stop()
        XCTAssertTrue(model.testcontainers.isEmpty)
    }

    /// Remove All, as Ryuk does it when a run ends: the containers with
    /// their anonymous volumes, then the networks, volumes and images
    /// labelled with the session, Ryuk last; another run's and the rest
    /// stay.
    func testRemoveAllTakesARunsContainersNetworksVolumesImagesAndRyukLast() async throws {
        let session = tc.merging(["org.testcontainers.sessionId": "A"]) { $1 }
        let other = tc.merging(["org.testcontainers.sessionId": "B"]) { $1 }
        let pg = fake.add(name: "tc-pg", image: "postgres:16-alpine", labels: session, created: 100)
        let kafka = fake.add(name: "tc-kafka", image: "confluentinc/cp-kafka:7.6.0", labels: session, created: 110)
        let ryuk = fake.add(name: "testcontainers-ryuk-A", image: "testcontainers/ryuk:0.14.0", labels: tc, created: 90)
        fake.addNetwork("tc-net", labels: session)
        fake.addNetwork("keep")
        fake.addVolume("tc-data", size: 1 << 20, refCount: 0, labels: session)
        fake.addVolume("tc-other-run", size: 1 << 20, refCount: 0, labels: other)
        fake.addVolume("keep-data", size: 1 << 20, refCount: 0)
        let built = fake.addImage("localhost/testcontainers/0f1e2d3c4b5a6978:latest", size: 5 << 20, labels: session)
        let otherBuilt = fake.addImage("localhost/testcontainers/aaaabbbbccccdddd:latest", size: 5 << 20, labels: other)
        let pulled = fake.addImage("postgres:16-alpine", size: 90 << 20)
        model.start()
        try await eventually("the run listed") { model.testcontainers.first?.containers.count == 3 }
        let page = DockerPageModel(docker: model)
        page.remove(session: model.testcontainers[0])
        XCTAssertTrue(page.busy.contains(DockerPageModel.sessionTag("A")), "busy while it goes")
        try await eventually("all of it gone") { page.busy.isEmpty }
        XCTAssertNil(fake.summary(pg))
        XCTAssertNil(fake.summary(kafka))
        XCTAssertNil(fake.summary(ryuk))
        XCTAssertEqual(fake.networkNames, ["keep"])
        XCTAssertEqual(Set(fake.volumeNames), ["tc-other-run", "keep-data"])
        XCTAssertEqual(Set(fake.imageIDs), [otherBuilt, pulled])
        let requests = fake.requests
        XCTAssertTrue(requests.contains("DELETE /v1.47/containers/\(pg)?force=1&v=1"), "\(requests.filter { $0.hasPrefix("DELETE") })")
        func index(_ prefix: String) -> Int { requests.firstIndex { $0.hasPrefix("DELETE /v1.47/" + prefix) } ?? -1 }
        XCTAssertGreaterThan(index("networks/"), index("containers/\(pg)"), "the containers first")
        XCTAssertGreaterThan(index("networks/"), index("containers/\(kafka)"))
        XCTAssertGreaterThan(index("volumes/tc-data"), index("networks/"), "then the networks, the volumes, the images")
        XCTAssertGreaterThan(index("images/\(built)"), index("volumes/tc-data"))
        XCTAssertGreaterThan(index("containers/\(ryuk)"), index("images/\(built)"), "Ryuk last")
        for list in ["networks", "volumes", "images/json"] {
            XCTAssertEqual(requests.filter { $0.hasPrefix("GET /v1.47/" + list) }.count, 1, "\(list) read once")
        }
        XCTAssertNil(page.error)
        XCTAssertTrue(model.testcontainers.isEmpty)
    }

    /// What won't go keeps Ryuk, which still removes it when the run ends;
    /// the page says what, and how many more.
    func testRemoveAllKeepsRyukWhenSomethingWontGo() async throws {
        let session = tc.merging(["org.testcontainers.sessionId": "A"]) { $1 }
        let pg = fake.add(name: "tc-pg", labels: session, created: 100)
        let stuck = fake.add(name: "tc-x", labels: session, created: 110)
        let ryuk = fake.add(name: "testcontainers-ryuk-A", image: "testcontainers/ryuk:0.14.0", labels: tc, created: 90)
        fake.addVolume("tc-data", size: 0, refCount: 1, labels: session)
        fake.refuseRemoval(of: "tc-x", 500, "could not kill container: tried to kill container, but did not receive an exit event")
        fake.refuseRemoval(of: "tc-data", 409, "remove tc-data: volume is in use - [\(stuck)]")
        model.start()
        try await eventually("the run listed") { model.testcontainers.first?.containers.count == 3 }
        let page = DockerPageModel(docker: model)
        page.remove(session: model.testcontainers[0])
        try await eventually("done") { page.busy.isEmpty }
        XCTAssertNil(fake.summary(pg), "what could go went")
        XCTAssertNotNil(fake.summary(stuck))
        XCTAssertNotNil(fake.summary(ryuk), "Ryuk kept, to remove the rest when the run ends")
        XCTAssertFalse(fake.requests.contains { $0.hasPrefix("DELETE /v1.47/containers/\(ryuk)") }, "not even asked")
        XCTAssertEqual(
            page.error, "Remove All: tc-x: could not kill container: tried to kill container, but did not receive an exit event (and 1 more)")
        XCTAssertEqual(model.testcontainers.first?.containers.map(\.name), ["tc-x", "testcontainers-ryuk-A"])
    }

    /// Ryuk's own removal racing ours: a container's "already in progress",
    /// or a volume gone, is one removed, and Ryuk still goes last.
    func testRemoveAllCountsARemovalAlreadyInProgressAsDone() async throws {
        let session = tc.merging(["org.testcontainers.sessionId": "A"]) { $1 }
        let pg = fake.add(name: "tc-pg", labels: session, created: 100)
        let ryuk = fake.add(name: "testcontainers-ryuk-A", image: "testcontainers/ryuk:0.14.0", labels: tc, created: 90)
        fake.addVolume("tc-data", size: 0, refCount: 0, labels: session)
        fake.refuseRemoval(of: pg, 409, "removal of container \(pg) is already in progress")
        fake.refuseRemoval(of: "tc-data", 404, "get tc-data: no such volume")
        model.start()
        try await eventually("the run listed") { model.testcontainers.first?.containers.count == 2 }
        let page = DockerPageModel(docker: model)
        page.remove(session: model.testcontainers[0])
        try await eventually("done") { page.busy.isEmpty }
        XCTAssertNil(page.error, "\(page.error ?? "")")
        XCTAssertNil(fake.summary(ryuk), "Ryuk still last")
    }

    /// One gone before its turn (Ryuk's own AutoRemove) counts as removed.
    func testRemoveAllCountsAContainerAlreadyGoneAsRemoved() async throws {
        let pg = fake.add(name: "tc-pg", labels: tc.merging(["org.testcontainers.sessionId": "A"]) { $1 })
        model.start()
        try await eventually("the run listed") { model.testcontainers.count == 1 }
        var session = model.testcontainers[0]
        session.containers.append(
            ContainerSummary(
                Id: "0badc0ffee", Names: ["/tc-gone"], Image: "redis:7", Created: 1, Labels: tc.merging(["org.testcontainers.sessionId": "A"]) { $1 },
                State: "running", Status: "Up 1 minute"))
        let page = DockerPageModel(docker: model)
        page.remove(session: session)
        try await eventually("done") { page.busy.isEmpty }
        XCTAssertNil(fake.summary(pg))
        XCTAssertTrue(fake.requests.contains("DELETE /v1.47/containers/0badc0ffee?force=1&v=1"))
        XCTAssertNil(page.error, "a 404 is a container gone")
    }

    /// An image's platform is read when something asks for it, once an
    /// id, never at a reload; an image event makes what asks ask again.
    func testPlatformsAreReadForWhatAsksAndOnce() async throws {
        let amd = fake.addImage("legacy:1", size: 1, architecture: "amd64")
        let arm = fake.addImage("fresh:1", size: 1)
        fake.add(name: "old", image: "legacy:1", imageID: amd)
        fake.add(name: "new", image: "fresh:1", imageID: arm)
        fake.add(name: "lost", image: "gone:1", imageID: "sha256:" + String(repeating: "c", count: 64))
        model.start()
        try await eventually("listed") { model.containers.count == 3 }
        XCTAssertEqual(model.enginePlatform?.description, "linux/arm64")
        func inspects() -> Int { fake.requests.filter { $0.contains("/images/sha256:") && $0.hasSuffix("/json") }.count }
        XCTAssertEqual(inspects(), 0, "nothing asked, nothing read")
        let old = try XCTUnwrap(model.container("old"))
        let new = try XCTUnwrap(model.container("new"))
        let lost = try XCTUnwrap(model.container("lost"))
        model.wantPlatform(of: amd)
        model.wantPlatform(of: arm)
        model.wantPlatform(of: amd)
        try await eventually("both read") { model.platforms.count == 2 }
        XCTAssertEqual(model.emulation(of: old)?.image.short, "amd64")
        XCTAssertNil(model.emulation(of: new))
        XCTAssertEqual(inspects(), 2)
        await model.reload()
        await model.reload()
        model.wantPlatform(of: amd)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(inspects(), 2, "once an id")
        model.wantPlatform(of: lost.ImageID)
        model.wantPlatform(of: lost.ImageID)
        try await eventually("a miss read") { inspects() == 3 }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(inspects(), 3, "a miss isn't read twice")
        XCTAssertNil(model.emulation(of: lost))

        // Its arm64 variant pulled: an image event, and what asks again is read again.
        try await eventually("listening") { fake.listening == 1 }
        let epoch = model.platformEpoch
        for try await _ in try XCTUnwrap(model.engine).pull("legacy:1", platform: "linux/arm64") {}
        try await eventually("the epoch moved on") { model.platformEpoch > epoch }
        model.wantPlatform(of: amd)
        try await eventually("read again") { inspects() == 4 }
        XCTAssertEqual(model.emulation(of: old)?.image.short, "amd64", "it was made from the old image, which is still amd64")
        model.stop()
        XCTAssertTrue(model.platforms.isEmpty)
    }

    /// An agent waits for the platforms it asks about; what is known isn't
    /// read again.
    func testAnAgentReadsThePlatformsItAsksAbout() async throws {
        let amd = fake.addImage("legacy:1", size: 1, architecture: "amd64")
        fake.add(name: "old", image: "legacy:1", imageID: amd)
        model.start()
        try await eventually("listed") { model.containers.count == 1 }
        let read = await model.readPlatforms(of: [amd, "sha256:nope"])
        XCTAssertEqual(read[amd]?.short, "amd64")
        XCTAssertEqual(read.count, 1)
        _ = await model.readPlatforms(of: [amd, "sha256:nope"])
        XCTAssertEqual(fake.requests.filter { $0.contains("/images/sha256:") }.count, 2, "each read once")
    }

    /// An emulated compose service's verb: whose files can't be read here
    /// recreated alone with --build, nothing pulled, in a tab in its
    /// folder; a native one has none. An image's own pulls through the
    /// engine.
    func testAnEmulatedContainersVerbsRunItNatively() async throws {
        let amd = fake.addImage("legacy:1", size: 1, architecture: "amd64")
        let arm = fake.addImage("fresh:1", size: 1)
        fake.add(name: "shop-api-1", image: "legacy:1", project: "shop", workingDir: "/w/shop", service: "api", imageID: amd)
        fake.add(name: "new", image: "fresh:1", imageID: arm)
        model.start()
        try await eventually("listed") { model.containers.count == 2 }
        let page = DockerPageModel(docker: model)
        var ran: [(String, URL?)] = []
        page.actions = DockerActions(run: { ran.append(($0, $1)) }, confirm: { _, _, _, _ in }, open: { _ in }, copy: { _ in }, settings: {})
        let api = try XCTUnwrap(model.container("shop-api-1"))
        let new = try XCTUnwrap(model.container("new"))
        XCTAssertFalse(page.verbs(for: api).contains { $0.title.contains("arm64") }, "nothing known, nothing offered")
        model.wantPlatform(of: amd)
        model.wantPlatform(of: arm)
        try await eventually("read") { model.platforms.count == 2 }
        let verb = try XCTUnwrap(page.verbs(for: api).first { $0.title == "Recreate as arm64 in a Tab" })
        XCTAssertEqual(verb.place, .more)
        XCTAssertNil(verb.unavailable)
        XCTAssertTrue(verb.note?.contains("built again, if its compose file builds it") == true, verb.note ?? "no note")
        verb.perform()
        try await eventually("typed") { !ran.isEmpty }
        XCTAssertEqual(
            ran.last?.0, "DOCKER_DEFAULT_PLATFORM=linux/arm64 docker compose -p shop -f /w/shop/compose.yaml up -d --no-deps --force-recreate --build api",
            "its files not on this Mac: not known whether it is built, nothing pulled")
        XCTAssertEqual(ran.last?.1?.path, "/w/shop")
        XCTAssertFalse(page.verbs(for: new).contains { $0.title.contains("arm64") })

        let image = ImageSummary(Id: amd, RepoTags: ["legacy:1"], Created: 1, Size: 1)
        let pull = try XCTUnwrap(page.verbs(for: image).first { $0.title == "Pull the arm64 Variant" })
        pull.perform()
        try await eventually("pulled") { page.pulls["legacy:1 (linux/arm64)"]?.done == true }
        XCTAssertNil(page.pulls["legacy:1 (linux/arm64)"]?.error)
        XCTAssertTrue(fake.requests.contains { $0.contains("/images/create?") && $0.contains("platform=linux/arm64") })
        XCTAssertFalse(page.verbs(for: ImageSummary(Id: arm, RepoTags: ["fresh:1"], Created: 1, Size: 1)).contains { $0.title.contains("Variant") })
    }

    /// What a service's files build is theirs to say, not its image's name:
    /// one with build: and an image: name is built again, never pulled from
    /// a registry; another is pulled, then recreated. The verb waits for
    /// the files' answer.
    func testAServiceItsFilesBuildIsBuiltAgain() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ot-built-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.path
        try "services:\n  api:\n    build: .\n    image: ghcr.io/org/api:dev\n  db:\n    image: legacy:1\n"
            .write(to: root.appendingPathComponent("compose.yaml"), atomically: true, encoding: .utf8)
        let config = #"{"name":"shop","services":{"api":{"build":{"context":"\#(folder)"},"image":"ghcr.io/org/api:dev"},"db":{"image":"legacy:1"}}}"#
        let stub = root.appendingPathComponent("docker")
        try "#!/bin/sh\ncase \"$*\" in\n*\" config --format json\"*) echo '\(config)' ;;\n*\" config --profiles\"*) ;;\n*) exit 1 ;;\nesac\n"
            .write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        DockerCLI.override = stub
        defer { DockerCLI.override = nil }
        let built = fake.addImage("ghcr.io/org/api:dev", size: 1, architecture: "amd64")
        let pulled = fake.addImage("legacy:1", size: 1, architecture: "amd64")
        fake.add(name: "shop-api-1", image: "ghcr.io/org/api:dev", project: "shop", workingDir: folder, service: "api", imageID: built)
        fake.add(name: "shop-db-1", image: "legacy:1", project: "shop", workingDir: folder, service: "db", imageID: pulled)
        model.start()
        try await eventually("listed") { model.containers.count == 2 }
        await model.readPlatforms(for: model.containers)
        let page = DockerPageModel(docker: model)
        var ran: [(String, URL?)] = []
        page.actions = DockerActions(run: { ran.append(($0, $1)) }, confirm: { _, _, _, _ in }, open: { _ in }, copy: { _ in }, settings: {})
        let api = try XCTUnwrap(model.container("shop-api-1"))
        let db = try XCTUnwrap(model.container("shop-db-1"))

        // At once, before the files have answered: the verb waits for them.
        let early = try XCTUnwrap(page.verbs(for: db).first { $0.symbol == "cpu" })
        XCTAssertEqual(early.title, "Recreate as arm64 in a Tab")
        early.perform()
        try await eventually("typed") { ran.count == 1 }
        let files = "docker compose -p shop -f \(folder)/compose.yaml"
        XCTAssertEqual(
            ran.last?.0, "docker pull --platform linux/arm64 legacy:1 && DOCKER_DEFAULT_PLATFORM=linux/arm64 \(files) up -d --no-deps --force-recreate db",
            "pulled, as its files say")
        XCTAssertEqual(ran.last?.1?.path, folder)
        XCTAssertEqual(page.composeFacts["shop"]?.built, ["api"])

        let rebuild = try XCTUnwrap(page.verbs(for: api).first { $0.title == "Rebuild as arm64 in a Tab" }, "\(page.verbs(for: api).map(\.title))")
        XCTAssertTrue(rebuild.note?.contains("Compose built it for amd64") == true, rebuild.note ?? "no note")
        rebuild.perform()
        try await eventually("typed") { ran.count == 2 }
        XCTAssertEqual(ran.last?.0, "DOCKER_DEFAULT_PLATFORM=linux/arm64 \(files) up -d --no-deps --force-recreate --build api", "built again, nothing pulled")
    }

    /// The containerd image store before API 1.48: an image's id is its
    /// index, whose inspect says arm64 once a pull adds it. A container
    /// made before still runs amd64 — kept to what its image said first —
    /// while the image now says arm64; one made after runs arm64.
    func testAContainerKeepsThePlatformItWasMadeFor() async throws {
        fake.containerdStore = true
        let index = fake.addImage("legacy:1", size: 1, architecture: "amd64")
        fake.add(name: "old", image: "legacy:1", imageID: index)
        model.start()
        try await eventually("listed") { model.containers.count == 1 }
        let old = try XCTUnwrap(model.container("old"))
        XCTAssertNil(old.ownPlatform, "API 1.47 says none")
        XCTAssertEqual(model.platformKey(of: old), model.platformKey(index), "not known yet: the image's, with its epoch")
        model.wantPlatform(of: old)
        try await eventually("read") { model.emulation(of: old) != nil }
        XCTAssertEqual(model.platformKey(of: old), old.Id, "known for good: no epoch")

        try await eventually("listening") { fake.listening == 1 }
        let epoch = model.platformEpoch
        for try await _ in try XCTUnwrap(model.engine).pull("legacy:1", platform: "linux/arm64") {}
        try await eventually("the epoch moved on") { model.platformEpoch > epoch }
        let images = try await XCTUnwrap(model.engine).images()
        XCTAssertEqual(images.filter { $0.tags.contains("legacy:1") }.map(\.Id), [index], "the same index")
        // The image's row asks again; the container's doesn't.
        model.wantPlatform(of: old)
        model.wantPlatform(of: index)
        try await eventually("the image read again") { model.platforms[index]?.architecture == "arm64" }
        XCTAssertNil(model.emulation(ofImage: index), "its index holds arm64 now")
        XCTAssertEqual(model.emulation(of: try XCTUnwrap(model.container("old")))?.image.short, "amd64", "made before: still amd64")
        let platform = await model.readPlatforms(of: [index])
        XCTAssertEqual(platform[index]?.short, "arm64")

        fake.add(name: "new", image: "legacy:1", imageID: index)
        try await eventually("the new one listed") { model.container("new") != nil }
        let new = try XCTUnwrap(model.container("new"))
        XCTAssertNil(model.emulation(of: new), "made after: arm64")
        XCTAssertEqual(model.platformKey(of: new), new.Id, "kept to what its image said, read since the last image event")
        XCTAssertEqual(model.emulation(of: try XCTUnwrap(model.container("old")))?.image.short, "amd64")
    }

    /// From API 1.48 a container in the containerd store says what it
    /// runs: nothing is read for it, and a pull into its image's index
    /// changes nothing. Every other call keeps its version.
    func testAContainerSaysWhatItRunsFromAPI148() async throws {
        fake.containerdStore = true
        fake.apiVersion = "1.51"
        let index = fake.addImage("legacy:1", size: 1, architecture: "amd64")
        fake.add(name: "old", image: "legacy:1", imageID: index)
        model.start()
        try await eventually("listed") { model.containers.count == 1 }
        XCTAssertEqual(model.connection, .running("1.47"))
        XCTAssertTrue(fake.requests.contains("GET /v1.48/containers/json?all=1"), "\(fake.requests)")
        let old = try XCTUnwrap(model.container("old"))
        XCTAssertEqual(old.ownPlatform?.description, "linux/amd64")
        XCTAssertEqual(model.emulation(of: old)?.image.short, "amd64")
        XCTAssertEqual(model.platformKey(of: old), old.Id)
        model.wantPlatform(of: old)
        await model.readPlatforms(for: [old])
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(fake.requests.contains { $0.contains("/images/") }, "nothing to read: \(fake.requests)")
        for try await _ in try XCTUnwrap(model.engine).pull("legacy:1", platform: "linux/arm64") {}
        await model.reload()
        XCTAssertEqual(model.emulation(of: try XCTUnwrap(model.container("old")))?.image.short, "amd64")
    }

    /// An agent asking for a platform a view's read has on its way waits
    /// for that read, rather than answering without it — and doesn't read
    /// it again.
    func testAnAgentWaitsForAReadOnItsWay() async throws {
        let amd = fake.addImage("legacy:1", size: 1, architecture: "amd64")
        fake.add(name: "old", image: "legacy:1", imageID: amd)
        model.start()
        try await eventually("listed") { model.containers.count == 1 }
        fake.imageInspectDelay = 300
        func inspects() -> Int { fake.requests.filter { $0.hasSuffix("/images/\(amd)/json") }.count }
        model.wantPlatform(of: amd)
        try await eventually("on its way") { inspects() == 1 }
        XCTAssertTrue(model.platforms.isEmpty, "not answered yet")
        let read = await model.readPlatforms(of: [amd])
        XCTAssertEqual(read[amd]?.short, "amd64", "waited for it")
        XCTAssertEqual(inspects(), 1, "read once")
        await model.readPlatforms(for: model.containers)
        XCTAssertNotNil(model.emulation(of: try XCTUnwrap(model.container("old"))))
        XCTAssertEqual(inspects(), 1)
    }

    /// An Intel engine emulates arm64 images.
    func testAnIntelEngineEmulatesArm() async throws {
        fake.architecture = "x86_64"
        let arm = fake.addImage("fresh:1", size: 1)
        let amd = fake.addImage("legacy:1", size: 1, architecture: "amd64")
        fake.add(name: "new", image: "fresh:1", imageID: arm)
        fake.add(name: "old", image: "legacy:1", imageID: amd)
        model.start()
        try await eventually("listed") { model.containers.count == 2 }
        XCTAssertEqual(model.enginePlatform?.short, "amd64")
        model.wantPlatform(of: arm)
        model.wantPlatform(of: amd)
        try await eventually("read") { model.platforms.count == 2 }
        XCTAssertEqual(model.emulation(of: try XCTUnwrap(model.container("new")))?.image.short, "arm64")
        XCTAssertNil(model.emulation(of: try XCTUnwrap(model.container("old"))))
    }

    func testNoEndpointIsOff() async throws {
        let off = DockerModel(endpoint: { nil })
        off.start()
        try await eventually("off") { off.connection == .off }
        XCTAssertTrue(off.containers.isEmpty)
        off.stop()
    }

    func testAMissingSocketSaysSo() async throws {
        let gone = DockerModel(
            endpoint: { DockerEndpoint(address: .unix("/tmp/ot-nothing-here.sock"), context: nil, source: "test") }, retries: [.seconds(60)])
        gone.start()
        try await eventually("down") {
            if case .down = gone.connection { return true }
            return false
        }
        XCTAssertEqual(gone.connection, .down("Docker Engine isn't running — no socket at /tmp/ot-nothing-here.sock."))
        gone.stop()
        XCTAssertEqual(gone.connection, .off)
    }

    /// The poll runs only while something shows Docker.
    func testThePollRunsWhileShown() async throws {
        shop()
        model.start()
        try await eventually("listed") { model.containers.count == 3 }
        let lists = { self.fake.requests.filter { $0.contains("/containers/json") }.count }
        model.show()
        let before = lists()
        try await eventually("two polls") { lists() - before >= 2 }
        model.hide()
        // A poll already on its way when it was hidden still lands.
        try await Task.sleep(for: .milliseconds(150))
        let after = lists()
        try await Task.sleep(for: .milliseconds(450))
        XCTAssertEqual(lists(), after, "no poll once hidden")
    }
}

/// Which events are a container going wrong on its own. Pure.
final class DockerAttentionTests: XCTestCase {
    private func event(_ action: String, _ id: String = "c1", _ attributes: [String: String] = [:]) -> DockerEvent {
        var all = ["name": "shop-web-1", "com.docker.compose.project.working_dir": "/w/shop"]
        all.merge(attributes) { $1 }
        return DockerEvent(Type: "container", Action: action, Actor: .init(ID: id, Attributes: all))
    }

    func testACrashIsNewsAndAStopAskedForIsNot() {
        var attention = DockerAttention()
        let now = Date()
        XCTAssertEqual(
            attention.note(event("die", "c1", ["exitCode": "1"]), at: now),
            .init(container: "shop-web-1", detail: "exited (1)", workingDir: "/w/shop"))
        XCTAssertNil(attention.note(event("die", "c1", ["exitCode": "0"]), at: now), "done with its work")
        XCTAssertNil(attention.note(event("kill", "c2", ["signal": "15"]), at: now))
        XCTAssertNil(attention.note(event("die", "c2", ["exitCode": "143"]), at: now.addingTimeInterval(10)), "docker stop")
        XCTAssertNil(attention.note(event("kill", "c3"), at: now))
        XCTAssertNotNil(attention.note(event("die", "c3", ["exitCode": "1"]), at: now.addingTimeInterval(60)), "a kill long before isn't this die's")
        XCTAssertNotNil(attention.note(event("die", "c2", ["exitCode": "1"]), at: now.addingTimeInterval(11)), "a kill is used up by its die")
    }

    func testOutOfMemoryAndUnhealthy() {
        var attention = DockerAttention()
        XCTAssertEqual(attention.note(event("oom", "c4"))?.detail, "ran out of memory")
        XCTAssertNil(attention.note(event("die", "c4", ["exitCode": "137"])), "said once, not twice")
        XCTAssertEqual(attention.note(event("health_status: unhealthy"))?.note, "shop-web-1 is unhealthy")
        XCTAssertNil(attention.note(event("health_status: healthy")))
        XCTAssertNil(attention.note(DockerEvent(Type: "image", Action: "delete", Actor: .init(ID: "x", Attributes: nil))))
    }

    func testWhoseCheckoutItIs() {
        XCTAssertTrue(DockerAttention.belongs("/w/shop", to: "/w/shop"))
        XCTAssertTrue(DockerAttention.belongs("/w/shop/deploy", to: "/w/shop"))
        XCTAssertTrue(DockerAttention.belongs("/w/shop", to: "/w/shop/services/api"), "a tab in a folder of the project")
        XCTAssertFalse(DockerAttention.belongs("/w/shop-2", to: "/w/shop"))
        XCTAssertFalse(DockerAttention.belongs("/w", to: "/"), "the root is nobody's checkout")
    }

    @MainActor
    func testAFailureMarksATabNotLooking() {
        var activity = TabActivity()
        XCTAssertFalse(activity.containerFailed("db exited (1)", visible: true), "seen as it happened")
        XCTAssertTrue(activity.containerFailed("db exited (1)", visible: false))
        XCTAssertEqual(activity.mark, .failed)
        XCTAssertEqual(activity.note, "db exited (1)")
        XCTAssertFalse(activity.containerFailed("db exited (1)", visible: false), "once until seen")
    }
}

/// Compose's labels, read into projects. Pure.
final class ComposeProjectsTests: XCTestCase {
    private func container(
        _ name: String, project: String? = nil, service: String? = nil, number: Int = 1, oneOff: Bool = false, state: String = "running",
        status: String = "Up 1 minute", created: Int = 1, dir: String? = nil, dependsOn: String? = nil
    ) -> ContainerSummary {
        var labels: [String: String] = [:]
        if let project {
            labels["com.docker.compose.project"] = project
            labels["com.docker.compose.service"] = service ?? name
            labels["com.docker.compose.container-number"] = "\(number)"
            labels["com.docker.compose.oneoff"] = oneOff ? "True" : "False"
            if let dir {
                labels["com.docker.compose.project.working_dir"] = dir
                labels["com.docker.compose.project.config_files"] = "\(dir)/compose.yaml,\(dir)/compose.override.yaml"
            }
            if let dependsOn { labels["com.docker.compose.depends_on"] = dependsOn }
        }
        return ContainerSummary(Id: name + "-id", Names: ["/" + name], Image: "x", Created: created, Labels: labels, State: state, Status: status)
    }

    func testProjectsServicesAndReplicas() {
        let (projects, loose) = ComposeProjects.group([
            container("shop-web-2", project: "shop", service: "web", number: 2, dir: "/w/shop", dependsOn: "db:service_healthy:false"),
            container("shop-web-1", project: "shop", service: "web", number: 1, dir: "/w/shop"),
            container("shop-web-run-1a2b", project: "shop", service: "web", oneOff: true, state: "exited", status: "Exited (0) 1 minute ago"),
            container("shop-db-1", project: "shop", service: "db", dir: "/w/shop"),
            container("blog-app-1", project: "blog", service: "app"),
            container("scratch"),
        ])
        XCTAssertEqual(projects.map(\.name), ["blog", "shop"])
        let shop = projects[1]
        XCTAssertEqual(shop.services.map(\.name), ["db", "web"])
        XCTAssertEqual(shop.services[1].containers.map(\.name), ["shop-web-1", "shop-web-2", "shop-web-run-1a2b"])
        XCTAssertEqual(shop.services[1].dependsOn, ["db"])
        XCTAssertEqual(shop.workingDir, "/w/shop")
        XCTAssertEqual(shop.configFiles, ["/w/shop/compose.yaml", "/w/shop/compose.override.yaml"])
        XCTAssertEqual(shop.status, .running, "a finished one-off doesn't make the stack partial")
        XCTAssertTrue(shop.failing.isEmpty)
        XCTAssertEqual(loose.map(\.name), ["scratch"])
    }

    func testStatusAndFailing() {
        let crashed = ComposeProjects.group([
            container("a-web-1", project: "a", service: "web"),
            container("a-db-1", project: "a", service: "db", state: "exited", status: "Exited (1) 5 seconds ago"),
            container("a-cache-1", project: "a", service: "cache", status: "Up 1 minute (unhealthy)"),
        ]).projects[0]
        XCTAssertEqual(crashed.status, .partial)
        XCTAssertEqual(Set(crashed.failing.map(\.name)), ["a-db-1", "a-cache-1"])
        let stopped = ComposeProjects.group([
            container("b-web-1", project: "b", service: "web", state: "exited", status: "Exited (0) 1 hour ago")
        ]).projects[0]
        XCTAssertEqual(stopped.status, .stopped)
        XCTAssertTrue(stopped.failing.isEmpty, "stopped cleanly is not failing")
    }

    /// A project made again elsewhere (another worktree with the folder's
    /// name) is where its newest container says.
    func testTheNewestContainerSaysWhereTheProjectIs() {
        let project = ComposeProjects.group([
            container("app-web-1", project: "app", service: "web", created: 10, dir: "/old/app"),
            container("app-db-1", project: "app", service: "db", created: 20, dir: "/new/app"),
        ]).projects[0]
        XCTAssertEqual(project.workingDir, "/new/app")
    }

    /// What a pane header shows for a checkout: running containers' TCP
    /// ports, each once, by number, named for their service.
    func testWhatACheckoutPublishes() {
        var web = container("a-web-1", project: "a", service: "web", dir: "/w/a")
        web.Ports = [
            DockerPort(IP: "0.0.0.0", PrivatePort: 80, PublicPort: 8080, Type: "tcp"), DockerPort(IP: "::", PrivatePort: 80, PublicPort: 8080, Type: "tcp"),
            DockerPort(IP: "0.0.0.0", PrivatePort: 53, PublicPort: 5353, Type: "udp"),
        ]
        var db = container("a-db-1", project: "a", service: "db", dir: "/w/a")
        db.Ports = [DockerPort(IP: "127.0.0.1", PrivatePort: 5432, PublicPort: 55432, Type: "tcp")]
        var stopped = container("a-cache-1", project: "a", service: "cache", state: "exited", status: "Exited (0) 1 minute ago", dir: "/w/a")
        stopped.Ports = [DockerPort(IP: "0.0.0.0", PrivatePort: 6379, PublicPort: 6379, Type: "tcp")]
        let ports = ComposeProjects.ports(of: ComposeProjects.group([web, db, stopped]).projects)
        XCTAssertEqual(ports.map(\.port), [8080, 55432])
        XCTAssertEqual(ports.map(\.process), ["web", "db"])
        XCTAssertEqual(ports.map(\.container), ["a-web-1", "a-db-1"])
        XCTAssertEqual(ports.first?.id, "a-web-1:8080", "not a pid's: there is none")
        XCTAssertEqual(ports.map(\.movedFrom), [nil, nil])
        // Up on Free Ports moved web's: its pill says where from.
        let moved = ComposePortOverride(
            folder: "/w/a", project: "a", fileName: "a", baseFiles: ["/w/a/compose.yaml"],
            moves: [ComposePortMove(service: "web", target: 80, proto: "tcp", from: 8000, to: 8080), ComposePortMove(service: "db", target: 5432, proto: "tcp", from: 5432, to: 15432)],
            made: Date())
        let pills = ComposeProjects.ports(of: ComposeProjects.group([web, db, stopped]).projects, overrides: ["a": moved])
        XCTAssertEqual(pills.map(\.movedFrom), [8000, nil], "db's 55432 isn't where the override put it")
        XCTAssertEqual(pills.first?.id, "a-web-1:8080", "the same pill")
    }

    func testDependencies() {
        XCTAssertEqual(ComposeProjects.dependencies("db:service_started:false,cache:service_healthy:true"), ["db", "cache"])
        XCTAssertEqual(ComposeProjects.dependencies(""), [])
        XCTAssertEqual(ComposeProjects.dependencies(nil), [])
    }

    func testACheckoutHoldsWhatIsRunInItOrFromItsFiles() {
        let projects = ComposeProjects.group([
            container("a-web-1", project: "a", service: "web", dir: "/w/repo"),
            container("b-web-1", project: "b", service: "web", dir: "/w/repo/services/b"),
            container("c-web-1", project: "c", service: "web", dir: "/w/repo-other"),
            container("d-web-1", project: "d", service: "web", dir: "/elsewhere"),
        ]).projects
        var fromFile = projects[3]
        fromFile.configFiles = ["/w/repo/deploy/compose.yaml"]
        let all = Array(projects.prefix(3)) + [fromFile]
        XCTAssertEqual(ComposeProjects.projects(all, in: "/w/repo").map(\.name), ["a", "b", "d"])
        XCTAssertEqual(ComposeProjects.projects(all, in: "/w/repo/").map(\.name), ["a", "b", "d"])
        XCTAssertEqual(ComposeProjects.projects(all, in: "/w/repo/services/b").map(\.name), ["b"])
        XCTAssertTrue(ComposeProjects.projects(all, in: "/").isEmpty, "the root holds nothing in particular")
    }
}

/// Finding `docker` without a shell's PATH, telling it which engine, and
/// what the runtimes say of themselves.
final class DockerCLITests: XCTestCase {
    func testToolsAreLookedForWhereInstallersPutThem() {
        let home = URL(fileURLWithPath: "/Users/me")
        let folders = DockerCLI.folders(home: home, path: "/usr/bin:/bin:/usr/local/bin")
        XCTAssertEqual(Array(folders.prefix(3)), ["/usr/bin", "/bin", "/usr/local/bin"])
        XCTAssertEqual(folders.filter { $0 == "/usr/local/bin" }.count, 1)
        XCTAssertTrue(folders.contains("/Users/me/.docker/bin"))
        XCTAssertTrue(folders.contains("/Users/me/.orbstack/bin"))
        let found = DockerCLI.locate("docker", home: home, path: "/usr/bin") { $0 == "/Users/me/.orbstack/bin/docker" }
        XCTAssertEqual(found?.path, "/Users/me/.orbstack/bin/docker")
        XCTAssertNil(DockerCLI.locate("docker", home: home, path: nil) { _ in false })
    }

    func testTheCommandIsToldWhichEngine() {
        let docker = URL(fileURLWithPath: "/Users/me/.docker/bin/docker")
        let context = DockerEndpoint(address: .unix("/o.sock"), context: "orbstack", source: "context orbstack")
        XCTAssertEqual(DockerCLI.environment(for: context, executable: docker).first, "DOCKER_CONTEXT=orbstack")
        let host = DockerEndpoint(address: .tcp(host: "10.0.0.2", port: 2375), context: nil, source: "docker.endpoint")
        XCTAssertEqual(DockerCLI.environment(for: host, executable: docker).first, "DOCKER_HOST=tcp://10.0.0.2:2375")
        let plain = DockerCLI.environment(for: DockerEndpoint(address: .unix("/var/run/docker.sock"), context: nil, source: "default"), executable: docker)
        XCTAssertEqual(plain.count, 1)
        XCTAssertTrue(plain[0].hasPrefix("PATH=/Users/me/.docker/bin:"), "plugins and credential helpers beside it are found")
    }

    func testItRunsWithThatEnvironment() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ot-cli-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let tool = folder.appendingPathComponent("docker")
        try Data("#!/bin/sh\necho \"$DOCKER_CONTEXT|$*\"\n".utf8).write(to: tool)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        let cli = DockerCLI(executable: tool, endpoint: DockerEndpoint(address: .unix("/c.sock"), context: "colima", source: "context colima"))
        let output = try await cli.run(["desktop", "status", "--format", "json"])
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "colima|desktop status --format json")
    }

    func testWhatEachRuntimesOwnCLIDoesForIt() {
        let desktop = DockerRuntime.dockerDesktop.extras().map(\.command)
        XCTAssertTrue(desktop.contains("docker desktop update --check-only"))
        XCTAssertTrue(desktop.contains("docker desktop kubernetes status"))
        XCTAssertEqual(DockerRuntime.colima.extras(context: "colima-work").first?.command, "colima status --profile work")
        XCTAssertTrue(DockerRuntime.engine.extras().isEmpty)
    }

    func testWhereEachEngineKeepsItsSettings() {
        let home = URL(fileURLWithPath: "/Users/me")
        XCTAssertEqual(DockerRuntime.dockerDesktop.configFile(home: home)?.path, "/Users/me/.docker/daemon.json")
        XCTAssertEqual(DockerRuntime.orbStack.configFile(home: home)?.path, "/Users/me/.orbstack/config/docker.json")
        XCTAssertEqual(DockerRuntime.colima.configFile(context: "colima-work", home: home)?.path, "/Users/me/.colima/work/colima.yaml")
        XCTAssertEqual(DockerRuntime.colima.configFile(context: "colima", home: home)?.path, "/Users/me/.colima/default/colima.yaml")
        XCTAssertNil(DockerRuntime.engine.configFile(home: home))
    }

    func testRuntimesSayWhetherTheyAreUp() {
        XCTAssertEqual(DockerRuntime.dockerDesktop.status(fromOutput: #"{"PauseType":"","SessionID":"x","Status":"running"}"#), .running)
        XCTAssertEqual(DockerRuntime.dockerDesktop.status(fromOutput: #"{"PauseType":"","Status":"stopped"}"#), .stopped)
        XCTAssertEqual(DockerRuntime.dockerDesktop.status(fromOutput: #"{"PauseType":"resource-saver","Status":"running"}"#), .paused)
        XCTAssertEqual(DockerRuntime.dockerDesktop.status(fromOutput: "unknown command"), .unknown)
        XCTAssertEqual(DockerRuntime.orbStack.status(fromOutput: "Running\n"), .running)
        XCTAssertEqual(DockerRuntime.orbStack.status(fromOutput: "Stopped"), .stopped)
        XCTAssertEqual(DockerRuntime.colima.status(fromOutput: #"{"display_name":"colima","runtime":"docker"}"#), .running)
        XCTAssertEqual(DockerRuntime.colima.status(fromOutput: ""), .stopped)
        XCTAssertEqual(DockerRuntime.podman.status(fromOutput: "running"), .running)
        XCTAssertNil(DockerRuntime.engine.statusCommand())
        XCTAssertEqual(DockerRuntime.colima.statusCommand(context: "colima-work")?.arguments, ["status", "--json", "--profile", "work"])
    }

    func testPluginsAreFoundWhereTheCLILooks() {
        let home = URL(fileURLWithPath: "/Users/me")
        var looked: [String] = []
        XCTAssertFalse(
            DockerCLI.hasPlugin("scout", home: home) {
                looked.append($0); return false
            })
        XCTAssertTrue(looked.contains("/Users/me/.docker/cli-plugins/docker-scout"), "\(looked)")
        XCTAssertTrue(looked.contains("/Applications/Docker.app/Contents/Resources/cli-plugins/docker-scout"))
        XCTAssertTrue(DockerCLI.hasPlugin("scout", home: home) { $0 == "/opt/homebrew/lib/docker/cli-plugins/docker-scout" })
        XCTAssertEqual(DockerCommands.scout("cves", image: "ghcr.io/acme/web:1.2"), "docker scout cves ghcr.io/acme/web:1.2")
        let context = DockerEndpoint(address: .unix("/c.sock"), context: "colima", source: "docker.context")
        XCTAssertEqual(DockerCommands.scout("quickview", image: "my image", endpoint: context), "DOCKER_CONTEXT=colima docker scout quickview 'my image'")
    }

    /// Rancher Desktop through rdctl: its app's API says the VM's state.
    func testRancherDesktopThroughRdctl() {
        let rancher = DockerRuntime.rancherDesktop
        XCTAssertEqual(rancher.command(.start), "rdctl start")
        XCTAssertEqual(rancher.command(.stop), "rdctl shutdown")
        XCTAssertEqual(rancher.command(.restart), "rdctl shutdown && rdctl start")
        XCTAssertEqual(rancher.statusCommand()?.tool, "rdctl")
        XCTAssertEqual(rancher.statusCommand()?.arguments, ["api", "/v1/backend_state"])
        XCTAssertEqual(rancher.status(fromOutput: #"{"vmState":"STARTED","locked":false}"#), .running)
        XCTAssertEqual(rancher.status(fromOutput: #"{"vmState":"DISABLED","locked":false}"#), .running, "up, with Kubernetes off")
        XCTAssertEqual(rancher.status(fromOutput: #"{"vmState":"STARTING","locked":true}"#), .starting)
        XCTAssertEqual(rancher.status(fromOutput: #"{"vmState":"STOPPED","locked":false}"#), .stopped)
        XCTAssertEqual(rancher.status(fromOutput: #"{"vmState":"ERROR","locked":false}"#), .unknown)
        XCTAssertEqual(rancher.status(fromOutput: "Error: connection refused"), .unknown)
        XCTAssertEqual(rancher.extras().map(\.command), ["rdctl list-settings", "rdctl version"])
    }
}
