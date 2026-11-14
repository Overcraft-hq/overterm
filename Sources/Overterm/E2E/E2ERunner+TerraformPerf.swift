import AppKit

/// Terraform's plan at Section 10's size, timed in the app as built: a
/// generated plan of 2,000 updates (20 tags and a 1 KB string each, the
/// spike's `terraform_data` × 2,000), every one holding a sensitive value
/// that is also copied where nothing marks it — 2,000 `random_password`
/// results. Decoded off the main thread through the allow-list and the mask
/// by value in under 0.5 s; its rows built, filtered and shown in the right
/// slot in under 150 ms. No terraform runs: the plan is the JSON `show
/// -json` would give.
extension E2ERunner {
    func terraformPerfScenario() async {
        let json = Self.terraformPerfPlan(resources: 2_000)
        let started = Date()
        let decoded = await TerraformPanelModel.blocking { () -> TerraformPlan? in try? TerraformPlan.decode(json, scrub: TerraformPlan.scrub) }
        let decode = Date().timeIntervalSince(started)
        guard let plan = decoded else { return check("the generated plan decodes", false) }
        print("E2E PERF terraformPerf decode \(json.count >> 20) MB: \(Int(decode * 1000)) ms")
        check("2,000 resources decoded off the main thread in under 0.5 s", plan.resourceChanges.count == 2_000 && decode < 0.5, "\(Int(decode * 1000)) ms")
        check(
            "the copies of sensitive values masked by value",
            TerraformAttributeDiff.flatten(plan.resourceChanges[1_999].after)["output.copy"] == TerraformAttributeDiff.masked)

        var start = Date()
        let rows = TerraformPlanRows.build(plan)
        let build = Date().timeIntervalSince(start)
        print("E2E PERF terraformPerf rows: \(Int(build * 1000)) ms")
        check("its rows in under 150 ms", !rows.isEmpty && build < 0.15, "\(Int(build * 1000)) ms")

        // In the slot: shown, then a filter typed — rows kept by the model, not built in a body.
        let card = TerraformRootCard(
            path: "envs/perf", name: "envs/perf", folder: scratch.appendingPathComponent("envs/perf"), kind: .root, facts: TerraformRootFacts(),
            backendSummary: "local", identity: nil, verdict: .init(rootClass: .local, reason: "local"))
        let run = TerraformPlanRun(kind: .plan, checkout: scratch, card: card)
        guard let record = Self.perfRecord(plan) else { return check("a record for the plan", false) }
        run.landed(record)
        start = Date()
        app.showTerraformPlan(run)
        await pause(0.05)
        let shown = Date().timeIntervalSince(start) - 0.05
        print("E2E PERF terraformPerf shown: \(Int(shown * 1000)) ms")
        check("shown in the slot in under 150 ms", app.terraformPlanPane.rows.count == rows.count && shown < 0.15, "\(Int(shown * 1000)) ms")
        start = Date()
        app.terraformPlanPane.filter = "acme[1999]"
        let filtered = Date().timeIntervalSince(start)
        print("E2E PERF terraformPerf filter: \(Int(filtered * 1000)) ms")
        check("a filter keystroke in under 150 ms", app.terraformPlanPane.rows.count == 1 && filtered < 0.15, "\(Int(filtered * 1000)) ms")
        app.terraformPlanPane.clear()
        TerraformRunRegistry.shared.discard(run)
    }

    /// A held record over a scratch descriptor (nothing to apply).
    static func perfRecord(_ plan: TerraformPlan) -> TerraformPlanRecord? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("overterm-tf-perf-\(UUID().uuidString)")
        guard (try? Data("PK\u{3}\u{4}".utf8).write(to: url)) != nil else { return nil }
        let fd = open(url.path, O_RDONLY | O_CLOEXEC)
        unlink(url.path)
        guard fd >= 0 else { return nil }
        return TerraformPlanRecord(
            plan: plan, file: TerraformPlanFile(descriptor: fd, sha256: "", size: 4, mode: 0o600), binary: URL(fileURLWithPath: "/nonexistent/terraform"),
            version: "1.17.1", environment: [:], dataDir: "", workspace: "default", status: 2)
    }

    /// `show -json` of a plan of `resources` updates at the spike's shape:
    /// 20 tags, a 1 KB string, a sensitive `result` copied into an unmarked
    /// `output`. Fictional names only.
    nonisolated static func terraformPerfPlan(resources: Int) -> Data {
        let filler = String(repeating: "acme-filler-", count: 85)
        var changes: [String] = []
        changes.reserveCapacity(resources)
        for index in 0..<resources {
            let secret = "acme-pw-\(index)-\(String(format: "%08x", index &* 2_654_435_761 & 0xFFFF_FFFF))"
            let tags = (0..<20).map { "\"label\($0)\": \"acme-\($0)\"" }.joined(separator: ", ")
            let newTags = (0..<20).map { "\"label\($0)\": \"acme-\($0 == 0 ? index : $0)\"" }.joined(separator: ", ")
            changes.append(
                """
                {"address": "terraform_data.acme[\(index)]", "index": \(index), "mode": "managed", "type": "terraform_data", "name": "acme", "provider_name": "terraform.io/builtin/terraform",
                 "change": {"actions": ["update"],
                   "before": {"input": {"result": "\(secret)", "note": "\(filler)\(index)", "tags": {\(tags)}}, "output": {"copy": "\(secret)", "note": "\(filler)"}},
                   "after": {"input": {"result": "\(secret)", "note": "\(filler)\(index + 1)", "tags": {\(newTags)}}, "output": {"copy": "\(secret)", "note": "\(filler)"}},
                   "after_unknown": {}, "before_sensitive": {"input": {"result": true}}, "after_sensitive": {"input": {"result": true}}}}
                """)
        }
        return Data(("{\"format_version\": \"1.2\", \"terraform_version\": \"1.17.1\", \"applyable\": true, \"complete\": true, \"resource_changes\": [" + changes.joined(separator: ",") + "]}").utf8)
    }
}
