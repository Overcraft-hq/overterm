import Foundation

/// `tf_test` (analysis 5.10, stage 2d, D-19): `terraform test` of a root
/// of the calling pane's checkout — every test file, or one — answered
/// with each run's status and each failure at its file and line. The
/// one write-free feedback loop for agents: test files whose every
/// provider is mocked and whose code runs no command run at once, without
/// credentials (the providers — the root's, its modules', the tests'
/// mocks — start for their schemas, so only where a committed, unchanged
/// lock file pins them — `providersRefusal` — unless only the builtin one
/// is named). A real provider, or a provisioner, creates real
/// infrastructure or runs a command: asked in the window every call,
/// never on production. The run shows in the window's
/// right slot as the person's does; its answer is the stream's masked
/// decode, cut.
extension TerraformMCP {
    static let testNames = ["tf_test"]

    static let testTool: [String: Any] = [
        "name": "tf_test",
        "description":
            "Runs terraform test in a root of your checkout and answers each run's status and each failure at its file and line. Test files whose every provider is mocked (mock_provider) run at once, without credentials; a test with a real provider creates real infrastructure, so the person is asked every time (never on production; on a remote root only where terraform.roots sets it writable).",
        "inputSchema": [
            "type": "object",
            "properties": [
                "root": ["type": "string", "description": "The root, relative to the checkout. Optional when there is one root."],
                "file": ["type": "string", "description": "One test file, relative to the root (tests/acme.tftest.hcl). Optional: every test file."],
            ] as [String: Any],
            "required": [String](),
        ] as [String: Any],
    ]

    /// Starts a test in the window of the pane that asked
    /// (`TerminalWindowController.startTerraformTest`): asked there when a
    /// real provider would run. A failure with no message: declined.
    static var startTest: ((TerraformRootCard, URL, String, String?) async -> Result<TerraformTestRun, TerraformReadFailure>)?

    /// How long a call waits for its run: beyond it, the run goes on and
    /// a later call reads it.
    static var testWait: TimeInterval = 240

    static func test(_ arguments: [String: Any], in checkout: URL, pane: String) async throws -> String {
        let card = try await card(arguments, in: checkout, tool: "tf_test")
        let file = argument(arguments, "file")
        if let file, !TerraformCommands.isTestFile(file) {
            return "\(file) isn't a test file: name one relative to the root, ending .tftest.hcl (tests/acme.tftest.hcl)."
        }
        // Every path argument resolved, never a link out of the checkout (5.10).
        if let file {
            let folder = card.folder
            let inside = await TerraformPanelModel.blocking { TerraformTestFiles.inside(folder.appendingPathComponent(file), checkout: checkout) != nil }
            guard inside else { return "\(file) resolves outside your checkout: not read, not run." }
        }
        // A run of the root still going (its own, or the person's): waited for.
        if let going = TerraformTestResults.shared.latest(checkout: checkout, root: card.path)
            ?? TerraformTestResults.shared.latest(
                checkout: checkout.resolvingSymlinksInPath(), root: card.path), going.isGoing
        {
            return await answer(going, waitingFor: testWait)
        }
        // The lock file's check (every provider its tests start, mocked or
        // not) and the question are the window's: `TerraformTestRun.begin`.
        guard let startTest else { return "Overterm can't run tests from here: no window has your pane." }
        switch await startTest(card, checkout, pane, file) {
        case .failure(let failure):
            return failure.message.isEmpty ? "The person declined the test of \(card.name)." : "\(card.name): \(failure.message)"
        case .success(let run):
            return await answer(run, waitingFor: testWait)
        }
    }

    /// The run's answer once it ends, or its progress after `wait`.
    static func answer(_ run: TerraformTestRun, waitingFor wait: TimeInterval) async -> String {
        let deadline = Date().addingTimeInterval(wait)
        while run.isGoing, Date() < deadline {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        let name = run.card.name
        switch run.phase {
        case .preparing, .running:
            let done = run.report.runs.filter { $0.status != .pending && $0.status != .running }.count
            return "The test of \(name) is still running (\(done) of \(run.report.runs.count) runs done). Call tf_test again for its result."
        case .refused(let why): return "\(name): not run — \(why)"
        case .stopped: return "The test of \(name) was stopped."
        case .passed, .failed:
            let head: String
            if case .failed(let said) = run.phase { head = "Failed — \(said)" } else { head = "Passed." }
            return head + "\n" + run.report.text(root: name, mocked: run.mocking?.isMocked ?? false)
        }
    }
}
