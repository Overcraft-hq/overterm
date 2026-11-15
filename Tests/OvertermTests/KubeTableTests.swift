import Foundation
import XCTest

@testable import Overterm

/// The pure half of the Kubernetes client: Tables read (columns and their
/// priorities, rows known by namespace and name, the List fallback), a
/// pod's row read into what the list marks, watch events decoded (headers
/// kept from the first, bookmarks, an in-stream 410), discovery read
/// (aggregated and legacy), the API's errors, paths and queries.
final class KubeTableTests: XCTestCase {
    private func json(_ object: Any) -> Data { try! JSONSerialization.data(withJSONObject: object) }

    private static var podColumns: [[String: Any]] {
        [
            ["name": "Name", "type": "string", "format": "name", "description": "", "priority": 0],
            ["name": "Ready", "type": "string", "format": "", "description": "", "priority": 0],
            ["name": "Status", "type": "string", "format": "", "description": "", "priority": 0],
            ["name": "Restarts", "type": "string", "format": "", "description": "", "priority": 0],
            ["name": "Age", "type": "string", "format": "", "description": "", "priority": 0],
            ["name": "IP", "type": "string", "format": "", "description": "", "priority": 1],
            ["name": "Node", "type": "string", "format": "", "description": "", "priority": 1],
        ]
    }

    private func podTable(_ rows: [[Any]], columns: Bool = true, metadata: [String: Any] = ["resourceVersion": "42"]) -> [String: Any] {
        var table: [String: Any] = ["kind": "Table", "apiVersion": "meta.k8s.io/v1", "metadata": metadata, "rows": rows.map { ["cells": $0] }]
        if columns { table["columnDefinitions"] = Self.podColumns }
        return table
    }

    // MARK: Tables

    func testATableIsColumnsAndRowsKnownByNamespaceAndName() throws {
        let table = try KubeTableReader.read(
            json(
                podTable(
                    [["web-1", "1/1", "Running", 0, "5m", "10.0.0.1", "n1"], ["api-1", "0/1", "CrashLoopBackOff", "7 (2m ago)", "1h", "10.0.0.2", "n2"]],
                    metadata: ["resourceVersion": "42", "continue": "abc", "remainingItemCount": 3])),
            namespace: "shop")
        XCTAssertEqual(table.columns.map(\.name), ["Name", "Ready", "Status", "Restarts", "Age", "IP", "Node"])
        XCTAssertEqual(table.defaultColumns.map(\.name), ["Name", "Ready", "Status", "Restarts", "Age"], "priority 0 only; the rest are -o wide's")
        XCTAssertEqual(table.columns[5].priority, 1)
        XCTAssertEqual(table.rows.map(\.id), [KubeRowID(namespace: "shop", name: "web-1"), KubeRowID(namespace: "shop", name: "api-1")])
        XCTAssertEqual(table.rows[0].cells[3], .integer(0))
        XCTAssertEqual(table.rows[1].cells[3], .text("7 (2m ago)"))
        XCTAssertEqual(table.resourceVersion, "42")
        XCTAssertEqual(table.continueToken, "abc")
        XCTAssertEqual(table.remainingItemCount, 3)
        XCTAssertEqual(table.column(named: "status"), 2)
        XCTAssertEqual(table.rows[1].cell("Status", in: table.columns), .text("CrashLoopBackOff"))
    }

    func testARowsNamespaceIsItsColumnsElseTheRequestsAndAClusterKindHasNone() throws {
        let columns: [[String: Any]] = [["name": "Namespace", "type": "string"], ["name": "Name", "type": "string", "format": "name"]]
        let table = try KubeTableReader.read(
            json(["kind": "Table", "columnDefinitions": columns, "rows": [["cells": ["a", "x"]], ["cells": ["b", "x"]], ["cells": ["", ""]]]]), namespace: nil)
        XCTAssertEqual(table.rows.map(\.id.description), ["a/x", "b/x"], "the same name in two namespaces is two rows; a row with no name is none")
        let namespaces = try KubeTableReader.read(
            json(["kind": "Table", "columnDefinitions": [["name": "Name", "format": "name"], ["name": "Status"]], "rows": [["cells": ["default", "Active"]]]]),
            namespace: nil)
        XCTAssertEqual(namespaces.rows.first?.id, KubeRowID(namespace: nil, name: "default"))
        // An embedded object's metadata (includeObject=Metadata) says it too.
        let embedded = try KubeTableReader.read(
            json([
                "kind": "Table", "columnDefinitions": [["name": "Name", "format": "name"]],
                "rows": [["cells": ["p"], "object": ["kind": "PartialObjectMetadata", "metadata": ["name": "p", "namespace": "ns"]]]],
            ]), namespace: nil)
        XCTAssertEqual(embedded.rows.first?.id.description, "ns/p")
    }

