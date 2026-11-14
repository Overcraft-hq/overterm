import XCTest

@testable import Overterm

/// Ask Why (stage 1e; docs/design/kubernetes/analysis.md, 3.4): what is
/// wrong with a pod or a Deployment, the brief's words for each failure —
/// exit codes, events, previous logs, the template and its diff with the
/// previous ReplicaSet, a Pending pod's requests against the nodes — the
/// shared scrubbing (every pattern; a Secret's env named, never valued),
/// the bounds, and the reads against `FakeKubeAPI` on a socket of the
/// test's own: only GETs, never a Secret's. Nothing reads ~/.kube.
final class KubeAgentTroubleTests: XCTestCase {
    private func pod(phase: String = "Running", _ statuses: [[String: Any]], conditions: [[String: Any]] = []) -> [String: Any] {
        ["kind": "Pod", "apiVersion": "v1", "metadata": ["name": "worker-1", "namespace": "shop"], "status": ["phase": phase, "containerStatuses": statuses, "conditions": conditions]]
    }

    private func waiting(_ reason: String, last: [String: Any]? = nil, restarts: Int = 0) -> [String: Any] {
        var status: [String: Any] = ["name": "app", "state": ["waiting": ["reason": reason, "message": "back-off 5m0s"]], "restartCount": restarts]
        if let last { status["lastState"] = ["terminated": last] }
        return status
    }

    func testEachFailureKindIsReadOffThePod() {
        XCTAssertEqual(
            KubeTrouble.of(pod: pod([waiting("CrashLoopBackOff", last: ["reason": "Error", "exitCode": 1], restarts: 5)])), .crashLoop(container: "app", exit: 1))
        XCTAssertEqual(
            KubeTrouble.of(pod: pod([waiting("CrashLoopBackOff", last: ["reason": "OOMKilled", "exitCode": 137], restarts: 3)])),
            .outOfMemory(container: "app"), "a crash loop of OOM kills is out of memory")
        XCTAssertEqual(
            KubeTrouble.of(pod: pod([["name": "app", "state": ["terminated": ["reason": "OOMKilled", "exitCode": 137]]]])), .outOfMemory(container: "app"))
        XCTAssertEqual(KubeTrouble.of(pod: pod([waiting("ImagePullBackOff")])), .imagePull(container: "app", reason: "ImagePullBackOff"))
        XCTAssertEqual(KubeTrouble.of(pod: pod([waiting("ErrImagePull")])), .imagePull(container: "app", reason: "ErrImagePull"))
        XCTAssertEqual(
            KubeTrouble.of(pod: pod([waiting("CreateContainerConfigError")])), .configError(container: "app", reason: "CreateContainerConfigError"))
        XCTAssertEqual(KubeTrouble.of(pod: pod(phase: "Pending", [])), .pending)
        XCTAssertEqual(
            KubeTrouble.of(pod: pod([["name": "app", "state": ["terminated": ["reason": "Error", "exitCode": 2]]]])),
            .failed(container: "app", reason: "Error", exit: 2))
        XCTAssertEqual(KubeTrouble.of(pod: pod([["name": "app", "state": ["running": [:]], "ready": true]])), nil, "running is fine")
        XCTAssertEqual(
            KubeTrouble.of(pod: pod(phase: "Succeeded", [["name": "app", "state": ["terminated": ["reason": "Completed", "exitCode": 0]]]])), nil,
            "a finished pod is fine")
        XCTAssertEqual(KubeTrouble.crashLoop(container: "app", exit: 1).question("pod shop/worker-1"), "Why does pod shop/worker-1 keep crashing (CrashLoopBackOff)?")
        XCTAssertEqual(KubeTrouble.pending.question("pod shop/worker-1"), "Why is pod shop/worker-1 stuck in Pending?")
    }

    func testAStuckRolloutAndAnUnavailableDeployment() {
        func deployment(_ status: [String: Any]) -> [String: Any] {
            ["kind": "Deployment", "apiVersion": "apps/v1", "metadata": ["name": "worker", "generation": 1], "spec": ["replicas": 2], "status": status]
        }
        let stuck = deployment([
            "observedGeneration": 1, "availableReplicas": 1,
            "conditions": [["type": "Progressing", "status": "False", "reason": "ProgressDeadlineExceeded"]],
        ])
        XCTAssertEqual(KubeTrouble.of(deployment: stuck), .stuckRollout)
        XCTAssertEqual(KubeTrouble.of(object: stuck), .stuckRollout)
        XCTAssertEqual(KubeTrouble.of(deployment: deployment(["observedGeneration": 1, "availableReplicas": 1])), .unavailable(available: 1, desired: 2))
        XCTAssertNil(KubeTrouble.of(deployment: deployment(["observedGeneration": 1, "availableReplicas": 2, "updatedReplicas": 2, "replicas": 2])))
        XCTAssertEqual(
            KubeTrouble.notFailing(object: deployment(["observedGeneration": 1, "availableReplicas": 2])),
            "deploy/worker is rolled out and available: nothing to ask about.")
    }

    func testARowSaysWhetherAskWhyIsOffered() {
        let id = KubeRowID(namespace: "shop", name: "web-1")
        XCTAssertNil(KubeTrouble.notFailing(KubePodSummary(id: id, ready: 0, containers: 1, status: "CrashLoopBackOff", restarts: 4)))
        XCTAssertNil(KubeTrouble.notFailing(KubePodSummary(id: id, ready: 0, containers: 1, status: "Pending", restarts: 0)))
        XCTAssertEqual(
            KubeTrouble.notFailing(KubePodSummary(id: id, ready: 1, containers: 1, status: "Running", restarts: 0)), "pod/web-1 isn't failing: Running, 1/1 ready.")
        XCTAssertEqual(KubeTrouble.notFailing(.available, name: "web"), "deploy/web is available: nothing to ask about.")
        XCTAssertNil(KubeTrouble.notFailing(.rollingOut(updated: 0, desired: 1), name: "web"), "rolling out may be stuck: the object says")
        XCTAssertNil(KubeTrouble.notFailing(nil, name: "web"))
    }

    func testWhatAnExitCodeMeans() {
        XCTAssertTrue(KubeAgentText.exitMeaning(137, reason: "OOMKilled")?.contains("OOM killer") == true)
        let killed = KubeAgentText.exitMeaning(137, reason: "Error") ?? ""
        XCTAssertTrue(killed.contains("SIGKILL") && killed.contains("liveness probe") && !killed.contains("OOM killer:"), killed)
        XCTAssertTrue(KubeAgentText.exitMeaning(143)?.contains("SIGTERM") == true)
        XCTAssertTrue(KubeAgentText.exitMeaning(139)?.contains("segmentation fault") == true)
        XCTAssertTrue(KubeAgentText.exitMeaning(1)?.contains("general error") == true)
        XCTAssertTrue(KubeAgentText.exitMeaning(126)?.contains("couldn't be run") == true)
        XCTAssertTrue(KubeAgentText.exitMeaning(127)?.contains("wasn't found") == true)
        XCTAssertEqual(KubeAgentText.exitMeaning(134), "killed by signal 6 (SIGABRT)")
        XCTAssertNil(KubeAgentText.exitMeaning(0))
        XCTAssertNil(KubeAgentText.exitMeaning(42))
    }

