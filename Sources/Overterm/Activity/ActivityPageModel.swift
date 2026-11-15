import Combine
import Foundation

/// The Activity page (⌥⌘A; docs/design/activity/analysis.md, 6.4): its
/// sections, its rows from the census's full snapshots, and its want. It
/// wants the full level only while it is the page on screen in a window
/// that shows (7.9): hidden, it reads nothing and builds no rows.
@MainActor
final class ActivityPageModel: ObservableObject {
    enum Section: String, CaseIterable, Identifiable {
        case processes, listening

        var id: String { rawValue }

        var title: String {
            switch self {
            case .processes: "Processes"
            case .listening: "Listening"
            }
        }

        var symbol: String {
            switch self {
            case .processes: "list.bullet.indent"
            case .listening: "dot.radiowaves.left.and.right"
            }
        }

        /// Its digit on the page (6.3).
        var key: String {
            switch self {
            case .processes: "1"
            case .listening: "2"
            }
        }
    }

    @Published var section: Section = .processes {
        didSet { if section != oldValue { selection = [] } }
    }
    @Published var selection: Set<String> = []
    @Published var processSort: ResourceSort? = ResourceSort(column: "cpu", ascending: false) {
        didSet { if processSort != oldValue { rebuild() } }
    }
    @Published var portSort: ResourceSort? = ResourceSort(column: "port") {
        didSet { if portSort != oldValue { rebuild() } }
    }
    @Published private(set) var content = ActivityPageContent()
    /// A full snapshot has been made into rows since the page showed.
    @Published private(set) var hasRead = false
    /// The interval the rows are read at, as the header says it.
    @Published private(set) var interval: Duration = .seconds(2)
    /// Asks the list for the keyboard (the window gives it).
    @Published var focusList = 0

    /// It is the page over the body.
    var visible = false {
        didSet { if visible != oldValue { updateWant() } }
    }
    /// Its window is on screen (an isolated run's counts as shown).
    var windowVisible = true {
        didSet { if windowVisible != oldValue { updateWant() } }
    }
    /// Every window's tabs' titles, by id: what the Where column says.
    var tabTitles: @MainActor () -> [UUID: String] = { [:] }
    /// A test run lists only its own tabs' processes (6.4, 9.9).
    var isolated = AppEnvironment.isIsolated

    let monitor: ActivityMonitor
    /// Whether it holds the monitor's full level now.
    private(set) var wanting = false
    /// Rows made, a scenario's count.
    private(set) var builds = 0
    private var latest: ActivitySnapshot?
    private var generation = 0
    private var snapshots: AnyCancellable?

    init(monitor: ActivityMonitor = .shared) {
        self.monitor = monitor
    }

    /// Its want, as it shows and Activity is on: the full level at the
    /// census's interval; given back otherwise.
    func updateWant() {
        let wanted = visible && windowVisible && Settings.shared.activityEnabled
        if wanted {
            interval = monitor.interval
            monitor.want(self, .full)
            if !wanting { follow() }
            wanting = true
        } else if wanting {
            monitor.unwant(self)
            wanting = false
            snapshots = nil
            forget()
        }
    }

    /// Hidden: the rows go with the want, so the page shown again says
    /// "Reading…" until a fresh tick's rows land — never minutes-old
    /// numbers as now. The section and the selection stay.
    private func forget() {
        generation += 1
        latest = nil
        content = ActivityPageContent()
        hasRead = false
    }

    /// Takes each full snapshot that lands while it wants them, and one
    /// already there that is no older than two intervals: an older one
    /// would show minutes-old numbers as now.
    private func follow() {
        if let last = monitor.lastFull, monitor.age(of: last) <= 2 * ActivityMonitor.nanoseconds(monitor.interval) { take(last) }
        // @Published emits before it changes: the emitted value.
        snapshots = monitor.$snapshot.compactMap { $0 }.filter { $0.demand.full }
            .sink { [weak self] snapshot in self?.take(snapshot) }
    }

    func take(_ snapshot: ActivitySnapshot) {
        guard snapshot.tick > latest?.tick ?? 0 else { return }
        latest = snapshot
        rebuild()
    }

    /// The rows of the latest snapshot, made off the main thread (7.7); a
    /// later rebuild wins over one still on its way.
    private func rebuild() {
        guard wanting, let snapshot = latest else { return }
        generation += 1
        let generation = self.generation
        let options = ActivityRows.Options(
            titles: tabTitles(), everyone: Settings.shared.activityEveryone, isolated: isolated, processSort: processSort, portSort: portSort)
        Task { [weak self] in
            let content = await Self.make(snapshot, options)
            guard let self, self.generation == generation else { return }
            self.content = content
            self.hasRead = true
            self.builds += 1
            let shown = Set(content.processes.map(\.id)).union(content.ports.map(\.id))
            if !self.selection.isSubset(of: shown) { self.selection = self.selection.intersection(shown) }
        }
    }

    private nonisolated static func make(_ snapshot: ActivitySnapshot, _ options: ActivityRows.Options) async -> ActivityPageContent {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { continuation.resume(returning: ActivityRows.content(of: snapshot, options)) }
        }
    }

    /// A setting changed: the want again (on, off, the interval), the rows
    /// again (everyone's) — only while it shows: hidden, nothing is made.
    func settingsChanged() {
        let was = wanting
        if wanting {
            monitor.unwant(self)
            wanting = false
            snapshots = nil
        }
        updateWant()
        if wanting { rebuild() } else if was { forget() }
    }

    /// The page closed: what it shows goes with it.
    func close() {
        visible = false
        selection = []
        forget()
    }

    /// A key while the list has the keyboard: the sections' digits (6.3).
    func press(_ characters: String) -> Bool {
        guard let section = Section.allCases.first(where: { $0.key == characters }) else { return false }
        self.section = section
        return true
    }

    /// ⌘C: the selected rows, a line each — names, pids, ports only.
    var selectedLines: [String] {
        switch section {
        case .processes:
            content.processes.filter { selection.contains($0.id) }.map { "\($0.name)\t\($0.identity.pid)" }
        case .listening:
            content.ports.filter { selection.contains($0.id) }.map { "\($0.port)/\($0.proto)\t\($0.process)\t\($0.holder.map { String($0.pid) } ?? "")" }
        }
    }

    /// The process or port shown on the page: its section, selected.
    func reveal(_ id: String, in section: Section) {
        self.section = section
        selection = [id]
        focusList += 1
    }
}
