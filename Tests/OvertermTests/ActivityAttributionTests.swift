import Darwin
import Foundation
import XCTest

@testable import Overterm
@testable import OvertermCore

/// Each rule of docs/design/activity/analysis.md 6.5, in order, over a
/// fake Mac and a fake context: owners, reasons, roles and the agent. Every
/// name and path is invented.
final class ActivityAttributionTests: XCTestCase {
    private let kernel = FakeActivityKernel(uid: 501)
    private let app: pid_t = 1000
    private let tab = UUID()
    private let other = UUID()
    private let pty: dev_t = 0x1000_0003
    private let otherPTY: dev_t = 0x1000_0009
    private let checkout = "/Users/fake/src/acme-shop"

    @discardableResult
    private func add(
        _ pid: pid_t, parent: pid_t, uid: uid_t = 501, name: String, path: String? = nil, words: [String]? = nil, environment: [String] = [],
        terminal: dev_t? = nil, group: pid_t? = nil, ignoresHangup: Bool = false, flags: ActivityProcess.Flags = [], platform: Bool = false,
        responsible: pid_t? = nil, sockets: [socket_fdinfo] = []
    ) -> ActivityProcessID {
        let start = UInt64(pid) * 1_000
        var record = FakeActivityKernel.record(
            pid: pid, start: start, parent: parent, uid: uid, realUID: uid == 0 && name == "login" ? 501 : nil, group: group, terminal: terminal,
            flags: flags, ignoredSignals: ignoresHangup ? UInt32(1) << UInt32(SIGHUP - 1) : 0, name: name)
        if let terminal { record = Self.with(record, terminal: terminal, foreground: group ?? pid) }
        var process = FakeActivityKernel.Process(record: record)
        process.name = name
        process.path = path ?? (uid == 501 ? "/opt/acme/bin/\(name)" : "/usr/local/fake/\(name)")
        process.codeSigning = ActivityCodeSigning(flags: ActivityCodeSigning.valid | (platform ? ActivityCodeSigning.platformBinary : 0))
        process.usage = FakeActivityKernel.usage(cpuTime: 0, footprint: 4 << 20, threads: 2)
        process.arguments = FakeActivityKernel.arguments(executable: process.path ?? name, words ?? [name], environment: environment)
        process.descriptors = sockets.indices.map { FakeActivityKernel.descriptor(Int32(3 + $0)) }
        process.sockets = Dictionary(uniqueKeysWithValues: sockets.enumerated().map { (Int32(3 + $0.offset), $0.element) })
        process.responsible = responsible
        kernel.add(process)
        return ActivityProcessID(pid: pid, start: start)
    }

    private static func with(_ record: ActivityProcess, terminal: dev_t, foreground: pid_t) -> ActivityProcess {
        ActivityProcess(
            identity: record.identity, parentPID: record.parentPID, group: record.group, terminal: terminal, terminalGroup: foreground,
            effectiveUID: record.effectiveUID, realUID: record.realUID, savedUID: record.savedUID, status: record.status, flags: record.flags,
            ignoredSignals: record.ignoredSignals, caughtSignals: record.caughtSignals, nice: record.nice, shortName: record.shortName)
    }

    private struct Mac {
        var context: ActivityContext
        var ids: [String: ActivityProcessID]
    }