    func testAContainerSaysHowItEndedAndItsEnvNamesASecretNeverItsValue() {
        let container: [String: Any] = [
            "name": "app", "image": "acme/worker:1.4.2",
            "resources": ["requests": ["cpu": "100m", "memory": "128Mi"], "limits": ["memory": "256Mi"]],
            "livenessProbe": ["httpGet": ["path": "/healthz", "port": 8080], "periodSeconds": 10],
            "command": ["redis-server", "--requirepass", "fake-requirepass"],
            "env": [
                ["name": "MODE", "value": "prod"], ["name": "DB_PASSWORD", "value": "hunter2-fake"],
                ["name": "API_KEY", "valueFrom": ["secretKeyRef": ["name": "web-db", "key": "api-key"]]],
                ["name": "NODE", "valueFrom": ["fieldRef": ["fieldPath": "spec.nodeName"]]],
            ],
            "envFrom": [["secretRef": ["name": "web-env"]], ["configMapRef": ["name": "web-config"]]],
        ]
        let status: [String: Any] = [
            "name": "app", "restartCount": 5, "state": ["waiting": ["reason": "CrashLoopBackOff", "message": "back-off 5m0s restarting failed container"]],
            "lastState": ["terminated": ["reason": "OOMKilled", "exitCode": 137, "finishedAt": "2026-11-05T10:00:00Z"]],
        ]
        let text = KubeAgentText.container(container, status: status).joined(separator: "\n")
        for said in [
            "Container app (image acme/worker:1.4.2)", "State: waiting — CrashLoopBackOff: back-off 5m0s", "Restarts: 5",
            "Last terminated: terminated — OOMKilled, exit 137", "OOM killer", "requests cpu 100m, memory 128Mi; limits memory 256Mi",
            "Liveness probe: HTTP GET :8080/healthz, every 10s", "MODE=prod", "DB_PASSWORD=••••••", "API_KEY from Secret web-db, key api-key (not read)",
            "NODE from field spec.nodeName", "every key of Secret web-env (not read)", "every key of ConfigMap web-config", "--requirepass ••••••",
        ] {
            XCTAssertTrue(text.contains(said), "\(said) in:\n\(text)")
        }
        XCTAssertFalse(text.contains("hunter2-fake"))
        XCTAssertFalse(text.contains("fake-requirepass"))
    }

    func testTheTemplateDiffShowsWhatChangedAndNotTheHash() {
        func template(_ image: String, hash: String) -> [String: Any] {
            [
                "metadata": ["labels": ["app": "worker", "pod-template-hash": hash], "creationTimestamp": NSNull()],
                "spec": ["containers": [["name": "app", "image": image, "env": [["name": "DB_PASSWORD", "value": "hunter2-fake"]]]]],
            ]
        }
        let diff = KubeAgentText.templateDiff(
            current: template("acme/worker:1.4.2", hash: "6b8f"), previous: template("acme/worker:1.4.1", hash: "5a7c"), currentName: "worker-6b8f",
            previousName: "worker-5a7c")
        XCTAssertTrue(diff.contains("- ") && diff.contains("acme/worker:1.4.1") && diff.contains("+ ") && diff.contains("acme/worker:1.4.2"), diff)
        XCTAssertTrue(diff.contains("previous ReplicaSet worker-5a7c → current worker-6b8f"), diff)
        XCTAssertFalse(diff.contains("pod-template-hash"), "the controller's own label is no change")
        XCTAssertFalse(diff.contains("hunter2-fake"), "env masked in the diff too")
        let same = KubeAgentText.templateDiff(
            current: template("a:1", hash: "x"), previous: template("a:1", hash: "y"), currentName: "worker-x", previousName: "worker-y")
        XCTAssertTrue(same.contains("is the same"), same)
        XCTAssertEqual(KubeAgentText.lineDiff(["a", "b", "c"], ["a", "B", "c"]), ["  a", "- b", "+ B", "  c"])
        let far = KubeAgentText.lineDiff((0..<20).map(String.init), (0..<20).map { $0 == 3 || $0 == 15 ? "x\($0)" : "\($0)" }, context: 1)
        XCTAssertTrue(far.contains("@@"), "hunks apart: \(far)")
        XCTAssertFalse(far.contains("  9"), "unchanged lines far from a change left out")
    }

    /// A rollout that changed only a value masked here — a rotated
    /// password, a secret flag's value — is no "same template": the value
    /// isn't shown, but that it changed is, and what it was.
    func testATemplateDiffOfOnlyAMaskedValueSaysItChanged() {
        func template(password: String, flag: String) -> [String: Any] {
            [
                "metadata": ["labels": ["app": "worker"]],
                "spec": [
                    "containers": [
                        [
                            "name": "app", "image": "acme/worker:1.4.2", "command": ["redis-server"], "args": ["--requirepass", flag, "--port", "6379"],
                            "env": [["name": "DB_PASSWORD", "value": password], ["name": "MODE", "value": "prod"]],
                        ]
                    ]
                ],
            ]
        }
        let rotated = KubeAgentText.templateDiff(
            current: template(password: "new-pw-fake", flag: "same-flag-fake"), previous: template(password: "old-pw-fake", flag: "same-flag-fake"),
            currentName: "worker-6b8f", previousName: "worker-5a7c")
        XCTAssertFalse(rotated.contains("is the same"), rotated)
        XCTAssertTrue(rotated.contains("DB_PASSWORD's value (container app)"), rotated)
        XCTAssertTrue(rotated.contains("- ") && rotated.contains("+ ") && rotated.contains("••••••\(KubeAgentText.changedMark)"), "the line marked changed:\n\(rotated)")
        for secret in ["new-pw-fake", "old-pw-fake", "same-flag-fake"] { XCTAssertFalse(rotated.contains(secret), "\(secret) in:\n\(rotated)") }

        let flag = KubeAgentText.templateDiff(
            current: template(password: "pw-fake", flag: "new-flag-fake"), previous: template(password: "pw-fake", flag: "old-flag-fake"),
            currentName: "worker-6b8f", previousName: "worker-5a7c")
        XCTAssertTrue(flag.contains("an argument of container app's command"), flag)
        XCTAssertFalse(flag.contains("DB_PASSWORD's value"), flag)
        for secret in ["new-flag-fake", "old-flag-fake", "pw-fake"] { XCTAssertFalse(flag.contains(secret), "\(secret) in:\n\(flag)") }

        let same = KubeAgentText.templateDiff(
            current: template(password: "pw-fake", flag: "f-fake"), previous: template(password: "pw-fake", flag: "f-fake"), currentName: "a", previousName: "b")
        XCTAssertTrue(same.contains("is the same"), same)
    }

    /// A template's command, args and probes' exec commands go through the
    /// argument masking the pod's own Command line does: a flag and its
    /// value are a list item each in YAML, no `=` between them.
    func testATemplatesSecretFlagsAreMaskedInTheTemplateAndTheDiff() {
        func template(_ image: String) -> [String: Any] {
            [
                "spec": [
                    "initContainers": [["name": "migrate", "image": image, "args": ["--db-password", "init-pw-fake"]]],
                    "containers": [
                        [
                            "name": "app", "image": image, "command": ["redis-server"], "args": ["--requirepass", "hunter2-fake-flag"],
                            "livenessProbe": ["exec": ["command": ["redis-cli", "-a", "probe-pw-fake", "ping"]]],
                            "lifecycle": ["preStop": ["exec": ["command": ["sh", "-c", "redis-cli -a hook-pw-fake shutdown"]]]],
                        ]
                    ],
                ]
            ]
        }
        let shown = KubeAgentText.template(template("acme/redis:7"), of: "deploy/cache") ?? ""
        let diff = KubeAgentText.templateDiff(current: template("acme/redis:8"), previous: template("acme/redis:7"), currentName: "cache-2", previousName: "cache-1")
        for text in [shown, diff] {
            for secret in ["init-pw-fake", "hunter2-fake-flag", "probe-pw-fake", "hook-pw-fake"] { XCTAssertFalse(text.contains(secret), "\(secret) in:\n\(text)") }
        }
        XCTAssertTrue(shown.contains("--requirepass") && shown.contains("redis-server") && shown.contains("ping"), shown)
        XCTAssertTrue(diff.contains("acme/redis:7") && diff.contains("acme/redis:8"), diff)
    }

