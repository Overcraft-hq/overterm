import Foundation

/// Argo CD and Flux on the fake (docs/design/kubernetes/gitops.md, 8.3):
/// their CRDs with the printer columns the pinned CRDs declare
/// (`Tests/OvertermTests/Fixtures/gitops-crds`, checked against these by
/// `KubeGitOpsCRDTests`), their controllers, and the objects every state
/// of the ladder is drawn from. The fake evaluates no JSONPath, so each
/// helper sets an object's body and its cells together, and a change is
/// one MODIFIED (`modify`). Every name is fictional; the sentinel sits in
/// every place a value can hide.
extension FakeKubeAPI {
    /// What must never come out of a summary, a row, a brief or an answer.
    static let gitOpsSentinel = "s3cr3t-sentinel"

    /// The fixtures' commits (fictional).
    enum GitOpsCommit {
        /// What is applied: Argo CD's live, Flux's artifact and applied.
        static let applied = "a77b0d1e2f3a4b5c6d7e8f9a0b1c2d3e4f5a6b7c"
        /// What Flux tried and failed.
        static let attempted = "c03f9aa1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7"
        /// What Argo CD's git has now.
        static let target = "77e1a02b3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f"
        /// An older revision.
        static let older = "5d0c1e2f3a4b5c6d7e8f9a0b1c2d3e4f5a6b7c8d"
    }

    /// The pinned CRDs' printer columns, by full name.
    static let gitOpsColumns: [String: [Column]] = {
        func c(_ name: String, _ type: String = "string", priority: Int = 0) -> Column { Column(name: name, type: type, priority: priority) }
        let flux = [c("Age", "date"), c("Ready"), c("Status")]
        return [
            "applications.argoproj.io": [c("Sync Status"), c("Health Status"), c("Revision", priority: 10), c("Project", priority: 10)],
            "applicationsets.argoproj.io": [],
            "kustomizations.kustomize.toolkit.fluxcd.io": flux,
            "helmreleases.helm.toolkit.fluxcd.io": flux,
            "gitrepositories.source.toolkit.fluxcd.io": [c("URL")] + flux,
            "helmrepositories.source.toolkit.fluxcd.io": [c("URL")] + flux,
            "ocirepositories.source.toolkit.fluxcd.io": [c("URL"), c("Ready"), c("Status"), c("Age", "date")],
            "helmcharts.source.toolkit.fluxcd.io": [c("Chart"), c("Version"), c("Source Kind"), c("Source Name")] + flux,
            "buckets.source.toolkit.fluxcd.io": [c("Endpoint")] + flux,
        ]
    }()

    private func serveCRD(_ group: String, _ version: String, _ plural: String, _ kind: String, shortNames: [String]) {
        let fullName = "\(plural).\(group)"
        // Served already (an earlier scenario's, with no columns): the pinned CRD's columns.
        if let served = servedKinds.first(where: { $0.fullName == fullName }) {
            if (served.columns ?? []).isEmpty { setColumns(fullName, Self.gitOpsColumns[fullName] ?? []) }
            return
        }
        addCRD(group: group, version: version, plural: plural, kind: kind, shortNames: shortNames, columns: Self.gitOpsColumns[fullName] ?? [])
    }

    /// Argo CD: Applications and ApplicationSets, its server, repo server
    /// and application controller in `argocd`. No ConfigMap.
    func serveArgoCD() {
        addNamespace("argocd")
        serveCRD("argoproj.io", "v1alpha1", "applications", "Application", shortNames: ["app", "apps"])
        serveCRD("argoproj.io", "v1alpha1", "applicationsets", "ApplicationSet", shortNames: ["appset", "appsets"])
        addController("argocd-server", namespace: "argocd")
        addController("argocd-repo-server", namespace: "argocd")
        addController("argocd-application-controller", namespace: "argocd", statefulSet: true)
    }

