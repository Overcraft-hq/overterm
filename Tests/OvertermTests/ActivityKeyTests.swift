import Darwin
import Foundation
import XCTest

@testable import Overterm

/// The Activity page's keys, columns and live order (docs/design/activity/
/// analysis.md, 6.3, 6.5, 6.7) over a fake Mac: the key table well formed,
/// htop's sort keys, `u`, `F`, `Z` giving the census back, `?` and `/`,
/// ← and → folding, columns moved and resized kept, the order held while
/// the list is worked and the rows a tick brought shown once it lets go.
@MainActor
final class ActivityKeyTests: XCTestCase {
    private let kernel = FakeActivityKernel(uid: 501)
    private let app: pid_t = 1000
    private let tab = UUID()

    override func tearDown() {
        AppEnvironment.defaults.removeObject(forKey: ActivityColumns.key)
        super.tearDown()
    }

    @discardableResult
    private func add(_ pid: pid_t, parent: pid_t, uid: uid_t = 501, name: String, cpu: UInt64 = 0) -> ActivityProcessID {
        let start = UInt64(pid) * 1_000
        var process = FakeActivityKernel.Process(
            record: FakeActivityKernel.record(pid: pid, start: start, parent: parent, uid: uid, realUID: uid == 0 ? 501 : nil, name: name))
        process.name = name
        process.path = "/opt/acme/bin/\(name)"
        process.codeSigning = ActivityCodeSigning(flags: ActivityCodeSigning.valid)
        process.usage = FakeActivityKernel.usage(cpuTime: cpu, footprint: UInt64(pid) << 20, threads: 2)
        process.arguments = FakeActivityKernel.arguments(executable: process.path ?? name, [name])
        process.folder = "/tmp/acme-shop/\(name)"
        kernel.add(process)
        return ActivityProcessID(pid: pid, start: start)
    }

    private func mac() -> ActivityContext {
        add(1, parent: 0, uid: 0, name: "launchd")
        add(app, parent: 1, name: "Overterm")
        let login = add(1100, parent: app, uid: 0, name: "login")
        add(1101, parent: 1100, name: "zsh")
        add(1102, parent: 1101, name: "acme-server")
        add(1103, parent: 1102, name: "acme-worker")
        add(2000, parent: 1, name: "globex-tool")
        return ActivityContext(panes: [ActivityContext.Pane(tag: "pane-a", tab: tab, login: login)], appPID: app)
    }

    private func page() async throws -> (ActivityPageModel, ActivityMonitor) {
        let monitor = ActivityMonitor(sampler: ActivitySampler(kernel: kernel))
        monitor.setContext(mac())
        monitor.interval = .milliseconds(300)
        let page = ActivityPageModel(monitor: monitor)
        page.isolated = false
        page.tabTitles = { [tab] in [tab: "web"] }
        page.visible = true
        let read = await eventually { page.hasRead }
        XCTAssertTrue(read)
        return (page, monitor)
    }

    // MARK: The table

    func testTheKeyTableIsWellFormed() {
        XCTAssertTrue(ActivityKey.isWellFormed, "no key twice, each reachable")
        XCTAssertEqual(ActivityKey.of("1"), .processes)
        XCTAssertEqual(ActivityKey.of("2"), .listening)
        XCTAssertEqual(ActivityKey.of("\r"), .goTo)
        XCTAssertEqual(ActivityKey.of(" "), .detail)
        XCTAssertEqual(ActivityKey.of("P"), .sortCPU)
        XCTAssertEqual(ActivityKey.of("p"), .suspend, "case matters: P sorts by CPU, p suspends")
        XCTAssertEqual(ActivityKey.of("b"), .background)
        XCTAssertEqual(ActivityKey.of("n"), .lower)
        XCTAssertEqual(ActivityKey.of("N"), .sortPID, "case matters")
        XCTAssertEqual(ActivityKey.of("k"), .stop)
        XCTAssertEqual(ActivityKey.of("K"), .forceQuit, "case matters")
        XCTAssertEqual(ActivityKey.of("x"), .signal)
        XCTAssertEqual(ActivityKey.of("a"), .ask)
        XCTAssertNil(ActivityKey.of(String(Character(UnicodeScalar(NSLeftArrowFunctionKey)!))), "← is the table's own")
        XCTAssertEqual(ActivityKey.press("?", sheetShowing: false).map { if case .help = $0 { true } else { false } }, true)
        XCTAssertEqual(ActivityKey.press("x", sheetShowing: true).map { if case .closeSheet = $0 { true } else { false } }, true)
    }

