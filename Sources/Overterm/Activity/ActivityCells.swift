import Foundation

/// A plain cell of the page's list as words (docs/design/activity/
/// analysis.md, 6.5, 7.7): what `ActivityListView` draws as AppKit text
/// (`ResourceTextCell`), compared with what the cell shows so an unchanged
/// one isn't drawn again. Its colour a token, the theme's to resolve.
struct ActivityCellText: Equatable, Sendable {
    enum Tint: Equatable, Sendable { case text, text2, text3, signal }

    var text: String
    var tint: Tint
    /// A number: monospaced, against the trailing edge.
    var number = false
    var help: String? = nil
    /// A process row's: drawn dimmed once ended, tinted while new (6.7).
    var ended = false
    var isNew = false
}

/// Which cells are plain and what they say. Pure.
enum ActivityCells {
    /// `row`'s cell in `column` as words; nil where the list draws it with
    /// SwiftUI — a process's name and 15-minute strip, a container's name,
    /// a row laid across the columns. Nil depends only on the row's kind
    /// and the column (`ResourceTable.plainCell`'s rule).
    static func plain(_ row: ActivityListRow, _ column: String) -> ActivityCellText? {
        switch row {
        case .process(let process):
            guard column != "name", column != "cpu15", var cell = processCell(process, column) else { return nil }
            cell.ended = process.ended
            cell.isNew = process.isNew
            return cell
        case .port(let port): return port.kind == .folded ? nil : portCell(port, column)
        case .group(let group): return group.kind == .container && column != "name" ? containerCell(group, column) : nil
        }
    }

    private static func number(_ text: String, _ tint: ActivityCellText.Tint = .text2) -> ActivityCellText {
        ActivityCellText(text: text, tint: tint, number: true)
    }

    private static func text(_ text: String, _ tint: ActivityCellText.Tint, help: String? = nil) -> ActivityCellText {
        ActivityCellText(text: text, tint: tint, help: help)
    }

    private static func cpu(_ value: Double?) -> ActivityCellText {
        number(value.map(ActivityRows.percent) ?? "—", (value ?? 0) >= 50 ? .signal : .text2)
    }

    static func processCell(_ row: ActivityProcessRow, _ column: String) -> ActivityCellText? {
        switch column {
        case "pid": number(String(row.identity.pid))
        case "cpu": cpu(row.cpu)
        case "memory": number(row.memory.map(ActivityRows.bytes) ?? "—")
        case "threads": number(row.threads.map { String($0) } ?? "—")
        case "state": text(row.state.letter, row.state == .stopped || row.state == .zombie ? .signal : .text2)
        case "started": number(row.startedText)
        case "user": text(row.user, .text3)
        case "listening": text(ActivityPageView.ports(row.listening), .text2)
        case "where": text(row.whereText, .text2)
        case "rss": number(row.residentSize.map(ActivityRows.bytes) ?? "—")
        case "time": number(row.cpuTime.map(ActivityDetail.duration) ?? "—")
        case "nice": number(String(row.nice))
        case "priority": number(row.priority.map { String($0) } ?? "—")
        case "ppid": number(String(row.parentPID))
        case "pgid": number(String(row.group))
        case "tty": text(row.terminal ?? "", .text3)
        case "kind": text(row.translated ? "Intel" : "Apple", .text3)
        case "path": text(row.path ?? "", .text3)
        case "command": text(row.command ?? "", .text2)
        case "energy": number(ActivityPageView.rate(row.energy, unit: "W"))
        case "wakeups": number(row.idleWakeups.map { ActivityRows.fixed($0, digits: 0) } ?? "—")
        case "diskRead": number(ActivityPageView.rate(row.diskRead, unit: "B/s"))
        case "diskWritten": number(ActivityPageView.rate(row.diskWritten, unit: "B/s"))
        case "sleep": text(row.sleepHold.map { $0.isEmpty ? "No" : $0.text } ?? "—", row.sleepHold?.isEmpty == false ? .text : .text3)
        default: text("", .text2)
        }
    }

    static func portCell(_ row: ActivityPortRow, _ column: String) -> ActivityCellText {
        switch column {
        case "port":
            if row.kind == .unix { return text((row.address as NSString).abbreviatingWithTildeInPath, .text, help: row.address) }
            return number(row.kind == .connection ? "→ :\(row.port)" : ":\(row.port)", row.kind == .connection ? .text2 : .text)
        case "proto": return text(row.proto, .text2)
        case "address":
            return text(
                row.reach, row.scope == .thisMac && row.forwardedBy == nil ? .text2 : .signal,
                help: row.scope == .network ? "Anything that can route to this Mac reaches it — over IPv6 that may be the internet" : nil)
        case "families": return text(row.familyWords, .text3)
        case "owner": return text(row.ownerText, row.portOwner == .pane ? .text2 : .text)
        case "process": return text(row.processText, row.kind == .connection ? .text2 : .text)
        case "pid": return number(row.holder.map { String($0.pid) } ?? "")
        case "where": return text(row.whereText, .text2)
        case "clients": return number(row.kind == .listener && row.clients > 0 ? String(row.clients) : "")
        case "note": return text(row.note ?? "", row.collisions.isEmpty ? .text3 : .signal, help: row.note)
        case "since": return text(row.sinceText, .text2)
        case "backlog":
            return text(
                row.backlogLimit > 0 ? (row.backlogFull ? "full — not accepting" : "\(row.backlog) of \(row.backlogLimit)") : "",
                row.backlogFull ? .signal : .text3)
        default: return text("", .text2)
        }
    }

    static func containerCell(_ row: ActivityGroupRow, _ column: String) -> ActivityCellText {
        switch column {
        case "cpu": cpu(row.cpu)
        case "memory": number(row.memory.map(ActivityRows.bytes) ?? "—")
        default: text("", .text2)
        }
    }
}
