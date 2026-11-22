import Darwin
import Foundation
import XCTest

@testable import Overterm
@testable import OvertermCore

/// Stage 4's listeners (docs/design/activity/analysis.md, 6.8, D-25,
/// D-32) over a fake Mac: other users' from a nettop reading, launchd's
/// named from its socket jobs, macOS's daemons by name, a blind or narrow
/// read showing none; a forward typed in a pane saying its target, an `ssh
/// -R` named as the tunnel; the user's unix-socket listeners behind their
/// setting; Free's step for each. Every name is invented.
final class ActivityListenerSourcesTests: XCTestCase {
    private let kernel = FakeActivityKernel(uid: 501)
    private let app: pid_t = 1000
    private let tab = UUID()

    @discardableResult
    private func add(
        _ pid: pid_t, parent: pid_t, uid: uid_t = 501, name: String, words: [String]? = nil, sockets: [socket_fdinfo] = [], platform: Bool = false
    ) -> ActivityProcessID {
        let start = UInt64(pid) * 1_000
        var process = FakeActivityKernel.Process(record: FakeActivityKernel.record(pid: pid, start: start, parent: parent, uid: uid, name: name))
        process.name = name
        process.path = uid == 501 ? "/opt/acme/bin/\(name)" : "/usr/libexec/\(name)"
        process.codeSigning = ActivityCodeSigning(flags: ActivityCodeSigning.valid | (platform ? ActivityCodeSigning.platformBinary : 0))
        process.usage = FakeActivityKernel.usage(footprint: 8 << 20, threads: 3)
        process.arguments = FakeActivityKernel.arguments(executable: process.path ?? name, words ?? [name], environment: [])
        process.descriptors = sockets.indices.map { FakeActivityKernel.descriptor(Int32(3 + $0)) }
        process.sockets = Dictionary(uniqueKeysWithValues: sockets.enumerated().map { (Int32(3 + $0.offset), $0.element) })
        kernel.add(process)
        return ActivityProcessID(pid: pid, start: start)
    }

    /// launchd, the app, a pane with a server on 127.0.0.1:3000, another
    /// user's daemon and macOS's Bonjour.
    private func mac() -> ActivityContext {
        add(1, parent: 0, uid: 0, name: "launchd", platform: true)
        add(app, parent: 1, name: "Overterm")
        let login = add(1100, parent: app, uid: 0, name: "login")
        add(1101, parent: 1100, name: "zsh")
        add(1102, parent: 1101, name: "acme-server", sockets: [FakeActivityKernel.tcp(local: "127.0.0.1", port: 3000, handle: 1)])
        add(300, parent: 1, uid: 65, name: "mDNSResponder", platform: true)
        add(400, parent: 1, uid: 0, name: "globex-agent")
        return ActivityContext(panes: [ActivityContext.Pane(tag: "pane-a", tab: tab, login: login)], appPID: app)
    }

    private func snapshot(_ context: ActivityContext) throws -> ActivitySnapshot {
        try XCTUnwrap(ActivitySampler(kernel: kernel).tickNow(ActivityDemand(.full), context: context))
    }

    private func content(_ context: ActivityContext, _ change: (inout ActivityRows.Options) -> Void = { _ in }) throws -> ActivityPageContent {
        let snapshot = try snapshot(context)
        var options = ActivityRows.Options(tabs: [tab: ActivityTabFacts(id: tab, title: "web", checkout: "/tmp/acme-shop", branch: "feature-x")])
        options.context = context
        change(&options)
        return ActivityRows.content(of: snapshot, options)
    }

    private static let text = """
        ,state,
        launchd.1,,
        tcp4 127.0.0.1:8021<->*:*,Listen,
        tcp6 ::1.8021<->*.*,Listen,
        tcp4 127.0.0.1:9090<->*:*,Listen,
        launchd.1,,
        tcp4 127.0.0.1:8080<->*:*,Listen,
        mDNSResponder.300,,
        udp4 *:5353<->*:*,,
        globex-agent.400,,
        tcp4 *:7777<->*:*,Listen,
        acme-server.1102,,
        tcp4 127.0.0.1:3000<->*:*,Listen,
        gone.4999,,
        tcp4 *:6000<->*:*,Listen,

        """

