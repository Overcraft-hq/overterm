import Foundation

extension E2ERunner {
    /// Stage M10 (metrics.md 2.10, 4.6's R1): the Deployment's Metrics tab
    /// on kube-prometheus-stack's profile — nothing sized before Sizing is
    /// pressed; on the press, R1's instant queries over the week through
    /// the Service's `query` with 20 s, from the mixin's rules (no
    /// subquery), its pods by the workload rule over the week; the card per
    /// container against the template's request and limit, CPU from p95,
    /// memory from the max; never refreshed. Then the prometheus chart's
    /// profile (no rules) and 60 pods listed: refused, said, no subquery
    /// sent. The button and the card checked on screen, not only in the
    /// model. Reads only: nothing applied.
    func sizingPart(_ model: KubernetesModel, _ page: KubernetesPageModel, _ fake: FakeKubeAPI, namespace: String, service: KubePrometheusService) async {
        let mi = 1_048_576.0
        let appContainer = ["container": "app"]
        let fixtures: [(String, Double)] = [
            ("quantile_over_time(0.5, \(KubePromProfile.containerCPURate5m){", 0.03), ("quantile_over_time(0.95, \(KubePromProfile.containerCPURate5m){", 0.06),
            ("max_over_time(\(KubePromProfile.containerCPURate5m){", 0.09), ("quantile_over_time(0.95, \(KubePromProfile.containerMemoryRule){", 38 * mi),
            ("max_over_time(\(KubePromProfile.containerMemoryRule){", 40 * mi),
        ]
        for (fragment, value) in fixtures { fake.setPrometheusMatrix(fragment, [FakePromFixture.Line(appContainer) { _ in value }]) }
        // The prometheus chart's pods, listed by owner: sixty of them, a series each.
        let counted = "max by (namespace,pod)(label_replace(max_over_time(kube_pod_owner{"
        fake.setPrometheusMatrix(counted, (0..<60).map { index in FakePromFixture.Line(["namespace": namespace, "pod": "api-7d9fc-\(index)"]) { _ in 1 } })
        defer {
            for (fragment, _) in fixtures { fake.clearPrometheusMatrix(fragment) }
            fake.clearPrometheusMatrix(counted)
            fake.setPrometheusProfile(.kubePrometheusStack)
            model.prometheus.forgetProfile()
            page.hideSizing()
        }
        func sized() -> [FakeKubeAPI.Request] { fake.requests.filter { $0.isPrometheusQuery && $0.query["query"]?.contains("[168h") == true } }

        page.showTab(.overview)
        page.closeDetail()
        guard let deployments = model.discovery?.kind("deployments") else { return check("deployments served", false) }
        page.showKind(deployments)
        check("the Deployment listed for sizing", await eventually(15) { model.kind.fullName == deployments.fullName && model.rows[KubeRowID(namespace: namespace, name: "api")] != nil })
        fake.forgetRequests()
        page.selection = ["\(namespace)/api"]
        check("m opens its Metrics tab", page.press("m") && page.detailTab == .metrics && page.detail?.ref.name == "api")
        guard let ref = page.detail?.ref else { return check("its detail", false) }
        check("Sizing offered: a workload, Prometheus on", page.offersSizing(ref) && page.sizingDisabled == nil, page.sizingDisabled ?? "")
        // On screen, as a person sees it: the button drawn, no card yet.
        let button = await shownText(15) { $0.trimmingCharacters(in: .whitespaces) == "Sizing" }
        check("the Metrics tab draws the Sizing button", button != nil)
        // The card's title says the window ("Sizing · 7 days · per pod"); the workload's own "Per pod" toggle is no sign of it.
        check("no card before the press", await readWindow().first { $0.text.lowercased().contains("7 days") } == nil)
        await pause(1)
        check("nothing sized before the press", sized().isEmpty, "\(sized().map(\.query))")

        page.sizeUsage()
        check("read once pressed", await eventually(20) { page.sizingReading(of: ref)?.done == true }, "\(page.sizingReading(of: ref).map { "\($0)" } ?? "none")")
        let reading = page.sizingReading(of: ref)
        check("from the rules, by the workload rule, over the week", reading?.tier == .rules && reading?.selection == .rule && reading?.window == 7 * 86400)
        check(
            "one instant query a measure and the OOMKills, through the Service's query with 20 s",
            sized().count == 6 && sized().allSatisfy { $0.path == service.queryPath && $0.query["timeout"] == "20s" && $0.query["step"] == nil },
            "\(sized().map(\.query))")
        check("no subquery with the rules", sized().allSatisfy { !($0.query["query"] ?? "").contains(":5m]") })
        check(
            "its pods: whoever the rule says it owned in the week",
            sized().allSatisfy {
                ($0.query["query"] ?? "").contains(
                    #"max_over_time(namespace_workload_pod:kube_pod_owner:relabel{namespace="\#(namespace)",workload="api",workload_type="deployment"}[168h])"#)
            })
        let card = page.detail.flatMap { page.sizingCard(of: $0) }
        let row = card?.rows.first
        check("a row a container", card?.rows.map(\.container) == ["app"], "\(card?.rows.map(\.container) ?? [])")
        check("CPU from p95", row?.cpu?.suggestion == "suggested request ≈ p95 × 1.15 = 70m", row?.cpu?.suggestion ?? "none")
        check("memory from the max", row?.memory?.suggestion == "suggested request and limit ≈ max × 1.15 = 46Mi", row?.memory?.suggestion ?? "none")
        check("against the template's request and limit", row?.cpu?.now == "now: request 100m · limit 500m", row?.cpu?.now ?? "none")
        check("titled per pod", card?.title.hasPrefix("Sizing · 7 days · per pod · recording rules") == true, card?.title ?? "")
        let titled = await shownText(15) { $0.lowercased().contains("7 days") }
        let suggested = await shownText(15) { $0.contains("70m") }
        check("the card's title and suggestion on screen", titled != nil && suggested != nil, "\(titled?.text ?? "no title"); \(suggested?.text ?? "no suggestion")")
        let asked = sized().count
        await pause(1.5)
        check("never refreshed", sized().count == asked && page.sizingWant == nil)
        note("kubernetes sizing: \(sized().first?.query["query"] ?? "none")")

        // No rules, sixty pods counted: refused, said; no subquery sent.
        page.hideSizing()
        fake.setPrometheusProfile(.prometheusChart)
        model.prometheus.forgetProfile()
        fake.forgetRequests()
        page.sizeUsage()
        check("without rules, its pods counted first", await eventually(20) { page.sizingReading(of: ref)?.done == true })
        let refused = page.sizingReading(of: ref)
        check("sixty pods: refused, and why", refused?.pods == 60 && refused?.refused?.contains("at most 50 pods, or one of its pods") == true, refused?.refused ?? refused?.problem ?? "none")
        check(
            "only its pods' list was sent, from kube-state-metrics",
            sized().count == 1 && sized().first?.query["query"]?.hasPrefix("max by (namespace,pod)(") == true
                && !sized().contains { ($0.query["query"] ?? "").contains(":5m]") || ($0.query["query"] ?? "").contains("container_") },
            "\(sized().map(\.query))")
        let said = await shownText(15) { $0.contains("subquery") || $0.contains("50 pods") }
        check("the refusal said on the card", said != nil)
        check("sizing wrote nothing", fake.writes.isEmpty)
        page.showTab(.overview)
        page.closeDetail()
        if let nodes = model.discovery?.kind("nodes") {
            page.showKind(nodes)
            _ = await eventually(10) { model.kind.fullName == "nodes" }
        }
        await pause(1)
    }
}
