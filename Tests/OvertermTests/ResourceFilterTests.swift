import XCTest

@testable import Overterm

/// A page's filter field (`ResourceFilter`): words split and lowercased,
/// `key:value` by a page's own keys and aliases, `-` negating, unknown
/// names as text, and numeric comparisons. Docker's keys are one table
/// (`DockerPageTests.testFilterWords`); this is another, shaped like a
/// cluster's pods.
final class ResourceFilterTests: XCTestCase {
    private enum PodKey: String, ResourceFilterKey {
        case text, namespace, status, label, field, node, owner, restarts

        static let names: [String: PodKey] = [
            "ns": .namespace, "namespace": .namespace,
            "status": .status, "is": .status,
            "label": .label, "l": .label,
            "field": .field,
            "node": .node,
            "owner": .owner,
            "restarts": .restarts,
        ]
    }

    private struct Pod {
        var name: String
        var namespace: String
        var status: String
        var labels: [String: String]
        var node: String
        var owner: String
        var restarts: Int
    }

    private typealias PodFilter = ResourceFilter<PodKey>

    private func matches(_ filter: PodFilter, _ pod: Pod) -> Bool {
        filter.matches(by: { term in
            switch term.key {
            case .text: pod.name.lowercased().contains(term.value)
            case .namespace: pod.namespace == term.value
            case .status: pod.status.lowercased() == term.value
            case .label:
                pod.labels.contains { key, value in
                    term.value == key.lowercased() || term.value == "\(key)=\(value)".lowercased()
                }
            case .field: false  // a server's selector, sent as typed (`raw`)
            case .node: pod.node.hasPrefix(term.value)
            case .owner: pod.owner.lowercased().contains(term.value)
            case .restarts: term.compare(pod.restarts)
            }
        })
    }

    private let pods = [
        Pod(name: "api-7f9", namespace: "shop", status: "Running", labels: ["app": "api"], node: "ip-10-0-1", owner: "ReplicaSet/api-7f", restarts: 0),
        Pod(
            name: "worker-2c1", namespace: "shop", status: "CrashLoopBackOff", labels: ["app": "worker"], node: "ip-10-0-2",
            owner: "ReplicaSet/worker-2c", restarts: 7),
        Pod(name: "coredns-x1", namespace: "kube-system", status: "Running", labels: ["k8s-app": "kube-dns"], node: "ip-10-0-1", owner: "ReplicaSet/coredns", restarts: 3),
    ]

    private func names(_ text: String) -> [String] {
        let filter = PodFilter(text)
        return pods.filter { matches(filter, $0) }.map(\.name)
    }

    func testTerms() {
        XCTAssertEqual(PodFilter("").terms, [])
        XCTAssertTrue(PodFilter("  \t ").isEmpty)
        XCTAssertEqual(
            PodFilter("NS:Shop -status:running Api").terms,
            [
                .init(key: .namespace, value: "shop", negated: false, raw: "Shop"),
                .init(key: .status, value: "running", negated: true),
                .init(key: .text, value: "api", negated: false, raw: "Api"),
            ])
        XCTAssertEqual(PodFilter("http://x").terms, [.init(key: .text, value: "http://x", negated: false)], "an unknown name is text")
        XCTAssertEqual(PodFilter(":x").terms, [.init(key: .text, value: ":x", negated: false)], "no name is text")
        XCTAssertEqual(PodFilter("ns:").terms, [], "a known key without a value is nothing")
        XCTAssertEqual(PodFilter("-").terms, [.init(key: .text, value: "-", negated: false)], "a lone dash is text")
        XCTAssertEqual(PodFilter("label:app=api").terms, [.init(key: .label, value: "app=api", negated: false)], "only the first colon splits")
        XCTAssertEqual(PodFilter("l:a:b").terms, [.init(key: .label, value: "a:b", negated: false)])
    }

    /// A selector sent to a server is case-sensitive: the value as typed is
    /// kept beside the lowercased one matching reads.
    func testRawKeepsTheCaseAsTyped() {
        let terms = PodFilter("label:app=API -field:status.phase=Running Api-7F").terms
        XCTAssertEqual(terms.map(\.raw), ["app=API", "status.phase=Running", "Api-7F"])
        XCTAssertEqual(terms.map(\.value), ["app=api", "status.phase=running", "api-7f"])
        XCTAssertEqual(terms.map(\.negated), [false, true, false])
        XCTAssertEqual(PodFilter("http://X").terms.map(\.raw), ["http://X"], "an unknown name keeps the whole word")
    }

    func testMatchingByThePagesMeaning() {
        XCTAssertEqual(names(""), ["api-7f9", "worker-2c1", "coredns-x1"])
        XCTAssertEqual(names("ns:shop"), ["api-7f9", "worker-2c1"])
        XCTAssertEqual(names("namespace:kube-system"), ["coredns-x1"], "an alias")
        XCTAssertEqual(names("-ns:shop"), ["coredns-x1"])
        XCTAssertEqual(names("status:running ns:shop"), ["api-7f9"], "every term")
        XCTAssertEqual(names("label:app=worker"), ["worker-2c1"])
        XCTAssertEqual(names("l:k8s-app"), ["coredns-x1"])
        XCTAssertEqual(names("node:ip-10-0-1"), ["api-7f9", "coredns-x1"])
        XCTAssertEqual(names("owner:replicaset/worker"), ["worker-2c1"])
        XCTAssertEqual(names("API"), ["api-7f9"], "any case")
    }

    func testNumericComparisons() {
        XCTAssertEqual(names("restarts:>3"), ["worker-2c1"])
        XCTAssertEqual(names("restarts:>=3"), ["worker-2c1", "coredns-x1"])
        XCTAssertEqual(names("restarts:<3"), ["api-7f9"])
        XCTAssertEqual(names("restarts:<=3"), ["api-7f9", "coredns-x1"])
        XCTAssertEqual(names("restarts:=7"), ["worker-2c1"])
        XCTAssertEqual(names("restarts:0"), ["api-7f9"], "a bare number is equal")
        XCTAssertEqual(names("-restarts:>0"), ["api-7f9"])
        XCTAssertEqual(names("restarts:many"), [], "not a number matches nothing")
        XCTAssertEqual(names("-restarts:many"), ["api-7f9", "worker-2c1", "coredns-x1"])

        XCTAssertNil(ResourceFilterComparison(">"))
        XCTAssertNil(ResourceFilterComparison(""))
        XCTAssertNil(ResourceFilterComparison(">+3"))
        XCTAssertNil(ResourceFilterComparison("-3"))
        XCTAssertNil(ResourceFilterComparison("=>3"))
        XCTAssertNil(ResourceFilterComparison("٣"), "only ASCII digits")
        XCTAssertEqual(ResourceFilterComparison(">=12"), ResourceFilterComparison(op: .greaterOrEqual, number: 12))
    }

    /// Docker's table: every alias it had, and still nothing else.
    func testDockerKeys() {
        let keys = ["status", "state", "is", "project", "p", "stack", "service", "s", "image", "i", "port", "session", "tc"]
        XCTAssertEqual(Set(DockerFilterKey.names.keys), Set(keys))
        XCTAssertEqual(DockerFilter("STACK:Shop").terms, [.init(key: .project, value: "shop", negated: false, raw: "Shop")])
        XCTAssertEqual(DockerFilter("text:x").terms, [.init(key: .text, value: "text:x", negated: false)], "text is not a name")
    }
}