    // MARK: Keys on the page

    func testHtopsSortKeysAndInvert() async throws {
        let (page, monitor) = try await page()
        defer { monitor.stop() }
        XCTAssertTrue(page.press("N"))
        XCTAssertEqual(page.processSort, ResourceSort(column: "pid"))
        let sorted = await eventually { page.content.processes.map(\.identity.pid) == page.content.processes.map(\.identity.pid).sorted() }
        XCTAssertTrue(sorted, "by PID, ascending")
        XCTAssertTrue(page.press("I"))
        XCTAssertEqual(page.processSort, ResourceSort(column: "pid", ascending: false))
        let inverted = await eventually { page.content.processes.first?.identity.pid == 2000 }
        XCTAssertTrue(inverted, "inverted")
        XCTAssertTrue(page.press("M"))
        XCTAssertEqual(page.processSort, ResourceSort(column: "memory", ascending: false))
        let byMemory = await eventually { page.content.processes.first?.name == "globex-tool" }
        XCTAssertTrue(byMemory, "the biggest footprint first")
        XCTAssertTrue(page.press("T"))
        XCTAssertEqual(page.processSort?.column, "time")
        XCTAssertTrue(page.press("P"))
        XCTAssertEqual(page.processSort, ResourceSort(column: "cpu", ascending: false))
        page.section = .listening
        XCTAssertFalse(page.press("N"), "Processes' only")
    }

    func testYoursOnlyFollowAndTheSheets() async throws {
        let (page, monitor) = try await page()
        defer { monitor.stop() }
        XCTAssertTrue(page.content.processes.contains { !$0.isOwn }, "everyone's by default (D-7)")
        XCTAssertTrue(page.press("u"))
        XCTAssertEqual(page.everyone, false)
        let mine = await eventually { !page.content.processes.isEmpty && page.content.processes.allSatisfy(\.isOwn) }
        XCTAssertTrue(mine, "yours only")
        XCTAssertTrue(page.press("u"))
        XCTAssertEqual(page.everyone, true)
        XCTAssertTrue(page.press("F"))
        XCTAssertTrue(page.following)
        let filter = page.focusFilter
        XCTAssertTrue(page.press("/"))
        XCTAssertEqual(page.focusFilter, filter + 1)
        XCTAssertTrue(page.press("?"))
        XCTAssertTrue(page.cheatSheet)
        XCTAssertTrue(page.orderHeld, "a sheet over the list holds its order")
        XCTAssertTrue(page.press("P"))
        XCTAssertFalse(page.cheatSheet, "any key closes it, and does nothing else")
        XCTAssertFalse(page.orderHeld)
        XCTAssertTrue(page.press(" "))
        XCTAssertFalse(page.showsDetail)
    }

    /// `Z`: values and order frozen, the census given back; again, read.
    func testPauseGivesTheCensusBack() async throws {
        let (page, monitor) = try await page()
        defer { monitor.stop() }
        XCTAssertTrue(page.press("Z"))
        XCTAssertTrue(page.paused)
        XCTAssertFalse(monitor.demand.full, "the page was its only reader")
        XCTAssertTrue(page.hasRead, "its rows stay")
        let builds = page.builds
        page.take(try XCTUnwrap(monitor.sampler.tickNow(ActivityDemand(.full), context: monitor.context)))
        XCTAssertEqual(page.builds, builds, "a tick that lands while paused is not taken")
        page.setFilter("acme")
        let filtered = await eventually { page.builds > builds && page.content.processes.allSatisfy { $0.name.hasPrefix("acme") || $0.dimmed } }
        XCTAssertTrue(filtered, "the filter still works on the frozen rows")
        XCTAssertTrue(page.press("Z"))
        XCTAssertTrue(monitor.demand.full)
        page.visible = false
        XCTAssertFalse(page.paused, "hidden, the pause goes with the rows")
    }

