import Foundation

// Change markers on every chart (docs/design/kubernetes/metrics.md, 3.2;
// stage M4): rollouts and Helm revisions, scaling, restarts, OOMKills and
// Warning events, joined from what the detail already holds — a workload's
// History (`KubeTimeline`), the detail's own events, its pods' `lastState`
// and the restarts seen between two reads of them — by a pure join that
// reads nothing. At most `KubeChartMarkers.cap` a chart; older ones fold
// into "+N earlier". A marker's popover opens it, and "Show ±30 min" sets
// a custom window around it (`KubeChartWindow`).

/// A custom window over the Metrics tab's charts: a marker's time ± 30
/// minutes, its end never in the future. With sampled data it only
/// narrows the axis — nothing is asked (metrics.md 3.3): drawn from 6h's
/// folded minutes (`tier`). In memory, the page's, never saved. Pure.
struct KubeChartWindow: Equatable, Hashable, Sendable {
    var start: Date
    var end: Date

    /// Either side of a marker.
    static let around: TimeInterval = 1800

    /// `time` ± 30 minutes, the end at `now` at the latest — never empty.
    static func around(_ time: Date, now: Date) -> KubeChartWindow {
        let end = min(time.addingTimeInterval(around), now)
        let start = min(time.addingTimeInterval(-around), end.addingTimeInterval(-60))
        return KubeChartWindow(start: start, end: end)
    }

    /// The sampled tier that holds it: 6h's minute buckets, always. A
    /// window starts at least 30 minutes before now (its marker is never in
    /// the future), past the raw tier's 15 minutes, so Live's samples never
    /// hold the whole of it — even around a marker a minute old its first
    /// half is minutes only; one tier for the whole axis, never two spacings
    /// on one line.
    var tier: KubeMetricsRange { .sixHours }

    /// `13:28–14:28`.
    var title: String { "\(KubeChartTime.clock(start))–\(KubeChartTime.clock(end))" }

    /// `data` narrowed to the window: its usage points and breaks inside
    /// it, a reference's steps up to its end; versioned anew.
    func narrow(_ data: KubeChartData) -> KubeChartData {
        var data = data
        data.start = start
        data.end = end
        data.series = data.series.map { series in
            var series = series
            if series.role.isReference {
                // A reference of several readings: the one standing at the start, then those inside.
                let readings = series.points
                guard readings.count > 1 else { return series }
                let before = readings.last { $0.time <= start }
                series.points = (before.map { [$0] } ?? []) + readings.filter { $0.time > start && $0.time <= end }
                // All after the window: the first one, as the line it was.
                if series.points.isEmpty, let first = readings.first { series.points = [first] }
            } else {
                series.points = series.points.filter { $0.time >= start && $0.time <= end }
                series.breaks = series.breaks.filter { $0 >= start && $0 <= end }
            }
            return series
        }
        var hasher = Hasher()
        hasher.combine(data.version)
        hasher.combine(self)
        data.version = hasher.finalize()
        return data
    }
}

/// The containers' restarts and last terminations of a pod or of a
/// workload's pods (metrics.md 2.3, 2.5; W2's markers), decoded from the
/// pod objects of one bounded read — everything else dropped as it is
/// decoded, env and all; no object kept. Pure.
struct KubePodStates: Equatable, Sendable {
    struct Container: Equatable, Sendable {
        var name: String
        var restarts: Int
        var last: KubePodCharts.Termination?
    }

    struct Pod: Equatable, Sendable {
        var name: String
        var containers: [Container]
    }

    /// The workload's pods read at most: a workload of more is marked for these.
    static let limit = 250
    /// The most of an answer read: 250 pods' whole objects (managedFields,
    /// env, annotations) at 64 KB each. Past it the read stops there, its
    /// connection closed, and the tab says so (`tooLarge`).
    static let maxBytes = 16 << 20

    /// What the tab says of an answer past `maxBytes`.
    static func tooLarge(limit: Int) -> String {
        let size = limit >= 1 << 20 ? "\(limit >> 20) MB" : "\(limit >> 10) KB"
        return "their answer passed \(size), more than is read here, so restarts and OOMKills aren't marked."
    }

    var pods: [Pod]
    /// More than `limit` matched: the rest not read.
    var more = false
    var read: Date

    struct Malformed: Error, LocalizedError {
        var errorDescription: String? { "The pods' answer isn't a pod or a pod list." }
    }

    /// One pod's object, as its containers' states.
    static func pod(_ object: [String: Any]) -> Pod? {
        guard let name = (object["metadata"] as? [String: Any])?["name"] as? String else { return nil }
        let containers = KubePodCharts.containers(of: object).map { Container(name: $0.name, restarts: $0.restarts, last: $0.lastTerminated) }
        return Pod(name: name, containers: containers)
    }

