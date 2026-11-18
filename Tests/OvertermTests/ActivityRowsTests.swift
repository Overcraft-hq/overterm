import Darwin
import Foundation
import XCTest

@testable import Overterm

/// The Activity page's rows and its want (docs/design/activity/analysis.md,
/// 6.4, 7.9, 9.9) over a fake Mac: every process, other users' named only,
/// a test run's own tabs' alone, the first sample "—", CPU first; the
/// listeners of the user's processes with their tab; what VoiceOver says;
/// the full level wanted only while the page shows in a window on screen.
@MainActor
final class ActivityRowsTests: XCTestCase {
    private let kernel = FakeActivityKernel(uid: 501)
    private let app: pid_t = 1000
    private let tab = UUID()

    override func tearDown() {
        Settings.shared.set("activity.enabled", nil)
        Settings.shared.set("activity.everyone", nil)
        super.tearDown()
    }

    @discardableResult
    private func add(_ pid: pid_t, parent: pid_t, uid: uid_t = 501, name: String, cpu: UInt64 = 0, sockets: [socket_fdinfo] = []) -> ActivityProcessID {
        let start = UInt64(pid) * 1_000
        var process = FakeActivityKernel.Process(
            record: FakeActivityKernel.record(pid: pid, start: start, parent: parent, uid: uid, realUID: uid == 0 ? 501 : nil, name: name))
        process.name = name
        process.path = uid == 501 ? "/opt/acme/bin/\(name)" : "/usr/libexec/\(name)"
        process.codeSigning = ActivityCodeSigning(flags: ActivityCodeSigning.valid)
        process.usage = FakeActivityKernel.usage(cpuTime: cpu, footprint: 8 << 20, threads: 3)
        process.arguments = FakeActivityKernel.arguments(executable: process.path ?? name, [name])
        process.descriptors = sockets.indices.map { FakeActivityKernel.descriptor(Int32(3 + $0)) }
        process.sockets = Dictionary(uniqueKeysWithValues: sockets.enumerated().map { (Int32(3 + $0.offset), $0.element) })
        kernel.add(process)
        return ActivityProcessID(pid: pid, start: start)
    }

    private func burn(_ pid: pid_t, _ cpu: UInt64) {
        kernel.update(pid) { process in
            process.usage = FakeActivityKernel.usage(cpuTime: (process.usage?.cpuTime ?? 0) + cpu, footprint: 8 << 20, threads: 3)
        }
    }

    /// launchd, the app, a pane — its root `login`, a shell, a server
    /// listening on TCP 5173 and bound on UDP 5353 — one of the user's
    /// elsewhere, listening too, and root's daemon.
    private func mac() -> ActivityContext {
        add(1, parent: 0, uid: 0, name: "launchd")
        add(app, parent: 1, name: "Overterm")
        let login = add(1100, parent: app, uid: 0, name: "login")
        add(1101, parent: 1100, name: "zsh")
        add(
            1102, parent: 1101, name: "acme-server",
            sockets: [FakeActivityKernel.tcp(local: "127.0.0.1", port: 5173, handle: 1), FakeActivityKernel.udp(local: "0.0.0.0", port: 5353, handle: 2)])
        add(2000, parent: 1, name: "globex-agent", sockets: [FakeActivityKernel.tcp(local: "0.0.0.0", port: 8080, handle: 3)])
        add(300, parent: 1, uid: 0, name: "fakeservd")
        return ActivityContext(panes: [ActivityContext.Pane(tag: "pane-a", tab: tab, login: login)], appPID: app)
    }

    private func full(_ sampler: ActivitySampler, _ context: ActivityContext) throws -> ActivitySnapshot {
        try XCTUnwrap(sampler.tickNow(ActivityDemand(.full), context: context))
    }

    func testEveryProcessOtherUsersNamedTheFirstSampleADash() throws {
        let context = mac()
        let snapshot = try full(ActivitySampler(kernel: kernel), context)
        let content = ActivityRows.content(of: snapshot, ActivityRows.Options(titles: [tab: "web"]))
        XCTAssertEqual(content.summary.processes, 7)
        XCTAssertEqual(content.summary.own, 4, "the login runs as root")
        XCTAssertEqual(content.processes.count, 7, "everyone's, as htop shows them (D-7)")
        XCTAssertTrue(content.summary.firstSample)
        XCTAssertTrue(content.processes.allSatisfy { $0.cpu == nil }, "a first sample is —, never 0")
        let daemon = try XCTUnwrap(content.processes.first { $0.name == "fakeservd" })
        XCTAssertFalse(daemon.isOwn)
        XCTAssertNil(daemon.memory, "another user's numbers aren't readable")
        XCTAssertEqual(daemon.user, ActivityRows.userName(0))
        let server = try XCTUnwrap(content.processes.first { $0.name == "acme-server" })
        XCTAssertEqual(server.tabTitle, "web")
        XCTAssertEqual(server.memory, 8 << 20)
        XCTAssertNil(content.processes.first { $0.name == "globex-agent" }?.tab, "outside every tab")
        XCTAssertEqual(server.accessibilityLabel, "acme-server, pid 1102, in “web”")
    }

