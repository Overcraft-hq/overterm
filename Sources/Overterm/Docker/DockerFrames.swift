import Foundation

/// A log line as the engine sends it: which stream it came on and its
/// text (a timestamp first, when asked for).
struct DockerLogChunk: Equatable, Sendable {
    enum Stream: UInt8, Sendable {
        case stdin = 0, stdout = 1, stderr = 2
    }

    var stream: Stream
    var text: String
}

/// Docker's log stream for a container without a TTY: frames of an 8-byte
/// header — the stream (0, 1, 2), three zeros, the length big-endian — then
/// that many bytes. A container with a TTY sends its bytes plain. Fed in
/// whatever pieces the socket gives; a frame cut in two waits for the rest.
/// Pure.
struct DockerLogDemuxer: Sendable {
    /// False for a TTY's plain bytes (ContainerDetail.Config.Tty).
    let framed: Bool
    private var pending = Data()

    init(framed: Bool) {
        self.framed = framed
    }

    mutating func feed(_ data: Data) -> [DockerLogChunk] {
        guard framed else { return [DockerLogChunk(stream: .stdout, text: String(decoding: data, as: UTF8.self))] }
        pending.append(data)
        var chunks: [DockerLogChunk] = []
        var offset = pending.startIndex
        while pending.endIndex - offset >= 8 {
            let header = pending[offset..<offset + 8]
            let kind = header[header.startIndex]
            let length = header.dropFirst(4).reduce(0) { $0 << 8 | Int($1) }
            guard pending.endIndex - offset - 8 >= length else { break }
            let body = pending[offset + 8..<offset + 8 + length]
            chunks.append(DockerLogChunk(stream: DockerLogChunk.Stream(rawValue: kind) ?? .stdout, text: String(decoding: body, as: UTF8.self)))
            offset += 8 + length
        }
        pending = Data(pending[offset...])
        return chunks
    }
}

/// Newline-delimited JSON (events, stats, a pull's progress), fed in
/// pieces: whole lines out, the last half line kept. Pure.
struct DockerLineSplitter: Sendable {
    private var pending = Data()

    mutating func feed(_ data: Data) -> [Data] {
        pending.append(data)
        var lines: [Data] = []
        while let newline = pending.firstIndex(of: 0x0A) {
            let line = pending[pending.startIndex..<newline]
            if !line.isEmpty { lines.append(Data(line)) }
            pending = Data(pending[pending.index(after: newline)...])
        }
        return lines
    }

    /// The half line left at the end, if any — emptied: what a stream that
    /// ended without a last newline still said.
    mutating func finish() -> Data? {
        defer { pending = Data() }
        return pending.isEmpty ? nil : pending
    }
}

/// A log line, read: when, how bad, and its text as a person reads it —
/// a JSON line's message pulled out, the rest of it kept. Pure.
struct DockerLogLine: Equatable, Sendable {
    enum Level: Int, Comparable, Sendable {
        case trace, debug, info, warning, error, fatal

        static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
    }

    var stream: DockerLogChunk.Stream
    /// The engine's timestamp (`timestamps=1`), as it wrote it.
    var timestamp: String?
    var level: Level?
    /// What is shown: a JSON line's `msg`/`message`, else the line.
    var message: String
    /// A JSON line's other fields, `key=value`.
    var fields: [(String, String)]
    /// The compose service, in a project's merged logs.
    var service: String?

    /// The line as plain text, as an agent reads it: its time, its level,
    /// its message, then a JSON line's fields.
    var plain: String {
        [timestamp, level.map { "\($0)".uppercased() }, message].compactMap { $0 }.joined(separator: " ")
            + (fields.isEmpty ? "" : "  " + fields.map { "\($0.0)=\($0.1)" }.joined(separator: " "))
    }

