import AppKit
import SwiftUI

/// The Activity page's list (docs/design/activity/analysis.md, 6.4, 7.7):
/// the table and its cells, observing only `ActivityListState` — what it
/// draws — and the theme. The page's other changes (the detail, a verb's
/// subject, "order held", the header's words) re-evaluate the page, never
/// this: it is equal while its objects are the same, so the table isn't
/// updated and its cells on screen aren't handed their rows again.
package struct ActivityListView: View, Equatable {
    @ObservedObject package var list: ActivityListState
    /// Read, never observed: its changes come through `list`.
    package let page: ActivityPageModel
    @ObservedObject package var theme: ChromeTheme
    /// ⌘C: the selection, as the window copies it.
    package let copy: ([String]) -> Void

    /// The objects' identities, as `==` compares them: an observed object's
    /// property is the main actor's, and `==` is nonisolated (Swift 6.1).
    private let objects: [ObjectIdentifier]

    package init(list: ActivityListState, page: ActivityPageModel, theme: ChromeTheme, copy: @escaping ([String]) -> Void) {
        self.list = list
        self.page = page
        self.theme = theme
        self.copy = copy
        objects = [ObjectIdentifier(list), ObjectIdentifier(page), ObjectIdentifier(theme)]
    }

    package nonisolated static func == (a: ActivityListView, b: ActivityListView) -> Bool {
        a.objects == b.objects
    }

    private var sort: Binding<ResourceSort?> {
        let page = page
        return switch list.section {
        case .processes, .leftBehind: Binding(get: { page.processSort }, set: { page.processSort = $0 })
        case .listening: Binding(get: { page.portSort }, set: { page.portSort = $0 })
        }
    }

    package var body: some View {
        let shown = list.rows
        let page = page
        let section = list.section
        ZStack {
            ResourceTable(
                rows: shown.rows, selection: Binding(get: { page.selection }, set: { page.selection = $0 }), columns: list.columns, sort: sort,
                cell: { row, column in cell(row, column) },
                verbs: { [weak page, copy] ids in page?.verbs(for: ids, copy: copy) ?? [] }, copy: { [weak page, copy] in copy(page?.selectedLines ?? []) },
                accessibilityIdentifier: "activity.list",
                pressed: { [weak page] in page?.pressed($0) },
                accessibilityLabel: { $0.accessibilityLabel }
            )
            .with { table in
                table.interacting = { [weak page] interaction in page?.interacted(interaction) }
                table.columnsChanged = { [weak page] columns in page?.columnsChanged(columns, in: section) }
                table.columnChoices = ActivityColumns.choices(section)
                table.toggleColumn = { [weak page] id in page?.toggleColumn(id, in: section) }
                table.fold = { [weak page] id, open in page?.fold(id, open: open) ?? false }
                table.follow = list.following
                table.order = shown.order
                table.index = { shown.index[$0] }
                table.uniformHeight = true
                table.plainCell = { [theme] row, column in ActivityCells.plain(row, column.id).map { Self.value($0, theme: theme) } }
                table.drawnCell = { [theme, weak page] row, column in Self.drawn(row, column.id, theme: theme, page: page) }
                table.cellKey = { [theme] row, column in Self.key(row, column?.id, theme: theme) }
                // A row holds all its cells draw but the theme, the text size
                // and the minute its chips count to (6.11).
                table.skipsEqualRows = true
                table.fillsProposal = true
                table.look = Self.look(theme: theme, now: Date())
            }
            if !list.hasRead {
                VStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Reading…").font(.system(size: ChromeMetrics.text(12))).foregroundStyle(theme.text2)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(nsColor: GhosttyRuntime.shared.backgroundColor))
                .accessibilityIdentifier("activity.empty")
            } else if shown.rows.isEmpty {
                Text(verbatim: list.emptySentence).font(.system(size: ChromeMetrics.text(12))).foregroundStyle(theme.text3).multilineTextAlignment(.center)
                    .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: GhosttyRuntime.shared.backgroundColor))
                    .accessibilityIdentifier("activity.empty")
            }
        }
    }

    // MARK: Cells

    private func cell(_ row: ActivityListRow, _ column: ResourceColumn?) -> AnyView {
        switch row {
        // A process's cells are all AppKit's: `plainCell`, `drawnCell`.
        case .process: AnyView(EmptyView())
        case .port(let port): AnyView(portCell(port, column?.id))
        case .group(let group): AnyView(groupCell(group, column?.id))
        }
    }

    /// The fold's triangle, or its room. Not a button: a press anywhere on
    /// a group's row flips it (`ActivityPageModel.pressed`), and a button
    /// here would take the same press and flip it back. VoiceOver flips it
    /// by the row's action.
    private func disclosure(_ id: String, foldable: Bool, folded: Bool) -> some View {
        Group {
            if foldable {
                Image(systemName: folded ? "chevron.right" : "chevron.down").font(.system(size: ChromeMetrics.text(9), weight: .semibold))
                    .foregroundStyle(theme.text3).frame(width: 14, height: 18)
                    .accessibilityElement()
                    .accessibilityLabel(Text(folded ? "Unfold" : "Fold"))
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { [weak page] in page?.toggleFold(id, folded: folded) }
            } else {
                Color.clear.frame(width: 14, height: 18)
            }
        }
    }

    @ViewBuilder
    private func groupCell(_ row: ActivityGroupRow, _ column: String?) -> some View {
        if row.kind == .container {
            switch column {
            case "name":
                HStack(spacing: 4) {
                    Color.clear.frame(width: CGFloat(row.depth) * 14 + 14)
                    Image(systemName: "shippingbox").font(.system(size: ChromeMetrics.text(10))).foregroundStyle(theme.text3)
                    text(row.title, theme.text2)
                }
                .help(row.detail.isEmpty ? "A container: its processes run inside Docker’s VM" : row.detail)
            default: EmptyView()  // `ActivityCells`' AppKit text
            }
        } else {
            HStack(spacing: 6) {
                Color.clear.frame(width: CGFloat(row.depth) * 14)
                disclosure(row.id, foldable: row.foldable, folded: row.folded)
                if let agent = row.agent { Image(systemName: agent.symbol).font(.system(size: ChromeMetrics.text(10))).foregroundStyle(theme.text2) }
                Text(verbatim: row.title).font(.system(size: ChromeMetrics.text(12), weight: row.kind == .more ? .regular : .semibold))
                    .foregroundStyle(row.kind == .more ? theme.text3 : theme.text).lineLimit(1).truncationMode(.middle)
                if !row.detail.isEmpty {
                    Text(verbatim: row.detail).font(.system(size: ChromeMetrics.text(11.5))).foregroundStyle(theme.text3).lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 8)
                if row.kind != .more {
                    if !row.ports.isEmpty {
                        Text(verbatim: ActivityPageView.ports(row.ports)).font(.system(size: ChromeMetrics.text(11.5), design: .monospaced))
                            .foregroundStyle(theme.text2).lineLimit(1)
                    }
                    Text(verbatim: row.cpu.map { "\(ActivityRows.percent($0))%" } ?? "—").font(.system(size: ChromeMetrics.text(11.5), design: .monospaced))
                        .foregroundStyle((row.cpu ?? 0) >= 50 ? TabStatusStyle.signal : theme.text2).frame(minWidth: 52, alignment: .trailing)
                    Text(verbatim: row.memory.map(ActivityRows.bytes) ?? "").font(.system(size: ChromeMetrics.text(11.5), design: .monospaced))
                        .foregroundStyle(theme.text2).frame(minWidth: 64, alignment: .trailing)
                }
            }
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipped()
        }
    }

    @ViewBuilder
    private func portCell(_ row: ActivityPortRow, _ column: String?) -> some View {
        if row.kind == .folded {
            HStack(spacing: 6) {
                disclosure(row.id, foldable: true, folded: row.folded)
                Text(verbatim: row.process).font(.system(size: ChromeMetrics.text(12))).foregroundStyle(theme.text3).lineLimit(1)
                Spacer(minLength: 4)
            }
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .help("Listeners of your apps on ports in the ephemeral range: rarely ones you start. A filter shows them too.")
        }
        // Every other port cell is `ActivityCells`' AppKit text.
    }

    private func text(_ value: String, _ color: Color) -> some View {
        Text(verbatim: value).font(.system(size: ChromeMetrics.text(12))).foregroundStyle(color).lineLimit(1).truncationMode(.middle)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 6)
    }

    /// A plain cell's words as the table draws them: its tint the theme's.
    package static func value(_ cell: ActivityCellText, theme: ChromeTheme) -> ResourceTextCellValue {
        let color: NSColor =
            switch cell.tint {
            case .text: theme.textNS
            case .text2: theme.text2NS
            case .text3: theme.text3NS
            case .signal: TabStatusStyle.signalNS
            }
        return ResourceTextCellValue(
            text: cell.text, color: color, size: ChromeMetrics.text(12), number: cell.number, help: cell.help, alpha: cell.ended ? 0.45 : 1,
            ground: cell.isNew ? newGround : nil)
    }

    /// A new row's tint (6.7).
    private static let newGround = TabStatusStyle.doneNS.withAlphaComponent(0.14)

    // MARK: The AppKit name and strip

    /// A process's name or strip cell, drawn by AppKit; nil for every other.
    package static func drawn(_ row: ActivityListRow, _ column: String, theme: ChromeTheme, page: ActivityPageModel?) -> ResourceDrawnCell? {
        guard case .process(let process) = row else { return nil }
        switch column {
        case "name":
            let value = nameValue(process, theme: theme, now: Date())
            return ResourceDrawnCell(
                kind: "name", make: { ActivityNameCell() },
                show: { [weak page] cell in
                    guard let cell = cell as? ActivityNameCell else { return false }
                    if cell.toggle == nil { cell.toggle = { [weak page] id, folded in page?.toggleFold(id, folded: folded) } }
                    return cell.show(value)
                })
        case "cpu15":
            let value = stripValue(process, theme: theme)
            return ResourceDrawnCell(kind: "strip", make: { ActivityStripCell() }, show: { ($0 as? ActivityStripCell)?.show(value) ?? false })
        default: return nil
        }
    }

    /// The name cell's value (6.5): indent, fold, the agent's symbol, the
    /// name dimmed for a match's ancestor, a session or a shell, its chips.
    package static func nameValue(_ row: ActivityProcessRow, theme: ChromeTheme, now: Date) -> ActivityNameValue {
        var chips = ActivityPageView.chips(row).map { ActivityNameValue.Chip(text: $0, color: theme.text3NS, stroke: theme.borderNS) }
        for chip in row.chips {
            chips.append(
                ActivityNameValue.Chip(
                    text: chip.text(now: now), color: chip.warns ? TabStatusStyle.signalNS : theme.text2NS,
                    fill: (chip.warns ? TabStatusStyle.signalNS : theme.text3NS).withAlphaComponent(0.12), bold: chip.warns, help: chip.help,
                    identifier: "activity.chip"))
        }
        if row.ended { chips.append(ActivityNameValue.Chip(text: "ended", color: theme.text3NS, stroke: theme.borderNS, identifier: "activity.ended")) }
        let role = row.owner?.paneRole
        let agent = role == .agent ? row.owner?.agentKind : nil
        return ActivityNameValue(
            id: row.id, depth: row.depth, folded: row.hasChildren ? row.folded : nil, chevron: theme.text3NS, symbol: agent?.symbol,
            symbolColor: theme.textNS, name: row.name,
            nameColor: row.dimmed || role == .session || role == .shell ? theme.text3NS : row.isOwn ? theme.textNS : theme.text2NS, chips: chips,
            help: row.owner?.reason ?? "", size: ChromeMetrics.text(12), chipSize: ChromeMetrics.text(10), alpha: row.ended ? 0.45 : 1,
            ground: row.isNew ? newGround : nil)
    }

    /// The strip cell's value (6.11): a cell each 15 s, CPU capped at 100
    /// for the colour, a gap a faint tick.
    package static func stripValue(_ row: ActivityProcessRow, theme: ChromeTheme) -> ActivityStripValue {
        ActivityStripValue(
            strip: row.strip, since: row.stripSince, colours: heatColours(dark: theme.isDark), track: theme.text3NS, alpha: row.ended ? 0.45 : 1,
            ground: row.isNew ? newGround : nil)
    }

    private static let heat = (
        light: KubeHeatStrip.Level.allCases.map { heatColour(TimeChartPalette.heat($0, dark: false)) },
        dark: KubeHeatStrip.Level.allCases.map { heatColour(TimeChartPalette.heat($0, dark: true)) }
    )

    private static func heatColour(_ rgb: TimeChartPalette.RGB) -> NSColor {
        NSColor(srgbRed: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
    }

    private static func heatColours(dark: Bool) -> [NSColor] { dark ? heat.dark : heat.light }

    /// What every cell draws besides its row: the theme's colours, the
    /// text size, the minute a chip's "for 5 min" counts to.
    package static func look(theme: ChromeTheme, now: Date) -> Int {
        var hasher = Hasher()
        hasher.combine(theme.revision)
        hasher.combine(ChromeMetrics.text(12))
        hasher.combine(Int(now.timeIntervalSinceReferenceDate / 60))
        return hasher.finalize()
    }

    /// What a hosted cell draws, as a key (`ResourceTable.cellKey`): a
    /// group's or a container's row, a folded port row, by every value its
    /// SwiftUI cell reads and the theme's colours.
    package static func key(_ row: ActivityListRow, _ column: String?, theme: ChromeTheme) -> Int {
        var hasher = Hasher()
        hasher.combine(theme.revision)
        hasher.combine(ChromeMetrics.text(12))
        hasher.combine(column)
        switch row {
        case .group(let group):
            hasher.combine(group.id)
            hasher.combine(group.kind.rawValue)
            hasher.combine(group.depth)
            hasher.combine(group.title)
            hasher.combine(group.detail)
            hasher.combine(group.cpu)
            hasher.combine(group.memory)
            hasher.combine(group.ports)
            hasher.combine(group.folded)
            hasher.combine(group.foldable)
            hasher.combine(group.agent?.symbol)
        case .port(let port):
            hasher.combine(port.id)
            hasher.combine(port.process)
            hasher.combine(port.folded)
        case .process(let process):
            // Drawn by AppKit (`drawn`): a key that never repeats, should one
            // ever be hosted.
            hasher.combine(process.id)
            hasher.combine(UUID())
        }
        return hasher.finalize()
    }
}
