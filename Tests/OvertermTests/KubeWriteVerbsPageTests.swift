import Foundation
import XCTest

@testable import Overterm

/// Stage 2a's other verbs through the page's one guard path, against the
/// fake API server: `kind-fake` (local, writable), `fake-dev` (remote,
/// read-only) and `fake-prod` (production, writable with no switch),
/// all fictional and on the same fake. Each verb's exact requests, the
/// order — the access review, the reads, the confirmation, then the write —
/// and the refusals, with nothing sent.
@MainActor
final class KubeWriteVerbsPageTests: XCTestCase {
    private var api: FakeKubeAPI!
    private var socket: String!
    private var contexts: KubeTestContexts!

    override func setUp() async throws {
        socket = "/tmp/otkwv-\(UInt32.random(in: 0...UInt32.max)).sock"
        api = FakeKubeAPI(socket: socket)
        try api.start()
        api.addNamespace("shop")
        api.addPod("web-1", namespace: "shop")
        api.add(
            "deployments.apps", "web", namespace: "shop", values: ["Ready": "1/1", "Up-to-date": 1, "Available": 1],
            fields: ["spec": ["replicas": 1, "template": ["metadata": ["labels": ["app": "web"]]]], "status": ["replicas": 1]])
        api.add(
            "cronjobs.batch", "nightly", namespace: "shop", values: ["Schedule": "0 3 * * *", "Timezone": "<none>", "Active": 0, "Last Schedule": "<none>"],
            fields: [
                "spec": [
                    "schedule": "0 3 * * *",
                    "jobTemplate": [
                        "metadata": ["labels": ["app": "nightly"]],
                        "spec": ["template": ["spec": ["restartPolicy": "OnFailure", "containers": [["name": "job", "image": "busybox:1.36"]]]]],
                    ],
                ]
            ])
        api.add("nodes", "fake-node-1", values: ["Status": "Ready", "Roles": "control-plane", "Version": "v1.34.1"])
    }

    override func tearDown() async throws {
        api?.stop()
    }

    private final class Box {
        var confirmations: [(KubeWriteConfirmation, (KubeWriteAnswer) -> Void)] = []
        var confirms: [(String, String, () -> Void)] = []
    }

    private func page(current: String) async throws -> (KubernetesPageModel, Box) {
        let model = KubernetesModel(proxies: KubeProxies())
        let contexts = KubeTestContexts(["fake-dev", "fake-prod", "kind-fake"], current: current)
        self.contexts = contexts
        model.load = { _ in contexts.value }
        model.readConfiguration = { KubernetesModel.Configuration() }
        model.watchesSettings = false
        model.remembersSelection = false
        model.flushInterval = .milliseconds(20)
        model.statusInterval = .milliseconds(50)
        let socket = self.socket!
        model.connectOverride = { context in KubeSocketConnection(socket: socket, context: context.name, writable: context.isWritable) }
        model.statusOverride = { _ in .open }
        model.access.run = { _, _, _ in .yes }
        let page = KubernetesPageModel(model: model)
        page.jobSuffix = { "x2b4k" }
        let box = Box()
        var actions = KubernetesActions(run: { _ in }, settings: {}, copy: { _ in }, copySecret: { _ in })
        actions.confirmWrite = { confirmation, then in box.confirmations.append((confirmation, then)) }
        actions.confirm = { _, detail, button, then in box.confirms.append((detail, button, then)) }
        page.actions = actions
        model.show()
        try await until("listed") { model.rows.count == 1 && model.selectedName == current && model.discovery != nil }
        return (page, box)
    }

    /// The kind `name` shown, its rows listed.
    private func show(_ page: KubernetesPageModel, _ name: String, rows: Int) async throws -> KubeResourceKind {
        let kind = try XCTUnwrap(page.model.discovery?.kind(name))
        page.showKind(kind)
        try await until("\(name) listed") { page.model.kind.fullName == kind.fullName && page.model.rows.count == rows && page.model.listState == .live }
        return kind
    }

