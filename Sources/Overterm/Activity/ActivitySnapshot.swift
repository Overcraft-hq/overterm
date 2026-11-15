import Darwin
import Foundation

/// What a reader asks the census to read (docs/design/activity/analysis.md,
/// 7.3). Each costs what it reads; a reader wants the least that serves it.
enum ActivityLevel: Hashable, Sendable {
    /// These tabs' panes' processes and Overterm's helpers: usage, the
    /// listening and bound-UDP sockets, the panes' agents' folders — what
    /// the pills, Tab Info and the overview show. Nil: every tab the
    /// context names. A process outside every pane's tree has its markers
    /// read once, to learn whether it carries a pane's tag.
    case light(tabs: Set<UUID>?)
    /// These processes in depth: every socket, peers included, the
    /// descriptor count, the working folder (the detail, a Stop's watch,
    /// Tab Info's rows on screen).
    case focus(Set<ActivityProcessID>)
    /// Every process: the user's read in full (usage, every socket, argv),
    /// the others' named (the page, the switcher, an agent's read).
    case full
}

/// Every level the readers want, merged into what one tick reads (7.1):
/// one tick serves them all.
struct ActivityDemand: Hashable, Sendable {
    /// Every process.
    var full = false
    /// Whose panes the light level reads; nil: every pane the context
    /// names; empty: none.
    var tabs: Set<UUID>? = []
    /// Processes read in depth.
    var focus: Set<ActivityProcessID> = []

    init() {}

    init(_ levels: ActivityLevel...) { self.init(levels) }

    init(_ levels: [ActivityLevel]) {
        for level in levels { add(level) }
    }

    mutating func add(_ level: ActivityLevel) {
        switch level {
        case .light(let wanted):
            if let mine = tabs, let wanted { tabs = mine.union(wanted) } else { tabs = nil }
        case .focus(let identities): focus.formUnion(identities)
        case .full: full = true
        }
    }

    /// Both read in one tick.
    func merged(_ other: ActivityDemand) -> ActivityDemand {
        var merged = self
        merged.full = full || other.full
        if let mine = tabs, let theirs = other.tabs { merged.tabs = mine.union(theirs) } else { merged.tabs = nil }
        merged.focus.formUnion(other.focus)
        return merged
    }

    var isEmpty: Bool { !full && tabs?.isEmpty == true && focus.isEmpty }

    /// Whether any pane is read: then the user's processes outside every
    /// pane's tree have their markers read, and Overterm's helpers are read
    /// too.
    var readsPanes: Bool { full || tabs.map { !$0.isEmpty } ?? true }

    /// Whether `pane`'s processes are read: at the full level every pane's.
    func reads(_ pane: ActivityContext.Pane) -> Bool { full || tabs.map { $0.contains(pane.tab) } ?? true }

    /// Whether a tick for this reads everything `other` asks: a full one
    /// reads every pane and every process's usage and sockets — the folders
    /// it asks for come when they come, never waited for.
    func covers(_ other: ActivityDemand) -> Bool {
        if full { return true }
        if other.full { return false }
        switch (tabs, other.tabs) {
        case (nil, _): break
        case (.some, nil): return false
        case (let mine?, let theirs?): if !theirs.isSubset(of: mine) { return false }
        }
        return other.focus.isSubset(of: focus)
    }
}

/// What a tick knows of one process beyond `KERN_PROC_ALL`'s record (7.2,
/// 7.5). The reads it was given are cached by identity on the sampler's
/// queue; usage, rates and sockets are this tick's.
struct ActivityFacts: Hashable, Sendable {
    /// What a row calls it (6.5): the user's `pbi_name`, else its path's
    /// file; another user's its path's file — `p_comm`, cut at 16 bytes,
    /// only while nothing of it is read yet.
    var name: String
    /// Read in full: its path and code signing, and for the user's its name
    /// and argv — read, or found unreadable (`command` nil then). One of the
    /// user's whose markers alone were read (outside every tree, at the
    /// light level) is named from its path but waits for its argv, false
    /// until the churn budget lets a level read it: pending, not failed.
    var isRead = false
    var path: String?
    var codeSigning: ActivityCodeSigning?
    /// argv masked as it was read (`ProcessArguments`): the user's only;
    /// nil until read, or unreadable.
    var command: String?
    /// An interpreter's or a package runner's label (`ActivityText.label`).
    var label: String?
    /// argv ran past 64 KB: `command` ends "…cut".
    var isCut = false
    /// argv[0] is a title the process wrote over its argv.
    var isTitle = false
    /// The agent argv[0]'s file names, and the session id its `--resume`
    /// or `-r` gives, read off the raw words (`ProcessArguments`).
    var argvAgent: Agent?
    var resumes: String?
    /// The four names of its environment (9.2): nil for a process a pane's
    /// tree places (never read), a `CS_RESTRICT` one (hidden by the
    /// kernel), another user's, or one not read yet.
    var markers: ProcessMarkers?
    /// This tick's usage, the user's processes the level read; `rates`
    /// nil is "—": a first sample, or none this tick.
    var usage: ActivityUsage?
    var rates: ActivityRates?
    /// Its sockets as this tick read them: at the light level only its
    /// listening and bound-UDP ones.
    var sockets: SocketScan.Sockets?
    /// Its working folder, where a level asked (a pane's agent, a process
    /// in focus): the last read, never waited for.
    var folder: ProcessFolders.Folder?
}

