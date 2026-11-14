import Foundation

/// Sizing on a pod's or a workload's Metrics tab (docs/design/kubernetes/
/// metrics.md 2.10; stage M10): offered where the context's Prometheus is
/// on, asked on the press — seven days of usage, once, never refreshed —
/// and read only while that object's tab shows: the tab left before it
/// answers, nothing more is asked until it is pressed again. What it
/// suggests is shown, never applied nor typed anywhere.
extension KubernetesPageModel {
    /// Whose usage the detail's Sizing would size: a pod, or a workload with pods.
    func sizingSubject(of ref: KubeObjectRef) -> KubeSizingSubject? {
        guard let namespace = ref.namespace else { return nil }
        switch ref.metricsSubject {
        case .pod: return .pod(namespace: namespace, name: ref.name)
        case .workload(let kind): return .workload(namespace: namespace, kind: kind, name: ref.name)
        default: return nil
        }
    }

    /// Whether the tab offers Sizing: a pod or a workload, Prometheus opted in.
    func offersSizing(_ ref: KubeObjectRef) -> Bool { sizingSubject(of: ref) != nil && prometheusOn }

    /// Why Sizing can't be pressed now; nil, it can.
    var sizingDisabled: String? {
        switch model.prometheus.state {
        case .found: return nil
        case .unavailable(let why): return why
        default: return "Looking for Prometheus…"
        }
    }

    /// Sizing pressed: R1 asked of Prometheus for the detail's object, once.
    func sizeUsage() {
        guard let ref = detail?.ref, let subject = sizingSubject(of: ref), prometheusOn, sizingDisabled == nil else { return }
        sizingAsked = KubeSizingRequest(context: ref.context, subject: subject, asked: Date())
        updatePrometheusWanted()
    }

    /// The card closed: its answer stays the monitor's until another press.
    func hideSizing() {
        sizingAsked = nil
        updatePrometheusWanted()
    }

    /// The press for `ref`'s object, if the last one was its.
    func sizingRequest(of ref: KubeObjectRef) -> KubeSizingRequest? {
        guard let asked = sizingAsked, asked.context == ref.context, asked.subject == sizingSubject(of: ref) else { return nil }
        return asked
    }

    /// Its answer as it stands: nil, not pressed (or dropped: the tab left before it came).
    func sizingReading(of ref: KubeObjectRef) -> KubeSizingReading? {
        sizingRequest(of: ref).flatMap { model.prometheus.sizings[$0] }
    }

    /// The press read while its object's Metrics tab shows on a page on screen, until it is.
    var sizingWant: KubeSizingRequest? {
        guard windowVisible, visible, prometheusOn, metricsTabShows, let ref = detail?.ref, let request = sizingRequest(of: ref), model.selected?.name == request.context
        else { return nil }
        return model.prometheus.sizings[request]?.done == true ? nil : request
    }

    /// The card for `session`: the answer against the pod's spec, or its
    /// workload's template, and the OOMKills its objects say (the pod's
    /// last terminations, its workload's pods' as the markers read them).
    func sizingCard(of session: KubeDetailSession, now: Date = Date()) -> KubeSizingCard? {
        guard let reading = sizingReading(of: session.ref), reading.done, !reading.figures.isEmpty else { return nil }
        var containers: [KubePodCharts.Container] = []
        var killed: [String: Date] = [:]
        func note(_ container: String, _ termination: KubePodCharts.Termination?) {
            guard let termination, termination.reason == "OOMKilled", let at = termination.finishedAt else { return }
            killed[container] = max(killed[container] ?? at, at)
        }
        if let json = session.object?.json {
            if session.ref.isPod {
                containers = KubePodCharts.containers(of: json)
                for container in containers { note(container.name, container.lastTerminated) }
            } else {
                let template = ((json["spec"] as? [String: Any])?["template"] as? [String: Any]) ?? [:]
                containers = KubePodCharts.containers(of: ["spec": template["spec"] ?? [:]])
            }
        }
        if let states = podStates, states.ref == session.ref {
            for pod in states.log.states?.pods ?? [] {
                for container in pod.containers { note(container.name, container.last) }
            }
            for restart in states.log.restarts { note(restart.container, restart.termination) }
        }
        return KubeSizingCard.of(reading, containers: containers, oomKilled: killed, now: now)
    }
}
