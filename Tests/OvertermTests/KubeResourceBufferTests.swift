import AppKit
import Foundation
import XCTest

@testable import Overterm

/// A cluster object's YAML in the editor (2.8), against `FakeKubeAPI` on a
/// socket of the test's own — never ~/.kube, over fictional contexts on it
/// (`kind-fake` writable, `fake-dev` read-only): one buffer per resource,
/// the same one the detail's YAML tab and the window's editor show; a
/// change on the cluster taken quietly without edits and held for the
/// banner with them; Apply greyed with why on a read-only context, the
/// buffer still edited and diffed; a Secret masked, never sent masked,
/// never followed; nothing ever written to disk.
@MainActor
final class KubeResourceBufferTests: XCTestCase {
    nonisolated(unsafe) private var api: FakeKubeAPI!
    nonisolated(unsafe) private var socket: String!

    final class Host: KubeManifestHost {
        var asked: [KubeWriteConfirmation] = []
        func askManifestWrite(_ confirmation: KubeWriteConfirmation) async -> String? {
            asked.append(confirmation)
            return ""
        }
        func askManifest(_ title: String, _ detail: String, _ button: String) async -> Bool { true }
        func showManifestDiff(_ session: KubeManifestSession) {}
    }

    override func setUpWithError() throws {
        socket = "/tmp/otkrb-\(UInt32.random(in: 0...UInt32.max)).sock"
        api = FakeKubeAPI(socket: socket)
        try api.start()
        Self.seed(api)
    }

    nonisolated private static func seed(_ api: FakeKubeAPI) {
        api.addNamespace("shop")
        api.add(
            "deployments.apps", "web", namespace: "shop", values: ["Ready": "1/1", "Up-to-date": 1, "Available": 1],
            fields: ["spec": ["replicas": 1, "template": ["metadata": ["labels": ["app": "web"]]]], "status": ["replicas": 1]])
        api.setManagedFields(
            "deployments.apps", "web", namespace: "shop",
            [["manager": "kubectl", "operation": "Update", "apiVersion": "apps/v1", "fieldsType": "FieldsV1", "fieldsV1": ["f:spec": [String: Any]()]]])
        api.add("secrets", "web-db", namespace: "shop", values: ["Type": "Opaque"], data: ["password": "old-pw-Q7z", "username": "web"])
    }

    override func tearDown() {
        api?.stop()
    }

    private func model() -> KubernetesModel {
        let model = KubernetesModel(proxies: KubeProxies())
        model.load = { _ in
            KubeContextList(contexts: [KubeWritesTests.context("fake-dev"), KubeWritesTests.context("kind-fake")], current: "kind-fake")
        }
        model.readConfiguration = { KubernetesModel.Configuration() }
        model.watchesSettings = false
        model.remembersSelection = false
        let socket = self.socket!
        model.connectOverride = { context in KubeSocketConnection(socket: socket, context: context.name, writable: context.isWritable) }
        model.statusOverride = { _ in .open }
        return model
    }

    private func ref(_ context: String = "kind-fake", secret: Bool = false) -> KubeObjectRef {
        secret
            ? KubeObjectRef(context: context, kind: KubeApplyTests.secrets, namespace: "shop", name: "web-db")
            : KubeObjectRef(context: context, kind: KubeWritesTests.deployments, namespace: "shop", name: "web")
    }

    /// Its reads through the test's socket, as the page's would go.
    private func resource(_ model: KubernetesModel, _ ref: KubeObjectRef) -> KubeResourceBuffer {
        let resource = model.resourceBuffers.buffer(for: ref)
        let socket = self.socket!
        let writable = ref.context == "kind-fake"
        resource.client = { KubeClient(KubeSocketConnection(socket: socket, context: ref.context, writable: writable)) }
        return resource
    }

