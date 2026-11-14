import Foundation

/// A log line, read: when, how bad, and its text as a person reads it —
/// a JSON line's message pulled out, the rest of it kept — whoever wrote
/// it (a container's log, a pod's). Pure.
struct LogLine: Equatable, Sendable {
    enum Level: Int, Comparable, Sendable {
        case trace, debug, info, warning, error, fatal

        static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
    }

    /// Which of the two it was written to: stderr's unlevelled lines count
    /// as warnings in a filter.
    enum Stream: Sendable {
        case stdout, stderr
    }

    var stream: Stream
    /// The timestamp its source put first (Docker's `timestamps=1`), as it
    /// was written: RFC 3339, a fraction perhaps.
    var timestamp: String?
    var level: Level?
    /// What is shown: a JSON line's `msg`/`message`, else the line.
    var message: String
    /// A JSON line's other fields, `key=value`.
    var fields: [(String, String)]
    /// Whose it is in merged logs: a compose project's service; nil in
    /// one source's own log.
    var source: String?

    /// The line as plain text, as an agent reads it: its time, its level,
    /// its message, then a JSON line's fields.
    var plain: String {
        [timestamp, level.map { "\($0)".uppercased() }, message].compactMap { $0 }.joined(separator: " ")
            + (fields.isEmpty ? "" : "  " + fields.map { "\($0.0)=\($0.1)" }.joined(separator: " "))
    }

    static func == (a: LogLine, b: LogLine) -> Bool {
        a.stream == b.stream && a.timestamp == b.timestamp && a.level == b.level && a.message == b.message && a.source == b.source
            && a.fields.map { "\($0.0)=\($0.1)" } == b.fields.map { "\($0.0)=\($0.1)" }
    }

    static func parse(_ raw: String, stream: Stream, timestamps: Bool, source: String? = nil) -> LogLine {
        var text = raw
        var timestamp: String?
        // RFC 3339's shape only (a digit first, a T in it): a line's first
        // word that merely has a T ("Timeout reached") is no time.
        if timestamps, let space = text.firstIndex(of: " "), text.first?.isASCII == true, text.first?.isNumber == true, text[..<space].contains("T") {
            timestamp = String(text[..<space])
            text = String(text[text.index(after: space)...])
        }
        let plain = stripANSI(text)
        if plain.hasPrefix("{"), let json = try? JSONSerialization.jsonObject(with: Data(plain.utf8)) as? [String: Any] {
            let messageKey = ["msg", "message", "Message", "MESSAGE", "event"].first { json[$0] is String }
            let levelKey = ["level", "lvl", "severity", "Level", "levelname", "log.level"].first { json[$0] != nil }
            let skipped = Set([messageKey, levelKey, "time", "ts", "timestamp", "@timestamp"].compactMap { $0 })
            let fields = json.keys.sorted().filter { !skipped.contains($0) }.map { ($0, "\(json[$0]!)") }
            return LogLine(
                stream: stream, timestamp: timestamp, level: levelKey.flatMap { level(of: "\(json[$0]!)") },
                message: messageKey.flatMap { json[$0] as? String } ?? plain, fields: fields, source: source)
        }
        return LogLine(
            stream: stream, timestamp: timestamp, level: inlineLevel(plain), message: plain, fields: [],
            source: source)
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