    func testALogsTailIsBoundedAndKeepsNoPartOfALine() {
        let body = Data("first line secret-abc\nsecond line\nthird line cut-in-the-mid".utf8)
        XCTAssertEqual(String(decoding: KubeLogText.tail(body, keep: 1000, stopped: false), as: UTF8.self), String(decoding: body, as: UTF8.self))
        XCTAssertEqual(
            String(decoding: KubeLogText.tail(body, keep: 1000, stopped: true), as: UTF8.self), "first line secret-abc\nsecond line\n",
            "the line the server's limit cut is left out")
        XCTAssertEqual(
            String(decoding: KubeLogText.tail(body, keep: 30, stopped: false), as: UTF8.self), "third line cut-in-the-mid",
            "the line the keep cut through is left out")
        let one = Data(("x" + String(repeating: " word", count: 100)).utf8)
        let tail = String(decoding: KubeLogText.tail(one, keep: 52, stopped: false), as: UTF8.self)
        XCTAssertTrue(tail.hasPrefix("word") && tail.utf8.count <= 52, "a line longer than keep: from a word's start: \(tail)")

        let long = "start " + String(repeating: "abcdefgh ", count: 2000) + "secretvalue"
        let bounded = KubeAgentText.bounded(long)
        XCTAssertLessThanOrEqual(bounded.utf8.count, KubeAgentText.maxLineBytes + 20)
        XCTAssertTrue(bounded.hasSuffix("abcdefgh … (line cut)"), "cut at a word's end: \(bounded.suffix(30))")
        XCTAssertEqual(KubeAgentText.bounded("short"), "short")
        XCTAssertTrue(
            KubeAgentText.logs(["a"], container: "app", previous: true, stopped: true)?.text.contains("newer lines may be past it") == true)
    }

    func testPendingSaysTheSchedulerAndTheNodesAgainstTheRequests() {
        let pending: [String: Any] = [
            "spec": [
                "containers": [["name": "app", "resources": ["requests": ["cpu": "1500m", "memory": "6Gi"]]], ["name": "side", "resources": ["requests": ["cpu": "500m"]]]],
                "initContainers": [["name": "migrate", "resources": ["requests": ["cpu": "3"]]]],
                "nodeSelector": ["pool": "big"], "tolerations": [["key": "gpu", "operator": "Exists", "effect": "NoSchedule"]],
            ],
            "status": [
                "phase": "Pending",
                "conditions": [["type": "PodScheduled", "status": "False", "reason": "Unschedulable", "message": "0/2 nodes are available: 2 Insufficient memory."]],
            ],
        ]
        let nodes: [[String: Any]] = [
            [
                "metadata": ["name": "fake-node-1"], "spec": ["taints": [["key": "dedicated", "value": "db", "effect": "NoSchedule"]]],
                "status": ["allocatable": ["cpu": "3800m", "memory": "3896Mi", "pods": "110"], "conditions": [["type": "Ready", "status": "True"]]],
            ],
            ["metadata": ["name": "fake-node-2"], "spec": ["unschedulable": true], "status": ["allocatable": ["cpu": "8", "memory": "16Gi", "pods": "110"]]],
        ]
        let wanted = KubeAgentText.requests(pending)
        XCTAssertEqual(wanted.cpu, 3, "the init container's 3 beats the containers' 2")
        XCTAssertEqual(wanted.memory, 6 * 1_073_741_824)
        let text = KubeAgentText.scheduling(pending, nodes: nodes)
        for said in [
            "The scheduler: Unschedulable: 0/2 nodes are available: 2 Insufficient memory.", "It requests: cpu 3, memory 6Gi", "Node selector: pool=big",
            "Tolerations: gpu Exists NoSchedule", "fake-node-1: Ready; allocatable cpu 3800m, memory 3.8Gi, pods 110 — too little memory",
            "taints dedicated=db:NoSchedule", "fake-node-2: NotReady, cordoned (unschedulable)", "what other pods already request isn't counted",
        ] {
            XCTAssertTrue(text.contains(said), "\(said) in:\n\(text)")
        }
        XCTAssertTrue(KubeAgentText.scheduling(pending, nodes: nil, nodesProblem: "Not allowed: nodes is forbidden").contains("couldn't be read: Not allowed"))
        XCTAssertEqual(KubeQuantity.value("500m"), 0.5)
        XCTAssertEqual(KubeQuantity.value("128Mi"), 134_217_728)
        XCTAssertEqual(KubeQuantity.value("1G"), 1e9)
        XCTAssertEqual(KubeQuantity.value("2"), 2)
        XCTAssertNil(KubeQuantity.value("lots"))
    }

    func testTheBriefIsBounded() {
        let lines = (0..<2000).map { "line \($0) " + String(repeating: "x", count: 40) }
        let logs = KubeAgentText.logs(lines, container: "app", previous: true)
        XCTAssertNotNil(logs)
        XCTAssertLessThanOrEqual(logs?.text.utf8.count ?? .max, KubeAgentText.maxLogBytes + 300)
        XCTAssertTrue(logs?.text.contains("line 1999") == true, "the newest kept")
        XCTAssertTrue(logs?.text.contains("earlier lines left out") == true)
        XCTAssertTrue(logs?.text.contains("previous (terminated) instance") == true)
        let huge = KubeAgentText.logs([String(repeating: "y", count: 50_000)], container: "app", previous: false)
        XCTAssertTrue(huge?.text.contains("(line cut)") == true, "the newest alone too long is cut, not dropped")
        XCTAssertLessThanOrEqual(huge?.text.utf8.count ?? .max, KubeAgentText.maxLogBytes + 300)
        XCTAssertNil(KubeAgentText.logs([], container: "app", previous: false))

        let events = (0..<40).map { KubeEvent(id: "\($0)", type: "Warning", reason: "BackOff", message: String(repeating: "m", count: 2000)) }
        let said = KubeAgentText.events(events, about: "pod/x") ?? ""
        XCTAssertEqual(said.components(separatedBy: "\n").filter { $0.hasPrefix("Warning") }.count, KubeAgentText.maxEvents)
        XCTAssertTrue(said.contains("25 older left out"))
        XCTAssertLessThan(said.utf8.count, 10_000, "each message bounded")

        let template: [String: Any] = ["spec": ["containers": (0..<400).map { ["name": "c\($0)", "image": "acme/x:\($0)"] }]]
        let text = KubeAgentText.template(template, of: "deploy/x") ?? ""
        XCTAssertLessThanOrEqual(text.utf8.count, KubeAgentText.maxTemplateBytes + 300)
        XCTAssertTrue(text.hasSuffix("… the rest left out"))
    }

    func testTheLogTargetsAreTheFailingContainerFirstAndItsPreviousInstance() {
        let pod: [String: Any] = [
            "status": [
                "containerStatuses": [
                    ["name": "sidecar", "restartCount": 1, "state": ["running": [:]]],
                    ["name": "app", "restartCount": 4, "state": ["waiting": ["reason": "CrashLoopBackOff"]]],
                    ["name": "proxy", "restartCount": 0, "state": ["running": [:]]],
                    ["name": "pull", "restartCount": 0, "state": ["waiting": ["reason": "ImagePullBackOff"]]],
                ]
            ]
        ]
        let targets = KubeAgentText.logTargets(pod, trouble: .crashLoop(container: "app", exit: 1))
        XCTAssertEqual(targets.map(\.container), ["app", "sidecar"], "the failing one first, a container that never ran none")
        XCTAssertEqual(targets.map(\.previous), [true, true])
    }
}

