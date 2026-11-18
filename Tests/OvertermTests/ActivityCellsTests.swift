import AppKit
import XCTest

@testable import Overterm

/// The list's plain cells as words (`ActivityCells`): which columns are
/// AppKit text, what each says, its tint — what the table compares to skip
/// an unchanged cell. Every name is invented.
final class ActivityCellsTests: XCTestCase {
    private func row(cpu: Double? = 12.34, memory: UInt64? = 64 << 20) -> ActivityProcessRow {
        var row = ActivityProcessRow(
            id: "4242:1", identity: ActivityProcessID(pid: 4242, start: 1), name: "acme-server", cpu: cpu, memory: memory, threads: 7, state: .running,
            started: Date(timeIntervalSince1970: 0), startedText: "10:02", user: "fake", isOwn: true, tab: nil, tabTitle: nil)
        row.command = "node server.js --token=••••••"
        row.listening = [3000, 3001, 3002, 3003]
        return row
    }

    /// A process's name and strip, a container's name and a row laid across
    /// the columns are SwiftUI's; every other cell is words — by the row's
    /// kind and the column alone, as `ResourceTable.plainCell` requires.
    func testOnlyTheNameAndStripAreHosted() {
        let process = ActivityListRow.process(row())
        for column in ActivityColumns.processes.map(\.id) {
            let hosted = column == "name" || column == "cpu15"
            XCTAssertEqual(ActivityCells.plain(process, column) == nil, hosted, column)
            XCTAssertEqual(ActivityCells.plain(.process(row(cpu: nil, memory: nil)), column) == nil, hosted, "\(column): by kind and column, not value")
        }
        let container = ActivityGroupRow(id: "container:web", kind: .container, title: "web", cpu: 3, memory: 1 << 20)
        XCTAssertNil(ActivityCells.plain(.group(container), "name"))
        XCTAssertEqual(ActivityCells.plain(.group(container), "cpu")?.text, "3.0")
        let holder = ActivityProcessID(pid: 4242, start: 1)
        let port = ActivityPortRow(id: "l", port: 3000, proto: "tcp", address: "127.0.0.1", families: .v4, scope: .thisMac, process: "acme-server", holder: holder)
        for column in ActivityColumns.listening.map(\.id) { XCTAssertNotNil(ActivityCells.plain(.port(port), column), column) }
        XCTAssertEqual(ActivityCells.plain(.port(port), "port"), ActivityCellText(text: ":3000", tint: .text, number: true))
    }

    /// What each says: as the SwiftUI cells said it, numbers with a dot
    /// whatever the locale, the command only as masked, a busy CPU tinted.
    func testTheWordsAndTints() {
        let cells = ActivityListRow.process(row())
        XCTAssertEqual(ActivityCells.plain(cells, "pid"), ActivityCellText(text: "4242", tint: .text2, number: true))
        XCTAssertEqual(ActivityCells.plain(cells, "cpu"), ActivityCellText(text: "12.3", tint: .text2, number: true))
        XCTAssertEqual(ActivityCells.plain(.process(row(cpu: 50)), "cpu")?.tint, .signal)
        XCTAssertEqual(ActivityCells.plain(.process(row(cpu: nil)), "cpu")?.text, "—", "a first sample: never 0")
        XCTAssertEqual(ActivityCells.plain(cells, "memory")?.text, "64.0 MB")
        XCTAssertEqual(ActivityCells.plain(cells, "listening")?.text, ":3000 :3001 :3002 +1")
        XCTAssertEqual(ActivityCells.plain(cells, "command")?.text, "node server.js --token=••••••")
        XCTAssertEqual(ActivityCells.plain(cells, "started")?.text, "10:02")
        XCTAssertEqual(ActivityCells.plain(cells, "state"), ActivityCellText(text: "R", tint: .text2))
    }

    /// A value drawn changes only its own column's words; an ended or new
    /// row changes every cell's look.
    func testAChangeMovesOnlyItsColumns() {
        let before = row()
        var after = before
        after.cpu = 80
        for column in ActivityColumns.processes.map(\.id) {
            let a = ActivityCells.plain(.process(before), column)
            let b = ActivityCells.plain(.process(after), column)
            XCTAssertEqual(a != b, column == "cpu", column)
        }
        var ended = before
        ended.ended = true
        XCTAssertEqual(ActivityCells.plain(.process(ended), "pid")?.ended, true)
        var new = before
        new.isNew = true
        XCTAssertEqual(ActivityCells.plain(.process(new), "memory")?.isNew, true)
    }

    /// The name cell's fold takes its own click — the fold toggled, no row
    /// selected —; a press anywhere else is the row's, as every cell's.
    @MainActor
    func testTheNameCellsFoldTakesItsOwnClick() throws {
        let cell = ActivityNameCell()
        cell.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
        var folded: [(String, Bool)] = []
        cell.toggle = { folded.append(($0, $1)) }
        let value = ActivityNameValue(
            id: "4242:1", depth: 1, folded: false, chevron: .gray, symbol: nil, symbolColor: .labelColor, name: "acme-server",
            nameColor: .labelColor, chips: [.init(text: "MCP", color: .gray, stroke: .gray)], help: "in pane 1", size: 12, chipSize: 10)
        XCTAssertTrue(cell.show(value))
        XCTAssertFalse(cell.show(value), "the same value: nothing drawn again")
        cell.layoutSubtreeIfNeeded()
        // The fold sits after the indent: 6 + 14 + 4.
        let fold = cell.hitTest(NSPoint(x: 6 + 14 + 4 + 7, y: 12))
        let button = try XCTUnwrap(fold as? NSButton, "the fold answers its own point")
        XCTAssertEqual(button.accessibilityLabel(), "Fold", "unfolded: it folds")
        button.performClick(nil)
        XCTAssertEqual(folded.map(\.0), ["4242:1"])
        XCTAssertEqual(folded.map(\.1), [false])
        XCTAssertTrue(cell.hitTest(NSPoint(x: 120, y: 12)) === cell, "the name: the row's press")
        XCTAssertTrue(cell.acceptsFirstMouse(for: nil))
        var leaf = value
        leaf.folded = nil
        cell.show(leaf)
        cell.layoutSubtreeIfNeeded()
        XCTAssertTrue(cell.hitTest(NSPoint(x: 6 + 14 + 4 + 7, y: 12)) === cell, "no fold: its room is the row's")
    }

    /// The AppKit strip draws the rects the Canvas drew (`bars`): a bar a
    /// sampled cell from the foot, a tick a gap.
    func testTheStripsBarsAreTheCanvas() {
        let rect = CGRect(x: 6, y: 3, width: 60, height: 18)
        let bars = KubeHeatStripView.bars([10, nil, 100, 250], in: rect)
        XCTAssertEqual(bars.count, 4)
        XCTAssertEqual(bars[0].rect, CGRect(x: 6, y: 21 - 2, width: 15, height: 2), "10% of 18 is under the 2 pt floor")
        XCTAssertEqual(bars[0].level, .low)
        XCTAssertEqual(bars[1].rect, CGRect(x: 21, y: 20, width: 15, height: 1))
        XCTAssertNil(bars[1].level, "a gap, never a zero")
        XCTAssertEqual(bars[2].rect, CGRect(x: 36, y: 3, width: 15, height: 18))
        XCTAssertEqual(bars[3].rect.height, 18, "capped at the strip")
        XCTAssertEqual(bars[3].level, .over)
    }
}
