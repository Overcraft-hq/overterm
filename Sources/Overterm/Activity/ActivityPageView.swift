import SwiftUI

/// A row of the page's one list: a process's or a listener's. One table for
/// both sections, so the list keeps its place in the view tree — the
/// keyboard and the scroll with it — as the section changes (6.4).
enum ActivityListRow: ResourceTableRow {
    case process(ActivityProcessRow)
    case port(ActivityPortRow)

    var id: String {
        switch self {
        case .process(let row): row.id
        case .port(let row): row.id
        }
    }

    var height: CGFloat { 24 }

    var reuseKind: String {
        switch self {
        case .process: "process"
        case .port: "port"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .process(let row): row.accessibilityLabel
        case .port(let row): row.accessibilityLabel
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
        case .processes: page.content.processes.map(ActivityListRow.process)
        case .listening: page.content.ports.map(ActivityListRow.port)
        }
    }

    private var columns: [ResourceColumn] {
        switch page.section {
        case .processes:
            [
                ResourceColumn(id: "name", title: "Name", width: 220, minWidth: 120),
                ResourceColumn(id: "pid", title: "PID", width: 64),
                ResourceColumn(id: "cpu", title: "CPU %", width: 64, help: "100% is one core, as htop and Tab Info count"),
                ResourceColumn(id: "memory", title: "Memory", width: 84, help: "The footprint: Activity Monitor's Memory"),
                ResourceColumn(id: "threads", title: "Threads", width: 60),
                ResourceColumn(id: "state", title: "St", width: 36, help: "R running, S sleeping, T stopped, Z ended and not collected"),
                ResourceColumn(id: "started", title: "Started", width: 80),
                ResourceColumn(id: "user", title: "User", width: 90),
                ResourceColumn(id: "where", title: "Where", width: 160, help: "The tab it runs in"),
            ]
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
        }
    }

    @ViewBuilder
    private func processCell(_ row: ActivityProcessRow, _ column: String?) -> some View {
        switch column {
        case "name":
            text(row.name, row.isOwn ? theme.text : theme.text2)
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
        case "where":
            text(row.tabTitle.map { "“\($0)”" } ?? "", theme.text2)
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
