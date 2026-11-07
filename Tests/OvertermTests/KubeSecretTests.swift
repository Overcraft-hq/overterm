import Foundation
import XCTest

@testable import Overterm

/// A Secret's values (docs/design/kubernetes/analysis.md, rule 9): taken
/// apart as Show reads them — masked, lengths only, `tls.key` never
/// decoded, the last-applied annotation gone — a TLS Secret's certificate
/// read, and against `FakeKubeAPI` the page's Show: the list never asks
/// for data, the detail never GETs before Show, production asks first,
/// one value revealed at a time, Copy only when asked, and everything
/// dropped on navigation, the page hiding, another context and a timeout.
/// The certificate is `FakeKubeAPI.testCertificatePEM`, public only. No
/// cluster of the user's is reached.
@MainActor
final class KubeSecretTests: XCTestCase {
    private static let password = "acme-unit-pw-Zq7Lm"

    private func secretJSON(type: String = "Opaque", data: [String: String], annotations: [String: String] = [:]) throws -> Data {
        var metadata: [String: Any] = ["name": "web-db", "namespace": "shop", "uid": "u-1"]
        if !annotations.isEmpty { metadata["annotations"] = annotations }
        let object: [String: Any] = ["kind": "Secret", "apiVersion": "v1", "type": type, "metadata": metadata, "data": data]
        return try JSONSerialization.data(withJSONObject: object)
    }

    private func base64(_ text: String) -> String { Data(text.utf8).base64EncodedString() }

    // MARK: Taken apart