    /// The selected row's detail: its tree, its command, its usage.
    func testTheDetailOfTheSelection() async throws {
        let (page, monitor) = try await page()
        defer { monitor.stop() }
        let server = try XCTUnwrap(page.content.processes.first { $0.name == "acme-server" })
        page.selection = [server.id]
        let detail = try XCTUnwrap(page.detail)
        XCTAssertEqual(detail.ancestors.map(\.name), ["zsh", "login", "Overterm", "launchd"])
        XCTAssertEqual(detail.children.map(\.name), ["acme-worker"])
        XCTAssertEqual(detail.row.command, "acme-server")
        XCTAssertTrue(detail.subtitle.hasPrefix("pid 1102"))
        XCTAssertEqual(page.selectedProcess?.id, server.id)
        page.selection = []
        XCTAssertNil(page.detail)
    }

    /// An isolated run's rows are its own tabs' (9.9): the detail's tree
    /// stops at the first ancestor that isn't one — never Overterm, nor
    /// what launched the run — and every ancestor is a row.
    func testTheDetailsTreeStopsAtTheRows() async throws {
        let monitor = ActivityMonitor(sampler: ActivitySampler(kernel: kernel))
        monitor.setContext(mac())
        monitor.interval = .milliseconds(300)
        defer { monitor.stop() }
        let page = ActivityPageModel(monitor: monitor)
        page.isolated = true
        page.tabTitles = { [tab] in [tab: "web"] }
        page.visible = true
        let read = await eventually { page.content.processes.contains { $0.name == "acme-server" } }
        XCTAssertTrue(read)
        let server = try XCTUnwrap(page.content.processes.first { $0.name == "acme-server" })
        page.selection = [server.id]
        let detail = try XCTUnwrap(page.detail)
        XCTAssertFalse(detail.ancestors.isEmpty, "up to the pane's shell at least")
        XCTAssertFalse(detail.ancestors.contains { $0.name == "Overterm" || $0.name == "launchd" })
        let rows = Set(page.content.processes.map(\.id))
        XCTAssertTrue(detail.ancestors.allSatisfy { rows.contains($0.id) }, "every ancestor a row")
        XCTAssertTrue(detail.children.allSatisfy { rows.contains($0.id) })
    }

