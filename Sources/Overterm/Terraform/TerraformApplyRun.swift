import Combine
import Darwin
import Foundation

/// Who a detached apply is (analysis 4.7), in its run folder as
/// `apply.json`: the launcher's pid and start time, so a relaunched
/// Overterm finds it again — and only it, never a pid reused since — and
/// what the slot says of it. Names and paths only: never the
/// environment, never a value of the plan.
struct TerraformApplyMarker: Codable, Equatable, Sendable {
    var pid: Int32
    /// The launcher's start time, µs since 1970 (`ProcessInspector.kinfo`).
    var started: UInt64
    /// The launcher's executable: `/bin/bash`.
    var executable: String
    var checkout: String
    /// The root's path in the checkout.
    var root: String
    /// Its display name.
    var name: String
    var workspace: String
    var rootClass: String
    var identity: String?
    var at: Date

    /// Now, to the second: what the marker keeps survives its JSON whole.
    static var now: Date { Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down)) }

    static let file = "apply.json"
    static let stdout = "stdout"
    static let stderr = "stderr"
    static let status = "status"

    /// Whether `marker`'s process is still that apply: alive, started then,
    /// the same executable. Pure over what it is told.
    static func isAlive(_ marker: TerraformApplyMarker, alive: (pid_t) -> Bool, started: (pid_t) -> UInt64?, path: (pid_t) -> String?) -> Bool {
        guard marker.pid > 0, alive(marker.pid), let start = started(marker.pid), start == marker.started else { return false }
        return path(marker.pid).map { $0 == marker.executable } ?? false
    }

    static func read(_ folder: URL) -> TerraformApplyMarker? {
        let url = folder.appendingPathComponent(file)
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_size < 64 << 10,
            let data = try? Data(contentsOf: url)
        else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(TerraformApplyMarker.self, from: data)
    }

    func write(to folder: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let url = folder.appendingPathComponent(Self.file)
        let data = try encoder.encode(self)
        let fd = open(url.path, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        _ = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
    }

    /// The real process facts.
    static func liveNow(_ marker: TerraformApplyMarker) -> Bool {
        isAlive(marker, alive: TerraformRunFolder.isAlive, started: { ProcessInspector.kinfo($0)?.start }, path: executablePath)
    }

    static func executablePath(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4_096)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

/// Who is still in a detached apply's process group (4.7): the launcher,
/// terraform, its provider plugins, a provisioner's commands. Its id is
/// the launcher's pid, which outlives the launcher only while a member of
/// the group remains — so a member counts only when it started no
/// earlier than the launcher, in the launcher's session, and never when
/// the group's leader is there but another process (a pid reused since).
/// The decisions are pure; `members(of:)` asks the kernel.
enum TerraformApplyGroup {
    struct Member: Equatable, Sendable {
        var pid: pid_t
        /// Its start time, µs since 1970 (`ProcessInspector.kinfo`).
        var started: UInt64
        /// Its session's id, when it could be read.
        var session: pid_t?
        /// Its executable, when it could be read.
        var path: String?
    }

    /// The members that are the apply's.
    static func ours(_ members: [Member], marker: TerraformApplyMarker) -> [Member] {
        guard marker.pid > 0, marker.started > 0 else { return [] }
        if let leader = members.first(where: { $0.pid == marker.pid }), leader.started != marker.started { return [] }
        return members.filter { $0.started >= marker.started && ($0.session.map { $0 == marker.pid } ?? true) }
    }

    /// A provider plugin: what terraform starts and leaves behind only if it dies.
    static func isPlugin(_ member: Member) -> Bool {
        guard let path = member.path else { return false }
        return URL(fileURLWithPath: path).lastPathComponent.hasPrefix("terraform-provider-")
    }

    /// Whether anything but a plugin is still there: terraform, its
    /// launcher, a provisioner's command. Nothing is killed while one is.
    static func terraformRuns(_ ours: [Member]) -> Bool { ours.contains { !isPlugin($0) } }

    /// The plugins to sweep once terraform is gone (4.7: "SIGKILL only
    /// after terraform has exited"): none while anything else runs.
    static func strays(_ ours: [Member]) -> [pid_t] { terraformRuns(ours) ? [] : ours.filter(isPlugin).map(\.pid) }

    /// The group `pgid`'s members now.
    static func members(of pgid: pid_t) -> [Member] {
        guard pgid > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: 256)
        let bytes = pids.withUnsafeMutableBytes { proc_listpids(UInt32(PROC_PGRP_ONLY), UInt32(pgid), $0.baseAddress, Int32($0.count)) }
        guard bytes > 0 else { return [] }
        return pids.prefix(Int(bytes) / MemoryLayout<pid_t>.stride).filter { $0 > 0 }.compactMap { pid in
            guard let info = ProcessInspector.kinfo(pid) else { return nil }
            let session = getsid(pid)
            return Member(pid: pid, started: info.start, session: session > 0 ? session : nil, path: TerraformApplyMarker.executablePath(pid))
        }
    }

    /// The apply's members now.
    static func live(_ marker: TerraformApplyMarker) -> [Member] { ours(members(of: marker.pid), marker: marker) }
}