    static func == (a: DockerLogLine, b: DockerLogLine) -> Bool {
        a.stream == b.stream && a.timestamp == b.timestamp && a.level == b.level && a.message == b.message && a.service == b.service
            && a.fields.map { "\($0.0)=\($0.1)" } == b.fields.map { "\($0.0)=\($0.1)" }
    }

    /// One chunk may hold several lines (and the engine's timestamp starts
    /// each one). Split on any newline: `\r\n` is one Character, which a
    /// split on `\n` leaves whole.
    static func lines(of chunk: DockerLogChunk, timestamps: Bool, service: String? = nil) -> [DockerLogLine] {
        chunk.text.split(whereSeparator: \.isNewline).map {
            parse(String($0), stream: chunk.stream, timestamps: timestamps, service: service)
        }
    }

    static func parse(_ raw: String, stream: DockerLogChunk.Stream, timestamps: Bool, service: String? = nil) -> DockerLogLine {
        var text = raw
        var timestamp: String?
        if timestamps, let space = text.firstIndex(of: " "), text[..<space].contains("T") {
            timestamp = String(text[..<space])
            text = String(text[text.index(after: space)...])
        }
        let plain = stripANSI(text)
        if plain.hasPrefix("{"), let json = try? JSONSerialization.jsonObject(with: Data(plain.utf8)) as? [String: Any] {
            let messageKey = ["msg", "message", "Message", "MESSAGE", "event"].first { json[$0] is String }
            let levelKey = ["level", "lvl", "severity", "Level", "levelname", "log.level"].first { json[$0] != nil }
            let skipped = Set([messageKey, levelKey, "time", "ts", "timestamp", "@timestamp"].compactMap { $0 })
            let fields = json.keys.sorted().filter { !skipped.contains($0) }.map { ($0, "\(json[$0]!)") }
            return DockerLogLine(
                stream: stream, timestamp: timestamp, level: levelKey.flatMap { level(of: "\(json[$0]!)") },
                message: messageKey.flatMap { json[$0] as? String } ?? plain, fields: fields, service: service)
        }
        return DockerLogLine(
            stream: stream, timestamp: timestamp, level: inlineLevel(plain), message: plain, fields: [],
            service: service)
    }

    static func level(of word: String) -> Level? {
        switch word.lowercased() {
        case "trace": .trace
        case "debug", "dbg": .debug
        case "info", "information", "notice": .info
        case "warn", "warning": .warning
        case "error", "err": .error
        case "fatal", "panic", "critical", "crit", "emergency": .fatal
        default: Int(word).flatMap(pinoLevel)
        }
    }

    /// Pino and Bunyan write numbers: 10 trace … 60 fatal.
    private static func pinoLevel(_ number: Int) -> Level? {
        switch number {
        case 10: .trace
        case 20: .debug
        case 30: .info
        case 40: .warning
        case 50: .error
        case 60: .fatal
        default: nil
        }
    }

    /// `level=error`, `[ERROR]`, `ERROR:`, `E1027` (glog) and the like near
    /// the start of a plain line.
    static func inlineLevel(_ line: String) -> Level? {
        let head = String(line.prefix(80))
        if let range = head.range(of: #"level=(\w+)"#, options: .regularExpression) {
            return level(of: String(head[range].dropFirst("level=".count)))
        }
        for word in ["FATAL", "PANIC", "ERROR", "WARNING", "WARN", "INFO", "DEBUG", "TRACE"] {
            let pattern = #"(^|[\s\[|])"# + word + #"([\]:|\s]|$)"#
            if head.range(of: pattern, options: .regularExpression) != nil { return level(of: word) }
        }
        return nil
    }

    /// Colour codes out: the line is searched and shown as text (the
    /// terminal tab shows it in colour).
    static func stripANSI(_ text: String) -> String {
        guard text.contains("\u{1B}") else { return text }
        return text.replacingOccurrences(of: #"\x1B\[[0-9;?]*[ -/]*[@-~]"#, with: "", options: .regularExpression)
    }
}