    /// A Metadata row's embedded object is a `PartialObjectMetadata` of
    /// `meta.k8s.io`: a tracking id is checked against the kind the list
    /// asked for and the row's own name and namespace, never against what
    /// the embedded object says it is.
    func testARowsMarkIsCheckedAgainstTheKindListedNotTheEmbeddedOne() throws {
        func table(kind: String, apiVersion: String, namespace: String?, name: String, mark: String) -> [String: Any] {
            var metadata: [String: Any] = ["name": name, "annotations": ["argocd.argoproj.io/tracking-id": mark]]
            metadata["namespace"] = namespace
            return [
                "kind": "Table", "columnDefinitions": [["name": "Name", "format": "name"]],
                "rows": [["cells": [name], "object": ["kind": kind, "apiVersion": apiVersion, "metadata": metadata]]],
            ]
        }
        let mark = "prod-shop-api-service:apps/Deployment:shop/api"
        let deployments = try KubeTableReader.read(
            table(kind: "PartialObjectMetadata", apiVersion: "meta.k8s.io/v1", namespace: "shop", name: "api", mark: mark), namespace: nil, kind: .deployments,
            owners: true)
        XCTAssertEqual(deployments.rows.first?.owners.map(\.said), ["Application prod-shop-api-service"], "PartialObjectMetadata, read as the Deployment listed")
        // An embedded object that claims to be the Deployment doesn't make a ReplicaSet's copy its own.
        let replicaSets = try KubeTableReader.read(
            table(kind: "Deployment", apiVersion: "apps/v1", namespace: "shop", name: "api", mark: mark), namespace: nil, kind: .replicaSets, owners: true)
        XCTAssertEqual(replicaSets.rows.first?.owners, [])
        // Its namespace from the row: the same name in another namespace is a copy.
        let elsewhere = try KubeTableReader.read(
            table(kind: "PartialObjectMetadata", apiVersion: "meta.k8s.io/v1", namespace: "shop-2", name: "api", mark: mark), namespace: nil,
            kind: .deployments, owners: true)
        XCTAssertEqual(elsewhere.rows.first?.owners, [])
        // A cluster-scoped kind: the mark's namespace is the destination's, not compared.
        let clusterRoles = KubeResourceKind(
            group: "rbac.authorization.k8s.io", version: "v1", resource: "clusterroles", kind: "ClusterRole", singular: "clusterrole", namespaced: false,
            verbs: ["get", "list", "watch"])
        let roles = try KubeTableReader.read(
            table(
                kind: "PartialObjectMetadata", apiVersion: "meta.k8s.io/v1", namespace: nil, name: "acme-reader",
                mark: "acme-rbac:rbac.authorization.k8s.io/ClusterRole:payments/acme-reader"), namespace: nil, kind: clusterRoles, owners: true)
        XCTAssertEqual(roles.rows.first?.owners.map(\.name), ["acme-rbac"])
    }

    /// Whether a row's metadata carries one of Argo CD's own marks is
    /// looked up, nothing of it kept, on every row with metadata — marks
    /// asked or not; a Helm instance label isn't one.
    func testARowSaysWhetherItCarriesArgoCDsMark() throws {
        func row(_ metadata: [String: Any]?) throws -> KubeRow? {
            var row: [String: Any] = ["cells": ["api"]]
            if let metadata { row["object"] = ["kind": "PartialObjectMetadata", "metadata": metadata] }
            return try KubeTableReader.read(
                json(["kind": "Table", "columnDefinitions": [["name": "Name", "format": "name"]], "rows": [row]]), namespace: nil
            ).rows.first
        }
        let tracked = try row(["name": "api", "namespace": "shop", "annotations": ["argocd.argoproj.io/tracking-id": "prod-shop-api-service:apps/Deployment:shop/api"]])
        XCTAssertEqual(tracked?.argoMarked, true)
        XCTAssertNil(tracked?.marks, "nothing kept: marks weren't asked")
        XCTAssertEqual(try row(["name": "api", "labels": ["argocd.argoproj.io/instance": "prod-shop-api"]])?.argoMarked, true)
        XCTAssertEqual(try row(["name": "api", "labels": ["app.kubernetes.io/instance": "api"]])?.argoMarked, false)
        XCTAssertEqual(try row(nil)?.argoMarked, false)
    }

