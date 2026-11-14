import Foundation
import XCTest

/// End-to-end: launches the built Overterm.app once per scenario
/// (OVERTERM_E2E=<name>, see Sources/Overterm/E2E/E2ERunner.swift) and
/// fails with whatever checks the app reported failing.
///
/// Opt-in — each scenario opens a real window for a few seconds:
///     make e2e      (= make app && OVERTERM_E2E_TESTS=1 swift test --filter OvertermE2ETests)
/// The runs are isolated from the real app's state (AppEnvironment): own
/// defaults suite, temp support dir, no notifications, never activated.
final class E2ETests: XCTestCase {
    private static let app = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Overterm.app/Contents/MacOS/Overterm")

    /// The display kept awake for the whole run: a full run takes about 14
    /// minutes, and on a Mac whose display sleeps after 10 every scenario
    /// after that would read a black window. Released at the end; only
    /// while E2E runs (it is opt-in).
    nonisolated(unsafe) private static var awake: NSObjectProtocol?

    override class func setUp() {
        super.setUp()
        guard ProcessInfo.processInfo.environment["OVERTERM_E2E_TESTS"] == "1", awake == nil else { return }
        awake = ProcessInfo.processInfo.beginActivity(
            options: [.idleDisplaySleepDisabled, .userInitiated], reason: "Overterm's E2E scenarios read the window's pixels")
    }

