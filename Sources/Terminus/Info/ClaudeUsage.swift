import Foundation

/// Token use of a Claude Code session, read from the transcript Claude Code
/// writes: ~/.claude/projects/<cwd, non-alphanumerics as "-">/<session>.jsonl.
/// Not a public API — if the format moves, this reads as "unknown" and the
/// tests say so.
struct ClaudeUsage: Equatable {
    var input = 0
    var output = 0
    var cacheRead = 0
    var cacheWrite = 0
    /// Distinct model replies.
    var replies = 0
    var model: String?
    var started: Date?
    var lastActivity: Date?

    var total: Int { input + output + cacheRead + cacheWrite }
}

/// Reads session transcripts incrementally: a transcript only grows, so after
/// the first read only the appended bytes are parsed.
final class ClaudeUsageReader: @unchecked Sendable {
    private struct Progress {
        var offset: UInt64 = 0
        /// Per reply id, its latest usage: Claude Code writes a reply once
        /// per content block, repeating the same usage (858 lines, 367
        /// replies in a real transcript) — summing lines would double-count.
        var replies: [String: (input: Int, output: Int, cacheRead: Int, cacheWrite: Int)] = [:]
        var model: String?
        /// Kept as text; turned into dates once per read, not once per line
        /// (date parsing was a third of a full read).
        var firstStamp: String?
        var lastStamp: String?
    }

    private let lock = NSLock()
    /// The transcripts read lately: a week of sessions would otherwise all
    /// stay here, each with everything parsed from it.
    private var progress = RecentlyUsed<URL, Progress>(capacity: 120)
    var trackedTranscripts: Int { lock.withLock { progress.count } }

    /// Where Claude Code keeps transcripts (an isolated run's own, see
    /// AppEnvironment). Overridable for tests.
    nonisolated(unsafe) static var projectsDirectory: URL = AppEnvironment.claudeProjectsDirectory

