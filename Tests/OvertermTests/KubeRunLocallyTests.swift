import Foundation
import XCTest

@testable import Overterm

/// Run Locally and Scan (3.12): the Run window planned from fixture pods —
/// a value given copied, a Secret's key asked hidden and never read, a
/// ConfigMap's named and never read, a secret-looking value asked rather
/// than copied, the pod's own fields filled in, `envFrom` named, ports on
/// 127.0.0.1, command and args — a workload's template the same, the
/// command that asks in the tab, and the Scan handoff's image. Pure.
final class KubeRunLocallyTests: XCTestCase {
    nonisolated(unsafe) static let pod: [String: Any] = [
        "metadata": ["name": "web-7d9", "namespace": "shop"],
        "spec": [
            "nodeName": "fake-node-1",
            "serviceAccountName": "web",
            "containers": [
                [
                    "name": "app",
                    "image": "ghcr.io/acme/web:1.4.2",
                    "command": ["/bin/web", "--serve"],
                    "args": ["--port", "8080", "--greeting", "it's me"],
                    "env": [
                        ["name": "PORT", "value": "8080"],
                        ["name": "BASE_URL", "value": "http://localhost:$(PORT)/api"],
                        ["name": "ESCAPED", "value": "$$(PORT)"],
                        ["name": "DB_PASSWORD", "valueFrom": ["secretKeyRef": ["name": "db-auth", "key": "password"]]],
                        ["name": "API_TOKEN", "value": "tok-literal-123"],
                        ["name": "DATABASE_URL", "value": "postgres://shop:hunter2@db:5432/shop"],
                        ["name": "FEATURES", "valueFrom": ["configMapKeyRef": ["name": "web-config", "key": "features"]]],
                        ["name": "POD_NAME", "valueFrom": ["fieldRef": ["fieldPath": "metadata.name"]]],
                        ["name": "POD_NAMESPACE", "valueFrom": ["fieldRef": ["fieldPath": "metadata.namespace"]]],
                        ["name": "NODE", "valueFrom": ["fieldRef": ["fieldPath": "spec.nodeName"]]],
                        ["name": "POD_IP", "valueFrom": ["fieldRef": ["fieldPath": "status.podIP"]]],
                        ["name": "MEMORY", "valueFrom": ["resourceFieldRef": ["resource": "limits.memory"]]],
                        ["name": "LOG_LEVEL", "value": "debug"],
                        ["name": "LOG_LEVEL", "value": "info"],
                        ["name": "my.dotted-name", "valueFrom": ["secretKeyRef": ["name": "odd", "key": "k"]]],
                    ],
                    "envFrom": [["secretRef": ["name": "web-env"]], ["configMapRef": ["name": "web-defaults"], "prefix": "CFG_"]],
                    "ports": [
                        ["containerPort": 8080, "name": "http"], ["containerPort": 9090, "protocol": "UDP"], ["containerPort": 8080, "protocol": "TCP"],
                    ],
                    "volumeMounts": [["name": "cache", "mountPath": "/var/cache/web"]],
                ],
                ["name": "sidecar", "image": "envoyproxy/envoy:v1.30"],
            ],
            "initContainers": [["name": "migrate", "image": "ghcr.io/acme/migrate:1"]],
        ],
        "status": [
            "containerStatuses": [
                ["name": "app", "imageID": "ghcr.io/acme/web@sha256:" + String(repeating: "a", count: 64)],
                ["name": "sidecar", "imageID": "docker-pullable://envoyproxy/envoy@not-a-digest"],
            ]
        ],
    ]

    private func plan() throws -> DockerRunSpec {
        try XCTUnwrap(KubeRunLocally.plan(Self.pod, container: "app", context: "fake-dev", namespace: "shop", object: "pod shop/web-7d9"))
    }

    func testAValueGivenIsCopiedAndExpandedAsTheKubeletDoes() throws {
        let run = try plan()
        XCTAssertEqual(run.image, "ghcr.io/acme/web:1.4.2")
        XCTAssertEqual(
            run.env,
            [
                "PORT=8080", "BASE_URL=http://localhost:8080/api", "ESCAPED=$(PORT)", "POD_NAME=web-7d9", "POD_NAMESPACE=shop", "NODE=fake-node-1",
                "LOG_LEVEL=info",
            ], "the later of two of a name wins")
        XCTAssertTrue(run.removeWhenStopped, "a reproduction, not a server kept")
        XCTAssertTrue(run.detached)
        XCTAssertEqual(KubeRunLocally.expand("$(MISSING)/x$", with: []), "$(MISSING)/x$", "unknown left as written")
    }

