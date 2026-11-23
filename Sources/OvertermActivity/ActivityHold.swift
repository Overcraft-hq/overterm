import Foundation

/// When the list's order is held (docs/design/activity/analysis.md, 6.7):
/// a press resolves its row by index at release and a menu targets the ids
/// it captured as it opened, so with a CPU sort moving the rows every tick
/// the wrong row could be hit. The order holds while the pointer moves over
/// the list, while a press is in flight, while a menu or a sheet is open
/// and while VoiceOver's focus is in the table; values still update. It
/// lets go once the pointer has rested `rest` without a press, since people
/// rest it on a list while reading. Pure.
package struct ActivityHold: Equatable, Sendable {
    package static let rest: Duration = .seconds(5)

    package var hovering = false
    package var pressing = false
    package var menu = false
    package var sheet = false
    /// The pointer's last move over the list, or a press's end.
    package var lastMove: ContinuousClock.Instant?

    package mutating func note(_ interaction: ResourceTableInteraction, at now: ContinuousClock.Instant) {
        switch interaction {
        case .hover:
            hovering = true
            lastMove = now
        case .exit:
            hovering = false
            lastMove = nil
        case .pressBegan:
            pressing = true
        case .pressEnded:
            pressing = false
            lastMove = now
        case .menuOpened:
            menu = true
        case .menuClosed:
            menu = false
            lastMove = now
        }
    }

    /// Whether the order holds at `now`; `voiceOver` its focus in the list.
    package func holds(at now: ContinuousClock.Instant, voiceOver: Bool = false) -> Bool {
        if pressing || menu || sheet || voiceOver { return true }
        guard hovering, let lastMove else { return false }
        return now - lastMove < Self.rest
    }

    /// When a hold that only the pointer keeps lets go, if nothing moves.
    package var restsAt: ContinuousClock.Instant? {
        guard hovering, !pressing, !menu, !sheet, let lastMove else { return nil }
        return lastMove + Self.rest
    }
}

extension ActivityRows {
    /// `next`'s values in `shown`'s order (6.7): each row of `shown` takes
    /// its newer self where `next` has it, a row gone keeps its last
    /// values, and a new one waits for the hold to end — so no row moves,
    /// and `ResourceTable` draws again only the cells on screen. The counts
    /// and the meters are `next`'s.
    package static func held(_ shown: ActivityPageContent, _ next: ActivityPageContent) -> ActivityPageContent {
        var out = next
        let list = Dictionary(next.list.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        out.list = shown.list.map { list[$0.id] ?? $0 }
        let ports = Dictionary(next.ports.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        out.ports = shown.ports.map { ports[$0.id] ?? $0 }
        let processes = Dictionary(next.processes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        out.processes = shown.processes.map { processes[$0.id] ?? $0 }
        // The rows shown are the older census's: what came since is new
        // once it lets go (6.7).
        out.madeAt = shown.madeAt
        out.shownIDs = nil
        // The list's rows in the order shown, as `list` and `ports` are;
        // Left Behind's are `next`'s, as its items are.
        if shown.listRowsMade, next.listRowsMade {
            out.processRows = shown.processRows.taking(next.processRows)
            out.portRows = shown.portRows.taking(next.portRows)
        } else {
            out.listRowsMade = false
        }
        return out
    }

    /// `content` with its list's rows made (7.7): off the main thread, with
    /// the rest of it.
    package static func withListRows(_ content: ActivityPageContent) -> ActivityPageContent {
        var out = content
        out.processRows = ActivityListRows(content.list.map(ActivityListRow.init))
        out.leftBehindRows = ActivityListRows(content.leftBehind.map(ActivityListRow.init))
        out.portRows = ActivityListRows(content.ports.map(ActivityListRow.port))
        out.listRowsMade = true
        return out
    }

    /// Every row id `content` shows: what a selection is kept to.
    package static func shownIDs(_ content: ActivityPageContent) -> Set<String> {
        var ids = Set(content.processes.map(\.id))
        ids.reserveCapacity(content.processes.count + content.ports.count)
        for item in content.list { ids.insert(item.id) }
        for port in content.ports { ids.insert(port.id) }
        return ids
    }
}
