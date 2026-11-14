import XCTest

@testable import Overterm

/// Force unlock (analysis 2.5, 4.10, D-10, stage 2e): the two lines it
/// runs and nothing like them, the probe's answer read against the lock
/// parsed, where it is offered, and the sheet.
final class TerraformUnlockTests: XCTestCase {
    /// `state rm -dry-run`'s stderr, Terraform 1.17.1 against
    /// `FakeTerraformBackend` holding another machine's lock (captured by
    /// `TerraformRealBackendTests`).
    static let held = """

        Error: Error acquiring the state lock

        Error message: HTTP remote state already locked:
        ID=5b1d0c7e-acme-0000-0000-00000000beef
        Lock Info:
          ID:        5b1d0c7e-acme-0000-0000-00000000beef
          Path:
          Operation: OperationTypeApply
          Who:       ci@globex-runner-9
          Version:   1.17.1
          Created:   2026-11-12 19:24:59.92231 +0000 UTC
          Info:


        Terraform acquires a state lock to protect the state from being written
        by multiple users at the same time. Please resolve the issue above and try
        again. For most commands, you can disable locking with the "-lock=false"
        flag, but this is not recommended.

        """

    /// The same on an s3 backend, boxed as a terminal shows it.
    static let boxed = """
        ╷
        │ Error: Error acquiring the state lock
        │
        │ Error message: operation error S3: PutObject, https response error StatusCode: 412
        │ Lock Info:
        │   ID:        8a3c1e52-acme-0000-0000-0000000f00d5
        │   Path:      acme-tfstate/prod/network.tfstate
        │   Operation: OperationTypeApply
        │   Who:       ci@globex-runner-7
        │   Version:   1.17.1
        │   Created:   2026-11-08 09:00:12.353924 +0000 UTC
        │   Info:
        │
        │ Terraform acquires a state lock to protect the state from being written
        │ by multiple users at the same time.
        ╵
        """

    static let empty = "No state file was found!\n\nState management commands require a state file.\n"

    private var parsed: TerraformLockInfo {
        TerraformLockInfo(id: "5b1d0c7e-acme-0000-0000-00000000beef", who: "ci@globex-runner-9", http: true)
    }

    // MARK: The lines

    func testTheTwoLinesAndNothingLikeThem() {
        XCTAssertEqual(
            TerraformCommands.lockProbe, ["state", "rm", "-dry-run", "-lock=true", "-lock-timeout=0s", "-no-color", "terraform_data.overterm_lock_probe"])
        XCTAssertEqual(TerraformCommands.forceUnlock(id: "8a3c1e52-acme"), ["force-unlock", "-force", "-no-color", "8a3c1e52-acme"])
        XCTAssertTrue(TerraformCommands.all.contains(TerraformCommands.lockProbe))
        XCTAssertNil(TerraformCommands.refusal(TerraformCommands.lockProbe))
        XCTAssertNil(TerraformCommands.refusal(TerraformCommands.forceUnlock(id: "8a3c1e52-acme")!))
        for id in ["", "-force", "acme lock", "acme\u{202E}lock", "acme\nlock", "é", String(repeating: "a", count: 257)] {
            XCTAssertNil(TerraformCommands.forceUnlock(id: id), id)
        }
        let refused: [[String]] = [
            ["state", "rm", "a.b"], ["state", "rm", "-dry-run", "a.b"], ["state", "rm", "-lock=true", "-lock-timeout=0s", "-no-color", "terraform_data.overterm_lock_probe"],
            ["state", "rm", "-dry-run", "-lock=true", "-lock-timeout=0s", "-no-color", "aws_db_instance.acme"],
            ["state", "rm", "-dry-run", "-lock=false", "-lock-timeout=0s", "-no-color", "terraform_data.overterm_lock_probe"],
            ["state", "list"], ["state", "pull"], ["force-unlock", "8a3c"], ["force-unlock", "8a3c", "-force"], ["force-unlock", "-force", "8a3c"],
            ["force-unlock", "-force", "-no-color", "-chdir=x"], ["force-unlock", "-force", "-no-color", "a", "b"],
            ["-chdir=envs/prod", "force-unlock", "-force", "-no-color", "8a3c"],
        ]
        for line in refused { XCTAssertNotNil(TerraformCommands.refusal(line), "\(line)") }
        // No line that locks says -lock=false; the probe never plans.
        XCTAssertFalse(TerraformCommands.lockProbe.contains("plan"))
    }

