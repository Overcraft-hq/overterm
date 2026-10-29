import Foundation

/// One line of BuildKit's `--progress rawjson`: a SolveStatus as
/// client/graph.go's json tags write it — Go's encoder, so `[]byte` is
/// base64 and times are RFC 3339 with up to nine fraction digits. Fields
/// a newer BuildKit adds are ignored. Pure.
struct DockerSolveStatus: Decodable, Sendable {
    struct Vertex: Decodable, Sendable {
        var digest: String
        var inputs: [String]?
        var name: String?
        var started: Date?
        var completed: Date?
        var cached: Bool?
        var error: String?
    }

    /// A step's sub-progress: a layer pulled, the context sent, an image named.
    struct Status: Decodable, Sendable {
        var id: String
        var vertex: String?
        var name: String?
        var total: Int64?
        var current: Int64?
        var timestamp: Date?
        var started: Date?
        var completed: Date?
    }

    struct Log: Decodable, Sendable {
        var vertex: String?
        /// 1 stdout, 2 stderr.
        var stream: Int?
        var data: Data
        var timestamp: Date?
    }

    /// A Dockerfile check's (BuildKit's lint): `short` and `detail` are bytes.
    struct Warning: Decodable, Sendable {
        var vertex: String?
        var level: Int?
        var short: Data?
        var detail: [Data]?
        var url: String?
        var sourceInfo: SourceInfo?
        var range: [Range]?
    }

    struct SourceInfo: Decodable, Sendable {
        var filename: String?
        var data: Data?
        var language: String?
    }

    struct Range: Decodable, Sendable {
        var start: Position?
        var end: Position?
    }

    struct Position: Decodable, Sendable {
        var line: Int?
        var character: Int?
    }

    var vertexes: [Vertex]?
    var statuses: [Status]?
    var logs: [Log]?
    var warnings: [Warning]?

    /// Go's RFC3339Nano: `10:00:00Z`, `10:00:00.01Z`, `10:00:00.123456789Z`,
    /// an offset instead of Z. The fraction is added to the whole second,
    /// so its digits are never cut to what a formatter reads. Go's zero
    /// time (`0001-01-01T00:00:00Z`, a time that was never set) is
    /// `distantPast`, which the fold reads as no time.
    static func date(_ text: String) -> Date? {
        if text.hasPrefix("0001-01-01T00:00:00") { return .distantPast }
        var whole = text
        var fraction = 0.0
        if let dot = text.firstIndex(of: ".") {
            let digits = text[text.index(after: dot)...].prefix(while: { $0.isASCII && $0.isNumber })
            fraction = Double("0." + digits) ?? 0
            whole = String(text[..<dot]) + text[digits.endIndex...]
        }
        return wholeSeconds.date(from: whole).map { $0.addingTimeInterval(fraction) }
    }

    /// Thread-safe, and parsing runs off the main thread at high rates.
    nonisolated(unsafe) private static let wholeSeconds = ISO8601DateFormatter()

    static func decode(_ data: Data) throws -> DockerSolveStatus {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            guard let date = date(text) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "not a time: \(text)"))
            }
            return date
        }
        return try decoder.decode(DockerSolveStatus.self, from: data)
    }
}

/// A build's steps as BuildKit reports them, folded as its plain printer
/// (`--progress plain`) folds them: a step numbered when it first starts,
/// its time its intervals merged, its output in lines. The same for a
/// running build and a finished record's replay. Pure.
struct DockerBuildProgress: Sendable {
    enum Update: Sendable {
        case status(DockerSolveStatus)
        /// A line that isn't one: what buildx said (an error, mostly).
        case said(String)
    }

