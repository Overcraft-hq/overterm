import Foundation
import XCTest

@testable import Overterm

/// The fake against Argo CD's and Flux's own CRDs (docs/design/kubernetes/
/// gitops.md, 8.5): pinned and SHA-checked by `Scripts/fetch-gitops-crds.sh`
/// into `Fixtures/gitops-crds`, read here — nothing downloaded. The fake's
/// printer columns are the CRDs' (names, types, priorities, Age's `date`
/// included), its versions the CRDs' storage versions, and every field the
/// summaries read — the [verify] ones among them — is in the schemas.
final class KubeGitOpsCRDTests: XCTestCase {
    private static let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/gitops-crds")

    /// Each CRD by its full name: its storage version's name, columns and schema.
    private struct CRD {
        var version: String
        var columns: [FakeKubeAPI.Column]
        var schema: [String: Any]
    }

    nonisolated(unsafe) private static var read: [String: CRD]?

    private static func crds() throws -> [String: CRD] {
        if let read { return read }
        var found: [String: CRD] = [:]
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".yaml") }.sorted()
        XCTAssertEqual(files.count, 5, "\(files)")
        for file in files {
            let text = try String(contentsOf: folder.appendingPathComponent(file), encoding: .utf8)
            let documents = try XCTUnwrap(YAMLReader.documents(text), file)
            for case let document as [String: Any] in documents where document["kind"] as? String == "CustomResourceDefinition" {
                let spec = document["spec"] as? [String: Any] ?? [:]
                let group = spec["group"] as? String ?? ""
                let plural = (spec["names"] as? [String: Any])?["plural"] as? String ?? ""
                let versions = spec["versions"] as? [[String: Any]] ?? []
                guard let stored = versions.first(where: { $0["storage"] as? Bool == true }) else { continue }
                let columns = (stored["additionalPrinterColumns"] as? [[String: Any]] ?? []).map { column in
                    FakeKubeAPI.Column(
                        name: column["name"] as? String ?? "", type: column["type"] as? String ?? "", priority: (column["priority"] as? NSNumber)?.intValue ?? 0)
                }
                let schema = ((stored["schema"] as? [String: Any])?["openAPIV3Schema"] as? [String: Any]) ?? [:]
                found["\(plural).\(group)"] = CRD(version: stored["name"] as? String ?? "", columns: columns, schema: schema)
            }
        }
        read = found
        return found
    }

    /// The schema at a path: `properties` by name, `[]` through an array's `items`.
    private func schema(_ root: [String: Any], _ path: String) -> [String: Any]? {
        var node: [String: Any]? = root
        for part in path.split(separator: ".") {
            if part == "[]" {
                node = node?["items"] as? [String: Any]
            } else {
                node = (node?["properties"] as? [String: Any])?[String(part)] as? [String: Any]
            }
        }
        return node
    }

    /// What the opt-in suite deletes after applying the files (8.5): every
    /// CRD they hold, by `metadata.name` — the source controller's six,
    /// ExternalArtifact too, not only those the fake serves.
    func testTheRealClusterSuiteNamesEveryCRDItApplies() throws {
        let files = try FileManager.default.contentsOfDirectory(atPath: Self.folder.path).filter { $0.hasSuffix(".yaml") }
        let names = try Set(files.flatMap { try KubeRealClusterTests.crdNames(inYAML: String(contentsOf: Self.folder.appendingPathComponent($0), encoding: .utf8)) })
        XCTAssertEqual(names, Set(try Self.crds().keys))
        XCTAssertTrue(names.contains("externalartifacts.source.toolkit.fluxcd.io"))
        XCTAssertEqual(names.count, 10, "\(names.sorted())")
    }

    func testTheFakesColumnsAreTheCRDs() throws {
        let crds = try Self.crds()
        for (fullName, columns) in FakeKubeAPI.gitOpsColumns {
            let crd = try XCTUnwrap(crds[fullName], fullName)
            XCTAssertEqual(crd.columns.map(\.name), columns.map(\.name), fullName)
            XCTAssertEqual(crd.columns.map(\.type), columns.map(\.type), "\(fullName): Age is a date column")
            XCTAssertEqual(crd.columns.map(\.priority), columns.map(\.priority), fullName)
        }
        // And the versions the fake serves are the stored ones.
        let fake = FakeKubeAPI(socket: nil)
        fake.serveArgoCD()
        fake.serveFlux()
        for kind in fake.servedKinds where crds[kind.fullName] != nil {
            XCTAssertEqual(kind.version, crds[kind.fullName]?.version, kind.fullName)
        }
        XCTAssertEqual(Set(KubeGitOpsSummary.summarised.map(\.fullName)).subtracting(crds.keys), [], "every summarised kind has its CRD here")
    }

    /// Each key the summary's `spec` and `status` declare is one some CRD
    /// has, and the [verify] fields are where the summaries read them.
    func testEveryFieldTheSummaryReadsIsInTheSchemas() throws {
        let crds = try Self.crds()
        func named(_ part: String) -> Set<String> {
            var names: Set<String> = []
            for crd in crds.values {
                if let properties = schema(crd.schema, part)?["properties"] as? [String: Any] { names.formUnion(properties.keys) }
            }
            return names
        }
        let spec = named("spec")
        let status = named("status")
        XCTAssertEqual(Set(KubeGitOpsWire.Spec.keys).subtracting(spec), [], "spec")
        XCTAssertEqual(Set(KubeGitOpsWire.Status.keys).subtracting(status), [], "status")

        func has(_ fullName: String, _ path: String, line: UInt = #line) {
            XCTAssertNotNil(crds[fullName].flatMap { schema($0.schema, path) }, "\(fullName): \(path)", line: line)
        }
        let applications = "applications.argoproj.io"
        // The [verify] fields.
        has(applications, "spec.syncPolicy.automated.enabled")
        has(applications, "status.operationState.retryCount")
        has(applications, "spec.sourceHydrator.drySource.repoURL")
        // The rest the ladder stands on.
        has(applications, "spec.syncPolicy.automated.selfHeal")
        has(applications, "spec.syncPolicy.retry.limit")
        has(applications, "status.sync.revisions")
        has(applications, "status.operationState.syncResult.revisions")
        has(applications, "status.operationState.syncResult.resources.[].status")
        has(applications, "status.operationState.operation.initiatedBy.automated")
        has(applications, "status.history.[].revisions")
        has(applications, "status.history.[].deployedAt")
        has(applications, "status.resources.[].requiresPruning")
        has(applications, "status.resourceHealthSource")
        has(applications, "status.reconciledAt")
        has(applications, "status.summary.images")
        has("applicationsets.argoproj.io", "status.conditions.[].type")
        has("kustomizations.kustomize.toolkit.fluxcd.io", "status.inventory.entries.[].id")
        has("kustomizations.kustomize.toolkit.fluxcd.io", "status.lastAttemptedRevision")
        has("kustomizations.kustomize.toolkit.fluxcd.io", "spec.retryInterval")
        has("helmreleases.helm.toolkit.fluxcd.io", "status.history.[].chartVersion")
        has("helmreleases.helm.toolkit.fluxcd.io", "status.history.[].status")
        has("helmreleases.helm.toolkit.fluxcd.io", "spec.chartRef.kind")
        has("helmreleases.helm.toolkit.fluxcd.io", "spec.chart.spec.sourceRef.name")
        has("ocirepositories.source.toolkit.fluxcd.io", "status.artifact.metadata")
        has("gitrepositories.source.toolkit.fluxcd.io", "spec.ref.commit")
        has("gitrepositories.source.toolkit.fluxcd.io", "status.artifact.lastUpdateTime")
        has("buckets.source.toolkit.fluxcd.io", "spec.endpoint")
    }
}
