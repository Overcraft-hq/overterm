import Foundation

/// One stream of a merged log: a pod's container, as stern follows it.
struct KubeLogStreamKey: Hashable, Sendable, CustomStringConvertible {
    var pod: String
    var container: String

    /// What its lines are prefixed with, and coloured by: `pod/container`.
    var description: String { "\(pod)/\(container)" }
}

/// stern's include and exclude: regular expressions (case aside) over a
/// pod's name (`--pod-query`, `--exclude-pod`), a container's
/// (`--container`) and a line (`--include`, `--exclude`). Empty, a part
/// picks everything. A pod or container left out takes no stream; a
/// line left out never reaches the feed. Pure.
struct KubeMergedLogFilter: Equatable, Sendable {
    var pods = ""
    var excludePods = ""
    var containers = ""
    var lines = ""
    var excludeLines = ""

    var isEmpty: Bool { [pods, excludePods, containers, lines, excludeLines].allSatisfy { $0.isEmpty } }

    /// How many parts pick something.
    var count: Int { [pods, excludePods, containers, lines, excludeLines].filter { !$0.isEmpty }.count }

    /// The first part that isn't a regular expression, said; nil when each is one.
    var problem: String? {
        for (title, pattern) in [("Pods", pods), ("Pods left out", excludePods), ("Containers", containers), ("Lines", lines), ("Lines left out", excludeLines)]
        where !pattern.isEmpty && Self.expression(pattern) == nil {
            return "\(title): not a regular expression"
        }
        return nil
    }

    static func expression(_ pattern: String) -> NSRegularExpression? {
        pattern.isEmpty ? nil : try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    private static func found(_ expression: NSRegularExpression?, in text: String) -> Bool {
        expression?.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil
    }

    /// Whether a pod's streams are followed: its name matches `pods` (when
    /// set) and not `excludePods`.
    func picks(pod name: String) -> Bool {
        if !pods.isEmpty, !Self.found(Self.expression(pods), in: name) { return false }
        return excludePods.isEmpty || !Self.found(Self.expression(excludePods), in: name)
    }

    func picks(container name: String) -> Bool {
        containers.isEmpty || Self.found(Self.expression(containers), in: name)
    }

    /// The line parts, made once: a stream's thousands of lines go through it.
    func lineMatcher() -> LineMatcher { LineMatcher(include: Self.expression(lines), exclude: Self.expression(excludeLines)) }

    struct LineMatcher {
        let include: NSRegularExpression?
        let exclude: NSRegularExpression?

        /// Its message and a JSON line's fields, as the pane shows them.
        func keeps(_ line: LogLine) -> Bool {
            guard include != nil || exclude != nil else { return true }
            let text = line.fields.isEmpty ? line.message : line.message + "  " + line.fields.map { "\($0.0)=\($0.1)" }.joined(separator: " ")
            if include != nil, !KubeMergedLogFilter.found(include, in: text) { return false }
            return !KubeMergedLogFilter.found(exclude, in: text)
        }
    }
}

/// Which streams a merged log follows: the pods the selector picks (and
/// the filter keeps), each container of theirs, at most `cap` at once
/// (`kubernetes.logStreams`). Streams followed already keep their place —
/// a pod joining never takes one from a stream open now — then the rest
/// in the pods' order (by name) and their containers' (the spec's). A pod
/// whose containers aren't known yet is read (`fetch`) while there is
/// room. Pure.
enum KubeMergedLogPlan {
    struct Plan: Equatable {
        /// The streams followed, in the pods' order.
        var streams: [KubeLogStreamKey] = []
        /// The pods to read for their containers.
        var fetch: [String] = []
        /// How many streams the selector and the filter pick (a pod not
        /// read yet counts as one).
        var total = 0
        /// How many of them the cap leaves out.
        var capped: Int { total - streams.count - fetch.count }
    }

    /// `pods`: each pod the selector picks now, with its containers' names
    /// once read (nil: not yet). `following`: the streams open now.
    static func plan(pods: [(name: String, containers: [String]?)], following: Set<KubeLogStreamKey>, cap: Int, filter: KubeMergedLogFilter)
        -> Plan
    {
        let cap = max(cap, 1)
        let picked = pods.filter { filter.picks(pod: $0.name) }.sorted { $0.name < $1.name }
        var known: [KubeLogStreamKey] = []
        var unknown: [String] = []
        for pod in picked {
            guard let containers = pod.containers else {
                unknown.append(pod.name)
                continue
            }
            known += containers.filter(filter.picks(container:)).map { KubeLogStreamKey(pod: pod.name, container: $0) }
        }
        let kept = Set(known.filter(following.contains).prefix(cap))
        var chosen = kept
        for key in known where chosen.count < cap && !chosen.contains(key) { chosen.insert(key) }
        var plan = Plan()
        plan.streams = known.filter(chosen.contains)
        plan.fetch = Array(unknown.prefix(max(cap - plan.streams.count, 0)))
        plan.total = known.count + unknown.count
        return plan
    }
}
