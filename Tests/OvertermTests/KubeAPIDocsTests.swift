import Foundation
import XCTest

@testable import Overterm

/// The cluster's docs read from `FakeKubeAPI` on a socket of the test's own
/// (3.15), never a real cluster: GETs only, read when asked and not before,
/// cached per context and server version, the cache bounded; a manifest's
/// hover, completion and marks, and the explain view, against it.
@MainActor
final class KubeAPIDocsTests: XCTestCase {
    nonisolated(unsafe) private var api: FakeKubeAPI!
    nonisolated(unsafe) private var socket: String!

    override func setUpWithError() throws {
        socket = "/tmp/otkdoc-\(UInt32.random(in: 0...UInt32.max)).sock"
        api = FakeKubeAPI(socket: socket)
        try api.start()
        api.addNamespace("shop")
    }

    override func tearDown() { api?.stop() }

    private func client(_ context: String = "fake-dev") -> KubeClient { KubeClient(KubeSocketConnection(socket: socket, context: context)) }

    private func model() -> KubernetesModel {
        let model = KubernetesModel(proxies: KubeProxies())
        model.load = { _ in
            KubeContextList(contexts: [KubeWritesTests.context("fake-dev"), KubeWritesTests.context("fake-prod"), KubeWritesTests.context("kind-fake")], current: "fake-dev")
        }
        model.readConfiguration = { KubernetesModel.Configuration() }
        model.watchesSettings = false
        model.remembersSelection = false
        let socket = self.socket!
        model.connectOverride = { context in KubeSocketConnection(socket: socket, context: context.name, writable: context.isWritable) }
        model.statusOverride = { _ in .open }
        return model
    }

    private var docsRequests: [FakeKubeAPI.Request] { api.requests.filter { $0.path.hasPrefix("/openapi") || $0.path == "/version" } }

    private static let deployment = KubeGVK(group: "apps", version: "v1", kind: "Deployment")

    // MARK: The cache

    func testReadOnceWithGETsThenCached() async throws {
        let docs = KubeAPIDocs()
        let context = KubeWritesTests.context("fake-dev")
        XCTAssertNil(docs.cached(Self.deployment, context: context), "nothing until asked")
        XCTAssertTrue(api.requests.isEmpty)
        let (document, source) = try await docs.document(Self.deployment, context: context, client: client())
        XCTAssertEqual(source.said, "fake-dev's API (v1.34.1)")
        guard case .found(let replicas) = document.lookup(Self.deployment, ["spec", "replicas"]) else { return XCTFail("replicas") }
        XCTAssertTrue(replicas.description.hasPrefix("Number of desired pods."))
        let asked = docsRequests.map(\.path)
        XCTAssertEqual(asked, ["/version", "/openapi/v3", "/openapi/v3/apis/apps/v1"])
        XCTAssertTrue(api.requests.allSatisfy { $0.method == "GET" }, "reads only")
        XCTAssertTrue(api.writes.isEmpty)
        XCTAssertNotNil(api.requests.last?.query["hash"], "the index's URL, its hash")
        api.forgetRequests()
        _ = try await docs.document(Self.deployment, context: context, client: client())
        XCTAssertNotNil(docs.cached(Self.deployment, context: context))
        XCTAssertTrue(api.requests.isEmpty, "cached: nothing asked again")
        // Another group version: its document only.
        _ = try await docs.document(KubeGVK(group: "", version: "v1", kind: "Pod"), context: context, client: client())
        XCTAssertEqual(api.requests.map(\.path), ["/openapi/v3/api/v1"])
        XCTAssertEqual(docs.documentsRead, 2)
    }

