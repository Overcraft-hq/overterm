import SwiftUI

/// The Activity page's list (docs/design/activity/analysis.md, 6.4, 7.7):
/// the table and its cells, observing only `ActivityListState` — what it
/// draws — and the theme. The page's other changes (the detail, a verb's
/// subject, "order held", the header's words) re-evaluate the page, never
/// this: it is equal while its objects are the same, so the table isn't
/// updated and its cells on screen aren't handed their rows again.
struct ActivityListView: View, Equatable {
    @ObservedObject var list: ActivityListState
    /// Read, never observed: its changes come through `list`.
    let page: ActivityPageModel
    @ObservedObject var theme: ChromeTheme
    /// ⌘C: the selection, as the window copies it.
    let copy: ([String]) -> Void

    nonisolated static func == (a: ActivityListView, b: ActivityListView) -> Bool {
        a.list === b.list && a.page === b.page && a.theme === b.theme
    }

    private var sort: Binding<ResourceSort?> {
        let page = page
        return switch list.section {
        case .processes, .leftBehind: Binding(get: { page.processSort }, set: { page.processSort = $0 })
        case .listening: Binding(get: { page.portSort }, set: { page.portSort = $0 })
        }
    }

    var body: some View {
        let shown = list.rows
        let page = page
        let section = list.section
        ZStack {
            ResourceTable(
                rows: shown.rows, selection: Binding(get: { page.selection }, set: { page.selection = $0 }), columns: list.columns, sort: sort,
                cell: { row, column in cell(row, column) },
                verbs: { [weak page, copy] ids in page?.verbs(for: ids, copy: copy) ?? [] }, copy: { [weak page, copy] in copy(page?.selectedLines ?? []) },
                accessibilityIdentifier: "activity.list",
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
        case .process(let process): AnyView(processCell(process, column?.id))
        case .port(let port): AnyView(portCell(port, column?.id))
        case .group(let group): AnyView(groupCell(group, column?.id))
        }
    }

    /// The fold's triangle, or its room.
    private func disclosure(_ id: String, foldable: Bool, folded: Bool) -> some View {
        Group {
            if foldable {
                Button {
                    page.toggleFold(id, folded: folded)
                } label: {
                    Image(systemName: folded ? "chevron.right" : "chevron.down").font(.system(size: ChromeMetrics.text(9), weight: .semibold))
                        .foregroundStyle(theme.text3).frame(width: 14, height: 18).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(folded ? "Unfold" : "Fold"))
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
            case "cpu": number(row.cpu.map(ActivityRows.percent) ?? "—", (row.cpu ?? 0) >= 50 ? TabStatusStyle.signal : theme.text2)
            case "memory": number(row.memory.map(ActivityRows.bytes) ?? "—")
            default: EmptyView()
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

    /// A process's cell: tinted while new, dimmed once ended (6.7).
    private func processCell(_ row: ActivityProcessRow, _ column: String?) -> some View {
        processCellContent(row, column)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .opacity(row.ended ? 0.45 : 1)
            .background(row.isNew ? TabStatusStyle.done.opacity(0.14) : Color.clear)
    }

    /// The row's 15 minutes, a cell each 15 s (6.11): `KubeHeatStripView`'s
    /// drawing, CPU capped at 100 for the colour; a gap a faint tick.
    private func strip(_ row: ActivityProcessRow) -> some View {
        let cells = row.strip ?? []
        let colours = KubeHeatStrip.Level.allCases.map { TimeChartPalette.heat($0, dark: theme.isDark).color }
        let track = theme.text3
        return Canvas { context, size in
            guard !cells.isEmpty else { return }
            KubeHeatStripView.draw(
                cells.map { $0.map { min($0, 100) } }, in: CGRect(x: 0, y: 3, width: size.width, height: max(size.height - 6, 1)),
                context: &context, colours: colours, track: track)
        }
        .padding(.horizontal, 6)
        .help(ActivityPageView.stripHelp(row))
        .accessibilityElement()
        .accessibilityLabel(Text(verbatim: ActivityPageView.stripHelp(row)))
        .accessibilityIdentifier("activity.strip")
    }

    @ViewBuilder
    private func processCellContent(_ row: ActivityProcessRow, _ column: String?) -> some View {
        switch column {
        case "name":
            HStack(spacing: 4) {
                Color.clear.frame(width: CGFloat(row.depth) * 14)
                disclosure(row.id, foldable: row.hasChildren, folded: row.folded)
                if row.owner?.paneRole == .agent, let agent = row.owner?.agentKind {
                    Image(systemName: agent.symbol).font(.system(size: ChromeMetrics.text(10))).foregroundStyle(theme.text)
                }
                Text(verbatim: row.name).font(.system(size: ChromeMetrics.text(12)))
                    .foregroundStyle(
                        row.dimmed || row.owner?.paneRole == .session || row.owner?.paneRole == .shell ? theme.text3 : row.isOwn ? theme.text : theme.text2
                    )
                    .lineLimit(1).truncationMode(.middle).layoutPriority(1)
                ForEach(ActivityPageView.chips(row), id: \.self) { chip in
                    Text(verbatim: chip).font(.system(size: ChromeMetrics.text(10))).foregroundStyle(theme.text3).lineLimit(1)
                        .padding(.horizontal, 5).background(Capsule().stroke(theme.border))
                }
                ForEach(row.chips, id: \.self) { chip in
                    Text(verbatim: chip.text(now: Date())).font(.system(size: ChromeMetrics.text(10), weight: chip.warns ? .semibold : .regular))
                        .foregroundStyle(chip.warns ? TabStatusStyle.signal : theme.text2).lineLimit(1)
                        .padding(.horizontal, 5).background(Capsule().fill((chip.warns ? TabStatusStyle.signal : theme.text3).opacity(0.12)))
                        .help(chip.help)
                        .accessibilityIdentifier("activity.chip")
                }
                if row.ended {
                    Text(verbatim: "ended").font(.system(size: ChromeMetrics.text(10))).foregroundStyle(theme.text3).lineLimit(1)
                        .padding(.horizontal, 5).background(Capsule().stroke(theme.border))
                        .accessibilityIdentifier("activity.ended")
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .clipped()
            .help(row.owner?.reason ?? "")
        case "pid":
            number("\(row.identity.pid)")
        case "cpu":
            number(row.cpu.map(ActivityRows.percent) ?? "—", (row.cpu ?? 0) >= 50 ? TabStatusStyle.signal : theme.text2)
        case "memory":
            number(row.memory.map(ActivityRows.bytes) ?? "—")
        case "threads":
            number(row.threads.map { "\($0)" } ?? "—")
        case "state":
            text(row.state.letter, row.state == .stopped || row.state == .zombie ? TabStatusStyle.signal : theme.text2)
        case "started":
            number(row.startedText)
        case "user":
            text(row.user, theme.text3)
        case "listening":
            text(ActivityPageView.ports(row.listening), theme.text2)
        case "where":
            text(row.whereText, theme.text2)
        case "rss": number(row.residentSize.map(ActivityRows.bytes) ?? "—")
        case "time": number(row.cpuTime.map(ActivityDetail.duration) ?? "—")
        case "nice": number("\(row.nice)")
        case "priority": number(row.priority.map { "\($0)" } ?? "—")
        case "ppid": number("\(row.parentPID)")
        case "pgid": number("\(row.group)")
        case "tty": text(row.terminal ?? "", theme.text3)
        case "kind": text(row.translated ? "Intel" : "Apple", theme.text3)
        case "path": text(row.path ?? "", theme.text3)
        case "command": text(row.command ?? "", theme.text2)
        case "cpu15": strip(row)
        case "energy": number(ActivityPageView.rate(row.energy, unit: "W"))
        case "wakeups": number(row.idleWakeups.map { String(format: "%.0f", locale: Locale(identifier: "en_US_POSIX"), $0) } ?? "—")
        case "diskRead": number(ActivityPageView.rate(row.diskRead, unit: "B/s"))
        case "diskWritten": number(ActivityPageView.rate(row.diskWritten, unit: "B/s"))
        case "sleep": text(row.sleepHold.map { $0.isEmpty ? "No" : $0.text } ?? "—", row.sleepHold?.isEmpty == false ? theme.text : theme.text3)
        default:
            EmptyView()
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
        } else {
            switch column {
            case "port":
                if row.kind == .unix {
                    text((row.address as NSString).abbreviatingWithTildeInPath, theme.text).help(row.address)
                } else {
                    number(row.kind == .connection ? "→ :\(row.port)" : ":\(row.port)", row.kind == .connection ? theme.text2 : theme.text)
                }
            case "proto": text(row.proto, theme.text2)
            case "address":
                text(row.reach, row.scope == .thisMac && row.forwardedBy == nil ? theme.text2 : TabStatusStyle.signal)
                    .help(row.scope == .network ? "Anything that can route to this Mac reaches it — over IPv6 that may be the internet" : "")
            case "families": text(row.familyWords, theme.text3)
            case "owner": text(row.ownerText, row.portOwner == .pane ? theme.text2 : theme.text)
            case "process": text(row.processText, row.kind == .connection ? theme.text2 : theme.text)
            case "pid": number(row.holder.map { "\($0.pid)" } ?? "")
            case "where": text(row.whereText, theme.text2)
            case "clients": number(row.kind == .listener && row.clients > 0 ? "\(row.clients)" : "")
            case "note":
                text(row.note ?? "", row.collisions.isEmpty ? theme.text3 : TabStatusStyle.signal).help(row.note ?? "")
            case "since": text(row.sinceText, theme.text2)
            case "backlog":
                text(
                    row.backlogLimit > 0 ? (row.backlogFull ? "full — not accepting" : "\(row.backlog) of \(row.backlogLimit)") : "",
                    row.backlogFull ? TabStatusStyle.signal : theme.text3)
            default: EmptyView()
            }
        }
    }

    private func text(_ value: String, _ color: Color) -> some View {
        Text(verbatim: value).font(.system(size: ChromeMetrics.text(12))).foregroundStyle(color).lineLimit(1).truncationMode(.middle)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 6)
    }

    private func number(_ value: String, _ color: Color? = nil) -> some View {
        Text(verbatim: value).font(.system(size: ChromeMetrics.text(12), design: .monospaced)).foregroundStyle(color ?? theme.text2).lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .trailing).padding(.horizontal, 6)
    }
}
