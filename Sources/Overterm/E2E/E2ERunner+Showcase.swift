import AppKit
import Foundation

/// The showcase's Kubernetes and Terraform pictures (README), on fakes
/// only: the Kubernetes page against `FakeKubeAPI` and its Prometheus, a
/// pod's Metrics tab over an hour — no kubectl, never ~/.kube; Terraform's
/// panel over a checkout this run writes, and a plan of its production
/// root in the right slot, decoded from `show -json`'s shape — no
/// terraform runs. Fictional names only.
extension E2ERunner {
    /// The Kubernetes page: a production context's pods, one's Metrics tab
    /// over an hour of the fake Prometheus. Needs OVERTERM_KUBECONFIG (the
    /// run's own file, which this writes); without it, no picture.
    func showcaseKubernetes() async {
        guard let path = ProcessInfo.processInfo.environment["OVERTERM_KUBECONFIG"], !path.isEmpty, !path.contains(":") else {
            return note("showcase: no OVERTERM_KUBECONFIG, no Kubernetes picture")
        }
        let kubeconfig = URL(fileURLWithPath: path)
        guard !KubeconfigSources.isUsersOwn(kubeconfig, home: FileManager.default.homeDirectoryForCurrentUser) else {
            return check("OVERTERM_KUBECONFIG isn't under ~/.kube", false, path)
        }
        // The run writes this file and removes it: never one that is there
        // already, which a run by hand could name — a kubeconfig kept elsewhere.
        guard !FileManager.default.fileExists(atPath: path) else {
            return check("OVERTERM_KUBECONFIG names no file yet", false, path)
        }
        check("the showcase guards the user's kubeconfig", AppEnvironment.guardsKubeconfig)
        let socket = "/tmp/ot-e2e-show-\(UUID().uuidString.prefix(6)).sock"
        let fake = FakeKubeAPI(socket: socket)
        let port: Int
        do {
            try fake.start()
            port = try fake.listenTCP()
        } catch {
            return check("the fake API server starts", false, "\(error)")
        }
        defer { fake.stop() }
        let name = "checkout-api-6d8f7-x2kqd"
        Self.showcaseCluster(fake, pod: name)
        do {
            // The server's address is the picture's, never dialled: every
            // connection goes to the fake's socket (`connectOverride`).
            let shown = Self.fakeKubeconfig(port: port).replacingOccurrences(
                of: "http://127.0.0.1:\(port)", with: "https://k8s.example")
            try shown.write(to: kubeconfig, atomically: true, encoding: .utf8)
        } catch {
            return check("the showcase's kubeconfig is written", false, "\(error)")
        }
        defer { try? FileManager.default.removeItem(at: kubeconfig) }
        let model = KubernetesModel.shared
        model.connectOverride = { context in KubeSocketConnection(socket: socket, context: context.name) }
        model.prometheusOverride = { context, service in
            KubePrometheusDirect(connection: KubeSocketConnection(socket: socket, context: context.name), service: service)
        }
        model.statusOverride = { _ in .open }
        Settings.shared.set(
            "kubernetes.contexts",
            Self.kubeContexts(["fake-prod": ["metrics": .string("prometheus"), "prometheus": .string("monitoring/prometheus-k8s:9090")]]))
        let interval = model.metrics.interval
        model.metrics.interval = .milliseconds(500)
        defer {
            model.connectOverride = nil
            model.prometheusOverride = nil
            model.statusOverride = nil
            model.metrics.interval = interval
            Settings.shared.set("kubernetes.contexts", nil)
        }

        let page = app.kubernetesPage
        app.toggleKubernetesPage(nil)
        check("the fake's contexts are read", await eventually(10) { model.contexts.contexts.map(\.name) == ["fake-dev", "fake-prod"] })
        if model.selectedName != "fake-prod" { model.select("fake-prod") }
        model.setScope(.namespace("shop"))
        page.showKind(.pods)
        page.filter = ""
        page.applySelector()
        check(
            "the pods listed, with their usage",
            await eventually(20) { model.rows[KubeRowID(namespace: "shop", name: name)] != nil && model.metrics.availability == .served },
            "\(model.rows.sorted.map(\.id.description)) \(model.listState)")
        page.selection = ["shop/\(name)"]
        page.metricsRange = .live
        check("m opens the pod's Metrics tab", page.press("m") && page.detailTab == .metrics && page.detail?.ref.name == name)
        check("its Prometheus found", await eventually(20) { if case .found = model.prometheus.state { true } else { false } }, "\(model.prometheus.state)")
        page.pickMetricsRange(.live)
        check(". is 1h", page.press(".") && page.shownMetricsRange == .hour)
        let scope = app.theme.map(ObjectIdentifier.init)
        let charts = KubeChartRegistry.shared
        let cpu = "kubernetes.chart.pod.shop.\(name).cpu"
        check(
            "the pod's CPU over an hour of Prometheus",
            await eventually(25) { charts.chart(cpu, in: scope).map { $0.data.source == "Prometheus" && $0.plot != nil } == true },
            charts.lines(in: scope).joined(separator: "; "))
        await pause(2.0)
        dump("kubernetes")
        check("the showcase wrote nothing to the cluster", fake.writes.isEmpty, "\(fake.writes)")
        page.showTab(.overview)
        page.closeDetail()
        page.metricsRange = .live
        page.metricsRangePicked = false
        app.toggleKubernetesPage(nil)
        app.closeOverlay(.kubernetes)
        _ = await eventually(10) { fake.openWatches == 0 }
        ManagedProcess.closeAll()
        KubeSocketFolder.app.remove()
    }