    /// Claude Code's folder name for a working directory: every character
    /// that isn't a letter or digit becomes "-" (/Users/b/.claude →
    /// -Users-b--claude).
    static func projectFolder(for directory: String) -> String {
        String(directory.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
    }

    /// The most recently written transcript for a working directory.
    static func latestSession(for directory: String) -> URL? {
        let folder = projectsDirectory.appendingPathComponent(projectFolder(for: directory))
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return
            files
            .filter { $0.pathExtension == "jsonl" }
            .max {
                let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return a < b
            }
    }

    /// Usage of the latest session in `directory`. Blocking; call off main.
    func usage(for directory: String) -> ClaudeUsage? {
        guard let file = Self.latestSession(for: directory) else { return nil }
        return usage(of: file)
    }

    /// Bytes read per step: memory stays flat however big the transcript
    /// (real ones pass a gigabyte).
    static let chunkSize = 8 << 20

    func usage(of file: URL) -> ClaudeUsage? {
        lock.lock()
        defer { lock.unlock() }
        var state = progress[file] ?? Progress()
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        if size < state.offset { state = Progress() }  // rewritten: start over
        try? handle.seek(toOffset: state.offset)

        var carry = Data()
        while true {
            let chunk = handle.readData(ofLength: Self.chunkSize)
            if chunk.isEmpty { break }
            var data = carry
            data.append(chunk)
            // Only whole lines: the last one may still be being written.
            guard let lastNewline = data.lastIndex(of: 0x0A) else {
                carry = data
                continue
            }
            let complete = data[data.startIndex...lastNewline]
            consume(complete, into: &state)
            state.offset += UInt64(complete.count)
            carry = Data(data[data.index(after: lastNewline)...])
        }
        progress[file] = state

        var usage = ClaudeUsage(
            model: state.model, started: state.firstStamp.flatMap(timestamp.date(from:)),
            lastActivity: state.lastStamp.flatMap(timestamp.date(from:)))
        for reply in state.replies.values {
            usage.input += reply.input
            usage.output += reply.output
            usage.cacheRead += reply.cacheRead
            usage.cacheWrite += reply.cacheWrite
        }
        usage.replies = state.replies.count
        return usage
    }

    /// Used under `lock` only (a formatter isn't thread-safe to share).
    private let timestamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let timestampKey = Array(#""timestamp":""#.utf8)
    private static let assistantKey = Array(#""type":"assistant""#.utf8)
    /// The reply's id: a transcript line has no top-level "id", and the
    /// message's own comes before its content (whose tool blocks have ids).
    private static let idKey = Array(#""id":""#.utf8)
    private static let modelKey = Array(#""model":""#.utf8)
    private static let usageKey = Array(#""usage":{"#.utf8)
    private static let inputKey = Array(#""input_tokens":"#.utf8)
    private static let outputKey = Array(#""output_tokens":"#.utf8)
    private static let cacheReadKey = Array(#""cache_read_input_tokens":"#.utf8)
    private static let cacheWriteKey = Array(#""cache_creation_input_tokens":"#.utf8)

    /// Most lines are huge tool results nobody needs here, so a line is only
    /// searched for a few keys, and no JSON is parsed at all.
    private func consume(_ data: Data, into state: inout Progress) {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            let count = raw.count
            var start = 0
            while start < count {
                let rest = base + start
                let length = memchr(rest, 0x0A, count - start).map { UnsafeRawPointer($0) - rest } ?? (count - start)
                let line = UnsafeRawBufferPointer(start: rest, count: length)
                handle(line, state: &state)
                start += length + 1
            }
        }
    }

    /// How much of a line's ends to search. A transcript line puts its
    /// top-level "type" and (usually) "timestamp" after the message — at
    /// most ~420 bytes from the end in a real 1 GB transcript — while the
    /// middle can be megabytes of tool output. Searching only the ends made
    /// a full read ~5x faster.
    private static let edge = 1024

    private func handle(_ line: UnsafeRawBufferPointer, state: inout Progress) {
        let tail = UnsafeRawBufferPointer(rebasing: line[max(0, line.count - Self.edge)...])
        let head = UnsafeRawBufferPointer(rebasing: line[..<min(line.count, Self.edge)])
        if let stamp = Self.string(after: Self.timestampKey, in: tail) ?? Self.string(after: Self.timestampKey, in: head) {
            if state.firstStamp == nil { state.firstStamp = stamp }
            state.lastStamp = stamp
        }
        guard Self.find(Self.assistantKey, in: tail) != nil,
            let id = Self.string(after: Self.idKey, in: line),
            let usageStart = Self.find(Self.usageKey, in: line)
        else { return }
        // The four counts, read straight from the usage object's bytes —
        // parsing it as JSON 22k times dominated a full read. Each key starts
        // with a quote, so "input_tokens" can't match inside
        // "cache_read_input_tokens".
        let usage = UnsafeRawBufferPointer(rebasing: line[usageStart...])
        func count(_ key: [UInt8]) -> Int {
            guard let at = Self.find(key, in: usage) else { return 0 }
            var i = at + key.count
            var value = 0
            while i < usage.count, usage[i] >= 48, usage[i] <= 57 {
                value = value * 10 + Int(usage[i] - 48)
                i += 1
            }
            return value
        }
        state.replies[id] = (count(Self.inputKey), count(Self.outputKey), count(Self.cacheReadKey), count(Self.cacheWriteKey))
        if let model = Self.string(after: Self.modelKey, in: line), !model.hasPrefix("<") { state.model = model }
    }

    private static func find(_ needle: [UInt8], in line: UnsafeRawBufferPointer) -> Int? {
        guard let base = line.baseAddress, line.count >= needle.count else { return nil }
        return needle.withUnsafeBytes { n in
            memmem(base, line.count, n.baseAddress, needle.count).map { UnsafeRawPointer($0) - base }
        }
    }

    /// The characters after `key` up to the next `"`.
    private static func string(after key: [UInt8], in line: UnsafeRawBufferPointer) -> String? {
        guard let at = find(key, in: line) else { return nil }
        let from = at + key.count
        var to = from
        while to < line.count, line[to] != UInt8(ascii: "\"") { to += 1 }
        guard to < line.count else { return nil }
        return String(decoding: UnsafeRawBufferPointer(rebasing: line[from..<to]), as: UTF8.self)
    }
}