/// Starting the detached apply (4.7, D-1): `apply -input=false -json
/// -lock=true -lock-timeout=60s /dev/fd/3`, the plan's descriptor as fd 3,
/// by the plan's binary, in the plan's environment, cwd the root. Its own
/// session (`POSIX_SPAWN_SETSID`): no terminal, no SIGHUP when the app or
/// a pane goes; stdout and stderr to 0600 files in its run folder, never a
/// pipe whose reader dying would SIGPIPE it (spike 12). A `bash -p`
/// launcher waits for it and writes its exit code beside them, so whoever
/// follows — this app, or the next launch after a crash — reads how it
/// ended; it traps INT and TERM so a Stop reaches terraform and the code
/// is still written. It starts terraform only once its marker is written
/// (`go` on fd 4): an app that dies between the spawn and the marker, or
/// a marker that can't be written, leaves no apply nobody could find.
enum TerraformApplyLaunch {
    static let shell = "/bin/bash"
    static let launcher =
        #"status=$0; tf=$1; shift; IFS= read -r go <&4; exec 4<&-; [ "$go" = go ] || exit 125; trap ':' INT TERM; "$tf" "$@"; code=$?; (umask 077; printf '%s\n' "$code" > "$status.part") && /bin/mv -f "$status.part" "$status""#

    enum Failure: Error, CustomStringConvertible {
        case refused(String)
        case files(Int32)
        case spawn(Int32)
        /// Its marker couldn't be written, or its start time read: not started.
        case marker(String)

        var description: String {
            switch self {
            case .refused(let why): "refused: \(why)"
            case .files(let code): "the apply's files can't be made: \(String(cString: strerror(code)))"
            case .spawn(let code): "terraform could not start: \(String(cString: strerror(code)))"
            case .marker(let why): "not started — \(why), so a relaunch couldn't find it"
            }
        }
    }

    /// The environment an apply runs in: the plan's, as it was built, with
    /// whatever injects flags or logs values taken out again — never
    /// trusted to the record alone (5.13 rule 3). Pure.
    static func environment(_ recorded: [String: String]) -> [String: String] {
        recorded.filter { name, _ in !TerraformEnvironment.isAlwaysRemoved(name) || name == "TF_WORKSPACE" || name == "TF_DATA_DIR" }
    }

    /// The launcher's argv: its script, the status file, the binary, the apply.
    static func arguments(status: URL, binary: URL) -> [String] {
        ["-p", "-c", launcher, status.path, binary.path] + TerraformCommands.apply
    }