/// The shared scrubbing (`Secrets`, Docker's `DockerSecrets`): every pattern
/// of a credential in text, and what is left alone.
final class SecretsScrubTests: XCTestCase {
    func testEveryCredentialPatternIsTakenOut() {
        let blob = "QWxhZGRpbjpvcGVuIHNlc2FtZTEyMzQ1Njc4OTBhYmNkZWZn"
        let text = """
            GET /api Authorization: Bearer abc.def-fake-token
            Authorization: Basic dXNlcjpwYXNzd29yZA==
            jwt eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U
            aws AKIAIOSFODNN7EXAMPLE
            token: abc123fake
            client-key-data: LS0tLS1CRUdJTiBQUklWQVRF
            client-certificate-data: LS0tLS1DRVJUSUZJQ0FURQ
            "password": "s3cr3t-fake"
            id-token: fake-id-token-value
            refresh-token=fake-refresh-value
            client-secret: fake-client-secret
            value \(blob) in a line
            url-safe \(Self.urlSafe) here
            DB_PASSWORD=hunter2fake FOO_PASSWORD=foo-pw-fake
            export API_TOKEN: xyz-api-token-fake
            X_TOKEN: x-token-fake
            CLIENT_SECRET=client-secret-fake
            user=admin pass=pass-fake-value
            gh \("ghp" + "_FakeGithubToken1234567890abcdefghij")
            pat \("github" + "_pat_11FAKE0000_fakefakefake")
            slack \("xoxb" + "-1234-5678-fakeSlackToken")
            gitlab \("glpat" + "-FakeGitlabToken12345")
            stripe \("sk" + "_live_FakeStripeKey123") and sk_test_fake_e2e_7Hq2 and \("rk" + "_live_FakeRestricted99")
            -----BEGIN EC PRIVATE KEY-----
            MHcCAQEEIFakeFakeFake
            -----END EC PRIVATE KEY-----
            """
        let scrubbed = Secrets.scrubCredentials(text)
        for secret in [
            "abc.def-fake-token", "dXNlcjpwYXNzd29yZA", "eyJhbGciOiJIUzI1NiJ9", "AKIAIOSFODNN7EXAMPLE", "abc123fake", "LS0tLS1CRUdJTiBQUklWQVRF",
            "LS0tLS1DRVJUSUZJQ0FURQ", "s3cr3t-fake", "fake-id-token-value", "fake-refresh-value", "fake-client-secret", blob, "MHcCAQEEIFakeFakeFake",
            Self.urlSafe, "hunter2fake", "foo-pw-fake", "xyz-api-token-fake", "x-token-fake", "client-secret-fake", "pass-fake-value",
            "FakeGithubToken1234567890", "fakefakefake", "fakeSlackToken", "FakeGitlabToken12345", "FakeStripeKey123", "fake_e2e_7Hq2", "FakeRestricted99",
        ] {
            XCTAssertFalse(scrubbed.contains(secret), "\(secret) taken out of:\n\(scrubbed)")
        }
        for kept in [
            "GET /api", "value ", " in a line", "-----BEGIN EC PRIVATE KEY-----", "client-key-data: ", "DB_PASSWORD=", "FOO_PASSWORD=", "X_TOKEN: ",
            "CLIENT_SECRET=", "user=admin pass=", "gh ghp_", "slack xoxb-", "gitlab glpat-", "stripe sk_live_",
        ] {
            XCTAssertTrue(scrubbed.contains(kept), "\(kept) kept in:\n\(scrubbed)")
        }
        XCTAssertEqual(Secrets.scrubCredentials("bypass=true compass: north"), "bypass=true compass: north", "a word ending in pass is no password")
    }

    /// A URL-safe base64 token (`secrets.token_urlsafe`, a Fernet key): `-`
    /// and `_` in it.
    static let urlSafe = "Ab3dEfGhIjKlMnOpQrStUvWxYz012345-_AbCdEfGhIjKlMnOpQrSt9"

    /// The patterns read one line at a time: in YAML a key on its own line
    /// is a block, and the next line's key isn't its value.
    func testYAMLBlocksUnderASecretLookingKeyAreLeftAlone() {
        let yaml = """
            volumes:
            - name: tls
              secret:
                defaultMode: 420
                secretName: web-tls
            - name: creds
              password:
                path: /etc/creds
              token:
                audience: api
            """
        XCTAssertEqual(KubeAgentBriefing.scrubber(env: [], names: [])(yaml), yaml)
        XCTAssertEqual(Secrets.scrubCredentials("token:\n  value"), "token:\n  value")
        XCTAssertEqual(Secrets.scrubCredentials("token: \tabc-fake\nnext: 1"), "token: \t\(Secrets.credentialMask)\nnext: 1")
    }

    func testWhatIsNoBlobIsLeftAlone() {
        let digest = "sha256:" + String(repeating: "3f2a9c", count: 10) + "abcd"
        let sha = "9c8fa27d1e3b4c5a6f7e8d9c0b1a2f3e4d5c6b7a"
        let uid = "4f1d7a2e-9c3b-4e8a-b1d6-7c2e9f0a3b5d"
        let path = "/var/lib/kubelet/pods/Abc123DefGhi456JklMno789PqrStu/volumes"
        let name = "kube-api-access-thisisalongbutlowercasename01234"
        let words = "TheQuickBrownFoxJumpsOverTheLazyDogAgainAndAgain"
        for kept in [digest, sha, uid, path, name, words] {
            XCTAssertEqual(Secrets.maskBase64Blobs(in: "x \(kept) y"), "x \(kept) y", kept)
        }
        XCTAssertEqual(Secrets.maskBase64Blobs(in: "short Ab1"), "short Ab1")
    }

    func testDockersScrubbingIsUnchanged() {
        // The env's secret values and a URL's password, as before; nothing else.
        let env = [(key: "DB_PASSWORD", value: "hunter2"), (key: "POSTGRES_PASSWORD", value: "postgres")]
        let text = "connect postgres://shop:pw@db/shop with hunter2 as postgres token: abc123fake"
        XCTAssertEqual(
            DockerSecrets.scrub(text, env: env, keeping: ["postgres"]), "connect postgres://shop:••••••@db/shop with •••••• as postgres token: abc123fake")
        XCTAssertEqual(DockerSecrets.masked("API_TOKEN", "x"), "••••••")
    }
}

/// The reads, against `FakeKubeAPI`: a crash-looping pod of a Deployment
/// with two revisions, a Pending pod, a stuck rollout — GETs only, never a
/// Secret, every planted secret scrubbed.
@MainActor
final class KubeAgentBriefingTests: XCTestCase {
    nonisolated(unsafe) private var api: FakeKubeAPI!
    nonisolated(unsafe) private var socket: String!

    static let password = "hunter2-fake-pw"
    static let bearer = "abcDEF.fake-bearer-token"
    static let blob = "QWxhZGRpbjpvcGVuIHNlc2FtZTEyMzQ1Njc4OTBhYmNkZWZn"
    static let secretValue = "never-read-secret-value"

    override func setUp() async throws {
        socket = "/tmp/otkb-\(UInt32.random(in: 0...UInt32.max)).sock"
        api = FakeKubeAPI(socket: socket)
        try api.start()
        api.addNamespace("shop")
        api.add("secrets", "web-db", namespace: "shop", values: ["Type": "Opaque"], data: ["api-key": Self.secretValue])
    }

    override func tearDown() async throws {
        if let api {
            XCTAssertEqual(api.writes, [], "only GETs")
            XCTAssertEqual(api.subresourceRequests.filter { !$0.isLog }, [], "no subresource but a pod's log")
            XCTAssertFalse(api.requests.contains { $0.path.contains("/secrets") }, "no Secret is ever read: \(api.requests)")
            api.stop()
        }
    }

    private var client: KubeClient { KubeClient(KubeSocketConnection(socket: socket, context: "fake-dev")) }
    private let dev = KubeBriefContext(name: "fake-dev", production: false, writable: false)