    /// Flux: its kinds and its three controllers in `flux-system`.
    func serveFlux() {
        addNamespace("flux-system")
        serveCRD("kustomize.toolkit.fluxcd.io", "v1", "kustomizations", "Kustomization", shortNames: ["ks"])
        serveCRD("helm.toolkit.fluxcd.io", "v2", "helmreleases", "HelmRelease", shortNames: ["hr"])
        serveCRD("source.toolkit.fluxcd.io", "v1", "gitrepositories", "GitRepository", shortNames: ["gitrepo"])
        serveCRD("source.toolkit.fluxcd.io", "v1", "ocirepositories", "OCIRepository", shortNames: ["ocirepo"])
        serveCRD("source.toolkit.fluxcd.io", "v1", "helmrepositories", "HelmRepository", shortNames: ["helmrepo"])
        serveCRD("source.toolkit.fluxcd.io", "v1", "helmcharts", "HelmChart", shortNames: ["hc"])
        serveCRD("source.toolkit.fluxcd.io", "v1", "buckets", "Bucket", shortNames: [])
        for name in ["source-controller", "kustomize-controller", "helm-controller"] { addController(name, namespace: "flux-system") }
    }

    private func addController(_ name: String, namespace: String, statefulSet: Bool = false) {
        add(
            statefulSet ? "statefulsets.apps" : "deployments.apps", name, namespace: namespace,
            values: statefulSet ? ["Ready": "1/1"] : ["Ready": "1/1", "Up-to-date": 1, "Available": 1],
            labels: ["app.kubernetes.io/name": name],
            fields: ["spec": ["replicas": 1], "status": ["replicas": 1, "readyReplicas": 1, "availableReplicas": 1]])
    }

    /// A controller ready or not (`0/1`): its banner's cause.
    func setControllerReady(_ name: String, _ ready: Bool) {
        let namespace = name.hasPrefix("argocd") ? "argocd" : "flux-system"
        let resource = name == "argocd-application-controller" ? "statefulsets.apps" : "deployments.apps"
        let count = ready ? 1 : 0
        var values: [String: Value] = ["Ready": .text("\(count)/1")]
        if resource == "deployments.apps" { values["Available"] = .integer(count) }
        modify(resource, name, namespace: namespace, values: values) { body in
            body["status"] = ["replicas": 1, "readyReplicas": count, "availableReplicas": count]
        }
    }

    // MARK: Objects

    /// An Argo CD Application, its cells from its status.
    func addApplication(_ name: String, namespace: String = "argocd", spec: [String: Any], status: [String: Any], metadata: [String: Any] = [:]) {
        var fields: [String: Any] = ["spec": spec, "status": status]
        if !metadata.isEmpty { fields["metadata"] = metadata }
        add("applications.argoproj.io", name, namespace: namespace, values: Self.argoCells(spec: spec, status: status), fields: fields)
    }

    /// A Flux object (any of its kinds), its cells from its Ready condition.
    func addFlux(
        _ resource: String, _ name: String, namespace: String = "flux-system", spec: [String: Any], status: [String: Any],
        metadata: [String: Any] = [:], managedFields: [[String: Any]]? = nil
    ) {
        var fields: [String: Any] = ["spec": spec, "status": status]
        if !metadata.isEmpty { fields["metadata"] = metadata }
        var values = Self.fluxCells(status: status)
        if let url = spec["url"] as? String { values["URL"] = .text(url) }
        add(resource, name, namespace: namespace, values: values, fields: fields)
        if let managedFields { setManagedFields(resource, name, namespace: namespace, managedFields) }
    }

    /// An Application's status changed, its cells with it: one MODIFIED.
    func setArgoState(_ name: String, namespace: String = "argocd", _ change: @escaping (inout [String: Any]) -> Void) {
        let current = object("applications.argoproj.io", name, namespace: namespace) ?? [:]
        var status = current["status"] as? [String: Any] ?? [:]
        change(&status)
        let cells = Self.argoCells(spec: current["spec"] as? [String: Any] ?? [:], status: status)
        modify("applications.argoproj.io", name, namespace: namespace, values: cells) { body in body["status"] = status }
    }