    /// Spawns it, its marker written, then lets it start terraform.
    /// Blocking, briefly. Nothing runs when the marker can't be written.
    static func spawn(
        binary: URL, root: URL, environment recorded: [String: String], plan descriptor: Int32, folder: URL,
        marker: (pid_t, UInt64) -> TerraformApplyMarker, write: (TerraformApplyMarker, URL) throws -> Void = { try $0.write(to: $1) }
    ) throws -> TerraformApplyMarker {
        if let why = TerraformCommands.refusal(TerraformCommands.apply) { throw Failure.refused(why) }
        func create(_ name: String) throws -> Int32 {
            let fd = open(folder.appendingPathComponent(name).path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw Failure.files(errno) }
            return fd
        }
        let out = try create(TerraformApplyMarker.stdout)
        defer { close(out) }
        let err = try create(TerraformApplyMarker.stderr)
        defer { close(err) }
        let status = folder.appendingPathComponent(TerraformApplyMarker.status)
        // The launcher's go: fd 4, kept above the numbers the child is given.
        var ends: [Int32] = [-1, -1]
        guard pipe(&ends) == 0 else { throw Failure.files(errno) }
        let reading = fcntl(ends[0], F_DUPFD_CLOEXEC, 10)
        let writing = fcntl(ends[1], F_DUPFD_CLOEXEC, 10)
        close(ends[0])
        close(ends[1])
        guard reading >= 0, writing >= 0 else {
            if reading >= 0 { close(reading) }
            if writing >= 0 { close(writing) }
            throw Failure.files(errno)
        }
        // A launcher gone before reading must not take the app down.
        _ = fcntl(writing, F_SETNOSIGPIPE, 1)
        defer { close(writing) }
        let spawned = ProcessGroup.spawn(
            URL(fileURLWithPath: shell), arguments(status: status, binary: binary), environment(recorded), directory: root, stdout: out, stderr: err,
            descriptors: [3: descriptor, 4: reading], newSession: true)
        close(reading)
        let pid: pid_t
        switch spawned {
        case .success(let child): pid = child
        case .failure(let error): throw Failure.spawn(error.code.rawValue)
        }
        // Not started: the go never sent, the launcher exits on its own (reaped).
        func abandon(_ why: String) -> Failure {
            _ = ProcessGroup.Child(pid: pid)
            return Failure.marker(why)
        }
        guard let started = ProcessInspector.kinfo(pid)?.start, started > 0 else { throw abandon("its start time couldn't be read") }
        let made = marker(pid, started)
        do { try write(made, folder) } catch { throw abandon("its marker couldn't be written (\(error.localizedDescription))") }
        let go = Array("go\n".utf8)
        guard go.withUnsafeBytes({ Darwin.write(writing, $0.baseAddress, $0.count) }) == go.count else { throw abandon("the launcher didn't take its go") }
        return made
    }

