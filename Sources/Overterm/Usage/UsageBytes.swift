import Foundation

/// Reading numbers, strings and timestamps straight out of a log line's
/// bytes. The lines are huge — a tool result can be megabytes — and the
/// usage pane walks tens of thousands of them, so nothing here parses JSON
/// or builds a `Date` through a formatter.
enum UsageBytes {
    static func key(_ text: String) -> [UInt8] { Array(text.utf8) }

    static func find(_ needle: [UInt8], in line: UnsafeRawBufferPointer) -> Int? {
        guard let base = line.baseAddress, line.count >= needle.count else { return nil }
        return needle.withUnsafeBytes { n in
            memmem(base, line.count, n.baseAddress, needle.count).map { UnsafeRawPointer($0) - base }
        }
    }

    static func has(_ needle: [UInt8], in line: UnsafeRawBufferPointer) -> Bool { find(needle, in: line) != nil }

    /// The characters after `key` up to the next quote.
    static func string(after key: [UInt8], in line: UnsafeRawBufferPointer) -> String? {
        guard let at = find(key, in: line) else { return nil }
        let from = at + key.count
        var to = from
        while to < line.count, line[to] != UInt8(ascii: "\"") { to += 1 }
        guard to < line.count else { return nil }
        return String(decoding: UnsafeRawBufferPointer(rebasing: line[from..<to]), as: UTF8.self)
    }

    /// The whole number after `key`; 0 when the key isn't there, which is
    /// what a missing count means in every log here.
    static func int(after key: [UInt8], in line: UnsafeRawBufferPointer) -> Int {
        guard let at = find(key, in: line) else { return 0 }
        var i = at + key.count
        var value = 0
        while i < line.count, line[i] >= 48, line[i] <= 57 {
            value = value * 10 + Int(line[i] - 48)
            i += 1
        }
        return value
    }

    /// An ISO timestamp written as the logs write it —
    /// "2026-10-15T14:23:45.123Z" or "…+00:00" — to the second, in UTC.
    /// `ISO8601DateFormatter` costs microseconds each and is wrong for one
    /// of those two shapes depending on how it is configured.
    static func instant(_ text: String) -> Date? {
        instant(Array(text.utf8)[...])
    }

    static func instant(_ digits: ArraySlice<UInt8>) -> Date? {
        let d = Array(digits)
        guard d.count >= 19 else { return nil }
        func number(_ range: Range<Int>) -> Int? {
            var value = 0
            for i in range {
                guard d[i] >= 48, d[i] <= 57 else { return nil }
                value = value * 10 + Int(d[i] - 48)
            }
            return value
        }
        guard let year = number(0..<4), let month = number(5..<7), let day = number(8..<10),
            let hour = number(11..<13), let minute = number(14..<16), let second = number(17..<19)
        else { return nil }
        return Date(timeIntervalSince1970: epoch(year: year, month: month, day: day) + Double(hour * 3600 + minute * 60 + second))
    }

    /// Seconds from 1970 to midnight UTC on a civil date — the usual
    /// days-from-civil arithmetic, so no calendar is involved.
    static func epoch(year: Int, month: Int, day: Int) -> Double {
        let y = year - (month <= 2 ? 1 : 0)
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return Double((era * 146_097 + doe - 719_468) * 86_400)
    }

    /// The timestamp a log line starts or ends with, whichever it has.
    /// Only the ends of a line are searched: the middle is tool output.
    static let edge = 1024

    static func timestamp(_ key: [UInt8], in line: UnsafeRawBufferPointer) -> Date? {
        let head = UnsafeRawBufferPointer(rebasing: line[..<min(line.count, edge)])
        let tail = UnsafeRawBufferPointer(rebasing: line[max(0, line.count - edge)...])
        return (string(after: key, in: head) ?? string(after: key, in: tail)).flatMap(instant)
    }
}
