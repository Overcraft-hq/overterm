import SwiftUI

/// A row of the page's one list: a process's or a listener's. One table for
/// both sections, so the list keeps its place in the view tree — the
/// keyboard and the scroll with it — as the section changes (6.4).
enum ActivityListRow: ResourceTableRow {
    case process(ActivityProcessRow)
    case port(ActivityPortRow)
    /// A group's header, a container, "+N more" (6.5).
    case group(ActivityGroupRow)

    var id: String {
        switch self {
        case .process(let row): row.id
        case .port(let row): row.id
        case .group(let row): row.id
        }
    }

    var height: CGFloat { 24 }

    var spansColumns: Bool {
        if case .group(let row) = self { return row.spansColumns }
        return false
    }

    var reuseKind: String {
        switch self {
        case .process: "process"
        case .port: "port"
        case .group(let row): row.kind == .container ? "container" : "group"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .process(let row): row.accessibilityLabel
        case .port(let row): row.accessibilityLabel
        case .group(let row): row.accessibilityLabel
        }
    }
}

/// The Activity page (⌥⌘A; docs/design/activity/analysis.md, 6.4): the
/// sections, the busiest and the meters down the left, the list beside.
struct ActivityPageView: View {
    @ObservedObject var page: ActivityPageModel
    @ObservedObject var theme: ChromeTheme
    /// ⌘C: the selection, as the window copies it.
    let copy: ([String]) -> Void

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 210).background(theme.panelGround)
            Rectangle().fill(theme.border).frame(width: 1)
            VStack(spacing: 0) {
                header
                Rectangle().fill(theme.border).frame(height: 1)
                list
            }
        }
        .background(Color(nsColor: GhosttyRuntime.shared.backgroundColor))
        .environment(\.colorScheme, theme.isDark ? .dark : .light)
        // A container of its own: an identifier on the whole page would
        // otherwise be every child's, hiding the list's, the header's.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("activity.page")
    }

    private var summary: ActivitySummary { page.content.summary }

    // MARK: The left

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(ActivityPageModel.Section.allCases) { section in
                Button {
                    page.section = section
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: section.symbol).frame(width: 18)
                        Text(section.title)
                        Spacer()
                        if page.hasRead {
                            Text(verbatim: "\(section == .processes ? summary.shown : summary.listening)")
                                .foregroundStyle(theme.text3).font(.system(size: ChromeMetrics.text(11), design: .monospaced))
                        }
                    }
                    .foregroundStyle(page.section == section ? theme.text : theme.text2)
                    .padding(.horizontal, 10)
                    .frame(height: ChromeMetrics.row(30))
                    .background(RoundedRectangle(cornerRadius: 7).fill(page.section == section ? theme.selected : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("\(section.title) (\(section.key))")
                .accessibilityIdentifier("activity.section.\(section.rawValue)")
            }
            if !summary.busiest.isEmpty {
                caption("Busiest").padding(.top, 14)
                ForEach(summary.busiest, id: \.id) { busy in
                    Button {
                        page.reveal(busy.id, in: .processes)
                    } label: {
                        HStack(spacing: 6) {
                            Text(verbatim: busy.name).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 4)
                            Text(verbatim: "\(ActivityRows.percent(busy.cpu))%").font(.system(size: ChromeMetrics.text(11), design: .monospaced))
                                .foregroundStyle(busy.cpu >= 50 ? TabStatusStyle.signal : theme.text3)
                        }
                        .font(.system(size: ChromeMetrics.text(11.5)))
                        .foregroundStyle(theme.text2)
                        .padding(.horizontal, 10)
                        .frame(height: ChromeMetrics.row(20))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(verbatim: "\(busy.name), \(ActivityRows.percent(busy.cpu)) percent CPU"))
                }
            }
            Spacer()
            ActivityMetersView(meters: summary.meters, processes: summary.processes, threads: summary.threads, theme: theme)
        }
        .padding(12)
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.system(size: ChromeMetrics.text(10.5), weight: .semibold)).textCase(.uppercase).foregroundStyle(theme.text3)
            .padding(.horizontal, 10)
    }

    // MARK: The header

    private var header: some View {
        HStack(spacing: 10) {
            Text("Activity").font(.system(size: ChromeMetrics.text(14), weight: .semibold)).foregroundStyle(theme.text)
            if page.hasRead {
                Text(verbatim: counts).font(.system(size: ChromeMetrics.text(12))).foregroundStyle(theme.text2).lineLimit(1)
                    .accessibilityIdentifier("activity.counts")
            }
            Spacer(minLength: 8)
            if let scope = page.scopeTitle(page.section) {
                HStack(spacing: 4) {
                    Text(verbatim: scope).lineLimit(1)
                    Button {
                        page.setScope(.mac)
                    } label: {
                        Image(systemName: "xmark").font(.system(size: ChromeMetrics.text(9), weight: .bold))
                    }
                    .buttonStyle(.plain)
                    .help("Back to the whole Mac (])")
                }
                .font(.system(size: ChromeMetrics.text(11.5))).foregroundStyle(theme.text)
                .padding(.horizontal, 8).frame(height: ChromeMetrics.row(22))
                .background(Capsule().fill(theme.selected))
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("activity.scope")
            }
            if page.section == .processes {
                Button {
                    page.grouping = page.grouping.next
                } label: {
                    Text(verbatim: "Group: \(page.grouping.title)").font(.system(size: ChromeMetrics.text(11.5))).foregroundStyle(theme.text2)
                }
                .buttonStyle(.plain)
                .help("Group by checkout, tab, agent, app, user or none (G)")
                .accessibilityIdentifier("activity.grouping")
                Button {
                    page.tree.toggle()
                } label: {
                    Text(page.tree ? "Tree" : "Flat").font(.system(size: ChromeMetrics.text(11.5))).foregroundStyle(theme.text2)
                }
                .buttonStyle(.plain)
                .help("A tree of parents and children, or flat and sorted (t)")
            }
            if Self.reading(hasRead: page.hasRead, summary) {
                Text("Reading…").font(.system(size: ChromeMetrics.text(11.5))).foregroundStyle(theme.text3)
                    .accessibilityIdentifier("activity.reading")
            }
            Text(verbatim: "every \(Self.seconds(page.interval))").font(.system(size: ChromeMetrics.text(11.5))).foregroundStyle(theme.text3)
                .help("How often the page reads the Mac while it shows: Settings ▸ Activity")
        }
        .padding(.horizontal, 14)
        .frame(height: ChromeMetrics.row(40))
    }

    /// The header says "Reading…" until rows are made, while the churn
    /// budget leaves processes for a later tick, and while no rate is in.
    static func reading(hasRead: Bool, _ summary: ActivitySummary) -> Bool {
        !hasRead || summary.unread > 0 || summary.firstSample
    }

    /// "1,297 processes · 864 yours · 23 listening", or a test run's own.
    private var counts: String {
        let number = { (value: Int) in value.formatted(.number.locale(Locale(identifier: "en_US"))) }
        if summary.scopedToRun {
            return "\(number(summary.shown)) of this test run's tabs · \(number(summary.processes)) on this Mac, counted only · \(summary.listening) listening"
        }
        return "\(number(summary.processes)) processes · \(number(summary.own)) yours · \(summary.listening) listening"
    }

    static func seconds(_ duration: Duration) -> String {
        let seconds = duration.components.seconds
        return seconds == 1 ? "1 s" : "\(seconds) s"
    }

    // MARK: The list

    private var rows: [ActivityListRow] {
        switch page.section {
        case .processes:
            page.content.list.map { item in
                switch item {
                case .group(let row): ActivityListRow.group(row)
                case .process(let row): ActivityListRow.process(row)
                }
            }
        case .listening: page.content.ports.map(ActivityListRow.port)
        }
    }

    private var columns: [ResourceColumn] {
        switch page.section {
        case .processes:
            [
                ResourceColumn(id: "name", title: "Name", width: 300, minWidth: 140),
                ResourceColumn(id: "pid", title: "PID", width: 64),
                ResourceColumn(id: "cpu", title: "CPU %", width: 64, help: "100% is one core, as htop and Tab Info count"),
                ResourceColumn(id: "memory", title: "Memory", width: 84, help: "The footprint: Activity Monitor's Memory"),
                ResourceColumn(id: "threads", title: "Threads", width: 60),
                ResourceColumn(id: "state", title: "St", width: 36, help: "R running, S sleeping, T stopped, Z ended and not collected"),
                ResourceColumn(id: "started", title: "Started", width: 80),
                ResourceColumn(id: "listening", title: "Listening", width: 110, sortable: false, help: "The TCP ports it listens on"),
                ResourceColumn(id: "user", title: "User", width: 90),
            ]
                + (page.grouping == .checkout || page.grouping == .tab
                    ? [] : [ResourceColumn(id: "where", title: "Where", width: 200, help: "Its tab · checkout · agent, or who it belongs to")])
        case .listening:
            [
                ResourceColumn(id: "port", title: "Port", width: 70),
                ResourceColumn(id: "proto", title: "Proto", width: 56),
                ResourceColumn(id: "address", title: "Reach", width: 130, help: "This Mac: loopback only. Network: whatever can route to this Mac"),
                ResourceColumn(id: "families", title: "IP", width: 60, sortable: false),
                ResourceColumn(id: "process", title: "Process", width: 200, minWidth: 100),
                ResourceColumn(id: "pid", title: "PID", width: 64),
                ResourceColumn(id: "where", title: "Where", width: 160, help: "The tab its process runs in"),
            ]
        }
    }

    private var sort: Binding<ResourceSort?> {
        switch page.section {
        case .processes: $page.processSort
        case .listening: $page.portSort
        }
    }

    private var list: some View {
        VStack(spacing: 0) {
            table
            if page.section == .listening, page.hasRead {
                // Every "none" must be true (6.4): what isn't read is said —
                // below the list, never over its last row.
                Rectangle().fill(theme.border).frame(height: 1)
                Text("Your processes' listeners. Other users' — root's, macOS's — aren't read.")
                    .font(.system(size: ChromeMetrics.text(11))).foregroundStyle(theme.text3).padding(.horizontal, 14).padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("activity.listeningNote")
            }
        }
    }

    private var table: some View {
        ZStack {
            ResourceTable(
                rows: rows, selection: $page.selection, columns: columns, sort: sort, cell: { row, column in cell(row, column) },
                verbs: { _ in [] }, copy: { copy(page.selectedLines) }, accessibilityIdentifier: "activity.list",
                accessibilityLabel: { $0.accessibilityLabel })
            if !page.hasRead {
                VStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Reading…").font(.system(size: ChromeMetrics.text(12))).foregroundStyle(theme.text2)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(nsColor: GhosttyRuntime.shared.backgroundColor))
                .accessibilityIdentifier("activity.empty")
            } else if rows.isEmpty {
                Text(verbatim: emptySentence).font(.system(size: ChromeMetrics.text(12))).foregroundStyle(theme.text3).multilineTextAlignment(.center)
                    .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: GhosttyRuntime.shared.backgroundColor))
                    .accessibilityIdentifier("activity.empty")
            }
        }
    }

    private var emptySentence: String { Self.emptySentence(page.section, scopedToRun: summary.scopedToRun) }

    /// What an empty section says: true of what was read (6.4).
    static func emptySentence(_ section: ActivityPageModel.Section, scopedToRun: Bool) -> String {
        switch section {
        case .processes:
            scopedToRun ? "Nothing runs in this test run's tabs." : "No processes to show."
        case .listening:
            scopedToRun
                ? "Nothing in this test run's tabs listens on a port." : "Nothing of yours listens on a port. Other users' listeners aren't read."
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
                        Text(verbatim: Self.ports(row.ports)).font(.system(size: ChromeMetrics.text(11.5), design: .monospaced))
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

    /// At most three ports, then "+N".
    static func ports(_ ports: [Int]) -> String {
        let shown = ports.prefix(3).map { ":\($0)" }.joined(separator: " ")
        return ports.count > 3 ? "\(shown) +\(ports.count - 3)" : shown
    }

    /// The chips beside a process's name (6.5): its role, what it did.
    static func chips(_ row: ActivityProcessRow) -> [String] {
        guard let owner = row.owner else { return [] }
        var chips: [String] = []
        if let counts = row.agentCounts, !counts.isEmpty { chips.append(counts) }
        if owner.paneRole != .agent {
            switch owner.role {
            case .mcp: chips.append("MCP")
            case .server: break
            case .shell where owner.paneRole == .agentChild: chips.append("tool shell")
            case .build: chips.append("build")
            default: break
            }
        }
        if owner.marks.contains(.detached) { chips.append("detached on purpose") }
        if owner.marks.contains(.leftTerminal) { chips.append("↗ left its terminal") }
        if owner.marks.contains(.nohup) { chips.append("nohup") }
        if owner.marks.contains(.setsid), owner.paneRole != .agentChild { chips.append("setsid") }
        return chips
    }

    @ViewBuilder
    private func processCell(_ row: ActivityProcessRow, _ column: String?) -> some View {
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
                        row.owner?.paneRole == .session || row.owner?.paneRole == .shell ? theme.text3 : row.isOwn ? theme.text : theme.text2
                    )
                    .lineLimit(1).truncationMode(.middle).layoutPriority(1)
                ForEach(Self.chips(row), id: \.self) { chip in
                    Text(verbatim: chip).font(.system(size: ChromeMetrics.text(10))).foregroundStyle(theme.text3).lineLimit(1)
                        .padding(.horizontal, 5).background(Capsule().stroke(theme.border))
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
            text(Self.ports(row.listening), theme.text2)
        case "where":
            text(row.whereText, theme.text2)
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private func portCell(_ row: ActivityPortRow, _ column: String?) -> some View {
        switch column {
        case "port": number(":\(row.port)", theme.text)
        case "proto": text(row.proto, theme.text2)
        case "address": text(row.reach, row.scope == .thisMac ? theme.text2 : TabStatusStyle.signal)
        case "families": text(row.familyWords, theme.text3)
        case "process": text(row.process, theme.text)
        case "pid": number(row.holder.map { "\($0.pid)" } ?? "")
        case "where": text(row.tabTitle.map { "“\($0)”" } ?? "", theme.text2)
        default: EmptyView()
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

/// The meters (6.4): CPU a bar a core, memory as Activity Monitor counts it,
/// pressure, swap, load, uptime, thermal state and Low Power Mode, tasks and
/// threads. "—" for what the census hasn't read yet.
struct ActivityMetersView: View {
    let meters: SystemMeters?
    let processes: Int
    let threads: Int
    @ObservedObject var theme: ChromeTheme

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("CPU").font(.system(size: ChromeMetrics.text(10.5), weight: .semibold)).textCase(.uppercase).foregroundStyle(theme.text3)
            cpu
            if let meters {
                line("Memory", "\(ActivityRows.bytes(meters.used)) of \(ActivityRows.bytes(meters.memory))")
                    .help(
                        "Used: app memory \(ActivityRows.bytes(meters.app)), wired \(ActivityRows.bytes(meters.wired)), compressed \(ActivityRows.bytes(meters.compressed)). Cached files \(ActivityRows.bytes(meters.cached))."
                    )
                line("Pressure", meters.pressure.rawValue, meters.pressure == .normal || meters.pressure == .unknown ? nil : TabStatusStyle.signal)
                line("Swap", meters.swapTotal == 0 ? "none" : "\(ActivityRows.bytes(meters.swapUsed)) of \(ActivityRows.bytes(meters.swapTotal))")
                line("Load", meters.load.map { String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), $0) }.joined(separator: " "))
                line("Up", Self.uptime(meters.uptime))
                line("Thermal", meters.thermal.rawValue, meters.thermal == .nominal ? nil : TabStatusStyle.signal)
                if meters.lowPower { line("Low Power Mode", "on") }
            }
            if processes > 0 { line("Tasks", "\(processes) · \(threads) threads yours") }
        }
        .padding(.horizontal, 10)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("activity.meters")
    }

    @ViewBuilder
    private var cpu: some View {
        if let meters, !meters.cores.isEmpty {
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(Array(meters.cores.enumerated()), id: \.offset) { _, share in
                    ZStack(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: 1.5).fill(theme.text3.opacity(0.25))
                        RoundedRectangle(cornerRadius: 1.5).fill(share >= 0.8 ? TabStatusStyle.signal : theme.text2).frame(height: max(1, 22 * share))
                    }
                    .frame(height: 22)
                }
            }
            .frame(maxWidth: .infinity)
            .accessibilityLabel(Text(verbatim: "CPU \(ActivityRows.percent((meters.cpu ?? 0) * 100)) percent"))
            HStack {
                Text(verbatim: "\(ActivityRows.percent((meters.cpu ?? 0) * 100))% of \(meters.cores.count) cores")
                Spacer(minLength: 2)
                if let performance = meters.performanceCores, let efficiency = meters.efficiencyCores {
                    Text(verbatim: "P \(performance) · E \(efficiency)")
                }
            }
            .font(.system(size: ChromeMetrics.text(10.5), design: .monospaced)).foregroundStyle(theme.text3)
        } else {
            Text(verbatim: "—").font(.system(size: ChromeMetrics.text(11), design: .monospaced)).foregroundStyle(theme.text3)
        }
    }

    private func line(_ label: String, _ value: String, _ color: Color? = nil) -> some View {
        HStack(spacing: 4) {
            Text(label).foregroundStyle(theme.text3)
            Spacer(minLength: 4)
            Text(verbatim: value).foregroundStyle(color ?? theme.text2).lineLimit(1)
        }
        .font(.system(size: ChromeMetrics.text(11)))
    }

    static func uptime(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds) / 60
        let days = minutes / 1_440
        let hours = (minutes % 1_440) / 60
        if days > 0 { return "\(days) d \(hours) h" }
        return hours > 0 ? "\(hours) h \(minutes % 60) min" : "\(minutes) min"
    }
}
