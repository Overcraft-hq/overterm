import Darwin
import Foundation

/// The process macOS holds responsible for another (docs/design/activity/
/// analysis.md, 6.5 rule 13, D-31): an XPC service's or a virtual machine's
/// app — WebKit's content processes under the app that shows the page,
/// Docker Desktop's Linux VM under Docker. `responsibility_get_pid_
/// responsible_for_pid` is private: looked up, never linked, and turned
/// off for the app's life at its first failure — the symbol missing, or no
/// answer for this very process, which is always its own responsible one.
/// Off, nothing is responsible for anything, and an unknown never means
/// "macOS" (rule 14 asks for no responsible app, and unknown isn't none:
/// `ActivityAttribution` reads `nil` as unread). Any thread.
enum ProcessResponsibility {
    private typealias Responsible = @convention(c) (pid_t) -> pid_t

    private static let call: Responsible? = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid").map {
        unsafeBitCast($0, to: Responsible.self)
    }

    private static let lock = NSLock()
    // Under `lock`.
    nonisolated(unsafe) private static var failed = false
    nonisolated(unsafe) private static var probed = false

    /// Whether the call is there and answered for this process.
    static var isAvailable: Bool {
        lock.withLock {
            guard !failed else { return false }
            guard let call else {
                failed = true
                return false
            }
            if !probed {
                probed = true
                let me = getpid()
                if call(me) <= 0 { failed = true }
            }
            return !failed
        }
    }

    /// The pid responsible for `pid`: nil when off, when none answered (the
    /// process ended), or when it is its own.
    static func responsible(for pid: pid_t) -> pid_t? {
        guard pid > 0, isAvailable, let call else { return nil }
        let answer = call(pid)
        guard answer > 0, answer != pid else { return nil }
        return answer
    }
}
