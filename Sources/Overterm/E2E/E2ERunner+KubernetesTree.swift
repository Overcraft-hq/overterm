import AppKit
import Foundation

/// Stage 3b's dependency tree check (docs/design/kubernetes/analysis.md,
/// 3.7, Section 9): a Deployment of `fake-dev`'s shop whose ReplicaSet has
/// a running pod and a crashing one, using a ConfigMap that isn't there, a
/// Secret that is (its value never read), a PVC and a ServiceAccount; a
/// Service selecting its pods with an Ingress to it, another selecting
/// nothing. `x` by the window's key path opens its Overview with the tree:
/// the owner chain down to containers, the references across — the missing
/// ConfigMap red, the Secret by name and type from the Secret list's Table
/// —, the Services and the Ingress; read once, in its namespace, no watch;
/// a node's verbs are its object's. Then Argo CD's and Flux's trees once
/// their CRDs are served: an Application's `status.resources`, a
/// Kustomization's inventory, a HelmRelease's objects by Helm's labels.
/// Reads only.
extension E2ERunner {
    func kubernetesTree(_ model: KubernetesModel, _ page: KubernetesPageModel, _ fake: FakeKubeAPI) async {
        let wasShowing = app.store.showingOverlay == .kubernetes
        if !wasShowing { app.toggleKubernetesPage(nil) }
        let secretValue = "acme-e2e-tree-pw-Z7q"
        fake.add(
            "deployments.apps", "tree-web", namespace: "shop", values: ["Ready": "1/2", "Up-to-date": 2, "Available": 1],
            labels: [KubeTree.fluxHelmName: "tree-shop", KubeTree.fluxHelmNamespace: "shop"],
            fields: [
                "spec": [
                    "replicas": 2, "selector": ["matchLabels": ["app": "tree-web"]],
                    "template": [
                        "metadata": ["labels": ["app": "tree-web"]],
                        "spec": [
                            "serviceAccountName": "tree-sa",
                            "volumes": [["name": "data", "persistentVolumeClaim": ["claimName": "tree-data"]]],
                            "containers": [
                                [
                                    "name": "app", "image": "nginx:1.27", "envFrom": [["configMapRef": ["name": "tree-env"]]],
                                    "env": [["name": "DB_PASSWORD", "valueFrom": ["secretKeyRef": ["name": "tree-db", "key": "password"]]]],
                                ]
                            ],
                        ],
                    ],
                ],
                "status": ["observedGeneration": 0, "replicas": 2, "readyReplicas": 1, "updatedReplicas": 2, "availableReplicas": 1],
            ])
        guard let deployUID = fake.uid("deployments.apps", "tree-web", namespace: "shop") else { return check("tree-web added", false) }
        fake.add(
            "replicasets.apps", "tree-web-5f6", namespace: "shop", labels: ["app": "tree-web"], annotations: ["deployment.kubernetes.io/revision": "1"],
            fields: [
                "metadata": ["ownerReferences": [["apiVersion": "apps/v1", "kind": "Deployment", "name": "tree-web", "uid": deployUID, "controller": true]]],
                "spec": ["replicas": 2], "status": ["replicas": 2, "readyReplicas": 1],
            ])
        guard let setUID = fake.uid("replicasets.apps", "tree-web-5f6", namespace: "shop") else { return check("its ReplicaSet added", false) }
        for (name, status) in [("tree-web-5f6-a", "Running"), ("tree-web-5f6-b", "CrashLoopBackOff")] {
            var pod = FakeKubeAPI.Pod(status: status)
            if status != "Running" { pod.ready = 0 }
            fake.addPod(name, namespace: "shop", pod, labels: ["app": "tree-web"])
            fake.setFields(
                "pods", name, namespace: "shop",
                ["metadata": ["ownerReferences": [["apiVersion": "apps/v1", "kind": "ReplicaSet", "name": "tree-web-5f6", "uid": setUID, "controller": true]]]])
        }
        fake.add("secrets", "tree-db", namespace: "shop", values: ["Type": "Opaque"], data: ["password": secretValue])
        fake.add("persistentvolumeclaims", "tree-data", namespace: "shop", values: ["Status": "Bound"])
        fake.add("serviceaccounts", "tree-sa", namespace: "shop")
        fake.add(
            "services", "tree-web", namespace: "shop", labels: [KubeTree.fluxHelmName: "tree-shop", KubeTree.fluxHelmNamespace: "shop"],
            fields: ["spec": ["selector": ["app": "tree-web"], "ports": [["port": 80, "protocol": "TCP"]]]])
        fake.add("services", "tree-idle", namespace: "shop", fields: ["spec": ["selector": ["app": "tree-gone"], "ports": [["port": 80, "protocol": "TCP"]]]])
        fake.add(
            "ingresses.networking.k8s.io", "tree-web", namespace: "shop",
            fields: [
                "spec": ["rules": [["host": "tree.acme.example", "http": ["paths": [["path": "/", "backend": ["service": ["name": "tree-web", "port": ["number": 80]]]]]]]]]
            ])
        // A look-alike in another namespace: not the tree's.
        fake.add("configmaps", "tree-env", namespace: "payments")

        if model.selectedName != "fake-dev" { model.select("fake-dev") }
        model.setScope(.namespace("shop"))
        page.filter = ""
        page.applySelector()
        guard await eventually(15, { model.discovery?.kind("deployments") != nil }), let deployments = model.discovery?.kind("deployments") else {
            return check("fake-dev serves Deployments", false)
        }
        page.closeDetail()
        page.showKind(deployments)
        check(
            "the Deployments of fake-dev's shop",
            await eventually(15) { model.kind.fullName == "deployments.apps" && model.rows[KubeRowID(namespace: "shop", name: "tree-web")] != nil })
        fake.forgetRequests()
        page.giveListTheKeyboard()
        page.selection = ["shop/tree-web"]
        page.detailTab = .events
        check(
            "x on a Deployment is its Overview with the tree, by the window's key path",
            await pressKubernetesKey("x", keyCode: 7) && page.detailTab == .overview && page.detail?.ref.name == "tree-web")
        guard let session = page.detail?.tree else { return check("its tree", false) }
        check("read", await eventually(15) { session.state == .loaded }, "\(session.state)")
        guard let tree = session.tree else { return check("built", false) }
        check("nothing it couldn't read", tree.notes.isEmpty, "\(tree.notes)")
        func node(_ kind: String, _ name: String, in tree: KubeTree) -> KubeTreeNode? { tree.root.all.first { $0.kind == kind && $0.name == name } }
        let set = node("ReplicaSet", "tree-web-5f6", in: tree)
        check("down the owner chain: its ReplicaSet, its pods", set?.relation == .owns && set?.children.map(\.name) == ["tree-web-5f6-a", "tree-web-5f6-b"])
        check(
            "to their containers, the crashing pod red",
            node("Pod", "tree-web-5f6-b", in: tree)?.health == .bad && node("Pod", "tree-web-5f6-a", in: tree)?.children.map(\.kind) == ["Container"],
            node("Pod", "tree-web-5f6-b", in: tree)?.status ?? "none")
        check("the missing ConfigMap red — another namespace's doesn't count", node("ConfigMap", "tree-env", in: tree)?.health == .missing)
        check(
            "the Secret by name and type, from its Table", node("Secret", "tree-db", in: tree)?.health == .good && node("Secret", "tree-db", in: tree)?.status == "Opaque")
        check("the PVC bound, the ServiceAccount there", node("PersistentVolumeClaim", "tree-data", in: tree)?.status == "Bound" && node("ServiceAccount", "tree-sa", in: tree)?.health == .good)
        let service = tree.root.children.first { $0.relation == .selects && $0.name == "tree-web" }
        check("the Service selecting its pods", service?.status == "selects 2 of its pods", service?.status ?? "none")
        check("and the Ingress routing to it", service?.children.map { "\($0.kind) \($0.name)" } == ["Ingress tree-web"])
        check("not a Service selecting others", node("Service", "tree-idle", in: tree) == nil)
        let secrets = fake.requests.filter { $0.path == "/api/v1/namespaces/shop/secrets" }
        check(
            "Secrets as the Secret list's Table, names only",
            secrets.count == 1
                && secrets.allSatisfy { $0.accept == KubeClient.tableOnlyAccept && $0.query["includeObject"] == "None" },
            "\(secrets.map { "\($0.accept) \($0.query)" })")
        check(
            "no Secret read, nor its value anywhere",
            !fake.requests.contains { $0.path.contains("/secrets/") } && !String(describing: tree).contains(secretValue))
        let treeKinds: Set<String> = ["replicasets", "pods", "configmaps", "secrets", "persistentvolumeclaims", "serviceaccounts", "services", "ingresses", "httproutes"]
        let treeReads = fake.requests.filter { treeKinds.contains(($0.path as NSString).lastPathComponent) }
        check(
            "its own namespace only, bounded, GETs",
            !treeReads.isEmpty && treeReads.allSatisfy { $0.method == "GET" && $0.path.contains("/namespaces/shop/") && $0.query["limit"] != nil },
            "\(treeReads.map { "\($0.method) \($0.path) \($0.query)" })")
        // The list's own watch and the page's CRD watch (discovery's,
        // followed again whenever the fake ends it) aren't the tree's.
        check(
            "no watch of its own",
            fake.requests.filter { $0.query["watch"] != nil }.allSatisfy {
                $0.path == "/apis/apps/v1/namespaces/shop/deployments" || $0.path == "/apis/apiextensions.k8s.io/v1/customresourcedefinitions"
            },
            "\(fake.requests.filter { $0.query["watch"] != nil }.map(\.path))")
        check("drawn", await shownText(15) { $0.contains("tree-env") } != nil)
        fake.forgetRequests()
        page.showTab(.events)
        page.showTab(.overview)
        await pause(0.5)
        check(
            "read once: the Overview again reads no tree",
            session.state == .loaded && !fake.requests.contains { treeKinds.contains(($0.path as NSString).lastPathComponent) }, "\(fake.requests.map(\.path))")

        // A node's verbs are its object's; Open is its detail.
        if let pod = node("Pod", "tree-web-5f6-b", in: tree) {
            let verbs = page.treeVerbs(for: pod)
            check("a node's verbs: Open first, Copy as kubectl last", verbs.first?.title == "Open" && verbs.last?.title == "Copy as kubectl", "\(verbs.map(\.title))")
            check("its object's own among them", verbs.contains { $0.title == "Port-forward…" }, "\(verbs.map(\.title))")
            verbs.first?.perform()
            check("Open: the pod's detail", page.detail?.ref.name == "tree-web-5f6-b" && page.detail?.ref.kind.resource == "pods")
        } else {
            check("the crashing pod's node", false)
        }

        // A Service selecting nothing is red.
        if let services = model.discovery?.kind("services") {
            page.open(KubeObjectRef(context: "fake-dev", kind: services, namespace: "shop", name: "tree-idle"), from: .list)
            page.showTab(.overview)
            check(
                "a Service selecting nothing, red",
                await eventually(15) { page.detail?.tree?.tree?.root.health == .bad && page.detail?.tree?.tree?.root.status == "selects no pod" },
                "\(String(describing: page.detail?.tree?.state))")
        }

        await kubernetesGitOpsTrees(model, page, fake)
        check("reads only", fake.writes.isEmpty, "\(fake.writes)")
        page.closeDetail()
        page.showKind(.pods)
        if !wasShowing { app.toggleKubernetesPage(nil) }
    }

