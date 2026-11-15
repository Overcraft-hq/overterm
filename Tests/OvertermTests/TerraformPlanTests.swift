import Compression
import CryptoKit
import XCTest

@testable import Overterm

/// Stage 1d's pure parts: the plan's command line and what it can never
/// say (5.13 rule 1), its environment, the workspace and process checks,
/// locks parsed from Terraform's words, the UI stream, the plan zip's
/// facts, the rows, the cause chain, the risk list and the questions,
/// init's fetch list — and the sentinel test of 5.6 rule 12.
final class TerraformPlanCommandTests: XCTestCase {
    let out = "/tmp/ot-tf-501-4242/0d7f/plan"

    func testThePlanLine() throws {
        let plan = try XCTUnwrap(TerraformCommands.plan(out: out, varFiles: ["dev.tfvars", "envs/acme.tfvars.json"]))
        XCTAssertEqual(
            plan,
            [
                "plan", "-input=false", "-json", "-detailed-exitcode", "-lock=true", "-lock-timeout=10s", "-out=\(out)", "-var-file=dev.tfvars",
                "-var-file=envs/acme.tfvars.json",
            ])
        XCTAssertNil(TerraformCommands.refusal(plan))
        XCTAssertTrue(TerraformCommands.isPlan(plan))
        let agent = try XCTUnwrap(TerraformCommands.plan(out: out, lock: .agent))
        XCTAssertTrue(agent.contains("-lock-timeout=0s"), "an agent's plan never waits on a lock")
        XCTAssertNil(TerraformCommands.refusal(agent))
        XCTAssertNil(TerraformCommands.refusal(try XCTUnwrap(TerraformCommands.plan(out: out, lock: .wait, parallelism: 4))))
    }

    func testWhatAPlanLineCanNeverBe() {
        XCTAssertNil(TerraformCommands.plan(out: "/tmp/acme/plan"), "only a run folder of Overterm's")
        XCTAssertNil(TerraformCommands.plan(out: "/tmp/ot-tf-501-1/../../etc/plan"))
        XCTAssertNil(TerraformCommands.plan(out: "plan"))
        for file in ["../prod.tfvars", "/etc/acme.tfvars", "~/acme.tfvars", "-var=x", "acme.tf", "a//b.tfvars", ""] {
            XCTAssertNil(TerraformCommands.plan(out: out, varFiles: [file]), file)
        }
        XCTAssertNil(TerraformCommands.plan(out: out, parallelism: 0))
        let base = TerraformCommands.plan(out: out)!
        let refused: [[String]] = [
            base + ["-lock=false"], base + ["-refresh=false"], base + ["-auto-approve"], base + ["-var=acme=1"], base + ["-target=-a.b"],
            base + ["-target=a.b", "-destroy"], base + ["-var-file=dev.tfvars", "-target=a.b"],
            base + ["-minimal-refresh"], base.map { $0 == "-lock=true" ? "-lock=false" : $0 }, base.map { $0 == "-lock-timeout=10s" ? "-lock-timeout=1h" : $0 },
            ["-chdir=envs/prod"] + base, ["apply", "-input=false", "-json", "-lock=true", "-lock-timeout=60s", "/dev/fd/4"], ["apply", out],
            ["apply", "-input=false", "-json", "-lock=true", "-lock-timeout=60s", "-auto-approve", "/dev/fd/3"],
            ["init"], ["init", "-input=false", "-json", "-lockfile=readonly", "-upgrade"], ["init", "-reconfigure"], ["init", "-migrate-state"],
            ["workspace", "select", "-or-create", "acme"], ["workspace", "new", "acme"], ["workspace", "delete", "acme"], ["workspace", "select", "../x"],
            ["state", "rm", "a.b"], ["force-unlock", "1"], ["output", "-json"], ["show", "-json"], ["plan"], ["plan", "-destroy"],
        ]
        for arguments in refused {
            XCTAssertNotNil(TerraformCommands.refusal(arguments), "\(arguments)")
        }
    }

    /// Every builder's output, enumerated: none says a forbidden form.
    func testEveryBuiltLineIsClean() {
        var lines = TerraformCommands.all
        for lock in TerraformCommands.LockWait.allCases {
            lines.append(TerraformCommands.plan(out: out, varFiles: ["dev.tfvars"], lock: lock, parallelism: 8)!)
        }
        lines.append(TerraformCommands.workspaceSelect("acme-stage")!)
        for line in lines {
            XCTAssertNil(TerraformCommands.refusal(line), "\(line)")
            for flag in TerraformCommands.forbiddenFlags { XCTAssertFalse(line.contains { $0.hasPrefix(flag) && !(flag == "-var=" && $0.hasPrefix("-var-file=")) }, "\(line) \(flag)") }
            XCTAssertTrue(!line.contains("apply") || line == TerraformCommands.apply, "the one apply: \(line)")
            XCTAssertFalse(line.contains { $0.hasPrefix("-target") })
        }
        XCTAssertEqual(TerraformCommands.initialize, ["init", "-input=false", "-json", "-lockfile=readonly"])
        XCTAssertNil(TerraformCommands.workspaceSelect("-or-create"))
        XCTAssertNil(TerraformCommands.workspaceSelect("acme stage"))
        XCTAssertNil(TerraformCommands.workspaceSelect(String(repeating: "a", count: 91)))
    }

    func testTheRunsEnvironment() {
        let hostile = [
            "PATH": "/usr/bin", "AWS_PROFILE": "acme-prod-admin", "TF_CLI_ARGS_apply": "-lock=false", "TF_CLI_ARGS": "-auto-approve", "TF_LOG": "trace",
            "TF_REATTACH_PROVIDERS": "{}", "TF_WORKSPACE": "acme-typo", "TF_DATA_DIR": "/tmp/shared", "TF_VAR_acme_region": "eu-west-1",
        ]
        let scratch = TerraformGuards.Scratch(folder: URL(fileURLWithPath: "/tmp/acme-scratch"))
        let root = URL(fileURLWithPath: "/tmp/acme-infra/envs/dev")
        let run = TerraformEnvironment.build(base: hostile, purpose: .run(workspace: "acme-stage", pluginCache: "/tmp/acme-cache"), root: root, scratch: scratch)
        XCTAssertEqual(run["AWS_PROFILE"], "acme-prod-admin", "credential chains pass through, unread")
        XCTAssertEqual(run["TF_VAR_acme_region"], "eu-west-1")
        for name in ["TF_CLI_ARGS_apply", "TF_CLI_ARGS", "TF_LOG", "TF_REATTACH_PROVIDERS", "TF_DATA_DIR"] where name != "TF_DATA_DIR" {
            XCTAssertNil(run[name], name)
        }
        XCTAssertEqual(run["TF_WORKSPACE"], "acme-stage", "the checked workspace, never the shell's")
        XCTAssertEqual(run["TF_DATA_DIR"], root.appendingPathComponent(".terraform").path)
        XCTAssertEqual(run["TF_PLUGIN_CACHE_DIR"], "/tmp/acme-cache")
        XCTAssertEqual(run["CHECKPOINT_DISABLE"], "1")
        XCTAssertEqual(run["TF_INPUT"], "0")
        let select = TerraformEnvironment.build(base: hostile, purpose: .run(workspace: nil, pluginCache: nil), root: root, scratch: scratch)
        XCTAssertNil(select["TF_WORKSPACE"], "workspace list and select never pinned")
        XCTAssertEqual(TerraformEnvironment.variableNames(in: hostile), ["acme_region"])
    }