    private func template(_ image: String, hash: String? = nil) -> [String: Any] {
        var labels = ["app": "worker"]
        if let hash { labels["pod-template-hash"] = hash }
        return [
            "metadata": ["labels": labels],
            "spec": [
                "containers": [
                    [
                        "name": "app", "image": image,
                        "env": [
                            ["name": "DB_PASSWORD", "value": Self.password],
                            ["name": "API_KEY", "valueFrom": ["secretKeyRef": ["name": "web-db", "key": "api-key"]]],
                        ],
                    ]
                ]
            ],
        ]
    }

    /// Deployment worker (revision 2), its ReplicaSets worker-6b8f (2,
    /// 1.4.2) and worker-5a7c (1, 1.4.1), and `pod` of the newest.
    private func workload(pod: String, _ status: [String: Any], restarts: Int) {
        api.add(
            "deployments.apps", "worker", namespace: "shop", values: ["Ready": "0/1", "Up-to-date": 1, "Available": 0],
            annotations: ["deployment.kubernetes.io/revision": "2"],
            fields: [
                "metadata": ["generation": 2],
                "spec": ["replicas": 1, "selector": ["matchLabels": ["app": "worker"]], "template": template("acme/worker:1.4.2")],
                "status": [
                    "observedGeneration": 2, "replicas": 1, "updatedReplicas": 1, "unavailableReplicas": 1,
                    "conditions": [["type": "Progressing", "status": "False", "reason": "ProgressDeadlineExceeded", "message": "ReplicaSet \"worker-6b8f\" has timed out progressing."]],
                ],
            ])
        let deployment = api.uid("deployments.apps", "worker", namespace: "shop") ?? ""
        for (name, revision, image) in [("worker-6b8f", "2", "acme/worker:1.4.2"), ("worker-5a7c", "1", "acme/worker:1.4.1")] {
            let hash = String(name.split(separator: "-").last ?? "")
            api.add(
                "replicasets.apps", name, namespace: "shop", labels: ["app": "worker", "pod-template-hash": hash],
                annotations: ["deployment.kubernetes.io/revision": revision],
                fields: [
                    "metadata": ["ownerReferences": [["apiVersion": "apps/v1", "kind": "Deployment", "name": "worker", "uid": deployment, "controller": true]]],
                    "spec": ["replicas": revision == "2" ? 1 : 0, "selector": ["matchLabels": ["app": "worker", "pod-template-hash": hash]], "template": template(image, hash: hash)],
                    "status": ["replicas": revision == "2" ? 1 : 0],
                ])
        }
        var fake = FakeKubeAPI.Pod(status: "CrashLoopBackOff", phase: "Running", ready: 0, restarts: restarts, image: "acme/worker:1.4.2")
        fake.env = ["DB_PASSWORD": Self.password, "MODE": "prod"]
        fake.secretEnv = ["API_KEY": FakeKubeAPI.SecretKeyRef(name: "web-db", key: "api-key")]
        api.addPod(pod, namespace: "shop", fake, labels: ["app": "worker", "pod-template-hash": "6b8f"])
        let replicaSet = api.uid("replicasets.apps", "worker-6b8f", namespace: "shop") ?? ""
        api.setFields(
            "pods", pod, namespace: "shop",
            [
                "metadata": ["ownerReferences": [["apiVersion": "apps/v1", "kind": "ReplicaSet", "name": "worker-6b8f", "uid": replicaSet, "controller": true]]],
                "status": status,
            ])
    }

    private static let crashing: [String: Any] = [
        "phase": "Running", "qosClass": "Burstable",
        "conditions": [["type": "Ready", "status": "False", "reason": "ContainersNotReady", "message": "containers with unready status: [app]"]],
        "containerStatuses": [
            [
                "name": "app", "image": "acme/worker:1.4.2", "ready": false, "restartCount": 5,
                "state": ["waiting": ["reason": "CrashLoopBackOff", "message": "back-off 5m0s restarting failed container=app"]],
                "lastState": ["terminated": ["reason": "Error", "exitCode": 1, "finishedAt": "2026-11-05T10:00:00Z"]],
            ]
        ],
    ]

    func testACrashLoopsBriefHasEverySectionScrubbed() async throws {
        workload(pod: "worker-6b8f-x1", Self.crashing, restarts: 5)
        api.addEvent(about: "pods", "worker-6b8f-x1", namespace: "shop", type: "Warning", reason: "BackOff", message: "Back-off restarting failed container app", count: 12)
        api.addEvent(about: "pods", "worker-6b8f-x1", namespace: "shop", reason: "Pulled", message: "Container image \"acme/worker:1.4.2\" already present on machine")
        api.setLog("worker-6b8f-x1", namespace: "shop", ["current instance line"])
        api.setLog(
            "worker-6b8f-x1", namespace: "shop",
            [
                "starting worker 1.4.2", "connecting to postgres://worker:\(Self.password)@db:5432/shop", "Authorization: Bearer \(Self.bearer)",
                "config blob \(Self.blob)", "loaded API_KEY=\(Self.secretValue) from the env", "Error: relation \"jobs\" does not exist",
            ], previous: true)
        let ref = KubeObjectRef(context: "fake-dev", kind: .pods, namespace: "shop", name: "worker-6b8f-x1")
        let brief = try await KubeAgentBriefing.brief(ref, client: client, context: dev)

        XCTAssertEqual(brief.message, "Why does pod shop/worker-6b8f-x1 keep crashing (CrashLoopBackOff)?")
        XCTAssertEqual(brief.subject, "pod/worker-6b8f-x1 CrashLoopBackOff")
        XCTAssertFalse(brief.production)
        XCTAssertNil(brief.deployedCommit, "no checkout bound: no deployed commit")
        XCTAssertEqual(brief.context, "fake-dev")
        XCTAssertEqual(brief.namespace, "shop")
        XCTAssertFalse(brief.images.isEmpty, "what the deployed commit is read from")
        XCTAssertEqual(brief.parts.map(\.title), ["events", "previous log of app", "pod template", "template diff"])
        let text = brief.text
        for said in [
            "Kubernetes pod shop/worker-6b8f-x1, in context fake-dev (read-only for Overterm).", "CrashLoopBackOff (container app)",
            "Owned by: ReplicaSet worker-6b8f ← Deployment worker.", "Ready False (ContainersNotReady", "Restarts: 5", "Last terminated: terminated — Error, exit 1",
            "a general error", "DB_PASSWORD=••••••", "API_KEY from Secret web-db, key api-key (not read)", "MODE=prod",
            "kubectl --context fake-dev -n shop describe pod worker-6b8f-x1",
        ] {
            XCTAssertTrue(text.contains(said), "\(said) in:\n\(text)")
        }
        let part = { (title: String) in brief.parts.first { $0.title == title }?.text ?? "" }
        XCTAssertTrue(part("events").contains("Warning BackOff ×12"), part("events"))
        XCTAssertTrue(part("events").hasPrefix("Events of pod/worker-6b8f-x1, newest first:"), part("events"))
        let logs = part("previous log of app")
        XCTAssertTrue(logs.contains("relation \"jobs\" does not exist") && logs.contains("starting worker 1.4.2"), logs)
        XCTAssertFalse(logs.contains("current instance line"), "the previous instance's, not the current one's")
        XCTAssertTrue(part("pod template").contains("The pod template of Deployment worker") && part("pod template").contains("secretKeyRef"), part("pod template"))
        XCTAssertTrue(part("template diff").contains("acme/worker:1.4.1") && part("template diff").contains("acme/worker:1.4.2"), part("template diff"))

        let whole = ([text] + brief.parts.map(\.text)).joined(separator: "\n")
        for secret in [Self.password, Self.bearer, Self.blob, Self.secretValue] {
            XCTAssertFalse(whole.contains(secret), "\(secret) scrubbed")
        }
        XCTAssertTrue(whole.contains("postgres://db:5432/shop") && !whole.contains("worker:••••••@"), "the URL kept, its whole userinfo out")
        XCTAssertTrue(whole.contains("acme/worker"), "the image's name isn't taken for a secret")

        let logRequests = api.requests.filter(\.isLog)
        XCTAssertEqual(logRequests.count, 1)
        XCTAssertEqual(logRequests.first?.query["previous"], "true")
        XCTAssertEqual(logRequests.first?.query["container"], "app")
        XCTAssertEqual(logRequests.first?.query["tailLines"], "\(KubeAgentText.logLines)")
        XCTAssertEqual(logRequests.first?.query["limitBytes"], "\(KubeAgentText.logReadBytes)", "bounded in bytes too")
        XCTAssertNil(logRequests.first?.query["follow"], "read once, never followed")
        XCTAssertTrue(logs.contains("loaded API_KEY=••••••"), "a value from a Secret, never read, is caught by its name in the line: \(logs)")
    }