    private func reading(_ snapshot: ActivitySnapshot, text: String = text) -> NettopListeners.Reading {
        NettopListeners.reading(text, status: 0, date: Date(), expected: NettopListeners.expected(in: snapshot))
    }

    private let jobs = [
        LaunchdSockets.Job(label: "com.acme.fake-proxy", port: 8021, proto: "tcp", domain: .system),
        LaunchdSockets.Job(label: "com.globex.dev", port: 8080, proto: "tcp", domain: .user),
    ]

    func testOtherUsersListenersFromACheckedRead() throws {
        let context = mac()
        let read = reading(try snapshot(context))
        XCTAssertEqual(read.outcome, .read(.checked), "it holds the user's own :3000")
        let content = try content(context) {
            $0.others = read
            $0.othersState = ActivityOtherListeners.of(read, period: 10)
            $0.launchdSockets = jobs
        }
        func row(_ port: Int, _ proto: String = "tcp") -> ActivityPortRow? { content.ports.first { $0.port == port && $0.proto == proto } }
        let proxy = try XCTUnwrap(row(8021))
        XCTAssertEqual(proxy.holder?.pid, 1)
        XCTAssertEqual(proxy.familyWords, "v4 + v6", "its v4 and v6 one row")
        XCTAssertEqual(proxy.portOwner, .launchdSocket(jobs[0]))
        XCTAssertEqual(proxy.ownerText, "launchd — com.acme.fake-proxy")
        XCTAssertEqual(proxy.owner, "system")
        XCTAssertEqual(proxy.user, "root")
        XCTAssertEqual(proxy.sinceText, ActivityRows.startedText(Date(timeIntervalSince1970: 0.001), today: Calendar.current.startOfDay(for: Date())), "its holder's start")
        XCTAssertFalse(proxy.sinceText.isEmpty)
        guard case .refused(let why)? = ActivityPortHolder.step(for: proxy) else { return XCTFail("launchd is never signalled") }
        XCTAssertTrue(why.contains("com.acme.fake-proxy"), why)

        let mine = try XCTUnwrap(row(8080))
        XCTAssertEqual(mine.portOwner, .service(LaunchdJobs.Job(label: "com.globex.dev")), "launchd holding the user's own job's socket")
        XCTAssertEqual(ActivityPortHolder.step(for: mine), .stopService(LaunchdJobs.Job(label: "com.globex.dev")), "its own stop, in the gui domain")

        let unnamed = try XCTUnwrap(row(9090))
        XCTAssertEqual(unnamed.portOwner, .known(try XCTUnwrap(KnownHolders.holder("launchd", port: 9090))))
        if case .refused? = ActivityPortHolder.step(for: unnamed) {} else { XCTFail("launchd unnamed: refused all the same") }

        let bonjour = try XCTUnwrap(row(5353, "udp"))
        XCTAssertEqual(bonjour.ownerText, "Bonjour")
        XCTAssertEqual(bonjour.owner, "macos")

        let other = try XCTUnwrap(row(7777))
        XCTAssertEqual(other.portOwner, .system(user: other.user ?? "?"))
        XCTAssertEqual(ActivityPortHolder.step(for: other), .readRoute(user: other.user ?? "?"), "another user's: the read route")

        XCTAssertEqual(content.ports.filter { $0.port == 3000 }.count, 1, "the user's own stay libproc's")
        XCTAssertNil(row(6000), "a pid the table doesn't list")
        XCTAssertEqual(content.summary.others, .checked(read.date, period: 10))
        XCTAssertTrue(ActivityPageView.listeningNote(connections: false, dropped: 0, others: content.summary.others).contains("every 10 s, checked against yours"))
        XCTAssertTrue(ActivityOtherListeners.checked(read.date, period: 25).sentence.contains("every 25 s"), "the period the interval makes")
    }

    /// A reading is up to three periods old: a process that started after
    /// it began took an ended listener's pid, and isn't its holder.
    func testAPidTakenSinceTheReadIsNotItsHolder() throws {
        let context = mac()
        var read = reading(try snapshot(context))
        read.date = Date(timeIntervalSince1970: 0.35)  // after launchd (0.001 s) and mDNSResponder (0.3 s), before pid 400 (0.4 s)
        let content = try content(context) {
            $0.others = read
            $0.launchdSockets = jobs
        }
        XCTAssertNil(content.ports.first { $0.port == 7777 }, "pid 400 started after the read: not its holder")
        XCTAssertNotNil(content.ports.first { $0.port == 8021 }, "launchd started before it")
        XCTAssertNotNil(content.ports.first { $0.port == 5353 })
    }