    /// launchd; Overterm with a helper and a forward; a pane — its login,
    /// shell, a server in the foreground, an agent with an MCP server, a
    /// tool shell and a dev server under it — and what left it; a second
    /// tab's pane; apps, an engine, macOS, root, the user's elsewhere.
    private func mac() -> Mac {
        var ids: [String: ActivityProcessID] = [:]
        ids["launchd"] = add(1, parent: 0, uid: 0, name: "launchd", path: "/sbin/launchd", platform: true)
        ids["app"] = add(app, parent: 1, name: "Overterm", path: "/Applications/Overterm.app/Contents/MacOS/Overterm")
        ids["git"] = add(1010, parent: app, name: "git", path: "/usr/bin/git", platform: true)
        ids["forward"] = add(1020, parent: app, name: "kubectl")
        ids["login"] = add(1100, parent: app, uid: 0, name: "login", path: "/usr/bin/login", terminal: pty, group: 1100, platform: true)
        ids["zsh"] = add(1101, parent: 1100, name: "zsh", path: "/bin/zsh", terminal: pty, group: 1101, platform: true)
        ids["server"] = add(
            1102, parent: 1101, name: "acme-server", terminal: pty, group: 1102,
            sockets: [FakeActivityKernel.tcp(local: "127.0.0.1", port: 5173, handle: 1)])
        ids["claude"] = add(1103, parent: 1101, name: "claude", words: ["claude"], terminal: pty, group: 1103)
        ids["mcp"] = add(1104, parent: 1103, name: "node", words: ["node", "/opt/acme/lib/fake-mcp-server.js"], group: 1103)
        ids["tool"] = add(
            1105, parent: 1103, name: "zsh", path: "/bin/zsh", words: ["/bin/zsh", "-c", "pnpm dev"], group: 1105, flags: [.sessionLeader],
            platform: true)
        ids["dev"] = add(
            1106, parent: 1105, name: "acme-dev", group: 1105, sockets: [FakeActivityKernel.tcp(local: "127.0.0.1", port: 3000, handle: 2)])
        // Left its terminal: nohup'd, the tag carried.
        ids["nohup"] = add(1200, parent: 1, name: "acme-worker", environment: ["OVERTERM_TAB_ID=pane-a"], ignoresHangup: true)
        // A tmux server started in the pane, a session's shell on its own pty.
        ids["tmux"] = add(1300, parent: 1, name: "tmux", environment: ["OVERTERM_TAB_ID=pane-a"])
        ids["tmuxShell"] = add(1301, parent: 1300, name: "zsh", path: "/bin/zsh", terminal: otherPTY, group: 1301, platform: true)
        // An app started from the pane with `code .`, and its helper.
        ids["editor"] = add(
            1400, parent: 1, name: "Fake Editor", path: "/Applications/Fake Editor.app/Contents/MacOS/Fake Editor",
            environment: ["OVERTERM_TAB_ID=pane-a"])
        ids["editorHelper"] = add(1401, parent: 1400, name: "fake-helper", path: "/opt/acme/bin/fake-helper")
        // A dev build of an app, inside the checkout: the pane's.
        ids["devBuild"] = add(
            1500, parent: 1, name: "AcmeApp", path: "\(checkout)/build/AcmeApp.app/Contents/MacOS/AcmeApp", environment: ["OVERTERM_TAB_ID=pane-a"])
        // The second tab's pane.
        ids["loginB"] = add(1600, parent: app, uid: 0, name: "login", path: "/usr/bin/login", terminal: otherPTY + 1, group: 1600, platform: true)
        ids["zshB"] = add(1601, parent: 1600, name: "zsh", path: "/bin/zsh", terminal: otherPTY + 1, group: 1601, platform: true)
        // Apps, an engine and its VM, services.
        ids["slack"] = add(2000, parent: 1, name: "Globex Chat", path: "/Applications/Globex Chat.app/Contents/MacOS/Globex Chat")
        ids["docker"] = add(2100, parent: 1, name: "Docker", path: "/Applications/Docker.app/Contents/MacOS/Docker")
        ids["backend"] = add(
            2101, parent: 2100, name: "com.docker.backend", path: "/Applications/Docker.app/Contents/MacOS/com.docker.backend",
            sockets: [FakeActivityKernel.tcp(local: "0.0.0.0", port: 15432, handle: 3)])
        ids["vm"] = add(
            2200, parent: 1, name: "com.apple.Virtualization.VirtualMachine",
            path: "/System/Library/Frameworks/Virtualization.framework/Versions/A/XPCServices/com.apple.Virtualization.VirtualMachine.xpc/Contents/MacOS/com.apple.Virtualization.VirtualMachine",
            platform: true, responsible: 2100)
        ids["webContent"] = add(
            2300, parent: 1, name: "com.apple.WebKit.WebContent",
            path: "/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.WebContent.xpc/Contents/MacOS/com.apple.WebKit.WebContent",
            platform: true, responsible: app)
        ids["slackService"] = add(
            2301, parent: 1, name: "com.apple.WebKit.Networking",
            path: "/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.Networking.xpc/Contents/MacOS/com.apple.WebKit.Networking",
            platform: true, responsible: 2000)
        // macOS.
        ids["controlCenter"] = add(
            2400, parent: 1, name: "ControlCenter", path: "/System/Library/CoreServices/ControlCenter.app/Contents/MacOS/ControlCenter", platform: true)
        ids["fakeagentd"] = add(2401, parent: 1, name: "fakeagentd", path: "/usr/libexec/fakeagentd", platform: true)
        // Root's, not macOS's.
        ids["rootd"] = add(300, parent: 1, uid: 0, name: "globexd", path: "/Library/Globex/globexd")
        // A service ControlCenter is responsible for.
        ids["controlService"] = add(
            2450, parent: 1, name: "com.apple.fake.agent",
            path: "/System/Library/PrivateFrameworks/FakeKit.framework/XPCServices/com.apple.fake.agent.xpc/Contents/MacOS/com.apple.fake.agent",
            platform: true, responsible: 2400)
        // The user's: an agent's nohup'd perl, an ssh in another terminal —
        // which, as macOS answers, has that terminal app responsible for it.
        ids["perl"] = add(2500, parent: 1, name: "perl", path: "/usr/bin/perl", words: ["perl", "-e", "sleep"], platform: true)
        ids["terminalApp"] = add(2550, parent: 1, name: "Fake Terminal", path: "/Applications/Fake Terminal.app/Contents/MacOS/Fake Terminal")
        ids["ssh"] = add(
            2600, parent: 2601, name: "ssh", path: "/usr/bin/ssh", terminal: otherPTY + 2, group: 2600, platform: true, responsible: 2550)
        ids["otherShell"] = add(
            2601, parent: 1, name: "zsh", path: "/bin/zsh", terminal: otherPTY + 2, group: 2601, platform: true, responsible: 2550)
        // A pane's leftover whose tag can't be read, Overterm responsible
        // for it as for anything a pane started.
        ids["leftover"] = add(2650, parent: 1, name: "nc", path: "/usr/bin/nc", ignoresHangup: true, platform: true, responsible: app)
        var context = ActivityContext(
            panes: [
                ActivityContext.Pane(tag: "pane-a", tab: tab, login: ids["login"], terminal: pty),
                ActivityContext.Pane(tag: "pane-b", tab: other, login: ids["loginB"], terminal: otherPTY + 1),
            ], appPID: app)
        context.forwards = [ActivityContext.Forward(pid: 1020, port: 8443, target: "svc/fake-api", tab: other)]
        context.published = [ActivityContext.PublishedPort(container: "acme-db-1", project: "acme-shop", address: "0.0.0.0", port: 15432, proto: "tcp")]
        return Mac(context: context, ids: ids)
    }

