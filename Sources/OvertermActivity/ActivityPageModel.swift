import AppKit
import Combine
import Foundation
import os

/// What the Activity page opens in a new tab (6.10: Terminal in Its
/// Folder, Sample, Open Files, the service's stop, the read route): a
/// folder, and a command typed into its shell — run, or left for the person
/// to run (Return theirs).
package struct ActivityTerminalRequest: Equatable, Sendable {
    package var directory: String
    package var command: String?
    package var run = true

    package init(directory: String, command: String? = nil, run: Bool = true) {
        self.directory = directory
        self.command = command
        self.run = run
    }
}

/// Where a link shows the page (6.12): Tab Info's header, the tab's menu
/// and ⌘K a tab; Tab Info's rows and the overview's card a process; a pane
/// pill, Tab Info's Listening and Docker's conflict box a port.
package enum ActivityLink: Equatable, Sendable {
    /// Processes, scoped to the tab.
    case tab(UUID)
    /// Processes, that process selected and followed — in its tab's scope
    /// when one is given.
    case process(ActivityProcessID, tab: UUID?)
    /// Listening, the port's row selected and followed — its holder's when
    /// `pid` is given — in its tab's checkout's scope (6.5: where the
    /// checkout's containers are listed too), else the tab's, else the
    /// Mac's; widened to the Mac's when a tick doesn't list it there.
    case port(Int, proto: String, pid: pid_t?, tab: UUID?)
}

/// A port a link asked for (6.12), selected once a tick's rows list it.
/// `after`: the tick the link came at — only a later tick's rows say it
/// isn't listed. `scope`: the rung it is looked for at.
package struct ActivityPendingPort: Equatable, Sendable {
    package var port: Int
    package var proto: String
    package var pid: pid_t?
    package var after: Int
    package var scope: ActivityScope
    /// Free a Port… (6.3): its Free asked once the row is listed.
    package var free = false
}

/// What the page asks of the window (6.3): the verbs that don't signal.
package struct ActivityPageActions {
    /// Its tab brought forward in whichever window holds it, and the pane
    /// whose tag is given focused.
    package var goTo: @MainActor (UUID, String?) -> Void = { _, _ in }
    /// A listener's URL in its tab's browser column, in the window that
    /// holds the tab, where Settings ▸ Browser says; true: the default
    /// browser (⌥o).
    package var open: @MainActor (URL, UUID?, Bool) -> Void = { _, _, _ in }
    /// Tab Info (⌃⌘I) for a tab.
    package var tabInfo: @MainActor (UUID) -> Void = { _ in }
    /// A tab's checkout in Overgit: the tab brought forward, the sidebar
    /// on its git panel.
    package var overgit: @MainActor (UUID) -> Void = { _ in }
    /// An executable shown in Finder.
    package var reveal: @MainActor (String) -> Void = { path in NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
    /// `sample <pid> 5` in a new tab (`s`): it only reads.
    package var sample: @MainActor (pid_t) -> Void = { _ in }
    /// Free :N (`f`) through the row's owner's own verb, asked first
    /// (`ActivityPortHolder`).
    package var free: @MainActor (ActivityPortRow) -> Void = { _ in }
    /// A new tab: Terminal in Its Folder (`e`), Open Files in a Tab — it
    /// only reads.
    package var terminal: @MainActor (ActivityTerminalRequest) -> Void = { _ in }
    /// A verb that changes a process (6.10): read again, asked, sent
    /// through `ProcessSignals` or typed into its pane.
    package var act: @MainActor (ActivityVerb, ActivityProcessID) -> Void = { _, _ in }
    /// Send a Signal (`x`): which one, asked first.
    package var chooseSignal: @MainActor (ActivityProcessID) -> Void = { _ in }
    /// `k`: what its class asks (`ActivityPageModel.stopVerb`), decided on
    /// the process read again as its sheet opens.
    package var stop: @MainActor (ActivityProcessID) -> Void = { _ in }
    /// Lower Priority ▸ +5, +10, 20: asked, saying it can't be undone.
    package var lower: @MainActor (ActivityProcessID, ActivityNiceStep) -> Void = { _, _ in }
    /// `n`: which step, then its question.
    package var chooseLower: @MainActor (ActivityProcessID) -> Void = { _ in }
    /// The header's Resume All: every process Activity stopped, asked when
    /// more than one.
    package var resumeAll: @MainActor () -> Void = {}
    /// Ask an Agent About It (`a`, ⌘L): the Ask Agent sheet with its brief.
    package var ask: @MainActor (ActivityBrief, UUID?) -> Void = { _, _ in }
    /// Keep (6.9): never in a bulk Stop, never Left Behind again.
    package var keep: @MainActor (ActivityProcessID) -> Void = { _ in }
    /// Stop All Certain in This Checkout… (6.9): one sheet listing each.
    package var stopAll: @MainActor (_ rows: [ActivityProcessRow], _ group: String) -> Void = { _, _ in }
    /// A key whose verb can't be done now: the system's beep, beside the
    /// reason the page says (`keySaid`).
    package var beep: @MainActor () -> Void = {}

    package init(
        goTo: @escaping @MainActor (UUID, String?) -> Void = { _, _ in }, open: @escaping @MainActor (URL, UUID?, Bool) -> Void = { _, _, _ in },
        tabInfo: @escaping @MainActor (UUID) -> Void = { _ in }, overgit: @escaping @MainActor (UUID) -> Void = { _ in },
        reveal: @escaping @MainActor (String) -> Void = { path in NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) },
        sample: @escaping @MainActor (pid_t) -> Void = { _ in }, free: @escaping @MainActor (ActivityPortRow) -> Void = { _ in },
        terminal: @escaping @MainActor (ActivityTerminalRequest) -> Void = { _ in }, act: @escaping @MainActor (ActivityVerb, ActivityProcessID) -> Void = { _, _ in },
        chooseSignal: @escaping @MainActor (ActivityProcessID) -> Void = { _ in }, stop: @escaping @MainActor (ActivityProcessID) -> Void = { _ in },
        lower: @escaping @MainActor (ActivityProcessID, ActivityNiceStep) -> Void = { _, _ in }, chooseLower: @escaping @MainActor (ActivityProcessID) -> Void = { _ in },
        resumeAll: @escaping @MainActor () -> Void = {}, ask: @escaping @MainActor (ActivityBrief, UUID?) -> Void = { _, _ in }, keep: @escaping @MainActor (ActivityProcessID) -> Void = { _ in },
        stopAll: @escaping @MainActor (_ rows: [ActivityProcessRow], _ group: String) -> Void = { _, _ in }
    ) {
        self.goTo = goTo
        self.open = open
        self.tabInfo = tabInfo
        self.overgit = overgit
        self.reveal = reveal
        self.sample = sample
        self.free = free
        self.terminal = terminal
        self.act = act
        self.chooseSignal = chooseSignal
        self.stop = stop
        self.lower = lower
        self.chooseLower = chooseLower
        self.resumeAll = resumeAll
        self.ask = ask
        self.keep = keep
        self.stopAll = stopAll
    }
}