    /// A PodList's (or one Pod's) answer.
    static func read(_ data: Data, at read: Date) throws -> KubePodStates {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Malformed() }
        if let items = object["items"] as? [[String: Any]] {
            let token = ((object["metadata"] as? [String: Any])?["continue"] as? String) ?? ""
            return KubePodStates(pods: items.compactMap(pod).sorted { $0.name < $1.name }, more: !token.isEmpty, read: read)
        }
        guard let one = pod(object) else { throw Malformed() }
        return KubePodStates(pods: [one], read: read)
    }
}

/// The restarts seen between two reads of the pods' states: a container
/// whose restartCount rose between them restarted in that stretch — the
/// last one's own time is its `lastState`'s, the others' only the stretch
/// ("restarted between 14:02 and 14:03"). Kept for the detail, bounded;
/// dropped with it. Pure.
struct KubeRestartLog: Equatable, Sendable {
    struct Restart: Equatable, Sendable {
        var pod: String
        var container: String
        var from: Date
        var to: Date
        var count: Int
        /// Its last termination changed between the two reads: that one is
        /// this restart (one), its own time exact — kept, since the pod's
        /// status keeps only the last.
        var termination: KubePodCharts.Termination?
        var exact: Bool { termination != nil }
    }

    /// The restarts kept, the newest.
    static let kept = 200

    /// The last read.
    private(set) var states: KubePodStates?
    /// Oldest first.
    private(set) var restarts: [Restart] = []

    init(_ states: KubePodStates? = nil) { self.states = states }

    /// A read: each container's restarts against the last read's — a pod or a container new since says nothing.
    mutating func record(_ new: KubePodStates) {
        if let old = states, new.read > old.read {
            for pod in new.pods {
                guard let before = old.pods.first(where: { $0.name == pod.name }) else { continue }
                for container in pod.containers {
                    guard let was = before.containers.first(where: { $0.name == container.name }), container.restarts > was.restarts else { continue }
                    let exact = container.last?.finishedAt != nil && container.last?.finishedAt != was.last?.finishedAt
                    restarts.append(
                        Restart(
                            pod: pod.name, container: container.name, from: old.read, to: new.read, count: container.restarts - was.restarts,
                            termination: exact ? container.last : nil))
                }
            }
            if restarts.count > Self.kept { restarts.removeFirst(restarts.count - Self.kept) }
        }
        if let old = states, new.read <= old.read { return }
        states = new
    }
}

/// What a tab's markers are joined from: what its detail already holds. Pure.
struct KubeChartChanges: Equatable, Sendable {
    /// A workload's History, newest first.
    var timeline: [KubeTimelineEntry] = []
    /// The detail's own events (a kind without a History: a pod, an HPA, a node…).
    var events: [KubeEvent] = []
    /// Its pods' states as read last, and the restarts seen between reads.
    var restarts = KubeRestartLog()
    /// The pods' states are a workload's: its markers name each pod.
    var namesPods = false
    /// Why the pods' states couldn't be read: said under the charts.
    var problem: String?
    /// Events are one of its sources — a History (which always reads the
    /// object's events), or its own events once loaded — whether any came
    /// back or not: the "events: last hour" note says why older ones
    /// aren't marked, most of all when none are.
    var eventsJoined = false

    var isEmpty: Bool { timeline.isEmpty && events.isEmpty && restarts.states == nil }

    /// What the charts' cache is keyed by.
    var version: Int {
        var hasher = Hasher()
        for entry in timeline { hasher.combine(entry.id) }
        for event in events {
            hasher.combine(event.id)
            hasher.combine(event.count)
        }
        hasher.combine(restarts.states?.read)
        hasher.combine(restarts.restarts.count)
        hasher.combine(namesPods)
        hasher.combine(problem)
        hasher.combine(eventsJoined)
        return hasher.finalize()
    }
}

/// The join (metrics.md 3.2): History entries, events, terminations and
/// restarts as markers; capped to a chart's window; the events' note. Pure.
enum KubeChartMarkers {
    /// At most this many a chart: the newest; the older ones "+N earlier".
    static let cap = 50
    /// The API server keeps events about this long (`--event-ttl`).
    static let eventsKept: TimeInterval = 3600
    static let eventsNote = "events: last hour"

    // MARK: Sources

    /// A workload's History: its revisions (rollouts, restarts, rollbacks)
    /// and Helm revisions blue, its scaling grey, its warnings yellow.
    static func timeline(_ entries: [KubeTimelineEntry]) -> [KubeChartMarker] {
        entries.compactMap { entry in
            guard let time = entry.time else { return nil }
            let kind: KubeChartMarker.Kind =
                switch entry.kind {
                case .revision, .restart, .rollback: .rollout
                case .helm: .helm
                case .scale: .scale
                case .warning: .warning
                }
            let count = entry.count > 1 ? " ×\(entry.count)" : ""
            return KubeChartMarker(
                id: entry.id, kind: kind, time: time, title: "\(entry.title)\(count) at \(KubeChartTime.clock(time))\(entry.approximate ? " or after" : "")",
                detail: entry.detail, opens: .history(entry: entry.id, change: entry.change))
        }
    }

