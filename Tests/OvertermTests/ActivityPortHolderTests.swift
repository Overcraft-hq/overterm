import Darwin
import Foundation
import XCTest

@testable import Overterm
@testable import OvertermCore
@testable import OvertermDatabase
@testable import OvertermDocker
@testable import OvertermKubernetes
@testable import OvertermTerraform
@testable import OvertermShell
@testable import OvertermOvergit
@testable import OvertermAPI

/// Free :N on the page (docs/design/activity/analysis.md, 6.8, Free :N):
/// each owner's own verb, its question, the command a service's stop or the
/// read route types, the refusals, the plan made again from a fresh read,
/// and `f` on the page. Every name is invented; nothing is signalled,
/// stopped or typed.
@MainActor
final class ActivityPortHolderTests: XCTestCase {
    private let kernel = FakeActivityKernel(uid: 501)
    private let app: pid_t = 1000
    private let tab = UUID()

    private func row(
        _ owner: ActivityPortOwner, port: Int = 5432, proto: String = "tcp", holder: ActivityProcessID? = ActivityProcessID(pid: 4242, start: 4_242_000)
    ) -> ActivityPortRow {
        var row = ActivityPortRow(
            id: "row", port: port, proto: proto, address: "127.0.0.1", families: .v4, scope: .thisMac, process: "acme-db", holder: holder)
        row.portOwner = owner
        row.owner = owner.word
        return row
    }

    // MARK: The steps

    func testEachOwnersOwnVerb() {
        XCTAssertEqual(ActivityPortHolder.step(for: row(.container(name: "acme-db", project: "shop"))), .stopContainer(name: "acme-db", project: "shop"))
        XCTAssertEqual(ActivityPortHolder.step(for: row(.forward(target: "svc/acme-api:80"))), .stopForward(pid: 4242, target: "svc/acme-api:80"))
        XCTAssertEqual(ActivityPortHolder.step(for: row(.tunnel(name: "acme-staging"))), .disconnect(name: "acme-staging", pid: 4242))
        let job = LaunchdJobs.Job(label: "homebrew.mxcl.postgresql@16")
        XCTAssertEqual(ActivityPortHolder.step(for: row(.service(job))), .stopService(job))
        XCTAssertEqual(ActivityPortHolder.step(for: row(.known(KnownHolders.airPlay), port: 5000)), .airPlay)
        XCTAssertEqual(ActivityPortHolder.step(for: row(.system(user: "_acme"))), .readRoute(user: "_acme"))
        XCTAssertEqual(
            ActivityPortHolder.title(.stopContainer(name: "acme-db", project: nil), port: 5432), "Stop Container…", "the owner's verb, by name")
        XCTAssertEqual(ActivityPortHolder.title(.readRoute(user: ""), port: 5432), "Who Holds :5432…")
    }

    func testWhatNothingHereFrees() {
        for owner in [ActivityPortOwner.bridge, .overterm, .anotherOverterm, .engine("Docker Desktop"), .macOS] {
            guard case .refused? = ActivityPortHolder.step(for: row(owner)) else { return XCTFail("\(owner) is refused") }
            XCTAssertNotNil(ActivityPortHolder.unavailable(row(owner)), "greyed with why")
        }
        XCTAssertEqual(ActivityPortHolder.unavailable(row(.bridge)), "Overterm's agent bridge: it closes when no agent setting needs it (Settings ▸ Agents).")
        let continuity = KnownHolders.holder("rapportd", port: 49152)!
        guard case .refused? = ActivityPortHolder.step(for: row(.known(continuity))) else { return XCTFail("macOS's own") }
        // The user's own processes: Activity's own verb, decided on the
        // holder read again as the sheet opens.
        for owner in [ActivityPortOwner.pane, .app("Acme.app"), .elsewhere, .known(KnownHolders.holder("adb", port: 5037)!)] {
            XCTAssertEqual(ActivityPortHolder.step(for: row(owner)), .stopHolder(ActivityProcessID(pid: 4242, start: 4_242_000)), "\(owner)")
            XCTAssertNil(ActivityPortHolder.unavailable(row(owner)))
            XCTAssertNil(ActivityPortHolder.question(.stopHolder(ActivityProcessID(pid: 4242, start: 4_242_000)), row: row(owner)), "asked with its plan")
        }
        XCTAssertEqual(ActivityPortHolder.title(.stopHolder(ActivityProcessID(pid: 4242, start: 1)), port: 5432), "Free :5432…")
        guard case .refused? = ActivityPortHolder.step(for: row(.pane, holder: nil)) else { return XCTFail("no holder to name") }
        // A forward restarting has no kubectl to name.
        guard case .refused? = ActivityPortHolder.step(for: row(.forward(target: "svc/acme-api:80"), holder: nil)) else { return XCTFail("no pid") }
        // No port to free: a connection, the fold.
        var connection = row(.pane)
        connection.kind = .connection
        XCTAssertNil(ActivityPortHolder.step(for: connection))
        XCTAssertEqual(ActivityPortHolder.unavailable(connection), "Only a listening port is freed")
    }

    // MARK: The commands

