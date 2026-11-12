import Darwin
import XCTest

@testable import Overterm

/// Stage 2a, the apply (analysis 2.3, 4.7, 4.8, 5.3, 5.4, 6.4): the one
/// apply line and the plan's modes; 5.4's checks, each with its refusal;
/// the version's move; the sheet's typed names; the apply's own
/// environment; the detached apply against stand-ins behind the recording
/// wrapper — its session, its files, its end, Stop, and a relaunch's
/// finding it again; the close guard's decision. No real terraform runs.
final class TerraformApplyCommandTests: XCTestCase {
    private let out = "/tmp/ot-tf-501-77/1f2e/plan"

    func testTheOneApply() {
        XCTAssertEqual(TerraformCommands.apply, ["apply", "-input=false", "-json", "-lock=true", "-lock-timeout=60s", "/dev/fd/3"])
        XCTAssertNil(TerraformCommands.refusal(TerraformCommands.apply))
        let refused: [[String]] = [
            ["apply"], ["apply", "/dev/fd/3"], ["apply", "plan"], ["apply", "-auto-approve"],
            ["apply", "-input=false", "-json", "-lock=false", "-lock-timeout=60s", "/dev/fd/3"],
            ["apply", "-input=false", "-json", "-lock=true", "-lock-timeout=60s", "-target=a.b", "/dev/fd/3"],
            ["apply", "-input=false", "-json", "-lock=true", "-lock-timeout=60s", "-var=a=1", "/dev/fd/3"],
            ["apply", "-input=false", "-json", "-lock=true", "-lock-timeout=60s", "-refresh-only", "/dev/fd/3"],
            ["apply", "-input=false", "-json", "-lock=true", "-lock-timeout=60s", "/tmp/plan"],
            ["-chdir=envs/prod"] + TerraformCommands.apply, ["destroy", "-auto-approve"], ["apply", "-destroy"],
        ]
        for arguments in refused { XCTAssertNotNil(TerraformCommands.refusal(arguments), "\(arguments)") }
    }

    func testThePlansModes() throws {
        let destroy = try XCTUnwrap(TerraformCommands.plan(out: out, mode: .destroy))
        XCTAssertTrue(destroy.contains("-destroy"))
        XCTAssertTrue(TerraformCommands.isPlan(destroy))
        let spaced = #"aws_instance.web["a b"]"#
        let targets = try XCTUnwrap(TerraformCommands.plan(out: out, varFiles: ["dev.tfvars"], mode: .targets([spaced, "module.acme.terraform_data.x"])))
        XCTAssertEqual(Array(targets.suffix(3)), ["-target=" + spaced, "-target=module.acme.terraform_data.x", "-var-file=dev.tfvars"], "one argument each, never quoted")
        XCTAssertTrue(TerraformCommands.isPlan(targets))
        XCTAssertNil(TerraformCommands.refusal(targets))
        let replace = try XCTUnwrap(TerraformCommands.plan(out: out, mode: .replace(["random_pet.acme"])))
        XCTAssertTrue(replace.contains("-replace=random_pet.acme"))
        XCTAssertTrue(TerraformCommands.isPlan(replace))
        for address in ["-a.b", "a", "acme", "a.b\nc", "a.b\u{200B}", "a.b\u{202E}c", "a.b\u{0}", "a.b\t", ".a.b", String(repeating: "a.", count: 300)] {
            XCTAssertNil(TerraformCommands.plan(out: out, mode: .targets([address])), address.debugDescription)
        }
        XCTAssertNil(TerraformCommands.plan(out: out, mode: .targets([])))
        XCTAssertNil(TerraformCommands.plan(out: out, mode: .targets(Array(repeating: "a.b", count: 2))), "an address once")
        XCTAssertNil(TerraformCommands.plan(out: out, mode: .targets((0...50).map { "a.b\($0)" })), "at most 50")
        XCTAssertFalse(TerraformCommands.isPlan(destroy + ["-target=a.b"]), "one mode at a time")
        XCTAssertEqual(TerraformPlanMode.destroy.label, "destroy")
        XCTAssertEqual(TerraformPlanMode.targets(["a.b"]).label, "partial: only a.b")
        XCTAssertNil(TerraformPlanMode.normal.label)
    }

