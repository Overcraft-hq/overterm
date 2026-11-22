import Foundation
import XCTest

@testable import Overterm
@testable import OvertermCore

/// An Argo CD app read from marks, its detail (docs/design/kubernetes/
/// gitops.md, 14.2.3, D4). Pure: the tree — each workload's children under
/// it by their owner references, the newest ReplicaSet and any still
/// running one, a copy of a member's mark a child and never a member,
/// pods with their own health and never counted, hooks apart,
/// `ignore-healthcheck` not counted, an Argo Rollout's Deployment "scaled
/// by its Rollout" and promote and abort Argo Rollouts' — not here; the
/// members settled by what the detail read; what only the Application
/// knows as fixed rows in the mode's words; hints as text; the lists by
/// each workload's own selector in its own namespace; the children reader
/// keeping its allow-list (the sentinel); a pod's and a ReplicaSet's
/// health by Argo CD's rule from their rows; the apply's and a write's
/// "may undo". Against the fake spoke (M4): only GETs — its members'
/// objects whose rule reads them, at most 50, 4 in flight, then its
/// workloads' ReplicaSets and pods by their selectors, as Table rows —,
/// never a watch, a Secret, a ConfigMap or a write; shown again within
/// 30 s, nothing read; no discovery, no request.
@MainActor
final class KubeMarkedAppDetailTests: XCTestCase {
    typealias Status = KubeMarkedHealth.Status
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    nonisolated(unsafe) private var fakes: [FakeKubeAPI] = []

    override func tearDown() {
        for api in fakes {
            XCTAssertEqual(api.requests.filter { $0.method != "GET" }, [], "only GETs")
            XCTAssertEqual(api.writes.count, 0, "nothing written")
            let paths = api.requests.map(\.path)
            XCTAssertFalse(paths.contains { $0.contains("/secrets") || $0.contains("/configmaps") }, "never a Secret or a ConfigMap")
            XCTAssertFalse(api.requests.contains(where: \.isWatch), "never a watch")
            api.stop()
        }
        fakes = []
    }

    // MARK: Fixtures

    private func marks(_ app: String, _ groupKind: String, _ namespace: String, _ name: String) -> KubeMarkWire {
        var wire = KubeMarkWire()
        wire.tracking = .own(KubeTrackingID.parse("\(app):\(groupKind):\(namespace)/\(name)")!)
        return wire
    }

    private func member(
        _ kind: KubeMarkedKind, _ name: String, app: String, namespace: String = "team-2", _ status: Status?, _ sentence: String, fromRow: Bool = false,
        scaledToZero: Bool = false, images: [String] = []
    ) -> KubeMarkedMember {
        let groupKind = kind.group.isEmpty ? "/\(kind.kind)" : "\(kind.group)/\(kind.kind)"
        return KubeMarkedMember(
            id: .init(kind: kind, namespace: namespace, name: name), marks: marks(app, groupKind, namespace, name),
            health: .init(status: status, sentence: sentence, fromRow: fromRow, scaledToZero: scaledToZero), images: images, created: now.addingTimeInterval(-3600))
    }

    private func ranked(_ members: [KubeMarkedMember], instance: String, copies: [KubeMarkedMember] = []) -> KubeMarkedRanked {
        let app = KubeMarkedApp.make(key: .init(installation: "", instance: instance), members, copies: copies)!
        return KubeMarkedRanked(app: app, health: app.health)
    }

    private func child(
        _ kind: KubeMarkedAppDetail.Child.Kind, _ name: String, owner: (String, String)?, namespace: String = "team-2", _ status: Status?, _ sentence: String,
        replicas: Int? = nil, ago: TimeInterval = 600, copied: KubeTrackingID? = nil
    ) -> KubeMarkedAppDetail.Child {
        KubeMarkedAppDetail.Child(
            kind: kind, namespace: namespace, name: name, created: now.addingTimeInterval(-ago), owner: owner.map { .init(kind: $0.0, name: $0.1) }, copied: copied,
            health: .init(status: status, sentence: sentence, fromRow: true), replicas: replicas)
    }

    private static let cart = "prod-team-2-acme-cart-service"

    /// The stalled app: a Deployment past its deadline, its rollout stuck —
    /// the new ReplicaSet's pod crash-looping, the old one's serving — and
    /// an old ReplicaSet at 0.
    private func stalled() -> (KubeMarkedRanked, KubeMarkedAppDetail.Read) {
        let app = ranked(
            [
                member(.deployment, "acme-cart", app: Self.cart, .degraded, "rollout stalled (ProgressDeadlineExceeded)"),
                member(.service, "acme-cart", app: Self.cart, .healthy, "service"),
            ], instance: Self.cart)
        let copy = KubeTrackingID.parse("\(Self.cart):apps/Deployment:team-2/acme-cart")
        var read = KubeMarkedAppDetail.Read()
        read.children = [
            child(.replicaSet, "acme-cart-5f8d7c", owner: ("Deployment", "acme-cart"), .progressing, "0/1 ready", replicas: 1, ago: 900, copied: copy),
            child(.replicaSet, "acme-cart-7d4b9c", owner: ("Deployment", "acme-cart"), .healthy, "1/1 ready", replicas: 1, ago: 86_400, copied: copy),
            child(.replicaSet, "acme-cart-6a5b4c", owner: ("Deployment", "acme-cart"), .healthy, "scaled to 0", replicas: 0, ago: 172_800, copied: copy),
            child(.pod, "acme-cart-5f8d7c-x2k9p", owner: ("ReplicaSet", "acme-cart-5f8d7c"), .degraded, "CrashLoopBackOff"),
            child(.pod, "acme-cart-7d4b9c-m4n8q", owner: ("ReplicaSet", "acme-cart-7d4b9c"), .healthy, "1/1 ready"),
            // Another workload's pod, matched by a looser selector: never under it.
            child(.pod, "acme-cartographer-1", owner: ("ReplicaSet", "acme-cartographer-9"), .healthy, "1/1 ready"),
            // Another namespace's: never.
            child(.pod, "acme-cart-5f8d7c-zzzzz", owner: ("ReplicaSet", "acme-cart-5f8d7c"), namespace: "team-3", .degraded, "CrashLoopBackOff"),
        ]
        return (app, read)
    }

    // MARK: The tree

    func testEachWorkloadsChildrenHangUnderItByTheirOwners() throws {
        let (app, read) = stalled()
        let detail = KubeMarkedAppDetail.make(app, read: read, mode: .only(.notServed), context: "fake-prod")
        let deployment = try XCTUnwrap(detail.tree.first { $0.kind == "Deployment" })
        XCTAssertEqual(deployment.role, .member)
        XCTAssertEqual(deployment.said(namespaced: false), "Deployment acme-cart — Degraded: rollout stalled (ProgressDeadlineExceeded)")
        // The newest ReplicaSet, and the old one still serving; the one at 0 folded.
        XCTAssertEqual(deployment.children.map(\.name), ["acme-cart-5f8d7c", "acme-cart-7d4b9c"])
        XCTAssertEqual(deployment.more, "1 older ReplicaSet, scaled to 0")
        let newest = deployment.children[0]
        XCTAssertEqual(newest.role, .owned)
        XCTAssertEqual(newest.status, .progressing)
        XCTAssertEqual(newest.note, "a copy of Deployment acme-cart's mark: not a member", "a copied mark: a child, never a member")
        XCTAssertEqual(newest.children.map(\.name), ["acme-cart-5f8d7c-x2k9p"], "only its own pods, in its namespace")
        XCTAssertEqual(newest.children.first?.said(namespaced: false), "Pod acme-cart-5f8d7c-x2k9p — Degraded: CrashLoopBackOff")
        XCTAssertEqual(deployment.children[1].children.map(\.name), ["acme-cart-7d4b9c-m4n8q"])
        XCTAssertFalse(detail.tree.flatMap(\.all).contains { $0.name.hasPrefix("acme-cartographer") || $0.name == "acme-cart-5f8d7c-zzzzz" })
        // Pods aren't counted: the app's word is its members'.
        XCTAssertEqual(detail.word, "Failed")
        XCTAssertEqual(detail.why, app.health.why)
        // Nothing past a pod: a pod's verbs are its own list's.
        XCTAssertTrue(detail.tree.flatMap(\.all).filter { $0.kind == "Pod" }.allSatisfy { $0.children.isEmpty })
    }

