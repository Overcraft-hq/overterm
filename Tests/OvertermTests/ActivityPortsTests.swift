import Darwin
import Foundation
import XCTest

@testable import Overterm
@testable import OvertermCore

/// Listening's rows (docs/design/activity/analysis.md, 6.8) over a fake Mac:
/// a holder's v4 and v6 as one row, UDP, the URL by the bound families; the
/// owners in order — a container by its published address, port and
/// protocol (and one nobody in scope is seen holding), a forward, a tunnel,
/// the bridge, a pane, a known holder, a launchd job —; co-holders of one
/// socket; connections paired by the 4-tuple, the listener's clients, a
/// tunnel client's forward; apps' ephemeral listeners folded. Every name is
/// invented.
final class ActivityPortsTests: XCTestCase {
    private let kernel = FakeActivityKernel(uid: 501)
    private let app: pid_t = 1000
    private let tab = UUID()
    private let checkout = "/tmp/acme-shop"

    @discardableResult
    private func add(
        _ pid: pid_t, parent: pid_t, uid: uid_t = 501, name: String, path: String? = nil, words: [String]? = nil, environment: [String] = [],
        sockets: [socket_fdinfo] = []
    ) -> ActivityProcessID {
        let start = UInt64(pid) * 1_000
        var process = FakeActivityKernel.Process(
            record: FakeActivityKernel.record(pid: pid, start: start, parent: parent, uid: uid, realUID: uid == 0 ? 501 : nil, name: name))
        process.name = name
        process.path = path ?? (uid == 501 ? "/opt/acme/bin/\(name)" : "/usr/libexec/\(name)")
        process.codeSigning = ActivityCodeSigning(flags: ActivityCodeSigning.valid)
        process.usage = FakeActivityKernel.usage(footprint: 8 << 20, threads: 3)
        process.arguments = FakeActivityKernel.arguments(executable: process.path ?? name, words ?? [name], environment: environment)
        process.descriptors = sockets.indices.map { FakeActivityKernel.descriptor(Int32(3 + $0)) }
        process.sockets = Dictionary(uniqueKeysWithValues: sockets.enumerated().map { (Int32(3 + $0.offset), $0.element) })
        kernel.add(process)
        return ActivityProcessID(pid: pid, start: start)
    }

    /// launchd, the app and a pane: its `login`, a shell, a server on
    /// 127.0.0.1:5173 and [::1]:5173 (one row, v4 + v6) and UDP 5353.
    private func mac() -> ActivityContext {
        add(1, parent: 0, uid: 0, name: "launchd")
        add(app, parent: 1, name: "Overterm")
        let login = add(1100, parent: app, uid: 0, name: "login")
        add(1101, parent: 1100, name: "zsh")
        add(
            1102, parent: 1101, name: "acme-server",
            sockets: [
                FakeActivityKernel.tcp(local: "127.0.0.1", port: 5173, handle: 1), FakeActivityKernel.tcp(local: "::1", port: 5173, handle: 2),
                FakeActivityKernel.udp(local: "127.0.0.1", port: 5353, handle: 3),
            ])
        return ActivityContext(panes: [ActivityContext.Pane(tag: "pane-a", tab: tab, login: login)], appPID: app)
    }

    private func content(_ context: ActivityContext, _ change: (inout ActivityRows.Options) -> Void = { _ in }) throws -> ActivityPageContent {
        let snapshot = try XCTUnwrap(ActivitySampler(kernel: kernel).tickNow(ActivityDemand(.full), context: context))
        var options = ActivityRows.Options(tabs: [tab: ActivityTabFacts(id: tab, title: "web", checkout: checkout, branch: "feature-x")])
        options.context = context
        change(&options)
        return ActivityRows.content(of: snapshot, options)
    }

    private func row(_ content: ActivityPageContent, port: Int, proto: String = "tcp", process: String? = nil) throws -> ActivityPortRow {
        try XCTUnwrap(content.ports.first { $0.port == port && $0.proto == proto && (process == nil || $0.process == process) && $0.kind == .listener })
    }