    /// A shop of a few workloads' pods, served with metrics-server's
    /// numbers and a kube-prometheus-stack Prometheus whose hour of `pod`'s
    /// CPU and memory moves as a service's does.
    private static func showcaseCluster(_ fake: FakeKubeAPI, pod name: String) {
        fake.addNamespace("shop")
        fake.addNamespace("payments")
        fake.addNamespace("monitoring")
        fake.metricsServer = true
        fake.add("nodes", "fake-node-1", values: ["Status": "Ready", "Roles": "<none>", "Version": "v1.34.1"])
        fake.addPod(
            name, namespace: "shop",
            FakeKubeAPI.Pod(
                ready: 2, containers: 2,
                resources: ["app": ["requests": ["cpu": "250m", "memory": "128Mi"], "limits": ["cpu": "1", "memory": "256Mi"]]]),
            labels: ["app": "checkout-api"], created: Date().addingTimeInterval(-2 * 86_400 - 5_400))
        fake.setPodMetrics(name, namespace: "shop", [("app", "142m", "118Mi"), ("sidecar-1", "6m", "12Mi")])
        let others: [(String, String, String, String)] = [
            ("checkout-api-6d8f7-m9w4c", "checkout-api", "131m", "112Mi"),
            ("cart-5b7c9-q8r2t", "cart", "48m", "74Mi"),
            ("catalog-7f9d4-h3k6p", "catalog", "86m", "203Mi"),
            ("catalog-7f9d4-z5n8v", "catalog", "91m", "198Mi"),
            ("orders-worker-58c4d-j7x1b", "orders-worker", "212m", "164Mi"),
            ("web-6c8b5-r4t9m", "web", "23m", "41Mi"),
            ("web-6c8b5-w2p7s", "web", "19m", "39Mi"),
        ]
        for (pod, app, cpu, memory) in others {
            fake.addPod(pod, namespace: "shop", labels: ["app": app], created: Date().addingTimeInterval(-Double(pod.count) * 9_000))
            fake.setPodMetrics(pod, namespace: "shop", [("app", cpu, memory)])
        }
        fake.addPod("postgres-0", namespace: "shop", labels: ["app": "postgres"], created: Date().addingTimeInterval(-41 * 86_400))
        fake.setPodMetrics("postgres-0", namespace: "shop", [("app", "64m", "412Mi")])
        fake.servePrometheus(namespace: "monitoring", service: "prometheus-k8s", port: "9090")
        fake.setPrometheusProfile(.kubePrometheusStack)
        let rule = ["namespace": "shop", "pod": name, "container": "app"]
        fake.setPrometheusSeries(KubePromProfile.containerCPURate5m, labels: rule, value: 0.14)
        fake.setPrometheusSeries(KubePromProfile.containerMemoryRule, labels: rule, value: 118 * 1_048_576)
        // Throttling, network, restarts and the rest a pod's tab asks for, as `kubernetesCharts` answers them.
        fake.setPrometheusMatrix("container_cpu_cfs_throttled_periods_total{", [FakePromFixture.Line(["container": "app"]) { time in 0.04 + 0.03 * wave(time, 900) }])
        fake.setPrometheusMatrix(
            "container_network_receive_bytes_total{",
            [
                FakePromFixture.Line(["overterm_s": "rx"]) { time in 1_200_000 + 450_000 * wave(time, 600) },
                FakePromFixture.Line(["overterm_s": "tx"]) { time in 340_000 + 120_000 * wave(time, 600) },
            ])
        fake.setPrometheusMatrix("sum(clamp_min(", [FakePromFixture.Line { _ in 0 }])
        fake.setPrometheusMatrix("kube_pod_container_status_last_terminated_reason{", [])
        fake.setPrometheusMatrix("container_memory_rss{", [])
        fake.setPrometheusMatrix(
            "container_fs_usage_bytes{",
            [
                FakePromFixture.Line(["overterm_s": "usage", "container": "app"]) { _ in 300 * 1_048_576 },
                FakePromFixture.Line(["overterm_s": "limit", "container": "app"]) { _ in 1_073_741_824 },
            ])
        // An hour of a service's day: CPU and memory by container, raw and as the rules have them.
        let cpu: [FakePromFixture.Line] = [
            FakePromFixture.Line(["container": "app"]) { time in 0.14 + 0.06 * wave(time, 1_100) + 0.02 * wave(time, 170) },
            FakePromFixture.Line(["container": "sidecar-1"]) { time in 0.006 + 0.002 * wave(time, 400) },
        ]
        let memory: [FakePromFixture.Line] = [
            FakePromFixture.Line(["container": "app"]) { time in (112 + 10 * wave(time, 1_700) + 3 * wave(time, 240)) * 1_048_576 },
            FakePromFixture.Line(["container": "sidecar-1"]) { _ in 12 * 1_048_576 },
        ]
        fake.setPrometheusMatrix("rate(container_cpu_usage_seconds_total{", cpu)
        fake.setPrometheusMatrix("\(KubePromProfile.containerCPURate5m){", cpu)
        fake.setPrometheusMatrix("container_memory_working_set_bytes{", memory)
    }