    private func attribution(_ mac: Mac, runningApps: [pid_t: String] = [:]) throws -> (ActivityAttribution, ActivitySnapshot) {
        let snapshot = try XCTUnwrap(ActivitySampler(kernel: kernel).tickNow(ActivityDemand(.full), context: mac.context))
        let inputs = ActivityAttribution.Inputs(
            tabs: [
                tab: ActivityTabFacts(id: tab, title: "web", checkout: checkout, branch: "feature-x"),
                other: ActivityTabFacts(id: other, title: "k8s", checkout: checkout, branch: "feature-x", order: 1),
            ], checkouts: [checkout], runningApps: runningApps)
        return (ActivityAttribution.of(snapshot, context: mac.context, inputs: inputs), snapshot)
    }

    private func owner(_ name: String, _ mac: Mac, _ attribution: ActivityAttribution) throws -> ActivityOwner {
        try XCTUnwrap(attribution[try XCTUnwrap(mac.ids[name])], name)
    }

    // MARK: Rules 1–2: Overterm

    func testOvertermItselfAndWhatItStarted() throws {
        let mac = mac()
        let (owners, _) = try attribution(mac)
        let me = try owner("app", mac, owners)
        XCTAssertEqual(me.place, .overterm)
        XCTAssertEqual(me.rule, 1)
        let git = try owner("git", mac, owners)
        XCTAssertEqual(git.place, .overterm, "a child no registry keeps, by its parent")
        XCTAssertEqual(git.rule, 2)
        XCTAssertEqual(git.reason, "git, started by Overterm")
        let forward = try owner("forward", mac, owners)
        XCTAssertEqual(forward.place, .overterm)
        XCTAssertEqual(forward.reason, "kubectl port-forward to svc/fake-api Overterm started from “k8s”", "a forward by its pid")
    }