    /// One verb list for the detail's bar and the row's menu: what can't be
    /// done greyed with why; ↩ to its tab and pane, `s` to Sample, ⌥o the
    /// default browser; several rows: Copy.
    func testTheVerbsAreOneList() async throws {
        let (page, monitor) = try await page()
        defer { monitor.stop() }
        final class Box {
            var goTo: [(UUID, String?)] = []
            var sampled: [pid_t] = []
            var copied: [[String]] = []
            var acted: [(ActivityVerb, ActivityProcessID)] = []
            var chosen: [ActivityProcessID] = []
            var stopped: [ActivityProcessID] = []
            var lowered: [ActivityProcessID] = []
            var asked: [(ActivityBrief, UUID?)] = []
        }
        let box = Box()
        page.actions.ask = { brief, tab in box.asked.append((brief, tab)) }
        page.actions.act = { verb, identity in box.acted.append((verb, identity)) }
        page.actions.chooseSignal = { box.chosen.append($0) }
        page.actions.stop = { box.stopped.append($0) }
        page.actions.chooseLower = { box.lowered.append($0) }
        page.actions.goTo = { tab, pane in box.goTo.append((tab, pane)) }
        page.actions.sample = { box.sampled.append($0) }
        let server = try XCTUnwrap(page.content.processes.first { $0.name == "acme-server" })
        let other = try XCTUnwrap(page.content.processes.first { $0.name == "globex-tool" })
        page.selection = [server.id]
        // Its verbs once its process is read off the main thread.
        let read = await eventually { page.verbSubject?.signal.identity == server.identity }
        XCTAssertTrue(read)
        let verbs = page.verbs(for: [server.id]) { box.copied.append($0) }
        XCTAssertEqual(
            verbs.map(\.title),
            [
                "Go to Tab", "Open in Browser", "Open in Default Browser", "Reveal in Finder", "Reveal Its Folder in Finder", "Terminal in Its Folder",
                "Tab Info", "Sample for 5 Seconds in a Tab", "Open Files in a Tab", "Ask an Agent About It…", "Interrupt…", "Stop…", "Force Quit…", "Send a Signal",
                "Stop Its Tree…", "Stop Its Group…", "Stop Its Parent…", "Suspend", "Run in Background", "Lower Priority", "Copy PID",
                "Copy Command", "Copy",
            ])
        XCTAssertEqual(
            verbs.first { $0.title == "Lower Priority" }?.children.map(\.title), ["+5 — nice 5…", "+10 — nice 10…", "20 — nice 20…"],
            "each step names the nice it gives")
        XCTAssertEqual(
            verbs.filter { $0.place == .button }.map(\.title), ["Go to Tab", "Open in Browser", "Reveal in Finder", "Tab Info", "Ask an Agent About It…"])
        XCTAssertNotNil(verbs.first { $0.title == "Open in Browser" }?.unavailable, "it listens on nothing: greyed, with why")
        XCTAssertNil(verbs.first { $0.title == "Go to Tab" }?.unavailable)
        verbs.first { $0.title == "Go to Tab" }?.perform()
        XCTAssertEqual(box.goTo.last?.0, tab)
        XCTAssertEqual(box.goTo.last?.1, "pane-a", "its pane too")
        XCTAssertTrue(page.press("\r"))
        XCTAssertEqual(box.goTo.count, 2)
        XCTAssertTrue(page.press("s"))
        XCTAssertEqual(box.sampled, [1102])
        XCTAssertFalse(page.pressOption("o"), "nothing to open")
        // k, K, x: the verb its class asks — decided by the window on its
        // read again —, Force Quit, Send a Signal — each handed to the
        // window, which reads it again and asks.
        XCTAssertTrue(page.press("k"))
        XCTAssertEqual(box.stopped, [server.identity])
        XCTAssertTrue(page.press("K"))
        XCTAssertEqual(box.acted.last?.0, .forceQuit)
        XCTAssertTrue(page.press("x"))
        XCTAssertEqual(box.chosen, [server.identity])
        // p, b, n: Suspend (it runs), Run in Background (Activity put it
        // nowhere), Lower Priority's steps.
        XCTAssertTrue(page.press("p"))
        XCTAssertEqual(box.acted.last?.0, .suspend)
        XCTAssertTrue(page.press("b"))
        XCTAssertEqual(box.acted.last?.0, .background)
        XCTAssertTrue(page.press("n"))
        XCTAssertEqual(box.lowered, [server.identity])
        // a: Ask an Agent About It, its brief from the detail, its tab's.
        XCTAssertNil(verbs.first { $0.title == "Ask an Agent About It…" }?.unavailable)
        XCTAssertTrue(page.press("a"))
        XCTAssertEqual(box.asked.last?.0.subject, "“acme-server” (pid 1102)")
        XCTAssertEqual(box.asked.last?.1, tab)
        verbs.first { $0.title == "Stop Its Tree…" }?.perform()
        XCTAssertEqual(box.acted.last?.0, .stopTree)
        verbs.first { $0.title == "Copy" }?.perform()
        XCTAssertEqual(box.copied.last, ["acme-server\t1102"])
        XCTAssertEqual(page.verbs(for: [other.id]) { _ in }.first { $0.title == "Go to Tab" }?.unavailable, "It runs outside every tab")
        XCTAssertEqual(page.verbs(for: [server.id, other.id]) { _ in }.map(\.title), ["Copy 2 Rows"])
    }

    /// A process Activity stopped reads as Activity's stop on its verbs once
    /// a tick lists it stopped: Resume offered, `p` its key; put in the
    /// background, Run Normally at once — nothing can read that back.
    func testWhatActivityHoldsIsSaidOnTheVerbs() async throws {
        let (page, monitor) = try await page()
        defer { monitor.stop() }
        let held = ActivityHeld()
        page.held = held
        page.known = { [app] in ActivityVerbSubject.Known(appPID: app, stoppedHere: held.stopped, backgroundHere: held.backgroundHere) }
        let worker = try XCTUnwrap(page.content.processes.first { $0.name == "acme-worker" })
        page.selection = [worker.id]
        let read = await eventually { page.verbSubject?.signal.identity == worker.identity }
        XCTAssertTrue(read)
        XCTAssertEqual(page.verbs(for: [worker.id]) { _ in }.first { $0.key == "p" }?.title, "Suspend")
        kernel.update(1103) { $0.record = FakeActivityKernel.record($0.record, status: SSTOP) }
        let target = ActivitySignalTarget(worker.identity, path: "/opt/acme/bin/acme-worker")
        held.suspended(root: target, name: "acme-worker", members: [target], names: [:])
        let resume = await eventually {
            page.verbs(for: [worker.id]) { _ in }.first { $0.key == "p" }.map { $0.title == "Resume" && $0.unavailable == nil } == true
        }
        XCTAssertTrue(resume, "Resume, offered: \(page.verbSubject?.target.stopped.map { "\($0)" } ?? "nobody")")
        held.backgrounded(worker.identity)
        page.refreshVerbs()
        let normally = await eventually { page.verbs(for: [worker.id]) { _ in }.first { $0.key == "b" }?.title == "Run Normally" }
        XCTAssertTrue(normally)
    }

