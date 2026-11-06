import Foundation
import XCTest

@testable import Overterm

/// A manifest's keys for the cluster's docs (3.15): each key's path, the
/// document's kind, where a key typed at the caret goes, and the unknown
/// fields marked against a fixture document. Pure.
final class KubeManifestFieldsTests: XCTestCase {
    static let manifest = """
        apiVersion: apps/v1
        kind: Deployment
        metadata:
          name: web
          labels:
            app: web
        spec:
          replicas: 2
          template:
            spec:
              containers:
              - name: web
                image: nginx:1.27
                args: ["--port", "80"]
                resources:
                  limits:
                    cpu: 500m
              - name: sidecar
                imag: busybox
          strategy:
            type: RollingUpdate
        ---
        apiVersion: v1
        kind: ConfigMap
        metadata:
          name: web-config
        data:
          nginx.conf: |
            server:
              listen: 80
          "quoted.key": yes
        """

    private func key(_ name: String, occurrence: Int = 0, in text: String = manifest) -> KubeManifestFields.Key? {
        KubeManifestFields.documents(text as NSString).flatMap(\.keys).filter { $0.name == name }.dropFirst(occurrence).first
    }

    func testEachKeysPath() throws {
        let documents = KubeManifestFields.documents(Self.manifest as NSString)
        XCTAssertEqual(documents.count, 2)
        XCTAssertEqual(documents[0].gvk, KubeGVK(group: "apps", version: "v1", kind: "Deployment"))
        XCTAssertEqual(documents[1].gvk, KubeGVK(group: "", version: "v1", kind: "ConfigMap"))
        XCTAssertEqual(key("replicas")?.path, ["spec", "replicas"])
        XCTAssertEqual(key("app")?.path, ["metadata", "labels", "app"])
        XCTAssertEqual(key("image")?.path, ["spec", "template", "spec", "containers", "[]", "image"], "a - item at its key's own indent")
        XCTAssertEqual(key("name", occurrence: 1)?.path, ["spec", "template", "spec", "containers", "[]", "name"])
        XCTAssertEqual(key("cpu")?.path, ["spec", "template", "spec", "containers", "[]", "resources", "limits", "cpu"])
        XCTAssertEqual(key("imag")?.path, ["spec", "template", "spec", "containers", "[]", "imag"], "the second item")
        XCTAssertEqual(key("strategy")?.path, ["spec", "strategy"], "back out of the list")
        XCTAssertEqual(key("type")?.path, ["spec", "strategy", "type"])
        XCTAssertEqual(key("nginx.conf")?.path, ["data", "nginx.conf"])
        XCTAssertNil(key("listen"), "a block scalar's text holds no keys")
        XCTAssertNil(key("server"))
        XCTAssertEqual(key("quoted.key")?.path, ["data", "quoted.key"])
        XCTAssertEqual(key("args")?.value, #"["--port", "80"]"#)
        let replicas = try XCTUnwrap(key("replicas"))
        XCTAssertEqual((Self.manifest as NSString).substring(with: replicas.range), "replicas")
    }

    func testListsOfMapsIndentedUnderTheirKey() {
        let text = """
            apiVersion: v1
            kind: Pod
            spec:
              containers:
                - name: a
                  ports:
                    - containerPort: 80
                      protocol: TCP
                - name: b
            """
        XCTAssertEqual(key("containerPort", in: text)?.path, ["spec", "containers", "[]", "ports", "[]", "containerPort"])
        XCTAssertEqual(key("protocol", in: text)?.path, ["spec", "containers", "[]", "ports", "[]", "protocol"])
        XCTAssertEqual(key("name", occurrence: 1, in: text)?.path, ["spec", "containers", "[]", "name"])
    }

    func testCommentsAndQuotedValuesAreNotKeys() {
        let text = """
            apiVersion: v1 # the core group
            kind: "ConfigMap"
            # note: not a key
            data:
              url: "http://example.com:8080/x"   # comment: here
              - odd
            """
        let documents = KubeManifestFields.documents(text as NSString)
        XCTAssertEqual(documents.first?.apiVersion, "v1")
        XCTAssertEqual(documents.first?.kind, "ConfigMap", "quotes taken off")
        XCTAssertNil(key("note", in: text))
        XCTAssertEqual(key("url", in: text)?.value, "\"http://example.com:8080/x\"")
    }

    func testTheKeyAtAnOffset() throws {
        let ns = Self.manifest as NSString
        let onKey = ns.range(of: "replicas").location + 3
        XCTAssertEqual(KubeManifestFields.key(at: onKey, in: ns)?.key.path, ["spec", "replicas"])
        let onValue = ns.range(of: "nginx:1.27").location + 2
        XCTAssertEqual(KubeManifestFields.key(at: onValue, in: ns)?.key.path, ["spec", "template", "spec", "containers", "[]", "image"], "its line's value")
        let second = ns.range(of: "web-config").location
        XCTAssertEqual(KubeManifestFields.key(at: second, in: ns)?.document.kind, "ConfigMap")
    }

    // MARK: Where a key typed goes

    func testASlotUnderAMap() throws {
        let text = "apiVersion: apps/v1\nkind: Deployment\nspec:\n  replicas: 1\n  rev"
        let slot = try XCTUnwrap(KubeManifestFields.slot(at: (text as NSString).length, in: text as NSString))
        XCTAssertEqual(slot.parent, ["spec"])
        XCTAssertEqual(slot.prefix, "rev")
        XCTAssertEqual(slot.siblings, ["replicas"])
        XCTAssertTrue(slot.atLineEnd)
        XCTAssertEqual(slot.document.kind, "Deployment")
        XCTAssertEqual((text as NSString).substring(with: slot.prefixRange), "rev")
    }

    func testASlotInAListItem() throws {
        let text = "apiVersion: v1\nkind: Pod\nspec:\n  containers:\n  - name: a\n    ima\n  - na\n"
        let ns = text as NSString
        let inItem = try XCTUnwrap(KubeManifestFields.slot(at: ns.range(of: "ima").location + 3, in: ns))
        XCTAssertEqual(inItem.parent, ["spec", "containers", "[]"])
        XCTAssertEqual(inItem.siblings, ["name"], "the item's own keys")
        let newItem = try XCTUnwrap(KubeManifestFields.slot(at: ns.range(of: "- na").location + 4, in: ns))
        XCTAssertEqual(newItem.parent, ["spec", "containers", "[]"])
        XCTAssertEqual(newItem.prefix, "na")
        XCTAssertEqual(newItem.siblings, [], "a new item has none yet")
        XCTAssertNil(KubeManifestFields.slot(at: ns.range(of: "name: a").location + 7, in: ns), "a value, not a key")
    }

    func testNoSlotInABlockScalar() {
        let text = "apiVersion: v1\nkind: ConfigMap\ndata:\n  conf: |\n    lis"
        XCTAssertNil(KubeManifestFields.slot(at: (text as NSString).length, in: text as NSString))
    }

    // MARK: Against the docs

    private func apps() throws -> KubeOpenAPIDocument { try KubeOpenAPIDocument.read(Data(KubeOpenAPITests.apps.utf8)) }

    func testUnknownFieldsAreMarkedAndOnlyThem() throws {
        let apps = try apps()
        let documents = KubeManifestFields.documents(Self.manifest as NSString)
        let marks = KubeManifestFields.marks(documents) { gvk in gvk.group == "apps" ? (apps, "fake-dev's API (v1.31.1)") : nil }
        XCTAssertEqual(marks.map { (Self.manifest as NSString).substring(with: $0.range) }, ["imag"])
        XCTAssertEqual(marks.first?.message, "Unknown field \"imag\" in Deployment.spec.template.spec.containers — fake-dev's API (v1.31.1) has no such field.")
        // A kind its document doesn't have, marked on its kind.
        let other = "apiVersion: apps/v1\nkind: StatefulSet\nspec:\n  x: 1\n"
        let none = KubeManifestFields.marks(KubeManifestFields.documents(other as NSString)) { _ in (apps, "fake-dev's API") }
        XCTAssertEqual(none, [KubeManifestFields.Mark(range: (other as NSString).range(of: "kind"), message: "fake-dev's API serves no StatefulSet at apps/v1.")])
        XCTAssertTrue(KubeManifestFields.marks(documents) { _ in nil }.isEmpty, "nothing cached, nothing said")
    }

    func testMarksAreBounded() throws {
        let apps = try apps()
        let many = "apiVersion: apps/v1\nkind: Deployment\nspec:\n" + (0..<(KubeManifestFields.maxMarks + 40)).map { "  bogus\($0): 1\n" }.joined()
        XCTAssertEqual(KubeManifestFields.marks(KubeManifestFields.documents(many as NSString)) { _ in (apps, "x") }.count, KubeManifestFields.maxMarks)
        XCTAssertTrue(KubeManifestFields.documents(String(repeating: "a: 1\n", count: KubeManifestFields.maxLines + 10) as NSString).isEmpty, "too long: not scanned")
    }

    func testCompletionOffersTheHoldersFieldsNotYetThere() throws {
        let apps = try apps()
        let text = "apiVersion: apps/v1\nkind: Deployment\nspec:\n  replicas: 1\n  te"
        let slot = try XCTUnwrap(KubeManifestFields.slot(at: (text as NSString).length, in: text as NSString))
        let gvk = try XCTUnwrap(slot.document.gvk)
        XCTAssertEqual(KubeManifestFields.candidates(slot, in: apps, gvk: gvk).map(\.name), ["template", "strategy"], "starts first, then by subsequence")
        let empty = "apiVersion: apps/v1\nkind: Deployment\nspec:\n  replicas: 1\n  "
        let all = try XCTUnwrap(KubeManifestFields.slot(at: (empty as NSString).length, in: empty as NSString))
        XCTAssertEqual(KubeManifestFields.candidates(all, in: apps, gvk: gvk).map(\.name), ["selector", "template", "strategy"], "required first, replicas there already")
        let item = "apiVersion: apps/v1\nkind: Deployment\nspec:\n  template:\n    spec:\n      containers:\n      - name: a\n        im"
        let inItem = try XCTUnwrap(KubeManifestFields.slot(at: (item as NSString).length, in: item as NSString))
        XCTAssertEqual(KubeManifestFields.candidates(inItem, in: apps, gvk: gvk).map(\.name), ["image"])
    }
}