    /// Off the main thread: a line → what it says; nil for an empty line.
    static func decode(_ line: String) -> Update? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("{"), let status = try? DockerSolveStatus.decode(Data(trimmed.utf8)) { return .status(status) }
        return .said(trimmed)
    }

    struct Step: Identifiable, Equatable, Sendable {
        /// `unknown`: still open when the stream broke off — it may have
        /// ended since, or still run; nothing here says which.
        enum State: Equatable, Sendable { case running, done, cached, failed, canceled, unknown }

        let digest: String
        var id: String { digest }
        /// `#N`: the order steps first started, as plain progress numbers
        /// them; 0 for one not started yet.
        fileprivate(set) var number: Int
        var name: String
        var cached: Bool
        var error: String?
        /// Start → stop, by start: a later copy of the same interval
        /// replaces it, as BuildKit's map does.
        var intervals: [Date: Date?]
        /// By id, in the order they started; each replaced on its update.
        var statuses: [Status]
        var log: [LogLine]
        var logBytes: Int
        var clipped: Bool
        var warnings: [Warning]
        /// Its last log's timestamp.
        var lastOutput: Date?

        /// `[internal]` and `[auth]`: BuildKit's own work, drawn dimmer.
        var isInternal: Bool { name.hasPrefix("[internal]") || name.hasPrefix("[auth]") }

        /// What it is now. An interval still open once the build has ended
        /// is a step stopped with it; once the stream was `lost`, one whose
        /// end isn't known.
        func state(ended: Bool, lost: Bool = false) -> State {
            if let error { return error.hasSuffix("context canceled") ? .canceled : .failed }
            if cached { return .cached }
            if merged.last.map({ $0.stop == nil }) == true { return ended ? .canceled : lost ? .unknown : .running }
            return .done
        }

        /// Its intervals merged, summed; an open one stops at `until`.
        func duration(until: Date) -> TimeInterval {
            merged.reduce(0) { $0 + max(0, ($1.stop ?? until).timeIntervalSince($1.start)) }
        }

        /// Overlapping intervals as one, by start; an open one takes in
        /// every one after it (progressui's `mergeIntervals`).
        var merged: [(start: Date, stop: Date?)] {
            let sorted = intervals.map { (start: $0.key, stop: $0.value) }.sorted { $0.start < $1.start }
            guard var current = sorted.first else { return [] }
            var out: [(start: Date, stop: Date?)] = []
            for next in sorted.dropFirst() {
                guard let stop = current.stop else { break }
                if stop < next.start {
                    out.append(current)
                    current = next
                } else if let nextStop = next.stop {
                    current.stop = max(stop, nextStop)
                } else {
                    current.stop = nil
                    break
                }
            }
            out.append(current)
            return out
        }

        /// Where its output's offsets count from: its most recent start.
        var lastStart: Date? { merged.last?.start }

        var startedAt: Date? { intervals.keys.min() }

        static func == (a: Step, b: Step) -> Bool {
            a.digest == b.digest && a.number == b.number && a.name == b.name && a.cached == b.cached && a.error == b.error && a.intervals == b.intervals
                && a.statuses == b.statuses && a.logBytes == b.logBytes && a.log.count == b.log.count && a.clipped == b.clipped
                && a.warnings == b.warnings && a.lastOutput == b.lastOutput
        }
    }

    struct Status: Equatable, Sendable {
        var id: String
        var current: Int64
        var total: Int64?
        var started: Date?
        var completed: Date?
        var timestamp: Date?

        /// As plain progress prints it, after `#N `: `sha256:… 3.64MB / 3.64MB 0.4s done`.
        var plain: String {
            var text = id
            if let total, total != 0 {
                text += " " + DockerBuildProgress.bytes(current) + " / " + DockerBuildProgress.bytes(total)
            } else if current != 0 {
                text += " " + DockerBuildProgress.bytes(current)
            }
            if let started, let end = completed ?? timestamp {
                let seconds = end.timeIntervalSince(started)
                if seconds > 0.01 { text += String(format: " %.1fs", seconds) }
            }
            if completed != nil { text += " done" }
            return text
        }
    }

    struct LogLine: Equatable, Sendable {
        /// Seconds since its step's most recent start.
        var offset: Double
        var text: String
        var stderr: Bool

        /// As plain progress prints it: three decimals under 10 s, two
        /// under 100, then one.
        var offsetText: String {
            String(format: offset < 10 ? "%.3f" : offset < 100 ? "%.2f" : "%.1f", offset)
        }
    }

    struct Warning: Equatable, Sendable {
        var short: String
        var detail: [String]
        var url: String?
        var file: String?
        var line: Int?
        /// That line of the Dockerfile.
        var source: String?
        /// The step's digest.
        var step: String?

        /// buildx's dedup ignores the vertex: a warning said again is one.
        func same(_ other: Warning) -> Bool { short == other.short && file == other.file && line == other.line }
    }

    /// `logLimit`: bytes of output kept a step — BuildKit's own default.
    init(logLimit: Int = 2 << 20) {
        self.logLimit = logLimit
    }

    let logLimit: Int
    private(set) var steps: [Step] = []
    /// Deduped, as buildx dedups them.
    private(set) var warnings: [Warning] = []
    /// The last 20 lines that weren't a SolveStatus: what buildx said.
    private(set) var said: [String] = []
    private(set) var ended = false
    /// The stream broke off before the build's end (`lose`).
    private(set) var lost = false
    /// The newest timestamp in the stream.
    private(set) var lastSeen: Date?

    private var index: [String: Int] = [:]
    /// Vertexes seen before they started: not a step yet, but what is said
    /// of them is kept for when they are.
    private var waiting: [String: Step] = [:]
    /// A step's half line: its bytes, and the offset of the log that began it.
    private var partial: [String: (data: Data, offset: Double, stderr: Bool)] = [:]

    mutating func apply(_ update: Update) {
        switch update {
        case .said(let line):
            said = Array((said + [line]).suffix(20))
        case .status(let status):
            for vertex in status.vertexes ?? [] { apply(vertex) }
            for status in status.statuses ?? [] { apply(status) }
            for warning in status.warnings ?? [] { apply(warning) }
            for log in status.logs ?? [] { apply(log) }
        }
    }

    /// Decode and apply, for tests.
    mutating func add(_ line: String) {
        if let update = Self.decode(line) { apply(update) }
    }

    /// The stream is over: each half line is a last line.
    mutating func end() {
        flushPartials()
        ended = true
    }

    /// The stream broke off before the build's end: each half line is a
    /// last line, and a step still open is no longer drawn as running —
    /// nothing here would say when it stops.
    mutating func lose() {
        flushPartials()
        lost = true
    }

    private mutating func flushPartials() {
        for digest in partial.keys.sorted() {
            guard let pending = partial.removeValue(forKey: digest) else { continue }
            change(digest) { step in step.log.append(Self.line(pending.data, offset: pending.offset, stderr: pending.stderr)) }
        }
    }

    func step(_ digest: String) -> Step? { index[digest].map { steps[$0] } }

    func state(of step: Step) -> Step.State { step.state(ended: ended, lost: lost) }

    /// The first that failed.
    var failedStep: Step? { steps.first { state(of: $0) == .failed } }

    /// The step a detail shows unless one is picked: the first that failed;
    /// else the running one that wrote last (a running one that wrote
    /// nothing after those that did, the higher number first); else the
    /// last that wrote anything; else the last.
    var automaticStep: Step? {
        if let failedStep { return failedStep }
        let running = steps.filter { state(of: $0) == .running }
        if let writing = running.max(by: { a, b in
            switch (a.lastOutput, b.lastOutput) {
            case (let x?, let y?) where x != y: x < y
            case (nil, .some): true
            case (.some, nil): false
            default: a.number < b.number
            }
        }) {
            return writing
        }
        return steps.last { !$0.log.isEmpty } ?? steps.last
    }

    struct Summary: Equatable, Sendable {
        var steps = 0
        var running = 0
        var done = 0
        var cached = 0
        var failed = 0
        var canceled = 0
        var unknown = 0
        var started: Date?
        var finished: Date?
    }

    var summary: Summary {
        var summary = Summary(steps: steps.count)
        for step in steps {
            switch state(of: step) {
            case .running: summary.running += 1
            case .done: summary.done += 1
            case .cached: summary.cached += 1
            case .failed: summary.failed += 1
            case .canceled: summary.canceled += 1
            case .unknown: summary.unknown += 1
            }
        }
        summary.started = steps.compactMap(\.startedAt).min()
        summary.finished = steps.flatMap { $0.intervals.values.compactMap { $0 } }.max()
        return summary
    }

    /// The earliest start to the latest stop — or to `now`, while the
    /// stream goes on. Never below 0 (a clock that is off).
    func elapsed(now: Date) -> TimeInterval? {
        let summary = summary
        guard let started = summary.started else { return nil }
        let end = ended || lost ? (summary.finished ?? started) : max(now, summary.finished ?? now)
        return max(0, end.timeIntervalSince(started))
    }

    /// The steps as `--progress plain` groups them, each once, in its last
    /// state; `secrets` taken out.
    func plainText(redacting secrets: [String] = []) -> String {
        let blocks = steps.map { step -> String in
            let mark = "#\(step.number) "
            var lines = [mark + step.name]
            lines += step.statuses.map { mark + $0.plain }
            lines += step.warnings.map { mark + "WARN: " + $0.short }
            lines += step.log.map { mark + $0.offsetText + " " + $0.text }
            switch state(of: step) {
            case .running, .unknown: break
            case .done: lines.append(mark + String(format: "DONE %.1fs", step.duration(until: lastSeen ?? Date())))
            case .cached: lines.append(mark + "CACHED")
            case .failed: lines.append(mark + "ERROR: " + (step.error ?? ""))
            case .canceled: lines.append(mark + "CANCELED")
            }
            return lines.joined(separator: "\n")
        }
        return DockerSecrets.redact(blocks.joined(separator: "\n\n") + (blocks.isEmpty ? "" : "\n"), values: secrets)
    }

    /// As plain progress (go-units, decimal): `214B`, `3.64MB`. Not
    /// localized: a log is read as BuildKit wrote it.
    static func bytes(_ count: Int64) -> String {
        guard count >= 1000 else { return "\(count)B" }
        var value = Double(count)
        var unit = 0
        let units = ["kB", "MB", "GB", "TB", "PB", "EB"]
        repeat {
            value /= 1000
            unit += 1
        } while value >= 1000 && unit < units.count
        return String(format: "%.2f", value) + units[unit - 1]
    }

    // MARK: Folding

    /// A time that was never set (Go's zero) is none.
    private static func when(_ date: Date?) -> Date? {
        guard let date, date > Date(timeIntervalSince1970: 0) else { return nil }
        return date
    }

    private mutating func seen(_ date: Date?) {
        guard let date = Self.when(date) else { return }
        if lastSeen.map({ date > $0 }) ?? true { lastSeen = date }
    }

    /// The step or the vertex waiting to be one, changed in place.
    private mutating func change(_ digest: String, _ body: (inout Step) -> Void) {
        if let at = index[digest] {
            body(&steps[at])
        } else if var step = waiting[digest] {
            body(&step)
            waiting[digest] = step
        }
    }

    private mutating func apply(_ vertex: DockerSolveStatus.Vertex) {
        let started = Self.when(vertex.started)
        let completed = Self.when(vertex.completed)
        seen(started)
        seen(completed)
        if let at = index[vertex.digest] {
            var step = steps[at]
            // A copy without `started` after it started doesn't reset it.
            if started != nil || step.intervals.isEmpty {
                step.name = vertex.name ?? step.name
                step.cached = vertex.cached ?? false
                step.error = vertex.error
            }
            if let started { step.intervals[started] = completed }
            steps[at] = step
            return
        }
        var step =
            waiting.removeValue(forKey: vertex.digest)
            ?? Step(
                digest: vertex.digest, number: 0, name: "", cached: false, error: nil, intervals: [:], statuses: [], log: [], logBytes: 0, clipped: false,
                warnings: [], lastOutput: nil)
        step.name = vertex.name ?? step.name
        step.cached = vertex.cached ?? false
        step.error = vertex.error
        if let started { step.intervals[started] = completed }
        // A step once it starts — or ends, is cached or fails without
        // having been said to start.
        guard started != nil || completed != nil || vertex.cached == true || vertex.error != nil else {
            waiting[vertex.digest] = step
            return
        }
        step.number = steps.count + 1
        index[vertex.digest] = steps.count
        steps.append(step)
    }

    private mutating func apply(_ status: DockerSolveStatus.Status) {
        guard let digest = status.vertex else { return }
        seen(status.timestamp)
        let new = Status(
            id: status.id, current: status.current ?? 0, total: status.total, started: Self.when(status.started), completed: Self.when(status.completed),
            timestamp: Self.when(status.timestamp))
        change(digest) { step in
            if let at = step.statuses.firstIndex(where: { $0.id == status.id }) {
                step.statuses[at] = new
            } else {
                step.statuses.append(new)
            }
        }
    }

    private mutating func apply(_ warning: DockerSolveStatus.Warning) {
        let line = warning.range?.first?.start?.line
        let source = line.flatMap { line -> String? in
            guard let data = warning.sourceInfo?.data, line > 0 else { return nil }
            let lines = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
            return line <= lines.count ? String(lines[line - 1]) : nil
        }
        let new = Warning(
            short: String(decoding: warning.short ?? Data(), as: UTF8.self), detail: (warning.detail ?? []).map { String(decoding: $0, as: UTF8.self) },
            url: warning.url, file: warning.sourceInfo?.filename, line: line, source: source, step: warning.vertex)
        if !warnings.contains(where: { $0.same(new) }) { warnings.append(new) }
        if let digest = warning.vertex {
            change(digest) { step in if !step.warnings.contains(where: { $0.same(new) }) { step.warnings.append(new) } }
        }
    }

    private mutating func apply(_ log: DockerSolveStatus.Log) {
        guard let digest = log.vertex, index[digest] != nil || waiting[digest] != nil else { return }
        let stamp = Self.when(log.timestamp)
        seen(stamp)
        let limit = logLimit
        var pending = partial.removeValue(forKey: digest)
        change(digest) { step in
            if let stamp { step.lastOutput = stamp }
            guard !step.clipped else { return }
            let offset = stamp.flatMap { stamp in step.lastStart.map { stamp.timeIntervalSince($0) } } ?? 0
            var data = log.data
            if step.logBytes + data.count > limit {
                data = data.prefix(max(0, limit - step.logBytes))
                step.clipped = true
            }
            step.logBytes += data.count
            let stderr = log.stream == 2
            var rest = data[...]
            while let newline = rest.firstIndex(of: 0x0A) {
                let piece = rest[rest.startIndex..<newline]
                if let begun = pending {
                    step.log.append(Self.line(begun.data + piece, offset: begun.offset, stderr: begun.stderr))
                    pending = nil
                } else {
                    step.log.append(Self.line(Data(piece), offset: offset, stderr: stderr))
                }
                rest = rest[rest.index(after: newline)...]
            }
            if !rest.isEmpty {
                if var begun = pending {
                    begun.data.append(contentsOf: rest)
                    pending = begun
                } else {
                    pending = (Data(rest), offset, stderr)
                }
            }
        }
        if let pending { partial[digest] = pending }
    }

    /// A line as a person reads it: UTF-8 decoded whole (a character split
    /// across messages was joined first), colour codes out, a progress bar
    /// redrawn with `\r` as its last drawing.
    private static func line(_ data: Data, offset: Double, stderr: Bool) -> LogLine {
        let text = DockerLogLine.stripANSI(String(decoding: data, as: UTF8.self))
        let drawn: String
        if text.unicodeScalars.contains("\r") {
            let segments = text.unicodeScalars.split(separator: "\r", omittingEmptySubsequences: true)
            drawn = segments.last.map { String(String.UnicodeScalarView($0)) } ?? ""
        } else {
            drawn = text
        }
        return LogLine(offset: offset, text: drawn, stderr: stderr)
    }
}
