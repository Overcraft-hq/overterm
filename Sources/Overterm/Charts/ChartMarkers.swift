import Foundation

/// A moment marked on a time chart: a tick on the plot's bottom edge with
/// a faint line the whole height, its colour by kind, hover saying what it
/// was, a click its popover — what opens it, "Show ±30 min" — and ⌥-click
/// the window around it (metrics.md, 3.2). `KubeChartMarkers` joins them
/// from what the detail already holds: a workload's History, the detail's
/// events, its pods' `lastState` and the restarts seen between reads.
package struct KubeChartMarker: Equatable, Sendable, Identifiable {
    /// How many a chart marks at most: the newest (`KubeChartMarkers`).
    package static let cap = 50

    package enum Kind: String, Sendable, CaseIterable {
        /// A new pod template, a rollout restart, a rollback: blue.
        case rollout
        /// A Helm revision: blue.
        case helm
        /// Replicas changed: grey.
        case scale
        /// A container ended and was started again: orange.
        case restart
        /// It was OOMKilled: red.
        case oom
        /// A Warning event: yellow.
        case warning

        /// What the popover calls it.
        package var label: String {
            switch self {
            case .rollout: "Rollout"
            case .helm: "Helm revision"
            case .scale: "Scaled"
            case .restart: "Restart"
            case .oom: "OOMKilled"
            case .warning: "Warning"
            }
        }
    }

    /// What a click on it opens.
    package enum Opens: Equatable, Sendable {
        /// A container's previous instance's log: the pod shown's (`pod` nil), or a workload's pod's.
        case previousLog(pod: String?, container: String)
        /// A History entry, and the diff it has.
        case history(entry: String, change: KubeTimelineChange?)
        /// One of the detail's events, in its Events tab.
        case event(String)

        /// What the popover's button says.
        package var title: String {
            switch self {
            case .previousLog(let pod, _): pod == nil ? "Previous Log" : "Open Pod's Previous Log"
            case .history(_, let change): change == nil ? "Show in History" : "Show Diff"
            case .event: "Show in Events"
            }
        }
    }

    package var id: String
    package var kind: Kind
    package var time: Date
    /// What hover says: "OOMKilled at 14:11 (exit 137)".
    package var title: String
    /// The container it is of, where it is one's: a click opens its previous log.
    package var container: String?
    /// The popover's second line: what changed, the event's message.
    package var detail: String?
    package var opens: Opens?

    package init(id: String, kind: Kind, time: Date, title: String, container: String? = nil, detail: String? = nil, opens: Opens? = nil) {
        self.id = id
        self.kind = kind
        self.time = time
        self.title = title
        self.container = container
        self.detail = detail
        self.opens = opens
    }
}

/// What opens a change's diff in the changes pane.
package enum KubeTimelineChange: Hashable, Sendable {
    /// One template revision against another (`from` nil: the first, against nothing).
    case template(from: Int?, to: Int)
    /// One Helm revision against another.
    case helm(from: Int?, to: Int)
}

/// One query a chart was drawn from, as it was sent: its id among the
/// tab's (`KubeTabQuery.id`) and its PromQL — what "Copy PromQL" gives.
package struct KubeChartQuery: Equatable, Sendable {
    package var id: String
    package var promql: String
    package var instant = false

    package init(id: String, promql: String, instant: Bool = false) {
        self.id = id
        self.promql = promql
        self.instant = instant
    }
}