    /// Other users' ephemeral listeners fold apart from the user's apps'.
    func testOtherUsersEphemeralListenersFoldApart() throws {
        let context = mac()
        let text = ",state,\nmDNSResponder.300,,\nudp4 *:50001<->*:*,,\nudp6 *.50002<->*.*,,\nacme-server.1102,,\ntcp4 127.0.0.1:3000<->*:*,Listen,\n"
        let read = reading(try snapshot(context), text: text)
        let content = try content(context) { $0.others = read }
        let folds = content.ports.filter { $0.kind == .folded }
        XCTAssertEqual(folds.map(\.id), [ActivityPorts.ephemeralOthersFold])
        XCTAssertEqual(folds.first?.process, "2 ephemeral listeners of macOS and other users")
        XCTAssertFalse(content.ports.contains { $0.port == 50001 && $0.kind == .listener }, "folded by default")
    }

    func testABlindNarrowOrMineOnlyReadShowsNone() throws {
        let context = mac()
        let snapshot = try snapshot(context)
        let blind = reading(snapshot, text: ",state,\nlaunchd.1,,\ntcp4 127.0.0.1:8021<->*:*,Listen,\n")
        XCTAssertEqual(blind.outcome, .read(.blind(missing: 1)), "the user's :3000 isn't in it")
        let shown = try content(context) {
            $0.others = blind
            $0.othersState = ActivityOtherListeners.of(blind, period: 10)
        }
        XCTAssertFalse(shown.ports.contains { $0.port == 8021 }, "a blind read is unknown, never believed")
        XCTAssertEqual(shown.summary.others, .blind(missing: 1))
        XCTAssertTrue(shown.summary.others.sentence.hasPrefix("Other users' listeners: unknown"))

        let read = reading(snapshot)
        XCTAssertFalse(
            try content(context) {
                $0.others = read; $0.scope = .allTabs
            }.ports.contains { $0.port == 8021 }, "the Mac's scope only")
        XCTAssertFalse(
            try content(context) {
                $0.others = read; $0.everyone = false
            }.ports.contains { $0.port == 8021 }, "yours only (u)")
        XCTAssertEqual(try content(context).summary.others, .off)
    }

    func testAForwardTypedInAPaneSaysItsTarget() throws {
        let context = mac()
        add(
            1103, parent: 1101, name: "kubectl", words: ["kubectl", "port-forward", "-n", "acme", "--context=fake-dev", "svc/acme-web", "18080:80", "18443:443"],
            sockets: [FakeActivityKernel.tcp(local: "127.0.0.1", port: 18080, handle: 30)])
        add(
            1104, parent: 1101, name: "ssh", words: ["ssh", "-N", "-o", "ExitOnForwardFailure=yes", "-L", "15432:db.acme.internal:5432", "bastion.acme"],
            sockets: [FakeActivityKernel.tcp(local: "127.0.0.1", port: 15432, handle: 31)])
        let content = try content(context)
        let forward = try XCTUnwrap(content.ports.first { $0.port == 18080 })
        XCTAssertEqual(forward.target, "port-forward → svc/acme-web:80 · namespace acme, context fake-dev")
        XCTAssertEqual(forward.ownerText, "“web” · port-forward → svc/acme-web:80 · namespace acme, context fake-dev")
        XCTAssertEqual(forward.portOwner, .pane, "still the pane's: Free asks what its class asks")
        let tunnel = try XCTUnwrap(content.ports.first { $0.port == 15432 })
        XCTAssertEqual(tunnel.target, "ssh -L → db.acme.internal:5432 via bastion.acme")
    }