    /// The exit code the launcher wrote, once it has.
    static func status(in folder: URL) -> Int32? {
        guard let text = try? String(contentsOf: folder.appendingPathComponent(TerraformApplyMarker.status), encoding: .utf8) else { return nil }
        return Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// The run folders under `base` whose apply is alive: in a process
    /// folder of this user's — another Overterm's that died, or this one's
    /// when `includingOwn` (a scenario's "crash") — never one already
    /// followed (`followed`). Blocking.
    static func detached(base: URL = AppEnvironment.terraformRunsBase, includingOwn: Bool, followed: Set<String>) -> [(folder: URL, marker: TerraformApplyMarker)] {
        let manager = FileManager.default
        var found: [(URL, TerraformApplyMarker)] = []
        let own = TerraformRunFolder.name()
        for name in ((try? manager.contentsOfDirectory(atPath: base.path)) ?? []).prefix(256) where name.hasPrefix(TerraformRunFolder.prefix) {
            guard includingOwn || name != own, name.hasPrefix(TerraformRunFolder.prefix + "\(getuid())-") else { continue }
            let process = base.appendingPathComponent(name, isDirectory: true)
            for run in ((try? manager.contentsOfDirectory(atPath: process.path)) ?? []).prefix(256) {
                let folder = process.appendingPathComponent(run, isDirectory: true)
                guard !followed.contains(folder.standardizedFileURL.path), let marker = TerraformApplyMarker.read(folder),
                    TerraformApplyMarker.liveNow(marker)
                else { continue }
                found.append((folder, marker))
            }
        }
        return found
    }
}

/// Following a detached apply's stdout file (4.7): read as it grows, a
/// line at a time, decoded on its thread (`TerraformUIMessage`), handed on
/// in 120 ms batches; when the apply is gone, the rest read, and its exit
/// code. `cancel` stops following, never the apply.
final class TerraformApplyTail: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }

    static let poll: UInt32 = 150_000
    static let batchInterval: UInt64 = 120_000_000

    /// Blocking: a GCD thread's. `done` gets the exit code (nil: none was
    /// written) and stderr's last lines, scrubbed — unless cancelled.
    /// `scrub`: every string of a line, as it is decoded — the plan's
    /// sensitive values masked first (`TerraformValueMask`).
    func follow(
        folder: URL, scrub: @Sendable (String) -> String = TerraformPlan.scrub, alive: @Sendable () -> Bool,
        batch: @Sendable ([TerraformUIMessage]) -> Void, done: @Sendable (Int32?, String) -> Void
    ) {
        let fd = open(folder.appendingPathComponent(TerraformApplyMarker.stdout).path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        defer { if fd >= 0 { close(fd) } }
        var pending = Data()
        var messages: [TerraformUIMessage] = []
        var flushed = DispatchTime.now().uptimeNanoseconds
        var buffer = [UInt8](repeating: 0, count: 1 << 16)
        var ending = false
        while !isCancelled {
            var got = 0
            if fd >= 0 {
                got = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
                if got < 0, errno == EINTR { continue }
            }
            if got > 0 {
                pending.append(contentsOf: buffer[0..<got])
                while let newline = pending.firstIndex(of: 0x0A) {
                    messages.append(TerraformUIMessage.decode(String(decoding: pending[pending.startIndex..<newline], as: UTF8.self), scrub: scrub))
                    pending.removeSubrange(pending.startIndex...newline)
                }
                if pending.count > TerraformStreamRun.maxPending {
                    messages.append(.raw("(a line too long to keep)"))
                    pending.removeAll()
                }
            }
            let now = DispatchTime.now().uptimeNanoseconds
            if !messages.isEmpty, now - flushed >= Self.batchInterval || got <= 0 {
                batch(messages)
                messages = []
                flushed = now
            }
            guard got <= 0 else { continue }
            // Nothing new: gone, then one more read of what it wrote last.
            if ending { break }
            if !alive() {
                ending = true
                continue
            }
            usleep(Self.poll)
        }
        guard !isCancelled else { return }
        if !pending.isEmpty { messages.append(TerraformUIMessage.decode(String(decoding: pending, as: UTF8.self), scrub: scrub)) }
        if !messages.isEmpty { batch(messages) }
        let stderr = Self.lastLines(of: folder.appendingPathComponent(TerraformApplyMarker.stderr), scrub: scrub)
        done(TerraformApplyLaunch.status(in: folder), stderr)
    }

    /// The last 16 KB of a file, scrubbed.
    static func lastLines(of url: URL, scrub: (String) -> String = TerraformPlan.scrub) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 16_384 ? size - 16_384 : 0)
        let data = (try? handle.readToEnd()) ?? Data()
        return String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false).map { scrub(String($0)) }.joined(separator: "\n")
    }
}

/// One apply of a shown plan (6.4), in memory only: the plan's rows, each
/// waiting → running → done or errored, a replace's two steps counted; the
/// provisioners' output under its row; the diagnostics by address; the
/// raw log, scrubbed; the end said from the exit code **and** a
/// `change_summary` whose operation is `apply` (spike 24) — never the
/// stream alone. Stop is one SIGINT to its group (D-3); a second, asked,
/// another. Never SIGKILL while it runs.
@MainActor
final class TerraformApplyRun: ObservableObject, Identifiable {
    enum Phase: Equatable, Sendable {
        case running
        /// Stop sent: once, or twice.
        case stopping(Int)
        case applied(String)
        case failed(String)
        case stopped(String)
    }

