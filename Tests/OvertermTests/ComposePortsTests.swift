import Foundation
import XCTest

@testable import Overterm

/// Each worktree's stack on its own ports: Compose's reading of the files,
/// the plan (which ports go where, under which name), the override file,
/// who holds a port, the question — pure; the files Compose finds and the
/// store, on folders of their own; and an Up through a stub `docker`.
final class ComposePortsTests: XCTestCase {
    /// What Compose v5.6.0 printed for `--profile '*' config --format json`,
    /// networks and commands left out — and `mail`'s `published` an int, as
    /// early Compose v2 wrote it.
    static let answer = """
        {"name": "shop", "services": {
          "admin": {"profiles": ["tools"], "image": "adminer", "ports": [{"mode": "ingress", "target": 8080, "published": "8081", "protocol": "tcp"}]},
          "cache": {"image": "redis", "ports": [{"mode": "ingress", "target": 6379, "protocol": "tcp"},
            {"mode": "ingress", "target": 7000, "published": "7000", "protocol": "tcp"}, {"mode": "ingress", "target": 7001, "published": "7001", "protocol": "tcp"}]},
          "db": {"container_name": "shop-db", "image": "postgres:16", "ports": [{"mode": "ingress", "target": 5432, "published": "5432", "protocol": "tcp"}],
            "volumes": [{"type": "volume", "source": "data", "target": "/var/lib/postgresql/data", "volume": {}}]},
          "mail": {"image": "mailhog/mailhog", "ports": [{"mode": "ingress", "target": 25, "published": 1025, "protocol": "tcp"}]},
          "w": {"image": "busybox", "ports": [{"mode": "ingress", "target": 80, "published": "7000-7010", "protocol": "tcp"}]},
          "web": {"image": "nginx:1.27", "ports": [{"mode": "ingress", "target": 80, "published": "8080", "protocol": "tcp"},
            {"mode": "ingress", "host_ip": "127.0.0.1", "target": 9229, "published": "9229", "protocol": "tcp"},
            {"name": "https", "mode": "ingress", "target": 443, "published": "8443", "protocol": "tcp", "app_protocol": "https"}]}},
         "volumes": {"data": {"name": "shop_data"}, "ext": {"name": "ext", "external": true}, "shared": {"name": "shared-data"}}}
        """

    private var config: ComposeConfig { try! ComposeConfig.parse(Self.answer) }

    private func service(_ name: String, in config: ComposeConfig? = nil) -> ComposeConfig.Service? {
        (config ?? self.config).services.first { $0.name == name }
    }

    /// The plan with `taken` held (by something unknown), `busy` not free
    /// either.
    private func plan(
        _ config: ComposeConfig? = nil, taken: [Int] = [], busy: Set<Int> = [], reserved: Set<Int> = [], keep: [ComposePortMove] = [],
        active: Set<String> = [], name: String = "shop", holder: String? = nil, holders: [Int: DockerPortConflict.Holder] = [:]
    ) -> ComposePortPlan {
        var held: [ComposePortKey: DockerPortConflict.Holder] = [:]
        for port in taken { held[ComposePortKey(port: port, proto: "tcp")] = holders[port] ?? .unknown }
        return ComposePortPlan.make(
            config: config ?? self.config, active: active, taken: held, isFree: { port, _ in !busy.contains(port) && !taken.contains(port) },
            reserved: reserved, keep: keep, name: name, nameHolder: holder)
    }

    private func move(_ service: String, _ target: Int, _ from: Int, _ to: Int) -> ComposePortMove {
        ComposePortMove(service: service, target: target, proto: "tcp", from: from, to: to)
    }

