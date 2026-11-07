import Foundation
import XCTest

@testable import Overterm

/// Helm's releases read from the cluster's own records (docs/design/
/// kubernetes/analysis.md, 2.12, Section 4 and rule 9): a record decoded as
/// Helm stores it — the API's base64, Helm's base64, gzip (a member made
/// by the system's own gzip, header fields and all) or plain JSON, capped —
/// the values and the manifest masked, the list from the records' labels
/// alone; and against `FakeKubeAPI` the page's Helm section: the list asks
/// for metadata only and by Helm's selectors, one record is read when a
/// release opens, production asks first, a forbidden Secret list degrades
/// while ConfigMap records still list, and what was read goes with the
/// page. No cluster of the user's is reached, and no helm runs.
@MainActor
final class KubeHelmTests: XCTestCase {
    private static let password = "acme-helm-pw-Qx81r"
    private static let token = "acme-helm-token-7Ycd2"
    private static let secretData = "acme-helm-secret-data-Lm42"

    // MARK: Fixtures

    /// A release as Helm writes one (`release.Release`, JSON).
    private func release(
        name: String = "web", namespace: String = "shop", revision: Int = 2, status: String = "deployed", config: [String: Any]? = nil,
        manifest: String? = nil, notes: String = "Visit http://web.shop.svc"
    ) -> [String: Any] {
        [
            "name": name, "namespace": namespace, "version": revision,
            "info": [
                "status": status, "description": "Upgrade complete", "notes": notes, "first_deployed": "2026-10-01T10:00:00.123456789Z",
                "last_deployed": "2026-11-01T12:30:00.5Z",
            ],
            "chart": [
                "metadata": ["name": "web", "version": "1.4.2", "appVersion": "1.27.0", "description": "A web server"],
                "values": ["replicaCount": 1, "image": ["repository": "nginx", "tag": "1.25"], "auth": ["password": ""], "ingress": ["enabled": false]],
                "templates": [["name": "templates/deployment.yaml", "data": "a2luZDogRGVwbG95bWVudA=="]],
            ],
            "config": config ?? ["image": ["tag": "1.27"], "auth": ["password": Self.password], "apiToken": Self.token],
            "manifest": manifest ?? Self.manifest,
        ]
    }

    private static let manifest = """
        ---
        # Source: web/templates/secret.yaml
        apiVersion: v1
        kind: Secret
        metadata:
          name: web-auth
        type: Opaque
        data:
          password: \(Data(password.utf8).base64EncodedString())
        stringData:
          token: \(token)
        ---
        # Source: web/templates/deployment.yaml
        apiVersion: apps/v1
        kind: Deployment
        metadata:
          name: web
        spec:
          replicas: 1
          template:
            spec:
              containers:
                - name: web
                  image: nginx:1.27
                  env:
                    - name: DB_PASSWORD
                      value: \(password)
                    - name: LOG_LEVEL
                      value: info
        """