    func testARegisteredChildIsNamedByItsRegistry() throws {
        var mac = mac()
        mac.context.registered[try XCTUnwrap(mac.ids["git"])] = "git, for the changes pane"
        let (owners, _) = try attribution(mac)
        XCTAssertEqual(try owner("git", mac, owners).reason, "git, for the changes pane")
    }

    // MARK: Rules 3–4: the pane

    func testThePanesTreeWithItsRolesAndItsAgent() throws {
        let mac = mac()
        let (owners, _) = try attribution(mac)
        let login = try owner("login", mac, owners)
        XCTAssertEqual(login.place, .pane("pane-a"))
        XCTAssertEqual(login.rule, 3)
        XCTAssertEqual(login.paneRole, .session)
        XCTAssertEqual(login.reason, "the session of “web”")
        XCTAssertEqual(try owner("zsh", mac, owners).paneRole, .shell)
        let server = try owner("server", mac, owners)
        XCTAssertEqual(server.rule, 4)
        XCTAssertEqual(server.tab, tab)
        XCTAssertEqual(server.paneRole, .foreground)
        XCTAssertEqual(server.role, .server)
        XCTAssertEqual(server.reason, "in “web”")
        let agent = try owner("claude", mac, owners)
        XCTAssertEqual(agent.paneRole, .agent)
        XCTAssertEqual(agent.agentKind, .claude)
        let mcp = try owner("mcp", mac, owners)
        XCTAssertEqual(mcp.role, .mcp)
        XCTAssertEqual(mcp.paneRole, .agentChild)
        XCTAssertEqual(mcp.agent, mac.ids["claude"])
        XCTAssertEqual(mcp.reason, "started by Claude in “web”")
        let tool = try owner("tool", mac, owners)
        XCTAssertEqual(tool.role, .shell, "the Bash tool's shell")
        XCTAssertTrue(tool.marks.contains(.setsid), "a session leader with no terminal: a display fact")
        let dev = try owner("dev", mac, owners)
        XCTAssertEqual(dev.role, .server)
        XCTAssertEqual(dev.agent, mac.ids["claude"], "what the agent's shell started is the agent's")
        XCTAssertNil(try owner("zshB", mac, owners).agent, "another pane's shell says nothing of an agent")
        XCTAssertEqual(try owner("zshB", mac, owners).place, .pane("pane-b"))
    }

    // MARK: Rules 5, 7, 9: what left the pane

    func testWhatLeftThePaneDetachedAnAppOrNohup() throws {
        let mac = mac()
        let (owners, _) = try attribution(mac)
        let nohup = try owner("nohup", mac, owners)
        XCTAssertEqual(nohup.place, .pane("pane-a"))
        XCTAssertEqual(nohup.rule, 9)
        XCTAssertTrue(nohup.marks.contains(.leftTerminal))
        XCTAssertTrue(nohup.marks.contains(.nohup))
        XCTAssertEqual(nohup.reason, "carries “web”’s tag: it left its terminal (nohup, disown)")
        let tmux = try owner("tmux", mac, owners)
        XCTAssertEqual(tmux.rule, 5)
        XCTAssertTrue(tmux.marks.contains(.detached))
        XCTAssertEqual(tmux.tab, tab, "its pane while the pane lives")
        XCTAssertTrue(try owner("tmuxShell", mac, owners).marks.contains(.detached), "a session's shell on tmux's pty is tmux's")
        let editor = try owner("editor", mac, owners)
        XCTAssertEqual(editor.place, .app("Fake Editor"))
        XCTAssertEqual(editor.rule, 7)
        XCTAssertEqual(editor.reason, "Fake Editor, started from “web”")
        XCTAssertTrue(editor.marks.contains(.fromPane))
        XCTAssertEqual(try owner("editorHelper", mac, owners).place, .app("Fake Editor"), "its helpers with it")
        XCTAssertEqual(try owner("devBuild", mac, owners).place, .pane("pane-a"), "a dev build inside the checkout stays the pane's")
    }

