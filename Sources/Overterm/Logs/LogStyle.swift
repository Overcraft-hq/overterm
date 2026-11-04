import AppKit

/// How a log line looks: its time dim, its level in its colour, a JSON
/// line's fields after its message. Pure but for the colours.
@MainActor
enum LogStyle {
    static let font = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)

    static func color(_ level: LogLine.Level?) -> NSColor? {
        switch level {
        case .fatal, .error: NSColor(srgbRed: 0.94, green: 0.36, blue: 0.34, alpha: 1)
        case .warning: TabStatusStyle.waitingNS
        case .debug, .trace: nil
        default: nil
        }
    }

    /// A source's colour in merged logs (a service's): the same one each
    /// time, told apart from its neighbours.
    static func sourceColor(_ source: String) -> NSColor {
        let palette: [NSColor] = [.systemTeal, .systemPurple, .systemOrange, .systemPink, .systemIndigo, .systemGreen, .systemYellow, .systemBlue]
        let sum = source.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0x7fff_ffff }
        return palette[sum % palette.count]
    }

    /// `2026-10-27T10:00:00.123456789Z` → `10:00:00.123`, local time.
    static func time(_ stamp: String) -> String {
        let trimmed = stamp.replacingOccurrences(of: #"(\.\d{3})\d+"#, with: "$1", options: .regularExpression)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: trimmed) ?? ISO8601DateFormatter().date(from: stamp) else { return stamp }
        return timeFormatter.string(from: date)
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    /// A search's match, marked rather than picked out.
    static let highlight = NSColor.systemYellow.withAlphaComponent(0.38)

    static func line(_ line: LogLine, text: NSColor, dim: NSColor, timestamps: Bool, highlight: NSRegularExpression? = nil) -> NSAttributedString {
        let out = NSMutableAttributedString()
        func add(_ string: String, _ color: NSColor) {
            out.append(NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color]))
        }
        if timestamps, let stamp = line.timestamp { add(time(stamp) + "  ", dim) }
        if let source = line.source { add(source + " | ", sourceColor(source)) }
        let levelColor = color(line.level)
        let body = line.stream == .stderr && levelColor == nil ? text.withAlphaComponent(0.85) : text
        add(line.message, levelColor ?? (line.level == .debug || line.level == .trace ? dim : body))
        if !line.fields.isEmpty { add("  " + line.fields.map { "\($0.0)=\($0.1)" }.joined(separator: " "), dim) }
        if let highlight {
            for match in highlight.matches(in: out.string, range: NSRange(location: 0, length: out.length)) where match.range.length > 0 {
                out.addAttribute(.backgroundColor, value: Self.highlight, range: match.range)
            }
        }
        return out
    }
}