    /// `XPC_SERVICE_NAME` is the process's own to set: a service's stop
    /// only where launchd runs that job as the holder or a parent of it.
    func testAServiceIsTheHolderOnlyByLaunchdsPID() {
        let print = "gui/501/homebrew.mxcl.postgresql@16 = {\n\tactive count = 1\n\tstate = running\n\tpid = 4242\n\tendpoints = {\n\t\tpid = 9\n\t}\n}\n"
        XCTAssertEqual(LaunchdJobs.pid(inPrint: print), 4242)
        XCTAssertNil(LaunchdJobs.pid(inPrint: "gui/501/x = {\n\tstate = not running\n}\n"), "not running: no pid")
        XCTAssertNil(LaunchdJobs.pid(inPrint: "\t\tpid = 9\n"), "only the job's own key")
        let table = ProcessTable([
            FakeActivityKernel.record(pid: 1, start: 1, parent: 0, uid: 0, name: "launchd"),
            FakeActivityKernel.record(pid: 4242, start: 10, parent: 1, name: "postgres"),
            FakeActivityKernel.record(pid: 4300, start: 20, parent: 4242, name: "postgres"),
            FakeActivityKernel.record(pid: 5000, start: 30, parent: 1, name: "node"),
        ])
        let job = ActivityProcessID(pid: 4242, start: 10)
        let worker = ActivityProcessID(pid: 4300, start: 20)
        let stranger = ActivityProcessID(pid: 5000, start: 30)
        XCTAssertTrue(LaunchdJobs.runs(job, jobPID: 4242, in: table))
        XCTAssertTrue(LaunchdJobs.runs(worker, jobPID: 4242, in: table), "a child of the job's process")
        XCTAssertFalse(LaunchdJobs.runs(stranger, jobPID: 4242, in: table), "a process that only says the label")
        XCTAssertFalse(LaunchdJobs.runs(stranger, jobPID: nil, in: table), "a job launchd doesn't run")
        XCTAssertNil(LaunchdJobs.runningPID(of: "homebrew.mxcl.postgresql@16"), "a unit test never asks this Mac's launchd")
        XCTAssertNil(LaunchdJobs.runningPID(of: "x; rm -rf ~"), "nor about a label launchd's characters don't make")
    }

    /// Free a Port…'s field (6.3): a number, `:3000`, `5353/udp` — never a
    /// guess at anything else.
    func testFreeAPortReadsWhatWasTyped() {
        XCTAssertTrue(ActivityPageModel.typedPort("3000")! == (3000, "tcp"))
        XCTAssertTrue(ActivityPageModel.typedPort(" :8080 ")! == (8080, "tcp"))
        XCTAssertTrue(ActivityPageModel.typedPort("5353/UDP")! == (5353, "udp"))
        for bad in ["", "0", "65536", "3000x", "-1", "３０００", "1e3", "localhost:3000", ":"] {
            XCTAssertNil(ActivityPageModel.typedPort(bad), bad)
        }
    }

    func testTheCommandsTyped() {
        let brew = ActivityPortHolder.Step.stopService(LaunchdJobs.Job(label: "homebrew.mxcl.postgresql@16"))
        XCTAssertEqual(ActivityPortHolder.command(brew, port: 5432, proto: "tcp", uid: 501), "brew services stop postgresql@16")
        let job = ActivityPortHolder.Step.stopService(LaunchdJobs.Job(label: "com.acme.dev"))
        XCTAssertEqual(ActivityPortHolder.command(job, port: 8080, proto: "tcp", uid: 501), "launchctl bootout gui/501/com.acme.dev")
        // A label is the process's own XPC_SERVICE_NAME: anything but
        // launchd's characters is refused, never typed — a control
        // character inside quotes still acts on the line editor.
        for label in [
            "com.acme.dev; touch /tmp/x", "a\u{03}touch /tmp/x;#", "acme\rtouch /tmp/x", "acme\u{1B}[200~x", "acme\u{15}x", "acme dev", "acme.dév",
            "homebrew.mxcl.acme\u{03}x", "",
        ] {
            let job = LaunchdJobs.Job(label: label)
            XCTAssertNil(ActivityPortHolder.command(.stopService(job), port: 8080, proto: "tcp", uid: 501), "nothing typed for \(label.debugDescription)")
            guard case .refused(let why)? = ActivityPortHolder.step(for: row(.service(job))) else {
                return XCTFail("\(label.debugDescription) is refused")
            }
            XCTAssertTrue(why.contains("characters a shell would act on"))
        }
        XCTAssertTrue(ActivityPortHolder.launchdLabel("homebrew.mxcl.postgresql@16"))
        XCTAssertTrue(ActivityPortHolder.launchdLabel("com.acme.dev-agent+1_x"))
        XCTAssertTrue(ActivityPortHolder.runs(job), "the service's stop runs once asked")
        let read = ActivityPortHolder.Step.readRoute(user: "_acme")
        XCTAssertEqual(ActivityPortHolder.command(read, port: 3000, proto: "tcp"), "sudo lsof -nP -iTCP:3000 -sTCP:LISTEN")
        XCTAssertEqual(ActivityPortHolder.command(read, port: 5353, proto: "udp"), "sudo lsof -nP -iUDP:5353")
        XCTAssertFalse(ActivityPortHolder.runs(read), "the read route is typed, Return the person's")
        XCTAssertNil(ActivityPortHolder.command(.airPlay, port: 5000, proto: "tcp"))
        XCTAssertEqual(ActivityPortHolder.airPlaySettings.scheme, "x-apple.systempreferences", "System Settings opened, never changed")
    }

    /// An isolated run's Free with no recorder (9.9, 10.6): a service's
    /// stop and System Settings refused; the rest go to the run's own.
    func testAnIsolatedRunTypesNoServiceStopAndOpensNoSettings() {
        let service = ActivityPortHolder.Step.stopService(LaunchdJobs.Job(label: "homebrew.mxcl.acme-db"))
        let refuse = TerminalWindowController.isolatedFreeRefusal
        XCTAssertNotNil(refuse(service, true, false, false))
        XCTAssertNotNil(refuse(service, true, true, false), "the free recorded but not the terminal: still refused")
        XCTAssertNil(refuse(service, true, true, true), "a scenario's recorder takes it")
        XCTAssertNotNil(refuse(.airPlay, true, false, false))
        XCTAssertNil(refuse(.airPlay, true, true, false))
        XCTAssertNil(refuse(.stopContainer(name: "acme-db", project: nil), true, false, false), "the run's own fake engine")
        XCTAssertNil(refuse(service, false, false, false), "the user's app asks, then acts")
    }

    // MARK: The questions