    /// The pane's set leaves out what the display places (6.5): a tagged
    /// daemon and its child on a pty of its own, a nohup'd server, an app.
    func testThePanesSetLeavesOutWhatOnlyItsTagPlaces() throws {
        let mac = mac()
        let (_, snapshot) = try attribution(mac)
        let slice = try XCTUnwrap(snapshot.pane("pane-a"))
        let set = ActivityPaneSet(slice, in: snapshot, terminal: pty, checkouts: [checkout])
        for name in ["tmux", "tmuxShell", "nohup", "editor", "editorHelper"] {
            XCTAssertFalse(set.members.contains(try XCTUnwrap(mac.ids[name])), name)
        }
        XCTAssertTrue(slice.placed.contains(try XCTUnwrap(mac.ids["nohup"])), "listed all the same")
        XCTAssertTrue(set.members.contains(try XCTUnwrap(mac.ids["server"])))
    }

    // MARK: Rule 6: engines

    func testAnEngineHoldsAContainersPortAndItsVM() throws {
        let mac = mac()
        let (owners, _) = try attribution(mac)
        let backend = try owner("backend", mac, owners)
        XCTAssertEqual(backend.place, .engine("Docker"))
        XCTAssertEqual(backend.reason, "holds the published ports of 1 container", "matched on host IP, port and protocol")
        let vm = try owner("vm", mac, owners)
        XCTAssertEqual(vm.place, .engine("Docker"), "its app responsible for it: never macOS")
        XCTAssertEqual(vm.reason, "Docker’s Linux VM — containers run inside it")
    }

    func testAPublishedPortOnAnotherAddressIsntMatched() {
        let published = ActivityContext.PublishedPort(container: "acme-db-1", address: "127.0.0.1", port: 15432, proto: "tcp")
        let wildcard = SocketRecord.classify(FakeActivityKernel.tcp(local: "0.0.0.0", port: 15432), descriptor: 3)
        let loopback = SocketRecord.classify(FakeActivityKernel.tcp(local: "127.0.0.1", port: 15432), descriptor: 3)
        let udp = SocketRecord.classify(FakeActivityKernel.udp(local: "127.0.0.1", port: 15432), descriptor: 3)
        XCTAssertEqual(wildcard.map { ActivityAttribution.matches($0, published) }, false)
        XCTAssertEqual(loopback.map { ActivityAttribution.matches($0, published) }, true)
        XCTAssertEqual(udp.map { ActivityAttribution.matches($0, published) }, false, "another protocol")
    }

    // MARK: Rules 10, 12, 13: other Overterms, apps, responsibility

    func testAnotherOvertermByItsRunsMarker() throws {
        var mac = mac()
        add(3000, parent: 1, name: "Overterm", path: "/Applications/Overterm Dev.app/Contents/MacOS/Overterm")
        let tabbed = add(3100, parent: 1, name: "acme-server", environment: ["OVERTERM_RUN=app.3000.3000000"])
        // A dead run's marker names nobody: a tmux shell after a relaunch.
        let stale = add(3200, parent: 1300, name: "zsh", path: "/bin/zsh", environment: ["OVERTERM_RUN=app.4321.99"], platform: true)
        mac.ids["stale"] = stale
        let (owners, _) = try attribution(mac)
        XCTAssertEqual(owners[ActivityProcessID(pid: 3000, start: 3_000_000)]?.place, .anotherOverterm)
        XCTAssertEqual(owners[tabbed]?.place, .anotherOverterm)
        XCTAssertEqual(owners[tabbed]?.reason, "a tab of another Overterm")
        XCTAssertNotEqual(owners[stale]?.place, .anotherOverterm)
    }