    /// Terraform: the panel over a checkout of three roots and their
    /// modules, envs/prod red; a plan of envs/prod in the right slot —
    /// a replace and why, a risky update, a delete, a create, drift, a
    /// sensitive value masked — from `show -json`'s shape. No terraform.
    func showcaseTerraform() async {
        let checkout = out("acme-infra")
        let files: [String: String] = [
            ".gitignore": ".terraform/\n*.tfstate\n*.tfstate.*\n",
            "envs/dev/main.tf": "module \"network\" {\n  source = \"../../modules/acme-network\"\n}\n\nmodule \"db\" {\n  source = \"../../modules/acme-db\"\n}\n",
            "envs/staging/main.tf": "module \"network\" {\n  source = \"../../modules/acme-network\"\n}\n\nmodule \"db\" {\n  source = \"../../modules/acme-db\"\n}\n",
            "envs/prod/main.tf":
                "module \"network\" {\n  source = \"../../modules/acme-network\"\n}\n\nmodule \"db\" {\n  source = \"../../modules/acme-db\"\n}\n\nresource \"aws_instance\" \"web\" {\n  count = 2\n  ami   = var.ami\n}\n",
            "modules/acme-network/main.tf": "variable \"cidr\" {\n  default = \"10.40.0.0/16\"\n}\n",
            "modules/acme-db/main.tf": "variable \"instance_class\" {\n  default = \"db.r6g.large\"\n}\n",
        ]
        let git = URL(fileURLWithPath: "/usr/bin/git")
        do {
            for (path, text) in files {
                let url = checkout.appendingPathComponent(path)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try text.write(to: url, atomically: true, encoding: .utf8)
            }
            _ = try Git.runBlocking(git, ["init", "-q", "-b", "main"], in: checkout, success: [0], timeout: 10)
            _ = try Git.runBlocking(git, ["add", "-A"], in: checkout, success: [0], timeout: 10)
            _ = try Git.runBlocking(
                git, ["-c", "user.name=Acme", "-c", "user.email=acme@example.test", "commit", "-q", "-m", "acme"], in: checkout, success: [0], timeout: 10)
            // Each root's state, local and out of git: a plan of a root with state.
            for root in ["envs/dev", "envs/staging", "envs/prod"] {
                let lineage = "acme-\(root.split(separator: "/").last ?? "")-0d4c"
                try #"{"version": 4, "terraform_version": "1.17.1", "serial": 42, "lineage": "\#(lineage)", "outputs": {}, "resources": []}"#
                    .write(to: checkout.appendingPathComponent("\(root)/terraform.tfstate"), atomically: true, encoding: .utf8)
            }
        } catch {
            return check("the Terraform checkout is written", false, "\(error)")
        }
        let panel = app.terraformPanel
        // A plain bash with a prompt of the checkout's alone: the picture
        // shows no prompt, name or host of whoever takes it.
        let rc = out("showcase-bashrc")
        try? "PS1='acme-infra (main) $ '\nprintf '\\033[H\\033[2J\\033[3J'\n".write(to: rc, atomically: true, encoding: .utf8)
        app.newTab(
            in: checkout,
            running: "exec /usr/bin/env -i HOME=\"$PWD\" TERM=xterm-256color BASH_SILENCE_DEPRECATION_WARNING=1 /bin/bash --noprofile --rcfile '\(rc.path)' -i")
        let infra = app.store.selected
        infra?.customTitle = "acme-infra"
        check("the panel follows the checkout", await eventually(10) { panel.checkout.map { self.realPath($0) } == self.realPath(checkout) })
        app.showTerraformPanel(nil)
        check(
            "its roots listed", await eventually(15) { panel.roots.map(\.path) == ["envs/dev", "envs/prod", "envs/staging"] },
            "\(panel.roots.map(\.path)) \(panel.state)")
        guard let prod = panel.roots.first(where: { $0.path == "envs/prod" }) else { return check("envs/prod", false) }
        check("envs/prod is production", prod.rootClass == .production, prod.verdict.reason)
        guard let plan = try? TerraformPlan.decode(Self.showcasePlan, scrub: TerraformPlan.scrub), let record = Self.perfRecord(plan) else {
            return check("the showcase's plan decodes", false)
        }
        let run = TerraformPlanRun(kind: .plan, checkout: checkout, card: prod)
        run.landed(record)
        app.showTerraformPlan(run)
        check("the plan in the right slot", await eventually(5) { self.app.terraformPlanPane.rows.isEmpty == false })
        // The slot wide enough for the plan's addresses and buttons.
        await pause(0.6)
        // The sidebar too, for the roots' rows and their class badges.
        let thickness = app.diffItem?.minimumThickness
        app.diffItem?.minimumThickness = 600
        app.sidebarItem?.minimumThickness = 340
        // The window back to the photographs' frame: the terminal gives way.
        await photoFrame()
        defer {
            if let thickness { app.diffItem?.minimumThickness = thickness }
            app.sizeSidebarColumn()
        }
        await pause(1.6)
        // The hidden ⌘F overlay once held the terminal at 640 pt, and the window grew.
        check("the terminal gives way to the panels", window.frame.width == 1_400, "\(window.frame.width)")
        dump("terraform")
        app.terraformPlanPane.clear()
        TerraformRunRegistry.shared.discard(run)
    }