    /// Argo CD's and Flux's trees, read-only, once their CRDs are served.
    private func kubernetesGitOpsTrees(_ model: KubernetesModel, _ page: KubernetesPageModel, _ fake: FakeKubeAPI) async {
        fake.addCRD(group: "argoproj.io", version: "v1alpha1", plural: "applications", kind: "Application", shortNames: ["app"])
        fake.addCRD(group: "kustomize.toolkit.fluxcd.io", version: "v1", plural: "kustomizations", kind: "Kustomization", shortNames: ["ks"])
        fake.addCRD(group: "helm.toolkit.fluxcd.io", version: "v2", plural: "helmreleases", kind: "HelmRelease", shortNames: ["hr"])
        fake.add(
            "applications.argoproj.io", "tree-shop", namespace: "shop",
            fields: [
                "spec": [
                    "destination": ["server": "https://kubernetes.default.svc", "namespace": "shop"],
                    "source": ["repoURL": "https://git.acme.example/shop.git", "path": "deploy", "targetRevision": "main"],
                ],
                "status": [
                    "sync": ["status": "OutOfSync", "revision": "0123456789abcdef"], "health": ["status": "Degraded"],
                    "resources": [
                        ["group": "apps", "version": "v1", "kind": "Deployment", "namespace": "shop", "name": "tree-web", "status": "Synced", "health": ["status": "Degraded"]],
                        ["version": "v1", "kind": "ConfigMap", "namespace": "shop", "name": "tree-env", "status": "OutOfSync", "health": ["status": "Missing"]],
                    ],
                ],
            ])
        fake.add(
            "kustomizations.kustomize.toolkit.fluxcd.io", "tree-shop", namespace: "shop",
            fields: [
                "spec": ["path": "./deploy", "prune": true, "sourceRef": ["kind": "GitRepository", "name": "acme-shop"]],
                "status": [
                    "conditions": [["type": "Ready", "status": "True", "reason": "ReconciliationSucceeded"]], "lastAppliedRevision": "main@sha1:0123456",
                    "inventory": ["entries": [["id": "shop_tree-web_apps_Deployment", "v": "v1"], ["id": "shop_tree-web__Service", "v": "v1"]]],
                ],
            ])
        // One applying to another cluster (spec.kubeConfig): its objects
        // there, same-named as this cluster's.
        fake.add(
            "kustomizations.kustomize.toolkit.fluxcd.io", "tree-remote", namespace: "shop",
            fields: [
                "spec": [
                    "path": "./deploy", "prune": true, "sourceRef": ["kind": "GitRepository", "name": "acme-shop"],
                    "kubeConfig": ["secretRef": ["name": "acme-edge-kubeconfig"]],
                ],
                "status": ["inventory": ["entries": [["id": "shop_tree-web_apps_Deployment", "v": "v1"]]]],
            ])
        fake.add(
            "helmreleases.helm.toolkit.fluxcd.io", "tree-shop", namespace: "shop",
            fields: [
                "spec": ["chart": ["spec": ["chart": "shop", "version": "1.2.x", "sourceRef": ["kind": "HelmRepository", "name": "acme"]]]],
                "status": ["conditions": [["type": "Ready", "status": "True"]], "history": [["chartName": "shop", "chartVersion": "1.2.3"]]],
            ])
        // No reconnect, no rediscover(): the CRD watch brings the kinds in.
        guard
            await eventually(
                15,
                {
                    ["applications", "kustomizations", "helmreleases"].allSatisfy { model.discovery?.kind($0) != nil }
                }), let applications = model.discovery?.kind("applications"), let kustomizations = model.discovery?.kind("kustomizations"),
            let releases = model.discovery?.kind("helmreleases")
        else {
            return check(
                "Argo CD's and Flux's CRDs served, by the CRD watch", false,
                "\(fake.watched) \(model.discoveryReads) discovery reads, \(fake.openWatches) watches open, shown \(app.store.showingOverlay == .kubernetes), \(model.discovery?.kinds.filter { !$0.group.isEmpty && !$0.group.contains("k8s.io") }.map(\.fullName) ?? [])"
            )
        }

        fake.forgetRequests()
        page.open(KubeObjectRef(context: "fake-dev", kind: applications, namespace: "shop", name: "tree-shop"), from: .list)
        page.showTab(.overview)
        check("an Application's tree", await eventually(15) { page.detail?.tree?.state == .loaded }, "\(String(describing: page.detail?.tree?.state))")
        let argo = page.detail?.tree?.tree
        check(
            "what Argo CD says it manages, with its health",
            argo?.root.children.filter { $0.relation == .manages }.map { "\($0.kind) \($0.name) \($0.health.rawValue)" } == [
                "Deployment tree-web bad", "ConfigMap tree-env missing",
            ], "\(argo?.root.children.map(\.name) ?? [])")
        check("its own sync and health", argo?.root.status == "OutOfSync · Degraded" && argo?.root.health == .bad, argo?.root.status ?? "none")
        check(
            "from its object alone", fake.requests.filter { $0.query["watch"] == nil }.map(\.path) == ["/apis/argoproj.io/v1alpha1/namespaces/shop/applications/tree-shop"],
            "\(fake.requests.map(\.path))")
        if let managed = argo?.root.children.first(where: { $0.kind == "Deployment" }) {
            check("a managed object opens", page.treeVerbs(for: managed).first?.title == "Open")
        }
        check("drawn", await shownText(15) { $0.contains("git.acme.example/shop.git") } != nil)

        page.open(KubeObjectRef(context: "fake-dev", kind: kustomizations, namespace: "shop", name: "tree-shop"), from: .list)
        page.showTab(.overview)
        check("a Kustomization's tree", await eventually(15) { page.detail?.tree?.state == .loaded })
        let flux = page.detail?.tree?.tree
        check(
            "its inventory and its source",
            flux?.root.children.map { "\($0.relation.rawValue) \($0.kind) \($0.name)" } == [
                "source GitRepository acme-shop", "manages Deployment tree-web", "manages Service tree-web",
            ], "\(flux?.root.children.map(\.name) ?? [])")

        page.open(KubeObjectRef(context: "fake-dev", kind: kustomizations, namespace: "shop", name: "tree-remote"), from: .list)
        page.showTab(.overview)
        check("a Kustomization deploying elsewhere: its tree", await eventually(15) { page.detail?.tree?.state == .loaded && page.detail?.ref.name == "tree-remote" })
        let remote = page.detail?.tree?.tree
        let elsewhere = remote?.root.children.filter { $0.relation == .manages } ?? []
        check(
            "its objects listed as Flux says, not opened here — a verb would reach this cluster's tree-web",
            elsewhere.map(\.name) == ["tree-web"] && elsewhere.allSatisfy { $0.link == nil && page.treeVerbs(for: $0).isEmpty },
            "\(elsewhere.map { "\($0.name) \(String(describing: $0.link))" })")
        check(
            "and said", remote?.notes.contains { $0.contains("another cluster through spec.kubeConfig.secretRef acme-edge-kubeconfig") } == true,
            "\(remote?.notes ?? [])")

        fake.forgetRequests()
        page.open(KubeObjectRef(context: "fake-dev", kind: releases, namespace: "shop", name: "tree-shop"), from: .list)
        page.showTab(.overview)
        check("a HelmRelease's tree", await eventually(15) { page.detail?.tree?.state == .loaded })
        let release = page.detail?.tree?.tree
        check(
            "the objects Helm's controller labelled",
            release?.root.children.filter { $0.relation == .manages }.map { "\($0.kind) \($0.name)" } == ["Deployment tree-web", "Service tree-web"],
            "\(release?.root.children.map(\.name) ?? [])")
        check(
            "asked by Helm's labels",
            fake.requests.filter { $0.path.hasSuffix("/deployments") && $0.query["watch"] == nil }.allSatisfy {
                $0.query["labelSelector"] == "\(KubeTree.fluxHelmName)=tree-shop,\(KubeTree.fluxHelmNamespace)=shop"
            })
        check("drawn", await shownText(15) { $0.contains("HelmRepository") } != nil)
    }
}
