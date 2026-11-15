import Darwin

/// A pane's set (docs/design/activity/analysis.md, 6.5): what a verb on a
/// pane or a tab as a whole acts on — Suspend Tab today; Suspend Pane,
/// Stop Its Tree, the close sheet's list and an agent's "own" scope with
/// their stages. Display is another thing: a slice's `placed` shows
/// whatever carries the pane's tag, and a tag goes further than the pane
/// (2.4, item 14) — tmux copies its first client's environment into its
/// global one, so a tmux server first started in the pane and every
/// session's shell, on tmux's own ptys and attached from anywhere, carry
/// it; so do ssh-agent, gpg-agent, a colima or limactl daemon, an app
/// started with `code .` and its helpers.
///
/// The set is the `login`'s descendants (parents linked by start time),
/// then the tagged outside every pane's tree with their descendants —
/// parents first, as the slice lists them — **less**, each with its
/// subtree:
/// - a process that ignores SIGHUP: it chose to outlive its terminal
///   (nohup), and is picked alone;
/// - one whose controlling terminal is set and isn't the pane's: tmux's
///   ptys, another terminal's sessions;
/// - one detached on purpose (rule 5): a session manager or daemon people
///   start on purpose, known by its executable, off the pane's terminal;
///   or, outside the pane's tree and off its terminal, one serving other
///   terminals — a child of its own leads one — as a tmux server does
///   whatever it is called;
/// - an app started from the pane (rule 7), off the pane's terminal — `code
///   .` detaches it: an app's own executable, `<X>.app/Contents/MacOS/…`,
///   in a bundle that isn't inside a checkout (a dev build's stays the
///   pane's). A toolchain inside a bundle — Xcode's `Contents/Developer`
///   (swift-build, clang), a framework's `Python.app`, Docker.app's CLI in
///   `Contents/Resources` — is no app, and the pane's foreground job on
///   its terminal never is one, whatever its path;
/// - what another pane's tree holds.
///
/// Pure: one snapshot, nothing read now.
struct ActivityPaneSet: Hashable, Sendable {
    /// Why a process the slice places isn't in the set.
    enum Exclusion: Hashable, Sendable {
        case ignoresHangup
        case otherTerminal
        case detachedOnPurpose
        case app
        case anotherPane
        /// Below one left out for one of the above.
        case underExcluded
    }

    /// The set, parents first: the tree, then the tagged.
    let members: [ActivityProcessID]
    /// What the slice places that the set leaves out, and why — in the
    /// slice's order.
    let leftOut: [(identity: ActivityProcessID, reason: Exclusion)]

    static func == (lhs: ActivityPaneSet, rhs: ActivityPaneSet) -> Bool {
        lhs.members == rhs.members && lhs.leftOut.map(\.identity) == rhs.leftOut.map(\.identity)
            && lhs.leftOut.map(\.reason) == rhs.leftOut.map(\.reason)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(members)
        for (identity, reason) in leftOut {
            hasher.combine(identity)
            hasher.combine(reason)
        }
    }

    /// Session managers and daemons people start on purpose (6.5 rule 5,
    /// with the engines' daemons of rule 6 that a pane starts: `colima
    /// start`, `limactl start`), by their executable's name.
    static let detachedNames: Set<String> = [
        "tmux", "screen", "ssh-agent", "gpg-agent", "caffeinate", "mosh-server", "colima", "limactl", "dtach", "abduco", "zellij",
    ]

