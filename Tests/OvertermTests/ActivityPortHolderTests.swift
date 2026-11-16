import Darwin
import Foundation
import XCTest

@testable import Overterm

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
        // The user's own processes: the verbs' stage, never a signal here.
        for owner in [ActivityPortOwner.pane, .app("Acme.app"), .elsewhere] {
            guard case .notYet? = ActivityPortHolder.step(for: row(owner)) else { return XCTFail("\(owner) waits for the verbs") }
        }
        XCTAssertTrue(ActivityPortHolder.unavailable(row(.pane))?.contains("port pill") == true, "says where it is freed now")
        // A forward restarting has no kubectl to name.
        guard case .refused? = ActivityPortHolder.step(for: row(.forward(target: "svc/acme-api:80"), holder: nil)) else { return XCTFail("no pid") }
        // No port to free: a connection, the fold.
        var connection = row(.pane)
        connection.kind = .connection
        XCTAssertNil(ActivityPortHolder.step(for: connection))
        XCTAssertEqual(ActivityPortHolder.unavailable(connection), "Only a listening port is freed")
    }

    // MARK: The commands

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
        let greyed = try XCTUnwrap(page.verbs(for: [pane.id]) { _ in }.first { $0.key == "f" })
        XCTAssertNotNil(greyed.unavailable, "a tab's process: the verbs' stage, greyed with why")
        XCTAssertFalse(page.press("f"), "and f does nothing")
        XCTAssertEqual(box.freed.count, 1)
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