    enum RowState: String, Sendable {
        case waiting, running, done, errored
    }

    struct Row: Identifiable, Equatable, Sendable {
        var address: String
        var action: TerraformPlan.Action
        var state: RowState = .waiting
        /// Steps done: a replace has two.
        var completed = 0
        var expected = 1
        var elapsed: Int?
        /// Its provisioners' output, scrubbed, the last lines.
        var output: [String] = []
        var error: String?
        /// The diagnostic's file and line: "Open at main.tf:67".
        var file: String?
        var line: Int?

        var id: String { address }
    }

    static let maxLog = 2_000
    static let maxOutput = 40
    /// A silence this long is said, never acted on (4.7).
    static let silence: TimeInterval = 120

    let id: String
    let marker: TerraformApplyMarker
    let folder: URL
    /// Found again after Overterm last quit, or after its record was lost.
    let reattached: Bool
    let identity: TerraformStateIdentity?
    /// The turn's key in the registry: the state's identity, else the root.
    let key: String
    weak var planRun: TerraformPlanRun?

    @Published private(set) var phase: Phase = .running
    @Published private(set) var rows: [Row] = []
    @Published private(set) var log: [String] = []
    @Published private(set) var diagnostics: [TerraformDiagnostic] = []
    @Published private(set) var lastHeard = Date()
    @Published private(set) var finished: Date?
    /// The apply's `change_summary`.
    private(set) var summary: (add: Int, change: Int, remove: Int)?
    /// What the window does when it ends: the state written, the turn given back.
    var onEnd: ((TerraformApplyRun) -> Void)?

    private let tail = TerraformApplyTail()
    private var child: ProcessGroup.Child?
    private let planned: Bool
    private var interrupts = 0
    /// Each row's index by address: the stream touches rows by address
    /// (Section 10), never a scan of 2,000 rows per hook line.
    private var rowIndexes: [String: Int] = [:]
    /// The plan's sensitive values, over what the stream prints in clear (5.6).
    let mask: TerraformValueMask

    var started: Date { marker.at }
    var isGoing: Bool {
        switch phase {
        case .running, .stopping: true
        default: false
        }
    }

    var worktree: String { URL(fileURLWithPath: marker.checkout).lastPathComponent }

    init(
        id: String? = nil, marker: TerraformApplyMarker, folder: URL, plan: TerraformPlan?, identity: TerraformStateIdentity?, key: String, reattached: Bool,
        child: ProcessGroup.Child?, mask: TerraformValueMask = .none
    ) {
        self.mask = mask
        self.id = id ?? "tfa-" + UUID().uuidString.prefix(8).lowercased()
        self.marker = marker
        self.folder = folder
        self.reattached = reattached
        self.identity = identity
        self.key = key
        self.child = child
        self.planned = plan != nil
        if let plan { rows = Self.rows(of: plan) }
        for (index, row) in rows.enumerated() where rowIndexes[row.address] == nil { rowIndexes[row.address] = index }
    }

    /// The plan's rows that apply does something to, risky first.
    nonisolated static func rows(of plan: TerraformPlan) -> [Row] {
        let changing = plan.resourceChanges.filter { [.create, .update, .delete, .replace].contains($0.action) }
        let ordered = changing.filter(\.isRisky) + changing.filter { !$0.isRisky }
        return ordered.map { Row(address: $0.address, action: $0.action, expected: $0.action == .replace ? 2 : 1) }
    }

    /// "7 of 12 · 2 running · 1m 12s".
    func progressText(now: Date = Date()) -> String {
        let done = rows.filter { $0.state == .done }.count
        let running = rows.filter { $0.state == .running }.count
        let errored = rows.filter { $0.state == .errored }.count
        var parts = ["\(done) of \(rows.count)"]
        if running > 0 { parts.append("\(running) running") }
        if errored > 0 { parts.append("\(errored) failed") }
        parts.append(Self.elapsed(now.timeIntervalSince(started)))
        return parts.joined(separator: " · ")
    }