/// One pane's processes as the light level found them (6.5): the slices
/// Tab Info, the pills and the overview read.
struct ActivityPaneSlice: Hashable, Sendable {
    let tag: String
    let tab: UUID
    /// Its `login`, while the table has it.
    let login: ActivityProcessID?
    /// The login's descendants, parents linked by start time, depth first
    /// and oldest first: its tree.
    let tree: [ActivityProcessID]
    /// Processes carrying its tag outside its tree (nohup, disown), and
    /// their descendants: a place for display, not the pane's set (6.5).
    let tagged: [ActivityProcessID]
    /// The first claude or codex in its tree (`Agent.of`), and which.
    let agent: ActivityProcessID?
    let agentKind: Agent?

    /// Where its processes show (6.5): the tree, then the tagged with their
    /// descendants — what the light level reads. For display only, never
    /// what a verb on the pane or its tab acts on: a tag goes further than
    /// the pane (2.4, item 14) — a tmux server and every session's shell on
    /// tmux's own ptys, an app started with `code .` and its helpers,
    /// ssh-agent, a job that ignores SIGHUP all carry it, with whatever
    /// they started. The pane's set (6.5) leaves those out.
    var placed: [ActivityProcessID] { tree + tagged }
}

/// What a tick cost (7.3, 7.4), counts and times only.
struct ActivityTickCost: Hashable, Sendable {
    /// From the table's read to the snapshot, on the kernel's clock
    /// (`CLOCK_UPTIME_RAW`): what the stretched cadence weighs.
    var wall: UInt64 = 0
    /// The sampler's thread's CPU time (`CLOCK_THREAD_CPUTIME_ID`).
    var cpu: UInt64 = 0
    var processes = 0
    /// The user's.
    var own = 0
    /// Identities read this tick: path, code signing, name, markers or argv.
    var identitiesRead = 0
    /// argv read and masked this tick.
    var commandsRead = 0
    /// Usage read this tick.
    var usageRead = 0
    /// Processes whose sockets were walked this tick.
    var socketsRead = 0
}

/// One census (7.1): what one tick read, as values the main actor takes in
/// one hop. `table` is every process; `facts` what the tick's levels read,
/// and at the full level every process's.
struct ActivitySnapshot: Sendable {
    /// Counts the sampler's ticks from 1.
    let tick: Int
    /// What it read.
    let demand: ActivityDemand
    /// When the table was read: `CLOCK_UPTIME_RAW`, ns, on the kernel's
    /// clock — an age is measured against it — and the wall clock then.
    let time: UInt64
    let date: Date
    /// The user it read for.
    let uid: uid_t
    let table: ProcessTable
    let facts: [ActivityProcessID: ActivityFacts]
    /// The panes it read, in the context's order.
    let panes: [ActivityPaneSlice]
    /// Overterm's helpers: the app's children that aren't panes' `login`s,
    /// and their descendants.
    let helpers: [ActivityProcessID]
    /// The app's live children, oldest first, with `p_comm`, listed on the
    /// sampler's queue: what the main actor pairs each surface's `login`
    /// with when the snapshot lands (`SurfaceProcesses.pair`, 7.7). A
    /// zombie is left out: a `login` that ended before it was paired never
    /// pairs (7.10) — listed, the next surface's `login` shifted onto it.
    let appChildren: [(pid: pid_t, start: UInt64, name: String)]
    /// Of those, the `login`s no pane of the tick's context was paired
    /// with, oldest first (`SurfaceProcesses.unclaimedLogins`, pure, run on
    /// the sampler's queue): the main actor only hands them to the
    /// surfaces waiting, in microseconds.
    let unclaimedLogins: [ActivityProcessID]
    /// New identities its level wanted read and the churn budget left for
    /// a later tick: named from `p_comm` until then (7.3).
    let unread: Int
    let cost: ActivityTickCost
    /// The cadence is stretched to 5 s: a busy Mac (7.3).
    let isStretched: Bool
    /// The system's meters, read at the full level (6.4); nil at the others
    /// and where they can't be read.
    var meters: SystemMeters? = nil

    /// Whether this reads everything `demand` asks.
    func covers(_ demand: ActivityDemand) -> Bool { self.demand.covers(demand) }

    func pane(_ tag: String) -> ActivityPaneSlice? { panes.first { $0.tag == tag } }

    func panes(of tab: UUID) -> [ActivityPaneSlice] { panes.filter { $0.tab == tab } }

    /// What a row calls it: its facts' name, else `p_comm`.
    func name(of identity: ActivityProcessID) -> String? {
        facts[identity]?.name ?? table.process(identity)?.shortName
    }
}
