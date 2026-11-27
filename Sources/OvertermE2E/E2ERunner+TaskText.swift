#if E2E
import AppKit
import Foundation

/// New Task's text (P05, GIT-G11): typed into the task's agent once it is
/// up, then Return on its own — and never into a shell whose agent didn't
/// start. The agent is a stand-in: argv[0] claude, raw, writing what it
/// reads to a file; no real agent starts in a test run.
extension E2ERunner {
    func taskTextChecks() async {
        guard let tab = app.store.selected else { return check("the task's tab", false) }
        let pane = tab.terminal
        let task = "Sepete kupon kodu alanı ekle"

        // No agent comes up: the text waits, then is given up; the shell
        // gets nothing.
        var said: [TerminalWindowController.TaskTextOutcome] = []
        app.taskTextRecorder = { said.append($0) }
        let gaveUp = await app.sendTaskText(task, to: tab, branch: "feat/e2e-task", timeout: 2)
        check("with no agent up, the text isn't sent", gaveUp != .sent && said.count == 1, "\(gaveUp)")
        check("and the shell got nothing of it", pane.visibleText?.contains(task) != true)

        // A stand-in Claude Code, built as ImagePaste's is: named `node`,
        // run under argv[0] claude, reading raw into a file.
        let got = scratch.appendingPathComponent("task-text")
        let node = scratch.appendingPathComponent("task-node").path
        pane.insertText(
            "printf '#include <stdlib.h>\\nint main(int c, char **v) { return system(v[1]); }\\n' | cc -x c - -o \(node) && "
                + "(exec -a claude \(node) 'stty raw -echo; printf \"> \"; cat > \(got.path)')")
        pane.pressReturn()
        let sent = await app.sendTaskText(task, to: tab, branch: "feat/e2e-task", timeout: 30)
        check("once the agent is up, the text is sent", sent == .sent, "\(sent)")
        let read = await eventually(5) {
            (try? String(contentsOf: got, encoding: .utf8)).map { $0.contains(task) && $0.hasSuffix("\r") } == true
        }
        let bytes = (try? String(contentsOf: got, encoding: .utf8)) ?? "nothing"
        check("the agent reads it, then Return on its own", read, bytes.debugDescription)
        app.taskTextRecorder = nil
        // The stand-in goes with its tab.
        app.closeTabsWithoutAsking([tab])
    }
}
#endif
