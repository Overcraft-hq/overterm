import AppKit
import Foundation

/// Stage 2c's check (docs/design/kubernetes/analysis.md, Section 9): Helm's
/// releases read from the fake's own records — a Secret-stored release
/// with two revisions and a ConfigMap-stored one, in Helm's real encoding —
/// on `fake-dev`, read-only, through its proxy. `8` (the window's key)
/// shows the section; the list asks for the records' metadata alone, by
/// Helm's selectors; a release opened is its one record read, its values
/// and its manifest's Secret masked; a forbidden Secret list degrades,
/// saying so, while the ConfigMap's release still lists. No helm runs, and
/// nothing is written.
extension E2ERunner {
    func kubernetesHelm(_ model: KubernetesModel, _ page: KubernetesPageModel, _ fake: FakeKubeAPI) async {
        let wasShowing = app.store.showingOverlay == .kubernetes
        if !wasShowing { app.toggleKubernetesPage(nil) }
        defer { if !wasShowing, app.store.showingOverlay == .kubernetes { app.toggleKubernetesPage(nil) } }
        let password = "acme-e2e-helm-pw-T7m2"
        let token = "acme-e2e-helm-token-Kq90"
        fake.addHelmRelease("web", namespace: "shop", revision: 1, status: "superseded", config: ["image": ["tag": "1.25"]])
        fake.addHelmRelease(
            "web", namespace: "shop", revision: 2, chart: "web", version: "1.4.2", appVersion: "1.27.0", description: "Upgrade complete",
            config: ["image": ["tag": "1.27"], "auth": ["password": password], "apiToken": token],
            values: ["replicaCount": 1, "image": ["repository": "nginx", "tag": "1.25"]],
            manifest: """
                ---
                # Source: web/templates/secret.yaml
                apiVersion: v1
                kind: Secret
                metadata:
                  name: web-auth
                data:
                  password: \(Data(password.utf8).base64EncodedString())
                ---
                # Source: web/templates/deployment.yaml
                apiVersion: apps/v1
                kind: Deployment
                metadata:
                  name: web
                spec:
                  replicas: 1
                """, notes: "Thanks for installing web.")
        fake.addHelmRelease("cache", namespace: "shop", chart: "redis", version: "19.0.1", appVersion: "7.2", configMap: true)
        model.select("fake-dev")
        model.setScope(.namespace("shop"))
        check("on fake-dev, in shop", await eventually(10) { model.selectedName == "fake-dev" && model.scope == .namespace("shop") })
        page.giveListTheKeyboard()
        fake.forgetRequests()

        check("8 is the list's", await pressKubernetesKey("8", keyCode: 28))
        check("and shows Helm", page.section == .helm && !page.showsSection)
        let helm = page.helm
        check(
            "its releases are listed from Helm's records", await eventually(15) { helm.listState == .live && helm.releases.map(\.name) == ["cache", "web"] },
            "\(helm.listState) \(helm.releases.map(\.name))")
        let web = helm.releases.first { $0.name == "web" }
        check("web's two revisions, newest first", web?.history.map(\.revision) == [2, 1] && web?.status == "deployed")
        check("cache from a ConfigMap", helm.releases.first { $0.name == "cache" }?.storage == .configMap)
        let lists = fake.requests.filter { $0.path.hasSuffix("/secrets") || $0.path.hasSuffix("/configmaps") }
        check(
            "asked for as metadata only", !lists.isEmpty && lists.allSatisfy { $0.accept == KubeClient.metadataListAccept }, "\(lists.map(\.accept))")
        check(
            "by Helm's selectors",
            lists.contains { $0.path.hasSuffix("/secrets") && $0.query["labelSelector"] == "owner=helm" && $0.query["fieldSelector"] == "type=helm.sh/release.v1" })
        check("and no record read for the list", !fake.requests.contains { $0.path.contains("/secrets/") || $0.path.contains("/configmaps/") })
        check("drawn", await shownText(15) { $0.contains("2 releases") } != nil)

        // Opened: one record, decoded and masked.
        if let web {
            page.openHelm(web)
            check("web opened, read and decoded", await eventually(15) { helm.opened?.detail != nil }, "\(String(describing: helm.opened?.state))")
            let reads = fake.requests.filter { $0.path.contains("/secrets/") }.map(\.path)
            check("by one GET of its latest record", reads == ["/api/v1/namespaces/shop/secrets/sh.helm.release.v1.web.v2"], "\(reads)")
            let detail = helm.opened?.detail
            check("its chart", detail?.chart.said == "web-1.4.2" && helm.charts[web.id]?.appVersion == "1.27.0")
            let texts = [detail?.userValues, detail?.computedValues, detail?.manifest, detail?.notes].compactMap { $0 }
            check("its values masked", detail?.userValues.contains("password: \"***\"") == true && detail?.userValues.contains("apiToken: \"***\"") == true)
            check("no value of a secret's anywhere it shows", texts.allSatisfy { !$0.contains(password) && !$0.contains(token) })
            check("nor the manifest's Secret's data", detail?.maskedSecrets == 1 && detail?.manifest.contains(Data(password.utf8).base64EncodedString()) == false)
            check("what isn't secret stays", detail?.userValues.contains("tag: \"1.27\"") == true && detail?.computedValues.contains("repository: nginx") == true)
            helm.tab = .values
            check("the values tab drawn, saying what it masked", await shownText(15) { $0.contains("masked") } != nil)
            page.showSection(.workloads)
            check("another section, the release goes", helm.opened == nil)
            check("8 again", page.press("8") && page.section == .helm)
        }

        // RBAC refuses Secrets: said, helm in a terminal offered; ConfigMaps still list.
        fake.forbidden = ["secrets"]
        page.loadHelm()
        check(
            "a forbidden Secret list degrades", await eventually(15) { helm.listState == .live && helm.secretsRefused != nil },
            "\(helm.listState) \(helm.secretsRefused ?? "none")")
        check("saying why", helm.secretsRefused?.contains("can't list Secrets in shop") == true, helm.secretsRefused ?? "none")
        check("while the ConfigMap's release still lists", helm.releases.map(\.name) == ["cache"], "\(helm.releases.map(\.name))")
        check("drawn", await shownText(15) { $0.contains("can't list Secrets") } != nil)
        check("with helm list to copy", page.helmCommand == "helm list --kube-context fake-dev -n shop")
        fake.forbidden = []
        page.loadHelm()
        check("allowed again, listed again", await eventually(15) { helm.secretsRefused == nil && helm.releases.count == 2 })

        check("Helm wrote nothing", fake.writes.isEmpty, "\(fake.writes)")
        check("nor reached any subresource but a pod's log", fake.subresourceRequests.allSatisfy { $0.isLog }, "\(fake.subresourceRequests)")
        page.showSection(.workloads)
    }
}