    func testEveryStepAsks() throws {
        var container = row(.container(name: "acme-db", project: "shop"))
        container.checkout = "acme-shop"
        let stop = try XCTUnwrap(ActivityPortHolder.question(.stopContainer(name: "acme-db", project: "shop"), row: container))
        XCTAssertEqual(stop.title, "Stop container “acme-db”?")
        XCTAssertEqual(stop.scope, "compose project shop · checkout acme-shop")
        XCTAssertEqual(stop.button, "Stop Container")
        let forward = try XCTUnwrap(ActivityPortHolder.question(.stopForward(pid: 4242, target: "svc/acme-api:80"), row: row(.forward(target: "svc/acme-api:80"))))
        XCTAssertEqual(forward.button, "Stop Forward")
        XCTAssertTrue(forward.detail.contains("pid 4242"))
        let tunnel = try XCTUnwrap(ActivityPortHolder.question(.disconnect(name: "acme-staging", pid: 4242), row: row(.tunnel(name: "acme-staging"))))
        XCTAssertEqual(tunnel.title, "Disconnect “acme-staging”?")
        let service = ActivityPortHolder.Step.stopService(LaunchdJobs.Job(label: "homebrew.mxcl.postgresql@16"))
        let asked = try XCTUnwrap(ActivityPortHolder.question(service, row: row(.service(LaunchdJobs.Job(label: "homebrew.mxcl.postgresql@16")))))
        XCTAssertTrue(asked.detail.hasSuffix("brew services stop postgresql@16"), "the command it runs, said")
        XCTAssertEqual(asked.button, "Stop the Service")
        let airPlay = try XCTUnwrap(ActivityPortHolder.question(.airPlay, row: row(.known(KnownHolders.airPlay), port: 5000)))
        XCTAssertEqual(airPlay.title, "AirPlay Receiver holds :5000")
        XCTAssertEqual(airPlay.button, "Open System Settings")
        let read = try XCTUnwrap(ActivityPortHolder.question(.readRoute(user: "_acme"), row: row(.system(user: "_acme"), port: 3000)))
        XCTAssertEqual(read.title, "Owned by _acme: Overterm doesn't signal it")
        XCTAssertTrue(read.detail.hasSuffix("sudo lsof -nP -iTCP:3000 -sTCP:LISTEN"))
        XCTAssertNil(ActivityPortHolder.question(.refused("no"), row: row(.bridge)), "a refusal asks nothing")
    }

    func testAQuestionShowsEveryCharacter() throws {
        let job = LaunchdJobs.Job(label: "com.acme.\u{202E}ved")
        let asked = try XCTUnwrap(ActivityPortHolder.question(.stopService(job), row: row(.service(job))))
        XCTAssertFalse(asked.title.contains("\u{202E}"), "a direction override is shown, never obeyed")
    }

    // MARK: Made again

    private func snapshot(holderOn port: UInt16?) throws -> ActivitySnapshot {
        var process = FakeActivityKernel.Process(record: FakeActivityKernel.record(pid: 4242, start: 4_242_000, parent: 1, uid: 501, name: "acme-db"))
        process.name = "acme-db"
        process.path = "/opt/acme/bin/acme-db"
        process.usage = FakeActivityKernel.usage(footprint: 8 << 20, threads: 2)
        if let port {
            process.descriptors = [FakeActivityKernel.descriptor(3)]
            process.sockets = [3: FakeActivityKernel.tcp(local: "127.0.0.1", port: port, handle: 1)]
        }
        kernel.add(process)
        var other = FakeActivityKernel.Process(record: FakeActivityKernel.record(pid: 5150, start: 5_150_000, parent: 1, uid: 501, name: "globex-server"))
        other.name = "globex-server"
        other.path = "/opt/globex/bin/globex-server"
        other.usage = FakeActivityKernel.usage(footprint: 8 << 20, threads: 2)
        other.descriptors = [FakeActivityKernel.descriptor(3)]
        other.sockets = [3: FakeActivityKernel.tcp(local: "127.0.0.1", port: port == nil ? 5432 : 9, handle: 2)]
        kernel.add(other)
        return try XCTUnwrap(ActivitySampler(kernel: kernel).tickNow(ActivityDemand(.full), context: ActivityContext(panes: [], appPID: app)))
    }

    func testThePlanIsMadeAgainAsTheSheetOpens() throws {
        let listed = row(.service(LaunchdJobs.Job(label: "com.acme.db")))
        let step = try XCTUnwrap(ActivityPortHolder.step(for: listed))
        let same = try snapshot(holderOn: 5432)
        XCTAssertNil(
            ActivityPortHolder.changed(listed, step: step, holders: ListeningPorts.holders(of: 5432, in: same), snapshot: same), "still its holder: asked")
        let moved = try snapshot(holderOn: nil)
        let said = ActivityPortHolder.changed(listed, step: step, holders: ListeningPorts.holders(of: 5432, in: moved), snapshot: moved)
        XCTAssertEqual(said, ":5432 is now held by globex-server (pid 5150): nothing was asked — free it again to be asked about what it is now.")
        XCTAssertEqual(
            ActivityPortHolder.changed(listed, step: step, holders: [], snapshot: moved), ":5432 is free now: nothing was asked, nothing done.")
        // A container's port is the engine's: its own Stop says what it finds.
        XCTAssertNil(ActivityPortHolder.changed(row(.container(name: "acme-db", project: nil)), step: .stopContainer(name: "acme-db", project: nil), holders: [], snapshot: moved))
        // AirPlay's ControlCenter is the user's own: a port that changed
        // hands is said, never asked about as AirPlay's.
        let airPlay = row(.known(KnownHolders.airPlay), port: 5432)
        XCTAssertEqual(
            ActivityPortHolder.changed(airPlay, step: .airPlay, holders: ListeningPorts.holders(of: 5432, in: moved), snapshot: moved),
            ":5432 is now held by globex-server (pid 5150): nothing was asked — free it again to be asked about what it is now.")
        XCTAssertNil(ActivityPortHolder.changed(row(.system(user: "_acme")), step: .readRoute(user: "_acme"), holders: [], snapshot: moved))
    }

    // MARK: The user's own holder (6.8's plans)

    /// A fake Mac of the user's: launchd, the app, a pane's `login` and
    /// shell on a terminal; what each test adds, with the ports it holds.
    private final class OwnMac {
        let kernel = FakeActivityKernel(uid: 501)
        let tty: dev_t = 0x1000_0009
        let tab = UUID()
        var apps: [pid_t: String] = [:]

        init() {
            add(1, parent: 0, uid: 0, name: "launchd")
            add(1000, parent: 1, name: "Overterm")
            add(1100, parent: 1000, uid: 0, terminal: tty, name: "login")
            add(1101, parent: 1100, group: 1101, terminal: tty, foreground: 1101, name: "zsh")
        }

