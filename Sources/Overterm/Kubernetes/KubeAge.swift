import Foundation

/// A row's age, as `kubectl get` says it, kept moving while the list shows.
/// Pure.
///
/// The server renders Age when it answers, so a row's cell goes stale the
/// moment it arrives. Where the row carries its metadata (across all
/// namespaces) the age is its `creationTimestamp`'s; with rows only (one
/// namespace, `includeObject=None` — 885 KB for 2886 pods, against 35 MB
/// with the metadata) the cell is all there is: the age is what it said
/// plus the time since it was received. A cell is rounded down as kubectl
/// rounds (`5d` is 5 to 6 days), so the age shown is never older than the
/// object.
enum KubeAge {
    /// Where a row's age is counted from.
    struct Anchor: Equatable, Sendable {
        /// The object's own creation time, when the row carried it.
        var created: Date?
        /// What the Age cell said, in seconds.
        var said: TimeInterval?
        /// When the row was received.
        var received: Date

        /// Its age at `now`, nil when neither is known.
        func age(at now: Date) -> TimeInterval? {
            if let created { return max(0, now.timeIntervalSince(created)) }
            guard let said else { return nil }
            return said + max(0, now.timeIntervalSince(received))
        }
    }

    /// A row's anchor: its creation time when it has one — the metadata's,
    /// or a `Created At` cell (a CRD's Table, a List read without Table
    /// support) — else its Age cell.
    static func anchor(_ row: KubeRow, columns: [KubeColumn], received: Date) -> Anchor {
        let createdAt = row.cell("Created At", in: columns).flatMap { try? Date($0.text, strategy: .iso8601) }
        return Anchor(created: row.created ?? createdAt, said: row.cell("Age", in: columns).flatMap { seconds($0.text) }, received: received)
    }

    /// kubectl's duration (`45s`, `5m30s`, `3h12m`, `2d3h`, `3y12d`) in
    /// seconds; nil for anything else (`<unknown>`, `<invalid>`, "").
    static func seconds(_ text: String) -> TimeInterval? {
        let units: [Character: TimeInterval] = ["s": 1, "m": 60, "h": 3600, "d": 86400, "y": 365 * 86400]
        var total: TimeInterval = 0
        var digits = ""
        var parts = 0
        for character in text.trimmingCharacters(in: .whitespaces) {
            if character.isASCII, character.isNumber {
                digits.append(character)
            } else if let unit = units[character], let number = Double(digits) {
                total += number * unit
                digits = ""
                parts += 1
            } else {
                return nil
            }
        }
        return parts > 0 && digits.isEmpty ? total : nil
    }

    /// `seconds` as kubectl says an age (apimachinery's `HumanDuration`):
    /// exact while short, coarser as it grows.
    static func format(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.down))
        if total < -1 { return "<invalid>" }
        if total < 0 { return "0s" }
        if total < 120 { return "\(total)s" }
        let minutes = total / 60
        if minutes < 10 {
            let rest = total % 60
            return rest == 0 ? "\(minutes)m" : "\(minutes)m\(rest)s"
        }
        if minutes < 180 { return "\(minutes)m" }
        let hours = total / 3600
        if hours < 8 {
            let rest = minutes % 60
            return rest == 0 ? "\(hours)h" : "\(hours)h\(rest)m"
        }
        if hours < 48 { return "\(hours)h" }
        if hours < 24 * 8 {
            let rest = hours % 24
            return rest == 0 ? "\(hours / 24)d" : "\(hours / 24)d\(rest)h"
        }
        if hours < 24 * 365 * 2 { return "\(hours / 24)d" }
        if hours < 24 * 365 * 8 {
            let rest = (hours / 24) % 365
            return rest == 0 ? "\(hours / 24 / 365)y" : "\(hours / 24 / 365)y\(rest)d"
        }
        return "\(hours / 24 / 365)y"
    }
}
