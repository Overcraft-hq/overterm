import Darwin

/// A process as the census knows it (docs/design/activity/analysis.md, 7.5):
/// its pid and when it started, in µs since 1970 (`p_starttime`). Pids come
/// round again within hours on a busy Mac (3.2), so a row, a fold, a
/// selection, a CPU baseline or a signal keyed by the pid alone would land
/// on whatever holds it next; the pair doesn't repeat. An `exec` keeps both
/// (the image changes, the process doesn't): a changed `shortName` says so.
package struct ActivityProcessID: Hashable, Comparable, Sendable, CustomStringConvertible {
    package let pid: pid_t
    /// µs since 1970.
    package let start: UInt64

    package init(pid: pid_t, start: UInt64) {
        self.pid = pid
        self.start = start
    }

    package init(pid: pid_t, start: timeval) {
        self.init(pid: pid, start: UInt64(max(start.tv_sec, 0)) * 1_000_000 + UInt64(max(start.tv_usec, 0)))
    }

    /// From `id`'s form, "pid:start"; nil for anything else.
    package init?(id: String) {
        let parts = id.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, let pid = pid_t(parts[0]), pid >= 0, let start = UInt64(parts[1]) else { return nil }
        self.init(pid: pid, start: start)
    }

    /// "pid:start": what rows, folds and the selection are keyed by.
    package var id: String { "\(pid):\(start)" }

    package var description: String { id }

    /// Older first; a pid breaks a tie.
    package static func < (lhs: ActivityProcessID, rhs: ActivityProcessID) -> Bool {
        (lhs.start, lhs.pid) < (rhs.start, rhs.pid)
    }
}

/// One process's structure from `KERN_PROC_ALL` (7.2): every user's, root's
/// included — the kernel refuses another user's usage, argv and sockets,
/// never this. Its CPU and memory fields are always zero on macOS, so none
/// is read here (`ProcessUsage` reads the user's).
package struct ActivityProcess: Hashable, Sendable {
    package let identity: ActivityProcessID
    /// `e_ppid` as the kernel says it. Not checked: `ProcessTable` links a
    /// child to that parent only when it started no later (6.5).
    package let parentPID: pid_t
    /// `e_pgid`.
    package let group: pid_t
    /// The controlling terminal (`e_tdev`); nil when it has none.
    package let terminal: dev_t?
    /// That terminal's foreground group (`e_tpgid`); nil without a terminal.
    package let terminalGroup: pid_t?
    /// Who the kernel's reads compare with: own or another's (3.2).
    package let effectiveUID: uid_t
    /// What `kill(2)` compares with, beside the saved one: a setuid process
    /// the user started keeps the user's here (every terminal's `login`).
    package let realUID: uid_t
    package let savedUID: uid_t
    /// `p_stat`: only stopped and zombie mean anything here — every live
    /// process reads SRUN (3.2).
    package let status: Int32
    package let flags: Flags
    /// `p_sigignore`: a process that ignores SIGHUP chose to outlive its
    /// terminal (6.5, nohup).
    package let ignoredSignals: UInt32
    /// `p_sigcatch`.
    package let caughtSignals: UInt32
    /// `p_nice`.
    package let nice: Int8
    /// `p_comm`: the executable's name cut at 16 bytes (`com.docker.backe`).
    /// A fallback name only, for a process not read in full yet; it changes
    /// at an `exec`, which keeps the identity.
    package let shortName: String

    package var pid: pid_t { identity.pid }

    /// What `p_flag` and `e_flag` say that the census uses.
    package struct Flags: OptionSet, Hashable, Sendable {
        package let rawValue: UInt8
        package init(rawValue: UInt8) { self.rawValue = rawValue }
        /// `P_TRANSLATED`: Intel code under Rosetta.
        package static let translated = Flags(rawValue: 1 << 0)
        /// `P_TRACED`: a debugger holds it — nothing is offered.
        package static let traced = Flags(rawValue: 1 << 1)
        /// `EPROC_SLEADER`: it leads its session (`setsid`).
        package static let sessionLeader = Flags(rawValue: 1 << 2)
        /// `EPROC_CTTY`: it has a controlling terminal.
        package static let controllingTerminal = Flags(rawValue: 1 << 3)
    }

    package var isStopped: Bool { status == SSTOP }
    package var isZombie: Bool { status == SZOMB }
    package var ignoresHangup: Bool { ignoredSignals & (1 << UInt32(SIGHUP - 1)) != 0 }

    /// Whether `uid` may read it: the effective uid decides, as the kernel
    /// decides reads (7.5).
    package func isOwn(by uid: uid_t) -> Bool { effectiveUID == uid }

    /// Whether it runs as `uid` and as nobody else — its effective, real
    /// and saved uids all `uid` —: what a signal asks (6.10). `kill(2)`
    /// lets the user signal a setuid program they started (its real uid
    /// theirs, 3.2) whether it runs as root now or has set its effective
    /// uid to theirs for a while, root kept as its saved uid to take back;
    /// and root's process running as the user for now passes `isOwn`.
    package func isWhollyOwn(by uid: uid_t) -> Bool { effectiveUID == uid && realUID == uid && savedUID == uid }
}

