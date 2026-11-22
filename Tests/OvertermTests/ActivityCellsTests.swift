import AppKit
import XCTest

@testable import Overterm
@testable import OvertermCore
@testable import OvertermDatabase
@testable import OvertermDocker
@testable import OvertermKubernetes
@testable import OvertermTerraform
@testable import OvertermShell
@testable import OvertermOvergit
@testable import OvertermAPI
@testable import OvertermNotes
@testable import OvertermSimulator
@testable import OvertermUsage
@testable import OvertermSettingsPage
@testable import OvertermAgents
@testable import OvertermActivity
@testable import OvertermE2E

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

    /// A CPU or memory sort orders by what the column shows: rows that read
    /// alike keep the order they came in, so a re-sort moves a row only for
    /// a change a person can see (6.7).
    func testASortMovesARowOnlyForAChangeShown() {
        func process(_ pid: Int32, cpu: Double, memory: UInt64 = 64 << 20) -> ActivityProcessRow {
            ActivityProcessRow(
                id: "\(pid):1", identity: ActivityProcessID(pid: pid, start: 1), name: "acme-\(pid)", cpu: cpu, memory: memory, threads: 1, state: .running,
                started: Date(timeIntervalSince1970: 0), startedText: "10:02", user: "fake", isOwn: true, tab: nil, tabTitle: nil)
        }
        let busiest = ResourceSort(column: "cpu", ascending: false)
        let rows = [process(1, cpu: 1.24), process(2, cpu: 1.21), process(3, cpu: 1.26), process(4, cpu: 0)]
        XCTAssertEqual(ActivityRows.sorted(rows, by: busiest).map(\.identity.pid), [3, 1, 2, 4], "1.2 and 1.2 keep their order; 1.3 goes first")
        XCTAssertEqual(ActivityRows.sorted([rows[1], rows[0]], by: busiest).map(\.identity.pid), [2, 1], "whichever came first")
        XCTAssertEqual(ActivityRows.Shown.percent(1.24), ActivityRows.Shown.percent(1.21))
        XCTAssertLessThan(ActivityRows.Shown.percent(1.21), ActivityRows.Shown.percent(1.26))

        let byMemory = ResourceSort(column: "memory", ascending: false)
        let sized = [process(1, cpu: 0, memory: 64 << 20), process(2, cpu: 0, memory: (64 << 20) + 4_096), process(3, cpu: 0, memory: 65 << 20)]
        XCTAssertEqual(ActivityRows.bytes(sized[0].memory!), ActivityRows.bytes(sized[1].memory!), "both read 64.0 MB")
        XCTAssertEqual(ActivityRows.sorted(sized, by: byMemory).map(\.identity.pid), [3, 1, 2])
        // Across units and the 100 a unit's digits change at, in the words' order.
        let values: [UInt64] = [512, 1_023, 1_024, 99 << 10, 100 << 10, 1_023 << 10, 1 << 20, 3 << 30]
        let keys = values.map(ActivityRows.Shown.bytes)
        XCTAssertEqual(keys, keys.sorted())
        for (a, b) in zip(values, values.dropFirst()) where ActivityRows.bytes(a) != ActivityRows.bytes(b) {
            XCTAssertLessThan(ActivityRows.Shown.bytes(a), ActivityRows.Shown.bytes(b), "\(a) < \(b)")
        }
    }

    /// The page's numbers, written from integers, say what Foundation's
    /// `%.Nf` said in the POSIX locale, halves and all.
    func testNumbersAreWrittenAsPrintfWrites() {
        let posix = Locale(identifier: "en_US_POSIX")
        var values: [Double] = [0, 0.05, 0.15, 0.25, 0.35, 1.25, 2.5, 99.95, 100, 123.456, 1_234_567.891, -0.04, 312, .greatestFiniteMagnitude / 1e300]
        var random = SystemRandomNumberGenerator()
        values += (0..<500).map { _ in Double.random(in: 0...2_000, using: &random) }
        for value in values {
            for digits in 0...2 {
                XCTAssertEqual(ActivityRows.fixed(value, digits: digits), String(format: "%.\(digits)f", locale: posix, value), "\(value), \(digits)")
            }
        }
        XCTAssertEqual(ActivityRows.bytes(64 << 20), "64.0 MB")
        XCTAssertEqual(ActivityRows.bytes(512), "512 B")
        XCTAssertEqual(ActivityRows.bytes(150 << 30), "150 GB")
        XCTAssertEqual(ActivityPageView.rate(1.25, unit: "W"), "1.2 W")
        XCTAssertEqual(ActivityPageView.rate(2_048, unit: "B/s"), "2.0 KB/s")
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