    private func until(_ what: String, _ timeout: TimeInterval = 5, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return XCTFail("timed out: \(what)") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func written() -> [FakeKubeAPI.Request] { api.writes.filter { !$0.isAccessReview } }
    private func reviewed() -> [[String: String]] {
        api.requests.filter(\.isAccessReview).compactMap {
            (($0.json as? [String: Any])?["spec"] as? [String: Any])?["resourceAttributes"] as? [String: String]
        }
    }

    // MARK: CronJobs

    /// `s`: create jobs.batch reviewed, the CronJob read, the Job asked
    /// for by name, then made — and listed as the CronJob's.
    func testATriggerMakesTheJobAfterItsReviewAndConfirmation() async throws {
        let (page, box) = try await page(current: "kind-fake")
        defer { page.model.hide() }
        _ = try await show(page, "cj", rows: 1)
        page.selection = ["shop/nightly"]
        api.forgetRequests()
        XCTAssertTrue(page.press("s"))
        XCTAssertEqual(page.writeStatus, .working("Checking… cronjob shop/nightly"), "said while it is reviewed and read")
        XCTAssertTrue(page.press("s"), "a second s meanwhile is the list's…")
        try await until("asked") { box.confirmations.count == 1 }
        XCTAssertNil(page.writeStatus, "the confirmation shows: nothing more to say")
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(box.confirmations.count, 1, "…but starts no second write: two triggers would make two Jobs")
        XCTAssertEqual(api.requests.filter { $0.path.hasSuffix("/cronjobs/nightly") }.count, 1, "read once")
        XCTAssertTrue(reviewed().contains(["verb": "create", "resource": "jobs", "group": "batch", "namespace": "shop"]), "\(reviewed())")
        let order = api.requests.map(\.description)
        let review = try XCTUnwrap(order.firstIndex(of: "POST /apis/authorization.k8s.io/v1/selfsubjectaccessreviews"))
        let read = try XCTUnwrap(order.firstIndex(of: "GET /apis/batch/v1/namespaces/shop/cronjobs/nightly"))
        XCTAssertLessThan(review, read, "reviewed before it is read")
        XCTAssertEqual(written(), [], "nothing made before the button")
        let (confirmation, then) = box.confirmations[0]
        XCTAssertEqual(confirmation.title, "Trigger cronjob shop/nightly now?")
        XCTAssertEqual(confirmation.scope, "kind-fake · namespace shop")
        XCTAssertNil(confirmation.typedName)
        XCTAssertEqual(confirmation.kubectl, "kubectl create job nightly-manual-x2b4k --from=cronjob/nightly --context kind-fake -n shop")
        then("")
        try await until("made") { self.api.names("jobs.batch") == ["nightly-manual-x2b4k"] }
        XCTAssertEqual(written().map(\.description), ["POST /apis/batch/v1/namespaces/shop/jobs"])
        XCTAssertEqual(written().first?.query["fieldManager"], "overterm")
        let jobKind = try XCTUnwrap(page.model.discovery?.kind("jobs"))
        let job = try await KubeClient(KubeSocketConnection(socket: socket, context: "kind-fake")).object(jobKind, namespace: "shop", name: "nightly-manual-x2b4k")
            .json
        let metadata = try XCTUnwrap(job["metadata"] as? [String: Any])
        XCTAssertEqual((metadata["annotations"] as? [String: String])?["cronjob.kubernetes.io/instantiate"], "manual")
        XCTAssertEqual((metadata["labels"] as? [String: String])?["app"], "nightly")
        XCTAssertEqual(
            (metadata["ownerReferences"] as? [[String: Any]])?.first?["uid"] as? String, api.uid("cronjobs.batch", "nightly", namespace: "shop"))
        try await until("said") {
            page.writeStatus == .done("Triggered cronjob shop/nightly in kind-fake: job shop/nightly-manual-x2b4k made.")
        }
    }

    /// `p` on a CronJob: suspended (its row says True by the watch), then
    /// resumed — the row decides which; the menu greys the one that's so.
    func testSuspendAndResumeACronJob() async throws {
        let (page, box) = try await page(current: "kind-fake")
        defer { page.model.hide() }
        _ = try await show(page, "cj", rows: 1)
        page.selection = ["shop/nightly"]
        try await until("Resume Schedule greyed: it isn't suspended") {
            page.verbs(for: ["shop/nightly"]).first { $0.title == "Resume Schedule…" }?.unavailable == "cronjob shop/nightly isn't suspended."
        }
        XCTAssertTrue(page.press("p"))
        try await until("asked") { box.confirmations.count == 1 }
        XCTAssertEqual(box.confirmations[0].0.title, "Suspend cronjob shop/nightly?")
        box.confirmations[0].1("")
        try await until("its row says so") { self.suspendCell(page) == "True" }
        let suspend = try XCTUnwrap(written().last)
        XCTAssertEqual(suspend.description, "PATCH /apis/batch/v1/namespaces/shop/cronjobs/nightly")
        XCTAssertEqual(suspend.contentType, "application/merge-patch+json")
        XCTAssertEqual(String(decoding: suspend.body, as: UTF8.self), #"{"spec":{"suspend":true}}"#)
        XCTAssertEqual(page.verbs(for: ["shop/nightly"]).first { $0.title == "Suspend…" }?.unavailable, "cronjob shop/nightly is suspended already.")
        page.write(.suspend, on: try XCTUnwrap(page.ref(for: "shop/nightly")))
        try await until("the menu's Suspend refused") { page.writeStatus == .failed("cronjob shop/nightly is suspended already.") }
        XCTAssertTrue(page.press("p"))
        try await until("asked again") { box.confirmations.count == 2 }
        XCTAssertEqual(box.confirmations[1].0.title, "Resume cronjob shop/nightly's schedule?")
        box.confirmations[1].1("")
        try await until("resumed") { self.suspendCell(page) == "False" }
        XCTAssertEqual(String(decoding: try XCTUnwrap(written().last).body, as: UTF8.self), #"{"spec":{"suspend":false}}"#)
        XCTAssertEqual(written().count, 2)
    }

    /// `p` twice before the watch has the row say so (its coalescing, a
    /// watch stale after sleep): the object read turns the second round
    /// to a resume rather than refusing it as suspended already.
    func testPAgainBeforeTheRowFollowsTurnsRound() async throws {
        let (page, box) = try await page(current: "kind-fake")
        defer { page.model.hide() }
        // The row's Suspend held at False whatever the spec says: behind it.
        api.update("cronjobs.batch", "nightly", namespace: "shop", values: ["Suspend": "False"])
        _ = try await show(page, "cj", rows: 1)
        page.selection = ["shop/nightly"]
        XCTAssertTrue(page.press("p"))
        try await until("asked") { box.confirmations.count == 1 }
        XCTAssertEqual(box.confirmations[0].0.title, "Suspend cronjob shop/nightly?")
        box.confirmations[0].1("")
        try await until("suspended") { page.writeStatus == .done("Suspended cronjob shop/nightly in kind-fake: no Job is scheduled until it is resumed.") }
        XCTAssertEqual(suspendCell(page), "False", "the row is behind")
        XCTAssertTrue(page.press("p"))
        try await until("asked again") { box.confirmations.count == 2 || page.writeStatus?.isFailure == true }
        XCTAssertEqual(box.confirmations.last?.0.title, "Resume cronjob shop/nightly's schedule?", "\(String(describing: page.writeStatus))")
        box.confirmations[1].1("")
        try await until("resumed") { self.written().count == 2 }
        XCTAssertEqual(String(decoding: try XCTUnwrap(written().last).body, as: UTF8.self), #"{"spec":{"suspend":false}}"#)
    }

    private func suspendCell(_ page: KubernetesPageModel) -> String? {
        page.model.rows[KubeRowID(namespace: "shop", name: "nightly")]?.cell("Suspend", in: page.model.rows.columns)?.text
    }

    // MARK: Rollouts

    /// `p` on a Deployment: its rows don't say whether it is paused, so it
    /// is read after the review — paused, then on the next `p` turned
    /// round to a resume by that read.
    func testPauseAndResumeARollout() async throws {
        let (page, box) = try await page(current: "kind-fake")
        defer { page.model.hide() }
        _ = try await show(page, "deploy", rows: 1)
        page.selection = ["shop/web"]
        XCTAssertTrue(page.press("p"))
        try await until("asked") { box.confirmations.count == 1 }
        XCTAssertTrue(reviewed().contains(["verb": "patch", "resource": "deployments", "group": "apps", "namespace": "shop"]))
        XCTAssertEqual(box.confirmations[0].0.title, "Pause deployment shop/web's rollout?")
        XCTAssertEqual(box.confirmations[0].0.kubectl, "kubectl rollout pause deploy/web --context kind-fake -n shop")
        box.confirmations[0].1("")
        try await until("paused") { self.written().count == 1 }
        XCTAssertEqual(written()[0].description, "PATCH /apis/apps/v1/namespaces/shop/deployments/web")
        XCTAssertEqual(written()[0].contentType, "application/strategic-merge-patch+json")
        try await until("said") { page.writeStatus == .done("Paused deployment shop/web's rollout in kind-fake.") }
        XCTAssertTrue(page.press("p"))
        try await until("asked again") { box.confirmations.count == 2 }
        XCTAssertEqual(box.confirmations[1].0.title, "Resume deployment shop/web's rollout?", "read paused: turned round")
        box.confirmations[1].1("")
        try await until("resumed") { self.written().count == 2 }
        XCTAssertEqual(String(decoding: written()[1].body, as: UTF8.self), #"{"spec":{"paused":null}}"#)
        let spec = try await KubeClient(KubeSocketConnection(socket: socket, context: "kind-fake")).spec(try XCTUnwrap(page.ref(for: "shop/web")))
        XCTAssertNil((spec["spec"] as? [String: Any])?["paused"])
        // The menu's Resume, not a toggle: refused once read so.
        page.write(.resume, on: try XCTUnwrap(page.ref(for: "shop/web")))
        try await until("refused") { page.writeStatus == .failed("deployment shop/web's rollout isn't paused.") }
        XCTAssertEqual(box.confirmations.count, 2, "not asked")
    }

    // MARK: Nodes

    /// `u`: cordoned — its row says SchedulingDisabled — then uncordoned.
    func testCordonAndUncordonANode() async throws {
        let (page, box) = try await page(current: "kind-fake")
        defer { page.model.hide() }
        _ = try await show(page, "no", rows: 1)
        page.selection = ["fake-node-1"]
        XCTAssertTrue(page.press("u"))
        try await until("asked") { box.confirmations.count == 1 }
        XCTAssertTrue(reviewed().contains(["verb": "patch", "resource": "nodes", "group": ""]), "cluster-wide: no namespace in the review — \(reviewed())")
        let (confirmation, then) = box.confirmations[0]
        XCTAssertEqual(confirmation.title, "Cordon node fake-node-1?")
        XCTAssertEqual(confirmation.scope, "kind-fake · cluster-wide")
        XCTAssertEqual(confirmation.kubectl, "kubectl cordon fake-node-1 --context kind-fake")
        then("")
        try await until("its row says SchedulingDisabled") { self.statusCell(page) == "Ready,SchedulingDisabled" }
        XCTAssertEqual(written().map(\.description), ["PATCH /api/v1/nodes/fake-node-1"])
        XCTAssertEqual(page.verbs(for: ["fake-node-1"]).first { $0.title == "Cordon…" }?.unavailable, "node fake-node-1 is cordoned already.")
        XCTAssertTrue(page.press("u"))
        try await until("asked again") { box.confirmations.count == 2 }
        XCTAssertEqual(box.confirmations[1].0.title, "Uncordon node fake-node-1?")
        box.confirmations[1].1("")
        try await until("schedulable again") { self.statusCell(page) == "Ready" }
        XCTAssertEqual(String(decoding: try XCTUnwrap(written().last).body, as: UTF8.self), #"{"spec":{"unschedulable":null}}"#)
    }

    private func statusCell(_ page: KubernetesPageModel) -> String? {
        page.model.rows[KubeRowID(namespace: nil, name: "fake-node-1")]?.cell("Status", in: page.model.rows.columns)?.text
    }

    // MARK: Namespaces

    /// `N`: the sheet, its name checked as a DNS label, then create
    /// namespaces reviewed and the POST asked for; a name taken is said.
    func testANamespaceIsMadeFromTheSheet() async throws {
        let (page, box) = try await page(current: "kind-fake")
        defer { page.model.hide() }
        XCTAssertTrue(page.press("N"))
        XCTAssertEqual(page.namespaceDraft?.context, "kind-fake")
        XCTAssertFalse(page.press("p"), "the sheet's field has the keys")
        page.namespaceDraft?.name = "Scratch"
        page.confirmNamespace()
        XCTAssertEqual(page.namespaceDraft?.problem, "Lowercase only: scratch?")
        XCTAssertTrue(box.confirmations.isEmpty)
        page.namespaceDraft?.name = "scratch"
        page.confirmNamespace()
        XCTAssertNil(page.namespaceDraft)
        try await until("asked") { box.confirmations.count == 1 }
        XCTAssertTrue(reviewed().contains(["verb": "create", "resource": "namespaces", "group": ""]), "\(reviewed())")
        XCTAssertEqual(box.confirmations[0].0.title, "Create namespace scratch?")
        XCTAssertEqual(box.confirmations[0].0.kubectl, "kubectl create namespace scratch --context kind-fake")
        XCTAssertNil(box.confirmations[0].0.typedName)
        XCTAssertEqual(written(), [])
        box.confirmations[0].1("")
        try await until("made") { self.api.names("namespaces").contains("scratch") }
        XCTAssertEqual(written().map(\.description), ["POST /api/v1/namespaces"])
        try await until("said") { page.writeStatus == .done("Made namespace scratch in kind-fake.") }

        XCTAssertTrue(page.press("N"))
        page.namespaceDraft?.name = "shop"
        page.confirmNamespace()
        try await until("asked") { box.confirmations.count == 2 }
        box.confirmations[1].1("")
        try await until("taken, said") { page.writeStatus == .failed(#"namespace shop is there already: namespaces "shop" already exists"#) }
    }

    /// ⌫ on a namespace: what it holds counted from Tables (rows alone),
    /// the name typed on a local context too; a wrong one sends nothing.
    func testANamespacesDeleteWarnsAndAsksForItsName() async throws {
        api.addNamespace("scratch")
        api.addPod("a-1", namespace: "scratch")
        api.addPod("a-2", namespace: "scratch")
        api.add("secrets", "token", namespace: "scratch", values: ["Type": "Opaque"], data: ["key": "fake-value-not-real"])
        let (page, box) = try await page(current: "kind-fake")
        defer { page.model.hide() }
        _ = try await show(page, "ns", rows: 2)
        page.selection = ["scratch"]
        api.forgetRequests()
        XCTAssertTrue(page.press("\u{7F}"))
        try await until("asked") { box.confirmations.count == 1 }
        let (confirmation, then) = box.confirmations[0]
        XCTAssertEqual(confirmation.title, "Delete namespace scratch and everything in it?")
        XCTAssertEqual(confirmation.typedName, "scratch", "a namespace's name on every class")
        XCTAssertTrue(confirmation.detail.hasPrefix("Among the kinds Overterm counts, it holds 2 pods and 1 secret."), confirmation.detail)
        let counted = api.requests.filter { $0.method == "GET" && $0.path.hasPrefix("/api/v1/namespaces/scratch/") }
        XCTAssertFalse(counted.isEmpty)
        XCTAssertTrue(counted.allSatisfy { $0.query["includeObject"] == "None" && $0.accept.contains("as=Table") }, "rows alone, never an object")
        XCTAssertFalse(api.requests.contains { $0.path == "/api/v1/namespaces/scratch/secrets/token" }, "no Secret read")
        then("scratc")
        XCTAssertEqual(page.writeStatus, .failed("The name typed wasn't scratch: nothing was changed."))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(written(), [])
        XCTAssertTrue(page.press("\u{7F}"))
        try await until("asked again") { box.confirmations.count == 2 }
        box.confirmations[1].1("scratch")
        try await until("gone, with what it held") { !self.api.names("namespaces").contains("scratch") && self.api.pod("a-1", namespace: "scratch") == nil }
        XCTAssertEqual(written().map(\.description), ["DELETE /api/v1/namespaces/scratch"])
        try await until("the list follows") { page.model.rows.count == 1 }
    }

    // MARK: Refusals

    /// fake-dev: every new verb greyed with why, every key refused at once;
    /// not even a review leaves.
    func testAReadOnlyContextRefusesEachWithWhy() async throws {
        let (page, box) = try await page(current: "fake-dev")
        defer { page.model.hide() }
        let readOnly = "This context is read-only: Overterm changes nothing here (its writable setting)."
        for (kind, row, rows, keys) in [("cj", "shop/nightly", 1, ["s", "p"]), ("deploy", "shop/web", 1, ["p"]), ("no", "fake-node-1", 1, ["u"])] {
            _ = try await show(page, kind, rows: rows)
            page.selection = [row]
            let writes = page.verbs(for: [row]).filter { KubeWriteVerb.allCases.map(\.title).contains($0.title) }
            XCTAssertFalse(writes.isEmpty)
            XCTAssertTrue(writes.allSatisfy { $0.unavailable == readOnly }, "\(kind): \(writes.map(\.unavailable))")
            for key in keys {
                page.writeStatus = nil
                XCTAssertTrue(page.press(key), key)
                XCTAssertEqual(page.writeStatus, .failed(readOnly), key)
            }
        }
        XCTAssertTrue(page.press("N"))
        XCTAssertNil(page.namespaceDraft, "no sheet")
        XCTAssertEqual(page.writeStatus, .failed(readOnly))
        // A namespace's delete: greyed, ⌫ refused at once — no review, and
        // not one of the counting reads.
        _ = try await show(page, "ns", rows: 1)
        page.selection = ["shop"]
        XCTAssertEqual(page.verbs(for: ["shop"]).first { $0.title == KubeWriteVerb.delete.title }?.unavailable, readOnly)
        api.forgetRequests()
        page.writeStatus = nil
        XCTAssertTrue(page.press("\u{7F}"))
        XCTAssertEqual(page.writeStatus, .failed(readOnly))
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(box.confirmations.isEmpty)
        XCTAssertEqual(api.writes, [], "nothing but GETs")
        XCTAssertFalse(api.requests.contains { $0.path.contains("/namespaces/shop/") }, "nothing counted: \(api.requests.map(\.description))")
    }

    /// The review's no stops a trigger before the CronJob is read.
    func testARefusedReviewStopsATriggerBeforeAnyRead() async throws {
        api.deniedAccess = ["create jobs.batch"]
        let (page, box) = try await page(current: "kind-fake")
        defer { page.model.hide() }
        _ = try await show(page, "cj", rows: 1)
        page.selection = ["shop/nightly"]
        api.forgetRequests()
        XCTAssertTrue(page.press("s"))
        let why = "The cluster's access review says you may not create jobs.batch in shop: RBAC: create jobs.batch is not allowed"
        try await until("said") { page.writeStatus == .failed(why) }
        XCTAssertTrue(box.confirmations.isEmpty)
        XCTAssertFalse(api.requests.contains { $0.path.hasSuffix("/cronjobs/nightly") }, "not read")
        XCTAssertEqual(written(), [])
        XCTAssertEqual(page.verbs(for: ["shop/nightly"]).first { $0.title == "Trigger Now…" }?.unavailable, why)
    }

    /// Production: writable with no switch — a cordon and a trigger are
    /// asked naming PRODUCTION, with no name to type, and a namespace's
    /// delete asks for its name; set read-only by its setting meanwhile,
    /// each is refused again at the button.
    func testProductionAsksNamingItAndItsSettingStillLocks() async throws {
        let (page, box) = try await page(current: "fake-prod")
        defer { page.model.hide() }
        _ = try await show(page, "no", rows: 1)
        XCTAssertEqual(page.model.selected?.isWritable, true)
        XCTAssertTrue(box.confirms.isEmpty, "no switch asked for")
        page.selection = ["fake-node-1"]
        XCTAssertTrue(page.press("u"))
        try await until("asked") { box.confirmations.count == 1 }
        XCTAssertEqual(box.confirmations[0].0.scope, "PRODUCTION · fake-prod · cluster-wide")
        XCTAssertTrue(box.confirmations[0].0.production)
        XCTAssertNil(box.confirmations[0].0.typedName)
        // A trigger: PRODUCTION named, no name to type.
        _ = try await show(page, "cj", rows: 1)
        page.selection = ["shop/nightly"]
        XCTAssertTrue(page.press("s"))
        try await until("the trigger asked") { box.confirmations.count == 2 }
        XCTAssertEqual(box.confirmations[1].0.title, "Trigger cronjob shop/nightly now?")
        XCTAssertEqual(box.confirmations[1].0.scope, "PRODUCTION · fake-prod · namespace shop")
        XCTAssertTrue(box.confirmations[1].0.production)
        XCTAssertNil(box.confirmations[1].0.typedName)
        // A namespace's delete: its name typed, as on every class.
        _ = try await show(page, "ns", rows: 1)
        page.selection = ["shop"]
        XCTAssertTrue(page.press("\u{7F}"))
        try await until("the delete asked") { box.confirmations.count == 3 }
        XCTAssertEqual(box.confirmations[2].0.scope, "PRODUCTION · fake-prod · cluster-wide")
        XCTAssertEqual(box.confirmations[2].0.typedName, "shop")
        XCTAssertTrue(box.confirmations[2].0.detail.contains("Type shop to confirm."), box.confirmations[2].0.detail)
        contexts.setReadOnly("fake-prod", true)
        page.model.reloadContexts()
        try await until("read-only") { page.model.selected?.isWritable == false }
        for (index, typed) in [(0, ""), (1, ""), (2, "shop")] {
            page.writeStatus = nil
            box.confirmations[index].1(KubeWriteAnswer(typed: typed))
            XCTAssertEqual(
                page.writeStatus, .failed("This context is read-only: Overterm changes nothing here (its writable setting)."), "checked again at the button")
        }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(written(), [])
    }
}