    func testEveryVerbAgainstEveryClass() {
        for verb in TerraformVerb.allCases {
            for rootClass in TerraformClass.allCases {
                for writable in [false, true] {
                    let refused = TerraformProcessCheck.refused(verb, rootClass: rootClass, writable: writable)
                    if TerraformProcessCheck.neverBuilt.contains(verb) {
                        XCTAssertNotNil(refused, "\(verb) is never built")
                    } else if verb == .apply || verb == .refreshOnlyApply || verb == .testRealProviders {
                        // The owner's decision: the setting alone, on every class.
                        XCTAssertEqual(refused == nil, writable, "\(verb) \(rootClass) writable \(writable)")
                    } else {
                        XCTAssertNil(refused, "\(verb) is started on any class")
                    }
                }
            }
        }
        XCTAssertTrue(TerraformProcessCheck.isWritable(.production, writable: true), "production writable unless its setting says no")
        XCTAssertNil(TerraformProcessCheck.refused(.apply, rootClass: .production), "writable by default")
    }

    func testAWorkspaceThatDoesntExistIsRefused() {
        let local = TerraformConfigFacts.Backend(type: "local")
        XCTAssertNil(TerraformWorkspaceCheck.refusal(workspace: "default", backend: local, localWorkspaces: [], listed: nil))
        XCTAssertNil(TerraformWorkspaceCheck.refusal(workspace: "acme-stage", backend: local, localWorkspaces: ["acme-stage"], listed: nil))
        let ghost = TerraformWorkspaceCheck.refusal(workspace: "acme-ghost", backend: local, localWorkspaces: ["acme-stage"], listed: nil)
        XCTAssertEqual(ghost?.hasPrefix("Workspace acme-ghost no longer exists in local"), true, ghost ?? "")
        let s3 = TerraformConfigFacts.Backend(type: "s3", settings: ["bucket": "acme-tfstate", "key": "net.tfstate"])
        XCTAssertNil(TerraformWorkspaceCheck.refusal(workspace: "acme-stage", backend: s3, localWorkspaces: [], listed: ["default", "acme-stage"]))
        XCTAssertNotNil(TerraformWorkspaceCheck.refusal(workspace: "acme-typo", backend: s3, localWorkspaces: [], listed: ["default", "acme-stage"]))
        XCTAssertNil(TerraformWorkspaceCheck.refusal(workspace: "acme-typo", backend: s3, localWorkspaces: [], listed: nil), "not listed yet: the caller lists")
        var cloud = TerraformConfigFacts.Backend(type: "cloud", settings: ["organization": "globex"])
        cloud.workspaceName = "net-prod"
        XCTAssertNotNil(TerraformWorkspaceCheck.refusal(workspace: "acme", backend: cloud, localWorkspaces: [], listed: nil))
        XCTAssertNotNil(TerraformWorkspaceCheck.refusal(workspace: "-or-create", backend: local, localWorkspaces: ["-or-create"], listed: nil))
        XCTAssertEqual(TerraformWorkspaceCheck.parseList("* default\n  acme-stage\n\n"), ["default", "acme-stage"])
    }
}

final class TerraformLockTests: XCTestCase {
    /// Terraform 1.17.1's own diagnostic, from a sandbox (a local backend).
    static let local =
        "Error message: resource temporarily unavailable\nLock Info:\n  ID:        864669d0-00d0-31f2-ed5d-37161463d31b\n  Path:      terraform.tfstate\n  Operation: OperationTypeApply\n  Who:       acme@globex-mac.local\n  Version:   1.17.1\n  Created:   2026-11-12 11:33:00.759159 +0000 UTC\n  Info:      \n\n\nTerraform acquires a state lock to protect the state from being written\nby multiple users at the same time."

    func testTheLocalBackendsWords() throws {
        let lock = try XCTUnwrap(TerraformLockInfo.parse(summary: "Error acquiring the state lock", detail: Self.local))
        XCTAssertEqual(lock.id, "864669d0-00d0-31f2-ed5d-37161463d31b")
        XCTAssertEqual(lock.who, "acme@globex-mac.local")
        XCTAssertEqual(lock.operationWords, "an apply")
        XCTAssertEqual(lock.version, "1.17.1")
        XCTAssertEqual(lock.path, "terraform.tfstate")
        XCTAssertNil(lock.info)
        XCTAssertFalse(lock.http)
        XCTAssertEqual(lock.created, Date(timeIntervalSince1970: 1_794_483_180), "Go's time, to the second")
        XCTAssertEqual(
            lock.said(now: Date(timeIntervalSince1970: 1_794_486_000), timeZone: TimeZone(identifier: "UTC")!),
            "Locked by acme@globex-mac.local since 11:33 (an apply, Terraform 1.17.1)")
        XCTAssertEqual(lock.age(now: Date(timeIntervalSince1970: 1_794_483_180 + 3 * 3_600)), "3 h")
        XCTAssertTrue(lock.isThisMac(user: "acme", host: "globex-mac.local"))
        XCTAssertFalse(lock.isThisMac(user: "acme", host: "initech-mac"))
    }

    func testTheHTTPVariant() throws {
        let detail =
            "Error message: HTTP remote state already locked: ID=8a3c1e52-acme-0000-0000-0000000f00d5\nLock Info:\n  ID:        8a3c1e52-acme-0000-0000-0000000f00d5\n  Path:      \n  Operation: OperationTypeApply\n  Who:       ci@globex-runner-7\n  Version:   1.17.1\n  Created:   2026-11-08 09:00:00 +0000 UTC\n  Info:      \n"
        let lock = try XCTUnwrap(TerraformLockInfo.parse(summary: "Error acquiring the state lock", detail: detail))
        XCTAssertTrue(lock.http)
        XCTAssertEqual(lock.who, "ci@globex-runner-7")
        XCTAssertNil(lock.path)
        let bare = TerraformLockInfo.parse(summary: "Error acquiring the state lock", detail: "Error message: HTTP remote state already locked: ID=acme-1")
        XCTAssertEqual(bare?.id, "acme-1")
        XCTAssertNil(TerraformLockInfo.parse(summary: "No value for required variable", detail: Self.local), "only Terraform's lock diagnostic")
    }
}