    /// Sixty lines can be megabytes: the read asks for at most
    /// `logReadBytes`, keeps `logKeepBytes` of its end, and the brief says
    /// when the server stopped at the limit.
    func testAHugeLogIsReadBounded() async throws {
        workload(pod: "worker-6b8f-x1", Self.crashing, restarts: 5)
        let line = "dump " + String(repeating: "{\"k\": \"v\"} ", count: 6000)
        api.setLog("worker-6b8f-x1", namespace: "shop", (0..<40).map { "\($0) " + line }, previous: true)
        let ref = KubeObjectRef(context: "fake-dev", kind: .pods, namespace: "shop", name: "worker-6b8f-x1")
        let brief = try await KubeAgentBriefing.brief(ref, client: client, context: dev)
        let logs = brief.parts.first { $0.title == "previous log of app" }?.text ?? ""
        XCTAssertLessThanOrEqual(logs.utf8.count, KubeAgentText.maxLogBytes + 400, "bounded")
        XCTAssertTrue(logs.contains("the read stopped at"), logs.prefix(300) + "…")
        XCTAssertEqual(api.requests.filter(\.isLog).first?.query["limitBytes"], "\(KubeAgentText.logReadBytes)")
    }

    /// An ownerReference may name any kind; a Secret named one is never
    /// read — the brief says so and goes on.
    func testAnOwnerThatIsASecretIsNeverRead() async throws {
        var fake = FakeKubeAPI.Pod(status: "CrashLoopBackOff", phase: "Running", ready: 0, restarts: 2)
        fake.env = ["MODE": "prod"]
        api.addPod("odd-1", namespace: "shop", fake)
        let secret = api.uid("secrets", "web-db", namespace: "shop") ?? ""
        api.setFields(
            "pods", "odd-1", namespace: "shop",
            [
                "metadata": ["ownerReferences": [["apiVersion": "v1", "kind": "Secret", "name": "web-db", "uid": secret, "controller": true]]],
                "status": Self.crashing,
            ])
        let ref = KubeObjectRef(context: "fake-dev", kind: .pods, namespace: "shop", name: "odd-1")
        let brief = try await KubeAgentBriefing.brief(ref, client: client, context: dev)
        XCTAssertTrue(brief.text.contains("its owner Secret web-db (a Secret is never read)"), brief.text)
        XCTAssertFalse(api.requests.contains { $0.path.contains("/secrets") }, "\(api.requests)")
        XCTAssertNil(KubeAgentBriefing.ownerKind(apiVersion: "v1", kind: "Secret", discovery: nil))
    }

    /// A Job's pod owned by a CronJob: the template is the Job's (the
    /// CronJob's is under `jobTemplate`), the CronJob named.
    func testACronJobsPodHasItsJobsTemplate() async throws {
        api.add(
            "cronjobs.batch", "nightly", namespace: "shop",
            fields: ["spec": ["schedule": "0 2 * * *", "jobTemplate": ["spec": ["template": template("acme/nightly:2")]]]])
        let cron = api.uid("cronjobs.batch", "nightly", namespace: "shop") ?? ""
        var jobTemplate = template("acme/nightly:2")
        var spec = jobTemplate["spec"] as? [String: Any] ?? [:]
        spec["restartPolicy"] = "Never"
        jobTemplate["spec"] = spec
        api.add(
            "jobs.batch", "nightly-29001", namespace: "shop",
            fields: [
                "metadata": ["ownerReferences": [["apiVersion": "batch/v1", "kind": "CronJob", "name": "nightly", "uid": cron, "controller": true]]],
                "spec": ["template": jobTemplate],
            ])
        let job = api.uid("jobs.batch", "nightly-29001", namespace: "shop") ?? ""
        var fake = FakeKubeAPI.Pod(status: "CrashLoopBackOff", phase: "Running", ready: 0, restarts: 2, image: "acme/nightly:2")
        fake.env = ["DB_PASSWORD": Self.password]
        api.addPod("nightly-29001-abc", namespace: "shop", fake)
        api.setFields(
            "pods", "nightly-29001-abc", namespace: "shop",
            [
                "metadata": ["ownerReferences": [["apiVersion": "batch/v1", "kind": "Job", "name": "nightly-29001", "uid": job, "controller": true]]],
                "status": Self.crashing,
            ])
        let ref = KubeObjectRef(context: "fake-dev", kind: .pods, namespace: "shop", name: "nightly-29001-abc")
        let brief = try await KubeAgentBriefing.brief(ref, client: client, context: dev)
        XCTAssertTrue(brief.text.contains("Owned by: Job nightly-29001 ← CronJob nightly."), brief.text)
        let shown = brief.parts.first { $0.title == "pod template" }?.text ?? ""
        XCTAssertTrue(shown.contains("The pod template of Job nightly-29001") && shown.contains("restartPolicy: Never"), shown)
        XCTAssertFalse(([brief.text] + brief.parts.map(\.text)).joined().contains(Self.password))
    }

    func testOnProductionItWorksTooAndSaysSo() async throws {
        workload(pod: "worker-6b8f-x1", Self.crashing, restarts: 5)
        let prod = KubeBriefContext(name: "fake-prod", production: true, writable: false)
        let ref = KubeObjectRef(context: "fake-prod", kind: .pods, namespace: "shop", name: "worker-6b8f-x1")
        let brief = try await KubeAgentBriefing.brief(ref, client: KubeClient(KubeSocketConnection(socket: socket, context: "fake-prod")), context: prod)
        XCTAssertTrue(brief.production)
        XCTAssertTrue(brief.text.contains("PRODUCTION context fake-prod (read only: change nothing there)"), brief.text)
        XCTAssertTrue(brief.text.contains("kubectl --context fake-prod -n shop describe pod"))
    }

    func testAPendingPodsBriefHasTheSchedulerAndTheNodes() async throws {
        var pod = FakeKubeAPI.Pod(status: "Pending", phase: "Pending", ready: 0)
        pod.node = ""
        api.addPod("big-0", namespace: "shop", pod)
        api.setFields(
            "pods", "big-0", namespace: "shop",
            [
                "spec": ["containers": [["name": "app", "image": "acme/big:1", "resources": ["requests": ["cpu": "2", "memory": "64Gi"]]]]],
                "status": [
                    "phase": "Pending",
                    "conditions": [["type": "PodScheduled", "status": "False", "reason": "Unschedulable", "message": "0/1 nodes are available: 1 Insufficient memory."]],
                ],
            ])
        api.add(
            "nodes", "fake-node-1", values: ["Status": "Ready"],
            fields: ["status": ["allocatable": ["cpu": "4", "memory": "15Gi", "pods": "110"], "conditions": [["type": "Ready", "status": "True"]]]])
        api.addEvent(
            about: "pods", "big-0", namespace: "shop", type: "Warning", reason: "FailedScheduling", message: "0/1 nodes are available: 1 Insufficient memory.",
            component: "default-scheduler")
        let brief = try await KubeAgentBriefing.brief(KubeObjectRef(context: "fake-dev", kind: .pods, namespace: "shop", name: "big-0"), client: client, context: dev)
        XCTAssertEqual(brief.message, "Why is pod shop/big-0 stuck in Pending?")
        let scheduling = brief.parts.first { $0.title == "scheduling" }?.text ?? ""
        for said in [
            "The scheduler: Unschedulable: 0/1 nodes are available: 1 Insufficient memory.", "It requests: cpu 2, memory 64Gi",
            "fake-node-1: Ready; allocatable cpu 4, memory 15Gi, pods 110 — too little memory",
        ] {
            XCTAssertTrue(scheduling.contains(said), "\(said) in:\n\(scheduling)")
        }
        XCTAssertTrue(brief.parts.contains { $0.title == "events" && $0.text.contains("FailedScheduling") })
        XCTAssertFalse(brief.parts.contains { $0.title.contains("log") }, "a pod that never ran has no log")
        XCTAssertTrue(api.requests.contains { $0.path == "/api/v1/nodes" && $0.query["limit"] == "50" }, "the nodes: one bounded page")
    }

