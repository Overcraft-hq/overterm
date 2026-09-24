import AppKit
import Carbon.HIToolbox

/// End-to-end scenarios, run inside the real app: `TERMINUS_E2E=<scenario>`.
///
/// Each drives the product the way a person would — key events into the
/// terminal, menu actions, clicks on sheet buttons — but only ever into its
/// own window (events go through `window.sendEvent`, never the system
/// queue), in an isolated run (see AppEnvironment). It prints one line per
/// check (`E2E PASS …` / `E2E FAIL …`), then `E2E DONE <failures>`, and exits
/// with the failure count. Tests/TerminusE2ETests launches one process per
/// scenario and asserts on that.
@MainActor
final class E2ERunner {
    static let scenarios: [String: (E2ERunner) async -> Void] = [
        "terminal": { await $0.terminal() },
        "tabs": { await $0.tabs() },
        "rename": { await $0.rename() },
        "pin": { await $0.pin() },
        "close": { await $0.close() },
        "editor": { await $0.editorScenario() },
        "diff": { await $0.diffScenario() },
        "layout": { await $0.layout() },
        "session": { await $0.session() },
        "task": { await $0.task() },
        "snippets": { await $0.snippetsScenario() },
        "attention": { await $0.attention() },
        "marks": { await $0.marks() },
        "palette": { await $0.paletteScenario() },
        "reorder": { await $0.reorder() },
        "info": { await $0.info() },
        "claude": { await $0.claudeInfo() },
        "disk": { await $0.diskInfo() },
        "follow": { await $0.follow() },
        "spotlight": { await $0.spotlightScenario() },
    ]

    private let app: TerminalWindowController
    private var failures = 0
    /// Scratch space for this run; removed at the end.
    private let scratch = FileManager.default.temporaryDirectory
        .appendingPathComponent("terminus-e2e-\(UUID().uuidString)", isDirectory: true)

    init(app: TerminalWindowController) {
        self.app = app
    }

    static func start(_ name: String, app: TerminalWindowController) {
        let runner = E2ERunner(app: app)
        Task { @MainActor in
            try? FileManager.default.createDirectory(at: runner.scratch, withIntermediateDirectories: true)
            if let scenario = scenarios[name] {
                await scenario(runner)
            } else {
                runner.check("scenario exists", false, "unknown scenario \(name)")
            }
            try? FileManager.default.removeItem(at: runner.scratch)
            print("E2E DONE \(runner.failures)")
            fflush(stdout)
            exit(Int32(min(runner.failures, 100)))
        }
    }

    // MARK: Primitives