    /// The rows' "suspended here" and "background" are the rows' own: said
    /// with nothing selected, as with a row selected.
    func testTheHeldChipsWithNothingSelected() async throws {
        let (page, monitor) = try await page()
        defer { monitor.stop() }
        let held = ActivityHeld()
        page.held = held
        page.known = { [app] in ActivityVerbSubject.Known(appPID: app, stoppedHere: held.stopped, backgroundHere: held.backgroundHere) }
        let worker = try XCTUnwrap(page.content.processes.first { $0.name == "acme-worker" })
        page.selection = []
        kernel.update(1103) { $0.record = FakeActivityKernel.record($0.record, status: SSTOP) }
        let target = ActivitySignalTarget(worker.identity, path: "/opt/acme/bin/acme-worker")
        held.suspended(root: target, name: "acme-worker", members: [target], names: [:])
        held.backgrounded(worker.identity)
        page.refreshVerbs()
        let said = await eventually {
            let row = page.content.processes.first { $0.id == worker.id }
            return row?.stoppedHere == true && row?.backgroundHere == true
        }
        XCTAssertTrue(said, "both chips, no selection")
        XCTAssertNil(page.verbSubject)
    }

    /// The selection's verbs read its process with every owner of the
    /// snapshot, off the main thread — not only the rows a filter left: its
    /// parent, the pane's shell filtered away, is still the pane's shell,
    /// never a supervisor elsewhere; before it is read, they say so.
    func testTheVerbsReadEveryOwnerWhateverTheRowsLeave() async throws {
        let (page, monitor) = try await page()
        defer { monitor.stop() }
        page.grouping = .none
        page.tree = false
        page.setFilter("acme-server")
        let filtered = await eventually { page.content.processes.map(\.name) == ["acme-server"] }
        XCTAssertTrue(filtered, "the shell is no row")
        let server = try XCTUnwrap(page.content.processes.first)
        XCTAssertTrue(page.signalVerbs(for: server).filter(\.children.isEmpty).allSatisfy { $0.unavailable == ActivityPageModel.reading }, "not read yet: greyed, said")
        page.selection = [server.id]
        let read = await eventually { page.verbSubject?.signal.identity == server.identity }
        XCTAssertTrue(read)
        let subject = try XCTUnwrap(page.subject(for: server))
        XCTAssertEqual(subject.target.kind, .paneJob)
        XCTAssertEqual(subject.parentTarget?.kind, .paneSession, "its parent the pane's shell, filtered out of the rows")
        XCTAssertNil(subject.supervisor, "so nobody is named as what may start it again")
        XCTAssertEqual(
            ActivitySignalCheck.rule(.stopParent, for: subject.target, parent: subject.parentTarget, user: 501), .route(.closePane, confirm: true),
            "Stop Its Parent is the pane's close, never a plain Stop")
        page.selection = []
        XCTAssertNil(page.verbSubject)
    }

