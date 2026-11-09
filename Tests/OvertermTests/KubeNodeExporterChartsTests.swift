import Foundation
import XCTest

@testable import Overterm

/// A node's disks and network from node-exporter (docs/design/kubernetes/
/// metrics.md 2.8's K6 and K7, 4.6, decision 6; stage M8b): their queries
/// as golden strings — mapped to the node by `node_uname_info`, every
/// series taken once an instance first, the mounts and interfaces the
/// design names —; left out with the sentence where node-exporter doesn't
/// map to nodes or lacks a collector; the charts a mount and the network,
/// their own group read only while shown, in Live too. Pure.
final class KubeNodeExporterChartsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let gib = 1_073_741_824.0
    private let node = KubeTabSubject.node("ip-10-0-0-1")

    private var stack: KubePromProfile {
        var profile = KubePromProfile(probed: now)
        profile.metrics = FakePromProfile.kubePrometheusStack.metrics
        profile.cadvisorPath = "/metrics/cadvisor"
        profile.cadvisorJob = "kubelet"
        profile.ksmJob = "kube-state-metrics"
        profile.nodeLabel = .node
        profile.scrape = 30
        return profile
    }

    private var unmapped: KubePromProfile {
        var profile = stack
        profile.metrics = FakePromProfile.noNodeExporter.metrics
        profile.nodeLabel = .instance
        return profile
    }

    private func points(_ values: [Double], from start: Date, step: TimeInterval) -> [KubeSeriesPoint] {
        values.enumerated().map { KubeSeriesPoint(time: start.addingTimeInterval(Double($0.offset) * step), value: $0.element) }
    }

    private static let mapped = #"on(instance) group_left(nodename) max by (instance,nodename)(node_uname_info{nodename="ip-10-0-0-1"})"#

    func testTheDisksAndNetworkAreNodeExportersMappedByUname() throws {
        let plan = KubeTabTesting.plan(.hour, profile: stack, subject: node)
        let by = Dictionary(uniqueKeysWithValues: plan.queries.map { ($0.id, $0) })
        let filesystems = #"fstype!~"tmpfs|overlay|squashfs",mountpoint=~"/|/local""#
        XCTAssertEqual(
            by["disks"]?.promql,
            #"label_replace(max by (mountpoint)((max by (instance,mountpoint)(node_filesystem_size_bytes{"# + filesystems
                + #"}) - max by (instance,mountpoint)(node_filesystem_avail_bytes{"# + filesystems + #"})) * "# + Self.mapped + #"),"overterm_s","used","","")"#
                + #" or label_replace(max by (mountpoint)(max by (instance,mountpoint)(node_filesystem_size_bytes{"# + filesystems + #"}) * "# + Self.mapped
                + #"),"overterm_s","size","","")"#)
        let devices = #"device!~"lo|veth.*|eni.*|cali.*|docker.*|cni.*""#
        XCTAssertEqual(
            by["nodeNetwork"]?.promql,
            #"label_replace(sum(max by (instance,device)(rate(node_network_receive_bytes_total{"# + devices + #"}[2m])) * "# + Self.mapped
                + #"),"overterm_s","rx","","")"#
                + #" or label_replace(sum(max by (instance,device)(rate(node_network_transmit_bytes_total{"# + devices + #"}[2m])) * "# + Self.mapped
                + #"),"overterm_s","tx","","")"#,
            "a rate's window four scrapes at least")
        XCTAssertEqual(by["disks"]?.instant, false, "over the range")
        XCTAssertNil(plan.refused[.disks])
        XCTAssertNil(plan.refused[.nodeNetwork])
        // K2's total shares the mapping.
        XCTAssertTrue(by["memory"]?.promql.contains(Self.mapped) == true)
        // On a minute's scrape the window is four minutes.
        var chart = stack
        chart.scrape = 60
        XCTAssertTrue(KubeTabTesting.query("nodeNetwork", .hour, profile: chart, subject: node)?.contains("[4m]") == true)
        // Escaped as every literal is.
        let odd = KubeTabTesting.query("disks", .hour, profile: stack, subject: .node(#"a"b\c"#))
        XCTAssertTrue(odd?.contains(#"nodename="a\"b\\c""#) == true, odd ?? "")
    }

    func testLeftOutWithTheSentenceWhereNodeExporterDoesntMapToNodes() {
        let plan = KubeTabTesting.plan(.hour, profile: unmapped, subject: node)
        XCTAssertNil(plan.queries.first { $0.family == .disks || $0.family == .nodeNetwork }, "never joined by host IP instead")
        XCTAssertEqual(plan.refused[.disks], KubeChartEmpty.nodeExporterUnmapped.sentence)
        XCTAssertEqual(plan.refused[.nodeNetwork], KubeChartEmpty.nodeExporterUnmapped.sentence)
        XCTAssertTrue(KubeChartEmpty.nodeExporterUnmapped.sentence.contains("disks"))
        // Said once, however many charts it leaves out.
        var reading = KubeTabReading(request: KubeTabTesting.request(.hour, subject: node))
        reading.span = KubeMetricsSpan.of(.hour, scrape: 30, now: now)
        reading.read = now
        reading.refused = plan.refused
        reading.notes = plan.notes
        reading.profile = unmapped
        reading.results["cpu"] = [KubeSeries(labels: [:], points: points([1], from: now, step: 30))]
        let charts = KubePromTabCharts.node(node: "ip-10-0-0-1", facts: KubeNodeFacts.of([:]), reading: reading, changes: KubeChartChanges(), window: nil)
        XCTAssertNil(charts.groups.first { $0.title == KubePromTabCharts.nodeExporterTitle }, "no group to scroll to")
        XCTAssertEqual(charts.notes.filter { $0 == KubeChartEmpty.nodeExporterUnmapped.sentence }.count, 1, "\(charts.notes)")

        // Mapped, but a collector off: that chart alone, said.
        var noFS = stack
        noFS.metrics?[KubePromQL.nodeFilesystemMetric] = nil
        let partial = KubeTabTesting.plan(.hour, profile: noFS, subject: node)
        XCTAssertEqual(partial.refused[.disks], KubeChartEmpty.nodeExporterNoFilesystems.sentence)
        XCTAssertNotNil(partial.queries.first { $0.id == "nodeNetwork" })
        var noNet = stack
        noNet.metrics?[KubePromQL.nodeNetworkMetric] = nil
        XCTAssertEqual(KubeTabTesting.plan(.hour, profile: noNet, subject: node).refused[.nodeNetwork], KubeChartEmpty.nodeExporterNoNetwork.sentence)
        // Not probed yet: assumed, as every raw metric is.
        XCTAssertNotNil(KubeTabTesting.query("disks", .hour, subject: node))
    }

    func testAChartAMountAndTheNetworkInAGroupOfTheirOwn() throws {
        let span = KubeMetricsSpan.of(.hour, scrape: 30, now: now)
        var reading = KubeTabReading(request: KubeTabTesting.request(.hour, subject: node))
        reading.span = span
        reading.read = span.end
        reading.profile = stack
        let start = span.end.addingTimeInterval(-30)
        reading.results["disks"] = [
            KubeSeries(labels: ["overterm_s": "used", "mountpoint": "/local"], points: points([18 * gib, 19 * gib], from: start, step: 30)),
            KubeSeries(labels: ["overterm_s": "size", "mountpoint": "/local"], points: points([20 * gib, 20 * gib], from: start, step: 30)),
            KubeSeries(labels: ["overterm_s": "used", "mountpoint": "/"], points: points([gib, gib], from: start, step: 30)),
            KubeSeries(labels: ["overterm_s": "size", "mountpoint": "/"], points: points([4 * gib, 4 * gib], from: start, step: 30)),
        ]
        reading.results["nodeNetwork"] = [
            KubeSeries(labels: ["overterm_s": "rx"], points: points([2_000_000, 1_200_000], from: start, step: 30)),
            KubeSeries(labels: ["overterm_s": "tx"], points: points([300_000, 340_000], from: start, step: 30)),
        ]
        let charts = KubePromTabCharts.node(node: "ip-10-0-0-1", facts: KubeNodeFacts.of([:]), reading: reading, changes: KubeChartChanges(), window: nil)
        XCTAssertEqual(charts.groups.map(\.title), ["Node", KubePromTabCharts.topPodsTitle, KubePromTabCharts.nodeExporterTitle], "the lowest, last")
        let group = try XCTUnwrap(charts.groups.last)
        XCTAssertTrue(group.readsWhenShown)
        XCTAssertFalse(group.pending)
        XCTAssertEqual(group.charts.map(\.data.id), ["node.ip-10-0-0-1.disk.root", "node.ip-10-0-0-1.disk.local", "node.ip-10-0-0-1.network"])
        let root = group.charts[0]
        XCTAssertEqual(root.data.title, "Disk /")
        XCTAssertEqual(root.data.usage.map(\.name), ["used"])
        XCTAssertEqual(root.data.references.map(\.role), [.capacity], "used against size")
        XCTAssertEqual(root.chips, [KubeChartChip(text: "25% used", alert: false)])
        XCTAssertEqual(group.charts[1].chips, [KubeChartChip(text: "95% used", alert: true)], "red from 90%")
        XCTAssertEqual(group.charts[1].headline, "19Gi of 20Gi")
        let network = group.charts[2]
        XCTAssertEqual(network.data.usage.map(\.name), ["received", "sent"])
        XCTAssertEqual(network.data.unit, .bytesPerSecond)
        XCTAssertEqual(network.headline, "rx \(KubeChartUnit.bytesPerSecond.format(1_200_000)) · tx \(KubeChartUnit.bytesPerSecond.format(340_000))")
        XCTAssertEqual(network.data.tier, "node-exporter, the node's own interfaces")

        // Asked, but neither mount on this node: said, the network still drawn.
        reading.results["disks"] = []
        let none = KubePromTabCharts.node(node: "ip-10-0-0-1", facts: KubeNodeFacts.of([:]), reading: reading, changes: KubeChartChanges(), window: nil)
        XCTAssertEqual(none.groups.last?.charts.map(\.data.id), ["node.ip-10-0-0-1.network"])
        XCTAssertTrue(none.notes.contains(KubeChartEmpty.nodeDisksNone.sentence))

        // Asked, but no interface left on this node: said too, not dropped silently.
        reading.results["nodeNetwork"] = []
        let quiet = KubePromTabCharts.node(node: "ip-10-0-0-1", facts: KubeNodeFacts.of([:]), reading: reading, changes: KubeChartChanges(), window: nil)
        XCTAssertEqual(quiet.groups.last?.title, KubePromTabCharts.nodeExporterTitle)
        XCTAssertEqual(quiet.groups.last?.charts.map(\.data.id), [])
        XCTAssertTrue(quiet.notes.contains(KubeChartEmpty.nodeNetworkNone.sentence), "\(quiet.notes)")
        XCTAssertFalse(none.notes.contains(KubeChartEmpty.nodeNetworkNone.sentence), "only when the network is the one empty")

        // Not read yet: the group waits to be scrolled to.
        reading.results = [:]
        let waiting = KubePromTabCharts.node(node: "ip-10-0-0-1", facts: KubeNodeFacts.of([:]), reading: reading, changes: KubeChartChanges(), window: nil)
        XCTAssertEqual(waiting.groups.last.map { [$0.title] }, [KubePromTabCharts.nodeExporterTitle])
        XCTAssertEqual(waiting.groups.last?.pending, true)
    }

    func testBothCollectorsOffLeavesNoGroupEvenBeforeItIsShown() {
        // The probe found neither collector: no group from the start, shown
        // or not — never one shown, then dropped on its refusals, then back.
        var neither = stack
        neither.metrics?[KubePromQL.nodeFilesystemMetric] = nil
        neither.metrics?[KubePromQL.nodeNetworkMetric] = nil
        let both = [KubeChartEmpty.nodeExporterNoFilesystems.sentence, KubeChartEmpty.nodeExporterNoNetwork.sentence]
        // Off screen: nothing of node-exporter's asked, nothing refused.
        var reading = KubeTabReading(request: KubeTabTesting.request(.hour, subject: node))
        reading.span = KubeMetricsSpan.of(.hour, scrape: 30, now: now)
        reading.read = now
        reading.profile = neither
        reading.results["cpu"] = [KubeSeries(labels: [:], points: points([1], from: now, step: 30))]
        XCTAssertTrue(reading.refused.isEmpty)
        let hidden = KubePromTabCharts.node(node: "ip-10-0-0-1", facts: KubeNodeFacts.of([:]), reading: reading, changes: KubeChartChanges(), window: nil)
        XCTAssertNil(hidden.groups.first { $0.title == KubePromTabCharts.nodeExporterTitle }, "\(hidden.groups.map(\.title))")
        for sentence in both { XCTAssertTrue(hidden.notes.contains(sentence), "\(hidden.notes)") }
        // Asked anyway (shown): the same, said once each.
        reading.refused = [.disks: both[0], .nodeNetwork: both[1]]
        let shown = KubePromTabCharts.node(node: "ip-10-0-0-1", facts: KubeNodeFacts.of([:]), reading: reading, changes: KubeChartChanges(), window: nil)
        XCTAssertEqual(shown.groups.map(\.title), hidden.groups.map(\.title))
        for sentence in both { XCTAssertEqual(shown.notes.filter { $0 == sentence }.count, 1, "\(shown.notes)") }
        // Live, nothing read yet: absent too.
        let sampled = KubeObjectCharts(range: .live, groups: [KubeObjectCharts.Group(title: "Node", charts: [])], caption: "", span: "", hasSamples: true)
        let live = KubePromTabCharts.addNodeExporter(sampled, node: "ip-10-0-0-1", reading: nil, profile: neither)
        XCTAssertEqual(live.groups.map(\.title), ["Node"])
        XCTAssertEqual(live.notes, both)

        // The top pods' alike: cAdvisor naming no node leaves no group, shown or not.
        var nameless = stack
        nameless.nodeLabel = nil
        reading.profile = nameless
        reading.refused = [:]
        let tops = KubePromTabCharts.node(node: "ip-10-0-0-1", facts: KubeNodeFacts.of([:]), reading: reading, changes: KubeChartChanges(), window: nil)
        XCTAssertNil(tops.groups.first { $0.title == KubePromTabCharts.topPodsTitle })
        XCTAssertNotNil(KubeTabTesting.plan(.hour, profile: nameless, subject: node).refused[.cpu], "the plan says the same")
    }

    /// The view reports a group shown by its own title, and the page reads
    /// a family only for a title of `readWhenShown`: every group that reads
    /// when shown must carry one of them, or it is never read.
    func testEveryGroupReadWhenShownIsOneThePageKnows() {
        let span = KubeMetricsSpan.of(.hour, scrape: 30, now: now)
        var reading = KubeTabReading(request: KubeTabTesting.request(.hour, subject: node))
        reading.span = span
        reading.read = span.end
        reading.profile = stack
        var built = [KubePromTabCharts.node(node: "ip-10-0-0-1", facts: KubeNodeFacts.of([:]), reading: reading, changes: KubeChartChanges(), window: nil)]
        let sampled = KubeObjectCharts(range: .live, groups: [KubeObjectCharts.Group(title: "Node", charts: [])], caption: "", span: "", hasSamples: true)
        built.append(KubePromTabCharts.addNodeExporter(sampled, node: "ip-10-0-0-1", reading: nil, profile: .unknown))
        built.append(KubePromTabCharts.addNodeExporter(sampled, node: "ip-10-0-0-1", reading: reading, profile: stack))
        let readers = built.flatMap(\.groups).filter(\.readsWhenShown)
        XCTAssertEqual(Set(readers.map(\.title)), Set(KubePromTabCharts.readWhenShown.keys), "each title read, each one built")
        for group in readers { XCTAssertNotNil(KubePromTabCharts.readWhenShown[group.title], group.title) }
    }

    func testReadOnlyWhileShownAndInLiveToo() {
        XCTAssertEqual(KubePromTabCharts.readWhenShown[KubePromTabCharts.nodeExporterTitle], [.disks, .nodeNetwork])
        XCTAssertEqual(KubePromTabCharts.families(.node, source: .mixed), [.disks, .nodeNetwork, .gpu], "no sampled form: Prometheus' in Live")
        XCTAssertTrue(KubePromTabCharts.families(.node, source: .prometheus).isSuperset(of: [.disks, .nodeNetwork]))
        XCTAssertEqual(KubePromTabCharts.families(.node, source: .sampled), [])
        XCTAssertFalse(KubePromTabCharts.families(.pod, source: .prometheus).contains(.disks), "a node's alone")

        // Live: the sampled charts, the group added — pending until shown, absent where unmapped.
        let sampled = KubeObjectCharts(range: .live, groups: [KubeObjectCharts.Group(title: "Node", charts: [])], caption: "", span: "", hasSamples: true)
        let pending = KubePromTabCharts.addNodeExporter(sampled, node: "ip-10-0-0-1", reading: nil, profile: .unknown)
        XCTAssertEqual(pending.groups.map(\.title), ["Node", KubePromTabCharts.nodeExporterTitle])
        XCTAssertEqual(pending.groups.last?.pending, true)
        let plain = KubePromTabCharts.addNodeExporter(sampled, node: "ip-10-0-0-1", reading: nil, profile: unmapped)
        XCTAssertEqual(plain.groups.map(\.title), ["Node"])
        XCTAssertEqual(plain.notes, [KubeChartEmpty.nodeExporterUnmapped.sentence])
    }
}
