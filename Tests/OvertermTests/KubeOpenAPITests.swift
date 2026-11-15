import Foundation
import XCTest

@testable import Overterm

/// The cluster's own API docs (3.15), pure: `/openapi/v3`'s index and its
/// documents read from fixtures in the server's shape — a core group's,
/// whose fields are `allOf: [{$ref}]` chains, and a CRD's, whose schema is
/// inline — paths resolved through refs, allOf, arrays and maps, kubectl's
/// type names and its explain text, and the bounds.
final class KubeOpenAPITests: XCTestCase {
    /// `apps/v1`, trimmed from a 1.31 server's: the shared types it refers to included.
    static let apps = #"""
        {"openapi":"3.0.0","info":{"title":"Kubernetes","version":"v1.31.1"},"paths":{},
         "components":{"schemas":{
          "io.k8s.api.apps.v1.Deployment":{"description":"Deployment enables declarative updates for Pods and ReplicaSets.","type":"object",
            "properties":{
              "apiVersion":{"description":"APIVersion defines the versioned schema of this representation of an object.","type":"string"},
              "kind":{"description":"Kind is a string value representing the REST resource this object represents.","type":"string"},
              "metadata":{"allOf":[{"$ref":"#/components/schemas/io.k8s.apimachinery.pkg.apis.meta.v1.ObjectMeta"}],"default":{},"description":"Standard object's metadata."},
              "spec":{"allOf":[{"$ref":"#/components/schemas/io.k8s.api.apps.v1.DeploymentSpec"}],"default":{},"description":"Specification of the desired behavior of the Deployment."},
              "status":{"allOf":[{"$ref":"#/components/schemas/io.k8s.api.apps.v1.DeploymentStatus"}],"default":{},"description":"Most recently observed status of the Deployment."}},
            "x-kubernetes-group-version-kind":[{"group":"apps","kind":"Deployment","version":"v1"}]},
          "io.k8s.api.apps.v1.DeploymentSpec":{"description":"DeploymentSpec is the specification of the desired behavior of the Deployment.","type":"object","required":["selector","template"],
            "properties":{
              "replicas":{"description":"Number of desired pods. This is a pointer to distinguish between explicit zero and not specified. Defaults to 1.","type":"integer","format":"int32"},
              "selector":{"allOf":[{"$ref":"#/components/schemas/io.k8s.apimachinery.pkg.apis.meta.v1.LabelSelector"}],"description":"Label selector for pods."},
              "template":{"allOf":[{"$ref":"#/components/schemas/io.k8s.api.core.v1.PodTemplateSpec"}],"default":{},"description":"Template describes the pods that will be created."},
              "strategy":{"allOf":[{"$ref":"#/components/schemas/io.k8s.api.apps.v1.DeploymentStrategy"}],"default":{},"description":"The deployment strategy to use to replace existing pods with new ones."}}},
          "io.k8s.api.apps.v1.DeploymentStatus":{"description":"DeploymentStatus is the most recently observed status of the Deployment.","type":"object",
            "properties":{"replicas":{"description":"Total number of non-terminated pods targeted by this deployment.","type":"integer","format":"int32"}}},
          "io.k8s.api.apps.v1.DeploymentStrategy":{"description":"DeploymentStrategy describes how to replace existing pods with new ones.","type":"object",
            "properties":{
              "type":{"description":"Type of deployment.\n\nPossible enum values:\n - `\"Recreate\"`\n - `\"RollingUpdate\"`","type":"string","enum":["Recreate","RollingUpdate"]},
              "rollingUpdate":{"allOf":[{"$ref":"#/components/schemas/io.k8s.api.apps.v1.RollingUpdateDeployment"}],"description":"Rolling update config params."}}},
          "io.k8s.api.apps.v1.RollingUpdateDeployment":{"description":"Spec to control the desired behavior of rolling update.","type":"object",
            "properties":{"maxSurge":{"allOf":[{"$ref":"#/components/schemas/io.k8s.apimachinery.pkg.util.intstr.IntOrString"}],"description":"The maximum number of pods that can be scheduled above the desired number of pods."}}},
          "io.k8s.api.core.v1.PodTemplateSpec":{"description":"PodTemplateSpec describes the data a pod should have when created from a template","type":"object",
            "properties":{
              "metadata":{"allOf":[{"$ref":"#/components/schemas/io.k8s.apimachinery.pkg.apis.meta.v1.ObjectMeta"}],"default":{},"description":"Standard object's metadata."},
              "spec":{"allOf":[{"$ref":"#/components/schemas/io.k8s.api.core.v1.PodSpec"}],"default":{},"description":"Specification of the desired behavior of the pod."}}},
          "io.k8s.api.core.v1.PodSpec":{"description":"PodSpec is a description of a pod.","type":"object","required":["containers"],
            "properties":{
              "containers":{"description":"List of containers belonging to the pod.","type":"array","items":{"allOf":[{"$ref":"#/components/schemas/io.k8s.api.core.v1.Container"}],"default":{}},
                "x-kubernetes-list-map-keys":["name"],"x-kubernetes-list-type":"map","x-kubernetes-patch-merge-key":"name"},
              "nodeSelector":{"description":"NodeSelector is a selector which must be true for the pod to fit on a node.","type":"object","additionalProperties":{"type":"string","default":""}}}},
          "io.k8s.api.core.v1.Container":{"description":"A single application container that you want to run within a pod.","type":"object","required":["name"],
            "properties":{
              "name":{"description":"Name of the container specified as a DNS_LABEL.","type":"string","default":""},
              "image":{"description":"Container image name.","type":"string"},
              "args":{"description":"Arguments to the entrypoint.","type":"array","items":{"type":"string","default":""}},
              "resources":{"allOf":[{"$ref":"#/components/schemas/io.k8s.api.core.v1.ResourceRequirements"}],"default":{},"description":"Compute Resources required by this container."}}},
          "io.k8s.api.core.v1.ResourceRequirements":{"description":"ResourceRequirements describes the compute resource requirements.","type":"object",
            "properties":{"limits":{"description":"Limits describes the maximum amount of compute resources allowed.","type":"object","additionalProperties":{"allOf":[{"$ref":"#/components/schemas/io.k8s.apimachinery.pkg.api.resource.Quantity"}]}}}},
          "io.k8s.apimachinery.pkg.api.resource.Quantity":{"description":"Quantity is a fixed-point representation of a number.","type":"string"},
          "io.k8s.apimachinery.pkg.util.intstr.IntOrString":{"description":"IntOrString is a type that can hold an int32 or a string.","type":"string","format":"int-or-string"},
          "io.k8s.apimachinery.pkg.apis.meta.v1.LabelSelector":{"description":"A label selector is a label query over a set of resources.","type":"object",
            "properties":{"matchLabels":{"description":"matchLabels is a map of {key,value} pairs.","type":"object","additionalProperties":{"type":"string","default":""}}},
            "x-kubernetes-map-type":"atomic"},
          "io.k8s.apimachinery.pkg.apis.meta.v1.ObjectMeta":{"description":"ObjectMeta is metadata that all persisted resources must have.","type":"object",
            "properties":{
              "name":{"description":"Name must be unique within a namespace.","type":"string"},
              "labels":{"description":"Map of string keys and values that can be used to organize and categorize (scope and select) objects.","type":"object","additionalProperties":{"type":"string","default":""}},
              "creationTimestamp":{"allOf":[{"$ref":"#/components/schemas/io.k8s.apimachinery.pkg.apis.meta.v1.Time"}],"description":"CreationTimestamp is a timestamp."}}},
          "io.k8s.apimachinery.pkg.apis.meta.v1.Time":{"description":"Time is a wrapper around time.Time.","type":"string","format":"date-time"}
         }}}
        """#

    /// A CRD's document (`stable.example.com/v1`): its schema inline, as the apiserver builds it.
    static let crd = #"""
        {"openapi":"3.0.0","info":{"title":"Kubernetes CRD Swagger","version":"v0.1.0"},"paths":{},
         "components":{"schemas":{
          "com.example.stable.v1.CronTab":{"type":"object",
            "properties":{
              "apiVersion":{"description":"APIVersion defines the versioned schema of this representation of an object.","type":"string"},
              "kind":{"description":"Kind is a string value representing the REST resource this object represents.","type":"string"},
              "metadata":{"allOf":[{"$ref":"#/components/schemas/io.k8s.apimachinery.pkg.apis.meta.v1.ObjectMeta"}],"description":"Standard object's metadata."},
              "spec":{"type":"object","description":"What the CronTab runs, and when.","required":["cronSpec"],
                "properties":{
                  "cronSpec":{"type":"string","description":"The schedule, in cron's own words."},
                  "replicas":{"x-kubernetes-int-or-string":true,"anyOf":[{"type":"integer"},{"type":"string"}],"description":"How many run at once."},
                  "selector":{"type":"object","additionalProperties":{"type":"string"}},
                  "template":{"type":"object","x-kubernetes-preserve-unknown-fields":true,"description":"Anything: the controller reads it."},
                  "jobs":{"type":"array","items":{"type":"object","properties":{"name":{"type":"string","description":"The job's name."}}}}}}},
            "x-kubernetes-group-version-kind":[{"group":"stable.example.com","kind":"CronTab","version":"v1"}]},
          "io.k8s.apimachinery.pkg.apis.meta.v1.ObjectMeta":{"description":"ObjectMeta is metadata that all persisted resources must have.","type":"object",
            "properties":{"name":{"description":"Name must be unique within a namespace.","type":"string"}}}
         }}}
        """#

    static let deployment = KubeGVK(group: "apps", version: "v1", kind: "Deployment")
    static let cronTab = KubeGVK(group: "stable.example.com", version: "v1", kind: "CronTab")

    private func document(_ text: String) throws -> KubeOpenAPIDocument { try KubeOpenAPIDocument.read(Data(text.utf8)) }

    private func found(_ document: KubeOpenAPIDocument, _ gvk: KubeGVK, _ path: [String], file: StaticString = #filePath, line: UInt = #line) throws
        -> KubeFieldDoc
    {
        guard case .found(let doc) = document.lookup(gvk, path) else {
            XCTFail("\(path) wasn't found: \(document.lookup(gvk, path))", file: file, line: line)
            throw KubeOpenAPIProblem("not found")
        }
        return doc
    }

    // MARK: The index

    func testTheIndexNamesEachGroupVersionsDocument() throws {
        let index = try KubeOpenAPIIndex.read(
            Data(
                #"{"paths":{"api/v1":{"serverRelativeURL":"/openapi/v3/api/v1?hash=AB12"},"apis/apps/v1":{"serverRelativeURL":"/openapi/v3/apis/apps/v1?hash=CD34"}}}"#
                    .utf8))
        XCTAssertEqual(index.url(for: Self.deployment), "/openapi/v3/apis/apps/v1?hash=CD34")
        XCTAssertEqual(index.url(for: KubeGVK(group: "", version: "v1", kind: "Pod")), "/openapi/v3/api/v1?hash=AB12")
        XCTAssertNil(index.url(for: Self.cronTab))
        XCTAssertEqual(KubeOpenAPIIndex.key(group: "", version: "v1"), "api/v1")
        XCTAssertEqual(KubeOpenAPIIndex.key(group: "apps", version: "v1"), "apis/apps/v1")
    }

    func testOnlyTheServersOwnDocumentPathsAreFollowed() throws {
        XCTAssertEqual(KubeOpenAPIIndex.safe("/openapi/v3/apis/apps/v1?hash=AB"), "/openapi/v3/apis/apps/v1?hash=AB")
        for refused in [
            "https://evil.example.com/openapi/v3/api/v1", "//evil.example.com/openapi/v3/x", "/api/v1/namespaces/shop/pods/p/exec",
            "/openapi/v3/../api/v1/namespaces/shop/pods/p/proxy", "/openapi/v3/%2e%2e/api/v1/pods", "/openapi/v3/apis/./x", "/openapi/v3/api v1",
            "/openapi/v3/a#frag", "/openapi/v3/a\\b",
        ] {
            XCTAssertNil(KubeOpenAPIIndex.safe(refused), refused)
        }
        let index = try KubeOpenAPIIndex.read(
            Data(#"{"paths":{"api/v1":{"serverRelativeURL":"/api/v1/namespaces/shop/services/web:80/proxy/"},"apis/apps/v1":{"serverRelativeURL":"/openapi/v3/apis/apps/v1"}}}"#.utf8))
        XCTAssertEqual(index.paths, ["apis/apps/v1": "/openapi/v3/apis/apps/v1"], "an entry pointing anywhere else is dropped")
    }

    func testTheIndexIsBounded() {
        XCTAssertThrowsError(try KubeOpenAPIIndex.read(Data(repeating: 32, count: KubeOpenAPIIndex.maxBytes + 1)))
        XCTAssertThrowsError(try KubeOpenAPIIndex.read(Data(#"{"kind":"Status"}"#.utf8)), "not the index")
        var paths: [String: Any] = [:]
        for index in 0..<(KubeOpenAPIIndex.maxPaths + 50) { paths["apis/g\(index).example.com/v1"] = ["serverRelativeURL": "/openapi/v3/apis/g\(index).example.com/v1"] }
        let data = try? JSONSerialization.data(withJSONObject: ["paths": paths])
        XCTAssertEqual(try data.map { try KubeOpenAPIIndex.read($0) }?.paths.count, KubeOpenAPIIndex.maxPaths)
    }

    // MARK: Paths through refs and allOf

    func testAFieldResolvesThroughAllOfRefs() throws {
        let apps = try document(Self.apps)
        XCTAssertEqual(apps.kinds[Self.deployment], "io.k8s.api.apps.v1.Deployment")
        let replicas = try found(apps, Self.deployment, ["spec", "replicas"])
        XCTAssertEqual(replicas.type, "integer")
        XCTAssertTrue(replicas.description.hasPrefix("Number of desired pods."), replicas.description)
        XCTAssertFalse(replicas.required)
        XCTAssertEqual(replicas.spokenPath, "Deployment.spec.replicas")
        let spec = try found(apps, Self.deployment, ["spec"])
        XCTAssertEqual(spec.type, "DeploymentSpec")
        XCTAssertEqual(spec.description, "Specification of the desired behavior of the Deployment.", "the field's own words before its type's")
        XCTAssertEqual(spec.fields.map(\.name), ["replicas", "selector", "strategy", "template"])
        XCTAssertEqual(spec.fields.filter(\.required).map(\.name), ["selector", "template"])
        XCTAssertEqual(try found(apps, Self.deployment, ["spec", "template"]).required, true)
    }

    func testArraysAreSteppedIntoByNameOrByItem() throws {
        let apps = try document(Self.apps)
        let byName = try found(apps, Self.deployment, ["spec", "template", "spec", "containers", "image"])
        let byItem = try found(apps, Self.deployment, ["spec", "template", "spec", "containers", "[]", "image"])
        XCTAssertEqual(byName, byItem)
        XCTAssertEqual(byName.type, "string")
        XCTAssertEqual(byName.description, "Container image name.")
        XCTAssertEqual(byName.path, ["spec", "template", "spec", "containers", "image"], "no [] in what is said")
        let containers = try found(apps, Self.deployment, ["spec", "template", "spec", "containers"])
        XCTAssertEqual(containers.type, "[]Container")
        XCTAssertTrue(containers.required)
        XCTAssertEqual(containers.fields.map(\.name), ["args", "image", "name", "resources"], "an array's items' fields")
        XCTAssertEqual(try found(apps, Self.deployment, ["spec", "template", "spec", "containers", "args"]).type, "[]string")
    }

    func testKubectlsTypeNames() throws {
        let apps = try document(Self.apps)
        let types = Dictionary(uniqueKeysWithValues: try found(apps, Self.deployment, ["spec"]).fields.map { ($0.name, $0.type) })
        XCTAssertEqual(types, ["replicas": "integer", "selector": "LabelSelector", "strategy": "DeploymentStrategy", "template": "PodTemplateSpec"])
        XCTAssertEqual(try found(apps, Self.deployment, ["metadata", "labels"]).type, "map[string]string")
        XCTAssertEqual(try found(apps, Self.deployment, ["metadata", "creationTimestamp"]).type, "string", "Time is a string")
        XCTAssertEqual(try found(apps, Self.deployment, ["spec", "strategy", "rollingUpdate", "maxSurge"]).type, "IntOrString")
        XCTAssertEqual(try found(apps, Self.deployment, ["spec", "template", "spec", "containers", "resources", "limits"]).type, "map[string]Quantity")
        XCTAssertEqual(try found(apps, Self.deployment, ["spec", "strategy", "type"]).enumValues, ["Recreate", "RollingUpdate"])
    }

    func testAMapsKeysAreAnyName() throws {
        let apps = try document(Self.apps)
        let label = try found(apps, Self.deployment, ["metadata", "labels", "app.kubernetes.io/name"])
        XCTAssertEqual(label.type, "string")
        XCTAssertEqual(try found(apps, Self.deployment, ["spec", "template", "spec", "nodeSelector", "disktype"]).type, "string")
    }

    func testAnUnknownFieldSaysWhereItStops() throws {
        let apps = try document(Self.apps)
        XCTAssertEqual(apps.lookup(Self.deployment, ["spec", "replicaz"]), .unknown(index: 1, parent: "Deployment.spec"))
        XCTAssertEqual(
            apps.lookup(Self.deployment, ["spec", "template", "spec", "containers", "[]", "imag"]),
            .unknown(index: 5, parent: "Deployment.spec.template.spec.containers"))
        XCTAssertEqual(apps.lookup(Self.deployment, ["spec", "replicas", "x"]), .unknown(index: 2, parent: "Deployment.spec.replicas"), "an integer has no fields")
        XCTAssertEqual(apps.lookup(Self.deployment, ["nope"]), .unknown(index: 0, parent: "Deployment"))
        XCTAssertEqual(apps.lookup(KubeGVK(group: "apps", version: "v1", kind: "StatefulSet"), ["spec"]), .noKind)
    }

    func testTheKindItselfIsAnEmptyPath() throws {
        let doc = try found(try document(Self.apps), Self.deployment, [])
        XCTAssertEqual(doc.description, "Deployment enables declarative updates for Pods and ReplicaSets.")
        XCTAssertEqual(doc.fields.map(\.name), ["apiVersion", "kind", "metadata", "spec", "status"])
        XCTAssertEqual(doc.name, "Deployment")
    }

    // MARK: A CRD's inline schema

    func testACRDsInlineSchema() throws {
        let crd = try document(Self.crd)
        let spec = try found(crd, Self.cronTab, ["spec"])
        XCTAssertEqual(spec.type, "Object")
        XCTAssertEqual(spec.description, "What the CronTab runs, and when.")
        XCTAssertEqual(spec.fields.map(\.name), ["cronSpec", "jobs", "replicas", "selector", "template"])
        XCTAssertEqual(spec.fields.first { $0.name == "cronSpec" }?.required, true)
        XCTAssertEqual(try found(crd, Self.cronTab, ["spec", "replicas"]).type, "IntOrString")
        XCTAssertEqual(try found(crd, Self.cronTab, ["spec", "selector"]).type, "map[string]string")
        XCTAssertEqual(try found(crd, Self.cronTab, ["spec", "jobs"]).type, "[]Object")
        XCTAssertEqual(try found(crd, Self.cronTab, ["spec", "jobs", "name"]).description, "The job's name.")
        XCTAssertEqual(crd.lookup(Self.cronTab, ["spec", "template", "anything", "at", "all"]), .opaque, "preserve-unknown takes anything")
        XCTAssertEqual(crd.lookup(Self.cronTab, ["spec", "cronspec"]), .unknown(index: 1, parent: "CronTab.spec"))
        XCTAssertTrue(try found(crd, Self.cronTab, ["spec", "template"]).opaque)
    }

    // MARK: Bounds

    func testASelfReferringSchemaEnds() throws {
        let text = #"""
            {"components":{"schemas":{
              "io.k8s.apiextensions.v1.JSONSchemaProps":{"type":"object","description":"JSONSchemaProps is a JSON-Schema.",
                "properties":{"items":{"allOf":[{"$ref":"#/components/schemas/io.k8s.apiextensions.v1.JSONSchemaProps"}]},
                  "properties":{"type":"object","additionalProperties":{"allOf":[{"$ref":"#/components/schemas/io.k8s.apiextensions.v1.JSONSchemaProps"}]}}},
                "allOf":[{"$ref":"#/components/schemas/io.k8s.apiextensions.v1.JSONSchemaProps"}],
                "x-kubernetes-group-version-kind":[{"group":"apiextensions.k8s.io","kind":"JSONSchemaProps","version":"v1"}]}}}}
            """#
        let doc = try document(text)
        let gvk = KubeGVK(group: "apiextensions.k8s.io", version: "v1", kind: "JSONSchemaProps")
        let deep = Array(repeating: "items", count: 20)
        XCTAssertNotNil(try found(doc, gvk, deep))
        XCTAssertEqual(doc.lookup(gvk, Array(repeating: "items", count: KubeOpenAPIDocument.maxPath + 1)), .opaque, "a path deeper than followed")
        XCTAssertEqual(try found(doc, gvk, ["properties"]).type, "map[string]JSONSchemaProps")
    }

    func testADocumentIsBoundedAsItIsRead() throws {
        XCTAssertThrowsError(try KubeOpenAPIDocument.read(Data(repeating: 32, count: KubeOpenAPIDocument.maxBytes + 1))) { error in
            XCTAssertEqual((error as? KubeOpenAPIProblem)?.message, "The cluster's document is over 32 MB: too much to read here.")
        }
        XCTAssertThrowsError(try KubeOpenAPIDocument.read(Data("not json".utf8)))
        var budget = 3
        let wide: [String: Any] = ["type": "object", "properties": ["a": ["type": "string"], "b": ["type": "string"], "c": ["type": "string"]]]
        XCTAssertThrowsError(try KubeOpenAPIDocument.parse(wide, depth: 0, budget: &budget), "more nodes than the budget")
        // Deeper than maxDepth: taken as saying nothing of its fields, not read on.
        var nested: [String: Any] = ["type": "string"]
        for _ in 0..<(KubeOpenAPIDocument.maxDepth + 10) { nested = ["type": "object", "properties": ["x": nested]] }
        var enough = 10_000
        let parsed = try KubeOpenAPIDocument.parse(nested, depth: 0, budget: &enough)
        XCTAssertGreaterThan(enough, 10_000 - KubeOpenAPIDocument.maxDepth - 5)
        var node = parsed
        var depth = 0
        while let next = node.properties["x"] {
            node = next
            depth += 1
        }
        XCTAssertEqual(depth, KubeOpenAPIDocument.maxDepth)
        XCTAssertTrue(node.preservesUnknown)
    }

    func testARefToAnotherDocumentIsNotFollowed() {
        XCTAssertNil(KubeOpenAPIDocument.refName("https://example.com/schema.json#/x"))
        XCTAssertNil(KubeOpenAPIDocument.refName("#/definitions/x"))
        XCTAssertEqual(KubeOpenAPIDocument.refName("#/components/schemas/io.k8s.api.core.v1.Pod"), "io.k8s.api.core.v1.Pod")
    }

    // MARK: kubectl explain

    func testExplainsQuery() throws {
        XCTAssertEqual(try KubeExplain.parse(" deployment.spec.replicas "), KubeExplain.Query(resource: "deployment", path: ["spec", "replicas"]))
        XCTAssertEqual(try KubeExplain.parse("po"), KubeExplain.Query(resource: "po", path: []))
        for bad in ["", "deployment..spec", "deployment.spec.", "deploy ment"] { XCTAssertThrowsError(try KubeExplain.parse(bad), bad) }
        XCTAssertThrowsError(try KubeExplain.parse("deploy." + Array(repeating: "a", count: 40).joined(separator: ".")))
    }

    func testExplainsTextIsKubectls() throws {
        let replicas = try found(try document(Self.apps), Self.deployment, ["spec", "replicas"])
        let text = KubeExplain.text(replicas)
        XCTAssertTrue(text.hasPrefix("GROUP:      apps\nKIND:       Deployment\nVERSION:    v1\n\nFIELD: replicas <integer>\n\nDESCRIPTION:\n    Number of desired pods."), text)
        let spec = KubeExplain.text(try found(try document(Self.apps), Self.deployment, ["spec"]))
        XCTAssertTrue(spec.contains("FIELD: spec <DeploymentSpec>"), spec)
        XCTAssertTrue(spec.contains("FIELDS:\n  replicas\t<integer>\n    Number of desired pods."), spec)
        XCTAssertTrue(spec.contains("  template\t<PodTemplateSpec> -required-"), spec)
        let core = KubeExplain.text(try found(try document(Self.apps), Self.deployment, []))
        XCTAssertFalse(core.contains("FIELD:"), "the kind itself has no FIELD line")
        XCTAssertEqual(
            KubeExplain.kubectl("deployment.spec.replicas", context: "fake-dev", apiVersion: "apps/v1"),
            "kubectl explain deployment.spec.replicas --context fake-dev --api-version apps/v1")
        XCTAssertEqual(KubeExplain.kubectl("po", context: "acme dev", apiVersion: nil), "kubectl explain po --context 'acme dev'")
    }

    func testAHoversWords() throws {
        let replicas = try found(try document(Self.apps), Self.deployment, ["spec", "replicas"])
        let text = KubeExplain.hover(replicas, source: "fake-dev's API (v1.31.1)")
        XCTAssertTrue(text.hasPrefix("**replicas** `<integer>`\nDeployment.spec.replicas · apps/v1 · fake-dev's API (v1.31.1)\n\nNumber of desired pods."), text)
        let spec = KubeExplain.hover(try found(try document(Self.apps), Self.deployment, ["spec"]), source: "x")
        XCTAssertTrue(spec.contains("Fields: replicas, selector*, strategy, template*"), spec)
    }

    func testAGVKFromAManifest() {
        XCTAssertEqual(KubeGVK(apiVersion: "apps/v1", kind: "Deployment"), Self.deployment)
        XCTAssertEqual(KubeGVK(apiVersion: "v1", kind: "Pod")?.group, "")
        XCTAssertNil(KubeGVK(apiVersion: "apps/", kind: "Deployment"))
        XCTAssertNil(KubeGVK(apiVersion: "a/b/c", kind: "X"))
        XCTAssertNil(KubeGVK(apiVersion: "v1", kind: ""))
    }
}
