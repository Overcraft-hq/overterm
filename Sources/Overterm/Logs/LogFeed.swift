import Combine
import Foundation

/// Log lines as a Logs tab shows them — one source's (a container's), or
/// several merged by time (a compose project's services). The text view
/// draws only what is added at the end; anything else bumps `revision`
/// and it draws it all. Filled by `LogFollower`s.
@MainActor
final class LogFeed: ObservableObject {
    @Published private(set) var lines: [LogLine] = []
    @Published private(set) var revision = 0
    /// Bumped when older lines went in before the rest (`prepend`): the
    /// text view keeps the line read where it was.
    @Published private(set) var prepended = 0
    /// Something is followed now (a stream is open).
    @Published var following = false
    /// What follows the same log in a terminal tab, if anything does.
    var terminalCommand: String?

    nonisolated static let keep = 5000
    /// What each source keeps past `keep`, whatever the others write.
    nonisolated static let keepEach = 1000

    /// Lines in the order they came: after the ones there.
    func append(_ added: [LogLine]) {
        guard !added.isEmpty else { return }
        if lines.count + added.count > Self.keep, let kept = Self.trimmed(lines + added) {
            lines = kept
            revision += 1
        } else {
            lines += added
        }
    }

    /// The last `keep` lines, and each source's last `keepEach` before
    /// them: in a merged feed a service that logs every request doesn't
    /// push out a quiet one's lines, which its picker shows alone. Nil when
    /// none go. Pure.
    nonisolated static func trimmed(_ lines: [LogLine], keep: Int = keep, keepEach: Int = keepEach) -> [LogLine]? {
        guard lines.count > keep else { return nil }
        var each: [String: Int] = [:]
        var kept = [Bool](repeating: false, count: lines.count)
        var count = 0
        for index in lines.indices.reversed() {
            let source = lines[index].source ?? ""
            let mine = each[source, default: 0]
            guard count < keep || mine < keepEach else { continue }
            kept[index] = true
            count += 1
            each[source] = mine + 1
        }
        guard count < lines.count else { return nil }
        return lines.indices.filter { kept[$0] }.map { lines[$0] }
    }

    /// Lines from one of several streams, in time order among the rest: at
    /// the end when they are the newest (the usual case), else merged and
    /// drawn again.
    func merge(_ added: [LogLine]) {
        guard !added.isEmpty else { return }
        let last = lines.last.flatMap(\.timestamp).map(Self.sortable) ?? ""
        let first = added.first?.timestamp.map(Self.sortable) ?? ""
        if first >= last {
            append(added)
            return
        }
        let merged = Self.merged(lines, added)
        lines = Self.trimmed(merged) ?? merged
        revision += 1
    }

    /// Older lines, before the ones there — asked for again with a larger
    /// tail (a pod's log has no offset). Only as many as `keep` has room
    /// for, the newest of them.
    func prepend(_ older: [LogLine]) {
        let room = Self.keep - lines.count
        guard !older.isEmpty, room > 0 else { return }
        lines = Array(older.suffix(room)) + lines
        revision += 1
        prepended += 1
    }

    func clear() {
        lines = []
        revision += 1
    }

    /// Both in time order, stable for equal times. Pure.
    nonisolated static func merged(_ a: [LogLine], _ b: [LogLine]) -> [LogLine] {
        var out: [LogLine] = []
        out.reserveCapacity(a.count + b.count)
        var i = 0
        var j = 0
        while i < a.count || j < b.count {
            if j >= b.count || (i < a.count && sortable(a[i].timestamp ?? "") <= sortable(b[j].timestamp ?? "")) {
                out.append(a[i])
                i += 1
            } else {
                out.append(b[j])
                j += 1
            }
        }
        return out
    }

    /// A timestamp that sorts as text: Docker (and Go's RFC 3339 nano)
    /// trims a fraction's trailing zeros (`.12Z` is later than `.115Z`), so
    /// it is padded to nine digits.
    nonisolated static func sortable(_ stamp: String) -> String {
        // The fraction starts after `THH:mm:ss`; a whole second has none.
        guard let t = stamp.firstIndex(of: "T"), let end = stamp.index(t, offsetBy: 9, limitedBy: stamp.endIndex) else { return stamp }
        var rest = stamp[end...]
        var digits = ""
        if rest.first == "." {
            rest = rest.dropFirst()
            digits = String(rest.prefix { $0.isNumber })
            rest = rest.dropFirst(digits.count)
        }
        return String(stamp[..<end]) + "." + digits.padding(toLength: 9, withPad: "0", startingAt: 0) + rest
    }

    /// `2026-10-27T10:00:00.123456789Z` → its Unix second.
    nonisolated static func seconds(_ stamp: String) -> Int? {
        let whole = stamp.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        return ISO8601DateFormatter().date(from: whole).map { Int($0.timeIntervalSince1970) }
    }
}