        /// `listens`: a port and its socket's handle — the same handle in
        /// two processes is one socket, inherited.
        @discardableResult
        func add(
            _ pid: pid_t, parent: pid_t, uid: uid_t = 501, group: pid_t? = nil, terminal: dev_t? = nil, foreground: pid_t? = nil, name: String,
            argv: [String]? = nil, listens: [(port: UInt16, handle: UInt64)] = [], ignoresHangup: Bool = false
        ) -> ActivityProcessID {
            let start = UInt64(pid) * 1_000
            var record = FakeActivityKernel.record(
                pid: pid, start: start, parent: parent, uid: uid, realUID: uid == 0 ? 501 : nil, group: group, terminal: terminal,
                ignoredSignals: ignoresHangup ? UInt32(1) << UInt32(SIGHUP - 1) : 0, name: name)
            if let foreground {
                record = ActivityProcess(
                    identity: record.identity, parentPID: record.parentPID, group: record.group, terminal: record.terminal, terminalGroup: foreground,
                    effectiveUID: record.effectiveUID, realUID: record.realUID, savedUID: record.savedUID, status: record.status, flags: record.flags,
                    ignoredSignals: record.ignoredSignals, caughtSignals: record.caughtSignals, nice: record.nice, shortName: record.shortName)
            }
            var process = FakeActivityKernel.Process(record: record)
            let executable = "/opt/acme/bin/\(name)"
            process.name = name
            process.path = executable
            process.usage = FakeActivityKernel.usage(footprint: 8 << 20, threads: 2)
            process.arguments = FakeActivityKernel.arguments(executable: executable, argv ?? [name])
            for (index, listen) in listens.enumerated() {
                let descriptor = Int32(3 + index)
                process.descriptors.append(FakeActivityKernel.descriptor(descriptor))
                process.sockets[descriptor] = FakeActivityKernel.tcp(local: "127.0.0.1", port: listen.port, handle: listen.handle)
            }
            kernel.add(process)
            return ActivityProcessID(pid: pid, start: start)
        }

        /// The plan for the listener on `port` that `holder` holds, read as
        /// the sheet's census reads it.
        func plan(_ port: Int, holder: ActivityProcessID, known: ActivityVerbSubject.Known? = nil) throws -> ActivityPortHolder.Plan {
            let context = ActivityContext(
                panes: [ActivityContext.Pane(tag: "pane-a", tab: tab, login: ActivityProcessID(pid: 1100, start: 1_100_000))], appPID: 1000)
            let snapshot = try XCTUnwrap(ActivitySampler(kernel: kernel).tickNow(ActivityDemand(.full), context: context))
            let owners = ActivityAttribution.of(
                snapshot, context: context, inputs: .init(tabs: [tab: ActivityTabFacts(id: tab, title: "web")], runningApps: apps))
            let known = known ?? ActivityVerbSubject.Known(appPID: 1000, runningApps: apps)
            var row = ActivityPortRow(
                id: "row", port: port, proto: "tcp", address: "127.0.0.1", families: .v4, scope: .thisMac, process: "acme", holder: holder)
            row.portOwner = .pane
            let subject = try XCTUnwrap(ActivityPortHolder.subject(of: holder, in: snapshot, owners: owners, known: known))
            return ActivityPortHolder.plan(
                row, subject: subject, holders: ListeningPorts.holders(of: port, in: snapshot), snapshot: snapshot, user: 501)
        }
    }

    private let utc = TimeZone(identifier: "UTC")!

    /// Each class of 6.8's table a process of the user's can be: the
    /// pane's foreground job interrupted with ⌃C typed, a background one
    /// stopped, the agent stopped in a critical sheet, one elsewhere and
    /// one that chose to outlive its terminal stopped (picked alone), an
    /// app quit — each asked; the pane's own shell refused, its close is
    /// its row's.
    func testEachClassOfHolderHasItsPlan() throws {
        let mac = OwnMac()
        let fg = mac.add(1102, parent: 1101, group: 1102, terminal: mac.tty, foreground: 1102, name: "acme-dev", listens: [(3000, 1)])
        let bg = mac.add(1103, parent: 1101, group: 1103, terminal: mac.tty, foreground: 1102, name: "acme-api", listens: [(3001, 2)])
        let elsewhere = mac.add(2000, parent: 1, name: "globex-server", listens: [(3003, 4)])
        let detached = mac.add(2001, parent: 1, name: "acme-daemon", listens: [(3006, 7)], ignoresHangup: true)
        let app = mac.add(2100, parent: 1, name: "Acme", listens: [(3004, 5)])
        mac.apps = [2100: "Acme"]
        mac.kernel.update(1101) { process in
            process.descriptors = [FakeActivityKernel.descriptor(3)]
            process.sockets = [3: FakeActivityKernel.tcp(local: "127.0.0.1", port: 3005, handle: 6)]
        }
        let shell = ActivityProcessID(pid: 1101, start: 1_101_000)

        let interrupt = try mac.plan(3000, holder: fg)
        XCTAssertEqual(interrupt.rule, .allowed(.interruptPane, confirm: true, critical: false))
        let asked = try XCTUnwrap(ActivityPortHolder.question(interrupt, scope: "Tab “web”", timeZone: utc))
        XCTAssertEqual(asked.title, "Interrupt “acme-dev” (pid 1102)?")
        XCTAssertTrue(asked.detail.hasPrefix("It holds :3000.\n⌃C is typed into its pane"), asked.detail)
        XCTAssertTrue(asked.detail.hasSuffix("The command it equals: ⌃C in the pane"))

        let stop = try mac.plan(3001, holder: bg)
        XCTAssertEqual(stop.rule, .allowed(.signal(.term), confirm: true, critical: false))
        let stopAsked = try XCTUnwrap(ActivityPortHolder.question(stop, scope: nil, timeZone: utc))
        XCTAssertEqual(stopAsked.title, "Stop “acme-api” (pid 1103)?")
        XCTAssertEqual(stopAsked.button, "Stop Process")
        XCTAssertTrue(stopAsked.detail.contains("Runs /opt/acme/bin/acme-api"))
        XCTAssertTrue(stopAsked.detail.hasSuffix("The command it equals: kill -TERM 1103"))

        for (holder, port) in [(elsewhere, 3003), (detached, 3006)] {
            XCTAssertEqual(try mac.plan(port, holder: holder).rule, .allowed(.signal(.term), confirm: true, critical: false), "picked alone: stopped")
        }
        XCTAssertTrue(try mac.plan(3006, holder: detached).subject.target.detached)

        let quit = try mac.plan(3004, holder: app)
        XCTAssertEqual(quit.rule, .allowed(.quitApp, confirm: true, critical: false))
        XCTAssertEqual(try XCTUnwrap(ActivityPortHolder.question(quit, scope: nil)).button, "Quit")

        // The pane's own shell: no Free of its own (6.10's class table) —
        // its pane's or tab's close, from its row.
        let shellPlan = try mac.plan(3005, holder: shell)
        XCTAssertEqual(shellPlan.rule, .refused(ActivitySignalCheck.paneSession))
        XCTAssertNil(ActivityPortHolder.question(shellPlan, scope: nil), "a refusal asks nothing")
    }