    /// A Flux object's Ready condition set, its cells with it: one MODIFIED.
    func setFluxReady(_ resource: String, _ name: String, namespace: String = "flux-system", _ ready: String, reason: String, message: String) {
        let current = object(resource, name, namespace: namespace) ?? [:]
        var status = current["status"] as? [String: Any] ?? [:]
        var conditions = (status["conditions"] as? [[String: Any]] ?? []).filter { $0["type"] as? String != "Ready" }
        conditions.insert(Self.condition("Ready", ready, reason, message, since: Date()), at: 0)
        status["conditions"] = conditions
        modify(resource, name, namespace: namespace, values: Self.fluxCells(status: status)) { body in body["status"] = status }
    }

    static func argoCells(spec: [String: Any], status: [String: Any]) -> [String: Value] {
        let sync = status["sync"] as? [String: Any]
        return [
            "Sync Status": .text(sync?["status"] as? String ?? ""), "Health Status": .text((status["health"] as? [String: Any])?["status"] as? String ?? ""),
            "Revision": .text(sync?["revision"] as? String ?? ""), "Project": .text(spec["project"] as? String ?? "default"),
        ]
    }

    static func fluxCells(status: [String: Any]) -> [String: Value] {
        let ready = (status["conditions"] as? [[String: Any]] ?? []).first { $0["type"] as? String == "Ready" }
        return ["Ready": .text(ready?["status"] as? String ?? "Unknown"), "Status": .text(ready?["message"] as? String ?? "")]
    }

    static func condition(_ type: String, _ status: String, _ reason: String, _ message: String = "", since: Date) -> [String: Any] {
        ["type": type, "status": status, "reason": reason, "message": message, "lastTransitionTime": time(since)]
    }