    func testAppsByPathAndByWhatIsResponsible() throws {
        let mac = mac()
        let (owners, _) = try attribution(mac)
        let chat = try owner("slack", mac, owners)
        XCTAssertEqual(chat.place, .app("Globex Chat"))
        XCTAssertEqual(chat.rule, 12)
        let web = try owner("webContent", mac, owners)
        XCTAssertEqual(web.place, .overterm, "a WebContent process Overterm is responsible for")
        XCTAssertEqual(web.rule, 13)
        XCTAssertEqual(web.reason, "WebKit content of Overterm’s browser column")
        let service = try owner("slackService", mac, owners)
        XCTAssertEqual(service.place, .app("Globex Chat"))
        XCTAssertEqual(service.reason, "WebKit content of Globex Chat")
    }

    func testResponsibilityOffLeavesUnknownNeverMacOS() throws {
        var mac = mac()
        mac.context.appServices = false
        let (owners, _) = try attribution(mac)
        let vm = try owner("vm", mac, owners)
        XCTAssertNotEqual(vm.place, .engine("Docker"), "no responsibility read")
        XCTAssertNotEqual(vm.place, .macOS, "its parent is launchd, but who is responsible is unknown, not none")
        XCTAssertEqual(kernel.count("responsible"), 0, "nothing asked while off")
    }

    /// D-31: where the call answers nothing, nil is unread — the user's
    /// XPC services and VMs are never macOS's then.
    func testResponsibilityThatAnswersNothingLeavesUnknownNeverMacOS() throws {
        let mac = mac()
        XCTAssertTrue(mac.context.appServices)
        kernel.dropResponsibilityCall()
        let (owners, snapshot) = try attribution(mac)
        for name in ["vm", "webContent", "slackService", "controlService"] {
            XCTAssertNotEqual(try owner(name, mac, owners).place, .macOS, name)
            XCTAssertEqual(snapshot.facts[try XCTUnwrap(mac.ids[name])]?.responsibilityRead, false, name)
        }
        XCTAssertEqual(try owner("fakeagentd", mac, owners).place, .macOS, "a daemon outside any .xpc is still macOS's")
    }

    /// 9.1: the responsible process is read for the user's processes only.
    func testResponsibilityIsReadOnlyForTheUsers() throws {
        let mac = mac()
        let rootService = add(
            320, parent: 1, uid: 0, name: "com.globex.helper", path: "/Library/Globex/XPCServices/com.globex.helper.xpc/Contents/MacOS/helper",
            responsible: 300)
        kernel.resetCounts()
        let (_, snapshot) = try attribution(mac)
        let facts = snapshot.facts[rootService]
        XCTAssertNil(facts?.responsible)
        XCTAssertEqual(facts?.responsibilityRead, false)
        let own = snapshot.table.processes.filter { $0.isOwn(by: 501) }.count
        XCTAssertGreaterThan(kernel.count("responsible"), 0)
        XCTAssertLessThanOrEqual(kernel.count("responsible"), own, "never asked for root's or another user's")
    }

    /// A responsible pid reused after its app quit names nobody: the
    /// identity read is kept, and once it is gone the fact is unread.
    func testAResponsiblePIDReusedNamesNobody() throws {
        let mac = mac()
        let sampler = ActivitySampler(kernel: kernel)
        let first = try XCTUnwrap(sampler.tickNow(ActivityDemand(.full), context: mac.context))
        let vm = try XCTUnwrap(mac.ids["vm"])
        XCTAssertEqual(first.facts[vm]?.responsible, mac.ids["docker"])
        kernel.remove(2101)
        kernel.remove(2100)
        var reused = FakeActivityKernel.Process(
            record: FakeActivityKernel.record(pid: 2100, start: 9_000_000, parent: 1, name: "Globex Notes"))
        reused.name = "Globex Notes"
        reused.path = "/Applications/Globex Notes.app/Contents/MacOS/Globex Notes"
        kernel.add(reused)
        kernel.advance(2_000_000_000)
        let second = try XCTUnwrap(sampler.tickNow(ActivityDemand(.full), context: mac.context))
        XCTAssertNil(second.facts[vm]?.responsible, "not whoever holds the pid now")
        XCTAssertEqual(second.facts[vm]?.responsibilityRead, false)
        let owners = ActivityAttribution.of(second, context: mac.context)
        XCTAssertNotEqual(owners[vm]?.place, .app("Globex Notes"))
        XCTAssertNotEqual(owners[vm]?.place, .macOS)
    }