    func testTheApplysStreamMessages() {
        let start = TerraformUIMessage.decode(
            #"{"@level":"info","@message":"terraform_data.acme: Creating...","type":"apply_start","hook":{"resource":{"addr":"terraform_data.acme"},"action":"create"}}"#)
        XCTAssertEqual(start, .apply(address: "terraform_data.acme", action: "create", step: .start, elapsed: nil))
        let complete = TerraformUIMessage.decode(
            #"{"type":"apply_complete","hook":{"resource":{"addr":"terraform_data.acme"},"action":"create","id_key":"id","id_value":"acme-hunter2-SECRET","elapsed_seconds":3}}"#)
        XCTAssertEqual(complete, .apply(address: "terraform_data.acme", action: "create", step: .complete, elapsed: 3))
        XCTAssertFalse(complete.logLine.contains("acme-hunter2-SECRET"), "never an object's ID")
        let errored = TerraformUIMessage.decode(#"{"type":"apply_errored","hook":{"resource":{"addr":"a.b"},"action":"delete","elapsed_seconds":1}}"#)
        XCTAssertEqual(errored, .apply(address: "a.b", action: "delete", step: .errored, elapsed: 1))
        // Split so the source never holds a whole token-shaped string.
        let fakeToken = "ghp" + "_0123456789abcdefghij" + "0123456789abcdef"
        let output = TerraformUIMessage.decode(
            #"{"type":"provision_progress","hook":{"resource":{"addr":"a.b"},"provisioner":"local-exec","output":"token=\#(fakeToken)"}}"#)
        guard case .provision(let address, let provisioner, let step, let text) = output else { return XCTFail("\(output)") }
        XCTAssertEqual([address, provisioner], ["a.b", "local-exec"])
        XCTAssertEqual(step, .progress)
        XCTAssertFalse(text?.contains(fakeToken) ?? true, "scrubbed")
        let summary = TerraformUIMessage.decode(#"{"type":"change_summary","changes":{"add":1,"change":0,"remove":0,"operation":"apply"}}"#)
        XCTAssertEqual(summary, .summary(add: 1, change: 0, remove: 0, importing: 0, operation: "apply"))
        let diagnostic = TerraformUIMessage.decode(
            #"{"type":"diagnostic","diagnostic":{"severity":"error","summary":"local-exec provisioner error","detail":"exit 1","address":"terraform_data.acme","range":{"filename":"main.tf","start":{"line":4,"column":3,"byte":40}}}}"#
        )
        guard case .diagnostic(let said) = diagnostic else { return XCTFail("\(diagnostic)") }
        XCTAssertEqual(said.address, "terraform_data.acme")
        XCTAssertEqual(said.start?.line, 4)
    }

    func testARootIsWritableBySettingOnlyWhenRemote() {
        let settings = TerraformRootSettings(fields: ["writable": .bool(true), "class": .string("production")])
        XCTAssertTrue(settings.writable)
        XCTAssertTrue(TerraformProcessCheck.isWritable(.remote, writable: settings.writable, sessionWrites: false))
        XCTAssertFalse(TerraformProcessCheck.isWritable(.production, writable: settings.writable, sessionWrites: false), "never a setting")
        XCTAssertFalse(TerraformRootSettings(fields: [:]).writable)
    }

    func testThePlanListsApplyAndStopKeys() {
        XCTAssertEqual(TerraformPlanPaneModel.key(keyCode: 0, characters: "A"), .apply)
        XCTAssertEqual(TerraformPlanPaneModel.key(keyCode: 47, characters: "."), .stop)
        XCTAssertNil(TerraformPlanPaneModel.key(keyCode: 0, characters: "a").flatMap { $0 == .apply ? $0 : nil }, "a is Ask Why, ⇧A applies")
    }
}

final class TerraformApplyCheckTests: XCTestCase {
    private func plan(
        applyable: Bool = true, complete: Bool = true, errored: Bool = false, version: String? = "1.17.1", prior: String? = "1.17.1", priorState: Bool = true,
        changes: [TerraformPlan.ResourceChange] = []
    ) -> TerraformPlan {
        var plan = TerraformPlan(formatVersion: "1.2", applyable: applyable, complete: complete, errored: errored)
        plan.terraformVersion = version
        plan.priorStateVersion = prior
        plan.hasPriorState = priorState
        plan.resourceChanges = changes
        return plan
    }

    private func change(_ address: String, _ actions: [String], paths: [String] = [], after: TerraformValue? = nil) -> TerraformPlan.ResourceChange {
        TerraformPlan.ResourceChange(
            address: address, previousAddress: nil, module: nil, mode: "managed", type: String(address.split(separator: ".")[0]),
            name: String(address.split(separator: ".")[1]), index: nil, provider: "registry.terraform.io/hashicorp/aws", actions: actions, reason: nil,
            replacePaths: [], importingID: nil, before: nil, after: after, changedPaths: paths)
    }

    private let environment = ["PATH": "/usr/bin", "TF_WORKSPACE": "default", "AWS_PROFILE": "acme-dev", "TF_DATA_DIR": "/acme/envs/dev/.terraform"]

    /// Everything as when planned: the facts a fresh apply sees.
    private func facts(_ plan: TerraformPlan, rootClass: TerraformClass = .local) -> TerraformApplyFacts {
        var facts = TerraformApplyFacts(
            plan: plan, recordSHA: "abc", recordBinary: "/opt/acme/terraform", recordVersion: "1.17.1", recordWorkspace: "default",
            recordDataDir: "/acme/envs/dev/.terraform", recordEnvironment: environment, zipLockSHA: "lock1", rootName: "envs/dev", rootClass: rootClass)
        facts.descriptorSHA = "abc"
        facts.binaryNow = "/opt/acme/terraform"
        facts.versionNow = "1.17.1"
        facts.environmentNow = environment
        facts.dataDirNow = "/acme/envs/dev/.terraform"
        facts.lockSHANow = "lock1"
        return facts
    }

    private func refusal(_ facts: TerraformApplyFacts) -> String? {
        if case .refused(let why) = TerraformApplyCheck.check(facts) { return why }
        return nil
    }

    func testAFreshLocalPlanAsksWithoutAName() {
        XCTAssertEqual(TerraformApplyCheck.check(facts(plan())), .ask(typed: false, versionMove: nil, partial: false, createsEverything: false))
    }

    /// 5.1, 5.13 rule 12: the class read again at apply time — a root seen
    /// as production since its plan (sticky by identity, the pattern,
    /// `terraform.roots`) is never applied as the plan's `local`.
    func testAClassRisenSinceThePlanRefuses() {
        var risen = facts(plan())
        risen.classNow = TerraformClassifier.Verdict(rootClass: .production, reason: "seen production as acme-prod")
        XCTAssertEqual(refusal(risen)?.hasPrefix("envs/dev is production now (seen production as acme-prod), not local"), true, refusal(risen) ?? "")
        risen.classNow = TerraformClassifier.Verdict(rootClass: .remote, reason: "set by hand")
        XCTAssertEqual(refusal(risen)?.contains("is remote now"), true)
        var same = facts(plan(), rootClass: .production)
        same.sessionWrites = true
        same.classNow = TerraformClassifier.Verdict(rootClass: .production, reason: "the pattern")
        XCTAssertEqual(TerraformApplyCheck.check(same), .ask(typed: true, versionMove: nil, partial: false, createsEverything: false), "unchanged: asked as before")
        XCTAssertNil(TerraformApplyCheck.risen(name: "envs/dev", planned: .production, now: .init(rootClass: .local, reason: "")), "a class only rises")
    }

    /// 5.4, each check its refusal (5.13 rule 2).
    func testEachCheckRefuses() {
        XCTAssertTrue(refusal(facts(plan(), rootClass: .production))?.contains("plan only") == true, "production without its switch")
        XCTAssertTrue(refusal(facts(plan(), rootClass: .remote))?.contains("set writable") == true)
        XCTAssertNotNil(refusal(facts(plan(errored: true))))
        XCTAssertNotNil(refusal(facts(plan(applyable: false))))
        var production = facts(plan(complete: false), rootClass: .production)
        production.sessionWrites = true
        XCTAssertTrue(refusal(production)?.contains("partial") == true, "a partial plan isn't applied on production")
        var swapped = facts(plan())
        swapped.descriptorSHA = "def"
        XCTAssertTrue(refusal(swapped)?.contains("hash") == true, "a swapped descriptor")
        var binary = facts(plan())
        binary.binaryNow = "/opt/globex/terraform"
        XCTAssertNotNil(refusal(binary), "another binary")
        var version = facts(plan())
        version.versionNow = "1.18.0"
        XCTAssertTrue(refusal(version)?.contains("1.18.0") == true, "a binary now another version")
        var workspace = facts(plan())
        workspace.workspaceRefusal = "Workspace acme-stage no longer exists in local · terraform.tfstate"
        XCTAssertEqual(refusal(workspace), workspace.workspaceRefusal)
        var changed = facts(plan())
        changed.environmentNow?["AWS_PROFILE"] = "acme-prod-admin"
        changed.environmentNow?["TF_VAR_acme_secret"] = "acme-hunter2-SECRET"
        let said = refusal(changed) ?? ""
        XCTAssertTrue(said.contains("AWS_PROFILE") && said.contains("TF_VAR_acme_secret"), said)
        XCTAssertFalse(said.contains("acme-prod-admin") || said.contains("acme-hunter2-SECRET"), "names, never values")
        var lock = facts(plan())
        lock.lockSHANow = "lock2"
        XCTAssertTrue(refusal(lock)?.contains("lock file") == true, "an edited lock file")
        var noLock = facts(plan())
        noLock.lockSHANow = nil
        XCTAssertNotNil(refusal(noLock), "a lock file removed")
        var none = facts(plan())
        none.lockSHANow = nil
        none.zipLockPinsNothing = true
        XCTAssertNil(refusal(none), "no lock file is one that pins nothing")
        var understood = facts(plan())
        understood.plan.unknownKeys = ["acme_future"]
        XCTAssertTrue(refusal(understood)?.contains("acme_future") == true)
        var overrides = facts(plan())
        overrides.devOverrides = true
        XCTAssertNotNil(refusal(overrides))
        var stale = facts(plan())
        stale.staleReason = "applied from acme-bump at 14:52: plan again"
        XCTAssertTrue(refusal(stale)?.contains("acme-bump") == true, "another worktree's apply")
        var old = facts(plan())
        old.staleReason = "older than 30 minutes: plan again"
        XCTAssertNotNil(refusal(old))
        var busy = facts(plan())
        busy.busy = "An apply of envs/dev in acme-bump is running on this state."
        XCTAssertEqual(refusal(busy), busy.busy)
        var dataDir = facts(plan())
        dataDir.dataDirNow = "/tmp/shared"
        XCTAssertNotNil(refusal(dataDir))
    }

    func testTypedNamesWhereTheyAreAsked() {
        var production = facts(plan(), rootClass: .production)
        production.sessionWrites = true
        XCTAssertEqual(TerraformApplyCheck.check(production), .ask(typed: true, versionMove: nil, partial: false, createsEverything: false), "every production apply (D-21)")
        var destroy = facts(plan())
        destroy.mode = .destroy
        XCTAssertEqual(TerraformApplyCheck.check(destroy), .ask(typed: true, versionMove: nil, partial: false, createsEverything: false), "a destroy, any class")
        var everything = facts(plan(priorState: false))
        everything.recordWorkspace = "acme-stage"
        XCTAssertEqual(TerraformApplyCheck.check(everything), .ask(typed: true, versionMove: nil, partial: false, createsEverything: true))
        var elsewhere = facts(plan(priorState: false))
        elsewhere.stateElsewhere = "main"
        XCTAssertEqual(TerraformApplyCheck.check(elsewhere), .ask(typed: true, versionMove: nil, partial: false, createsEverything: true))
        XCTAssertEqual(TerraformApplyCheck.check(facts(plan(priorState: false))), .ask(typed: false, versionMove: nil, partial: false, createsEverything: false), "a first apply on default")
        XCTAssertEqual(TerraformApplyCheck.check(facts(plan(complete: false))), .ask(typed: false, versionMove: nil, partial: true, createsEverything: false), "partial, labelled")
    }

    /// 3.8, D-18: a newer minor moves the state, asked with the sentence.
    func testTheVersionsMove() {
        XCTAssertEqual(
            TerraformApplyCheck.movesState(root: "envs/prod", planVersion: "1.17.1", priorVersion: "1.9.8"),
            "This moves the state of envs/prod to Terraform 1.17; anyone on 1.9 can no longer plan it.")
        XCTAssertNil(TerraformApplyCheck.movesState(root: "envs/prod", planVersion: "1.17.1", priorVersion: "1.17.0"), "a patch moves nothing")
        XCTAssertNil(TerraformApplyCheck.movesState(root: "envs/prod", planVersion: "1.9.0", priorVersion: "1.17.0"))
        XCTAssertNil(TerraformApplyCheck.movesState(root: "envs/prod", planVersion: "1.17.1", priorVersion: nil), "no state yet")
        guard case .ask(_, let move, _, _) = TerraformApplyCheck.check(facts(plan(prior: "1.9.8"))) else { return XCTFail() }
        XCTAssertEqual(move, "This moves the state of envs/dev to Terraform 1.17; anyone on 1.9 can no longer plan it.")
    }

    func testTheGreyedApplyNeedsNothingRead() {
        XCTAssertNil(TerraformApplyCheck.greyed(plan: plan(), rootClass: .local, writable: false, sessionWrites: false, mode: .normal, devOverrides: false, staleReason: nil, busy: nil))
        XCTAssertNotNil(TerraformApplyCheck.greyed(plan: nil, rootClass: .local, writable: false, sessionWrites: false, mode: .normal, devOverrides: false, staleReason: nil, busy: nil))
        XCTAssertNotNil(TerraformApplyCheck.greyed(plan: plan(), rootClass: .production, writable: true, sessionWrites: false, mode: .normal, devOverrides: false, staleReason: nil, busy: nil))
        XCTAssertNil(TerraformApplyCheck.greyed(plan: plan(), rootClass: .production, writable: false, sessionWrites: true, mode: .normal, devOverrides: false, staleReason: nil, busy: nil))
        XCTAssertTrue(
            TerraformApplyCheck.greyed(plan: plan(), rootClass: .local, writable: false, sessionWrites: false, mode: .normal, devOverrides: false, staleReason: "older than 30 minutes", busy: nil)?
                .hasPrefix("Stale") == true)
        XCTAssertTrue(TerraformApplyCheck.hasDevOverrides([TerraformDiagnostic(severity: .warning, summary: "Provider development overrides are in effect", detail: "")]))
    }

    func testTheSheet() {
        var changes = [change("aws_db_instance.acme", ["delete", "create"]), change("aws_s3_bucket.acme_logs", ["delete"])]
        changes.append(change("aws_rds_cluster.acme", ["update"], paths: ["deletion_protection"]))
        changes.append(change("aws_security_group.acme", ["update"], paths: ["ingress"], after: .object(["ingress": .list([.object(["cidr_blocks": .list([.string("0.0.0.0/0")])])])])))
        changes.append(change("aws_instance.acme", ["update"], paths: ["tags.deployed_at"]))
        changes.append(change("aws_instance.globex[\"a\u{202E}b\"]", ["delete"]))
        let sheet = TerraformApplySheet.make(
            root: .init(
                name: "envs/prod", path: "envs/prod", rootClass: .production, backend: "s3 · acme-tfstate/prod.tfstate", workspace: "acme-eu", worktree: "acme-infra", branch: "main @ 3f2a91c"),
            plan: plan(changes: changes), mode: .normal, typed: true, versionMove: nil, partial: false, createsEverything: false, risks: ["a provisioner"],
            profile: "acme-prod-admin", region: "eu-west-1")
        XCTAssertEqual(sheet.typedName, "envs/prod@acme-eu", "the workspace when it isn't default")
        XCTAssertTrue(sheet.production)
        XCTAssertTrue(sheet.scope.hasPrefix("PRODUCTION · envs/prod · workspace acme-eu"))
        XCTAssertTrue(sheet.detail.contains("± aws_db_instance.acme"))
        XCTAssertTrue(sheet.detail.contains("- aws_s3_bucket.acme_logs"))
        XCTAssertFalse(sheet.detail.contains("\u{202E}"), "a bidi character escaped")
        XCTAssertTrue(sheet.detail.contains("Risky updates (a heuristic)"))
        XCTAssertTrue(sheet.detail.contains("aws_rds_cluster.acme: deletion_protection"))
        XCTAssertTrue(sheet.detail.contains("aws_security_group.acme: ingress, open to 0.0.0.0/0"))
        XCTAssertFalse(sheet.detail.contains("aws_instance.acme:"), "tags aren't risky")
        XCTAssertTrue(sheet.detail.contains("AWS_PROFILE acme-prod-admin · region eu-west-1"))
        XCTAssertTrue(sheet.detail.contains("terraform apply -input=false -json -lock=true -lock-timeout=60s /dev/fd/3"))
        XCTAssertTrue(sheet.detail.contains("Its code: a provisioner"))
        XCTAssertEqual(TerraformApplySheet.typedName(root: "envs/dev", workspace: "default"), "envs/dev")
        let many = (0..<60).map { change("terraform_data.acme\($0)", ["delete"]) }
        let long = TerraformApplySheet.make(
            root: .init(name: "envs/dev", path: "envs/dev", rootClass: .local, backend: "local", workspace: "default", worktree: "acme", branch: nil),
            plan: plan(changes: many), mode: .destroy, typed: true, versionMove: nil, partial: false, createsEverything: false, risks: [], profile: nil, region: nil)
        XCTAssertTrue(long.detail.contains("… and 10 more"))
        XCTAssertEqual(long.button, "Destroy")
        XCTAssertEqual(long.title, "Destroy everything in envs/dev?")
    }
}

/// The detached apply against stand-ins (4.7): never a real terraform.
final class TerraformApplyRunTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = URL(fileURLWithPath: "/tmp").appendingPathComponent("ot-tfa-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: folder) }

    private func script(_ name: String, _ body: String) throws -> URL {
        let url = folder.appendingPathComponent("bin/\(name)")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/bash -p\n\(body)\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }

    private func planDescriptor() throws -> Int32 {
        let url = folder.appendingPathComponent("plan-\(UUID().uuidString)")
        try Data("PK\u{3}\u{4}acme-plan".utf8).write(to: url)
        let fd = open(url.path, O_RDONLY | O_CLOEXEC)
        unlink(url.path)
        return fd
    }

    private func marker(_ pid: pid_t, _ started: UInt64) -> TerraformApplyMarker {
        TerraformApplyMarker(
            pid: pid, started: started, executable: TerraformApplyLaunch.shell, checkout: folder.path, root: "envs/dev", name: "envs/dev",
            workspace: "default", rootClass: "local", identity: "terraform local \(folder.path)/envs/dev/terraform.tfstate", at: TerraformApplyMarker.now)
    }

    @MainActor private func wait(_ timeout: TimeInterval, _ condition: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    static let stream = [
        #"{"type":"version","terraform":"1.17.1","ui":"1.3"}"#,
        #"{"type":"apply_start","hook":{"resource":{"addr":"terraform_data.acme"},"action":"delete"}}"#,
        #"{"type":"apply_complete","hook":{"resource":{"addr":"terraform_data.acme"},"action":"delete","elapsed_seconds":0}}"#,
        #"{"type":"apply_start","hook":{"resource":{"addr":"terraform_data.acme"},"action":"create"}}"#,
        #"{"type":"apply_complete","hook":{"resource":{"addr":"terraform_data.acme"},"action":"create","id_value":"acme-id","elapsed_seconds":0}}"#,
        #"{"type":"change_summary","changes":{"add":1,"change":0,"remove":1,"operation":"apply"}}"#,
    ]

    /// Its own session and group; the plan as fd 3; its files 0600; the
    /// hostile names out; the end from the exit code and an apply summary.
    @MainActor func testADetachedApplyLands() async throws {
        let lines = Self.stream.map { "printf '%s\\n' \(TerraformRecorder.quoted($0))" }.joined(separator: "\n")
        let standIn = try script("terraform", "/bin/cat /dev/fd/3 > \(TerraformRecorder.quoted(folder.appendingPathComponent("fd3").path))\n\(lines)\nexit 0")
        let recorder = try TerraformRecorder.make(in: folder.appendingPathComponent("recorder"), target: standIn.path)
        let run = folder.appendingPathComponent("runs/ot-tf-\(getuid())-\(getpid())/r1", isDirectory: true)
        try FileManager.default.createDirectory(at: run, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let root = folder.appendingPathComponent("envs/dev", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fd = try planDescriptor()
        defer { close(fd) }
        let environment = [
            "PATH": "/usr/bin:/bin", "TF_WORKSPACE": "default", "TF_DATA_DIR": root.appendingPathComponent(".terraform").path, "TF_CLI_ARGS_apply": "-lock=false",
            "TF_LOG": "trace", "TF_REATTACH_PROVIDERS": "{}",
        ]
        let made = try TerraformApplyLaunch.spawn(binary: recorder.wrapper, root: root, environment: environment, plan: fd, folder: run, marker: marker)
        XCTAssertGreaterThan(made.pid, 0)
        XCTAssertEqual(getsid(made.pid), made.pid, "a session of its own: no terminal, no SIGHUP")
        XCTAssertEqual(TerraformApplyMarker.read(run), made, "its marker, beside its files")
        let apply = TerraformApplyRun(
            marker: made, folder: run, plan: nil, identity: nil, key: "acme", reattached: false, child: ProcessGroup.Child(pid: made.pid))
        apply.follow()
        let landed = await wait(15) { if case .applied = apply.phase { true } else { false } }
        XCTAssertTrue(landed, "\(apply.phase) \(apply.log)")
        XCTAssertEqual(apply.phase, .applied("Apply complete — 1 added, 0 changed, 1 destroyed."))
        XCTAssertEqual(apply.rows.first?.state, .done)
        XCTAssertEqual(apply.rows.first?.action, .replace, "a delete then a create: a replace's two steps")
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("fd3"), encoding: .utf8), "PK\u{3}\u{4}acme-plan", "the plan as fd 3")
        XCTAssertFalse(FileManager.default.fileExists(atPath: run.path), "its folder gone once followed to the end")
        let call = try XCTUnwrap(recorder.calls().first)
        XCTAssertEqual(call.arguments, TerraformCommands.apply)
        XCTAssertEqual(call.cwd, realpath(root.path, nil).map { String(cString: $0) })
        for name in ["TF_CLI_ARGS_apply", "TF_LOG", "TF_REATTACH_PROVIDERS"] { XCTAssertFalse(call.names.contains(name), name) }
        XCTAssertEqual(call.values["TF_WORKSPACE"], "default")
    }

    /// Stop (D-3): one SIGINT to the group; terraform stops as it will, the
    /// launcher still writes its code; said as stopped, never applied.
    @MainActor func testStopInterruptsTheGroup() async throws {
        let standIn = try script(
            "terraform",
            #"trap 'printf "%s\n" "{\"type\":\"change_summary\",\"changes\":{\"add\":0,\"change\":0,\"remove\":0,\"operation\":\"apply\"}}"; exit 1' INT"#
                + "\nprintf '%s\\n' '{\"type\":\"apply_start\",\"hook\":{\"resource\":{\"addr\":\"terraform_data.acme\"},\"action\":\"create\"}}'\nwhile true; do /bin/sleep 0.1; done")
        let run = folder.appendingPathComponent("runs/r2", isDirectory: true)
        try FileManager.default.createDirectory(at: run, withIntermediateDirectories: true)
        let fd = try planDescriptor()
        defer { close(fd) }
        let made = try TerraformApplyLaunch.spawn(binary: standIn, root: folder, environment: ["PATH": "/usr/bin:/bin"], plan: fd, folder: run, marker: marker)
        let apply = TerraformApplyRun(marker: made, folder: run, plan: nil, identity: nil, key: "acme", reattached: false, child: ProcessGroup.Child(pid: made.pid))
        apply.follow()
        let running = await wait(10) { apply.rows.first?.state == .running }
        XCTAssertTrue(running)
        XCTAssertTrue(apply.stop(), "the first Stop is sent")
        XCTAssertFalse(apply.stop(), "a second asks first")
        let stopped = await wait(10) { if case .stopped = apply.phase { true } else { false } }
        XCTAssertTrue(stopped, "\(apply.phase)")
    }

    /// A relaunch finds an apply by its pid and start time, never a pid
    /// reused since; the sweep keeps its folder and removes the rest.
    @MainActor func testAnApplyIsFoundAgainAfterTheAppGoes() async throws {
        let standIn = try script("terraform", "/bin/sleep 3\nprintf '%s\\n' '{\"type\":\"change_summary\",\"changes\":{\"add\":0,\"change\":0,\"remove\":0,\"operation\":\"apply\"}}'")
        // A process folder of a pid that is gone, as a crashed Overterm's.
        let gone = Process()
        gone.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try gone.run()
        gone.waitUntilExit()
        let base = folder.appendingPathComponent("runs", isDirectory: true)
        let crashed = base.appendingPathComponent(TerraformRunFolder.name(pid: gone.processIdentifier), isDirectory: true)
        let alive = crashed.appendingPathComponent("alive", isDirectory: true)
        let dead = crashed.appendingPathComponent("dead", isDirectory: true)
        for folder in [alive, dead] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        let fd = try planDescriptor()
        defer { close(fd) }
        let made = try TerraformApplyLaunch.spawn(binary: standIn, root: folder, environment: ["PATH": "/usr/bin:/bin"], plan: fd, folder: alive, marker: marker)
        let child = ProcessGroup.Child(pid: made.pid)
        XCTAssertTrue(TerraformApplyMarker.liveNow(made))
        var reused = made
        reused.started += 1
        XCTAssertFalse(TerraformApplyMarker.liveNow(reused), "a pid reused since isn't it")
        XCTAssertFalse(
            TerraformApplyMarker.isAlive(made, alive: { _ in true }, started: { _ in made.started }, path: { _ in "/bin/zsh" }), "another executable isn't it")
        let found = TerraformApplyLaunch.detached(base: base, includingOwn: false, followed: [])
        XCTAssertEqual(found.map(\.marker), [made])
        XCTAssertEqual(TerraformApplyLaunch.detached(base: base, includingOwn: false, followed: [alive.standardizedFileURL.path]).count, 0, "one followed already")
        let swept = TerraformRunFolder.sweep(base: base)
        XCTAssertEqual(swept.map(\.marker), [made])
        XCTAssertTrue(FileManager.default.fileExists(atPath: alive.path), "an apply alive keeps its folder")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dead.path), "the rest of a dead process's is swept")
        let apply = TerraformApplyRun.reattach(folder: alive, marker: made)
        XCTAssertTrue(apply.reattached)
        let ended = await wait(15) { !apply.isGoing }
        XCTAssertTrue(ended, "\(apply.phase)")
        XCTAssertTrue(child.isRunning == false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: alive.path))
    }

    /// 4.7: a marker that can't be written starts nothing — the launcher
    /// waits for its go, and exits without running terraform.
    @MainActor func testAMarkerNotWrittenStartsNothing() async throws {
        let ran = folder.appendingPathComponent("ran")
        let standIn = try script("terraform", "/usr/bin/touch \(TerraformRecorder.quoted(ran.path))")
        let run = folder.appendingPathComponent("runs/r3", isDirectory: true)
        try FileManager.default.createDirectory(at: run, withIntermediateDirectories: true)
        let fd = try planDescriptor()
        defer { close(fd) }
        struct Unwritable: Error {}
        XCTAssertThrowsError(
            try TerraformApplyLaunch.spawn(
                binary: standIn, root: folder, environment: ["PATH": "/usr/bin:/bin"], plan: fd, folder: run, marker: marker, write: { _, _ in throw Unwritable() })
        ) { error in
            guard case TerraformApplyLaunch.Failure.marker = error else { return XCTFail("\(error)") }
        }
        try? await Task.sleep(for: .milliseconds(800))
        XCTAssertFalse(FileManager.default.fileExists(atPath: ran.path), "terraform never ran")
        XCTAssertNil(TerraformApplyLaunch.status(in: run), "nor did the launcher say it did")
    }

    /// 4.7, D-3: a launcher killed (SIGKILL — its trap can't catch it)
    /// leaves terraform applying in its group: followed until it is done,
    /// never SIGKILLed while it runs; Stop still reaches it.
    @MainActor func testAKilledLauncherLeavesTerraformFollowedNotKilled() async throws {
        let done = folder.appendingPathComponent("done")
        let standIn = try script(
            "terraform",
            "printf '%s\\n' '{\"type\":\"apply_start\",\"hook\":{\"resource\":{\"addr\":\"terraform_data.acme\"},\"action\":\"create\"}}'\n/bin/sleep 2\n/usr/bin/touch \(TerraformRecorder.quoted(done.path))"
        )
        let run = folder.appendingPathComponent("runs/r4", isDirectory: true)
        try FileManager.default.createDirectory(at: run, withIntermediateDirectories: true)
        let fd = try planDescriptor()
        defer { close(fd) }
        let made = try TerraformApplyLaunch.spawn(binary: standIn, root: folder, environment: ["PATH": "/usr/bin:/bin"], plan: fd, folder: run, marker: marker)
        let apply = TerraformApplyRun(marker: made, folder: run, plan: nil, identity: nil, key: "acme", reattached: false, child: ProcessGroup.Child(pid: made.pid))
        apply.follow()
        let started = await wait(10) { apply.rows.first?.state == .running }
        XCTAssertTrue(started)
        kill(made.pid, SIGKILL)
        try? await Task.sleep(for: .milliseconds(600))
        XCTAssertTrue(apply.isGoing, "terraform still runs in the group: still followed")
        XCTAssertFalse(TerraformApplyGroup.live(made).isEmpty, "its group is still there, without its launcher")
        let ended = await wait(10) { !apply.isGoing }
        XCTAssertTrue(ended, "\(apply.phase)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: done.path), "terraform ran to its end: never killed while it ran")
        XCTAssertEqual(apply.phase, .failed("The apply ended without saying how (its launcher was killed): 0 applied. Plan again to see the state."))
    }

    /// The group's members (4.7): only the apply's; a plugin swept only
    /// once nothing else runs; nothing when the leader's pid is another's.
    func testTheGroupsMembersAreTheApplysOnly() {
        let launch = marker(500, 1_000)
        let launcher = TerraformApplyGroup.Member(pid: 500, started: 1_000, session: 500, path: "/bin/bash")
        let terraform = TerraformApplyGroup.Member(pid: 501, started: 1_100, session: 500, path: "/opt/acme/terraform")
        let plugin = TerraformApplyGroup.Member(
            pid: 502, started: 1_200, session: 500, path: "/acme/.terraform/providers/registry.terraform.io/hashicorp/null/3.2.4/darwin_arm64/terraform-provider-null_v3.2.4_x5")
        let older = TerraformApplyGroup.Member(pid: 503, started: 900, session: 500, path: "/bin/sleep")
        let elsewhere = TerraformApplyGroup.Member(pid: 504, started: 1_300, session: 77, path: "/bin/sleep")
        XCTAssertEqual(TerraformApplyGroup.ours([launcher, terraform, plugin, older, elsewhere], marker: launch), [launcher, terraform, plugin])
        XCTAssertEqual(TerraformApplyGroup.strays([terraform, plugin]), [], "terraform runs: nothing is killed")
        XCTAssertEqual(TerraformApplyGroup.strays([plugin]), [502], "terraform gone: its plugin swept")
        XCTAssertFalse(TerraformApplyGroup.terraformRuns([plugin]))
        let reused = TerraformApplyGroup.Member(pid: 500, started: 5_000, session: 500, path: "/bin/bash")
        XCTAssertEqual(TerraformApplyGroup.ours([reused, plugin], marker: launch), [], "the leader's pid is another process: none are ours")
        XCTAssertEqual(TerraformApplyGroup.ours([terraform], marker: marker(500, 0)), [], "no start time: nothing")
    }

    /// 5.6, rule 12: what the apply's stream prints in clear — a
    /// provisioner's output, an `apply_errored` diagnostic — masked by the
    /// plan's sensitive values, in the rows, the log, the diagnostics, the
    /// model's description and what Ask Why gives an agent.
    @MainActor func testTheApplysClearPathsAreMaskedByThePlansValues() {
        let sentinels = ["acme-hunter2-SECRET", "tok-acme-123", "globex-BKPW"]
        let mask = TerraformValueMask(TerraformSensitiveValues(Set(sentinels)))
        XCTAssertFalse(String(reflecting: mask).contains("acme-hunter2"), "the mask says nothing of its values")
        XCTAssertFalse(String(describing: mask).contains("tok-acme"))
        let lines = [
            #"{"type":"apply_start","hook":{"resource":{"addr":"terraform_data.acme"},"action":"create"}}"#,
            #"{"@message":"terraform_data.acme (local-exec): pw acme-hunter2-SECRET","type":"provision_progress","hook":{"resource":{"addr":"terraform_data.acme"},"provisioner":"local-exec","output":"pw acme-hunter2-SECRET"}}"#,
            #"{"type":"provision_progress","hook":{"resource":{"addr":"terraform_data.acme"},"provisioner":"local-exec","output":"tok-acme-123"}}"#,
            #"{"@level":"error","@message":"Error: globex-BKPW refused","type":"diagnostic","diagnostic":{"severity":"error","summary":"globex-BKPW refused","detail":"the API said: token tok-acme-123 for acme-hunter2-SECRET is invalid","address":"terraform_data.acme"}}"#,
            #"{"type":"apply_errored","hook":{"resource":{"addr":"terraform_data.acme"},"action":"create","elapsed_seconds":1}}"#,
        ]
        let messages = lines.map { TerraformUIMessage.decode($0, scrub: mask.scrub) }
        let marker = TerraformApplyMarker(
            pid: 0, started: 0, executable: TerraformApplyLaunch.shell, checkout: "/acme", root: "envs/dev", name: "envs/dev", workspace: "default",
            rootClass: "local", identity: nil, at: TerraformApplyMarker.now)
        let apply = TerraformApplyRun(
            marker: marker, folder: URL(fileURLWithPath: "/nonexistent"), plan: nil, identity: nil, key: "acme", reattached: false, child: nil, mask: mask)
        apply.absorb(messages)
        apply.ended(status: 1, stderr: "Error: acme-hunter2-SECRET\n")
        XCTAssertEqual(apply.rows.first?.state, .errored)
        XCTAssertEqual(apply.rows.first?.output.count, 2, "the provisioner's lines under its row")
        let brief = apply.brief(backend: "local", version: "1.17.1", providers: [])
        let everywhere = [
            String(reflecting: apply.rows), apply.log.joined(separator: "\n"), String(reflecting: apply.diagnostics), String(reflecting: messages),
            "\(apply.phase)", brief.parts.map(\.text).joined(separator: "\n"),
        ]
        for sentinel in sentinels {
            XCTAssertFalse(everywhere.contains { $0.contains(sentinel) }, sentinel)
        }
        XCTAssertTrue(apply.rows.first?.output.first?.contains(TerraformPlan.redaction) == true, "\(apply.rows.first?.output ?? [])")
    }

    /// 4.7, 5.6: the run folder keeps the plan's values as salted
    /// digests, never a value; an apply followed again after a crash is
    /// masked by them as before.
    @MainActor func testARelaunchMasksByTheFoldersDigests() throws {
        let sentinels = ["acme-hunter2-SECRET", "tok-acme-123", "globex-BKPW"]
        let mask = TerraformValueMask(TerraformSensitiveValues(Set(sentinels)))
        let run = folder.appendingPathComponent("runs/r5", isDirectory: true)
        try FileManager.default.createDirectory(at: run, withIntermediateDirectories: true)
        try mask.write(to: run)
        let kept = try Data(contentsOf: run.appendingPathComponent(TerraformHashedValues.file))
        for sentinel in sentinels { XCTAssertFalse(String(decoding: kept, as: UTF8.self).contains(sentinel), "never a value on disk") }
        let mode = try FileManager.default.attributesOfItem(atPath: run.appendingPathComponent(TerraformHashedValues.file).path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
        let again = TerraformValueMask.read(run)
        XCTAssertFalse(again.isEmpty)
        XCTAssertEqual(again.scrub("tok-acme-123"), TerraformPlan.redaction, "a whole line equal to one")
        XCTAssertEqual(again.scrub("globex-acme-hunter2-SECRET; done"), "globex-\(TerraformPlan.redaction); done")
        XCTAssertFalse(again.scrub("Executing: [\"/bin/sh\" \"-c\" \"echo globex-BKPW and tok-acme-123\"]").contains("BKPW"))
        XCTAssertEqual(again.scrub("nothing here"), "nothing here")
        XCTAssertFalse(String(reflecting: again).contains("acme"), "says nothing of its values")
        XCTAssertTrue(TerraformValueMask.read(folder.appendingPathComponent("runs/none")).isEmpty, "no file: no mask")
        XCTAssertThrowsError(try mask.write(to: run), "a new file only, never one already there")
    }

    /// 2.3, 6.4 step 5: Ask Why on a failed apply is the apply's — its
    /// diagnostics by address and its log, not its plan's; a reattached
    /// one (no plan) too.
    @MainActor func testAskWhyOnAFailedApplyIsTheApplys() {
        let marker = TerraformApplyMarker(
            pid: 0, started: 0, executable: TerraformApplyLaunch.shell, checkout: "/acme", root: "envs/dev", name: "envs/dev", workspace: "acme-eu",
            rootClass: "production", identity: "s3 acme-state/envs/dev", at: TerraformApplyMarker.now)
        let apply = TerraformApplyRun(marker: marker, folder: URL(fileURLWithPath: "/nonexistent"), plan: nil, identity: nil, key: "acme", reattached: true, child: nil)
        apply.absorb([
            TerraformUIMessage.decode(#"{"type":"apply_start","hook":{"resource":{"addr":"aws_s3_bucket.acme_logs"},"action":"update"}}"#),
            TerraformUIMessage.decode(
                #"{"type":"diagnostic","diagnostic":{"severity":"error","summary":"updating S3 Bucket (acme-logs) ACL: AccessDenied","detail":"","address":"aws_s3_bucket.acme_logs","range":{"filename":"main.tf","start":{"line":67,"column":1,"byte":0},"end":{"line":67,"column":9,"byte":8}}}}"#
            ),
        ])
        apply.ended(status: 1, stderr: "")
        guard case .failed(let said) = apply.phase else { return XCTFail("\(apply.phase)") }
        XCTAssertTrue(said.hasPrefix("1 failed — state saved, 0 applied: updating S3 Bucket"), said)
        XCTAssertEqual(apply.rows.first?.file, "main.tf")
        XCTAssertEqual(apply.rows.first?.line, 67)
        let brief = apply.brief(backend: nil, version: nil, providers: ["registry.terraform.io/hashicorp/aws 6.2.0"])
        let titles = brief.parts.map(\.title)
        XCTAssertTrue(titles.contains("apply's diagnostics"), "\(titles)")
        let text = brief.parts.map(\.text).joined(separator: "\n")
        XCTAssertTrue(text.contains("AccessDenied") && text.contains("main.tf:67"), text)
        XCTAssertTrue(text.contains("Workspace: acme-eu") && text.contains("Class: Production"), text)
        XCTAssertTrue(text.contains("1 failed — state saved"), "its end, in its log's last lines")
        XCTAssertEqual(apply.rootFolder.path, "/acme/envs/dev")
    }

    func testTheApplysEnvironmentIsThePlansWithNothingThatInjects() {
        let recorded = [
            "AWS_PROFILE": "acme-dev", "TF_WORKSPACE": "acme-stage", "TF_DATA_DIR": "/acme/.terraform", "TF_CLI_ARGS": "-auto-approve", "TF_CLI_ARGS_apply": "-lock=false",
            "TF_LOG": "trace", "TF_LOG_PATH": "/tmp/log", "TF_REATTACH_PROVIDERS": "{}", "TF_VAR_acme_region": "eu-west-1",
        ]
        let environment = TerraformApplyLaunch.environment(recorded)
        XCTAssertEqual(Set(environment.keys), ["AWS_PROFILE", "TF_WORKSPACE", "TF_DATA_DIR", "TF_VAR_acme_region"])
        XCTAssertEqual(environment["TF_WORKSPACE"], "acme-stage", "the plan's workspace, as recorded")
        XCTAssertEqual(
            TerraformApplyLaunch.arguments(status: URL(fileURLWithPath: "/tmp/s"), binary: URL(fileURLWithPath: "/opt/acme/terraform")).suffix(7),
            ["/opt/acme/terraform"] + TerraformCommands.apply)
    }

    func testProgressWords() {
        XCTAssertEqual(TerraformApplyRun.elapsed(72), "1m 12s")
        XCTAssertEqual(TerraformApplyRun.elapsed(9), "9s")
        XCTAssertEqual(TerraformApplyRun.elapsed(3_725), "1h 2m")
    }
}

final class TerraformCloseGuardTests: XCTestCase {
    private func line(_ text: String) -> TerraformCommandLine { TerraformCommandLine.parse(text, probable: false)! }

    func testWhatClosingAsksAbout() {
        for guarded in [
            "terraform apply", "terraform destroy", "terraform import a.b id", "terraform state rm a.b", "terraform state mv a b", "terraform force-unlock 1",
            "terraform workspace delete acme", "terraform -chdir=envs/prod apply -auto-approve", "terragrunt run --all apply", "terraform init -migrate-state",
        ] {
            XCTAssertTrue(TerraformCloseGuard.isGuarded(line(guarded)), guarded)
        }
        for free in ["terraform plan", "terraform validate", "terraform fmt", "terraform output", "terraform workspace list", "terraform init"] {
            XCTAssertFalse(TerraformCloseGuard.isGuarded(line(free)), free)
        }
    }

    func testTheQuestionPerPath() throws {
        let running = [TerraformCloseGuard.Running(pid: 4_242, group: 4_242, operation: "apply", tool: "terraform", root: "envs/prod", place: "this pane")]
        XCTAssertNil(TerraformCloseGuard.question([], path: .pane))
        let pane = try XCTUnwrap(TerraformCloseGuard.question(running, path: .pane))
        XCTAssertEqual(pane.title, "terraform apply is running in envs/prod (this pane).")
        XCTAssertTrue(pane.detail.hasPrefix("Closing kills it at once: the lock may stay held"))
        XCTAssertTrue(try XCTUnwrap(TerraformCloseGuard.question(running, path: .tabs)).detail.hasPrefix("Closing the tab kills it"))
        XCTAssertTrue(try XCTUnwrap(TerraformCloseGuard.question(running, path: .window)).detail.hasPrefix("Closing the window kills it"))
        XCTAssertTrue(try XCTUnwrap(TerraformCloseGuard.question(running + running, path: .quit)).title.contains("and 1 more"))
        XCTAssertEqual(TerraformCloseGuard.Question.buttons, ["Interrupt", "Close Anyway", "Cancel"])
    }

    func testInterruptReachesTerraformNotItsAgent() {
        let own = TerraformCloseGuard.Running(pid: 4_242, group: 4_242, operation: "apply", tool: "terraform", root: ".", place: "")
        XCTAssertEqual(TerraformCloseGuard.interruptTarget(own), -4_242, "its own group, as Ctrl-C")
        let child = TerraformCloseGuard.Running(pid: 4_243, group: 4_100, operation: "apply", tool: "terraform", root: ".", place: "")
        XCTAssertEqual(TerraformCloseGuard.interruptTarget(child), 4_243, "an agent's child: terraform alone")
    }

    /// 4.8: once interrupted writes stop, the notice offers Close Now —
    /// the close Interrupt held back — or keeps the pane; the header says
    /// "shutting down" meanwhile.
    func testTheNoticeOnceInterruptedWritesStop() throws {
        let running = [TerraformCloseGuard.Running(pid: 4_242, group: 4_242, operation: "apply", tool: "terraform", root: "envs/prod", place: "this pane", tag: "p1")]
        XCTAssertNil(TerraformCloseGuard.stoppedNotice([], path: .pane))
        let pane = try XCTUnwrap(TerraformCloseGuard.stoppedNotice(running, path: .pane))
        XCTAssertEqual(pane.title, "terraform apply has stopped in envs/prod (this pane).")
        XCTAssertTrue(pane.detail.hasSuffix("Close the pane now, or keep it open."))
        XCTAssertTrue(try XCTUnwrap(TerraformCloseGuard.stoppedNotice(running, path: .quit)).detail.hasSuffix("Quit now, or keep Overterm open."))
        XCTAssertEqual(TerraformCloseGuard.stoppedButtons, ["Close Now", "Keep Open"])
        XCTAssertEqual(TerraformCloseGuard.shuttingDown(running[0]), "terraform apply shutting down — interrupted")
    }

    func testQuittingWhileAnApplyRuns() throws {
        XCTAssertNil(TerraformCloseGuard.quitQuestion([]))
        let question = try XCTUnwrap(TerraformCloseGuard.quitQuestion([("envs/prod", Date())]))
        XCTAssertEqual(question.title, "An apply in envs/prod is running.")
        XCTAssertTrue(question.detail.contains("quitting lets it finish"))
    }

    /// `newSession`: setsid, its own group; without it, a group only.
    func testANewSession() throws {
        let null = open("/dev/null", O_WRONLY)
        defer { close(null) }
        let session = try ProcessGroup.spawn(URL(fileURLWithPath: "/bin/sleep"), ["5"], [:], stdout: null, stderr: null, newSession: true).get()
        let grouped = try ProcessGroup.spawn(URL(fileURLWithPath: "/bin/sleep"), ["5"], [:], stdout: null, stderr: null).get()
        defer {
            for pid in [session, grouped] {
                kill(pid, SIGKILL)
                var status: Int32 = 0
                waitpid(pid, &status, 0)
            }
        }
        XCTAssertEqual(getsid(session), session)
        XCTAssertEqual(getpgid(session), session)
        XCTAssertEqual(getpgid(grouped), grouped)
        XCTAssertNotEqual(getsid(grouped), grouped)
    }
}