    func testAnotherServerVersionDropsWhatWasRead() async throws {
        let docs = KubeAPIDocs()
        var now = Date()
        docs.now = { now }
        let context = KubeWritesTests.context("fake-dev")
        _ = try await docs.document(Self.deployment, context: context, client: client())
        api.minor = "35"
        api.forgetRequests()
        now += KubeAPIDocs.versionAge - 1
        _ = try await docs.document(Self.deployment, context: context, client: client())
        XCTAssertTrue(api.requests.isEmpty, "the version is taken as it was for a while")
        now += 2
        let (_, source) = try await docs.document(Self.deployment, context: context, client: client())
        XCTAssertEqual(api.requests.map(\.path), ["/version", "/openapi/v3", "/openapi/v3/apis/apps/v1"], "a new version: read again")
        XCTAssertEqual(source.version, "v1.35.1")
    }

    func testAnotherClusterUnderTheSameNameIsNotItsCache() async throws {
        let docs = KubeAPIDocs()
        let context = KubeWritesTests.context("fake-dev")
        _ = try await docs.document(Self.deployment, context: context, client: client())
        let moved = KubeContext(
            name: "fake-dev", cluster: "elsewhere", server: "http://127.0.0.1:2", namespace: "shop", user: "anonymous", auth: KubeAuth.none, file: nil,
            contextClass: .remote, settings: KubeContextSettings())
        XCTAssertNil(docs.cached(Self.deployment, context: moved), "the kubeconfig points the name at another cluster")
    }

    func testACRDAppliedSinceIsFoundByReadingTheIndexAgain() async throws {
        let docs = KubeAPIDocs()
        var now = Date()
        docs.now = { now }
        let context = KubeWritesTests.context("fake-dev")
        _ = try await docs.document(Self.deployment, context: context, client: client())
        api.addCRD(
            group: "stable.example.com", version: "v1", plural: "crontabs", kind: "CronTab",
            schema: ["type": "object", "properties": ["cronSpec": ["type": "string", "description": "The schedule, in cron's own words."]]])
        let cronTab = KubeGVK(group: "stable.example.com", version: "v1", kind: "CronTab")
        now += KubeAPIDocs.indexAge
        api.forgetRequests()
        let (document, _) = try await docs.document(cronTab, context: context, client: client())
        XCTAssertEqual(api.requests.map(\.path), ["/openapi/v3", "/openapi/v3/apis/stable.example.com/v1"])
        guard case .found(let field) = document.lookup(cronTab, ["spec", "cronSpec"]) else { return XCTFail("cronSpec") }
        XCTAssertEqual(field.description, "The schedule, in cron's own words.")
        XCTAssertEqual(document.lookup(cronTab, ["spec", "cronspec"]), .unknown(index: 1, parent: "CronTab.spec"))
    }

    func testAFailureIsKeptAMinuteForHoversButExplainAsksAgain() async throws {
        let docs = KubeAPIDocs()
        var now = Date()
        docs.now = { now }
        api.servesOpenAPI = false
        let context = KubeWritesTests.context("fake-dev")
        do {
            _ = try await docs.document(Self.deployment, context: context, client: client())
            XCTFail("an old server's 404")
        } catch {
            XCTAssertEqual(KubernetesModel.said(error), "The cluster serves no OpenAPI v3 (/openapi/v3: 404) — Kubernetes 1.27 and later do.")
        }
        api.forgetRequests()
        _ = try? await docs.document(Self.deployment, context: context, client: client())
        XCTAssertTrue(api.requests.isEmpty, "not asked again at every hover")
        api.servesOpenAPI = true
        _ = try await docs.document(Self.deployment, context: context, client: client(), retry: true)
        XCTAssertFalse(api.requests.isEmpty, "Explain asks anew")
        now += KubeAPIDocs.failureAge
        XCTAssertNotNil(docs.cached(Self.deployment, context: context))
    }