    func testWhereItIsOffered() {
        for type in ["http", "s3", "gcs", "azurerm", "kubernetes", "pg"] {
            XCTAssertNil(TerraformProcessCheck.refused(.forceUnlock, backendType: type), type)
        }
        XCTAssertEqual(TerraformProcessCheck.refused(.forceUnlock, backendType: "local"), TerraformProcessCheck.localUnlockRefusal)
        XCTAssertNotNil(TerraformProcessCheck.refused(.forceUnlock, backendType: "cloud"))
        XCTAssertNotNil(TerraformProcessCheck.refused(.forceUnlock, backendType: "remote"))
        // Every class: a stale lock blocks the person's own CI (5.3).
        for rootClass in TerraformClass.allCases {
            XCTAssertNil(TerraformProcessCheck.refused(.forceUnlock, rootClass: rootClass), "\(rootClass)")
        }
        // Plan and init stay as they were on these backends.
        XCTAssertNil(TerraformProcessCheck.refused(.plan, backendType: "local"))
    }

    // MARK: The probe

    func testTheLockReadFromText() throws {
        let plain = try XCTUnwrap(TerraformLockInfo.parse(text: Self.held))
        XCTAssertEqual(plain.id, "5b1d0c7e-acme-0000-0000-00000000beef")
        XCTAssertEqual(plain.who, "ci@globex-runner-9")
        XCTAssertEqual(plain.operation, "OperationTypeApply")
        XCTAssertTrue(plain.http)
        XCTAssertNotNil(plain.created)
        let boxed = try XCTUnwrap(TerraformLockInfo.parse(text: Self.boxed))
        XCTAssertEqual(boxed.id, "8a3c1e52-acme-0000-0000-0000000f00d5")
        XCTAssertEqual(boxed.path, "acme-tfstate/prod/network.tfstate")
        XCTAssertFalse(boxed.http)
        XCTAssertNil(TerraformLockInfo.parse(text: Self.empty))
        XCTAssertNil(TerraformLockInfo.parse(text: "Error: No valid credential sources found\n"))
    }

    func testTheProbeAgainstTheLockParsed() {
        guard case .held(let holder) = TerraformUnlock.probe(parsed: parsed, status: 1, stderr: Self.held) else { return XCTFail("held") }
        XCTAssertEqual(holder.who, "ci@globex-runner-9")
        XCTAssertNil(TerraformUnlock.refusal(.held(holder), parsed: parsed))

        let other = TerraformUnlock.probe(parsed: parsed, status: 1, stderr: Self.boxed)
        guard case .changedHands(let now) = other else { return XCTFail("changed hands") }
        XCTAssertEqual(now.id, "8a3c1e52-acme-0000-0000-0000000f00d5")
        let why = TerraformUnlock.refusal(other, parsed: parsed) ?? ""
        XCTAssertTrue(why.hasPrefix("The lock changed hands: Locked by ci@globex-runner-7"), why)
        XCTAssertTrue(why.contains("not 5b1d0c7e-acme-0000-0000-00000000beef"), why)
        XCTAssertTrue(why.contains("Nothing was unlocked"), why)

        XCTAssertEqual(TerraformUnlock.probe(parsed: parsed, status: 0, stderr: ""), .free)
        XCTAssertEqual(TerraformUnlock.probe(parsed: parsed, status: 1, stderr: Self.empty), .free, "state rm locks before it reads")
        XCTAssertEqual(TerraformUnlock.refusal(.free, parsed: parsed), "The lock was released meanwhile: nothing to unlock. Plan again.")

        let failed = TerraformUnlock.probe(parsed: parsed, status: 1, stderr: "╷\n│ Error: No valid credential sources found\n╵\n")
        XCTAssertEqual(failed, .failed("No valid credential sources found"))
        XCTAssertTrue(TerraformUnlock.refusal(failed, parsed: parsed)?.contains("nothing was unlocked") == true)
    }

