import Foundation

/// The Metrics tab's GPUs from the objects (docs/design/kubernetes/metrics.md,
/// decision 12; stage M8c): a pod's containers', a node's resources and the
/// pods that hold them (its pods as objects, read every 5 minutes while
/// shown — without metrics-server too), a workload's template's times its
/// pods. Shown above the charts whatever their source; the object's having
/// GPUs is also what lets the tab ask DCGM exporter at all.
extension KubernetesPageModel {
    /// The detail's GPUs; nil, none — built again only when the object or
    /// the node's pods' read changes.
    func gpuAllocation(of session: KubeDetailSession) -> KubeGPUAllocation? {
        let ref = session.ref
        guard let subject = ref.metricsSubject, let object = session.object else { return nil }
        let nodePods = subject == .node ? model.metrics.reading(.nodePods(ref.name))?.sample : nil
        let key = [
            ref.context, ref.kind.fullName, ref.namespace ?? "", ref.name, object.resourceVersion ?? "", String(object.data.count),
            nodePods.map { String($0.read.timeIntervalSince1970) } ?? "",
        ].joined(separator: "\n")
        if let cached = gpuCache, cached.key == key { return cached.allocation }
        let made = KubeGPUAllocation.of(subject, object: object.json, nodePods: nodePods?.nodePods)
        gpuCache = (key, made)
        return made
    }

    /// A node's GPU holder clicked: its pod, through the history (`[` returns).
    func openGPUHolder(_ pod: KubeRowID) {
        guard let context = detail?.ref.context ?? model.selectedName else { return }
        let kind = model.knownDiscovery(of: context)?.kind(apiVersion: "v1", kind: "Pod") ?? .pods
        open(KubeObjectRef(context: context, kind: kind, namespace: pod.namespace, name: pod.name), from: .link)
    }
}