    func testTheCacheIsBounded() async throws {
        let docs = KubeAPIDocs()
        var now = Date()
        docs.now = { now }
        for index in 0..<(KubeAPIDocs.maxContexts + 2) {
            now += 1
            _ = try await docs.document(Self.deployment, context: KubeWritesTests.context("fake-\(index)"), client: client("fake-\(index)"))
        }
        XCTAssertEqual(docs.kept.contexts, KubeAPIDocs.maxContexts, "the least recently used contexts go")
        XCTAssertNil(docs.cached(Self.deployment, context: KubeWritesTests.context("fake-0")))
        XCTAssertNotNil(docs.cached(Self.deployment, context: KubeWritesTests.context("fake-\(KubeAPIDocs.maxContexts + 1)")))
        // More group versions than a context keeps.
        for index in 0..<(KubeAPIDocs.maxDocuments + 3) {
            api.addCRD(group: "g\(index).example.com", version: "v1", plural: "things", kind: "Thing")
        }
        let context = KubeWritesTests.context("fake-dev")
        for index in 0..<(KubeAPIDocs.maxDocuments + 3) {
            now += KubeAPIDocs.indexAge
            _ = try await docs.document(KubeGVK(group: "g\(index).example.com", version: "v1", kind: "Thing"), context: context, client: client())
        }
        XCTAssertLessThanOrEqual(docs.kept.documents, KubeAPIDocs.maxContexts * KubeAPIDocs.maxDocuments)
        XCTAssertNil(docs.cached(KubeGVK(group: "g0.example.com", version: "v1", kind: "Thing"), context: context), "the oldest document goes")
        XCTAssertNotNil(docs.cached(KubeGVK(group: "g\(KubeAPIDocs.maxDocuments + 2).example.com", version: "v1", kind: "Thing"), context: context))
        XCTAssertLessThanOrEqual(docs.kept.bytes, docs.maxBytes)
    }

    /// The bound on bytes in all: the least recently used document goes,
    /// whichever context it was read for.
    func testTheTotalBoundDropsTheLeastRecentlyUsedDocumentAcrossContexts() async throws {
        let docs = KubeAPIDocs()
        var now = Date()
        docs.now = { now }
        _ = try await docs.document(Self.deployment, context: KubeWritesTests.context("fake-a"), client: client("fake-a"))
        let size = docs.kept.bytes
        XCTAssertGreaterThan(size, 0)
        docs.forgetAll()
        docs.maxBytes = size * 2 + size / 2
        let contexts = ["fake-a", "fake-b", "fake-c", "fake-d"].map { KubeWritesTests.context($0) }
        for context in contexts.prefix(3) {
            now += 1
            _ = try await docs.document(Self.deployment, context: context, client: client(context.name))
        }
        XCTAssertEqual(docs.kept.contexts, 3, "under the contexts' bound: only bytes drop documents")
        XCTAssertEqual(docs.kept.documents, 2)
        XCTAssertNil(docs.cached(Self.deployment, context: contexts[0]), "the least recently used, another context's")
        XCTAssertNotNil(docs.cached(Self.deployment, context: contexts[1]))
        XCTAssertNotNil(docs.cached(Self.deployment, context: contexts[2]))
        XCTAssertLessThanOrEqual(docs.kept.bytes, docs.maxBytes)
        // fake-b's used again: fake-c's is the oldest now.
        now += 1
        api.forgetRequests()
        _ = try await docs.document(Self.deployment, context: contexts[1], client: client("fake-b"))
        XCTAssertTrue(docsRequests.isEmpty, "from the cache")
        now += 1
        _ = try await docs.document(Self.deployment, context: contexts[3], client: client("fake-d"))
        XCTAssertNotNil(docs.cached(Self.deployment, context: contexts[1]))
        XCTAssertNil(docs.cached(Self.deployment, context: contexts[2]))
        XCTAssertNotNil(docs.cached(Self.deployment, context: contexts[3]))
        XCTAssertLessThanOrEqual(docs.kept.bytes, docs.maxBytes)
    }