    /// The agent holding a port is Stop Agent, critical; a stand-in
    /// `claude` leading the pane's foreground group while its child holds
    /// the port is Stop of the child by token — never Interrupt: ⌃C or a
    /// SIGINT would reach the agent too (Codex's children keep its group).
    func testAnAgentsChildOnThePortIsStoppedNeverInterrupted() throws {
        let mac = OwnMac()
        let agent = mac.add(1110, parent: 1101, group: 1110, terminal: mac.tty, foreground: 1110, name: "claude", argv: ["claude"], listens: [(3002, 3)])
        let child = mac.add(1111, parent: 1110, group: 1110, terminal: mac.tty, foreground: 1110, name: "node", listens: [(5150, 9)])
        let stopAgent = try mac.plan(3002, holder: agent)
        XCTAssertEqual(stopAgent.rule, .allowed(.signal(.term), confirm: true, critical: true))
        let asked = try XCTUnwrap(ActivityPortHolder.question(stopAgent, scope: nil))
        XCTAssertEqual(asked.title, "Stop Claude (pid 1110)?")
        XCTAssertTrue(asked.critical)
        let plan = try mac.plan(5150, holder: child)
        XCTAssertTrue(plan.subject.target.inForeground, "the pane's foreground group")
        XCTAssertTrue(plan.subject.target.groupHoldsAgent)
        XCTAssertEqual(plan.rule, .allowed(.signal(.term), confirm: true, critical: false), "Stop, by token: never ⌃C")
        let childAsked = try XCTUnwrap(ActivityPortHolder.question(plan, scope: nil))
        XCTAssertEqual(childAsked.title, "Stop “node” (pid 1111)?")
        XCTAssertFalse(childAsked.detail.contains("⌃C"))
    }

    /// Every holder of the port listed — one that inherited the very
    /// socket, one on a socket of its own —, none of them stopped by the
    /// Free; the supervisor named, never added to what is sent.
    func testEveryHolderIsListedAndTheSupervisorNamedNeverAdded() throws {
        let mac = OwnMac()
        mac.add(1130, parent: 1101, group: 1130, terminal: mac.tty, foreground: 1101, name: "acme-supervisor")
        let server = mac.add(1131, parent: 1130, group: 1130, terminal: mac.tty, foreground: 1101, name: "acme-server", listens: [(4000, 77)])
        mac.add(1132, parent: 1131, group: 1130, terminal: mac.tty, foreground: 1101, name: "acme-worker", listens: [(4000, 77)])
        mac.add(2300, parent: 1, name: "globex-server", listens: [(4000, 78)])
        let plan = try mac.plan(4000, holder: server)
        XCTAssertEqual(plan.subject.supervisor?.pid, 1130)
        XCTAssertEqual(plan.others.map(\.identity.pid), [1132, 2300])
        XCTAssertEqual(plan.others.map(\.sharesSocket), [true, false])
        let asked = try XCTUnwrap(ActivityPortHolder.question(plan, scope: nil, timeZone: utc))
        XCTAssertTrue(asked.detail.contains("Also holding :4000 — a Free ends none of them"), asked.detail)
        XCTAssertTrue(asked.detail.contains("  pid 1132 acme-worker — the same socket, inherited"))
        XCTAssertTrue(asked.detail.contains("  pid 2300 globex-server — a socket of its own"))
        XCTAssertTrue(asked.detail.contains("“acme-supervisor” (pid 1130), its parent, may start it again"))
        XCTAssertTrue(asked.detail.hasSuffix("The command it equals: kill -TERM 1131"), "the supervisor is never added")
    }

    /// A terraform write's provider plugin on the port: the write is the
    /// one interrupted — ⌃C typed where it is the pane's foreground job —,
    /// never the plugin, and never stopped; the plugin is what the watch
    /// follows. A helm write's plugin is stopped in a critical sheet.
    func testAWriteRunningThePortsHolderIsInterrupted() throws {
        let mac = OwnMac()
        mac.add(1120, parent: 1101, group: 1120, terminal: mac.tty, foreground: 1120, name: "terraform", argv: ["terraform", "apply"])
        let plugin = mac.add(1121, parent: 1120, group: 1120, terminal: mac.tty, foreground: 1120, name: "terraform-provider-acme", listens: [(3010, 11)])
        let plan = try mac.plan(3010, holder: plugin)
        XCTAssertEqual(plan.subject.signal.identity.pid, 1120)
        XCTAssertEqual(plan.holder, plugin)
        XCTAssertEqual(plan.rule, .allowed(.interruptPane, confirm: true, critical: false))
        let asked = try XCTUnwrap(ActivityPortHolder.question(plan, scope: nil))
        XCTAssertTrue(asked.detail.hasPrefix("It runs “terraform-provider-acme” (pid 1121), which holds :3010"), asked.detail)
        XCTAssertTrue(asked.detail.contains("SIGTERM or SIGKILL could leave its state locked"))
        mac.add(1140, parent: 1101, group: 1140, terminal: mac.tty, foreground: 1120, name: "helm", argv: ["helm", "upgrade", "acme"])
        let helmPlugin = mac.add(1141, parent: 1140, group: 1140, terminal: mac.tty, foreground: 1120, name: "acme-plugin", listens: [(3011, 12)])
        let helm = try mac.plan(3011, holder: helmPlugin)
        XCTAssertEqual(helm.subject.signal.identity, helmPlugin)
        XCTAssertEqual(helm.rule, .allowed(.signal(.term), confirm: true, critical: true), "a release stopped mid-upgrade stays pending")
    }