/// The Activity page (⌥⌘A; docs/design/activity/analysis.md, 6.4): its
/// sections, its rows from the census's full snapshots, and its want. It
/// wants the full level only while it is the page on screen in a window
/// that shows (7.9): hidden, it reads nothing and builds no rows.
@MainActor
package final class ActivityPageModel: ObservableObject {
    package enum Section: String, CaseIterable, Identifiable {
        case processes, listening, leftBehind

        package var id: String { rawValue }

        package var title: String {
            switch self {
            case .processes: "Processes"
            case .listening: "Listening"
            case .leftBehind: "Left Behind"
            }
        }

        package var symbol: String {
            switch self {
            case .processes: "list.bullet.indent"
            case .listening: "dot.radiowaves.left.and.right"
            case .leftBehind: "arrow.uturn.backward.circle"
            }
        }

        /// Its digit on the page (6.3).
        package var key: String {
            switch self {
            case .processes: "1"
            case .listening: "2"
            case .leftBehind: "3"
            }
        }
    }

    /// What the list draws, published apart (7.7): `syncList` keeps it.
    package let list = ActivityListState()

    @Published package var section: Section = .processes {
        didSet {
            guard section != oldValue else { return }
            syncList()
            byHand()
            selection = []
            updateContainers()
            // Left Behind lists Processes' rows by its own filter (6.9).
            if scope(section) != scope(oldValue) || section == .leftBehind || oldValue == .leftBehind { rebuild(asked: true) }
        }
    }
    /// How Processes is grouped (`G`), and whether as a tree (`t`).
    /// Both remembered across launches (9.5), as the sorts and columns are.
    @Published package var grouping: ActivityGrouping = .checkout {
        didSet {
            guard grouping != oldValue else { return }
            AppEnvironment.defaults.set(grouping.rawValue, forKey: Self.groupingKey)
            syncList()
            rebuild(asked: true)
        }
    }
    @Published package var tree = true {
        didSet {
            guard tree != oldValue else { return }
            AppEnvironment.defaults.set(tree, forKey: Self.treeKey)
            rebuild(asked: true)
        }
    }
    /// Each section's filter field (6.6): not remembered, as Docker's isn't.
    @Published package private(set) var filters: [Section: String] = [:] {
        didSet { syncList() }
    }
    /// Asks the filter field for the keyboard (`/`).
    @Published package var focusFilter = 0
    /// The keys' sheet (`?`).
    @Published package var cheatSheet = false {
        didSet { if cheatSheet != oldValue { interacted(cheatSheet ? .menuOpened : .menuClosed, sheet: true) } }
    }
    /// The detail beside the list (Space).
    @Published package var showsDetail = true
    /// `F`: the selection kept in view as its row moves.
    @Published package var following = false {
        didSet { syncList() }
    }
    /// `Z`: values and order frozen; the census given back while nothing
    /// else wants it.
    @Published package var paused = false {
        didSet { if paused != oldValue { updateWant() } }
    }
    /// The order is held while the person works the list (6.7): said.
    @Published package private(set) var orderHeld = false
    /// `u`: yours only, or everyone's — `activity.everyone` until pressed.
    @Published package var everyone: Bool? {
        didSet {
            guard everyone != oldValue else { return }
            syncList()
            rebuild(asked: true)
        }
    }
    /// The selected process's detail (6.4).
    @Published package private(set) var detail: ActivityDetail? {
        didSet { if showsFiles, detail?.row.identity != oldValue?.row.identity { readFiles() } }
    }
    /// The detail's Files (6.4, `l`): shown, and what the read found — of
    /// the selection, read when it opens and when the selection changes
    /// while it shows; nil while reading.
    @Published package var showsFiles = false
    @Published package private(set) var openFiles: ProcessOpenFiles.Listing?
    private var filesGeneration = 0
    /// The selected process as its verbs see it (6.10), read off the main
    /// thread with every owner — with the rows, or for a selection made
    /// between two publishes; nil while it is read.
    @Published package private(set) var verbSubject: ActivityVerbSubject?
    /// What a Free or a Stop from the page said last (6.8, After the step;
    /// 6.10 step 10): ":3000 freeing…", then free or still held; "Stopping
    /// “x”…", then stopped, still running or came back as pid N.
    @Published package var freeing: String?
    /// What the page sent SIGTERM or SIGINT to, and when: Force Quit is
    /// offered without "Stop it first?" for two minutes after (D-11).
    package var stoppedAt: [ActivityProcessID: Date] = [:]
    /// The main actor's facts a verb's target is read with (running apps,
    /// what Activity and Suspend Tab stopped): set by the window.
    package var known: @MainActor () -> ActivityVerbSubject.Known = { ActivityVerbSubject.Known() }
    /// What Activity stopped and put in the background (6.10): the
    /// header's "2 stopped here — Resume All", the rows' chips.
    package var held = ActivityHeld.shared
    /// What a link said of a port it couldn't show (6.12): ":N isn't
    /// listed"; cleared by the next link, the person's hand, or a hide.
    @Published package private(set) var linkSaid: String?
    /// What a key said it couldn't do (6.3): the reason its verb is greyed
    /// with in the menu, beside a beep — one source for both words. Cleared
    /// by the next key, the person's hand, or a hide.
    @Published package private(set) var keySaid: String?
    /// The columns the person left: each section's, kept (6.5).
    @Published package private(set) var layout: ActivityColumns.Layout = ActivityColumns.load() {
        didSet { syncList() }
    }
    /// The scope ladder's rung (6.5, `[` and `]`), a section each.
    @Published package private(set) var scopes: [Section: ActivityScope] = [:]
    /// Folds by row id, kept in memory for the app's life (6.5).
    @Published package private(set) var folds: [String: Bool] = [:]
    @Published package var selection: Set<String> = [] {
        didSet {
            guard selection != oldValue else { return }
            syncList()
            byHand()
            updateDetail()
        }
    }
    @Published package var processSort: ResourceSort? = ResourceSort(column: "cpu", ascending: false) {
        didSet {
            guard processSort != oldValue else { return }
            Self.saveSort(processSort, forKey: Self.processSortKey)
            syncList()
            rebuild(asked: true)
        }
    }
    @Published package var portSort: ResourceSort? = ResourceSort(column: "port") {
        didSet {
            guard portSort != oldValue else { return }
            Self.saveSort(portSort, forKey: Self.portSortKey)
            syncList()
            rebuild(asked: true)
        }
    }
    /// Listening's connections (`c`, 6.8): the user's established TCP
    /// connections, paired by the 4-tuple.
    @Published package var connections = false {
        didSet { if connections != oldValue { rebuild(asked: true) } }
    }
    @Published package private(set) var content = ActivityPageContent() {
        didSet {
            syncList(rows: true)
            ActivityRelease.later(oldValue)
        }
    }
    /// A full snapshot has been made into rows since the page showed.
    @Published package private(set) var hasRead = false {
        didSet { if hasRead != oldValue { syncList() } }
    }
    /// The interval the rows are read at, as the header says it.
    @Published package private(set) var interval: Duration = .seconds(2)
    /// Asks the list for the keyboard (the window gives it).
    @Published package var focusList = 0

    /// It is the page over the body.
    package var visible = false {
        didSet { if visible != oldValue { updateWant() } }
    }
    /// Its window is on screen (an isolated run's counts as shown).
    package var windowVisible = true {
        didSet { if windowVisible != oldValue { updateWant() } }
    }
    /// Every window's tabs' titles, by id: what the Where column says.
    package var tabTitles: @MainActor () -> [UUID: String] = { [:] }
    /// What every window says of its tabs — checkout, branch, order — and
    /// the checkouts it knows; with it the titles above are unused.
    package var tabFacts: @MainActor () -> (tabs: [UUID: ActivityTabFacts], checkouts: [String])? = { nil }
    /// The window's selected tab: where `[` narrows to with no row selected.
    package var currentTab: @MainActor () -> UUID? = { nil }
    /// The running containers with their usage, and the want of Docker's
    /// model while either section shows — their published ports are
    /// Listening's owners (6.8) — and of their usage while Processes does
    /// (6.5): set by the window.
    package var containers: @MainActor () -> [ActivityContainer] = { [] }
    package var wantContainers: @MainActor (ActivityContainerWant) -> Void = { _ in }
    /// What the census's context leaves to the page (6.5, rules 2 and 6):
    /// the forwards, the containers' published ports, the bridge's port.
    package var contextFacts: @MainActor (inout ActivityContext) -> Void = { _ in }
    /// Running apps' bundles by pid: a deleted executable's place.
    package var runningApps: @MainActor () -> [pid_t: String] = { [:] }
    /// A test run lists only its own tabs' processes (6.4, 9.9).
    package var isolated = AppEnvironment.isIsolated
    /// The verbs that don't signal, as the window does them.
    package var actions = ActivityPageActions()
    /// VoiceOver's focus is in the list: the order holds (6.7).
    package var voiceOverInList: @MainActor () -> Bool = { false }
    /// How the person works the list now, and the rows a tick brought
    /// while the order held: shown once it lets go.
    private var hold = ActivityHold()
    package private(set) var waiting: ActivityPageContent? {
        didSet { ActivityRelease.later(oldValue) }
    }
    private var release: Task<Void, Never>?

    package let monitor: ActivityMonitor
    /// Whether it holds the monitor's full level now.
    package private(set) var wanting = false
    /// Rows made, a scenario's count.
    package private(set) var builds = 0
    package private(set) var latest: ActivitySnapshot?
    private var generation = 0
    /// The last rows' options: a selection's subject between two publishes
    /// is read with them; and the read on its way, a later one winning.
    private var lastOptions: ActivityRows.Options?
    /// Every user's listeners (D-25): the last read, and when the last one
    /// began.
    private var others: NettopListeners.Reading?
    private var othersBegan: Date?
    package let othersReader: NettopListeners.Reader
    private var subjectGeneration = 0
    /// The selection's history read on its own, before the rows carry it:
    /// a row just selected (6.11).
    private var readHistory: ActivityDetailHistory?
    private var historyReading: ActivityProcessID?
    private var historyGeneration = 0
    /// The main thread's part of the last detail made, ms: what
    /// `activityPerf` gates (10.4, main ≤ 4 ms a publish).
    package private(set) var detailCost: Double = 0
    private var snapshots: AnyCancellable?
    /// The tabs' facts the last rows were made with.
    private var lastTabs: [UUID: ActivityTabFacts] = [:]
    /// The tabs' facts the last rows were made with, for Left Behind's verbs.
    package var lastTabsForVerbs: [UUID: ActivityTabFacts] { lastTabs }
    /// A row shown by a link: its groups unfolded for it.
    private var revealed: String?
    /// What it holds of Docker's now.
    package private(set) var wantsContainers = ActivityContainerWant.none
    /// A port a link asked for, selected once a tick's rows list it;
    /// dropped by the person's hand, or once a tick at the Mac's scope
    /// doesn't list it.
    package private(set) var pendingPort: ActivityPendingPort?
    /// `kern.maxprocperuid` as the rows read it (6.4); a scenario's lower.
    package var processLimit = ActivityProcessLimit.perUser
    /// A link is setting the section and selection: not the person's hand.
    private var linking = false
    /// The selection read in depth (7.3's focus level): its folder for
    /// `e` and ⌥r — the user's own process, one at a time.
    package private(set) var focused: Set<ActivityProcessID> = []

    package init(monitor: ActivityMonitor = .shared, othersReader: NettopListeners.Reader = .shared) {
        self.monitor = monitor
        self.othersReader = othersReader
        for section in Section.allCases {
            if let saved = AppEnvironment.defaults.string(forKey: Self.scopeKey(section)), saved == "allTabs" { scopes[section] = .allTabs }
        }
        // The view as it was left (9.5): grouping, tree or flat, the sorts.
        // Set in init, so no observer runs and nothing is rebuilt yet.
        let defaults = AppEnvironment.defaults
        if let raw = defaults.string(forKey: Self.groupingKey), let saved = ActivityGrouping(rawValue: raw) { grouping = saved }
        if defaults.object(forKey: Self.treeKey) != nil { tree = defaults.bool(forKey: Self.treeKey) }
        if let saved = Self.savedSort(forKey: Self.processSortKey) { processSort = saved }
        if let saved = Self.savedSort(forKey: Self.portSortKey) { portSort = saved }
        syncList(rows: true)
    }

    private static func scopeKey(_ section: Section) -> String { "activity.page.scope.\(section.rawValue)" }
    package nonisolated static let groupingKey = "activity.page.grouping"
    package nonisolated static let treeKey = "activity.page.tree"
    package nonisolated static let processSortKey = "activity.page.sort.processes"
    package nonisolated static let portSortKey = "activity.page.sort.listening"

    /// The view's keys, forgotten: a test's page starts as a new one does.
    package nonisolated static func forgetView() {
        for key in [groupingKey, treeKey, processSortKey, portSortKey] { AppEnvironment.defaults.removeObject(forKey: key) }
    }

    /// A sort as it is kept: `column:asc` or `column:desc`, "" for none.
    /// Pure.
    package nonisolated static func sortText(_ sort: ResourceSort?) -> String {
        sort.map { "\($0.column):\($0.ascending ? "asc" : "desc")" } ?? ""
    }

    /// What `sortText` kept: nil when it isn't one (`.some(nil)` is "no
    /// sort"). Pure.
    package nonisolated static func sort(fromText text: String) -> ResourceSort?? {
        if text.isEmpty { return .some(nil) }
        guard let colon = text.lastIndex(of: ":") else { return nil }
        let column = String(text[..<colon])
        let order = text[text.index(after: colon)...]
        guard !column.isEmpty, order == "asc" || order == "desc" else { return nil }
        return .some(ResourceSort(column: column, ascending: order == "asc"))
    }

    private static func saveSort(_ sort: ResourceSort?, forKey key: String) {
        AppEnvironment.defaults.set(sortText(sort), forKey: key)
    }

    private static func savedSort(forKey key: String) -> ResourceSort?? {
        AppEnvironment.defaults.string(forKey: key).flatMap { sort(fromText: $0) }
    }

    /// The scope of `section`: the Mac by default (⌥⌘A).
    package func scope(_ section: Section) -> ActivityScope { scopes[section] ?? .mac }

    /// Sets `section`'s scope; remembered across launches only as All
    /// tabs or the Mac — a tab or a checkout is this launch's.
    package func setScope(_ scope: ActivityScope, for section: Section? = nil) {
        let section = section ?? self.section
        guard self.scope(section) != scope else { return }
        scopes[section] = scope
        let saved: String? = scope == .allTabs ? "allTabs" : nil
        AppEnvironment.defaults.set(saved, forKey: Self.scopeKey(section))
        rebuild(asked: true)
    }

    /// The chip's words: "Tab: web", "Checkout: acme-shop", "All tabs";
    /// nil on the Mac.
    package func scopeTitle(_ section: Section) -> String? {
        switch scope(section) {
        case .mac: return nil
        case .allTabs: return "All tabs"
        case .checkout(let path): return "Checkout: \(ActivityRows.folderName(path))"
        case .tab(let id): return "Tab: \(lastTabs[id].map { ActivityText.title($0.title) } ?? "a tab")"
        }
    }

    /// `[`: narrower, onto the selected row's tab or the window's.
    package func narrowScope() {
        let row = content.processes.first { selection.contains($0.id) }
        let tab = row?.owner.flatMap(ActivityRows.paneTab) ?? row?.tab ?? currentTab()
        guard let narrower = scope(section).narrower(tab: tab, checkout: tab.flatMap { lastTabs[$0]?.checkout }) else { return }
        setScope(narrower)
    }

    /// `]`: wider.
    package func widenScope() {
        var checkout: String?
        if case .tab(let id) = scope(section) { checkout = lastTabs[id]?.checkout }
        setScope(scope(section).wider(checkout: checkout))
    }

    /// A row's fold flipped: a group, a process with children, "+N more".
    package func toggleFold(_ id: String, folded now: Bool) {
        folds[id] = !now
        revealed = nil
        rebuild(asked: true)
    }

    /// A plain press on a row (`ResourceTable`'s `pressed`, after it is
    /// selected): a group's header, or Listening's folded ports, flips its
    /// fold — the whole header is the switch, not only its chevron. A
    /// process is only selected; its own chevron is a button of its own.
    package func pressed(_ id: String) {
        if section == .listening {
            if let fold = content.ports.first(where: { $0.id == id && $0.kind == .folded }) { toggleFold(id, folded: fold.folded) }
            return
        }
        if case .group(let row)? = content.list.first(where: { $0.id == id }), row.foldable, row.kind != .container {
            toggleFold(id, folded: row.folded)
        }
    }

    /// ← (`open` false) and → on a row, as `ResourceTable` reads them:
    /// whether it folded or unfolded.
    package func fold(_ id: String, open: Bool) -> Bool {
        if section == .listening {
            guard let fold = content.ports.first(where: { $0.id == id && $0.kind == .folded }), fold.folded == open else { return false }
            toggleFold(id, folded: fold.folded)
            return true
        }
        let folded: Bool
        switch content.list.first(where: { $0.id == id }) {
        case .group(let row)?:
            guard row.foldable, row.kind != .container else { return false }
            folded = row.folded
        case .process(let row)?:
            guard row.hasChildren else { return false }
            folded = row.folded
        case nil: return false
        }
        guard folded == open else { return false }
        toggleFold(id, folded: folded)
        return true
    }

    // MARK: The filter

    /// What `section`'s filter field says.
    package func filter(_ section: Section) -> String { filters[section] ?? "" }

    package func setFilter(_ text: String, for section: Section? = nil) {
        let section = section ?? self.section
        guard filter(section) != text else { return }
        filters[section] = text
        rebuild(asked: true)
    }

    // MARK: The columns

    /// `section`'s columns as shown now (6.5).
    package func columns(_ section: Section) -> [ResourceColumn] {
        ActivityColumns.columns(section, kept: layout[section.rawValue], grouping: grouping, everyone: everyone ?? Settings.shared.activityEveryone)
    }

    /// A header moved or resized: kept for the next launch too.
    package func columnsChanged(_ columns: [ResourceColumn], in section: Section? = nil) {
        let section = section ?? self.section
        let kept = ActivityColumns.kept(columns)
        guard layout[section.rawValue] != kept else { return }
        layout[section.rawValue] = kept
        ActivityColumns.save(layout)
    }

    /// The header's menu: a column shown or hidden.
    package func toggleColumn(_ id: String, in section: Section? = nil) {
        let section = section ?? self.section
        columnsChanged(ActivityColumns.toggled(id, in: columns(section), section: section), in: section)
    }

    // MARK: The hold

    /// The list was worked (6.7): the order holds while it is, and lets go
    /// once the pointer rests — the rows a tick brought meanwhile shown.
    package func interacted(_ interaction: ResourceTableInteraction, sheet: Bool = false) {
        if sheet {
            hold.sheet = interaction == .menuOpened
        } else {
            hold.note(interaction, at: .now)
        }
        updateHold()
    }

    private func updateHold() {
        let held = hold.holds(at: .now, voiceOver: voiceOverInList())
        if !held, let waiting {
            self.waiting = nil
            apply(waiting)
        }
        if orderHeld != held { orderHeld = held }
        release?.cancel()
        release = nil
        if held, let rests = hold.restsAt {
            release = Task { [weak self] in
                try? await Task.sleep(until: rests, clock: .continuous)
                guard !Task.isCancelled else { return }
                self?.updateHold()
            }
        }
    }

    /// Docker's model wanted while the page shows, the containers' usage
    /// while Processes does.
    private func updateContainers() {
        let wanted: ActivityContainerWant = !isShown ? .none : section == .processes ? .usage : .listed
        guard wanted != wantsContainers else { return }
        wantsContainers = wanted
        wantContainers(wanted)
    }

    /// It shows, in a window on screen, with Activity on.
    package var isShown: Bool { visible && windowVisible && Settings.shared.activityEnabled }

    /// Its want, as it shows and Activity is on: the full level at the
    /// census's interval; given back otherwise — and while paused, its rows
    /// kept then. Hidden, the rows go and the pause with them.
    package func updateWant() {
        let shown = isShown
        if shown, !paused {
            interval = monitor.interval
            monitor.want(self, .full, .focus(focused))
            if !wanting { subscribe() }
            wanting = true
        } else if wanting {
            monitor.unwant(self)
            wanting = false
            snapshots = nil
        }
        if !shown, hasRead || latest != nil {
            forget()
            if paused { paused = false }
        }
        updateContainers()
    }

    /// Hidden: the rows go with the want, so the page shown again says
    /// "Reading…" until a fresh tick's rows land — never minutes-old
    /// numbers as now. The section and the selection stay.
    private func forget() {
        generation += 1
        latest = nil
        waiting = nil
        content = ActivityPageContent()
        hasRead = false
        detail = nil
        subjectGeneration += 1
        verbSubject = nil
        if !visible {
            pendingPort = nil
            linkSaid = nil
            keySaid = nil
        }
    }

    /// Takes each full snapshot that lands while it wants them, and one
    /// already there that is no older than two intervals: an older one
    /// would show minutes-old numbers as now.
    private func subscribe() {
        if let last = monitor.lastFull, monitor.age(of: last) <= 2 * ActivityMonitor.nanoseconds(monitor.interval) { take(last) }
        // @Published emits before it changes: the emitted value.
        snapshots = monitor.$snapshot.compactMap { $0 }.filter { $0.demand.full }
            .sink { [weak self] snapshot in self?.take(snapshot) }
    }

    package func take(_ snapshot: ActivitySnapshot) {
        guard !paused, snapshot.tick > latest?.tick ?? 0 else { return }
        latest = snapshot
        readOthers(snapshot)
        // What Activity stopped or put in the background and has since
        // ended, or been continued elsewhere, is let go.
        held.prune(at: snapshot.date) { snapshot.table.process($0) }
        rebuild(asked: false)
    }

    /// The selection's open files read again (6.4's Files): its own only,
    /// off the main thread; a later read wins.
    package func readFiles() {
        filesGeneration += 1
        openFiles = nil
        guard showsFiles, let row = detail?.row, row.isOwn, !row.ended else { return }
        let generation = filesGeneration
        ProcessOpenFiles.read(row.identity, kernel: monitor.sampler.kernel) { [weak self] listing in
            Task { @MainActor [weak self] in self?.tookFiles(listing, generation: generation) }
        }
    }

    private func tookFiles(_ listing: ProcessOpenFiles.Listing, generation: Int) {
        guard filesGeneration == generation else { return }
        openFiles = listing
    }

    /// nettop's period (D-25): every fifth tick, 10 s at the 2 s default.
    package var othersPeriod: TimeInterval {
        let parts = interval.components
        return 5 * (Double(parts.seconds) + Double(parts.attoseconds) / 1e18)
    }

    /// Every user's listeners read again (D-25, 6.8): while Listening shows
    /// with `activity.otherListeners` on, at most once a period, one read
    /// at a time; its blind check made against `snapshot`'s listeners of
    /// the user's and again against the latest's as it lands.
    private func readOthers(_ snapshot: ActivitySnapshot, now: Bool = false) {
        guard isShown, section == .listening, Settings.shared.activityOtherListeners, !othersReader.isReading else { return }
        if !now, let began = othersBegan, Date().timeIntervalSince(began) < othersPeriod { return }
        let expected = NettopListeners.expected(in: snapshot, among: othersAmong)
        let started = othersReader.read(expected: expected) { [weak self] reading in
            Task { @MainActor [weak self] in self?.tookOthers(reading) }
        }
        if started { othersBegan = Date() }
    }

    /// Whose listeners nettop's answer is checked against: a test run's
    /// own rows' (9.9), else every one of the user's.
    private var othersAmong: Set<ActivityProcessID>? { isolated ? content.identities : nil }

    private func tookOthers(_ reading: NettopListeners.Reading) {
        others = latest.map { reading.checked(against: NettopListeners.expected(in: $0, among: othersAmong)) } ?? reading
        if isShown { rebuild(asked: false) }
    }

    /// One read of every user's listeners now, whatever the period: what a
    /// scenario asks, with its stand-in nettop.
    @discardableResult
    package func readOtherListenersNow() -> Bool {
        guard let latest else { return false }
        readOthers(latest, now: true)
        return othersReader.isReading
    }

    /// The rows of the latest snapshot, made off the main thread (7.7); a
    /// later rebuild wins over one still on its way. `asked`: by the
    /// person — a sort, a fold, the filter — and shown at once; a tick's
    /// wait while the order holds (6.7).
    private func rebuild(asked: Bool = true) {
        guard isShown, let snapshot = latest else { return }
        generation += 1
        let generation = self.generation
        var options = ActivityRows.Options(
            everyone: everyone ?? Settings.shared.activityEveryone, isolated: isolated, processSort: processSort, portSort: portSort)
        options.processFilter = filter(section == .leftBehind ? .leftBehind : .processes)
        options.portFilter = filter(.listening)
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
        options.containers = wantsContainers == .none ? [] : containers()
        options.connections = connections
        options.unixSockets = Settings.shared.activityUnixSockets
        options.processLimit = processLimit
        if Settings.shared.activityOtherListeners {
            if let why = othersReader.unavailable, othersReader.standIn == nil {
                options.othersState = .unavailable(why)
            } else {
                // A read older than three of its periods is no longer now.
                let fresh = others.flatMap { Date().timeIntervalSince($0.date) <= 3 * othersPeriod ? $0 : nil }
                options.others = fresh
                options.othersState = ActivityOtherListeners.of(fresh, period: othersPeriod)
            }
        }
        // What Activity stopped and put in the background, always: every
        // row's "suspended here" and "background" chips read it, selected
        // or not.
        options.known = known()
        options.known.runningApps = options.runningApps
        if let selected = selectedProcess?.identity { options.subjectOf = selected }
        if let selected = selectedProcess, selected.isOwn { options.historyOf = selected.identity }
        // New and ended (6.7): against the rows shown, from the second build;
        // the same census made again keeps its ended rows as they were.
        options.marksNew = hasRead
        if hasRead {
            options.previous = content.processes
            options.shownAt = content.madeAt
            options.repeatsEnded = asked
        }
        lastOptions = options
        // Held now: the rows shown go along, and the merge of the new values
        // into their order is made off the main thread too (7.7).
        let shown = !asked && hasRead && hold.holds(at: .now, voiceOver: voiceOverInList()) ? content : nil
        let shownMark = shown.map(Self.mark)
        Task { [weak self] in
            let made = await Self.make(snapshot, options, heldOver: shown)
            // What this build carried (the rows shown, the merge) dies off
            // the main thread, after it.
            defer { ActivityRelease.later((made, shown)) }
            guard let self, self.generation == generation else { return }
            self.builds += 1
            let first = !self.hasRead
            self.hasRead = true
            if !asked, !first, self.hold.holds(at: .now, voiceOver: self.voiceOverInList()) {
                // Values in the order shown; the rest once it lets go. The
                // merge made with the rows when they are still the ones shown.
                self.waiting = made.content
                if let held = made.held, shownMark == Self.mark(self.content) {
                    self.content = held
                } else {
                    self.content = ActivityRows.held(self.content, made.content)
                }
                if !self.orderHeld { self.orderHeld = true }
                self.updateDetail()
                return
            }
            self.waiting = nil
            self.apply(made.content, made: (snapshot.tick, options.scope))
        }
    }

    /// What tells the rows shown from others, cheaply: when they were made
    /// and how many.
    private nonisolated static func mark(_ content: ActivityPageContent) -> [Double] {
        [content.madeAt?.timeIntervalSinceReferenceDate ?? 0, Double(content.processes.count), Double(content.list.count), Double(content.ports.count)]
    }

    /// `content` shown: the selection kept to what it still lists. `made`:
    /// the tick and scope its rows were made at — what says a link's port
    /// isn't listed; a held tick's, shown later, says nothing of it.
    private func apply(_ content: ActivityPageContent, made: (tick: Int, scope: ActivityScope)? = nil) {
        self.content = content
        if let pending = pendingPort {
            if let row = Self.linked(pending, in: content.ports) {
                pendingPort = nil
                reveal(row.id, in: .listening)
                if pending.free { actions.free(row) }
                return
            }
            if let made {
                switch Self.unlisted(pending, tick: made.tick, scope: made.scope) {
                case .wait: break
                case .widen:
                    // Not in the tab's or checkout's rows: the Mac's.
                    pendingPort?.scope = .mac
                    linking = true
                    setScope(.mac, for: .listening)
                    linking = false
                case .drop:
                    pendingPort = nil
                    linkSaid = Self.unlistedSaid(pending)
                }
            }
        }
        let shown = content.shownIDs ?? ActivityRows.shownIDs(content)
        if !selection.isSubset(of: shown) { selection = selection.intersection(shown) }
        updateDetail()
    }

    /// The rows made again from the latest snapshot with what the main
    /// actor knows now: a verb that changed what Activity holds (a process
    /// put in the background) is said at once, not a tick later.
    package func refreshVerbs() { rebuild(asked: true) }

    /// The selected row's detail: a process's, or a listener's holder's.
    private func updateDetail() {
        guard let snapshot = latest, let id = selection.first, selection.count == 1 else {
            if detail != nil { detail = nil }
            updateFocus()
            updateSubject()
            return
        }
        let started = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        var row = content.processes.first { $0.id == id }
        if row == nil, let port = content.ports.first(where: { $0.id == id }), let holder = port.holder {
            row = content.processes.first { $0.identity == holder }
        }
        // An ended row (6.7) is shown once more, never in the detail.
        if row?.ended == true { row = nil }
        let made = row.map { ActivityDetail.make($0, in: snapshot, rows: content.identities, ports: content.listeners, history: history(of: $0, snapshot)) }
        if made != detail { detail = made }
        detailCost = Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) &- started) / 1_000_000
        updateFocus()
        updateSubject()
    }

    /// `row`'s history (6.11), never made here: the rows', else one read
    /// on its own queue for a row just selected — the detail kept as it was
    /// until it comes.
    private func history(of row: ActivityProcessRow, _ snapshot: ActivitySnapshot) -> ActivityDetailHistory? {
        guard row.isOwn else { return nil }
        if let made = content.detailHistory, made.identity == row.identity { return made }
        if let read = readHistory, read.identity == row.identity { return read }
        if historyReading != row.identity {
            historyReading = row.identity
            historyGeneration += 1
            let generation = historyGeneration
            let identity = row.identity
            Task { [weak self] in
                let made = await ActivityDetailHistory.read(identity, in: snapshot)
                guard let self, self.historyGeneration == generation else { return }
                self.historyReading = nil
                self.readHistory = made
                self.updateDetail()
            }
        }
        return detail?.row.identity == row.identity ? detail?.history : nil
    }

    /// The selection's subject (6.10): the rows' when they read it, else
    /// read off the main thread from the latest snapshot — what the list's
    /// verbs say, never classed from the rows a scope or filter left.
    private func updateSubject() {
        guard let identity = selectedProcess?.identity, let snapshot = latest else {
            subjectGeneration += 1
            if verbSubject != nil { verbSubject = nil }
            return
        }
        if let made = content.subject, made.signal.identity == identity {
            subjectGeneration += 1
            verbSubject = made
            return
        }
        // Read already for this selection: kept until the next rows'.
        if verbSubject?.signal.identity == identity { return }
        if verbSubject != nil { verbSubject = nil }
        subjectGeneration += 1
        let generation = subjectGeneration
        var options = lastOptions ?? ActivityRows.Options()
        options.known = known()
        options.known.runningApps = options.runningApps
        let attribution = content.attribution
        Task { [weak self] in
            let made = await Self.readSubject(identity, snapshot, options, attribution: attribution)
            guard let self, self.subjectGeneration == generation else { return }
            self.verbSubject = made
        }
    }

    private nonisolated static func readSubject(
        _ identity: ActivityProcessID, _ snapshot: ActivitySnapshot, _ options: ActivityRows.Options, attribution: ActivityAttribution?
    ) async -> ActivityVerbSubject? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: ActivityRows.subject(identity, of: snapshot, options, attribution: attribution))
            }
        }
    }

    /// The selection, the user's own, read at the focus level while the
    /// page wants: its folder comes a tick or two later — never waited for.
    private func updateFocus() {
        let wanted: Set<ActivityProcessID> = detail.flatMap { $0.row.isOwn ? [$0.row.identity] : nil } ?? []
        guard wanted != focused else { return }
        focused = wanted
        if wanting { monitor.want(self, .full, .focus(focused)) }
    }

    private nonisolated static func make(
        _ snapshot: ActivitySnapshot, _ options: ActivityRows.Options, heldOver shown: ActivityPageContent? = nil
    ) async -> (content: ActivityPageContent, held: ActivityPageContent?) {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                // Off the main thread: the LaunchAgents' plists, read again
                // only when their folder changed, and the ephemeral range.
                var options = options
                options.launchAgents = LaunchdJobs.cachedAgents(in: AppEnvironment.launchAgentsDirectory)
                options.ephemeralFirst = ActivityPorts.ephemeralRangeFirst()
                options.containers = ActivityFolderSpelling.spelled(options.containers, checkouts: options.checkouts)
                // launchd's socket jobs, read once, lazily: only when there
                // are other users' listeners to name (6.8 rule 9).
                if options.others?.isBelieved == true { options.launchdSockets = LaunchdSockets.cachedJobs(in: AppEnvironment.launchdSocketFolders) }
                var content = ActivityRows.withListRows(ActivityRows.content(of: snapshot, options))
                content.shownIDs = ActivityRows.shownIDs(content)
                continuation.resume(returning: (content, shown.map { ActivityRows.held($0, content) }))
            }
        }
    }

    /// A setting changed: the want again (on, off, the interval), the rows
    /// again (everyone's) — only while it shows: hidden, nothing is made.
    package func settingsChanged() {
        let was = wanting
        if wanting {
            monitor.unwant(self)
            wanting = false
            snapshots = nil
        }
        updateWant()
        if isShown { rebuild(asked: true) } else if was { forget() }
    }

    /// The page closed: what it shows goes with it.
    package func close() {
        visible = false
        selection = []
        forget()
        paused = false
        hold = ActivityHold()
        updateHold()
    }

    /// A key while the list has the keyboard (`ActivityKey`, 6.3): whether
    /// it meant something; anything else goes on to the list.
    @discardableResult
    package func press(_ characters: String) -> Bool {
        guard let pressed = ActivityKey.press(characters, sheetShowing: cheatSheet) else { return false }
        byHand()
        switch pressed {
        case .closeSheet: cheatSheet = false
        case .section(let section): self.section = section
        case .help: cheatSheet = true
        case .filter: focusFilter += 1
        case .key(let key): return press(key)
        }
        return true
    }

    /// Each key does what the row's menu says it does, in every section
    /// (6.3): the verbs that are a row's are found in `verbs(for:)` by
    /// their key, so a key and the menu never disagree; one that can't be
    /// done now says why, as the greyed item does (`refuse`).
    private func press(_ key: ActivityKey) -> Bool {
        switch key {
        case .goTo: goToSelection()
        case .detail: showsDetail.toggle()
        case .open, .reveal, .tabInfo, .sample, .terminal, .free, .ask: return pressVerb(key.key)
        case .files: return pressFiles()
        case .tree, .group:
            guard section == .processes else { return refuse(Self.arrangesProcesses(key, in: section)) }
            if key == .tree { tree.toggle() } else { grouping = grouping.next }
        case .narrower: narrowScope()
        case .wider: widenScope()
        case .follow: following.toggle()
        case .pause: paused.toggle()
        case .mine: everyone = !(everyone ?? Settings.shared.activityEveryone)
        case .connections:
            guard section == .listening else { return refuse(Self.connectionsAreListenings) }
            connections.toggle()
        case .stop, .forceQuit, .signal, .suspend, .background, .lower: return pressSignalKey(key)
        case .sortCPU, .sortMemory, .sortTime, .sortPID, .invert:
            // Processes' and Left Behind's: both list processes by it.
            guard section != .listening else { return refuse(Self.listeningSorts) }
            switch key {
            case .sortCPU: processSort = ResourceSort(column: "cpu", ascending: false)
            case .sortMemory: processSort = ResourceSort(column: "memory", ascending: false)
            case .sortTime: processSort = ResourceSort(column: "time", ascending: false)
            case .sortPID: processSort = ResourceSort(column: "pid")
            default:
                guard var sort = processSort else { return refuse(Self.nothingToInvert) }
                sort.ascending.toggle()
                processSort = sort
            }
        default: return false
        }
        return true
    }

    /// A key that can't be done now (6.3): the reason the menu greys its
    /// verb with, said in the header, and a beep. The key is taken — it
    /// meant something, so it goes on to nothing else.
    @discardableResult
    package func refuse(_ why: String) -> Bool {
        keySaid = why
        actions.beep()
        return true
    }

    /// The row's verb with `key` (`o`, `r`, `i`, `s`, `e`, `f`, `a`, ⌥o,
    /// ⌥r): done, or its greyed reason said.
    private func pressVerb(_ key: String) -> Bool {
        guard selection.count == 1 else { return refuse(selection.isEmpty ? Self.nothingSelected : Self.severalSelected) }
        guard let verb = verbs(for: selection, copy: { _ in }).first(where: { $0.key == key }) else {
            return refuse(key == ActivityKey.free.key && section != .listening ? Self.freeIsListenings : Self.notForThisRow)
        }
        if let why = verb.unavailable { return refuse(why) }
        verb.perform()
        return true
    }

    /// `l`: the detail's Files, the selection's process's — a listener's
    /// holder, a left-behind row — read now, or hidden again.
    private func pressFiles() -> Bool {
        guard selection.count == 1 else { return refuse(selection.isEmpty ? Self.nothingSelected : Self.severalSelected) }
        guard let row = detail?.row else { return refuse(Self.notForThisRow) }
        guard row.isOwn else { return refuse(Self.othersFiles) }
        if showsFiles, openFiles?.identity == row.identity {
            showsFiles = false
        } else {
            showsFiles = true
            readFiles()
        }
        return true
    }

    package nonisolated static let nothingSelected = "Select a row first"
    package nonisolated static let severalSelected = "Select one row: it acts on one"
    package nonisolated static let notForThisRow = "Not for this row: it names no process of yours to act on"
    package nonisolated static let othersFiles = "Another user's: its open files aren't read"
    package nonisolated static let freeIsListenings = "f frees a port: select it in Listening (2)"
    package nonisolated static let connectionsAreListenings = "c shows connections in Listening (2)"
    package nonisolated static let listeningSorts = "Listening sorts by its column headers: P M T N I sort processes"
    package nonisolated static let nothingToInvert = "No sort to invert: pick one with P, M, T or N"

    /// Why `t` or `G` does nothing in `section`. Pure.
    package nonisolated static func arrangesProcesses(_ key: ActivityKey, in section: Section) -> String {
        let listed = section == .listening ? "Listening lists ports" : "Left Behind is grouped by checkout"
        return "\(key.key) arranges Processes (1): \(listed)"
    }

    /// The selected process — a listener's holder in Listening.
    package var selectedProcess: ActivityProcessRow? { selection.count == 1 ? detail?.row : nil }

    /// Ask an Agent About It (`a`, ⌘L; 8.6): the selected process's brief,
    /// from its detail, to the window's Ask Agent sheet. False when no one
    /// process is selected.
    @discardableResult
    package func askAboutSelection() -> Bool {
        guard selection.count == 1, let detail else { return false }
        actions.ask(ActivityBrief.make(detail), detail.row.tab)
        return true
    }

    /// The selected process's working folder, once the focus level read it.
    package var selectedFolder: String? { selectedProcess == nil ? nil : detail?.folderPath }

    /// ↩: a process to its tab and pane; a listener to its process's row;
    /// one outside every tab to its detail.
    private func goToSelection() {
        guard let id = selection.first else { return }
        if section == .listening, let holder = content.ports.first(where: { $0.id == id })?.holder {
            return reveal(holder.id, in: .processes)
        }
        if let row = content.processes.first(where: { $0.id == id }), row.tab != nil { return goTo(row) }
        showsDetail = true
    }

    /// `row`'s tab, and its pane when the pane's tag placed it.
    package func goTo(_ row: ActivityProcessRow) {
        guard let tab = row.tab else { return }
        var pane: String?
        if case .pane(let tag)? = row.owner?.place { pane = tag }
        actions.goTo(tab, pane)
    }

    /// The listener `o` opens for `id`: a listener's own row, or a
    /// process's first that a browser reaches — whatever a filter shows.
    private func openable(_ id: String) -> ActivityPortRow? {
        if let port = content.ports.first(where: { $0.id == id }) ?? content.listeners.first(where: { $0.id == id }) { return port.url == nil ? nil : port }
        guard let row = content.processes.first(where: { $0.id == id }) else { return nil }
        return content.listeners.first { $0.holder == row.identity && $0.url != nil }
    }

    /// A key with ⌥ while the list has the keyboard: ⌥o opens in the
    /// default browser (6.3). `characters` ignore the modifier.
    @discardableResult
    package func pressOption(_ characters: String) -> Bool {
        guard !cheatSheet else { return false }
        switch characters {
        case "o", "r":
            byHand()
            return pressVerb("⌥" + characters)
        default: return false
        }
    }

    /// ⌘C: the selected rows, a line each — names, pids, ports only.
    package var selectedLines: [String] { lines(for: selection) }

    /// `ids`' rows, a line each, as ⌘C copies them.
    package func lines(for ids: Set<String>) -> [String] {
        switch section {
        case .processes, .leftBehind:
            content.processes.filter { ids.contains($0.id) }.map { "\($0.name)\t\($0.identity.pid)" }
        case .listening:
            content.ports.filter { ids.contains($0.id) && $0.kind != .folded }.map {
                "\($0.port)/\($0.proto)\t\($0.process)\t\($0.holder.map { String($0.pid) } ?? "")\t\($0.ownerText)"
            }
        }
    }

    /// The verbs of `ids`' rows (6.4): one list, drawn as the detail's
    /// `ResourceActionBar` and as the list's right-click menu. One row: Go
    /// to Tab, Open, Reveal, Tab Info, Sample, Copy — what can't be done
    /// greyed with why; several: Copy. `copy` puts lines on the pasteboard.
    package func verbs(for ids: Set<String>, copy: @escaping ([String]) -> Void) -> [ResourceVerb] {
        let copyVerb = ResourceVerb(
            title: ids.count > 1 ? "Copy \(ids.count) Rows" : "Copy", symbol: "doc.on.doc", key: "⌘C", group: 1,
            perform: { [weak self] in
                guard let self else { return }
                copy(self.lines(for: ids))
            })
        guard ids.count == 1, let id = ids.first else { return ids.isEmpty ? [] : [copyVerb] }
        let port = content.ports.first { $0.id == id }
        let row = content.processes.first { $0.id == id } ?? port?.holder.flatMap { holder in content.processes.first { $0.identity == holder } }
        // Ended (6.7): its pid may be another's already — copied, never
        // acted on.
        if let row, row.ended {
            return [ResourceVerb(title: "Copy PID", symbol: "number", group: 1, perform: { copy([String(row.identity.pid)]) }), copyVerb]
        }
        var verbs: [ResourceVerb] = []
        if let port, let holder = port.holder {
            verbs.append(
                ResourceVerb(
                    title: "Show Its Process", label: "Process", symbol: "list.bullet.indent", key: "↩",
                    perform: { [weak self] in self?.reveal(holder.id, in: .processes) }))
        }
        if let row {
            verbs.append(
                ResourceVerb(
                    title: "Go to Tab", symbol: "arrow.right.square", place: .button, key: port == nil ? "↩" : nil,
                    unavailable: row.tab == nil ? "It runs outside every tab" : nil, perform: { [weak self] in self?.goTo(row) }))
        }
        let opens = openable(id)
        verbs.append(
            ResourceVerb(
                title: "Open in Browser", label: "Open", symbol: "safari", place: .button, key: "o",
                unavailable: opens == nil ? "Nothing it listens on opens in a browser" : nil,
                perform: { [weak self] in if let opens, let url = opens.url { self?.actions.open(url, opens.tab, false) } }))
        verbs.append(
            ResourceVerb(
                title: "Open in Default Browser", symbol: "arrow.up.forward.app", key: "⌥o",
                unavailable: opens == nil ? "Nothing it listens on opens in a browser" : nil,
                perform: { [weak self] in if let opens, let url = opens.url { self?.actions.open(url, opens.tab, true) } }))
        if let opens, opens.kind == .listener, let secure = Self.https(opens.url) {
            // 6.8, Open: a listener serving TLS that isn't a forward saying so.
            verbs.append(
                ResourceVerb(
                    title: "Open as https", symbol: "lock", perform: { [weak self] in self?.actions.open(secure, opens.tab, false) }))
        }
        if let port, port.kind == .listener {
            verbs.append(
                ResourceVerb(
                    title: "Copy URL", symbol: "link", unavailable: port.url == nil ? "Nothing a browser opens: UDP, or a link-local address" : nil, group: 1,
                    perform: { if let url = port.url { copy([url.absoluteString]) } }))
            verbs.append(ResourceVerb(title: "Copy Port", symbol: "number", group: 1, perform: { copy([String(port.port)]) }))
            // 6.8, Free :N: the owner's own verb, asked first; stopping
            // the user's own processes is the verbs' stage.
            let step = ActivityPortHolder.step(for: port)
            verbs.append(
                ResourceVerb(
                    title: step.map { ActivityPortHolder.title($0, port: port.port) } ?? "Free :\(port.port)…", label: "Free", symbol: "xmark.circle",
                    place: .button, key: "f", unavailable: ActivityPortHolder.unavailable(port),
                    perform: { [weak self] in self?.actions.free(port) }))
        }
        guard let row else { return verbs + [copyVerb] }
        verbs.append(
            ResourceVerb(
                title: "Reveal in Finder", label: "Reveal", symbol: "folder", place: .button, key: "r",
                unavailable: row.path == nil ? (row.isOwn ? "Its executable isn't read yet" : "Another user's: not readable") : nil,
                perform: { [weak self] in if let path = row.path { self?.actions.reveal(path) } }))
        // Its folder, read at the focus level for the selection alone.
        let shown = detail?.row.identity == row.identity ? detail : nil
        let folder = shown?.folderPath
        let noFolder = shown?.folderUnavailable ?? (row.isOwn ? "Select it alone: its folder is read for the selection" : "Another user's: its folder isn't read")
        verbs.append(
            ResourceVerb(
                title: "Reveal Its Folder in Finder", symbol: "folder.badge.gearshape", key: "⌥r", unavailable: folder == nil ? noFolder : nil,
                perform: { [weak self] in if let folder { self?.actions.reveal(folder) } }))
        // Near the per-user process limit (6.4), what would start one waits.
        let forks = content.summary.processLimitText.map { "\($0): near your limit, a new process may not start" }
        verbs.append(
            ResourceVerb(
                title: "Terminal in Its Folder", symbol: "terminal", key: "e", unavailable: forks ?? (folder == nil ? noFolder : nil),
                perform: { [weak self] in if let folder { self?.actions.terminal(ActivityTerminalRequest(directory: folder)) } }))
        verbs.append(
            ResourceVerb(
                title: "Tab Info", symbol: "info.circle", place: .button, key: "i", unavailable: row.tab == nil ? "It runs outside every tab" : nil,
                perform: { [weak self] in if let tab = row.tab { self?.actions.tabInfo(tab) } }))
        verbs.append(
            ResourceVerb(
                title: "Sample for 5 Seconds in a Tab", label: "Sample", symbol: "waveform.path.ecg", key: "s",
                unavailable: forks ?? (row.isOwn ? nil : "Another user's: sample can't read it"),
                perform: { [weak self] in self?.actions.sample(row.identity.pid) }))
        verbs.append(
            ResourceVerb(
                title: "Open Files in a Tab", symbol: "doc.text.magnifyingglass", unavailable: forks ?? (row.isOwn ? nil : "Another user's: lsof can't read it"),
                perform: { [weak self] in
                    self?.actions.terminal(ActivityTerminalRequest(directory: NSHomeDirectory(), command: Self.openFilesCommand(row.identity.pid)))
                }))
        verbs.append(
            ResourceVerb(
                title: "Ask an Agent About It…", label: "Ask", symbol: "bubble.left.and.text.bubble.right", place: .button, key: "a",
                unavailable: detail?.row.identity == row.identity ? nil : "Select it alone: the brief is made from its detail",
                perform: { [weak self] in self?.askAboutSelection() }))
        verbs += signalVerbs(for: row)
        verbs += leftBehindVerbs(for: row)
        verbs.append(ResourceVerb(title: "Copy PID", symbol: "number", group: 1, perform: { copy([String(row.identity.pid)]) }))
        verbs.append(
            ResourceVerb(
                title: "Copy Command", symbol: "text.quote", unavailable: row.command == nil ? "Its command isn't read" : nil, group: 1,
                // Masked as it was read (9.3): a password on a command
                // line never reaches the pasteboard.
                perform: { if let command = row.command { copy([command]) } }))
        return verbs + [copyVerb]
    }

    /// Open Files in a Tab's line (6.10): `lsof` of the one process, read
    /// only. Pure.
    package nonisolated static func openFilesCommand(_ pid: pid_t) -> String { "lsof -nP -p \(pid)" }

    /// Sample in a Tab's (6.10): its report to the tab, never left in /tmp
    /// as `sample` does without `-file`. Pure.
    package nonisolated static func sampleCommand(_ pid: pid_t) -> String { "sample \(pid) 5 -file /dev/stdout" }

    /// `url` as https, when it is http. Pure.
    package nonisolated static func https(_ url: URL?) -> URL? {
        guard let url, url.scheme == "http", var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        parts.scheme = "https"
        return parts.url
    }

    /// A link's (6.12): the page on its section and scope, the row
    /// selected and followed — a port's once a tick's rows list it.
    package func show(_ link: ActivityLink) {
        switch link {
        case .tab(let id):
            section = .processes
            setScope(.tab(id), for: .processes)
            focusList += 1
        case .process(let identity, let tab):
            if let tab { setScope(.tab(tab), for: .processes) }
            following = true
            reveal(identity.id, in: .processes)
        case .port(let port, let proto, let pid, let tab):
            linking = true
            defer { linking = false }
            linkSaid = nil
            let scope = Self.linkScope(tab: tab, checkout: tab.flatMap { tabFacts()?.tabs[$0]?.checkout })
            setScope(scope, for: .listening)
            section = .listening
            // The link's row replaces what was selected.
            selection = []
            following = true
            let pending = ActivityPendingPort(port: port, proto: proto, pid: pid, after: latest?.tick ?? 0, scope: scope)
            pendingPort = pending
            if let row = Self.linked(pending, in: content.ports) {
                pendingPort = nil
                reveal(row.id, in: .listening)
            }
        }
    }

    /// Free a Port… (6.3): Listening at the Mac's scope, the port's row
    /// selected and its Free asked as `f` asks it — the holder read again
    /// from a fresh census as the sheet opens. A port no row lists says so
    /// as a link's does.
    package func free(port: Int, proto: String = "tcp") {
        show(.port(port, proto: proto, pid: nil, tab: nil))
        if pendingPort != nil {
            pendingPort?.free = true
        } else if let row = Self.linked(ActivityPendingPort(port: port, proto: proto, after: 0, scope: .mac), in: content.ports) {
            actions.free(row)
        }
    }

    /// The port Free a Port… was given: a number, `:3000`, or `5353/udp`.
    /// Nil for anything else. Pure.
    package nonisolated static func typedPort(_ text: String) -> (port: Int, proto: String)? {
        var word = text.trimmingCharacters(in: .whitespaces).lowercased()
        var proto = "tcp"
        for suffix in ["/udp", "/tcp"] where word.hasSuffix(suffix) {
            proto = String(suffix.dropFirst())
            word.removeLast(suffix.count)
        }
        if word.hasPrefix(":") { word.removeFirst() }
        guard !word.isEmpty, word.count <= 5, word.allSatisfy(\.isASCII), word.allSatisfy(\.isNumber), let port = Int(word), (1...65_535).contains(port)
        else { return nil }
        return (port, proto)
    }

    /// The person's hand — a key, a selection, a section — takes the page
    /// from a link still waiting for its port, and from what it said.
    private func byHand() {
        guard !linking else { return }
        pendingPort = nil
        linkSaid = nil
        keySaid = nil
    }

    /// The scope a port link opens Listening at (6.5): the tab's
    /// checkout's — its stack's containers listed beside its tabs' — else
    /// the tab's, else the Mac's. Pure.
    package nonisolated static func linkScope(tab: UUID?, checkout: String?) -> ActivityScope {
        if let checkout { return .checkout(checkout) }
        return tab.map { .tab($0) } ?? .mac
    }

    /// What a tick's rows that don't list a link's port mean: nothing yet
    /// (made before the link, or at another rung), a wider look (the
    /// Mac's), or that it isn't listed at all. Pure.
    package enum Unlisted: Equatable, Sendable { case wait, widen, drop }

    package nonisolated static func unlisted(_ pending: ActivityPendingPort, tick: Int, scope: ActivityScope) -> Unlisted {
        guard tick > pending.after, scope == pending.scope else { return .wait }
        return scope == .mac ? .drop : .widen
    }

    /// What the header says of a port a link couldn't show. Pure.
    package nonisolated static func unlistedSaid(_ pending: ActivityPendingPort) -> String {
        ":\(pending.port)\(pending.proto == "udp" ? "/udp" : "") isn't listed (another user's?)"
    }

    /// The listener a port link names: its holder's when it says which,
    /// else the first on that port and protocol. Pure.
    package nonisolated static func linked(_ link: ActivityPendingPort, in ports: [ActivityPortRow]) -> ActivityPortRow? {
        let listeners = ports.filter { $0.kind == .listener && $0.port == link.port && $0.proto == link.proto }
        if let pid = link.pid, let held = listeners.first(where: { $0.holder?.pid == pid }) { return held }
        return listeners.first
    }

    /// The process or port shown on the page: its section, selected.
    package func reveal(_ id: String, in section: Section) {
        linking = true
        defer { linking = false }
        self.section = section
        revealed = id
        rebuild(asked: true)
        selection = [id]
        focusList += 1
    }
}

