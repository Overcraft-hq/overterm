import Darwin

/// The user's processes' usage (docs/design/activity/analysis.md, 7.2,
/// 7.5): `PROC_PIDTASKALLINFO` and `proc_pid_rusage(RUSAGE_INFO_V6)`, 2.4 ms
/// for about 860 — the footprint (Activity Monitor's Memory), real memory,
/// threads, running threads, priority, energy, idle wake-ups, disk. Another
/// user's process is refused by the kernel (3.3): its numbers are "—".
///
/// Rates divide by the interval measured between two samples on
/// `CLOCK_UPTIME_RAW` — App Nap coalesces timers, so a nominal interval
/// lies — and only over at least `minimumInterval`: two readers 10 ms
/// apart would read noise. An identity's first sample has no rate: "—",
/// never 0.
enum ProcessUsage {
    /// 250 ms (7.3).
    static let minimumInterval: UInt64 = 250_000_000

    /// `pid`'s usage now; nil when refused or gone. A plain synchronous call
    /// for the sampler's queue.
    static func read(_ pid: pid_t, kernel: some ActivityKernel) -> ActivityUsage? {
        kernel.usage(of: pid)
    }

    /// What changed from `previous` to `current`, per second; nil when
    /// there is no `previous` (a first sample), or less than
    /// `minimumInterval` lies between them, or a counter went back (not the
    /// same process's).
    static func rates(from previous: ActivityUsage?, to current: ActivityUsage) -> ActivityRates? {
        guard let previous, current.time > previous.time, current.time - previous.time >= minimumInterval,
            current.cpuTime >= previous.cpuTime, current.idleWakeups >= previous.idleWakeups,
            current.interruptWakeups >= previous.interruptWakeups, current.diskRead >= previous.diskRead,
            current.diskWritten >= previous.diskWritten
        else { return nil }
        let interval = current.time - previous.time
        let seconds = Double(interval) / 1e9
        var energy: Double?
        if let now = current.energy, let then = previous.energy, now >= then {
            // nJ over ns: W.
            energy = Double(now - then) / Double(interval)
        }
        return ActivityRates(
            interval: interval, cpuPercent: Double(current.cpuTime - previous.cpuTime) / Double(interval) * 100, energy: energy,
            idleWakeupsPerSecond: Double(current.idleWakeups - previous.idleWakeups) / seconds,
            interruptWakeupsPerSecond: Double(current.interruptWakeups - previous.interruptWakeups) / seconds,
            diskReadPerSecond: Double(current.diskRead - previous.diskRead) / seconds,
            diskWrittenPerSecond: Double(current.diskWritten - previous.diskWritten) / seconds)
    }
}

/// Each live identity's last sample and the rates last published for it
/// (7.5). Baselines are kept for every identity still running and pruned
/// only of identities that are gone from the latest process table — never
/// of what a reader didn't ask about this time: Tab Info's 0% in a split
/// tab came from a scan that kept only its own tree's baselines, so two
/// panes read alternately evicted each other's (2.4, item 1).
///
/// A sample less than `ProcessUsage.minimumInterval` after the baseline
/// leaves the baseline where it was and answers with the rates last
/// published, so a one-shot read soon after a tick neither reads noise nor
/// shortens the next tick's interval. A value for the sampler's queue.
struct UsageBaselines: Sendable {
    private var samples: [ActivityProcessID: ActivityUsage] = [:]
    private var published: [ActivityProcessID: ActivityRates] = [:]

    /// How many identities have a baseline.
    var count: Int { samples.count }

    /// The rates to show for `identity` after `usage`: new ones over the
    /// interval since its baseline, else the last published; nil for its
    /// first sample.
    mutating func record(_ usage: ActivityUsage, for identity: ActivityProcessID) -> ActivityRates? {
        guard let baseline = samples[identity] else {
            samples[identity] = usage
            return nil
        }
        if usage.time < baseline.time + ProcessUsage.minimumInterval { return published[identity] }
        samples[identity] = usage
        guard let rates = ProcessUsage.rates(from: baseline, to: usage) else {
            // A counter went back, or the clock: begin again from here.
            published[identity] = nil
            return nil
        }
        published[identity] = rates
        return rates
    }

    /// The rates last published for `identity`, without a new sample.
    func rates(of identity: ActivityProcessID) -> ActivityRates? { published[identity] }

    /// Forget what is no longer in the process table — and only that.
    mutating func prune(keeping live: Set<ActivityProcessID>) {
        samples = samples.filter { live.contains($0.key) }
        published = published.filter { live.contains($0.key) }
    }
}
