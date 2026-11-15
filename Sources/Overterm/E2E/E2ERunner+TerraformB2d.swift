import AppKit

/// Terraform stage 2d (docs/design/terraform/analysis.md 2.6, 2.9, 9):
/// drift and `terraform test`. A test file whose runs need no real
/// provider, run from the root's card: its runs listed in the right slot,
/// one passing, one failing at its line — said there, in the editor over
/// the test file, and to an agent through `tf_test` — run as `test -json
/// -no-color` without a credential, the checkout byte for byte the same
/// after; the failing assertion compares a value that is the sentinel, so
/// the real stream's snippet values and assertion sides carry it and the
/// allow-list is what keeps it out of the slot, the log and `tf_test`. A real-provider test asked
/// every time, nothing run when declined, an agent's refused on
/// production, the root's name typed there. Check Drift on a root whose output's expression changed since
/// its state: a `-refresh-only` plan, locked, its finding said with its
/// age; Accept into State its apply — the one apply line, asked — and a
/// second check finds no drift.
///
/// The real terraform behind the recording wrapper, in the guarded
/// environment, over a checkout this scenario writes, `terraform_data`
/// only, its state made by the CLI first. Called from the `terraform`
/// scenario, which skips without one.
extension E2ERunner {
    func terraformDriftAndTestB2d(binary: String) async {
        guard let recorder = try? TerraformRecorder.make(in: out("terraform-2d-recorder"), target: binary) else {
            return check("2d: the recording wrapper is made", false)
        }
        let wrapper = TerraformCLI.scenarioWrapper
        TerraformCLI.scenarioWrapper = recorder.wrapper
        defer { TerraformCLI.scenarioWrapper = wrapper }

        let sentinel = "acme-hunter2-SECRET"
        let checkout = out("acme-2d")
        let dev = checkout.appendingPathComponent("envs/dev", isDirectory: true)
        let testText = """
            variables {
              acme_password = "\(sentinel)"
            }

            run "acme_named" {
              command = plan

              assert {
                condition     = terraform_data.acme.input == "acme-dev"
                error_message = "the name is acme-dev"
              }
            }

            run "acme_upper" {
              variables {
                acme_name = "\(sentinel)"
              }

              assert {
                condition     = terraform_data.acme.input == "ACME"
                error_message = "the output is upper-cased acme"
              }
            }

            """
        let failingLine = 20
        let files: [String: String] = [
            ".gitignore": ".terraform/\n*.tfstate\n*.tfstate.*\n",
            "envs/dev/.terraform.lock.hcl": "# acme: no providers to lock\n",
            "envs/dev/main.tf": """
            variable "acme_name" {
              type    = string
              default = "acme-dev"
            }

            variable "acme_password" {
              type      = string
              sensitive = true
              default   = "acme-unset"
            }

            resource "terraform_data" "acme" {
              input = var.acme_name
            }

            output "acme_upper" {
              value = upper(terraform_data.acme.output)
            }

            """,
            "envs/dev/tests/acme.tftest.hcl": testText,
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
        } catch {
            return check("2d: the checkout is written", false, "\(error)")
        }
        // The state, by the CLI in the guarded environment: Overterm never applies here but Accept.
        guard let cli = try? TerraformGuards.prepareScratch(at: out("terraform-2d-cli")) else { return check("2d: the CLI's scratch", false) }
        let log = out("terraform-2d-cli.log")
        let environment = cli.environment
        let applied = await TerraformPanelModel.blocking { () -> Int32 in
            let initialised = Self.terraformCLI(binary, ["init", "-input=false"], in: dev, environment: environment, log: log)
            guard initialised == 0 else { return initialised }
            return Self.terraformCLI(binary, ["apply", "-auto-approve", "-input=false"], in: dev, environment: environment, log: log)
        }
        check("2d: envs/dev has its state, from the CLI", applied == 0, (try? String(contentsOf: log, encoding: .utf8)) ?? "")

        let questions = B2dAnswers()
        app.terraformPlanQuestionRecorder = { question in
            questions.plans.append(question)
            return true
        }
        app.terraformApplyQuestionRecorder = { sheet in
            questions.sheets.append(sheet)
            return ""
        }
        defer {
            app.terraformPlanQuestionRecorder = nil
            app.terraformApplyQuestionRecorder = nil
        }
        TerraformTestResults.shared.reset()

        let panel = app.terraformPanel
        let pane = app.terraformPlanPane
        app.newTab(in: checkout)
        app.showTerraformPanel(nil)
        // Another scenario's checkout has an envs/dev too: this one's, once the panel follows the new tab.
        check(
            "2d: the root is listed",
            await eventually(15) {
                panel.checkout.map { self.realPath($0) } == self.realPath(checkout) && panel.state == .read
                    && panel.roots.contains { $0.path == "envs/dev" }
            }, "\(panel.checkout?.path ?? "-"): \(panel.roots.map(\.path))")
        guard let card = panel.roots.first(where: { $0.path == "envs/dev" }) else { return check("2d: envs/dev", false) }
        Self.accessibilityTree(true)
        defer { Self.accessibilityTree(false) }
        guard let root = app.window?.contentView else { return check("2d: the window", false) }
        panel.selectedPath = card.path

        // 1. terraform test from the card: its runs, one failure at its line.
        let before = snapshot2d(checkout)
        let mark = recorder.calls().count
        check("2d: the card's Test button", await eventually(5) { Self.accessibilityPress("terraform.panel.test", in: root) })
        guard await eventually(5, { pane.test != nil }), let test = pane.test else {
            let sheet = (app.window?.attachedSheet?.contentView.map { Self.accessibilityElementTexts($0) } ?? []).joined(separator: " | ")
            return check("2d: Test shows a run in the slot", false, "sheet: \(sheet)")
        }
        check("2d: in the right slot", app.rightPane.mode == .terraformPlan)
        check("2d: the test ends", await eventually(60) { !test.isGoing }, "\(test.phase) \(test.log.suffix(6))")
        check("2d: every provider mocked (the builtin one alone)", test.mocking == .mocked)
        check("2d: its runs listed", test.report.runs.map(\.name) == ["acme_named", "acme_upper"], "\(test.report.runs.map(\.name))")
        check("2d: one passes, one fails", test.report.runs.map(\.status) == [.pass, .fail], "\(test.report.runs.map(\.status))")
        if case .failed(let said) = test.phase {
            check("2d: said failed, 1 passed, 1 failed", said.hasPrefix("1 passed, 1 failed"), said)
        } else {
            check("2d: the run failed", false, "\(test.phase)")
        }
        let failure = test.report.runs.last?.diagnostics.first
        check(
            "2d: the failure at its line", failure?.file == "tests/acme.tftest.hcl" && failure?.start?.line == failingLine,
            "\(failure?.file ?? "") \(failure?.start?.line ?? 0)")
        var drawn = ""
        check(
            "2d: drawn in the slot, the failure with its place",
            await eventually(5) {
                drawn = Self.accessibilityElement("terraform.test.run.tests/acme.tftest.hcl.acme_upper", in: root)?.text ?? ""
                return drawn.contains("fail") && drawn.contains("tests/acme.tftest.hcl:\(failingLine)")
            }, drawn)
        // The window's own reads go on meanwhile (the version pill's, a format check): the tests' runs alone.
        let calls = recorder.calls().dropFirst(mark).filter { $0.subcommand == "test" }
        check("2d: run as test -json -no-color, at the root", calls.map(\.arguments) == [TerraformCommands.test()!] && calls.first?.cwd == realPath(dev), "\(calls.map(\.arguments))")
        let home = (try? TerraformGuards.prepareScratch(at: AppEnvironment.terraformScratchDirectory))?.home.path
        check(
            "2d: without a credential, HOME the scratch one, no workspace pinned",
            calls.first.map { !$0.names.contains(where: TerraformGuards.isCredential) && $0.values["HOME"] == home && $0.values["TF_WORKSPACE"] == nil } == true,
            "\(calls.first?.names ?? [])")
        check("2d: the checkout byte for byte the same after", snapshot2d(checkout) == before)

        // The editor marks the failing line of the test file.
        let testFile = dev.appendingPathComponent("tests/acme.tftest.hcl")
        app.openInEditor(testFile)
        if let editor = app.editor {
            check("2d: the test file opens", await eventually(3) { editor.active?.url?.lastPathComponent == "acme.tftest.hcl" })
            let marks = editor.active?.terraformDiagnostics.filter { $0.source == EditorViewController.terraformTestSource } ?? []
            let text = testText as NSString
            let line = marks.first.map { TerraformTestFiles.line(of: $0.range.location, in: text) }
            check("2d: the editor marks the failure at its line", marks.count == 1 && line == failingLine, "\(marks.map(\.range)) \(line ?? 0)")
            // Validate shares the buffer's marks: validating the folder keeps the test run's.
            if let folder = editor.active?.terraform {
                editor.validateTerraform(manual: true)
                check("2d: the folder validated", await eventually(30) { !folder.isRunning }, folder.state.text)
                let kept = editor.active?.terraformDiagnostics.filter { $0.source == EditorViewController.terraformTestSource } ?? []
                check("2d: the test's mark is still there after validate", kept == marks, "\(kept.map(\.range))")
            } else {
                check("2d: the test file is a Terraform buffer", false)
            }
        } else {
            check("2d: the editor", false)
        }

        // An agent's tf_test: the same answer, from its pane.
        guard let tag = app.store.selected?.terminal.processTag else { return check("2d: the checkout's pane", false) }
        let agentMark = recorder.calls().count
        let answer = await b2dTool("tf_test", ["root": "envs/dev", "file": "tests/acme.tftest.hcl"], pane: tag)
        check(
            "2d: tf_test answers the runs and the failure's place",
            answer.contains("run \"acme_upper\"") && answer.contains("fail") && answer.contains("tests/acme.tftest.hcl:\(failingLine)"), answer)
        check(
            "2d: tf_test ran the one file",
            recorder.calls().dropFirst(agentMark).filter { $0.subcommand == "test" }.map(\.arguments) == [TerraformCommands.test(file: "tests/acme.tftest.hcl")!],
            "\(recorder.calls().dropFirst(agentMark).map(\.arguments))")
        for (where_, text) in [("the report", String(reflecting: test.report)), ("the slot", drawn), ("tf_test", answer), ("the log", test.log.joined(separator: "\n"))] {
            check("2d: no sentinel in \(where_)", !text.contains(sentinel))
        }

        await terraformRealProviderTestB2d(card: card, checkout: checkout, dev: dev, recorder: recorder)

        // 2. Drift: the output's expression changed since the state.
        let main = dev.appendingPathComponent("main.tf")
        let changed = ((try? String(contentsOf: main, encoding: .utf8)) ?? "").replacingOccurrences(of: "upper(", with: "lower(")
        try? changed.write(to: main, atomically: true, encoding: .utf8)
        let driftMark = recorder.calls().count
        check("2d: the card's Check Drift button", Self.accessibilityPress("terraform.panel.drift", in: root))
        check(
            "2d: a drift check in the slot, planned", await eventually(40) { pane.run?.mode == .refreshOnly && pane.run?.phase == .planned },
            "\(String(describing: pane.run?.phase)) \(pane.run?.log.suffix(4) ?? [])")
        guard let drift = pane.run, drift.mode == .refreshOnly, let plan = drift.plan else { return check("2d: the drift check", false) }
        check("2d: it found the output", TerraformDrift.said(plan) == "1 output changed", TerraformDrift.said(plan))
        let planCall = recorder.calls().dropFirst(driftMark).first { $0.subcommand == "plan" }
        check(
            "2d: plan -refresh-only, locked", planCall.map { $0.arguments.contains("-refresh-only") && $0.arguments.contains("-lock=true") && TerraformCommands.isPlan($0.arguments) } == true,
            "\(planCall?.arguments ?? [])")
        var driftText = ""
        check(
            "2d: its finding with its age",
            await eventually(5) {
                driftText = Self.accessibilityElement("terraform.plan.drift", in: root)?.text ?? ""
                return driftText.contains("1 output changed") && driftText.contains("checked just now")
            }, driftText)
        check(
            "2d: and on the root's card",
            await eventually(5) { Self.accessibilityElement("terraform.panel.drift.envs/dev", in: root)?.text.contains("checked") == true })
        check("2d: a drift check isn't the root's last plan", TerraformRunRegistry.shared.latest(checkout: checkout, root: "envs/dev")?.mode != .refreshOnly)

        // Accept into State: the one apply, asked, no name on a local root.
        let sheets = questions.sheets.count
        let outcome = await app.applyPlan(drift)
        guard case .started(let accept) = outcome else { return check("2d: Accept into State starts", false, "\(outcome)") }
        let sheet = questions.sheets.dropFirst(sheets).first
        check("2d: asked: Accept into State, no name typed on a local root", sheet?.button == "Accept into State" && sheet?.typedName == nil, sheet?.title ?? "none")
        check("2d: accepted", await eventually(60) { if case .applied = accept.phase { true } else { false } }, "\(accept.phase)")
        let applyCall = recorder.calls().last { $0.subcommand == "apply" }
        check("2d: the one apply line", applyCall?.arguments == TerraformCommands.apply, "\(applyCall?.arguments ?? [])")
        let state = (try? String(contentsOf: dev.appendingPathComponent("terraform.tfstate"), encoding: .utf8)) ?? ""
        check("2d: the state has the output as now", state.contains("\"acme-dev\"") && !state.contains("ACME-DEV"))
        check("2d: the check says it's stale now", await eventually(5) { drift.driftLine(.shared).stale }, drift.driftLine(.shared).text)

        // Checked again: no drift.
        app.checkTerraformDrift(card)
        check(
            "2d: checked again: no drift", await eventually(40) { pane.run !== drift && pane.run?.mode == .refreshOnly && pane.run?.phase == .noChanges },
            "\(String(describing: pane.run?.phase))")
        if let again = pane.run {
            check(
                "2d: nothing to accept", again.applyGreyed(.shared, writable: true)?.hasPrefix("No drift to accept") == true,
                again.applyGreyed(.shared, writable: true) ?? "")
        }
        TerraformTestResults.shared.reset()
    }