    func testSecretsAreAskedNeverCopied() throws {
        let run = try plan()
        XCTAssertEqual(
            run.asked,
            [
                DockerRunSpec.Ask(key: "DB_PASSWORD", from: "Secret db-auth, key password", secret: true),
                DockerRunSpec.Ask(key: "API_TOKEN", from: "its value looks secret — not copied", secret: true),
                DockerRunSpec.Ask(key: "DATABASE_URL", from: "a URL with a password — not copied", secret: true),
                DockerRunSpec.Ask(key: "FEATURES", from: "ConfigMap web-config, key features — not read", secret: false),
            ])
        let everything = ([run.line(), run.command, run.entrypoint] + run.env + run.notes).joined(separator: "\n")
        for value in ["tok-literal-123", "hunter2"] { XCTAssertFalse(everything.contains(value), "\(value) never copied") }
        XCTAssertTrue(run.notes.contains { $0.contains("Secret web-env, ConfigMap web-defaults (prefix CFG_)") && $0.contains("not read") }, "\(run.notes)")
        let left = try XCTUnwrap(run.notes.first { $0.hasPrefix("Left out") })
        for said in ["POD_IP (the pod's status.podIP)", "MEMORY (the container's limits.memory)", "my.dotted-name (Secret odd, key k): a name a shell can't ask for"] {
            XCTAssertTrue(left.contains(said), "\(said) in \(left)")
        }
    }

