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
        didSet {
            guard section != oldValue else { return }
            selection = []
            updateContainers()
            if scope(section) != scope(oldValue) { rebuild() }
        }
    }
    /// How Processes is grouped (`G`), and whether as a tree (`t`).
    @Published var grouping: ActivityGrouping = .checkout {
        didSet { if grouping != oldValue { rebuild() } }
    }
    @Published var tree = true {
        didSet { if tree != oldValue { rebuild() } }
    }
    /// The scope ladder's rung (6.5, `[` and `]`), a section each.
    @Published private(set) var scopes: [Section: ActivityScope] = [:]
    /// Folds by row id, kept in memory for the app's life (6.5).
    @Published private(set) var folds: [String: Bool] = [:]
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
    /// What every window says of its tabs — checkout, branch, order — and
    /// the checkouts it knows; with it the titles above are unused.
    var tabFacts: @MainActor () -> (tabs: [UUID: ActivityTabFacts], checkouts: [String])? = { nil }
    /// The window's selected tab: where `[` narrows to with no row selected.
    var currentTab: @MainActor () -> UUID? = { nil }
    /// The running containers with their usage, and the want of their
    /// usage while Processes shows (6.5): set by the window.
    var containers: @MainActor () -> [ActivityContainer] = { [] }
    var wantContainers: @MainActor (Bool) -> Void = { _ in }
    /// What the census's context leaves to the page (6.5, rules 2 and 6):
    /// the forwards, the containers' published ports, the bridge's port.
    var contextFacts: @MainActor (inout ActivityContext) -> Void = { _ in }
    /// Running apps' bundles by pid: a deleted executable's place.
    var runningApps: @MainActor () -> [pid_t: String] = { [:] }
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
    /// The tabs' facts the last rows were made with.
    private var lastTabs: [UUID: ActivityTabFacts] = [:]
    /// A row shown by a link: its groups unfolded for it.
    private var revealed: String?
    /// Whether it holds the containers' usage now.
    private(set) var wantsContainers = false

    init(monitor: ActivityMonitor = .shared) {
        self.monitor = monitor
        for section in Section.allCases {
            if let saved = AppEnvironment.defaults.string(forKey: Self.scopeKey(section)), saved == "allTabs" { scopes[section] = .allTabs }
        }
    }

    private static func scopeKey(_ section: Section) -> String { "activity.page.scope.\(section.rawValue)" }

    /// The scope of `section`: the Mac by default (⌥⌘A).
    func scope(_ section: Section) -> ActivityScope { scopes[section] ?? .mac }

    /// Sets `section`'s scope; remembered across launches only as All
    /// tabs or the Mac — a tab or a checkout is this launch's.
    func setScope(_ scope: ActivityScope, for section: Section? = nil) {
        let section = section ?? self.section
        guard self.scope(section) != scope else { return }
        scopes[section] = scope
        let saved: String? = scope == .allTabs ? "allTabs" : nil
        AppEnvironment.defaults.set(saved, forKey: Self.scopeKey(section))
        rebuild()
    }

    /// The chip's words: "Tab: web", "Checkout: acme-shop", "All tabs";
    /// nil on the Mac.
    func scopeTitle(_ section: Section) -> String? {
        switch scope(section) {
        case .mac: return nil
        case .allTabs: return "All tabs"
        case .checkout(let path): return "Checkout: \(ActivityRows.folderName(path))"
        case .tab(let id): return "Tab: \(lastTabs[id].map { ActivityText.title($0.title) } ?? "a tab")"
        }
    }

    /// `[`: narrower, onto the selected row's tab or the window's.
    func narrowScope() {
        let row = content.processes.first { selection.contains($0.id) }
        let tab = row?.owner.flatMap(ActivityRows.paneTab) ?? row?.tab ?? currentTab()
        guard let narrower = scope(section).narrower(tab: tab, checkout: tab.flatMap { lastTabs[$0]?.checkout }) else { return }
        setScope(narrower)
    }

    /// `]`: wider.
    func widenScope() {
        var checkout: String?
        if case .tab(let id) = scope(section) { checkout = lastTabs[id]?.checkout }
        setScope(scope(section).wider(checkout: checkout))
    }

    /// A row's fold flipped: a group, a process with children, "+N more".
    func toggleFold(_ id: String, folded now: Bool) {
        folds[id] = !now
        revealed = nil
        rebuild()
    }

    /// The containers' usage wanted while Processes shows.
    private func updateContainers() {
        let wanted = wanting && section == .processes
        guard wanted != wantsContainers else { return }
        wantsContainers = wanted
        wantContainers(wanted)
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
        updateContainers()
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
        var options = ActivityRows.Options(
            everyone: Settings.shared.activityEveryone, isolated: isolated, processSort: processSort, portSort: portSort)
        if let facts = tabFacts() {
            options.tabs = facts.tabs
            options.checkouts = facts.checkouts
            lastTabs = facts.tabs
        } else {
            options.titles = tabTitles()
            lastTabs = options.titles.reduce(into: [:]) { $0[$1.key] = ActivityTabFacts(id: $1.key, title: $1.value) }
        }
        options.context = monitor.context
        contextFacts(&options.context)
        options.runningApps = runningApps()
        options.grouping = grouping
        options.tree = tree
        options.scope = scope(section)
        options.folds = folds
        options.reveal = revealed
        options.containers = wantsContainers ? containers() : []
        Task { [weak self] in
            let content = await Self.make(snapshot, options)
            guard let self, self.generation == generation else { return }
            self.content = content
            self.hasRead = true
            self.builds += 1
            let shown = Set(content.processes.map(\.id)).union(content.list.map(\.id)).union(content.ports.map(\.id))
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
        if let section = Section.allCases.first(where: { $0.key == characters }) {
            self.section = section
            return true
        }
        switch characters {
        case "G" where section == .processes: grouping = grouping.next
        case "t" where section == .processes: tree.toggle()
        case "[": narrowScope()
        case "]": widenScope()
        default: return false
        }
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
        revealed = id
        rebuild()
        selection = [id]
        focusList += 1
    }
}