    /// Every object of §8.3, Argo CD's and Flux's both served first: one
    /// for each rung of the ladder, the sentinel in every carrier, a URL's
    /// token in a source and a message.
    func addGitOpsFixtures(now: Date = Date()) {
        serveArgoCD()
        serveFlux()
        for namespace in ["shop", "team-a"] { addNamespace(namespace) }
        let s = Self.gitOpsSentinel
        let c = GitOpsCommit.self
        func ago(_ seconds: TimeInterval) -> String { Self.time(now.addingTimeInterval(-seconds)) }
        let inCluster = "https://kubernetes.default.svc"
        let valuesSource: [String: Any] = [
            "repoURL": "https://git.acme.example/acme/shop.git", "path": "deploy/fake-prod", "targetRevision": "main",
            "helm": [
                "values": "password: \(s)", "valuesObject": ["password": s], "parameters": [["name": "pw", "value": s]],
                "fileParameters": [["name": s, "path": s]],
            ],
            "directory": ["jsonnet": ["extVars": [["name": "pw", "value": s]], "tlas": [["name": "pw", "value": s]]]],
            "plugin": ["env": [["name": "PW", "value": s]]],
            "kustomize": ["patches": [["patch": "value: \(s)"]]],
        ]
        let auto: [String: Any] = ["automated": ["prune": true, "selfHeal": true]]

        // Argo CD
        addApplication(
            "acme-shop-prod",
            spec: ["project": "acme", "source": valuesSource, "destination": ["server": inCluster, "namespace": "shop"], "syncPolicy": auto],
            status: [
                "sync": ["status": "Synced", "revision": c.applied, "comparedTo": ["source": valuesSource]], "health": ["status": "Healthy"],
                "history": [
                    ["revision": c.older, "deployedAt": ago(86_400), "source": valuesSource],
                    ["revision": c.applied, "deployedAt": ago(3600), "source": valuesSource],
                ],
                "operationState": [
                    "phase": "Succeeded", "startedAt": ago(3660), "finishedAt": ago(3600),
                    "operation": ["sync": ["source": valuesSource, "manifests": ["kind: Secret\nstringData:\n  pw: \(s)"]]],
                    "syncResult": ["revision": c.applied, "source": valuesSource],
                ],
                "resources": [["group": "apps", "version": "v1", "kind": "Deployment", "namespace": "shop", "name": "shop-api", "status": "Synced"]],
                "summary": ["images": ["registry.acme.example/shop-api:\(c.applied.prefix(7))"]],
                "reconciledAt": ago(60),
            ],
            metadata: ["annotations": ["kubectl.kubernetes.io/last-applied-configuration": "{\"pw\":\"\(s)\"}"]])
        addApplication(
            "acme-api", namespace: "team-a",
            spec: [
                "sources": [
                    ["repoURL": "oci://ghcr.io/acme/charts", "chart": "api", "targetRevision": "1.5.0", "helm": ["valuesObject": ["pw": s]]],
                    ["repoURL": "git@git.acme.example:acme/shop", "targetRevision": "main", "ref": "values"],
                ],
                "destination": ["server": inCluster, "namespace": "shop"], "syncPolicy": auto,
            ],
            status: [
                "sync": ["status": "OutOfSync", "revision": "", "revisions": ["1.5.0", c.target]], "health": ["status": "Degraded"],
                "resourceHealthSource": "appTree",
                "operationState": [
                    "phase": "Failed", "startedAt": ago(800), "finishedAt": ago(720),
                    "message":
                        "one or more objects failed to apply, reason: fetching https://bot:ghp_fake@git.acme.example/acme/shop.git failed:\n  apiVersion: v1\n  kind: Secret\n  data:\n    pw: \(s)",
                    "syncResult": ["revisions": ["1.5.0", c.target], "sources": [["repoURL": "oci://ghcr.io/acme/charts", "helm": ["values": s]]]],
                ],
                "resources": [["group": "apps", "version": "v1", "kind": "Deployment", "namespace": "shop", "name": "api", "status": "OutOfSync"]],
            ])
        addApplication(
            "acme-web",
            spec: [
                "source": ["repoURL": "https://git.acme.example/acme/fleet.git", "path": "apps/web", "targetRevision": "main"],
                "destination": ["server": inCluster, "namespace": "shop"], "syncPolicy": auto,
            ],
            status: [
                "sync": ["status": "OutOfSync", "revision": c.target], "health": ["status": "Healthy"],
                "history": [["revision": c.older, "deployedAt": ago(7200)]],
                "operationState": [
                    "phase": "Failed", "startedAt": ago(780), "finishedAt": ago(720), "message": "one or more synchronization tasks completed unsuccessfully",
                    "syncResult": [
                        "revision": c.target,
                        "resources": [
                            ["kind": "Deployment", "name": "acme-web", "namespace": "shop", "status": "SyncFailed", "message": "admission webhook denied the request"]
                        ],
                    ],
                ],
            ])
        addApplication(
            "acme-new",
            spec: [
                "source": ["repoURL": "https://git.acme.example/acme/fleet.git", "path": "apps/new", "targetRevision": "main"],
                "destination": ["server": inCluster, "namespace": "shop"], "syncPolicy": auto,
            ],
            status: [
                "sync": ["status": "OutOfSync", "revision": c.target], "health": ["status": "Missing"],
                "operationState": ["phase": "Running", "startedAt": ago(40), "syncResult": ["revision": c.target]],
            ])
        addApplication(
            "globex-batch",
            spec: [
                "source": ["repoURL": "https://git.globex.example/globex/ops.git", "path": "batch", "targetRevision": "v1.4"],
                "destination": ["server": inCluster, "namespace": "shop"], "syncPolicy": auto,
            ],
            status: [
                "sync": ["status": "OutOfSync", "revision": c.target], "health": ["status": "Healthy"],
                "operationState": ["phase": "Running", "startedAt": ago(26 * 60), "message": "waiting for completion of hook batch/Job/migrate"],
            ])
        addApplication(
            "acme-admin",
            spec: [
                "source": ["repoURL": "https://git.acme.example/acme/fleet.git", "path": "apps/admin", "targetRevision": "main"],
                "destination": ["server": inCluster, "namespace": "shop"],
            ],
            status: [
                "sync": ["status": "OutOfSync", "revision": c.target], "health": ["status": "Healthy"],
                "history": [["revision": c.older, "deployedAt": ago(3600)]],
            ])
        addApplication(
            "acme-old-fail",
            spec: [
                "source": ["repoURL": "https://git.acme.example/acme/fleet.git", "path": "apps/old", "targetRevision": "main"],
                "destination": ["server": inCluster, "namespace": "shop"], "syncPolicy": auto,
            ],
            status: [
                "sync": ["status": "Synced", "revision": c.applied], "health": ["status": "Healthy"],
                "history": [["revision": c.applied, "deployedAt": ago(86_400)]],
                "operationState": ["phase": "Failed", "startedAt": ago(2 * 86_400), "finishedAt": ago(2 * 86_400), "syncResult": ["revision": c.older]],
            ])
        addApplication(
            "acme-remote",
            spec: [
                "source": ["repoURL": "https://git.acme.example/acme/fleet.git", "path": "apps/remote", "targetRevision": "main"],
                "destination": ["server": "https://fake-prod.example:6443", "namespace": "shop"], "syncPolicy": auto,
            ],
            status: ["sync": ["status": "Synced", "revision": c.applied], "health": ["status": "Healthy"]])
        add(
            "applicationsets.argoproj.io", "acme-envs", namespace: "argocd",
            fields: [
                "spec": [
                    "generators": [["list": ["elements": [["env": "dev", "pw": s], ["env": "prod"]]]]],
                    "template": ["spec": ["source": valuesSource]],
                ],
                "status": ["conditions": [Self.condition("ResourcesUpToDate", "True", "ApplicationSetUpToDate", since: now.addingTimeInterval(-600))]],
            ])
        let setUID = uid("applicationsets.argoproj.io", "acme-envs", namespace: "argocd") ?? ""
        for env in ["dev", "prod"] {
            addApplication(
                "acme-envs-\(env)",
                spec: [
                    "source": ["repoURL": "https://git.acme.example/acme/fleet.git", "path": "envs/\(env)", "targetRevision": "main"],
                    "destination": ["server": inCluster, "namespace": "envs-\(env)"], "syncPolicy": auto,
                ],
                status: ["sync": ["status": "Synced", "revision": c.applied], "health": ["status": "Healthy"]],
                metadata: [
                    "ownerReferences": [
                        ["apiVersion": "argoproj.io/v1alpha1", "kind": "ApplicationSet", "name": "acme-envs", "uid": setUID, "controller": true]
                    ]
                ])
        }
        add(
            "applicationsets.argoproj.io", "globex-broken-set", namespace: "argocd",
            fields: [
                "spec": ["generators": [["git": ["repoURL": "https://git.globex.example/globex/ops.git"]]]],
                "status": [
                    "conditions": [
                        Self.condition("ErrorOccurred", "True", "ApplicationGenerationFromParamsError", "failed to get params for generator: repo not found", since: now.addingTimeInterval(-300))
                    ]
                ],
            ])

        // Flux: sources
        let fleetURL = "https://user:ghp_fake@git.acme.example/acme/shop.git"
        addFlux(
            "gitrepositories.source.toolkit.fluxcd.io", "acme-fleet", spec: ["url": fleetURL, "interval": "1m", "ref": ["branch": "main"]],
            status: [
                "observedGeneration": 1,
                "conditions": [Self.condition("Ready", "True", "Succeeded", "stored artifact for revision 'main@sha1:\(c.applied)'", since: now.addingTimeInterval(-3600))],
                "artifact": ["revision": "main@sha1:\(c.applied)", "lastUpdateTime": ago(3600)],
            ],
            metadata: ["generation": 1])
        addFlux(
            "gitrepositories.source.toolkit.fluxcd.io", "acme-broken",
            spec: ["url": "https://git.acme.example/acme/broken.git", "interval": "1m", "ref": ["branch": "main"]],
            status: [
                "conditions": [
                    Self.condition(
                        "Ready", "False", "AuthenticationFailed",
                        "failed to checkout and determine revision: unable to clone 'https://bot:ghp_fake@git.acme.example/acme/broken.git': authentication required",
                        since: now.addingTimeInterval(-1800))
                ]
            ])
        addFlux(
            "ocirepositories.source.toolkit.fluxcd.io", "acme-manifests", spec: ["url": "oci://ghcr.io/acme/manifests", "interval": "5m", "ref": ["tag": "latest"]],
            status: [
                "conditions": [Self.condition("Ready", "True", "Succeeded", "stored artifact", since: now.addingTimeInterval(-600))],
                "artifact": [
                    "revision": "latest@sha256:\(String(repeating: "1f2e3d4c", count: 8))", "lastUpdateTime": ago(600),
                    "metadata": [
                        "org.opencontainers.image.source": "https://git.acme.example/acme/shop", "org.opencontainers.image.revision": "main@sha1:\(c.applied)",
                    ],
                ],
            ])
        addFlux(
            "ocirepositories.source.toolkit.fluxcd.io", "globex-charts", spec: ["url": "oci://ghcr.io/globex/charts/redis", "interval": "10m"],
            status: [
                "conditions": [Self.condition("Ready", "True", "Succeeded", "stored artifact", since: now.addingTimeInterval(-600))],
                "artifact": ["revision": "18.2.0@sha256:\(String(repeating: "9a8b7c6d", count: 8))", "lastUpdateTime": ago(600)],
            ])
        addFlux(
            "helmrepositories.source.toolkit.fluxcd.io", "acme-charts", spec: ["url": "https://charts.acme.example", "interval": "10m"],
            status: ["conditions": [Self.condition("Ready", "True", "Succeeded", "stored artifact", since: now.addingTimeInterval(-600))]])
        addFlux(
            "helmcharts.source.toolkit.fluxcd.io", "flux-system-acme-payments",
            spec: ["chart": "payments", "version": "1.5.0", "sourceRef": ["kind": "HelmRepository", "name": "acme-charts"], "interval": "10m"],
            status: [
                "conditions": [Self.condition("Ready", "True", "ChartPullSucceeded", "pulled 'payments' chart with version '1.5.0'", since: now.addingTimeInterval(-600))],
                "artifact": ["revision": "1.5.0", "lastUpdateTime": ago(600)],
            ])

        // Flux: Kustomizations
        func kustomization(_ name: String, source: String = "acme-fleet", path: String, spec extra: [String: Any] = [:], status: [String: Any]) {
            var spec: [String: Any] = ["interval": "10m", "path": path, "prune": true, "sourceRef": ["kind": "GitRepository", "name": source]]
            spec.merge(extra) { $1 }
            addFlux(
                "kustomizations.kustomize.toolkit.fluxcd.io", name, spec: spec, status: status.merging(["observedGeneration": 1]) { a, _ in a },
                metadata: ["generation": 1])
        }
        kustomization(
            "acme-apps", path: "./deploy/fake-dev",
            spec: ["patches": [["patch": "value: \(s)"]], "postBuild": ["substitute": ["PW": s]]],
            status: [
                "conditions": [Self.condition("Ready", "True", "ReconciliationSucceeded", "Applied revision: main@sha1:\(c.applied)", since: now.addingTimeInterval(-3600))],
                "lastAppliedRevision": "main@sha1:\(c.applied)", "lastAttemptedRevision": "main@sha1:\(c.applied)",
                "inventory": ["entries": [["id": "shop_shop-api_apps_Deployment", "v": "v1"], ["id": "shop_shop-api__Service", "v": "v1"]]],
            ])
        kustomization(
            "acme-cron", path: "./apps/cron", spec: ["targetNamespace": "shop"],
            status: [
                "conditions": [
                    Self.condition(
                        "Ready", "False", "BuildFailed", "kustomize build failed: accumulating resources:\n---\napiVersion: v1\nkind: Secret\nstringData:\n  pw: \(s)",
                        since: now.addingTimeInterval(-480))
                ],
                "lastAppliedRevision": "main@sha1:\(c.applied)", "lastAttemptedRevision": "main@sha1:\(c.attempted)",
            ])
        kustomization(
            "acme-infra", path: "./infra", spec: ["targetNamespace": "shop"],
            status: [
                "conditions": [Self.condition("Ready", "False", "HealthCheckFailed", "health check failed after 5m: Deployment/shop/acme-db not ready", since: now.addingTimeInterval(-600))],
                "lastAppliedRevision": "main@sha1:\(c.applied)", "lastAttemptedRevision": "main@sha1:\(c.applied)",
            ])
        kustomization(
            "acme-web", path: "./apps/web", spec: ["targetNamespace": "shop", "dependsOn": [["name": "acme-infra"]]],
            status: [
                "conditions": [Self.condition("Ready", "False", "DependencyNotReady", "dependency 'flux-system/acme-infra' is not ready", since: now.addingTimeInterval(-120))]
            ])
        kustomization(
            "acme-api", source: "acme-broken", path: "./apps/api", spec: ["targetNamespace": "shop"],
            status: [
                "conditions": [Self.condition("Ready", "False", "ArtifactFailed", "Source artifact not found, retrying in 30s", since: now.addingTimeInterval(-120))]
            ])
        addFlux(
            "kustomizations.kustomize.toolkit.fluxcd.io", "acme-jobs",
            spec: ["interval": "10m", "path": "./apps/jobs", "prune": true, "suspend": true, "targetNamespace": "shop", "sourceRef": ["kind": "GitRepository", "name": "acme-fleet"]],
            status: [
                "observedGeneration": 2,
                "conditions": [Self.condition("Ready", "False", "HealthCheckFailed", "health check failed", since: now.addingTimeInterval(-13 * 86_400))],
                "lastAppliedRevision": "main@sha1:\(c.older)",
            ],
            metadata: ["generation": 2],
            managedFields: [
                [
                    "manager": "kustomize-controller", "operation": "Update", "time": ago(13 * 86_400), "fieldsType": "FieldsV1",
                    "fieldsV1": ["f:status": ["f:conditions": [String: Any]()]],
                ],
                [
                    "manager": "overterm", "operation": "Update", "time": ago(12 * 86_400), "fieldsType": "FieldsV1",
                    "fieldsV1": ["f:spec": ["f:suspend": [String: Any]()]],
                ],
            ])
        kustomization(
            "globex-remote", path: "./edge", spec: ["targetNamespace": "shop", "kubeConfig": ["secretRef": ["name": "globex-edge-kubeconfig"]]],
            status: [
                "conditions": [Self.condition("Ready", "True", "ReconciliationSucceeded", "Applied revision: main@sha1:\(c.applied)", since: now.addingTimeInterval(-600))],
                "lastAppliedRevision": "main@sha1:\(c.applied)", "lastAttemptedRevision": "main@sha1:\(c.applied)",
            ])

        // Flux: HelmReleases
        addFlux(
            "helmreleases.helm.toolkit.fluxcd.io", "globex-redis",
            spec: ["interval": "10m", "targetNamespace": "shop", "chartRef": ["kind": "OCIRepository", "name": "globex-charts"], "values": ["auth": ["password": s]]],
            status: [
                "conditions": [
                    Self.condition("Ready", "False", "InstallFailed", "Helm install failed for release shop/globex-redis: context deadline exceeded", since: now.addingTimeInterval(-900)),
                    Self.condition("Stalled", "True", "RetriesExceeded", "Failed to install after 3 attempt(s)", since: now.addingTimeInterval(-900)),
                ],
                "lastAttemptedRevision": "18.2.0",
            ])
        addFlux(
            "helmreleases.helm.toolkit.fluxcd.io", "acme-payments",
            spec: [
                "interval": "10m", "targetNamespace": "shop", "valuesFrom": [["kind": "Secret", "name": "acme-payments-values"]],
                "chart": ["spec": ["chart": "payments", "version": "1.5.0", "sourceRef": ["kind": "HelmRepository", "name": "acme-charts"]]],
                "values": ["pw": s],
            ],
            status: [
                "conditions": [
                    Self.condition(
                        "Ready", "False", "RollbackSucceeded", "Helm rollback to previous release shop/acme-payments.v4 with chart payments@1.4.2 succeeded",
                        since: now.addingTimeInterval(-240))
                ],
                "lastAttemptedRevision": "1.5.0",
                "history": [
                    ["chartName": "payments", "chartVersion": "1.4.2", "status": "deployed", "version": 6],
                    ["chartName": "payments", "chartVersion": "1.5.0", "status": "failed", "version": 5],
                    ["chartName": "payments", "chartVersion": "1.4.2", "status": "superseded", "version": 4],
                ],
            ])
    }
}
