import AppKit
import Darwin

/// Activity's stage 2 verbs that change a process (docs/design/activity/
/// analysis.md, 6.10, 10.3) over the run's own children only — a pane's
/// processes, which the isolated-run gate admits and nothing else: ⌃C typed
/// into the pane reaching a raw-mode program as a key, Stop asked and
/// sent by token, a stopped job continued after its TERM, Stop that didn't
/// end it then Force Quit, "Stop it first?", Stop Its Tree, Group and
/// Parent, Send a Signal, "came back as pid N", the agent's verbs — Stop
/// Agent, and Interrupt Turn read as a key by a raw-mode stand-in — and the
/// pane's shell's close route. Checks say pids, counts and the sheets'
/// words about the run's own processes.
extension E2ERunner {
    func activitySignalChecks(tab: Tab) async {
        let page = app.activityPage
        let pane = tab.terminal
        let kernel = LiveActivityKernel()
        _ = page.press("1")
        page.setScope(.tab(tab.id), for: .processes)
        defer { page.setScope(.mac, for: .processes) }

        /// The tab's row whose masked command is `command` — a `/bin/sleep`
        /// exactly, anything else by a part of it (a script's name, a
        /// shell's `-c` line).
        func row(_ command: String) -> ActivityProcessRow? {
            let rows = page.content.processes.filter { $0.tab == tab.id && $0.state != .zombie }
            if command.hasPrefix("/bin/sleep ") && !command.contains("&") { return rows.first { $0.command == command } }
            return rows.first { $0.command?.contains(command) == true }
        }
        func listed(_ command: String) async -> ActivityProcessRow? {
            _ = await eventually(15) { row(command) != nil }
            return row(command)
        }
        func ended(_ identity: ActivityProcessID) async -> Bool {
            await eventually(10) { kernel.process(identity.pid).map { $0.identity != identity || $0.isZombie } ?? true }
        }
        /// `row` selected, and its verbs once its process is read off the
        /// main thread: greyed "being read" until then.
        func select(_ row: ActivityProcessRow) async {
            page.selection = [row.id]
            _ = await eventually(10) { page.verbSubject?.signal.identity == row.identity }
        }
        /// `title`'s verb of `row` pressed — a child of Send a Signal by its
        /// title too —, and its sheet's words once it shows.
        func asked(_ title: String, of row: ActivityProcessRow, child: String? = nil) async -> (texts: [String], buttons: [String])? {
            // A word left up by a check before — "Not sent" — is put away
            // first, so one failure doesn't answer the next sheet.
            if window.attachedSheet != nil {
                answerActivitySheet(.alertSecondButtonReturn)
                _ = await eventually(5) { self.window.attachedSheet == nil }
            }
            await select(row)
            var verb = page.verbs(for: [row.id]) { _ in }.first { $0.title == title }
            if let child { verb = verb?.children.first { $0.title == child } }
            guard let verb, verb.unavailable == nil else { return nil }
            verb.perform()
            guard await eventually(10, { self.window.attachedSheet != nil }) else { return nil }
            return activitySheet()
        }
        func saying(_ words: (texts: [String], buttons: [String])?, _ text: String) -> Bool {
            words?.texts.joined(separator: "\n").contains(text) == true
        }

        // ⌃C typed, raw-mode aware: a program with ISIG off reads ⌃C as a
        // byte — a SIGINT to its group would never reach it as one.
        let ready = out("activity-raw.ready")
        let got = out("activity-raw.got")
        let script = out("activity-raw.py")
        try? """
        import os, sys, tty
        tty.setraw(0)
        open("\(ready.path)", "w").write("ready")
        byte = os.read(0, 1)
        open("\(got.path)", "w").write(str(byte[0]))
        """.write(to: script, atomically: true, encoding: .utf8)
        pane.insertText("python3 \(script.path)")
        pane.pressReturn()
        let raw = await eventually(15) { FileManager.default.fileExists(atPath: ready.path) }
        let rawRow = await listed("activity-raw.py")
        check("a raw-mode program runs in the pane's foreground", raw && rawRow != nil)
        if let rawRow {
            await select(rawRow)
            let k = page.verbs(for: [rawRow.id]) { _ in }.first { $0.key == "k" }
            check("k on the pane's foreground job is Interrupt…", k?.title == "Interrupt…" && k?.unavailable == nil, k?.title ?? "none")
            _ = page.press("k")
            let sheet = await eventually(10) { self.window.attachedSheet != nil } ? activitySheet() : nil
            check(
                "asked: ⌃C typed into its pane, a key a raw-mode program reads its own way",
                sheet?.buttons.contains("Interrupt") == true && saying(sheet, "⌃C is typed into its pane") && saying(sheet, "raw mode")
                    && saying(sheet, "The command it equals: ⌃C in the pane"), "\(sheet?.buttons ?? [])")
            answerActivitySheet(.alertFirstButtonReturn)
            let byte = await eventually(10) { (try? String(contentsOf: got, encoding: .utf8)) == "3" }
            check("the program read ⌃C as the byte 3, not a signal", byte)
            check("and ended its own way", await ended(rawRow.identity))
        }
        _ = await eventually(5) { pane.foregroundGroup == nil || kernel.process(pane.foregroundGroup ?? 0)?.shortName.hasSuffix("sh") == true }

        // The run's own jobs, in the background.
        pane.insertText(
            "/bin/sleep 151 & /bin/sleep 153 & sh -c 'trap \"\" TERM; exec /bin/sleep 152' & sh -c '/bin/sleep 154 & /bin/sleep 154 & wait' & "
                + "/bin/sleep 155 | /bin/sleep 156 & /bin/sleep 158 & kill -STOP $! ; /bin/sleep 159 & "
                + "sh -c 'while true; do /bin/sleep 157; done' & python3 -c 'import os,time; os.fork() or os._exit(0); time.sleep(160)' &")
        pane.pressReturn()

        // Stop, asked: Cancel sends nothing; the button sends TERM by token.
        if let plain = await listed("/bin/sleep 151") {
            var sheet = await asked("Stop…", of: plain)
            check(
                "Stop… asks, naming it, its executable and the command it equals",
                sheet?.texts.contains("Stop “sleep” (pid \(plain.identity.pid))?") == true && saying(sheet, "Runs /bin/sleep")
                    && saying(sheet, "kill -TERM \(plain.identity.pid)") && sheet?.buttons.contains("Stop Process") == true, "\(sheet?.buttons ?? [])")
            answerActivitySheet(.alertSecondButtonReturn)
            await pause(1)
            check("Cancel sends nothing", kernel.process(plain.identity.pid)?.identity == plain.identity)
            sheet = await asked("Stop…", of: plain)
            answerActivitySheet(.alertFirstButtonReturn)
            check("the button stops it", await ended(plain.identity))
            check("and the header says so", await eventually(15) { page.freeing == "Stopped “sleep” (pid \(plain.identity.pid))" }, page.freeing ?? "")
        } else {
            check("a plain job is listed", false)
        }

        // A stopped job: continued right after its TERM, so it ends.
        if let stopped = await listed("/bin/sleep 158") {
            _ = await eventuallyAsync(10) { await self.app.activitySubject(stopped.identity)?.target.stopped != nil }
            _ = await eventually(10) { row("/bin/sleep 158")?.state == .stopped }
            let read = await app.activitySubject(stopped.identity)
            let sheet = await asked("Stop…", of: row("/bin/sleep 158") ?? stopped)
            check(
                "a stopped job's sheet says it is continued after", saying(sheet, "It is stopped: it is continued right after"),
                "state \(row("/bin/sleep 158")?.state.letter ?? "-"), stopped by \(read?.target.stopped.map { "\($0)" } ?? "nobody")")
            answerActivitySheet(.alertFirstButtonReturn)
            check("and the TERM ends it", await ended(stopped.identity))
        }

        // K with no Stop before it: "Stop it first?" — Cancel sends nothing.
        if let fresh = await listed("/bin/sleep 153") {
            page.selection = [fresh.id]
            _ = page.press("K")
            let shown = await eventually(10) { self.window.attachedSheet != nil }
            let sheet = activitySheet()
            check(
                "K with no Stop before: Stop it first?, with Stop, Force Quit and Cancel",
                shown && sheet.texts.contains { $0.contains("Stop it first?") } && sheet.buttons == ["Stop", "Force Quit", "Cancel"], "\(sheet.buttons)")
            answerActivitySheet(.alertThirdButtonReturn)
            await pause(1)
            check("Cancel sends nothing", kernel.process(fresh.identity.pid)?.identity == fresh.identity)
            _ = page.press("K")
            _ = await eventually(10) { self.window.attachedSheet != nil }
            answerActivitySheet(.alertSecondButtonReturn)
            // Its Force Quit sends nothing yet: Force Quit's own sheet,
            // naming the executable and the command it equals.
            let title = "Force Quit “sleep” (pid \(fresh.identity.pid))?"
            let own = await eventually(10) { self.activitySheet().texts.contains(title) }
            let words = activitySheet()
            check(
                "its Force Quit asks with Force Quit's own sheet: its executable and kill -KILL",
                own && saying(words, "Runs /bin/sleep") && saying(words, "kill -KILL \(fresh.identity.pid)") && words.buttons.contains("Force Quit"),
                "\(words.buttons)")
            check("nothing sent before that sheet's button", kernel.process(fresh.identity.pid)?.identity == fresh.identity)
            answerActivitySheet(.alertFirstButtonReturn)
            check("its Force Quit ends it", await ended(fresh.identity))
        }

        // A Stop that didn't end it: still running, then Force Quit plainly.
        if let stubborn = await listed("/bin/sleep 152") {
            _ = await asked("Stop…", of: stubborn)
            answerActivitySheet(.alertFirstButtonReturn)
            let still = await eventually(20) { page.freeing?.contains("still running — Force Quit…") == true }
            check("a Stop it ignores: still running — Force Quit…", still, page.freeing ?? "")
            let sheet = await asked("Force Quit…", of: stubborn)
            check(
                "Force Quit within two minutes: its own sheet, critical words, no Stop it first?",
                sheet?.texts.contains("Force Quit “sleep” (pid \(stubborn.identity.pid))?") == true && sheet?.buttons.contains("Force Quit") == true
                    && saying(sheet, "kill -KILL \(stubborn.identity.pid)"), "\(sheet?.buttons ?? [])")
            answerActivitySheet(.alertFirstButtonReturn)
            check("SIGKILL ends it", await ended(stubborn.identity))
        }

        // Stop Its Tree: the shell and its two sleeps, parents first.
        if let shell = await listed("/bin/sleep 154 & wait") {
            _ = await eventually(10) { page.content.processes.filter { $0.tab == tab.id && $0.command == "/bin/sleep 154" }.count == 2 }
            let members = page.content.processes.filter { $0.tab == tab.id && $0.command == "/bin/sleep 154" }.map(\.identity)
            let sheet = await asked("Stop Its Tree…", of: shell)
            check(
                "Stop Its Tree… lists each, 3 processes", sheet?.buttons.contains("Stop 3 Processes") == true && members.count == 2,
                "\(sheet?.buttons ?? []), \(members.count) sleeps")
            answerActivitySheet(.alertFirstButtonReturn)
            var all = await ended(shell.identity)
            for member in members { all = await ended(member) && all }
            check("the shell and both sleeps end", all)
        } else {
            check("a tree is listed", false)
        }

        // Stop Its Group: a pipeline's job, its leader and its sibling.
        if let leader = await listed("/bin/sleep 155"), let sibling = await listed("/bin/sleep 156") {
            let sheet = await asked("Stop Its Group…", of: leader)
            check(
                "Stop Its Group… on a pipeline's leader: killpg after every member is checked",
                sheet?.buttons.contains("Stop Group") == true && saying(sheet, "pid \(sibling.identity.pid)"), "\(sheet?.buttons ?? [])")
            answerActivitySheet(.alertFirstButtonReturn)
            let both = await ended(leader.identity)
            check("the leader and its sibling end", await ended(sibling.identity) && both)
        } else {
            check("a pipeline is listed", false)
        }

        // Send a Signal ▸ SIGHUP: asked, sent.
        if let hup = await listed("/bin/sleep 159") {
            let sheet = await asked("Send a Signal", of: hup, child: "SIGHUP…")
            check(
                "Send a Signal ▸ SIGHUP: asked as itself", sheet?.texts.contains("Send SIGHUP to “sleep” (pid \(hup.identity.pid))?") == true,
                "\(sheet?.buttons ?? [])")
            answerActivitySheet(.alertFirstButtonReturn)
            check("and sent", await ended(hup.identity))
        }

        // Came back: a supervisor's loop starts it again.
        if let looped = await listed("/bin/sleep 157") {
            let sheet = await asked("Stop…", of: looped)
            answerActivitySheet(.alertFirstButtonReturn)
            let back = await eventually(25) { page.freeing?.contains("came back as pid") == true }
            check("a supervised job: came back as pid N", back, "\(sheet?.buttons ?? []) — \(page.freeing ?? "nothing said")")
            _ = await eventually(15) { row("/bin/sleep 157").map { $0.identity != looped.identity } == true }
            if let again = row("/bin/sleep 157"), again.identity != looped.identity,
                let supervisor = page.content.processes.first(where: { $0.identity.pid == again.parentPID && $0.tab == tab.id })
            {
                // Stop Its Parent: asked about the supervisor, by its own
                // class — cancelled here, since its sleep would outlive it
                // outside the run's tab, where the gate keeps the run off it.
                let parentSheet = await asked("Stop Its Parent…", of: again)
                check(
                    "Stop Its Parent…: the supervisor's own Stop",
                    parentSheet?.texts.contains { $0.hasPrefix("Stop “") && $0.hasSuffix("(pid \(supervisor.identity.pid))?") } == true,
                    "\(parentSheet?.texts.first ?? "none")")
                answerActivitySheet(.alertSecondButtonReturn)
                _ = await asked("Stop Its Tree…", of: supervisor)
                answerActivitySheet(.alertFirstButtonReturn)
                let both = await ended(supervisor.identity)
                check("its tree, the supervisor and its sleep, ends", await ended(again.identity) && both)
            } else {
                check("the sleep started again is listed under its supervisor", false)
            }
        }

        // A zombie: refused; Stop Its Parent ends what doesn't collect it.
        let zombie = await eventually(15) { page.content.processes.contains { $0.tab == tab.id && $0.state == .zombie } }
        if zombie, let dead = page.content.processes.first(where: { $0.tab == tab.id && $0.state == .zombie }) {
            await select(dead)
            let stop = page.verbs(for: [dead.id]) { _ in }.first { $0.title == "Stop…" }
            check("a zombie's Stop is greyed: it has ended", stop?.unavailable == ActivitySignalCheck.ended)
            let parent = page.content.processes.first { $0.identity.pid == dead.parentPID }
            let sheet = await asked("Stop Its Parent…", of: dead)
            check("Stop Its Parent… asks about the parent", sheet?.texts.contains { $0.contains("(pid \(dead.parentPID))?") } == true, "\(sheet?.texts.first ?? "")")
            answerActivitySheet(.alertFirstButtonReturn)
            var parentEnded = false
            if let parent { parentEnded = await ended(parent.identity) }
            check("the parent ends", parentEnded)
            check("and the zombie with it", await eventually(10) { kernel.process(dead.identity.pid)?.identity != dead.identity })
        } else {
            check("a zombie is listed", false)
        }

        // The agent's verbs: Interrupt Turn greyed while it isn't the
        // pane's foreground job; Stop Agent critical, with its resume line.
        if let agent = page.content.processes.first(where: { $0.tab == tab.id && $0.owner?.paneRole == .agent }) {
            await select(agent)
            let verbs = page.verbs(for: [agent.id]) { _ in }
            check(
                "an agent's row: Interrupt Turn greyed in the background, Stop Agent its k",
                verbs.first { $0.title == "Interrupt Turn…" }?.unavailable == ActivitySignalCheck.agentNotForeground
                    && verbs.first { $0.key == "k" }?.title == "Stop Agent…")
            let sheet = await asked("Stop Agent…", of: agent)
            check(
                "Stop Agent… asks, its resume command said", sheet?.buttons.contains("Stop Agent") == true && saying(sheet, "claude --continue"),
                "\(sheet?.buttons ?? [])")
            answerActivitySheet(.alertFirstButtonReturn)
            check("the stand-in agent stops", await ended(agent.identity))
        } else {
            check("the stand-in agent is listed", false)
        }

        // Interrupt Turn: a stand-in agent in the pane's foreground, in raw
        // mode as Claude Code's prompt is, reads the ⌃C typed as a key.
        let turnReady = out("activity-turn.ready")
        let turnGot = out("activity-turn.got")
        let turnScript = out("activity-turn.py")
        try? """
        import os, sys, tty
        tty.setraw(0)
        open("\(turnReady.path)", "w").write("ready")
        byte = os.read(0, 1)
        open("\(turnGot.path)", "w").write(str(byte[0]))
        """.write(to: turnScript, atomically: true, encoding: .utf8)
        _ = await eventually(5) { pane.foregroundGroup == nil || kernel.process(pane.foregroundGroup ?? 0)?.shortName.hasSuffix("sh") == true }
        pane.insertText("(exec -a claude python3 \(turnScript.path))")
        pane.pressReturn()
        let turnRuns = await eventually(15) { FileManager.default.fileExists(atPath: turnReady.path) }
        func foregroundAgent() -> ActivityProcessRow? {
            page.content.processes.first { $0.tab == tab.id && $0.owner?.paneRole == .agent && $0.state != .zombie && $0.identity.pid == pane.foregroundGroup }
        }
        _ = await eventually(15) { foregroundAgent() != nil }
        if turnRuns, let agent = foregroundAgent() {
            await select(agent)
            let offered = await eventually(10) { page.verbs(for: [agent.id]) { _ in }.first { $0.title == "Interrupt Turn…" }?.unavailable == nil }
            check("Interrupt Turn… is offered for the agent in the pane's foreground", offered)
            let sheet = await asked("Interrupt Turn…", of: agent)
            check(
                "Interrupt Turn… asks plainly: ⌃C typed into the agent's pane",
                sheet?.buttons.contains("Interrupt Turn") == true && sheet?.texts.contains("Interrupt Claude's turn?") == true
                    && saying(sheet, "⌃C is typed into Claude's pane"), "\(sheet?.buttons ?? [])")
            answerActivitySheet(.alertFirstButtonReturn)
            let got = await eventually(10) { (try? String(contentsOf: turnGot, encoding: .utf8)) == "3" }
            check("the agent read ⌃C as the byte 3: its turn interrupted, its own way", got)
            check("and the stand-in ended its own way", await ended(agent.identity))
        } else {
            check("a stand-in agent runs in the pane's foreground", false)
        }

        // The pane's shell: its close route, asked — cancelled here.
        if let shell = page.content.processes.first(where: { $0.tab == tab.id && $0.owner?.paneRole == .shell }) {
            await select(shell)
            let k = page.verbs(for: [shell.id]) { _ in }.first { $0.key == "k" }
            check("the pane's shell: Close Its Pane…, never a signal", k?.title == "Close Its Pane…")
            let sheet = await asked("Close Its Pane…", of: shell)
            check("asked as the tab's close", sheet?.buttons.contains("Close Tab") == true || sheet?.buttons.contains("Close Pane") == true, "\(sheet?.buttons ?? [])")
            answerActivitySheet(.alertSecondButtonReturn)
            await pause(1)
            check("Cancel leaves the tab", app.store.tabs.contains { $0.id == tab.id } && kernel.process(shell.identity.pid)?.identity == shell.identity)
        }
        page.selection = []
        check("the header's last word goes", await eventually(30) { page.freeing == nil }, page.freeing ?? "")
    }
}