    func testTheUnlocksAnswer() {
        XCTAssertNil(TerraformUnlock.unlockFailure(status: 0, stderr: ""))
        XCTAssertEqual(
            TerraformUnlock.unlockFailure(status: 1, stderr: "Error: Failed to unlock state: HTTP error: 409\n"),
            "terraform force-unlock failed: Failed to unlock state: HTTP error: 409")
        // Interrupted: neither unlocked nor "nothing was unlocked".
        XCTAssertNil(TerraformUnlock.interrupted(status: 0, timedOut: false, stoppedMeanwhile: false))
        XCTAssertNil(TerraformUnlock.interrupted(status: 1, timedOut: false, stoppedMeanwhile: false))
        for (status, timedOut, stopped) in [(Int32(0), false, true), (1, true, false), (130, false, false)] {
            let said = TerraformUnlock.interrupted(status: status, timedOut: timedOut, stoppedMeanwhile: stopped) ?? ""
            XCTAssertTrue(said.contains("may or may not have been removed"), said)
        }
    }

    // MARK: The sheet

    func testTheSheet() throws {
        let created = try XCTUnwrap(TerraformLockInfo.date("2026-11-08 09:00:12 +0000 UTC"))
        let now = created.addingTimeInterval(3 * 3_600 + 60)
        let lock = TerraformLockInfo(
            id: "8a3c1e52-acme", operation: "OperationTypeApply", who: "ci@globex-runner-7", version: "1.17.1", created: created, http: true)
        let root = TerraformUnlock.Root(name: "envs/prod", rootClass: .production, backend: "http · 127.0.0.1/state/acme-prod", workspace: "default", worktree: "acme-infra")
        let sheet = TerraformUnlock.sheet(root: root, lock: lock, now: now, timeZone: TimeZone(identifier: "UTC")!)
        XCTAssertEqual(sheet.title, "Force unlock envs/prod's state?")
        XCTAssertEqual(sheet.typedName, "envs/prod")
        XCTAssertTrue(sheet.production)
        XCTAssertEqual(sheet.button, "Force Unlock")
        XCTAssertTrue(sheet.scope.hasPrefix("PRODUCTION · envs/prod · workspace default"))
        let lines = sheet.detail.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.first, "Locked by ci@globex-runner-7 since 09:00 (an apply, Terraform 1.17.1).")
        XCTAssertEqual(lines[1], "Lock ID 8a3c1e52-acme · held 3 h")
        XCTAssertTrue(lines.contains(TerraformUnlock.warning))
        XCTAssertTrue(lines.contains(TerraformUnlock.httpWarning), "the http backend's empty UNLOCK said")
        XCTAssertEqual(lines.last, "terraform force-unlock -force 8a3c1e52-acme")