    /// A config of one or two services, their ports as Compose writes them.
    private func config(_ services: [String: String], name: String = "shop") throws -> ComposeConfig {
        let body = services.map { #""\#($0.key)": {"image": "x", "ports": [\#($0.value)]}"# }.joined(separator: ",")
        return try ComposeConfig.parse(#"{"name": "\#(name)", "services": {\#(body)}}"#)
    }

    private func port(_ published: String, _ target: Int, ip: String? = nil) -> String {
        #"{"mode": "ingress", "target": \#(target), "published": "\#(published)", "protocol": "tcp""# + (ip.map { #", "host_ip": "\#($0)""# } ?? "") + "}"
    }

    // MARK: Compose's reading

    func testTheResolvedConfigIsRead() throws {
        let config = try ComposeConfig.parse(Self.answer)
        XCTAssertEqual(config.name, "shop")
        XCTAssertEqual(service("web")?.ports.map(\.hostPort), [8080, 9229, 8443])
        XCTAssertEqual(service("web")?.ports[1].hostIP, "127.0.0.1")
        XCTAssertEqual(service("web")?.ports[2].name, "https")
        XCTAssertEqual(service("web")?.ports[2].appProtocol, "https")
        XCTAssertNil(service("web")?.ports[0].mode, "ingress is Compose's own")
        XCTAssertEqual(service("cache")?.ports.map(\.hostPort), [nil, 7000, 7001], "a port Docker picks has none; a range is spread")
        XCTAssertEqual(service("w")?.ports.map(\.hostPort), [nil], "a range onto one port is the range")
        XCTAssertEqual(service("w")?.ports.first?.published, "7000-7010")
        XCTAssertEqual(service("mail")?.ports.map(\.hostPort), [1025], "an int published")
        XCTAssertEqual(service("admin")?.profiles, ["tools"])
        XCTAssertEqual(service("db")?.containerName, "shop-db")
        XCTAssertEqual(config.projectVolumes, ["data"], "the explicit and the external one are no project's own")
    }

    // MARK: The plan

    func testATakenPortMovesTenThousandUp() {
        let plan = plan(taken: [8080])
        XCTAssertEqual(plan.moves, [move("web", 80, 8080, 18080)])
        XCTAssertEqual(plan.moves.map(\.label), ["web 8080 → 18080"])
        XCTAssertEqual(plan.blocking.map(\.port), [8080])
        XCTAssertTrue(plan.needsAsking)
        XCTAssertTrue(plan.changes)
        XCTAssertTrue(plan.unmovable.isEmpty)
        let nothing = self.plan()
        XCTAssertFalse(nothing.changes, "nothing taken: nothing to move")
        XCTAssertFalse(nothing.needsAsking)
        XCTAssertEqual(ComposePortMove(service: "dns", target: 53, proto: "udp", from: 53, to: 10053).label, "dns 53 → 10053/udp")
    }

    func testTheNextFreeOneWhenThatIsTaken() throws {
        XCTAssertEqual(plan(taken: [8080], busy: [18080]).moves.map(\.to), [28080])
        XCTAssertEqual(plan(taken: [8080], busy: [18080], reserved: [28080]).moves.map(\.to), [38080], "another override's port isn't given twice")
        let wants = try config(["web": port("8080", 80), "api": port("18080", 3000)])
        XCTAssertEqual(plan(wants, taken: [8080]).moves, [move("web", 80, 8080, 28080)], "a port the files want themselves is skipped")
        let high = try config(["web": port("45000", 80)])
        XCTAssertEqual(plan(high, taken: [45000]).moves.map(\.to), [45001], "55000 would be the system's")
        XCTAssertEqual(ComposePortPlan.candidates(for: 8080).prefix(5), [18080, 28080, 38080, 48080, 8081])
        XCTAssertEqual(ComposePortPlan.candidates(for: 65_535), [])
        let none = ComposePortPlan.make(
            config: high, active: [], taken: [ComposePortKey(port: 45000, proto: "tcp"): .unknown], isFree: { _, _ in false }, reserved: [], keep: [],
            name: "shop", nameHolder: nil)
        XCTAssertTrue(none.moves.isEmpty)
        XCTAssertEqual(none.unmovable.map(\.port), [45000], "nowhere to go: it stays as written")
        XCTAssertFalse(none.changes)
    }

    func testOnePortForBothAddressFamilies() throws {
        let both = try config(["web": port("8080", 80, ip: "0.0.0.0") + "," + port("8080", 80, ip: "::"), "admin": port("8080", 8000, ip: "10.0.0.2")])
        let plan = plan(both, taken: [8080])
        XCTAssertEqual(plan.moves, [move("admin", 8000, 8080, 18080), move("web", 80, 8080, 18080)], "one to a service, one port for all")
        let yaml = ComposePorts.overrideYAML(plan: plan, config: both, folder: "/w/x")
        XCTAssertEqual(yaml.components(separatedBy: #"published: "18080""#).count - 1, 3, yaml)
    }

    func testAKeptPortStays() {
        XCTAssertEqual(plan(keep: [move("web", 80, 8080, 18080)]).moves, [move("web", 80, 8080, 18080)], "free again, it stays where it was put")
        XCTAssertEqual(
            plan(taken: [8080], busy: [18080], keep: [move("web", 80, 8080, 18080)]).moves, [move("web", 80, 8080, 28080)], "taken since: moved again")
        XCTAssertEqual(
            plan(taken: [5432], keep: [move("web", 3000, 3000, 13000), move("web", 80, 8080, 18080)]).moves,
            [move("db", 5432, 5432, 15432), move("web", 80, 8080, 18080)], "a port the files no longer ask for is dropped")
    }

    func testAPortAnotherOverrideGaveOutIsntKept() {
        let kept = [move("web", 80, 8080, 18080)]
        XCTAssertEqual(
            plan(taken: [8080], reserved: [18080], keep: kept).moves, [move("web", 80, 8080, 28080)],
            "another window's override has it since the question: moved on")
        XCTAssertEqual(plan(reserved: [18080], keep: kept).moves, [], "the file's free again: as written")
    }

    func testAKeptOverrideAgainstChangedFiles() throws {
        let files = try config(["web": port("8080", 80) + "," + port("9229", 9229)])
        let kept = ComposePortOverride(
            folder: "/w/x", project: "shop-wt-x", fileName: "shop", baseFiles: [],
            moves: [move("web", 80, 8080, 18080), move("api", 3000, 3000, 13000), move("web", 9229, 9300, 19300)], made: Date())
        let refreshed = ComposePortPlan.refreshed(kept, config: files)
        XCTAssertEqual(refreshed.moves, [move("web", 80, 8080, 18080)], "a service gone, a port changed: dropped; the rest stays")
        XCTAssertTrue(refreshed.blocking.isEmpty && refreshed.unmovable.isEmpty, "nothing looked at")
        XCTAssertEqual(refreshed.name, "shop-wt-x")
        XCTAssertTrue(refreshed.changes)
        var same = kept
        same.project = "shop"
        same.moves = [move("api", 3000, 3000, 13000)]
        XCTAssertFalse(ComposePortPlan.refreshed(same, config: files).changes, "nothing left of it")
        let wantsIt = try config(["web": port("8080", 80), "admin": port("18080", 80)])
        XCTAssertEqual(ComposePortPlan.refreshed(kept, config: wantsIt).moves, [], "the files want its port themselves now")
    }

    func testWhatAnUpChangedIsSaid() throws {
        let files = try config(["web": port("8080", 80), "db": port("5432", 5432)])
        let kept = [move("web", 80, 8080, 18080), move("db", 5432, 5432, 15432), move("api", 3000, 3000, 13000)]
        XCTAssertEqual(
            ComposePorts.changes(from: kept, to: [move("web", 80, 8080, 18081)], config: files),
            ["web 18080 was taken — it is on 18081 now", "db is back on 5432: 15432 is taken"], "api is no longer asked for: unsaid")
        XCTAssertEqual(ComposePorts.changes(from: kept, to: kept, config: files), [])
        XCTAssertEqual(ComposePorts.changes(from: [], to: [move("db", 5432, 5432, 15432)], config: files), ["db 5432 was taken — it is on 15432 now"])
    }

    func testOnlyServicesThatStartAsk() {
        let quiet = plan(taken: [8081])
        XCTAssertEqual(quiet.moves, [move("admin", 8080, 8081, 18081)], "moved all the same")
        XCTAssertTrue(quiet.blocking.isEmpty, "tools isn't on")
        XCTAssertFalse(quiet.needsAsking)
        XCTAssertEqual(plan(taken: [8081], active: ["tools"]).blocking.map(\.service), ["admin"])
        XCTAssertEqual(plan(taken: [8081], active: ["*"]).blocking.map(\.service), ["admin"])
        XCTAssertEqual(ComposePorts.activeProfiles(dotEnv: ["COMPOSE_PROFILES": "a, b,"], extra: ["c"]), ["a", "b", "c"])
        XCTAssertEqual(ComposePorts.activeProfiles(dotEnv: [:]), [])
    }

    func testTheProjectsName() {
        let projects = [ComposeProject(name: "shop", workingDir: "/w/shop", configFiles: ["/w/shop/compose.yaml"], services: [])]
        func name(_ folder: String, running: String? = nil, reserved: [String: String] = [:]) -> (String, String?) {
            let named = ComposePortPlan.projectName(fileName: "shop", folder: folder, running: running, projects: projects, reserved: reserved)
            return (named.name, named.holder)
        }
        XCTAssertTrue(name("/w/shop-wt-feat-x") == ("shop-wt-feat-x", "/w/shop"), "a worktree's folder starts with it")
        XCTAssertTrue(name("/w/other") == ("shop-other", "/w/shop"))
        XCTAssertTrue(name("/w/shop") == ("shop", nil), "this folder's own")
        XCTAssertTrue(name("/w/shop-wt-feat-x", reserved: ["shop-wt-feat-x": "/x"]) == ("shop-wt-feat-x-2", "/w/shop"), "another override has it")
        XCTAssertTrue(name("/w/x", running: "custom") == ("custom", nil), "one that runs keeps its name")
        XCTAssertTrue(
            ComposePortPlan.projectName(fileName: "api", folder: "/w/b", running: nil, projects: [], reserved: ["api": "/w/a"]) == ("api-b", "/w/a"),
            "another override's name")
        XCTAssertEqual(ComposePortPlan.slug("Feat/X  Y"), "feat-x-y")
        XCTAssertEqual(ComposePortPlan.slug("--My.Shop_2"), "my-shop_2")
    }

    // MARK: The file

    func testTheOverrideFile() throws {
        let config = try ComposeConfig.parse(
            #"{"name": "shop", "services": {"db": {"image": "postgres", "ports": [\#(port("5432", 5432))]}, "web": {"image": "nginx", "ports": ["#
                + port("8080", 80) + "," + port("9229", 9229, ip: "127.0.0.1") + ","
                + #"{"mode": "host", "target": 443, "published": "8443", "protocol": "tcp", "name": "ht$ps", "app_protocol": "https"}"# + "]}}}")
        let moved = plan(config, taken: [8080], name: "shop-wt-x", holder: "/w/shop")
        XCTAssertEqual(
            ComposePorts.overrideYAML(plan: moved, config: config, folder: "/w/shop-wt-x"),
            """
            # Overterm: /w/shop-wt-x's stack on ports of its own (Up on Free Ports).
            # Written again before each Up from Overterm; the project's “Back to the File's Ports” removes it.
            # Nothing of it is in the repository.
            name: "shop-wt-x"
            services:
              "web":
                ports: !override
                  - target: 80
                    published: "18080"
                    protocol: "tcp"
                  - target: 9229
                    published: "9229"
                    host_ip: "127.0.0.1"
                    protocol: "tcp"
                  - target: 443
                    published: "8443"
                    protocol: "tcp"
                    mode: "host"
                    name: "ht$$ps"
                    app_protocol: "https"

            """)
        let renamed = plan(config, name: "shop-2", holder: "/w/shop")
        XCTAssertEqual(
            ComposePorts.overrideYAML(plan: renamed, config: config, folder: "/w/a\nb").split(separator: "\n").suffix(2),
            ["# Nothing of it is in the repository.", #"name: "shop-2""#], "only the name: no services")
        XCTAssertTrue(ComposePorts.overrideYAML(plan: renamed, config: config, folder: "/w/a\nb").hasPrefix("# Overterm: /w/a b's stack"))
    }

    // MARK: Who holds what

    func testWhoHoldsWhat() {
        func container(_ name: String, _ project: String?, _ port: Int, state: String = "running", dir: String = "/w/shop") -> ContainerSummary {
            var labels: [String: String] = [:]
            if let project {
                labels["com.docker.compose.project"] = project
                labels["com.docker.compose.project.working_dir"] = dir
            }
            return ContainerSummary(
                Id: name + "-id", Names: ["/" + name], Image: "x", Created: 1, Ports: [DockerPort(IP: "0.0.0.0", PrivatePort: 80, PublicPort: port, Type: "tcp")],
                Labels: labels, State: state, Status: "")
        }
        let containers = [
            container("shop-web-1", "shop", 8080), container("old", "shop", 5432, state: "exited"),
            container("wt-api-1", "shop-wt", 9229, dir: "/w/wt"),
        ]
        let own: (ContainerSummary) -> Bool = { $0.composeProject == "shop-wt" && $0.composeWorkingDir == "/w/wt" }
        let wanted = [8080, 5432, 9229, 6000, 7000].map { ComposePortKey(port: $0, proto: "tcp") }
        let bound: Set<Int> = [9229, 6000]
        let taken = ComposePortCensus.taken(wanted: wanted, containers: containers, own: own, isBound: { port, _ in bound.contains(port) })
        XCTAssertEqual(taken[ComposePortKey(port: 8080, proto: "tcp")], .container(id: "shop-web-1-id", name: "shop-web-1", project: "shop", folder: "/w/shop"))
        XCTAssertNil(taken[ComposePortKey(port: 5432, proto: "tcp")], "an exited one holds nothing")
        XCTAssertNil(taken[ComposePortKey(port: 9229, proto: "tcp")], "its own: Docker's process binds it for them")
        XCTAssertEqual(taken[ComposePortKey(port: 6000, proto: "tcp")], .unknown, "bound by something on this Mac")
        XCTAssertNil(taken[ComposePortKey(port: 7000, proto: "tcp")])
        XCTAssertNil(taken[ComposePortKey(port: 8080, proto: "udp")])
        let remote = ComposePortCensus.taken(wanted: wanted, containers: containers, own: own, isBound: { _, _ in false })
        XCTAssertEqual(Set(remote.keys), [ComposePortKey(port: 8080, proto: "tcp")], "a remote engine: its containers only")
        XCTAssertTrue(ComposePortCensus.isFree(9229, "tcp", containers: containers, own: own, isBound: { _, _ in true }), "its own containers' port is its")
        XCTAssertFalse(ComposePortCensus.isFree(8080, "tcp", containers: containers, own: own, isBound: { _, _ in false }))
        XCTAssertFalse(ComposePortCensus.isFree(6000, "tcp", containers: containers, own: own, isBound: { port, _ in bound.contains(port) }))
        XCTAssertTrue(ComposePortCensus.isFree(7000, "tcp", containers: containers, own: own, isBound: { port, _ in bound.contains(port) }))
    }

    func testComposeVersions() {
        for version in ["5.6.0", "v2.24.4", "2.29.1-desktop.1", "2.25", "v5.6.0\n"] { XCTAssertTrue(ComposePorts.supportsOverride(version: version), version) }
        for version in ["2.24.3", "1.29.2", "", "dev", "2.24"] { XCTAssertFalse(ComposePorts.supportsOverride(version: version), version) }
    }

    func testTheQuestion() {
        let web = DockerPortConflict.Holder.container(id: "x", name: "shop-web-1", project: "shop", folder: "/w/shop")
        let ports = ComposePorts.question(plan(taken: [8080], holders: [8080: web]))
        XCTAssertEqual(ports.title, "web's port 8080 is taken")
        XCTAssertEqual(
            ports.detail,
            """
            8080 (web): shop-web-1 publishes it — compose project shop in /w/shop.
            db keeps container_name, so it can't run beside the other stack's either way.

            Up on Free Ports runs it on web 8080 → 18080 — an override in Overterm's folder, not in the repository, which every Up from Overterm uses until you take it back.
            """)
        XCTAssertEqual(ComposePorts.question(plan(taken: [8080, 5432])).title, "2 of the stack's ports are taken")

        let name = ComposePorts.question(plan(name: "shop-wt-x", holder: "/w/shop"))
        XCTAssertEqual(name.title, "“shop” is another checkout's stack")
        XCTAssertTrue(name.detail.hasPrefix("“shop” runs in /w/shop: up as written would replace its containers with this checkout's."), name.detail)
        XCTAssertTrue(name.detail.contains("Up on Free Ports runs it as “shop-wt-x” — an override"), name.detail)
        XCTAssertTrue(name.detail.hasSuffix("Its volumes are its own under that name (data): their data starts empty."), name.detail)

        let both = ComposePorts.question(plan(taken: [8080], name: "shop-wt-x", holder: "/w/shop"))
        XCTAssertEqual(both.title, "This stack would run into another checkout's")
        XCTAssertTrue(both.detail.contains("runs it as “shop-wt-x” on web 8080 → 18080 — an override"), both.detail)
        XCTAssertFalse(ports.detail.contains("volumes"), "its own name only makes its volumes new")
    }

    // MARK: The files Compose finds

    func testTheFilesComposeFinds() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ot-files-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("sub"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func touch(_ name: String) throws { try Data().write(to: root.appendingPathComponent(name)) }
        func remove(_ name: String) throws { try FileManager.default.removeItem(at: root.appendingPathComponent(name)) }
        func names() -> [String] {
            ComposeProjects.composeFiles(in: root).map { String($0.path.dropFirst(root.standardizedFileURL.path.count + 1)) }
        }
        XCTAssertEqual(names(), [], "none")
        XCTAssertNil(ComposeProjects.composeFile(in: root))
        try touch("compose.override.yml")
        XCTAssertEqual(names(), [], "an override alone is nothing")
        try touch("compose.yaml")
        XCTAssertEqual(names(), ["compose.yaml", "compose.override.yml"], "the file, then its override")
        try remove("compose.yaml")
        try remove("compose.override.yml")
        try touch("docker-compose.yaml")
        try touch("docker-compose.yml")
        XCTAssertEqual(names(), ["docker-compose.yml"], "compose-go's order")
        try "COMPOSE_FILE=a.yaml:sub/b.yaml\nCOMPOSE_PROFILES=a,b\n".write(to: root.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
        XCTAssertEqual(names(), ["a.yaml", "sub/b.yaml"], ".env's COMPOSE_FILE, relative to the folder")
        XCTAssertNil(ComposeProjects.composeFile(in: root), "named but not there")
        try touch("a.yaml")
        XCTAssertEqual(ComposeProjects.composeFile(in: root)?.lastPathComponent, "a.yaml")
        XCTAssertEqual(ComposeProjects.projectFolder(in: root), FileTreeModel.realPath(root), "Compose's folder: the first file's")
        XCTAssertEqual(ComposePorts.activeProfiles(dotEnv: ComposeProjects.dotEnv(in: root)), ["a", "b"])
        try "COMPOSE_PATH_SEPARATOR=;\nCOMPOSE_FILE=a.yaml;sub/b.yaml\n".write(to: root.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
        XCTAssertEqual(names(), ["a.yaml", "sub/b.yaml"], "its separator")
    }

    @MainActor
    func testALinkedComposeFileIsTheCheckouts() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ot-link-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let checkout = root.appendingPathComponent("shop-wt-x", isDirectory: true)
        let shared = root.appendingPathComponent("shared", isDirectory: true)
        try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "services: {}\n".write(to: shared.appendingPathComponent("compose.yaml"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: checkout.appendingPathComponent("compose.yaml"), withDestinationURL: shared.appendingPathComponent("compose.yaml"))
        let file = try XCTUnwrap(ComposeProjects.composeFiles(in: checkout).first)
        XCTAssertEqual(
            ComposeProjects.composePath(file), FileTreeModel.realPath(checkout) + "/compose.yaml",
            "the link as named: Compose's project folder is the checkout, not the target's")
        XCTAssertEqual(ComposeProjects.projectFolder(in: checkout), FileTreeModel.realPath(checkout))
        let store = ComposePortStore(folder: root.appendingPathComponent("Ports", isDirectory: true))
        let page = DockerPageModel(docker: DockerModel(endpoint: { nil }), ports: store)
        let setup = try XCTUnwrap(page.upSetup(.checkout(checkout)))
        XCTAssertEqual(setup.base, [FileTreeModel.realPath(checkout) + "/compose.yaml"], "an Up passes the link")
        XCTAssertEqual(setup.folder, FileTreeModel.realPath(checkout))
        let kept = ComposePortOverride(folder: setup.folder, project: "shop-wt-x", fileName: "shop", baseFiles: setup.base, moves: [], made: Date())
        try store.save(kept, yaml: "name: \"shop-wt-x\"\n")
        XCTAssertEqual(
            ComposeFileModel.arguments(in: checkout, ports: store).prefix(5), ["compose", "-p", "shop-wt-x", "-f", setup.base[0]], "and so does the plan's read")
    }

    // MARK: The store

    @MainActor
    func testTheStoreKeepsOverridesInItsFolder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ot-ports-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let checkout = root.appendingPathComponent("shop-wt-x", isDirectory: true)
        try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
        let folder = root.appendingPathComponent("Application Support/Overterm/Compose/Ports", isDirectory: true)
        let store = ComposePortStore(folder: folder)
        XCTAssertTrue(store.overrides.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path), "reading writes nothing")
        let base = checkout.appendingPathComponent("compose.yaml").path
        let kept = ComposePortOverride(
            folder: checkout.path, project: "shop-wt-x", fileName: "shop", baseFiles: [base], moves: [move("web", 80, 8080, 18080)],
            made: Date(timeIntervalSince1970: 1_800_000_000))
        try store.save(kept, yaml: "name: \"shop-wt-x\"\n")
        let file = store.file(of: kept)
        XCTAssertEqual(file.deletingLastPathComponent().path, folder.path)
        XCTAssertTrue(file.lastPathComponent.hasPrefix("shop-wt-x-") && file.pathExtension == "yaml", file.lastPathComponent)
        XCTAssertEqual(file, ComposePortStore(folder: folder).file(of: kept), "the same name from one launch to the next")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "name: \"shop-wt-x\"\n")
        let index = folder.appendingPathComponent("index.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: index.path))
        XCTAssertEqual(ComposePortStore(folder: folder).override(in: checkout.path), kept, "read back")
        XCTAssertEqual(kept.summary, "web 8080 → 18080")

        // A project made with it, and one whose labels still name a forgotten one.
        let running = ComposeProject(name: "shop-wt-x", workingDir: checkout.path, configFiles: [base, file.path], services: [])
        XCTAssertEqual(store.override(of: running), kept)
        XCTAssertEqual(store.files(for: running), [base, file.path])
        let stale = ComposeProject(
            name: "shop-wt-x", workingDir: checkout.path, configFiles: [base, folder.appendingPathComponent("old-0000.yaml").path], services: [])
        XCTAssertEqual(store.files(for: stale), [base, file.path], "the stale path left out, the current one in")
        XCTAssertEqual(store.reservedPorts(except: "/elsewhere"), [18080])
        XCTAssertEqual(store.reservedPorts(except: checkout.path), [])
        XCTAssertEqual(store.reservedNames(except: "/elsewhere"), ["shop-wt-x": checkout.path])
        XCTAssertTrue(
            store.command(running, "up -d", endpoint: nil).hasSuffix("-f '\(file.path)' up -d"), "its path quoted: \(store.command(running, "up -d", endpoint: nil))")
        XCTAssertEqual(store.command(running, "down", endpoint: nil), "docker compose -p shop-wt-x down", "down finds it by name")

        // Not touched by reading.
        let written = try FileManager.default.attributesOfItem(atPath: index.path)[.modificationDate] as? Date
        Thread.sleep(forTimeInterval: 0.05)
        _ = ComposePortStore(folder: folder)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: index.path)[.modificationDate] as? Date, written)

        store.forget(checkout.path)
        XCTAssertNil(store.override(in: checkout.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "its file goes with it")
        XCTAssertEqual(store.files(for: running), [base], "back to the files")
        XCTAssertNil(ComposePortStore(folder: folder).override(in: checkout.path))

        // A worktree removed: pruned.
        let gone = ComposePortOverride(folder: root.appendingPathComponent("gone").path, project: "gone", fileName: "shop", baseFiles: [], moves: [], made: Date())
        try store.save(gone, yaml: "name: gone\n")
        try store.save(kept, yaml: "name: \"shop-wt-x\"\n")
        store.prune()
        XCTAssertEqual(Set(store.overrides.keys), [checkout.path])
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.file(of: gone).path))
        XCTAssertEqual(Set(ComposePortStore(folder: folder).overrides.keys), [checkout.path])

        // What it was written from: the files changed since, it is stale.
        try "services: {}\n".write(to: URL(fileURLWithPath: base), atomically: true, encoding: .utf8)
        var stamped = kept
        stamped.stamp = ComposePortStore.stamp(of: [base], folder: checkout.path)
        try store.save(stamped, yaml: "name: \"shop-wt-x\"\n")
        XCTAssertFalse(store.isStale(stamped))
        XCTAssertFalse(store.needsRefresh(running))
        try "services:\n  web: {}\n".write(to: URL(fileURLWithPath: base), atomically: true, encoding: .utf8)
        XCTAssertTrue(store.isStale(stamped), "an edit to its file")
        XCTAssertTrue(store.needsRefresh(running))
        stamped.stamp = ComposePortStore.stamp(of: [base], folder: checkout.path)
        XCTAssertFalse(store.isStale(stamped))
        try "A=1\n".write(to: checkout.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
        XCTAssertTrue(store.isStale(stamped), "its folder's .env too")
        try FileManager.default.removeItem(at: checkout.appendingPathComponent(".env"))
        XCTAssertTrue(store.isStale(kept), "one written before it was stamped is read again once")

        // Unreadable: set aside, nothing kept.
        try Data("{".utf8).write(to: index)
        XCTAssertTrue(ComposePortStore(folder: folder).overrides.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: index.path), "moved aside")
    }

    /// A checkout whose `.env` names a file in a subfolder: Compose's
    /// project folder is that one, and its plan finds its override there.
    @MainActor
    func testAPlanFindsItsOverrideInComposesFolder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ot-sub-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let checkout = root.appendingPathComponent("shop-wt-x", isDirectory: true)
        try FileManager.default.createDirectory(at: checkout.appendingPathComponent("docker"), withIntermediateDirectories: true)
        try "services: {}\n".write(to: checkout.appendingPathComponent("docker/compose.yaml"), atomically: true, encoding: .utf8)
        try "COMPOSE_FILE=docker/compose.yaml\n".write(to: checkout.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
        let store = ComposePortStore(folder: root.appendingPathComponent("Ports", isDirectory: true))
        let folder = try XCTUnwrap(ComposeProjects.projectFolder(in: checkout))
        XCTAssertEqual(folder, FileTreeModel.realPath(checkout.appendingPathComponent("docker")))
        let base = folder + "/compose.yaml"
        let kept = ComposePortOverride(
            folder: folder, project: "shop-wt-x", fileName: "shop", baseFiles: [base], moves: [move("web", 80, 8080, 18080)], made: Date())
        try store.save(kept, yaml: "name: \"shop-wt-x\"\n")
        let plan = ComposeProject(name: "shop-wt-x", workingDir: FileTreeModel.realPath(checkout), configFiles: [], services: [], planned: true)
        XCTAssertEqual(store.override(of: plan), kept, "by Compose's folder, not the checkout")
        XCTAssertEqual(store.files(for: plan), [base, store.file(of: kept).path])
        XCTAssertEqual(
            store.command(plan, "watch", endpoint: nil), "docker compose -p shop-wt-x -f \(base) -f \(store.file(of: kept).path) watch",
            "its Watch under its name, with its override")
        XCTAssertEqual(
            ComposeFileModel.arguments(in: checkout, ports: store),
            ["compose", "-p", "shop-wt-x", "-f", base, "-f", store.file(of: kept).path, "config", "--format", "json"])
    }
}

/// An Up of a checkout's stack through a stub `docker` answering as
/// Compose 2.29 does: a port held on this Mac is moved, the override
/// written in the store's own folder and used by the next Up; an older
/// Compose isn't asked to; what is kept follows the files.
@MainActor
final class ComposeUpTests: XCTestCase {
    private var root: URL!
    private var listeners: [Int32] = []
    private var commands: [(String, URL?)] = []
    private var asked: [(title: String, detail: String)] = []
    private var alerts: [String] = []
    private var copied: [String] = []
    /// What the question is answered: Up on Free Ports.
    private var answer: (@escaping (Int) -> Void) -> Void = { $0(0) }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ot-up-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        DockerPageModel.checksPortsInTests = true
        commands = []
        asked = []
        alerts = []
        copied = []
        answer = { $0(0) }
    }

    override func tearDownWithError() throws {
        DockerPageModel.checksPortsInTests = false
        DockerCLI.override = nil
        for listener in listeners { close(listener) }
        listeners = []
        try FileManager.default.removeItem(at: root)
    }

    /// A port held on 127.0.0.1, as a dev server would.
    private func hold() throws -> Int {
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        listeners.append(listener)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        XCTAssertEqual(bound, 0)
        XCTAssertEqual(listen(listener, 1), 0)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &length) } }
        return Int(UInt16(bigEndian: address.sin_port))
    }

