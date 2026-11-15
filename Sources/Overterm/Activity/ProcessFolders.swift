import Darwin
import Foundation

/// Where the user's processes work (docs/design/activity/analysis.md, 7.2,
/// 7.7): `PROC_PIDVNODEPATHINFO`, read only where a level asks — a pane's
/// agent, a process in focus. The call fills a `vn_stat`, which asks the
/// file system, so a folder on a share that stopped answering (SMB, NFS,
/// sshfs, macFUSE) can hold it for the mount's timeout. So:
///
/// - the reads run on a queue of their own, one at a time, and nothing
///   waits for them: a tick asks, and takes what is known by then;
/// - a tick asks for at most so many (7.2: 200), the first it lists first;
/// - a read still going `deadline` after it began marks its process "its
///   folder isn't answering", skipped for `skipFor`; what waited behind it
///   is dropped, to be asked again, and nothing more is queued while it
///   hangs;
/// - a folder is kept `freshFor`; one asked `everyTick` (an agent's: a
///   worktree move changes it) is read again at each ask, the last one
///   answering meanwhile.
///
/// Times are the kernel's clock, so a test moves them. A read is by pid: a
/// pid reused between the ask and the read gives a stranger's folder to an
/// identity that has ended, which the next tick's table drops.
final class ProcessFolders: @unchecked Sendable {
    /// What is known of one process's folder.
    enum Folder: Hashable, Sendable {
        case path(String)
        /// None to read, or refused.
        case unknown
        /// A read outlived the deadline: skipped a while (7.2).
        case notAnswering
    }

    /// One process's folder, asked for.
    struct Request: Hashable, Sendable {
        let identity: ActivityProcessID
        /// Read again at every ask (an agent's), not kept `freshFor`.
        var everyTick = false
    }

    static let deadline: UInt64 = 200_000_000
    static let skipFor: UInt64 = 60_000_000_000
    static let freshFor: UInt64 = 10_000_000_000

    private let kernel: any ActivityKernel
    private let queue = DispatchQueue(label: "Overterm.activity.folders", qos: .userInitiated)
    /// A lock, and what a caller waiting for a read waits on
    /// (`folder(waitingFor:now:)`): a read ending wakes it.
    private let lock = NSCondition()
    // Under `lock`.
    /// Each folder known: what the read found, when it ended, and when it
    /// began — what a caller asking for one read since a moment checks.
    private var known: [ActivityProcessID: (folder: Folder, at: UInt64, began: UInt64)] = [:]
    private var waiting: [ActivityProcessID] = []
    private var reading: (identity: ActivityProcessID, since: UInt64)?
    private var draining = false
    private var skipped: [ActivityProcessID: UInt64] = [:]

    init(kernel: any ActivityKernel) {
        self.kernel = kernel
    }

    /// What is known of each requested folder now; those not fresh are
    /// asked for, at most `limit` of them, in the order requested — the
    /// rest when they are requested again. Never waits.
    func folders(_ requests: [Request], now: UInt64, limit: Int = .max) -> [ActivityProcessID: Folder] {
        lock.withLock {
            var asked = 0
            var hangs = false
            if let reading, now > reading.since + Self.deadline {
                hangs = true
                if skipped[reading.identity] == nil {
                    skipped[reading.identity] = now + Self.skipFor
                    known[reading.identity] = (.notAnswering, now, now)
                }
                // Behind a hung read nothing would come: asked again later.
                waiting.removeAll()
            }
            var found: [ActivityProcessID: Folder] = [:]
            for request in requests {
                let identity = request.identity
                if let until = skipped[identity] {
                    if now < until {
                        found[identity] = .notAnswering
                        continue
                    }
                    skipped[identity] = nil
                    known[identity] = nil
                }
                if let entry = known[identity] {
                    found[identity] = entry.folder
                    if !request.everyTick, now < entry.at + Self.freshFor { continue }
                }
                guard !hangs, asked < limit, reading?.identity != identity, !waiting.contains(identity) else { continue }
                waiting.append(identity)
                asked += 1
            }
            if !draining, !hangs, !waiting.isEmpty {
                draining = true
                queue.async { [self] in drain() }
            }
            return found
        }
    }