    /// The detail's own events: its warnings, and an HPA's or a
    /// Deployment's scaling (`SuccessfulRescale`, `ScalingReplicaSet`).
    static func events(_ events: [KubeEvent]) -> [KubeChartMarker] {
        events.compactMap { event in
            guard let time = event.last ?? event.first else { return nil }
            let kind: KubeChartMarker.Kind
            if event.isWarning {
                kind = .warning
            } else if ["SuccessfulRescale", "ScalingReplicaSet"].contains(event.reason) {
                kind = .scale
            } else {
                return nil
            }
            let count = event.count > 1 ? " ×\(event.count)" : ""
            return KubeChartMarker(
                id: "event/\(event.id)", kind: kind, time: time, title: "\(event.reason)\(count) at \(KubeChartTime.clock(time))", detail: event.message,
                opens: .event(event.id))
        }
    }

    /// The pods' last terminations (exact, `lastState.terminated.finishedAt`)
    /// and the restarts seen between reads but one whose termination
    /// changed meanwhile (that one is the same restart, said exactly) —
    /// of `pod` and `container` when named. `namesPods`: a workload's, each named by its pod.
    static func pods(_ log: KubeRestartLog, pod only: String? = nil, container: String? = nil, namesPods: Bool) -> [KubeChartMarker] {
        guard let states = log.states else { return [] }
        var out: [KubeChartMarker] = []
        var seen: Set<String> = []
        func add(_ marker: KubeChartMarker) { if seen.insert(marker.id).inserted { out.append(marker) } }
        for pod in states.pods where only == nil || pod.name == only {
            for state in pod.containers where container == nil || state.name == container {
                if let marker = termination(state, pod: namesPods ? pod.name : nil) { add(marker) }
            }
        }
        for restart in log.restarts where (only == nil || restart.pod == only) && (container == nil || restart.container == container) {
            // An earlier termination, superseded in the status since: still marked, at its own time.
            if let ended = restart.termination,
                let marker = termination(KubePodStates.Container(name: restart.container, restarts: 0, last: ended), pod: namesPods ? restart.pod : nil)
            {
                add(marker)
            }
            guard !(restart.exact && restart.count == 1) else { continue }
            let who = namesPods ? "\(restart.pod)/\(restart.container)" : restart.container
            let times = restart.count > 1 ? " \(restart.count) times" : ""
            add(
                KubeChartMarker(
                    id: "restart.\(restart.pod).\(restart.container).\(Int(restart.to.timeIntervalSince1970))", kind: .restart, time: restart.to,
                    title: "\(who): restarted\(times) between \(KubeChartTime.clock(restart.from)) and \(KubeChartTime.clock(restart.to))", container: restart.container,
                    detail: "Its restart count rose between two reads; the last termination's own time is its lastState's.",
                    opens: .previousLog(pod: namesPods ? restart.pod : nil, container: restart.container)))
        }
        return out
    }

    /// A container's last termination, where its time is known: OOMKilled red, any other a restart.
    static func termination(_ container: KubePodStates.Container, pod: String? = nil) -> KubeChartMarker? {
        guard let last = container.last, let time = last.finishedAt else { return nil }
        let oom = last.reason == "OOMKilled"
        let exit = last.exitCode.map { " (exit \($0))" } ?? ""
        let what = oom ? "OOMKilled\(exit)" : "Restarted after \(last.reason)\(exit)"
        let kept = container.restarts > 1 ? " · only the last previous instance's log is kept" : ""
        let who = pod.map { "\($0)/\(container.name)" } ?? container.name
        return KubeChartMarker(
            id: "\(pod.map { $0 + "." } ?? "")\(container.name).\(Int(time.timeIntervalSince1970))", kind: oom ? .oom : .restart, time: time,
            title: "\(who): \(what) at \(KubeChartTime.clock(time))\(kept)", container: container.name,
            opens: .previousLog(pod: pod, container: container.name))
    }

    // MARK: A chart's

    /// Those inside `start…end`, once each (the first of an id), oldest
    /// first: the newest `cap`, and how many older were left out.
    static func capped(_ markers: [KubeChartMarker], start: Date, end: Date) -> (markers: [KubeChartMarker], earlier: Int) {
        var seen: Set<String> = []
        let inside = markers.filter { $0.time >= start && $0.time <= end && seen.insert($0.id).inserted }
            .enumerated().sorted { $0.element.time == $1.element.time ? $0.offset < $1.offset : $0.element.time < $1.element.time }.map(\.element)
        guard inside.count > cap else { return (inside, 0) }
        return (Array(inside.suffix(cap)), inside.count - cap)
    }

