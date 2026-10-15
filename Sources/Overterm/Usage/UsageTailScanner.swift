import Foundation

/// Tokens cut by the hour they were spent in and the model that spent
/// them: an hour falls on one side of "today" wherever you are, and the
/// model is what gives tokens a price.
struct UsageSlice: Equatable, Sendable {
    struct Key: Hashable, Sendable {
        let hour: Date
        /// Empty when the log never named a model.
        let model: String
    }

    let hour: Date
    let model: String
    var tokens: UsageTokens
}

/// Reads the end of a log, backwards, until it is older than you asked for.
///
/// The usage pane adds up a day or a month of agent logs, and those logs are
/// enormous: 643 MB of Claude transcripts here, 471 MB of it written today,
/// and 217 MB of Codex rollouts. Reading them forwards — even incrementally,
/// as `ClaudeUsageReader` does for one session — means reading all of it the
/// first time the pane opens.
///
/// Backwards, a day costs about 0.1 MB per transcript. It works because the
/// lines that carry usage are written in order within a file (24,603
/// assistant lines across the six newest transcripts here, not one of them
/// out of order), so the first one older than the window is the end of the
/// read. Other lines — attachments, queued operations — are *not* ordered,
/// by up to five hours, so only the lines that carry usage may stop it.
///
/// What a scan found is kept against the file's size and modification date,
/// so a log nobody has written to since is never read twice.
final class UsageTailScanner: @unchecked Sendable {
    /// What one file's tail added up to, and what it was when we read it.
    private struct Scanned {
        let size: UInt64
        let modified: Date
        let since: Date
        let slices: [UsageSlice.Key: UsageTokens]
    }

    private let lock = NSLock()
    private var scanned = RecentlyUsed<URL, Scanned>(capacity: 240)
    var tracked: Int { lock.withLock { scanned.count } }

    /// Bytes per step of the walk back. A day of one transcript fits in the
    /// first of these; the loop takes another when it hasn't reached far
    /// enough back yet.
    static let step = 256 << 10
    /// Where a walk gives up, so a pathological file can't hold the pane:
    /// 64 MB is two months of the busiest transcript on this Mac.
    static let limit = 64 << 20

    /// Adds up `file`'s tokens from `since` onwards, by the hour and the
    /// model they were spent on. Blocking; call off the main thread.
    func slices(of file: URL, since: Date, parse: (UnsafeRawBufferPointer) -> UsageLine?) -> [UsageSlice.Key: UsageTokens] {
        let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let size = UInt64(values?.fileSize ?? 0)
        let modified = values?.contentModificationDate ?? .distantPast
        if let known = lock.withLock({ scanned[file] }), known.size == size, known.modified == modified, known.since <= since {
            // Read already, and it reached further back than this window
            // wants: keep only the hours asked for.
            return known.slices.filter { $0.key.hour >= Self.hour(of: since) }
        }
        guard size > 0, let handle = try? FileHandle(forReadingFrom: file) else { return [:] }
        defer { try? handle.close() }

        var totals = [UsageSlice.Key: UsageTokens]()
        var seen = Set<String>()
        var end = size
        var carry = Data()
        var reachedBack = false
        while end > 0, size - end < UInt64(Self.limit), !reachedBack {
            let length = UInt64(min(Self.step, Int(end)))
            let start = end - length
            try? handle.seek(toOffset: start)
            var data = autoreleasepool { handle.readData(ofLength: Int(length)) }
            data.append(carry)
            // The first line of a chunk is half a line unless we are at the
            // start of the file; it is carried into the next step.
            var from = data.startIndex
            if start > 0 {
                guard let newline = data.firstIndex(of: 0x0A) else {
                    carry = data
                    end = start
                    continue
                }
                carry = data[data.startIndex...newline]
                from = data.index(after: newline)
            } else {
                carry = Data()
            }
            reachedBack = Self.consume(data[from...], since: since, into: &totals, seen: &seen, parse: parse)
            end = start
        }

        lock.withLock { scanned[file] = Scanned(size: size, modified: modified, since: since, slices: totals) }
        return totals
    }

    /// Walks a chunk's whole lines backwards. Returns true once a line that
    /// carries usage is older than `since` — everything before it in the
    /// file is older still.
    private static func consume(
        _ data: Data, since: Date, into totals: inout [UsageSlice.Key: UsageTokens], seen: inout Set<String>,
        parse: (UnsafeRawBufferPointer) -> UsageLine?
    ) -> Bool {
        var reached = false
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var lines = [(offset: Int, count: Int)]()
            var start = 0
            while start < raw.count {
                let rest = base + start
                let length = memchr(rest, 0x0A, raw.count - start).map { UnsafeRawPointer($0) - rest } ?? (raw.count - start)
                if length > 0 { lines.append((start, length)) }
                start += length + 1
            }
            for line in lines.reversed() {
                guard let found = parse(UnsafeRawBufferPointer(start: base + line.offset, count: line.count)) else { continue }
                if found.at < since {
                    reached = true
                    return
                }
                // A reply is written once per content block, with the same
                // usage each time; and a tail can be read twice across two
                // steps. Both are the same guard.
                if let id = found.id {
                    guard seen.insert(id).inserted else { continue }
                }
                let key = UsageSlice.Key(hour: hour(of: found.at), model: found.model ?? "")
                totals[key] = (totals[key] ?? UsageTokens()) + found.tokens
            }
        }
        return reached
    }

    /// The hour an instant falls in — the grain everything is bucketed at.
    static func hour(of date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 3600).rounded(.down) * 3600)
    }
}

/// One line of a log that carries usage, whoever wrote it.
struct UsageLine {
    /// When it was written.
    let at: Date
    /// What to charge it to, as the log names it; nil when it doesn't.
    var model: String?
    /// The reply's id, where the log repeats a reply (Claude Code does).
    var id: String?
    var tokens: UsageTokens
}