    /// The silence said, past two minutes with nothing from Terraform.
    func silenceText(now: Date = Date()) -> String? {
        guard isGoing, now.timeIntervalSince(lastHeard) > Self.silence else { return nil }
        return "Nothing from Terraform for \(Self.elapsed(now.timeIntervalSince(lastHeard))): it may be waiting on a provider. Nothing is done about it."
    }

    nonisolated static func elapsed(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        if total < 60 { return "\(total)s" }
        if total < 3_600 { return "\(total / 60)m \(total % 60)s" }
        return "\(total / 3_600)h \(total % 3_600 / 60)m"
    }

    // MARK: The stream

    func absorb(_ messages: [TerraformUIMessage]) {
        lastHeard = Date()
        var lines: [String] = []
        for message in messages {
            switch message {
            case .apply(let address, let action, let step, let elapsed):
                let index = rowIndex(address, action: action)
                rows[index].elapsed = elapsed ?? rows[index].elapsed
                switch step {
                case .start, .progress:
                    if rows[index].state != .errored { rows[index].state = .running }
                case .complete:
                    rows[index].completed += 1
                    if rows[index].state != .errored { rows[index].state = rows[index].completed >= rows[index].expected ? .done : .running }
                case .errored:
                    rows[index].state = .errored
                }
            case .provision(let address, _, let step, let output):
                let index = rowIndex(address)
                if let output, step == .progress {
                    rows[index].output.append(output)
                    if rows[index].output.count > Self.maxOutput { rows[index].output.removeFirst(rows[index].output.count - Self.maxOutput) }
                }
                if step == .errored { rows[index].state = .errored }
            case .summary(let add, let change, let remove, _, let operation):
                if operation == "apply" { summary = (add, change, remove) }
            case .diagnostic(let diagnostic):
                diagnostics.append(diagnostic)
                if let address = diagnostic.address {
                    let index = rowIndex(address)
                    rows[index].state = diagnostic.severity == .error ? .errored : rows[index].state
                    rows[index].error = diagnostic.summary + (diagnostic.detail.isEmpty ? "" : " — " + diagnostic.detail)
                    rows[index].file = diagnostic.file
                    rows[index].line = diagnostic.start?.line
                }
            default:
                break
            }
            lines.append(message.logLine)
        }
        log.append(contentsOf: lines)
        if log.count > Self.maxLog { log.removeFirst(log.count - Self.maxLog) }
    }

    /// A row of the plan's, or one the stream names that the plan didn't
    /// (a reattached apply has no plan): by the hook's action.
    private func rowIndex(_ address: String, action: String? = nil) -> Int {
        if let index = rowIndexes[address] {
            // A replace the plan didn't say (reattached): a second action seen.
            if action == "delete" || action == "create", rows[index].action != .replace, rows[index].action.rawValue != action, plannedless {
                rows[index].action = .replace
                rows[index].expected = 2
            }
            return index
        }
        rows.append(Row(address: address, action: action.flatMap(TerraformPlan.Action.init(rawValue:)) ?? .update))
        rowIndexes[address] = rows.count - 1
        return rows.count - 1
    }

    /// No plan gave the rows (a reattached apply's): they come from the stream.
    private var plannedless: Bool { !planned }

    // MARK: Following

    /// Follows the files until the apply is gone (or `detach`).
    func follow() {
        let folder = self.folder
        let marker = self.marker
        let child = self.child
        let handlers = Self.hand(self)
        // Going while its launcher is, or — the launcher killed, or reaped
        // by launchd — while terraform or anything but a plugin is still in
        // its group: never called over while terraform writes.
        let alive: @Sendable () -> Bool = {
            if let child {
                if child.isRunning { return true }
            } else if TerraformApplyMarker.liveNow(marker) {
                return true
            }
            return TerraformApplyGroup.terraformRuns(TerraformApplyGroup.live(marker))
        }
        let tail = self.tail
        let mask = self.mask
        let work: @Sendable () -> Void = {
            tail.follow(folder: folder, scrub: { mask.scrub($0) }, alive: alive, batch: handlers.batch, done: handlers.done)
        }
        DispatchQueue.global(qos: .userInitiated).async(execute: work)
    }

