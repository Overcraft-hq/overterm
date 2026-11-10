import XCTest

@testable import Overterm

/// What the Overview's cards say (`KubeOverviewCards`): the header's
/// pills, a kind's line and bar, what needs attention worst first with
/// its reason pill, the usage's tone, how many cards across. Pure.
final class KubeOverviewCardsTests: XCTestCase {
    private func overview() -> KubeClusterOverview {
        var overview = KubeClusterOverview()
        overview.phases = ["Running": 9, "Pending": 2]
        overview.failingPending = 1
        overview.failingPods = [
            KubePodSummary(id: KubeRowID(namespace: "shop", name: "pull-1"), ready: 0, containers: 1, status: "ImagePullBackOff", restarts: 0),
            KubePodSummary(id: KubeRowID(namespace: "shop", name: "api-7f"), ready: 0, containers: 1, status: "OOMKilled", restarts: 3),
            KubePodSummary(id: KubeRowID(namespace: "shop", name: "worker-5c"), ready: 0, containers: 1, status: "CrashLoopBackOff", restarts: 14),
        ]
        let api = KubeRowID(namespace: "shop", name: "api")
        let agent = KubeRowID(namespace: "shop", name: "node-agent")
        overview.workloads = [
            .init(title: "Deployments", resource: "deployments.apps", total: 4, notReady: [api], said: [api: "2/3 ready"]),
            .init(title: "DaemonSets", resource: "daemonsets.apps", total: 1, notReady: [agent]),
            .init(title: "StatefulSets", resource: "statefulsets.apps", total: 1, notReady: []),
        ]
        overview.nodes = 3
        overview.notReadyNodes = ["fake-node-3"]
        return overview
    }

    func testAttentionIsWorstFirstWithItsReason() {
        let rows = KubeOverviewCards.attention(overview())
        XCTAssertEqual(
            rows.map(\.title),
            ["node/fake-node-3", "pod/worker-5c", "pod/api-7f", "pod/pull-1", "daemonset/node-agent", "deployment/api"])
        XCTAssertEqual(rows.map(\.pill), ["NotReady", "CrashLoopBackOff · 14×", "OOMKilled · 3×", "ImagePullBackOff", "not ready", "2/3 ready"])
        XCTAssertEqual(rows.first?.resource, "nodes")
        XCTAssertEqual(rows.first?.row, KubeRowID(namespace: nil, name: "fake-node-3"))
        XCTAssertEqual(rows.last?.resource, "deployments.apps")
        XCTAssertEqual(rows.map(\.tone), [.failed, .failed, .failed, .failed, .waiting, .waiting])
    }

    func testPodPill() {
        let id = KubeRowID(namespace: "shop", name: "p")
        XCTAssertEqual(KubeOverviewCards.podPill(KubePodSummary(id: id, ready: 0, containers: 1, status: "CrashLoopBackOff", restarts: 14)), "CrashLoopBackOff · 14×")
        XCTAssertEqual(KubeOverviewCards.podPill(KubePodSummary(id: id, ready: 0, containers: 1, status: "Init:Error", restarts: nil)), "Error (init container)")
        XCTAssertEqual(KubeOverviewCards.podPill(KubePodSummary(id: id, ready: 0, containers: 1, status: "Unknown", restarts: 0)), "Unknown")
    }

    func testKindsSayTheirBarsCounts() {
        let kinds = KubeOverviewCards.kinds(overview())
        XCTAssertEqual(kinds.map(\.title), ["Pods", "Deployments", "DaemonSets", "StatefulSets", "Nodes"])
        // A pod Pending and failing (its image not pulled) counted once, as failing.
        XCTAssertEqual(kinds[0].line, "7 running · 1 pending · 3 failing")
        XCTAssertEqual(kinds[0].bar, [.init(tone: .done, count: 7), .init(tone: .waiting, count: 1), .init(tone: .failed, count: 3)])
        XCTAssertEqual(kinds[1].line, "3 ready · 1 not ready")
        XCTAssertEqual(kinds[2].line, "1 not ready")
        XCTAssertEqual(kinds[3].line, "ready")
        XCTAssertEqual(kinds[4].line, "2 ready · 1 not ready")
        XCTAssertEqual(KubeOverviewCards.said([(5, "ready"), (0, "not ready")], total: 5), "all 5 ready")
        XCTAssertEqual(KubeOverviewCards.said([], total: 0), "none")
        XCTAssertEqual(KubeOverviewCards.said([(4, "running")], total: 4), "all 4 running")
    }

