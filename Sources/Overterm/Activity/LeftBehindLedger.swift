import Combine
import Foundation

/// What Left Behind remembers for the app (docs/design/activity/analysis.md,
/// 6.9): the panes this run closed, the agents' runs the census has seen in
/// each pane, and what the person kept. Memory only — the kept identities
/// are written by `ActivityPersisted` (D-29) — and nothing of a process
/// but its identity and the pane's own words.
///
/// No polling: the agents' runs follow whatever snapshots land (the light
/// tick reads every visible tab's panes); 2 s after a run ends, one
/// one-off census says what it left, and the tab is told.
@MainActor
package final class LeftBehindLedger: ObservableObject {
    package static let shared = LeftBehindLedger()

    /// The panes this run closed, oldest first.
    @Published package private(set) var retired: [ActivityContext.RetiredPane] = []
    /// What the person kept: Keep, or unticked in a close sheet (6.9).
    @Published package private(set) var kept: Set<ActivityProcessID> = []
    /// What each tab's ended agent runs left, as the last census after the
    /// run found it: the overview's "left N behind" (6.9).
    @Published package private(set) var leftByTab: [UUID: [LeftBehindItem]] = [:]
    package private(set) var runs = ActivityAgentRuns()

    /// A run ended and left processes in a tab still open: its note (D-17).
    package var onLeft: @MainActor (_ tab: UUID, _ run: ActivityAgentRun, _ left: [LeftBehindItem]) -> Void = { _, _, _ in }
    /// The checkouts the app knows: an app inside one stays a pane's.
    package var checkouts: @MainActor () -> [String] = { [] }
    /// The kept set changed: written down (D-29).
    package var keptChanged: @MainActor (Set<ActivityProcessID>) -> Void = { _ in }

    package static let kept = 256
    /// How long after an agent's end its leftovers are read: SIGHUP and the
    /// shells' own exits have had their effect.
    package static let settle: Duration = .seconds(2)

    /// How often a full snapshot sweeps the kept set.
    package static let pruneSpacing: TimeInterval = 60
    private var lastPrune = Date.distantPast
    private var snapshots: AnyCancellable?
    private let monitor: ActivityMonitor

    package init(monitor: ActivityMonitor = .shared) {
        self.monitor = monitor
    }

    /// Follows the census's snapshots: each one's panes' agents.
    package func start() {
        guard snapshots == nil else { return }
        // @Published emits before it changes: the emitted value.
        snapshots = monitor.$snapshot.compactMap { $0 }
            .sink { [weak self] snapshot in self?.observe(snapshot) }
    }

    /// One snapshot's panes: a run that ended is read again in 2 s. A full
    /// one also sweeps the kept set of what ended, at most once a minute.
    package func observe(_ snapshot: ActivitySnapshot) {
        if snapshot.demand.full, snapshot.date.timeIntervalSince(lastPrune) >= Self.pruneSpacing {
            lastPrune = snapshot.date
            prune(in: snapshot)
        }
        let gap = ActivityMonitor.nanoseconds(monitor.interval) / 1_000 * 2 + 1_000_000
        let ended = runs.observe(snapshot, gap: max(gap, ActivityAgentRuns.gap))
        guard !ended.isEmpty else { return }
        monitor.contextChanged()
        for run in ended {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: Self.settle)
                await self?.settled(run)
            }
        }
    }

    /// What `run` left, read by a one-off census: the tab told when it is
    /// still open and something was left.
    private func settled(_ run: ActivityAgentRun) async {
        guard let snapshot = await monitor.census() else { return }
        let left = LeftBehind.left(by: run, in: snapshot, checkouts: checkouts(), kept: kept)
        let merged = LeftBehind.merged(leftByTab[run.tab] ?? [], left, in: snapshot, limit: Self.kept)
        leftByTab[run.tab] = merged.isEmpty ? nil : merged
        guard !left.isEmpty, snapshot.pane(run.tag) != nil else { return }
        onLeft(run.tab, run, left)
    }

    /// A command finished in the pane `tag`: when an agent was running
    /// there, one census 2 s later says whether it went — a window off
    /// screen has no tick to say so (6.9). It publishes, so `observe` takes it.
    package func commandFinished(in tag: String) {
        guard runs.running[tag] != nil else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.settle)
            guard let self, self.runs.running[tag] != nil else { return }
            _ = await self.monitor.census()
        }
    }

    /// The overview's count for `tab`, kept to what still runs in `snapshot`.
    package func leftCount(of tab: UUID, in snapshot: ActivitySnapshot?) -> Int {
        guard let left = leftByTab[tab] else { return 0 }
        guard let snapshot else { return left.count }
        return left.filter { snapshot.table.process($0.identity).map { !$0.isZombie } ?? false }.count
    }

    /// A pane closes: what still carries its tag was left behind by it.
    package func retire(_ pane: ActivityContext.Pane, at date: Date = Date()) {
        retired.append(ActivityContext.RetiredPane(pane: pane, closed: date))
        if retired.count > Self.kept { retired.removeFirst(retired.count - Self.kept) }
        runs.forget(tag: pane.tag)
        monitor.contextChanged()
    }

    /// The person kept these (Keep, a close sheet's unticked rows): never
    /// in a bulk Stop, never Left Behind again, for their life.
    package func keep(_ identities: some Sequence<ActivityProcessID>) {
        let before = kept
        kept.formUnion(identities)
        guard kept != before else { return }
        monitor.contextChanged()
        keptChanged(kept)
    }

    /// The kept identities as a launch read them back (D-29), swept of
    /// what ended.
    package func restoreKept(_ identities: Set<ActivityProcessID>) {
        guard !identities.isEmpty else { return }
        kept.formUnion(identities)
        monitor.contextChanged()
    }

    /// What ended goes from the kept set.
    package func prune(in snapshot: ActivitySnapshot) {
        let live = kept.filter { snapshot.table.process($0).map { !$0.isZombie } ?? false }
        guard live != kept else { return }
        kept = live
        keptChanged(kept)
    }

    /// The context's part (7.1): retired panes, ended runs, kept.
    package func fill(_ context: inout ActivityContext) {
        context.retired = retired
        context.agentRuns = runs.ended
        context.kept = kept
    }
}
