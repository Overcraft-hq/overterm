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

    func testTheDigitsPickTheSections() {
        let page = ActivityPageModel(monitor: ActivityMonitor(sampler: ActivitySampler(kernel: kernel)))
        XCTAssertTrue(page.press("2"))
        XCTAssertEqual(page.section, .listening)
        XCTAssertTrue(page.press("1"))
        XCTAssertEqual(page.section, .processes)
        XCTAssertFalse(page.press("x"), "not the page's: the list's")
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
