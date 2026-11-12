import AppKit

// MARK: Drift and terraform test (docs/design/terraform/analysis.md 2.6, 2.9, 5.3, stage 2d)

extension TerminalWindowController {
    /// Agents' `tf_test` reaches the window of their pane: shown there, and
    /// asked there when a real provider would run.
    func wireTerraformTest() {
        TerraformMCP.startTest = { card, checkout, pane, file in
            for controller in NSApp.windows.compactMap({ $0.windowController as? TerminalWindowController }) {
                guard controller.store.tabs.contains(where: { $0.terminals.contains { $0.processTag == pane } }) else { continue }
                return await controller.startTerraformTest(card, checkout: checkout, file: file, agent: await MCPAsker.current() ?? "an agent")
            }
            return .failure(TerraformReadFailure(message: "The pane that asked isn't in any window."))
        }
    }

    /// Check Drift (2.6): Overterm's plan with `-refresh-only`, in the
    /// slot — asked as any plan is (production's first this session, code
    /// not the person's), locked, never on a timer. Its Accept into State
    /// is the apply of that plan, with every check of 5.4.
    func checkTerraformDrift(_ card: TerraformRootCard, checkout: URL? = nil) {
        planTerraformRoot(card, checkout: checkout, mode: .refreshOnly)
    }

    /// Test (2.9): every test file of the root, or one, in the slot.
    func testTerraformRoot(_ card: TerraformRootCard, checkout: URL? = nil, file: String? = nil) {
        guard let checkout = checkout ?? terraformPanel.checkout else { return NSSound.beep() }
        Task { @MainActor [weak self] in
            guard let self else { return }
            if case .failure(let why) = await self.startTerraformTest(card, checkout: checkout, file: file, agent: nil), !why.message.isEmpty {
                self.presentTerraformRefusal(why.message)
            }
        }
    }

    /// A test run started, shown in the slot (`TerraformTestRun.begin`):
    /// a run of the root still going is shown again, never started twice.
    /// Files whose every provider is mocked run at once, without
    /// credentials; a real provider is a write (5.3) — refused on a
    /// read-only root, asked everywhere else, every time, the root's name
    /// typed on production (an agent's there refused: agents never write
    /// there). A failure whose message is empty was declined.
    @discardableResult
    func startTerraformTest(_ card: TerraformRootCard, checkout: URL, file: String?, agent: String?) async -> Result<TerraformTestRun, TerraformReadFailure> {
        await TerraformTestRun.begin(
            card: card, checkout: checkout, file: file, agent: agent, writable: Settings.shared.terraformRoots[card.path]?.writable ?? false,
            settingPath: Settings.shared.terraformPath,
            ask: { [weak self] question in await self?.askTerraformTest(question, card: card) ?? false },
            show: { [weak self] run in self?.showTerraformTest(run) })
    }

    /// A real-provider test's question: the scenario's recorder, else the
    /// write confirmation — the name typed exactly, on production.
    private func askTerraformTest(_ question: TerraformPlanGate.Question, card: TerraformRootCard) async -> Bool {
        if let recorder = terraformPlanQuestionRecorder { return recorder(question) }
        let confirmation = WriteConfirmation(
            title: question.title, scope: "\(card.rootClass.title.uppercased()) · \(card.name) · workspace \(card.workspace)",
            production: card.isProduction, detail: question.detail, button: question.button, typedName: question.typedName, critical: card.isProduction)
        guard let typed = await confirmation.ask(on: window) else { return false }
        if let name = question.typedName, typed.trimmingCharacters(in: .whitespacesAndNewlines) != name {
            presentTerraformRefusal("The name typed isn't \(name): the test wasn't run.")
            return false
        }
        return true
    }

    /// A test run in the right slot, which takes it (`RightSlot`).
    func showTerraformTest(_ run: TerraformTestRun) {
        terraformPlanPane.showTest(run)
        rightPane.terraformPlanOpened = true
        rightPane.mode = .terraformPlan
        if diffItem?.isCollapsed == true { toggleDiff(nil) }
        updateRightPaneVisibility()
    }
}