    /// A workload's object with its own selector, as a GET says it.
    private func object(_ name: String, namespace: String = "team-2", selector: [String: Any]) -> KubeMarkedSettled {
        KubeMarkedSettled(
            KubeMarkedHealthTests.wire(["apiVersion": "apps/v1", "kind": "Deployment", "metadata": ["name": name, "namespace": namespace], "spec": ["selector": selector]]),
            at: now)
    }

    /// Two workloads whose selectors overlap — `app=acme-web`, and
    /// `app=acme-web,track=canary` —: the wider one's lists hold the
    /// narrower one's ReplicaSet and pod too. Each is kept once, drawn once
    /// under its owner, its pods counted once, every node's id its own.
    func testOverlappingSelectorsKeepEachObjectOnce() throws {
        let instance = "prod-team-2-acme-web-service"
        let app = ranked(
            [member(.deployment, "acme-web", app: instance, .healthy, "2/2"), member(.deployment, "acme-web-canary", app: instance, .healthy, "1/1")],
            instance: instance)
        let objects = [
            KubeMarkedMember.ID(kind: .deployment, namespace: "team-2", name: "acme-web"): object("acme-web", selector: ["matchLabels": ["app": "acme-web"]]),
            KubeMarkedMember.ID(kind: .deployment, namespace: "team-2", name: "acme-web-canary"): object(
                "acme-web-canary", selector: ["matchLabels": ["app": "acme-web", "track": "canary"]]),
        ]
        XCTAssertEqual(
            KubeMarkedAppDetail.lists(app.app, objects: objects).map { "\($0.what.rawValue) \($0.selector ?? "-")" },
            ["ReplicaSet app=acme-web", "Pod app=acme-web", "ReplicaSet app=acme-web,track=canary", "Pod app=acme-web,track=canary"], "two selectors: two lists each")
        let wide = [
            child(.replicaSet, "acme-web-7d4b9c", owner: ("Deployment", "acme-web"), .healthy, "2/2 ready", replicas: 2),
            child(.replicaSet, "acme-web-canary-5f8d7c", owner: ("Deployment", "acme-web-canary"), .healthy, "1/1 ready", replicas: 1),
            child(.pod, "acme-web-7d4b9c-a1b2c", owner: ("ReplicaSet", "acme-web-7d4b9c"), .healthy, "1/1 ready"),
            child(.pod, "acme-web-7d4b9c-d3e4f", owner: ("ReplicaSet", "acme-web-7d4b9c"), .healthy, "1/1 ready"),
            child(.pod, "acme-web-canary-5f8d7c-g5h6i", owner: ("ReplicaSet", "acme-web-canary-5f8d7c"), .healthy, "1/1 ready"),
        ]
        let narrow = [
            child(.replicaSet, "acme-web-canary-5f8d7c", owner: ("Deployment", "acme-web-canary"), .healthy, "1/1 ready", replicas: 1),
            child(.pod, "acme-web-canary-5f8d7c-g5h6i", owner: ("ReplicaSet", "acme-web-canary-5f8d7c"), .healthy, "1/1 ready"),
        ]
        XCTAssertEqual(KubeMarkedAppDetail.unique(wide + narrow).map(\.name), wide.map(\.name), "each object once, as the first list found it")
        // Both lists' answers as they came, one after the other.
        var read = KubeMarkedAppDetail.Read()
        read.children = wide + narrow
        let detail = KubeMarkedAppDetail.make(app, read: read, mode: .only(.notServed), context: "fake-prod", bounds: .init(podsShown: 1))
        let canary = try XCTUnwrap(detail.tree.first { $0.name == "acme-web-canary" })
        XCTAssertEqual(canary.children.map(\.name), ["acme-web-canary-5f8d7c"], "its ReplicaSet once")
        XCTAssertEqual(canary.children.first?.children.map(\.name), ["acme-web-canary-5f8d7c-g5h6i"], "its pod once")
        XCTAssertNil(canary.children.first?.more, "no pod counted twice")
        XCTAssertEqual(detail.tree.first { $0.name == "acme-web" }?.children.first?.more, "1 more pod")
        let ids = KubeMarkedAppDetailView.rows(detail.tree).map(\.node.id) + detail.hooks.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "every node's id its own: \(ids)")
    }

    /// An app across two namespaces with a Deployment of one name in each:
    /// its hints, images and notes name each one's namespace — no two lines
    /// alike —; in one namespace, the name alone as before.
    func testHintsImagesAndNotesSayTheNamespaceWhereTheAppSpansSeveral() {
        let instance = "prod-team-1-acme-api-service"
        let image = "registry.acme.example/acme-api:4.12.0"
        var first = member(.deployment, "acme-api", app: instance, namespace: "team-1", .healthy, "2/2", images: [image])
        first.marks.syncWave = "1"
        var second = member(.deployment, "acme-api", app: instance, namespace: "team-2", .healthy, "2/2", images: [image])
        second.marks.syncWave = "1"
        var read = KubeMarkedAppDetail.Read()
        read.unread = [first.id: "forbidden", second.id: "forbidden"]
        let detail = KubeMarkedAppDetail.make(ranked([first, second], instance: instance), read: read, mode: .only(.notServed), context: "fake-prod")
        XCTAssertTrue(detail.namespaced)
        XCTAssertEqual(detail.hints, ["sync-wave 1 — Deployment team-1/acme-api", "sync-wave 1 — Deployment team-2/acme-api"])
        XCTAssertEqual(detail.images, ["\(image) — Deployment team-1/acme-api, Deployment team-2/acme-api"])
        XCTAssertEqual(
            detail.notes, ["Deployment team-1/acme-api: not read — forbidden; from its row", "Deployment team-2/acme-api: not read — forbidden; from its row"])
        let one = KubeMarkedAppDetail.make(ranked([first], instance: instance), mode: .only(.notServed), context: "fake-prod")
        XCTAssertFalse(one.namespaced)
        XCTAssertEqual(one.hints, ["sync-wave 1 — Deployment acme-api"])
        XCTAssertEqual(first.id.said(namespaced: true), "Deployment team-1/acme-api")
    }

    /// ↩ on a node (14.2.3): the keyboard walks the tree as it is drawn —
    /// depth first —, then the hooks; held at either end; on none yet, or
    /// on one gone, the first.
    func testTheKeyboardWalksTheTreeAsDrawnThenTheHooks() {
        let (app, read) = stalled()
        let detail = KubeMarkedAppDetail.make(app, read: read, mode: .only(.notServed), context: "fake-prod")
        let walk = KubeMarkedAppDetail.walk(detail)
        XCTAssertEqual(walk.map(\.id), KubeMarkedAppDetailView.rows(detail.tree).map(\.node.id), "as drawn")
        XCTAssertEqual(
            walk.map(\.name), ["acme-cart", "acme-cart-5f8d7c", "acme-cart-5f8d7c-x2k9p", "acme-cart-7d4b9c", "acme-cart-7d4b9c-m4n8q", "acme-cart"])
        XCTAssertEqual(KubeMarkedAppDetail.step(walk, from: nil, by: 1), walk[0].id, "none yet: the first")
        XCTAssertEqual(KubeMarkedAppDetail.step(walk, from: "member|Deployment|team-2|acme-gone", by: -1), walk[0].id, "one gone: the first")
        XCTAssertEqual(KubeMarkedAppDetail.step(walk, from: walk[0].id, by: -1), walk[0].id, "held at the top")
        XCTAssertEqual(KubeMarkedAppDetail.step(walk, from: walk[2].id, by: 1), walk[3].id)
        XCTAssertEqual(KubeMarkedAppDetail.step(walk, from: walk[5].id, by: 1), walk[5].id, "held at the end")
        XCTAssertNil(KubeMarkedAppDetail.step([], from: nil, by: 1))
        let instance = "prod-team-2-acme-orders-service"
        var hook = member(.job, "acme-orders-migrate", app: instance, .degraded, "job failed")
        hook.marks.hook = "PreSync"
        let hooked = KubeMarkedAppDetail.make(
            ranked([member(.deployment, "acme-orders", app: instance, .healthy, "2/2"), hook], instance: instance), mode: .only(.notServed), context: "fake-prod")
        XCTAssertEqual(KubeMarkedAppDetail.walk(hooked).map(\.name), ["acme-orders", "acme-orders-migrate"], "the hooks after the tree")
    }

    /// A write's "may undo" is for the app's own objects alone (14.2.3): a
    /// member, or one `ignore-healthcheck` leaves out of health only —
    /// never a ReplicaSet or a pod under one, a hook, or a copy of a mark.
    func testOnlyTheAppsOwnObjectsMayBeUndone() {
        let (app, read) = stalled()
        let cart = KubeMarkedAppDetail.walk(KubeMarkedAppDetail.make(app, read: read, mode: .only(.notServed), context: "fake-prod"))
        XCTAssertEqual(cart.filter(\.mayBeUndone).map { "\($0.kind) \($0.name)" }, ["Deployment acme-cart", "Service acme-cart"], "never a ReplicaSet or a pod")
        let instance = "prod-team-2-acme-orders-service"
        var ignored = member(.service, "acme-orders", app: instance, .healthy, "service")
        ignored.marks.ignoreHealthcheck = true
        var hook = member(.job, "acme-orders-migrate", app: instance, .degraded, "job failed")
        hook.marks.hook = "PreSync"
        var copy = KubeMarkedMember(id: .init(kind: .horizontalPodAutoscaler, namespace: "team-2", name: "acme-orders-extra"), marks: KubeMarkWire(), health: nil)
        copy.marks.tracking = .copied(KubeTrackingID.parse("\(instance):apps/Deployment:team-2/acme-orders")!)
        let detail = KubeMarkedAppDetail.make(
            ranked([member(.deployment, "acme-orders", app: instance, .healthy, "2/2"), ignored, hook], instance: instance, copies: [copy]), mode: .only(.notServed),
            context: "fake-prod")
        XCTAssertEqual(
            KubeMarkedAppDetail.walk(detail).map { "\($0.role) \($0.kind) \($0.mayBeUndone)" },
            ["member Deployment true", "copy HorizontalPodAutoscaler false", "ignored Service true", "hook Job false"])
    }

    func testPodsUnderAnOwnerAreCappedAndCounted() throws {
        let (app, base) = stalled()
        var read = base
        read.children += (0..<60).map { child(.pod, "acme-cart-7d4b9c-\($0)", owner: ("ReplicaSet", "acme-cart-7d4b9c"), .healthy, "1/1 ready") }
        let detail = KubeMarkedAppDetail.make(app, read: read, mode: .only(.notServed), context: "fake-prod", bounds: .init(podsShown: 50))
        let old = try XCTUnwrap(detail.tree.first?.children.first { $0.name == "acme-cart-7d4b9c" })
        XCTAssertEqual(old.children.count, 50)
        XCTAssertEqual(old.more, "11 more pods")
    }

    func testTheDetailSettlesItsMembersByWhatItRead() throws {
        // The single replica whose old pod still serves: cells 1/1, Ready from its row.
        let instance = "prod-team-1-acme-pay-service"
        let app = ranked([member(.deployment, "acme-pay", app: instance, namespace: "team-1", .healthy, "1/1 ready", fromRow: true)], instance: instance)
        XCTAssertEqual(app.health.state, .ready)
        var read = KubeMarkedAppDetail.Read()
        let object = KubeMarkedHealthTests.wire([
            "apiVersion": "apps/v1", "kind": "Deployment", "metadata": ["name": "acme-pay", "namespace": "team-1", "generation": 4],
            "spec": ["replicas": 1], "status": ["observedGeneration": 4, "replicas": 2, "updatedReplicas": 1, "readyReplicas": 1, "availableReplicas": 1],
        ])
        read.objects[.init(kind: .deployment, namespace: "team-1", name: "acme-pay")] = KubeMarkedSettled(object, at: now)
        let detail = KubeMarkedAppDetail.make(app, read: read, mode: .only(.notServed), context: "fake-prod")
        XCTAssertEqual(detail.state, .progressing, "its object says what its cells hide")
        XCTAssertEqual(detail.tree.first?.said(namespaced: false), "Deployment acme-pay — Progressing: 1 old replica pending termination")
        // Read nothing: the section's word stands.
        XCTAssertEqual(KubeMarkedAppDetail.make(app, mode: .only(.notServed), context: "fake-prod").state, .ready)
    }

    func testHooksApartIgnoreHealthcheckGreyAndCopiesUnderWhatTheyName() throws {
        let instance = "prod-team-2-acme-orders-service"
        var ignored = member(.service, "acme-orders", app: instance, .healthy, "service")
        ignored.marks.ignoreHealthcheck = true
        var hook = member(.job, "acme-orders-migrate", app: instance, .degraded, "job failed")
        hook.marks.hook = "PreSync"
        var copy = KubeMarkedMember(
            id: .init(kind: .horizontalPodAutoscaler, namespace: "team-2", name: "acme-orders-extra"), marks: KubeMarkWire(),
            health: .init(status: .healthy, sentence: "every target read", fromRow: true))
        copy.marks.tracking = .copied(KubeTrackingID.parse("\(instance):apps/Deployment:team-2/acme-orders")!)
        var stray = copy
        stray.id.name = "acme-orders-other"
        stray.marks.tracking = .copied(KubeTrackingID.parse("\(instance):apps/Deployment:team-2/acme-gone")!)
        let app = ranked(
            [member(.deployment, "acme-orders", app: instance, .healthy, "2/2 available"), ignored, hook], instance: instance, copies: [copy, stray])
        XCTAssertEqual(app.app.hooks.map(\.id.name), ["acme-orders-migrate"])
        let detail = KubeMarkedAppDetail.make(app, mode: .only(.notServed), context: "fake-prod")
        XCTAssertEqual(detail.state, .ready, "a failed hook, an ignored Service: neither counts")
        XCTAssertEqual(
            detail.hooks.map { $0.said(namespaced: false) }, ["Job acme-orders-migrate — Degraded: job failed — a hook (PreSync): not counted, as in Argo CD"])
        let service = try XCTUnwrap(detail.tree.first { $0.kind == "Service" })
        XCTAssertEqual(service.role, .ignored)
        XCTAssertEqual(service.note, "ignore-healthcheck: not counted, as in Argo CD")
        let deployment = try XCTUnwrap(detail.tree.first { $0.kind == "Deployment" })
        XCTAssertEqual(deployment.children.map(\.name), ["acme-orders-extra"], "a copy under the object its mark names")
        XCTAssertEqual(deployment.children.first?.role, .copy)
        XCTAssertEqual(
            deployment.children.first?.said(namespaced: false),
            "HorizontalPodAutoscaler acme-orders-extra — carries Deployment acme-orders's mark — a copy, not a member")
        XCTAssertEqual(detail.tree.last?.name, "acme-orders-other", "a copy naming none of its members: at the end")
        XCTAssertFalse(detail.tree.contains { $0.role == .copy && $0.status != nil }, "a copy has no health of its own here")
    }

    func testARolloutsAppSaysPromoteAndAbortAreArgoRolloutsAndItsDeploymentIsScaledByIt() throws {
        let instance = "prod-team-1-acme-blue-service"
        var rollout = member(.rollout, "acme-blue", app: instance, namespace: "team-1", .degraded, "rollout degraded")
        rollout.workloadRef = "acme-blue"
        let app = ranked(
            [rollout, member(.deployment, "acme-blue", app: instance, namespace: "team-1", .healthy, "scaled to 0", scaledToZero: true)], instance: instance)
        var read = KubeMarkedAppDetail.Read()
        read.children = [
            child(.replicaSet, "acme-blue-84c6d9", owner: ("Rollout", "acme-blue"), namespace: "team-1", .progressing, "1/2 ready", replicas: 2),
            child(.replicaSet, "acme-blue-7d4b9c", owner: ("Deployment", "acme-blue"), namespace: "team-1", .healthy, "scaled to 0", replicas: 0),
            child(.pod, "acme-blue-84c6d9-d3e4f", owner: ("ReplicaSet", "acme-blue-84c6d9"), namespace: "team-1", .degraded, "CrashLoopBackOff"),
        ]
        let detail = KubeMarkedAppDetail.make(app, read: read, mode: .only(.notServed), context: "fake-prod")
        XCTAssertEqual(detail.rollouts, "Its Argo Rollout is read for its health only: promote and abort are Argo Rollouts' — not here.")
        let node = try XCTUnwrap(detail.tree.first { $0.kind == "Rollout" })
        XCTAssertEqual(node.note, "promote and abort are Argo Rollouts' — not here")
        XCTAssertEqual(node.children.map(\.name), ["acme-blue-84c6d9"], "its own ReplicaSet, by its owner")
        XCTAssertEqual(node.children.first?.children.map(\.name), ["acme-blue-84c6d9-d3e4f"])
        let deployment = try XCTUnwrap(detail.tree.first { $0.kind == "Deployment" })
        XCTAssertEqual(deployment.said(namespaced: false), "Deployment acme-blue — Healthy: scaled by its Rollout")
        XCTAssertEqual(deployment.children.map(\.name), ["acme-blue-7d4b9c"], "the newest shown, even at 0")
        XCTAssertEqual(detail.word, "Failed")
    }

    // MARK: What only the Application knows, and the words

    func testWhatOnlyTheApplicationKnowsIsFixedRowsInTheModesWords() {
        let (app, _) = stalled()
        let expected: [(KubeMarkedAppsMode, String)] = [
            (.only(.notServed), "in the Application, in Argo CD's cluster"), (.only(.noApplications), "in the Application, which isn't in this cluster"),
            (.only(.forbidden), "in the Application, which can't be read here"), (.only(.undiscovered), "in the Application, which couldn't be looked for here"),
            (.beside(.init(missing: [app.app.key])), "in the Application, which isn't among those read here"),
        ]
        for (mode, place) in expected {
            let detail = KubeMarkedAppDetail.make(app, mode: mode, context: "fake-prod")
            XCTAssertEqual(detail.knowsTitle, "What Argo CD knows and this cluster doesn't")
            XCTAssertEqual(detail.knows.map(\.field), KubeMarkedAppDetail.applicationFields)
            XCTAssertEqual(
                detail.knows.map(\.field),
                ["Sync status", "Repository and path", "Target and live revision", "Sync policy (automated, prune, selfHeal)", "Last sync", "Project"])
            XCTAssertTrue(detail.knows.allSatisfy { $0.place == place }, "\(mode): never filled from a guess")
            XCTAssertEqual(detail.manifests, "The manifests' revision Argo CD synced: \(place)")
            XCTAssertEqual(detail.absent.contains("another cluster") || detail.absent.contains("Argo CD's cluster"), mode == .only(.notServed))
            for text in [detail.absent] + detail.knows.map(\.place) {
                for verb in ["Synced", "OutOfSync", "https://"] { XCTAssertFalse(text.contains(verb), text) }
            }
        }
        XCTAssertEqual(
            KubeMarkedAppDetail.undone(.only(.notServed)), "Argo CD may undo this: whether selfHeal is on is in the Application, in another cluster.")
        XCTAssertFalse(KubeMarkedAppDetail.undone(.only(.noApplications)).contains("another cluster"))
        XCTAssertFalse(KubeMarkedAppDetail.undone(.only(.forbidden)).contains("another cluster"))
        XCTAssertTrue(KubeMarkedAppDetail.undone(.only(.notServed), probable: true).contains("if it deploys it"))
    }

    func testHintsImagesAndCommitsAreText() {
        let instance = "prod-team-2-acme-cart-service"
        var deployment = member(
            .deployment, "acme-cart", app: instance, .healthy, "2/2 available", images: ["registry.acme.example/acme/cart:7f3c2e1", "registry.acme.example/sidecar:1.2"])
        deployment.marks.syncWave = "2"
        deployment.marks.syncOptions = "Prune=false"
        var service = member(.service, "acme-cart", app: instance, .healthy, "service")
        service.marks.compareOptions = "IgnoreExtraneous"
        service.marks.links = [.init(name: "external-link", value: KubeMarkWire.link("https://user:p4ss@grafana.acme.example/d/cart?orgId=1")!)]
        var hook = member(.job, "acme-cart-migrate", app: instance, .healthy, "job complete")
        hook.marks.hook = "PreSync"
        hook.marks.syncWave = "-1"
        let detail = KubeMarkedAppDetail.make(ranked([deployment, service, hook], instance: instance), mode: .only(.notServed), context: "fake-prod")
        XCTAssertEqual(
            detail.hints,
            [
                "sync-wave 2 — Deployment acme-cart", "sync-options Prune=false — Deployment acme-cart", "compare-options IgnoreExtraneous — Service acme-cart",
                "link external-link: https://grafana.acme.example/d/cart?orgId=1 — Service acme-cart", "sync-wave -1 — Job acme-cart-migrate (a hook)",
            ])
        XCTAssertFalse(detail.hints.joined().contains("p4ss"), "a link's userinfo never kept")
        XCTAssertEqual(
            detail.images,
            ["registry.acme.example/acme/cart:7f3c2e1 — Deployment acme-cart", "registry.acme.example/sidecar:1.2 — Deployment acme-cart"])
        XCTAssertEqual(detail.commits, ["commit 7f3c2e1 — the image's tag (…/cart:7f3c2e1)"])
        XCTAssertEqual(KubeMarkedAppDetail.names(ranked([deployment, service, hook], instance: instance).app), "Deployment team-2/acme-cart\nService team-2/acme-cart\nJob team-2/acme-cart-migrate")
    }

    func testFiftyMembersAreReadTheRestFromTheirRows() {
        let instance = "prod-team-0-acme-many-service"
        let members =
            (0..<60).map { member(.deployment, String(format: "acme-many-%02d", $0), app: instance, .healthy, "1/1 ready", fromRow: true) }
            + [member(.service, "acme-many", app: instance, .healthy, "service")]
        let app = ranked(members, instance: instance)
        let plan = KubeMarkedAppDetail.fetched(app.app, limit: 50)
        XCTAssertEqual(plan.read.count, 50)
        XCTAssertEqual(plan.past.count, 10)
        XCTAssertFalse(plan.read.contains { $0.kind == .service }, "a Service's cells say its health: never a GET")
        var read = KubeMarkedAppDetail.Read()
        read.past = plan.past
        read.unread[plan.read[0]] = "forbidden"
        let notes = KubeMarkedAppDetail.make(app, read: read, mode: .only(.notServed), context: "fake-prod").notes
        XCTAssertEqual(notes.first, "10 objects past the first 50 show from its row: a detail reads at most 50")
        XCTAssertTrue(notes.contains("Deployment acme-many-00: not read — forbidden; from its row"), "\(notes)")
    }

    // MARK: What is read

    func testTheListsAreByEachWorkloadsOwnSelectorInItsNamespace() {
        func object(_ kind: String, _ name: String, namespace: String = "team-2", selector: [String: Any]? = nil, workloadRef: String? = nil) -> KubeMarkedSettled {
            var spec: [String: Any] = [:]
            if let selector { spec["selector"] = selector }
            if let workloadRef { spec["workloadRef"] = ["apiVersion": "apps/v1", "kind": "Deployment", "name": workloadRef] }
            let group = kind == "Rollout" ? "argoproj.io/v1alpha1" : kind == "CronJob" ? "batch/v1" : "apps/v1"
            return KubeMarkedSettled(
                KubeMarkedHealthTests.wire(["apiVersion": group, "kind": kind, "metadata": ["name": name, "namespace": namespace], "spec": spec]), at: now)
        }
        let instance = "prod-team-2-acme-cart-service"
        let members = [
            member(.deployment, "acme-cart", app: instance, .healthy, "2/2"), member(.deployment, "acme-bare", app: instance, .healthy, "2/2"),
            member(.deployment, "acme-all", app: instance, .healthy, "2/2"), member(.statefulSet, "acme-db", app: instance, .healthy, "3/3"),
            member(.rollout, "acme-blue", app: instance, .healthy, "rollout healthy"), member(.deployment, "acme-blue", app: instance, .healthy, "scaled to 0"),
            member(.cronJob, "acme-reindex", app: instance, .healthy, "last run succeeded"), member(.service, "acme-cart", app: instance, .healthy, "service"),
        ]
        let app = ranked(members, instance: instance).app
        let objects: [KubeMarkedMember.ID: KubeMarkedSettled] = [
            .init(kind: .deployment, namespace: "team-2", name: "acme-cart"): object("Deployment", "acme-cart", selector: ["matchLabels": ["app": "acme-cart"]]),
            .init(kind: .deployment, namespace: "team-2", name: "acme-bare"): object("Deployment", "acme-bare"),
            .init(kind: .deployment, namespace: "team-2", name: "acme-all"): object("Deployment", "acme-all", selector: ["matchLabels": [String: String]()]),
            .init(kind: .statefulSet, namespace: "team-2", name: "acme-db"): object(
                "StatefulSet", "acme-db", selector: ["matchLabels": ["app": "acme-db"], "matchExpressions": [["key": "tier", "operator": "In", "values": ["b", "a"]]]]),
            .init(kind: .rollout, namespace: "team-2", name: "acme-blue"): object("Rollout", "acme-blue", workloadRef: "acme-blue"),
            .init(kind: .deployment, namespace: "team-2", name: "acme-blue"): object("Deployment", "acme-blue", selector: ["matchLabels": ["app": "acme-blue"]]),
            .init(kind: .cronJob, namespace: "team-2", name: "acme-reindex"): object("CronJob", "acme-reindex"),
        ]
        let lists = KubeMarkedAppDetail.lists(app, objects: objects)
        let said = lists.map { "\($0.what.rawValue) \($0.namespace) \($0.selector ?? "-") \($0.limit)" }
        XCTAssertEqual(
            said,
            [
                "ReplicaSet team-2 app=acme-blue 50", "Pod team-2 app=acme-blue 200", "ReplicaSet team-2 app=acme-cart 50", "Pod team-2 app=acme-cart 200",
                "Pod team-2 app=acme-db,tier in (a,b) 200", "Job team-2 - 500",
            ],
            "the Rollout's by its Deployment's selector, once; none without a selector or with one selecting everything; none for a Service")
        XCTAssertNil(KubeMarkedAppDetail.selector(KubeMarkedHealthTests.wire(["spec": ["selector": ["matchExpressions": [["key": "x", "operator": "Gt"]]]]])))
        // A custom resource's selector the API server never checked: no query of its making.
        func selector(_ selector: [String: Any]) -> String? { KubeMarkedAppDetail.selector(KubeMarkedHealthTests.wire(["spec": ["selector": selector]])) }
        XCTAssertNil(selector(["matchLabels": ["app": "acme,tier"]]), "a value that would add a clause")
        XCTAssertNil(selector(["matchLabels": ["!app": "acme"]]))
        XCTAssertNil(selector(["matchExpressions": [["key": "tier", "operator": "In", "values": ["a)", "b"]]]]))
        XCTAssertNil(selector(["matchLabels": ["app": String(repeating: "a", count: 64)]]), "never cut: a cut value selects other pods")
        XCTAssertNil(selector(["matchLabels": Dictionary(uniqueKeysWithValues: (0..<33).map { ("k\($0)", "v") })]), "past its bounds")
        XCTAssertNil(selector(["matchLabels": ["app": "acme\u{200B}cart"]]), "a format character: no label's")
        // A selector it can't read: the object read all the same, no list made of it.
        let odd = KubeMarkedHealthTests.wire([
            "apiVersion": "argoproj.io/v1alpha1", "kind": "Rollout", "metadata": ["name": "acme-blue", "namespace": "team-2"], "spec": ["selector": "app=acme-blue"],
            "status": ["phase": "Healthy"],
        ])
        XCTAssertEqual(odd.status?.phase, "Healthy")
        XCTAssertEqual(odd.spec?.selector?.unusable, true)
        XCTAssertNil(KubeMarkedAppDetail.selector(odd))
        XCTAssertNil(selector(["matchLabels": ["app": 7]]))
        XCTAssertEqual(selector(["matchLabels": ["app.kubernetes.io/name": "acme-cart", "tier": ""]]), "app.kubernetes.io/name=acme-cart,tier=")
        // 1 KB in all, never cut: each label within its bounds, 16 of 59 bytes kept (944), 20 not (1,180).
        func labels(_ count: Int) -> [String: Any] {
            ["matchLabels": Dictionary(uniqueKeysWithValues: (0..<count).map { (String(format: "acme.example/key-%02d", $0), String(repeating: "v", count: 40)) })]
        }
        XCTAssertNotNil(selector(labels(16)))
        XCTAssertNil(selector(labels(20)), "past 1 KB in all")
        XCTAssertEqual(KubeMarkedHealthTests.wire(["spec": ["selector": labels(20)]]).spec?.selector?.unusable, true, "kept as unusable: no list made of it")
        let expressions: [String: Any] = [
            "matchExpressions": (0..<4).map { ["key": "acme.example/tier-\($0)", "operator": "In", "values": (0..<5).map { "value-\($0)-" + String(repeating: "x", count: 40) }] }
        ]
        XCTAssertNil(selector(expressions), "expressions' values count toward it too")
    }

    /// The children's rows carry their metadata — kubectl's last-applied
    /// copy, other annotations, managed fields: none of it is kept.
    func testTheChildrenReaderKeepsOnlyItsAllowList() throws {
        let sentinel = FakeKubeAPI.gitOpsSentinel
        let columns: [[String: Any]] = [
            ["name": "Name", "type": "string", "format": "name"], ["name": "Desired", "type": "integer"], ["name": "Current", "type": "integer"],
            ["name": "Ready", "type": "integer"],
        ]
        func row(_ name: String, owners: [[String: Any]], annotations: [String: String]) -> [String: Any] {
            [
                "cells": [name, 1, 1, 0],
                "object": [
                    "kind": "PartialObjectMetadata", "apiVersion": "meta.k8s.io/v1",
                    "metadata": [
                        "name": name, "namespace": "team-2", "creationTimestamp": "2026-11-14T09:00:00Z", "ownerReferences": owners, "annotations": annotations,
                        "labels": ["app": "acme-cart", "secret-label": sentinel],
                        "managedFields": [["manager": "kube-controller-manager", "fieldsV1": ["f:metadata": ["f:annotations": [sentinel: [String: Any]()]]]]],
                    ],
                ],
            ]
        }
        let table: [String: Any] = [
            "kind": "Table", "apiVersion": "meta.k8s.io/v1", "columnDefinitions": columns, "metadata": ["continue": "next-page"],
            "rows": [
                row(
                    "acme-cart-5f8d7c",
                    owners: [
                        ["apiVersion": "apps/v1", "kind": "Deployment", "name": "acme-other", "controller": false],
                        ["apiVersion": "apps/v1", "kind": "Deployment", "name": "acme-cart", "controller": true],
                    ],
                    annotations: [
                        "argocd.argoproj.io/tracking-id": "\(Self.cart):apps/Deployment:team-2/acme-cart",
                        "kubectl.kubernetes.io/last-applied-configuration": "{\"env\":\"\(sentinel)\"}", "acme.example/token": sentinel,
                    ])
            ],
        ]
        let list = KubeMarkedAppDetail.List(what: .replicaSet, namespace: "team-2", selector: "app=acme-cart", limit: 50, of: .init(kind: .deployment, namespace: "team-2", name: "acme-cart"))
        let kind = KubeResourceKind(group: "apps", version: "v1", resource: "replicasets", kind: "ReplicaSet", singular: "replicaset", namespaced: true, verbs: ["list"])
        let read = try KubeMarkedAppDetail.children(JSONSerialization.data(withJSONObject: table), list: list, kind: kind, now: now)
        XCTAssertEqual(read.more, 0, "more past the page: said, not read")
        let set = try XCTUnwrap(read.children.first)
        XCTAssertEqual(set.owner, .init(kind: "Deployment", name: "acme-cart"), "the controller")
        XCTAssertEqual(set.copied?.name, "acme-cart", "its Deployment's mark: a copy")
        XCTAssertEqual(set.health?.status, .progressing)
        XCTAssertEqual(set.replicas, 1)
        XCTAssertFalse(String(describing: read).contains(sentinel), "nothing of its metadata but the allow-list")
        // Not a Table: refused, never read as objects.
        XCTAssertThrowsError(try KubeMarkedAppDetail.children(Data("{\"kind\":\"ReplicaSetList\",\"items\":[]}".utf8), list: list, kind: kind, now: now))
    }

    func testAPodsHealthByArgoCDsRuleFromItsRow() {
        let columns = ["Name", "Ready", "Status", "Restarts"].map { KubeColumn(name: $0, format: $0 == "Name" ? "name" : "") }
        func pod(_ ready: String, _ status: String, _ restarts: String = "0") -> KubeMarkedHealth.Verdict {
            KubeMarkedHealth.pod(KubeRow(id: KubeRowID(namespace: "team-2", name: "p"), cells: [.text("p"), .text(ready), .text(status), .text(restarts)]), columns: columns)
        }
        for status in ["CrashLoopBackOff", "ImagePullBackOff", "ErrImagePull", "CreateContainerConfigError", "Error", "OOMKilled", "Evicted"] {
            XCTAssertEqual(pod("0/1", status).status, .degraded, status)
        }
        for status in ["Init:CrashLoopBackOff", "Init:0/2", "Pending", "ContainerCreating", "PodInitializing", "Terminating"] {
            XCTAssertEqual(pod("0/1", status).status, .progressing, "\(status): its pod pending, as Argo CD reads it")
        }
        XCTAssertEqual(pod("1/1", "Running").status, .healthy)
        XCTAssertEqual(pod("1/2", "Running").status, .progressing)
        XCTAssertEqual(pod("1/2", "Running", "3 (2m ago)").status, .degraded, "not ready once a container restarted")
        XCTAssertEqual(pod("1/2", "Running", "3 (2m ago)").sentence, "1/2 ready after 3 restarts")
        XCTAssertEqual(pod("0/1", "Completed").status, .healthy)
        XCTAssertEqual(pod("0/1", "").status, .unknown)
        let sets = ["Name", "Desired", "Current", "Ready"].map { KubeColumn(name: $0, format: $0 == "Name" ? "name" : "") }
        func set(_ desired: Int, _ ready: Int) -> KubeMarkedHealth.Verdict? {
            KubeMarkedHealth.replicaSet(KubeRow(id: KubeRowID(namespace: "team-2", name: "r"), cells: [.text("r"), .integer(desired), .integer(desired), .integer(ready)]), columns: sets)
        }
        XCTAssertEqual(set(2, 1)?.status, .progressing)
        XCTAssertEqual(set(2, 2)?.status, .healthy)
        XCTAssertEqual(set(0, 0)?.sentence, "scaled to 0")
    }

    // MARK: Copies kept by the app their mark names

    func testCopiesJoinTheAppTheirMarkNamesNeverItsMembers() throws {
        let instance = "prod-team-2-acme-cart-service"
        let deployment = member(.deployment, "acme-cart", app: instance, .healthy, "2/2")
        var copy = KubeMarkedMember(id: .init(kind: .horizontalPodAutoscaler, namespace: "team-2", name: "acme-cart-extra"), marks: KubeMarkWire(), health: nil)
        copy.marks.tracking = .copied(KubeTrackingID.parse("\(instance):apps/Deployment:team-2/acme-cart")!)
        var apps = KubeMarkedApps()
        apps.merge(changed: [deployment, copy], removed: [])
        let app = try XCTUnwrap(apps[.init(installation: "", instance: instance)])
        XCTAssertEqual(app.members.map(\.id.name), ["acme-cart"])
        XCTAssertEqual(app.copies.map(\.id.name), ["acme-cart-extra"])
        XCTAssertEqual(apps.tally.copied, 1)
        XCTAssertEqual(apps, KubeMarkedApps.group([copy, deployment]), "the same, merged in any order")
        apps.merge(changed: [], removed: [copy.id])
        XCTAssertEqual(apps[.init(installation: "", instance: instance)]?.copies, [])
        XCTAssertEqual(apps.tally.copied, 0)
        // A copy alone makes no app.
        XCTAssertTrue(KubeMarkedApps.group([copy]).apps.isEmpty)
    }

    // MARK: Writes and applies say "may undo"

    func testAnApplyOnATrackedObjectSaysArgoCDMayUndoItWhereApplicationsArentRead() {
        func live(_ annotations: [String: String]) -> [String: Any] {
            ["apiVersion": "apps/v1", "kind": "Deployment", "metadata": ["name": "acme-cart", "namespace": "team-2", "annotations": annotations]]
        }
        let own = live(["argocd.argoproj.io/tracking-id": "\(Self.cart):apps/Deployment:team-2/acme-cart"])
        let copied = live(["argocd.argoproj.io/tracking-id": "\(Self.cart):apps/Deployment:team-2/acme-other"])
        let sentence = "Argo CD may undo this: whether selfHeal is on is in the Application, in another cluster."
        XCTAssertEqual(KubeMarkedAppDetail.applyWarning(live: own, reason: .notServed), sentence)
        XCTAssertNil(KubeMarkedAppDetail.applyWarning(live: copied, reason: .notServed), "a copy names somebody else")
        XCTAssertNil(KubeMarkedAppDetail.applyWarning(live: own, reason: nil), "Applications read here: today's warning")
        let warnings = KubeFieldOwners.warnings([], managedBy: KubeFieldOwners.managedBy(own), argoMarks: sentence)
        XCTAssertEqual(warnings, [sentence], "never \"will be reverted\" where selfHeal can't be known")
        XCTAssertEqual(KubeFieldOwners.warnings([], managedBy: KubeFieldOwners.managedBy(own)), ["Argo CD manages this; your change will be reverted."])
        let argoField = KubeFieldOwners.Owner(manager: "argocd-controller", operation: "Apply", fields: [".spec.replicas"])
        XCTAssertEqual(
            KubeFieldOwners.warnings([argoField], managedBy: [], argoMarks: sentence), [sentence, "Also owned: argocd-controller owns .spec.replicas (Apply)."],
            "a field Argo CD's controller owns: still \"may\"")
        // The mode's reason from discovery alone: not served, or argoproj.io not answering.
        XCTAssertEqual(
            KubeMarkedAppsMode.of(discovery: KubeDiscovery(kinds: []), applications: .notYetListed, marked: []), .only(.notServed))
    }

    func testAWriteConfirmationSaysTheNoteBesideTheRule() {
        let context = KubeWritesTests.context("kind-fake")
        let kind = KubeResourceKind(group: "apps", version: "v1", resource: "deployments", kind: "Deployment", singular: "deployment", namespaced: true, verbs: ["get", "patch"])
        let ref = KubeObjectRef(context: "kind-fake", kind: kind, namespace: "team-2", name: "acme-cart")
        let rule = KubeWriteCheck.rule(.restart, for: context, kind: kind)
        let note = KubeMarkedAppDetail.undone(.only(.notServed))
        let said = KubeWriteConfirmation.make(.restart, ref, context: context, rule: rule, note: note)
        XCTAssertTrue(said.detail.contains("⚠︎ " + note), said.detail)
        XCTAssertFalse(KubeWriteConfirmation.make(.restart, ref, context: context, rule: rule).detail.contains("Argo CD may undo"))
        XCTAssertEqual(said.typedName, KubeWriteConfirmation.make(.restart, ref, context: context, rule: rule).typedName, "the guard as it was")
        XCTAssertEqual(KubeMarkedAppDetail.undoneVerbs, [.delete, .restart, .scale, .pause, .resume, .suspend, .unsuspend])
    }

    // MARK: Against the fake spoke (M4)

    private func startFake(_ options: FakeKubeAPI.SpokeOptions = FakeKubeAPI.SpokeOptions(apps: 4)) throws -> (FakeKubeAPI, KubeClient, FakeKubeAPI.Spoke) {
        let socket = "/tmp/otmd-\(UInt32.random(in: 0...UInt32.max)).sock"
        let api = FakeKubeAPI(socket: socket)
        try api.start()
        fakes.append(api)
        let spoke = api.addSpoke(options, now: Date())
        return (api, KubeClient(KubeSocketConnection(socket: socket, context: "fake-prod")), spoke)
    }

    private func until(_ what: String, _ seconds: TimeInterval = 15, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            if Date() > deadline { return XCTFail("timed out: \(what)") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func cartApp() -> KubeMarkedApp {
        ranked(
            [
                member(.deployment, "acme-cart", app: Self.cart, .degraded, "rollout stalled (ProgressDeadlineExceeded)"),
                member(.service, "acme-cart", app: Self.cart, .healthy, "service"),
            ], instance: Self.cart
        ).app
    }

    func testTheDetailReadsItsMembersThenTheirChildrenByTheirSelectors() async throws {
        let (api, client, _) = try startFake()
        let discovery = try await client.discover()
        api.forgetRequests()
        let session = KubeMarkedDetailSession()
        var told: [KubeMarkedMember.ID] = []
        session.settled = { id, _, _ in told.append(id) }
        let ref = KubeMarkedDetailRef(context: "fake-prod", key: .init(installation: "", instance: Self.cart))
        session.show(ref, app: cartApp(), discovery: discovery, client: client)
        try await until("read") { session.state == .loaded }
        let requests = api.requests.filter { !$0.isDiscovery }
        XCTAssertEqual(
            requests.map(\.path).sorted(),
            ["/api/v1/namespaces/team-2/pods", "/apis/apps/v1/namespaces/team-2/deployments/acme-cart", "/apis/apps/v1/namespaces/team-2/replicasets"],
            "the Deployment's GET — never the Service's, its cells say it —, then its ReplicaSets and pods")
        for list in requests where list.path.hasSuffix("/pods") || list.path.hasSuffix("/replicasets") {
            XCTAssertEqual(list.query["labelSelector"], "app=acme-cart", "by its own selector")
            XCTAssertEqual(list.query["includeObject"], "Metadata")
            XCTAssertEqual(list.accept, KubeClient.tableOnlyAccept, "a Table or nothing: never whole objects")
        }
        XCTAssertEqual(told, [.init(kind: .deployment, namespace: "team-2", name: "acme-cart")], "the section keeps what it read")
        XCTAssertLessThanOrEqual(session.mostInFlight, KubeMarkedDetailSession.inFlight)
        let detail = KubeMarkedAppDetail.make(KubeMarkedRanked(app: cartApp(), health: cartApp().health), read: session.read, mode: .only(.notServed), context: "fake-prod")
        let deployment = try XCTUnwrap(detail.tree.first { $0.kind == "Deployment" })
        XCTAssertEqual(deployment.status, .degraded)
        XCTAssertEqual(deployment.children.map(\.name), ["acme-cart-5f8d7c", "acme-cart-7d4b9c"], "the newest, and the old one still serving")
        XCTAssertEqual(deployment.children.map(\.status), [.progressing, .healthy])
        XCTAssertTrue(deployment.children.allSatisfy { $0.note == "a copy of Deployment acme-cart's mark: not a member" }, "each carries its mark, copied")
        XCTAssertEqual(deployment.children.first?.children.map { $0.said(namespaced: false) }, ["Pod acme-cart-5f8d7c-x2k9p — Degraded: CrashLoopBackOff"])
        XCTAssertEqual(deployment.children.last?.children.map(\.status), [.healthy])
        XCTAssertFalse(String(describing: session.read).contains(FakeKubeAPI.gitOpsSentinel), "nothing kept but the allow-lists")

        // Still shown, a minute on (its section's flushes ask again): nothing read — no timer.
        api.forgetRequests()
        let readAt = Date()
        session.clock = { readAt.addingTimeInterval(60) }
        session.show(ref, app: cartApp(), discovery: discovery, client: client)
        // Shown again within 30 s: what was read, nothing asked.
        session.clock = { readAt.addingTimeInterval(10) }
        session.hide()
        session.show(ref, app: cartApp(), discovery: discovery, client: client)
        XCTAssertEqual(session.state, .loaded)
        XCTAssertEqual(session.getsAsked, 1)
        // Refresh: read again.
        session.show(ref, app: cartApp(), discovery: discovery, client: client, again: true)
        try await until("read again") { session.state == .loaded && session.getsAsked == 2 }
        XCTAssertEqual(api.requests.filter { $0.path.hasSuffix("/deployments/acme-cart") }.count, 1, "nothing read before Refresh")
        // Shown again past 30 s: read again.
        session.hide()
        session.clock = { readAt.addingTimeInterval(120) }
        session.show(ref, app: cartApp(), discovery: discovery, client: client)
        try await until("read once more") { session.state == .loaded && session.getsAsked == 3 }
    }

    func testTheSectionsFreshReadStandsAndNoDiscoveryAsksNothing() async throws {
        let (api, client, _) = try startFake()
        let discovery = try await client.discover()
        api.forgetRequests()
        let session = KubeMarkedDetailSession()
        let ref = KubeMarkedDetailRef(context: "fake-prod", key: .init(installation: "", instance: Self.cart))
        session.show(ref, app: cartApp(), discovery: nil, client: client)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(api.requests.count, 0, "no discovery, no request")
        XCTAssertEqual(session.state, .idle)
        // What the section settled a moment ago stands: only the lists are read.
        let id = KubeMarkedMember.ID(kind: .deployment, namespace: "team-2", name: "acme-cart")
        let wire = KubeMarkedHealthTests.wire([
            "apiVersion": "apps/v1", "kind": "Deployment", "metadata": ["name": "acme-cart", "namespace": "team-2", "generation": 4],
            "spec": ["selector": ["matchLabels": ["app": "acme-cart"]]],
        ])
        session.show(ref, app: cartApp(), discovery: discovery, client: client, store: [id: KubeMarkedSettled(wire, at: Date())])
        try await until("read") { session.state == .loaded }
        XCTAssertFalse(api.requests.contains { $0.path.hasSuffix("/deployments/acme-cart") }, "the section's fresh read stands")
        XCTAssertTrue(api.requests.contains { $0.path.hasSuffix("/replicasets") })
        XCTAssertEqual(session.getsAsked, 0)
    }

    /// Two Deployments whose selectors overlap on the fake: the canary's
    /// ReplicaSet and pod come in both workloads' lists, and are read once.
    func testOverlappingSelectorsAreReadOnce() async throws {
        let (api, client, _) = try startFake(FakeKubeAPI.SpokeOptions(apps: 0, states: false))
        let instance = "prod-team-0-acme-web-service"
        api.addMarkedDeployment("acme-web", namespace: "team-0", app: instance, padding: 0, now: now)
        api.addMarkedDeployment("acme-web-canary", namespace: "team-0", app: instance, padding: 0, now: now)
        // The canary selects a part of the web's pods: app=acme-web, track=canary.
        api.modify("deployments.apps", "acme-web-canary", namespace: "team-0") { body in
            var spec = body["spec"] as? [String: Any] ?? [:]
            spec["selector"] = ["matchLabels": ["app": "acme-web", "track": "canary"]]
            body["spec"] = spec
        }
        let canary = ["app": "acme-web", "track": "canary"]
        api.add(
            "replicasets.apps", "acme-web-canary-5f8d7c", namespace: "team-0", values: ["Desired": 1, "Current": 1, "Ready": 1], labels: canary,
            created: now.addingTimeInterval(-600))
        api.setRowOwners(
            "replicasets.apps", "acme-web-canary-5f8d7c", namespace: "team-0", [api.owner("apps/v1", "Deployment", "acme-web-canary", resource: "deployments.apps", namespace: "team-0")])
        api.addPod("acme-web-canary-5f8d7c-g5h6i", namespace: "team-0", FakeKubeAPI.Pod(), labels: canary, created: now.addingTimeInterval(-600))
        api.setRowOwners(
            "pods", "acme-web-canary-5f8d7c-g5h6i", namespace: "team-0",
            [api.owner("apps/v1", "ReplicaSet", "acme-web-canary-5f8d7c", resource: "replicasets.apps", namespace: "team-0")])
        let app = ranked(
            [
                member(.deployment, "acme-web", app: instance, namespace: "team-0", .healthy, "2/2 ready", fromRow: true),
                member(.deployment, "acme-web-canary", app: instance, namespace: "team-0", .healthy, "2/2 ready", fromRow: true),
            ], instance: instance
        ).app
        let discovery = try await client.discover()
        api.forgetRequests()
        let session = KubeMarkedDetailSession()
        session.show(.init(context: "fake-prod", key: app.key), app: app, discovery: discovery, client: client)
        try await until("read") { session.state == .loaded }
        let selectors = api.requests.filter { $0.path.hasSuffix("/replicasets") }.compactMap { $0.query["labelSelector"] }.sorted()
        XCTAssertEqual(selectors, ["app=acme-web", "app=acme-web,track=canary"], "each workload's own selector")
        let places = session.read.children.map(\.place)
        XCTAssertEqual(Set(places).count, places.count, "each object once")
        XCTAssertEqual(session.read.children.filter { $0.name == "acme-web-canary-5f8d7c" }.count, 1)
        XCTAssertEqual(session.read.children.filter { $0.name == "acme-web-canary-5f8d7c-g5h6i" }.count, 1)
        let detail = KubeMarkedAppDetail.make(KubeMarkedRanked(app: app, health: app.health), read: session.read, mode: .only(.notServed), context: "fake-prod")
        XCTAssertEqual(detail.tree.first { $0.name == "acme-web-canary" }?.children.map(\.name), ["acme-web-canary-5f8d7c"])
    }

    /// An app of 60 Deployments: 50 GETs, 4 at a time; the rest from their rows, said.
    func testAtMostFiftyObjectsFourInFlight() async throws {
        let (api, client, _) = try startFake(FakeKubeAPI.SpokeOptions(apps: 0, states: false))
        let instance = "prod-team-0-acme-many-service"
        let names = (0..<60).map { String(format: "acme-many-%02d", $0) }
        for name in names { api.addMarkedDeployment(name, namespace: "team-0", app: instance, padding: 0, now: now) }
        let app = ranked(names.map { member(.deployment, $0, app: instance, namespace: "team-0", .healthy, "2/2 ready", fromRow: true) }, instance: instance).app
        let discovery = try await client.discover()
        api.forgetRequests()
        let session = KubeMarkedDetailSession()
        session.show(.init(context: "fake-prod", key: app.key), app: app, discovery: discovery, client: client)
        try await until("read", 30) { session.state == .loaded }
        let gets = api.requests.filter { $0.path.contains("/deployments/") }
        XCTAssertEqual(gets.count, 50, "at most 50 objects")
        XCTAssertEqual(session.getsAsked, 50)
        XCTAssertEqual(session.read.past.count, 10)
        XCTAssertGreaterThan(session.mostInFlight, 1, "read at once")
        XCTAssertLessThanOrEqual(session.mostInFlight, 4)
        let notes = KubeMarkedAppDetail.make(KubeMarkedRanked(app: app, health: app.health), read: session.read, mode: .only(.notServed), context: "fake-prod").notes
        XCTAssertTrue(notes.contains("10 objects past the first 50 show from its row: a detail reads at most 50"), "\(notes)")
    }
}