    /// gzip as the system's own tool writes it (a file's name in the
    /// header, as `gzip file` keeps it) — not Overterm's encoder.
    private func systemGzip(_ data: Data) throws -> Data {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("overterm-helm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("release.json")
        try data.write(to: file)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        process.arguments = ["-c", file.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let out = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return out
    }

    /// A record's object as the API answers its GET.
    private func recordObject(_ helmText: String, storage: KubeHelmStorage, name: String = "sh.helm.release.v1.web.v2") throws -> Data {
        let secret = storage == .secret
        let object: [String: Any] = [
            "kind": secret ? "Secret" : "ConfigMap", "apiVersion": "v1", "metadata": ["name": name, "namespace": "shop"],
            "data": ["release": secret ? Data(helmText.utf8).base64EncodedString() : helmText],
        ]
        return try JSONSerialization.data(withJSONObject: object.merging(secret ? ["type": KubeHelm.secretType] : [:]) { $1 })
    }

    private func json(_ object: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: object) }

    // MARK: Decoding

    func testASecretRecordIsDecodedAsHelmStoresIt() throws {
        let gzipped = try systemGzip(try json(release()))
        XCTAssertTrue(KubeHelm.isGzip(gzipped))
        XCTAssertNotEqual(gzipped[3] & 0x08, 0, "the system's gzip names the file: the header's FNAME is skipped")
        let body = try recordObject(gzipped.base64EncodedString(), storage: .secret)
        let detail = try KubeHelm.decode(body, storage: .secret)
        XCTAssertEqual(detail.release, "web")
        XCTAssertEqual(detail.namespace, "shop")
        XCTAssertEqual(detail.revision, 2)
        XCTAssertEqual(detail.status, "deployed")
        XCTAssertEqual(detail.chart, KubeHelmChart(chart: "web", version: "1.4.2", appVersion: "1.27.0"))
        XCTAssertEqual(detail.chart.said, "web-1.4.2", "as helm list says it")
        XCTAssertEqual(detail.summary, "Upgrade complete")
        XCTAssertEqual(detail.chartDescription, "A web server")
        XCTAssertEqual(detail.firstDeployed, ISO8601DateFormatter().date(from: "2026-10-01T10:00:00Z"))
        XCTAssertEqual(detail.lastDeployed, ISO8601DateFormatter().date(from: "2026-11-01T12:30:00Z"))
        XCTAssertEqual(detail.notes, "Visit http://web.shop.svc")
        // Printed, a detail names the release, nothing it read.
        XCTAssertEqual(String(describing: detail), "Helm release shop/web v2 (deployed)")
    }

    func testAPlainJSONRecordAndAConfigMapsAreReadToo() throws {
        // Old releases: no gzip, the JSON base64'd.
        let plain = try json(release(revision: 1, status: "superseded")).base64EncodedString()
        let old = try KubeHelm.decode(try recordObject(plain, storage: .secret), storage: .secret)
        XCTAssertEqual(old.revision, 1)
        XCTAssertEqual(old.status, "superseded")
        // HELM_DRIVER=configmap: one base64 fewer — a ConfigMap's data is text.
        let configMap = try recordObject(KubeHelm.encode(release()), storage: .configMap)
        XCTAssertEqual(try KubeHelm.decode(configMap, storage: .configMap).chart.chart, "web")
        // Read as the other storage, a record isn't one.
        XCTAssertThrowsError(try KubeHelm.decode(configMap, storage: .secret)) { XCTAssertEqual($0 as? KubeHelmProblem, .notARecord) }
        // Overterm's own encoder (the fake's) round-trips through the system's gunzip view too.
        let ours = try XCTUnwrap(Data(base64Encoded: KubeHelm.encode(["name": "x"])))
        XCTAssertEqual(try KubeHelm.gunzip(ours), Data("{\"name\":\"x\"}".utf8))
    }

    func testARecordIsCappedAndNothingItHeldIsSaid() throws {
        // A bomb: 4 MB of JSON that gzips to a few KB, read with a 1 MB cap.
        let big = Data("{\"pad\":\"".utf8) + Data(repeating: UInt8(ascii: "a"), count: 4 * 1024 * 1024) + Data("\"}".utf8)
        let body = try recordObject(try systemGzip(big).base64EncodedString(), storage: .secret)
        XCTAssertThrowsError(try KubeHelm.payload(body, storage: .secret, limit: 1024 * 1024)) {
            XCTAssertEqual($0 as? KubeHelmProblem, .tooLarge(1024 * 1024))
        }
        XCTAssertNoThrow(try KubeHelm.payload(body, storage: .secret, limit: 8 * 1024 * 1024))
        // Not Helm's encoding: said without what it held.
        let junk = try recordObject(Data("not json \(Self.password)".utf8).base64EncodedString(), storage: .secret)
        XCTAssertThrowsError(try KubeHelm.decode(junk, storage: .secret)) { error in
            XCTAssertEqual(error as? KubeHelmProblem, .unreadable)
            XCTAssertFalse(error.localizedDescription.contains(Self.password))
        }
        // A truncated gzip member.
        let gzipped = try systemGzip(try json(release()))
        XCTAssertThrowsError(try KubeHelm.gunzip(gzipped.prefix(40)))
        // Helm 2's records are protobuf: listed, never decoded.
        let tiller = try recordObject(KubeHelm.gzip(Data([0x0A, 0x03, 0x77, 0x65, 0x62])).base64EncodedString(), storage: .tiller)
        XCTAssertThrowsError(try KubeHelm.decode(tiller, storage: .tiller)) { XCTAssertEqual($0 as? KubeHelmProblem, .helm2) }
    }

    // MARK: Masking

    func testValuesAreMaskedUserSuppliedAndComputed() throws {
        let pem = "-----BEGIN PRIVATE KEY-----\nMIIEvQIBADANBgkqhkiG9w0BAQEFAASC\n-----END PRIVATE KEY-----"
        let config: [String: Any] = [
            "image": ["tag": "1.27"], "replicaCount": 3,
            "auth": ["password": Self.password, "username": "web", "enabled": true],
            "apiToken": Self.token, "dbUrl": "postgres://web:\(Self.password)@db:5432/web",
            "extraEnv": [["name": "STRIPE_SECRET", "value": Self.token], ["name": "LOG_LEVEL", "value": "debug"]],
            "tlsPem": pem, "pin": ["key": 4242],
            "ingress": NSNull(),
        ]
        let detail = try KubeHelm.detail(release(config: config))
        for text in [detail.userValues, detail.computedValues] {
            XCTAssertFalse(text.contains(Self.password), text)
            XCTAssertFalse(text.contains(Self.token), text)
            XCTAssertFalse(text.contains("MIIEvQIBADANBgkqhkiG9w0BAQEFAASC"), "a PEM body: \(text)")
            XCTAssertFalse(text.contains("4242"), "a number under a secret key: \(text)")
            XCTAssertTrue(text.contains("tag: \"1.27\""), "what isn't secret stays: \(text)")
            XCTAssertTrue(text.contains("value: debug"), "an env entry that isn't secret stays: \(text)")
            XCTAssertTrue(text.contains("postgres://web:••••••@db:5432/web"), "a URL keeps all but its password: \(text)")
            XCTAssertTrue(text.contains("enabled: true"), "a bool is never a secret")
        }
        XCTAssertTrue(detail.userValues.contains("password: \"***\""), detail.userValues)
        XCTAssertTrue(detail.userValues.contains("apiToken: \"***\""), detail.userValues)
        XCTAssertTrue(detail.userValues.contains("replicaCount: 3"))
        XCTAssertGreaterThanOrEqual(detail.maskedUserValues, 6)
        // Computed: the chart's defaults under the user's — and a null takes one away.
        XCTAssertTrue(detail.computedValues.contains("repository: nginx"), detail.computedValues)
        XCTAssertFalse(detail.computedValues.contains("tag: \"1.25\""), "the user's tag wins")
        XCTAssertFalse(detail.computedValues.contains("ingress"), "null removes the default, as Helm's coalesce does")
        XCTAssertEqual(KubeHelm.coalesced(["a": ["b": 1, "c": 2]], ["a": ["c": 3]]) as NSDictionary, ["a": ["b": 1, "c": 3]] as NSDictionary)
        // No values: said, not an empty map.
        XCTAssertEqual(try KubeHelm.detail(release(config: [:])).userValues, "")
    }

    func testTheManifestsSecretsAndSecretEnvAreMasked() throws {
        let manifest =
            Self.manifest + """

                ---
                # Source: web/templates/configmap.yaml
                apiVersion: v1
                kind: ConfigMap
                metadata:
                  name: web-config
                data:
                  nginx.conf: |
                    # a comment inside a block stays
                    worker_processes 1;
                ---
                # Source: web/templates/empty.yaml
                # nothing rendered
                ---
                # Source: web/templates/broken.yaml
                kind: [unclosed \(Self.password)
                """
        let detail = try KubeHelm.detail(release(manifest: manifest))
        let text = detail.manifest
        XCTAssertFalse(text.contains(Self.password), text)
        XCTAssertFalse(text.contains(Data(Self.password.utf8).base64EncodedString()), "nor its base64")
        XCTAssertFalse(text.contains(Self.token), text)
        XCTAssertTrue(text.contains("password: \"***\""), "every Secret value masked: \(text)")
        XCTAssertTrue(text.contains("token: \"***\""), "stringData too")
        XCTAssertTrue(text.contains("value: info"), "an env value that isn't secret stays")
        XCTAssertTrue(text.contains("# Source: web/templates/deployment.yaml"), "where each came from")
        XCTAssertTrue(text.contains("# a comment inside a block stays"), "a block's text is the object's")
        XCTAssertTrue(text.contains("worker_processes 1;"))
        XCTAssertEqual(detail.maskedSecrets, 1)
        XCTAssertEqual(detail.withheldDocuments, 1, "one that can't be read can't be masked: left out")
        XCTAssertTrue(text.contains("# Left out: Overterm couldn't read this document whole"))
        XCTAssertFalse(text.contains("nothing rendered"), "a document of comments alone is nothing")
    }

    func testASecretInsideAListIsMasked() throws {
        let encoded = Data(Self.password.utf8).base64EncodedString()
        let manifest = """
            ---
            # Source: web/templates/list.yaml
            apiVersion: v1
            kind: List
            items:
              - apiVersion: v1
                kind: Secret
                metadata:
                  name: web-list-auth
                data:
                  password: \(encoded)
              - apiVersion: v1
                kind: ConfigMap
                metadata:
                  name: web-list-config
                data:
                  mode: plain
            ---
            # Source: web/templates/secrets.yaml
            apiVersion: v1
            kind: SecretList
            items:
              - apiVersion: v1
                kind: Secret
                metadata:
                  name: web-tokens
                stringData:
                  token: \(Self.token)
            """
        let detail = try KubeHelm.detail(release(manifest: manifest))
        let text = detail.manifest
        XCTAssertFalse(text.contains(encoded), "a List's Secret's data: \(text)")
        XCTAssertFalse(text.contains(Self.token), "a SecretList's stringData: \(text)")
        XCTAssertTrue(text.contains("password: \"***\""), text)
        XCTAssertTrue(text.contains("mode: plain"), "a List's other items stay: \(text)")
        XCTAssertEqual(detail.maskedSecrets, 2, "the Secrets among the items counted")
    }

    func testNumbersUnderASecretPathAreMasked() throws {
        let config: [String: Any] = [
            "auth": ["pin": 123_456], "secrets": ["api": 987_654],
            "env": [["name": "DB_PASSWORD", "value": 246_810], ["name": "WORKERS", "value": 4]],
            "replicaCount": 3,
        ]
        let detail = try KubeHelm.detail(release(config: config))
        for text in [detail.userValues, detail.computedValues] {
            for number in ["123456", "987654", "246810"] { XCTAssertFalse(text.contains(number), "\(number): \(text)") }
            XCTAssertTrue(text.contains("value: 4"), "a number that isn't secret stays: \(text)")
            XCTAssertTrue(text.contains("replicaCount: 3"), text)
        }
    }

    func testNotesAndDescriptionsAreScrubbed() throws {
        let notes = "Log in with postgres://admin:\(Self.password)@db:5432 or Authorization: Bearer \(Self.token)abcdefghijklmnopqrstuvwxyz"
        let detail = try KubeHelm.detail(release(notes: notes))
        XCTAssertFalse(detail.notes.contains(Self.password), detail.notes)
        XCTAssertFalse(detail.notes.contains(Self.token), detail.notes)
        XCTAssertTrue(detail.notes.hasPrefix("Log in with postgres://admin:"))
    }

    // MARK: Records

    func testRecordsComeFromTheLabelsAlone() throws {
        let list: [String: Any] = [
            "kind": "PartialObjectMetadataList", "metadata": ["continue": "next"],
            "items": [
                [
                    "metadata": [
                        "name": "sh.helm.release.v1.web.v2", "namespace": "shop", "labels": ["owner": "helm", "name": "web", "status": "deployed", "version": "2", "modifiedAt": "1761998400"],
                    ]
                ],
                [
                    "metadata": [
                        "name": "sh.helm.release.v1.web.v1", "namespace": "shop", "labels": ["owner": "helm", "name": "web", "status": "superseded", "version": "1"],
                        "creationTimestamp": "2026-10-01T10:00:00Z",
                    ]
                ],
                // Labels lost: the name says it.
                ["metadata": ["name": "sh.helm.release.v1.my.app.v12", "namespace": "shop", "labels": ["owner": "helm"]]],
                ["metadata": ["name": "not-helm", "namespace": "shop"]],
            ],
        ]
        let page = try KubeHelm.records(try json(list), storage: .secret)
        XCTAssertEqual(page.continueToken, "next")
        XCTAssertEqual(page.records.map(\.object), ["sh.helm.release.v1.web.v2", "sh.helm.release.v1.web.v1", "sh.helm.release.v1.my.app.v12"])
        XCTAssertEqual(page.records[0].updated, Date(timeIntervalSince1970: 1_761_998_400))
        XCTAssertEqual(page.records[1].updated, ISO8601DateFormatter().date(from: "2026-10-01T10:00:00Z"), "else the object's creation")
        XCTAssertEqual(page.records[2].release, "my.app")
        XCTAssertEqual(page.records[2].revision, 12)
        XCTAssertEqual(page.records[2].status, "unknown")

        let releases = KubeHelm.releases(page.records)
        XCTAssertEqual(releases.map(\.name), ["my.app", "web"])
        XCTAssertEqual(releases[1].history.map(\.revision), [2, 1], "newest first")
        XCTAssertEqual(releases[1].status, "deployed")
        XCTAssertEqual(releases[1].revision, 2)

        // Tiller's: uppercase labels, `name.vN`.
        let tiller = KubeHelm.record(
            ["name": "web.v3", "namespace": "kube-system", "labels": ["OWNER": "TILLER", "NAME": "web", "STATUS": "DEPLOYED", "VERSION": "3"]], storage: .tiller)
        XCTAssertEqual(tiller?.release, "web")
        XCTAssertEqual(tiller?.status, "deployed")
        XCTAssertEqual(KubeHelm.nameAndRevision("web.v3", storage: .tiller)?.revision, 3)
        XCTAssertNil(KubeHelm.nameAndRevision("web.v3", storage: .secret), "Helm 3's records are prefixed")
    }

    func testTheSectionAndItsCommands() {
        XCTAssertEqual(KubeSection.helm.key, "8")
        XCTAssertEqual(KubeSection.forwards.key, "9")
        XCTAssertFalse(KubeSection.helm.listsKinds)
        guard case .section(.helm) = KubernetesKey.press("8", sheetShowing: false) else { return XCTFail("8 is Helm") }
        XCTAssertEqual(KubeHelmLine.list(context: "fake-dev", scope: .namespace("shop")), "helm list --kube-context fake-dev -n shop")
        XCTAssertEqual(KubeHelmLine.list(context: "acme ctx", scope: .all), "helm list --kube-context 'acme ctx' -A")
        XCTAssertEqual(
            KubeHelmLine.status(context: "fake-dev", namespace: "shop", release: "web", revision: 2),
            "helm status web --kube-context fake-dev -n shop --revision 2")
        XCTAssertEqual(KubeHelmLine.history(context: "fake-dev", namespace: "shop", release: "web"), "helm history web --kube-context fake-dev -n shop")
        XCTAssertEqual(KubeHelmStorage.secret.labelSelector, "owner=helm")
        XCTAssertEqual(KubeHelmStorage.secret.fieldSelector, "type=helm.sh/release.v1")
        XCTAssertNil(KubeHelmStorage.configMap.fieldSelector)
        XCTAssertEqual(KubeHelmStorage.tiller.labelSelector, "OWNER=TILLER")
    }

    // MARK: The page, against the fake

    private var api: FakeKubeAPI!
    private var copied: [String] = []
    private var terminals: [(String, String?)] = []

    override func tearDown() {
        if let api {
            XCTAssertEqual(api.writes, [], "only GETs")
            XCTAssertEqual(api.subresourceRequests, [], "no subresource")
            api.stop()
        }
        api = nil
    }

    private func until(_ timeout: TimeInterval = 5, _ what: String = "", _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return XCTFail("timed out: \(what)") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    /// GETs of one Secret or ConfigMap: a record read.
    private var recordGETs: [FakeKubeAPI.Request] { api.requests.filter { $0.path.contains("/secrets/") || $0.path.contains("/configmaps/") } }

    private func pageOverFake() throws -> (KubernetesModel, KubernetesPageModel) {
        let socket = "/tmp/otkh-\(UInt32.random(in: 0...UInt32.max)).sock"
        api = FakeKubeAPI(socket: socket)
        try api.start()
        api.addNamespace("shop")
        api.addNamespace("payments")
        api.addHelmRelease("web", namespace: "shop", revision: 1, status: "superseded", config: ["image": ["tag": "1.25"]])
        api.addHelmRelease(
            "web", namespace: "shop", revision: 2, description: "Upgrade complete",
            config: ["auth": ["password": Self.password], "image": ["tag": "1.27"]], manifest: Self.manifest, notes: "Thanks for installing web.")
        api.addHelmRelease("cache", namespace: "shop", chart: "redis", version: "19.0.1", appVersion: "7.2", configMap: true)
        api.addHelmRelease("pay", namespace: "payments", chart: "pay", config: ["apiToken": Self.token])
        // Not Helm's: never listed, never read.
        api.add("secrets", "web-db", namespace: "shop", values: ["Type": "Opaque"], labels: ["owner": "helm"], data: ["password": Self.secretData])
        api.add("configmaps", "web-config", namespace: "shop", data: ["nginx.conf": "worker_processes 1;"])

        let model = KubernetesModel(proxies: KubeProxies())
        func context(_ name: String, _ kind: KubeContextClass) -> KubeContext {
            KubeContext(
                name: name, cluster: name, server: "http://127.0.0.1:1", namespace: "shop", user: "anonymous", auth: KubeAuth.none, file: nil,
                contextClass: kind, settings: KubeContextSettings())
        }
        let list = KubeContextList(contexts: [context("fake-dev", .remote), context("fake-prod", .production)], current: "fake-dev")
        model.load = { _ in list }
        model.readConfiguration = { KubernetesModel.Configuration() }
        model.watchesSettings = false
        model.remembersSelection = false
        model.flushInterval = .milliseconds(20)
        model.statusInterval = .milliseconds(50)
        model.connectOverride = { context in KubeSocketConnection(socket: socket, context: context.name) }
        model.statusOverride = { _ in .open }
        let page = KubernetesPageModel(model: model)
        var actions = KubernetesActions(run: { _ in }, settings: {}, copy: { [weak self] in self?.copied.append($0) }, copySecret: { _ in })
        actions.openTerminal = { [weak self] context, namespace in self?.terminals.append((context.name, namespace)) }
        page.actions = actions
        page.visible = true
        return (model, page)
    }

    private func showHelm(_ model: KubernetesModel, _ page: KubernetesPageModel) async throws {
        model.show()
        try await until(5, "a context") { model.selectedName == "fake-dev" && model.scope == .namespace("shop") }
        XCTAssertTrue(page.press("8"))
        XCTAssertEqual(page.section, .helm)
        try await until(5, "releases") { page.helm.listState == .live && page.helm.releases.count == 2 }
    }

    func testTheListIsHelmsRecordsMetadataOnly() async throws {
        let (model, page) = try pageOverFake()
        defer { model.hide() }
        try await showHelm(model, page)
        let helm = page.helm
        XCTAssertEqual(helm.releases.map(\.name), ["cache", "web"])
        let web = try XCTUnwrap(helm.releases.first { $0.name == "web" })
        XCTAssertEqual(web.history.map(\.revision), [2, 1])
        XCTAssertEqual(web.status, "deployed")
        XCTAssertEqual(web.storage, .secret)
        XCTAssertEqual(helm.releases.first { $0.name == "cache" }?.storage, .configMap, "ConfigMap storage too")
        XCTAssertNil(helm.charts[web.id], "the chart isn't in a record's labels: unknown until opened")

        let lists = api.requests.filter { $0.path.hasSuffix("/secrets") || $0.path.hasSuffix("/configmaps") }
        XCTAssertEqual(lists.count, 2, "secrets, configmaps — Tiller's only across all namespaces: \(lists)")
        for request in lists {
            XCTAssertEqual(request.accept, KubeClient.metadataListAccept, "metadata only, no fallback to whole objects: \(request)")
            XCTAssertTrue(request.path.hasPrefix("/api/v1/namespaces/shop/"), "the namespace shown: \(request)")
        }
        let secrets = try XCTUnwrap(lists.first { $0.path.hasSuffix("/secrets") })
        XCTAssertEqual(secrets.query["labelSelector"], "owner=helm")
        XCTAssertEqual(secrets.query["fieldSelector"], "type=helm.sh/release.v1", "Helm's records only — not every Secret labelled owner=helm")
        XCTAssertTrue(recordGETs.isEmpty, "no record read for the list: \(recordGETs)")

        // All namespaces: payments' too, the cluster-wide path.
        model.setScope(.all)
        try await until(5, "every namespace's") { helm.releases.count == 3 && helm.scope == .all }
        XCTAssertTrue(api.requests.contains { $0.path == "/api/v1/secrets" && $0.accept == KubeClient.metadataListAccept })
        XCTAssertTrue(api.requests.contains { $0.path == "/api/v1/configmaps" && $0.query["labelSelector"] == "OWNER=TILLER" }, "Tiller's, cluster-wide")
        XCTAssertEqual(page.helmCommand, "helm list --kube-context fake-dev -A")
    }

    func testOpeningAReleaseReadsOneRecordMasked() async throws {
        let (model, page) = try pageOverFake()
        defer { model.hide() }
        try await showHelm(model, page)
        let helm = page.helm
        helm.selection = helm.releases.first { $0.name == "web" }?.id
        XCTAssertTrue(page.press("\r"), "↩ opens the release picked")
        try await until(5, "shown") { helm.opened?.detail != nil }
        XCTAssertEqual(recordGETs.map(\.path), ["/api/v1/namespaces/shop/secrets/sh.helm.release.v1.web.v2"], "one GET, the latest revision's")
        let detail = try XCTUnwrap(helm.opened?.detail)
        XCTAssertEqual(detail.chart.said, "web-1.0.0")
        XCTAssertEqual(helm.charts[helm.opened!.release.id]?.appVersion, "1.27", "the list's Chart and App Version, once opened")
        XCTAssertEqual(helm.summaries[helm.opened!.record.id], "Upgrade complete")
        for text in [detail.userValues, detail.computedValues, detail.manifest, detail.notes] {
            XCTAssertFalse(text.contains(Self.password), text)
            XCTAssertFalse(text.contains(Self.token), text)
        }
        XCTAssertTrue(detail.userValues.contains("password: \"***\""), detail.userValues)
        XCTAssertEqual(detail.notes, "Thanks for installing web.")
        XCTAssertFalse(String(describing: helm.opened as Any).contains(Self.password), "printed, an opened release holds no value")
        XCTAssertEqual(page.helmCommand, "helm status web --kube-context fake-dev -n shop")
        XCTAssertTrue(page.press("k"))
        XCTAssertEqual(copied.last, "helm status web --kube-context fake-dev -n shop")

        // A revision of its history: that record, read on its own.
        let latest = try XCTUnwrap(helm.opened?.record.id)
        let first = try XCTUnwrap(helm.opened?.release.history.last)
        page.openHelm(try XCTUnwrap(helm.opened?.release), revision: first)
        try await until(5, "revision 1") { helm.opened?.detail?.revision == 1 }
        XCTAssertEqual(recordGETs.last?.path, "/api/v1/namespaces/shop/secrets/sh.helm.release.v1.web.v1")
        XCTAssertEqual(helm.charts[helm.opened!.release.id]?.version, "1.0.0", "an older revision doesn't change the list's chart")
        XCTAssertEqual(helm.summaries[latest], "Upgrade complete", "another revision of the same release: its History stays")

        // A ConfigMap's release: its ConfigMap read.
        page.openHelm(try XCTUnwrap(helm.releases.first { $0.name == "cache" }))
        try await until(5, "cache") { helm.opened?.detail?.chart.chart == "redis" }
        XCTAssertEqual(recordGETs.last?.path, "/api/v1/namespaces/shop/configmaps/sh.helm.release.v1.cache.v1")
        XCTAssertNil(helm.summaries[latest], "another release: web's descriptions went")

        // Esc closes it; the page hiding keeps it open, read no more.
        XCTAssertTrue(page.press("\u{1B}"))
        XCTAssertNil(helm.opened)
        XCTAssertTrue(helm.summaries.isEmpty, "History's descriptions go with the release (rule 9)")
        page.openHelm(try XCTUnwrap(helm.releases.first { $0.name == "web" }))
        try await until(5, "web again") { helm.opened?.detail != nil }
        page.visible = false
        guard case .dropped = helm.opened?.state else { return XCTFail("hidden, what was read goes: \(String(describing: helm.opened?.state))") }
        XCTAssertNil(helm.opened?.detail)
        XCTAssertTrue(helm.summaries.isEmpty, "hidden, the descriptions too")
        page.visible = true
        helm.readAgain()
        try await until(5, "read again") { helm.opened?.detail != nil }
        // Another section closes it.
        page.showSection(.workloads)
        XCTAssertNil(helm.opened)
        // Another context forgets what this one said.
        XCTAssertTrue(page.press("8"))
        page.openHelm(try XCTUnwrap(helm.releases.first { $0.name == "web" }))
        try await until(5, "web once more") { helm.opened?.detail != nil }
        model.select("fake-prod")
        try await until(5, "fake-prod's") { helm.context == "fake-prod" }
        XCTAssertNil(helm.opened)
        XCTAssertTrue(helm.charts.isEmpty)
        XCTAssertTrue(helm.summaries.isEmpty)
    }

    func testProductionAsksBeforeTheFirstRelease() async throws {
        let (model, page) = try pageOverFake()
        defer { model.hide() }
        try await showHelm(model, page)
        model.select("fake-prod")
        let helm = page.helm
        try await until(5, "fake-prod's releases") { helm.context == "fake-prod" && helm.listState == .live && helm.releases.count == 2 }
        let reads = recordGETs.count
        page.openHelm(try XCTUnwrap(helm.releases.first { $0.name == "web" }))
        XCTAssertEqual(helm.opened?.state, .confirming, "asked first, naming the context")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(recordGETs.count, reads, "nothing read while it asks")
        helm.cancelConfirmation()
        XCTAssertNil(helm.opened)
        page.openHelm(try XCTUnwrap(helm.releases.first { $0.name == "web" }))
        helm.confirm()
        try await until(5, "shown") { helm.opened?.detail != nil }
        XCTAssertEqual(recordGETs.count, reads + 1)
        XCTAssertFalse(model.secretConsent.needsAsking("fake-prod", production: true), "the session's answer, shared with a Secret's Show")
        page.openHelm(try XCTUnwrap(helm.releases.first { $0.name == "cache" }))
        XCTAssertNotEqual(helm.opened?.state, .confirming, "asked once a context and session")
    }

    func testAForbiddenSecretListDegrades() async throws {
        let (model, page) = try pageOverFake()
        defer { model.hide() }
        api.forbidden = ["secrets"]
        model.show()
        try await until(5, "a context") { model.selectedName == "fake-dev" }
        XCTAssertTrue(page.press("8"))
        let helm = page.helm
        try await until(5, "listed") { helm.listState == .live }
        XCTAssertEqual(helm.releases.map(\.name), ["cache"], "ConfigMap records still list")
        let refused = try XCTUnwrap(helm.secretsRefused)
        XCTAssertTrue(refused.contains("can't list Secrets in shop"), refused)
        XCTAssertTrue(refused.contains("helm in a terminal"), refused)
        page.openHelmTerminal()
        XCTAssertEqual(terminals.first?.0, "fake-dev")
        XCTAssertEqual(terminals.first?.1, "shop", "pinned to the context, in the namespace shown")
        XCTAssertTrue(page.press("k"))
        XCTAssertEqual(copied.last, "helm list --kube-context fake-dev -n shop")

        // Allowed again, Refresh lists them.
        api.forbidden = []
        page.loadHelm()
        try await until(5, "listed again") { helm.listState == .live && helm.releases.count == 2 && helm.secretsRefused == nil }
    }

    func testTheSectionsKeysLeaveTheKindsVerbsAlone() async throws {
        let (model, page) = try pageOverFake()
        defer { model.hide() }
        try await showHelm(model, page)
        let helm = page.helm
        XCTAssertTrue(page.press("\u{F701}"))
        XCTAssertEqual(helm.selection, helm.releases.first?.id)
        XCTAssertTrue(page.press("\u{F701}"))
        XCTAssertEqual(helm.selection, helm.releases.last?.id)
        XCTAssertTrue(page.press("\u{F700}"))
        XCTAssertEqual(helm.selection, helm.releases.first?.id)
        XCTAssertFalse(page.press("r"), "a kind's verb does nothing here")
        XCTAssertFalse(page.press("l"))
        XCTAssertTrue(page.press("9"), "the sections still")
        XCTAssertEqual(page.section, .forwards)
        XCTAssertTrue(page.press("8"))
        XCTAssertTrue(page.press("n"), "and the pickers")
        XCTAssertEqual(page.picker?.kind, .namespace)
    }

    func testATillerReleaseIsListedButNotRead() async throws {
        let (model, page) = try pageOverFake()
        defer { model.hide() }
        // Where Helm 2 writes it: Tiller's namespace, whatever the release's.
        api.addNamespace("kube-system")
        api.add(
            "configmaps", "legacy.v4", namespace: "kube-system", labels: ["OWNER": "TILLER", "NAME": "legacy", "STATUS": "DEPLOYED", "VERSION": "4"],
            data: ["release": KubeHelm.gzip(Data([0x0A, 0x06])).base64EncodedString()])
        try await showHelm(model, page)
        let helm = page.helm
        XCTAssertFalse(helm.releases.contains { $0.storage == .tiller }, "a namespace's list can't say Tiller's releases")
        XCTAssertFalse(api.requests.contains { $0.query["labelSelector"] == "OWNER=TILLER" }, "so it isn't asked for")
        model.setScope(.all)
        try await until(5, "listed") { helm.scope == .all && helm.listState == .live && helm.releases.count == 4 }
        let legacy = try XCTUnwrap(helm.releases.first { $0.name == "legacy" })
        XCTAssertEqual(legacy.storage, .tiller)
        XCTAssertEqual(legacy.namespace, "kube-system", "Tiller's namespace, said as such in the row")
        XCTAssertEqual(legacy.revision, 4)
        let reads = recordGETs.count
        page.openHelm(legacy)
        XCTAssertEqual(helm.opened?.state, .failed(KubeHelmProblem.helm2.localizedDescription))
        XCTAssertEqual(recordGETs.count, reads, "Helm 2's protobuf isn't asked for")
    }

    func testASecretListThatFailsIsSaidOverTheOthers() async throws {
        let (model, page) = try pageOverFake()
        defer { model.hide() }
        api.failingResources = ["secrets"]
        model.show()
        try await until(5, "a context") { model.selectedName == "fake-dev" }
        XCTAssertTrue(page.press("8"))
        let helm = page.helm
        try await until(5, "listed") { helm.listState == .live }
        XCTAssertEqual(helm.releases.map(\.name), ["cache"], "the ConfigMap's release")
        XCTAssertNil(helm.secretsRefused, "not a 403")
        let note = try XCTUnwrap(helm.unlisted, "a 500 is said, not dropped")
        XCTAssertTrue(note.contains("Releases kept in Secrets couldn't be listed"), note)
        XCTAssertTrue(note.contains("shows the others only"), note)
        // Every storage failing: the list fails, no note over nothing.
        api.failingResources = ["secrets", "configmaps"]
        page.loadHelm()
        try await until(5, "failed") { if case .failed = helm.listState { return true } else { return false } }
        XCTAssertNil(helm.unlisted)
        // Back: Refresh lists them all, the note gone.
        api.failingResources = []
        page.loadHelm()
        try await until(5, "listed again") { helm.listState == .live && helm.releases.count == 2 && helm.unlisted == nil }
    }

    func testTheCheatSheetClosesBeforeTheSectionsKeys() async throws {
        let (model, page) = try pageOverFake()
        defer { model.hide() }
        try await showHelm(model, page)
        let helm = page.helm
        page.openHelm(try XCTUnwrap(helm.releases.first { $0.name == "web" }))
        try await until(5, "shown") { helm.opened?.detail != nil }
        let picked = helm.selection
        page.cheatSheet = true
        XCTAssertTrue(page.press("\u{1B}"))
        XCTAssertFalse(page.cheatSheet, "Esc closes the sheet")
        XCTAssertNotNil(helm.opened?.detail, "not the release under it")
        page.cheatSheet = true
        _ = page.press("\u{F701}")
        XCTAssertTrue(page.cheatSheet, "only Esc or ? closes it")
        XCTAssertEqual(helm.selection, picked, "↓ moved nothing hidden")
    }

    func testADecodeStopsWhenCancelled() throws {
        let body = try recordObject(KubeHelm.encode(release()), storage: .secret)
        XCTAssertThrowsError(try KubeHelm.decode(body, storage: .secret, isCancelled: { true })) { XCTAssertTrue($0 is CancellationError) }
        // Asked between the steps: cancelled after the first, it stops there.
        var asked = 0
        XCTAssertThrowsError(
            try KubeHelm.decode(
                body, storage: .secret,
                isCancelled: {
                    asked += 1
                    return asked > 2
                })
        ) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(asked, 3)
    }

    func testADecodeRunsOnHelmsQueueNotThePool() async throws {
        let body = try recordObject(KubeHelm.encode(release()), storage: .secret)
        let detail = try await KubeHelm.decodeOffPool(body, storage: .secret)
        XCTAssertEqual(detail.release, "web")
        XCTAssertFalse(detail.manifest.contains(Self.password))
        // Cancelled before its turn on the queue: nothing decoded, said as cancelled.
        let blocker = DispatchSemaphore(value: 0)
        KubeHelm.decoding.async { blocker.wait() }
        let task = Task { try await KubeHelm.decodeOffPool(body, storage: .secret) }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        try await Task.sleep(for: .milliseconds(20))
        blocker.signal()
        do {
            _ = try await task.value
            XCTFail("a cancelled decode answers CancellationError")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
    }
}
