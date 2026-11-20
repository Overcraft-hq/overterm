import AppKit

/// ⌘V with only a picture on the clipboard: an agent gets ⌃V (it reads the
/// image itself); a shell gets nothing new. On a pasteboard of the run's
/// own — never the user's clipboard.
extension E2ERunner {
    func imagePasteScenario() async {
        let board = NSPasteboard(name: NSPasteboard.Name("overterm-e2e-\(UUID())"))
        board.clearContents()
        board.setData(Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]), forType: .png)
        ImagePaste.override = board
        defer { ImagePaste.override = nil }

        guard let pane = app.store.selected?.terminal else { return check("a pane", false) }
        check("the shell is up", await eventually { pane.shellReported })
        func commandV() -> NSEvent {
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: "v", charactersIgnoringModifiers: "v", isARepeat: false,
                keyCode: 9)!
        }
        window.makeFirstResponder(pane)

        // A stand-in Claude Code: argv[0] claude, the first byte it reads, in hex.
        let got = scratch.appendingPathComponent("agent-byte")
        // A stand-in Claude Code named `node` (its npm install runs as
        // node), built in the pane: a name that can't host an agent — bash,
        // the stand-in's own shell — is never read for its argv inside the
        // key equivalent, and the name a process runs as is its executable
        // file's, never a link's (a copy of a system binary isn't allowed
        // to run). It runs, under argv[0] claude, a shell that reads the
        // byte: both in the pane's foreground group. /usr/bin/python3 is a
        // shim that runs Python under its own name. In a subshell: the
        // pane's own shell must outlive it, or its tab closes and the run
        // with it.
        let node = scratch.appendingPathComponent("node").path
        pane.insertText(
            "printf '#include <stdlib.h>\\nint main(int c, char **v) { return system(v[1]); }\\n' | cc -x c - -o \(node) && "
                + "(exec -a claude \(node) 'stty raw -echo; dd bs=1 count=1 2>/dev/null | xxd -p > \(got.path)')")
        pane.pressReturn()
        // As the key equivalent reads it: the surface's foreground group.
        func agentHasKeyboard(_ pane: TerminalView) -> Bool {
            ImagePaste.agentHasKeyboard(foreground: pane.surface.flatMap { ImagePaste.foregroundGroup(of: $0) })
        }
        check("the agent has the keyboard", await eventually(10) { agentHasKeyboard(pane) })
        await pause(0.3)
        check("⌘V is taken", pane.performKeyEquivalent(with: commandV()))
        let byte = await eventually(5) { (try? String(contentsOf: got, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) == "16" }
        check("the agent gets ⌃V, to read the image", byte, (try? String(contentsOf: got, encoding: .utf8)) ?? "nothing")

        // A shell: nothing changes — ⌃V there would be quoted-insert.
        app.newTab(in: scratch)
        guard let shell = app.store.selected?.terminal, shell !== pane else { return check("a second pane", false) }
        check("its shell is up", await eventually { shell.shellReported })
        window.makeFirstResponder(shell)
        check("no agent there", !agentHasKeyboard(shell))
        check("so ⌘V is not turned into ⌃V", !ImagePaste.clipboardHasOnlyImage() || !agentHasKeyboard(shell))
    }
}