    /// The plan made again at the button (6.10 step 4): the holder gone,
    /// no longer on the port, or another rule for it now refuses; the
    /// same plan goes.
    func testThePlanIsMadeAgainAtTheButton() throws {
        let mac = OwnMac()
        let job = mac.add(1103, parent: 1101, group: 1103, terminal: mac.tty, foreground: 1101, name: "acme-api", listens: [(3001, 2)])
        let asked = try mac.plan(3001, holder: job)
        XCTAssertNil(ActivityPortHolder.changedAtButton(asked, now: asked, holders: [job]))
        XCTAssertEqual(
            ActivityPortHolder.changedAtButton(asked, now: nil, holders: []), "What held :3001 ended or let it go while you were asked: nothing was sent.")
        XCTAssertNotNil(ActivityPortHolder.changedAtButton(asked, now: asked, holders: []), "no longer on the port")
        // Moved to the pane's foreground while the sheet was up: ⌃C now, not
        // the Stop asked about.
        mac.add(1103, parent: 1101, group: 1103, terminal: mac.tty, foreground: 1103, name: "acme-api", listens: [(3001, 2)])
        let now = try mac.plan(3001, holder: job)
        XCTAssertEqual(now.rule, .allowed(.interruptPane, confirm: true, critical: false))
        XCTAssertEqual(
            ActivityPortHolder.changedAtButton(asked, now: now, holders: [job]),
            "What holds :3001 changed while you were asked: nothing was sent — free it again to be asked about what it is now.")
    }

    /// The watch's last word on the page (6.8, After the step): Force
    /// Quit offered only while the one freed still holds the port; one
    /// that inherited the socket named, never Force Quit as the one gone.
    func testTheWatchsLastWord() {
        let freed = ActivityProcessID(pid: 4242, start: 1)
        XCTAssertEqual(
            TerminalWindowController.freeSaid(.stillHeld(pid: 4242), port: 3000, freed: freed), ":3000 still held — pid 4242 — Force Quit… (K)")
        XCTAssertEqual(
            TerminalWindowController.freeSaid(.inherited(pid: 4243), port: 3000, freed: freed),
            ":3000 still held by pid 4243, which held it with the one freed")
        XCTAssertEqual(TerminalWindowController.freeSaid(.free, port: 3000, freed: freed), ":3000 is free")
        XCTAssertEqual(TerminalWindowController.freeSaid(.cameBack(pid: 4300), port: 3000, freed: freed), ":3000 came back as pid 4300")
        XCTAssertEqual(TerminalWindowController.freeSaid(.stillHeld(pid: 4243), port: 3000, freed: nil), ":3000 still held — pid 4243")
        // A terraform write interrupted over its plugin, which holds the
        // port: never Force Quit of the plugin — SIGKILL into the write.
        let plugin = TerminalWindowController.freeSaid(.stillHeld(pid: 4242), port: 3000, freed: freed, write: "terraform")
        XCTAssertEqual(plugin, ":3000 still held — pid 4242 — “terraform” is still stopping")
        XCTAssertFalse(plugin.contains("Force Quit"))
    }

    /// The watch after a Free reads the census's sockets — never a bind,
    /// which would break a supervisor's rebind (6.8, After the step): not
    /// while it watches, nor at its end, held or freed.
    func testTheWatchNeverBinds() async {
        let port = 47_321
        let mac = OwnMac()
        let server = mac.add(2000, parent: 1, name: "globex-server", listens: [(UInt16(port), 11)])
        let before = ListeningPorts.bindProbes(of: port)
        let held = await TerminalWindowController.watchPort(
            port, proto: "tcp", freed: server, sentAt: PortFreeing.now(), monitor: ActivityMonitor(sampler: ActivitySampler(kernel: mac.kernel)),
            watch: .seconds(1))
        XCTAssertEqual(held, .stillHeld(pid: 2000), "held to its deadline")
        mac.kernel.remove(2000)
        let freed = await TerminalWindowController.watchPort(
            port, proto: "tcp", freed: server, sentAt: PortFreeing.now(), monitor: ActivityMonitor(sampler: ActivitySampler(kernel: mac.kernel)),
            watch: .seconds(1))
        XCTAssertEqual(freed, .free)
        XCTAssertEqual(ListeningPorts.bindProbes(of: port), before, "the port was never bound to see")
        _ = ListeningPorts.isBound(port)
        XCTAssertEqual(ListeningPorts.bindProbes(of: port), before + 1, "the count sees a probe")
    }

    // MARK: The page