    /// `slice`'s set in `snapshot`. `terminal`: the pane's pty as the
    /// context knows it (`ActivityContext.Pane.terminal`), else its
    /// `login`'s controlling terminal, else its tree's first one's.
    /// `checkouts`: the folders a `.app` inside of stays the pane's.
    init(_ slice: ActivityPaneSlice, in snapshot: ActivitySnapshot, terminal: dev_t? = nil, checkouts: [String] = []) {
        let table = snapshot.table
        var paneTerminal = terminal ?? slice.login.flatMap { table.process($0)?.terminal }
        for identity in slice.tree where paneTerminal == nil { paneTerminal = table.process(identity)?.terminal }
        var others = Set<ActivityProcessID>()
        for other in snapshot.panes where other.tag != slice.tag { others.formUnion(other.tree) }
        let inTree = Set(slice.tree)
        var excluded = Set<ActivityProcessID>()
        var members: [ActivityProcessID] = []
        var leftOut: [(ActivityProcessID, Exclusion)] = []
        for identity in slice.tree + slice.tagged {
            guard let process = table.process(identity) else { continue }
            var reason: Exclusion?
            if !inTree.contains(identity), others.contains(identity) {
                reason = .anotherPane
            } else if let parent = table.parent(of: identity), excluded.contains(parent.identity) {
                reason = .underExcluded
            } else {
                reason = Self.exclusion(
                    of: process, facts: snapshot.facts[identity], inTree: inTree.contains(identity), paneTerminal: paneTerminal,
                    children: table.children(of: identity), checkouts: checkouts)
            }
            if let reason {
                excluded.insert(identity)
                leftOut.append((identity, reason))
            } else {
                members.append(identity)
            }
        }
        self.members = members
        self.leftOut = leftOut
    }

    /// Why `process` itself is left out, if it is; its parent's reasons
    /// are the caller's.
    static func exclusion(
        of process: ActivityProcess, facts: ActivityFacts?, inTree: Bool, paneTerminal: dev_t?, children: [ActivityProcess], checkouts: [String]
    ) -> Exclusion? {
        if process.ignoresHangup { return .ignoresHangup }
        // Without the pane's terminal, nothing is said of terminals: every
        // process with one would read as another's.
        let offPane = paneTerminal.map { process.terminal != $0 } ?? !inTree
        if let paneTerminal, let own = process.terminal, own != paneTerminal { return .otherTerminal }
        if offPane, isDetachedOnPurpose(process, facts: facts) { return .detachedOnPurpose }
        if !inTree, offPane, let paneTerminal, children.contains(where: { $0.terminal != nil && $0.terminal != paneTerminal }) {
            return .detachedOnPurpose
        }
        if offPane, let path = facts?.path, let bundle = appBundle(of: path), !checkouts.contains(where: { isInside(bundle, $0) }) { return .app }
        return nil
    }

    /// A session manager or daemon by its executable's name; Emacs only as
    /// a daemon.
    static func isDetachedOnPurpose(_ process: ActivityProcess, facts: ActivityFacts?) -> Bool {
        let name = executableName(process, facts: facts)
        if detachedNames.contains(name) { return true }
        if name.lowercased() == "emacs", let command = facts?.command {
            return command.split(separator: " ").contains { $0 == "--daemon" || $0.hasPrefix("--daemon=") || $0.hasPrefix("--bg-daemon") || $0.hasPrefix("--fg-daemon") }
        }
        return false
    }

    /// Its executable's file name, else its name, else `p_comm`.
    static func executableName(_ process: ActivityProcess, facts: ActivityFacts?) -> String {
        if let path = facts?.path, let last = path.split(separator: "/").last { return String(last) }
        return facts?.name ?? process.shortName
    }

    /// The outermost `.app` on `path` when `path` is an app's own
    /// executable — `<X>.app/Contents/MacOS/<file>`, nothing of it inside a
    /// `.framework` nor a bundle's `Contents/Developer` or
    /// `Contents/Resources` (a toolchain, an interpreter, a CLI shipped in
    /// a bundle) —, else nil. A string walk over its components, bounded by
    /// them — no file system read.
    static func appBundle(of path: String) -> String? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        let count = parts.count
        guard count >= 4, parts[count - 2] == "MacOS", parts[count - 3] == "Contents", parts[count - 4].hasSuffix(".app") else { return nil }
        for (index, part) in parts.enumerated() {
            if part.hasSuffix(".framework") { return nil }
            if part == "Contents", index + 1 < count, parts[index + 1] == "Developer" || parts[index + 1] == "Resources" { return nil }
        }
        // The executable's own file name ending ".app" is no bundle.
        guard let index = parts.dropLast().firstIndex(where: { $0.hasSuffix(".app") }) else { return nil }
        return "/" + parts[...index].joined(separator: "/")
    }

    /// Whether `path` is `folder` or inside it.
    static func isInside(_ path: String, _ folder: String) -> Bool {
        var base = folder
        while base.count > 1, base.hasSuffix("/") { base.removeLast() }
        guard !base.isEmpty, base != "/" else { return false }
        return path == base || path.hasPrefix(base + "/")
    }
}