    /// The verbs that don't signal (6.10): its folder read at the focus
    /// level for the selection alone, then Terminal in Its Folder (`e`)
    /// and ⌥r; Open Files and Sample typed into a tab, read only; Copy PID
    /// and the masked command.
    func testTheVerbsThatDontSignal() async throws {
        let (page, monitor) = try await page()
        defer { monitor.stop() }
        final class Box {
            var terminals: [ActivityTerminalRequest] = []
            var revealed: [String] = []
            var copied: [[String]] = []
        }
        let box = Box()
        page.actions.terminal = { box.terminals.append($0) }
        page.actions.reveal = { box.revealed.append($0) }
        let server = try XCTUnwrap(page.content.processes.first { $0.name == "acme-server" })
        page.selection = [server.id]
        XCTAssertEqual(page.focused, [server.identity], "the selection read in depth")
        XCTAssertTrue(monitor.demand.focus.contains(server.identity))
        let read = await eventually { page.selectedFolder == "/tmp/acme-shop/acme-server" }
        XCTAssertTrue(read, "its folder, a tick or two later")
        XCTAssertTrue(page.press("e"))
        XCTAssertEqual(box.terminals.last, ActivityTerminalRequest(directory: "/tmp/acme-shop/acme-server"))
        XCTAssertTrue(page.pressOption("r"))
        XCTAssertEqual(box.revealed.last, "/tmp/acme-shop/acme-server")
        let verbs = page.verbs(for: [server.id]) { box.copied.append($0) }
        verbs.first { $0.title == "Open Files in a Tab" }?.perform()
        XCTAssertEqual(box.terminals.last?.command, "lsof -nP -p 1102")
        XCTAssertEqual(ActivityPageModel.sampleCommand(1102), "sample 1102 5 -file /dev/stdout", "its report to the tab, none left in /tmp")
        verbs.first { $0.title == "Copy PID" }?.perform()
        XCTAssertEqual(box.copied.last, ["1102"])
        verbs.first { $0.title == "Copy Command" }?.perform()
        XCTAssertEqual(box.copied.last, [server.command ?? "-"], "the command as it was masked")
        // Another user's: no folder, no lsof.
        let login = try XCTUnwrap(page.content.processes.first { $0.name == "login" })
        page.selection = [login.id]
        XCTAssertEqual(page.focused, [], "another user's isn't read in depth")
        let theirs = page.verbs(for: [login.id]) { _ in }
        XCTAssertNotNil(theirs.first { $0.title == "Terminal in Its Folder" }?.unavailable)
        XCTAssertNotNil(theirs.first { $0.title == "Open Files in a Tab" }?.unavailable)
        XCTAssertFalse(page.press("e"))
        page.selection = []
        XCTAssertEqual(page.focused, [])
        XCTAssertFalse(monitor.demand.focus.contains(server.identity), "the focus given back")
    }

    // MARK: ← →

    func testLeftAndRightFoldAndUnfold() async throws {
        let (page, monitor) = try await page()
        defer { monitor.stop() }
        let server = try XCTUnwrap(page.content.processes.first { $0.name == "acme-server" })
        let tabGroup = "group:tab:\(tab.uuidString)"
        let listed = await eventually { page.content.list.contains { $0.id == server.id } }
        XCTAssertTrue(listed)
        XCTAssertFalse(page.fold(server.id, open: true), "already open")
        XCTAssertTrue(page.fold(server.id, open: false), "← folds its children")
        let folded = await eventually { !page.content.list.contains { $0.id.hasPrefix("1103:") } }
        XCTAssertTrue(folded)
        XCTAssertTrue(page.fold(server.id, open: true), "→ unfolds")
        let open = await eventually { page.content.list.contains { $0.id.hasPrefix("1103:") } }
        XCTAssertTrue(open)
        let leaf = try XCTUnwrap(page.content.processes.first { $0.name == "acme-worker" })
        XCTAssertFalse(page.fold(leaf.id, open: false), "a leaf: the table's own ←")
        XCTAssertTrue(page.fold(tabGroup, open: false), "a group folds too")
    }

    // MARK: Columns

    func testColumnsMovedResizedAndPickedAreKept() async throws {
        XCTAssertEqual(ActivityColumns.columns(.processes, kept: nil, grouping: .checkout, everyone: false).map(\.id), ActivityColumns.processDefaults)
        XCTAssertEqual(
            ActivityColumns.columns(.processes, kept: nil, grouping: .checkout, everyone: true).map(\.id), ActivityColumns.processDefaults + ["user"],
            "User while All shows")
        XCTAssertEqual(ActivityColumns.columns(.processes, kept: nil, grouping: .none, everyone: true).suffix(2).map(\.id), ["user", "where"], "Where by the grouping")
        XCTAssertFalse(ActivityColumns.choices(.processes).contains { $0.id == "user" || $0.id == "where" })
        let (page, monitor) = try await page()
        defer { monitor.stop() }
        var columns = page.columns(.processes)
        columns.swapAt(1, 2)
        columns[0].width = 333
        page.columnsChanged(columns, in: .processes)
        XCTAssertEqual(page.columns(.processes).prefix(3).map(\.id), ["name", "cpu", "pid"])
        page.toggleColumn("command", in: .processes)
        page.toggleColumn("threads", in: .processes)
        let shown = page.columns(.processes).map(\.id)
        XCTAssertEqual(shown.last, "command")
        XCTAssertFalse(shown.contains("threads"))
        // Another page — the next launch — builds them as they were left.
        let again = ActivityPageModel(monitor: monitor)
        XCTAssertEqual(again.columns(.processes).map(\.id), shown)
        XCTAssertEqual(again.columns(.processes).first?.width, 333)
        XCTAssertEqual(
            ActivityColumns.columns(.processes, kept: [ActivityColumns.Kept(id: "acme-gone", width: 10)], grouping: .checkout, everyone: false).map(\.id), ["name"])
        page.everyone = false
        XCTAssertFalse(page.columns(.processes).contains { $0.id == "user" }, "Yours: every row's user is the same")
        page.everyone = true
        XCTAssertTrue(page.columns(.processes).contains { $0.id == "user" })
    }