final class TerraformUIStreamTests: XCTestCase {
    func testTheMessages() {
        XCTAssertEqual(
            TerraformUIMessage.decode(#"{"@level":"info","@message":"Terraform 1.17.1","type":"version","terraform":"1.17.1","ui":"1.3"}"#),
            .version(terraform: "1.17.1", ui: "1.3"))
        XCTAssertEqual(TerraformUIMessage.decode(#"{"type":"version","terraform":"9.0.0","ui":"2.0"}"#), .unknownMajor("2.0"))
        XCTAssertEqual(
            TerraformUIMessage.decode(#"{"type":"planned_change","change":{"resource":{"addr":"terraform_data.acme"},"action":"replace"}}"#),
            .plannedChange(address: "terraform_data.acme", action: "replace"))
        XCTAssertEqual(
            TerraformUIMessage.decode(#"{"type":"refresh_complete","hook":{"resource":{"addr":"terraform_data.acme"}}}"#),
            .refresh(address: "terraform_data.acme", done: true))
        XCTAssertEqual(
            TerraformUIMessage.decode(#"{"type":"change_summary","changes":{"add":1,"change":0,"import":0,"remove":1,"operation":"plan"}}"#),
            .summary(add: 1, change: 0, remove: 1, importing: 0, operation: "plan"))
        XCTAssertEqual(TerraformUIMessage.decode("panic: runtime error"), .raw("panic: runtime error"))
        XCTAssertEqual(TerraformUIMessage.decode(#"{"type":"acme_new","@level":"info","@message":"acme"}"#), .message(type: "acme_new", level: "info", text: "acme"))
    }

    func testADiagnosticKeepsTheAllowListOnly() throws {
        let line =
            #"{"@level":"error","@message":"Error: Invalid value","type":"diagnostic","diagnostic":{"severity":"error","summary":"Invalid value","detail":"bad","range":{"filename":"main.tf","start":{"line":3,"column":1,"byte":0}},"snippet":{"code":"  input = var.acme","values":[{"traversal":"var.acme","statement":"is \"acme-hunter2-SECRET\""}]}}}"#
        guard case .diagnostic(let diagnostic) = TerraformUIMessage.decode(line) else { return XCTFail() }
        XCTAssertEqual(diagnostic.summary, "Invalid value")
        XCTAssertEqual(diagnostic.file, "main.tf")
        XCTAssertEqual(diagnostic.start?.line, 3)
        XCTAssertFalse(String(reflecting: diagnostic).contains("acme-hunter2-SECRET"), "a snippet's values are never kept")
    }
}

final class TerraformPlanZipTests: XCTestCase {
    /// A zip as Terraform writes a plan: `tfstate` deflated, the lock file stored.
    static func zip(_ entries: [(name: String, data: Data, deflate: Bool)]) -> Data {
        var body = Data()
        var directory = Data()
        func le16(_ v: Int) -> Data { Data([UInt8(v & 0xff), UInt8((v >> 8) & 0xff)]) }
        func le32(_ v: Int) -> Data { Data([UInt8(v & 0xff), UInt8((v >> 8) & 0xff), UInt8((v >> 16) & 0xff), UInt8((v >> 24) & 0xff)]) }
        for entry in entries {
            var stored = entry.data
            if entry.deflate {
                var output = Data(count: entry.data.count + 1024)
                let written = output.withUnsafeMutableBytes { out in
                    entry.data.withUnsafeBytes { input in
                        compression_encode_buffer(
                            out.bindMemory(to: UInt8.self).baseAddress!, out.count, input.bindMemory(to: UInt8.self).baseAddress!, entry.data.count, nil,
                            COMPRESSION_ZLIB)
                    }
                }
                stored = output.prefix(written)
            }
            let offset = body.count
            let name = Data(entry.name.utf8)
            let method = entry.deflate ? 8 : 0
            let local: [Data] = [
                le32(0x0403_4B50), le16(20), le16(0), le16(method), le32(0), le32(0), le32(stored.count), le32(entry.data.count), le16(name.count), le16(0),
                name, stored,
            ]
            for part in local { body.append(part) }
            let central: [Data] = [
                le32(0x0201_4B50), le16(20), le16(20), le16(0), le16(method), le32(0), le32(0), le32(stored.count), le32(entry.data.count), le16(name.count),
                le16(0), le16(0), le16(0), le16(0), le32(0), le32(offset), name,
            ]
            for part in central { directory.append(part) }
        }
        let end: [Data] = [le32(0x0605_4B50), le16(0), le16(0), le16(entries.count), le16(entries.count), le32(directory.count), le32(body.count), le16(0)]
        var zip = body
        zip.append(directory)
        for part in end { zip.append(part) }
        return zip
    }

    func testLineageSerialAndTheLockFilesHash() throws {
        let state = Data(#"{"version":4,"lineage":"acme-lineage-1","serial":7,"outputs":{"db":{"value":"acme-hunter2-SECRET"}}}"#.utf8)
        let lock = Data("provider \"registry.terraform.io/hashicorp/random\" {\n  version = \"3.6.3\"\n}\n".utf8)
        let data = Self.zip([("tfplan", Data("acme".utf8), false), ("tfstate", state, true), (".terraform.lock.hcl", lock, false)])
        let facts = try XCTUnwrap(
            TerraformPlanZip.read(size: data.count) { offset, length in
                offset + length <= data.count ? data.subdata(in: offset..<(offset + length)) : nil
            })
        XCTAssertEqual(facts.lineage, "acme-lineage-1")
        XCTAssertEqual(facts.serial, 7)
        XCTAssertEqual(facts.lockFileSHA256, SHA256.hash(data: lock).map { String(format: "%02x", $0) }.joined())
        XCTAssertFalse(String(reflecting: facts).contains("acme-hunter2-SECRET"), "nothing of the state but lineage and serial")
        XCTAssertNil(TerraformPlanZip.read(size: 4) { _, _ in Data("acme".utf8) }, "not a zip: an encrypted plan says unknown")
    }

    func testFromADescriptor() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("overterm-tf-zip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("plan")
        try Self.zip([("tfstate", Data(#"{"lineage":"globex-1","serial":2}"#.utf8), true)]).write(to: url)
        let held = try XCTUnwrap(TerraformPlanFile.hold(url, limit: 1 << 20))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "held by its descriptor, the path unlinked")
        XCTAssertEqual(TerraformPlanZip.read(descriptor: held.descriptor)?.lineage, "globex-1")
        XCTAssertEqual(held.sha256, TerraformPlanFile.sha256(of: held.descriptor, size: held.size))
    }
}

final class TerraformRunFolderTests: XCTestCase {
    func testTheFolderIsPrivate() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("overterm-tf-runs-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let run = try TerraformRunFolder.makeRun(base: base)
        let process = run.deletingLastPathComponent()
        XCTAssertEqual(process.lastPathComponent, TerraformRunFolder.name())
        for folder in [process, run] {
            let mode = try FileManager.default.attributesOfItem(atPath: folder.path)[.posixPermissions] as? Int
            XCTAssertEqual(mode, 0o700, folder.path)
        }
        TerraformRunFolder.remove(run)
        XCTAssertFalse(FileManager.default.fileExists(atPath: run.path))
        // A link where the folder goes is refused, never followed.
        let other = base.appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let link = base.appendingPathComponent("ot-tf-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: other)
        XCTAssertThrowsError(try TerraformRunFolder.ensurePrivate(link))
    }

    func testTheSweepTakesOnlyTheDeadOfThisUser() {
        let names = ["ot-tf-501-100", "ot-tf-501-200", "ot-tf-502-100", "ot-tf-501-300", "acme", "ot-tf-501-x", "ot-tf-501-42"]
        let swept = TerraformRunFolder.sweepable(names, uid: 501, me: 42, alive: { $0 == 200 })
        XCTAssertEqual(swept, ["ot-tf-501-100", "ot-tf-501-300"])
    }
}

/// The stream run against stand-ins: the umask launcher, the plan file held
/// and unlinked, the exit code deciding, a line no builder made refused.
final class TerraformStreamRunTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("overterm-tf-stream-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: folder) }

    /// A terraform that streams two lines, writes its `-out` file and exits `status`.
    private func standIn(status: Int32) throws -> URL {
        let url = folder.appendingPathComponent("bin/terraform")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let script = """
            #!/bin/bash -p
            echo '{"type":"version","terraform":"1.17.1","ui":"1.3","@message":"Terraform 1.17.1"}'
            echo '{"type":"planned_change","change":{"resource":{"addr":"terraform_data.acme"},"action":"create"},"@message":"plan"}'
            for a in "$@"; do case "$a" in -out=*) printf 'PK\\003\\004acme' > "${a#-out=}";; esac; done
            exit \(status)

            """
        try Data(script.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }

    final class Collected: @unchecked Sendable {
        let lock = NSLock()
        var messages: [TerraformUIMessage] = []
    }

    func testAPlanIsHeldAndItsPathGone() throws {
        let binary = try standIn(status: 2)
        let run = try TerraformRunFolder.makeRun(base: folder.appendingPathComponent("runs"))
        let planFile = run.appendingPathComponent("plan")
        let arguments = try XCTUnwrap(TerraformCommands.plan(out: planFile.path))
        let collected = Collected()
        let outcome = try TerraformStreamRun.run(
            binary, arguments, in: folder, environment: ["PATH": "/usr/bin:/bin"], planFile: planFile,
            batch: { messages in collected.lock.withLock { collected.messages += messages } })
        XCTAssertEqual(outcome.status, 2)
        XCTAssertEqual(outcome.file?.mode, 0o600, "written under umask 077")
        XCTAssertFalse(FileManager.default.fileExists(atPath: planFile.path), "unlinked once held")
        XCTAssertEqual(collected.messages.first, .version(terraform: "1.17.1", ui: "1.3"))
        XCTAssertEqual(collected.messages.count, 2)
    }

    /// A plan file past `maxPlanBytes` (sparse: no 64 MB written): planned,
    /// never held, said as too large rather than as a failure.
    func testAPlanPastTheBoundIsTooLargeNotFailed() throws {
        let url = folder.appendingPathComponent("bin/terraform-large")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let script = """
            #!/bin/bash -p
            echo '{"type":"change_summary","changes":{"add":2000,"change":0,"remove":0,"import":0,"operation":"plan"},"@message":"Plan: 2000 to add"}'
            for a in "$@"; do case "$a" in -out=*) /bin/dd if=/dev/zero of="${a#-out=}" bs=1 count=0 seek=\(TerraformStreamRun.maxPlanBytes + 1) 2>/dev/null;; esac; done
            exit 2

            """
        try Data(script.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        let run = try TerraformRunFolder.makeRun(base: folder.appendingPathComponent("runs"))
        let planFile = run.appendingPathComponent("plan")
        let collected = Collected()
        let outcome = try TerraformStreamRun.run(
            url, try XCTUnwrap(TerraformCommands.plan(out: planFile.path)), in: folder, environment: ["PATH": "/usr/bin:/bin"], planFile: planFile,
            batch: { messages in collected.lock.withLock { collected.messages += messages } })
        XCTAssertEqual(outcome.status, 2)
        XCTAssertTrue(outcome.tooLarge)
        XCTAssertNil(outcome.file, "never held")
        XCTAssertFalse(FileManager.default.fileExists(atPath: planFile.path), "and gone")
        XCTAssertEqual(collected.messages.first, .summary(add: 2000, change: 0, remove: 0, importing: 0, operation: "plan"))
    }

    func testExitOneKeepsNothing() throws {
        let binary = try standIn(status: 1)
        let run = try TerraformRunFolder.makeRun(base: folder.appendingPathComponent("runs"))
        let planFile = run.appendingPathComponent("plan")
        let outcome = try TerraformStreamRun.run(
            binary, try XCTUnwrap(TerraformCommands.plan(out: planFile.path)), in: folder, environment: [:], planFile: planFile, batch: { _ in })
        XCTAssertEqual(outcome.status, 1)
        XCTAssertNil(outcome.file, "exit 1 is failure, whatever was written")
        XCTAssertFalse(FileManager.default.fileExists(atPath: planFile.path))
    }

    func testALineNoBuilderMadeNeverStarts() throws {
        let binary = try standIn(status: 0)
        XCTAssertThrowsError(try TerraformStreamRun.run(binary, ["apply", "-auto-approve"], in: folder, environment: [:], batch: { _ in }))
        XCTAssertThrowsError(try TerraformStreamRun.run(binary, ["plan", "-lock=false"], in: folder, environment: [:], batch: { _ in }))
    }
}

final class TerraformPlanReadingTests: XCTestCase {
    /// A plan's JSON with the sentinels planted in each path of 5.6: a
    /// sensitive variable's value, marked attributes, an unmarked copy of
    /// a sensitive value (`terraform_data`'s `output`), an unmarked
    /// `password`, an output's before, prior state, planned values, a
    /// constant value, relevant attributes, a check's problem, an action's
    /// config, an unknown key.
    static let planted = """
        {
          "format_version": "1.2", "terraform_version": "1.17.1", "applyable": true, "complete": true, "errored": false,
          "variables": {"acme_name": {"value": "acme-two"}, "acme_db_password": {"value": "acme-hunter2-SECRET"}},
          "planned_values": {"root_module": {"resources": [{"values": {"input": {"db": "acme-hunter2-SECRET"}}}]}},
          "resource_drift": [{"address": "local_file.acme_config", "mode": "managed", "type": "local_file", "name": "acme_config", "provider_name": "registry.terraform.io/hashicorp/local",
            "change": {"actions": ["delete"], "before": {"content": "x"}, "after": null, "before_sensitive": {}, "after_sensitive": false}}],
          "resource_changes": [
            {"address": "terraform_data.acme", "mode": "managed", "type": "terraform_data", "name": "acme", "provider_name": "terraform.io/builtin/terraform",
             "action_reason": "replace_because_cannot_update",
             "change": {"actions": ["delete", "create"], "replace_paths": [["triggers_replace"]],
               "before": {"id": "acme-id", "triggers_replace": "acme-one", "input": {"db": "acme-hunter2-SECRET", "password": "tok-acme-123", "name": "acme-one"}, "output": {"db": "acme-hunter2-SECRET", "password": "tok-acme-123", "name": "acme-one"}},
               "after": {"triggers_replace": "acme-two", "input": {"db": "acme-hunter2-SECRET", "password": "tok-acme-123", "name": "acme-two"}},
               "after_unknown": {"id": true, "output": true},
               "before_sensitive": {"input": {"db": true}, "output": {}}, "after_sensitive": {"input": {"db": true}}}},
            {"address": "aws_s3_bucket.acme_logs[\\"a\\"]", "mode": "managed", "type": "aws_s3_bucket", "name": "acme_logs", "index": "a", "provider_name": "registry.terraform.io/hashicorp/aws",
             "change": {"actions": ["update"], "before": {"tags": {"deployed_at": "1"}, "key_name": "acme"}, "after": {"tags": {"deployed_at": "2"}, "key_name": "acme"}, "after_unknown": {}, "before_sensitive": {}, "after_sensitive": {}}},
            {"address": "aws_s3_bucket.acme_logs[\\"b\\"]", "mode": "managed", "type": "aws_s3_bucket", "name": "acme_logs", "index": "b", "provider_name": "registry.terraform.io/hashicorp/aws",
             "change": {"actions": ["update"], "before": {"tags": {"deployed_at": "1"}}, "after": {"tags": {"deployed_at": "2"}}, "after_unknown": {}, "before_sensitive": {}, "after_sensitive": {}}},
            {"address": "random_id.acme_imported", "mode": "managed", "type": "random_id", "name": "acme_imported", "provider_name": "registry.terraform.io/hashicorp/random",
             "change": {"actions": ["no-op"], "importing": {"id": "p-9hUg"}, "before": {}, "after": {}}},
            {"address": "module.globex_worker.terraform_data.w", "previous_address": "module.globex_app.terraform_data.w", "module_address": "module.globex_worker", "mode": "managed", "type": "terraform_data", "name": "w", "provider_name": "terraform.io/builtin/terraform",
             "change": {"actions": ["no-op"], "before": {}, "after": {}}},
            {"address": "random_password.acme_db", "mode": "managed", "type": "random_password", "name": "acme_db", "provider_name": "registry.terraform.io/hashicorp/random",
             "change": {"actions": ["delete"], "before": {"result": "globex-BKPW"}, "after": null, "before_sensitive": {"result": true}, "after_sensitive": false}}
          ],
          "output_changes": {"acme_db": {"actions": ["update"], "before": "acme-hunter2-SECRET", "after": "acme-hunter2-SECRET", "before_sensitive": true, "after_sensitive": true}},
          "prior_state": {"format_version": "1.0", "terraform_version": "1.17.1", "values": {"outputs": {"acme_db": {"value": "acme-hunter2-SECRET", "sensitive": true}}}},
          "configuration": {"root_module": {
            "variables": {"acme_name": {}, "acme_db_password": {"sensitive": true, "default": "acme-hunter2-SECRET"}},
            "resources": [{"address": "terraform_data.acme", "expressions": {"triggers_replace": {"references": ["var.acme_name"]}, "input": {"constant_value": {"password": "tok-acme-123"}}}}]}},
          "relevant_attributes": [{"resource": "terraform_data.acme", "attribute": ["input", "db"]}],
          "checks": [{"address": {"to_display": "check.acme"}, "status": "fail", "instances": [{"problems": [{"message": "acme-hunter2-SECRET"}]}]}],
          "action_invocations": [{"address": "action.local_command.acme", "type": "local_command", "config_values": {"command": "echo tok-acme-123"}, "config_sensitive": {"command": true}}],
          "acme_future_key": {"secret": "acme-hunter2-SECRET"},
          "timestamp": "2026-11-12T11:00:00Z"
        }
        """
    static let sentinels = ["acme-hunter2-SECRET", "tok-acme-123", "globex-BKPW"]

    func plan() throws -> TerraformPlan { try TerraformPlan.decode(Data(Self.planted.utf8), scrub: TerraformPlan.scrub) }

    /// 5.6 rule 12: no sentinel survives decode, in the model or anything said from it.
    func testNoSentinelSurvives() throws {
        let plan = try plan()
        let sources = TerraformCauseChain.Sources.make(config: [], varFiles: [])
        var said = [
            String(reflecting: plan), TerraformPlanText.summary(plan, root: "envs/dev", file: nil), TerraformPlanText.summary(plan.forAgents(), root: "envs/dev", file: nil),
            TerraformPlanText.copySummary(plan, root: "envs/dev", workspace: "default", branch: "main @ abc1234"), String(reflecting: TerraformPlanRows.build(plan)),
        ]
        for change in plan.resourceChanges + plan.drift {
            said.append(TerraformPlanText.resource(change, plan: plan.forAgents()))
            said.append(String(reflecting: TerraformAttributeDiff.lines(change)))
            said.append(String(reflecting: TerraformCauseChain.chain(for: change, plan: plan, sources: sources, changed: [:])))
        }
        for text in said {
            for sentinel in Self.sentinels { XCTAssertFalse(text.contains(sentinel), "\(sentinel) in \(text.prefix(300))") }
        }
        XCTAssertTrue(plan.partlyUnderstood, "an unknown top-level key is said, never read")
        XCTAssertEqual(plan.unknownKeys, ["acme_future_key"])
    }

    /// A sensitive number (a PIN) and a sensitive string too short to hunt
    /// inside others, each copied into an attribute nothing marks: masked
    /// whole, by value, wherever they appear.
    func testShortSecretsAndNumbersAreMaskedByValue() throws {
        let json = """
            {
              "format_version": "1.2", "applyable": true, "complete": true,
              "variables": {"acme_pin": {"value": 73911}, "acme_code": {"value": "q7Z"}},
              "configuration": {"root_module": {"variables": {"acme_pin": {"sensitive": true}, "acme_code": {"sensitive": true}}}},
              "resource_changes": [
                {"address": "terraform_data.acme", "mode": "managed", "type": "terraform_data", "name": "acme", "provider_name": "terraform.io/builtin/terraform",
                 "change": {"actions": ["create"], "before": null,
                   "after": {"input": {"pin": 73911, "code": "q7Z", "port": 8443, "label": "q7Z-not-alone"}, "output": {"pin": 73911, "code": "q7Z"}},
                   "after_unknown": {}, "before_sensitive": false, "after_sensitive": {"input": {"pin": true, "code": true}}}}
              ]
            }
            """
        let plan = try TerraformPlan.decode(Data(json.utf8), scrub: TerraformPlan.scrub)
        let after = TerraformAttributeDiff.flatten(plan.resourceChanges[0].after)
        XCTAssertEqual(after["output.pin"], "••••••", "a sensitive number copied where nothing marks it")
        XCTAssertEqual(after["output.code"], "••••••", "a three-character secret, whole")
        XCTAssertEqual(after["input.port"], "8443", "another number stays")
        XCTAssertEqual(after["input.label"], "\"q7Z-not-alone\"", "too short to hunt inside a longer string")
        var said = [
            String(reflecting: plan), TerraformPlanText.summary(plan.forAgents(), root: "envs/dev", file: nil),
            TerraformPlanText.copySummary(plan, root: "envs/dev", workspace: "default", branch: nil),
            TerraformPlanText.resource(plan.resourceChanges[0], plan: plan.forAgents()),
        ]
        said.append(String(reflecting: TerraformAttributeDiff.lines(plan.resourceChanges[0])))
        for text in said {
            XCTAssertFalse(text.contains("73911"), text)
            XCTAssertFalse(text.contains("\"q7Z\""), text)
        }
    }

    /// A secret the scrubber would alter is redacted before it runs.
    func testRedactedBeforeScrubbing() {
        let secrets = TerraformSensitiveValues(["acme-pw-1234", "pw"])
        XCTAssertEqual(secrets.redact("url https://u:acme-pw-1234@acme.example/x"), "url https://u:••••••@acme.example/x")
        XCTAssertEqual(secrets.redact("acme-pw-1234 and acme-pw-1234."), "•••••• and ••••••.")
        XCTAssertEqual(secrets.redact("pw stays: too short to hunt"), "pw stays: too short to hunt")
        XCTAssertTrue(secrets.isSecret("pw"), "but a leaf equal to it is masked")
        XCTAssertTrue(secrets.contains("xxacme-pw-1234yy"))
        XCTAssertFalse(secrets.contains("acme-pw-123"))
        let overlapping = TerraformSensitiveValues(["acme-long-secret", "acme"])
        XCTAssertEqual(overlapping.redact("[acme-long-secret]"), "[••••••]", "the longest first")
        XCTAssertEqual(TerraformSensitiveValues.none.redact("acme"), "acme")
    }

    /// Section 10's plan: 2,000 resources, every one holding a sensitive
    /// value — 2,000 `random_password` results — copied into an unmarked
    /// attribute too, with 20 tags and a 1 KB string beside, decoded in time
    /// and masked everywhere.
    func testAGenerated2000ResourcePlanDecodesInBudget() throws {
        let data = E2ERunner.terraformPerfPlan(resources: 2_000)
        let started = Date()
        let plan = try TerraformPlan.decode(data, scrub: TerraformPlan.scrub)
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertEqual(plan.resourceChanges.count, 2_000)
        XCTAssertEqual(TerraformAttributeDiff.flatten(plan.resourceChanges[1_999].after)["output.copy"], "••••••", "the last one is masked too")
        XCTAssertFalse(String(reflecting: plan.resourceChanges[1_000]).contains("acme-pw-1000-"))
        XCTAssertFalse(String(reflecting: plan).contains("acme-pw-"), "no sensitive value anywhere in the model")
        // 0.5 s in the app as built (Section 10: the terraformPerf
        // scenario); a debug build is ten times slower. Bound here against
        // a scan per value per string, which took minutes.
        #if DEBUG
            let budget = 15.0
        #else
            let budget = 0.5
        #endif
        XCTAssertLessThan(elapsed, budget, "decoding \(data.count >> 20) MB took \(elapsed) s")
    }

    func testTheRows() throws {
        let plan = try plan()
        let rows = TerraformPlanRows.build(plan)
        XCTAssertEqual(rows.map(\.section), [.drift, .risky, .risky, .actions, .changes, .moved, .imported])
        XCTAssertEqual(rows[1].address, "terraform_data.acme", "replace first")
        XCTAssertEqual(rows[1].what, "replace (delete, then create) · can't change in place · triggers_replace forces it")
        XCTAssertEqual(rows[2].address, "random_password.acme_db")
        XCTAssertEqual(rows[4].count, 2, "the same change on two buckets, folded ×2")
        XCTAssertEqual(rows[4].what, "update · tags.deployed_at   (2 resources, same change)")
        XCTAssertEqual(rows[5].what, "moved from module.globex_app.terraform_data.w")
        XCTAssertEqual(rows[6].what, "import ← p-9hUg")
        XCTAssertEqual(TerraformPlanRows.build(plan, filter: "acme_logs").map(\.address), [#"aws_s3_bucket.acme_logs["a"]"#])
        XCTAssertEqual(TerraformPlanRows.build(plan, chips: [.delete]).filter { $0.section == .risky }.map(\.address), ["random_password.acme_db"])
        XCTAssertEqual(plan.counts.bar, "+0 ~2 -1 ±1 →1 ⇣1 ⚠1 ⚡1")
    }

    func testTheAttributesBeforeAndAfter() throws {
        let plan = try plan()
        let change = try XCTUnwrap(plan.resourceChanges.first)
        let diff = TerraformAttributeDiff.lines(change)
        let byPath = Dictionary(uniqueKeysWithValues: diff.lines.map { ($0.path, $0) })
        XCTAssertEqual(byPath["triggers_replace"]?.forces, true)
        XCTAssertEqual(byPath["triggers_replace"]?.after, "\"acme-two\"")
        let before = TerraformAttributeDiff.flatten(change.before)
        XCTAssertEqual(before["input.db"], "••••••")
        XCTAssertEqual(before["input.password"], "••••••", "an unmarked password: masked by name")
        XCTAssertNil(byPath["input.db"], "unchanged: folded into the count, whatever its mask")
        XCTAssertEqual(byPath["output.db"]?.before, "••••••", "an unmarked copy of a sensitive value: masked by value")
        XCTAssertEqual(byPath["id"]?.after, "known after apply")
        let bucket = plan.resourceChanges[1]
        XCTAssertEqual(TerraformAttributeDiff.lines(bucket).unchanged, 1, "key_name: shown unchanged, not masked")
        XCTAssertEqual(TerraformAttributeDiff.flatten(bucket.after)["key_name"], "\"acme\"", "key_name is no secret (5.6 rule 4)")
    }

    func testTheCauseChain() throws {
        let plan = try plan()
        let main = "variable \"acme_name\" {\n  type = string\n}\n\nresource \"terraform_data\" \"acme\" {\n  triggers_replace = var.acme_name\n}\n"
        let sources = TerraformCauseChain.Sources.make(
            config: [("envs/dev/main.tf", main)], varFiles: [("envs/dev/terraform.tfvars", "acme_name = \"x\"\n"), ("envs/dev/dev.tfvars", "# acme\nacme_name = \"acme-two\"\n")])
        let change = plan.resourceChanges[0]
        let links = TerraformCauseChain.chain(for: change, plan: plan, sources: sources, changed: ["envs/dev/dev.tfvars": [2]])
        XCTAssertEqual(links.map(\.text), ["triggers_replace", "var.acme_name", "envs/dev/dev.tfvars:2"], "the last var file a run loads wins")
        XCTAssertEqual(links.last?.changed, true)
        XCTAssertEqual(TerraformCauseChain.said(links), "← triggers_replace ← var.acme_name ← envs/dev/dev.tfvars:2  changed in this branch")
        let defaults = TerraformCauseChain.Sources.make(config: [("envs/dev/main.tf", "variable \"acme_name\" {\n  default = \"a\"\n}\n")], varFiles: [])
        XCTAssertEqual(TerraformCauseChain.location(of: "var.acme_name", in: defaults), .init(file: "envs/dev/main.tf", line: 2), "its default's line")
        XCTAssertEqual(sources.blocks["terraform_data.acme"], .init(file: "envs/dev/main.tf", line: 5))
        XCTAssertTrue(TerraformCauseChain.chain(for: plan.resourceChanges[1], plan: plan, sources: sources, changed: [:]).isEmpty, "updates have none (the floor)")
        let deleted = TerraformCauseChain.chain(for: plan.resourceChanges[5], plan: plan, sources: sources, changed: [:])
        XCTAssertTrue(deleted.isEmpty || deleted.allSatisfy { $0.kind == .reason })
    }

    func testAMissingVariableIsNamed() async throws {
        await MainActor.run {
            let card = TerraformRootCard(
                path: "envs/dev", name: "envs/dev", folder: URL(fileURLWithPath: "/tmp/acme/envs/dev"), kind: .root, facts: TerraformRootFacts(),
                backendSummary: "local · terraform.tfstate", identity: nil, verdict: .init(rootClass: .local, reason: "local"))
            let run = TerraformPlanRun(kind: .plan, checkout: URL(fileURLWithPath: "/tmp/acme"), card: card)
            run.absorb([
                TerraformUIMessage.decode(
                    #"{"type":"diagnostic","diagnostic":{"severity":"error","summary":"No value for required variable","detail":"The root module input variable \"acme_name\" is not set, and has no default value."}}"#
                )
            ])
            XCTAssertEqual(run.missingVariables, ["acme_name"])
            run.absorb([
                TerraformUIMessage.decode(
                    #"{"type":"diagnostic","diagnostic":{"severity":"error","summary":"Error acquiring the state lock","detail":"\#(TerraformLockTests.local.replacingOccurrences(of: "\n", with: "\\n"))"}}"#
                )
            ])
            XCTAssertEqual(run.lock?.who, "acme@globex-mac.local")
        }
    }

    @MainActor func testAWriteElsewhereMakesThePlanStale() async throws {
        let registry = TerraformRunRegistry()
        let identity = TerraformStateIdentity(product: "terraform", backend: "http", location: "127.0.0.1:9/state/acme-shared")
        let card = TerraformRootCard(
            path: "envs/shared", name: "envs/shared", folder: URL(fileURLWithPath: "/tmp/acme-bump/envs/shared"), kind: .root, facts: TerraformRootFacts(),
            backendSummary: "http", identity: identity, verdict: .init(rootClass: .remote, reason: "http"))
        let run = TerraformPlanRun(kind: .plan, checkout: URL(fileURLWithPath: "/tmp/acme-bump"), card: card)
        XCTAssertNil(run.staleReason(registry), "not planned yet")
        let finished = Date(timeIntervalSinceNow: -60)
        run.landed(try Self.record(), at: finished)
        XCTAssertEqual(run.phase, .planned)
        XCTAssertNil(run.staleReason(registry, now: finished.addingTimeInterval(1)), "fresh")
        registry.stateWritten(identity, by: "acme-plan", operation: "applied", at: finished.addingTimeInterval(-30))
        XCTAssertNil(run.staleReason(registry, now: finished.addingTimeInterval(1)), "a write before the plan finished doesn't make it stale")
        registry.stateWritten(identity, by: "acme-plan", operation: "applied", at: finished.addingTimeInterval(20))
        XCTAssertEqual(run.staleReason(registry, now: finished.addingTimeInterval(30))?.hasPrefix("applied from acme-plan at "), true)
        let other = TerraformStateIdentity(product: "terraform", backend: "http", location: "127.0.0.1:9/state/globex")
        let elsewhere = TerraformRunRegistry()
        elsewhere.stateWritten(other, by: "acme-plan", operation: "applied", at: finished.addingTimeInterval(20))
        XCTAssertNil(run.staleReason(elsewhere, now: finished.addingTimeInterval(30)), "another state's write says nothing of this plan")
        XCTAssertEqual(TerraformPaneMonitor.past("apply"), "applied")
        XCTAssertEqual(TerraformPaneMonitor.past("state rm"), "state changed")
        let line = TerraformCommandLine.parse(
            "env -i HOME='/tmp/h' PATH=/usr/bin:/bin NO_PROXY=127.0.0.1,localhost '/opt/homebrew/bin/terraform' -chdir=envs/shared apply -auto-approve -input=false",
            probable: false)
        XCTAssertEqual(line?.operation, "apply")
        XCTAssertEqual(line?.chdir, "envs/shared")
        XCTAssertEqual(line?.isWrite, true)
    }

    /// An applied plan has nothing left to apply, so no stale note — but a
    /// drift check's finding is "then" once its own Accept wrote the state.
    @MainActor func testADriftCheckAcceptedIsThen() async throws {
        let registry = TerraformRunRegistry()
        let identity = TerraformStateIdentity(product: "terraform", backend: "local", location: "/tmp/acme-2d/envs/dev/terraform.tfstate")
        let card = TerraformRootCard(
            path: "envs/dev", name: "envs/dev", folder: URL(fileURLWithPath: "/tmp/acme-2d/envs/dev"), kind: .root, facts: TerraformRootFacts(),
            backendSummary: "local", identity: identity, verdict: .init(rootClass: .local, reason: "local"))
        let run = TerraformPlanRun(kind: .plan, checkout: URL(fileURLWithPath: "/tmp/acme-2d"), card: card)
        let finished = Date(timeIntervalSinceNow: -60)
        run.landed(try Self.record(), at: finished)
        registry.stateWritten(identity, by: "acme-2d", operation: "applied", at: finished.addingTimeInterval(1))
        run.dropRecord()
        XCTAssertNil(run.staleReason(registry, now: finished.addingTimeInterval(2)), "applied: nothing to plan again for")
        XCTAssertNotNil(run.staleReason(registry, now: finished.addingTimeInterval(2), held: false), "what it found was then")
    }

    /// A held plan over a scratch file's descriptor: what `landed` needs.
    static func record(_ plan: TerraformPlan? = nil, status: Int32 = 2) throws -> TerraformPlanRecord {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("overterm-tf-record-\(UUID().uuidString)")
        try Data("PK\u{3}\u{4}acme".utf8).write(to: url)
        let fd = open(url.path, O_RDONLY | O_CLOEXEC)
        unlink(url.path)
        let plan = plan ?? TerraformPlan(formatVersion: "1.2", applyable: true, complete: true, errored: false)
        return TerraformPlanRecord(
            plan: plan, file: TerraformPlanFile(descriptor: fd, sha256: "", size: 8, mode: 0o600), binary: URL(fileURLWithPath: "/opt/acme/terraform"),
            version: "1.17.1", environment: [:], dataDir: "/tmp/acme/.terraform", workspace: "default", status: status)
    }

    @MainActor func testAStoppedWaitingRunEndsWhileTheHolderHolds() async {
        let registry = TerraformRunRegistry()
        let card = TerraformRootCard(
            path: "envs/dev", name: "envs/dev", folder: URL(fileURLWithPath: "/tmp/acme/envs/dev"), kind: .root, facts: TerraformRootFacts(),
            backendSummary: "local", identity: nil, verdict: .init(rootClass: .local, reason: "local"))
        let holder = TerraformPlanRun(kind: .plan, checkout: URL(fileURLWithPath: "/tmp/acme"), card: card)
        let queued = TerraformPlanRun(kind: .plan, checkout: URL(fileURLWithPath: "/tmp/acme-bump"), card: card)
        registry.add(holder)
        registry.add(queued)
        let first = await holder.waitTurn("acme-state", registry: registry)
        XCTAssertTrue(first)
        let waiting = Task { @MainActor in await queued.waitTurn("acme-state", registry: registry) }
        for _ in 0..<20 where !registry.isWaiting(queued.id) { await Task.yield() }
        XCTAssertEqual(queued.phase, .waiting("Waiting for the plan of envs/dev in acme"))
        queued.stop()
        let got = await waiting.value
        XCTAssertFalse(got, "out of the queue, without the turn")
        XCTAssertEqual(queued.phase, .stopped, "ended at once")
        XCTAssertTrue(registry.holder(of: "acme-state") === holder, "the holder still holds")
        XCTAssertFalse(registry.isWaiting(queued.id))
        registry.release("acme-state")
        XCTAssertNil(registry.holder(of: "acme-state"), "nobody left in the queue takes it")
    }

    @MainActor func testTheQueueTakesTurns() async {
        let registry = TerraformRunRegistry()
        let card = TerraformRootCard(
            path: "envs/dev", name: "envs/dev", folder: URL(fileURLWithPath: "/tmp/acme/envs/dev"), kind: .root, facts: TerraformRootFacts(),
            backendSummary: "local", identity: nil, verdict: .init(rootClass: .local, reason: "local"))
        let first = TerraformPlanRun(kind: .plan, checkout: URL(fileURLWithPath: "/tmp/acme"), card: card)
        let second = TerraformPlanRun(kind: .plan, checkout: URL(fileURLWithPath: "/tmp/acme-bump"), card: card)
        registry.add(first)
        registry.add(second)
        await registry.acquire("acme-state", for: first)
        XCTAssertTrue(registry.holder(of: "acme-state") === first)
        var secondHas = false
        let waiting = Task { @MainActor in
            await registry.acquire("acme-state", for: second)
            secondHas = true
        }
        await Task.yield()
        XCTAssertFalse(secondHas, "one run per state at a time")
        registry.release("acme-state")
        await waiting.value
        XCTAssertTrue(secondHas)
        XCTAssertTrue(registry.holder(of: "acme-state") === second)
        registry.release("acme-state")
        XCTAssertNil(registry.holder(of: "acme-state"))
    }
}

final class TerraformRisksTests: XCTestCase {
    func testWhatACodeRunsOrReaches() {
        let text = """
            data "external" "acme" {
              program = ["sh", "x"]
            }
            data "http" "acme" {
              url = "https://acme.example"
            }
            data "terraform_remote_state" "net" {
              backend = "s3"
            }
            resource "terraform_data" "acme" {
              provisioner "local-exec" {
                command = "echo"
              }
            }
            module "net" {
              source = "git::https://example.test/acme-net.git?ref=main"
            }
            """
        let config = TerraformConfigFacts.read([text])
        let lock = [TerraformLockFile.Provider("registry.terraform.io/hashicorp/random")!, TerraformLockFile.Provider("registry.terraform.io/acme/acme")!]
        let base = TerraformRunRisks.Base(config: TerraformConfigFacts.read(["data \"external\" \"acme\" {\n}\n"]), lockProviders: [lock[0]])
        let kinds = TerraformRunRisks.risks(config: config, lockProviders: lock).map(\.kind)
        XCTAssertTrue([.command, .fetch, .provisioner, .remoteState, .providerAdded, .moduleChanged].allSatisfy(kinds.contains))
        let fresh = TerraformRunRisks.new(config: config, lockProviders: lock, base: base)
        XCTAssertFalse(fresh.contains { $0.kind == .command }, "data.external was there before")
        XCTAssertTrue(fresh.contains { $0 == .init(kind: .providerAdded, detail: "acme/acme") })
        XCTAssertFalse(fresh.contains { $0 == .init(kind: .providerAdded, detail: "hashicorp/random") })
        XCTAssertTrue(fresh.contains { $0.kind == .moduleChanged })
        XCTAssertTrue(TerraformRunRisks.new(config: TerraformConfigFacts.read(["resource \"random_pet\" \"a\" {}\n"]), lockProviders: lock, base: nil).isEmpty)
    }

    func testWhenAPlanAsks() {
        let risk = TerraformRunRisk(kind: .command, detail: "data.external")
        func ask(_ cls: TerraformClass = .local, first: Bool = false, mine: Bool? = true, fresh: [TerraformRunRisk] = [], agent: String? = nil) -> TerraformPlanGate.Question? {
            TerraformPlanGate.question(
                root: "envs/prod", workspace: "default", rootClass: cls, profile: "acme-prod-admin", firstOnProduction: first, authoredByPerson: mine,
                newRisks: fresh, allRisks: [risk], agent: agent)
        }
        XCTAssertNil(ask(), "a plan of your own code with nothing new runs on the click")
        XCTAssertNil(ask(.production), "production asks only its first plan per session")
        XCTAssertEqual(ask(.production, first: true)?.detail.contains("AWS_PROFILE acme-prod-admin"), true)
        XCTAssertEqual(ask(.production, first: true)?.production, true)
        XCTAssertEqual(ask(mine: false)?.detail.contains("data.external"), true, "code you didn't write: always, with the risk list")
        XCTAssertNotNil(ask(fresh: [risk]), "risks new against the base branch")
        XCTAssertEqual(ask(agent: "Claude Code")?.title, "Let the agent plan envs/prod?")
    }

    func testInitsFetchList() {
        let config = TerraformConfigFacts.read([
            """
            terraform {
              required_providers {
                random = {
                  source = "hashicorp/random"
                }
                acme = {
                  source = "acme/acme"
                }
              }
            }
            module "a" {
              source  = "acme/net/aws"
              version = "1.2.3"
            }
            module "b" {
              source  = "acme/net/aws"
            }
            module "c" {
              source = "git::https://example.test/acme.git?ref=main"
            }
            module "d" {
              source = "git::https://example.test/acme.git?ref=v1.2.0"
            }
            module "e" {
              source = "./modules/e"
            }
            """
        ])
        let items = TerraformInitPlan.items(config: config, lockProviders: [TerraformLockFile.Provider("registry.terraform.io/hashicorp/random")!])
        let flags = Dictionary(items.map { ($0.source + ($0.version ?? ""), $0.flag) }, uniquingKeysWith: { a, _ in a })
        XCTAssertNil(flags["hashicorp/random"] ?? nil)
        XCTAssertNotNil(flags["acme/acme"] ?? nil, "not in the lock file")
        XCTAssertNil(flags["acme/net/aws1.2.3"] ?? nil)
        XCTAssertEqual(TerraformInitPlan.moduleFlag("acme/net/aws", version: nil), "no version: the newest is fetched")
        XCTAssertEqual(TerraformInitPlan.moduleFlag("acme/net/aws", version: "~> 1.2"), "version ~> 1.2 isn't exact")
        XCTAssertEqual(TerraformInitPlan.moduleFlag("git::https://example.test/acme.git?ref=main", version: nil)?.hasPrefix("a branch ref (main)"), true)
        XCTAssertNil(TerraformInitPlan.moduleFlag("git::https://example.test/acme.git?ref=v1.2.0", version: nil))
        XCTAssertEqual(TerraformInitPlan.moduleFlag("http://example.test/acme.zip", version: nil), "fetched over plain HTTP")
        XCTAssertFalse(items.contains { $0.source == "./modules/e" }, "a local module fetches nothing")
        XCTAssertTrue(TerraformInitPlan.offersCache(answered: false, worktreesWithRoots: 2, userConfiguresCLI: false))
        XCTAssertFalse(TerraformInitPlan.offersCache(answered: true, worktreesWithRoots: 2, userConfiguresCLI: false))
        XCTAssertFalse(TerraformInitPlan.offersCache(answered: false, worktreesWithRoots: 1, userConfiguresCLI: false))
        XCTAssertFalse(TerraformInitPlan.offersCache(answered: false, worktreesWithRoots: 3, userConfiguresCLI: true), "the user's own CLI config: never")
    }

    func testTheBriefOfALock() throws {
        let lock = try XCTUnwrap(TerraformLockInfo.parse(summary: "Error acquiring the state lock", detail: TerraformLockTests.local))
        let brief = TerraformAgentBrief.run(
            operation: "plan", diagnostics: [], lock: lock, log: ["Error: Error acquiring the state lock", "password=acme-hunter2-SECRET"],
            root: .init(name: "envs/shared", workspace: "default", backend: "http · 127.0.0.1/state/acme-shared", rootClass: .remote), checkout: "/tmp/acme")
        XCTAssertTrue(brief.text.contains("acme@globex-mac.local"))
        XCTAssertTrue(brief.message.contains("Don't run force-unlock"))
        XCTAssertFalse(brief.text.contains("acme-hunter2-SECRET"), "every word through Secrets")
    }
}