    func testASecretIsTakenApartWithItsValuesMasked() throws {
        let body = try secretJSON(
            data: ["password": base64(Self.password), "username": base64("web"), "blob": Data([0, 1, 2, 255]).base64EncodedString()],
            annotations: [KubeObjectStrip.lastApplied: "{\"data\":{\"password\":\"\(base64(Self.password))\"}}", "team": "shop"])
        let read = try KubeSecret.read(body)
        XCTAssertEqual(read.type, "Opaque")
        XCTAssertEqual(read.entries.map(\.key), ["blob", "password", "username"], "by key")
        XCTAssertEqual(read.entries.map(\.length), [4, Self.password.utf8.count, 3])
        XCTAssertEqual(read.entries.map(\.isBinary), [true, false, false])
        XCTAssertEqual(read.values["password"], Data(Self.password.utf8))

        let stripped = String(decoding: read.stripped, as: UTF8.self)
        XCTAssertFalse(stripped.contains(Self.password))
        XCTAssertFalse(stripped.contains(base64(Self.password)), "nor its base64")
        XCTAssertFalse(stripped.contains(KubeObjectStrip.lastApplied), "the last-applied annotation can hold every value: gone")
        XCTAssertTrue(stripped.contains("\"team\":\"shop\""), "other annotations stay")
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: read.stripped) as? [String: Any])
        XCTAssertEqual(object["data"] as? [String: String], ["blob": "***", "password": "***", "username": "***"])
        let yaml = KubeYAML.text(KubeObjectStrip.shown(object, full: true))
        XCTAssertTrue(yaml.contains("password: \"***\""), yaml)
        XCTAssertFalse(yaml.contains(Self.password))

        // Printed, a read says its keys and never a value.
        XCTAssertFalse(String(describing: read).contains(Self.password))
        XCTAssertFalse(String(describing: read).contains(base64(Self.password)))
        XCTAssertEqual(read.entries.first { $0.key == "password" }?.masked, "•••••••• · \(Self.password.utf8.count) bytes")
    }

    func testATLSSecretsKeyIsNeverDecoded() throws {
        let key = "-----BEGIN PRIVATE KEY-----\nbm90LWEta2V5\n-----END PRIVATE KEY-----\n"
        let body = try secretJSON(type: KubeSecret.tlsType, data: ["tls.crt": base64(FakeKubeAPI.testCertificatePEM), "tls.key": base64(key)])
        let read = try KubeSecret.read(body)
        let entry = try XCTUnwrap(read.entries.first { $0.key == "tls.key" })
        XCTAssertTrue(entry.isPrivateKey)
        XCTAssertEqual(entry.length, key.utf8.count, "its length from the base64 alone")
        XCTAssertEqual(entry.masked, "private key · never shown")
        XCTAssertNil(read.values["tls.key"], "never decoded, never kept")
        XCTAssertNotNil(read.values["tls.crt"])
        // Not a TLS Secret: a key called tls.key is an ordinary value.
        XCTAssertFalse(KubeSecret.isPrivateKey("tls.key", type: "Opaque"))
    }

    func testAnAnswerThatIsntASecretSaysNothingOfIt() throws {
        let configMap = try JSONSerialization.data(withJSONObject: [
            "kind": "ConfigMap", "apiVersion": "v1", "metadata": ["name": "x"], "data": ["password": Self.password],
        ])
        XCTAssertThrowsError(try KubeSecret.read(configMap)) { error in
            XCTAssertEqual(error as? KubeSecret.Unreadable, KubeSecret.Unreadable())
            XCTAssertFalse(error.localizedDescription.contains(Self.password))
        }
        XCTAssertThrowsError(try KubeSecret.read(Data("not json \(Self.password)".utf8))) { error in
            XCTAssertFalse(error.localizedDescription.contains(Self.password), "the answer is never quoted")
        }
    }

    func testLengthsAndTextAreTold() {
        for text in ["", "a", "ab", "abc", "abcd", "hello world", Self.password] {
            XCTAssertEqual(KubeSecret.decodedLength(ofBase64: base64(text)), text.utf8.count, text)
        }
        XCTAssertEqual(KubeSecret.decodedLength(ofBase64: "aGVs\nbG8=\n"), 5, "line breaks don't count")
        XCTAssertTrue(KubeSecret.isText(Data("line one\nline two\ttab".utf8)))
        XCTAssertTrue(KubeSecret.isText(Data("şifre ğ".utf8)))
        XCTAssertFalse(KubeSecret.isText(Data([0xFF, 0xFE])))
        XCTAssertFalse(KubeSecret.isText(Data([0x41, 0x00, 0x42])))
    }

    // MARK: The certificate

    private func utc(_ text: String) -> Date { try! Date(text, strategy: .iso8601) }

    func testATLSCertificateIsRead() throws {
        let certificates = KubeCertificate.certificates(inPEM: FakeKubeAPI.testCertificatePEM)
        XCTAssertEqual(certificates.count, 1)
        let certificate = try XCTUnwrap(certificates.first)
        XCTAssertEqual(certificate.subject, "C=US, O=Acme Fake, CN=web.acme.example")
        XCTAssertEqual(certificate.commonName, "web.acme.example")
        XCTAssertEqual(certificate.issuer, certificate.subject)
        XCTAssertTrue(certificate.isSelfSigned)
        XCTAssertTrue(certificate.isCA)
        XCTAssertEqual(certificate.alternativeNames, ["DNS:web.acme.example", "DNS:*.shop.acme.example", "IP:10.0.0.12", "email:ops@acme.example"])
        XCTAssertEqual(certificate.notBefore, utc("2026-11-04T03:59:47Z"))
        XCTAssertEqual(certificate.notAfter, utc("2036-11-01T03:59:47Z"))

        XCTAssertEqual(certificate.validity(at: utc("2026-11-04T03:59:46Z")), .notYetValid)
        XCTAssertEqual(certificate.validity(at: utc("2030-01-01T00:00:00Z")), .valid)
        XCTAssertEqual(certificate.validity(at: utc("2036-10-22T03:59:47Z")), .expiringSoon(days: 10))
        XCTAssertEqual(certificate.validity(at: utc("2036-11-01T03:59:47Z")), .expired)
    }

    func testOnlyCertificateBlocksAreRead() {
        let chain = "-----BEGIN PRIVATE KEY-----\nbm90LWEta2V5\n-----END PRIVATE KEY-----\n" + FakeKubeAPI.testCertificatePEM + FakeKubeAPI.testCertificatePEM
        XCTAssertEqual(KubeCertificate.certificates(inPEM: chain).count, 2, "the chain, the key passed over")
        XCTAssertEqual(KubeCertificate.certificates(inPEM: "fake-crt"), [])
        XCTAssertEqual(KubeCertificate.certificates(inPEM: "-----BEGIN CERTIFICATE-----\nAAAA\n-----END CERTIFICATE-----"), [])
    }

    func testATruncatedCertificateIsNoCertificate() throws {
        let body = FakeKubeAPI.testCertificatePEM.split(separator: "\n").filter { !$0.hasPrefix("-----") }.joined()
        let der = try XCTUnwrap(Data(base64Encoded: body))
        XCTAssertNotNil(KubeCertificate.parse(der: der))
        for length in stride(from: 0, to: der.count, by: 7) {
            XCTAssertNil(KubeCertificate.parse(der: der.prefix(length)), "cut at \(length)")
        }
        var corrupt = der
        corrupt[1] = 0xFF
        XCTAssertNil(KubeCertificate.parse(der: corrupt))
    }

    // MARK: Production asks

    func testProductionAsksOncePerContextAndSession() async throws {
        let consent = KubeSecretConsent()
        XCTAssertTrue(consent.needsAsking("fake-prod", production: true))
        XCTAssertFalse(consent.needsAsking("fake-dev", production: false))
        consent.grant("fake-prod")
        XCTAssertFalse(consent.needsAsking("fake-prod", production: true))
        XCTAssertTrue(consent.needsAsking("acme-prod", production: true), "another production context asks for itself")
        consent.forget()
        XCTAssertTrue(consent.needsAsking("fake-prod", production: true))
    }

    // MARK: The page, against the fake

    private var api: FakeKubeAPI!
    private var copied: [String] = []
    private var copiedSecrets: [String] = []

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

    private var secretGETs: [FakeKubeAPI.Request] { api.requests.filter { $0.path.contains("/secrets/") } }

    private func pageOverFake() throws -> (KubernetesModel, KubernetesPageModel) {
        let socket = "/tmp/otks-\(UInt32.random(in: 0...UInt32.max)).sock"
        api = FakeKubeAPI(socket: socket)
        try api.start()
        api.addNamespace("shop")
        api.addNamespace("payments")
        api.add(
            "secrets", "web-db", namespace: "shop", values: ["Type": "Opaque"], annotations: [KubeObjectStrip.lastApplied: "{\"password\":\"\(Self.password)\"}"],
            data: ["password": Self.password, "username": "web"])
        api.add(
            "secrets", "web-tls", namespace: "shop", values: ["Type": .text(KubeSecret.tlsType)],
            data: ["tls.crt": FakeKubeAPI.testCertificatePEM, "tls.key": "not-a-key"])
        api.add("secrets", "api-key", namespace: "payments", values: ["Type": "Opaque"], data: ["token": "acme-unit-token"])
        api.addPod("web-7d9", namespace: "shop")

        let model = KubernetesModel(proxies: KubeProxies())
        let dev = KubeContext(
            name: "fake-dev", cluster: "fake-dev", server: "http://127.0.0.1:1", namespace: "shop", user: "anonymous", auth: KubeAuth.none, file: nil,
            contextClass: .remote, settings: KubeContextSettings())
        let prod = KubeContext(
            name: "fake-prod", cluster: "fake-prod", server: "http://127.0.0.1:1", namespace: "shop", user: "anonymous", auth: KubeAuth.none, file: nil,
            contextClass: .production, settings: KubeContextSettings())
        let list = KubeContextList(contexts: [dev, prod], current: "fake-dev")
        model.load = { _ in list }
        model.readConfiguration = { KubernetesModel.Configuration() }
        model.watchesSettings = false
        model.remembersSelection = false
        model.flushInterval = .milliseconds(20)
        model.statusInterval = .milliseconds(50)
        model.connectOverride = { context in KubeSocketConnection(socket: socket, context: context.name) }
        model.statusOverride = { _ in .open }
        let page = KubernetesPageModel(model: model)
        page.actions = KubernetesActions(
            run: { _ in }, settings: {}, copy: { [weak self] in self?.copied.append($0) }, copySecret: { [weak self] in self?.copiedSecrets.append($0) })
        page.visible = true
        return (model, page)
    }

    /// The secrets listed, `name`'s detail open — read nothing yet.
    private func openSecret(_ name: String, _ model: KubernetesModel, _ page: KubernetesPageModel, count: Int = 2) async throws -> KubeDetailSession {
        if model.kind.fullName != "secrets" {
            try await until(5, "discovery") { model.discovery != nil }
            page.showKind(try XCTUnwrap(model.discovery?.kind("secrets")))
        }
        try await until(5, "secrets listed") { model.kind.fullName == "secrets" && model.rows.count == count }
        page.selection = ["\(model.rows.sorted.first { $0.id.name == name }?.id.description ?? name)"]
        XCTAssertTrue(page.openSelected())
        let detail = try XCTUnwrap(page.detail)
        XCTAssertEqual(detail.ref.name, name)
        return detail
    }

    func testTheSecretListNeverAsksForData() async throws {
        let (model, page) = try pageOverFake()
        model.show()
        defer { model.hide() }
        try await until(5, "discovery") { model.discovery != nil }
        page.showKind(try XCTUnwrap(model.discovery?.kind("secrets")))
        try await until(5, "secrets listed") { model.rows.count == 2 && model.kind.fullName == "secrets" }
        // The list: a streaming list on this 1.34.
        let lists = api.requests.filter { $0.path == "/api/v1/namespaces/shop/secrets" && (!$0.isWatch || $0.query["sendInitialEvents"] == "true") }
        XCTAssertFalse(lists.isEmpty)
        for request in api.requests where request.path.hasSuffix("/secrets") {
            XCTAssertTrue(request.accept.hasPrefix("application/json;as=Table"), "\(request) \(request.accept)")
            XCTAssertEqual(request.query["includeObject"], "None", "rows only, in one namespace: \(request)")
        }
        let row = try XCTUnwrap(model.rows[KubeRowID(namespace: "shop", name: "web-db")])
        XCTAssertEqual(row.cell("Data", in: model.rows.columns), .integer(2), "how many keys")
        XCTAssertEqual(row.cell("Type", in: model.rows.columns)?.text, "Opaque")

        // Across all namespaces the rows carry metadata — never the
        // last-applied annotation, which here holds a value.
        model.setScope(.all)
        try await until(5, "every namespace's") { model.rows.count == 3 }
        XCTAssertTrue(api.requests.contains { $0.path == "/api/v1/secrets" && $0.query["includeObject"] == "Metadata" })
        XCTAssertFalse(String(describing: model.rows).contains(Self.password))
        XCTAssertFalse(String(describing: model.rows).contains(base64(Self.password)))
        XCTAssertTrue(secretGETs.isEmpty, "\(secretGETs)")
    }

    func testTheDetailDoesntReadBeforeShow() async throws {
        let (model, page) = try pageOverFake()
        model.show()
        defer { model.hide() }
        let detail = try await openSecret("web-db", model, page)
        let secret = try XCTUnwrap(detail.secret)
        XCTAssertEqual(detail.state, .withheld)
        XCTAssertEqual(secret.state, .hidden)
        XCTAssertEqual(secret.listedType, "Opaque", "what the row says")
        XCTAssertEqual(secret.listedKeys, 2)
        XCTAssertFalse(secret.isProduction)
        detail.load()
        page.showTab(.yaml)
        page.showTab(.events)
        try await until(5, "events") { detail.events.value != nil }
        page.showTab(.overview)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(secretGETs.isEmpty, "nothing before Show: \(secretGETs)")
        XCTAssertNil(detail.object)
        XCTAssertEqual(detail.yaml, "")
        XCTAssertFalse(secret.holdsValues)
    }

    func testShowReadsOnceAndRevealsOneValueAtATime() async throws {
        let (model, page) = try pageOverFake()
        model.show()
        defer { model.hide() }
        let detail = try await openSecret("web-db", model, page)
        let secret = try XCTUnwrap(detail.secret)
        XCTAssertTrue(page.showSecret())
        try await until(5, "shown") { secret.state == .shown }
        XCTAssertEqual(secretGETs.map(\.path), ["/api/v1/namespaces/shop/secrets/web-db"], "one GET")
        XCTAssertEqual(secret.entries.map(\.key), ["password", "username"])
        XCTAssertEqual(secret.entries.map(\.length), [Self.password.utf8.count, 3])
        XCTAssertNil(secret.revealed, "every value masked")
        XCTAssertNil(secret.revealedText)

        // The object without its values: the Overview and the YAML.
        XCTAssertEqual(detail.state, .loaded)
        XCTAssertNotNil(detail.overview)
        XCTAssertTrue(detail.yaml.contains("password: \"***\""), detail.yaml)
        XCTAssertFalse(detail.yaml.contains(Self.password))
        XCTAssertFalse(detail.yaml.contains(KubeObjectStrip.lastApplied))
        detail.showsHidden = true
        XCTAssertFalse(detail.yaml.contains(Self.password), "the toggle shows no value either")
        XCTAssertFalse(detail.yaml.contains(KubeObjectStrip.lastApplied))
        XCTAssertFalse(String(decoding: detail.object?.data ?? Data(), as: UTF8.self).contains(base64(Self.password)))

        XCTAssertTrue(secret.reveal("password"))
        XCTAssertEqual(secret.revealedText, Self.password)
        XCTAssertTrue(secret.reveal("username"))
        XCTAssertEqual(secret.revealed, "username", "revealing another hides the first")
        XCTAssertEqual(secret.revealedText, "web")
        XCTAssertFalse(secret.reveal("nope"))
        secret.conceal()
        XCTAssertNil(secret.revealedText)

        // Copy: only when asked, one value, marked concealed.
        XCTAssertTrue(copiedSecrets.isEmpty)
        page.copySecretValue("password")
        XCTAssertEqual(copiedSecrets, [Self.password])
        XCTAssertTrue(copied.isEmpty, "never through the plain copy")

        // Show again while shown reads nothing more.
        secret.show()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(secretGETs.count, 1)
        // Hide: dropped, the detail back to Show.
        secret.drop(.asked)
        XCTAssertEqual(secret.state, .hidden)
        XCTAssertFalse(secret.holdsValues)
        XCTAssertEqual(detail.state, .withheld)
        XCTAssertNil(detail.object)
        XCTAssertEqual(detail.yaml, "")
        XCTAssertNil(secret.copyValue("password"))
    }

    func testATLSSecretShowsItsCertificateNeverItsKey() async throws {
        let (model, page) = try pageOverFake()
        model.show()
        defer { model.hide() }
        let detail = try await openSecret("web-tls", model, page)
        let secret = try XCTUnwrap(detail.secret)
        secret.show()
        try await until(5, "shown") { secret.state == .shown }
        XCTAssertEqual(secret.type, KubeSecret.tlsType)
        XCTAssertEqual(secret.certificates.first?.commonName, "web.acme.example")
        XCTAssertEqual(secret.certificates.first?.alternativeNames.first, "DNS:web.acme.example")
        let key = try XCTUnwrap(secret.entries.first { $0.key == "tls.key" })
        XCTAssertTrue(key.isPrivateKey)
        XCTAssertFalse(secret.reveal("tls.key"))
        XCTAssertNil(secret.revealedText)
        XCTAssertNil(secret.copyValue("tls.key"))
        page.copySecretValue("tls.key")
        XCTAssertTrue(copiedSecrets.isEmpty)
        XCTAssertTrue(secret.reveal("tls.crt"), "the certificate is public")
        XCTAssertEqual(secret.revealedText, FakeKubeAPI.testCertificatePEM)
    }

    func testEverythingIsDroppedOnNavigation() async throws {
        let (model, page) = try pageOverFake()
        model.show()
        defer { model.hide() }
        let detail = try await openSecret("web-db", model, page)
        let secret = try XCTUnwrap(detail.secret)
        secret.show()
        try await until(5, "shown") { secret.state == .shown }
        secret.reveal("password")

        // The next row: the first Secret's values go with its detail.
        page.selection = ["shop/web-tls"]
        XCTAssertEqual(page.detail?.ref.name, "web-tls")
        XCTAssertEqual(secret.state, .hidden)
        XCTAssertFalse(secret.holdsValues)
        XCTAssertTrue(secret.entries.isEmpty)
        XCTAssertNil(secret.revealedText)
        XCTAssertEqual(secret.dropped, .navigation)
        XCTAssertEqual(page.detail?.secret?.state, .hidden, "the next one isn't read either")

        // Back to it: a new detail, read again only on Show.
        page.goBack()
        let again = try XCTUnwrap(page.detail?.secret)
        XCTAssertFalse(again === secret)
        XCTAssertEqual(again.state, .hidden)
        XCTAssertNil(again.revealedText)

        // Shown, then the detail closed (Esc).
        again.show()
        try await until(5, "shown again") { again.state == .shown }
        XCTAssertEqual(secretGETs.count, 2)
        page.closeDetail()
        XCTAssertFalse(again.holdsValues)
        XCTAssertEqual(again.state, .hidden)
    }

    func testEverythingIsDroppedWhenThePageHides() async throws {
        let (model, page) = try pageOverFake()
        model.show()
        defer { model.hide() }
        let detail = try await openSecret("web-db", model, page)
        let secret = try XCTUnwrap(detail.secret)
        secret.show()
        try await until(5, "shown") { secret.state == .shown }
        secret.reveal("password")
        page.visible = false
        XCTAssertFalse(secret.holdsValues)
        XCTAssertEqual(secret.state, .hidden)
        XCTAssertEqual(secret.dropped, .pageHidden)
        XCTAssertEqual(detail.state, .withheld, "the views reset")
        XCTAssertNil(detail.overview)
        page.visible = true
        XCTAssertEqual(secret.state, .hidden, "shown again, the page asks again")

        // Its window off screen counts as hidden too.
        secret.show()
        try await until(5, "shown") { secret.state == .shown }
        page.windowVisible = false
        XCTAssertFalse(secret.holdsValues)
        page.windowVisible = true
    }

    func testEverythingIsDroppedOnAnotherContext() async throws {
        let (model, page) = try pageOverFake()
        model.show()
        defer { model.hide() }
        let detail = try await openSecret("web-db", model, page)
        let secret = try XCTUnwrap(detail.secret)
        secret.show()
        try await until(5, "shown") { secret.state == .shown }
        model.select("fake-prod")
        try await until(5, "the detail goes") { page.detail == nil }
        XCTAssertFalse(secret.holdsValues)
        XCTAssertEqual(secret.state, .hidden)
        XCTAssertNil(secret.revealedText)
        XCTAssertEqual(secret.dropped, .contextChanged, "said as another context's, not navigation")
    }

    func testEverythingIsDroppedAfterTheTimeout() async throws {
        let (model, page) = try pageOverFake()
        model.show()
        defer { model.hide() }
        let detail = try await openSecret("web-db", model, page)
        let secret = try XCTUnwrap(detail.secret)
        secret.timeout = .milliseconds(300)
        secret.show()
        try await until(5, "shown") { secret.state == .shown }
        // A reveal starts the time again.
        try await Task.sleep(for: .milliseconds(200))
        secret.reveal("password")
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(secret.state, .shown, "a look keeps it")
        try await until(5, "dropped") { secret.state == .hidden }
        XCTAssertEqual(secret.dropped, .timeout)
        XCTAssertEqual(secret.droppedNote, "Hidden again after 0 seconds without a look.")
        XCTAssertFalse(secret.holdsValues)
        XCTAssertEqual(detail.state, .withheld)
        XCTAssertEqual(KubeSecretSession.said(KubeSecretSession.defaultTimeout), "2 minutes")
    }

    func testShowOnProductionAsksFirst() async throws {
        let (model, page) = try pageOverFake()
        model.show()
        defer { model.hide() }
        try await until(5, "the contexts") { model.discovery != nil }
        model.select("fake-prod")
        try await until(5, "fake-prod's discovery") { model.selectedName == "fake-prod" && model.discovery != nil }
        let detail = try await openSecret("web-db", model, page)
        let secret = try XCTUnwrap(detail.secret)
        XCTAssertTrue(secret.isProduction)
        secret.show()
        XCTAssertEqual(secret.state, .confirming)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(secretGETs.isEmpty, "nothing read while it asks")
        secret.cancelConfirmation()
        XCTAssertEqual(secret.state, .hidden)
        secret.show()
        XCTAssertEqual(secret.state, .confirming, "cancelled, it asks again")
        secret.confirm()
        try await until(5, "shown") { secret.state == .shown }
        XCTAssertEqual(secretGETs.count, 1)

        // The next Secret on fake-prod this session: no question.
        page.selection = ["shop/web-tls"]
        let next = try XCTUnwrap(page.detail?.secret)
        next.show()
        XCTAssertEqual(next.state, .loading)
        try await until(5, "shown") { next.state == .shown }
        XCTAssertFalse(model.secretConsent.needsAsking("fake-prod", production: true))
    }
}