    /// A page over a fake Mac: a tab's server on 5173 (pid 1102), and
    /// acme-db's published 5432 held by a proxy outside every tab.
    private func page(visible: Bool = true) async throws -> (ActivityPageModel, ActivityMonitor) {
        func add(_ pid: pid_t, parent: pid_t, uid: uid_t = 501, name: String, port: UInt16? = nil) -> ActivityProcessID {
            let start = UInt64(pid) * 1_000
            var process = FakeActivityKernel.Process(
                record: FakeActivityKernel.record(pid: pid, start: start, parent: parent, uid: uid, realUID: uid == 0 ? 501 : nil, name: name))
            process.name = name
            process.path = "/opt/acme/bin/\(name)"
            process.codeSigning = ActivityCodeSigning(flags: ActivityCodeSigning.valid)
            process.usage = FakeActivityKernel.usage(footprint: 8 << 20, threads: 2)
            process.arguments = FakeActivityKernel.arguments(executable: process.path ?? name, [name])
            if let port {
                process.descriptors = [FakeActivityKernel.descriptor(3)]
                process.sockets = [3: FakeActivityKernel.tcp(local: "127.0.0.1", port: port, handle: UInt64(pid))]
            }
            kernel.add(process)
            return ActivityProcessID(pid: pid, start: start)
        }
        _ = add(1, parent: 0, uid: 0, name: "launchd")
        _ = add(app, parent: 1, name: "Overterm")
        let login = add(1100, parent: app, uid: 0, name: "login")
        _ = add(1101, parent: 1100, name: "zsh")
        _ = add(1102, parent: 1101, name: "acme-server", port: 5173)
        _ = add(2000, parent: 1, name: "acme-proxy", port: 5432)
        let monitor = ActivityMonitor(sampler: ActivitySampler(kernel: kernel))
        monitor.setContext(ActivityContext(panes: [ActivityContext.Pane(tag: "pane-a", tab: tab, login: login)], appPID: app))
        monitor.interval = .milliseconds(300)
        let page = ActivityPageModel(monitor: monitor)
        page.isolated = false
        page.tabTitles = { [tab] in [tab: "web"] }
        page.contextFacts = { context in
            context.published = [ActivityContext.PublishedPort(container: "acme-db", project: "shop", address: "127.0.0.1", port: 5432, proto: "tcp")]
        }
        if visible {
            page.visible = true
            let read = await eventually { page.hasRead }
            XCTAssertTrue(read)
        }
        return (page, monitor)
    }

    func testFOnThePageFreesThroughTheOwner() async throws {
        let (page, monitor) = try await page(visible: false)
        defer { monitor.stop() }
        final class Box { var freed: [ActivityPortRow] = [] }
        let box = Box()
        page.actions.free = { box.freed.append($0) }
        page.visible = true
        page.section = .listening
        let read = await eventually { page.content.ports.contains { $0.port == 5432 } && page.content.ports.contains { $0.port == 5173 } }
        XCTAssertTrue(read)
        let container = try XCTUnwrap(page.content.ports.first { $0.port == 5432 })
        let pane = try XCTUnwrap(page.content.ports.first { $0.port == 5173 })
        page.selection = [container.id]
        let verbs = page.verbs(for: [container.id]) { _ in }
        let free = try XCTUnwrap(verbs.first { $0.key == "f" })
        XCTAssertEqual(free.title, "Stop Container…")
        XCTAssertEqual(free.place, .button)
        XCTAssertNil(free.unavailable)
        XCTAssertTrue(page.press("f"))
        XCTAssertEqual(box.freed.map(\.port), [5432], "f hands the row to the window, which asks")
        page.selection = [pane.id]
        let own = try XCTUnwrap(page.verbs(for: [pane.id]) { _ in }.first { $0.key == "f" })
        XCTAssertEqual(own.title, "Free :5173…", "a tab's process: Activity's own verb, decided as the sheet opens")
        XCTAssertNil(own.unavailable)
        XCTAssertTrue(page.press("f"))
        XCTAssertEqual(box.freed.map(\.port), [5432, 5173])
        page.section = .processes
        XCTAssertFalse(page.press("f"), "Processes has no f")
    }

    // MARK: Links (6.12)

    func testALinkShowsItsRow() async throws {
        let (page, monitor) = try await page()
        defer { monitor.stop() }
        let read = await eventually { page.content.ports.contains { $0.port == 5173 } }
        XCTAssertTrue(read)
        // A port: Listening, in its tab's scope, its holder's row selected
        // and followed.
        page.show(.port(5173, proto: "tcp", pid: 1102, tab: tab))
        XCTAssertEqual(page.section, .listening)
        XCTAssertEqual(page.scope(.listening), .tab(tab))
        let port = await eventually { page.selection.count == 1 && page.content.ports.first { page.selection.contains($0.id) }?.port == 5173 }
        XCTAssertTrue(port, "the port's row selected")
        XCTAssertTrue(page.following)
        XCTAssertNil(page.pendingPort)
        // A process: Processes, in its tab, selected.
        page.following = false
        let server = ActivityProcessID(pid: 1102, start: 1_102_000)
        page.show(.process(server, tab: tab))
        XCTAssertEqual(page.section, .processes)
        XCTAssertEqual(page.scope(.processes), .tab(tab))
        let process = await eventually { page.selection == [server.id] && page.detail?.row.identity == server }
        XCTAssertTrue(process, "the process selected, its detail shown")
        XCTAssertTrue(page.following)
        // A tab: Processes in its scope.
        page.setScope(.mac, for: .processes)
        page.show(.tab(tab))
        XCTAssertEqual(page.scope(.processes), .tab(tab))
        // Docker's conflict box for a process in no tab: the Mac.
        page.show(.port(5432, proto: "tcp", pid: nil, tab: nil))
        XCTAssertEqual(page.scope(.listening), .mac)
        let held = await eventually { page.content.ports.first { page.selection.contains($0.id) }?.port == 5432 }
        XCTAssertTrue(held)
    }

    /// A tab's container port (Tab Info and the pill list the checkout's):
    /// the link opens at the tab's checkout, where its stack is listed — a
    /// tab's own scope lists no container.
    func testAContainerPortLinkOpensAtTheTabsCheckout() async throws {
        let checkout = "/Users/fake/src/acme-shop"
        let (page, monitor) = try await page(visible: false)
        defer { monitor.stop() }
        page.tabFacts = { [tab] in ([tab: ActivityTabFacts(id: tab, title: "web", checkout: checkout)], [checkout]) }
        page.containers = { [ActivityContainer(id: "c1", name: "acme-db", project: "shop", folder: checkout)] }
        page.contextFacts = { context in
            context.published = [ActivityContext.PublishedPort(container: "acme-db", project: "shop", address: "0.0.0.0", port: 6543, proto: "tcp")]
        }
        page.visible = true
        let read = await eventually { page.hasRead }
        XCTAssertTrue(read)
        page.show(.port(6543, proto: "tcp", pid: nil, tab: tab))
        XCTAssertEqual(page.scope(.listening), .checkout(checkout))
        let shown = await eventually { page.content.ports.first { page.selection.contains($0.id) }?.port == 6543 }
        XCTAssertTrue(shown, "the container's row selected")
        XCTAssertNil(page.pendingPort)
    }