    private func editor(embedded: Bool = false) -> EditorViewController {
        let editor = EditorViewController(
            theme: ChromeTheme(background: .black, foreground: .white), background: .black, foreground: .white, opener: ExternalOpener(), embedded: embedded)
        _ = editor.view
        return editor
    }

    private func deployment(replicas: Int, version: String, image: String? = nil) -> [String: Any] {
        var spec: [String: Any] = ["replicas": replicas]
        if let image { spec["template"] = ["spec": ["containers": [["name": "web", "image": image]]]] }
        return [
            "apiVersion": "apps/v1", "kind": "Deployment",
            "metadata": [
                "name": "web", "namespace": "shop", "resourceVersion": version, "uid": "u-1",
                "managedFields": [["manager": "kubectl", "operation": "Update"]],
            ],
            "spec": spec, "status": ["replicas": replicas, "observedGeneration": Int(version) ?? 1],
        ]
    }

    private func until(_ timeout: TimeInterval = 5, _ what: String = "", _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return XCTFail("timed out: \(what)") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    // MARK: One buffer, two editors

    func testOneBufferPerResourceTheTabAndTheEditorShare() throws {
        let model = model()
        let resource = resource(model, ref())
        XCTAssertTrue(model.resourceBuffers.buffer(for: ref()) === resource, "one per resource")
        XCTAssertTrue(model.resourceBuffers.resource(at: resource.url) === resource, "found by its name in the editor")
        resource.take(deployment(replicas: 1, version: "5"))
        let text = resource.buffer.storage.string
        XCTAssertTrue(text.contains("replicas: 1"), text)
        XCTAssertFalse(text.contains("managedFields") || text.contains("status:") || text.contains("resourceVersion"), "trimmed as the tab trims it")
        XCTAssertEqual(resource.resourceVersion, "5", "its version kept beside it")
        XCTAssertEqual(KubeManifestEdits.edit(at: resource.url)?.resourceVersion, "5", "and sent with the apply")

        // The detail's tab (embedded) and the window's editor (`y`): the same buffer.
        let detail = NSObject()
        model.resourceBuffers.hold(resource, by: detail)
        let tab = editor(embedded: true)
        tab.showOnly(resource.buffer)
        let window = editor()
        window.adopt(resource.buffer)
        XCTAssertTrue(tab.active === resource.buffer && window.active === resource.buffer, "no second copy")
        XCTAssertEqual(window.buffers.count, 1)
        window.adopt(resource.buffer)
        XCTAssertEqual(window.buffers.count, 1, "y again: the tab it has")

        // Typed in the window's editor, seen in the tab.
        window.replaceText(of: resource.buffer, with: text.replacingOccurrences(of: "replicas: 1", with: "replicas: 4"))
        XCTAssertTrue(tab.textView.string.contains("replicas: 4"), "the same edits")
        XCTAssertTrue(resource.isEdited)
        XCTAssertEqual(window.unsavedNames, [resource.buffer.name], "edits not applied count as unsaved: closing asks")
        // Typed in the tab, seen in the window's editor.
        tab.replaceText(of: resource.buffer, with: tab.textView.string.replacingOccurrences(of: "replicas: 4", with: "replicas: 6"))
        XCTAssertTrue(window.textView.string.contains("replicas: 6"))

        // Never a file: a save is refused, nothing at its name.
        window.save(resource.buffer, overwriting: false)
        XCTAssertEqual(resource.session.state, .done(KubeManifestEdits.unsaved))
        XCTAssertThrowsError(try resource.buffer.document.save("x", overwriting: true))
        XCTAssertFalse(FileManager.default.fileExists(atPath: resource.url.path), "nothing written, ever")
        XCTAssertTrue(resource.buffer.document.isVirtual)

        // Both let go while it has edits: kept — they are nowhere else.
        window.removeBuffer(at: 0)
        tab.showOnly(nil)
        model.resourceBuffers.release(resource, by: detail)
        XCTAssertTrue(model.resourceBuffers.existing(ref()) === resource, "its edits keep it")
        XCTAssertTrue(resource.buffer.storage.string.contains("replicas: 6"), "the edits as they were")
        // Reverted, held by nobody: it goes.
        resource.revert()
        XCTAssertFalse(resource.isEdited)
        XCTAssertNil(model.resourceBuffers.existing(ref()), "nothing kept for an object without edits")
        XCTAssertNil(KubeManifestEdits.edit(at: resource.url))
    }

    // MARK: The banner

    func testTheBannerRule() {
        XCTAssertEqual(KubeResourceBuffer.rule(loaded: false, edited: false, sameVersion: false, sameText: false), .replace, "the first read")
        XCTAssertEqual(KubeResourceBuffer.rule(loaded: true, edited: false, sameVersion: false, sameText: false), .replace, "followed quietly")
        XCTAssertEqual(KubeResourceBuffer.rule(loaded: true, edited: true, sameVersion: false, sameText: false), .banner, "never over edits")
        XCTAssertEqual(KubeResourceBuffer.rule(loaded: true, edited: true, sameVersion: true, sameText: false), .keep, "the same object")
        XCTAssertEqual(KubeResourceBuffer.rule(loaded: true, edited: true, sameVersion: false, sameText: true), .keep, "only its status moved")

        let model = model()
        let resource = resource(model, ref())
        resource.take(deployment(replicas: 1, version: "5"))
        // Without edits: the cluster's change replaces the text, quietly.
        resource.take(deployment(replicas: 2, version: "6"))
        XCTAssertTrue(resource.buffer.storage.string.contains("replicas: 2"))
        XCTAssertNil(resource.clusterChange)
        XCTAssertEqual(resource.resourceVersion, "6")
        XCTAssertFalse(resource.isEdited)

        // With edits: held for the banner, the edits untouched.
        let window = editor()
        window.adopt(resource.buffer)
        let edited = resource.buffer.storage.string.replacingOccurrences(of: "replicas: 2", with: "replicas: 9")
        window.replaceText(of: resource.buffer, with: edited)
        resource.take(deployment(replicas: 3, version: "7", image: "acme/web:2"))
        XCTAssertEqual(resource.buffer.storage.string, edited, "the edits never overwritten")
        guard case .changed(let newer, let version) = resource.clusterChange else { return XCTFail("the banner: \(String(describing: resource.clusterChange))") }
        XCTAssertTrue(newer.contains("replicas: 3") && newer.contains("acme/web:2"))
        XCTAssertEqual(version, "7")
        XCTAssertEqual(resource.resourceVersion, "6", "the apply still says what the edits were made on")
        XCTAssertEqual(KubeResourceBanner.said(resource.clusterChange!, resource), "deployment shop/web changed on the cluster — your edits are kept")

        // Reload: the cluster's, the edits dropped.
        resource.reload()
        XCTAssertTrue(window.textView.string.contains("replicas: 3"))
        XCTAssertNil(resource.clusterChange)
        XCTAssertEqual(resource.resourceVersion, "7")
        XCTAssertFalse(resource.isEdited)

        // Deleted while edited: said, the text kept.
        window.replaceText(of: resource.buffer, with: window.textView.string + "# mine\n")
        resource.deleted()
        XCTAssertEqual(resource.clusterChange, .deleted)
        XCTAssertTrue(resource.buffer.storage.string.hasSuffix("# mine\n"))
    }

    func testItFollowsTheClusterWhileItShows() async throws {
        let model = model()
        let resource = resource(model, ref())
        try await resource.load()
        XCTAssertTrue(resource.buffer.storage.string.contains("replicas: 1"))
        let window = editor()
        window.adopt(resource.buffer)
        resource.watch(by: self)
        XCTAssertTrue(resource.isFollowing)
        try await Task.sleep(for: .milliseconds(200))

        // No edits: the cluster's change followed quietly.
        api.setFields("deployments.apps", "web", namespace: "shop", ["spec": ["replicas": 2, "template": ["metadata": ["labels": ["app": "web"]]]]])
        try await until(5, "followed") { resource.buffer.storage.string.contains("replicas: 2") }
        XCTAssertNil(resource.clusterChange)

        // Edits: the next change is the banner's, never written over them.
        let edited = resource.buffer.storage.string.replacingOccurrences(of: "app: web", with: "app: web-edited")
        window.replaceText(of: resource.buffer, with: edited)
        api.setFields("deployments.apps", "web", namespace: "shop", ["spec": ["replicas": 5, "template": ["metadata": ["labels": ["app": "web"]]]]])
        try await until(5, "the banner") { resource.clusterChange != nil }
        XCTAssertEqual(resource.buffer.storage.string, edited)
        XCTAssertTrue(api.writes.isEmpty, "following reads only")

        resource.unwatch(by: self)
        XCTAssertTrue(resource.isFollowing, "the window editor's active tab shows it too")
        window.removeBuffer(at: 0)
        XCTAssertFalse(resource.isFollowing, "nothing watched once nobody shows it")
        XCTAssertTrue(model.resourceBuffers.existing(ref()) === resource, "its edits keep it")
    }

    // MARK: Read-only

    func testOnAReadOnlyContextItIsEditedAndDiffedButApplyIsGreyed() async throws {
        let model = model()
        let resource = resource(model, ref("fake-dev"))
        try await resource.load()
        let host = Host()
        resource.session.host = host
        await resource.session.refreshContexts()
        XCTAssertTrue(resource.session.applyRefusal?.hasPrefix("This context is read-only") == true, resource.session.applyRefusal ?? "none")
        let window = editor()
        window.adopt(resource.buffer)
        window.replaceText(of: resource.buffer, with: resource.buffer.storage.string.replacingOccurrences(of: "replicas: 1", with: "replicas: 3"))
        XCTAssertTrue(resource.isEdited, "the buffer can be edited")
        let diffed = await resource.session.runDiff(show: false)
        let diff = try XCTUnwrap(diffed)
        XCTAssertFalse(diff.isServerSide, "client-side: the read-only socket takes no dry run")
        XCTAssertTrue(diff.items.first?.diff.contains("+  replicas: 3") == true, diff.items.first?.diff ?? "none")
        await resource.session.runApply()
        XCTAssertTrue(resource.session.state.isFailure)
        XCTAssertTrue(host.asked.isEmpty, "never asked")
        XCTAssertTrue(api.writes.isEmpty, "nothing sent")
    }

    // MARK: Secrets

    func testASecretStaysMaskedAndIsNeverSentMasked() async throws {
        let model = model()
        let resource = resource(model, ref(secret: true))
        do {
            try await resource.load()
            XCTFail("a Secret is read only when asked")
        } catch {}
        XCTAssertEqual(resource.state, .empty)
        try await resource.load(secret: true)
        let text = resource.buffer.storage.string
        XCTAssertTrue(text.contains("password: \"***\""), text)
        XCTAssertFalse(text.contains("old-pw-Q7z") || text.contains(Data("old-pw-Q7z".utf8).base64EncodedString()), "no value in the buffer")
        resource.watch(by: self)
        XCTAssertFalse(resource.isFollowing, "a Secret's read is every value: never followed")

        // An edit elsewhere in it: the masks are still there, so nothing is sent.
        let host = Host()
        resource.session.host = host
        let window = editor()
        window.adopt(resource.buffer)
        window.replaceText(of: resource.buffer, with: text.replacingOccurrences(of: "  namespace: shop\n", with: "  namespace: shop\n  labels:\n    tier: db\n"))
        api.forgetRequests()
        await resource.session.runApply()
        XCTAssertTrue(resource.session.state.text?.contains("still holds masked values") == true, "\(resource.session.state)")
        XCTAssertTrue(host.asked.isEmpty)
        XCTAssertTrue(api.writes.isEmpty, "never a masked value sent")
        XCTAssertFalse(FileManager.default.fileExists(atPath: resource.url.path))

        // Another kind's answer that is a Secret is never taken.
        let other = self.resource(model, ref())
        other.take(["apiVersion": "v1", "kind": "Secret", "metadata": ["name": "web"], "data": ["k": "dmFsdWU="]])
        XCTAssertEqual(other.state, .empty)
    }

    // MARK: Following again, only on screen

    func testTheFollowStartsAgainAfterItsStreamEnds() async throws {
        let model = model()
        let resource = resource(model, ref())
        resource.restartDelay = { _ in .milliseconds(50) }
        try await resource.load()
        resource.watch(by: self)
        try await until(5, "the watch opens") { self.api.openWatches == 1 }

        // The server goes (the proxy closed for idle, the socket reopened): the stream ends with an error.
        api.stop()
        try await until(5, "the follow ends") { !resource.isFollowing }
        XCTAssertTrue(resource.wantsFollowing, "still shown: it waits to follow again")
        // It comes back: followed again, its list read again.
        api = FakeKubeAPI(socket: socket)
        try api.start()
        Self.seed(api)
        try await until(10, "followed again") { resource.isFollowing && self.api.openWatches == 1 }
        api.setFields("deployments.apps", "web", namespace: "shop", ["spec": ["replicas": 4, "template": ["metadata": ["labels": ["app": "web"]]]]])
        try await until(5, "a change reaches it again") { resource.buffer.storage.string.contains("replicas: 4") }

        resource.unwatch(by: self)
        XCTAssertFalse(resource.wantsFollowing, "nobody shows it: nothing started again")
    }

    func testNoClientYetIsTriedAgainWhileItShows() async throws {
        let model = model()
        let resource = resource(model, ref())
        let client = resource.client
        resource.restartDelay = { _ in .milliseconds(50) }
        try await resource.load()
        resource.client = { nil }
        resource.watch(by: self)
        XCTAssertFalse(resource.isFollowing)
        XCTAssertTrue(resource.wantsFollowing, "tried again while it shows")
        resource.client = client
        try await until(5, "followed once there is a client") { resource.isFollowing }
        resource.unwatch(by: self)
        XCTAssertFalse(resource.wantsFollowing)
    }

    func testTheWindowEditorFollowsOnlyWhileOnScreen() async throws {
        let model = model()
        let resource = resource(model, ref())
        try await resource.load()
        let window = editor()
        window.adopt(resource.buffer)
        XCTAssertTrue(resource.isFollowing && window.watching === resource, "its active tab, on screen")
        window.isOnScreen = false
        XCTAssertFalse(resource.wantsFollowing, "its pane hidden, a page over it, the window away: nothing read")
        window.isOnScreen = true
        XCTAssertTrue(resource.isFollowing, "back on screen")

        // The window closes: nothing followed or held for it, the buffer gone without edits.
        window.releaseResources()
        XCTAssertFalse(resource.wantsFollowing)
        XCTAssertTrue(window.buffers.isEmpty)
        XCTAssertNil(model.resourceBuffers.existing(ref()), "held by nobody, no edits: gone")
    }

    // MARK: Edits, wherever they were made

    func testEveryEditorSaysTheSameEdits() throws {
        let model = model()
        let resource = resource(model, ref())
        resource.take(deployment(replicas: 1, version: "5"))
        let detail = NSObject()
        model.resourceBuffers.hold(resource, by: detail)
        let tab = editor(embedded: true)
        tab.showOnly(resource.buffer)
        let window = editor()
        window.adopt(resource.buffer)
        let text = resource.buffer.storage.string

        tab.replaceText(of: resource.buffer, with: text.replacingOccurrences(of: "replicas: 1", with: "replicas: 3"))
        XCTAssertTrue(resource.buffer.document.isDirty, "typed in the tab: the window's tab marked too")
        XCTAssertEqual(window.unsavedNames, [resource.buffer.name])
        // Undone back to what the cluster has, in the other editor: no edits anywhere.
        window.replaceText(of: resource.buffer, with: text)
        XCTAssertFalse(resource.isEdited)
        XCTAssertFalse(resource.buffer.document.isDirty, "no dot once it is as the cluster has it")
        XCTAssertTrue(window.unsavedNames.isEmpty)

        // Edited only in the tab, the detail moved on: kept, and counted for the window's close and the quit.
        tab.replaceText(of: resource.buffer, with: text.replacingOccurrences(of: "replicas: 1", with: "replicas: 8"))
        window.removeBuffer(at: 0)
        tab.showOnly(nil)
        model.resourceBuffers.release(resource, by: detail)
        XCTAssertEqual(model.resourceBuffers.edited.map(\.buffer.name), [resource.buffer.name], "the close and quit questions read these")
        XCTAssertTrue(
            KubernetesPageModel.keptEdits(ref()).hasPrefix("Your edits to deployment shop/web's YAML are kept"), KubernetesPageModel.keptEdits(ref()))
        resource.revert()
        XCTAssertTrue(model.resourceBuffers.edited.isEmpty)
    }

    func testAnAppliedSecretIsMaskedAgainInTheBuffer() async throws {
        let model = model()
        let resource = resource(model, ref(secret: true))
        try await resource.load(secret: true)
        let host = Host()
        resource.session.host = host
        let window = editor()
        window.adopt(resource.buffer)
        let newPassword = Data("new-pw-K8m".utf8).base64EncodedString()
        let newUser = Data("web2".utf8).base64EncodedString()
        let typed = resource.buffer.storage.string
            .replacingOccurrences(of: "password: \"***\"", with: "password: \(newPassword)")
            .replacingOccurrences(of: "username: \"***\"", with: "username: \(newUser)")
        window.replaceText(of: resource.buffer, with: typed)
        XCTAssertTrue(resource.isEdited)
        await resource.session.runApply()
        XCTAssertEqual(resource.session.state, .done("Applied secret shop/web-db to kind-fake."), "\(resource.session.state)")
        let data = api.object("secrets", "web-db", namespace: "shop")?["data"] as? [String: String]
        XCTAssertEqual(data?["password"], newPassword, "the values typed were applied")

        let text = resource.buffer.storage.string
        XCTAssertTrue(text.contains("password: \"***\"") && text.contains("username: \"***\""), text)
        XCTAssertFalse(text.contains(newPassword) || text.contains(newUser) || text.contains("new-pw-K8m"), "no value left in the buffer")
        XCTAssertFalse(window.textView.string.contains(newPassword), "nor in what the editor shows")
        XCTAssertFalse(resource.buffer.undo.canUndo, "nor in its undo")
        XCTAssertFalse(resource.isEdited, "the masks are what the cluster has")
        XCTAssertFalse(resource.buffer.document.isDirty)
    }

    func testOnlyWhatIsTypedInClearIsMaskedAgain() {
        let shown: ([String: Any]) -> String = { KubeYAML.text(KubeManifestDiff.forEditing($0)) }
        let plain = "apiVersion: apps/v1\nkind: Deployment\nmetadata:\n  name: web\nspec:\n  replicas: 2\n"
        XCTAssertNil(KubeResourceBuffer.masked(plain, as: shown), "nothing secret: the text as typed")
        let env =
            "apiVersion: v1\nkind: Pod\nmetadata:\n  name: web\nspec:\n  containers:\n  - name: web\n    env:\n    - name: DB_PASSWORD\n      value: hunter2-Zq\n"
        let masked = KubeResourceBuffer.masked(env, as: shown)
        XCTAssertNotNil(masked)
        XCTAssertFalse(masked?.contains("hunter2-Zq") ?? true, masked ?? "none")
    }
}