    /// An answer past its bound is cut off as it is read — the connection
    /// closed, the rest never held — and said; the context's other docs
    /// are read as ever.
    func testAnOversizedDocumentIsCutOffAsItIsRead() async throws {
        let docs = KubeAPIDocs()
        docs.maxDocumentBytes = 256 << 10
        let served = 16 << 20
        api.openAPIPadding = served
        let context = KubeWritesTests.context("fake-dev")
        do {
            _ = try await docs.document(Self.deployment, context: context, client: client())
            XCTFail("over its bound")
        } catch {
            XCTAssertEqual(KubernetesModel.said(error), "The cluster's the apps/v1 document is over 256 KB: too much to read here.")
        }
        XCTAssertEqual(docs.kept.documents, 0)
        do {
            _ = try await client().get("/openapi/v3/apis/apps/v1", maxBytes: 256 << 10)
            XCTFail("over its bound")
        } catch let error as KubeBodyTooLarge {
            XCTAssertGreaterThan(error.read, 256 << 10)
            XCTAssertLessThan(error.read, served / 4, "stopped near the bound, not read whole")
        }
        // The index is bounded on its own, and it was small: read.
        XCTAssertTrue(api.requests.contains { $0.path == "/openapi/v3" })
        // Another group version's document, within its bound, is read: the failure was apps/v1's alone.
        api.openAPIPadding = 0
        let (document, _) = try await docs.document(KubeGVK(group: "", version: "v1", kind: "Pod"), context: context, client: client())
        XCTAssertNotNil(document.kinds[KubeGVK(group: "", version: "v1", kind: "Pod")])
        // apps/v1's failure is kept a minute for hovers; Explain asks anew.
        api.forgetRequests()
        _ = try? await docs.document(Self.deployment, context: context, client: client())
        XCTAssertTrue(docsRequests.isEmpty, "apps/v1's own failure, kept")
        _ = try await docs.document(Self.deployment, context: context, client: client(), retry: true)
    }

    /// A group version the server doesn't serve (an old apiVersion, a CRD
    /// not there yet) is said, but not kept as the context's failure: the
    /// next hover on another kind reads as ever, and the CRD once applied
    /// is found at the index's next read.
    func testAnUnservedGroupVersionDoesNotFailTheContextsOtherHovers() async throws {
        let docs = KubeAPIDocs()
        var now = Date()
        docs.now = { now }
        let context = KubeWritesTests.context("fake-dev")
        let old = KubeGVK(group: "extensions", version: "v1beta1", kind: "Deployment")
        do {
            _ = try await docs.document(old, context: context, client: client())
            XCTFail("extensions/v1beta1 isn't served")
        } catch {
            XCTAssertEqual(KubernetesModel.said(error), "fake-dev serves no extensions/v1beta1: its OpenAPI index has no apis/extensions/v1beta1.")
        }
        let (document, _) = try await docs.document(Self.deployment, context: context, client: client())
        guard case .found = document.lookup(Self.deployment, ["spec", "replicas"]) else { return XCTFail("apps/v1 Deployment read") }
        let cronTab = KubeGVK(group: "stable.example.com", version: "v1", kind: "CronTab")
        do {
            _ = try await docs.document(cronTab, context: context, client: client())
            XCTFail("not applied yet")
        } catch {
            XCTAssertTrue(error is KubeDocsUnserved)
        }
        api.addCRD(group: "stable.example.com", version: "v1", plural: "crontabs", kind: "CronTab")
        now += KubeAPIDocs.indexAge
        _ = try await docs.document(cronTab, context: context, client: client())
        XCTAssertNotNil(docs.cached(cronTab, context: context), "applied since: found, no failure kept against it")
    }