    /// Events are kept about an hour: a chart reaching further back whose
    /// tab joins events says so, whether or not any is marked — none
    /// marked on 6h may only mean they expired; older warnings come only
    /// from a History.
    static func note(eventsJoined: Bool, start: Date, now: Date) -> String? {
        eventsJoined && start < now.addingTimeInterval(-eventsKept) ? eventsNote : nil
    }

    /// `data` with its markers: those in its window, capped, the note,
    /// its version changed with them.
    static func apply(_ markers: [KubeChartMarker], eventsJoined: Bool, to data: KubeChartData, now: Date) -> KubeChartData {
        var data = data
        let (kept, earlier) = capped(data.markers + markers, start: data.start, end: data.end)
        data.markers = kept
        data.earlierMarkers = earlier
        data.markerNote = note(eventsJoined: eventsJoined, start: data.start, now: now)
        var hasher = Hasher()
        hasher.combine(data.version)
        for marker in kept { hasher.combine(marker.id) }
        hasher.combine(earlier)
        hasher.combine(data.markerNote)
        data.version = hasher.finalize()
        return data
    }

    // MARK: A tab's

    /// A pod's tab: every chart its pod's terminations, restarts and
    /// events; a container's charts that container's.
    static func mark(_ charts: KubePodCharts, pod: String, changes: KubeChartChanges, window: KubeChartWindow?, now: Date) -> KubePodCharts {
        var charts = charts
        let events = Self.events(changes.events)
        func finish(_ chart: KubePodCharts.Chart, container: String?) -> KubePodCharts.Chart {
            var chart = chart
            if let window { chart.data = window.narrow(chart.data) }
            let own = pods(changes.restarts, pod: pod, container: container, namesPods: false)
            chart.data = apply(own + events, eventsJoined: changes.eventsJoined, to: chart.data, now: now)
            return chart
        }
        charts.pod = charts.pod.map { finish($0, container: nil) }
        charts.sections = charts.sections.map { section in
            var section = section
            section.charts = section.charts.map { finish($0, container: section.container) }
            return section
        }
        if let window { charts.mark(window) }
        return charts
    }

    /// A workload's, an HPA's, a node's or a namespace's tab: every chart
    /// its History's or its events' markers; a workload's CPU and memory
    /// (W1, W2) also its pods' OOMKills and restarts.
    static func mark(_ charts: KubeObjectCharts, changes: KubeChartChanges, window: KubeChartWindow?, now: Date) -> KubeObjectCharts {
        var charts = charts
        let shared = timeline(changes.timeline) + events(changes.events)
        let podMarkers = pods(changes.restarts, namesPods: changes.namesPods)
        charts.groups = charts.groups.enumerated().map { index, group in
            var group = group
            group.charts = group.charts.map { chart in
                var chart = chart
                if let window { chart.data = window.narrow(chart.data) }
                let usage = index == 0 && (chart.data.id.hasSuffix(".cpu") || chart.data.id.hasSuffix(".memory"))
                chart.data = apply(shared + (usage ? podMarkers : []), eventsJoined: changes.eventsJoined, to: chart.data, now: now)
                return chart
            }
            return group
        }
        if let problem = changes.problem { charts.notes.append(problem) }
        if let states = changes.restarts.states, states.more {
            charts.notes.append("More than \(KubePodStates.limit) pods: restarts and OOMKills are marked for the first \(KubePodStates.limit) read.")
        }
        if let window { charts.mark(window) }
        return charts
    }
}

extension KubePodCharts {
    /// The window said: the caption, and nothing sampled in it said plainly.
    fileprivate mutating func mark(_ window: KubeChartWindow) {
        span = window.title
        hasSamples = (pod + sections.flatMap(\.charts)).contains { chart in chart.data.usage.contains { !$0.points.isEmpty } }
        caption = hasSamples ? "\(caption) · Custom \(window.title)" : KubeChartMarkers.nothingSampled(window)
    }
}

extension KubeObjectCharts {
    fileprivate mutating func mark(_ window: KubeChartWindow) {
        span = window.title
        hasSamples = charts.contains { chart in chart.data.usage.contains { !$0.points.isEmpty } }
        caption = hasSamples ? "\(caption) · Custom \(window.title)" : KubeChartMarkers.nothingSampled(window)
    }
}

extension KubeChartMarkers {
    /// A window with nothing in it: sampled only while shown, so nothing from then.
    static func nothingSampled(_ window: KubeChartWindow) -> String {
        "Nothing was sampled between \(window.title): metrics-server keeps no history, and Overterm samples only while a chart shows. Reset shows the range again."
    }
}
