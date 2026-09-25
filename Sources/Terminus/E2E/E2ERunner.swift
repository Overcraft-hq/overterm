import AppKit
import Carbon.HIToolbox
import GhosttyKit

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
        "link": { await $0.linkScenario() },
        "cleanup": { await $0.cleanupScenario() },
        "splits": { await $0.splitsScenario() },
        "pullRequest": { await $0.pullRequestScenario() },
        "overview": { await $0.overviewScenario() },
        "scrollback": { await $0.scrollbackScenario() },
        "openFromFinder": { await $0.openFromFinderScenario() },
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
        // A new shell's first prompt keeps working (git status for the
        // theme, deferred integration init) after it first reports; keys
        // typed in that second were seen lost, twice in a row under load.
        let sinceFirst = terminal?.shellReportedAt.map { Date().timeIntervalSince($0) } ?? 0
        await pause(max(0.4, 1.2 - sinceFirst))
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
        let ok = await run(command) {
            (try? String(contentsOf: file, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) == content
        }
        check(name, ok, "\(file.lastPathComponent) = \((try? String(contentsOf: file, encoding: .utf8)) ?? "missing")")
    }

    /// Types `command` at a settled prompt and presses Return, once more if
    /// `condition` doesn't come to hold. A prompt redraw can flush keys
    /// mid-typing (seen: 40 characters gone from the middle), leaving half a
    /// command or a continuation prompt (for>, braceparam>) — Ctrl-C clears
    /// either before the retry. Only for commands that are fine to run twice.
    @discardableResult
    private func run(_ command: String, timeout: TimeInterval = 8, until condition: () -> Bool) async -> Bool {
        for attempt in 0..<2 {
            if attempt > 0 {
                key(kVK_ANSI_C, "\u{3}", modifiers: .control, ignoringModifiers: "c")
                await pause(0.3)
            }
            await settledPrompt()
            type(command)
            pressReturn()
            if await eventually(timeout, condition) { return true }
        }
        return false
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
        let resolved = dir.resolvingSymlinksInPath().path
        let followed = await run("cd \(dir.path)") {
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
        let cwd = ProcessInfo.processInfo.environment["TERMINUS_E2E_CWD"]
        check("each in its directory", tabs[1].workingDirectory == cwd)
        let panes = tabs[1].terminals
        check("the split tab's two panes come back", panes.count == 2, "\(panes.count)")
        if panes.count == 2 {
            check("each pane in its own directory", panes[1].workingDirectory == cwd && panes[0].workingDirectory != cwd)
            check("the saved pane has the keyboard", tabs[1].terminal === panes[1] && window.firstResponder === panes[1])
            await eventually(2) { panes[0].frame.width > 0 }
            let share = panes[0].frame.width / (panes[0].frame.width + panes[1].frame.width)
            check("at the saved size", abs(share - 0.3) < 0.02, "\(share)")
        }
        tabs[1].customTitle = "renamed"
        let saved = await eventually(4) { SessionState.load()?.tabs.last?.customTitle == "renamed" }
        check("a change is autosaved", saved)
        check("with the panes", SessionState.load()?.tabs.last?.panes != nil && SessionState.load()?.tabs.last?.focusedPane == 1)
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
        await settledPrompt()
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
        await settledPrompt()
        guard let first = app.store.selected else { return check("a tab", false) }
        app.newTab(nil)
        await settledPrompt()
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
        await run("python3 \(server.path) &", timeout: 10) { readPort() != nil }
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
        // Only once it knows where the tab is does "not measured" mean anything.
        await eventually(8) { self.app.infoModel?.location != nil }
        await pause(0.5)
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
        let followed = await run("bash \(script.path) &", timeout: 10) { self.app.diff.root?.resolvingSymlinksInPath() == feat }
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

    private func key(_ code: Int, _ characters: String, modifiers: NSEvent.ModifierFlags = [], ignoringModifiers: String? = nil) {
        let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: characters,
            charactersIgnoringModifiers: ignoringModifiers ?? characters, isARepeat: false, keyCode: UInt16(code))!
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

    /// ⌘-click on a `path:line` the shell printed opens it in the editor.
    private func linkScenario() async {
        let repo = scratch.appendingPathComponent("linkrepo")
        try? FileManager.default.createDirectory(at: repo.appendingPathComponent("src"), withIntermediateDirectories: true)
        try? "one\ntwo\nthree\nfour\n".write(to: repo.appendingPathComponent("src/main.swift"), atomically: true, encoding: .utf8)
        try? await git(["init", "-q", "-b", "main"], in: repo)
        app.newTab(in: repo)
        guard let terminal = app.store.selected?.terminal else { return check("a tab", false) }
        // Every row starts with the path, so a click a few cells in hits it
        // whatever the padding and the row. A script keeps the typed command
        // short.
        let script = scratch.appendingPathComponent("paths.sh")
        try? "clear\nfor i in $(seq 60); do echo src/main.swift:3; done\necho ok > \(out("printed").path)\n"
            .write(to: script, atomically: true, encoding: .utf8)
        await runAndExpect("sh \(script.path)", file: out("printed"), content: "ok", "the shell prints a path:line")
        guard let surface = terminal.surface else { return check("a surface", false) }
        let size = ghostty_surface_size(surface)
        // The file is written before libghostty's IO thread has necessarily
        // drawn the output: click only once the paths fill the screen.
        let drawn = await eventually(5) {
            (terminal.visibleText ?? "").split(separator: "\n").filter { $0.hasPrefix("src/main.swift:3") }.count
                >= Int(size.rows) - 3
        }
        check("the paths are on screen", drawn, terminal.visibleText ?? "nil")
        let scale = window.backingScaleFactor
        let inView = NSPoint(x: CGFloat(size.cell_width_px) / scale * 5, y: terminal.bounds.midY)
        let point = terminal.convert(inView, to: nil)
        func mouse(_ type: NSEvent.EventType) -> NSEvent {
            NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: .command, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        terminal.mouseMoved(with: mouse(.mouseMoved))
        await pause(0.2)
        window.sendEvent(mouse(.leftMouseDown))
        window.sendEvent(mouse(.leftMouseUp))
        check(
            "⌘-click opens the file in the editor, at that line",
            await eventually(3) {
                self.app.editor?.document.url?.lastPathComponent == "main.swift" && self.app.editor?.selectedLine == 3
            }, "\(app.editor?.document.url?.path ?? "nil") line \(app.editor?.selectedLine ?? -1)")
    }

    /// Merged worktrees are marked, and Clean Up removes exactly those —
    /// keeping one with changes and one with a tab in it.
    private func cleanupScenario() async {
        let remote = scratch.appendingPathComponent("origin.git")
        let repo = scratch.appendingPathComponent("cleanrepo")
        for dir in [remote, repo] { try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        try? await git(["init", "-q", "--bare", "-b", "main"], in: remote)
        try? await git(["init", "-q", "-b", "main"], in: repo)
        try? await git(["commit", "-q", "--allow-empty", "-m", "init"], in: repo)
        try? await git(["remote", "add", "origin", remote.path], in: repo)
        try? await git(["push", "-q", "-u", "origin", "main"], in: repo)
        try? await git(["remote", "set-head", "origin", "main"], in: repo)
        func worktree(_ branch: String, push: Bool = true) async -> URL {
            let path = scratch.appendingPathComponent("wt-\(branch)")
            try? await git(["worktree", "add", "-q", "-b", branch, path.path], in: repo)
            try? await git(["commit", "-q", "--allow-empty", "-m", branch], in: path)
            if push { try? await git(["push", "-q", "-u", "origin", branch], in: path) }
            return path
        }
        // Merged by a merge commit; merged and deleted on the remote (a squash);
        // merged but dirty; merged with a tab in it; still open.
        let merged = await worktree("merged")
        try? await git(["merge", "-q", "--no-ff", "-m", "Merge merged", "merged"], in: repo)
        let squashed = await worktree("squashed")
        try? await git(["push", "-q", "origin", "--delete", "squashed"], in: repo)
        let dirty = await worktree("dirty")
        try? await git(["merge", "-q", "--no-ff", "-m", "Merge dirty", "dirty"], in: repo)
        try? "wip\n".write(to: dirty.appendingPathComponent("wip.txt"), atomically: true, encoding: .utf8)
        let busy = await worktree("busy")
        try? await git(["merge", "-q", "--no-ff", "-m", "Merge busy", "busy"], in: repo)
        let open = await worktree("open")
        try? await git(["push", "-q", "origin", "main"], in: repo)

        app.newTab(in: busy)
        await eventually { self.app.store.selected?.workingDirectory != nil }
        app.newTab(in: repo)
        await eventually { self.app.worktrees.main != nil }
        await app.worktrees.refresh(fetch: true)
        check(
            "the merged ones are marked, the open one isn't",
            Set(app.worktrees.merged.keys) == ["merged", "squashed", "dirty", "busy"],
            app.worktrees.merged.keys.sorted().joined(separator: ","))
        check(
            "and say why", app.worktrees.merged["squashed"] == .upstreamGone && app.worktrees.merged["merged"] == .mergedInto("origin/main"))

        if let png = ProcessInfo.processInfo.environment["TERMINUS_DUMP_PNG"] {
            AppEnvironment.defaults.set(SidebarPanel.worktrees.rawValue, forKey: "sidebarPanel")
            await pause(0.8)
            app.captureWindow(to: png)
        }
        app.cleanUpMergedWorktrees(nil)
        check("Clean Up asks first", await eventually(10) { self.window.attachedSheet != nil })
        let text = sheetTexts().joined(separator: " | ")
        check("listing the two it will remove", text.contains("Remove 2 merged worktrees?"), text)
        check("and why the others stay", text.contains("dirty — uncommitted changes") && text.contains("busy — open in a tab"), text)
        check("not the unmerged one", !text.contains("• open"), text)
        clickSheetButton("Remove")
        let gone = await eventually(10) {
            !FileManager.default.fileExists(atPath: merged.path) && !FileManager.default.fileExists(atPath: squashed.path)
        }
        check("removes the merged worktrees", gone)
        // Branches go after each folder, and the list refreshes last.
        await eventually(10) { self.app.worktrees.worktrees.count == 4 }
        let branches = (try? await Git.run(["branch", "--format=%(refname:short)"], in: repo)) ?? ""
        let names = Set(branches.split(separator: "\n").map(String.init))
        check("and their branches", !names.contains("merged") && !names.contains("squashed"), names.sorted().joined(separator: ","))
        check(
            "keeps the rest",
            [dirty, busy, open].allSatisfy { FileManager.default.fileExists(atPath: $0.path) } && names.isSuperset(of: ["dirty", "busy", "open"]))
        check(
            "the list updates", await eventually { self.app.worktrees.worktrees.count == 4 },
            app.worktrees.worktrees.map(\.displayName).joined(separator: ","))
    }

    /// Splits: made from the menu and from Ghostty's own bindings, the
    /// keyboard moved and the layout resized by them, a divider dragged,
    /// a pane zoomed, and panes closed by exit and by ⌘W.
    private func splitsScenario() async {
        await waitForPrompt()
        guard let tab = app.store.selected, let host = app.host(of: tab) else { return check("a tab", false) }
        let first = tab.terminal
        await runAndExpect("sleep 71 & echo a > \(out("left").path)", file: out("left"), content: "a", "a job in the first pane")

        app.splitRight(nil)
        check("Split Right makes a second pane", tab.terminals.count == 2)
        let right = tab.terminals[1]
        check("the new pane has the keyboard", await eventually(2) { self.window.firstResponder === right && tab.terminal === right })
        await eventually(2) { right.frame.width > 0 }
        check(
            "side by side, half each", abs(first.frame.width - right.frame.width) <= 1 && right.frame.minX > first.frame.maxX,
            "\(first.frame) | \(right.frame)")
        await runAndExpect(
            "sleep 72 & echo right > \(out("right").path)", file: out("right"), content: "right", "typing goes to the focused pane")

        // Tab Info is the whole tab's: both panes' jobs.
        app.showInfo(for: tab)
        if let model = app.infoModel {
            let both = await eventually(8) {
                let commands = model.processes.flatMap(\.flattened).map(\.command)
                return commands.contains { $0.hasPrefix("sleep 71") } && commands.contains { $0.hasPrefix("sleep 72") }
            }
            check("Tab Info lists every pane's processes", both, model.processes.flatMap(\.flattened).map(\.command).joined(separator: " | "))
        } else {
            check("Tab Info opens", false)
        }
        app.infoPopover?.performClose(nil)
        await eventually(2) { self.app.infoPopover?.isShown != true }
        window.makeFirstResponder(right)

        right.perform(binding: "new_split:down")
        check("Ghostty's new_split makes a third", tab.terminals.count == 3)
        let below = tab.terminals[2]
        check("below the second", await eventually(2) { below.frame.minY > right.frame.maxY && abs(below.frame.minX - right.frame.minX) < 1 })

        below.perform(binding: "goto_split:left")
        check("goto_split moves the keyboard", await eventually(2) { self.window.firstResponder === first && tab.terminal === first })
        check("unfocused panes are dimmed", host.subviews.filter { !($0 is TerminalView) && !$0.isHidden }.count == 2)

        let before = first.frame.width
        first.perform(binding: "resize_split:right,60")
        check("resize_split moves the divider", await eventually(2) { first.frame.width > before + 40 }, "\(before) → \(first.frame.width)")
        first.perform(binding: "equalize_splits")
        check("equalize_splits evens it out", await eventually(2) { abs(first.frame.width - right.frame.width) <= 1 })

        // A real drag on the divider, 3 pt off the 1 pt line — a quarter of
        // the way down, clear of where the right column's divider meets it.
        let start = host.convert(NSPoint(x: first.frame.maxX + 3, y: host.bounds.height / 4), to: nil)
        let end = NSPoint(x: start.x - 80, y: start.y)
        func mouse(_ type: NSEvent.EventType, _ p: NSPoint) -> NSEvent {
            NSEvent.mouseEvent(
                with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        let widthBefore = first.frame.width
        // The divider tracks the drag in its own loop: queue the rest first.
        NSApp.postEvent(mouse(.leftMouseDragged, end), atStart: false)
        NSApp.postEvent(mouse(.leftMouseUp, end), atStart: false)
        window.sendEvent(mouse(.leftMouseDown, start))
        check("the divider drags", abs(first.frame.width - (widthBefore - 80)) <= 2, "\(widthBefore) → \(first.frame.width)")

        if let png = ProcessInfo.processInfo.environment["TERMINUS_DUMP_PNG"] {
            await pause(0.8)
            app.captureWindow(to: png)
        }

        first.perform(binding: "toggle_split_zoom")
        check(
            "zoom shows the pane alone",
            await eventually(2) { first.frame.size == host.bounds.size && right.isHidden && below.isHidden })
        first.perform(binding: "toggle_split_zoom")
        check("and back", await eventually(2) { !right.isHidden && !below.isHidden && first.frame.width < host.bounds.width })

        // exit in a pane closes just that pane.
        window.makeFirstResponder(below)
        await eventually(2) { tab.terminal === below }
        let exited = await run("exit") { tab.terminals.count == 2 }
        check("exit closes only its pane", exited && !tab.terminals.contains { $0 === below }, "\(tab.terminals.count) panes")
        check("and the tab stays", app.store.tabs.contains { $0.id == tab.id })

        // ⌘W on an idle pane: closed without asking.
        window.makeFirstResponder(right)
        await eventually(2) { tab.terminal === right }
        app.closeSelectedTab(nil)
        check("⌘W closes the focused pane", await eventually(2) { tab.terminals.count == 1 } && window.attachedSheet == nil)
        check("the last pane fills the tab again", await eventually(2) { first.frame.size == host.bounds.size })
        check("and has the keyboard", await eventually(2) { self.window.firstResponder === first })
    }

    /// A stand-in gh (fixtures in, posts logged) drives the real calls:
    /// PR and CI on the worktrees, a merged PR counting as merged, the Pull
    /// Request pane's conversation and threads, commenting and replying.
    private func pullRequestScenario() async {
        let repo = scratch.appendingPathComponent("prrepo")
        try? FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try? await git(["init", "-q", "-b", "main"], in: repo)
        try? "a\nb\n".write(to: repo.appendingPathComponent("app.swift"), atomically: true, encoding: .utf8)
        try? await git(["add", "."], in: repo)
        try? await git(["commit", "-q", "-m", "init"], in: repo)
        let feature = scratch.appendingPathComponent("wt-feat")
        let done = scratch.appendingPathComponent("wt-done")
        try? await git(["worktree", "add", "-q", "-b", "feat/pr", feature.path], in: repo)
        try? await git(["worktree", "add", "-q", "-b", "done", done.path], in: repo)
        try? await git(["commit", "-q", "--allow-empty", "-m", "done"], in: done)
        let doneTip = ((try? await Git.run(["rev-parse", "done"], in: repo)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        let log = scratch.appendingPathComponent("gh.log")
        let gh = scratch.appendingPathComponent("gh")
        try? Self.fakeGh(log: log.path, doneTip: doneTip).write(to: gh, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: gh.path)
        GitHub.executableOverride = gh

        app.newTab(in: feature)
        await eventually { self.app.diff.branch == "feat/pr" && self.app.worktrees.main != nil }
        await app.worktrees.refresh()
        let pr = app.worktrees.pullRequests["feat/pr"]
        check("the worktree's pull request, with CI", pr?.number == 7 && pr?.checks.overall == .failing, "\(String(describing: pr))")
        check("a merged pull request counts as merged", app.worktrees.merged["done"] == .pullRequestMerged(5))

        app.showPullRequest(nil)
        check("the pane opens on it", app.rightPane.mode == .pullRequest && app.diffItem?.isCollapsed == false)
        let loaded = await eventually(8) { self.app.pullRequest.phase == .loaded }
        let detail = app.pullRequest.detail
        check("and loads it", loaded && detail?.summary.number == 7, "\(app.pullRequest.phase)")
        check("its conversation", detail?.conversation.map(\.body) == ["First look", "Needs a test"], "\(detail?.conversation.map(\.body) ?? [])")
        check("its review thread", app.pullRequest.threads.first?.path == "app.swift" && app.pullRequest.threads.first?.comments.count == 1)
        if let png = ProcessInfo.processInfo.environment["TERMINUS_DUMP_PNG"] {
            await pause(0.8)
            app.captureWindow(to: png)
        }

        let commented = await app.pullRequest.comment("Ship it")
        let logged = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        check("a comment is posted with gh pr comment", commented && logged.contains("comment 7 Ship it"), logged)
        check("and shows after", app.pullRequest.detail?.conversation.last?.body == "Ship it")
        if let thread = app.pullRequest.threads.first {
            let replied = await app.pullRequest.reply(to: thread, "Added one")
            let logged = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
            check("a reply goes to the thread's root", replied && logged.contains("reply 101 Added one"), logged)
            check("and joins the thread", app.pullRequest.threads.first?.comments.last?.body == "Added one")
        }

        app.newTab(in: repo)
        check("a branch without one says so", await eventually(8) { self.app.pullRequest.phase == .none })
        GitHub.executableOverride = nil
    }

    /// gh answering from fixtures; comments and replies it is sent are
    /// logged and come back in later answers.
    private static func fakeGh(log: String, doneTip: String) -> String {
        #"""
        #!/usr/bin/python3
        import json, sys
        LOG = "\#(log)"
        args = sys.argv[1:]
        def posted():
            try:
                return [l.rstrip("\n").split(" ", 2) for l in open(LOG)]
            except FileNotFoundError:
                return []
        def run(name, conclusion):
            return {"__typename": "CheckRun", "name": name, "status": "COMPLETED", "conclusion": conclusion, "detailsUrl": "https://ci/" + name}
        CHECKS = [run("Go", "SUCCESS"), run("Lint", "FAILURE")]
        if args[:2] == ["pr", "list"]:
            print(json.dumps([
                {"number": 7, "title": "Add the thing", "headRefName": "feat/pr", "headRefOid": "x", "state": "OPEN", "isDraft": False,
                 "url": "https://github.com/o/r/pull/7", "statusCheckRollup": CHECKS},
                {"number": 5, "title": "Done", "headRefName": "done", "headRefOid": "\#(doneTip)", "state": "MERGED", "isDraft": False,
                 "url": "https://github.com/o/r/pull/5", "statusCheckRollup": []}]))
        elif args[:2] == ["pr", "view"]:
            if args[2] != "feat/pr":
                sys.stderr.write('no pull requests found for branch "%s"\n' % args[2])
                sys.exit(1)
            comments = [{"id": "IC_1", "author": {"login": "rev"}, "body": "First look", "createdAt": "2026-09-20T09:00:00Z", "url": "https://c/1"}]
            comments += [{"id": "IC_p%d" % i, "author": {"login": "me"}, "body": p[2], "createdAt": "2026-09-21T09:00:%02dZ" % i, "url": None}
                         for i, p in enumerate(posted()) if p[0] == "comment"]
            print(json.dumps({"number": 7, "title": "Add the thing", "headRefName": "feat/pr", "baseRefName": "main", "state": "OPEN",
                "isDraft": False, "url": "https://github.com/o/r/pull/7", "statusCheckRollup": CHECKS,
                "body": "Adds **the thing**.", "author": {"login": "me"}, "additions": 3, "deletions": 1, "changedFiles": 1, "comments": comments,
                "reviews": [{"id": "R_1", "author": {"login": "rev"}, "body": "Needs a test", "state": "CHANGES_REQUESTED",
                             "submittedAt": "2026-09-20T10:00:00Z"}]}))
        elif args[:2] == ["pr", "comment"]:
            open(LOG, "a").write("comment %s %s\n" % (args[2], args[args.index("--body") + 1]))
            print("https://github.com/o/r/pull/7#issuecomment-1")
        elif args[0] == "api" and args[1].endswith("/replies"):
            root = args[1].split("/")[-2]
            open(LOG, "a").write("reply %s %s\n" % (root, args[args.index("-f") + 1][len("body="):]))
            print("{}")
        elif args[0] == "api" and args[1].endswith("/pulls/7/comments"):
            thread = [{"id": 101, "path": "app.swift", "line": 2, "body": "Why b?", "user": {"login": "rev"},
                       "created_at": "2026-09-20T10:01:00Z", "html_url": "https://r/101", "diff_hunk": "@@ -1,1 +1,2 @@\n a\n+b"}]
            thread += [{"id": 200 + i, "in_reply_to_id": int(p[1]), "path": "app.swift", "line": 2, "body": p[2], "user": {"login": "me"},
                        "created_at": "2026-09-21T10:00:%02dZ" % i} for i, p in enumerate(posted()) if p[0] == "reply"]
            print(json.dumps(thread))
        else:
            sys.stderr.write("fake gh: unexpected %s\n" % args)
            sys.exit(2)
        """#
    }

    /// ⇧⌘A: a Claude tab waiting for you comes first, with what its
    /// session is about and what it is doing (from a prepared transcript);
    /// Esc closes; a card goes to its tab.
    private func overviewScenario() async {
        let projects = scratch.appendingPathComponent("claude-projects")
        ClaudeUsageReader.projectsDirectory = projects
        let dir = scratch.appendingPathComponent("agentproj")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? await git(["init", "-q", "-b", "feat/overview"], in: dir)
        let transcript =
            [
                #"{"type":"ai-title","aiTitle":"Fix the flaky login"}"#,
                #"{"type":"user","message":{"role":"user","content":"make the login test pass"}}"#,
                #"{"type":"assistant","message":{"content":[{"type":"text","text":"I found the race."}]}}"#,
                #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"make test"}}]}}"#,
            ].joined(separator: "\n") + "\n"
        for path in Set([dir.path, dir.resolvingSymlinksInPath().path]) {
            let folder = projects.appendingPathComponent(ClaudeUsageReader.projectFolder(for: path))
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? transcript.write(to: folder.appendingPathComponent("session.jsonl"), atomically: true, encoding: .utf8)
        }
        guard let shell = app.store.selected else { return check("a tab", false) }
        app.newTab(in: dir, agent: .claude, startAgent: false)
        guard let agentTab = app.store.selected, agentTab.id != shell.id else { return check("an agent tab", false) }
        await settledPrompt()
        // Claude Code's "needs you" notification, while another tab is selected.
        app.store.select(shell)
        await eventually(2) { self.app.store.selectedID == shell.id }
        emit("777;notify;Claude Code;Claude needs your permission", from: agentTab)
        await eventually(4) { agentTab.activity.mark == .waiting }

        app.showAgentOverview(nil)
        check("⇧⌘A opens the overview", app.overviewView?.isHidden == false)
        let first = await eventually(6) { self.app.overview.cards.first?.id == agentTab.id }
        check("the tab waiting for you comes first", first, app.overview.cards.map(\.title).joined(separator: ", "))
        let card = app.overview.cards.first { $0.id == agentTab.id }
        check("with its notification", card?.activity.note?.contains("needs your permission") == true, card?.activity.note ?? "nil")
        check("what the session is about", card?.claude?.title == "Fix the flaky login")
        check("what you asked, and what it is doing", card?.claude?.lastPrompt == "make the login test pass" && card?.claude?.currentTool == "Bash: make test")
        check("and where", card?.branch == "feat/overview" && card?.directory.map { ($0 as NSString).lastPathComponent } == "agentproj")
        check("the plain tab is there too", app.overview.cards.contains { $0.id == shell.id && $0.agent == nil })
        if let png = ProcessInfo.processInfo.environment["TERMINUS_DUMP_PNG"] {
            await pause(0.8)
            app.captureWindow(to: png)
        }

        check("it has the keyboard", window.firstResponder === app.overviewView)
        key(53, "\u{1b}")
        check("Esc closes it", await eventually(2) { self.app.overviewView?.isHidden == true })

        // Seen by hand: something else had the keyboard and Esc did nothing.
        // Through the app's event path (its monitors), with the terminal focused.
        app.showAgentOverview(nil)
        window.makeFirstResponder(shell.terminal)
        let escape = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false, keyCode: 53)!
        NSApp.sendEvent(escape)
        check("Esc closes it even when it lost the keyboard", await eventually(2) { self.app.overviewView?.isHidden == true })

        app.showAgentOverview(nil)
        app.chooseOverviewCard(agentTab.id)
        check("a card goes to its tab", app.overviewView?.isHidden == true && app.store.selectedID == agentTab.id)
        check("with the keyboard", await eventually(3) { self.app.store.selected?.terminal === self.window.firstResponder })
    }

    /// A shell pane's text is saved at quit and printed back into the pane
    /// on the next launch — whose shell still has Ghostty's integration.
    private func scrollbackScenario() async {
        guard let tab = app.store.selected else { return check("a tab", false) }
        await runAndExpect("echo marker-from-before > \(out("m").path); echo marker-from-before", file: out("m"), content: "marker-from-before", "output in the pane")
        await eventually(3) { tab.terminal.scrollbackText?.contains("marker-from-before\n") == true }

        let sessionFile = scratch.appendingPathComponent("session.json")
        app.saveFinalSession(to: sessionFile)
        let state = SessionState.load(from: sessionFile)
        let saved = Scrollback.file(named: state?.tabs.first?.scrollback)
        check("the final save keeps the pane's text", saved != nil, "\(String(describing: state?.tabs.first))")
        let text = saved.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        check("in a file", text.contains("marker-from-before"), text.suffix(200).description)

        // The next launch, in this window.
        guard let state else { return }
        app.restore(state)
        guard let restored = app.store.tabs.last, restored.id != tab.id else { return check("a restored tab", false) }
        app.store.select(restored)
        let shown = await eventually(10) { restored.terminal.visibleText?.contains("restored from the last session") == true }
        check("the new pane shows it", shown && restored.terminal.visibleText?.contains("marker-from-before") == true, restored.terminal.visibleText ?? "nil")
        if let png = ProcessInfo.processInfo.environment["TERMINUS_DUMP_PNG"] {
            await pause(0.8)
            app.captureWindow(to: png)
        }
        check("printed once: the file is gone", saved.map { !FileManager.default.fileExists(atPath: $0.path) } ?? false)
        check("the shell still has its integration", await eventually(10) { restored.terminal.shellReported })
        let dir = scratch.appendingPathComponent("after")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let followed = await run("cd \(dir.path)") {
            restored.workingDirectory.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path } == dir.resolvingSymlinksInPath().path
        }
        check("and reports its directory", followed, restored.workingDirectory ?? "nil")
        await runAndExpect("echo $0 > \(out("shell").path)", file: out("shell"), content: "-zsh", "as a login zsh")
    }

    /// Finder's Open With and "New Terminus Tab Here": a folder becomes a
    /// tab; a file opens in the editor, in the tab already in its checkout.
    private func openFromFinderScenario() async {
        let repo = scratch.appendingPathComponent("finderrepo")
        try? FileManager.default.createDirectory(at: repo.appendingPathComponent("src"), withIntermediateDirectories: true)
        try? "let x = 1\n".write(to: repo.appendingPathComponent("src/main.swift"), atomically: true, encoding: .utf8)
        try? await git(["init", "-q", "-b", "main"], in: repo)
        let before = app.store.tabs.count

        app.open([repo])
        check("a folder opens as a tab there", app.store.tabs.count == before + 1 && app.store.selected?.workingDirectory == repo.path)
        let repoTab = app.store.selected

        app.open([repo.appendingPathComponent("src/main.swift")])
        check(
            "a file in an open checkout: that tab, in the editor",
            await eventually(3) { self.app.editor?.document.url?.lastPathComponent == "main.swift" }
                && app.store.selected?.id == repoTab?.id && app.store.tabs.count == before + 1)

        let elsewhere = scratch.appendingPathComponent("notes")
        try? FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try? "hello\n".write(to: elsewhere.appendingPathComponent("todo.md"), atomically: true, encoding: .utf8)
        app.open([elsewhere.appendingPathComponent("todo.md")])
        check(
            "a file elsewhere: a new tab in its folder",
            await eventually(3) { self.app.editor?.document.url?.lastPathComponent == "todo.md" }
                && app.store.selected?.workingDirectory == elsewhere.path)

        // The service Finder calls, with a pasteboard as Finder fills it.
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("terminus-e2e-\(UUID().uuidString)"))
        pasteboard.clearContents()
        let other = scratch.appendingPathComponent("service-dir")
        try? FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        pasteboard.writeObjects([other as NSURL])
        var error: NSString = ""
        (NSApp.delegate as? AppDelegate)?.newTabHere(pasteboard, userData: nil, error: &error)
        check("New Terminus Tab Here opens one there", app.store.selected?.workingDirectory == other.path, error as String)
        pasteboard.releaseGlobally()
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