/// The page's rows let go of off the main thread (7.7): a tick's content
/// replaced by the next freed thousands of rows' storage on it — 1.8–4.0
/// ms of the queue's CPU a publish at 1,300 processes (`activityPerf`). Each value is kept a moment
/// past the main thread's last use, so the queue's is the last reference.
package enum ActivityRelease {
    private static let queue = DispatchQueue(label: "overterm.activity.release", qos: .utility)

    /// The queue's CPU so far, and the values it let go of: moved off the
    /// main thread, not removed, so 7.3's share of a core counts it
    /// (`activityPerf`).
    private static let spentSoFar = OSAllocatedUnfairLock(initialState: (cpu: UInt64(0), values: 0))

    package nonisolated static func later<Value: Sendable>(_ value: Value) {
        let held = Held(value)
        let block: @Sendable () -> Void = {
            let start = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
            held.value = nil
            let cpu = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) &- start
            spentSoFar.withLock {
                $0.cpu &+= cpu
                $0.values += 1
            }
        }
        queue.asyncAfter(deadline: .now() + 1, execute: block)
    }

    /// The queue's CPU (nanoseconds) and the values it freed, since launch.
    package nonisolated static var spent: (cpu: UInt64, values: Int) { spentSoFar.withLock { $0 } }

    /// A value let go of inside the timed part of the block, not when the
    /// block itself is.
    private final class Held<Value: Sendable>: @unchecked Sendable {
        var value: Value?
        init(_ value: Value) { self.value = value }
    }
}
