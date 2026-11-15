import Foundation

/// A tab's agent as the census found it (docs/design/activity/analysis.md,
/// 7.8's `AgentOverviewModel`, `SessionsModel` and `MCPAsker` rows): the
/// first Claude Code or Codex in its panes' trees, in the order asked —
/// each pane's slice of one snapshot, a lookup, where each reader walked
/// every pane's tree with a scan of its own (2.4 item 2).
struct PaneAgent: Equatable, Sendable {
    let identity: ActivityProcessID
    let kind: Agent
    /// Its argv, masked as the census read it (9.3); "" when not read.
    let command: String
    /// Where it works, when known.
    let folder: String?

    /// The first agent among `tags`' panes, in that order, as `snapshot`
    /// read them. A pane the snapshot has for another tab (one moved since
    /// its context was built) isn't this tab's; an agent that has ended (a
    /// zombie) or doesn't run as the user alone isn't running
    /// (`ProcessInspector.running`). Its folder is the snapshot's, else
    /// `folder`'s answer. Pure.
    static func first(
        _ tags: [String], tab: UUID, in snapshot: ActivitySnapshot, folder: (ActivityProcessID) -> String? = { _ in nil }
    ) -> PaneAgent? {
        for tag in tags {
            guard let slice = snapshot.pane(tag), slice.tab == tab, let identity = slice.agent, let kind = slice.agentKind,
                !ProcessInspector.running([identity], in: snapshot).isEmpty
            else { continue }
            let facts = snapshot.facts[identity]
            let known: String?
            if case .path(let path)? = facts?.folder { known = path } else { known = folder(identity) }
            return PaneAgent(identity: identity, kind: kind, command: facts?.command ?? "", folder: known)
        }
        return nil
    }

    /// Each tab's first agent: one lookup in `census` at the light level of
    /// these tabs — the latest snapshot while it is a tick old and read
    /// them, which a visible window's light tick keeps so; else one tick
    /// for all of them. `folders`: an agent's folder the census hasn't
    /// read yet is asked and waited for (200 ms at most,
    /// `ProcessFolders.folder(waitingFor:now:)`), as the overview and
    /// Sessions show it at once. Blocking: call off the main thread, on a
    /// GCD thread (7.7). The lookup reads the context the app's monitor
    /// last built: a caller on the main actor flushes a rebuild waiting
    /// first (`ActivityMonitor.flushContext`).
    static func lookup(
        _ tabs: [(id: UUID, tags: [String])], census: ActivitySampler = .app, folders: Bool,
        within: UInt64 = ProcessInspector.freshness
    ) -> [UUID: PaneAgent] {
        guard !tabs.isEmpty else { return [:] }
        let demand = ActivityDemand(.light(tabs: Set(tabs.map(\.id))))
        guard let snapshot = census.lookup(within: within, demand: demand, context: census.appContext, answers: { $0.covers(demand) })
        else { return [:] }
        var found: [UUID: PaneAgent] = [:]
        for tab in tabs {
            found[tab.id] = first(tab.tags, tab: tab.id, in: snapshot) { identity in
                guard folders, case .path(let path)? = census.folders.folder(waitingFor: identity, now: census.kernel.uptime()) else { return nil }
                return path
            }
        }
        return found
    }

    /// `lookup`, on a GCD thread (7.7: never a blocked Swift-concurrency
    /// thread), awaited.
    nonisolated static func read(
        _ tabs: [(id: UUID, tags: [String])], census: ActivitySampler = .app, folders: Bool
    ) async -> [UUID: PaneAgent] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: lookup(tabs, census: census, folders: folders))
            }
        }
    }
}
