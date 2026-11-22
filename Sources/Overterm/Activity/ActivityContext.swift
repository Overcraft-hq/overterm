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
package struct ActivityContext: Hashable, Sendable {
    /// One terminal pane.
    package struct Pane: Hashable, Sendable {
        /// `TerminalView.processTag`, its shell's `OVERTERM_TAB_ID`: what a
        /// process that left the pane's tree (nohup, disown) still carries.
        package let tag: String
        /// Its tab (`Tab.id`).
        package let tab: UUID
        /// Its window's number; nil before it has one.
        package var window: Int?
        /// The `login` libghostty spawned for it, as the main actor paired
        /// it from a census's children of the app (`SurfaceProcesses`,
        /// 7.7); nil until then. Its descendants are the pane's tree.
        package var login: ActivityProcessID?
        /// Its pty's device (`ghostty_surface_tty_name`'s `st_rdev`,
        /// `TerminalView.terminalDevice`): what its processes carry as their
        /// controlling terminal (7.10); nil until libghostty has named it.
        package var terminal: dev_t?
        /// Its title, masked as a command (`ActivityText.title`).
        package var title = ""
        /// The checkout its tab shows (`Tab.checkoutSource`), and that
        /// checkout's branch.
        package var checkout: String?
        package var branch: String?
        /// The agent its tab was opened for (`Tab.agent`); one typed into
        /// a plain tab is found in its tree (`ActivityPaneSlice.agent`).
        package var agent: Agent?

        package init(
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
    package struct PublishedPort: Hashable, Sendable {
        package let container: String
        /// Its compose project, when it has one.
        package var project: String?
        /// The host address it is published on (`0.0.0.0`, `127.0.0.1`, `::`).
        package let address: String
        package let port: UInt16
        /// "tcp" or "udp".
        package let proto: String

        package init(container: String, project: String? = nil, address: String, port: UInt16, proto: String) {
            self.container = container
            self.project = project
            self.address = address
            self.port = port
            self.proto = proto
        }
    }

    /// A Kubernetes port-forward (`KubeForwards`): kubectl is Overterm's
    /// child, so its socket is the forward's, never the tab's.
    package struct Forward: Hashable, Sendable {
        /// kubectl's; 0 while it restarts.
        package let pid: pid_t
        package let port: UInt16
        /// What it forwards to, as its pill says.
        package let target: String
        /// The tab that started it.
        package var tab: UUID?
        /// It serves https: its URL says so (6.8, Open).
        package var https = false

        package init(pid: pid_t, port: UInt16, target: String, tab: UUID? = nil, https: Bool = false) {
            self.pid = pid
            self.port = port
            self.target = target
            self.tab = tab
            self.https = https
        }
    }

    /// A database tunnel (`SSHTunnel`): ssh's local port.
    package struct Tunnel: Hashable, Sendable {
        package let pid: pid_t
        package let port: UInt16
        /// The connection's name.
        package let name: String

        package init(pid: pid_t, port: UInt16, name: String) {
            self.pid = pid
            self.port = port
            self.name = name
        }
    }

    /// A pane this run closed (stage 3, 6.9): a process that still carries
    /// its tag was left behind by it.
    package struct RetiredPane: Hashable, Sendable {
        package let pane: Pane
        package let closed: Date
    }

    package var panes: [Pane] = []
    /// The app's pid: its children that aren't panes' `login`s are
    /// Overterm's helpers (6.5, rule 2). `getpid()`; a fake's in the tests.
    package var appPID: pid_t = getpid()

    /// What a local engine's running containers publish.
    package var published: [PublishedPort] = []
    package var forwards: [Forward] = []
    package var tunnels: [Tunnel] = []
    /// The MCP bridge's port (`BrowserBridge.shared.port`): Overterm's own listener.
    package var bridgePort: UInt16?
    /// `activity.appServices` (D-31): the full level reads who is
    /// responsible for each process.
    package var appServices = true

    // Left Behind's (6.9: `LeftBehindLedger`) and Activity's own holds.

    /// This run's closed panes (6.9), oldest first.
    package var retired: [RetiredPane] = []
    /// The agents' runs that have ended in live panes, their windows from
    /// the census (6.9, rule 8).
    package var agentRuns: [ActivityAgentRun] = []
    /// Overterm's registries of its children by identity, each with what
    /// it is ("kubectl proxy", "the database tunnel"): stage 1's rule 2.
    package var registered: [ActivityProcessID: String] = [:]
    /// This run's `OVERTERM_RUN` (stage 3, D-15).
    package var run: String?
    /// What Activity stopped (stage 2), put in the background (stage 2),
    /// or was told to keep (stage 3).
    package var stopped: Set<ActivityProcessID> = []
    package var background: Set<ActivityProcessID> = []
    package var kept: Set<ActivityProcessID> = []

    package init(panes: [Pane] = [], appPID: pid_t = getpid()) {
        self.panes = panes
        self.appPID = appPID
    }

    /// The panes of `tab`, in the order the context lists them.
    package func panes(of tab: UUID) -> [Pane] { panes.filter { $0.tab == tab } }
}