    // MARK: The order held

    func testTheHoldsRules() {
        let start = ContinuousClock.now
        var hold = ActivityHold()
        XCTAssertFalse(hold.holds(at: start))
        hold.note(.hover, at: start)
        XCTAssertTrue(hold.holds(at: start + .seconds(4)))
        XCTAssertFalse(hold.holds(at: start + .seconds(5)), "lets go once the pointer rested 5 s")
        XCTAssertEqual(hold.restsAt, start + .seconds(5))
        hold.note(.pressBegan, at: start + .seconds(1))
        XCTAssertTrue(hold.holds(at: start + .seconds(60)), "a press in flight holds however long")
        XCTAssertNil(hold.restsAt)
        hold.note(.pressEnded, at: start + .seconds(61))
        XCTAssertTrue(hold.holds(at: start + .seconds(65)), "rested from the press's end")
        hold.note(.menuOpened, at: start + .seconds(70))
        XCTAssertTrue(hold.holds(at: start + .seconds(100)))
        hold.note(.menuClosed, at: start + .seconds(100))
        hold.note(.exit, at: start + .seconds(101))
        XCTAssertFalse(hold.holds(at: start + .seconds(101)), "the pointer left")
        XCTAssertTrue(hold.holds(at: start, voiceOver: true), "VoiceOver's focus in the list")
    }

    func testAHeldOrderTakesNewValuesButNoNewRows() {
        func row(_ pid: pid_t, cpu: Double) -> ActivityListItem {
            .process(
                ActivityProcessRow(
                    id: "\(pid):1", identity: ActivityProcessID(pid: pid, start: 1), name: "acme-\(pid)", cpu: cpu, memory: nil, threads: nil,
                    state: .sleeping, started: Date(timeIntervalSince1970: 0), startedText: "", user: "fake", isOwn: true, tab: nil, tabTitle: nil))
        }
        var shown = ActivityPageContent()
        shown.list = [row(1, cpu: 50), row(2, cpu: 10), row(3, cpu: 1)]
        var next = ActivityPageContent()
        next.list = [row(4, cpu: 90), row(2, cpu: 70), row(1, cpu: 5)]
        let held = ActivityRows.held(shown, next)
        XCTAssertEqual(held.list.map(\.id), ["1:1", "2:1", "3:1"], "the order shown; the new row waits")
        if case .process(let first) = held.list[0] { XCTAssertEqual(first.cpu, 5, "with its new value") }
        if case .process(let gone) = held.list[2] { XCTAssertEqual(gone.cpu, 1, "a row gone keeps its last") }
        XCTAssertNil(held.shownIDs, "the ids made with the next rows aren't the held ones")
        XCTAssertEqual(ActivityRows.shownIDs(held), ["1:1", "2:1", "3:1"])
    }

    func testTheOrderHoldsWhileTheListIsWorked() async throws {
        let (page, monitor) = try await page()
        defer { monitor.stop() }
        page.interacted(.hover)
        XCTAssertTrue(page.orderHeld)
        let order = page.content.list.map(\.id)
        add(1104, parent: 1101, name: "acme-new")
        let waited = await eventually { page.waiting?.processes.contains { $0.name == "acme-new" } == true }
        XCTAssertTrue(waited, "a tick's rows wait while it holds")
        XCTAssertEqual(page.content.list.map(\.id), order, "no row moves, none comes")
        page.setFilter("acme")
        let asked = await eventually { page.content.processes.contains { $0.name == "acme-new" } }
        XCTAssertTrue(asked, "what the person asks for shows at once")
        page.setFilter("")
        _ = await eventually { page.content.processes.contains { $0.name == "launchd" } }
        page.interacted(.exit)
        XCTAssertFalse(page.orderHeld, "the pointer left: it lets go")
        XCTAssertNil(page.waiting)
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