    /// Forget what is no longer in the process table.
    func prune(keeping live: Set<ActivityProcessID>) {
        lock.withLock {
            known = known.filter { live.contains($0.key) }
            skipped = skipped.filter { live.contains($0.key) }
            waiting.removeAll { !live.contains($0) }
        }
    }

    /// `identity`'s folder for a caller that answers at once — the old
    /// API's lookups (`ProcessInspector`): an agent's folder is what the
    /// overview, Sessions, an MCP confirmation and a drop ask of a tree —
    /// where a tick never waits.
    /// The one known, of any age; else its read is asked, and waited for
    /// `deadline` at most: one that doesn't come by then is nil, its
    /// process marked as not answering by the next ask, as a tick's would
    /// be. Never from this queue.
    func folder(waitingFor identity: ActivityProcessID, now: UInt64) -> Folder? {
        dispatchPrecondition(condition: .notOnQueue(queue))
        if let known = folders([Request(identity: identity)], now: now)[identity] { return known }
        let until = Date().addingTimeInterval(Double(Self.deadline) / 1e9)
        lock.lock()
        defer { lock.unlock() }
        while known[identity] == nil, skipped[identity] == nil, reading?.identity == identity || waiting.contains(identity) {
            guard lock.wait(until: until) else { break }
        }
        return known[identity]?.folder
    }

    /// `identity`'s folder as a read begun at `since` or later found it —
    /// an agent's MCP call's (`TerminalWindowController.paneCheckout`):
    /// where it works now, never the one known while a read goes on, which
    /// a tick and `folder(waitingFor:now:)` hand back. A read is asked
    /// unless one begun since is going or waiting, and waited for
    /// `deadline` at most: nil when none came by then, or none could be
    /// asked — nothing is queued behind a read that hangs. One skipped as
    /// not answering is that at once. Never from this queue.
    func folder(readSince since: UInt64, of identity: ActivityProcessID) -> Folder? {
        dispatchPrecondition(condition: .notOnQueue(queue))
        // Asked as an agent's is at each tick: queued unless it is being read.
        if folders([Request(identity: identity, everyTick: true)], now: kernel.uptime())[identity] == .notAnswering { return .notAnswering }
        let until = Date().addingTimeInterval(Double(Self.deadline) / 1e9)
        lock.lock()
        defer { lock.unlock() }
        while true {
            if let entry = known[identity], entry.began >= since { return entry.folder }
            if skipped[identity] != nil { return .notAnswering }
            let readNow = reading?.identity == identity
            // The read going began before: another after it.
            if readNow, let reading, reading.since < since, !waiting.contains(identity) { waiting.append(identity) }
            guard readNow || waiting.contains(identity) else { return nil }
            guard lock.wait(until: until) else { return nil }
        }
    }

    /// Whether a read is going or waiting: the tests wait for it.
    var isBusy: Bool { lock.withLock { draining } }

    /// The reads, one at a time, until none waits.
    private func drain() {
        while true {
            let next: (identity: ActivityProcessID, began: UInt64)? = lock.withLock {
                guard !waiting.isEmpty else {
                    draining = false
                    return nil
                }
                let identity = waiting.removeFirst()
                let began = kernel.uptime()
                reading = (identity, began)
                return (identity, began)
            }
            guard let (next, began) = next else { return }
            let path = kernel.workingDirectory(of: next.pid)
            let at = kernel.uptime()
            lock.withLock {
                // A read that outlived its deadline answers too late: the
                // skip stands its minute.
                if skipped[next] == nil { known[next] = (path.map(Folder.path) ?? .unknown, at, began) }
                reading = nil
                lock.broadcast()
            }
        }
    }
}