    override class func tearDown() {
        if let awake { ProcessInfo.processInfo.endActivity(awake) }
        awake = nil
        super.tearDown()
    }

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["OVERTERM_E2E_TESTS"] == "1", "E2E is opt-in: make e2e")
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: Self.app.path), "build the app first: make app")
    }

    /// Returns all the app printed (and, with `stderr`, its standard error
    /// is written to that file).
    @discardableResult
    private func run(_ scenario: String, env extra: [String: String] = [:], timeout: TimeInterval = 120, stderr: URL? = nil, attempt: Int = 0) throws
        -> String
    {
        let process = Process()
        process.executableURL = Self.app
        var env = ProcessInfo.processInfo.environment
        env["OVERTERM_E2E"] = scenario
        env.removeValue(forKey: "OVERTERM_E2E_TESTS")
        // No credential of the shell's reaches a scenario's panes; the app
        // refuses to run with one (TerraformGuards.refusedCredentials).
        for name in env.keys where Self.carriesCredential(name) { env.removeValue(forKey: name) }
        // Nor any of git's: run from a git hook or `git bisect run`, a
        // scenario's shells and its own git worked in this checkout's .git
        // (GIT_DIR) — once setting core.bare there.
        for name in env.keys where name.hasPrefix("GIT_") { env.removeValue(forKey: name) }
        extra.forEach { env[$0.key] = $0.value }
        process.environment = env
        let out = Pipe()
        process.standardOutput = out
        if let stderr {
            FileManager.default.createFile(atPath: stderr.path, contents: nil)
            process.standardError = try FileHandle(forWritingTo: stderr)
        } else {
            process.standardError = FileHandle.nullDevice
        }
        // Drained as it comes: a pipe holds 64 KB, and a scenario printing
        // more would block on its next line until it timed out.
        // An empty read is the end: the handler stops itself and says so, so
        // the last chunk is appended by the handler alone, in order — never
        // by a second read racing a handler block still running.
        let collected = Collected()
        let ended = DispatchSemaphore(value: 0)
        out.fileHandleForReading.readabilityHandler = { @Sendable handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                ended.signal()
                return
            }
            collected.append(data)
        }
        try process.run()

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        var left: [pid_t] = []
        if process.isRunning {
            // What it started (each context's kubectl proxy, in a group of
            // its own) outlives a terminated app: found first, by parent.
            left = Self.descendants(of: process.processIdentifier)
            process.terminate()
            XCTFail("\(scenario): timed out after \(Int(timeout)) s")
        }
        process.waitUntilExit()
        // Then ended, each by its exact pid — never by a pattern.
        for pid in left where kill(pid, 0) == 0 { kill(pid, SIGTERM) }
        // A child of the app still holding the pipe would keep it open: bounded.
        if ended.wait(timeout: .now() + 10) == .timedOut { out.fileHandleForReading.readabilityHandler = nil }
        let printed = String(decoding: collected.data, as: UTF8.self)
        let lines = printed.split(separator: "\n").map(String.init).filter { $0.hasPrefix("E2E ") }
        // Dead before a line, by a signal: launched in quick succession,
        // macOS's LaunchServices connection can trap in NSApplication's
        // own +initialize (_xpc_api_misuse) before any of the app runs.
        // Not a result: launched once more.
        if lines.isEmpty, process.terminationReason == .uncaughtSignal, attempt == 0 {
            Thread.sleep(forTimeInterval: 1)
            return try run(scenario, env: extra, timeout: timeout, stderr: stderr, attempt: 1)
        }
        let passed = lines.filter { $0.hasPrefix("E2E PASS") }
        let failed = lines.filter { $0.hasPrefix("E2E FAIL") }
        for failure in failed { XCTFail("\(scenario): \(failure.dropFirst("E2E FAIL ".count))") }
        XCTAssertTrue(lines.contains { $0.hasPrefix("E2E DONE") }, "\(scenario): never finished — crashed? exit \(process.terminationStatus)")
        // A scenario that needs something this machine hasn't got (a test
        // server) says so, and is skipped rather than failed.
        if passed.isEmpty, failed.isEmpty, let skip = lines.first(where: { $0.hasPrefix("E2E SKIP") }) {
            throw XCTSkip(String(skip.dropFirst("E2E SKIP ".count)))
        }
        XCTAssertFalse(passed.isEmpty, "\(scenario): no checks ran")
        print("\(scenario): \(passed.count) checks passed")
        return printed
    }

    /// `TerraformGuards.isCredential`'s rule, by name (this target doesn't
    /// link the app): should the two drift, the app's refusal names what
    /// was missed.
    private static func carriesCredential(_ name: String) -> Bool {
        let upper = name.uppercased()
        let prefixes = [
            "AWS_", "GOOGLE_", "CLOUDSDK_", "ARM_", "AZURE_", "TF_TOKEN_", "TF_CLOUD_", "TF_VAR_", "TF_HTTP_", "VAULT_", "CONSUL_HTTP_", "TFE_",
            "OCI_", "ALICLOUD_", "CLOUDFLARE_", "DIGITALOCEAN_", "HCLOUD_", "LINODE_", "SCW_", "KUBE_", "HELM_",
        ]
        let names: Set<String> = [
            "KUBECONFIG", "TF_REATTACH_PROVIDERS", "GOOGLE_APPLICATION_CREDENTIALS", "TF_ENCRYPTION", "PG_CONN_STR", "PGPASSWORD", "PGPASSFILE",
            "PGSERVICEFILE",
        ]
        let suffixes = ["_TOKEN", "_PASSWORD", "_PASSWD", "_API_KEY", "_APIKEY", "_ACCESS_KEY", "_PRIVATE_KEY", "_CREDENTIALS"]
        return names.contains(upper) || prefixes.contains { upper.hasPrefix($0) } || suffixes.contains { upper.hasSuffix($0) }
            || upper.contains("_SECRET") || upper.hasPrefix("SECRET")
    }

    /// Every process under `root`, children before theirs.
    private static func descendants(of root: pid_t) -> [pid_t] {
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-axo", "pid=,ppid="]
        let out = Pipe()
        ps.standardOutput = out
        guard (try? ps.run()) != nil else { return [] }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        ps.waitUntilExit()
        var children: [pid_t: [pid_t]] = [:]
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let fields = line.split(separator: " ").compactMap { pid_t($0) }
            if fields.count == 2 { children[fields[1], default: []].append(fields[0]) }
        }
        var found: [pid_t] = []
        var queue = [root]
        while let next = queue.first, found.count < 10_000 {
            queue.removeFirst()
            let under = children[next] ?? []
            found += under
            queue += under
        }
        return found
    }

    func testTerminal() throws { try run("terminal") }
    func testTabs() throws { try run("tabs") }
    func testRename() throws { try run("rename") }
    func testPin() throws { try run("pin") }
    func testClose() throws { try run("close") }
    func testEditor() throws { try run("editor") }
    /// Terraform's editor (stage 1a) with the installed terraform, offline,
    /// behind the recording wrapper, over checkouts the scenario writes:
    /// `OVERTERM_TF_TEST_TERRAFORM`, else Homebrew's. Skipped, loudly, without one.
    func testTerraform() throws {
        let candidates = [ProcessInfo.processInfo.environment["OVERTERM_TF_TEST_TERRAFORM"], "/opt/homebrew/bin/terraform", "/usr/local/bin/terraform"]
        guard let terraform = candidates.compactMap({ $0 }).first(where: { $0.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw XCTSkip("no terraform installed: the terraform scenario needs one (OVERTERM_TF_TEST_TERRAFORM names it)")
        }
        try run("terraform", env: ["OVERTERM_TERRAFORM": terraform])
    }
    /// Terraform's roots (stage 1b): the rail panel, the classes, the pane
    /// header over the real terraform (offline, a cleared environment).
    func testTerraformRoots() throws {
        try run("terraformRoots", env: ["OVERTERM_TERRAFORM": try Self.installedTerraform()])
    }

    /// Guarding agents (stage 1c): the deny rules on an agent's launch, a
    /// fake agent's ask for terraform apply marked and never answered, a
    /// saved plan read masked through tf_plan_summary.
    func testTerraformAgents() throws {
        try run("terraformAgents", env: ["OVERTERM_TERRAFORM": try Self.installedTerraform()])
    }

    /// The plan in the right slot (stage 1d): Overterm's plan of a
    /// checkout's roots read as data, the sentinel never in it, a missing
    /// workspace refused, a lock on the fake backend named, a worktree's
    /// plan stale after another applies, an agent's tf_plan.
    func testTerraformPlan() throws {
        try run("terraformPlan", env: ["OVERTERM_TERRAFORM": try Self.installedTerraform()])
    }

    /// The apply (stage 2a): a local root's plan applied in the plan's
    /// environment, a hostile TF_CLI_ARGS_apply never reaching it; a destroy
    /// and production asking for the root's name, with no switch; closing a
    /// pane, the window or a tab where the real terraform applies asks,
    /// Interrupt leaving the resource tainted and the lock free; an apply
    /// whose record is lost found again by its pid.
    func testTerraformApply() throws {
        try run("terraformApply", env: ["OVERTERM_TERRAFORM": try Self.installedTerraform()])
    }

    /// A 2,000-resource plan at Section 10's budgets: decoded and masked
    /// in under 0.5 s, its rows shown and filtered in under 150 ms. No
    /// terraform runs.
    func testTerraformPerf() throws { try run("terraformPerf") }

    /// The installed terraform: `OVERTERM_TF_TEST_TERRAFORM`, else Homebrew's.
    private static func installedTerraform() throws -> String {
        let candidates = [ProcessInfo.processInfo.environment["OVERTERM_TF_TEST_TERRAFORM"], "/opt/homebrew/bin/terraform", "/usr/local/bin/terraform"]
        guard let terraform = candidates.compactMap({ $0 }).first(where: { $0.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw XCTSkip("no terraform installed: the terraform scenarios need one (OVERTERM_TF_TEST_TERRAFORM names it)")
        }
        return terraform
    }
    func testAPI() throws { try run("api") }
    func testAPIImport() throws { try run("apiImport") }
    func testNotes() throws { try run("notes") }
    func testDrawing() throws { try run("drawing") }
    func testReview() throws { try run("review") }
    func testReviewPerf() throws { try run("reviewPerf") }
    func testDockerPerf() throws { try run("dockerPerf") }
    func testDatabase() throws { try run("database") }
    func testStorage() throws { try run("storage") }
    func testRedis() throws { try run("redis") }
    func testObservability() throws { try run("observability") }
    // The whole Docker page, end to end: 80–110 s on a busy machine.
    func testDocker() throws { try run("docker", timeout: 300) }
    /// The Kubernetes page against the fake API server: the run's only
    /// kubeconfig is this temporary file, which the scenario writes once
    /// the fake listens — never ~/.kube/config, whose current context is
    /// production. About 260 s; the charts are `kubernetesCharts`.
    func testKubernetes() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("overterm-e2e-kube-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let stderr = dir.appendingPathComponent("stderr.log")
        let printed = try run(
            "kubernetes", env: ["OVERTERM_KUBECONFIG": dir.appendingPathComponent("fake.kubeconfig").path], timeout: 420, stderr: stderr)
        // The scenario's Secret value (E2ERunner.secretValue), shown and
        // revealed in the app: never in what it printed, nor its errors.
        // And the Secret's values the editor diffs (E2ERunner.applySecretOld, applySecretNew),
        // and the env values and Helm values a workload's timeline diffs,
        // and the env values Compare with… diffs across contexts.
        let values = [
            "acme-e2e-pw-Zq7Lm", "acme-e2e-apply-Hx4Wq", "acme-e2e-apply-Rt8Pz", "acme-e2e-timeline-pw-old-W2n", "acme-e2e-timeline-pw-new-P5k",
            "acme-e2e-compare-pw-dev-T8s", "acme-e2e-compare-pw-stage-K3d",
        ]
        let output = printed + ((try? String(contentsOf: stderr, encoding: .utf8)) ?? "")
        for needle in values + values.map({ Data($0.utf8).base64EncodedString() }) {
            XCTAssertFalse(output.contains(needle), "kubernetes: a Secret's value reached the app's output")
        }
    }
    /// The charts — a pod's, a workload's, a node's, a namespace's, then
    /// over Prometheus — against the fake API server, apart from
    /// `kubernetes` so each runs well inside its time (about 120 s). Its
    /// kubeconfig is this temporary file alone.
    func testKubernetesCharts() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("overterm-e2e-kch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try run("kubernetesCharts", env: ["OVERTERM_KUBECONFIG": dir.appendingPathComponent("fake.kubeconfig").path], timeout: 300)
    }
    /// 5,000 pods on the fake API server: the first draw, a burst of 500
    /// events, the scroll. Its kubeconfig is this temporary file alone.
    func testKubernetesPerf() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("overterm-e2e-kperf-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try run("kubernetesPerf", env: ["OVERTERM_KUBECONFIG": dir.appendingPathComponent("fake.kubeconfig").path], timeout: 300)
    }
    /// The Overview as cards, in a dark theme, a light one and a narrow
    /// window, against the fake: OVERTERM_DUMP_PNG captures each.
    func testKubernetesOverview() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("overterm-e2e-kov-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try run("kubernetesOverview", env: ["OVERTERM_KUBECONFIG": dir.appendingPathComponent("fake.kubeconfig").path], timeout: 180)
    }
    /// The GitOps section on a spoke (Argo CD's apps read from the marks on
    /// their objects), beside a hub's Applications and where they are
    /// refused, against three fakes: its kubeconfig is this temporary file
    /// alone, every context routed to a fake by name.
    func testKubernetesGitOpsMarks() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("overterm-e2e-kgm-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try run("kubernetesGitOpsMarks", env: ["OVERTERM_KUBECONFIG": dir.appendingPathComponent("fake.kubeconfig").path], timeout: 240)
    }
    /// 5,000 pods across 50 namespaces with their Deployments, ReplicaSets
    /// and Services: the first list, the scroll, a burst, the Overview's
    /// health checks, a 200-pod Deployment's tree, the footprint after.
    func testKubernetesScale() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("overterm-e2e-kscale-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try run("kubernetesScale", env: ["OVERTERM_KUBECONFIG": dir.appendingPathComponent("fake.kubeconfig").path], timeout: 300)
    }
    func testSuspend() throws { try run("suspend") }
    func testDatabaseAgent() throws { try run("databaseAgent") }
    func testDatabaseTunnel() throws { try run("databaseTunnel") }
    func testSessionGroups() throws { try run("sessionGroups") }
    func testFullScreen() throws { try run("fullScreen") }
    func testImagePaste() throws { try run("imagePaste") }
    func testSidebarPanels() throws { try run("sidebarPanels") }
    func testCloseKeys() throws { try run("closeKeys") }
    func testEditorZed() throws { try run("editorZed") }
    func testFileActions() throws { try run("fileActions") }
    func testBrowser() throws { try run("browser") }
    func testDiff() throws { try run("diff") }
    func testBranchDiff() throws { try run("branchDiff") }
    func testWhy() throws { try run("why") }
    func testDiffStyle() throws { try run("diffStyle") }
    func testLayout() throws { try run("layout") }
    func testTask() throws { try run("task") }
    func testSnippets() throws { try run("snippets") }
    func testAttention() throws { try run("attention") }
    func testMarks() throws { try run("marks") }
    /// The README's pictures, Kubernetes' against the fake: its
    /// kubeconfig is this temporary file alone.
    func testShowcase() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("overterm-e2e-show-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try run("showcase", env: ["OVERTERM_KUBECONFIG": dir.appendingPathComponent("fake.kubeconfig").path], timeout: 180)
    }
    func testPalette() throws { try run("palette") }
    func testReorder() throws { try run("reorder") }
    func testInfo() throws { try run("info") }
    func testClaudeInfo() throws { try run("claude") }
    func testDiskInfo() throws { try run("disk") }
    func testFollow() throws { try run("follow") }
    func testSpotlight() throws { try run("spotlight") }
    func testLink() throws { try run("link") }
    func testCleanup() throws { try run("cleanup") }
    func testSplits() throws { try run("splits") }
    func testPullRequest() throws { try run("pullRequest") }
    func testOverview() throws { try run("overview") }
    func testPeek() throws { try run("peek") }
    func testScrollback() throws { try run("scrollback") }
    func testOpenFromFinder() throws { try run("openFromFinder") }
    func testSessions() throws { try run("sessions") }
    func testSettings() throws { try run("settings") }
    func testThemes() throws { try run("themes") }
    func testUsage() throws { try run("usage") }
    func testUpdates() throws { try run("updates") }
    func testPerformance() throws { try run("performance") }
    func testBigFiles() throws { try run("bigFiles") }
    func testClipboard() throws { try run("clipboard") }
    func testOpenWith() throws { try run("openWith") }
    func testDropFiles() throws { try run("dropFiles") }
    func testGroups() throws { try run("groups") }
    func testBlocks() throws { try run("blocks") }
    func testInbox() throws { try run("inbox") }
    func testAskAgent() throws { try run("askAgent") }
    func testDropSplit() throws { try run("dropSplit") }
    func testOvergit() throws { try run("overgit") }
    func testOvergitWork() throws { try run("overgitWork") }
    func testOvergitGit() throws { try run("overgitGit") }
    func testAppearance() throws { try run("appearance") }
    func testSimulator() throws { try run("simulator") }
    func testThroughput() throws { try run("throughput") }

    /// A prepared session.json comes back (pin, colour, names, selection,
    /// directories, a split tab's panes) and changes are autosaved to it.
    func testSession() throws {
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("overterm-e2e-session-\(UUID().uuidString)")
        let dir = support.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: support) }
        let session = """
            {"selectedIndex":1,"tabs":[
              {"workingDirectory":"\(support.path)","customTitle":"pinned one","color":"green","isPinned":true},
              {"workingDirectory":"\(dir.path)","isPinned":false,"focusedPane":1,"panes":{"split":{"axis":"horizontal","ratio":0.3,
                "first":{"pane":{"directory":"\(support.path)"}},"second":{"pane":{"directory":"\(dir.path)"}}}}}
            ]}
            """
        try Data(session.utf8).write(to: support.appendingPathComponent("session.json"))
        try run("session", env: ["OVERTERM_SUPPORT_DIR": support.path, "OVERTERM_E2E_CWD": dir.path])
    }
}

/// What a scenario printed, gathered on the pipe's queue.
private final class Collected: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()

    func append(_ data: Data) {
        lock.lock()
        bytes.append(data)
        lock.unlock()
    }

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return bytes
    }
}