    /// Pods said by phase: a completed Job's pod is neither green nor
    /// ready; a Failed pod counted once, as failing.
    func testPodsSaidByTheirPhase() {
        var overview = overview()
        overview.phases = ["Running": 9, "Pending": 2, "Succeeded": 2, "Failed": 1]
        overview.failingPods.append(KubePodSummary(id: KubeRowID(namespace: "shop", name: "job-x"), ready: 0, containers: 1, status: "Error", restarts: 0))
        let pods = KubeOverviewCards.kinds(overview)[0]
        XCTAssertEqual(pods.total, 14)
        XCTAssertEqual(pods.line, "7 running · 2 completed · 1 pending · 4 failing")
        XCTAssertEqual(
            pods.bar, [.init(tone: .done, count: 7), .init(tone: .neutral, count: 2), .init(tone: .waiting, count: 1), .init(tone: .failed, count: 4)])
        XCTAssertEqual(pods.bar.reduce(0) { $0 + $1.count }, pods.total)
        var done = KubeClusterOverview()
        done.phases = ["Succeeded": 3]
        XCTAssertEqual(KubeOverviewCards.kinds(done)[0].line, "3 completed")
    }

    func testHeaderPills() {
        var report = KubeHealth.Report()
        report.checked = 10
        let subject = KubeHealth.Subject(apiVersion: "v1", kind: "Pod", namespace: "shop", name: "queue-0")
        report.findings = [
            KubeHealth.Finding(check: .pendingLong, subject: subject, sentence: "Pending for 3m"),
            KubeHealth.Finding(check: .noLimits, subject: subject, sentence: "no limits"),
        ]
        // Only what ran passes: every check here but Argo CD's.
        report.ran = Set(KubeHealth.Check.allCases).subtracting([.argoDegraded, .argoOutOfSync])
        XCTAssertEqual(KubeOverviewCards.passingChecks(report), KubeHealth.Check.allCases.count - 2 - 2)
        let pills = KubeOverviewCards.pills(overview(), health: report)
        XCTAssertEqual(pills.first, .init(text: "6 need attention", tone: .failed))
        XCTAssertEqual(pills.last?.tone, .done)
        XCTAssertEqual(pills.last?.text, "\(KubeHealth.Check.allCases.count - 4) checks pass")
        XCTAssertEqual(KubeOverviewCards.severities(report), [.init(text: "1 problem", tone: .failed), .init(text: "1 warning", tone: .waiting)])
        XCTAssertEqual(KubeOverviewCards.pills(KubeClusterOverview(), health: nil), [])
        // Argo CD's checks count where Argo CD answered whole.
        report.ran.formUnion([.argoDegraded, .argoOutOfSync])
        XCTAssertEqual(KubeOverviewCards.passingChecks(report), KubeHealth.Check.allCases.count - 2)
        report.findings.append(KubeHealth.Finding(check: .argoDegraded, subject: subject, sentence: "Degraded"))
        XCTAssertEqual(KubeOverviewCards.passingChecks(report), KubeHealth.Check.allCases.count - 3)
    }

    /// A list refused or cut: its checks never said to pass — no all-clear for what wasn't checked.
    func testChecksOverListsNotReadNeverPass() {
        var lists = KubeHealth.Lists()
        lists.add(
            KubeHealth.reads[0], kind: "Pod", apiVersion: "v1", body: try! JSONSerialization.data(withJSONObject: ["metadata": ["continue": "more"], "items": []]),
            place: "namespace shop")
        lists.failed(KubeHealth.reads.first { $0.resource == "services" }!, "Forbidden", place: "namespace shop")
        let report = KubeHealth.report(lists)
        XCTAssertFalse(report.notes.isEmpty)
        XCTAssertTrue(report.findings.isEmpty)
        XCTAssertEqual(KubeOverviewCards.passingChecks(report), 0, "\(report.ran)")
        XCTAssertFalse(KubeOverviewCards.pills(KubeClusterOverview(), health: report).contains { $0.tone == .done })
    }

    func testUsageToneAndColumns() {
        XCTAssertEqual(KubeOverviewCards.usageTone(69), .done)
        XCTAssertEqual(KubeOverviewCards.usageTone(70), .waiting)
        XCTAssertEqual(KubeOverviewCards.usageTone(90), .failed)
        XCTAssertEqual(KubeOverviewCards.columns(count: 6, width: 1700, minimum: 150, spacing: 12), 6)
        XCTAssertEqual(KubeOverviewCards.columns(count: 6, width: 500, minimum: 150, spacing: 12), 3)
        XCTAssertEqual(KubeOverviewCards.columns(count: 6, width: 100, minimum: 150, spacing: 12), 1)
    }

    func testWorkloadSaidAsItsRow() {
        let columns = [KubeColumn(name: "Ready", type: "string"), KubeColumn(name: "Desired", type: "integer"), KubeColumn(name: "Status", type: "string")]
        func row(_ cells: [KubeCell]) -> KubeRow { KubeRow(id: KubeRowID(namespace: "shop", name: "x"), cells: cells) }
        XCTAssertEqual(KubeWorkloadState.said(row([.text("2/3"), .none, .none]), columns: columns, kind: "deployments"), "2/3 ready")
        XCTAssertEqual(KubeWorkloadState.said(row([.integer(2), .integer(3), .none]), columns: columns, kind: "daemonsets"), "2/3 ready")
        XCTAssertEqual(KubeWorkloadState.said(row([.none, .none, .text("Failed")]), columns: columns, kind: "jobs"), "Failed")
    }
}