    func testTypedTargetsAreReadFromTheWords() {
        let target = ActivityTypedForwards.target
        XCTAssertEqual(target("/usr/bin/python3 /tmp/x/kubectl port-forward pod/acme-0 :8080", 0), nil, "a random local port isn't a port")
        XCTAssertEqual(target("kubectl port-forward pod/acme-0 9000", 9000), "port-forward → pod/acme-0:9000")
        XCTAssertEqual(target("/usr/bin/python3 /tmp/x/kubectl port-forward deploy/acme 7000:70", 7000), "port-forward → deploy/acme:70", "past an interpreter")
        XCTAssertNil(target("kubectl port-forward deploy/acme 7000:70", 7001), "another port")
        XCTAssertNil(target("kubectl get pods", 80))
        XCTAssertEqual(target("ssh -L127.0.0.1:2000:db:5432 jump", 2000), "ssh -L → db:5432 via jump", "joined, with a bind address")
        XCTAssertEqual(target("ssh -p 2222 -D 1080 jump", 1080), "ssh -D: a SOCKS proxy via jump")
        XCTAssertNil(target("node server.js --port 3000", 3000))
        XCTAssertEqual(ActivityTypedForwards.remoteForward(of: "ssh -N -R 8080:localhost:3000 relay.acme", port: 3000), "ssh -R to relay.acme:8080")
        XCTAssertNil(ActivityTypedForwards.remoteForward(of: "ssh -N -R 8080:localhost:3000 relay.acme", port: 3001))
        // Clustered flags, as people type them: each letter a flag until the
        // first that takes a value.
        XCTAssertEqual(target("ssh -fNL 5432:db.acme:5432 bastion.acme", 5432), "ssh -L → db.acme:5432 via bastion.acme")
        XCTAssertEqual(target("ssh -NL 6000:cache.acme:6379 bastion.acme", 6000), "ssh -L → cache.acme:6379 via bastion.acme")
        XCTAssertEqual(target("ssh -fNL5432:db.acme:5432 bastion.acme", 5432), "ssh -L → db.acme:5432 via bastion.acme", "the value joined")
        XCTAssertEqual(target("ssh -NCp 2222 -L 7000:db:70 jump", 7000), "ssh -L → db:70 via jump", "-p's value read, not the destination")
        XCTAssertEqual(ActivityTypedForwards.remoteForward(of: "ssh -fNR 8080:localhost:3000 relay.acme", port: 3000), "ssh -R to relay.acme:8080")
        XCTAssertEqual(ActivityTypedForwards.remoteForward(of: "ssh -NR 8081:localhost:3001 relay.acme", port: 3001), "ssh -R to relay.acme:8081")
    }

    func testAnSSHRemoteForwardNamesWhereItPublishes() throws {
        let context = mac()
        add(
            1105, parent: 1101, name: "ssh", words: ["ssh", "-N", "-R", "8080:localhost:3100", "relay.acme"],
            sockets: [FakeActivityKernel.tcp(local: "127.0.0.1", port: 52000, remote: "127.0.0.1", remotePort: 3100, state: .established, handle: 40)])
        add(
            1106, parent: 1101, name: "acme-api",
            sockets: [
                FakeActivityKernel.tcp(local: "127.0.0.1", port: 3100, handle: 41),
                FakeActivityKernel.tcp(local: "127.0.0.1", port: 3100, remote: "127.0.0.1", remotePort: 52000, state: .established, handle: 42),
            ])
        let content = try content(context)
        let server = try XCTUnwrap(content.ports.first { $0.port == 3100 && $0.kind == .listener })
        XCTAssertEqual(server.forwardedBy, "ssh -R to relay.acme:8080 (pid 1105)")
        XCTAssertEqual(server.reach, "forwarded by ssh -R to relay.acme:8080 (pid 1105)")
    }