/// What the State column says (6.5). `KERN_PROC_ALL` gives T and Z; R
/// against S takes the running-thread count, which only the user's own
/// processes give.
package enum ActivityState: Hashable, Sendable {
    case running
    case sleeping
    case stopped
    case zombie
    /// Another user's live process: R or S can't be told.
    case unknown

    /// From kinfo's `p_stat` and, for the user's processes, `pti_numrunning`.
    package init(status: Int32, runningThreads: Int32?) {
        if status == SSTOP {
            self = .stopped
        } else if status == SZOMB {
            self = .zombie
        } else if let runningThreads {
            self = runningThreads > 0 ? .running : .sleeping
        } else {
            self = .unknown
        }
    }

    /// htop's letter; nothing for `unknown`.
    package var letter: String {
        switch self {
        case .running: "R"
        case .sleeping: "S"
        case .stopped: "T"
        case .zombie: "Z"
        case .unknown: ""
        }
    }
}

/// A process's code-signing status (`csops(CS_OPS_STATUS)`, else
/// Security.framework's dynamic status, 3.3): whether the binary is
/// macOS's own and whether the kernel hides its environment from other
/// processes (`CS_RESTRICT`: zsh, sh, git…, 3.9). Unknown flags are nil
/// where they are kept, never "macOS".
package struct ActivityCodeSigning: Hashable, Sendable {
    package let flags: UInt32

    package static let valid: UInt32 = 0x0000_0001
    package static let adhoc: UInt32 = 0x0000_0002
    package static let restrict: UInt32 = 0x0000_0800
    package static let runtime: UInt32 = 0x0001_0000
    package static let platformBinary: UInt32 = 0x0400_0000

    /// The kernel leaves its environment out of `KERN_PROCARGS2`.
    package var isRestricted: Bool { flags & Self.restrict != 0 }
    /// Part of the system: in the trust cache.
    package var isPlatformBinary: Bool { flags & Self.platformBinary != 0 }
    /// The hardened runtime.
    package var isHardened: Bool { flags & Self.runtime != 0 }
    package var isAdhoc: Bool { flags & Self.adhoc != 0 }
}

/// One sample of a process's usage (7.5): the user's processes only — the
/// kernel refuses another user's (3.3). Counters, read together with the
/// moment they were read, so a rate divides by the interval measured, never
/// the nominal one (App Nap coalesces timers, 3.9).
package struct ActivityUsage: Hashable, Sendable {
    /// When it was read: `CLOCK_UPTIME_RAW`, ns.
    package let time: UInt64
    /// User and system CPU time, ns.
    package let cpuTime: UInt64
    /// `ri_phys_footprint`: Activity Monitor's Memory.
    package let footprint: UInt64
    /// `pti_resident_size`: real memory.
    package let residentSize: UInt64
    /// `pti_threadnum`.
    package let threads: Int32
    /// `pti_numrunning`: R against S.
    package let runningThreads: Int32
    /// `pti_priority`: a plain number — never read as "background" (3.9).
    package let priority: Int32
    /// `ri_energy_nj`; nil where the kernel's `rusage` has none.
    package let energy: UInt64?
    /// `ri_pkg_idle_wkups`: Activity Monitor's Idle Wake Ups.
    package let idleWakeups: UInt64
    /// `ri_interrupt_wkups`: the detail's only.
    package let interruptWakeups: UInt64
    package let diskRead: UInt64
    package let diskWritten: UInt64
}

/// A process's rates between two of its samples (7.5), over the interval
/// measured between them, at least `ProcessUsage.minimumInterval`.
package struct ActivityRates: Hashable, Sendable {
    /// ns between the samples.
    package let interval: UInt64
    /// 100 is one core, as htop and Tab Info count.
    package let cpuPercent: Double
    /// W, an estimate; nil without an energy counter.
    package let energy: Double?
    package let idleWakeupsPerSecond: Double
    package let interruptWakeupsPerSecond: Double
    /// Bytes a second.
    package let diskReadPerSecond: Double
    package let diskWrittenPerSecond: Double
}