    func testADeletedExecutableIsPlacedThroughItsRunningApp() throws {
        let mac = mac()
        let gone = add(3300, parent: 1, name: "Globex Notes")
        kernel.update(3300) { $0.path = nil }
        let (owners, _) = try attribution(mac, runningApps: [3300: "/Applications/Globex Notes.app"])
        XCTAssertEqual(owners[gone]?.place, .app("Globex Notes"))
    }

    // MARK: Rules 14–16

    func testMacOSIsNarrow() throws {
        let mac = mac()
        let (owners, _) = try attribution(mac)
        let controlCenter = try owner("controlCenter", mac, owners)
        XCTAssertEqual(controlCenter.place, .macOS)
        XCTAssertEqual(controlCenter.reason, "AirPlay Receiver (ControlCenter)")
        XCTAssertEqual(try owner("fakeagentd", mac, owners).place, .macOS)
        let perl = try owner("perl", mac, owners)
        XCTAssertEqual(perl.place, .elsewhere, "a user's platform binary under /usr/bin, launchd its parent, no tag: never macOS")
        XCTAssertEqual(perl.reason, "no terminal, parent launchd")
        XCTAssertEqual(try owner("rootd", mac, owners).place, .system, "root's, not a platform binary")
        XCTAssertEqual(try owner("launchd", mac, owners).place, .macOS)
        let service = try owner("controlService", mac, owners)
        XCTAssertEqual(service.place, .macOS, "a service of a macOS process is macOS's, not yours elsewhere")
        XCTAssertEqual(service.rule, 13)
        XCTAssertEqual(service.reason, "a service of AirPlay Receiver (ControlCenter)")
    }

    func testAnSSHInAnotherTerminalIsYoursElsewhere() throws {
        let mac = mac()
        let (owners, _) = try attribution(mac)
        let ssh = try owner("ssh", mac, owners)
        XCTAssertEqual(ssh.place, .elsewhere)
        XCTAssertEqual(ssh.rule, 16)
        XCTAssertNotEqual(ssh.reason, "no terminal, parent launchd", "it has a terminal")
        for name in ["ssh", "otherShell"] {
            let placed = try owner(name, mac, owners)
            XCTAssertEqual(placed.rule, 16, "its terminal app is responsible for it, as for anything started there: not rule 13's")
            XCTAssertNotEqual(placed.place, .app("Fake Terminal"), name)
        }
        let leftover = try owner("leftover", mac, owners)
        XCTAssertEqual(leftover.place, .elsewhere, "Overterm responsible for it, but not a service of Overterm")
        XCTAssertEqual(leftover.rule, 16)
        XCTAssertEqual(leftover.reason, "no terminal, parent launchd")
    }

    /// Every process gets an owner; the pure step reads nothing of the
    /// kernel.
    /// An `exec` keeps the identity and changes its path: what the path
    /// says is read again (`ActivityPathWords`, 10.4), never the last one's.
    func testAnExecIsPlacedByItsNewPath() throws {
        var mac = mac()
        mac.ids["exec"] = add(2700, parent: 1, name: "acme-tool")
        XCTAssertEqual(try owner("exec", mac, try attribution(mac).0).place, .elsewhere)
        kernel.update(2700) { $0.path = "/Applications/Globex Mail.app/Contents/MacOS/Globex Mail" }
        XCTAssertEqual(try owner("exec", mac, try attribution(mac).0).place, .app("Globex Mail"))
        kernel.update(2700) { $0.path = "/opt/acme/bin/acme-tool" }
        XCTAssertEqual(try owner("exec", mac, try attribution(mac).0).place, .elsewhere)
    }