    private func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
        if !ok { failures += 1 }
        let suffix = ok ? "" : " — \(detail())"
        print("E2E \(ok ? "PASS" : "FAIL") \(name)\(suffix)")
        fflush(stdout)
    }

    /// Polls until `condition` holds or `timeout` passes. Returns whether it held.
    @discardableResult
    private func eventually(_ timeout: TimeInterval = 10, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return false }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return true
    }

    private func pause(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private var window: NSWindow { app.window! }
    private var terminal: TerminalView? { app.store.selected?.terminal }

    /// Waits for the selected tab's shell to be at a prompt (shell
    /// integration reported it), so typed input isn't swallowed by startup.
    @discardableResult
    private func waitForPrompt() async -> Bool {
        await eventually(15) {
            self.terminal?.surface != nil && self.terminal?.shellReported == true && self.terminal?.needsConfirmClose == false
        }
    }

    /// At a prompt, and past the moment a shell may still be reading the
    /// terminal while drawing it (see runAndExpect).
    private func settledPrompt() async {
        await waitForPrompt()
        await pause(0.4)
    }

    /// Types `text` as key-down events into the key view, like a keyboard
    /// would (US layout), through the window — i.e. TerminalView.keyDown,
    /// interpretKeyEvents, libghostty's key encoder, the pty.
    private func type(_ text: String) {
        for char in text {
            guard let (code, shift) = Self.keyCode(for: char) else {
                check("typeable character", false, "no key for \(char)")
                continue
            }
            let s = String(char)
            let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: shift ? .shift : [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                characters: s, charactersIgnoringModifiers: s.lowercased(), isARepeat: false, keyCode: code)!
            window.sendEvent(event)
        }
    }

    private func pressReturn() {
        let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false,
            keyCode: UInt16(kVK_Return))!
        window.sendEvent(event)
    }

    /// Runs a command by typing it, then waits for `file` to have `content`.
    ///
    /// Types only at a settled prompt: while drawing a new prompt, a shell
    /// (its theme, plugins, integration) may query the terminal and read the
    /// reply — swallowing keys typed in that window, which is wider under
    /// load. If the output still doesn't come, the command is typed once
    /// more; these commands only write a file, so a second run is harmless.
    private func runAndExpect(_ command: String, file: URL, content: String, _ name: String) async {
        func done() -> Bool {
            (try? String(contentsOf: file, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) == content
        }
        var ok = false
        for _ in 0..<2 where !ok {
            await settledPrompt()
            type(command)
            pressReturn()
            ok = await eventually(8) { done() }
        }
        check(name, ok, "\(file.lastPathComponent) = \((try? String(contentsOf: file, encoding: .utf8)) ?? "missing")")
    }

    /// Clicks the button titled `title` in the window's attached sheet.
    @discardableResult
    private func clickSheetButton(_ title: String) -> Bool {
        guard let sheet = window.attachedSheet, let button = Self.find(NSButton.self, in: sheet.contentView, where: { $0.title == title })
        else { return false }
        button.performClick(nil)
        return true
    }

    private func sheetTexts() -> [String] {
        guard let root = window.attachedSheet?.contentView else { return [] }
        var texts: [String] = []
        func walk(_ v: NSView) {
            if let field = v as? NSTextField { texts.append(field.stringValue) }
            v.subviews.forEach(walk)
        }
        walk(root)
        return texts
    }

    private static func find<T: NSView>(_ type: T.Type, in view: NSView?, where match: (T) -> Bool) -> T? {
        guard let view else { return nil }
        if let hit = view as? T, match(hit) { return hit }
        for sub in view.subviews {
            if let hit = find(type, in: sub, where: match) { return hit }
        }
        return nil
    }

    private func git(_ args: [String], in dir: URL) async throws {
        _ = try await Git.run(["-c", "user.email=e2e@terminus", "-c", "user.name=e2e"] + args, in: dir)
    }

    /// A shell-safe path for typing (the scratch path has no spaces).
    private func out(_ name: String) -> URL { scratch.appendingPathComponent(name) }

    // MARK: Scenarios

    /// Keyboard → TerminalView → libghostty → pty → shell, from the bundle.
    private func terminal() async {
        check("a surface exists", terminal?.surface != nil)
        check("shell reaches its prompt", await waitForPrompt())
        await runAndExpect("echo $TERM > \(out("term").path)", file: out("term"), content: "xterm-ghostty", "typed command runs; TERM is xterm-ghostty")
        await runAndExpect(
            "echo ${GHOSTTY_SHELL_FEATURES:+integrated} > \(out("si").path)", file: out("si"), content: "integrated", "shell integration is on")
        await runAndExpect("echo 'Mixed Case_!' > \(out("chars").path)", file: out("chars"), content: "Mixed Case_!", "shifted characters survive")
    }

    /// New tab inherits the cwd; tab keys; cwd follows cd.
    private func tabs() async {
        await waitForPrompt()
        let dir = scratch.appendingPathComponent("here")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        type("cd \(dir.path)")
        pressReturn()
        let resolved = dir.resolvingSymlinksInPath().path
        let followed = await eventually {
            app.store.selected?.workingDirectory.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path } == resolved
        }
        check("cd reaches the tab's working directory (OSC 7)", followed, app.store.selected?.workingDirectory ?? "nil")
        check("the file tree follows the cd", await eventually { self.app.tree.root?.resolvingSymlinksInPath().path == resolved })

        app.newTab(nil)
        check("⌘T opens a second tab", app.store.tabs.count == 2)
        check("the new tab is selected", app.store.selectedIndex == 1)
        let inherited = app.store.selected?.workingDirectory.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
        check("the new tab starts in the same directory", inherited == resolved, inherited ?? "nil")
        await settledPrompt()
        await runAndExpect("pwd > \(out("pwd").path)", file: out("pwd"), content: dir.path, "and its shell really is there")

        check("goto_tab 1", app.gotoTab(1) && app.store.selectedIndex == 0)
        app.selectNextTab(nil)
        check("next tab", app.store.selectedIndex == 1)
        app.selectNextTab(nil)
        check("next tab wraps", app.store.selectedIndex == 0)
        await eventually(2) { self.window.firstResponder === self.app.store.selected?.terminal }
        check("the selected tab's terminal has the keyboard", window.firstResponder === app.store.selected?.terminal)
    }

    /// Rename in place: starts with focus, keeps it, commits on Return.
    private func rename() async {
        guard let tab = app.store.selected else { return check("a tab", false) }
        app.menu(for: tab).items.first { $0.title == "Rename Tab…" }.map { item in
            _ = (item.target as? NSObject)?.perform(item.action, with: item)
        }
        let editing = await eventually(2) { self.window.firstResponder is NSTextView && self.app.store.renamingID == tab.id }
        check("Rename Tab… puts the keyboard in the name field", editing, String(describing: window.firstResponder))
        await pause(0.5)
        check("and it stays there", app.store.renamingID == tab.id && window.firstResponder is NSTextView)
        if let editor = window.firstResponder as? NSTextView {
            editor.selectAll(nil)
            editor.insertText("feat/e2e", replacementRange: editor.selectedRange())
            editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        }
        check("Return commits the name", await eventually(2) { tab.customTitle == "feat/e2e" }, tab.title)
        check("editing ends", app.store.renamingID == nil)
        check("the keyboard goes back to the terminal", await eventually(2) { self.window.firstResponder === tab.terminal })
    }

    /// Pinning reorders, protects from ⌘W, and unpins.
    private func pin() async {
        app.newTab(nil)
        guard let second = app.store.selected, let first = app.store.tabs.first else { return check("two tabs", false) }
        app.menu(for: second).items.first { $0.title == "Pin Tab" }.map { item in
            _ = (item.target as? NSObject)?.perform(item.action, with: item)
        }
        check("Pin Tab moves it first", app.store.tabs.first === second && second.isPinned)
        app.closeSelectedTab(nil)
        await pause(0.3)
        check("⌘W on a pinned tab does nothing", window.attachedSheet == nil && app.store.tabs.count == 2)
        let items = app.menu(for: second).items.map(\.title)
        // The menu auto-enables: an item shows disabled when it has no action.
        let close = app.menu(for: second).items.first { $0.title == "Close Tab" }
        check("its menu offers Unpin, and Close is disabled", items.contains("Unpin Tab") && close != nil && close?.action == nil)
        check("Color submenu has the swatches", app.menu(for: first).items.first { $0.title == "Color" }?.submenu?.items.count ?? 0 >= 9)
        app.store.setPinned(second, false)
        check("Unpin restores it", !second.isPinned)
    }

    /// Closing asks; Cancel keeps; Close closes; a shell's exit doesn't ask.
    private func close() async {
        await waitForPrompt()
        app.newTab(nil)
        await waitForPrompt()
        app.closeSelectedTab(nil)
        check("Close Tab asks", await eventually(2) { self.window.attachedSheet != nil })
        check("and says the shell is idle", sheetTexts().contains("Its shell is idle."), sheetTexts().joined(separator: " | "))
        clickSheetButton("Cancel")
        await pause(0.3)
        check("Cancel keeps the tab", app.store.tabs.count == 2)

        app.closeSelectedTab(nil)
        await eventually(2) { self.window.attachedSheet != nil }
        clickSheetButton("Close Tab")
        check("Close Tab closes it", await eventually(3) { self.app.store.tabs.count == 1 })

        app.newTab(nil)
        var running = false
        for _ in 0..<2 where !running {
            await settledPrompt()
            type("sleep 30")
            pressReturn()
            running = await eventually(5) { self.app.store.selected?.terminal.needsConfirmClose == true }
        }
        check("a running command is seen", running)
        app.closeSelectedTab(nil)
        await eventually(2) { self.window.attachedSheet != nil }
        check("the warning names the running tab", sheetTexts().contains { $0.hasPrefix("Still running:") }, sheetTexts().joined(separator: " | "))
        clickSheetButton("Close Tab")
        await eventually(3) { self.app.store.tabs.count == 1 }

        app.newTab(nil)
        var closed = false
        for _ in 0..<2 where !closed {
            await settledPrompt()
            type("exit")
            pressReturn()
            closed = await eventually(6) { self.app.store.tabs.count == 1 }
        }
        check("exit closes the tab without asking", closed && window.attachedSheet == nil, "tabs \(app.store.tabs.count), sheet \(window.attachedSheet != nil)")

        check("closing the window asks", app.windowShouldClose(window) == false && window.attachedSheet != nil)
        clickSheetButton("Cancel")
    }

    /// Open from the tree's action, edit, save; reload on outside change.
    private func editorScenario() async {
        let file = out("hello.swift")
        try? "let greeting = \"hi\"\n// comment\n".write(to: file, atomically: true, encoding: .utf8)
        app.openInEditor(file)
        guard let editor = app.editor else { return check("editor exists", false) }
        check("the editor pane opens", await eventually(2) { self.app.editorItem?.isCollapsed == false })
        check("it shows the file", editor.document.url == file && editor.document.text.hasPrefix("let greeting"))
        let textView = Self.find(NSTextView.self, in: editor.view) { _ in true }
        check("the text is in the text view", textView?.string.hasPrefix("let greeting") == true)
        check("the text is laid out (not a 0-wide container)", (textView?.frame.width ?? 0) > 100, "\(textView?.frame.width ?? 0)")
        check("the header names the file", await eventually(2) { Self.find(NSTextField.self, in: editor.view) { $0.stringValue == "hello.swift" } != nil })
        let colored = textView?.textStorage.map { storage -> Bool in
            let kw = storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
            let plain = storage.attribute(.foregroundColor, at: 4, effectiveRange: nil) as? NSColor
            return kw != nil && kw != plain
        }
        check("syntax colours apply", colored == true)

        textView?.setSelectedRange(NSRange(location: (textView?.string as NSString?)?.length ?? 0, length: 0))
        textView?.insertText("let added = 1\n", replacementRange: textView?.selectedRange() ?? NSRange())
        check("an edit marks it unsaved", editor.document.isDirty)
        editor.saveDocument(nil)
        check("⌘S writes the file", (try? String(contentsOf: file, encoding: .utf8))?.contains("let added = 1") == true)
        check("and clears the unsaved mark", !editor.document.isDirty)

        try? "rewritten by an agent\n".write(to: file, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: file.path)
        editor.reloadIfChangedOnDisk()
        check("an outside change reloads it", textView?.string == "rewritten by an agent\n")

        let bin = out("blob.bin")
        try? Data([0, 1, 2, 3]).write(to: bin)
        app.openInEditor(bin)
        check("a binary file is refused, with a reason", await eventually(2) { editor.document.unavailable == "Binary file." })
    }

    /// Badge counts, pane with cards, stage, commit — in a repo with no commit yet.
    private func diffScenario() async {
        let repo = scratch.appendingPathComponent("repo")
        try? FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try? await git(["init", "-q", "-b", "main"], in: repo)
        try? "ddd\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try? await git(["add", "a.txt"], in: repo)
        try? "ddd\neee\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try? "x\n".write(to: repo.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)

        app.newTab(in: repo)
        check("the model follows the tab into the repo", await eventually { self.app.diff.root?.resolvingSymlinksInPath() == repo.resolvingSymlinksInPath() })
        check("badge counts, before the first commit", await eventually { self.app.diff.totals.added == 3 }, "\(app.diff.totals)")
        check("no diff text while the pane is closed", app.diff.diffs.isEmpty)
        app.toggleDiff(nil)
        check("the pane opens", await eventually(2) { self.app.diffItem?.isCollapsed == false })
        check("every file gets its diff", await eventually { self.app.diff.diffs.count == 2 })
        check("the diff has the new lines", app.diff.diffs["a.txt"]?.lines.filter { $0.kind == .added }.map(\.text) == ["ddd", "eee"])

        guard let b = app.diff.files.first(where: { $0.path == "b.txt" }) else { return check("b.txt listed", false) }
        await app.diff.toggleStaged(b)
        check("staging", await eventually { self.app.diff.files.first { $0.path == "b.txt" }?.stageState == .full })
        let committed = await app.diff.commitAll(message: "e2e commit")
        let emptied = await eventually { self.app.diff.files.isEmpty }
        check("Commit All commits everything", committed && emptied)
        let log = (try? await Git.run(["log", "--format=%s"], in: repo))?.trimmingCharacters(in: .whitespacesAndNewlines)
        check("the commit is in git", log == "e2e commit", log ?? "nil")
        check("the badge clears", app.diff.totals.added == 0)
        app.toggleDiff(nil)
    }

    /// Dividers can be grabbed next to the 1 pt line and dragged.
    private func layout() async {
        if app.sidebarItem?.isCollapsed == true { app.toggleFileTree(nil) }
        await pause(0.5)
        let splitView = app.split.splitView
        guard let sidebar = app.sidebarItem?.viewController.view else { return check("sidebar", false) }
        let before = sidebar.frame.width
        let x = sidebar.superview!.frame.maxX + splitView.dividerThickness / 2 + 3
        let start = splitView.convert(NSPoint(x: x, y: splitView.bounds.midY), to: nil)
        let end = NSPoint(x: start.x + 80, y: start.y)
        func mouse(_ type: NSEvent.EventType, _ p: NSPoint) -> NSEvent {
            NSEvent.mouseEvent(
                with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        NSApp.postEvent(mouse(.leftMouseDragged, end), atStart: false)
        NSApp.postEvent(mouse(.leftMouseUp, end), atStart: false)
        window.sendEvent(mouse(.leftMouseDown, start))
        check("the sidebar divider drags from 3 pt off the line", abs(sidebar.frame.width - before - 80) < 2, "\(before) → \(sidebar.frame.width)")
        let terminalWidth = app.store.selected?.terminal.frame.width ?? 0
        check("the terminal keeps its minimum", terminalWidth >= 240, "\(terminalWidth)")
    }

    /// A prepared session comes back; changes are autosaved.
    private func session() async {
        let tabs = app.store.tabs
        check("both saved tabs restored", tabs.count == 2, "\(tabs.count)")
        guard tabs.count == 2 else { return }
        check("pinned first, with its colour and name", tabs[0].isPinned && tabs[0].color == .green && tabs[0].title == "pinned one")
        check("the selection is restored", app.store.selectedIndex == 1)
        check("each in its directory", tabs[1].workingDirectory == ProcessInfo.processInfo.environment["TERMINUS_E2E_CWD"])
        tabs[1].customTitle = "renamed"
        let saved = await eventually(4) { SessionState.load()?.tabs.last?.customTitle == "renamed" }
        check("a change is autosaved", saved)
    }

    /// New Task: a worktree on a new branch next to the repo, a tab in it.
    private func task() async {
        let repo = scratch.appendingPathComponent("proj")
        try? FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try? await git(["init", "-q", "-b", "main"], in: repo)
        try? await git(["commit", "-q", "--allow-empty", "-m", "init"], in: repo)
        app.newTab(in: repo)
        check("the worktree list follows the tab", await eventually { self.app.worktrees.main?.branch == "main" })
        do {
            try await app.createTask(repo: repo, branch: "feat/e2e-task", base: "main", agent: nil)
        } catch {
            return check("createTask", false, error.localizedDescription)
        }
        let path = scratch.appendingPathComponent("proj-wt-feat-e2e-task")
        check("the worktree exists next to the repo", FileManager.default.fileExists(atPath: path.appendingPathComponent(".git").path))
        check("a tab opened in it, named after the branch", app.store.selected?.title == "feat/e2e-task" && app.store.selected?.workingDirectory == path.path)
        check("the worktree list shows it", await eventually { self.app.worktrees.worktrees.contains { $0.branch == "feat/e2e-task" } })
        await waitForPrompt()
        await runAndExpect("git branch --show-current > \(out("br").path)", file: out("br"), content: "feat/e2e-task", "its shell is on the new branch")
    }

    /// Snippets: starters seeded; Run types and executes; placeholders ask.
    private func snippetsScenario() async {
        check("first run seeds the starters", app.snippets.snippets.first?.command == "mise run validate")
        await waitForPrompt()
        app.useSnippet(Snippet(name: "e2e", command: "echo snippet-ran > \(out("snip").path)"), run: true)
        let ran = await eventually { (try? String(contentsOf: self.out("snip"), encoding: .utf8)) == "snippet-ran\n" }
        check("Run types it and presses Return (bracketed paste)", ran)
        app.useSnippet(Snippet(name: "p", command: "echo {{thing}}"), run: true)
        check("a placeholder asks first", await eventually(2) { self.window.attachedSheet != nil })
        clickSheetButton("Cancel")
    }

    /// Sends a terminal escape sequence from a tab's own shell, as an agent
    /// running there would.
    private func emit(_ sequence: String, from tab: Tab) {
        tab.terminal.insertText("printf '\\033]\(sequence)\\a'")
        tab.terminal.pressReturn()
    }

    /// What Claude Code sends — progress while working (OSC 9;4), a
    /// notification when it wants you (OSC 777) — marks a background tab.
    private func attention() async {
        await waitForPrompt()
        guard let first = app.store.selected else { return check("a tab", false) }
        app.newTab(nil)
        await waitForPrompt()
        let second = app.store.selected!

        emit("9;4;3;0", from: first)
        check("working: progress starts", await eventually { first.activity.isWorking })
        check("starting work is not a mark", first.activity.mark == .none)
        emit("9;4;0;0", from: first)
        check("done: work finished out of sight", await eventually { first.activity.mark == .done && !first.activity.isWorking })
        emit("777;notify;Claude Code;needs your permission", from: first)
        check("waiting: the agent's notification raises the mark", await eventually { first.activity.mark == .waiting })
        check("with the agent's text", first.activity.note == "Claude Code — needs your permission", first.activity.note ?? "nil")
        emit("9;4;0;0", from: first)
        await pause(0.5)
        check("a lesser signal doesn't hide that it wants you", first.activity.mark == .waiting)

        // From a tab in the background: the app can end up active during a
        // run, and the selected tab of an active app is "seen".
        app.newTab(nil)
        await waitForPrompt()
        emit("9;4;2;0", from: second)
        check("failed: error progress", await eventually { second.activity.mark == .failed })
        check("the Dock badge counts marked tabs", app.store.tabs.filter(\.activity.needsAttention).count == 2)
        // An inactive app would notify; an isolated run suppresses (counts) it.
        // (Under load the run's app can end up active — then there is nothing to notify.)
        check("no real notification from an isolated run", NSApp.isActive || AttentionNotifier.suppressed >= 1)
    }

    /// One tab in each state, for looking at: TERMINUS_DUMP_PNG=<png>
    /// captures the window once they are set.
    private func marks() async {
        let home = FileManager.default.homeDirectoryForCurrentUser
        await waitForPrompt()
        let shell = app.store.selected!
        shell.customTitle = "shell — done"
        app.newTab(in: home, agent: .claude, startAgent: false)
        let working = app.store.selected!
        working.customTitle = "feat/auth"
        app.newTab(in: home, agent: .codex, startAgent: false)
        let waiting = app.store.selected!
        waiting.customTitle = "fix/billing"
        app.newTab(in: home, agent: .claude, startAgent: false)
        let failed = app.store.selected!
        failed.customTitle = "chore/deps"
        app.newTab(in: home, agent: .claude, startAgent: false)
        let pinned = app.store.selected!
        app.store.setPinned(pinned, true)
        app.newTab(in: home)
        app.store.selected!.customTitle = "current"
        for tab in app.store.tabs { _ = await eventually(15) { tab.terminal.needsConfirmClose == false } }

        emit("9;4;3;0", from: working)
        emit("9;4;3;0", from: pinned)
        emit("9;4;3;0", from: shell)
        emit("777;notify;Codex;approve the migration?", from: waiting)
        emit("9;4;2;0", from: failed)
        check("working", await eventually { working.activity.isWorking && pinned.activity.isWorking })
        check("waiting", await eventually { waiting.activity.mark == .waiting })
        check("failed", await eventually { failed.activity.mark == .failed })
        _ = await eventually { shell.activity.isWorking }
        emit("9;4;0;0", from: shell)
        check("done", await eventually { shell.activity.mark == .done })
        if let png = ProcessInfo.processInfo.environment["TERMINUS_DUMP_PNG"] {
            await pause(0.6)
            app.captureWindow(to: png)
        }
    }

    /// A point in window coordinates at a tab's centre (tab frames are
    /// reported by the strip, top-left origin).
    private func point(inTab tab: Tab, dx: CGFloat = 0) -> NSPoint? {
        guard let frame = app.store.tabFrames[tab.id], let strip = app.tabBarView else { return nil }
        var p = NSPoint(x: frame.midX + dx, y: frame.midY)
        if !strip.isFlipped { p.y = strip.bounds.height - p.y }
        return strip.convert(p, to: nil)
    }

    /// A mouse drag as the system would dispatch it (NSApp.sendEvent, so the
    /// app's event monitors see it), from one point to another.
    /// `gap`: seconds between drag events. 0 sends them back to back, like
    /// a real hand faster than the strip can redraw.
    private func drag(from start: NSPoint, to end: NSPoint, steps: Int = 8, gap: Double = 0.02) async {
        func mouse(_ type: NSEvent.EventType, _ p: NSPoint) -> NSEvent {
            NSEvent.mouseEvent(
                with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        NSApp.sendEvent(mouse(.leftMouseDown, start))
        for step in 1...steps {
            let t = CGFloat(step) / CGFloat(steps)
            NSApp.sendEvent(mouse(.leftMouseDragged, NSPoint(x: start.x + (end.x - start.x) * t, y: start.y)))
            if gap > 0 { await pause(gap) }
        }
        NSApp.sendEvent(mouse(.leftMouseUp, end))
        await pause(0.2)
    }

    /// Dragging a tab reorders the strip (and doesn't move the window).
    private func reorder() async {
        guard let a = app.store.selected else { return check("a tab", false) }
        a.customTitle = "A"
        app.newTab(nil)
        app.store.selected?.customTitle = "B"
        app.newTab(nil)
        let c = app.store.selected!
        c.customTitle = "C"
        check("tab frames are reported", await eventually(3) { self.app.store.tabs.allSatisfy { self.app.store.tabFrames[$0.id] != nil } })
        // A real press that lands on the strip's window-drag view starts a
        // window move (an in-process event can't), and the tab never moves.
        // So check what a press at each tab, and between them, would hit.
        for tab in app.store.tabs {
            for dx in [-60.0, -20.0, 0.0, 20.0, 60.0] {
                guard let p = point(inTab: tab, dx: dx), let content = window.contentView,
                    let frame = app.store.tabFrames[tab.id], abs(dx) < frame.width / 2 - 2
                else { continue }
                let hit = content.hitTest(content.convert(p, from: nil))
                let name = hit.map { String(describing: Swift.type(of: $0)) } ?? "nil"
                check("a press on tab \(tab.title) (dx \(Int(dx))) doesn't hit the window-drag area", !name.contains("WindowDrag") && !(hit is WindowDragView), name)
            }
        }

        let windowOrigin = window.frame.origin
        // Past C's middle: that is what "after C" means (as in Chrome).
        guard let from = point(inTab: a), let to = point(inTab: c, dx: 30) else { return check("points", false) }
        await drag(from: from, to: to)
        check("dragging A past C's middle moves it after C", app.store.tabs.map(\.title) == ["B", "C", "A"], app.store.tabs.map(\.title).joined(separator: ","))
        check("the window didn't move", window.frame.origin == windowOrigin)
        check("the dragged tab is selected", app.store.selected?.title == "A")

        // Leftwards, to the very front — moving slowly, as a hand does, so the
        // strip redraws between events. A swap-on-hover rule flip-flopped
        // here: the strip's frames lag a move, the pointer still "hits" the
        // tab just swapped with, and they swap back.
        var orders: [[String]] = []
        let watch = app.store.$tabs.sink { tabs in orders.append(tabs.map(\.title)) }
        guard let fromA = point(inTab: a), let toB = point(inTab: app.store.tabs[0], dx: -30) else { return check("points", false) }
        await drag(from: fromA, to: toB, steps: 40, gap: 0)
        watch.cancel()
        check("dragging to the front puts it first", app.store.tabs.map(\.title) == ["A", "B", "C"], app.store.tabs.map(\.title).joined(separator: ","))
        let changes = zip(orders, orders.dropFirst()).filter { $0 != $1 }.count
        check("without flip-flopping on the way", changes <= 2, "\(changes) reorders: \(orders.map { $0.joined() })")

        app.store.setPinned(c, true)
        await pause(0.3)
        guard let from2 = point(inTab: a), let to2 = point(inTab: c) else { return check("points", false) }
        await drag(from: from2, to: to2)
        check("an unpinned tab can't be dragged into the pinned group", app.store.tabs.first?.title == "C")

        guard let tiny = point(inTab: a), let tiny2 = point(inTab: a, dx: 2) else { return }
        let before = app.store.tabs.map(\.title)
        await drag(from: tiny, to: tiny2)
        check("a click with a wobble is not a drag", app.store.tabs.map(\.title) == before)

        // A plain click still selects (the press goes through to the strip).
        guard let b = app.store.tabs.first(where: { $0.title == "B" }), let pb = point(inTab: b) else { return }
        await drag(from: pb, to: pb)
        check("a click selects the tab", await eventually(2) { self.app.store.selected?.title == "B" }, app.store.selected?.title ?? "nil")
    }

    /// Tab Info shows the tab's own processes, measured — and not another tab's.
    private func info() async {
        await waitForPrompt()
        let first = app.store.selected!
        type("sleep 61 &")
        pressReturn()
        app.newTab(nil)
        await waitForPrompt()
        type("sleep 62 &")
        pressReturn()
        await pause(0.5)

        // Back to the first tab: typing goes to the selected one.
        app.store.select(first)
        await eventually(2) { self.window.firstResponder === first.terminal }
        await runAndExpect(
            "echo ${TERMINUS_TAB_ID:-unset} > \(out("tag").path)", file: out("tag"), content: first.terminal.processTag,
            "the shell carries its own tab's tag")
        // A server on a port the OS picks; it writes the port where we can read it.
        let portFile = out("port")
        // The server's code goes in a file, so what is typed stays short and
        // plain — a long line of quotes and parentheses typed key by key is
        // at the mercy of the user's zsh plugins.
        let server = out("server.py")
        try? """
        import socket, time
        s = socket.socket()
        s.bind(("127.0.0.1", 0))
        s.listen()
        open("\(portFile.path)", "w").write(str(s.getsockname()[1]))
        time.sleep(60)
        """.write(to: server, atomically: true, encoding: .utf8)
        func readPort() -> Int? { (try? String(contentsOf: portFile, encoding: .utf8)).flatMap { Int($0) } }
        for _ in 0..<2 where readPort() == nil {
            await settledPrompt()
            type("python3 \(server.path) &")
            pressReturn()
            await eventually(10) { readPort() != nil }
        }
        let port = readPort()
        check("a dev server starts in the tab", port != nil)

        app.showInfo(for: first)
        check("the popover opens", await eventually(2) { self.app.infoPopover?.isShown == true })
        guard let model = app.infoModel else { return check("a model", false) }
        let listed = await eventually { model.processes.flatMap(\.flattened).contains { $0.command.hasPrefix("sleep 61") } }
        let all = model.processes.flatMap(\.flattened)
        check("its background job is listed", listed, all.map(\.command).joined(separator: " | "))
        check("under its shell", model.processes.contains { ["zsh", "bash", "fish", "sh"].contains($0.name) && $0.flattened.contains { $0.command.hasPrefix("sleep 61") } })
        check("the other tab's job is not", !all.contains { $0.command.hasPrefix("sleep 62") })
        check("memory is measured", model.totalMemory > 0)
        check("the location is the tab's directory", await eventually { model.location?.directory == first.workingDirectory })
        if let port {
            let shown = await eventually(8) { model.ports.contains { $0.port == port } }
            check("its listening port is shown", shown, "ports \(model.ports.map(\.port)) want \(port)")
        }
        if let png = ProcessInfo.processInfo.environment["TERMINUS_DUMP_PNG"], let popoverWindow = app.infoPopover?.contentViewController?.view.window {
            await pause(1.2)
            app.captureWindow(to: png, window: popoverWindow)
        }
        app.showSelectedTabInfo(nil)
        await eventually(2) { self.app.infoPopover == nil }
        check("closing it stops the refresh", app.infoModel == nil)
        // Leave no sleeps behind.
        all.filter { $0.name == "sleep" || $0.command.contains("socket.socket") }.forEach { kill($0.pid, SIGTERM) }
        for tab in app.store.tabs {
            tab.terminal.insertText("kill %1 2>/dev/null")
            tab.terminal.pressReturn()
        }
    }

    /// Tab Info reads a Claude tab's session transcript (a prepared one, in
    /// a scratch projects directory) and shows its token use, each reply
    /// counted once.
    private func claudeInfo() async {
        let projects = scratch.appendingPathComponent("claude-projects")
        ClaudeUsageReader.projectsDirectory = projects
        let dir = scratch.appendingPathComponent("proj")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        func reply(_ id: String, _ input: Int, _ output: Int, _ read: Int, _ time: String) -> String {
            #"{"type":"assistant","timestamp":"\#(time)","message":{"id":"\#(id)","model":"claude-opus-4-8","usage":{"input_tokens":\#(input),"output_tokens":\#(output),"cache_read_input_tokens":\#(read),"cache_creation_input_tokens":0}}}"#
                + "\n"
        }
        let transcript =
            reply("msg_a", 1200, 300, 40_000, "2026-09-23T10:00:00.000Z") + reply("msg_a", 1200, 300, 40_000, "2026-09-23T10:00:01.000Z")
            + reply("msg_b", 800, 700, 60_000, "2026-09-23T11:14:00.000Z")
        // The tab may report its cwd resolved (/private/var/…) or not.
        for path in Set([dir.path, dir.resolvingSymlinksInPath().path]) {
            let folder = projects.appendingPathComponent(ClaudeUsageReader.projectFolder(for: path))
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? transcript.write(to: folder.appendingPathComponent("session.jsonl"), atomically: true, encoding: .utf8)
        }

        app.newTab(in: dir, agent: .claude, startAgent: false)
        guard let tab = app.store.selected else { return check("a tab", false) }
        await eventually(3) { self.app.store.tabFrames[tab.id] != nil }
        app.showInfo(for: tab)
        guard let model = app.infoModel else { return check("popover", false) }
        check("the session is read", await eventually(6) { model.claude != nil }, model.claudeDirectory ?? "no directory")
        let usage = model.claude
        check("replies counted once", usage?.replies == 2, "\(usage?.replies ?? -1)")
        check("tokens add up", usage.map { [$0.input, $0.output, $0.cacheRead] } == [2000, 1000, 100_000], "\(String(describing: usage))")
        check("model and duration", usage?.model == "claude-opus-4-8" && usage?.lastActivity.map { $0.timeIntervalSince(usage!.started!) } == 74 * 60)
        if let png = ProcessInfo.processInfo.environment["TERMINUS_DUMP_PNG"], let popoverWindow = app.infoPopover?.contentViewController?.view.window {
            await pause(0.8)
            app.captureWindow(to: png, window: popoverWindow)
        }
    }

    /// Tab Info measures a checkout's disk use, biggest entries first — and
    /// doesn't walk a directory that isn't a checkout.
    private func diskInfo() async {
        await waitForPrompt()
        guard let home = app.store.selected else { return check("a tab", false) }
        await eventually(3) { self.app.store.tabFrames[home.id] != nil }
        app.showInfo(for: home)
        await pause(1.5)
        check("a tab outside a checkout isn't measured", app.infoModel?.disk == nil && app.infoModel?.measuringDisk == false)
        app.infoPopover?.close()

        let repo = scratch.appendingPathComponent("sized")
        for sub in ["node_modules/pkg", "src"] {
            try? FileManager.default.createDirectory(at: repo.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        try? Data(count: 900_000).write(to: repo.appendingPathComponent("node_modules/pkg/index.js"))
        try? Data(count: 30_000).write(to: repo.appendingPathComponent("src/app.ts"))
        try? await git(["init", "-q", "-b", "main"], in: repo)
        app.newTab(in: repo)
        guard let tab = app.store.selected else { return }
        await eventually(3) { self.app.store.tabFrames[tab.id] != nil }
        app.showInfo(for: tab)
        guard let model = app.infoModel else { return check("popover", false) }
        check("the checkout is measured", await eventually(8) { model.disk != nil })
        check("biggest first", model.disk?.largest.first?.name == "node_modules", model.disk?.largest.map(\.name).joined(separator: ",") ?? "nil")
        check("the total covers it", (model.disk?.total ?? 0) >= 930_000)
        if let png = ProcessInfo.processInfo.environment["TERMINUS_DUMP_PNG"], let popoverWindow = app.infoPopover?.contentViewController?.view.window {
            await pause(0.8)
            app.captureWindow(to: png, window: popoverWindow)
        }
    }

    /// The sidebar and diff follow the tab's agent into a worktree (as
    /// Claude Code's EnterWorktree does: it chdirs its process), can be
    /// attached to another checkout by hand, and detach back.
    private func follow() async {
        let repo = scratch.appendingPathComponent("mono")
        try? FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try? await git(["init", "-q", "-b", "main"], in: repo)
        try? await git(["commit", "-q", "--allow-empty", "-m", "init"], in: repo)
        let worktree = repo.appendingPathComponent(".worktrees/feat")
        try? await git(["worktree", "add", "-q", "-b", "feat", worktree.path], in: repo)
        try? "work in progress\n".write(to: worktree.appendingPathComponent("agent-change.txt"), atomically: true, encoding: .utf8)

        // A stand-in "claude": sleep run with argv[0] = claude (as the real
        // CLI appears), from a script that cds into the worktree first — the
        // shell itself stays in main. (A copy of /bin/sleep won't do: macOS
        // launch constraints kill relocated system binaries.)
        let script = scratch.appendingPathComponent("agent.sh")
        try? "cd '\(worktree.path)' && exec -a claude sleep 60\n".write(to: script, atomically: true, encoding: .utf8)

        app.newTab(in: repo)
        guard let tab = app.store.selected else { return check("a tab", false) }
        let main = repo.resolvingSymlinksInPath()
        let feat = worktree.resolvingSymlinksInPath()
        check("starts on the shell's checkout", await eventually { self.app.diff.root?.resolvingSymlinksInPath() == main })
        await settledPrompt()
        type("bash \(script.path) &")
        pressReturn()

        let followed = await eventually(10) { self.app.diff.root?.resolvingSymlinksInPath() == feat }
        let seen = ProcessInspector().tree(root: SurfaceProcesses.shared.loginPID(of: tab.terminal), tag: tab.terminal.processTag)
            .flatMap(\.flattened).map { "\($0.name)@\($0.workingDirectory ?? "?")" }.joined(separator: " ")
        check("follows the agent into its worktree", followed, "diff \(app.diff.root?.path ?? "nil"); agentDirectory \(tab.agentDirectory ?? "nil"); tab \(seen)")
        check("and says so", app.diff.showing == .agent(.claude))
        check("the tree follows too", app.tree.root?.resolvingSymlinksInPath() == feat)
        check("the agent's change is in the diff", await eventually { self.app.diff.files.contains { $0.path == "agent-change.txt" } })
        check("the worktree list marks it", app.worktrees.showing?.reason == .agent(.claude))

        guard let mainWorktree = app.worktrees.worktrees.first(where: \.isMain) else { return check("main worktree listed", false) }
        app.attach(mainWorktree)
        check("attaching pins it", await eventually(2) { self.app.diff.root?.resolvingSymlinksInPath() == main && self.app.diff.showing == .attached })
        await pause(2.5)
        check("and holds while the agent keeps working elsewhere", app.diff.showing == .attached)
        app.detach()
        check("detaching follows the agent again", await eventually(2) { self.app.diff.root?.resolvingSymlinksInPath() == feat })

        // The agent leaves (EnterWorktree's exit chdirs back; here it just ends).
        tab.terminal.insertText("kill %1")
        tab.terminal.pressReturn()
        check("when the agent is gone, back to the shell's checkout", await eventually(10) { self.app.diff.root?.resolvingSymlinksInPath() == main })
        check(
            "session keeps an attachment",
            {
                self.app.attach(mainWorktree)
                return self.app.sessionState.tabs.last?.attachedCheckout == mainWorktree.path.path
            }())
    }

    private func key(_ code: Int, _ characters: String) {
        let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: UInt16(code))!
        window.sendEvent(event)
    }

    /// The keyboard is in the overlay's own field — not just any text view
    /// (the editor is one too).
    private var spotlightHasKeyboard: Bool {
        guard let editor = window.firstResponder as? NSTextView, let field = editor.delegate as? NSTextField,
            let overlay = app.spotlightView
        else { return false }
        return field.isDescendant(of: overlay)
    }

    /// ⌘F: one search over the terminal, file names and file contents.
    private func spotlightScenario() async {
        let repo = scratch.appendingPathComponent("searchrepo")
        try? FileManager.default.createDirectory(at: repo.appendingPathComponent("src"), withIntermediateDirectories: true)
        try? "let a = 1\n\nlet needleword = 3\n".write(to: repo.appendingPathComponent("src/main.swift"), atomically: true, encoding: .utf8)
        try? "meeting notes\n".write(to: repo.appendingPathComponent("notes.md"), atomically: true, encoding: .utf8)
        try? await git(["init", "-q", "-b", "main"], in: repo)
        app.newTab(in: repo)
        guard let tab = app.store.selected else { return check("a tab", false) }
        await runAndExpect("echo needleword-in-the-shell > \(out("shell").path); echo needleword-in-the-shell", file: out("shell"), content: "needleword-in-the-shell", "output in the terminal")
        await eventually { self.app.diff.root != nil }

        // ⌘F with the terminal focused arrives as Ghostty's start_search.
        tab.terminal.perform(binding: "start_search")
        check("⌘F opens the overlay", await eventually(2) { self.app.spotlightView?.isHidden == false })
        check("with the keyboard in its field", await eventually(2) { self.spotlightHasKeyboard })
        type("needleword")
        let found = await eventually(5) {
            self.app.spotlight.rows.contains {
                if case .content(let m) = $0 { return m.path == "src/main.swift" }; return false
            }
                && (tab.terminal.search.total ?? 0) >= 1
        }
        check("finds it in the terminal and in a file", found, app.spotlight.rows.map(\.id).joined(separator: " | ") + " total \(tab.terminal.search.total ?? -1)")
        if let png = ProcessInfo.processInfo.environment["TERMINUS_DUMP_PNG"] {
            await pause(0.5)
            app.captureWindow(to: png)
        }
        if let i = app.spotlight.rows.firstIndex(where: {
            if case .content = $0 { return true }; return false
        }) {
            app.spotlight.selectedIndex = i
        }
        pressReturn()
        check(
            "Return on a line opens it in the editor, at that line",
            await eventually(3) {
                self.app.editor?.document.url?.lastPathComponent == "main.swift" && self.app.editor?.selectedLine == 3
            }, "\(app.editor?.document.url?.lastPathComponent ?? "nil") line \(app.editor?.selectedLine ?? -1)")
        check("and the overlay closes", app.spotlightView?.isHidden == true)
        check("ending the terminal search", tab.terminal.search.isActive == false)

        app.showSpotlight(for: tab.terminal, needle: nil)
        check("reopened after the editor had focus, the field takes the keyboard", await eventually(2) { self.spotlightHasKeyboard })
        type("notes")
        check("file names match", await eventually(5) { self.app.spotlight.rows.contains(.file("notes.md")) })
        if let i = app.spotlight.rows.firstIndex(of: .file("notes.md")) { app.spotlight.selectedIndex = i }
        pressReturn()
        check("Return on a file opens it", await eventually(3) { self.app.editor?.document.url?.lastPathComponent == "notes.md" })

        app.showSpotlight(for: tab.terminal, needle: "needleword")
        check("a needle can come in", app.spotlight.query == "needleword")
        await eventually(3) { (tab.terminal.search.total ?? 0) >= 1 }
        app.spotlight.selectedIndex = 0
        pressReturn()
        check(
            "the terminal row keeps the search, with the compact bar",
            await eventually(2) {
                self.app.spotlightView?.isHidden == true && tab.terminal.search.barVisible && self.app.searchBar?.isHidden == false
            })
        tab.terminal.search.end()
        check("closing the bar hides it", await eventually(2) { self.app.searchBar?.isHidden == true })

        app.showSpotlight(for: tab.terminal, needle: nil)
        await eventually(2) { self.spotlightHasKeyboard }
        key(53, "\u{1b}")
        check("Escape closes the overlay", await eventually(2) { self.app.spotlightView?.isHidden == true })
    }

    /// ⌘P shows, searches across kinds, and hides.
    private func paletteScenario() async {
        app.showPalette(nil)
        check("⌘P shows the palette", app.paletteView?.isHidden == false)
        check("it lists actions and tabs", app.palette.results.contains { $0.group == .action } && app.palette.results.contains { $0.group == .tab })
        app.palette.query = "ncl"
        check("fuzzy search finds New Claude Tab", app.palette.results.first?.title == "New Claude Tab")
        app.palette.query = "validate"
        check("snippets are searchable", app.palette.results.first?.group == .snippet)
        app.showPalette(nil)
        check("⌘P again hides it", app.paletteView?.isHidden == true)
    }

    // MARK: Keyboard map (US)

    private static let unshifted: [Character: Int] = [
        "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D, "e": kVK_ANSI_E, "f": kVK_ANSI_F, "g": kVK_ANSI_G,
        "h": kVK_ANSI_H, "i": kVK_ANSI_I, "j": kVK_ANSI_J, "k": kVK_ANSI_K, "l": kVK_ANSI_L, "m": kVK_ANSI_M, "n": kVK_ANSI_N,
        "o": kVK_ANSI_O, "p": kVK_ANSI_P, "q": kVK_ANSI_Q, "r": kVK_ANSI_R, "s": kVK_ANSI_S, "t": kVK_ANSI_T, "u": kVK_ANSI_U,
        "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X, "y": kVK_ANSI_Y, "z": kVK_ANSI_Z,
        "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3, "4": kVK_ANSI_4, "5": kVK_ANSI_5, "6": kVK_ANSI_6,
        "7": kVK_ANSI_7, "8": kVK_ANSI_8, "9": kVK_ANSI_9,
        " ": kVK_Space, "-": kVK_ANSI_Minus, "=": kVK_ANSI_Equal, "[": kVK_ANSI_LeftBracket, "]": kVK_ANSI_RightBracket,
        "\\": kVK_ANSI_Backslash, ";": kVK_ANSI_Semicolon, "'": kVK_ANSI_Quote, ",": kVK_ANSI_Comma, ".": kVK_ANSI_Period,
        "/": kVK_ANSI_Slash, "`": kVK_ANSI_Grave,
    ]
    private static let shifted: [Character: Character] = [
        "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8", "(": "9", ")": "0",
        "_": "-", "+": "=", "{": "[", "}": "]", "|": "\\", ":": ";", "\"": "'", "<": ",", ">": ".", "?": "/", "~": "`",
    ]

    static func keyCode(for char: Character) -> (UInt16, Bool)? {
        if let code = unshifted[char] { return (UInt16(code), false) }
        if let base = shifted[char], let code = unshifted[base] { return (UInt16(code), true) }
        if char.isUppercase, let lower = char.lowercased().first, let code = unshifted[lower] { return (UInt16(code), true) }
        return nil
    }
}