    func testUnixSocketListenersBehindTheirSetting() throws {
        let context = mac()
        add(
            1107, parent: 1101, name: "acme-db",
            sockets: [
                FakeActivityKernel.unix(handle: 50, path: "/tmp/.s.ACME.5432", listening: true), FakeActivityKernel.unix(handle: 51),
                FakeActivityKernel.unix(handle: 52, path: "/tmp/acme-client.sock"),
            ])
        add(1108, parent: 1107, name: "acme-db-worker", sockets: [FakeActivityKernel.unix(handle: 50, path: "/tmp/.s.ACME.5432", listening: true)])
        XCTAssertFalse(try content(context).ports.contains { $0.kind == .unix }, "off by default (D-32)")
        let content = try content(context) { $0.unixSockets = true }
        let rows = content.ports.filter { $0.kind == .unix }
        XCTAssertEqual(rows.map(\.address), ["/tmp/.s.ACME.5432"], "listening and named only; a connected or unnamed end isn't")
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.holder?.pid, 1107)
        XCTAssertEqual(row.coHolders.map(\.pid), [1108], "the same socket inherited: a co-holder")
        XCTAssertEqual(row.tab, tab)
        XCTAssertEqual(row.portOwner, .pane)
        XCTAssertNil(row.url)
        XCTAssertEqual(row.reach, "This Mac · socket file")
        XCTAssertNil(ActivityPortHolder.step(for: row), "no port to free")
        XCTAssertTrue(row.collisions.isEmpty)
        XCTAssertTrue(row.accessibilityLabel.hasPrefix("unix socket /tmp/.s.ACME.5432"))
    }

    func testMoreKnownHolders() throws {
        XCTAssertEqual(KnownHolders.holder("mDNSResponder", port: 5353)?.word, "macos")
        XCTAssertEqual(KnownHolders.holder("screensharingd", port: 5900)?.note, "Screen Sharing (screensharingd), part of macOS: System Settings ▸ General ▸ Sharing")
        XCTAssertEqual(KnownHolders.holder("ngrok", port: 4040)?.name, "ngrok's inspector")
        XCTAssertNil(KnownHolders.holder("ngrok", port: 8080), "ngrok's other ports aren't its inspector")
        XCTAssertEqual(KnownHolders.holder("cloudflared", port: 20241)?.word, "elsewhere", "the user's own: Free asks as for any process")
        XCTAssertNil(KnownHolders.holder("acme-server", port: 3000))
    }

    /// macOS's daemons are named by their file only where the binary is
    /// macOS's: a user's own `sshd` (Homebrew's, a test's) is theirs, and
    /// Free asks as for any process of theirs.
    func testAUsersOwnDaemonNamedLikeMacOSsIsTheirs() throws {
        let context = mac()
        add(2200, parent: 1, name: "sshd", sockets: [FakeActivityKernel.tcp(local: "127.0.0.1", port: 2222, handle: 70)])
        add(2201, parent: 1, name: "sshd", sockets: [FakeActivityKernel.tcp(local: "127.0.0.1", port: 2223, handle: 71)], platform: true)
        let content = try content(context)
        let mine = try XCTUnwrap(content.ports.first { $0.port == 2222 })
        XCTAssertNotEqual(mine.owner, "macos")
        XCTAssertFalse(mine.ownerText.contains("Remote Login"), mine.ownerText)
        if case .refused(let why)? = ActivityPortHolder.step(for: mine) { XCTFail("the user's own sshd is never refused as macOS's: \(why)") }
        let macOS = try XCTUnwrap(content.ports.first { $0.port == 2223 })
        XCTAssertEqual(macOS.owner, "macos", "a platform binary of that name is macOS's")
        XCTAssertEqual(macOS.ownerText, "Remote Login")
    }

    func testABrewServiceOfAKnownToolIsTheService() throws {
        let context = mac()
        var process = FakeActivityKernel.Process(record: FakeActivityKernel.record(pid: 2100, start: 2_100_000, parent: 1, uid: 501, name: "ollama"))
        process.name = "ollama"
        process.path = "/opt/acme/bin/ollama"
        process.codeSigning = ActivityCodeSigning(flags: ActivityCodeSigning.valid)
        process.usage = FakeActivityKernel.usage(footprint: 8 << 20, threads: 3)
        process.arguments = FakeActivityKernel.arguments(executable: "/opt/acme/bin/ollama", ["ollama", "serve"], environment: ["XPC_SERVICE_NAME=homebrew.mxcl.ollama"])
        process.descriptors = [FakeActivityKernel.descriptor(3)]
        process.sockets = [3: FakeActivityKernel.tcp(local: "127.0.0.1", port: 11434, handle: 60)]
        kernel.add(process)
        let row = try XCTUnwrap(try content(context).ports.first { $0.port == 11434 })
        XCTAssertEqual(row.portOwner, .service(LaunchdJobs.Job(label: "homebrew.mxcl.ollama")), "a launchd job before a known tool: its own stop")
    }
}