    /// A port nothing lists (another user's, before stage 4): widened to
    /// the Mac's once, then given up and said — never left to take the
    /// selection later. The person's hand drops a link still waiting.
    func testAPortNoTickListsIsGivenUp() async throws {
        let (page, monitor) = try await page()
        defer { monitor.stop() }
        page.show(.port(6001, proto: "tcp", pid: nil, tab: tab))
        XCTAssertEqual(page.scope(.listening), .tab(tab))
        let said = await eventually { page.linkSaid != nil }
        XCTAssertTrue(said)
        XCTAssertEqual(page.linkSaid, ":6001 isn't listed (another user's?)")
        XCTAssertEqual(page.scope(.listening), .mac, "looked for on the Mac's first")
        XCTAssertNil(page.pendingPort)
        XCTAssertTrue(page.selection.isEmpty)
        // Waiting, then the person's hand: dropped.
        page.show(.port(6002, proto: "tcp", pid: nil, tab: nil))
        XCTAssertNil(page.linkSaid)
        XCTAssertNotNil(page.pendingPort)
        let row = try XCTUnwrap(page.content.ports.first { $0.port == 5173 })
        page.selection = [row.id]
        XCTAssertNil(page.pendingPort, "a row picked by hand drops the link")
        page.show(.port(6003, proto: "tcp", pid: nil, tab: nil))
        XCTAssertTrue(page.press("1"))
        XCTAssertNil(page.pendingPort, "and so does a key")
    }

    func testAPortLinkBeforeTheFirstRowsWaitsForThem() async throws {
        let (page, monitor) = try await page(visible: false)
        defer { monitor.stop() }
        page.visible = true
        page.show(.port(5173, proto: "tcp", pid: nil, tab: nil))
        XCTAssertNotNil(page.pendingPort, "nothing listed yet: it waits")
        let shown = await eventually { page.content.ports.first { page.selection.contains($0.id) }?.port == 5173 }
        XCTAssertTrue(shown, "selected once a tick's rows list it")
        XCTAssertNil(page.pendingPort)
        page.show(.port(6001, proto: "tcp", pid: nil, tab: nil))
        page.close()
        XCTAssertNil(page.pendingPort, "hidden, a link nobody saw goes")
    }

    func testWhichListenerALinkNames() {
        func listener(_ id: String, port: Int, pid: pid_t?) -> ActivityPortRow {
            ActivityPortRow(
                id: id, port: port, proto: "tcp", address: "127.0.0.1", families: .v4, scope: .thisMac, process: "acme",
                holder: pid.map { ActivityProcessID(pid: $0, start: 1) })
        }
        let rows = [listener("a", port: 3000, pid: 10), listener("b", port: 3000, pid: 20), listener("c", port: 3001, pid: 30)]
        func link(_ port: Int, _ proto: String, _ pid: pid_t?) -> ActivityPendingPort {
            ActivityPendingPort(port: port, proto: proto, pid: pid, after: 0, scope: .mac)
        }
        XCTAssertEqual(ActivityPageModel.linked(link(3000, "tcp", 20), in: rows)?.id, "b", "its holder's")
        XCTAssertEqual(ActivityPageModel.linked(link(3000, "tcp", nil), in: rows)?.id, "a")
        XCTAssertEqual(ActivityPageModel.linked(link(3000, "tcp", 99), in: rows)?.id, "a", "a holder gone: the port's first")
        XCTAssertNil(ActivityPageModel.linked(link(3000, "udp", nil), in: rows))
    }

    /// Tab Info's port ⋯ ▸ Show in Activity: the holder's pid when a
    /// process holds it, none for a container's (pid 0), its protocol.
    func testTabInfosPortLink() {
        let server = ListeningPort(pid: 4242, process: "acme-server", port: 3000, address: "127.0.0.1")
        XCTAssertEqual(TabInfoView.portLink(server, tab: tab), .port(3000, proto: "tcp", pid: 4242, tab: tab))
        var container = ListeningPort(pid: 0, process: "acme-db", port: 5353, address: "*")
        container.proto = "udp"
        XCTAssertEqual(TabInfoView.portLink(container, tab: tab), .port(5353, proto: "udp", pid: nil, tab: tab))
    }

    func testTabInfosProcessLink() {
        let node = ProcessNode(
            identity: ActivityProcessID(pid: 4242, start: 7), parent: 1, name: "acme-server", maskedCommand: "acme-server", cpuPercent: 0, memory: 0,
            workingDirectory: nil)
        XCTAssertEqual(TabInfoView.processLink(node, tab: tab), .process(ActivityProcessID(pid: 4242, start: 7), tab: tab))
    }

    func testAPortLinksScopeAndWhenItGivesUp() {
        let checkout = "/Users/fake/src/acme-shop"
        XCTAssertEqual(ActivityPageModel.linkScope(tab: tab, checkout: checkout), .checkout(checkout), "a tab's checkout: its stack's containers too")
        XCTAssertEqual(ActivityPageModel.linkScope(tab: tab, checkout: nil), .tab(tab))
        XCTAssertEqual(ActivityPageModel.linkScope(tab: nil, checkout: nil), .mac)
        let pending = ActivityPendingPort(port: 6001, proto: "tcp", pid: nil, after: 7, scope: .checkout(checkout))
        XCTAssertEqual(ActivityPageModel.unlisted(pending, tick: 7, scope: .checkout(checkout)), .wait, "rows of a tick before the link say nothing")
        XCTAssertEqual(ActivityPageModel.unlisted(pending, tick: 8, scope: .tab(tab)), .wait, "rows of another rung say nothing")
        XCTAssertEqual(ActivityPageModel.unlisted(pending, tick: 8, scope: .checkout(checkout)), .widen, "not in the checkout's: the Mac's")
        var widened = pending
        widened.scope = .mac
        XCTAssertEqual(ActivityPageModel.unlisted(widened, tick: 8, scope: .mac), .drop, "not on the Mac's either: given up")
        XCTAssertEqual(ActivityPageModel.unlistedSaid(widened), ":6001 isn't listed (another user's?)")
    }

    private func eventually(_ seconds: Double = 10, _ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }
}
