import Combine
import Foundation

/// The ⌃⌘A switcher's rows (docs/design/activity/analysis.md, 6.2): the
/// listening ports first, by number, then the ten busiest processes, as
/// ranked when it opened. It holds the census's full level while the
/// palette shows it — every second, so CPU has a rate by the second read —
/// and stocks its rows until a read with rates, then keeps them and gives
/// the full level back (7.3 asks only for two ticks 1 s apart first;
/// every later one would be read and thrown away): the
/// palette re-ranks on a reorder, which would move the selection, and a
/// changed CPU figure alone is never shown (`PaletteModel.restock`).
@MainActor
package final class ActivitySwitcher {
    package struct Row: Equatable, Sendable {
        package enum Target: Equatable, Sendable {
            case port(url: URL?)
            case process
        }

        /// The page's row id: a port's or a process's.
        package let id: String
        package let title: String
        package let subtitle: String
        package let target: Target
        package let tab: UUID?
    }

    package let monitor: ActivityMonitor
    /// Its rows, once a full read is made into them; nil while closed.
    package private(set) var rows: [Row]?
    /// Whether it is open: its rows held while the palette shows them.
    package private(set) var holding = false
    /// Whether it wants the census's full level now: from its opening
    /// until a read with rates is made into its rows.
    package private(set) var wanting = false
    /// Rows stocked, a scenario's count.
    package private(set) var stocks = 0
    private var rated = false
    private var latest = 0
    private var snapshots: AnyCancellable?
    /// What the window does when the rows change: the palette restocked.
    package var stocked: @MainActor () -> Void = {}
    package var tabTitles: @MainActor () -> [UUID: String] = { [:] }
    package var isolated = AppEnvironment.isIsolated

    package init(monitor: ActivityMonitor = .shared) {
        self.monitor = monitor
    }

    /// The palette opened on it: the full level, every second, while it shows.
    package func open() {
        guard !holding else { return }
        holding = true
        rated = false
        latest = 0
        wanting = true
        monitor.want(self, .full, every: .seconds(1))
        if let last = monitor.lastFull, monitor.age(of: last) <= ActivityMonitor.nanoseconds(monitor.interval) { take(last) }
        // @Published emits before it changes: the emitted value.
        snapshots = monitor.$snapshot.compactMap { $0 }.filter { $0.demand.full }
            .sink { [weak self] snapshot in self?.take(snapshot) }
    }

    /// The palette closed: the hold given back, the rows dropped.
    package func close() {
        guard holding else { return }
        holding = false
        letGo()
        rows = nil
    }

    /// The full level given back: its rows are kept from here on.
    private func letGo() {
        guard wanting else { return }
        wanting = false
        snapshots = nil
        monitor.unwant(self)
    }

    private func take(_ snapshot: ActivitySnapshot) {
        guard holding, !rated, snapshot.tick > latest else { return }
        latest = snapshot.tick
        var options = ActivityRows.Options(titles: tabTitles(), everyone: Settings.shared.activityEveryone, isolated: isolated)
        // Its rows are flat: no groups made.
        options.grouping = nil
        Task { [weak self] in
            let made = await Self.make(snapshot, options)
            guard let self, self.holding, !self.rated, self.latest == snapshot.tick else { return }
            self.rows = made.rows
            self.rated = made.rated
            self.stocks += 1
            if made.rated { self.letGo() }
            self.stocked()
        }
    }

    private nonisolated static func make(_ snapshot: ActivitySnapshot, _ options: ActivityRows.Options) async -> (rows: [Row], rated: Bool) {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let content = ActivityRows.content(of: snapshot, options)
                continuation.resume(returning: (rows(of: content), !content.summary.firstSample))
            }
        }
    }

    /// Ports by number, then the ten busiest with a rate. Pure.
    package nonisolated static func rows(of content: ActivityPageContent) -> [Row] {
        func place(_ title: String?) -> String { title.map { " — “\($0)”" } ?? "" }
        // Every listener, the folded ephemeral ones too.
        let ports = content.listeners.filter { $0.kind == .listener }.sorted { ($0.port, $0.proto) < ($1.port, $1.proto) }
            .map { port in
                Row(
                    id: port.id, title: ":\(port.port) \(port.process)", subtitle: "\(port.proto) · \(port.reach)\(place(port.tabTitle))",
                    target: .port(url: port.url), tab: port.tab)
            }
        let busiest = content.processes.filter { $0.cpu != nil }.sorted { ($0.cpu ?? 0) > ($1.cpu ?? 0) }.prefix(10)
            .map { process in
                Row(
                    id: process.id, title: process.name,
                    subtitle: "\(ActivityRows.percent(process.cpu ?? 0))% CPU · pid \(process.identity.pid)\(place(process.tabTitle))",
                    target: .process, tab: process.tab)
            }
        return ports + busiest
    }
}