    /// A hover where the mouse rests reads as nobody asked: on an oidc
    /// context nobody has signed in to, it opens no browser sign-in, starts
    /// no proxy, and leaves no failure behind for a read someone asks for.
    func testAMouseHoverNeverSignsIn() async throws {
        let oidc = KubeContext(
            name: "globex-eu-west-1-dev", cluster: "globex-eu-west-1-dev", server: "http://127.0.0.1:1", namespace: "shop", user: "globex",
            auth: KubeAuth.exec(KubeExec(command: "kubectl", arguments: ["oidc-login", "get-token"])), file: nil, contextClass: .remote,
            settings: KubeContextSettings())
        let proxies = KubeProxies()
        let model = KubernetesModel(proxies: proxies)
        model.load = { _ in KubeContextList(contexts: [oidc], current: oidc.name) }
        model.readConfiguration = { KubernetesModel.Configuration() }
        model.watchesSettings = false
        model.remembersSelection = false
        do {
            _ = try await model.apiDocs.document(Self.deployment, context: oidc, client: model.spareClient(for: oidc))
            XCTFail("not signed in")
        } catch {
            XCTAssertEqual(error as? KubeProxyProblem, .needsPageSignIn)
        }
        let session = await session(model, context: oidc.name)
        let text = Self.manifest
        let offset = (text as NSString).range(of: "replicas").location + 2
        let hovered = await session.fieldHover(at: offset, in: text, unasked: true)
        XCTAssertNil(hovered)
        XCTAssertEqual(session.docsNote, "Field docs: " + KubeProxyProblem.needsPageSignIn.reason)
        let status = await proxies.status(of: oidc.name)
        XCTAssertEqual(status, .closed, "nothing started, no sign-in turn held")
        let connected = await proxies.connected
        XCTAssertTrue(connected.isEmpty)
        XCTAssertTrue(docsRequests.isEmpty)
        // Not kept: a read someone asks for (the keyboard's hover, here a test's socket) goes on.
        let (document, _) = try await model.apiDocs.document(Self.deployment, context: oidc, client: client(oidc.name))
        XCTAssertNotNil(document.kinds[Self.deployment])
    }

    // MARK: A manifest in the editor

    private static let manifest = """
        apiVersion: apps/v1
        kind: Deployment
        metadata:
          name: web
        spec:
          replicas: 2
          replicaz: 3
          te
        """

    private func session(_ model: KubernetesModel, context: String = "fake-dev") async -> KubeManifestSession {
        let file = URL(fileURLWithPath: "/tmp/checkout-\(UUID().uuidString)/web.yaml")
        let session = KubeManifestSession(source: .file(file), file: file, model: model)
        session.contextName = context
        session.text = { Self.manifest }
        await session.refreshContexts()
        return session
    }

    func testAHoverReadsTheDocsAndMarksFollowFromTheCache() async throws {
        let model = model()
        let session = await session(model)
        let text = Self.manifest
        XCTAssertTrue(session.fieldMarks(in: text).isEmpty, "nothing read: nothing marked")
        let offset = (text as NSString).range(of: "replicas").location + 2
        let notAsked = await session.fieldHover(at: offset, in: text, fetch: false)
        XCTAssertNil(notAsked)
        XCTAssertTrue(docsRequests.isEmpty, "nothing fetched while not asked")
        var read = 0
        session.onDocsRead = { read += 1 }
        let hovered = await session.fieldHover(at: offset, in: text)
        let hover = try XCTUnwrap(hovered)
        XCTAssertEqual(hover.doc.spokenPath, "Deployment.spec.replicas")
        XCTAssertTrue(hover.text.contains("Number of desired pods."), hover.text)
        XCTAssertTrue(hover.text.contains("fake-dev's API (v1.34.1)"), hover.text)
        XCTAssertEqual(read, 1)
        XCTAssertEqual(session.docsNote, "Field docs: fake-dev's API (v1.34.1)")
        XCTAssertTrue(api.writes.isEmpty)
        let marks = session.fieldMarks(in: text)
        XCTAssertEqual(marks.map { (text as NSString).substring(with: $0.range) }, ["replicaz"])
        api.forgetRequests()
        let completions = await session.fieldCompletions(at: (text as NSString).length, in: text)
        XCTAssertEqual(completions?.fields.map(\.name), ["template", "strategy"])
        XCTAssertTrue(api.requests.isEmpty, "from the cache")
    }