    /// A port nothing holds, by the same probe the Up uses.
    private func free(after port: Int = 30_000) -> Int {
        var port = port
        while ListeningPorts.isBound(port) { port += 1 }
        return port
    }

    /// `version` nil: `compose version` fails, as one that doesn't answer.
    private func stub(version: String?, config: String) throws {
        try config.write(to: root.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)
        let versionLine = version.map { #""compose version --short") echo "\#($0)" ;;"# } ?? #""compose version --short") exit 1 ;;"#
        let script = """
            #!/bin/sh
            echo "$*" >> "\(root.path)/calls"
            case "$*" in
              \(versionLine)
              *" config --format json"*) cat "\(root.path)/config.json" ;;
              *) exit 1 ;;
            esac
            """
        let file = root.appendingPathComponent("docker")
        try script.write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        DockerCLI.override = file
    }

    private var calls: String { (try? String(contentsOf: root.appendingPathComponent("calls"), encoding: .utf8)) ?? "" }

    /// One service publishing `ports` (host:target).
    private func json(_ ports: [(Int, Int)], name: String = "shop", service: String = "db") -> String {
        let list = ports.map { #"{"mode":"ingress","host_ip":"127.0.0.1","target":\#($0.1),"published":"\#($0.0)","protocol":"tcp"}"# }
        return #"{"name":"\#(name)","services":{"\#(service)":{"image":"postgres","ports":[\#(list.joined(separator: ","))]}}}"#
    }

    private func checkout(_ name: String = "shop") throws -> URL {
        let checkout = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
        try "services: {}\n".write(to: checkout.appendingPathComponent("compose.yaml"), atomically: true, encoding: .utf8)
        return checkout
    }

    private func page(_ store: ComposePortStore, docker: DockerModel = DockerModel(endpoint: { nil })) -> DockerPageModel {
        let page = DockerPageModel(docker: docker, ports: store)
        page.actions = DockerActions(
            run: { [weak self] in self?.commands.append(($0, $1)) }, confirm: { _, _, _, _ in XCTFail("nothing to confirm") }, open: { _ in },
            copy: { [weak self] in self?.copied.append($0) }, settings: {},
            choose: { [weak self] title, detail, _, then in
                self?.asked.append((title, detail))
                self?.answer(then)
            },
            alert: { [weak self] title, detail in self?.alerts.append(title + ": " + detail) })
        return page
    }

    private func store() -> ComposePortStore { ComposePortStore(folder: root.appendingPathComponent("Ports", isDirectory: true)) }

    private func until(_ what: String, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(condition(), what)
    }

    func testUpOnFreePortsMovesWhatIsHeldAndKeepsIt() async throws {
        let held = try hold()
        let checkout = try checkout()
        try stub(version: "2.29.7", config: json([(held, 5432)]))
        let store = store()
        let page = page(store)

        await page.up(.checkout(checkout), freePorts: .yes)
        let real = FileTreeModel.realPath(checkout)
        let kept = try XCTUnwrap(store.override(in: real), page.error ?? "nothing kept")
        XCTAssertTrue(asked.isEmpty, "the verb moves without asking")
        XCTAssertEqual(kept.moves.map(\.from), [held])
        XCTAssertGreaterThan(kept.moves.first?.to ?? 0, held, "the next free one: 10 000 up is the system's range")
        XCTAssertEqual(kept.project, "shop", "nobody else's name: its own")
        XCTAssertEqual(kept.stamp, ComposePortStore.stamp(of: [real + "/compose.yaml"], folder: real), "what it was written from")
        XCTAssertEqual(
            commands.last?.0, "docker compose -p shop -f \(real)/compose.yaml -f \(store.file(of: kept).path) up -d", "its files, then the override")
        XCTAssertEqual(commands.last?.1, checkout)
        let yaml = try String(contentsOf: store.file(of: kept), encoding: .utf8)
        XCTAssertTrue(yaml.contains("ports: !override") && yaml.contains(#"published: "\#(kept.moves[0].to)""#) && yaml.contains(#"host_ip: "127.0.0.1""#), yaml)
        XCTAssertTrue(calls.contains("compose -f \(real)/compose.yaml --profile * config --format json --no-env-resolution"), calls)
        XCTAssertTrue(alerts.isEmpty, "nothing to say")

        // The next Up uses it, asking nothing; a kept port stays put.
        await page.up(.checkout(checkout))
        XCTAssertTrue(asked.isEmpty)
        XCTAssertEqual(commands.count, 2)
        XCTAssertTrue(commands.last?.0.hasSuffix("-f \(store.file(of: kept).path) up -d") == true, commands.last?.0 ?? "")
        XCTAssertEqual(store.override(in: real)?.moves, kept.moves)

        // Copy Up Command: what the next Up runs.
        let plan = ComposeProject(name: "shop", workingDir: real, configFiles: [], services: [], planned: true)
        page.verbs(for: plan).first { $0.title == "Copy Up Command" }?.perform()
        XCTAssertEqual(copied, ["docker compose -p shop -f \(real)/compose.yaml -f \(store.file(of: kept).path) up -d"])

        // An older Compose: up as written, and the verb says why not.
        store.forget(real)
        try stub(version: "2.20.0", config: "{}")
        page.composeVersion = nil
        await page.up(.checkout(checkout), freePorts: .yes)
        XCTAssertEqual(commands.last?.0, "docker compose up -d")
        XCTAssertTrue(page.error?.contains("2.24.4") == true, page.error ?? "")
        XCTAssertTrue(alerts.last?.contains("2.24.4") == true, "the page isn't on screen: an alert says it too")
        XCTAssertNil(store.override(in: real))
        XCTAssertTrue(page.freePortsUnavailable(plan)?.contains("2.20.0") == true)
    }

    /// A Compose that doesn't answer its version keeps what was chosen:
    /// its name and its ports, not the files' name over another checkout's
    /// stack.
    func testAComposeThatDoesntAnswerKeepsTheOverride() async throws {
        let checkout = try checkout("shop-wt-feat")
        let real = FileTreeModel.realPath(checkout)
        let store = store()
        let kept = ComposePortOverride(
            folder: real, project: "shop-wt-feat", fileName: "shop", baseFiles: [real + "/compose.yaml"],
            moves: [ComposePortMove(service: "web", target: 80, proto: "tcp", from: 8080, to: 18080)], made: Date())
        try store.save(kept, yaml: "name: \"shop-wt-feat\"\n")
        try stub(version: nil, config: "{}")
        let page = page(store)
        await page.up(.checkout(checkout))
        XCTAssertEqual(commands.last?.0, "docker compose -p shop-wt-feat -f \(real)/compose.yaml -f \(store.file(of: kept).path) up -d")
        XCTAssertTrue(page.error?.contains("didn't answer") == true, page.error ?? "said nothing")
        XCTAssertEqual(alerts.count, 1, "said where it can be seen")
        XCTAssertEqual(store.override(in: real), kept, "kept as it was")
    }

    /// Asked for free ports where the files aren't (a remote engine's
    /// project): nothing typed, and why.
    func testFreePortsWithNoFilesHereSaysWhy() async throws {
        try stub(version: "2.29.7", config: "{}")
        let page = page(store())
        let remote = ComposeProject(name: "shop", workingDir: "/srv/shop", configFiles: ["/srv/shop/compose.yaml"], services: [])
        XCTAssertEqual(page.freePortsUnavailable(remote), "Its compose files aren't on this Mac.")
        XCTAssertEqual(page.verbs(for: remote).first { $0.title == "Up on Free Ports" }?.unavailable, "Its compose files aren't on this Mac.")
        await page.up(.project(remote), freePorts: .yes)
        XCTAssertTrue(commands.isEmpty, "not the same taken ports again")
        XCTAssertEqual(page.error, "Up on Free Ports can't move shop's ports: its compose files aren't on this Mac.")
        XCTAssertEqual(alerts.count, 1)
        await page.up(.project(remote))
        XCTAssertEqual(commands.map(\.0), ["docker compose -p shop -f /srv/shop/compose.yaml up -d"], "a plain Up is typed as it always was")
    }

    /// A kept move whose port is held since, the file's free again: back on
    /// the file's, said — and with nothing left, the override forgotten.
    func testAKeptPortTakenSinceGoesBack() async throws {
        let checkout = try checkout()
        let real = FileTreeModel.realPath(checkout)
        let held = try hold()
        let port = free()
        try stub(version: "2.29.7", config: json([(port, 5432)]))
        let store = store()
        let kept = ComposePortOverride(
            folder: real, project: "shop", fileName: "shop", baseFiles: [real + "/compose.yaml"],
            moves: [ComposePortMove(service: "db", target: 5432, proto: "tcp", from: port, to: held)], made: Date())
        try store.save(kept, yaml: "name: \"shop\"\n")
        let page = page(store)
        await page.up(.checkout(checkout))
        XCTAssertNil(store.override(in: real), "nothing left to move: no empty override kept")
        XCTAssertEqual(commands.last?.0, "docker compose up -d", "as the files say")
        XCTAssertEqual(page.cleaned, "shop is on its compose file's ports again — db is back on \(port): \(held) is taken.")
        XCTAssertTrue(asked.isEmpty)
    }

    /// The question answered later: another window's override gave out
    /// the same port meanwhile, so it goes to the next free one.
    func testAnAnswerLooksAtThePortsAgain() async throws {
        let held = try hold()
        let checkout = try checkout()
        let real = FileTreeModel.realPath(checkout)
        try stub(version: "2.29.7", config: json([(held, 5432)]))
        let store = store()
        let page = page(store)
        var first: Int?
        answer = { then in
            // Another window answered first, for another worktree.
            let detail = self.asked.last?.detail ?? ""
            let to = detail.range(of: #"→ (\d+)"#, options: .regularExpression).flatMap { Int(detail[$0].dropFirst(2)) }
            first = to
            let other = ComposePortOverride(
                folder: self.root.appendingPathComponent("other").path, project: "shop-other", fileName: "shop", baseFiles: [],
                moves: [ComposePortMove(service: "db", target: 5432, proto: "tcp", from: held, to: to ?? 0)], made: Date())
            try? store.save(other, yaml: "name: other\n")
            then(0)
        }
        await page.up(.checkout(checkout))
        try await until("up on free ports") { commands.count == 1 }
        let to = try XCTUnwrap(first, asked.last?.detail ?? "not asked")
        let kept = try XCTUnwrap(store.override(in: real))
        XCTAssertNotEqual(kept.moves.first?.to, to, "never the same port as another override")
        XCTAssertEqual(page.cleaned, "shop: db \(to) was taken — it is on \(kept.moves.first?.to ?? 0) now.")
    }

    /// A test stack run from the same folder off other files is another
    /// stack: its ports are taken, its name isn't this one's.
    func testAnotherStackFromTheSameFolderIsntThisOne() async throws {
        let socket = "/tmp/ot-up-\(UUID().uuidString.prefix(8)).sock"
        let fake = FakeDockerEngine(socket: socket)
        try fake.start()
        defer { fake.stop() }
        let endpoint = DockerEndpoint(address: .unix(socket), context: nil, source: "test")
        let docker = DockerModel(endpoint: { endpoint }, retries: [.milliseconds(50)], poll: .milliseconds(200))
        docker.start()
        defer { docker.stop() }
        let checkout = try checkout()
        let real = FileTreeModel.realPath(checkout)
        let port = free(after: 31_000)
        _ = fake.add(
            name: "shop-test-db-1", image: "postgres", project: "shop-test", workingDir: real, service: "db",
            ports: [DockerPort(IP: "0.0.0.0", PrivatePort: 5432, PublicPort: port, Type: "tcp")], configFiles: [real + "/docker-compose.test.yml"])
        try await until("its project") { docker.projects.contains { $0.name == "shop-test" } }
        try stub(version: "2.29.7", config: json([(port, 5432)]))
        let store = store()
        let page = page(store, docker: docker)
        XCTAssertNil(page.upSetup(.checkout(checkout))?.running, "made from other files: not this stack")
        await page.up(.checkout(checkout))
        XCTAssertEqual(asked.first?.title, "db's port \(port) is taken", "\(asked)")
        XCTAssertTrue(asked.first?.detail.contains("shop-test-db-1 publishes it") == true, asked.first?.detail ?? "")
        try await until("up on free ports") { commands.count == 1 }
        let kept = try XCTUnwrap(store.override(in: real))
        XCTAssertEqual(kept.project, "shop", "the files' name, not the other stack's")
        XCTAssertTrue(commands.last?.0.contains("compose -p shop -f \(real)/compose.yaml -f ") == true, commands.last?.0 ?? "")
        let same = fake.add(name: "custom-db-1", image: "postgres", project: "custom", workingDir: real, service: "db", configFiles: [real + "/compose.yaml"])
        try await until("one from its files") { docker.projects.contains { $0.name == "custom" } }
        XCTAssertEqual(page.upSetup(.checkout(checkout))?.running, "custom", "one made from its files is it, whatever its name")
        try await docker.remove(same, force: true)

        // `U` on the test stack, whose files aren't here: as its verb, it
        // says why and types nothing.
        let typed = commands.count
        page.selection = [DockerPageModel.projectTag("shop-test")]
        page.press("U")
        XCTAssertEqual(page.error, "Up on Free Ports: Its compose files aren't on this Mac.")
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(commands.count, typed)
    }

    /// The files changed since the override was written: written again
    /// from them before Pull, the plan's read or anything else reads it —
    /// a service gone dropped, which Compose would refuse.
    func testTheOverrideFollowsItsFiles() async throws {
        let checkout = try checkout("shop-wt-x")
        let real = FileTreeModel.realPath(checkout)
        let base = real + "/compose.yaml"
        let store = store()
        let web = ComposePortMove(service: "web", target: 80, proto: "tcp", from: 8080, to: 18080)
        var kept = ComposePortOverride(folder: real, project: "shop-wt-x", fileName: "shop", baseFiles: [base], moves: [web], made: Date())
        kept.stamp = ComposePortStore.stamp(of: [base], folder: real)
        try store.save(kept, yaml: "name: \"shop-wt-x\"\nservices:\n  \"web\":\n    ports: !override\n")
        try stub(version: "2.29.7", config: json([(8080, 80)], service: "frontend"))
        let page = page(store)
        let plan = ComposeProject(name: "shop-wt-x", workingDir: real, configFiles: [], services: [], planned: true)

        // Unchanged: at once, nothing asked.
        page.compose("pull", plan)
        XCTAssertEqual(commands.last?.0, "docker compose -p shop-wt-x -f \(base) -f \(store.file(of: kept).path) pull")
        XCTAssertEqual(calls, "", "nothing read")

        // `web` renamed in the file: read, written again, then pulled.
        try "services:\n  frontend: {}\n".write(to: URL(fileURLWithPath: base), atomically: true, encoding: .utf8)
        XCTAssertTrue(store.needsRefresh(plan))
        page.compose("pull", plan)
        try await until("pulled") { commands.count == 2 }
        XCTAssertTrue(calls.contains("compose -f \(base) --profile * config --format json"), calls)
        let now = try XCTUnwrap(store.override(in: real))
        XCTAssertEqual(now.moves, [], "web is gone")
        XCTAssertEqual(now.project, "shop-wt-x", "its own name stays")
        XCTAssertFalse(store.needsRefresh(plan))
        XCTAssertFalse(try String(contentsOf: store.file(of: now), encoding: .utf8).contains("web"))
        XCTAssertEqual(commands.last?.0, "docker compose -p shop-wt-x -f \(base) -f \(store.file(of: now).path) pull")

        // The plan's read: its name, its files, then the override.
        let output = try await ComposeFileModel.compose(in: checkout, endpoint: nil, ports: store)
        XCTAssertEqual(output, json([(8080, 80)], service: "frontend"))
        XCTAssertTrue(calls.contains("compose -p shop-wt-x -f \(base) -f \(store.file(of: now).path) config --format json"), calls)

        // Its name the files' now, nothing moved: forgotten.
        try stub(version: "2.29.7", config: json([(8080, 80)], name: "shop-wt-x", service: "frontend"))
        try "services:\n  frontend: {image: x}\n".write(to: URL(fileURLWithPath: base), atomically: true, encoding: .utf8)
        await store.refresh(real, endpoint: nil)
        XCTAssertNil(store.override(in: real), "nothing left of it")
    }
}
