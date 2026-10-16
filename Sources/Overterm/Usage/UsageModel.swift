import AppKit
import Combine
import Foundation

/// What the usage pane and the strip's chip show, and when it is read.
///
/// Two tiers, because they cost different amounts. The **meters** are a
/// file Claude Code keeps and the end of one Codex rollout: cheap, and the
/// chip in the strip wants them whether or not the pane is open. The
/// **spend** walks every log touched in the window: only while the pane is
/// open, as the inbox's column only polls while it shows.
@MainActor
final class UsageModel: ObservableObject {
    @Published private(set) var providers: [UsageSnapshot] = []
    @Published private(set) var isRefreshing = false
    /// Set by the window when the pane is the one showing.
    @Published var visible = false {
        didSet { if visible != oldValue { refresh() } }
    }
    @Published var scope: UsageScope = .today {
        didSet { if scope != oldValue { refresh() } }
    }

    /// How often the cheap half is re-read while the app is in front;
    /// openusage refreshes every five minutes and these files move less
    /// often than that.
    static let meterInterval: TimeInterval = 120
    private var poll: Timer?
    private let scanner = UsageTailScanner()
    /// A read still running: the next tick skips rather than piling up
    /// behind it (AgentOverviewModel's rule).
    private var reading = false
    /// Asked again while a read was running.
    private var again = false

    /// Whether anything was found on this Mac to track at all.
    var isAvailable: Bool { !providers.isEmpty }

    /// What the strip's gauge shows: the session window that is fullest,
    /// over every provider.
    func chipMeter(_ now: Date = Date()) -> (snapshot: UsageSnapshot, meter: UsageMeter)? {
        let found = providers.compactMap { snapshot in snapshot.chipMeter(now).map { (snapshot: snapshot, meter: $0) } }
        return found.filter(\.meter.isSession).max { $0.meter.usedPercent < $1.meter.usedPercent }
            ?? found.max { $0.meter.usedPercent < $1.meter.usedPercent }
    }

    func start() {
        refresh()
        poll?.invalidate()
        poll = Timer.scheduledTimer(withTimeInterval: Self.meterInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                // Nobody is looking while the app is in the background, and
                // these reads are not free (pullRequestPoll does the same).
                guard NSApplication.shared.isActive || AppEnvironment.isIsolated else { return }
                self?.refresh()
            }
        }
    }

    func stop() {
        poll?.invalidate()
        poll = nil
    }

    /// Re-reads: the meters always, the spend only while the pane shows.
    /// The agents' own usage command runs first — every ten minutes, and
    /// at once when the ↻ button asks (`force`) — so the pane can never
    /// say something `/usage` doesn't.
    func refresh(force: Bool = false) {
        guard !reading else {
            again = true
            return
        }
        reading = true
        isRefreshing = true
        let scope = scope
        let scanner = scanner
        let withCost = visible && Settings.shared.usageCost
        let asking = Settings.shared.usageAsk
        Task { [weak self] in
            let read = await withCheckedContinuation { (continuation: CheckedContinuation<[UsageSnapshot], Never>) in
                DispatchQueue.global(qos: .utility).async {
                    // The agent's own command, so the pane and `/usage`
                    // cannot disagree; it writes its answer where the
                    // structured figures are read from.
                    ClaudeUsageSource.refresh(asking: asking, force: force)
                    var found = [
                        ClaudeUsageSource.snapshot(scope: scope, scanner: scanner, cost: withCost),
                        CodexUsageSource.snapshot(scope: scope, scanner: scanner, cost: withCost),
                    ].compactMap { $0 }
                    // The rest are listed when they are installed, with
                    // what can honestly be said about them: their numbers
                    // are on their own servers, behind a login we don't
                    // have and won't ask for.
                    found += UsageSnapshot.Provider.allCases.compactMap { provider -> UsageSnapshot? in
                        guard let home = provider.home, FileManager.default.fileExists(atPath: home.path) else { return nil }
                        return UsageSnapshot(provider: provider, note: provider.elsewhere)
                    }
                    continuation.resume(returning: found)
                }
            }
            guard let self else { return }
            self.providers = read
            self.reading = false
            self.isRefreshing = false
            if self.again {
                self.again = false
                self.refresh()
            }
        }
    }
}