    func testAStuckRolloutsBrief() async throws {
        workload(pod: "worker-6b8f-x1", Self.crashing, restarts: 5)
        api.setLog("worker-6b8f-x1", namespace: "shop", ["boom: \(Self.password) rejected"], previous: true)
        api.addEvent(about: "deployments.apps", "worker", namespace: "shop", reason: "ScalingReplicaSet", message: "Scaled up replica set worker-6b8f to 1", component: "deployment-controller")
        api.addEvent(
            about: "replicasets.apps", "worker-6b8f", namespace: "shop", type: "Warning", reason: "FailedCreate",
            message: "Error creating: pods \"worker-6b8f-y2\" is forbidden: exceeded quota: compute", component: "replicaset-controller")
        let ref = KubeObjectRef(context: "fake-dev", kind: .deployments, namespace: "shop", name: "worker")
        let brief = try await KubeAgentBriefing.brief(ref, client: client, context: dev)
        XCTAssertEqual(brief.message, "Why is the rollout of deployment shop/worker stuck (ProgressDeadlineExceeded)?")
        XCTAssertEqual(brief.subject, "deploy/worker ProgressDeadlineExceeded")
        for said in [
            "Kubernetes Deployment shop/worker", "exceeded its progress deadline", "Condition Progressing False (ProgressDeadlineExceeded)",
            "Current ReplicaSet: worker-6b8f, revision 2", "Previous ReplicaSet: worker-5a7c, revision 1", "rollout status deploy/worker",
        ] {
            XCTAssertTrue(brief.text.contains(said), "\(said) in:\n\(brief.text)")
        }
        let titles = brief.parts.map(\.title)
        XCTAssertEqual(titles, ["events", "ReplicaSet events", "pods", "pod/worker-6b8f-x1", "log of worker-6b8f-x1", "pod template", "template diff"])
        let part = { (title: String) in brief.parts.first { $0.title == title }?.text ?? "" }
        XCTAssertTrue(part("ReplicaSet events").contains("FailedCreate") && part("ReplicaSet events").contains("exceeded quota"))
        XCTAssertTrue(part("pods").contains("worker-6b8f-x1: CrashLoopBackOff"), part("pods"))
        XCTAssertTrue(part("pod/worker-6b8f-x1").contains("Last terminated: terminated — Error, exit 1"))
        XCTAssertTrue(part("log of worker-6b8f-x1").contains("boom: •••••• rejected"), part("log of worker-6b8f-x1"))
        let whole = ([brief.text] + brief.parts.map(\.text)).joined(separator: "\n")
        XCTAssertFalse(whole.contains(Self.password))
        XCTAssertTrue(
            api.requests.contains { $0.path == "/api/v1/namespaces/shop/pods" && $0.query["labelSelector"] == "app=worker,pod-template-hash=6b8f" },
            "its newest ReplicaSet's pods, by its hash")
    }

    func testAPodThatIsFineGetsNoBriefAndASecretIsNeverRead() async throws {
        api.addPod("web-1", namespace: "shop")
        do {
            _ = try await KubeAgentBriefing.brief(KubeObjectRef(context: "fake-dev", kind: .pods, namespace: "shop", name: "web-1"), client: client, context: dev)
            XCTFail("a running pod is no failure")
        } catch let problem as KubeBriefProblem {
            XCTAssertEqual(problem, .notFailing("pod/web-1 isn't failing: Running."))
        }
        api.forgetRequests()
        do {
            _ = try await KubeAgentBriefing.brief(
                KubeObjectRef(context: "fake-dev", kind: .secrets, namespace: "shop", name: "web-db"), client: client, context: dev)
            XCTFail("a Secret is never briefed")
        } catch let problem as KubeBriefProblem {
            XCTAssertEqual(problem, .unsupported("A Secret is never put in a brief."))
        }
        XCTAssertTrue(api.requests.isEmpty, "nothing asked: \(api.requests)")
    }

    func testAReadThatHangsIsLeftOutInTime() async throws {
        let started = Date()
        do {
            _ = try await KubeBriefRace<Int>.run(limit: .milliseconds(100)) {
                try await Task.sleep(for: .seconds(30))
                return 1
            }
            XCTFail("no answer in time is a timeout")
        } catch is KubeBriefTimeout {}
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        let answered = try await KubeBriefRace<Int>.run(limit: .seconds(5)) { 7 }
        XCTAssertEqual(answered, 7)
    }
}

/// The page's Ask Why against `FakeKubeAPI`: `a` on a failing pod hands
/// the brief to the window (never sent here), greyed with why on one that
/// is fine, the detail's button, a Deployment's from its object, and on
/// production too — reads only.
@MainActor
final class KubeAskWhyPageTests: XCTestCase {
    private var api: FakeKubeAPI!
    private var socket: String!

    override func setUp() async throws {
        socket = "/tmp/otka-\(UInt32.random(in: 0...UInt32.max)).sock"
        api = FakeKubeAPI(socket: socket)
        try api.start()
        api.addNamespace("shop")
        api.addPod("web-1", namespace: "shop")
        var crashing = FakeKubeAPI.Pod(status: "CrashLoopBackOff", phase: "Running", ready: 0, restarts: 3)
        crashing.env = ["API_TOKEN": "fake-token-value-123"]
        api.addPod("worker-1", namespace: "shop", crashing)
        api.setLog("worker-1", namespace: "shop", ["using fake-token-value-123", "panic: boom"], previous: true)
    }

    override func tearDown() async throws {
        if let api {
            XCTAssertEqual(api.writes, [], "only GETs")
            XCTAssertEqual(api.subresourceRequests.filter { !$0.isLog }, [], "no subresource but a pod's log")
            XCTAssertFalse(api.requests.contains { $0.path.contains("/secrets") }, "no Secret read")
            api.stop()
        }
    }

    private final class Box { var briefs: [KubeAgentBrief] = [] }