    func testCPUFirstOnceRatedAndTheBusiest() throws {
        let context = mac()
        let sampler = ActivitySampler(kernel: kernel)
        _ = try full(sampler, context)
        burn(1102, 400_000_000)
        burn(2000, 100_000_000)
        kernel.advance(1_000_000_000)
        let snapshot = try full(sampler, context)
        let content = ActivityRows.content(of: snapshot, ActivityRows.Options(titles: [tab: "web"]))
        XCTAssertFalse(content.summary.firstSample)
        XCTAssertEqual(content.processes.prefix(2).map(\.name), ["acme-server", "globex-agent"], "busiest first")
        XCTAssertEqual(content.processes.first?.cpu ?? 0, 40, accuracy: 0.01)
        XCTAssertEqual(content.summary.busiest.first?.name, "acme-server")
        XCTAssertLessThanOrEqual(content.summary.busiest.count, 5)
        XCTAssertEqual(content.processes.first?.accessibilityLabel, "acme-server, pid 1102, 40.0 percent CPU, in “web”")
        XCTAssertEqual(content.processes.last.map { $0.cpu == nil }, true, "missing values last")
        let byName = ActivityRows.sorted(content.processes, by: ResourceSort(column: "name"))
        XCTAssertEqual(byName.first?.name, "acme-server")
    }

    func testOnlyYoursWithoutEveryone() throws {
        let snapshot = try full(ActivitySampler(kernel: kernel), mac())
        let content = ActivityRows.content(of: snapshot, ActivityRows.Options(everyone: false))
        XCTAssertEqual(content.processes.count, 4)
        XCTAssertTrue(content.processes.allSatisfy(\.isOwn))
        XCTAssertEqual(content.summary.processes, 7, "counted all the same")
    }

    /// A test run lists only its own tabs' processes; the Mac is counts (9.9).
    func testATestRunListsOnlyItsOwnTabs() throws {
        let snapshot = try full(ActivitySampler(kernel: kernel), mac())
        let content = ActivityRows.content(of: snapshot, ActivityRows.Options(titles: [tab: "web"], isolated: true))
        XCTAssertEqual(Set(content.processes.map(\.name)), ["zsh", "acme-server"])
        XCTAssertTrue(content.summary.scopedToRun)
        XCTAssertEqual(content.summary.processes, 7)
        XCTAssertEqual(content.ports.map(\.port), [5173, 5353], "and only their listeners")
    }

    func testTheListenersOfYourProcessesWithTheirTab() throws {
        let snapshot = try full(ActivitySampler(kernel: kernel), mac())
        let content = ActivityRows.content(of: snapshot, ActivityRows.Options(titles: [tab: "web"]))
        XCTAssertEqual(content.ports.map(\.port), [5173, 5353, 8080], "by number")
        let tcp = try XCTUnwrap(content.ports.first { $0.port == 5173 })
        XCTAssertEqual(tcp.proto, "tcp")
        XCTAssertEqual(tcp.reach, "This Mac")
        XCTAssertEqual(tcp.familyWords, "v4")
        XCTAssertEqual(tcp.tabTitle, "web")
        XCTAssertEqual(tcp.url?.absoluteString, "http://127.0.0.1:5173")
        XCTAssertEqual(tcp.accessibilityLabel, ":5173 tcp, acme-server, pid 1102, This Mac, in “web”")
        XCTAssertEqual(content.ports.first { $0.port == 5353 }?.proto, "udp")
        let wide = try XCTUnwrap(content.ports.first { $0.port == 8080 })
        XCTAssertEqual(wide.reach, "Network")
        XCTAssertNil(wide.tabTitle)
        XCTAssertEqual(content.summary.listening, 3)
    }

    /// A tab's title is often its command: masked as one wherever it
    /// leaves the strip — the Where column, VoiceOver (9.3).
    func testATabsTitleIsMaskedAsACommandIs() throws {
        let secret = "fake-secret-1"
        let snapshot = try full(ActivitySampler(kernel: kernel), mac())
        let content = ActivityRows.content(of: snapshot, ActivityRows.Options(titles: [tab: "psql --password \(secret) -h acme-db"]))
        let server = try XCTUnwrap(content.processes.first { $0.name == "acme-server" })
        XCTAssertNotNil(server.tabTitle)
        XCTAssertTrue(server.tabTitle?.hasPrefix("psql --password ") == true)
        let said =
            content.processes.compactMap(\.tabTitle) + content.processes.map(\.accessibilityLabel)
            + content.ports.compactMap(\.tabTitle) + content.ports.map(\.accessibilityLabel)
        XCTAssertFalse(said.isEmpty)
        XCTAssertFalse(said.contains { $0.contains(secret) }, "the password never shown")
    }