    /// What a pane's process's path says is kept too, read once a life
    /// like the rest's — not again each tick because the pane placed it
    /// before the walk (10.4).
    func testAPaneProcessesPathWordsAreKept() throws {
        let mac = mac()
        _ = try attribution(mac)
        let kept = ActivityPathWords.cached()
        let paths = [
            "nohup": ("acme-worker", "/opt/acme/bin/acme-worker"), "tmux": ("tmux", "/opt/acme/bin/tmux"),
            "editor": ("Fake Editor", "/Applications/Fake Editor.app/Contents/MacOS/Fake Editor"),
        ]
        for (key, (name, path)) in paths {
            let words = try XCTUnwrap(kept[try XCTUnwrap(mac.ids[key])], key)
            XCTAssertTrue(words.describes(path: path, name: name, shortName: name), key)
        }
    }

    func testEveryProcessIsPlacedAndNothingIsRead() throws {
        let mac = mac()
        let snapshot = try XCTUnwrap(ActivitySampler(kernel: kernel).tickNow(ActivityDemand(.full), context: mac.context))
        kernel.resetCounts()
        let owners = ActivityAttribution.of(snapshot, context: mac.context)
        XCTAssertEqual(owners.owners.count, snapshot.table.processes.count)
        for call in ["processes", "path", "name", "csops", "workingDirectory", "responsible", "usage"] {
            XCTAssertEqual(kernel.count(call), 0, call)
        }
    }

    // MARK: Roles

    func testRolesFromTheMaskedCommand() {
        XCTAssertEqual(ProcessRole.of(name: "node", command: "npx -y @modelcontextprotocol/server-fake", listensTCP: false), .mcp)
        XCTAssertEqual(ProcessRole.of(name: "node", command: "node /opt/acme/@playwright/mcp/cli.js", listensTCP: true), .mcp)
        XCTAssertEqual(ProcessRole.of(name: "node", command: "node mcpherson.js", listensTCP: false), .other, "a word, not a substring")
        XCTAssertEqual(ProcessRole.of(name: "zsh", command: "/bin/zsh -c pnpm dev", listensTCP: false), .shell)
        XCTAssertEqual(ProcessRole.of(name: "zsh", command: "-zsh", listensTCP: false), .other)
        XCTAssertEqual(ProcessRole.of(name: "acme", command: "acme serve", listensTCP: true), .server)
        XCTAssertEqual(ProcessRole.of(name: "node", command: "pnpm test", listensTCP: false), .build)
        XCTAssertEqual(ProcessRole.of(name: "swift-build", command: "swift-build", listensTCP: false), .build)
        XCTAssertEqual(ProcessRole.of(name: "cargo", command: "cargo build", listensTCP: false), .build)
        XCTAssertEqual(ProcessRole.of(name: "python3", command: "python3 -m pytest", listensTCP: false), .build)
        XCTAssertTrue(ProcessRole.mentionsMCP("node /opt/acme/MCP.js"))
        XCTAssertTrue(ProcessRole.mentionsMCP("npx @ModelContextProtocol/server-fake"))
        XCTAssertFalse(ProcessRole.mentionsMCP("node /opt/acme/m-c-p.js"))
        let helper = "fake-helper " + String(repeating: "--flag ", count: 1_000) + "fake-mcp"
        XCTAssertEqual(ProcessRole.of(name: "fake-helper", command: helper, listensTCP: false), .other, "past the first 4 KB of flags, not read")
        XCTAssertEqual(ProcessRole.mcp.counted(12), "12 MCP")
        XCTAssertEqual(ProcessRole.shell.counted(1), "1 shell")
    }

    func testAppNameIsTheOutermostBundleByStringsAlone() {
        XCTAssertEqual(ActivityAttribution.appName(of: "/Applications/Globex.app/Contents/Frameworks/Helper.app/Contents/MacOS/Helper"), "Globex")
        XCTAssertNil(ActivityAttribution.appName(of: "/usr/bin/perl"))
        XCTAssertNil(ActivityAttribution.appName(of: "/opt/.app/x"), "a bare .app is no name")
        XCTAssertEqual(ActivityAttribution.runIdentity("app.3000.3000000"), ActivityProcessID(pid: 3000, start: 3_000_000))
        XCTAssertNil(ActivityAttribution.runIdentity("garbage"))
    }
}