    func testCellsAreAsTheServerSentThem() {
        XCTAssertEqual(KubeCell(json: "x"), .text("x"))
        XCTAssertEqual(KubeCell(json: NSNumber(value: 3)), .integer(3))
        XCTAssertEqual(KubeCell(json: NSNumber(value: 2.5)), .number(2.5))
        XCTAssertEqual(KubeCell(json: NSNumber(value: true)), .bool(true))
        XCTAssertEqual(KubeCell(json: NSNull()), .none)
        XCTAssertEqual(KubeCell(json: ["b": 1, "a": 2]).text, #"{"a":2,"b":1}"#)
        XCTAssertEqual(KubeCell.number(4).text, "4")
        XCTAssertEqual(KubeCell.bool(false).text, "false")
        XCTAssertEqual(KubeCell.none.text, "")
    }

    /// An API without Table support answers plain JSON: Name and Created At.
    func testAPlainListOrObjectIsNameAndCreatedAt() throws {
        let list = try KubeTableReader.read(
            json([
                "kind": "WidgetList", "metadata": ["resourceVersion": "9", "continue": ""],
                "items": [["metadata": ["name": "w", "namespace": "ns", "creationTimestamp": "2026-11-01T00:00:00Z"]]],
            ]), namespace: "ns")
        XCTAssertEqual(list.columns.map(\.name), ["Namespace", "Name", "Created At"])
        XCTAssertEqual(list.rows.first?.id.description, "ns/w")
        XCTAssertEqual(list.rows.first?.cells.last, .text("2026-11-01T00:00:00Z"))
        XCTAssertEqual(list.resourceVersion, "9")
        XCTAssertNil(list.continueToken, "an empty continue is none")
        let one = try KubeTableReader.read(json(["kind": "Widget", "metadata": ["name": "w"]]), namespace: nil)
        XCTAssertEqual(one.columns.map(\.name), ["Name", "Created At"])
        XCTAssertThrowsError(try KubeTableReader.read(Data("nope".utf8), namespace: nil))
        XCTAssertThrowsError(try KubeTableReader.read(json(["kind": "Status"]), namespace: nil))
    }

    // MARK: Pods

    private func pod(_ cells: [Any]) throws -> KubePodSummary {
        let table = try KubeTableReader.read(json(podTable([cells])), namespace: "ns")
        return try XCTUnwrap(KubePodSummary(row: table.rows[0], columns: table.columns))
    }

    func testAPodsRowSaysWhetherItFailsAndWhy() throws {
        let running = try pod(["a", "2/2", "Running", 0, "1m"])
        XCTAssertEqual(running.ready, 2)
        XCTAssertEqual(running.containers, 2)
        XCTAssertEqual(running.restarts, 0)
        XCTAssertNil(running.lastRestart)
        XCTAssertTrue(running.isReady)
        XCTAssertFalse(running.isFailing)
        XCTAssertNil(running.exitReason)

        let crashing = try pod(["b", "0/1", "CrashLoopBackOff", "12 (3m4s ago)", "1h"])
        XCTAssertEqual(crashing.restarts, 12)
        XCTAssertEqual(crashing.lastRestart, "3m4s ago")
        XCTAssertTrue(crashing.isFailing)
        XCTAssertFalse(crashing.isReady)
        XCTAssertEqual(crashing.exitReason, "CrashLoopBackOff")

        XCTAssertEqual(try pod(["c", "0/1", "OOMKilled", 3, "1h"]).exitReason, "OOMKilled")
        XCTAssertEqual(try pod(["d", "0/1", "Init:CrashLoopBackOff", 2, "1h"]).exitReason, "CrashLoopBackOff (init container)")
        XCTAssertEqual(try pod(["e", "0/1", "ExitCode:137", 0, "1h"]).exitReason, "ExitCode:137")
        XCTAssertEqual(try pod(["f", "0/1", "ImagePullBackOff", 0, "1h"]).exitReason, "ImagePullBackOff")
        let initializing = try pod(["g", "0/1", "Init:0/2", 0, "5s"])
        XCTAssertTrue(initializing.isInit)
        XCTAssertFalse(initializing.isFailing, "an init container still running isn't failing")
        let completed = try pod(["h", "0/1", "Completed", 0, "1d"])
        XCTAssertTrue(completed.isCompleted)
        XCTAssertFalse(completed.isFailing)
        XCTAssertFalse(try pod(["i", "1/2", "Running", 0, "1m"]).isReady, "running but not every container ready")
        XCTAssertFalse(try pod(["j", "0/1", "Pending", 0, "1m"]).isFailing)
        XCTAssertNil(KubePodSummary(row: KubeRow(id: KubeRowID(name: "x"), cells: [.text("x")]), columns: [KubeColumn(name: "Name", format: "name")]))
    }

    // MARK: A Flux source's credentials

    private static let gitRepository = KubeResourceKind(
        group: "source.toolkit.fluxcd.io", version: "v1", resource: "gitrepositories", kind: "GitRepository", singular: "gitrepository", namespaced: true,
        verbs: ["get", "list", "watch"])

    private func sourceTable(_ rows: [[Any]], columns: Bool = true) -> [String: Any] {
        var table: [String: Any] = ["kind": "Table", "metadata": ["resourceVersion": "7"], "rows": rows.map { ["cells": $0] }]
        if columns {
            table["columnDefinitions"] = [
                ["name": "Name", "type": "string", "format": "name"], ["name": "URL", "type": "string"], ["name": "Age", "type": "date"],
                ["name": "Ready", "type": "string"], ["name": "Status", "type": "string"],
            ]
        }
        return table
    }

    func testAFluxSourcesURLColumnLosesItsCredentials() throws {
        let rows: [[Any]] = [
            [
                "acme-fleet", "https://user:ghp_fake@git.acme.example/acme/shop.git", "5m", "False",
                "failed to checkout and determine revision: unable to clone 'https://user:ghp_fake@git.acme.example/acme/shop.git': authentication required",
            ],
            ["acme-token", "https://ghp_fake@git.acme.example/acme/api.git", "1h", "True", "stored artifact for revision 'main@sha1:c1'"],
            ["acme-ssh", "ssh://git@git.acme.example/acme/infra.git", "1h", "True", ""],
        ]
        let table = try KubeTableReader.read(json(sourceTable(rows)), namespace: "flux-system", kind: Self.gitRepository)
        XCTAssertEqual(
            table.rows.map { $0.cell("URL", in: table.columns)?.text },
            ["https://git.acme.example/acme/shop.git", "https://git.acme.example/acme/api.git", "ssh://git.acme.example/acme/infra.git"])
        XCTAssertEqual(
            table.rows[0].cell("Status", in: table.columns)?.text,
            "failed to checkout and determine revision: unable to clone 'https://git.acme.example/acme/shop.git': authentication required",
            "the Ready message quoting it too")
        XCTAssertFalse(table.rows.flatMap(\.cells).contains { $0.text.contains("ghp_fake") })
        XCTAssertEqual(table.rows[1].cells[2], .text("1h"), "the other cells as they were")

        for resource in ["ocirepositories", "helmrepositories", "buckets"] {
            var kind = Self.gitRepository
            kind.resource = resource
            let read = try KubeTableReader.read(json(sourceTable([["x", "oci://robot:s3cr3t@ghcr.io/acme/charts", "1m", "True", ""]])), namespace: "a", kind: kind)
            XCTAssertEqual(read.rows.first?.cells[1], .text("oci://ghcr.io/acme/charts"), resource)
        }

        // Another kind's cells are the server's: nothing is read into them.
        var other = Self.gitRepository
        other.group = "example.acme.io"
        let raw = try KubeTableReader.read(json(sourceTable([["x", "https://u:p@h.example/x", "1m", "True", ""]])), namespace: "a", kind: other)
        XCTAssertEqual(raw.rows.first?.cells[1], .text("https://u:p@h.example/x"))
    }

    func testAFluxSourcesWatchedRowsLoseTheirCredentialsToo() throws {
        var decoder = KubeWatchDecoder(columns: [], namespace: "flux-system", kind: Self.gitRepository)
        let first = json(["type": "ADDED", "object": sourceTable([["acme-fleet", "https://git.acme.example/acme/shop.git", "1m", "True", ""]])])
        let second = json([
            "type": "MODIFIED", "object": sourceTable([["acme-fleet", "https://bot:ghp_fake@git.acme.example/acme/shop.git", "2m", "True", ""]], columns: false),
        ])
        let events = try decoder.feed(first + Data([0x0A]) + second + Data([0x0A]))
        guard events.count == 2, case .modified(let row, _) = events[1] else { return XCTFail("\(events)") }
        XCTAssertEqual(row.cell("URL", in: decoder.columns), .text("https://git.acme.example/acme/shop.git"), "a later event, read with the kept headers")
    }

    // MARK: Watch events

    func testAWatchKeepsTheFirstEventsHeadersForTheRest() throws {
        var decoder = KubeWatchDecoder(columns: [], namespace: "ns")
        let first = json(["type": "ADDED", "object": podTable([["a", "1/1", "Running", 0, "1s"]], metadata: ["resourceVersion": "101"])])
        let second = json(["type": "MODIFIED", "object": podTable([["a", "0/1", "Error", 1, "2s"]], columns: false, metadata: ["resourceVersion": "102"])])
        let third = json(["type": "DELETED", "object": podTable([["a", "0/1", "Error", 1, "3s"]], columns: false, metadata: ["resourceVersion": "103"])])
        var stream = first + Data([0x0A]) + second + Data([0x0A]) + third
        // In pieces that cut an event in two.
        let cut = stream.count / 2 + 7
        var events = try decoder.feed(Data(stream.prefix(cut)))
        stream = Data(stream.dropFirst(cut))
        events += try decoder.feed(stream)
        XCTAssertEqual(events.count, 2, "the last line isn't whole until the stream ends")
        events += try decoder.finish()
        XCTAssertEqual(decoder.columns.count, 7)
        guard events.count == 3, case .added(let added, "101") = events[0], case .modified(let modified, "102") = events[1],
            case .deleted(let deleted, "103") = events[2]
        else { return XCTFail("\(events)") }
        XCTAssertEqual(added.id.description, "ns/a")
        XCTAssertEqual(KubePodSummary(row: modified, columns: decoder.columns)?.exitReason, "Error", "headers kept from the first event")
        XCTAssertEqual(deleted.id, added.id)
    }

    func testBookmarksAndAnInStream410() throws {
        var decoder = KubeWatchDecoder(columns: [], namespace: nil)
        let bookmark = json(["type": "BOOKMARK", "object": ["kind": "Table", "metadata": ["resourceVersion": "500"], "rows": []]])
        let end = json([
            "type": "BOOKMARK", "object": ["kind": "Pod", "metadata": ["resourceVersion": "501", "annotations": ["k8s.io/initial-events-end": "true"]]],
        ])
        let gone = json([
            "type": "ERROR",
            "object": ["kind": "Status", "apiVersion": "v1", "status": "Failure", "message": "too old resource version: 1 (5)", "reason": "Expired", "code": 410],
        ])
        XCTAssertEqual(try decoder.decode(bookmark), [.bookmark(resourceVersion: "500", initialEventsEnd: false)])
        XCTAssertEqual(try decoder.decode(end), [.bookmark(resourceVersion: "501", initialEventsEnd: true)])
        let events = try decoder.decode(gone)
        XCTAssertEqual(events, [.error(KubeAPIError(status: 410, reason: "Expired", message: "too old resource version: 1 (5)"))])
        if case .error(let error) = events.first { XCTAssertTrue(error.isGone) }
        XCTAssertThrowsError(try decoder.decode(Data("{}".utf8)))
    }

    /// A streaming list's end as kind's 1.37 sends it for a Table: the
    /// annotation on the one row's object, not the Table's metadata — and,
    /// for an empty list, the columns with it (lines as the server wrote
    /// them, the descriptions cut).
    func testAStreamingListsEndAsARealServerSendsATable() throws {
        var decoder = KubeWatchDecoder(columns: [], namespace: "default")
        let added = Data(
            #"{"type":"ADDED","object":{"kind":"Table","apiVersion":"meta.k8s.io/v1","metadata":{"resourceVersion":"495"},"columnDefinitions":[{"name":"Name","type":"string","format":"name","description":"","priority":0},{"name":"Ready","type":"string","format":"","description":"","priority":0}],"rows":[{"cells":["coredns-1","1/1"],"object":{"kind":"PartialObjectMetadata","apiVersion":"meta.k8s.io/v1","metadata":{"name":"coredns-1","namespace":"kube-system","resourceVersion":"495"}}}]}}"#
                .utf8)
        let end = Data(
            #"{"type":"BOOKMARK","object":{"kind":"Table","apiVersion":"meta.k8s.io/v1","metadata":{"resourceVersion":"843"},"columnDefinitions":null,"rows":[{"cells":["","0/0"],"object":{"kind":"PartialObjectMetadata","apiVersion":"meta.k8s.io/v1","metadata":{"resourceVersion":"843","annotations":{"k8s.io/initial-events-end":"true"}}}}]}}"#
                .utf8)
        XCTAssertEqual(try decoder.decode(added).count, 1)
        XCTAssertEqual(try decoder.decode(end), [.bookmark(resourceVersion: "843", initialEventsEnd: true)], "its end, not one more row")
        XCTAssertEqual(decoder.columns.map(\.name), ["Name", "Ready"], "the list's columns kept")

        // includeObject=None: the bookmark's row still has an object, and it says so.
        var empty = KubeWatchDecoder(columns: [], namespace: "nothing-here")
        let emptyEnd = Data(
            #"{"type":"BOOKMARK","object":{"kind":"Table","apiVersion":"meta.k8s.io/v1","metadata":{"resourceVersion":"912"},"columnDefinitions":[{"name":"Name","type":"string","format":"name","description":"","priority":0},{"name":"Age","type":"string","format":"","description":"","priority":0}],"rows":[{"cells":["","<unknown>"],"object":{"kind":"PartialObjectMetadata","apiVersion":"meta.k8s.io/v1","metadata":{"resourceVersion":"912","annotations":{"k8s.io/initial-events-end":"true"}}}}]}}"#
                .utf8)
        XCTAssertEqual(try empty.decode(emptyEnd), [.bookmark(resourceVersion: "912", initialEventsEnd: true)])
        XCTAssertEqual(empty.columns.map(\.name), ["Name", "Age"], "an empty list's columns come with its end")
        // A Table bookmark that isn't the end.
        let interim = Data(#"{"type":"BOOKMARK","object":{"kind":"Table","metadata":{"resourceVersion":"900"},"rows":[{"cells":[""],"object":{"metadata":{"resourceVersion":"900"}}}]}}"#.utf8)
        XCTAssertEqual(try empty.decode(interim), [.bookmark(resourceVersion: "900", initialEventsEnd: false)])
    }

    func testRowsFollowAListAndItsChanges() throws {
        let table = try KubeTableReader.read(json(podTable([["a", "1/1", "Running", 0, "1s"], ["b", "1/1", "Running", 0, "1s"]])), namespace: "ns")
        var rows = KubeRows(table)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.resourceVersion, "42")
        let c = KubeRow(id: KubeRowID(namespace: "ns", name: "c"), cells: [.text("c")])
        var b = table.rows[1]
        b.cells[2] = .text("Error")
        rows.apply(.changed([.added(c), .modified(b), .deleted(table.rows[0].id)], resourceVersion: "50"))
        XCTAssertEqual(rows.sorted.map(\.id.name), ["b", "c"])
        XCTAssertEqual(rows[b.id]?.cells[2], .text("Error"))
        XCTAssertEqual(rows.resourceVersion, "50")
        rows.apply(.bookmark("60"))
        XCTAssertEqual(rows.resourceVersion, "60")
        XCTAssertEqual(rows.count, 2)
        rows.apply(.listed(KubeTable(columns: table.columns, rows: [], resourceVersion: "70")))
        XCTAssertEqual(rows.count, 0, "a list again replaces everything")
        XCTAssertEqual(rows.columns.count, 7)
    }

    // MARK: Discovery

    func testAggregatedDiscoveryGivesKindsScopeVerbsAndSubresources() throws {
        let answer = try KubeDiscovery.answer(
            json([
                "kind": "APIGroupDiscoveryList", "apiVersion": "apidiscovery.k8s.io/v2",
                "items": [
                    [
                        "metadata": ["name": "apps"],
                        "versions": [
                            [
                                "version": "v1",
                                "resources": [
                                    [
                                        "resource": "deployments", "responseKind": ["group": "apps", "version": "v1", "kind": "Deployment"],
                                        "scope": "Namespaced", "singularResource": "deployment", "verbs": ["get", "list", "watch"], "shortNames": ["deploy"],
                                        "subresources": [["subresource": "scale"], ["subresource": "status"]],
                                    ]
                                ],
                            ],
                            ["version": "v1beta1", "resources": [["resource": "old", "scope": "Cluster"]]],
                        ],
                    ]
                ],
            ]))
        guard case .aggregated(let kinds, let stale) = answer else { return XCTFail("\(answer)") }
        XCTAssertEqual(stale, [:])
        XCTAssertEqual(kinds.count, 1, "the preferred (first) version only")
        let deployments = try XCTUnwrap(kinds.first)
        XCTAssertEqual(deployments.fullName, "deployments.apps")
        XCTAssertEqual(deployments.kind, "Deployment")
        XCTAssertTrue(deployments.namespaced)
        XCTAssertTrue(deployments.canWatch)
        XCTAssertEqual(deployments.subresources, ["scale", "status"])
        XCTAssertEqual(deployments.path(namespace: "ns"), "/apis/apps/v1/namespaces/ns/deployments")
    }

    /// An aggregated API that is down is marked `Stale`, not left out:
    /// noted, and a group's next version that isn't stale is used.
    func testAggregatedDiscoveryNotesAStaleVersion() throws {
        let answer = try KubeDiscovery.answer(
            json([
                "kind": "APIGroupDiscoveryList", "apiVersion": "apidiscovery.k8s.io/v2",
                "items": [
                    ["metadata": ["name": "metrics.k8s.io"], "versions": [["version": "v1beta1", "freshness": "Stale", "resources": [[String: Any]]()]]],
                    [
                        "metadata": ["name": "example.com"],
                        "versions": [
                            ["version": "v2", "freshness": "Stale", "resources": [["resource": "widgets", "scope": "Namespaced"]]],
                            ["version": "v1", "freshness": "Current", "resources": [["resource": "widgets", "scope": "Namespaced"]]],
                        ],
                    ],
                ],
            ]))
        guard case .aggregated(let kinds, let stale) = answer else { return XCTFail("\(answer)") }
        XCTAssertEqual(Set(stale.keys), ["metrics.k8s.io/v1beta1", "example.com/v2"])
        XCTAssertEqual(kinds.map(\.groupVersion), ["example.com/v1"], "the next version that answers")
    }

    func testLegacyDiscoveryFoldsSubresourcesIntoTheirKinds() throws {
        XCTAssertEqual(try KubeDiscovery.answer(json(["kind": "APIVersions", "versions": ["v1"]])), .coreVersions(["v1"]))
        XCTAssertEqual(
            try KubeDiscovery.answer(
                json(["kind": "APIGroupList", "groups": [["name": "apps", "versions": [["groupVersion": "apps/v1"]], "preferredVersion": ["groupVersion": "apps/v1"]]]])),
            .groups(["apps/v1"]))
        let kinds = try KubeDiscovery.resourceList(
            json([
                "kind": "APIResourceList", "groupVersion": "v1",
                "resources": [
                    ["name": "pods", "singularName": "pod", "namespaced": true, "kind": "Pod", "verbs": ["get", "list", "watch"], "shortNames": ["po"]],
                    ["name": "pods/log", "namespaced": true, "kind": "Pod", "verbs": ["get"]],
                    ["name": "pods/exec", "namespaced": true, "kind": "PodExecOptions", "verbs": ["create", "get"]],
                    ["name": "nodes", "singularName": "", "namespaced": false, "kind": "Node", "verbs": ["list"]],
                ],
            ]))
        XCTAssertEqual(kinds.map(\.resource), ["pods", "nodes"])
        XCTAssertEqual(kinds[0].subresources, ["log", "exec"])
        XCTAssertEqual(kinds[1].singular, "node", "an empty singular is the kind's")
        XCTAssertFalse(kinds[1].namespaced)
        XCTAssertEqual(kinds[1].path(namespace: "ignored", name: "n1"), "/api/v1/nodes/n1", "a cluster kind's path has no namespace")
        XCTAssertThrowsError(try KubeDiscovery.resourceList(json(["kind": "Status"])))
    }

    func testAKindByAnyOfKubectlsNames() {
        let discovery = KubeDiscovery(kinds: FakeKubeAPI.builtinKinds.map(Self.kind))
        XCTAssertEqual(discovery.kind("po")?.fullName, "pods")
        XCTAssertEqual(discovery.kind("pods")?.group, "", "the core pods, not metrics.k8s.io's")
        XCTAssertEqual(discovery.kind("Pod")?.fullName, "pods")
        XCTAssertEqual(discovery.kind("deploy")?.fullName, "deployments.apps")
        XCTAssertEqual(discovery.kind("deployment")?.fullName, "deployments.apps")
        XCTAssertEqual(discovery.kind("events")?.group, "", "core first, as kubectl resolves it")
        XCTAssertEqual(discovery.kind("events.events.k8s.io")?.group, "events.k8s.io")
        XCTAssertEqual(discovery.kind("pods.metrics.k8s.io")?.kind, "PodMetrics")
        XCTAssertNil(discovery.kind("widgets"))
    }

    private static func kind(_ kind: FakeKubeAPI.Kind) -> KubeResourceKind {
        KubeResourceKind(
            group: kind.group, version: kind.version, resource: kind.resource, kind: kind.kind, singular: kind.kind.lowercased(), namespaced: kind.namespaced,
            verbs: kind.verbs, shortNames: kind.shortNames, categories: kind.categories, subresources: kind.subresources)
    }

    // MARK: Errors and paths

    func testTheServersErrorIsItsStatus() {
        let body = json(["kind": "Status", "message": "pods is forbidden: User \"u\" cannot list resource \"pods\"", "reason": "Forbidden", "code": 403])
        let forbidden = KubeAPIError.from(HTTPResponse(status: 403, headers: [("Content-Type", "application/json")], body: body))
        XCTAssertTrue(forbidden.isForbidden)
        XCTAssertEqual(forbidden.reason, "Forbidden")
        XCTAssertEqual(forbidden.message, #"pods is forbidden: User "u" cannot list resource "pods""#)
        let throttled = KubeAPIError.from(HTTPResponse(status: 429, headers: [("Retry-After", "3")], body: Data("slow down".utf8)))
        XCTAssertEqual(throttled.retryAfter, 3)
        XCTAssertEqual(throttled.message, "slow down")
        XCTAssertNil(throttled.reason)
    }

    func testNamesAndSelectorsAreEscaped() {
        XCTAssertEqual(KubeResourceKind.pods.path(namespace: "ns", name: "a/b"), "/api/v1/namespaces/ns/pods/a%2Fb", "a slash can't make another path")
        XCTAssertEqual(KubeResourceKind.pods.path(), "/api/v1/pods")
        XCTAssertEqual(KubeResourceKind.namespaces.path(namespace: "x"), "/api/v1/namespaces")
        XCTAssertEqual(
            KubePath.query("/api/v1/pods", [("labelSelector", "app=web,tier!=db"), ("continue", nil), ("limit", "500")]),
            "/api/v1/pods?labelSelector=app%3Dweb%2Ctier%21%3Ddb&limit=500")
        XCTAssertEqual(KubePath.query("/x", []), "/x")
        XCTAssertTrue(KubeClient.servesStreamingLists(minor: 32))
        XCTAssertFalse(KubeClient.servesStreamingLists(minor: 33))
        XCTAssertTrue(KubeClient.servesStreamingLists(minor: 35))
    }
}