    /// Builds, off any actor, what the follower's thread hands back on the main one.
    nonisolated private static func hand(_ run: TerraformApplyRun) -> (
        batch: @Sendable ([TerraformUIMessage]) -> Void, done: @Sendable (Int32?, String) -> Void
    ) {
        let batch: @Sendable ([TerraformUIMessage]) -> Void = { messages in DispatchQueue.main.async { MainActor.assumeIsolated { run.absorb(messages) } } }
        let done: @Sendable (Int32?, String) -> Void = { status, stderr in
            DispatchQueue.main.async { MainActor.assumeIsolated { run.ended(status: status, stderr: stderr) } }
        }
        return (batch, done)
    }

    /// Stops following without touching the apply or its folder: what a
    /// crash leaves (the scenario's), found again by `TerraformApplyLaunch.detached`.
    func detach() {
        tail.cancel()
    }

    /// The end: the exit code and an `apply` summary decide (spike 24).
    func ended(status: Int32?, stderr: String) {
        guard isGoing else { return }
        // terraform is gone: a provider plugin it left in its group goes
        // too — by pid, each checked just now, never the group's id, which
        // another group may hold once this one is empty.
        for stray in TerraformApplyGroup.strays(TerraformApplyGroup.live(marker)) { kill(stray, SIGKILL) }
        if !stderr.isEmpty {
            log.append(contentsOf: stderr.split(separator: "\n").suffix(40).map { mask.scrub(String($0)) })
            if log.count > Self.maxLog { log.removeFirst(log.count - Self.maxLog) }
        }
        finished = Date()
        let done = rows.filter { $0.state == .done }.count
        let failed = rows.filter { $0.state == .errored }.count
        if status == 0, let summary {
            phase = .applied("Apply complete — \(summary.add) added, \(summary.change) changed, \(summary.remove) destroyed.")
        } else if interrupts > 0 {
            phase = .stopped("Stopped: state saved, \(done) applied; running resources may be left tainted.")
        } else if let status {
            let first = diagnostics.first { $0.severity == .error }?.summary
            phase = .failed(
                (failed > 0 ? "\(failed) failed — state saved, \(done) applied" : "The apply failed (exit \(status)) — \(done) applied")
                    + (first.map { ": \($0)" } ?? "."))
        } else {
            phase = .failed("The apply ended without saying how (its launcher was killed): \(done) applied. Plan again to see the state.")
        }
        TerraformRunFolder.remove(folder)
        onEnd?(self)
    }

    // MARK: Ask Why (2.3, 6.4 step 5)

    /// What an agent is told of a failed apply: the apply's own
    /// diagnostics by address and its log — never the plan's — and the
    /// lock it couldn't take, if that was it. Masked as the stream was.
    func brief(backend: String?, version: String?, providers: [String]) -> TerraformAgentBrief {
        var lock: TerraformLockInfo?
        for diagnostic in diagnostics where lock == nil { lock = TerraformLockInfo.parse(summary: diagnostic.summary, detail: diagnostic.detail) }
        var log = self.log
        if case .failed(let said) = phase { log.append(said) }
        return TerraformAgentBrief.run(
            operation: "apply", diagnostics: diagnostics, lock: lock, log: log,
            root: .init(
                name: marker.name, workspace: marker.workspace, backend: backend ?? marker.identity ?? "unknown",
                rootClass: TerraformClass(rawValue: marker.rootClass), version: version, providers: providers),
            checkout: marker.checkout)
    }

    /// The root's folder: the checkout's, at the root's path.
    var rootFolder: URL {
        let checkout = URL(fileURLWithPath: marker.checkout, isDirectory: true)
        return marker.root.isEmpty ? checkout : checkout.appendingPathComponent(marker.root, isDirectory: true)
    }

    // MARK: Stop