    func testAHoldersFamiliesAreOneRowUDPToo() throws {
        let content = try content(mac())
        let server = try row(content, port: 5173)
        XCTAssertEqual(server.familyWords, "v4 + v6", "its v4 and v6 sockets, one row")
        XCTAssertEqual(server.reach, "This Mac")
        XCTAssertEqual(server.url?.absoluteString, "http://localhost:5173", "both families on loopback: localhost")
        XCTAssertEqual(server.portOwner, .pane)
        XCTAssertEqual(server.owner, "tab")
        XCTAssertEqual(server.ownerText, "“web”")
        XCTAssertEqual(server.whereText, "“web” · acme-shop · feature-x")
        XCTAssertEqual(server.tab, tab)
        XCTAssertEqual(server.sinceText.isEmpty, false)
        let udp = try row(content, port: 5353, proto: "udp")
        XCTAssertNil(udp.url, "UDP has no Open")
        XCTAssertEqual(content.summary.listening, 2)
    }

    func testURLsFollowTheBoundFamilies() throws {
        let context = mac()
        add(2000, parent: 1, name: "acme-v4", sockets: [FakeActivityKernel.tcp(local: "127.0.0.1", port: 3000, handle: 10)])
        add(2001, parent: 1, name: "acme-v6", sockets: [FakeActivityKernel.tcp(local: "::1", port: 3001, handle: 11)])
        add(2002, parent: 1, name: "acme-dual", sockets: [FakeActivityKernel.tcp(local: "::", port: 3002, dualStack: true, handle: 12)])
        add(2003, parent: 1, name: "acme-lan", sockets: [FakeActivityKernel.tcp(local: "192.0.2.7", port: 3003, handle: 13)])
        let content = try content(context)
        XCTAssertEqual(try row(content, port: 3000).url?.absoluteString, "http://127.0.0.1:3000", "v4 only: never the ::1 trap")
        XCTAssertEqual(try row(content, port: 3001).url?.absoluteString, "http://[::1]:3001")
        XCTAssertEqual(try row(content, port: 3002).url?.absoluteString, "http://localhost:3002")
        XCTAssertEqual(try row(content, port: 3002).reach, "Network")
        XCTAssertEqual(try row(content, port: 3003).url?.absoluteString, "http://192.0.2.7:3003")
        XCTAssertEqual(try row(content, port: 3003).reach, "Network · 192.0.2.7")
    }

    func testAContainerByItsPublishedAddressPortAndProtocol() throws {
        var context = mac()
        add(
            3000, parent: 1, name: "com.docker.backend",
            sockets: [FakeActivityKernel.tcp(local: "127.0.0.1", port: 5432, handle: 20), FakeActivityKernel.tcp(local: "0.0.0.0", port: 8080, handle: 21)])
        context.published = [
            ActivityContext.PublishedPort(container: "acme-db", project: "acme-shop", address: "127.0.0.1", port: 5432, proto: "tcp"),
            // On 127.0.0.1 only: the engine's wildcard 8080 isn't it.
            ActivityContext.PublishedPort(container: "acme-web", project: "acme-shop", address: "127.0.0.1", port: 8080, proto: "tcp"),
            ActivityContext.PublishedPort(container: "acme-cache", project: "acme-shop", address: "", port: 6379, proto: "tcp"),
        ]
        let containers = [
            ActivityContainer(id: "a", name: "acme-db", project: "acme-shop", folder: checkout),
            ActivityContainer(id: "b", name: "acme-cache", project: "acme-shop", folder: checkout),
        ]
        let content = try content(context) { $0.containers = containers }
        let db = try row(content, port: 5432)
        XCTAssertEqual(db.portOwner, .container(name: "acme-db", project: "acme-shop"))
        XCTAssertEqual(db.ownerText, "container acme-db · acme-shop · via com.docker.backend")
        XCTAssertEqual(db.checkout, "acme-shop")
        XCTAssertEqual(db.tab, tab, "Open goes to a tab of its checkout")
        XCTAssertEqual(db.url?.absoluteString, "http://127.0.0.1:5432")
        XCTAssertEqual(db.owner, "container")
        let web = try row(content, port: 8080)
        XCTAssertNotEqual(web.portOwner, .container(name: "acme-web", project: "acme-shop"), "the number alone never matches")
        let cache = try XCTUnwrap(content.ports.first { $0.port == 6379 })
        XCTAssertNil(cache.holder, "nobody in scope is seen holding it")
        XCTAssertEqual(cache.ownerText, "container acme-cache · acme-shop · via the engine")
        XCTAssertEqual(cache.reach, "Network")
        XCTAssertEqual(cache.url?.absoluteString, "http://localhost:6379")
        let tabOnly = try self.content(context) {
            $0.containers = containers
            $0.scope = .tab(tab)
        }
        XCTAssertNil(tabOnly.ports.first { $0.port == 6379 }, "a tab's scope is its panes, never the stack")
        let checkoutScope = try self.content(context) {
            $0.containers = containers
            $0.scope = .checkout(checkout)
        }
        XCTAssertNotNil(checkoutScope.ports.first { $0.port == 6379 }, "the checkout's scope lists its stack")
    }