    /// Started: today's as its time, an earlier day's as its date —
    /// whatever the locale.
    func testTheStartedColumnsWords() throws {
        let today = Calendar.current.startOfDay(for: Date())
        let morning = today.addingTimeInterval(9 * 3_600 + 5 * 60)
        XCTAssertEqual(ActivityRows.startedText(morning, today: today), "09:05")
        let earlier = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: -3, to: morning))
        let words = ActivityRows.startedText(earlier, today: today)
        XCTAssertFalse(words.contains(":"), "an earlier day's start is its date")
        let snapshot = try full(ActivitySampler(kernel: kernel), mac())
        let content = ActivityRows.content(of: snapshot, ActivityRows.Options())
        XCTAssertTrue(content.processes.allSatisfy { !$0.startedText.isEmpty })
    }

    /// "Reading…" until rows are made and while no rate is in; an empty
    /// section says what is true of what was read (6.4).
    func testWhatTheHeaderAndAnEmptySectionSay() throws {
        XCTAssertTrue(ActivityPageView.reading(hasRead: false, ActivitySummary()), "before the first rows")
        let snapshot = try full(ActivitySampler(kernel: kernel), mac())
        let first = ActivityRows.content(of: snapshot, ActivityRows.Options())
        XCTAssertTrue(first.summary.firstSample)
        XCTAssertTrue(ActivityPageView.reading(hasRead: true, first.summary), "a first sample has no rates yet")
        var rated = first.summary
        rated.firstSample = false
        XCTAssertFalse(ActivityPageView.reading(hasRead: true, rated))
        rated.unread = 3
        XCTAssertTrue(ActivityPageView.reading(hasRead: true, rated), "processes left for a later tick")
        XCTAssertEqual(
            ActivityPageView.emptySentence(.listening, scopedToRun: false), "Nothing of yours listens on a port. Other users' listeners aren't read.")
        XCTAssertEqual(ActivityPageView.emptySentence(.listening, scopedToRun: true), "Nothing in this test run's tabs listens on a port.")
        XCTAssertEqual(ActivityPageView.emptySentence(.processes, scopedToRun: true), "Nothing runs in this test run's tabs.")
    }

    func testNumbersAreWrittenWhateverTheLocale() {
        XCTAssertEqual(ActivityRows.percent(1234.56), "1234.6")
        XCTAssertEqual(ActivityRows.bytes(8 << 20), "8.0 MB")
        XCTAssertEqual(ActivityRows.bytes(1_536), "1.5 KB")
        XCTAssertEqual(ActivityRows.bytes(512), "512 B")
    }

    // MARK: The want

    /// The full level only while the page is the one shown in a window on
    /// screen, with Activity on (7.9); its rows from the snapshot it reads.
    func testThePageWantsTheFullLevelOnlyWhileItShows() async throws {
        let context = mac()
        let monitor = ActivityMonitor(sampler: ActivitySampler(kernel: kernel))
        monitor.setContext(context)
        let page = ActivityPageModel(monitor: monitor)
        page.isolated = false
        page.tabTitles = { [tab] in [tab: "web"] }
        XCTAssertFalse(monitor.demand.full, "made, it reads nothing")
        page.visible = true
        XCTAssertTrue(monitor.demand.full)
        XCTAssertTrue(page.wanting)
        let read = await eventually { page.hasRead }
        XCTAssertTrue(read, "its rows from the tick its want made")
        XCTAssertTrue(page.content.processes.contains { $0.name == "acme-server" && $0.tabTitle == "web" })
        page.windowVisible = false
        XCTAssertFalse(monitor.demand.full, "its window off screen")
        XCTAssertFalse(page.hasRead, "hidden, its rows go: shown again, it reads before it says anything")
        XCTAssertTrue(page.content.processes.isEmpty)
        let builds = page.builds
        Settings.shared.set("activity.everyone", .bool(false))
        page.settingsChanged()
        page.processSort = ResourceSort(column: "name")
        await Task.yield()
        XCTAssertEqual(page.builds, builds, "hidden, a setting or a sort makes no rows")
        XCTAssertFalse(monitor.demand.full)
        Settings.shared.set("activity.everyone", nil)
        page.windowVisible = true
        XCTAssertTrue(monitor.demand.full)
        let again = await eventually { page.hasRead }
        XCTAssertTrue(again, "fresh rows once shown again")
        Settings.shared.set("activity.enabled", .bool(false))
        page.settingsChanged()
        XCTAssertFalse(monitor.demand.full, "Activity off")
        Settings.shared.set("activity.enabled", nil)
        page.settingsChanged()
        XCTAssertTrue(monitor.demand.full)
        page.visible = false
        XCTAssertFalse(monitor.demand.full, "hidden")
        XCTAssertFalse(monitor.isTicking, "nothing else wants the ticks")
        monitor.stop()
    }

    // MARK: The switcher (⌃⌘A)

    /// Ports first by number, then the ten busiest with a rate.
    func testTheSwitchersRowsPortsThenTheBusiest() throws {
        let context = mac()
        let sampler = ActivitySampler(kernel: kernel)
        _ = try full(sampler, context)
        burn(1102, 400_000_000)
        burn(2000, 100_000_000)
        kernel.advance(1_000_000_000)
        let content = ActivityRows.content(of: try full(sampler, context), ActivityRows.Options(titles: [tab: "web"]))
        let rows = ActivitySwitcher.rows(of: content)
        XCTAssertEqual(rows.prefix(3).map(\.title), [":5173 acme-server", ":5353 acme-server", ":8080 globex-agent"])
        XCTAssertEqual(rows.first?.subtitle, "tcp · This Mac — “web”")
        XCTAssertEqual(rows.first?.target, .port(url: URL(string: "http://127.0.0.1:5173")))
        let processes = rows.filter { $0.target == .process }
        XCTAssertEqual(processes.first?.title, "acme-server")
        XCTAssertEqual(processes.first?.subtitle, "40.0% CPU · pid 1102 — “web”")
        XCTAssertLessThanOrEqual(processes.count, 10)
        XCTAssertTrue(processes.allSatisfy { row in content.processes.first { $0.id == row.id }?.cpu != nil }, "only what has a rate")
    }

    /// It holds the full level every second while open, its rows frozen
    /// once a read has rates; closed, nothing.
    func testTheSwitcherHoldsTheFullLevelWhileOpen() async throws {
        let context = mac()
        let monitor = ActivityMonitor(sampler: ActivitySampler(kernel: kernel))
        monitor.setContext(context)
        let switcher = ActivitySwitcher(monitor: monitor)
        switcher.isolated = false
        var stocked = 0
        switcher.stocked = { stocked += 1 }
        switcher.open()
        XCTAssertTrue(switcher.wanting)
        XCTAssertTrue(monitor.demand.full)
        XCTAssertEqual(monitor.cadence, .seconds(1))
        let first = await eventually { switcher.rows != nil }
        XCTAssertTrue(first)
        XCTAssertGreaterThanOrEqual(stocked, 1)
        burn(1102, 400_000_000)
        kernel.advance(1_000_000_000)
        _ = await monitor.tick()
        let rated = await eventually { switcher.rows?.contains { $0.target == .process } == true }
        XCTAssertTrue(rated, "stocked again once a read has rates")
        XCTAssertFalse(switcher.wanting, "rated: the full level given back")
        XCTAssertFalse(monitor.demand.full)
        XCTAssertTrue(switcher.holding, "its rows kept while it is open")
        let frozen = switcher.rows
        let stocks = switcher.stocks
        burn(2000, 900_000_000)
        kernel.advance(1_000_000_000)
        _ = await eventually { !monitor.isSampling }
        let later = monitor.fullTicks
        _ = await monitor.tick()
        _ = await eventually { monitor.fullTicks > later }
        await Task.yield()
        XCTAssertEqual(switcher.stocks, stocks, "then kept as ranked")
        XCTAssertEqual(switcher.rows, frozen)
        switcher.close()
        XCTAssertFalse(monitor.demand.full)
        XCTAssertNil(switcher.rows)
        monitor.stop()
    }

    /// The switcher's subtitles, and so the palette's search, carry the
    /// tab's title masked, as the page's rows do (9.3).
    func testTheSwitchersRowsCarryTheMaskedTitle() throws {
        let secret = "fake-secret-2"
        let context = mac()
        let sampler = ActivitySampler(kernel: kernel)
        _ = try full(sampler, context)
        burn(1102, 400_000_000)
        kernel.advance(1_000_000_000)
        let content = ActivityRows.content(of: try full(sampler, context), ActivityRows.Options(titles: [tab: "curl -u acme:\(secret) https://acme.test"]))
        let rows = ActivitySwitcher.rows(of: content)
        XCTAssertTrue(rows.contains { $0.subtitle.contains("“curl -u ") })
        XCTAssertFalse(rows.contains { $0.title.contains(secret) || $0.subtitle.contains(secret) })
    }

    /// With Activity off, ⌘K offers no Activity tab to ⇥ into (6.13).
    func testThePaletteOffersActivitysTabOnlyWhileOn() {
        let palette = PaletteModel()
        XCTAssertTrue(palette.tabs.contains(.activity))
        Settings.shared.set("activity.enabled", .bool(false))
        XCTAssertFalse(palette.tabs.contains(.activity))
    }

    func testTheDigitsPickTheSections() {
        let page = ActivityPageModel(monitor: ActivityMonitor(sampler: ActivitySampler(kernel: kernel)))
        XCTAssertTrue(page.press("2"))
        XCTAssertEqual(page.section, .listening)
        XCTAssertTrue(page.press("1"))
        XCTAssertEqual(page.section, .processes)
        XCTAssertFalse(page.press("x"), "not the page's: the list's")
    }

    // MARK: Groups, the tree, the scope (6.5)

    private let tabB = UUID()
    private let checkout = "/Users/fake/src/acme-shop"

    /// `mac()` and a second tab of the same checkout, split: one pane's
    /// shell, the other's agent with an MCP server and a tool shell.
    private func grouped() -> ActivityContext {
        var context = mac()
        let loginB = add(1200, parent: app, uid: 0, name: "login")
        add(1201, parent: 1200, name: "zsh")
        let loginC = add(1300, parent: app, uid: 0, name: "login")
        add(1301, parent: 1300, name: "zsh")
        var claude = FakeActivityKernel.Process(record: FakeActivityKernel.record(pid: 1302, start: 1_302_000, parent: 1301, name: "claude"))
        claude.name = "claude"
        claude.path = "/opt/acme/bin/claude"
        claude.codeSigning = ActivityCodeSigning(flags: ActivityCodeSigning.valid)
        claude.usage = FakeActivityKernel.usage(footprint: 8 << 20, threads: 3)
        claude.arguments = FakeActivityKernel.arguments(executable: "/opt/acme/bin/claude", ["claude"])
        kernel.add(claude)
        var mcp = FakeActivityKernel.Process(record: FakeActivityKernel.record(pid: 1303, start: 1_303_000, parent: 1302, name: "node"))
        mcp.name = "node"
        mcp.path = "/opt/acme/bin/node"
        mcp.codeSigning = ActivityCodeSigning(flags: ActivityCodeSigning.valid)
        mcp.usage = FakeActivityKernel.usage(footprint: 8 << 20, threads: 3)
        mcp.arguments = FakeActivityKernel.arguments(executable: "/opt/acme/bin/node", ["node", "fake-mcp-server.js"])
        kernel.add(mcp)
        add(1110, parent: app, name: "git")
        context.panes += [ActivityContext.Pane(tag: "pane-b", tab: tabB, login: loginB), ActivityContext.Pane(tag: "pane-c", tab: tabB, login: loginC)]
        return context
    }

    private func options(_ context: ActivityContext, _ change: (inout ActivityRows.Options) -> Void = { _ in }) -> ActivityRows.Options {
        var options = ActivityRows.Options()
        options.tabs = [
            tab: ActivityTabFacts(id: tab, title: "web", checkout: checkout, branch: "feature-x", repository: "acme", order: 0),
            tabB: ActivityTabFacts(id: tabB, title: "agent", checkout: checkout, branch: "feature-x", repository: "acme", order: 1),
        ]
        options.context = context
        options.checkouts = [checkout]
        change(&options)
        return options
    }

    private func plain(_ context: ActivityContext, _ change: (inout ActivityRows.Options) -> Void) -> ActivityRows.Options {
        var options = ActivityRows.Options()
        options.context = context
        change(&options)
        return options
    }

    private func processIDs(_ list: [ActivityListItem]) -> [String] {
        list.compactMap { if case .process(let row) = $0 { row.name } else { nil } }
    }

    private func groups(_ list: [ActivityListItem]) -> [ActivityGroupRow] {
        list.compactMap { if case .group(let row) = $0 { row } else { nil } }
    }

    private func process(_ name: String, _ list: [ActivityListItem]) -> ActivityProcessRow? {
        for item in list { if case .process(let row) = item, row.name == name { return row } }
        return nil
    }

    func testByCheckoutThenTabThenPaneThenTheTree() throws {
        let context = grouped()
        let snapshot = try full(ActivitySampler(kernel: kernel), context)
        let list = ActivityRows.content(of: snapshot, options(context)).list
        let headers = groups(list)
        XCTAssertEqual(
            headers.map(\.id).prefix(5),
            ["group:checkout:\(checkout)", "group:tab:\(tab.uuidString)", "group:tab:\(tabB.uuidString)", "group:pane:pane-b", "group:pane:pane-c"],
            "the checkout, its tabs in the strip's order, a split tab's panes")
        XCTAssertEqual(headers.first?.title, "acme · feature-x")
        XCTAssertEqual(headers.first?.detail, "✳ Claude  2 tabs")
        let fixed = headers.filter { $0.kind == .fixed }.map(\.id)
        XCTAssertEqual(fixed, ["group:fixed:overterm", "group:fixed:elsewhere", "group:fixed:system"], "then the fixed groups, in order")
        let zsh = try XCTUnwrap(process("zsh", list))
        let server = try XCTUnwrap(process("acme-server", list))
        XCTAssertEqual(server.depth, zsh.depth + 1, "a child under its parent")
        XCTAssertEqual(zsh.depth, 3, "under its login, in its tab, in its checkout")
        let agentTab = try XCTUnwrap(headers.first { $0.id == "group:tab:\(tabB.uuidString)" })
        XCTAssertEqual(agentTab.agent, .claude)
        XCTAssertEqual(agentTab.detail, "Claude Code  1 MCP")
        XCTAssertTrue(process("git", list) != nil, "Overterm's helper under Overterm")
        XCTAssertNil(process("globex-agent", list), "Yours elsewhere is folded by default")
        XCTAssertNil(process("fakeservd", list), "and other users'")
        let label = try XCTUnwrap(process("acme-server", list)?.accessibilityLabel)
        XCTAssertEqual(label, "acme-server, pid 1102, in “web”, acme-shop")
        XCTAssertTrue(headers.first?.accessibilityLabel.hasPrefix("acme · feature-x, ✳ Claude  2 tabs, ") == true)
    }

    func testFoldsHideAndUnfoldShows() throws {
        let context = grouped()
        let snapshot = try full(ActivitySampler(kernel: kernel), context)
        let tabID = "group:tab:\(tab.uuidString)"
        let folded = ActivityRows.content(of: snapshot, options(context) { $0.folds = [tabID: true, "group:fixed:elsewhere": false] }).list
        XCTAssertNil(process("acme-server", folded))
        XCTAssertEqual(groups(folded).first { $0.id == tabID }?.folded, true)
        XCTAssertNotNil(process("globex-agent", folded), "unfolded on demand")
        let zsh = try XCTUnwrap(snapshot.table.process(pid: 1101)).identity.id
        let tree = ActivityRows.content(of: snapshot, options(context) { $0.folds = [zsh: true] }).list
        XCTAssertNil(process("acme-server", tree), "a process folded hides its children")
        XCTAssertEqual(process("zsh", tree.filter { $0.id == zsh })?.folded, true)
    }

    func testSiblingsSortWithinTheTreeAndFlatSortsWithinTheGroup() throws {
        let context = grouped()
        add(1103, parent: 1101, name: "acme-worker")
        let sampler = ActivitySampler(kernel: kernel)
        _ = try full(sampler, context)
        burn(1103, 600_000_000)
        burn(1102, 100_000_000)
        kernel.advance(1_000_000_000)
        let snapshot = try full(sampler, context)
        let list = ActivityRows.content(of: snapshot, options(context)).list
        let names = processIDs(list)
        let worker = try XCTUnwrap(names.firstIndex(of: "acme-worker"))
        let server = try XCTUnwrap(names.firstIndex(of: "acme-server"))
        XCTAssertLessThan(worker, server, "the busier sibling first")
        let flat = ActivityRows.content(of: snapshot, options(context) { $0.tree = false }).list
        let tabRows = flat.compactMap { item -> ActivityProcessRow? in
            if case .process(let row) = item, row.tab == tab { return row }
            return nil
        }
        XCTAssertEqual(Set(tabRows.map(\.depth)).count, 1, "flat: one depth in the group")
        XCTAssertEqual(tabRows.first?.name, "acme-worker", "sorted by CPU")
    }

    func testEveryGroupingListsEachProcessOnce() throws {
        let context = grouped()
        let snapshot = try full(ActivitySampler(kernel: kernel), context)
        for grouping in ActivityGrouping.allCases {
            let unfolded = Dictionary(uniqueKeysWithValues: ActivityRows.Fixed.allCases.map { ($0.id, false) })
            let list = ActivityRows.content(
                of: snapshot,
                options(context) {
                    $0.grouping = grouping
                    $0.folds = unfolded.merging(["group:user:\(ActivityRows.userName(0))": false]) { $1 }
                }
            ).list
            let names = list.compactMap { if case .process(let row) = $0 { row.id } else { nil } }
            XCTAssertEqual(names.count, Set(names).count, "\(grouping): each once")
            XCTAssertFalse(list.isEmpty, "\(grouping)")
        }
        let byAgent = ActivityRows.content(of: snapshot, options(context) { $0.grouping = .agent }).list
        let agent = try XCTUnwrap(groups(byAgent).first)
        XCTAssertEqual(agent.title, "Claude · “agent” · acme-shop")
        XCTAssertEqual(agent.detail, "1 MCP")
        XCTAssertEqual(processIDs(byAgent).prefix(2), ["claude", "node"], "the agent and its subtree under it")
        XCTAssertTrue(groups(byAgent).contains { $0.title == "No agent" })
        let byApp = ActivityRows.content(of: snapshot, options(context) { $0.grouping = .app }).list
        XCTAssertTrue(groups(byApp).contains { $0.title == "zsh ×2" || $0.title == "zsh ×3" }, "command-line processes by executable")
        XCTAssertTrue(groups(byApp).contains { $0.title == "Overterm" })
        let none = ActivityRows.content(of: snapshot, options(context) { $0.grouping = ActivityGrouping.none }).list
        XCTAssertTrue(groups(none).isEmpty, "no headers")
        XCTAssertEqual(process("launchd", none)?.depth, 0, "launchd at the top")
        XCTAssertEqual(ActivityGrouping.none.next, .checkout, "G comes round")
    }

    func testTheScopeLadder() throws {
        let context = grouped()
        let snapshot = try full(ActivitySampler(kernel: kernel), context)
        func names(_ scope: ActivityScope) -> Set<String> {
            Set(ActivityRows.content(of: snapshot, options(context) { $0.scope = scope }).processes.map(\.name))
        }
        XCTAssertEqual(names(.tab(tab)), ["login", "zsh", "acme-server"])
        XCTAssertEqual(names(.checkout(checkout)), ["login", "zsh", "acme-server", "claude", "node"])
        XCTAssertTrue(names(.allTabs).isSuperset(of: ["Overterm", "git", "claude"]))
        XCTAssertFalse(names(.allTabs).contains("globex-agent"), "not a tab's")
        XCTAssertTrue(names(.mac).contains("globex-agent"))
        let ports = ActivityRows.content(of: snapshot, options(context) { $0.scope = .tab(tabB) }).ports
        XCTAssertTrue(ports.isEmpty, "the other tab's listener isn't this one's")
        XCTAssertEqual(ActivityScope.mac.narrower(tab: tab, checkout: checkout), .allTabs)
        XCTAssertEqual(ActivityScope.allTabs.narrower(tab: tab, checkout: checkout), .checkout(checkout))
        XCTAssertEqual(ActivityScope.checkout(checkout).narrower(tab: tab, checkout: checkout), .tab(tab))
        XCTAssertNil(ActivityScope.tab(tab).narrower(tab: tab, checkout: checkout))
        XCTAssertEqual(ActivityScope.tab(tab).wider(checkout: checkout), .checkout(checkout))
        XCTAssertEqual(ActivityScope.tab(tab).wider(checkout: nil), .allTabs)
        XCTAssertEqual(ActivityScope.allTabs.wider(checkout: nil), .mac)
        // The checkout's stack is the checkout's scope's and wider's, never
        // one tab's (6.5).
        let stack = [ActivityContainer(id: "c1", name: "acme-db-1", project: "acme-shop", folder: checkout, cpu: 40, memory: 512 << 20)]
        for scope in [ActivityScope.checkout(checkout), .allTabs, .mac] {
            let list = ActivityRows.content(
                of: snapshot,
                options(context) {
                    $0.scope = scope
                    $0.containers = stack
                }
            ).list
            XCTAssertTrue(groups(list).contains { $0.kind == .container }, "\(scope)")
        }
        for grouping in [ActivityGrouping.checkout, .tab] {
            let list = ActivityRows.content(
                of: snapshot,
                options(context) {
                    $0.scope = .tab(tab)
                    $0.grouping = grouping
                    $0.containers = stack
                }
            ).list
            XCTAssertFalse(groups(list).contains { $0.kind == .container || $0.kind == .docker }, "\(grouping): not the tab's")
            XCTAssertNil(groups(list).first?.cpu, "nor counted in its header: its processes have no rate yet")
        }
    }

    /// Grouped by tab, what left a tab's terminal is under the tab's header:
    /// folding the tab folds it too.
    func testWhatLeftATabFoldsWithIt() throws {
        let context = grouped()
        var left = FakeActivityKernel.Process(record: FakeActivityKernel.record(pid: 1500, start: 1_500_000, parent: 1, name: "acme-worker"))
        left.name = "acme-worker"
        left.path = "/opt/acme/bin/acme-worker"
        left.codeSigning = ActivityCodeSigning(flags: ActivityCodeSigning.valid)
        left.usage = FakeActivityKernel.usage(footprint: 8 << 20, threads: 1)
        left.arguments = FakeActivityKernel.arguments(executable: "/opt/acme/bin/acme-worker", ["acme-worker"], environment: ["OVERTERM_TAB_ID=pane-a"])
        kernel.add(left)
        let snapshot = try full(ActivitySampler(kernel: kernel), context)
        let tabID = "group:tab:\(tab.uuidString)"
        let open = ActivityRows.content(of: snapshot, options(context) { $0.grouping = .tab }).list
        let headers = groups(open)
        let leftHeader = try XCTUnwrap(headers.first { $0.kind == .left })
        let tabHeader = try XCTUnwrap(headers.first { $0.id == tabID })
        XCTAssertEqual(leftHeader.depth, tabHeader.depth + 1, "under the tab")
        XCTAssertNotNil(process("acme-worker", open))
        let folded = ActivityRows.content(
            of: snapshot,
            options(context) {
                $0.grouping = .tab
                $0.folds = [tabID: true]
            }
        ).list
        XCTAssertFalse(groups(folded).contains { $0.kind == .left }, "folded with its tab")
        XCTAssertNil(process("acme-worker", folded))
    }

    func testContainersUnderTheirCheckout() throws {
        let context = grouped()
        let snapshot = try full(ActivitySampler(kernel: kernel), context)
        let list = ActivityRows.content(
            of: snapshot,
            options(context) {
                $0.containers = [
                    ActivityContainer(id: "c1", name: "acme-db-1", project: "acme-shop", folder: checkout + "/deploy", cpu: 12, memory: 64 << 20),
                    ActivityContainer(id: "c2", name: "globex-cache", project: "globex", folder: "/Users/fake/src/globex", cpu: 3, memory: 1 << 20),
                ]
            }
        ).list
        let headers = groups(list)
        let docker = try XCTUnwrap(headers.first { $0.kind == .docker })
        XCTAssertEqual(docker.title, "In Docker’s VM: acme-db-1")
        XCTAssertEqual(docker.detail, "compose project acme-shop")
        XCTAssertEqual(headers.first { $0.kind == .container }?.title, "acme-db-1")
        XCTAssertFalse(headers.contains { $0.title.contains("globex-cache") }, "outside every known checkout: not listed under one")
        XCTAssertEqual(headers.first?.cpu ?? 0, 12, accuracy: 0.01, "the checkout's totals count its stack")
        XCTAssertEqual(headers.first?.memory, (64 << 20) + 6 * (8 << 20), "its processes' memory and the container's")
    }

    func testAGroupPastItsLimitSaysHowManyMore() throws {
        let context = mac()
        for pid in pid_t(5000)..<pid_t(10_000) { add(pid, parent: 1, name: "fake-\(pid % 7)") }
        let snapshot = try full(ActivitySampler(kernel: kernel), context)
        let content = ActivityRows.content(of: snapshot, plain(context) { $0.folds = ["group:fixed:elsewhere": false] })
        let more = try XCTUnwrap(groups(content.list).first { $0.kind == .more })
        XCTAssertEqual(more.id, "more:group:fixed:elsewhere")
        XCTAssertEqual(more.title, "+\(5_001 - 500) more", "5,000 and globex-agent, 500 shown")
        XCTAssertLessThan(content.list.count, 600)
        let all = ActivityRows.content(
            of: snapshot,
            plain(context) {
                $0.folds = ["group:fixed:elsewhere": false, "more:group:fixed:elsewhere": false]
            })
        XCTAssertNil(groups(all.list).first { $0.kind == .more }, "unfolded: every one")
    }

    /// The containers' want: Docker's model while the page shows — its
    /// published ports are Listening's owners —, their usage too while
    /// Processes shows; given back when the window closes over it.
    func testTheContainersWantIsGivenBackAtTheWindowsClose() {
        let monitor = ActivityMonitor(sampler: ActivitySampler(kernel: kernel))
        let page = ActivityPageModel(monitor: monitor)
        var wants: [ActivityContainerWant] = []
        page.wantContainers = { wants.append($0) }
        page.visible = true
        XCTAssertEqual(wants, [.usage])
        page.section = .listening
        XCTAssertEqual(wants, [.usage, .listed], "Listening: the model, not the usage")
        page.section = .processes
        page.close()
        XCTAssertEqual(wants, [.usage, .listed, .usage, .none], "the window's close gives it back")
        monitor.stop()
    }

    func testThePagesKeysGroupTreeAndScope() {
        let page = ActivityPageModel(monitor: ActivityMonitor(sampler: ActivitySampler(kernel: kernel)))
        page.currentTab = { [tab] in tab }
        XCTAssertTrue(page.press("G"))
        XCTAssertEqual(page.grouping, .tab)
        XCTAssertTrue(page.press("t"))
        XCTAssertFalse(page.tree)
        XCTAssertTrue(page.press("["))
        XCTAssertEqual(page.scope(.processes), .allTabs)
        XCTAssertEqual(page.scopeTitle(.processes), "All tabs")
        XCTAssertTrue(page.press("["))
        XCTAssertEqual(page.scope(.processes), .tab(tab), "no checkout known: the tab")
        XCTAssertTrue(page.press("]"))
        XCTAssertEqual(page.scope(.processes), .allTabs)
        XCTAssertTrue(page.press("]"))
        XCTAssertEqual(page.scope(.processes), .mac)
        XCTAssertNil(page.scopeTitle(.processes))
        XCTAssertEqual(page.scope(.listening), .mac, "a section each")
    }

    /// Waits for `condition`, at most `seconds`, never sampling one moment.
    private func eventually(_ seconds: Double = 10, _ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }
}