    func testExplainForAKindAndFieldPath() async throws {
        let model = model()
        let explain = KubeExplainSession(query: "deployment.spec.replicas", context: "fake-dev", model: model)
        explain.client = { [socket] context in KubeClient(KubeSocketConnection(socket: socket!, context: context.name)) }
        var read = 0
        explain.onRead = { read += 1 }
        await explain.run()
        let result = try XCTUnwrap(explain.result, "\(explain.state)")
        XCTAssertEqual(result.type, "integer")
        XCTAssertTrue(explain.text?.contains("FIELD: replicas <integer>") == true, explain.text ?? "")
        XCTAssertEqual(explain.kubectl, "kubectl explain deployment.spec.replicas --context fake-dev")
        XCTAssertEqual(read, 1)
        XCTAssertTrue(api.writes.isEmpty)
        // Up runs it again on its own: that run answers.
        explain.up()
        var waited = 0
        while explain.result?.spokenPath != "Deployment.spec", waited < 500 {
            try await Task.sleep(for: .milliseconds(10))
            waited += 1
        }
        XCTAssertEqual(explain.result?.spokenPath, "Deployment.spec")
        XCTAssertEqual(explain.result?.fields.map(\.name).contains("replicas"), true)
        explain.query = "deploy.spec.replicaz"
        await explain.run()
        XCTAssertEqual(explain.state, .failed("Deployment.spec has no field \"replicaz\" in fake-dev's API (v1.34.1)."))
        explain.query = "nosuchkind.spec"
        await explain.run()
        XCTAssertEqual(explain.state, .failed("fake-dev serves no kind called nosuchkind."))
        explain.query = "po.spec.containers.image"
        await explain.run()
        XCTAssertEqual(explain.result?.type, "string")
        XCTAssertEqual(explain.result?.description, "Container image name.")
    }

    /// A failure leaves no earlier answer under it; an answer to a query
    /// changed meanwhile (typed, ↩ not pressed) isn't shown, and the pane
    /// doesn't go on saying it reads.
    func testExplainFailuresAndSupersededAnswers() async throws {
        let model = model()
        let explain = KubeExplainSession(query: "deployment.spec.replicas", context: "fake-dev", model: model)
        let socket = self.socket!
        explain.client = { context in KubeClient(KubeSocketConnection(socket: socket, context: context.name)) }
        await explain.run()
        XCTAssertEqual(explain.result?.spokenPath, "Deployment.spec.replicas")
        explain.query = "deployment.spec.bogus"
        await explain.run()
        XCTAssertEqual(explain.state, .failed("Deployment.spec has no field \"bogus\" in fake-dev's API (v1.34.1)."))
        XCTAssertNil(explain.result, "replicas' docs aren't left under bogus's error")
        XCTAssertNil(explain.source)
        XCTAssertNil(explain.text)
        explain.query = "nosuchkind"
        await explain.run()
        XCTAssertNil(explain.result)
        // The query changes while the read is under way.
        explain.query = "deployment.spec.paused"
        explain.client = { [weak explain] context in
            explain?.query = "deployment.spec.minReadySeconds"
            return KubeClient(KubeSocketConnection(socket: socket, context: context.name))
        }
        await explain.run()
        XCTAssertEqual(explain.state, .idle, "not left reading")
        XCTAssertNil(explain.result, "paused's answer isn't shown as minReadySeconds'")
        // ↩ again: answered.
        explain.client = { context in KubeClient(KubeSocketConnection(socket: socket, context: context.name)) }
        await explain.run()
        XCTAssertEqual(explain.result?.spokenPath, "Deployment.spec.minReadySeconds")
    }

    func testExplainFromTheManifestTakesTheFieldAtTheCaret() async throws {
        let model = model()
        let session = await session(model)
        let text = Self.manifest
        session.caret = { (text as NSString).range(of: "replicas").location }
        let explain = session.explainSession(at: session.caret(), in: text)
        XCTAssertEqual(explain.query, "deployment.spec.replicas")
        XCTAssertEqual(explain.apiVersion, "apps/v1")
        XCTAssertEqual(explain.contextName, "fake-dev")
        XCTAssertTrue(docsRequests.isEmpty, "nothing read until it runs")
        await explain.run()
        XCTAssertEqual(explain.result?.spokenPath, "Deployment.spec.replicas")
        XCTAssertEqual(explain.kubectl, "kubectl explain deployment.spec.replicas --context fake-dev --api-version apps/v1")
        XCTAssertEqual(session.explainSession(at: 0, in: text).query, "deployment", "apiVersion: the kind itself")
    }
}