    func testAForwardATunnelAndTheBridge() throws {
        var context = mac()
        add(app + 1, parent: app, name: "kubectl", sockets: [FakeActivityKernel.tcp(local: "127.0.0.1", port: 31083, handle: 30)])
        add(app + 2, parent: app, name: "ssh", sockets: [FakeActivityKernel.tcp(local: "127.0.0.1", port: 40001, handle: 31)])
        kernel.update(app) { $0.descriptors = [FakeActivityKernel.descriptor(3)] }
        kernel.update(app) { $0.sockets = [3: FakeActivityKernel.tcp(local: "127.0.0.1", port: 45999, handle: 32)] }
        context.forwards = [ActivityContext.Forward(pid: app + 1, port: 31083, target: "svc/acme-api:80", tab: tab, https: true)]
        context.tunnels = [ActivityContext.Tunnel(pid: app + 2, port: 40001, name: "acme-staging-db")]
        context.bridgePort = 45999
        let content = try content(context)
        let forward = try row(content, port: 31083)
        XCTAssertEqual(forward.portOwner, .forward(target: "svc/acme-api:80"))
        XCTAssertEqual(forward.ownerText, "port-forward → svc/acme-api:80")
        XCTAssertEqual(forward.tab, tab, "the tab that asked for it")
        XCTAssertEqual(forward.url?.scheme, "https", "a forward keeps its https")
        XCTAssertEqual(forward.owner, "forward")
        let tunnel = try row(content, port: 40001)
        XCTAssertEqual(tunnel.ownerText, "the database tunnel “acme-staging-db”")
        XCTAssertNil(tunnel.url, "a database's port opens in no browser")
        let bridge = try row(content, port: 45999)
        XCTAssertEqual(bridge.portOwner, .bridge)
        XCTAssertEqual(bridge.ownerText, "Overterm — the agents' MCP bridge")
        XCTAssertEqual(bridge.owner, "overterm")
    }

    func testKnownHoldersAndLaunchdJobs() throws {
        let context = mac()
        add(
            2100, parent: 1, name: "ControlCenter", path: "/System/Library/CoreServices/ControlCenter.app/Contents/MacOS/ControlCenter",
            sockets: [FakeActivityKernel.tcp(local: "0.0.0.0", port: 5000, handle: 40)])
        add(
            2101, parent: 1, name: "fake-db", environment: ["XPC_SERVICE_NAME=homebrew.mxcl.fake-db@16"],
            sockets: [FakeActivityKernel.tcp(local: "127.0.0.1", port: 5433, handle: 41)])
        add(2102, parent: 1, name: "globex-dev", sockets: [FakeActivityKernel.tcp(local: "127.0.0.1", port: 8081, handle: 42)])
        add(
            2103, parent: 1, name: "fake-app", environment: ["XPC_SERVICE_NAME=application.com.example.fake"],
            sockets: [FakeActivityKernel.tcp(local: "127.0.0.1", port: 8082, handle: 43)])
        let content = try content(context) {
            $0.launchAgents = [LaunchdJobs.Agent(label: "com.example.globex-dev", program: "/opt/acme/bin/globex-dev")]
        }
        let airPlay = try row(content, port: 5000)
        XCTAssertEqual(airPlay.portOwner, .known(KnownHolders.airPlay))
        XCTAssertEqual(airPlay.ownerText, "AirPlay Receiver")
        XCTAssertTrue(airPlay.note?.contains("AirDrop & Handoff") == true, "where it is turned off")
        XCTAssertEqual(try row(content, port: 5433).ownerText, "brew service fake-db@16")
        XCTAssertEqual(try row(content, port: 5433).owner, "service")
        XCTAssertEqual(try row(content, port: 8081).ownerText, "launchd job com.example.globex-dev", "matched by the plist's program")
        XCTAssertEqual(try row(content, port: 8082).ownerText, "yours elsewhere", "an app's application.* label is no job")
    }

