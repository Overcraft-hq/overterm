import Foundation
import XCTest

@testable import Overterm

/// GPUs (docs/design/kubernetes/metrics.md, decision 12; stage M8c): what
/// the objects say — a node's GPU resources and the pods that hold them, a
/// pod's containers', a workload's template's times its pods — without
/// Prometheus; DCGM exporter's labels read by the probe's one more query;
/// the tab's `gpu` query as a golden string a subject, `exported_*` labels
/// where Prometheus scrapes it with honor_labels off; asked only where the
/// profile found DCGM, said where it didn't; the charts per GPU, per
/// container, by pod; MIG instances by profile; an allocated GPU idle over
/// the range said plainly. Pure.
final class KubeGPUTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let gib = 1_073_741_824.0

    private var operatorProfile: KubePromProfile {
        var profile = KubePromProfile(probed: now)
        profile.metrics = FakePromProfile.gpuOperator.metrics
        profile.cadvisorPath = "/metrics/cadvisor"
        profile.cadvisorJob = "kubelet"
        profile.ksmJob = "kube-state-metrics"
        profile.nodeLabel = .node
        profile.scrape = 30
        profile.dcgm = KubePromProfile.DCGM(podPrefix: "exported_", namesPods: true, nodeLabel: "Hostname", mig: false)
        return profile
    }

    private func gpuPod(_ name: String, gpus: Int, phase: String = "Running", node: String = "gpu-1") -> [String: Any] {
        [
            "metadata": ["name": name, "namespace": "ml"],
            "spec": [
                "nodeName": node,
                "containers": [
                    ["name": "trainer", "resources": ["limits": ["nvidia.com/gpu": String(gpus), "cpu": "4"], "requests": ["cpu": "2"]]],
                    ["name": "sidecar", "resources": ["requests": ["cpu": "10m"]]],
                ],
            ],
            "status": ["phase": phase],
        ]
    }

    private func points(_ values: [Double], step: TimeInterval = 30) -> [KubeSeriesPoint] {
        let start = now.addingTimeInterval(-Double(values.count - 1) * step)
        return values.enumerated().map { KubeSeriesPoint(time: start.addingTimeInterval(Double($0.offset) * step), value: $0.element) }
    }

    // MARK: From the objects

    func testAPodsGPUsAreItsContainersLimits() throws {
        XCTAssertTrue(KubeGPU.isGPU("nvidia.com/gpu"))
        XCTAssertTrue(KubeGPU.isGPU("nvidia.com/mig-1g.5gb"))
        XCTAssertTrue(KubeGPU.isGPU("amd.com/gpu"))
        XCTAssertFalse(KubeGPU.isGPU("cpu"))
        XCTAssertFalse(KubeGPU.isGPU("hugepages-2Mi"))
        let allocation = try XCTUnwrap(KubeGPUAllocation.pod(gpuPod("train-0", gpus: 2)))
        XCTAssertEqual(allocation.resources, [KubeGPUAllocation.Resource(name: "nvidia.com/gpu", allocated: 2)])
        XCTAssertEqual(allocation.holders.map(\.name), ["Container trainer"], "the sidecar holds none")
        XCTAssertEqual(allocation.lines, ["nvidia.com/gpu: 2 given", "Container trainer holds 2 nvidia.com/gpu"])
        XCTAssertNil(KubeGPUAllocation.pod(["spec": ["containers": [["name": "web", "resources": ["limits": ["cpu": "1"]]]]]]), "no GPUs, nothing said")
        // A MIG slice, and AMD's.
        let mig: [String: Any] = [
            "spec": ["containers": [["name": "a", "resources": ["limits": ["nvidia.com/mig-1g.5gb": 1, "amd.com/gpu": "1"]]]]]
        ]
        XCTAssertEqual(KubeGPUAllocation.pod(mig)?.lines.first, "amd.com/gpu: 1 given")
        XCTAssertTrue(KubeGPUAllocation.pod(mig)?.lines.contains("MIG 1g.5gb: 1 given") == true)
    }

    func testANodesGPUsAllocatedFreeAndWhoHoldsThem() throws {
        let node: [String: Any] = [
            "status": [
                "capacity": ["cpu": "48", "nvidia.com/gpu": "4"], "allocatable": ["cpu": "47", "nvidia.com/gpu": "4", "memory": "180Gi"],
            ]
        ]
        let list: [String: Any] = [
            "items": [gpuPod("train-0", gpus: 2), gpuPod("train-1", gpus: 1), gpuPod("done-0", gpus: 1, phase: "Succeeded"), gpuPod("web", gpus: 0)],
            "metadata": [:],
        ]
        let pods = try KubeNodePods.read(JSONSerialization.data(withJSONObject: list))
        XCTAssertEqual(pods.pods.first { $0.id.name == "train-0" }?.gpus, ["nvidia.com/gpu": 2], "decoded with the requests, nothing else kept")
        let allocation = try XCTUnwrap(KubeGPUAllocation.node(node, pods: pods))
        XCTAssertEqual(
            allocation.lines, ["nvidia.com/gpu: 3 of 4 allocated · 1 free", "ml/train-0 holds 2 nvidia.com/gpu", "ml/train-1 holds 1 nvidia.com/gpu"],
            "a finished pod holds none: the scheduler's count")
        XCTAssertEqual(allocation.holders.map(\.pod), [KubeRowID(namespace: "ml", name: "train-0"), KubeRowID(namespace: "ml", name: "train-1")])
        // Its pods not read yet: what it offers, and where who holds them comes from.
        let unread = try XCTUnwrap(KubeGPUAllocation.node(node, pods: nil))
        XCTAssertEqual(unread.lines, ["nvidia.com/gpu: 4 allocatable"])
        XCTAssertEqual(unread.notes.count, 1)
        // A node with none.
        XCTAssertNil(KubeGPUAllocation.node(["status": ["allocatable": ["cpu": "4"]]], pods: KubeNodePods(pods: [], more: false)))
        // Capacity past allocatable (a GPU unhealthy): both said.
        var sick = node
        sick["status"] = ["capacity": ["nvidia.com/gpu": "4"], "allocatable": ["nvidia.com/gpu": "3"]]
        XCTAssertEqual(KubeGPUAllocation.node(sick, pods: KubeNodePods(pods: [], more: false))?.lines, ["nvidia.com/gpu: 0 of 3 allocated · 3 free · capacity 4"])
    }

    func testAWorkloadsGPUsAreItsTemplatesTimesItsPods() throws {
        let deployment: [String: Any] = [
            "spec": ["template": ["spec": ["containers": [["name": "vllm", "resources": ["limits": ["nvidia.com/gpu": "1"]]]]]]],
            "status": ["replicas": 3],
        ]
        let allocation = try XCTUnwrap(KubeGPUAllocation.workload(deployment, kind: "Deployment"))
        XCTAssertEqual(allocation.lines, ["nvidia.com/gpu: 3 given", "Each pod (the template) holds 1 nvidia.com/gpu"])
        XCTAssertEqual(KubeGPUAllocation.of(.workload("Deployment"), object: deployment, nodePods: nil), allocation)
        XCTAssertNil(KubeGPUAllocation.of(.namespace, object: deployment, nodePods: nil))
    }

    // MARK: The probe

    func testTheProbeReadsDCGMsLabelsExportedFirst() {
        XCTAssertTrue(KubePromProfile.names.contains(KubePromProfile.dcgmMemoryUsed), "query 1 asks after it")
        XCTAssertEqual(
            KubePromProfile.dcgmQuery,
            #"label_replace(count(DCGM_FI_DEV_FB_USED{exported_pod!=""}),"overterm_s","exported_pod","","")"#
                + #" or label_replace(count(DCGM_FI_DEV_FB_USED{pod!=""}),"overterm_s","pod","","")"#
                + #" or label_replace(count(DCGM_FI_DEV_FB_USED{pod=~".*dcgm-exporter.*"} or DCGM_FI_DEV_FB_USED{container=~"(nvidia-)?dcgm-exporter"}),"overterm_s","exporter","","")"#
                + #" or label_replace(count(DCGM_FI_DEV_FB_USED{pod!="",pod!~".*dcgm-exporter.*",container!~"(nvidia-)?dcgm-exporter"}),"overterm_s","pod_other","","")"#
                + #" or label_replace(count(DCGM_FI_DEV_FB_USED{Hostname!=""}),"overterm_s","Hostname","","")"#
                + #" or label_replace(count(DCGM_FI_DEV_FB_USED{node!=""}),"overterm_s","node","","")"#
                + #" or label_replace(count(DCGM_FI_DEV_FB_USED{GPU_I_PROFILE!=""}),"overterm_s","mig","","")"#)
        func answer(_ tags: [String]) -> [KubeSeries] { tags.map { KubeSeries(labels: ["overterm_s": $0], points: [KubeSeriesPoint(time: now, value: 4)]) } }
        // honor_labels off: `pod` is the exporter's own, `exported_pod` the GPU's.
        XCTAssertEqual(
            KubePromProfile.dcgm(answer(["exported_pod", "pod", "exporter", "Hostname"])),
            KubePromProfile.DCGM(podPrefix: "exported_", namesPods: true, nodeLabel: "Hostname", mig: false))
        // honor_labels on: `pod` names the GPU's pod, not the exporter.
        XCTAssertEqual(KubePromProfile.dcgm(answer(["pod", "pod_other", "node", "mig"])), KubePromProfile.DCGM(podPrefix: "", namesPods: true, nodeLabel: "node", mig: true))
        // honor_labels off and no GPU allocated when probed (or the mapping
        // off): every `pod` is the exporter's own — never a holder; the
        // exported labels are read, which a pod taking a GPU sets.
        XCTAssertEqual(
            KubePromProfile.dcgm(answer(["pod", "exporter", "Hostname"])), KubePromProfile.DCGM(podPrefix: "exported_", namesPods: true, nodeLabel: "Hostname", mig: false))
        // Some series the exporter's, some a pod's (honor_labels on, idle GPUs unmapped): `pod`.
        XCTAssertEqual(KubePromProfile.dcgm(answer(["pod", "exporter", "pod_other", "Hostname"])).podPrefix, "")
        XCTAssertTrue(KubePromProfile.DCGM.isExporter(pod: "nvidia-dcgm-exporter-x7k2p", container: nil))
        XCTAssertTrue(KubePromProfile.DCGM.isExporter(pod: "gpu-metrics-abcde", container: "dcgm-exporter"))
        XCTAssertFalse(KubePromProfile.DCGM.isExporter(pod: "train-0", container: "trainer"))
        XCTAssertEqual(KubePromProfile.dcgm(answer([])), KubePromProfile.DCGM(podPrefix: "", namesPods: false, nodeLabel: nil, mig: false))
        let labels = KubePromProfile.DCGM(podPrefix: "exported_", namesPods: true, nodeLabel: "Hostname", mig: false)
        XCTAssertEqual([labels.pod, labels.namespace, labels.container], ["exported_pod", "exported_namespace", "exported_container"])
    }

    // MARK: The queries

    func testEachSubjectsGPUQueryAsAGoldenString() {
        let pod = KubeTabSubject.pod(namespace: "ml", name: "train-0", cpuLimited: true, hostNetwork: false)
        let identity = "gpu,GPU_I_PROFILE,GPU_I_ID,modelName"
        func arms(_ scope: String, by: String) -> String {
            let group = "\(identity),\(by)"
            return #"label_replace(max by (\#(group))(DCGM_FI_DEV_GPU_UTIL{\#(scope)}) / 100,"overterm_s","util","","")"#
                + #" or label_replace(max by (\#(group))(DCGM_FI_DEV_FB_USED{\#(scope)}) * 1048576,"overterm_s","used","","")"#
                + #" or label_replace(max by (\#(group))(DCGM_FI_DEV_FB_USED{\#(scope)} + DCGM_FI_DEV_FB_FREE{\#(scope)}) * 1048576,"overterm_s","total","","")"#
                + #" or label_replace(max by (\#(group))(DCGM_FI_DEV_POWER_USAGE{\#(scope)}),"overterm_s","power","","")"#
                + #" or label_replace(max by (\#(group))(DCGM_FI_DEV_GPU_TEMP{\#(scope)}),"overterm_s","temp","","")"#
        }
        XCTAssertEqual(
            KubeTabTesting.query("gpu", .hour, profile: operatorProfile, subject: pod),
            arms(#"exported_namespace="ml",exported_pod="train-0""#, by: "exported_container"), "a container's, by the exported labels")
        XCTAssertEqual(
            KubeTabTesting.query("gpu", .hour, profile: operatorProfile, subject: .node("gpu-1")), arms(#"Hostname="gpu-1""#, by: "exported_namespace,exported_pod"),
            "a node's, its holders kept")
        XCTAssertEqual(
            KubeTabTesting.query("gpu", .hour, profile: operatorProfile, subject: .workload(namespace: "ml", kind: "StatefulSet", name: "train", hpa: nil)),
            arms(#"exported_namespace="ml",exported_pod=~"train-[0-9]+""#, by: "exported_pod"), "a workload's pods by their names")
        // Gauges keep their peaks past 5-minute steps; the total doesn't —
        // used and free at one sample, or a peaked used overstates it.
        let day = KubeTabTesting.query("gpu", .day, profile: operatorProfile, subject: pod) ?? ""
        XCTAssertTrue(day.contains("max_over_time(DCGM_FI_DEV_GPU_UTIL{"), day)
        XCTAssertTrue(day.contains("max_over_time(DCGM_FI_DEV_FB_USED{"), day)
        XCTAssertTrue(
            day.contains(
                #"(DCGM_FI_DEV_FB_USED{exported_namespace="ml",exported_pod="train-0"} + DCGM_FI_DEV_FB_FREE{exported_namespace="ml",exported_pod="train-0"}) * 1048576,"overterm_s","total""#),
            day)
        XCTAssertFalse(day.contains("max_over_time(DCGM_FI_DEV_FB_FREE"), day)
        // Profiling metrics on: the engine's activity too; the plain `pod` labels where honor_labels is on.
        var profiled = operatorProfile
        profiled.metrics?[KubePromProfile.dcgmEngineActive] = 8
        profiled.dcgm = KubePromProfile.DCGM(podPrefix: "", namesPods: true, nodeLabel: "node", mig: true)
        let both = KubeTabTesting.query("gpu", .hour, profile: profiled, subject: pod) ?? ""
        XCTAssertTrue(both.contains(#"DCGM_FI_PROF_GR_ENGINE_ACTIVE{namespace="ml",pod="train-0"}),"overterm_s","engine""#), both)
        XCTAssertTrue(KubeTabTesting.query("gpu", .hour, profile: profiled, subject: .node("gpu-1"))?.contains(#"{node="gpu-1"}"#) == true)
        // Escaped as every literal is.
        let odd = KubeTabTesting.query("gpu", .hour, profile: operatorProfile, subject: .node(#"a"b"#)) ?? ""
        XCTAssertTrue(odd.contains(#"Hostname="a\"b""#), odd)
        XCTAssertTrue(KubeTabFamily.prometheusOnly.contains(.gpu), "no sampled form: Prometheus' in Live too")
        XCTAssertEqual(KubePromTabCharts.families(.pod, source: .mixed).contains(.gpu), true)
        XCTAssertEqual(KubePromTabCharts.families(.namespace, source: .prometheus).contains(.gpu), false)
    }

    func testNotAskedAndSaidWhereDCGMIsntThere() {
        let pod = KubeTabSubject.pod(namespace: "ml", name: "train-0", cpuLimited: true, hostNetwork: false)
        // Nothing known yet: nothing asked, nothing said.
        let unknown = KubeTabTesting.plan(.hour, profile: .unknown, families: [.gpu], subject: pod)
        XCTAssertTrue(unknown.queries.isEmpty)
        XCTAssertNil(unknown.refused[.gpu])
        // No DCGM exporter.
        var stack = operatorProfile
        stack.metrics = FakePromProfile.kubePrometheusStack.metrics
        stack.dcgm = nil
        let none = KubeTabTesting.plan(.hour, profile: stack, families: [.gpu], subject: pod)
        XCTAssertTrue(none.queries.isEmpty)
        XCTAssertEqual(none.refused[.gpu], KubeChartEmpty.noDCGM.sentence)
        // Its labels unread.
        var unread = operatorProfile
        unread.dcgm = nil
        XCTAssertEqual(KubeTabTesting.plan(.hour, profile: unread, families: [.gpu], subject: pod).refused[.gpu], KubeChartEmpty.dcgmUnread.sentence)
        // No pods named: a pod's refused, a node's still asked; no node named: a node's refused.
        var podless = operatorProfile
        podless.dcgm = KubePromProfile.DCGM(podPrefix: "", namesPods: false, nodeLabel: nil, mig: false)
        XCTAssertEqual(KubeTabTesting.plan(.hour, profile: podless, families: [.gpu], subject: pod).refused[.gpu], KubeChartEmpty.dcgmNoPods.sentence)
        XCTAssertEqual(KubeTabTesting.plan(.hour, profile: podless, families: [.gpu], subject: .node("gpu-1")).refused[.gpu], KubeChartEmpty.dcgmNoNode.sentence)
        var nodeOnly = podless
        nodeOnly.dcgm?.nodeLabel = "Hostname"
        XCTAssertEqual(KubeTabTesting.plan(.hour, profile: nodeOnly, families: [.gpu], subject: .node("gpu-1")).queries.map(\.id), ["gpu"])
        // Only the one Service's query_range: no other path, nothing written.
        XCTAssertFalse(KubeTabTesting.query("gpu", .hour, profile: operatorProfile, subject: pod)?.contains("nodes/proxy") ?? true)
    }

    // MARK: The charts

    private func reading(_ subject: KubeTabSubject, _ series: [KubeSeries], profile: KubePromProfile? = nil) -> KubeTabReading {
        var reading = KubeTabReading(request: KubeTabTesting.request(.hour, families: [.gpu], subject: subject))
        reading.span = KubeMetricsSpan.of(.hour, scrape: 30, now: now)
        reading.read = now
        reading.profile = profile ?? operatorProfile
        reading.results["gpu"] = series
        return reading
    }

    private func gpu(_ tag: String, _ index: String, _ values: [Double], _ extra: [String: String] = [:]) -> KubeSeries {
        KubeSeries(labels: ["overterm_s": tag, "gpu": index, "modelName": "NVIDIA A100-SXM4-40GB"].merging(extra) { $1 }, points: points(values))
    }

    func testANodesGPUsEachTheirOwnLineTheIdleHeldOneSaid() throws {
        let held = ["exported_namespace": "ml", "exported_pod": "train-0"]
        let busy = ["exported_namespace": "ml", "exported_pod": "train-1"]
        let series = [
            gpu("util", "0", [0.01, 0.02, 0.0], held), gpu("util", "1", [0.6, 0.9, 0.8], busy), gpu("util", "2", [0, 0, 0]),
            gpu("used", "0", [3 * gib, 3 * gib, 3 * gib], held), gpu("total", "0", [40 * gib, 40 * gib, 40 * gib], held),
            gpu("used", "1", [30 * gib, 31 * gib, 32 * gib], busy), gpu("total", "1", [40 * gib, 40 * gib, 40 * gib], busy),
            gpu("power", "0", [60, 61, 62], held), gpu("power", "1", [300, 310, 320], busy), gpu("temp", "0", [40, 41, 42], held),
            gpu("temp", "1", [70, 72, 74], busy),
        ]
        let read = reading(.node("gpu-1"), series)
        let charts = KubePromTabCharts.node(node: "gpu-1", facts: KubeNodeFacts.of([:]), reading: read, changes: KubeChartChanges(), window: nil)
        let group = try XCTUnwrap(charts.groups.first { $0.title == KubeGPUCharts.groupTitle })
        XCTAssertEqual(charts.groups.firstIndex { $0.title == KubeGPUCharts.groupTitle }, 1, "after the node's own charts")
        XCTAssertEqual(group.charts.map(\.data.id), ["node.gpu-1.gpu.utilisation", "node.gpu-1.gpu.memory", "node.gpu-1.gpu.power", "node.gpu-1.gpu.temperature"])
        let utilisation = group.charts[0]
        XCTAssertEqual(utilisation.data.usage.map(\.name), ["GPU 0", "GPU 1", "GPU 2"], "a line a GPU")
        XCTAssertEqual(utilisation.data.unit, .ratio)
        XCTAssertEqual(utilisation.chips, [KubeChartChip(text: "1 allocated GPU idle", alert: true)], "GPU 2 is idle but nobody's: no cost")
        XCTAssertEqual(utilisation.headline, "27% now · NVIDIA A100-SXM4-40GB")
        let idle = charts.notes.filter { $0.contains("idle") }
        XCTAssertEqual(idle, ["GPU 0, held by ml/train-0, was idle over the last 1h (never above 2%): allocated, and paid for, but unused."])
        let memory = group.charts[1]
        XCTAssertEqual(memory.data.references.map(\.name), ["total a GPU"], "every GPU the same 40 GiB")
        XCTAssertEqual(memory.data.references.first?.points.last?.value, 40 * gib)
        XCTAssertEqual(memory.chips, [KubeChartChip(text: "44% of total", alert: false)])
        XCTAssertEqual(group.charts[2].data.unit, .watts)
        XCTAssertEqual(group.charts[2].headline, "382 W now")
        XCTAssertEqual(group.charts[3].headline, "hottest 74 °C")
        XCTAssertEqual(KubeChartUnit.celsius.format(66.6), "67 °C")
        XCTAssertEqual(KubeChartUnit.watts.format(61.24), "61.2 W")
    }

    func testMIGInstancesByProfileAndTheirUtilisationsSentence() throws {
        var profile = operatorProfile
        profile.dcgm?.mig = true
        let mig = ["GPU_I_PROFILE": "1g.5gb", "GPU_I_ID": "3", "exported_namespace": "ml", "exported_pod": "infer-0"]
        let read = reading(.node("gpu-1"), [gpu("used", "0", [gib, gib], mig), gpu("total", "0", [5 * gib, 5 * gib], mig)], profile: profile)
        let built = KubeGPUCharts.group(subject: "node.gpu-1", reading: read, whose: .node, window: nil)
        XCTAssertEqual(built.group?.charts.map(\.data.title), ["GPU memory"], "no GPU_UTIL from a MIG instance: no utilisation chart")
        XCTAssertEqual(built.group?.charts.first?.data.usage.map(\.name), ["GPU 0 · MIG 1g.5gb #3"])
        XCTAssertEqual(built.notes, [KubeChartEmpty.migNeedsProfiling.sentence])
        XCTAssertTrue(KubeChartEmpty.migNeedsProfiling.isFootnote)
        // With profiling metrics: the engine's activity, no sentence.
        profile.metrics?[KubePromProfile.dcgmEngineActive] = 8
        let engine = reading(.node("gpu-1"), [gpu("engine", "0", [0.4, 0.5], mig), gpu("used", "0", [gib, gib], mig)], profile: profile)
        let profiled = KubeGPUCharts.group(subject: "node.gpu-1", reading: engine, whose: .node, window: nil)
        XCTAssertEqual(profiled.group?.charts.first?.data.title, "GPU utilisation")
        XCTAssertEqual(profiled.group?.charts.first?.data.tier, "DCGM exporter · engine activity (profiling)")
        XCTAssertEqual(profiled.notes, [])
    }

    func testAPodsGPUsByContainerAWorkloadsByPod() throws {
        let pod = KubeTabSubject.pod(namespace: "ml", name: "train-0", cpuLimited: true, hostNetwork: false)
        let trainer = ["exported_container": "trainer"]
        let read = reading(pod, [gpu("util", "0", [0, 0, 0.01], trainer), gpu("used", "0", [gib, gib, gib], trainer), gpu("total", "0", [2 * gib, 2 * gib, 2 * gib], trainer)])
        let charts = KubePromTabCharts.pod(namespace: "ml", pod: "train-0", object: gpuPod("train-0", gpus: 1), reading: read, changes: KubeChartChanges(), window: nil)
        let utilisation = try XCTUnwrap(charts.pod.first { $0.data.id == "pod.ml.train-0.gpu.utilisation" })
        XCTAssertEqual(utilisation.data.usage.map(\.name), ["trainer · GPU 0"], "a container's GPU")
        XCTAssertEqual(utilisation.chips, [KubeChartChip(text: "1 allocated GPU idle", alert: true)], "a pod's GPU is always held")
        XCTAssertTrue(charts.notes.contains { $0.hasPrefix("trainer · GPU 0 was idle over the last 1h (never above 1%)") }, "\(charts.notes)")
        XCTAssertEqual(charts.pod.first { $0.data.id == "pod.ml.train-0.gpu.memory" }?.data.references.map(\.name), ["total"])
        // Live with metrics-server: the same, added to the sampled charts.
        let sampled = KubePodCharts(range: .live, pod: [], sections: [], caption: "", span: "last 15 min", hasSamples: true)
        let mixed = KubePromTabCharts.addOnly(sampled, namespace: "ml", pod: "train-0", object: gpuPod("train-0", gpus: 1), reading: read, changes: KubeChartChanges())
        XCTAssertTrue(mixed.pod.contains { $0.data.id == "pod.ml.train-0.gpu.utilisation" })
        // A workload's by pod.
        let workload = KubeTabSubject.workload(namespace: "ml", kind: "StatefulSet", name: "train", hpa: nil)
        let pods = reading(
            workload, [gpu("util", "0", [0.5, 0.5], ["exported_pod": "train-0"]), gpu("util", "0", [0.7, 0.8], ["exported_pod": "train-1"])])
        let built = KubeGPUCharts.group(subject: "workload.ml.statefulset.train", reading: pods, whose: .workload, window: nil)
        XCTAssertEqual(built.group?.charts.first?.data.usage.map(\.name), ["train-0 · GPU 0", "train-1 · GPU 0"])
        XCTAssertEqual(built.notes, [])
        // Mixed: the group after the workload's own.
        let object = KubeObjectCharts(range: .live, groups: [KubeObjectCharts.Group(title: "StatefulSet", charts: [])], caption: "", span: "", hasSamples: true)
        XCTAssertEqual(KubeGPUCharts.add(object, subject: "workload.ml.statefulset.train", reading: pods, whose: .workload).groups.map(\.title), ["StatefulSet", KubeGPUCharts.groupTitle])
        // Asked and nothing answered: said.
        XCTAssertEqual(KubeGPUCharts.group(subject: "x", reading: reading(pod, []), whose: .pod, window: nil).notes, [KubeChartEmpty.gpuNone.sentence])
        // Not asked: nothing at all.
        var unasked = reading(pod, [])
        unasked.results = [:]
        XCTAssertNil(KubeGPUCharts.group(subject: "x", reading: unasked, whose: .pod, window: nil).group)
        XCTAssertEqual(KubeGPUCharts.group(subject: "x", reading: unasked, whose: .pod, window: nil).notes, [])
    }

    func testTwelveGPUsAtMostTheBusiest() {
        let many = (0..<14).map { gpu("util", String($0), [Double($0) / 20, Double($0) / 20]) }
        let read = reading(.node("gpu-1"), many)
        let charts = KubeGPUCharts.charts(subject: "node.gpu-1", reading: read, span: read.span!, whose: .node)
        XCTAssertEqual(charts.first?.data.usage.count, 12)
        XCTAssertFalse(charts.first?.data.usage.contains { $0.name == "GPU 0" } ?? true, "the idlest left out")
        XCTAssertEqual(KubeGPUCharts.notes(read, span: read.span!, whose: .node, window: nil), ["2 GPUs more aren't drawn: the 12 busiest are."])
    }

    /// honor_labels on, DCGM's mapping off for idle GPUs: their series' `pod`
    /// is the exporter's own target label — never a holder, so never the
    /// costly "allocated but idle".
    func testTheExportersOwnPodIsNeverAGPUsHolder() throws {
        var profile = operatorProfile
        profile.dcgm = KubePromProfile.DCGM(podPrefix: "", namesPods: true, nodeLabel: "Hostname", mig: false)
        let exporter = ["namespace": "gpu-operator", "pod": "nvidia-dcgm-exporter-x7k2p", "container": "nvidia-dcgm-exporter"]
        let held = ["namespace": "ml", "pod": "train-0", "container": "trainer"]
        let read = reading(
            .node("gpu-1"), [gpu("util", "0", [0, 0, 0], exporter), gpu("util", "1", [0.01, 0, 0], held), gpu("util", "2", [0, 0, 0], ["pod": "dcgm-exporter-abcde"])],
            profile: profile)
        let gpus = KubeGPUCharts.gpus(read, whose: .node)
        XCTAssertEqual(gpus.map(\.holders), [[], ["ml/train-0"], []])
        let built = KubeGPUCharts.group(subject: "node.gpu-1", reading: read, whose: .node, window: nil)
        XCTAssertEqual(built.group?.charts.first?.chips, [KubeChartChip(text: "1 allocated GPU idle", alert: true)], "only the one a pod holds")
        XCTAssertEqual(built.notes.filter { $0.contains("idle") }.count, 1)
        XCTAssertTrue(built.notes.allSatisfy { !$0.contains("dcgm-exporter") }, "\(built.notes)")
    }

    /// G2's total is used + free at one sample, never a peaked used beside a plain free.
    func testTheMemoryTotalIsItsOwnSeries() throws {
        let read = reading(.node("gpu-1"), [gpu("used", "0", [10 * gib, 39 * gib, 12 * gib]), gpu("total", "0", [40 * gib, 40 * gib, 40 * gib])])
        let first = try XCTUnwrap(KubeGPUCharts.gpus(read, whose: .node).first)
        XCTAssertEqual(first.total, 40 * gib)
        let memory = try XCTUnwrap(KubeGPUCharts.charts(subject: "node.gpu-1", reading: read, span: read.span!, whose: .node).first { $0.data.title == "GPU memory" })
        XCTAssertEqual(memory.data.references.first?.points.last?.value, 40 * gib)
        XCTAssertEqual(memory.chips, [KubeChartChip(text: "30% of total", alert: false)])
        // No total answered (no FB_FREE): no reference, no percentage.
        let bare = reading(.node("gpu-1"), [gpu("used", "0", [10 * gib, 12 * gib])])
        let alone = KubeGPUCharts.charts(subject: "node.gpu-1", reading: bare, span: bare.span!, whose: .node).first
        XCTAssertEqual(alone?.data.references.count, 0)
        XCTAssertEqual(alone?.chips, [])
    }

    /// What a pod is given, said per resource: a whole device, a shared time slice, a MIG instance.
    func testAPodsNoteSaysHowEachResourceIsGiven() throws {
        func pod(_ resource: String) -> [String: Any] {
            ["metadata": ["name": "p", "namespace": "ml"], "spec": ["containers": [["name": "c", "resources": ["limits": [resource: "1"]]]]]]
        }
        let whole = try XCTUnwrap(KubeGPUAllocation.pod(pod("nvidia.com/gpu")))
        XCTAssertEqual(whole.notes, ["nvidia.com/gpu: given by the scheduler as whole devices: a pod's GPUs are its own while it runs, busy or not."])
        XCTAssertTrue(try XCTUnwrap(KubeGPUAllocation.pod(pod("amd.com/gpu"))).notes[0].contains("whole devices"))
        let shared = try XCTUnwrap(KubeGPUAllocation.pod(pod("nvidia.com/gpu.shared")))
        XCTAssertEqual(shared.notes.count, 1)
        XCTAssertTrue(shared.notes[0].contains("time slice") && !shared.notes[0].contains("whole devices"), shared.notes[0])
        let mig = try XCTUnwrap(KubeGPUAllocation.pod(pod("nvidia.com/mig-1g.5gb")))
        XCTAssertTrue(mig.notes[0].hasPrefix("MIG 1g.5gb: a MIG instance"), mig.notes[0])
    }
}