    /// Stop (D-3): the first is one SIGINT to the group, as Ctrl-C; true.
    /// False when it was sent already — the caller asks before `interruptAgain`.
    @discardableResult
    func stop() -> Bool {
        guard isGoing, interrupts == 0 else { return false }
        interrupt()
        return true
    }

    /// The second Stop, asked first: SIGINT again, "exit now, data loss may occur".
    func interruptAgain() {
        guard isGoing else { return }
        interrupt()
    }

    private func interrupt() {
        interrupts += 1
        phase = .stopping(interrupts)
        // The group while anything of it is there: its launcher, or
        // terraform alone when the launcher was killed.
        if marker.pid > 0, child?.isRunning == true || TerraformApplyMarker.liveNow(marker) || !TerraformApplyGroup.live(marker).isEmpty {
            killpg(marker.pid, SIGINT)
        }
        log.append(interrupts == 1 ? "Stop: interrupt sent — Terraform stops gracefully; running resources may be left tainted." : "Stop again: interrupt sent a second time.")
    }

    // MARK: Starting

    /// Spawns the apply of `record` (its checks done, its sheet answered),
    /// in `card`'s root. Off the main thread for the spawn.
    static func start(
        record: TerraformPlanRecord, plan: TerraformPlan, card: TerraformRootCard, checkout: URL, identity: TerraformStateIdentity?, key: String,
        id: String? = nil
    ) async -> Result<TerraformApplyRun, TerraformReadFailure> {
        let root = card.folder
        let binary = record.binary
        let environment = record.environment
        let descriptor = record.file.descriptor
        let mask = record.mask
        let base = TerraformApplyMarker(
            pid: 0, started: 0, executable: TerraformApplyLaunch.shell, checkout: checkout.standardizedFileURL.path, root: card.path, name: card.name,
            workspace: record.workspace, rootClass: card.rootClass.rawValue, identity: identity?.description, at: TerraformApplyMarker.now)
        let spawned = await TerraformPanelModel.blocking { () -> Result<(URL, TerraformApplyMarker), TerraformReadFailure> in
            do {
                let folder = try TerraformRunFolder.makeRun()
                do {
                    // Its marker, and the plan's values as digests for a
                    // relaunch's mask, both before terraform starts.
                    let marker = try TerraformApplyLaunch.spawn(
                        binary: binary, root: root, environment: environment, plan: descriptor, folder: folder,
                        marker: { pid, started in
                            var made = base
                            made.pid = pid
                            made.started = started
                            return made
                        },
                        write: { marker, folder in
                            try marker.write(to: folder)
                            try mask.write(to: folder)
                        })
                    return .success((folder, marker))
                } catch {
                    TerraformRunFolder.remove(folder)
                    throw error
                }
            } catch {
                return .failure(TerraformReadFailure(message: TerraformPlan.scrub("\(error)")))
            }
        }
        switch spawned {
        case .failure(let failure): return .failure(failure)
        case .success(let (folder, marker)):
            let run = TerraformApplyRun(
                id: id, marker: marker, folder: folder, plan: plan, identity: identity, key: key, reattached: false, child: ProcessGroup.Child(pid: marker.pid),
                mask: record.mask)
            run.follow()
            return .success(run)
        }
    }

    /// An apply found running after Overterm last quit (or its record lost):
    /// followed again from its files' start.
    static func reattach(folder: URL, marker: TerraformApplyMarker) -> TerraformApplyRun {
        let key = marker.identity ?? URL(fileURLWithPath: marker.checkout).appendingPathComponent(marker.root).standardizedFileURL.path
        // Masked as before the crash: the plan's values, as its folder keeps them.
        let run = TerraformApplyRun(
            marker: marker, folder: folder, plan: nil, identity: nil, key: key, reattached: true, child: nil, mask: TerraformValueMask.read(folder))
        run.log.append(
            "An apply in \(marker.name) has been running since \(TerraformPlanRun.clock(marker.at)), started before Overterm last quit: followed again.")
        run.follow()
        return run
    }
}