    func testLaunchAgentPlistsAreReadByLabelAndProgram() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("acme-agents-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        func write(_ name: String, _ plist: [String: Any]) throws {
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: folder.appendingPathComponent(name))
        }
        try write("com.example.one.plist", ["Label": "com.example.one", "Program": "/opt/acme/bin/one"])
        try write("com.example.two.plist", ["Label": "com.example.two", "ProgramArguments": ["/opt/acme/bin/two", "--serve"]])
        try write("com.example.relative.plist", ["Label": "com.example.relative", "ProgramArguments": ["two"]])
        try Data("not a plist".utf8).write(to: folder.appendingPathComponent("broken.plist"))
        let agents = LaunchdJobs.agents(in: folder)
        XCTAssertEqual(Set(agents), [LaunchdJobs.Agent(label: "com.example.one", program: "/opt/acme/bin/one"), LaunchdJobs.Agent(label: "com.example.two", program: "/opt/acme/bin/two")])
        XCTAssertEqual(LaunchdJobs.job(path: "/opt/acme/bin/two", parent: 1, agents: agents)?.label, "com.example.two")
        XCTAssertNil(LaunchdJobs.job(path: "/opt/acme/bin/two", parent: 4242, agents: agents), "only what launchd started")
        XCTAssertNil(LaunchdJobs.job(service: "0"))
        XCTAssertEqual(LaunchdJobs.job(service: "homebrew.mxcl.fake")?.title, "brew service fake")
        XCTAssertEqual(LaunchdJobs.cachedAgents(in: folder).count, 2)
        XCTAssertTrue(LaunchdJobs.cachedAgents(in: nil).isEmpty, "a test run reads none")
        XCTAssertNil(AppEnvironment.launchAgentsDirectory, "none under test (9.9)")
    }

    func testProcessesSharingOneSocketAreOneRow() throws {
        let context = mac()
        add(2200, parent: 1, name: "acme-master", sockets: [FakeActivityKernel.tcp(local: "0.0.0.0", port: 9000, handle: 50)])
        add(2201, parent: 2200, name: "acme-worker", sockets: [FakeActivityKernel.tcp(local: "0.0.0.0", port: 9000, handle: 50)])
        add(2202, parent: 2200, name: "acme-worker", sockets: [FakeActivityKernel.tcp(local: "0.0.0.0", port: 9000, handle: 50)])
        let content = try content(context)
        let rows = content.ports.filter { $0.port == 9000 }
        XCTAssertEqual(rows.count, 1, "one socket, its holders on one row")
        XCTAssertEqual(rows.first?.process, "acme-master", "the oldest holds it")
        XCTAssertEqual(rows.first?.processText, "acme-master +2 holders")
        XCTAssertTrue(rows.first?.collisions.isEmpty == true, "sharing a socket isn't a collision")
    }

    func testConnectionsArePairedByTheFourTuple() throws {
        let context = mac()
        // The server's end of a connection from a browser of the user's.
        kernel.update(1102) { process in
            process.descriptors.append(FakeActivityKernel.descriptor(10))
            process.sockets[10] = FakeActivityKernel.tcp(
                local: "127.0.0.1", port: 5173, remote: "127.0.0.1", remotePort: 50_001, state: .established, handle: 60)
        }
        add(
            2300, parent: 1, name: "fake-browser",
            sockets: [
                FakeActivityKernel.tcp(local: "127.0.0.1", port: 50_001, remote: "127.0.0.1", remotePort: 5173, state: .established, handle: 61),
                FakeActivityKernel.tcp(local: "192.0.2.5", port: 50_002, remote: "198.51.100.9", remotePort: 443, state: .established, handle: 62),
                FakeActivityKernel.tcp(local: "192.0.2.5", port: 50_003, remote: "198.51.100.9", remotePort: 443, state: .established, handle: 63),
            ])
        let off = try content(context)
        XCTAssertTrue(off.ports.allSatisfy { $0.kind != .connection }, "connections only when asked")
        XCTAssertEqual(try row(off, port: 5173).clients, 1, "the listener counts its paired clients anyway")
        let on = try content(context) { $0.connections = true }
        let connections = on.ports.filter { $0.kind == .connection }
        XCTAssertEqual(connections.count, 2, "one paired line, one counted line to the remote end")
        let paired = try XCTUnwrap(connections.first { $0.port == 5173 })
        XCTAssertEqual(paired.process, "fake-browser → acme-server :5173")
        XCTAssertEqual(paired.ownerText, "acme-server in “web”")
        let remote = try XCTUnwrap(connections.first { $0.port == 443 })
        XCTAssertEqual(remote.process, "fake-browser → 198.51.100.9:443 ×2")
        XCTAssertFalse(remote.id.contains("198.51"), "a remote address is never in a row's id")
        let filtered = try content(context) { $0.portFilter = "state:established" }
        XCTAssertEqual(filtered.ports.count, 2, "state:established asks for them, and shows only them")
        XCTAssertEqual(on.summary.listening, 2, "connections aren't counted as listening")
    }

    func testATunnelClientMakesALoopbackListenerReachable() throws {
        let context = mac()
        kernel.update(1102) { process in
            process.descriptors.append(FakeActivityKernel.descriptor(10))
            process.sockets[10] = FakeActivityKernel.tcp(
                local: "127.0.0.1", port: 5173, remote: "127.0.0.1", remotePort: 50_010, state: .established, handle: 70)
        }
        add(
            2400, parent: 1, name: "cloudflared",
            sockets: [FakeActivityKernel.tcp(local: "127.0.0.1", port: 50_010, remote: "127.0.0.1", remotePort: 5173, state: .established, handle: 71)])
        let content = try content(context)
        XCTAssertEqual(try row(content, port: 5173).reach, "forwarded by cloudflared (pid 2400)", "it isn't This Mac only")
    }

    func testAppsEphemeralListenersFoldATabsNever() throws {
        let context = mac()
        add(
            2500, parent: 1, name: "fake-app", path: "/Applications/FakeApp.app/Contents/MacOS/fake-app",
            sockets: [FakeActivityKernel.udp(local: "0.0.0.0", port: 52_000, handle: 80)])
        add(
            2501, parent: 1, name: "fake-app2", path: "/Applications/FakeApp2.app/Contents/MacOS/fake-app2",
            sockets: [FakeActivityKernel.tcp(local: "127.0.0.1", port: 52_001, handle: 81)])
        // A server the user started in another terminal: yours elsewhere,
        // never folded away.
        add(2502, parent: 1, name: "globex-server", sockets: [FakeActivityKernel.tcp(local: "127.0.0.1", port: 52_003, handle: 83)])
        kernel.update(1102) { process in
            process.descriptors.append(FakeActivityKernel.descriptor(10))
            process.sockets[10] = FakeActivityKernel.udp(local: "127.0.0.1", port: 52_002, handle: 82)
        }
        let folded = try content(context)
        XCTAssertNil(folded.ports.first { $0.port == 52_000 }, "folded")
        XCTAssertNotNil(folded.ports.first { $0.port == 52_002 }, "a tab's always shown")
        XCTAssertEqual(folded.ports.first { $0.port == 52_003 }?.ownerText, "yours elsewhere", "only apps' listeners fold")
        XCTAssertEqual(folded.summary.listening, 6, "the count is every listener, folded ones too")
        XCTAssertTrue(ActivitySwitcher.rows(of: folded).contains { $0.id == folded.listeners.first { $0.port == 52_000 }?.id }, "the switcher lists folded ones")
        let fold = try XCTUnwrap(folded.ports.last)
        XCTAssertEqual(fold.kind, .folded, "the fold last")
        XCTAssertEqual(fold.process, "2 ephemeral listeners of your apps")
        XCTAssertTrue(fold.spansColumns)
        XCTAssertNotNil(folded.listeners.first { $0.port == 52_000 }, "the detail and the switcher read every listener")
        let open = try content(context) { $0.folds = [ActivityPorts.ephemeralFold: false] }
        XCTAssertNotNil(open.ports.first { $0.port == 52_000 })
        XCTAssertEqual(open.ports.last?.folded, false)
        let filtered = try content(context) { $0.portFilter = "52000" }
        XCTAssertEqual(filtered.ports.map(\.port), [52_000], "a filter finds a folded one")
    }

    func testTheFiltersListeningKeys() throws {
        var context = mac()
        add(3000, parent: 1, name: "com.docker.backend", sockets: [FakeActivityKernel.tcp(local: "127.0.0.1", port: 5432, handle: 20)])
        context.published = [ActivityContext.PublishedPort(container: "acme-db", project: nil, address: "127.0.0.1", port: 5432, proto: "tcp")]
        XCTAssertEqual(try content(context) { $0.portFilter = "owner:container" }.ports.map(\.port), [5432])
        XCTAssertEqual(try content(context) { $0.portFilter = "acme-db" }.ports.map(\.port), [5432], "free text reads the owner")
        XCTAssertEqual(try content(context) { $0.portFilter = "owner:tab proto:tcp" }.ports.map(\.port), [5173])
        XCTAssertEqual(try content(context) { $0.portFilter = "family:6" }.ports.map(\.port), [5173])
    }

    func testASocketTwoProcessesHoldIsPairedOnce() throws {
        let context = mac()
        kernel.update(1102) { process in
            process.descriptors.append(FakeActivityKernel.descriptor(10))
            process.sockets[10] = FakeActivityKernel.tcp(
                local: "127.0.0.1", port: 5173, remote: "127.0.0.1", remotePort: 50_020, state: .established, handle: 90)
        }
        let client = FakeActivityKernel.tcp(local: "127.0.0.1", port: 50_020, remote: "127.0.0.1", remotePort: 5173, state: .established, handle: 91)
        add(2600, parent: 1, name: "fake-client", sockets: [client])
        // A fork after connect: the child holds the very same socket.
        add(2601, parent: 2600, name: "fake-client", sockets: [client])
        let content = try content(context) { $0.connections = true }
        let connections = content.ports.filter { $0.kind == .connection && $0.port == 5173 }
        XCTAssertEqual(connections.map(\.process), ["fake-client → acme-server :5173"], "one socket, one line")
        XCTAssertEqual(try row(content, port: 5173).clients, 1, "and one client")
    }

    func testAContainersOwnRowIsBoundAsItIsPublished() throws {
        var context = mac()
        // A checkout's server on 127.0.0.1:5432; its stack's container on
        // 0.0.0.0:5432, the engine's holder not in scope.
        add(1103, parent: 1101, name: "acme-db-dev", sockets: [FakeActivityKernel.tcp(local: "127.0.0.1", port: 5432, handle: 100)])
        context.published = [
            ActivityContext.PublishedPort(container: "acme-db", project: "acme-shop", address: "0.0.0.0", port: 5432, proto: "tcp"),
            ActivityContext.PublishedPort(container: "acme-v6", project: "acme-shop", address: "::", port: 6000, proto: "tcp"),
            ActivityContext.PublishedPort(container: "acme-both", project: "acme-shop", address: "0.0.0.0", port: 6001, proto: "tcp"),
            ActivityContext.PublishedPort(container: "acme-both", project: "acme-shop", address: "::", port: 6001, proto: "tcp"),
            ActivityContext.PublishedPort(container: "acme-lan", project: "acme-shop", address: "192.0.2.4", port: 6002, proto: "tcp"),
        ]
        let containers = ["acme-db", "acme-v6", "acme-both", "acme-lan"].map {
            ActivityContainer(id: $0, name: $0, project: "acme-shop", folder: checkout)
        }
        let content = try content(context) {
            $0.containers = containers
            $0.scope = .checkout(checkout)
        }
        let db = try XCTUnwrap(content.ports.first { $0.port == 5432 && $0.holder == nil })
        XCTAssertEqual(db.familyWords, "v4", "0.0.0.0 is IPv4's every address")
        XCTAssertEqual(db.url?.absoluteString, "http://127.0.0.1:5432", "v4 only: never the ::1 trap")
        XCTAssertEqual(db.collisions, [.wildcardBesideSpecific], "the container's wildcard beside the checkout's server")
        XCTAssertEqual(try row(content, port: 5432, process: "acme-db-dev").collisions, [.wildcardBesideSpecific], "said on both rows")
        let v6 = try XCTUnwrap(content.ports.first { $0.port == 6000 })
        XCTAssertEqual(v6.familyWords, "v6")
        XCTAssertEqual(v6.url?.absoluteString, "http://[::1]:6000")
        let both = content.ports.filter { $0.port == 6001 }
        XCTAssertEqual(both.count, 1, "published on both families: one row")
        XCTAssertEqual(both.first?.familyWords, "v4 + v6")
        XCTAssertEqual(both.first?.url?.absoluteString, "http://localhost:6001", "localhost only where both families are published")
        let lan = try XCTUnwrap(content.ports.first { $0.port == 6002 })
        XCTAssertEqual(lan.url?.absoluteString, "http://192.0.2.4:6002")
        XCTAssertEqual(lan.reach, "Network · 192.0.2.4")
    }

    func testAHoldersContainerKeepsTheURLItsSocketsGive() throws {
        var context = mac()
        add(3000, parent: 1, name: "com.docker.backend", sockets: [FakeActivityKernel.tcp(local: "0.0.0.0", port: 8443, handle: 110)])
        context.published = [ActivityContext.PublishedPort(container: "acme-web", project: nil, address: "0.0.0.0", port: 8443, proto: "tcp")]
        let web = try row(try content(context), port: 8443)
        XCTAssertEqual(web.portOwner, .container(name: "acme-web", project: nil))
        XCTAssertEqual(web.url?.absoluteString, "http://127.0.0.1:8443", "v4 only: its bound family's URL")
    }

    func testOneNumberOnTwoHostAddressesIsTwoContainers() throws {
        var context = mac()
        add(
            3000, parent: 1, name: "com.docker.backend",
            sockets: [FakeActivityKernel.tcp(local: "127.0.0.1", port: 7001, handle: 120), FakeActivityKernel.tcp(local: "192.0.2.4", port: 7001, handle: 121)])
        context.published = [
            ActivityContext.PublishedPort(container: "acme-api", project: nil, address: "127.0.0.1", port: 7001, proto: "tcp"),
            ActivityContext.PublishedPort(container: "globex-api", project: nil, address: "192.0.2.4", port: 7001, proto: "tcp"),
        ]
        let content = try content(context)
        let rows = content.ports.filter { $0.port == 7001 }
        XCTAssertEqual(rows.count, 2, "a row each")
        XCTAssertEqual(Set(rows.map(\.portOwner)), [.container(name: "acme-api", project: nil), .container(name: "globex-api", project: nil)])
        XCTAssertEqual(Set(rows.map(\.id)).count, 2)
        XCTAssertEqual(rows.first { $0.portOwner == .container(name: "acme-api", project: nil) }?.url?.absoluteString, "http://127.0.0.1:7001")
        XCTAssertEqual(rows.first { $0.portOwner == .container(name: "globex-api", project: nil) }?.url?.absoluteString, "http://192.0.2.4:7001")
    }

    func testAnEnginesListenerOnNoPublishedPortIsHostNetwork() throws {
        let context = mac()
        add(3000, parent: 1, name: "com.docker.backend", sockets: [FakeActivityKernel.tcp(local: "0.0.0.0", port: 9100, handle: 130)])
        let row = try row(try content(context), port: 9100)
        XCTAssertEqual(row.portOwner, .engine("Docker"))
        XCTAssertEqual(row.ownerText, "Docker’s engine — host network")
        XCTAssertEqual(row.owner, "container")
    }

    func testConnectionsPastTheCapAreCountedAndStillForward() throws {
        let context = mac()
        var sockets: [socket_fdinfo] = []
        for index in 0..<(ActivityPorts.connectionCap + 3) {
            sockets.append(
                FakeActivityKernel.tcp(
                    local: "192.0.2.5", port: UInt16(20_000 + index), remote: "198.51.100.\(index % 250 + 1)", remotePort: UInt16(1_000 + index),
                    state: .established, handle: UInt64(10_000 + index)))
        }
        // Older than the server: its lines come first and fill the cap.
        add(1050, parent: 1, name: "fake-crawler", sockets: sockets)
        kernel.update(1102) { process in
            process.descriptors.append(FakeActivityKernel.descriptor(10))
            process.sockets[10] = FakeActivityKernel.tcp(
                local: "127.0.0.1", port: 5173, remote: "127.0.0.1", remotePort: 50_030, state: .established, handle: 140)
        }
        // The tunnel's pair comes last: past the cap.
        add(
            2800, parent: 1, name: "cloudflared",
            sockets: [FakeActivityKernel.tcp(local: "127.0.0.1", port: 50_030, remote: "127.0.0.1", remotePort: 5173, state: .established, handle: 141)])
        let content = try content(context) { $0.connections = true }
        XCTAssertEqual(content.ports.filter { $0.kind == .connection }.count, ActivityPorts.connectionCap)
        XCTAssertEqual(content.droppedConnections, 4, "said, never silently cut")
        XCTAssertEqual(try row(content, port: 5173).reach, "forwarded by cloudflared (pid 2800)", "from every pair, not the kept lines")
        XCTAssertEqual(try row(content, port: 5173).clients, 1)
        XCTAssertTrue(ActivityPageView.listeningNote(connections: true, dropped: 4).contains("+4 more connections"))
    }

    func testOpenAsHTTPS() {
        XCTAssertEqual(ActivityPageModel.https(URL(string: "http://127.0.0.1:8443"))?.absoluteString, "https://127.0.0.1:8443")
        XCTAssertNil(ActivityPageModel.https(URL(string: "https://127.0.0.1:8443")), "already https")
        XCTAssertNil(ActivityPageModel.https(nil))
    }

    func testLaunchAgentsAreRegularFilesTheirProgramsResolved() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("acme-agents-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        // A program behind a link, as Homebrew's opt/<formula> is.
        let cellar = folder.appendingPathComponent("acme-server-1.0")
        try Data().write(to: cellar)
        let opt = folder.appendingPathComponent("acme-server")
        try FileManager.default.createSymbolicLink(at: opt, withDestinationURL: cellar)
        let plist = try PropertyListSerialization.data(fromPropertyList: ["Label": "homebrew.mxcl.acme-server", "Program": opt.path], format: .xml, options: 0)
        let real = folder.appendingPathComponent("plain.plist")
        try plist.write(to: real)
        // A link to a plist, and a FIFO: never read.
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("linked.plist"), withDestinationURL: real)
        XCTAssertEqual(mkfifo(folder.appendingPathComponent("pipe.plist").path, 0o600), 0)
        let agents = LaunchdJobs.agents(in: folder)
        XCTAssertEqual(agents.count, 1, "the regular file alone")
        let resolved = try XCTUnwrap(agents.first).program
        XCTAssertEqual(resolved, LaunchdJobs.resolved(cellar.path), "the link resolved to its target")
        XCTAssertTrue(resolved.hasSuffix("/acme-server-1.0"))
        XCTAssertEqual(LaunchdJobs.job(path: resolved, parent: 1, agents: agents)?.title, "brew service acme-server")
    }
}
