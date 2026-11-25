import Combine
import Foundation

/// The census's readers (docs/design/activity/analysis.md, 7.1, 7.3, 7.9),
/// one monitor for the app. Each reader says what it wants read and how
/// often (`want`), keyed by its owner, and stops (`unwant`), as
/// `DockerUsageMonitor` counts its readers: one tick serves every reader,
/// at the fastest cadence any asks, two windows reading once; when nothing
/// wants it, the ticks stop. Readers ask only while they show (7.9) — a
/// window while it is visible, Tab Info while it is open, the page while
/// it is the overlay on screen.
///
/// What has to read while nothing shows doesn't want the ticks: an MCP
/// call, the close and quit sheets and the events of 6.9 each take a one-off
/// census (`census`), coalesced to at most one every 2 s, and an agent's
/// read is served from a snapshot at most one interval old (`forAgents`).
///
/// Snapshots come to the main actor as values, in one hop from the
/// sampler's queue. The context is rebuilt from the app's state on change,
/// debounced (`contextChanged`) — and first thing at a tick that finds a
/// rebuild waiting — and goes to each tick whole.
@MainActor
package final class ActivityMonitor: ObservableObject {
    /// The app's: over the app's census, which the old API's lookups read
    /// too (`ActivitySampler.app`).
    package static let shared = ActivityMonitor(sampler: .app)

    /// One reader's want: its owner held weakly, so a reader that goes
    /// without saying so stops wanting.
    private struct Want {
        weak var owner: AnyObject?
        var demand: ActivityDemand
        var every: Duration
    }

    package let sampler: ActivitySampler
    /// The latest snapshot, whoever's tick made it.
    @Published package private(set) var snapshot: ActivitySnapshot?
    /// The latest full one: what agents' reads and one-off censuses are
    /// served from.
    package private(set) var lastFull: ActivitySnapshot?
    /// `activity.interval` (7.3): the cadence a reader gets by default, and
    /// how old a snapshot an agent's read may be served.
    package var interval: Duration = .seconds(2)
    /// How long a burst of context changes must be quiet before the
    /// context is rebuilt…
    package var debounce: Duration = .milliseconds(100)
    /// …and the longest a burst that never quiets holds the rebuild back
    /// from its first change: a title an agent rewrites several times a
    /// second rebuilds it once a second, not at every change.
    package var debounceLimit: Duration = .seconds(1)
    /// One-off censuses come at most this often, ns (7.1).
    package nonisolated static let oneOffSpacing: UInt64 = 2_000_000_000

    private var wants: [ObjectIdentifier: Want] = [:]
    private var loop: Task<Void, Never>?
    private var generation = 0
    /// A tick on its way: what it reads, and its number among the
    /// monitor's.
    private struct Flight {
        let number: Int
        let task: Task<ActivitySnapshot?, Never>
        let demand: ActivityDemand
    }

    /// The tick on its way.
    private var running: Flight?
    private var flights = 0
    /// When the last tick began.
    private var lastTick: ContinuousClock.Instant?
    /// What each tick is given — and the sampler's lookups between ticks,
    /// which read the app's panes with it (`ActivitySampler.appContext`).
    package private(set) var context = ActivityContext() {
        didSet { sampler.appContext = context }
    }
    /// Builds the context from the app as it stands: set by the app.
    package var contextSource: (@MainActor () -> ActivityContext)?
    private var rebuild: Task<Void, Never>?
    private var rebuildGeneration = 0
    /// The latest change the waiting rebuild has heard of.
    private var lastChange: ContinuousClock.Instant?
    /// Ticks the in-flight guard spared (7.3): a tick asked for while one
    /// was on its way, and a round or a census that waited on it instead.
    package private(set) var skippedTicks = 0
    /// Times the context was rebuilt from `contextSource`.
    package private(set) var contextBuilds = 0
    /// Full ticks that landed, a one-off's too: what the page's "reads
    /// nothing while hidden" is checked by (10.3, check 10).
    package private(set) var fullTicks = 0
    /// One-off censuses that read (`census`): a close sheet's, an agent
    /// run's end, a Stop's watch — theirs whether or not anything shows.
    package private(set) var oneOffTicks = 0

    package init(sampler: ActivitySampler = ActivitySampler()) {
        self.sampler = sampler
    }

    // MARK: Readers

    /// What `owner` wants read, at most `every` apart (the interval by
    /// default): it replaces what `owner` wanted before. The first want
    /// starts the ticks. One that asks for a level or a tab the last tick
    /// didn't read, or for a faster cadence, gets a tick early — never
    /// sooner than `earliest` after the last one began, so a burst of
    /// wants (tabs restored, a window's tabs changing) makes one tick;
    /// processes newly in focus wait for the next tick, so a list's rows
    /// changing as it scrolls make none.
    package func want(_ owner: AnyObject, _ levels: ActivityLevel..., every: Duration? = nil) {
        let fastest = self.fastest
        wants[ObjectIdentifier(owner)] = Want(owner: owner, demand: ActivityDemand(levels), every: every ?? interval)
        var wider = demand
        wider.focus = []
        if loop == nil {
            start(after: .zero)
        } else if snapshot?.covers(wider) != true || self.fastest < fastest {
            stopTicks()
            start(after: soonest)
            earlyTicks += 1
        }
    }

    /// Wants that asked for an early tick.
    package private(set) var earlyTicks = 0

    /// An early tick waits this long after the last one began: rates need
    /// 250 ms anyway (7.3).
    package static let earliest: Duration = .milliseconds(250)

    /// How long until an early tick may come.
    private var soonest: Duration {
        guard let lastTick else { return .zero }
        let since = ContinuousClock.now - lastTick
        return since >= Self.earliest ? .zero : Self.earliest - since
    }

    /// `owner` reads no more. At the last reader the ticks stop; one on its
    /// way still lands.
    package func unwant(_ owner: AnyObject) {
        wants[ObjectIdentifier(owner)] = nil
        pruneOwners()
        if wants.isEmpty { stopTicks() }
    }

    /// Nothing wants it: the ticks and a waiting rebuild stop (quitting,
    /// the tests).
    package func stop() {
        wants = [:]
        stopTicks()
        dropRebuild()
    }

    package var isTicking: Bool { loop != nil }

    /// A tick is on its way.
    package var isSampling: Bool { running != nil }

    /// Every reader's want, merged.
    package var demand: ActivityDemand {
        wants.values.filter { $0.owner != nil }.reduce(ActivityDemand()) { $0.merged($1.demand) }
    }

    /// How often the ticks come: the fastest any reader asks, stretched to
    /// 5 s while the sampler says the Mac is busy (7.3).
    package var cadence: Duration {
        guard snapshot?.isStretched == true else { return fastest }
        return max(fastest, ActivityCadence.stretched)
    }

    private var fastest: Duration { wants.values.filter { $0.owner != nil }.map(\.every).min() ?? interval }

    private func pruneOwners() { wants = wants.filter { $0.value.owner != nil } }

    private func start(after delay: Duration) {
        generation += 1
        let generation = self.generation
        loop = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            while !Task.isCancelled {
                guard let self, await self.round() else { break }
            }
            self?.ended(generation)
        }
    }

    private func stopTicks() {
        loop?.cancel()
        loop = nil
        generation += 1
    }

    /// The loop ended on its own (its readers went): no loop now, unless a
    /// newer one runs.
    private func ended(_ generation: Int) {
        if generation == self.generation { loop = nil }
    }

    /// One round: a tick — or the one in flight, when it reads what the
    /// readers want — then the cadence's wait. False when nothing wants
    /// ticks any more.
    private func round() async -> Bool {
        pruneOwners()
        guard !wants.isEmpty else { return false }
        if let running {
            // Its round is the tick on its way (a one-off's, or the one a
            // wider want restarted the loop during); one that read less is
            // followed by the readers' own at once.
            skippedTicks += 1
            let served = await landed(running)
            guard served?.covers(demand) == true else { return true }
        } else {
            await tick()
        }
        try? await Task.sleep(for: cadence)
        return true
    }

    // MARK: Ticks

    /// A tick for what the readers want, now: the loop's, and the tests'
    /// one at a time. Nil while one is in flight — this one is skipped,
    /// nothing read — or when nothing is wanted.
    @discardableResult
    package func tick() async -> ActivitySnapshot? {
        guard running == nil else {
            skippedTicks += 1
            return nil
        }
        let demand = self.demand
        guard !demand.isEmpty else { return nil }
        return await sample(demand)
    }

    /// A one-off census (7.1, 7.9): an MCP call, a close or quit sheet, an
    /// event of 6.9 — whether or not anything wants the ticks, whether or
    /// not a window shows. It reads in full, so any one serves the next:
    /// one younger than `within` answers — by default 2 s, so they come at
    /// most one every 2 s — and one on its way is waited for. Like every
    /// tick, it takes a waiting context rebuild first, so it sees the app
    /// as it stands. Nil when the table can't be read: an older snapshot is
    /// never passed off as one, where a sheet or an agent counts on its age.
    package func census(within: UInt64 = ActivityMonitor.oneOffSpacing) async -> ActivitySnapshot? {
        while true {
            if let lastFull, age(of: lastFull) < within { return lastFull }
            guard let running else { break }
            skippedTicks += 1
            let served = await landed(running)
            if running.demand.full, let served { return served }
        }
        oneOffTicks += 1
        return await sample(demand.merged(ActivityDemand(.full)))
    }

    /// What an agent's read is answered from (7.3): the latest full
    /// snapshot while it is at most one interval old, else a census that no
    /// older one answers — not the one-offs' 2 s, two intervals at 1 s — at
    /// most one an interval for the app, however often agents call.
    package func forAgents() async -> ActivitySnapshot? {
        let interval = Self.nanoseconds(self.interval)
        if let lastFull, age(of: lastFull) <= interval { return lastFull }
        return await census(within: interval)
    }

    /// How old `snapshot` is, ns, on the sampler's clock.
    package func age(of snapshot: ActivitySnapshot) -> UInt64 {
        let now = sampler.kernel.uptime()
        return now > snapshot.time ? now - snapshot.time : 0
    }

    private func sample(_ demand: ActivityDemand) async -> ActivitySnapshot? {
        // A rebuild still waiting is made now: a tab opened and wanted in
        // the same turn has its panes in the early tick its want makes.
        flushContext()
        let sampler = self.sampler
        let context = self.context
        let task = Task.detached(priority: .userInitiated) { await sampler.tick(demand, context: context) }
        flights += 1
        let flight = Flight(number: flights, task: task, demand: demand)
        running = flight
        lastTick = .now
        return await landed(flight)
    }

    /// `flight`'s snapshot, once it has landed — and then it is no longer
    /// on its way and its snapshot is published, whichever of its waiters
    /// hears first. A task's waiters are resumed newest first, and a
    /// finished task's value is given without a suspension: a round that
    /// found the tick still on its way, and went round again before the
    /// tick's own `sample` heard, waited on it again at once, for ever, on
    /// the main actor.
    private func landed(_ flight: Flight) async -> ActivitySnapshot? {
        let snapshot = await flight.task.value
        if running?.number == flight.number { running = nil }
        if let snapshot {
            // Never an older tick's over a newer one's.
            if snapshot.tick > self.snapshot?.tick ?? 0 { self.snapshot = snapshot }
            if snapshot.demand.full, snapshot.tick > lastFull?.tick ?? 0 {
                lastFull = snapshot
                fullTicks += 1
            } else if snapshot.tick > lastFull?.tick ?? .max {
                keepLastFull(behind: snapshot)
            }
        }
        return snapshot
    }

    /// A newer light tick landed after the last full one: the ring is
    /// the sampler's, copied at every merge, and a full snapshot kept
    /// behind light ticks held a third copy the cap (`ActivityRing.copies`)
    /// doesn't count. Past every window that reads it — the one-offs' 2 s,
    /// an agent's interval, the page's two at opening — it is dropped; until
    /// then it shares the newer snapshot's ring, one copy fewer.
    private func keepLastFull(behind newer: ActivitySnapshot) {
        guard let last = lastFull else { return }
        if age(of: last) > max(Self.oneOffSpacing, 2 * Self.nanoseconds(interval)) {
            lastFull = nil
        } else {
            lastFull?.history = newer.history
        }
    }

    package nonisolated static func nanoseconds(_ duration: Duration) -> UInt64 {
        let (seconds, attoseconds) = duration.components
        guard seconds >= 0 else { return 0 }
        return UInt64(seconds) * 1_000_000_000 + UInt64(max(attoseconds, 0) / 1_000_000_000)
    }

    // MARK: The context

    /// What the context says changed — a pane opened or closed, a title, a
    /// pairing, a forward: rebuilt from `contextSource` once the changes
    /// have been quiet for `debounce`, at the latest `debounceLimit` after
    /// the first of them, and before then at the start of any tick. A sink
    /// calling this uses what it was emitted, not the object read back:
    /// `@Published` emits before the change.
    package func contextChanged() {
        let now = ContinuousClock.now
        lastChange = now
        guard rebuild == nil else { return }
        let generation = rebuildGeneration
        let limit = now + debounceLimit
        rebuild = Task { [weak self] in
            while let wait = self?.rebuildWait(generation, limit: limit) {
                guard wait > .zero else {
                    self?.rebuildContext()
                    return
                }
                try? await Task.sleep(for: wait)
                if Task.isCancelled { return }
            }
        }
    }

    /// How much longer the waiting rebuild waits: until its burst has been
    /// quiet for `debounce`, or `limit`. Nil when it was made or dropped
    /// meanwhile.
    private func rebuildWait(_ generation: Int, limit: ContinuousClock.Instant) -> Duration? {
        guard rebuildGeneration == generation, let lastChange else { return nil }
        return min(lastChange + debounce, limit) - .now
    }

    /// A snapshot that landed paired a surface with its `login` (7.7): the
    /// context is rebuilt, and while readers want ticks the next comes
    /// early — `earliest` after the last one began — so a new pane's tree,
    /// its ports and its agent are read then, not a cadence later.
    package func surfacesPaired() {
        contextChanged()
        guard loop != nil else { return }
        stopTicks()
        start(after: soonest)
        earlyTicks += 1
    }

    /// A rebuild waiting is made now: every tick's first step.
    package func flushContext() {
        guard rebuild != nil else { return }
        rebuildContext()
    }

    /// A rebuild is waiting for its debounce.
    package var hasPendingContext: Bool { rebuild != nil }

    /// The context as given, a waiting rebuild dropped: the tests'.
    package func setContext(_ context: ActivityContext) {
        dropRebuild()
        self.context = context
    }

    private func rebuildContext() {
        dropRebuild()
        guard let contextSource else { return }
        context = contextSource()
        contextBuilds += 1
    }

    private func dropRebuild() {
        rebuild?.cancel()
        rebuild = nil
        rebuildGeneration += 1
    }
}
