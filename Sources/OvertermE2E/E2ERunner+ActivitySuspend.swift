#if E2E
import AppKit
import Darwin

/// Activity's verbs that hold a process (docs/design/activity/analysis.md,
/// 6.10, 10.3), over the run's own pane's processes only — what the
/// isolated-run gate admits: Suspend of an agent's child alone, unasked,
/// Resume of only what Activity stopped, "2 stopped here — Resume All",
/// asked; the quit question in this isolated run, its Resume and Quit; a
/// pane's job suspended with its pane and resumed with its tab; Run in
/// Background and Normally, unasked; Lower Priority, asked, its nice read
/// back, nothing chosen at 20; Send a Signal ▸ STOP to a pane's job asked;
/// the chips with nothing selected; and the gate refusing a priority aimed
/// at a process the run didn't start (10.3, 8), its nice read back
/// unchanged and never printed. Checks say pids, counts, states and the
/// sheets' words about the run's own processes.
extension E2ERunner {
    package func activitySuspendChecks(tab: Tab) async {
        let page = app.activityPage
        let pane = tab.terminal
        let kernel = LiveActivityKernel()
        let held = ActivityHeld.shared
        _ = page.press("1")
        page.setScope(.tab(tab.id), for: .processes)
        defer { page.setScope(.mac, for: .processes) }

        func row(_ command: String) -> ActivityProcessRow? {
            page.content.processes.first { $0.tab == tab.id && $0.state != .zombie && $0.command == command }
        }
        func listed(_ command: String) async -> ActivityProcessRow? {
            _ = await eventually(15) { row(command) != nil }
            return row(command)
        }
        func stopped(_ identity: ActivityProcessID) -> Bool { kernel.process(identity.pid).map { $0.identity == identity && $0.isStopped } ?? false }
        func running(_ identity: ActivityProcessID) -> Bool { kernel.process(identity.pid).map { $0.identity == identity && !$0.isStopped } ?? false }
        func verb(_ title: String, of row: ActivityProcessRow) async -> ResourceVerb? {
            page.selection = [row.id]
            _ = await eventually(10) { page.verbSubject?.signal.identity == row.identity }
            return page.verbs(for: [row.id]) { _ in }.first { $0.title == title }
        }
        /// `title` offered for `row` once its process is read as it is now.
        func offered(_ title: String, of row: ActivityProcessRow) async -> ResourceVerb? {
            _ = await eventually(15) {
                page.selection = [row.id]
                return page.verbs(for: [row.id]) { _ in }.first { $0.title == title }?.unavailable == nil
            }
            return await verb(title, of: row)
        }
        /// What the verbs say of `row` now, for a failed check: the page's
        /// own titles and reasons, and who it reads as stopping it.
        func said(_ row: ActivityProcessRow) -> String {
            let subject = page.verbSubject
            let verbs = page.verbs(for: [row.id]) { _ in }.filter { ["p", "b"].contains($0.key) }
            return verbs.map { "\($0.title): \($0.unavailable ?? "offered")" }.joined(separator: "; ")
                + " — subject \(subject?.signal.identity == row.identity ? "read" : "not read"), stopped by \(subject?.target.stopped.map { "\($0)" } ?? "nobody"), background \(subject?.target.backgroundedHere == true), \(held.stoppedCount) held"
                + "; rows' subject \(page.content.subject.map { $0.signal.identity == row.identity ? "this" : "another" } ?? "none"), row \(page.content.processes.first { $0.id == row.id }?.state.letter ?? "-"), tick \(page.latest.map { String(format: "%.1f", Date().timeIntervalSince($0.date)) } ?? "-") s old, \(page.builds) builds, held order \(page.orderHeld), paused \(page.paused)"
        }
        func putAway() async {
            if window.attachedSheet != nil {
                answerActivitySheet(.alertSecondButtonReturn)
                _ = await eventually(5) { self.window.attachedSheet == nil }
            }
        }

        await putAway()
        _ = await eventually(5) { pane.foregroundGroup == nil || kernel.process(pane.foregroundGroup ?? 0)?.shortName.hasSuffix("sh") == true }
        // A stand-in agent with two children of its own, and two jobs.
        pane.insertText("(exec -a claude /bin/sh -c '/bin/sleep 171 & /bin/sleep 172 & wait') & /bin/sleep 173 & /bin/sleep 174 &")
        pane.pressReturn()

        // Suspend of an agent's child: with its subtree — none —, unasked.
        guard let first = await listed("/bin/sleep 171"), let second = await listed("/bin/sleep 172") else {
            return check("the stand-in agent's two children are listed", false)
        }
        check("an agent's child is its agent's", first.owner?.paneRole == .agentChild, "\(first.owner?.paneRole.map { "\($0)" } ?? "none")")
        let suspend = await verb("Suspend", of: first)
        check("Suspend is offered for an agent's child, its key p", suspend?.unavailable == nil && suspend?.key == "p", suspend?.unavailable ?? "")
        suspend?.perform()
        check("Suspend of one process asks nothing and stops it", await eventually(10) { stopped(first.identity) } && window.attachedSheet == nil)
        check("kept by identity: 1 stopped here", await eventually(5) { held.stoppedCount == 1 && held.stopped == [first.identity] })
        let resume = await offered("Resume", of: first)
        check("Resume is offered once it reads as Activity's stop", resume != nil && resume?.key == "p", said(first))
        let chip = await eventually(10) { row("/bin/sleep 171")?.stoppedHere == true }
        check("its row says it was suspended here", chip && ActivityPageView.chips(row("/bin/sleep 171") ?? first).contains("suspended here"))
        // Whatever is selected: the chip is the row's, not the selection's.
        page.selection = []
        page.refreshVerbs()
        check("and says so with nothing selected", await eventually(10) { page.verbSubject == nil && row("/bin/sleep 171")?.stoppedHere == true })
        page.selection = [first.id]
        _ = page.press("p")
        check("p resumes it, unasked", await eventually(10) { running(first.identity) } && window.attachedSheet == nil)
        check("and lets it go", await eventually(5) { held.stoppedCount == 0 })

        // A ⌃Z-like stop that isn't Activity's: Resume refused, its shell's.
        if let other = await listed("/bin/sleep 174") {
            _ = kernel.signal(SIGSTOP, pid: other.identity.pid)
            let refused = await eventually(15) {
                page.selection = [other.id]
                return page.verbs(for: [other.id]) { _ in }.first { $0.title == "Resume" }?.unavailable == ActivitySignalCheck.jobControl
            }
            check("a job stopped by its shell isn't Activity's to resume: fg in its tab", refused)
            _ = kernel.signal(SIGCONT, pid: other.identity.pid)
        }

        // Two stopped here: the header's Resume All, asked, each listed.
        (await verb("Suspend", of: first))?.perform()
        _ = await eventually(10) { stopped(first.identity) }
        (await verb("Suspend", of: second))?.perform()
        let both = await eventually(10) { stopped(second.identity) && held.stoppedCount == 2 }
        check("two suspended: 2 stopped here", both, "\(held.stoppedCount)")
        if let view = app.pages.view(.activity) {
            let said = await eventually(5) {
                view.layoutSubtreeIfNeeded()
                return Self.accessibilityElement("activity.stoppedHere", in: view)?.text.contains("2 stopped here") == true
            }
            check("the header says 2 stopped here, with Resume All", said)
        }
        page.actions.resumeAll()
        let sheet = await eventually(10) { self.window.attachedSheet != nil } ? activitySheet() : (texts: [], buttons: [])
        check(
            "Resume All asks, listing each",
            sheet.texts.contains("Resume the 2 processes you suspended from Activity?") && sheet.buttons.contains("Resume 2 Processes")
                && sheet.texts.joined().contains("pid \(first.identity.pid)") && sheet.texts.joined().contains("pid \(second.identity.pid)"),
            "\(sheet.buttons)")
        answerActivitySheet(.alertFirstButtonReturn)
        check("and continues both", await eventually(10) { running(first.identity) && running(second.identity) && held.stoppedCount == 0 })

        // The quit question, in this isolated run: built as quitting asks it,
        // never run modal; its Resume and Quit continues what is stopped.
        check("nothing stopped: quitting asks nothing of Activity", TerminalWindowController.activityQuitAlert() == nil)
        (await verb("Suspend", of: first))?.perform()
        (await verb("Suspend", of: second))?.perform()
        _ = await eventually(10) { stopped(first.identity) && stopped(second.identity) && held.stoppedCount == 2 }
        let alert = TerminalWindowController.activityQuitAlert()
        check(
            "quitting asks: 2 processes you suspended from Activity are still stopped",
            alert?.messageText == "2 processes you suspended from Activity are still stopped"
                && alert?.buttons.map(\.title) == ["Resume and Quit", "Quit", "Cancel"], alert?.messageText ?? "no question")
        let again = TerminalWindowController.activityResumeAtQuit()
        check(
            "its Resume and Quit continues each first, nothing asked again", again == nil && running(first.identity) && running(second.identity) && held.stoppedCount == 0,
            again?.messageText ?? "")

        // A pane's job: suspended with its pane — the shell too —, resumed with its tab.
        if let job = await listed("/bin/sleep 173") {
            let shell = page.content.processes.first { $0.tab == tab.id && $0.owner?.paneRole == .shell }
            // Send a Signal ▸ STOP to it: the same route, but asked — the
            // pane named and the kill -STOP line —; Cancel stops nothing.
            app.activityAct(.send(.stop), job.identity)
            let asked = await eventually(10) { self.activitySheet().texts.contains("Suspend “sleep” (pid \(job.identity.pid)) with its pane?") }
            let words = activitySheet()
            check(
                "Send a Signal ▸ STOP to a pane's job asks, naming its pane and kill -STOP",
                asked && words.buttons.contains("Suspend Pane") && words.texts.joined().contains("kill -STOP") && words.texts.joined().contains("pid \(job.identity.pid)"),
                "\(words.buttons)")
            answerActivitySheet(.alertSecondButtonReturn)
            await pause(1)
            check("its Cancel stops nothing", !pane.isSuspended && running(job.identity))
            (await verb("Suspend", of: job))?.perform()
            check("a pane's job is suspended with its pane, unasked", await eventually(10) { pane.isSuspended } && window.attachedSheet == nil)
            check("its job and its shell stop", await eventually(10) { stopped(job.identity) && shell.map { stopped($0.identity) } == true })
            check("which is Suspend Tab's, not kept by Activity", held.stoppedCount == 0)
            let resumeTab = await offered("Resume", of: row("/bin/sleep 173") ?? job)
            check("Resume is offered for it: Resume Tab's", resumeTab != nil, said(row("/bin/sleep 173") ?? job))
            resumeTab?.perform()
            check(
                "its Resume resumes the tab", await eventually(10) { !pane.isSuspended && running(job.identity) && shell.map { running($0.identity) } == true })
        }

        // Run in Background: unasked, kept by identity; Run Normally back.
        if let batch = await listed("/bin/sleep 174") {
            let background = await verb("Run in Background", of: batch)
            check("Run in Background is offered, its key b", background?.unavailable == nil && background?.key == "b", background?.unavailable ?? "")
            page.selection = [batch.id]
            _ = page.press("b")
            check("b puts it in the background, unasked", await eventually(10) { held.backgroundHere.contains(batch.identity) } && window.attachedSheet == nil)
            let normally = await offered("Run Normally", of: batch)
            check("Run Normally is offered only now", normally != nil, said(batch))
            check("its row says background", await eventually(10) { row("/bin/sleep 174")?.backgroundHere == true })
            page.selection = []
            page.refreshVerbs()
            check("with nothing selected too", await eventually(10) { page.verbSubject == nil && row("/bin/sleep 174")?.backgroundHere == true })
            normally?.perform()
            check("and back", await eventually(10) { !held.backgroundHere.contains(batch.identity) })

            // Lower Priority: n chooses the step, then asks, saying it
            // can't be undone; Cancel changes nothing, the button its nice.
            let nice = kernel.process(batch.identity.pid).map { Int32($0.nice) } ?? 0
            let lowered = ActivityNiceStep.five.value(from: Int8(nice))
            page.selection = [batch.id]
            _ = page.press("n")
            let chooser = await eventually(10) { self.window.attachedSheet != nil } ? activitySheet() : (texts: [], buttons: [])
            check("n asks which step", chooser.texts.contains("Lower the priority of pid \(batch.identity.pid)"), "\(chooser.buttons)")
            answerActivitySheet(.alertFirstButtonReturn)
            // zsh starts a background job at nice 5 (`bg_nice`): read, never assumed.
            let title = "Lower the priority of “sleep” (pid \(batch.identity.pid)) to nice \(lowered)?"
            let asked = await eventually(10) { self.activitySheet().texts.contains(title) }
            let words = activitySheet()
            check(
                "+5 asks, saying only an administrator undoes it, and its renice",
                asked && words.texts.joined().contains("without an administrator") && words.texts.joined().contains("renice \(lowered) -p \(batch.identity.pid)"),
                "\(words.buttons)")
            answerActivitySheet(.alertSecondButtonReturn)
            await pause(1)
            check("Cancel changes nothing", kernel.process(batch.identity.pid).map { Int32($0.nice) } == nice)
            let step = (await verb("Lower Priority", of: batch))?.children.first
            check("its menu names the nice each step gives", step?.title == "+5 — nice \(lowered)…", step?.title ?? "none")
            step?.perform()
            _ = await eventually(10) { self.activitySheet().texts.contains(title) }
            answerActivitySheet(.alertFirstButtonReturn)
            check("the button raises its nice", await eventually(10) { kernel.process(batch.identity.pid).map { Int32($0.nice) } == lowered })
            check("the header says so", await eventually(10) { page.freeing?.contains("runs at nice \(lowered)") == true }, page.freeing ?? "")

            // At 20, no step gives anything: n asks nothing, and says why.
            if let lowest = (await verb("Lower Priority", of: batch))?.children.last {
                lowest.perform()
                _ = await eventually(10) { self.activitySheet().buttons.contains("Lower Priority") }
                answerActivitySheet(.alertFirstButtonReturn)
                _ = await eventually(10) { kernel.process(batch.identity.pid).map(\.nice) == 20 }
                await putAway()
                page.selection = [batch.id]
                _ = page.press("n")
                let said = await eventually(10) { self.activitySheet().texts.contains("Not changed") }
                check("at nice 20, n offers no step: said, not chosen", said && activitySheet().texts.joined().contains("already 20"), "\(activitySheet().texts)")
                await putAway()
            }
        }

        // The gate (10.3, 8): a priority aimed at a process the run didn't
        // start nor register — the harness that launched it — is refused
        // before anything is asked of the kernel, and its nice is unchanged.
        let outside = getppid()
        if outside > 1, let before = kernel.process(outside) {
            let target = ActivitySignalTarget(before.identity, path: kernel.path(of: outside))
            let lower = ProcessSignals().setPriority(.nice(Int32(before.nice) + 1), of: target)
            let background = ProcessSignals().setPriority(.background, of: target)
            check(
                "the gate refuses a Lower Priority and a Run in Background of what isn't the run's own",
                lower == .refused(.gate) && background == .refused(.gate), "\(lower), \(background)")
            check("and its nice is unchanged", kernel.process(outside).map(\.nice) == before.nice)
        } else {
            check("the gate's priority check has a process outside the run to aim at", false, "launched by launchd")
        }
        await putAway()
        page.selection = []
    }
}
#endif