    /// A test file with a real provider: asked on every call — the files
    /// named, the name typed on production — nothing run when declined;
    /// an agent's on production refused before any question.
    private func terraformRealProviderTestB2d(card: TerraformRootCard, checkout: URL, dev: URL, recorder: TerraformRecorder) async {
        let real = dev.appendingPathComponent("tests/real.tftest.hcl")
        try? "provider \"aws\" {\n  region = \"eu-west-1\"\n}\n\nrun \"acme_real\" {}\n".write(to: real, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: real) }
        let saved = app.terraformPlanQuestionRecorder
        var asked: [TerraformPlanGate.Question] = []
        app.terraformPlanQuestionRecorder = { question in
            asked.append(question)
            return false
        }
        defer { app.terraformPlanQuestionRecorder = saved }
        let mark = recorder.calls().count
        for _ in 0..<2 {
            let outcome = await app.startTerraformTest(card, checkout: checkout, file: "tests/real.tftest.hcl", agent: nil)
            if case .failure(let why) = outcome { check("2d: a real-provider test declined", why.message.isEmpty, why.message) } else { check("2d: declined", false) }
        }
        check("2d: asked on every call", asked.count == 2, "\(asked.count)")
        check("2d: the question names the file and what is real", asked.first.map { $0.detail.contains("Files: tests/real.tftest.hcl") && $0.detail.contains("aws") } == true)
        var production = card
        production.verdict = .init(rootClass: .production, reason: "a scenario's")
        let agent = await app.startTerraformTest(production, checkout: checkout, file: "tests/real.tftest.hcl", agent: "an agent")
        if case .failure(let why) = agent {
            check("2d: an agent's real test on production refused", why.message.contains("is production"), why.message)
        } else {
            check("2d: an agent's real test on production refused", false)
        }
        check("2d: refused before any question", asked.count == 2)
        _ = await app.startTerraformTest(production, checkout: checkout, file: "tests/real.tftest.hcl", agent: nil)
        check("2d: on production, the root's name typed", asked.last?.typedName == card.name && asked.count == 3, asked.last?.typedName ?? "none")
        check("2d: nothing ran", recorder.calls().count == mark, "\(recorder.calls().dropFirst(mark).map(\.arguments))")
    }

    /// Every file under `folder` but `.git`'s and the state's, by path, with its bytes.
    private func snapshot2d(_ folder: URL) -> [String: Data] {
        var found: [String: Data] = [:]
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil) else { return found }
        for case let url as URL in walker {
            let relative = String(url.path.dropFirst(folder.path.count))
            if relative.hasPrefix("/.git") { continue }
            found[relative] = (try? Data(contentsOf: url)) ?? Data()
        }
        return found
    }

    /// A tool's text answer, as an agent reads it.
    private func b2dTool(_ name: String, _ arguments: [String: Any], pane: String) async -> String {
        guard let result = try? await TerraformMCP.call(name, arguments, pane: pane) else { return "(threw)" }
        let content = result["content"] as? [[String: Any]] ?? []
        return content.compactMap { $0["text"] as? String }.joined(separator: "\n")
    }

    @MainActor private final class B2dAnswers {
        var plans: [TerraformPlanGate.Question] = []
        var sheets: [TerraformApplySheet] = []
    }
}

extension E2ERunner {
    /// Every label, value and title under a view: what a sheet said, for a failed check.
    static func accessibilityElementTexts(_ view: NSView) -> [String] {
        var words: [String] = []
        func walk(_ object: NSObject, depth: Int) {
            guard depth < 40 else { return }
            for key in ["accessibilityLabel", "accessibilityValue", "accessibilityTitle"] where object.responds(to: Selector(key)) {
                if let said = object.value(forKey: key) as? String, !said.isEmpty { words.append(said) }
            }
            var children = (object.responds(to: Selector("accessibilityChildren")) ? object.value(forKey: "accessibilityChildren") as? [Any] : nil)?.compactMap { $0 as? NSObject } ?? []
            if let view = object as? NSView { children += view.subviews }
            for child in children { walk(child, depth: depth + 1) }
        }
        walk(view, depth: 0)
        return words
    }
}
