import Foundation

/// A token count as the usage pane and Tab Info say it: 950, 12K, 3.4M.
package enum TokenCount {
    package nonisolated static func text(_ n: Int) -> String {
        switch n {
        case ..<1_000: return "\(n)"
        case ..<1_000_000: return String(format: n < 10_000 ? "%.1fK" : "%.0fK", Double(n) / 1_000)
        case ..<1_000_000_000: return String(format: n < 10_000_000 ? "%.1fM" : "%.0fM", Double(n) / 1_000_000)
        default: return String(format: "%.1fB", Double(n) / 1_000_000_000)
        }
    }
}

/// A process's numbers as Tab Info and the agent overview say them.
package enum InfoText {
    package nonisolated static func cpu(_ percent: Double?) -> String { percent.map { String(format: "%.0f%%", $0) } ?? "—" }
    /// "0 KB", never "Zero KB" (the formatter's default for 0).
    package nonisolated static func memory(_ bytes: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .memory
        formatter.allowsNonnumericFormatting = false
        return formatter.string(fromByteCount: Int64(bytes))
    }

    /// A query's or a call's time: "12 ms", "1.25 s".
    package nonisolated static func duration(_ seconds: TimeInterval) -> String {
        seconds < 1 ? "\(Int(seconds * 1000)) ms" : String(format: "%.2f s", seconds)
    }
}
