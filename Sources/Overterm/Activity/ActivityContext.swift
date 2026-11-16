import Darwin
import Foundation

/// What the main actor knows that the census needs (docs/design/activity/
/// analysis.md, 7.1): which pane is which, and what Overterm's other
/// features hold — as one value. The main actor rebuilds it when what it
/// says changes, debounced by 100 ms (`ActivityMonitor.contextChanged`),
/// and each tick takes it whole: the sampler's queue never reads the main
/// actor's objects, and never sees half of a change.
///
/// The fields hold what the app knows today. The later stages' — the panes
/// this run retired, Overterm's registries, the run's marker, what
/// Activity stopped, put in the background or was told to keep — are
/// seams, empty until their stage fills them.
struct ActivityContext: Hashable, Sendable {
    /// One terminal pane.
    struct Pane: Hashable, Sendable {
        /// `TerminalView.processTag`, its shell's `OVERTERM_TAB_ID`: what a
        /// process that left the pane's tree (nohup, disown) still carries.
        let tag: String
        /// Its tab (`Tab.id`).
        let tab: UUID
        /// Its window's number; nil before it has one.
        var window: Int?
        /// The `login` libghostty spawned for it, as the main actor paired
        /// it from a census's children of the app (`SurfaceProcesses`,
        /// 7.7); nil until then. Its descendants are the pane's tree.
        var login: ActivityProcessID?
        /// Its pty's device (`ghostty_surface_tty_name`'s `st_rdev`,
        /// `TerminalView.terminalDevice`): what its processes carry as their
        /// controlling terminal (7.10); nil until libghostty has named it.
        var terminal: dev_t?
        /// Its title, masked as a command (`ActivityText.title`).
        var title = ""
        /// The checkout its tab shows (`Tab.checkoutSource`), and that
        /// checkout's branch.
        var checkout: String?
        var branch: String?
        /// The agent its tab was opened for (`Tab.agent`); one typed into
        /// a plain tab is found in its tree (`ActivityPaneSlice.agent`).
        var agent: Agent?

        init(
            tag: String, tab: UUID, window: Int? = nil, login: ActivityProcessID? = nil, terminal: dev_t? = nil, title: String = "",
            checkout: String? = nil, branch: String? = nil, agent: Agent? = nil
        ) {
            self.tag = tag
            self.tab = tab
            self.window = window
            self.login = login
            self.terminal = terminal
            self.title = title
            self.checkout = checkout
            self.branch = branch
            self.agent = agent
        }
    }

    /// A port a running container publishes on a local engine
    /// (`ComposeProjects.ports`): the engine's process holds it, matched on
    /// the host address, the port and the protocol (6.5, rule 6).
    struct PublishedPort: Hashable, Sendable {
        let container: String
        /// Its compose project, when it has one.
        var project: String?
        /// The host address it is published on (`0.0.0.0`, `127.0.0.1`, `::`).
        let address: String
        let port: UInt16
        /// "tcp" or "udp".
        let proto: String
    }

    /// A Kubernetes port-forward (`KubeForwards`): kubectl is Overterm's
    /// child, so its socket is the forward's, never the tab's.
    struct Forward: Hashable, Sendable {
        /// kubectl's; 0 while it restarts.
        let pid: pid_t
        let port: UInt16
        /// What it forwards to, as its pill says.
        let target: String
        /// The tab that started it.
        var tab: UUID?
    }

    /// A database tunnel (`SSHTunnel`): ssh's local port.
    struct Tunnel: Hashable, Sendable {
        let pid: pid_t
        let port: UInt16
        /// The connection's name.
        let name: String
    }

    /// A pane this run closed (stage 3, 6.9): a process that still carries
    /// its tag was left behind by it.
    struct RetiredPane: Hashable, Sendable {
        let pane: Pane
        let closed: Date
    }

    var panes: [Pane] = []
    /// The app's pid: its children that aren't panes' `login`s are
    /// Overterm's helpers (6.5, rule 2). `getpid()`; a fake's in the tests.
    var appPID: pid_t = getpid()

    /// What a local engine's running containers publish.
    var published: [PublishedPort] = []
    var forwards: [Forward] = []
    var tunnels: [Tunnel] = []
    /// The MCP bridge's port (`BrowserBridge.shared.port`): Overterm's own listener.
    var bridgePort: UInt16?
    /// `activity.appServices` (D-31): the full level reads who is
    /// responsible for each process.
    var appServices = true

    // Seams: empty until their stage fills them.

    /// This run's closed panes (stage 3).
    var retired: [RetiredPane] = []
    /// Overterm's registries of its children by identity, each with what
    /// it is ("kubectl proxy", "the database tunnel"): stage 1's rule 2.
    var registered: [ActivityProcessID: String] = [:]
    /// This run's `OVERTERM_RUN` (stage 3, D-15).
    var run: String?
    /// What Activity stopped (stage 2), put in the background (stage 2),
    /// or was told to keep (stage 3).
    var stopped: Set<ActivityProcessID> = []
    var background: Set<ActivityProcessID> = []
    var kept: Set<ActivityProcessID> = []

    init(panes: [Pane] = [], appPID: pid_t = getpid()) {
        self.panes = panes
        self.appPID = appPID
    }

    /// The panes of `tab`, in the order the context lists them.
    func panes(of tab: UUID) -> [Pane] { panes.filter { $0.tab == tab } }
}
