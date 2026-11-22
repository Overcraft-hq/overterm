import Darwin
import Foundation

/// The detail's Files tab (docs/design/activity/analysis.md, 6.4, `l`):
/// what one process of the user's holds open — files by path
/// (`PROC_PIDFDVNODEPATHINFO`), sockets as the census decodes them, pipes
/// and the kernel's other kinds by name — read only when the tab opens,
/// off the main thread, never a tick's. A path's read asks the file
/// system, so a file on a share that stopped answering can hold it for
/// good: each path is read on a worker waited for `pathWait`, one that
/// doesn't come back left behind (`Stuck`) — the read stops there ("a file
/// isn't answering"), and every later read says so at once, reading no
/// path, until it returns —; one that comes back after `slowRead` stops
/// the read there too, and the whole read stops at `deadline`. Another user's isn't read (the
/// kernel refuses). Remote addresses are shown on the page only, as the
/// rows show them (9.4). Pure but for the kernel it is given.
package enum ProcessOpenFiles {
    /// One descriptor.
    package struct Entry: Hashable, Sendable {
        package enum Kind: String, Hashable, Sendable {
            case file, socket, pipe, kqueue, other
        }

        package let descriptor: Int32
        package let kind: Kind
        /// A file's path, a socket's ends, a kind's name.
        package let text: String
    }

    /// What one read found.
    package struct Listing: Hashable, Sendable {
        package let identity: ActivityProcessID
        package var entries: [Entry] = []
        /// Descriptors it holds, read or not.
        package var descriptors = 0
        /// Why the read stopped short: a file not answering, its time up,
        /// the cap; nil when whole.
        package var cut: String?
        /// It ended, or its pid is another's now: nothing shown.
        package var gone = false
    }

    package static let limit = 1_000
    package static let slowRead: UInt64 = 200_000_000
    package static let deadline: UInt64 = 2_000_000_000
    /// How long a path's worker is waited for before it is left behind.
    package static let pathWait: DispatchTimeInterval = .milliseconds(200)

    /// The path reads left behind, still not back: while any is, no path is
    /// read (a new one would hang on the same share).
    package final class Stuck: @unchecked Sendable {
        private let lock = NSLock()
        private var waiting = 0

        package var isStuck: Bool { lock.withLock { waiting > 0 } }
        fileprivate func left() { lock.withLock { waiting += 1 } }
        fileprivate func returned() { lock.withLock { waiting -= 1 } }
    }

    /// The app's.
    package static let stuck = Stuck()

    /// One path's answer, handed from its worker.
    private final class Answer: @unchecked Sendable {
        private let lock = NSLock()
        private var value: String?
        private var finished = false
        private var abandoned = false
        let done = DispatchSemaphore(value: 0)

        /// The worker's answer; true when nobody waits for it any more.
        func set(_ path: String?) -> Bool {
            lock.withLock {
                value = path
                finished = true
                return abandoned
            }
        }

        func take() -> String? { lock.withLock { value } }

        /// Nobody waits from now; false when the answer came first.
        func abandon() -> Bool {
            lock.withLock {
                if finished { return false }
                abandoned = true
                return true
            }
        }
    }

    private enum PathRead {
        case path(String?)
        case notAnswering
    }

    /// `descriptor`'s path read on a worker, waited for `wait`; left behind
    /// in `stuck` when it doesn't come back, counted back out by the
    /// worker if it ever does.
    private static func readPath(
        of pid: pid_t, descriptor: Int32, kernel: some ActivityKernel, wait: DispatchTimeInterval, stuck: Stuck
    ) -> PathRead {
        let answer = Answer()
        let work: @Sendable () -> Void = {
            let path = kernel.vnodePath(of: pid, descriptor: descriptor)
            if answer.set(path) { stuck.returned() }
            answer.done.signal()
        }
        DispatchQueue.global(qos: .userInitiated).async(execute: work)
        if answer.done.wait(timeout: .now() + wait) == .success { return .path(answer.take()) }
        stuck.left()
        guard answer.abandon() else {
            stuck.returned()
            return .path(answer.take())
        }
        return .notAnswering
    }

    /// `identity`'s open files, read through `kernel` now.
    package static func read(
        _ identity: ActivityProcessID, kernel: some ActivityKernel, wait: DispatchTimeInterval = pathWait, stuck: Stuck = stuck
    ) -> Listing {
        var listing = Listing(identity: identity)
        guard kernel.process(identity.pid)?.identity == identity, let descriptors = kernel.descriptors(of: identity.pid) else {
            listing.gone = true
            return listing
        }
        listing.descriptors = descriptors.count
        let began = kernel.uptime()
        for descriptor in descriptors.sorted(by: { $0.proc_fd < $1.proc_fd }) {
            if listing.entries.count >= limit {
                listing.cut = "the first \(limit) of \(descriptors.count)"
                break
            }
            if kernel.uptime() &- began > deadline {
                listing.cut = "its time was up after \(listing.entries.count) of \(descriptors.count)"
                break
            }
            let fd = descriptor.proc_fd
            switch Int32(descriptor.proc_fdtype) {
            case PROX_FDTYPE_VNODE:
                if stuck.isStuck {
                    listing.cut = "a file read earlier still isn't answering (a share that stopped?), so no file was read after \(listing.entries.count) of \(descriptors.count)"
                    break
                }
                let started = kernel.uptime()
                guard case .path(let path) = readPath(of: identity.pid, descriptor: fd, kernel: kernel, wait: wait, stuck: stuck),
                    kernel.uptime() &- started <= slowRead
                else {
                    listing.cut = "a file isn't answering (a share that stopped?) after \(listing.entries.count) of \(descriptors.count)"
                    break
                }
                listing.entries.append(Entry(descriptor: fd, kind: .file, text: path ?? "a file (its path can't be read)"))
            case PROX_FDTYPE_SOCKET:
                let record = kernel.socket(of: identity.pid, descriptor: fd).flatMap { SocketRecord.classify($0, descriptor: fd) }
                listing.entries.append(Entry(descriptor: fd, kind: .socket, text: record.map(describe) ?? "a socket"))
            case PROX_FDTYPE_PIPE:
                listing.entries.append(Entry(descriptor: fd, kind: .pipe, text: "pipe"))
            case PROX_FDTYPE_KQUEUE:
                listing.entries.append(Entry(descriptor: fd, kind: .kqueue, text: "kqueue"))
            case PROX_FDTYPE_PSHM:
                listing.entries.append(Entry(descriptor: fd, kind: .other, text: "shared memory"))
            case PROX_FDTYPE_PSEM:
                listing.entries.append(Entry(descriptor: fd, kind: .other, text: "semaphore"))
            case PROX_FDTYPE_FSEVENTS:
                listing.entries.append(Entry(descriptor: fd, kind: .other, text: "file system events"))
            default:
                listing.entries.append(Entry(descriptor: fd, kind: .other, text: "other (\(descriptor.proc_fdtype))"))
            }
            if listing.cut != nil { break }
        }
        // Read by pid: one whose pid was taken since shows nothing.
        if kernel.process(identity.pid)?.identity != identity {
            listing = Listing(identity: identity)
            listing.gone = true
        }
        return listing
    }

    /// A socket as the Files tab says it: "TCP 127.0.0.1:3000, listening",
    /// "UDP *:5353", "TCP 127.0.0.1:52000 → 127.0.0.1:3000, established",
    /// "unix /tmp/acme.sock, listening".
    package static func describe(_ record: SocketRecord) -> String {
        func end(_ address: ActivityAddress?, _ port: UInt16) -> String {
            guard let address, !address.isWildcard else { return "*:\(port)" }
            if case .v6 = address { return "[\(address.description)]:\(port)" }
            return "\(address.description):\(port)"
        }
        switch record.kind {
        case .tcp:
            var text = "TCP \(end(record.localAddress, record.localPort))"
            if record.remotePort != 0 { text += " → \(end(record.remoteAddress, record.remotePort))" }
            if let state = record.state { text += ", \(state.words)" }
            return text
        case .udp:
            var text = "UDP \(end(record.localAddress, record.localPort))"
            if record.remotePort != 0 { text += " → \(end(record.remoteAddress, record.remotePort))" }
            return text
        case .unix:
            return record.path.map { "unix \($0), listening" } ?? "unix socket"
        case .other:
            return "socket"
        }
    }

    /// The Files tab's reads: one at a time, on a queue of their own.
    package static let queue = DispatchQueue(label: "Overterm.activity.files", qos: .userInitiated)

    /// `identity`'s files, read on `queue`, `done` called there.
    package static func read(_ identity: ActivityProcessID, kernel: any ActivityKernel, done: @escaping @Sendable (Listing) -> Void) {
        let block: @Sendable () -> Void = { done(read(identity, kernel: kernel)) }
        queue.async(execute: block)
    }
}

extension TCPState {
    /// As lsof says it, in words.
    package var words: String {
        switch self {
        case .closed: "closed"
        case .listen: "listening"
        case .synSent: "connecting"
        case .synReceived: "accepting"
        case .established: "established"
        case .closeWait: "closing (its peer closed)"
        case .finWait1, .finWait2, .closing: "closing"
        case .lastAck: "closing (last ack)"
        case .timeWait: "time wait"
        }
    }
}
