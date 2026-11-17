import AppKit
import Combine
import Darwin
import Foundation

/// What Activity keeps across a crash (docs/design/activity/analysis.md,
/// 6.9, D-29): the identities the person kept and those Activity stopped —
/// pid and start µs, nothing else: no name, no argv, no path, nothing a
/// reader could learn from. One file under the support folder, 0600,
/// swept of dead identities at launch. The next launch offers to resume
/// what Activity stopped, and leaves kept processes out of its Stop All.
struct ActivityPersisted: Codable, Hashable, Sendable {
    struct Identity: Codable, Hashable, Sendable {
        let pid: Int32
        let start: UInt64

        init(_ identity: ActivityProcessID) {
            pid = identity.pid
            start = identity.start
        }

        var identity: ActivityProcessID { ActivityProcessID(pid: pid, start: start) }
    }

    var kept: [Identity] = []
    var stopped: [Identity] = []

    static let fileName = "activity-identities.json"
    /// More than this is no person's doing: the rest is dropped.
    static let limit = 1_024

    init(kept: Set<ActivityProcessID> = [], stopped: Set<ActivityProcessID> = []) {
        self.kept = kept.sorted().prefix(Self.limit).map(Identity.init)
        self.stopped = stopped.sorted().prefix(Self.limit).map(Identity.init)
    }

    var keptIdentities: Set<ActivityProcessID> { Set(kept.map(\.identity)) }
    var stoppedIdentities: Set<ActivityProcessID> { Set(stopped.map(\.identity)) }
    var isEmpty: Bool { kept.isEmpty && stopped.isEmpty }

    /// Only what still runs: its pid holds the same start. Stopped ones only
    /// while they are stopped — one continued elsewhere is no longer
    /// Activity's to resume. Pure.
    func swept(_ process: (ActivityProcessID) -> ActivityProcess?) -> ActivityPersisted {
        func alive(_ identity: ActivityProcessID) -> ActivityProcess? {
            guard let found = process(identity), found.identity == identity, !found.isZombie else { return nil }
            return found
        }
        return ActivityPersisted(
            kept: Set(kept.map(\.identity).filter { alive($0) != nil }),
            stopped: Set(stopped.map(\.identity).filter { alive($0)?.isStopped == true }))
    }

    /// Read from `url`; empty when there is none, it can't be read, isn't
    /// this user's own plain file, or isn't ours.
    static func load(from url: URL) -> ActivityPersisted {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_size < 1 << 20,
            let data = try? Data(contentsOf: url), let read = try? JSONDecoder().decode(ActivityPersisted.self, from: data)
        else { return ActivityPersisted() }
        return ActivityPersisted(kept: read.keptIdentities, stopped: read.stoppedIdentities)
    }

    /// Written to `url`, 0600, never through a link; removed when empty.
    @discardableResult
    func save(to url: URL) -> Bool {
        if isEmpty {
            unlink(url.path)
            return true
        }
        guard let data = try? JSONEncoder().encode(self) else { return false }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(url.path, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        fchmod(fd, 0o600)
        let written = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        return written == data.count
    }
}

/// The file's writer and the launch's reader (D-29): each change to the
/// kept set or to what Activity holds stopped is written at once, off the
/// main thread; at launch the file is read back, swept by one census.
@MainActor
final class ActivityPersistence {
    static let shared = ActivityPersistence()

    var url: URL { AppEnvironment.supportDirectory.appendingPathComponent(ActivityPersisted.fileName) }
    private var cancellables: Set<AnyCancellable> = []
    private let queue = DispatchQueue(label: "overterm.activity.persisted", qos: .utility)

    /// What the last launch's file said, swept; nil until read.
    private(set) var restored: ActivityPersisted?
    /// The earlier run's file as `start` found it, until `restore` sweeps
    /// it: every write until then keeps it, so a Keep or a Suspend before
    /// the launch's census never replaces what D-29 exists to keep.
    private(set) var unrestored: ActivityPersisted?
    private var ledger: LeftBehindLedger = .shared
    private var held: ActivityHeld = .shared

    /// Follows the kept set and Activity's stops — the earlier run's file
    /// read first, synchronously (≤ 1 MB, the support folder).
    func start(ledger: LeftBehindLedger = .shared, held: ActivityHeld = .shared) {
        guard cancellables.isEmpty else { return }
        self.ledger = ledger
        self.held = held
        if restored == nil {
            let earlier = ActivityPersisted.load(from: url)
            unrestored = earlier.isEmpty ? nil : earlier
        }
        ledger.keptChanged = { [weak self] _ in self?.write() }
        // @Published emits before it changes: the emitted value.
        held.$suspensions
            .dropFirst()
            .sink { [weak self] suspensions in
                self?.write(stopped: Set(suspensions.flatMap { $0.members.map(\.identity) }))
            }
            .store(in: &cancellables)
    }

    /// The file as the app holds it now.
    func write(kept: Set<ActivityProcessID>? = nil, stopped: Set<ActivityProcessID>? = nil) {
        var kept = kept ?? ledger.kept
        var stopped = stopped ?? held.stopped
        if let unrestored {
            kept.formUnion(unrestored.keptIdentities)
            stopped.formUnion(unrestored.stoppedIdentities)
        }
        let record = ActivityPersisted(kept: kept, stopped: stopped)
        let url = self.url
        queue.async { @Sendable in record.save(to: url) }
    }

    /// Waits for what was written.
    func flush() { queue.sync {} }

    /// At launch: the file read, swept by `snapshot`; the kept ones back in
    /// the ledger; what Activity stopped and still is stopped returned for
    /// the Resume offer. The swept file is written again.
    func restore(from snapshot: ActivitySnapshot, ledger: LeftBehindLedger = .shared) -> Set<ActivityProcessID> {
        flush()
        let file = ActivityPersisted.load(from: url)
        let earlier = ActivityPersisted(
            kept: file.keptIdentities.union(unrestored?.keptIdentities ?? []),
            stopped: file.stoppedIdentities.union(unrestored?.stoppedIdentities ?? []))
        unrestored = nil
        let swept = earlier.swept { snapshot.table.process($0) }
        restored = swept
        ledger.restoreKept(swept.keptIdentities)
        // Swept, with what this run kept and stopped since it began.
        write(kept: ledger.kept, stopped: swept.stoppedIdentities.union(held.stopped))
        return swept.stoppedIdentities
    }
}