    private func page(_ name: String) async throws -> (KubernetesPageModel, Box) {
        let model = KubernetesModel(proxies: KubeProxies())
        let context = KubeContext(
            name: name, cluster: name, server: "http://127.0.0.1:1", namespace: "shop", user: "anonymous", auth: KubeAuth.none, file: nil,
            contextClass: KubeClassifier.classify(context: name, cluster: name, set: nil), settings: KubeContextSettings())
        let list = KubeContextList(contexts: [context], current: name)
        model.load = { _ in list }
        model.readConfiguration = { KubernetesModel.Configuration() }
        model.watchesSettings = false
        model.remembersSelection = false
        model.flushInterval = .milliseconds(20)
        model.statusInterval = .milliseconds(50)
        let socket = self.socket!
        model.connectOverride = { context in KubeSocketConnection(socket: socket, context: context.name) }
        model.statusOverride = { _ in .open }
        model.access.run = { _, _, _ in .yes }
        let page = KubernetesPageModel(model: model)
        let box = Box()
        var actions = KubernetesActions(run: { _ in }, settings: {}, copy: { _ in }, copySecret: { _ in })
        actions.askWhy = { brief in box.briefs.append(brief) }
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

    private func askWhy(_ page: KubernetesPageModel, _ id: String) -> ResourceVerb? {
        page.verbs(for: [id]).first { $0.title == "Ask an Agent Why…" }
    }

    func testAOnAFailingPodHandsTheBriefToTheWindow() async throws {
        let (page, box) = try await page("fake-dev")
        defer { page.model.hide() }
        XCTAssertNil(askWhy(page, "shop/worker-1")?.unavailable, "offered on a crash loop")
        XCTAssertEqual(askWhy(page, "shop/worker-1")?.key, "a")
        XCTAssertEqual(askWhy(page, "shop/web-1")?.unavailable, "pod/web-1 isn't failing: Running, 1/1 ready.", "greyed with why")
        page.selection = ["shop/worker-1"]
        XCTAssertTrue(page.press("a"))
        try await until("the brief") { box.briefs.count == 1 }
        let brief = box.briefs.first
        XCTAssertEqual(brief?.message, "Why does pod shop/worker-1 keep crashing (CrashLoopBackOff)?")
        XCTAssertTrue(brief?.parts.contains { $0.title == "previous log of app" && $0.text.contains("panic: boom") } == true)
        let whole = ([brief?.text ?? ""] + (brief?.parts.map(\.text) ?? [])).joined(separator: "\n")
        XCTAssertFalse(whole.contains("fake-token-value-123"), "the pod's own secret env value scrubbed")
        XCTAssertNil(page.askingWhy)

        page.selection = ["shop/web-1"]
        XCTAssertTrue(page.press("a"))
        XCTAssertEqual(page.commandProblem, "pod/web-1 isn't failing: Running, 1/1 ready.", "a fine pod says why")
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(box.briefs.count, 1, "and asks nothing")
    }

    func testTheDetailsButtonAndADeploymentsFromItsObject() async throws {
        api.add(
            "deployments.apps", "web", namespace: "shop", values: ["Ready": "1/1", "Up-to-date": 1, "Available": 1],
            fields: [
                "metadata": ["generation": 1], "spec": ["replicas": 1, "selector": ["matchLabels": ["app": "web"]]],
                "status": ["observedGeneration": 1, "replicas": 1, "updatedReplicas": 1, "availableReplicas": 1],
            ])
        let (page, box) = try await page("fake-dev")
        defer { page.model.hide() }
        page.selection = ["shop/worker-1"]
        page.pressed("shop/worker-1")
        try await until("the detail read") { page.detail?.object != nil }
        let button = page.detailVerbs(for: page.detail!.ref).first { $0.title == "Ask an Agent Why…" }
        XCTAssertEqual(button?.place, .button, "a button on the detail")
        XCTAssertNil(button?.unavailable)
        button?.perform()
        try await until("the brief") { box.briefs.count == 1 }

        let deployment = KubeObjectRef(context: "fake-dev", kind: .deployments, namespace: "shop", name: "web")
        page.open(deployment, from: .link)
        try await until("the deployment read") { page.detail?.object != nil }
        XCTAssertEqual(
            page.askWhyVerb(for: deployment)?.unavailable, "deploy/web is rolled out and available: nothing to ask about.", "its object says it's fine")
    }

    func testOnProductionItIsAskedToo() async throws {
        let (page, box) = try await page("fake-prod")
        defer { page.model.hide() }
        page.selection = ["shop/worker-1"]
        XCTAssertTrue(page.press("a"))
        try await until("the brief") { box.briefs.count == 1 }
        XCTAssertEqual(box.briefs.first?.production, true)
        XCTAssertTrue(box.briefs.first?.text.contains("PRODUCTION context fake-prod") == true)
    }

    // MARK: The bound checkout's deployed commit (3.2)

    func testTheBoundCheckoutsDeployedCommitIsAPartOfItsOwn() async throws {
        let repo = FileManager.default.temporaryDirectory.appendingPathComponent("kube-brief-bound-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repo) }
        func git(_ arguments: [String]) async throws -> String {
            try await Git.run(["-c", "user.email=t@overterm", "-c", "user.name=t", "-c", "commit.gpgsign=false"] + arguments, in: repo)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        _ = try await git(["init", "-q", "-b", "main"])
        try "a".write(to: repo.appendingPathComponent("a"), atomically: true, encoding: .utf8)
        _ = try await git(["add", "a"])
        _ = try await git(["commit", "-q", "-m", "a"])
        let sha = try await git(["rev-parse", "HEAD"])

        let brief = KubeAgentBrief(
            message: "Why?", subject: "pod/worker-1 CrashLoopBackOff", text: "t", parts: [.init(title: "events", text: "e")], production: false,
            context: "fake-dev", namespace: "shop", images: ["ghcr.io/acme/worker:\(sha.prefix(7))", "busybox:1.36"])
        let with = await KubeAgentBriefing.withDeployedCommit(brief, checkout: repo)
        XCTAssertEqual(with.parts.map(\.title), ["events", "deployed commit"])
        let said = try XCTUnwrap(with.deployedCommit)
        XCTAssertEqual(with.parts.last?.text, said)
        XCTAssertTrue(said.contains("deployed \(sha.prefix(7)), up to date with main (from the image's tag)"), said)
        XCTAssertEqual(with.checkout, repo.path)
        XCTAssertEqual(with.text, brief.text, "what is always sent is unchanged")

        var plain = brief
        plain.images = ["nginx:1.27"]
        let none = await KubeAgentBriefing.withDeployedCommit(plain, checkout: repo)
        XCTAssertTrue(none.deployedCommit?.contains("no commit found in the image") == true, none.deployedCommit ?? "")
        plain.images = ["ghcr.io/acme/worker:deadbee"]
        let missing = await KubeAgentBriefing.withDeployedCommit(plain, checkout: repo)
        XCTAssertTrue(missing.deployedCommit?.contains("commit deadbee is not in this checkout") == true, missing.deployedCommit ?? "")
    }
}

/// Who Ask Why's brief is offered to (3.4): several checkouts of one
/// repository bound to one namespace, the brief's own checkout first,
/// then the others bound there, the selected tab's agent, the rest.
final class KubeBriefTargetsTests: XCTestCase {
    private final class Agent {
        let name: String
        let checkout: String?
        init(_ name: String, _ checkout: String?) {
            self.name = name
            self.checkout = checkout
        }
    }

    func testTheBriefsCheckoutFirstThenTheBoundOnesThenTheSelected() {
        let a = Agent("a", "/repo/a")
        let b = Agent("b", "/repo/b")
        let other = Agent("other", "/elsewhere")
        let loose = Agent("loose", nil)
        let agents = [other, a, loose, b]
        func names(selected: Agent?, first: String?, bound: Set<String> = ["/repo/a", "/repo/b"]) -> [String] {
            KubeBriefTargets.ordered(agents, selected: selected, checkout: \.checkout, bound: bound, first: first).map(\.name)
        }
        // The selected tab's binding made the brief: its checkout's agent first.
        XCTAssertEqual(names(selected: other, first: "/repo/b"), ["b", "a", "other", "loose"])
        XCTAssertEqual(names(selected: loose, first: "/repo/a"), ["a", "b", "loose", "other"])
        // No checkout in the brief: the bound ones in the window's order, then the selected.
        XCTAssertEqual(names(selected: loose, first: nil), ["a", "b", "loose", "other"])
        // Nothing bound: the selected agent first.
        XCTAssertEqual(names(selected: loose, first: nil, bound: []), ["loose", "other", "a", "b"])
        // A selected tab that isn't an agent's is not offered.
        XCTAssertEqual(names(selected: Agent("shell", "/repo/a"), first: nil, bound: []), ["other", "a", "loose", "b"])
    }
}