    func testPortsCommandAndWhatCantComeAlong() throws {
        let run = try plan()
        XCTAssertEqual(run.ports, ["127.0.0.1:8080:8080", "127.0.0.1:9090:9090/udp"], "on 127.0.0.1 only, once each")
        XCTAssertEqual(run.entrypoint, "/bin/web")
        XCTAssertEqual(run.command, #"--serve --port 8080 --greeting 'it'\''s me'"#, "command's other words, then args")
        XCTAssertTrue(run.notes.first?.contains("pod shop/web-7d9, container app, in fake-dev · namespace shop") == true, "\(run.notes)")
        XCTAssertTrue(run.notes.contains { $0.contains("Not mounted: /var/cache/web") })

        let args = ["metadata": [:], "spec": ["containers": [["name": "c", "image": "busybox", "args": ["sleep", "1d"]]]]] as [String: Any]
        let plain = try XCTUnwrap(KubeRunLocally.plan(args, container: "c", context: "kind-fake", namespace: "default", object: "pod default/p"))
        XCTAssertEqual(plain.entrypoint, "")
        XCTAssertEqual(plain.command, "sleep 1d", "args alone are the image's command")
        XCTAssertTrue(plain.asked.isEmpty && plain.ports.isEmpty && plain.env.isEmpty)
        XCTAssertNil(KubeRunLocally.plan(Self.pod, container: "migrate", context: "c", namespace: "n", object: "o"), "an init container runs before, not instead")
    }

    func testAWorkloadIsItsTemplate() throws {
        let deployment: [String: Any] = [
            "metadata": ["name": "web"],
            "spec": ["template": ["metadata": ["labels": ["app": "web"]], "spec": Self.pod["spec"]!]],
            "status": ["replicas": 3],
        ]
        let like = try XCTUnwrap(KubeRunLocally.podLike(deployment, kind: KubeResourceKind.deployments))
        XCTAssertNil(like["status"], "nothing ran yet")
        let run = try XCTUnwrap(KubeRunLocally.plan(like, container: "app", context: "fake-dev", namespace: "shop", object: "deployment shop/web"))
        XCTAssertEqual(run.image, "ghcr.io/acme/web:1.4.2")
        XCTAssertFalse(run.env.contains { $0.hasPrefix("POD_NAME=") }, "a template has no pod name")
        XCTAssertTrue(run.notes.contains { $0.contains("POD_NAME (the pod's metadata.name)") })
        let cron: [String: Any] = ["spec": ["jobTemplate": ["spec": ["template": ["spec": ["containers": [["name": "job", "image": "acme/report:2"]]]]]]]]
        let cronJobs = KubeResourceKind.cronJobs
        XCTAssertEqual(KubeRunLocally.podLike(cron, kind: cronJobs).flatMap { KubeRunLocally.image($0, container: "job") }?.name, "acme/report:2")
        XCTAssertTrue(KubeRunLocally.offers(.pods) && KubeRunLocally.offers(.deployments))
        XCTAssertFalse(KubeRunLocally.offers(.services), "a Service runs nothing")
        XCTAssertNil(KubeRunLocally.podLike(["spec": [:]], kind: .deployments), "no template")
    }

    func testTheScanHandoffsImage() {
        XCTAssertEqual(
            KubeRunLocally.image(Self.pod, container: "app"),
            KubeRunLocally.Image(name: "ghcr.io/acme/web:1.4.2", digest: "sha256:" + String(repeating: "a", count: 64)), "what the kubelet ran")
        XCTAssertEqual(KubeRunLocally.image(Self.pod, container: "sidecar"), KubeRunLocally.Image(name: "envoyproxy/envoy:v1.30", digest: nil))
        XCTAssertNil(KubeRunLocally.image(Self.pod, container: "nope"))
    }

    func testTheRunAsksInTheTabNeverOnItsCommandLine() throws {
        var run = try plan()
        run.asked = Array(run.asked.prefix(1)) + [run.asked[3]]
        let line = run.line(prefix: "DOCKER_HOST=unix:///tmp/d.sock ")
        XCTAssertTrue(line.hasPrefix("sh -c '"), line)
        XCTAssertTrue(line.contains("export DOCKER_HOST=unix:///tmp/d.sock"), "the endpoint exported inside")
        XCTAssertTrue(line.contains("stty -echo 2>/dev/null; IFS= read -r DB_PASSWORD || exit 1"), "a secret read hidden")
        XCTAssertTrue(line.contains("IFS= read -r FEATURES || exit 1;"), "a ConfigMap's read as typed")
        XCTAssertFalse(line.contains("stty -echo 2>/dev/null; IFS= read -r FEATURES"))
        XCTAssertTrue(line.contains(" -e DB_PASSWORD -e FEATURES "), "passed by name")
        XCTAssertTrue(line.contains("exec docker run -d --rm --entrypoint /bin/web -p 127.0.0.1:8080:8080"), line)
        // What sh is given is the script, quoted once.
        let script = try XCTUnwrap(Self.unquote(String(line.dropFirst("sh -c ".count))))
        XCTAssertTrue(script.contains(#"if [ -n "$DB_PASSWORD" ]; then export DB_PASSWORD; else unset DB_PASSWORD; fi"#), script)
        XCTAssertTrue(script.contains(#"--greeting 'it'\''s me'"#), script)
        XCTAssertTrue(script.hasPrefix("trap 'stty echo 2>/dev/null' EXIT; trap 'stty echo 2>/dev/null; exit 130' INT TERM;"), "^C runs nothing")

        run.asked = []
        XCTAssertFalse(run.line().contains("sh -c"), "nothing asked: the plain command")
        XCTAssertFalse(DockerRunSpec.Ask.askable("my.dotted-name"))
        XCTAssertFalse(DockerRunSpec.Ask.askable("1ABC"))
        XCTAssertTrue(DockerRunSpec.Ask.askable("_DB_PASSWORD2"))
    }

    /// `'…'` with `'\''` inside, as `DockerCommands.quote` writes it.
    static func unquote(_ word: String) -> String? {
        guard word.hasPrefix("'"), word.hasSuffix("'"), word.count >= 2 else { return nil }
        return String(word.dropFirst().dropLast()).replacingOccurrences(of: #"'\''"#, with: "'")
    }

    func testTheEngineImageIsFoundByAnyNameItGoesBy() {
        let digest = "sha256:" + String(repeating: "a", count: 64)
        let images = [
            ImageSummary(Id: "sha256:1", RepoTags: ["nginx:1.27"], Created: 0, Size: 1),
            ImageSummary(Id: "sha256:2", RepoTags: ["<none>:<none>"], RepoDigests: ["ghcr.io/acme/web@" + digest], Created: 0, Size: 1),
            ImageSummary(Id: "sha256:3", RepoTags: ["acme/report:2"], Created: 0, Size: 1),
        ]
        XCTAssertEqual(DockerPageModel.localImage(named: "docker.io/library/nginx:1.27", digest: nil, in: images)?.Id, "sha256:1")
        XCTAssertEqual(DockerPageModel.localImage(named: "index.docker.io/library/nginx:1.27", digest: nil, in: images)?.Id, "sha256:1")
        XCTAssertNil(DockerPageModel.localImage(named: "nginx:1.26", digest: nil, in: images))
        XCTAssertNil(DockerPageModel.localImage(named: "nginx", digest: nil, in: images), "nginx is :latest")
        XCTAssertEqual(DockerPageModel.localImage(named: "ghcr.io/acme/web:1.4.2", digest: digest, in: images)?.Id, "sha256:2", "by what the kubelet ran")
        XCTAssertEqual(DockerPageModel.localImage(named: "ghcr.io/acme/web@" + digest, digest: nil, in: images)?.Id, "sha256:2", "pinned")
        XCTAssertNil(DockerPageModel.localImage(named: "ghcr.io/other/web:1", digest: digest, in: images), "the digest is a repository's")
        XCTAssertEqual(DockerPageModel.localImage(named: "docker.io/acme/report:2", digest: nil, in: images)?.Id, "sha256:3")
        XCTAssertEqual(DockerPageModel.pinnedName("ghcr.io/acme/web:1.4.2", digest: digest), "ghcr.io/acme/web@" + digest, "scanned and pulled by digest")
        XCTAssertEqual(DockerPageModel.pinnedName("nginx:1.27", digest: nil), "nginx:1.27")
    }

    /// A tag of the same name built or pulled at another time sits next to
    /// the image the pod ran: the digest decides, never the tag.
    func testAStaleTagIsNotThePodsImage() {
        let ran = "sha256:" + String(repeating: "a", count: 64)
        let other = "sha256:" + String(repeating: "b", count: 64)
        let stale = ImageSummary(Id: "sha256:9", RepoTags: ["ghcr.io/acme/web:1.4.2"], RepoDigests: ["ghcr.io/acme/web@" + other], Created: 0, Size: 1)
        let pinned = ImageSummary(Id: "sha256:2", RepoTags: ["<none>:<none>"], RepoDigests: ["ghcr.io/acme/web@" + ran], Created: 0, Size: 1)
        XCTAssertEqual(DockerPageModel.localImage(named: "ghcr.io/acme/web:1.4.2", digest: ran, in: [stale, pinned])?.Id, "sha256:2")
        XCTAssertNil(DockerPageModel.localImage(named: "ghcr.io/acme/web:1.4.2", digest: ran, in: [stale]), "the tag here is another image")
        XCTAssertEqual(DockerPageModel.localImage(named: "ghcr.io/acme/web:1.4.2", digest: nil, in: [stale, pinned])?.Id, "sha256:9", "no digest: the tag")
    }

    /// `$(VAR)` in command and args as the kubelet expands it, an asked
    /// one left to the tab's shell; a secret flag's value asked, never on
    /// the command line.
    func testTheCommandIsExpandedAndItsSecretFlagsAsked() throws {
        let pod: [String: Any] = [
            "metadata": ["name": "cache-0"],
            "spec": [
                "containers": [
                    [
                        "name": "redis", "image": "redis:7",
                        "command": ["redis-server"],
                        "args": ["--port", "$(PORT)", "--requirepass", "s3cr3t", "--db-password=hunter2", "--auth-from=$(DB_PASSWORD)", "--keep=$(POD_IP)"],
                        "env": [
                            ["name": "PORT", "value": "6380"],
                            ["name": "DB_PASSWORD", "valueFrom": ["secretKeyRef": ["name": "db-auth", "key": "password"]]],
                        ],
                    ]
                ]
            ],
        ]
        let run = try XCTUnwrap(KubeRunLocally.plan(pod, container: "redis", context: "fake-dev", namespace: "shop", object: "pod shop/cache-0"))
        XCTAssertEqual(run.entrypoint, "redis-server")
        XCTAssertEqual(
            run.command, #"--port 6380 --requirepass "$OVERTERM_ARG_1" --db-password="$OVERTERM_ARG_2" --auth-from="$DB_PASSWORD" '--keep=$(POD_IP)'"#)
        XCTAssertEqual(
            run.asked.filter { !$0.env },
            [
                DockerRunSpec.Ask(key: "OVERTERM_ARG_1", from: "--requirepass in its command — not copied", secret: true, env: false),
                DockerRunSpec.Ask(key: "OVERTERM_ARG_2", from: "--db-password in its command — not copied", secret: true, env: false),
            ])
        let line = run.line()
        for value in ["s3cr3t", "hunter2"] { XCTAssertFalse((line + run.notes.joined()).contains(value), "\(value) never copied") }
        XCTAssertTrue(line.contains("IFS= read -r OVERTERM_ARG_1"), line)
        XCTAssertFalse(line.contains("-e OVERTERM_ARG_1"), "a command's value, not the container's env")
        XCTAssertTrue(line.contains(" -e DB_PASSWORD "), line)

        // mysqld's -pvalue; two secrets in one script: nothing copied.
        func command(_ words: [String]) throws -> DockerRunSpec {
            let pod: [String: Any] = ["spec": ["containers": [["name": "c", "image": "busybox", "command": words]]]]
            return try XCTUnwrap(KubeRunLocally.plan(pod, container: "c", context: "kind-fake", namespace: "default", object: "pod default/p"))
        }
        let mysql = try command(["mysql", "-uroot", "-phunter2"])
        XCTAssertEqual(mysql.command, #"-uroot -p"$OVERTERM_ARG_1""#)
        XCTAssertEqual(mysql.asked.map(\.from), ["-p in its command — not copied"])
        let script = try command(["sh", "-c", "app --password a1 --token b2"])
        XCTAssertEqual(script.command, "")
        XCTAssertEqual(script.entrypoint, "")
        XCTAssertTrue(script.notes.contains { $0.contains("not copied") }, "\(script.notes)")
        XCTAssertFalse(script.line().contains("a1") || script.line().contains("b2"))
    }

    /// A credential under a harmless name is asked, not copied: a
    /// `password=` pair, a JWT, a GitHub or AWS token.
    func testAValueThatLooksLikeACredentialIsAsked() throws {
        let jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJmYWtlIn0.c2lnbmF0dXJlLWZha2U"
        let pod: [String: Any] = [
            "spec": [
                "containers": [
                    [
                        "name": "app", "image": "acme/app:1",
                        "env": [
                            ["name": "JAVA_OPTS", "value": "-Xmx512m -Dspring.datasource.password=hunter2"],
                            ["name": "CONFIG", "value": jwt],
                            ["name": "GITHUB_PAT", "value": "ghp" + "_fakefakefakefakefake1234"],
                            ["name": "UPSTREAM", "value": "AKIAFAKEFAKEFAKEFAKE"],
                            ["name": "GREETING", "value": "hello"],
                            ["name": "PATH", "valueFrom": ["secretKeyRef": ["name": "odd", "key": "path"]]],
                        ],
                    ]
                ]
            ]
        ]
        let run = try XCTUnwrap(KubeRunLocally.plan(pod, container: "app", context: "fake-dev", namespace: "shop", object: "pod shop/app"))
        XCTAssertEqual(run.env, ["GREETING=hello"])
        XCTAssertEqual(run.asked.map(\.key), ["JAVA_OPTS", "CONFIG", "GITHUB_PAT", "UPSTREAM"])
        XCTAssertTrue(run.asked.allSatisfy { $0.secret && $0.from == "its value looks like a credential — not copied" })
        let everything = ([run.line()] + run.env + run.notes).joined(separator: "\n")
        for value in ["hunter2", jwt, "ghp_fakefake", "AKIAFAKE"] { XCTAssertFalse(everything.contains(value), "\(value) never copied") }
        // PATH read in the wrapper shell would change which docker runs.
        XCTAssertFalse(run.line().contains("read -r PATH"))
        XCTAssertTrue(run.notes.contains { $0.contains("PATH (Secret odd, key path): a name the shell running docker") }, "\(run.notes)")
        XCTAssertFalse(DockerRunSpec.Ask.askable("PATH") || DockerRunSpec.Ask.askable("LD_PRELOAD") || DockerRunSpec.Ask.askable("DOCKER_HOST"))
    }
}

/// The handoffs against `FakeKubeAPI`: the pod or workload read with one
/// GET — no Secret, no ConfigMap — its container picked when several, and
/// the Docker page handed the Run window's plan or the image to scan.
@MainActor
final class KubeRunLocallyPageTests: XCTestCase {
    private var api: FakeKubeAPI!
    private var socket: String!

    override func setUpWithError() throws {
        socket = "/tmp/otrl-\(UInt32.random(in: 0...UInt32.max)).sock"
        api = FakeKubeAPI(socket: socket)
        try api.start()
        api.addNamespace("shop")
        var web = FakeKubeAPI.Pod()
        web.image = "ghcr.io/acme/web:1.4.2"
        web.env = ["PORT": "8080", "API_TOKEN": "tok-literal-123"]
        web.secretEnv = ["DB_PASSWORD": FakeKubeAPI.SecretKeyRef(name: "db-auth", key: "password")]
        web.ports = [FakeKubeAPI.ContainerPort(8080, name: "http")]
        api.addPod("web-1", namespace: "shop", web)
        var two = FakeKubeAPI.Pod()
        two.containers = 2
        api.addPod("api-1", namespace: "shop", two, annotations: [KubePodContainers.defaultAnnotation: "sidecar-1"])
        api.add(
            "deployments.apps", "web", namespace: "shop",
            fields: ["spec": ["template": ["metadata": ["labels": ["app": "web"]], "spec": ["containers": [["name": "web", "image": "acme/web:2"]]]]]])
    }

    override func tearDown() {
        if let api {
            XCTAssertEqual(api.writes, [], "only GETs")
            XCTAssertFalse(api.requests.contains { $0.path.contains("/secrets") || $0.path.contains("/configmaps") }, "nothing they name read")
            api.stop()
        }
    }

    private final class Box {
        var runs: [DockerRunSpec] = []
        var scans: [(KubeRunLocally.Image, String)] = []
        var choices: [([String], (Int) -> Void)] = []
    }

    private func page() async throws -> (KubernetesPageModel, Box) {
        let model = KubernetesModel(proxies: KubeProxies())
        let context = KubeContext(
            name: "fake-dev", cluster: "fake-dev", server: "http://127.0.0.1:1", namespace: "shop", user: "anonymous", auth: KubeAuth.none, file: nil,
            contextClass: .remote, settings: KubeContextSettings())
        let list = KubeContextList(contexts: [context], current: "fake-dev")
        model.load = { _ in list }
        model.readConfiguration = { KubernetesModel.Configuration() }
        model.watchesSettings = false
        model.remembersSelection = false
        model.flushInterval = .milliseconds(20)
        model.statusInterval = .milliseconds(50)
        let socket = self.socket!
        model.connectOverride = { context in KubeSocketConnection(socket: socket, context: context.name) }
        model.statusOverride = { _ in .open }
        let page = KubernetesPageModel(model: model)
        let box = Box()
        var actions = KubernetesActions(run: { _ in }, settings: {}, copy: { _ in }, copySecret: { _ in })
        actions.runLocally = { box.runs.append($0) }
        actions.scanImage = { box.scans.append(($0, $1)) }
        actions.choose = { _, _, buttons, then in box.choices.append((buttons, then)) }
        page.actions = actions
        model.show()
        try await until("listed") { model.rows.count == 2 }
        return (page, box)
    }

    private func until(_ what: String, _ timeout: TimeInterval = 5, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return XCTFail("timed out: \(what)") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    func testRunLocallyFillsTheRunWindowFromThePod() async throws {
        let (page, box) = try await page()
        defer { page.model.hide() }
        let verbs = page.verbs(for: ["shop/web-1"])
        let run = try XCTUnwrap(verbs.first { $0.title == KubernetesPageModel.runLocallyTitle })
        XCTAssertNil(run.unavailable, "a read, offered on a read-only context")
        XCTAssertEqual(run.place, .more)
        run.perform()
        try await until("handed over") { box.runs.count == 1 }
        let spec = try XCTUnwrap(box.runs.first)
        XCTAssertEqual(spec.image, "ghcr.io/acme/web:1.4.2")
        XCTAssertEqual(spec.env, ["PORT=8080"])
        XCTAssertEqual(spec.asked.map(\.key).sorted(), ["API_TOKEN", "DB_PASSWORD"])
        XCTAssertEqual(spec.asked.first { $0.key == "DB_PASSWORD" }?.from, "Secret db-auth, key password")
        XCTAssertEqual(spec.ports, ["127.0.0.1:8080:8080"])
        XCTAssertFalse(spec.line().contains("tok-literal-123"))
        XCTAssertEqual(
            api.requests.filter { $0.path == "/api/v1/namespaces/shop/pods/web-1" }.map(\.method), ["GET"], "the pod read once")
        let detail = page.detailVerbs(for: try XCTUnwrap(page.ref(for: "shop/web-1"))).map(\.title)
        XCTAssertTrue(detail.contains(KubernetesPageModel.runLocallyTitle) && detail.contains(KubernetesPageModel.scanImageTitle), "\(detail)")
    }

    func testScanPicksTheContainerThenHandsOverItsImage() async throws {
        let (page, box) = try await page()
        defer { page.model.hide() }
        page.verbs(for: ["shop/api-1"]).first { $0.title == KubernetesPageModel.scanImageTitle }?.perform()
        try await until("the picker") { box.choices.count == 1 }
        XCTAssertEqual(box.choices.first?.0, ["sidecar-1 (default)", "app"])
        box.choices.first?.1(0)
        try await until("handed over") { box.scans.count == 1 }
        XCTAssertEqual(box.scans.first?.0.name, "nginx:1.27")
        XCTAssertEqual(box.scans.first?.1, "pod shop/api-1 (container sidecar-1, in fake-dev)")
        XCTAssertTrue(box.runs.isEmpty)
    }

    func testAWorkloadsTemplateAndDockerOff() async throws {
        let (page, box) = try await page()
        defer { page.model.hide() }
        let ref = KubeObjectRef(context: "fake-dev", kind: .deployments, namespace: "shop", name: "web")
        page.toDocker(.run, ref)
        try await until("handed over: \(String(describing: page.writeStatus))") { box.runs.count == 1 }
        XCTAssertEqual(box.runs.first?.image, "acme/web:2")
        XCTAssertTrue(box.runs.first?.notes.first?.contains("deployment shop/web") == true, "\(box.runs.first?.notes ?? [])")
        XCTAssertTrue(page.dockerVerbs(for: KubeObjectRef(context: "fake-dev", kind: .services, namespace: "shop", name: "web")).isEmpty)

        let was = Settings.shared.value("docker.enabled")
        Settings.shared.set("docker.enabled", .bool(false))
        defer { Settings.shared.set("docker.enabled", was) }
        XCTAssertEqual(page.dockerVerbs(for: ref).first?.unavailable, "Docker is off — Settings ▸ Docker")
        page.toDocker(.scan, ref)
        XCTAssertEqual(page.writeStatus, .failed("Docker is off — Settings ▸ Docker."))
        XCTAssertTrue(box.scans.isEmpty)
    }
}

/// Scan from elsewhere on the Docker page, against `FakeDockerEngine`: an
/// image the engine has is scanned on its Vulnerabilities tab at once; one
/// it hasn't is asked first, pulled only on the user's word.
@MainActor
final class DockerScanHandoffTests: XCTestCase {
    func testAnImageHereIsScannedOneNotHereIsAskedFirst() async throws {
        let socket = "/tmp/ot-scan-\(UUID().uuidString.prefix(8)).sock"
        let fake = FakeDockerEngine(socket: socket)
        try fake.start()
        defer { fake.stop() }
        let id = fake.addImage("nginx:1.27", size: 1 << 20)
        let endpoint = DockerEndpoint(address: .unix(socket), context: nil, source: "test")
        let docker = DockerModel(endpoint: { endpoint }, retries: [.milliseconds(50)])
        docker.start()
        defer { docker.stop() }
        let page = DockerPageModel(docker: docker)
        var confirms: [(String, String, () -> Void)] = []
        page.actions = DockerActions(
            run: { _, _ in }, confirm: { title, detail, _, then in confirms.append((title, detail, then)) }, open: { _ in }, copy: { _ in }, settings: {})
        page.scanImage(named: "docker.io/library/nginx:1.27", from: "pod shop/web-1")
        let deadline = Date().addingTimeInterval(5)
        while page.scans.scan(for: id) == nil, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(page.section, .images)
        XCTAssertEqual(page.imageSelection, [id])
        XCTAssertEqual(page.imageTab, .vulnerabilities)
        XCTAssertEqual(page.scans.scan(for: id)?.image, "nginx:1.27", "by the engine's own name")
        XCTAssertTrue(confirms.isEmpty)

        page.scanImage(named: "ghcr.io/acme/web:1.4.2", from: "pod shop/web-1")
        let asked = Date().addingTimeInterval(5)
        while confirms.isEmpty, Date() < asked { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(confirms.first?.0, "Pull ghcr.io/acme/web:1.4.2 to scan it?")
        XCTAssertTrue(confirms.first?.1.hasPrefix("pod shop/web-1 runs it") == true)
        XCTAssertTrue(page.pulls.isEmpty, "nothing pulled until the user says")
    }

    /// Pull and Scan: the image the pod ran pulled by its digest, not its
    /// tag — a stale local tag of the same name left alone — then scanned.
    func testPullAndScanPullsTheDigestThePodRan() async throws {
        let socket = "/tmp/ot-scan-\(UUID().uuidString.prefix(8)).sock"
        let fake = FakeDockerEngine(socket: socket)
        try fake.start()
        defer { fake.stop() }
        let ran = "sha256:" + String(repeating: "a", count: 64)
        let stale = fake.addImage("ghcr.io/acme/web:1.4.2", size: 1 << 20, digest: "sha256:" + String(repeating: "b", count: 64))
        let endpoint = DockerEndpoint(address: .unix(socket), context: nil, source: "test")
        let docker = DockerModel(endpoint: { endpoint }, retries: [.milliseconds(50)])
        docker.start()
        defer { docker.stop() }
        let page = DockerPageModel(docker: docker)
        var confirms: [(String, String, () -> Void)] = []
        page.actions = DockerActions(
            run: { _, _ in }, confirm: { title, detail, _, then in confirms.append((title, detail, then)) }, open: { _ in }, copy: { _ in }, settings: {})
        page.scanImage(named: "ghcr.io/acme/web:1.4.2", digest: ran, from: "pod shop/web-1")
        let asked = Date().addingTimeInterval(5)
        while confirms.isEmpty, Date() < asked { try await Task.sleep(for: .milliseconds(20)) }
        let pinned = "ghcr.io/acme/web@" + ran
        XCTAssertEqual(confirms.first?.0, "Pull \(pinned) to scan it?")
        XCTAssertTrue(confirms.first?.1.contains("is another image") == true, confirms.first?.1 ?? "")
        XCTAssertNil(page.scans.scan(for: stale), "the stale tag isn't scanned for the pod")
        confirms.first?.2()
        XCTAssertEqual(Array(page.pulls.keys), [pinned], "pulled by digest")
        let deadline = Date().addingTimeInterval(10)
        func pulled() -> String? { fake.allImages.first { $0.RepoDigests?.contains(pinned) == true }?.Id }
        while pulled().map({ page.scans.scan(for: $0) }) ?? nil == nil, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        let id = try XCTUnwrap(pulled())
        XCTAssertNotEqual(id, stale)
        XCTAssertEqual(page.scans.scan(for: id)?.image, pinned, "scanned as what the pod ran")
        XCTAssertEqual(page.imageSelection, [id])
        XCTAssertNil(page.scans.scan(for: stale))
        XCTAssertNil(page.error)
    }

    func testAPullThatCantStartSaysSo() {
        let page = DockerPageModel(docker: DockerModel(endpoint: { nil }))
        page.pullThenScan("ghcr.io/acme/web:1.4.2", digest: nil)
        XCTAssertEqual(page.error, "Docker isn't running: ghcr.io/acme/web:1.4.2 can't be pulled.")
        XCTAssertTrue(page.pulls.isEmpty)
    }
}