        var s3 = lock
        s3.http = false
        var staging = root
        staging.rootClass = .remote
        staging.workspace = "acme-eu"
        let other = TerraformUnlock.sheet(root: staging, lock: s3, now: now, note: "No Terraform is running on this Mac in envs/prod.")
        XCTAssertEqual(other.typedName, "envs/prod@acme-eu", "typed on every class, the workspace with it")
        XCTAssertFalse(other.production)
        XCTAssertFalse(other.detail.contains(TerraformUnlock.httpWarning))
        XCTAssertTrue(other.detail.contains("No Terraform is running on this Mac"))
    }

    // MARK: Who may hold it

    /// Refused before anything runs: only a lock a plan shown in this
    /// window was refused by, not while it plans again, never the local
    /// backend's or HCP's lock, never while Overterm's own run holds the state.
    func testRefusedBeforeAnythingRuns() {
        func refusal(hasLock: Bool = true, shown: Bool = true, going: Bool = false, backend: String = "http", busy: String? = nil) -> String? {
            TerraformUnlock.refusalBefore(hasLock: hasLock, shown: shown, going: going, backendType: backend, rootClass: .production, busy: busy)
        }
        XCTAssertNil(refusal())
        let offered = "Force unlock is offered only for a lock a plan in this window was refused by."
        XCTAssertEqual(refusal(hasLock: false), offered)
        XCTAssertEqual(refusal(shown: false), offered, "a run no longer the one in this window's pane")
        XCTAssertEqual(refusal(going: true), offered, "not while it plans again")
        XCTAssertEqual(refusal(backend: "local"), TerraformProcessCheck.localUnlockRefusal)
        XCTAssertNotNil(refusal(backend: "remote"))
        XCTAssertNotNil(refusal(backend: "cloud"))
        let busy = refusal(busy: "The plan of envs/shared in acme-live is running on this state.")
        XCTAssertEqual(busy?.hasPrefix("The plan of envs/shared in acme-live"), true)
        XCTAssertEqual(busy?.contains("never force it"), true)
        XCTAssertEqual(refusal(shown: false, busy: "x")?.hasPrefix("Force unlock is offered only"), true)
    }

    /// A live terraform on the same state is the holder, wherever it runs:
    /// the same identity in any folder, the root's own folder, the same
    /// root in another worktree; another root's state is not.
    func testTheHolderAmongLiveTerraforms() {
        let identity = TerraformStateIdentity(product: "terraform", backend: "http", location: "127.0.0.1:9/state/acme-shared")
        let other = TerraformStateIdentity(product: "terraform", backend: "http", location: "127.0.0.1:9/state/globex-net")
        let root = "/w/acme-live/envs/shared"
        func live(_ folder: String?, _ identity: TerraformStateIdentity?) -> TerraformUnlock.Live {
            TerraformUnlock.Live(pid: 42, folder: folder, identity: identity, operation: "apply", inPane: true)
        }
        func holds(_ processes: [TerraformUnlock.Live], path: String = "envs/shared") -> Bool {
            TerraformUnlock.holder(among: processes, identity: identity, root: root, path: path) != nil
        }
        XCTAssertTrue(holds([live("/w/acme-live-bump/envs/shared", identity)]), "another worktree's checkout of the same state")
        XCTAssertTrue(holds([live("/w/elsewhere/stacks/shared-copy", identity)]), "the same state under another folder")
        XCTAssertTrue(holds([live(nil, identity)]), "a pane's identity, as the monitor resolved it")
        XCTAssertTrue(holds([live(root, nil)]), "the root itself, its state unreadable")
        XCTAssertTrue(holds([live("/w/acme-live-bump/envs/shared", nil)]), "the same root in another worktree, its state unreadable")
        XCTAssertFalse(holds([live("/w/acme-live/envs/shared-eu", other)]), "a neighbour's folder name isn't this root")
        XCTAssertFalse(holds([live("/w/acme-live/envs/net", other)]))
        XCTAssertFalse(holds([live("/w/acme-live", nil)], path: "."), "the checkout's top matches only by identity or folder")
        XCTAssertFalse(holds([]))
        let said = TerraformUnlock.liveRefusal(live("/w/acme-live-bump/envs/shared", identity), name: "envs/shared")
        XCTAssertTrue(said.contains("terraform apply") && said.contains("nothing was unlocked"), said)
    }

    /// The sheet's note claims only what was looked at.
    func testTheNoteAndTheHTTPWarning() {
        XCTAssertNil(TerraformUnlock.note(isThisMac: false, name: "envs/shared"))
        let note = TerraformUnlock.note(isThisMac: true, name: "envs/shared") ?? ""
        XCTAssertTrue(note.contains("another user") && note.contains("every worktree"), note)
        let plain = TerraformLockInfo(id: "5b1d0c7e", who: "ci@globex-runner-9", http: false)
        XCTAssertTrue(TerraformUnlock.isHTTP(holder: plain, parsed: plain, backendType: "http"), "the root's backend says http, whatever the text")
        XCTAssertTrue(TerraformUnlock.isHTTP(holder: parsed, parsed: plain, backendType: "s3"))
        XCTAssertFalse(TerraformUnlock.isHTTP(holder: plain, parsed: plain, backendType: "s3"))
    }

    /// A terraform running in a second worktree's checkout of the same
    /// http state — here under another folder name, so only its state says
    /// it — is found by the scan of this user's processes and resolved to
    /// the run's identity: the force unlock is refused.
    func testATerraformInASecondWorktreeOfTheSameStateIsFound() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("overterm-tf-live-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let backend = "terraform {\n  backend \"http\" {\n    address = \"http://127.0.0.1:9/state/acme-shared\"\n  }\n}\n"
        let main = folder.appendingPathComponent("acme-live/envs/shared", isDirectory: true)
        let second = folder.appendingPathComponent("acme-live-bump/stacks/acme-shared-copy", isDirectory: true)
        for (checkout, root) in [("acme-live", main), ("acme-live-bump", second)] {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try backend.write(to: root.appendingPathComponent("main.tf"), atomically: true, encoding: .utf8)
            try "gitdir: elsewhere\n".write(to: folder.appendingPathComponent(checkout).appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        }
        let facts = TerraformRootFacts.read(root: main, checkout: folder.appendingPathComponent("acme-live"))
        let identity = try XCTUnwrap(TerraformStateIdentity.of(backend: facts.backend, workspace: facts.workspace, root: main))

        // A stand-in named terraform, run by bash as the recording wrapper is: `terraform apply`, waiting.
        let script = folder.appendingPathComponent("bin/terraform")
        try FileManager.default.createDirectory(at: script.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/bash\ntrap 'kill $child; exit 0' TERM\nsleep 30 &\nchild=$!\nwait $child\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path, "apply"]
        process.currentDirectoryURL = second
        process.environment = ["PATH": "/usr/bin:/bin", "HOME": folder.path]
        try process.run()
        defer {
            process.terminate()
            process.waitUntilExit()
        }
        var found: TerraformProcess?
        for _ in 0..<50 where found == nil {
            found = TerraformLiveProcesses.scan(limit: 512).first { $0.pid == process.processIdentifier }
            if found == nil { Thread.sleep(forTimeInterval: 0.1) }
        }
        let terraform = try XCTUnwrap(found, "the scan finds the stand-in")
        XCTAssertEqual(terraform.line.operation, "apply")
        let live = TerraformLiveProcesses.resolve(terraform, inPane: false)
        XCTAssertEqual(live.identity, identity, "its folder's backend resolved to the same state")
        XCTAssertEqual(live.folder, second.resolvingSymlinksInPath().path, "its folder as the kernel says it")
        let holder = TerraformUnlock.holder(among: [live], identity: identity, root: main.standardizedFileURL.path, path: "envs/shared")
        XCTAssertEqual(holder?.pid, process.processIdentifier)
        XCTAssertNil(
            TerraformUnlock.holder(
                among: [live], identity: TerraformStateIdentity(product: "terraform", backend: "http", location: "127.0.0.1:9/state/globex-net"),
                root: main.standardizedFileURL.path, path: "envs/shared"), "another state's root isn't refused for it")
    }

    // MARK: Through the wrapper

    /// The probe and the unlock run through `TerraformRun` as built — the
    /// recording wrapper sees exactly those lines, in the guarded
    /// environment — and the probe's answer is read as above.
    func testTheProbeAndTheUnlockRunAsBuilt() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("overterm-tf-unlock-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let root = folder.appendingPathComponent("acme-infra/envs/prod", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let standIn = folder.appendingPathComponent("stand-in/terraform")
        try TerraformRecorder.writeStandIn(at: standIn, stderr: Self.held, exitCode: 1)
        let recorder = try TerraformRecorder.make(in: folder.appendingPathComponent("recorder"), target: standIn.path)
        let scratch = try TerraformGuards.prepareScratch(at: folder.appendingPathComponent("scratch"))
        var base = scratch.environment
        base["TF_CLI_ARGS_state_rm"] = "-lock=false"
        let environment = TerraformEnvironment.build(base: base, purpose: .run(workspace: "default", pluginCache: nil), root: root, scratch: scratch)
        let probe = try await TerraformRun.short(recorder.wrapper, TerraformCommands.lockProbe, in: root, environment: environment)
        guard case .held = TerraformUnlock.probe(parsed: parsed, status: probe.status, stderr: probe.stderr) else { return XCTFail(probe.stderr) }
        _ = try await TerraformRun.short(recorder.wrapper, XCTUnwrap(TerraformCommands.forceUnlock(id: parsed.id)), in: root, environment: environment)
        do {
            _ = try await TerraformRun.short(recorder.wrapper, ["state", "rm", "aws_db_instance.acme"], in: root, environment: environment)
            XCTFail("a state rm no builder made ran")
        } catch let failure as TerraformRun.Failure {
            guard case .refused = failure else { return XCTFail("\(failure)") }
        }
        let calls = recorder.calls()
        XCTAssertEqual(calls.map(\.arguments), [TerraformCommands.lockProbe, ["force-unlock", "-force", "-no-color", parsed.id]])
        for call in calls {
            XCTAssertFalse(call.names.contains("TF_CLI_ARGS_state_rm"), "a hostile TF_CLI_ARGS never reaches it")
            XCTAssertEqual(call.values["TF_WORKSPACE"], "default")
            XCTAssertEqual(call.values["CHECKPOINT_DISABLE"], "1")
        }
    }
}