    /// `show -json` of a plan of envs/prod: fictional names only.
    private static let showcasePlan = Data(
        #"""
        {"format_version": "1.2", "terraform_version": "1.17.1", "applyable": true, "complete": true,
         "prior_state": {"format_version": "1.0", "terraform_version": "1.17.1", "values": {"root_module": {}}},
         "resource_drift": [
          {"address": "module.network.aws_security_group.web", "module_address": "module.network", "mode": "managed", "type": "aws_security_group", "name": "web",
           "provider_name": "registry.terraform.io/hashicorp/aws",
           "change": {"actions": ["update"], "before": {"name": "acme-web", "description": "acme web", "tags": {"team": "acme-web"}},
             "after": {"name": "acme-web", "description": "acme web", "tags": {"team": "acme-web", "edited-by": "console"}},
             "after_unknown": {}, "before_sensitive": {}, "after_sensitive": {}}}
         ],
         "resource_changes": [
          {"address": "aws_instance.web[0]", "index": 0, "mode": "managed", "type": "aws_instance", "name": "web", "provider_name": "registry.terraform.io/hashicorp/aws",
           "action_reason": "replace_because_cannot_update",
           "change": {"actions": ["delete", "create"], "replace_paths": [["ami"]],
             "before": {"ami": "ami-0acme1111", "instance_type": "t3.large", "tags": {"Name": "acme-web-0"}},
             "after": {"ami": "ami-0acme2222", "instance_type": "t3.large", "tags": {"Name": "acme-web-0"}},
             "after_unknown": {"id": true, "private_ip": true}, "before_sensitive": {}, "after_sensitive": {}}},
          {"address": "aws_instance.web[1]", "index": 1, "mode": "managed", "type": "aws_instance", "name": "web", "provider_name": "registry.terraform.io/hashicorp/aws",
           "action_reason": "replace_because_cannot_update",
           "change": {"actions": ["delete", "create"], "replace_paths": [["ami"]],
             "before": {"ami": "ami-0acme1111", "instance_type": "t3.large", "tags": {"Name": "acme-web-1"}},
             "after": {"ami": "ami-0acme2222", "instance_type": "t3.large", "tags": {"Name": "acme-web-1"}},
             "after_unknown": {"id": true, "private_ip": true}, "before_sensitive": {}, "after_sensitive": {}}},
          {"address": "module.db.aws_db_instance.orders", "module_address": "module.db", "mode": "managed", "type": "aws_db_instance", "name": "orders",
           "provider_name": "registry.terraform.io/hashicorp/aws",
           "change": {"actions": ["update"],
             "before": {"identifier": "acme-orders", "instance_class": "db.r6g.large", "allocated_storage": 200, "password": "acme-showcase-pw"},
             "after": {"identifier": "acme-orders", "instance_class": "db.r6g.xlarge", "allocated_storage": 200, "password": "acme-showcase-pw"},
             "after_unknown": {}, "before_sensitive": {"password": true}, "after_sensitive": {"password": true}}},
          {"address": "module.network.aws_security_group_rule.legacy_ssh", "module_address": "module.network", "mode": "managed", "type": "aws_security_group_rule",
           "name": "legacy_ssh", "provider_name": "registry.terraform.io/hashicorp/aws",
           "change": {"actions": ["delete"], "before": {"type": "ingress", "from_port": 22, "to_port": 22, "cidr_blocks": ["10.40.0.0/16"]}, "after": null,
             "after_unknown": {}, "before_sensitive": {}, "after_sensitive": false}},
          {"address": "aws_s3_bucket.assets", "mode": "managed", "type": "aws_s3_bucket", "name": "assets", "provider_name": "registry.terraform.io/hashicorp/aws",
           "change": {"actions": ["create"], "before": null, "after": {"bucket": "acme-assets-prod", "tags": {"team": "acme-web"}},
             "after_unknown": {"arn": true, "id": true}, "before_sensitive": false, "after_sensitive": {}}},
          {"address": "aws_cloudwatch_log_group.api", "mode": "managed", "type": "aws_cloudwatch_log_group", "name": "api", "provider_name": "registry.terraform.io/hashicorp/aws",
           "change": {"actions": ["update"], "before": {"name": "/acme/api", "retention_in_days": 14}, "after": {"name": "/acme/api", "retention_in_days": 30},
             "after_unknown": {}, "before_sensitive": {}, "after_sensitive": {}}}
         ],
         "output_changes": {"web_url": {"actions": ["update"], "before": "https://web.acme.example", "after": "https://web.acme.example", "after_unknown": false,
           "before_sensitive": false, "after_sensitive": false}}}
        """#.utf8)
}

/// A wave between -1 and 1 over `period` seconds.
private func wave(_ time: Double, _ period: Double) -> Double { sin(2 * Double.pi * time / period) }
