import Foundation

/// A tab's agent as the census found it (docs/design/activity/analysis.md,
/// 7.8's `AgentOverviewModel`, `SessionsModel` and `MCPAsker` rows): the
/// first agent (`Agent.of`: Claude Code, Codex, opencode, pi, Gemini CLI) in its panes' trees, in the order asked —
/// each pane's slice of one snapshot, a lookup, where each reader walked
/// every pane's tree with a scan of its own (2.4 item 2).
package struct PaneAgent: Equatable, Sendable {
    package let identity: ActivityProcessID
    package let kind: Agent
    /// Its argv, masked as the census read it (9.3); "" when not read.
    package let command: String
    /// The session a Claude's `--resume <id>` or `-r <id>` picks back up,
    /// read off argv's raw words (`ProcessArguments.resumes`): Sessions'
    /// match, which the masked command can lose.
    package var resumes: String? = nil
    /// Where it works, when known.
    package let folder: String?

    /// The first agent among `tags`' panes, in that order, as `snapshot`
    /// read them: in each pane, the first of its placed processes — its
    /// tree, then those carrying its tag outside it (a `claude` in a tmux
    /// session started there, one nohup'd or setsid'd out of the tree) —
    /// that is an agent (`Agent.of`), as the scans these callers made
    /// found one by tag too. Display only, which `placed` is for (6.5). A
    /// pane the snapshot has for another tab (one moved since its context
    /// was built) isn't this tab's; an agent that has ended (a zombie) or
    /// doesn't run as the user alone isn't running
    /// (`ProcessInspector.running`), and a later one in the same pane is
    /// looked at. Its folder is the snapshot's, else `folder`'s answer.
    /// `only`: that kind's alone, anywhere in the pane — Sessions' Claude
    /// in a pane whose first agent is Codex. Pure.
    package static func first(
        _ tags: [String], tab: UUID, in snapshot: ActivitySnapshot, only: Agent? = nil,
        folder: (ActivityProcessID) -> String? = { _ in nil }
    ) -> PaneAgent? {
        for tag in tags {
            guard let slice = snapshot.pane(tag), slice.tab == tab else { continue }
            for identity in ProcessInspector.running(slice.placed, in: snapshot) {
                guard let process = snapshot.table.process(identity) else { continue }
                let facts = snapshot.facts[identity]
                let command = facts?.command ?? ""
                guard let kind = Agent.of(name: snapshot.name(of: identity) ?? process.shortName, argv: facts?.argvAgent, command: command),
                    only == nil || kind == only
                else { continue }
                let known: String?
                if case .path(let path)? = facts?.folder { known = path } else { known = folder(identity) }
                return PaneAgent(identity: identity, kind: kind, command: command, resumes: kind == .claude || kind == .opencode ? facts?.resumes : nil, folder: known)
            }
        }
        return nil
    }

    /// Each tab's first agent: one lookup in `census` at the light level of
    /// these tabs — the latest snapshot while it is a tick old, read them
    /// and read their panes with the pairings the context has now
    /// (`ActivitySnapshot.readPairings`), which a visible window's light
    /// tick keeps so; else one tick for all of them. `folders`: an agent's
    /// folder the census hasn't read yet is asked and waited for (200 ms at
    /// most, `ProcessFolders.folder(waitingFor:now:)`), as the overview and
    /// Sessions show it at once. Blocking: call off the main thread, on a
    /// GCD thread (7.7). The lookup reads the context the app's monitor
    /// last built: a caller on the main actor goes through `pairing`.
    package static func lookup(
        _ tabs: [(id: UUID, tags: [String])], census: ActivitySampler = .app, only: Agent? = nil, folders: Bool,
        within: UInt64 = ProcessInspector.freshness
    ) -> [UUID: PaneAgent] {
        lookupAndSnapshot(tabs, census: census, only: only, folders: folders, within: within).agents
    }

    /// `lookup`, with the snapshot it read: what `pairing` pairs a surface
    /// still waiting from.
    package static func lookupAndSnapshot(
        _ tabs: [(id: UUID, tags: [String])], census: ActivitySampler = .app, only: Agent? = nil, folders: Bool,
        within: UInt64 = ProcessInspector.freshness
    ) -> (agents: [UUID: PaneAgent], snapshot: ActivitySnapshot?) {
        guard !tabs.isEmpty else { return ([:], nil) }
        let demand = ActivityDemand(.light(tabs: Set(tabs.map(\.id))))
        let context = census.appContext
        let tags = tabs.flatMap(\.tags)
        guard
            let snapshot = census.lookup(
                within: within, demand: demand, context: context, answers: { $0.covers(demand) && $0.readPairings(of: tags, as: context) })
        else { return ([:], nil) }
        var found: [UUID: PaneAgent] = [:]
        for tab in tabs {
            found[tab.id] = first(tab.tags, tab: tab.id, in: snapshot, only: only) { identity in
                guard folders, case .path(let path)? = census.folders.folder(waitingFor: identity, now: census.kernel.uptime()) else { return nil }
                return path
            }
        }
        return (found, snapshot)
    }

    /// `lookup`, on a GCD thread (7.7: never a blocked Swift-concurrency
    /// thread), awaited — through `pairing`.
    @MainActor package static func read(
        _ tabs: [(id: UUID, tags: [String])], census: ActivitySampler = .app, folders: Bool,
        surfaces: SurfaceProcesses = .shared, monitor: ActivityMonitor = .shared
    ) async -> [UUID: PaneAgent] {
        await pairing(census: census, surfaces: surfaces, monitor: monitor) {
            lookupAndSnapshot(tabs, census: census, folders: folders)
        }
    }

    /// A census read for the main actor (7.7): `read` on a GCD thread,
    /// awaited, over the context `monitor` has with any rebuild waiting
    /// made first — a pane opened since is in it. A pane whose `login`
    /// isn't paired yet reads empty: the snapshot `read` made carries the
    /// app's children and the `login`s no pane claimed, as a landing
    /// tick's does, so a surface waiting is paired from it here, on the
    /// main actor, in microseconds (`SurfaceProcesses.pair`, a `login` held
    /// by a read on the census's kernel, as `followAgents` does), the context rebuilt, and `read` made once
    /// more — a drop in a new pane's first moments, an MCP call from a
    /// pane made while no window showed (no light tick). Only for the
    /// census `monitor` reads with: the app's surfaces are its panes.
    @MainActor package static func pairing<T: Sendable>(
        census: ActivitySampler, surfaces: SurfaceProcesses = .shared, monitor: ActivityMonitor = .shared,
        _ read: @escaping @Sendable () -> (T, ActivitySnapshot?)
    ) async -> T {
        let ours = census === monitor.sampler
        if ours { monitor.flushContext() }
        let (answer, snapshot) = await offMain(read)
        guard ours, let snapshot, surfaces.hasWaiting, surfaces.pair(snapshot, kernel: census.kernel) else { return answer }
        monitor.surfacesPaired()
        monitor.flushContext()
        return await offMain(read).0
    }

    /// `work` on a GCD thread, awaited (7.7).
    package nonisolated static func offMain<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { continuation.resume(returning: work()) }
        }
    }
}

extension ActivitySnapshot {
    /// Whether it read `tags`' panes with the pairings `context` has: one
    /// made before a pane's `login` was paired read that pane with none —
    /// an empty tree — and answers nothing of it once the pairing is made.
    /// A `login` gone from its table is no reason to read again.
    package func readPairings(of tags: [String], as context: ActivityContext) -> Bool {
        for tag in tags {
            guard let login = context.panes.first(where: { $0.tag == tag })?.login else { continue }
            if pane(tag)?.login != login, table.process(login) != nil { return false }
        }
        return true
    }
}
