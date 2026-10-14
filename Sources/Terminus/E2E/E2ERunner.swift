import AppKit
import Carbon.HIToolbox
import GhosttyKit
import UniformTypeIdentifiers

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
        "editorZed": { await $0.editorZedScenario() },
        "diff": { await $0.diffScenario() },
        "branchDiff": { await $0.branchDiffScenario() },
        "why": { await $0.whyScenario() },
        "diffStyle": { await $0.diffStyleScenario() },
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
        "peek": { await $0.peekScenario() },
        "scrollback": { await $0.scrollbackScenario() },
        "openFromFinder": { await $0.openFromFinderScenario() },
        "sessions": { await $0.sessionsScenario() },
        "settings": { await $0.settingsScenario() },
        "updates": { await $0.updatesScenario() },
        "performance": { await $0.performanceScenario() },
        "bigFiles": { await $0.bigFilesScenario() },
        "clipboard": { await $0.clipboardScenario() },
        "openWith": { await $0.openWithScenario() },
        "dropFiles": { await $0.dropFilesScenario() },
        "groups": { await $0.groupsScenario() },
        "blocks": { await $0.blocksScenario() },
        "inbox": { await $0.inboxScenario() },
        "askAgent": { await $0.askAgentScenario() },
        "dropSplit": { await $0.dropSplitScenario() },
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

    /// A measurement, printed whether or not a check passes.
    private func note(_ text: String) {
        print("E2E INFO \(text)")
        fflush(stdout)
    }

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

    /// An item of the menu bar's `menu`, as the menu bar has it.
    private func menuItem(_ menu: String, _ title: String) -> NSMenuItem? {
        NSApp.mainMenu?.items.first { $0.submenu?.title == menu }?.submenu?.items.first { $0.title == title }
    }

    /// Chooses a menu item: its action goes up the responder chain from the
    /// window's first responder, as it does from the menu bar (the run's
    /// window is never key, so NSApp.sendAction wouldn't find it). Then the
    /// item is validated, as before the menu opens again.
    @discardableResult
    private func perform(_ item: NSMenuItem) -> Bool {
        guard let action = item.action, (window.firstResponder ?? window).tryToPerform(action, with: item) else { return false }
        _ = app.validateMenuItem(item)
        return true
    }

    /// A shell-safe path for typing (the scratch path has no spaces).
    private func out(_ name: String) -> URL { scratch.appendingPathComponent(name) }

    /// What a scenario's scratch file holds, trimmed — the usual way a
    /// scenario checks that something reached a shell.
    private func contents(_ file: URL) -> String? {
        (try? Data(contentsOf: file)).map {
            String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    // MARK: Scenarios

    /// Keyboard → TerminalView → libghostty → pty → shell, from the bundle.
    private func terminal() async {
        // macOS charges a program's microphone use to the app it runs in, and
        // refuses it without asking when that app's Info.plist gives no reason
        // (Claude Code's /voice got silence).
        let usage = ["NSMicrophoneUsageDescription", "NSSpeechRecognitionUsageDescription", "NSAudioCaptureUsageDescription"]
        check(
            "programs in it may ask for the microphone and speech recognition",
            usage.allSatisfy { (Bundle.main.object(forInfoDictionaryKey: $0) as? String)?.isEmpty == false },
            "missing: \(usage.filter { Bundle.main.object(forInfoDictionaryKey: $0) == nil })")
        check("a surface exists", terminal?.surface != nil)
        check("shell reaches its prompt", await waitForPrompt())
        await runAndExpect("echo $TERM > \(out("term").path)", file: out("term"), content: "xterm-ghostty", "typed command runs; TERM is xterm-ghostty")
        await runAndExpect(
            "echo ${GHOSTTY_SHELL_FEATURES:+integrated} > \(out("si").path)", file: out("si"), content: "integrated", "shell integration is on")
        await runAndExpect("echo 'Mixed Case_!' > \(out("chars").path)", file: out("chars"), content: "Mixed Case_!", "shifted characters survive")
        versionChecks()
    }

    /// The version, from the bundle (Scripts/make-app.sh): VERSION of the
    /// checkout it was built in — the run's app is that checkout's
    /// Overterm.app — the commit count as the build, the commit. About
    /// Overterm shows them.
    private func versionChecks() {
        let info = Bundle.main.infoDictionary ?? [:]
        let file = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("VERSION")
        let version = (try? String(contentsOf: file, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        let shown = info["CFBundleShortVersionString"] as? String ?? ""
        check("the app's version is the checkout's VERSION", shown == version, "bundle \(shown), VERSION \(version ?? "missing")")
        let build = info["CFBundleVersion"] as? String ?? ""
        check("its build number is a positive integer", (Int(build) ?? 0) > 0, "CFBundleVersion \(build)")
        let commit = info[AboutPanel.commitKey] as? String ?? ""
        check("it names the commit it was built from", !commit.isEmpty, "no \(AboutPanel.commitKey)")

        // The menu item, as the menu bar sends it: the standard panel, with
        // the commit as its credits.
        guard let about = NSApp.mainMenu?.items.first?.submenu?.items.first(where: { $0.title == "About Overterm" }), let action = about.action
        else { return check("the app menu has About Overterm", false) }
        let before = Set(NSApp.windows.map(ObjectIdentifier.init))
        NSApp.sendAction(action, to: about.target, from: about)
        let panel = NSApp.windows.first { !before.contains(ObjectIdentifier($0)) && $0.isVisible }
        var texts: [String] = []
        func walk(_ view: NSView) {
            if let field = view as? NSTextField { texts.append(field.stringValue) }
            if let text = view as? NSTextView { texts.append(text.string) }
            view.subviews.forEach(walk)
        }
        panel?.contentView.map(walk)
        check("About Overterm shows the version and build", texts.contains { $0.contains("\(shown) (\(build))") }, "\(texts)")
        check("…and the commit it was built from", texts.contains { $0.hasPrefix("commit \(commit) · ") }, "\(texts)")
        check("…without bringing the app forward", !NSApp.isActive)
        panel?.close()
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
        // Colours come from tree-sitter, off the main thread: a moment later.
        let colored = await eventually(3) {
            textView?.textStorage.map { storage -> Bool in
                let kw = storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
                let plain = storage.attribute(.foregroundColor, at: 3, effectiveRange: nil) as? NSColor
                return kw != nil && kw != plain
            } == true
        }
        check("syntax colours apply", colored)

        textView?.setSelectedRange(NSRange(location: (textView?.string as NSString?)?.length ?? 0, length: 0))
        textView?.insertText("let added = 1\n", replacementRange: textView?.selectedRange() ?? NSRange())
        check("an edit marks it unsaved", editor.document.isDirty)
        editor.saveDocument(nil)
        check("⌘S writes the file", (try? String(contentsOf: file, encoding: .utf8))?.contains("let added = 1") == true)
        check("and clears the unsaved mark", !editor.document.isDirty)

        // Unsaved changes keep the window when its last tab closes.
        textView?.insertText("// unsaved\n", replacementRange: textView?.selectedRange() ?? NSRange())
        check("…unsaved again", app.unsavedEditorFile == "hello.swift")
        let lastTabs = app.store.tabs
        app.closeTabsWithoutAsking(lastTabs)
        check(
            "closing the last tab keeps the window while the editor has unsaved changes",
            await eventually(3) { self.window.isVisible && self.app.store.tabs.count == 1 && !lastTabs.contains { $0.id == self.app.store.tabs[0].id } })
        editor.saveDocument(nil)
        await settledPrompt()

        try? "rewritten by an agent\n".write(to: file, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: file.path)
        editor.reloadIfChangedOnDisk()
        check("an outside change reloads it", textView?.string == "rewritten by an agent\n")

        let bin = out("blob.bin")
        try? Data([0, 1, 2, 3]).write(to: bin)
        app.openInEditor(bin)
        check("a binary file is refused, with a reason", await eventually(2) { editor.document.unavailable == "Binary file." })
    }

    /// The editor as Zed's: zoomed, tabs, tree-sitter (markdown too), Zed's
    /// editing commands, pickers, a language server's problems and
    /// completions (the fake one LanguageServerTests uses), the git gutter, vim.
    private func editorZedScenario() async {
        let repo = scratch.appendingPathComponent("zed")
        try? FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        let main = repo.appendingPathComponent("main.go")
        try? "package main\n\nfunc main() {\n\tprintln(\"hi\")\n}\n".write(to: main, atomically: true, encoding: .utf8)
        _ = try? await Git.run(["init", "-q"], in: repo)
        _ = try? await Git.run(["-c", "user.email=e2e@x", "-c", "user.name=e2e", "add", "."], in: repo)
        _ = try? await Git.run(["-c", "user.email=e2e@x", "-c", "user.name=e2e", "commit", "-qm", "init"], in: repo)
        let readme = repo.appendingPathComponent("README.md")
        try? "# Title\n\nSome **bold** text.\n".write(to: readme, atomically: true, encoding: .utf8)

        // The fake server, for Go only: the problems, completions, symbols.
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../Tests/TerminusTests/Fixtures/fake-lsp.py").standardizedFileURL
        let serverLog = scratch.appendingPathComponent("fake-lsp.log")
        LanguageServers.shared.discoveryOverride = { spec in
            spec.id == "go" ? LanguageServer.Command(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: [script.path, serverLog.path]) : nil
        }
        defer { LanguageServers.shared.discoveryOverride = nil }

        app.openInEditor(main)
        guard let editor = app.editor, let textView = editor.textView else { return check("editor exists", false) }
        check("a file opens zoomed: the editor fills the window", await eventually(3) { self.app.isEditorZoomed && editor.isZoomed })
        editor.perform("editor.toggleZoom")
        check("⇧⎋ gives the terminal back", await eventually(3) { !self.app.isEditorZoomed })

        // Problems from the language server: a squiggle, the gutter, the status bar.
        check(
            "the language server's problems show", await eventually(8) { editor.active?.diagnostics.first?.message == "unused" },
            (try? String(contentsOf: serverLog, encoding: .utf8)) ?? "no server log")
        check("…drawn under the text", textView.diagnostics.count == 1)
        check(
            "…counted in the status bar",
            Self.find(NSButton.self, in: editor.view) { $0.identifier?.rawValue == "editorProblems" }?.accessibilityLabel() == "0 errors, 1 warnings")

        // Zed's editing commands.
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        editor.perform("editor.toggleComment")
        check("⌘/ comments the line", textView.string.hasPrefix("// package main"), textView.string)
        editor.perform("editor.toggleComment")
        check("…and back", textView.string.hasPrefix("package main"))
        editor.perform("editor.duplicateLineDown")
        check("⇧⌥↓ duplicates it", textView.string.hasPrefix("package main\npackage main\n"))
        editor.perform("editor.deleteLine")
        check("⇧⌘K deletes it", textView.string.hasPrefix("package main\n\nfunc"))
        // At a line's end (before a word it wouldn't, as in Zed).
        let lineEnd = NSMaxRange((textView.string as NSString).range(of: "println(\"hi\")"))
        textView.setSelectedRange(NSRange(location: lineEnd, length: 0))
        // As typing sends it: no replacement range.
        textView.insertText("(", replacementRange: NSRange(location: NSNotFound, length: 0))
        check("( closes itself", textView.string.contains("println(\"hi\")()\n"), textView.string)
        check("…with the caret between", textView.selectedRange().location == lineEnd + 1)
        check("the gutter marks the line changed since the commit", await eventually(3) { editor.gutter.gitMarks.contains { $0.kind == .modified } })
        editor.active?.undo.undo()
        check("undo takes it back", !textView.string.contains("()\n"), textView.string)

        // Pickers.
        editor.perform("editor.goToLine")
        check("⌃G opens Go to Line", editor.picker?.identifier?.rawValue == "goToLine")
        editor.picker?.dismiss()
        editor.perform("editor.goToSymbol")
        check(
            "⇧⌘O lists the server's symbols",
            await eventually(5) { (Self.find(NSTableView.self, in: editor.picker) { _ in true }?.numberOfRows ?? 0) >= 2 })
        editor.picker?.dismiss()

        // Completions: the server's and the file's words.
        textView.setSelectedRange(NSRange(location: (textView.string as NSString).range(of: "println").location, length: 0))
        editor.triggerCompletion(manual: true)
        check("⌃Space asks the server", await eventually(5) { editor.completion?.candidates.contains { $0.label == "Println" } == true })
        editor.dismissCompletion()

        // A second file is a second tab; markdown is coloured inline too.
        app.openInEditor(readme)
        check("another file is another tab", await eventually(3) { editor.buffers.count == 2 && editor.document.url == readme })
        let bold = await eventually(3) {
            guard let storage = textView.textStorage, storage.length > 15 else { return false }
            let font = storage.attribute(.font, at: (storage.string as NSString).range(of: "**bold**").location + 2, effectiveRange: nil) as? NSFont
            return font.map { NSFontManager.shared.traits(of: $0).contains(.boldFontMask) } == true
        }
        check("markdown's **bold** is bold (the inline grammar is injected)", bold)
        check("markdown wraps long lines", textView.textContainer?.widthTracksTextView == true)
        editor.perform("editor.previousFile")
        check("⌥⌘← goes to the other tab", editor.document.url == main)
        editor.saveDocument(nil)
        editor.perform("editor.closeFile")
        check("⌘W closes a tab, not the terminal", await eventually(2) { editor.buffers.count == 1 && editor.document.url == readme })

        // Vim, when asked for.
        Settings.shared.set("editor.vimMode", .bool(true))
        check("vim mode starts", await eventually(2) { editor.vim != nil && textView.blockCursor })
        if let vim = editor.vim {
            editor.textView.setSelectedRange(NSRange(location: 0, length: 0))
            vim.reset()
            for key in ["d", "d"] { _ = vim.handle(VimKey(key)) }
            check("dd deletes a line", !textView.string.hasPrefix("# Title"), textView.string)
            _ = vim.handle(VimKey("u"))
            check("u undoes it", textView.string.hasPrefix("# Title"), textView.string)
        }
        Settings.shared.set("editor.vimMode", nil)
        check("vim mode stops", await eventually(2) { editor.vim == nil && !textView.blockCursor })
        editor.saveDocument(nil)
        editor.requestClose()
        check("closing the editor closes its tabs", await eventually(2) { editor.buffers.isEmpty && self.app.editorItem?.isCollapsed == true })
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
        guard let changes = menuItem("View", "Changes") else { return check("View ▸ Changes exists", false) }
        check("View ▸ Changes is ⌥⌘D", changes.keyEquivalent == "d" && changes.keyEquivalentModifierMask == [.command, .option])
        check("View ▸ Changes opens the pane", perform(changes) && app.diffItem?.isCollapsed == false)
        check("and is ticked while it shows", changes.state == .on)
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
        check("to a plain ±, still there to open the pane", app.diff.badge == .plain, "\(String(describing: app.diff.badge))")
        check("View ▸ Changes again closes it", perform(changes) && app.diffItem?.isCollapsed == true)
        check("and it is no longer ticked", changes.state == .off)
    }

    /// What an agent did on its branch, committed or not. Uncommitted shows
    /// the edit under way; Branch shows everything since the branch left
    /// main — the committed change too — and the commit. Once all is
    /// committed the badge shows the branch's totals; on main itself there
    /// is nothing to compare with, and the pane says so.
    private func branchDiffScenario() async {
        let repo = scratch.appendingPathComponent("brepo")
        let worktree = scratch.appendingPathComponent("brepo-feat")
        try? FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try? await git(["init", "-q", "-b", "main"], in: repo)
        for name in ["a.txt", "b.txt"] { try? "one\n".write(to: repo.appendingPathComponent(name), atomically: true, encoding: .utf8) }
        try? await git(["add", "."], in: repo)
        try? await git(["commit", "-q", "-m", "init"], in: repo)
        try? await git(["worktree", "add", "-q", "-b", "feat", worktree.path], in: repo)
        try? "two\n".write(to: worktree.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try? await git(["commit", "-q", "-am", "Change a", "-m", "The agent's reason."], in: worktree)
        try? "one\nmore\n".write(to: worktree.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        let diff = app.diff

        app.newTab(in: worktree)
        let feature = app.store.selected
        check(
            "the model follows the tab into the worktree",
            await eventually { diff.root?.resolvingSymlinksInPath() == worktree.resolvingSymlinksInPath() })
        check("Uncommitted: the edit under way", await eventually { diff.files.map(\.path) == ["b.txt"] }, "\(diff.files.map(\.path))")
        check("Branch: the committed file too", await eventually { diff.branchFiles.map(\.path) == ["a.txt", "b.txt"] }, "\(diff.branchFiles.map(\.path))")
        check("the badge shows what is uncommitted", diff.badge == .uncommitted(added: 1, removed: 0), "\(String(describing: diff.badge))")

        app.toggleDiff(nil)
        check("the pane opens on Uncommitted", await eventually { self.app.diffItem?.isCollapsed == false && diff.diffs.count == 1 })
        check("Uncommitted says nothing about the branch", diff.shownScope == .uncommitted && diff.scopeNote == nil)
        // The switch's Branch button.
        diff.choose(.branch)
        check("Branch lists both files", await eventually { diff.shownFiles.map(\.path) == ["a.txt", "b.txt"] }, "\(diff.shownFiles.map(\.path))")
        check(
            "and the commit, with its reason",
            diff.commits.map(\.subject) == ["Change a"] && diff.commits.first?.body == "The agent's reason." && diff.commits.first?.files == ["a.txt"],
            "\(diff.commits)")
        check("the header says what it compares with", diff.scopeNote == "Since main · 1 commit", diff.scopeNote ?? "nil")
        check(
            "each file's diff is from where the branch left main",
            await eventually { diff.diffs["a.txt"]?.lines.filter { $0.kind == .added }.map(\.text) == ["two"] && diff.diffs.count == 2 })
        check("the pick is remembered", AppEnvironment.defaults.string(forKey: DiffModel.scopeKey) == "branch")
        if let png = ProcessInfo.processInfo.environment["TERMINUS_DUMP_PNG"] {
            await pause(0.8)
            app.captureWindow(to: png)
        }

        // The agent commits the rest.
        await pause(0.5)
        try? await git(["commit", "-q", "-am", "More b"], in: worktree)
        check("nothing is uncommitted then", await eventually { diff.files.isEmpty }, "\(diff.files.map(\.path))")
        check(
            "the branch keeps both files and both commits",
            await eventually { diff.branchFiles.count == 2 && diff.commits.map(\.subject) == ["More b", "Change a"] }, "\(diff.commits.map(\.subject))")
        check("the badge shows the branch's totals", diff.badge == .branch(added: 2, removed: 1), "\(String(describing: diff.badge))")
        check("the header counts both commits", diff.scopeNote == "Since main · 2 commits", diff.scopeNote ?? "nil")

        app.newTab(in: repo)
        check("on main there is nothing to compare with", await eventually { diff.comparison == .onBase("main") }, "\(String(describing: diff.comparison))")
        check(
            "the pane says so and shows Uncommitted", diff.scopeNote == "On main — nothing to compare with" && diff.shownScope == .uncommitted,
            diff.scopeNote ?? "nil")
        app.toggleDiff(nil)

        // The ± badge opens the pane on what it counts; View ▸ Changes (⌥⌘D)
        // opens it on the scope picked last.
        guard let feature, let changes = menuItem("View", "Changes") else { return check("the branch's tab, View ▸ Changes", false) }
        app.store.select(feature)
        check(
            "back on the branch, the badge shows its totals",
            await eventually {
                diff.root?.resolvingSymlinksInPath() == worktree.resolvingSymlinksInPath() && diff.badge == .branch(added: 2, removed: 1)
            }, "\(String(describing: diff.badge))")
        // Uncommitted picked in the pane's switch, and the pane closed.
        perform(changes)
        diff.choose(.uncommitted)
        perform(changes)
        check(
            "View ▸ Changes opens on the scope picked last, whatever the badge counts",
            perform(changes) && app.diffItem?.isCollapsed == false && diff.shownScope == .uncommitted, "\(diff.shownScope)")
        perform(changes)
        // Last on the Pull Request view: the badge is about changes.
        app.rightPane.mode = .pullRequest
        app.toggleDiffFromBadge()
        check(
            "the badge showing the branch's totals opens Branch", app.diffItem?.isCollapsed == false && diff.shownScope == .branch,
            "open: \(app.diffItem?.isCollapsed == false), \(diff.shownScope)")
        check("on the changes, not the pull request", app.rightPane.mode == .changes)
        check("listing the branch's files", await eventually { diff.shownFiles.map(\.path) == ["a.txt", "b.txt"] }, "\(diff.shownFiles.map(\.path))")
        app.toggleDiffFromBadge()
        check("the badge again closes it", await eventually(2) { self.app.diffItem?.isCollapsed == true })

        // Branch picked in the switch; then an edit is under way.
        perform(changes)
        diff.choose(.branch)
        perform(changes)
        try? "one\nmore\nstill more\n".write(to: worktree.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        check("an edit under way: the badge counts it", await eventually { diff.badge == .uncommitted(added: 1, removed: 0) }, "\(String(describing: diff.badge))")
        app.toggleDiffFromBadge()
        check(
            "the badge showing uncommitted totals opens Uncommitted",
            app.diffItem?.isCollapsed == false && diff.shownScope == .uncommitted && diff.shownFiles.map(\.path) == ["b.txt"],
            "\(diff.shownScope) \(diff.shownFiles.map(\.path))")
        app.toggleDiffFromBadge()
    }

    /// Why each file changed, on its card: what Claude said making the edit,
    /// from a transcript in Claude Code's shape (a scratch projects
    /// directory, never ~/.claude) — never the words of an edit that failed
    /// — read only once the pane is open; a click shows the edits before; in
    /// Branch the commits that touched the file too. A file no session
    /// edited says nothing.
    private func whyScenario() async {
        let projects = scratch.appendingPathComponent("claude-projects")
        ClaudeUsageReader.projectsDirectory = projects
        let repo = scratch.appendingPathComponent("whyrepo")
        let worktree = scratch.appendingPathComponent("whyrepo-feat")
        try? FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try? await git(["init", "-q", "-b", "main"], in: repo)
        for name in ["a.txt", "b.txt"] { try? "one\n".write(to: repo.appendingPathComponent(name), atomically: true, encoding: .utf8) }
        try? await git(["add", "."], in: repo)
        try? await git(["commit", "-q", "-m", "init"], in: repo)
        try? await git(["worktree", "add", "-q", "-b", "feat", worktree.path], in: repo)
        try? "one\ntwo\n".write(to: worktree.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try? await git(["commit", "-q", "-am", "Teach a.txt to count"], in: worktree)
        try? "one\ntwo\nthree\n".write(to: worktree.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try? "one\nmore\n".write(to: worktree.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)

        let earlier = "a.txt should count; adding the second line."
        let failed = "Trying the edit on a line that is not there."
        let reason = "a.txt stops at two; the count goes on to three."
        writeTranscript(
            earlier: earlier, failed: failed, reason: reason, file: worktree.appendingPathComponent("a.txt").path,
            // Claude Code names the folder after its cwd, symlinks resolved.
            in: projects.appendingPathComponent(ClaudeUsageReader.projectFolder(for: ClaudeEdits.canonical(worktree.path))))

        let diff = app.diff
        app.newTab(in: worktree)
        check(
            "the model follows the tab into the worktree",
            await eventually { diff.root?.resolvingSymlinksInPath() == worktree.resolvingSymlinksInPath() })
        check("both files are changed", await eventually { diff.files.map(\.path) == ["a.txt", "b.txt"] }, "\(diff.files.map(\.path))")
        await pause(0.5)
        check("no transcript is read while the pane is closed", diff.reasons.isEmpty)

        guard let changes = menuItem("View", "Changes") else { return check("View ▸ Changes exists", false) }
        check("View ▸ Changes opens the pane", perform(changes) && app.diffItem?.isCollapsed == false)
        // What the cards show (DiffPanelView renders `why(for:)` as it is).
        func said(_ path: String) -> [String?] { diff.why(for: path).shownReasons.map(\.reason?.text) }
        check("a.txt's card says why: Claude's words at its last edit", await eventually { said("a.txt") == [reason] }, "\(said("a.txt"))")
        let newest = diff.why(for: "a.txt").shownReasons.first
        check("in Claude's words, with when", newest?.reason?.source == .said && newest?.time.map { ClaudeEdits.ago($0) } == "just now")
        check("and that there is more", diff.why(for: "a.txt").hiddenReasons == 1)
        check("b.txt, which no session edited, has nothing to say", diff.why(for: "b.txt").isEmpty)
        check("Uncommitted lists no commits", diff.why(for: "a.txt").commits.isEmpty)
        // A click on the strip.
        diff.toggleWhy("a.txt")
        check("opened, it shows what Claude said at the edit before", said("a.txt") == [reason, earlier], "\(said("a.txt"))")
        check("an edit that failed changed nothing: its words never show", !diff.reasons.values.joined().contains { $0.reason?.text == failed })

        // The switch's Branch button.
        diff.choose(.branch)
        check(
            "Branch lists the commit that touched a.txt on its card",
            await eventually { diff.shownScope == .branch && diff.why(for: "a.txt").commits.map(\.subject) == ["Teach a.txt to count"] },
            "\(diff.why(for: "a.txt").commits.map(\.subject))")
        check("with Claude's words still", said("a.txt") == [reason, earlier])
        check("b.txt no commit touched", diff.why(for: "b.txt").isEmpty)
        diff.toggleWhy("a.txt")
        check("a second click shows the newest again", said("a.txt") == [reason])
        if let png = ProcessInfo.processInfo.environment["TERMINUS_DUMP_PNG"] {
            await pause(0.8)
            app.captureWindow(to: png)
        }
    }

    /// A session transcript in Claude Code's shape (2.1.28x): a prompt; words,
    /// an edit and its result for each change — the first one's result an
    /// error — each part on a line of its own.
    private func writeTranscript(earlier: String, failed: String, reason: String, file: String, in folder: URL) {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let start = Date()
        func line(_ type: String, _ body: String, at second: Int, extra: String = "") -> String {
            let stamp = formatter.string(from: start.addingTimeInterval(TimeInterval(second)))
            return
                #"{"parentUuid":null,"isSidechain":false,\#(body),"type":"\#(type)","uuid":"u\#(second)","timestamp":"\#(stamp)","cwd":"\#((file as NSString).deletingLastPathComponent)","sessionId":"00000000-0000-0000-0000-0000000000f1","version":"2.1.281"\#(extra)}"#
        }
        func said(_ text: String, at second: Int) -> String {
            line("assistant", #""message":{"id":"msg_\#(second)","role":"assistant","model":"claude-opus-5","content":[{"type":"text","text":"\#(text)"}]}"#, at: second)
        }
        func edit(_ id: String, at second: Int) -> String {
            line(
                "assistant",
                #""message":{"id":"msg_\#(second)","role":"assistant","model":"claude-opus-5","content":[{"type":"tool_use","id":"\#(id)","name":"Edit","input":{"file_path":"\#(file)","old_string":"two","new_string":"two\nthree","replace_all":false}}]}"#,
                at: second)
        }
        func result(_ id: String, error: Bool, at second: Int) -> String {
            error
                ? line(
                    "user",
                    #""message":{"role":"user","content":[{"type":"tool_result","content":"<tool_use_error>String to replace not found in file.</tool_use_error>","is_error":true,"tool_use_id":"\#(id)"}]}"#,
                    at: second, extra: #","toolUseResult":"Error: String to replace not found in file.""#)
                : line(
                    "user", #""message":{"role":"user","content":[{"tool_use_id":"\#(id)","type":"tool_result","content":"The file has been updated successfully."}]}"#,
                    at: second,
                    extra:
                        #","toolUseResult":{"filePath":"\#(file)","structuredPatch":[{"oldStart":2,"oldLines":1,"newStart":2,"newLines":2,"lines":[" two","+three"]}],"userModified":false}"#
                )
        }
        let lines = [
            line("user", #""message":{"role":"user","content":"make a.txt count"}"#, at: 0),
            said(earlier, at: 1), edit("toolu_e2e_1", at: 2), result("toolu_e2e_1", error: false, at: 3),
            line("user", #""message":{"role":"user","content":"and on to three"}"#, at: 4),
            said(failed, at: 5), edit("toolu_e2e_2", at: 6), result("toolu_e2e_2", error: true, at: 7),
            said(reason, at: 8), edit("toolu_e2e_3", at: 9), result("toolu_e2e_3", error: false, at: 10),
        ]
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? (lines.joined(separator: "\n") + "\n").write(
            to: folder.appendingPathComponent("00000000-0000-0000-0000-0000000000f1.jsonl"), atomically: true, encoding: .utf8)
    }

    /// The changes pane reads like code: a Swift change in the editor's
    /// colours — a block comment over context lines a comment on each line,
    /// keywords, strings, numbers — and, in a line that was edited rather
    /// than replaced, the part that changed, on it and on the line it
    /// replaced. A file the highlighter doesn't know stays plain. With many
    /// files the cards start folded, a list of them, and what the user folds
    /// or opens stays so. SwiftUI builds no accessibility tree in-process:
    /// the checks are on what each line and card is given
    /// (`FileDiff.style(of:)`, `DiffModel.isFolded`), which the view draws as it is.
    private func diffStyleScenario() async {
        let repo = scratch.appendingPathComponent("stylerepo")
        try? FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try? await git(["init", "-q", "-b", "main"], in: repo)
        func write(_ name: String, _ lines: [String]) {
            try? (lines.joined(separator: "\n") + "\n").write(to: repo.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        write("Greeter.swift", ["/* Greets", "   the user. */", "func greet() -> String {", "    let times = 1", "    return \"hello\"", "}"])
        write("notes.txt", ["status: draft"])
        try? await git(["add", "."], in: repo)
        try? await git(["commit", "-q", "-m", "init"], in: repo)
        write(
            "Greeter.swift",
            ["/* Greets", "   the user. */", "func greet() -> String {", "    let times = 2", "    return \"hello, world\"", "    // unreachable, on purpose", "}"])
        write("notes.txt", ["status: final"])
        let diff = app.diff

        app.newTab(in: repo)
        check("the model follows the tab into the repo", await eventually { diff.root?.resolvingSymlinksInPath() == repo.resolvingSymlinksInPath() })
        guard let changes = menuItem("View", "Changes") else { return check("View ▸ Changes exists", false) }
        check("View ▸ Changes opens the pane", perform(changes) && app.diffItem?.isCollapsed == false)
        guard await eventually(10, { diff.diffs.count == 2 }), let greeter = diff.diffs["Greeter.swift"], let notes = diff.diffs["notes.txt"] else {
            return check("both files' diffs load", false, "\(diff.diffs.keys.sorted())")
        }
        /// What a line is given: its colours, "kind: text", then its changed part.
        func drawn(_ file: DiffModel.FileDiff, _ kind: DiffLine.Kind, _ text: String) -> [String] {
            guard let line = file.lines.first(where: { $0.kind == kind && $0.text == text }) else { return ["no \(kind) line \(text)"] }
            let style = file.style(of: line)
            let ns = line.text as NSString
            return style.tokens.map { "\($0.kind): \(ns.substring(with: $0.range))" } + (style.changed.map { ["changed: \(ns.substring(with: $0))"] } ?? [])
        }
        let comment = [drawn(greeter, .context, "/* Greets"), drawn(greeter, .context, "   the user. */")]
        check("a block comment over two context lines is a comment on each", comment == [["comment: /* Greets"], ["comment:    the user. */"]], "\(comment)")
        let signature = drawn(greeter, .context, "func greet() -> String {")
        check("a keyword on a context line", signature == ["keyword: func"], "\(signature)")
        let replaced = drawn(greeter, .removed, "    let times = 1")
        check("an edited line: its keyword and number, and the part replaced", replaced == ["keyword: let", "number: 1", "changed: 1"], "\(replaced)")
        let replacing = drawn(greeter, .added, "    let times = 2")
        check("the line that replaced it: the part that replaced it", replacing == ["keyword: let", "number: 2", "changed: 2"], "\(replacing)")
        let removed = drawn(greeter, .removed, "    return \"hello\"")
        check("a string on a removed line, nothing of it replaced", removed == ["keyword: return", "string: \"hello\""], "\(removed)")
        let added = drawn(greeter, .added, "    return \"hello, world\"")
        check("its added line marks what was added", added == ["keyword: return", "string: \"hello, world\"", "changed: , world"], "\(added)")
        let note = drawn(greeter, .added, "    // unreachable, on purpose")
        check("an added comment, with no line to pair with", note == ["comment: // unreachable, on purpose"], "\(note)")
        check("a closing brace is plain", drawn(greeter, .context, "}") == [])
        let plain = [drawn(notes, .removed, "status: draft"), drawn(notes, .added, "status: final")]
        check("a file the highlighter doesn't know: no colours, what changed marked", plain == [["changed: draft"], ["changed: final"]], "\(plain)")

        // Many files: the pane reads as a list of them.
        check("two files: their cards start open", !diff.isFolded("Greeter.swift") && !diff.isFolded("notes.txt"))
        // Nine more, moved in at once: a refresh sees all of them or none.
        let batch = scratch.appendingPathComponent("more")
        try? FileManager.default.createDirectory(at: batch, withIntermediateDirectories: true)
        for i in 1...9 { try? "one more\n".write(to: batch.appendingPathComponent("more\(i).txt"), atomically: true, encoding: .utf8) }
        try? FileManager.default.moveItem(at: batch, to: repo.appendingPathComponent("more"))
        let more = (1...9).map { "more/more\($0).txt" }
        check("eleven files: the cards that come start folded", await eventually { diff.shownFiles.count == 11 } && more.allSatisfy(diff.isFolded))
        check("the open ones stay open: one may be being read", !diff.isFolded("Greeter.swift") && !diff.isFolded("notes.txt"))
        if let png = ProcessInfo.processInfo.environment["TERMINUS_DUMP_PNG"] {
            await pause(0.8)
            app.captureWindow(to: png)
        }
        // The pane header's Expand All, then Collapse All.
        diff.expandAll()
        check("Expand All opens every card", diff.shownFiles.allSatisfy { !diff.isFolded($0.path) })
        diff.collapseAll()
        check("Collapse All folds every card", diff.everyCardFolded)
        // A click on a card's header, then the agent writes another file.
        diff.toggleFold("Greeter.swift")
        write("more10.txt", ["and another"])
        check(
            "a card opened with a click stays open through a refresh",
            await eventually { diff.shownFiles.count == 12 } && !diff.isFolded("Greeter.swift") && diff.isFolded("more10.txt"))

        let busy = scratch.appendingPathComponent("busyrepo")
        try? FileManager.default.createDirectory(at: busy, withIntermediateDirectories: true)
        try? await git(["init", "-q", "-b", "main"], in: busy)
        for i in 1...12 { try? "new\n".write(to: busy.appendingPathComponent("file\(i).txt"), atomically: true, encoding: .utf8) }
        app.newTab(in: busy)
        check(
            "a checkout with 12 changed files opens as a list, every card folded",
            await eventually { diff.root?.resolvingSymlinksInPath() == busy.resolvingSymlinksInPath() && diff.shownFiles.count == 12 } && diff.everyCardFolded)
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

        // The chrome: every column is a card, and the gaps are measured
        // where they are seen — between the cards themselves, with the
        // shut columns (editor, changes, inbox) costing nothing. A divider
        // wide enough to be the gap was measured for those too, and took
        // 30 pt off the right of the window.
        let columns = app.split.splitViewItems.map(\.viewController.view)
        check("every column is a card", columns.allSatisfy { $0 is CardColumn }, columns.map { "\(Swift.type(of: $0))" }.joined(separator: ", "))
        let body = splitView.superview!
        let content = window.contentView!
        func cards() -> [CGRect] {
            app.split.splitViewItems.filter { !$0.isCollapsed }
                .map { $0.viewController.view.superview!.frame.insetBy(dx: CardColumn.margin, dy: 0) }
        }
        func gaps(_ shown: [CGRect]) -> [CGFloat] { zip(shown, shown.dropFirst()).map { $1.minX - $0.maxX } }
        let shown = cards()
        check(
            "and they are \(Int(CardColumn.gap)) pt apart", gaps(shown).allSatisfy { abs($0 - CardColumn.gap) < 0.5 },
            gaps(shown).map { "\($0)" }.joined(separator: ", "))
        check(
            "the cards are inset from the window on three sides",
            body.frame.minX + (shown.first?.minX ?? 0) == CardColumn.gap
                && content.frame.maxX - (body.frame.minX + (shown.last?.maxX ?? 0)) == CardColumn.gap
                && body.frame.minY == CardColumn.gap,
            "\(shown.map { $0.integral }) in body \(body.frame.integral) of \(content.frame.integral)")

        // The changes pane opens with the editor still shut between it and
        // the terminal — the case a measured divider made worst: two of
        // them, 20 pt, in the middle of the window.
        app.toggleDiff(nil)
        // Uncollapsing is published before the pane is laid out; its frame
        // is .null until then, and .null insets to infinity.
        await eventually(3) { (self.app.diffItem?.viewController.view.superview?.frame.width ?? 0) > 1 }
        let opened = cards()
        check("a column opening beyond a shut one keeps the gap", gaps(opened).allSatisfy { abs($0 - CardColumn.gap) < 0.5 }, gaps(opened).map { "\($0)" }.joined(separator: ", "))
        check(
            "and the window's inset is unchanged",
            content.frame.maxX - (body.frame.minX + (opened.last?.maxX ?? 0)) == CardColumn.gap,
            "\(opened.map { $0.integral })")
        app.toggleDiff(nil)
        // The strip is the row the traffic lights sit in, or the tabs float
        // above or below them.
        let close = window.standardWindowButton(.closeButton)!
        let lights = close.convert(close.bounds, to: nil)
        let strip = app.tabBarView?.frame.height ?? 0
        check(
            "the strip is as tall as the traffic lights' row",
            abs(strip - ((window.frame.height - lights.maxY) * 2 + lights.height)) < 2,
            "strip \(strip), lights \(lights.integral) in \(window.frame.height)")
        let heights = Set(app.store.tabFrames.values.map { Int($0.height) })
        check("a tab is 30 pt tall", heights == [30], "\(heights)")
    }

    /// Dropping a tab onto a pane: the only way to make a split out of
    /// something that is already running.
    private func dropSplitScenario() async {
        let home = FileManager.default.homeDirectoryForCurrentUser
        await waitForPrompt()
        let first = app.store.selected!
        first.customTitle = "keeper"
        app.newTab(in: home)
        let dragged = app.store.selected!
        dragged.customTitle = "moving"
        await waitForPrompt()
        let moved = dragged.terminal
        // Something running in it, so there is a reason not to recreate it.
        await runAndExpect("echo mine > \(out("mine").path)", file: out("mine"), content: "mine", "it has run something")
        let ledger = app.blocks(of: moved)
        app.store.select(first)
        check("two tabs, one pane each", app.store.tabs.count == 2 && first.terminals.count == 1)

        app.movePane(moved, from: dragged, into: first, .right)
        check("the dragged tab is gone", app.store.tabs.count == 1, "\(app.store.tabs.map(\.title))")
        check("its pane joined the other tab", first.terminals.count == 2, "\(first.terminals.count)")
        check("the very same pane, not a new one", first.terminals.contains { $0 === moved })
        check("beside the one that was there", await eventually(3) { moved.frame.minX > first.terminals[0].frame.minX })
        check("and it has the keyboard", await eventually(2) { self.window.firstResponder === moved })
        // The pty survived: what it had run is still its own.
        check("what it had run came with it", app.blocks(of: moved) === ledger)
        check(
            "and it is still alive", await eventually(8) { (moved.visibleText ?? "").contains("echo mine") },
            String((moved.visibleText ?? "").suffix(40)).debugDescription)

        // Where a drop lands, for each zone.
        let rect = CGRect(x: 0, y: 0, width: 400, height: 200)
        check("the middle adds it to the tab", DropZone.at(CGPoint(x: 200, y: 100), in: rect) == .into)
        check("the top splits up", DropZone.at(CGPoint(x: 200, y: 10), in: rect) == .up)
        check("the left splits left", DropZone.at(CGPoint(x: 10, y: 100), in: rect) == .left)
    }

    /// Selecting terminal text and handing it to an agent.
    private func askAgentScenario() async {
        let home = FileManager.default.homeDirectoryForCurrentUser
        await waitForPrompt()
        guard let pane = app.store.selected?.terminal else { return check("a pane", false) }
        app.newTab(in: home, agent: .claude, startAgent: false)
        let agent = app.store.selected!
        agent.customTitle = "api · claude"
        app.store.select(app.store.tabs[0])
        await waitForPrompt()

        // Something worth selecting, from a command that failed. Short and
        // with no path in it: synthetic typing drops characters under a
        // full parallel run, and a temp path is sixty of them.
        type("(echo AssertionError 401; exit 1)")
        pressReturn()
        check(
            "a command failed, with something worth selecting",
            await eventually(12) { (pane.visibleText ?? "").contains("AssertionError 401") },
            String((pane.visibleText ?? "").suffix(60)).debugDescription)
        pane.perform(binding: "select_all")
        let selected = await eventually(5) { pane.selectionText?.contains("AssertionError 401") == true }
        check("the selection can be read", selected, String((pane.selectionText ?? "none").prefix(40)).debugDescription)
        check("and libghostty says where it is", pane.selection?.origin != .zero, "\(pane.selection?.origin ?? .zero)")

        app.askAboutSelection(nil)
        check("⌘L opens the sheet", await eventually(3) { self.window.attachedSheet != nil })
        check("with the agent tab offered", app.askAgent.targets.contains { $0.title == "api · claude" }, "\(app.askAgent.targets.map(\.title))")
        check("and a new tab as the fallback", app.askAgent.targets.last?.id == nil)
        check("an existing agent chosen first", app.askAgent.chosen == agent.id)
        check(
            "the failed command came with it", app.askAgent.command?.exit == 1,
            "exit \(app.askAgent.command?.exit ?? -99) of \(app.askAgent.command?.command ?? "nothing")")
        app.askAgent.message = "Fix this failing test"
        let prompt = app.askAgent.prompt()
        check("the prompt leads with what you typed", prompt.hasPrefix("Fix this failing test"), String(prompt.prefix(40)).debugDescription)
        check("then the command and its exit", prompt.contains("exit 1"), String(prompt.prefix(120)).debugDescription)
        check("then the selection", prompt.contains("AssertionError"), "")
        clickSheetButton("Cancel")
        _ = await eventually(3) { self.window.attachedSheet == nil }
    }

    /// The inbox: what is waiting, the question each one is asking, and
    /// answering it without leaving the column.
    private func inboxScenario() async {
        let home = FileManager.default.homeDirectoryForCurrentUser
        await waitForPrompt()
        let shell = app.store.selected!
        shell.customTitle = "zsh"
        app.newTab(in: home, agent: .claude, startAgent: false)
        let agent = app.store.selected!
        agent.customTitle = "api · claude"
        await waitForPrompt()

        app.toggleInbox(nil)
        check("⌘I opens the inbox", app.inboxItem?.isCollapsed == false)
        check("empty until something wants you", app.inbox.isEmpty && app.inbox.summary == "Nothing waiting", app.inbox.summary)

        // A question on the agent's screen, exactly as Claude Code asks it.
        // Written to a file and `cat`ed rather than typed: ten lines of
        // synthetic typing garble under load, and what is being tested is
        // the reading, not the typing.
        let question = """
            Edit file  apps/api/src/webhooks/bank.ts
             41 -   const event = JSON.parse(body)
             41 +   const event = verifySignature(body, headers)

            Do you want to make this edit?
            1. Yes
            2. Yes, and don't ask again this session
            3. No, and tell Claude what to do differently
            """
        try? question.write(to: out("prompt.txt"), atomically: true, encoding: .utf8)
        type("cat \(out("prompt.txt").path)")
        pressReturn()
        let asked = await eventually(10) { (agent.terminal.visibleText ?? "").contains("3. No, and tell") }
        check("the agent is asking something", asked, "")

        // It only lands in the inbox once the tab says it needs you — the
        // inbox is the attention list, not a screen scraper.
        app.store.select(shell)
        agent.activity.handle(.notification(title: "Claude", body: "needs your permission"), visible: false)
        app.refreshInbox()
        check("a waiting tab is in the inbox", app.inbox.entries.count == 1, "\(app.inbox.entries.count)")
        check("blocked first", app.inbox.entries.first?.mark == .waiting)
        check("and the summary counts it", app.inbox.summary == "1 waiting", app.inbox.summary)

        guard let entry = app.inbox.entries.first, let prompt = entry.prompt else {
            return check("its question was read off the screen", false, app.inbox.entries.first?.title ?? "no entry")
        }
        check("its question was read off the screen", prompt.question == "Do you want to make this edit?", prompt.question)
        check("with every choice", prompt.choices.map(\.key) == ["1", "2", "3"], "\(prompt.choices.map(\.key))")
        check("the diff above it", prompt.preview.contains { $0.contains("verifySignature") }, prompt.preview.joined(separator: " / "))
        check("deny found by its words", prompt.deny?.key == "3", prompt.deny?.key ?? "none")
        check("and the card names it", entry.headline.contains("wants to make this edit"), entry.headline)

        // Answering types the number and Return into that pane.
        app.answer(prompt.choices[0], in: entry.id)
        check(
            "answering types the choice into the agent",
            await eventually(8) { (agent.terminal.visibleText ?? "").contains("command not found: 1") },
            String((agent.terminal.visibleText ?? "").suffix(60)).debugDescription)

        app.toggleInbox(nil)
        check("⌘I closes it again", app.inboxItem?.isCollapsed == true)
    }

    /// The command ledger, against a real shell: libghostty gives no
    /// command boundaries, so everything here is inferred and everything
    /// here can therefore be wrong.
    private func blocksScenario() async {
        await waitForPrompt()
        guard let pane = app.store.selected?.terminal else { return check("a pane", false) }
        let blocks = app.blocks(of: pane)
        check(
            "the scrollbar is reported at all",
            await eventually(8) {
                pane.drawNow()
                return blocks.ledger.total > 0
            }, "total=\(blocks.ledger.total) rows=\(blocks.ledger.rows)")
        check("the cell has a size", pane.cellSize.height > 0, "\(pane.cellSize)")

        // A command that succeeds, with output of a known length.
        type("for i in 1 2 3 4 5; do echo line $i; done")
        pressReturn()
        let ran = await eventually(10) { blocks.ledger.blocks.contains { !$0.isRunning && $0.command.contains("echo line") } }
        check("a command becomes a block", ran, blocks.ledger.blocks.map(\.command).joined(separator: " | "))
        check(
            "and the directory the prompt shows does not",
            !blocks.ledger.blocks.contains { CommandLedger.isPrompt($0.command, cwd: pane.workingDirectory) },
            blocks.ledger.blocks.map(\.command).joined(separator: " | "))
        guard let ok = blocks.ledger.blocks.last(where: { $0.command.contains("echo line") }) else { return }
        check("that did not fail", !ok.failed, "exit \(ok.exit ?? -1)")
        // Five lines on a fresh screen never reach the scrollback, so the
        // block has no rows of its own — the ledger must say so rather
        // than name rows that are not there.
        check("short output has no rows to point at", !ok.isLocated, "\(ok.rows) rows (\(ok.startRow)…\(ok.endRow))")

        // Read back off the screen, because it is not located.
        app.copyOutput(of: pane)
        let copied = NSPasteboard.general.string(forType: .string) ?? ""
        check("⇧⌘C copies that block's output", copied.contains("line 1") && copied.contains("line 5"), copied.debugDescription)
        check("and nothing from before it", !copied.contains("Last login"), copied.debugDescription)

        // Enough output to push into the scrollback: now a block has rows
        // of its own, and everything row-based works on it.
        type("for i in $(seq 1 120); do echo filler $i; done")
        pressReturn()
        // The scrollbar is only recomputed when a frame is drawn, and this
        // window is never activated — so the renderer has to be asked, the
        // same way tab peek asks it.
        let scrolled = await eventually(15) {
            pane.drawNow()
            return blocks.ledger.blocks.last { $0.command.contains("seq 1 120") }?.isLocated == true
        }
        guard let big = blocks.ledger.blocks.last(where: { $0.command.contains("seq 1 120") }) else {
            return check("output that scrolls gets rows", false)
        }
        check("output that scrolls gets rows", scrolled, "\(big.rows) rows (\(big.startRow)…\(big.endRow))")
        check("the map can place it", blocks.ledger.position(of: big) != nil)
        app.copyOutput(of: pane)
        let fromRows = NSPasteboard.general.string(forType: .string) ?? ""
        check(
            "and its output reads back out of them", fromRows.contains("filler 1") && fromRows.contains("filler 120"),
            "rows \(big.startRow)…\(big.endRow) got \(fromRows.components(separatedBy: "\n").count) lines: "
                + String(fromRows.prefix(20)).debugDescription + "…" + String(fromRows.suffix(20)).debugDescription)

        // A failure, which is what the ring and ⌥⌘↓ are for. In a subshell:
        // a bare `exit 3` would take the pane with it.
        type("sh -c 'for i in $(seq 1 60); do echo broke $i; done; exit 3'")
        pressReturn()
        let failed = await eventually(15) {
            pane.drawNow()
            return blocks.ledger.locatedFailures.contains { $0.command.contains("exit 3") }
        }
        check("a non-zero exit is a failure", failed, blocks.ledger.blocks.map { "\($0.command)=\($0.exit ?? -1)" }.joined(separator: " | "))
        guard let bad = blocks.ledger.locatedFailures.last else { return }
        check("with its exit code in its detail", bad.detail.hasPrefix("exit 3"), bad.detail)
        check("and ⌥⌘↓ finds it", blocks.ledger.nextFailure(after: 0)?.id == bad.id)

        // ⌘R types it again without running it: a destructive command is
        // still yours to press Return on.
        app.rerun(in: pane)
        check(
            "⌘R types the last command back", await eventually(5) { (pane.visibleText ?? "").contains("exit 3") },
            "")
    }

    /// Islands in the strip: making one, what it does to the order, the
    /// things a chip can do, and what happens to the rest of the window.
    private func groupsScenario() async {
        let home = FileManager.default.homeDirectoryForCurrentUser
        await waitForPrompt()
        let first = app.store.selected!
        first.customTitle = "api"
        app.newTab(in: home, agent: .claude, startAgent: false)
        let second = app.store.selected!
        second.customTitle = "web"
        app.newTab(in: home, agent: nil, startAgent: false)
        let loose = app.store.selected!
        loose.customTitle = "loose"
        check("three tabs", app.store.tabs.count == 3)

        // ⌘-click marks a tab, and Group Selected Tabs takes the marked set.
        app.store.select(first)
        app.store.toggleMultiSelection(second)
        check("⌘-click marks a tab", app.store.isMarked(second) && app.store.selectedTabs.count == 2)
        app.groupSelectedTabs(nil)
        guard let group = app.store.groups.first else { return check("an island", false) }
        check("the island takes both", app.store.tabs(in: group).map(\.title) == ["api", "web"], "\(app.store.tabs(in: group).map(\.title))")
        check("and the marks are spent", app.store.multiSelection.isEmpty)
        check("its name is editable at once", app.store.renamingGroupID == group.id)
        check("with its settings under it", await eventually(3) { self.app.groupPopover?.isShown == true })
        app.groupPopover?.performClose(nil)
        app.store.renamingGroupID = nil

        // The invariant everything else depends on: one contiguous run.
        check(
            "a group's tabs are one run", app.store.strip.map(\.tabs.count) == [2, 1],
            "\(app.store.strip.map { $0.tabs.map(\.title) })")

        // Dragging: the island takes the tab dropped inside it, and lets it
        // go when it is dropped past the end.
        await eventually(3) { self.app.store.tabFrames.count == 3 && self.app.store.groupChipFrames.count == 1 }
        guard let span = app.store.islandSpans.first?.span else { return check("the island is drawn", false) }
        app.store.drop(loose, atPointerX: span.upperBound - 2)
        check("a tab dropped inside an island joins it", loose.groupID == group.id, "\(loose.groupID == nil ? "none" : "joined")")
        check("still one run", app.store.strip.map(\.tabs.count) == [3], "\(app.store.strip.map { $0.tabs.map(\.title) })")
        await eventually(3) { self.app.store.tabFrames[loose.id] != nil }
        app.store.drop(loose, atPointerX: 5000)
        check("and dropped outside it leaves", loose.groupID == nil)

        // ⌃⌘1 goes to the first island, expanding it if it is shut.
        app.store.select(loose)
        app.store.setCollapsed(group, true)
        let item = NSMenuItem()
        item.tag = 1
        app.showGroup(item)
        check("⌃⌘1 goes to the first island", app.store.selected?.groupID == group.id, app.store.selected?.title ?? "none")
        check("expanding it on the way", !group.isCollapsed)

        // Focus: only this island is in the strip, and the others' notices
        // are held — unless an agent is blocked, which always breaks through.
        app.toggleFocus(on: group)
        check("focus narrows the strip to one island", app.store.focusedStrip.map(\.tabs.count) == [2], "\(app.store.focusedStrip.count)")
        check(
            "a blocked agent still breaks through",
            GroupFocus.breaksThrough(tabGroup: nil, focused: group.id, mark: .waiting)
                && !GroupFocus.breaksThrough(tabGroup: nil, focused: group.id, mark: .done))
        app.toggleFocus(on: group)
        check("and leaving focus brings them back", app.store.focusedStrip.count == 2, "\(app.store.focusedStrip.count)")

        // Broadcast types one line into every tab of the island.
        app.beginBroadcast(to: group)
        check("broadcast names its targets", app.broadcast.summary == "Broadcasting to 2 tabs in \(group.name)", app.broadcast.summary)
        app.broadcast.text = "echo grouped > \(out("broadcast").path)"
        check("it sends", app.broadcast.send() != nil)
        check(
            "into every tab", await eventually(8) { contents(self.out("broadcast")) == "grouped" },
            contents(out("broadcast")) ?? "missing")
        app.stopBroadcast()

        // Stashing takes the island out of the strip and leaves it running.
        let running = app.store.tabs(in: group).count
        app.stashGroup(group)
        check(
            "a stashed island leaves the strip", app.store.strip.map { $0.tabs.map(\.title) } == [["loose"]],
            "\(app.store.strip.map { $0.tabs.map(\.title) })")
        check("its tabs are still there", app.store.tabs(in: group).count == running)
        check("and it says how long ago", TabGroup.stashedAgo(Date()) == "just now")
        app.restoreGroup(group)
        check(
            "restoring brings it back", app.store.strip.map(\.tabs.count) == [2, 1],
            "\(app.store.strip.map { $0.tabs.map(\.title) })")

        // Ungrouping leaves the tabs exactly where they were.
        let order = app.store.tabs.map(\.title)
        app.store.ungroup(group)
        check("ungrouping keeps the order", app.store.tabs.map(\.title) == order, "\(app.store.tabs.map(\.title))")
        check("and the island is gone", app.store.groups.isEmpty)

        // A new tab is not swallowed by the island the selected tab is in —
        // a group over a checkout soon holds every tab, and inheriting it
        // meant ⌘T, the +, the palette and the sidebar all disappeared into
        // it (NewTabGroup). `newTab(from:)` is what the strip's + and ⌘T
        // call, so these go through it and not the directory path.
        guard let island = app.store.addToNewGroup([first, second], name: "work") else {
            return check("an island again", false)
        }
        check("a new island binds no folder by itself", island.folder == nil)
        app.groupPopover?.performClose(nil)
        app.store.renamingGroupID = nil
        app.store.select(first)
        app.newTab(from: first.terminal)
        check("⌘T stays out of the selected tab's island", app.store.selected?.groupID == nil)
        check(
            "and lands after the island's run", app.store.tabs(in: island).map(\.title) == ["api", "web"],
            "\(app.store.tabs.map(\.title))")
        check(
            "the island's own + is the way in",
            {
                app.newTab(in: island)
                return app.store.selected?.groupID == island.id
            }())

        // Bound to the folder its tabs are in — the box in the group popover.
        // ⌘T inside it inherits that very folder, which is what put every new
        // tab back in the group: the binding is about opening a folder, not
        // about opening another tab where you already are.
        island.folder = home.path
        app.store.select(first)
        app.newTab(from: first.terminal)
        check("a folder-bound island still doesn't catch ⌘T", app.store.selected?.groupID == nil, island.folder ?? "unbound")
        app.newTab(in: home)
        check("but it does catch a tab opened for that folder", app.store.selected?.groupID == island.id)
        island.folder = nil

        // With every tab inside it, which way the strip's + goes is
        // genuinely ambiguous: the tab opens outside and the window asks.
        app.store.add(app.store.tabs.filter { $0.groupID != island.id }, to: island)
        await eventually(3) { self.app.store.groupChipFrames[island.id] != nil }
        app.store.select(first)
        app.newTab(from: first.terminal)
        check("with the island holding the whole strip, the tab still opens outside it", app.store.selected?.groupID == nil)
        check("and the window asks where it belongs", await eventually(3) { self.app.newTabPopover?.isShown == true })
        app.newTabPopover?.performClose(nil)
        // The window keeps the popover it opened; drop it so the next check
        // can only see one that was opened again.
        app.newTabPopover = nil

        // Answered once — here by hand, as the popover's button does — it
        // stops asking.
        island.takesNewTabs = true
        app.store.select(first)
        app.newTab(from: first.terminal)
        check("an island told to take new tabs takes them", app.store.selected?.groupID == island.id)
        check("without asking twice", app.newTabPopover?.isShown != true)
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

        // A working agent changes its tab many times a second; a change
        // elsewhere must still be saved meanwhile, not after a quiet second.
        let churn = Task { @MainActor in
            while !Task.isCancelled {
                tabs[0].objectWillChange.send()
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        tabs[1].customTitle = "renamed while busy"
        check(
            "a change is saved while another tab keeps changing",
            await eventually(4) { SessionState.load()?.tabs.last?.customTitle == "renamed while busy" })
        churn.cancel()
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
            // And the pane header's pills, which come from the same scan
            // (every third tick of the poll that walks the selected tab).
            let onTheTab = await eventually(12) { first.ports.contains { $0.port == port } }
            check("and so is the tab's, for the pane header", onTheTab, "\(first.ports.map(\.port))")
            check(
                "which makes it a server", onTheTab && first.kind == .server,
                "\(first.kind.rawValue)")
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
        // The agent commits: git writes only under main's .git (the worktree's
        // index, HEAD, its branch), nothing in the worktree itself.
        await pause(1)
        try? await git(["add", "agent-change.txt"], in: worktree)
        try? await git(["commit", "-q", "-m", "agent commit"], in: worktree)
        check("a commit in the agent's worktree clears the pane", await eventually(5) { self.app.diff.files.isEmpty }, "\(app.diff.files.map(\.path))")

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
        // Esc in the bar, with text in it, gives the terminal the keyboard and
        // keeps the highlights (as in Ghostty); Esc there then closes the bar.
        // Seen by hand: the keyboard bounced back into the bar, so Esc never
        // closed it. Through the app's event path, as a key press arrives.
        func escape() {
            NSApp.sendEvent(
                NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                    isARepeat: false, keyCode: 53)!)
        }
        check(
            "a search starting gives the bar's field the keyboard",
            await eventually(2) {
                guard let bar = self.app.searchBar, let field = (self.window.firstResponder as? NSTextView)?.delegate as? NSView else { return false }
                return field.isDescendant(of: bar)
            })
        escape()
        await pause(0.5)
        check(
            "Esc in the bar gives the terminal the keyboard, and it stays there", window.firstResponder === tab.terminal && tab.terminal.search.barVisible,
            "keyboard: \(window.firstResponder.map { String(describing: Swift.type(of: $0)) } ?? "nil")")
        escape()
        check("Esc again, in the terminal, closes the bar", await eventually(2) { self.app.searchBar?.isHidden == true && !tab.terminal.search.isActive })

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
            }, "\(app.editor?.document.url?.path ?? "nothing") line \(app.editor?.selectedLine ?? -1)")

        // Hovering reports the link. libghostty pushes the URL and no
        // rectangle, so the pane header is the only place it can be said.
        var nudge = false
        check(
            "hovering a link reports it",
            await eventually(10) {
                // The action comes when the hovered *cell* changes, so the
                // pointer has to actually move — polling one point reports
                // nothing after the first time.
                nudge.toggle()
                let at = NSPoint(x: point.x + (nudge ? CGFloat(size.cell_width_px) / scale : 0), y: point.y)
                terminal.mouseMoved(
                    with: NSEvent.mouseEvent(
                        with: .mouseMoved, location: at, modifierFlags: .command,
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: self.window.windowNumber,
                        context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!)
                return self.app.blocks(of: terminal).hoveredLink?.contains("main.swift") == true
            }, app.blocks(of: terminal).hoveredLink ?? "none")
    }

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
        // Merged by a merge commit; merged, pushed, then deleted on the remote;
        // gone as after a squash but committed on and never pushed (stays);
        // merged but dirty; merged with a tab in it; still open.
        let merged = await worktree("merged")
        try? await git(["merge", "-q", "--no-ff", "-m", "Merge merged", "merged"], in: repo)
        let squashed = await worktree("goneMerged")
        try? await git(["merge", "-q", "--no-ff", "-m", "Merge goneMerged", "goneMerged"], in: repo)
        try? await git(["push", "-q", "origin", "--delete", "goneMerged"], in: repo)
        let continued = await worktree("continued")
        try? await git(["push", "-q", "origin", "--delete", "continued"], in: repo)
        try? await git(["commit", "-q", "--allow-empty", "-m", "more work, never pushed"], in: continued)
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
            "the merged ones are marked — not the open one, nor one with unpushed commits",
            Set(app.worktrees.merged.keys) == ["merged", "goneMerged", "dirty", "busy"],
            app.worktrees.merged.keys.sorted().joined(separator: ","))
        check(
            "and say why", app.worktrees.merged["goneMerged"] == .upstreamGone && app.worktrees.merged["merged"] == .mergedInto("origin/main"))

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
        await eventually(10) { self.app.worktrees.worktrees.count == 5 }
        let branches = (try? await Git.run(["branch", "--format=%(refname:short)"], in: repo)) ?? ""
        let names = Set(branches.split(separator: "\n").map(String.init))
        check("and their branches", !names.contains("merged") && !names.contains("goneMerged"), names.sorted().joined(separator: ","))
        check(
            "keeps the rest",
            [dirty, busy, open, continued].allSatisfy { FileManager.default.fileExists(atPath: $0.path) }
                && names.isSuperset(of: ["dirty", "busy", "open", "continued"]))
        check(
            "the list updates", await eventually { self.app.worktrees.worktrees.count == 5 },
            app.worktrees.worktrees.map(\.displayName).joined(separator: ","))
    }

    /// Splits: made from the menu and from Ghostty's own bindings, the
    /// keyboard moved and the layout resized by them, a divider dragged,
    /// a pane zoomed, and panes closed by exit and by ⌘W.
    /// A pane filling its tab fills what is left under its header.
    @MainActor private static func underHeader(_ host: SplitHostView) -> CGSize {
        CGSize(width: host.bounds.width, height: host.bounds.height - SplitHostView.headerHeight)
    }

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
        check("unfocused panes are dimmed", host.dimmedPanes == 2, "\(host.dimmedPanes)")

        // Every pane wears its own header, and it is the terminal that gives
        // up the room for it — not the pane's share of the tab.
        let headers = tab.terminals.map { host.header(of: $0) }
        check("every pane has a header", headers.allSatisfy { $0 != nil && !$0!.isHidden }, "\(headers.map { $0 == nil ? "none" : ($0!.isHidden ? "hidden" : "shown") })")
        let sits = zip(tab.terminals, headers).allSatisfy { pane, header in
            guard let header else { return false }
            return abs(header.frame.maxY - pane.frame.minY) < 0.5 && abs(header.frame.height - SplitHostView.headerHeight) < 0.5
                && abs(header.frame.width - pane.frame.width) < 0.5
        }
        check("directly above its terminal, full width", sits, zip(tab.terminals, headers).map { "\($1?.frame.integral.debugDescription ?? "none") / \($0.frame.integral)" }.joined(separator: " | "))
        app.toggleSplitZoom(first)
        let zoomedHeaders = await eventually(2) { tab.terminals.compactMap { host.header(of: $0) }.count { !$0.isHidden } == 1 }
        check("a zoomed pane leaves one header", zoomedHeaders, "\(tab.terminals.compactMap { host.header(of: $0) }.count { !$0.isHidden })")
        app.toggleSplitZoom(first)
        _ = await eventually(2) { host.header(of: right)?.isHidden == false }

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
            "zoom shows the pane alone, under its header",
            await eventually(2) { first.frame.size == Self.underHeader(host) && right.isHidden && below.isHidden },
            "\(first.frame.size) want \(Self.underHeader(host))")
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
        check(
            "the last pane fills the tab again", await eventually(2) { first.frame.size == Self.underHeader(host) },
            "\(first.frame.size) want \(Self.underHeader(host))")
        check("and has the keyboard", await eventually(2) { self.window.firstResponder === first })
        // A close that arrives for a pane already gone (confirmed in a
        // sheet, an exit noticed late) must not take the tab with it.
        app.removePane(right, from: tab)
        check("a late close of a gone pane leaves the tab", app.store.tabs.contains { $0.id == tab.id } && tab.terminals == [first])
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

    /// Tab peek: three fingers (here, its menu action) and every tab's live
    /// terminal becomes a card. Its whole promise is that the terminals are
    /// moved, never resized — so that is what this measures.
    private func peekScenario() async {
        await waitForPrompt()
        guard let first = app.store.selected else { return check("a tab", false) }
        app.newTab(from: first.terminal)
        guard let second = app.store.selected, second.id != first.id else { return check("a second tab", false) }
        app.splitRight(nil)
        check("a split tab to preview", second.terminals.count == 2)
        app.newTab(from: second.terminal)
        guard let third = app.store.selected else { return check("a third tab", false) }
        _ = await eventually(3) { first.terminal.frame.width > 0 }

        let panes = { self.app.store.tabs.flatMap { $0.terminals } }
        let sizes = panes().compactMap { $0.surface.map { ghostty_surface_size($0) } }
        let frames = panes().map(\.frame)

        app.toggleTabPeek(nil)
        check("⇧⌘E opens the peek", app.peekView?.isHidden == false)
        check("it has the keyboard", window.firstResponder === app.peekView)
        check("every tab gets a card", app.peek.model.cards.count == app.store.tabs.count, "\(app.peek.model.cards.count)")
        check("the selected tab is highlighted", app.peek.model.highlighted == third.id)
        check(
            "every host is scaled into its card", app.store.tabs.allSatisfy { !CATransform3DIsIdentity(app.host(of: $0)?.layer?.transform ?? CATransform3DIdentity) },
            app.store.tabs.map { "\(app.host(of: $0)?.layer?.transform.m11 ?? -1)" }.joined(separator: " "))

        // The point of the whole design: pixels move, the pty does not.
        await pause(0.4)
        let after = panes().compactMap { $0.surface.map { ghostty_surface_size($0) } }
        let sameGrid = sizes.count == after.count && zip(sizes, after).allSatisfy { $0.columns == $1.columns && $0.rows == $1.rows }
        check("no terminal is resized by the peek", sameGrid, "\(sizes.map(\.columns)) → \(after.map(\.columns))")
        check(
            "and no pane's frame moved", zip(frames, panes().map(\.frame)).allSatisfy { $0 == $1 },
            "a changed frame is a reflow")

        check("every tab is showing, not just the selected one", app.store.tabs.allSatisfy { app.host(of: $0)?.isHidden == false })
        let container = app.peekView?.superview
        check("the cards stay inside the terminal column", app.peek.model.cards.allSatisfy { container?.bounds.insetBy(dx: -2, dy: -2).contains($0.frame) ?? false })
        check("so the column clips what hangs out of it", container?.clipsToBounds == true)

        if let png = ProcessInfo.processInfo.environment["TERMINUS_DUMP_PNG"] {
            await pause(0.8)
            app.captureWindow(to: png)
        }

        // The arrows move the highlight; Return goes there.
        let left = TabPeek.move(.left, from: third.id, in: app.peek.model.cards)
        check("there is a card to the left", left != third.id)
        key(123, "\u{1c}")
        check(
            "an arrow key moves the highlight", await eventually(2) { self.app.peek.model.highlighted == left },
            "responder=\(String(describing: window.firstResponder.map { String(describing: Swift.type(of: $0)) })) highlighted=\(String(describing: app.peek.model.highlighted)) want=\(left) open=\(app.peek.isOpen)"
        )
        key(36, "\r")
        check("Return goes to that tab", await eventually(2) { self.app.peekView?.isHidden == true && self.app.store.selectedID == left })
        check("with the keyboard", await eventually(3) { self.app.store.selected?.terminal === self.window.firstResponder })
        check(
            "and the other tabs go back to sleep",
            await eventually(2) { self.app.store.tabs.allSatisfy { $0.id == left || self.app.host(of: $0)?.isHidden == true } })
        check(
            "every host back where it was",
            app.store.tabs.allSatisfy { CATransform3DIsIdentity(app.host(of: $0)?.layer?.transform ?? CATransform3DIdentity) })

        // Seen by hand on the overview: something else had the keyboard and
        // Esc did nothing. The peek goes through the same monitor.
        app.toggleTabPeek(nil)
        check("it opens again", app.peekView?.isHidden == false)
        window.makeFirstResponder(app.store.selected?.terminal)
        let escape = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false, keyCode: 53)!
        NSApp.sendEvent(escape)
        check("Esc closes it even when it lost the keyboard", await eventually(2) { self.app.peekView?.isHidden == true })
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

    /// Finder's Open With and "New Overterm Tab Here": a folder becomes a
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
        check("New Overterm Tab Here opens one there", app.store.selected?.workingDirectory == other.path, error as String)
        pasteboard.releaseGlobally()
    }

    /// The Sessions panel lists the repository's Claude conversations
    /// (worktrees and subfolders, not look-alike folders), newest first; a
    /// running one switches to its tab, another resumes in a new tab.
    private func sessionsScenario() async {
        let projects = scratch.appendingPathComponent("claude-projects")
        ClaudeUsageReader.projectsDirectory = projects
        let repo = scratch.appendingPathComponent("sessrepo").resolvingSymlinksInPath()
        let worktree = scratch.appendingPathComponent("sessrepo-wt").resolvingSymlinksInPath()
        let lookalike = scratch.appendingPathComponent("sessrepo-other").resolvingSymlinksInPath()
        for dir in [repo.appendingPathComponent("sub"), lookalike] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try? await git(["init", "-q", "-b", "main"], in: repo)
        try? await git(["commit", "-q", "--allow-empty", "-m", "i"], in: repo)
        try? await git(["worktree", "add", "-q", "-b", "feat/s", worktree.path], in: repo)
        let ids = (
            old: "00000000-0000-0000-0000-00000000000a", feature: "00000000-0000-0000-0000-00000000000b",
            sub: "00000000-0000-0000-0000-00000000000c", other: "00000000-0000-0000-0000-00000000000d",
            empty: "00000000-0000-0000-0000-00000000000e"
        )
        func transcript(_ id: String, cwd: URL, title: String?, age: TimeInterval) {
            let folder = projects.appendingPathComponent(ClaudeUsageReader.projectFolder(for: cwd.path))
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var lines = [#"{"type":"user","cwd":"\#(cwd.path)","message":{"role":"user","content":"\#(title ?? "")"}}"#]
            if let title { lines.append(#"{"type":"ai-title","aiTitle":"\#(title)"}"#) } else { lines = [#"{"type":"mode","cwd":"\#(cwd.path)"}"#] }
            let file = folder.appendingPathComponent("\(id).jsonl")
            try? (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: file.path)
        }
        transcript(ids.old, cwd: repo, title: "Old work", age: 3600)
        transcript(ids.feature, cwd: worktree, title: "Feature work", age: 10)
        transcript(ids.sub, cwd: repo.appendingPathComponent("sub"), title: "Subfolder chat", age: 600)
        transcript(ids.other, cwd: lookalike, title: "Not this repo", age: 5)
        transcript(ids.empty, cwd: repo, title: nil, age: 1)

        app.newTab(in: repo)
        await eventually { self.app.worktrees.worktrees.count == 2 }
        app.refreshSessions()
        let listed = await eventually(5) { self.app.sessions.sessions.count == 3 }
        check(
            "the repo's sessions, newest first", listed && app.sessions.sessions.map(\.id) == [ids.feature, ids.sub, ids.old],
            app.sessions.sessions.map { $0.activity.title ?? $0.id }.joined(separator: ", "))
        check("with their titles and where they ran", app.sessions.sessions.first?.activity.title == "Feature work" && app.sessions.sessions.first?.directory == worktree.path)
        // The row's worktree label: sessrepo-wt starts with "sessrepo" too.
        check(
            "labelled with its own worktree",
            app.sessions.sessions.first.flatMap { Worktree.containing($0.directory, in: self.app.worktrees.worktrees) }?.branch == "feat/s")
        if let png = ProcessInfo.processInfo.environment["TERMINUS_DUMP_PNG"] {
            AppEnvironment.defaults.set(SidebarPanel.sessions.rawValue, forKey: "sidebarPanel")
            await pause(1)
            app.captureWindow(to: png)
        }

        // A stand-in `claude --resume <feature>` running in its own tab.
        let script = scratch.appendingPathComponent("claude.sh")
        try? "cd '\(worktree.path)' && exec -a claude /bin/sh -c 'sleep 60; true' --resume \(ids.feature)\n"
            .write(to: script, atomically: true, encoding: .utf8)
        app.newTab(in: worktree)
        guard let claudeTab = app.store.selected else { return check("a tab", false) }
        await run("bash \(script.path) &", timeout: 6) {
            ProcessInspector().tree(root: SurfaceProcesses.shared.loginPID(of: claudeTab.terminal), tag: claudeTab.terminal.processTag)
                .flatMap(\.flattened).contains { $0.command.contains("--resume") }
        }
        app.refreshSessions()
        check("the running one is known, by its --resume id", await eventually(5) { self.app.sessions.running[ids.feature] == claudeTab.id })

        guard let feature = app.sessions.sessions.first(where: { $0.id == ids.feature }),
            let old = app.sessions.sessions.first(where: { $0.id == ids.old })
        else { return check("sessions", false) }
        app.store.select(app.store.tabs[0])
        let count = app.store.tabs.count
        app.resume(feature)
        check("clicking it goes to its tab", app.store.selectedID == claudeTab.id && app.store.tabs.count == count)
        app.resume(old, start: false)
        check(
            "another resumes in a new tab, where it ran",
            app.store.tabs.count == count + 1 && app.store.selected?.workingDirectory == repo.path && app.store.selected?.agent == .claude)
        for node in ProcessInspector().tree(root: SurfaceProcesses.shared.loginPID(of: claudeTab.terminal), tag: claudeTab.terminal.processTag)
            .flatMap(\.flattened) where node.name != "login" && node.name != "zsh"
        {
            kill(node.pid, SIGTERM)
        }
    }

    /// Settings (⌘,): a tab, as Warp's; settings.json behind it, as VS
    /// Code's — the page and the file edited by hand both apply at once, the
    /// file keeps what a person wrote, and one that doesn't parse is never
    /// written over. Appearance reaches terminals already open; General and
    /// Agents change what tabs and New Task do; Keyboard Shortcuts rebinds
    /// menus and Ghostty's keys.
    private func settingsScenario() async {
        let settings = Settings.shared
        let keys = Keybindings.shared
        await settledPrompt()
        guard let tab = app.store.selected, let surface = tab.terminal.surface else { return check("a tab", false) }
        func fileText() -> String { (try? String(contentsOf: settings.url, encoding: .utf8)) ?? "" }
        func overrides() -> String { (try? String(contentsOf: Settings.ghosttyOverridesFile, encoding: .utf8)) ?? "" }

        // The tab.
        (NSApp.delegate as? AppDelegate)?.showSettings(nil)
        check("⌘, opens the Settings tab", app.store.settingsOpen && app.store.settingsShowing && app.settingsView?.isHidden == false)
        check("the terminal tab under it isn't drawn selected, but still is", app.store.selectedID == tab.id)
        app.settingsPage.search = "theme"
        check("its search finds Appearance by a setting in it", app.settingsPage.sections == [.appearance], "\(app.settingsPage.sections)")
        app.settingsPage.search = "split"
        check("and Keyboard Shortcuts by a command", app.settingsPage.sections.contains(.shortcuts), "\(app.settingsPage.sections)")
        app.settingsPage.search = ""
        if let png = ProcessInfo.processInfo.environment["TERMINUS_DUMP_PNG"] {
            app.settingsPage.show(.appearance)
            await pause(0.8)
            app.captureWindow(to: png)
        }

        // A value from the page reaches open terminals, through settings.json.
        let configured = GhosttyRuntime.shared.configNumber("font-size") ?? 13
        let before = ghostty_surface_size(surface).cell_width_px
        settings.set("appearance.fontSize", .int(Int(configured) + 8))
        let grew = await eventually(4) { ghostty_surface_size(surface).cell_width_px > before }
        check("a font size reaches the terminal already open", grew, "\(before) → \(ghostty_surface_size(surface).cell_width_px)")
        check("settings.json holds it", fileText().contains("\"appearance.fontSize\": \(Int(configured) + 8)"), fileText())
        check("written as a Ghostty override", overrides().contains("font-size = \(Int(configured) + 8)"), overrides())
        settings.set("appearance.fontSize", nil)
        check(
            "Reset hands it back to the Ghostty config",
            // The overrides file stays: the keys the menu takes off Ghostty
            // are written there too, and they are not settings.
            await eventually(4) { ghostty_surface_size(surface).cell_width_px == before }
                && !fileText().contains("appearance.fontSize") && !overrides().contains("font-size"),
            fileText() + " / " + overrides())

        // settings.json by hand: applies at once, and keeps its comments when the page changes something.
        try? "{\n  // mine\n  \"appearance.unfocusedPaneDim\": 0.6\n}\n".write(to: settings.url, atomically: true, encoding: .utf8)
        check(
            "a hand edit applies at once (the pane dim)",
            await eventually(4) { abs((self.app.host(of: tab)?.dimColor.alphaComponent ?? 0) - 0.6) < 0.01 })
        settings.set("general.newTabDirectory", .string("home"))
        check(
            "the page edits the file in place, comments kept",
            fileText().contains("// mine") && fileText().contains("\"general.newTabDirectory\": \"home\"")
                && fileText().contains("\"appearance.unfocusedPaneDim\": 0.6"), fileText())

        // New tabs open at home, not in the current tab's folder.
        let folder = scratch.appendingPathComponent("somewhere")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        app.newTab(in: folder)
        check("a new tab comes out from under Settings", !app.store.settingsShowing && app.store.settingsOpen && app.settingsView?.isHidden == true)
        app.newTab(nil)
        check(
            "New tabs open in: Home",
            app.store.selected?.workingDirectory == FileManager.default.homeDirectoryForCurrentUser.path,
            app.store.selected?.workingDirectory ?? "nil")

        // A file that doesn't parse: the last good settings stay, it isn't written over.
        let broken = "{\n  \"general.newTabDirectory\": \"current\",\n  oops\n"
        try? broken.write(to: settings.url, atomically: true, encoding: .utf8)
        check("a broken file is reported", await eventually(4) { settings.problems.first?.contains("doesn't parse") == true }, "\(settings.problems)")
        check("and the last good settings stay", settings.newTabDirectory == .home)
        settings.set("general.confirmClose", .string("whenRunning"))
        check("the page doesn't write over it", fileText() == broken, fileText())
        settings.save(text: "{\n  \"general.confirmClose\": \"whenRunning\",\n  \"general.nonsense\": 1\n}\n")
        check(
            "saved from the JSON view: what is good applies, the rest is listed",
            settings.confirmClose == .whenRunning && settings.newTabDirectory == .current
                && settings.problems.contains { $0.contains("general.nonsense") }, "\(settings.problems)")

        // Ask before closing: only when something runs — an idle tab just closes.
        guard let idle = app.store.selected else { return check("a tab to close", false) }
        await settledPrompt()
        let count = app.store.tabs.count
        app.closeTab(idle)
        check(
            "an idle tab closes without asking", await eventually(2) { self.app.store.tabs.count == count - 1 } && window.attachedSheet == nil)
        // Ghostty's own close_tab binding, from inside the terminal it closes,
        // with nothing to ask: must not free the surface mid-callback.
        app.newTab(nil)
        await settledPrompt()
        if let bound = app.store.selected {
            let before = app.store.tabs.count
            bound.terminal.perform(binding: "close_tab")
            check(
                "Ghostty's close_tab closes an idle tab, and the app lives",
                await eventually(3) { self.app.store.tabs.count == before - 1 && !self.app.store.tabs.contains { $0.id == bound.id } })
        }
        settings.set("general.confirmClose", nil)
        if let another = app.store.selected {
            app.closeTab(another)
            check("Always asks again", await eventually(2) { self.window.attachedSheet != nil })
            clickSheetButton("Cancel")
        }

        // Agents ▸ New Task's worktrees inside the repository, locally ignored.
        let repo = scratch.appendingPathComponent("taskrepo")
        try? FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try? await git(["init", "-q", "-b", "main"], in: repo)
        try? await git(["commit", "-q", "--allow-empty", "-m", "i"], in: repo)
        settings.set("agents.worktreeLocation", .string("inside"))
        do {
            try await app.createTask(repo: repo, branch: "feat/inside", base: "main", agent: nil)
        } catch {
            check("New Task creates it", false, error.localizedDescription)
        }
        let inside = repo.appendingPathComponent(".worktrees/feat-inside").standardizedFileURL.path
        check("New Task's worktree goes inside the repository", app.store.selected?.workingDirectory == inside, app.store.selected?.workingDirectory ?? "nil")
        let status = (try? await Git.run(["status", "--porcelain"], in: repo)) ?? "?"
        check("and the main checkout stays clean", status.isEmpty, status)
        settings.set("agents.worktreeLocation", nil)

        // Keyboard Shortcuts: a menu command moves to a new key; Ghostty lets go of both.
        let diagnosticsBefore = GhosttyRuntime.shared.configDiagnostics
        guard let newTab = KeyCommands.byID["tabs.new"], let splitRight = KeyCommands.byID["splits.right"],
            let clear = KeyCommands.byID["terminal.clear"]
        else { return check("the commands", false) }
        check("a menu item starts with its command's key", menuItem("tabs.new")?.keyEquivalent.lowercased() == "t")
        keys.set(newTab, to: KeyCombo("cmd+y"))
        check(
            "a new key goes on the menu item", menuItem("tabs.new")?.keyEquivalent.lowercased() == "y",
            menuItem("tabs.new")?.keyEquivalent ?? "nil")
        let bindings = (try? String(contentsOf: keys.url, encoding: .utf8)) ?? ""
        check("keybindings.json holds it", bindings.contains("{ \"key\": \"cmd+y\", \"command\": \"tabs.new\" }"), bindings)
        check(
            "Ghostty lets go of the old key and the new one",
            await eventually(3) { overrides().contains("keybind = super+t=unbind") && overrides().contains("keybind = super+y=unbind") },
            overrides())
        // A terminal-only command is bound in Ghostty itself.
        keys.set(clear, to: KeyCombo("ctrl+alt+l"))
        check(
            "a terminal command's new key is Ghostty's",
            await eventually(3) {
                GhosttyRuntime.shared.trigger(for: "clear_screen").flatMap(KeyCombo.init(trigger:)) == KeyCombo("ctrl+alt+l")
            }, overrides())
        // Removed: no key at all.
        keys.set(splitRight, to: nil)
        check("a removed shortcut leaves the menu item without one", menuItem("splits.right")?.keyEquivalent == "")
        check(
            "and Ghostty's binding goes too",
            await eventually(3) { GhosttyRuntime.shared.trigger(for: "new_split:right").flatMap(KeyCombo.init(trigger:)) == nil })
        check(
            "Ghostty takes the lines without complaint", GhosttyRuntime.shared.configDiagnostics == diagnosticsBefore,
            GhosttyRuntime.shared.configDiagnostics.joined(separator: " | "))
        if let png = ProcessInfo.processInfo.environment["TERMINUS_DUMP_PNG"] {
            app.openSettings(.shortcuts)
            await pause(0.8)
            app.captureWindow(to: png.replacingOccurrences(of: ".png", with: "-shortcuts.png"))
        }
        // The JSON view shows the section's file, as saved.
        app.openSettings(.general)
        app.settingsPage.mode = .json
        check(
            "JSON shows settings.json itself", await eventually(2) { self.app.settingsPage.draft == fileText() },
            app.settingsPage.draft ?? "nil")
        app.settingsPage.show(.shortcuts)
        app.settingsPage.mode = .json
        check(
            "and Keyboard Shortcuts' JSON is keybindings.json",
            await eventually(2) { self.app.settingsPage.draft?.contains("\"command\": \"tabs.new\"") == true })
        if let png = ProcessInfo.processInfo.environment["TERMINUS_DUMP_PNG"] {
            await pause(0.6)
            app.captureWindow(to: png.replacingOccurrences(of: ".png", with: "-json.png"))
        }
        app.settingsPage.show(.general)
        keys.resetAll()
        check(
            "Reset All puts the defaults back",
            await eventually(3) {
                self.menuItem("tabs.new")?.keyEquivalent.lowercased() == "t"
                    && self.menuItem("splits.right")?.keyEquivalent.lowercased() == "d"
                    // Only the unbinds the defaults themselves need are
                    // left: nothing anyone chose.
                    && !overrides().contains("=new_tab") && !overrides().contains("=new_split")
            }, overrides())

        // Clicking the terminal tab uncovers it; ⌘W on the Settings tab closes only that.
        app.openSettings()
        let tabs = app.store.tabs.count
        app.closeSelectedTab(nil)
        check(
            "⌘W closes the Settings tab, not a terminal one",
            !app.store.settingsOpen && app.settingsView?.isHidden == true && app.store.tabs.count == tabs && window.attachedSheet == nil)
        settings.save(text: "{\n}\n")
    }

    private func menuItem(_ id: String) -> NSMenuItem? {
        func find(_ menu: NSMenu?) -> NSMenuItem? {
            for item in menu?.items ?? [] {
                if item.identifier?.rawValue == id { return item }
                if let found = find(item.submenu) { return found }
            }
            return nil
        }
        return find(NSApp.mainMenu)
    }

    /// Settings ▸ About: a newer release (a stand-in gh answering for
    /// GitHub) shows as available — a chip in the title bar too — and
    /// downloads; none published yet is "up to date"; this version's
    /// changelog entry is in the app.
    private func updatesScenario() async {
        let log = scratch.appendingPathComponent("gh-updates.log")
        let mode = scratch.appendingPathComponent("gh-mode")
        let gh = scratch.appendingPathComponent("gh")
        try? #"""
        #!/usr/bin/python3
        import json, os, sys
        args = sys.argv[1:]
        open("\#(log.path)", "a").write(" ".join(args) + "\n")
        mode = open("\#(mode.path)").read().strip() if os.path.exists("\#(mode.path)") else "newer"
        if args[:1] == ["api"] and args[1].endswith("/releases/latest"):
            if mode == "none":
                sys.stderr.write("gh: Not Found (HTTP 404)\n"); sys.exit(1)
            print(json.dumps({"tag_name": "v99.0.0", "html_url": "https://example.invalid/v99.0.0",
                              "assets": [{"name": "Overterm-99.0.0.dmg"}]}))
        elif args[:2] == ["release", "download"]:
            folder = args[args.index("-D") + 1]
            open(os.path.join(folder, "Overterm-99.0.0.dmg"), "w").write("dmg")
        else:
            sys.stderr.write("fake gh: unexpected %s\n" % args); sys.exit(2)
        """#.write(to: gh, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: gh.path)
        GitHub.executableOverride = gh
        defer { GitHub.executableOverride = nil }
        let updates = UpdateChecker.shared

        await updates.check()
        check("a newer release shows as available", updates.available?.version == "99.0.0", "\(updates.state)")
        let asked = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        check("asked for the release repository's latest", asked.contains("api repos/\(UpdateChecker.repository)/releases/latest"), asked)

        (NSApp.delegate as? AppDelegate)?.checkForUpdates(nil)
        check(
            "Check for Updates opens the Settings tab on About",
            await eventually(3) { self.app.settingsPage.section == .about && self.app.store.settingsShowing })
        await eventually(3) { updates.available != nil }
        if let png = ProcessInfo.processInfo.environment["TERMINUS_DUMP_PNG"] {
            await pause(0.8)
            app.captureWindow(to: png)
        }

        if let release = updates.available {
            let downloads = scratch.appendingPathComponent("Downloads")
            try? FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
            await updates.download(release, into: downloads)
            check(
                "Download fetches its DMG",
                updates.state == .downloaded(downloads.appendingPathComponent("Overterm-99.0.0.dmg"))
                    && FileManager.default.fileExists(atPath: downloads.appendingPathComponent("Overterm-99.0.0.dmg").path), "\(updates.state)")
        }

        try? "none".write(to: mode, atomically: true, encoding: .utf8)
        await updates.check()
        check("no release yet reads as up to date", updates.state == .upToDate, "\(updates.state)")

        let entry = Changelog.bundled.map { Changelog.entry(for: updates.currentVersion, in: $0) } ?? []
        check("the app carries this version's changelog entry", !entry.isEmpty, "\(updates.currentVersion): \(entry)")
        (NSApp.delegate as? AppDelegate)?.showChangelog(nil)
        check("View Latest Changelog opens it", await eventually(2) { ChangelogWindowController.shared.window?.isVisible == true })
        ChangelogWindowController.shared.window?.close()
        app.closeSettings()
    }

    /// How heavy Overterm is to live in: idle with ten tabs (two split),
    /// then a flood of output. Measures this process's CPU time, its memory
    /// footprint, and the longest the main thread went without running a
    /// 50 ms timer — what you'd feel as a hitch.
    private func performanceScenario() async {
        await settledPrompt()
        for i in 0..<9 {
            app.newTab(nil)
            if i == 3 || i == 6 { app.splitRight(nil) }
        }
        await settledPrompt()
        await pause(3)  // shells started, first prompts drawn, polls warmed up

        let stalls = StallMeter()
        let cpu0 = Self.cpuSeconds()
        let wall0 = Date()
        await pause(20)
        let idleCPU = (Self.cpuSeconds() - cpu0) / Date().timeIntervalSince(wall0) * 100
        let idleStall = stalls.worst
        let footprint = Self.footprintMB()
        note(
            String(
                format: "idle, %d tabs / %d panes: CPU %.2f%%, footprint %.0f MB, worst main-thread stall %.0f ms",
                app.store.tabs.count, app.store.tabs.map(\.terminals.count).reduce(0, +), idleCPU, footprint, idleStall * 1000))
        check("idle with ten tabs costs little CPU (< 3%)", idleCPU < 3, String(format: "%.2f%%", idleCPU))
        check("and never stalls the main thread (< 150 ms)", idleStall < 0.15, String(format: "%.0f ms", idleStall * 1000))
        check("in a sane amount of memory (< 900 MB)", footprint < 900, String(format: "%.0f MB", footprint))

        // Five agents at work (as OSC 9;4 marks them): their tabs animate.
        let working = app.store.tabs.suffix(5)
        for tab in working { tab.activity.handle(.progress(active: true, failed: false), visible: false) }
        await pause(1)
        let busy0 = Self.cpuSeconds()
        let busyWall0 = Date()
        await pause(10)
        let busyCPU = (Self.cpuSeconds() - busy0) / Date().timeIntervalSince(busyWall0) * 100
        note(String(format: "five working tabs: CPU %.2f%%", busyCPU))
        check("five working agents' tabs cost little CPU (< 5%)", busyCPU < 5, String(format: "%.2f%%", busyCPU))
        for tab in working { tab.activity.handle(.progress(active: false, failed: false), visible: true) }

        // A tab in ~ watches everything under it, and ~/Library never stops
        // changing: events for folders nobody opened must cost nearly nothing.
        let churnRoot = scratch.appendingPathComponent("churn")
        let folders = (0..<200).map { churnRoot.appendingPathComponent("d\($0)") }
        for folder in folders { try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        app.newTab(in: churnRoot)
        await eventually(5) { self.app.tree.root?.lastPathComponent == "churn" }
        await pause(1)
        // Written from another process, so this one's CPU is the watching alone.
        let churning = Process()
        churning.executableURL = URL(fileURLWithPath: "/bin/sh")
        churning.arguments = ["-c", "i=0; while :; do echo x > d$((i % 200))/f$((i % 7)); i=$((i + 1)); done"]
        churning.currentDirectoryURL = churnRoot
        try? churning.run()
        let churn0 = Self.cpuSeconds()
        let churnWall0 = Date()
        await pause(8)
        let churnCPU = (Self.cpuSeconds() - churn0) / Date().timeIntervalSince(churnWall0) * 100
        churning.terminate()
        note(String(format: "a watched folder churning: CPU %.2f%%", churnCPU))
        check("changes in folders never opened cost little (< 10%)", churnCPU < 10, String(format: "%.2f%%", churnCPU))

        // A build writing steadily into an ignored folder of a repo: the
        // badge must still move for a real edit, and refreshes must not
        // stack up (the app's CPU and its git processes').
        let buildRepo = scratch.appendingPathComponent("building")
        try? FileManager.default.createDirectory(at: buildRepo.appendingPathComponent("out"), withIntermediateDirectories: true)
        try? await git(["init", "-q", "-b", "main"], in: buildRepo)
        try? "out/\n".write(to: buildRepo.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        try? "one\n".write(to: buildRepo.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)
        try? await git(["add", "."], in: buildRepo)
        try? await git(["commit", "-q", "-m", "init"], in: buildRepo)
        app.newTab(in: buildRepo)
        await eventually(5) { self.app.diff.root?.lastPathComponent == "building" }
        await pause(1)
        let build = Process()
        build.executableURL = URL(fileURLWithPath: "/bin/sh")
        build.arguments = ["-c", "i=0; while :; do echo x > out/o$((i % 50)); i=$((i + 1)); sleep 0.01; done"]
        build.currentDirectoryURL = buildRepo
        try? build.run()
        let build0 = Self.cpuSeconds(children: true)
        let buildWall0 = Date()
        await pause(3)
        try? "one\ntwo\n".write(to: buildRepo.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)
        let seen = await eventually(4) { self.app.diff.totals.added == 1 }
        await pause(3)
        let buildCPU = (Self.cpuSeconds(children: true) - build0) / Date().timeIntervalSince(buildWall0) * 100
        build.terminate()
        note(String(format: "a build writing into an ignored folder: CPU %.2f%% (with git's)", buildCPU))
        check("an edit reaches the badge while a build writes (< 4 s)", seen, "\(app.diff.totals)")
        check("and refreshing costs little meanwhile (< 25%)", buildCPU < 25, String(format: "%.2f%%", buildCPU))
        try? FileManager.default.removeItem(at: buildRepo)

        // An agent leaves a thousand new files: counting their lines for
        // the ± badge must not hold up the window.
        let busyRepo = scratch.appendingPathComponent("many-files")
        try? FileManager.default.createDirectory(at: busyRepo, withIntermediateDirectories: true)
        try? await git(["init", "-q", "-b", "main"], in: busyRepo)
        let body = Data(String(repeating: "a line of generated output\n", count: 3000).utf8)  // ~80 KB
        await Task.detached { for i in 0..<1000 { try? body.write(to: busyRepo.appendingPathComponent("gen-\(i).txt")) } }.value
        await pause(0.3)  // let the meter tick past the setup before measuring
        stalls.reset()
        app.newTab(in: busyRepo)
        let countedAll = await eventually(30) { self.app.diff.files.count == 1000 && self.app.diff.totals.added == 3_000_000 }
        note(String(format: "1000 untracked files counted: worst main-thread stall %.0f ms", stalls.worst * 1000))
        check("a thousand new files are counted", countedAll, "\(app.diff.files.count) files, \(app.diff.totals)")
        // Counting on the main thread stalled 2 s, on every refresh. What
        // remains (~0.2-0.4 s, once) is showing a 1000-entry folder: the
        // file tree's sort and SwiftUI laying out its rows.
        check("without stalling the main thread for long (< 600 ms)", stalls.worst < 0.6, String(format: "%.0f ms", stalls.worst * 1000))
        try? FileManager.default.removeItem(at: busyRepo)


        stalls.reset()
        let started = Date()
        await runAndExpect("seq 1 300000; echo done > \(out("flood").path)", file: out("flood"), content: "done", "300 000 lines of output")
        let flood = Date().timeIntervalSince(started)
        let floodStall = stalls.worst
        note(String(format: "flood: 300 000 lines in %.1f s, worst main-thread stall %.0f ms", flood, floodStall * 1000))
        check("the window stays responsive while output floods (< 250 ms)", floodStall < 0.25, String(format: "%.0f ms", floodStall * 1000))
        stalls.stop()
    }

    /// Big files in the editor: opening one, then typing in it (each pause
    /// re-highlights) — just under the highlighting cap, and far over it.
    private func bigFilesScenario() async {
        await settledPrompt()
        let stalls = StallMeter()
        let codeLine = "    let value = compute(\"a string\", 42) // a comment here\n"
        for size in [290_000, 4_000_000] {
            let bigSource = scratch.appendingPathComponent("big-\(size).swift")
            try? String(repeating: codeLine, count: size / codeLine.utf8.count).write(to: bigSource, atomically: true, encoding: .utf8)
            await pause(0.3)
            stalls.reset()
            app.openInEditor(bigSource)
            await eventually(10) { self.app.editor?.document.url == bigSource }
            await pause(1)
            let openStall = stalls.worst
            if let textView = Self.find(NSTextView.self, in: app.editor?.view, where: { _ in true }),
                let clip = textView.enclosingScrollView?.contentView
            {
                // The gutter floats over the clip view: the first character
                // (after the inset and padding) must start right of it.
                let firstCharacter =
                    textView.textContainerInset.width + (textView.textContainer?.lineFragmentPadding ?? 0) - clip.bounds.minX
                check(
                    "the gutter covers none of the \(size / 1000) KB file's text", firstCharacter >= clip.contentInsets.left,
                    "first character at \(firstCharacter), gutter \(clip.contentInsets.left)")
            }
            if let png = ProcessInfo.processInfo.environment["TERMINUS_DUMP_PNG"] {
                app.captureWindow(to: png.replacingOccurrences(of: ".png", with: "-\(size / 1000)k.png"))
            }
            stalls.reset()
            if let editor = app.editor, let textView = Self.find(NSTextView.self, in: editor.view, where: { _ in true }) {
                let expected = (try? String(contentsOf: bigSource, encoding: .utf8))?.utf16.count ?? -1
                check("the \(size / 1000) KB file is all in the editor", textView.string.utf16.count == expected, "\(textView.string.utf16.count) of \(expected)")
                textView.setSelectedRange(NSRange(location: 100, length: 0))
                for _ in 0..<5 {
                    textView.insertText("x", replacementRange: textView.selectedRange())
                    await pause(0.3)  // past the highlight debounce
                }
                check("and the typing landed", textView.string.utf16.count == expected + 5)
                textView.undoManager?.removeAllActions()
            }
            let typeStall = stalls.worst
            note(
                String(
                    format: "editor, %d KB: open stall %.0f ms, typing stall %.0f ms", size / 1000, openStall * 1000, typeStall * 1000))
            check("typing in a \(size / 1000) KB file stays responsive (< 100 ms)", typeStall < 0.1, String(format: "%.0f ms", typeStall * 1000))
            app.editor?.document.close()
        }


        // An agent rewrites a big file: its 3000-line diff (the cap) opens in
        // the changes pane.
        let bigRepo = scratch.appendingPathComponent("big-diff")
        try? FileManager.default.createDirectory(at: bigRepo, withIntermediateDirectories: true)
        try? await git(["init", "-q", "-b", "main"], in: bigRepo)
        let bigFile = bigRepo.appendingPathComponent("big.swift")
        try? (0..<3000).map { "let value\($0) = \($0)" }.joined(separator: "\n").write(to: bigFile, atomically: true, encoding: .utf8)
        try? await git(["add", "."], in: bigRepo)
        try? await git(["commit", "-q", "-m", "init"], in: bigRepo)
        try? (0..<3000).map { "let value\($0) = \($0 * 2)" }.joined(separator: "\n").write(to: bigFile, atomically: true, encoding: .utf8)
        app.newTab(in: bigRepo)
        await eventually(10) { self.app.diff.files.count == 1 }
        await pause(0.3)
        stalls.reset()
        if app.diffItem?.isCollapsed == true { app.toggleDiff(nil) }
        let shown = await eventually(15) { self.app.diff.diffs["big.swift"]?.truncated == true }
        await pause(1)  // drawn
        note(String(format: "3000-line diff opened: worst main-thread stall %.0f ms", stalls.worst * 1000))
        check("a diff at the line cap loads", shown, "\(app.diff.diffs["big.swift"]?.lines.count ?? 0) lines")
        check("and opens without freezing the window (< 500 ms)", stalls.worst < 0.5, String(format: "%.0f ms", stalls.worst * 1000))
        stalls.reset()
        if app.diffItem?.isCollapsed == false { app.toggleDiff(nil) }
        await pause(1)
        note(String(format: "closing the pane on it: worst main-thread stall %.0f ms", stalls.worst * 1000))
        check("and closes without freezing the window (< 250 ms)", stalls.worst < 0.25, String(format: "%.0f ms", stalls.worst * 1000))
        check("closed, the pane renders nothing", app.diff.panelVisible == false)
        // Opened by dragging its divider (not ⌥⌘D): its content comes back.
        app.diffItem?.isCollapsed = false
        check("dragged open, it has its content again", await eventually(3) { self.app.diff.panelVisible })
        app.toggleDiff(nil)
        try? FileManager.default.removeItem(at: bigRepo)
        stalls.stop()
    }

    /// This process's user + system CPU time, in seconds.
    /// `children`: plus the processes it ran that have ended (git).
    private static func cpuSeconds(children: Bool = false) -> Double {
        func seconds(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1_000_000 }
        var total = 0.0
        for who in children ? [RUSAGE_SELF, RUSAGE_CHILDREN] : [RUSAGE_SELF] {
            var usage = rusage()
            getrusage(who, &usage)
            total += seconds(usage.ru_utime) + seconds(usage.ru_stime)
        }
        return total
    }

    /// Memory as Activity Monitor's "Memory" column counts it.
    private static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }

    /// ⌘P shows, searches across kinds, and hides.
    private func paletteScenario() async {
        // ⌘K is Ghostty's clear_screen; the palette only ever opens on it
        // if Overterm writes the unbind.
        check(
            "⌘K is handed to the menu, not kept by Ghostty",
            Keybindings.shared.ghosttyLines.contains("keybind = super+k=unbind"),
            Keybindings.shared.ghosttyLines.filter { $0.contains("+k=") }.joined(separator: " / "))

        app.showPalette(nil)
        check("⌘K shows the palette", app.paletteView?.isHidden == false)
        check("it lists actions and tabs", app.palette.results.contains { $0.group == .action } && app.palette.results.contains { $0.group == .tab })
        app.palette.query = "ncl"
        check("fuzzy search finds New Claude Tab", app.palette.results.first?.title == "New Claude Tab")
        app.palette.query = "validate"
        check("snippets are searchable", app.palette.results.first?.group == .snippet)
        app.palette.query = "changes"
        check("the changes pane is Changes", app.palette.results.first?.title == "Changes", app.palette.results.first?.title ?? "nil")
        // History: what this pane has run, nearest folder first.
        app.palette.query = ""
        app.history.record(
            CommandBlock(id: 0, command: "pnpm --filter api build", startRow: 0, endRow: 9, exit: 2, seconds: 8),
            folder: "/src/app")
        app.history.record(
            CommandBlock(id: 1, command: "pnpm --filter web build", startRow: 0, endRow: 9, exit: 0, seconds: 3),
            folder: "/elsewhere")
        app.palette.query = "pnpm"
        // Not an exact count: Overterm's panes are real login shells, so
        // what the scenarios type lands in the user's own history file,
        // which is also seeded from.
        let history = app.palette.results.filter { $0.group == .history }
        check(
            "history is searchable",
            history.contains { $0.title.contains("--filter api") } && history.contains { $0.title.contains("--filter web") },
            "\(history.prefix(4).map(\.title))")
        check("a failed one is marked as failed", history.first { $0.title.contains("--filter api") }?.failed == true)
        check(
            "and the detail says when and how",
            history.first { $0.title.contains("--filter api") }?.detail?.contains("Last run") == true,
            history.first { $0.title.contains("--filter api") }?.detail ?? "none")

        // Scopes narrow what is searched.
        app.palette.scope = .history
        check("the History scope shows only history", app.palette.results.allSatisfy { $0.group == .history })
        app.palette.scope = .action
        check("the Actions scope shows only actions", app.palette.results.allSatisfy { $0.group == .action })
        app.palette.scope = nil

        // A snippet with a placeholder is not ready until it is filled.
        app.palette.query = "deploy"
        if let snippet = app.palette.results.first(where: { $0.group == .snippet && !$0.placeholders.isEmpty }) {
            app.palette.selectedIndex = app.palette.results.firstIndex { $0.id == snippet.id } ?? 0
            check("a snippet's fields are offered", !snippet.placeholders.isEmpty, "\(snippet.placeholders)")
            check("and it is not ready while they are empty", !app.palette.isReady)
            for name in snippet.placeholders { app.palette.values[name] = "api" }
            check("ready once they are filled", app.palette.isReady)
        } else {
            check("a snippet with placeholders is offered", false, "\(app.palette.results.map(\.title))")
        }

        app.showPalette(nil)
        check("⌘K again hides it", app.paletteView?.isHidden == true)
    }

    /// A program reading the clipboard (OSC 52) and a paste that could run
    /// commands ask first, in a sheet, and either answer ends the request —
    /// answering "not confirmed" made libghostty ask again until the app
    /// crashed. The run's clipboard is its own, never the user's.
    private func clipboardScenario() async {
        guard let clipboard = GhosttyRuntime.pasteboard(GHOSTTY_CLIPBOARD_STANDARD), clipboard != .general else {
            return check("an isolated run has its own clipboard", false)
        }
        let reader = scratch.appendingPathComponent("osc52.py")
        try? Self.osc52Reader.write(to: reader, atomically: true, encoding: .utf8)
        func contents(_ file: URL) -> String? { (try? Data(contentsOf: file)).map { String(decoding: $0, as: UTF8.self) } }

        clipboard.clearContents()
        clipboard.setString("e2e-clipboard-secret", forType: .string)
        for (button, file, encoded) in [("Deny", out("denied"), ""), ("Allow", out("allowed"), "ZTJlLWNsaXBib2FyZC1zZWNyZXQ=")] {
            let asked = await run("python3 \(reader.path) \(file.path)") { self.window.attachedSheet != nil }
            check("\(button): a program reading the clipboard asks first", asked, String(terminal?.visibleText?.suffix(400) ?? "no text"))
            check("\(button): the sheet shows what it would get", sheetPreview == "e2e-clipboard-secret", sheetPreview ?? "no preview")
            check("\(button): only a click allows it, no key does", await onlyAClickPresses("Allow"), "\(sheetButtons)")
            if button == "Allow", let png = ProcessInfo.processInfo.environment["TERMINUS_DUMP_PNG"], let sheet = window.attachedSheet {
                await pause(0.8)
                app.captureWindow(to: png, window: sheet)
            }
            check("\(button): answered", clickSheetButton(button))
            await eventually { contents(file) != nil }
            check(
                "\(button): the program gets \(encoded.isEmpty ? "an empty reply" : "the clipboard")", contents(file) == "\u{1b}]52;c;\(encoded)\u{1b}\\",
                contents(file)?.debugDescription ?? "no reply")
        }

        // While a sheet is up, another request is refused at once — not
        // queued behind it, not pasted into the waiting program.
        clipboard.clearContents()
        clipboard.setString("one\ntwo", forType: .string)
        let third = out("third")
        check("a read asks again", await run("python3 \(reader.path) \(third.path)") { self.window.attachedSheet != nil })
        terminal?.paste(nil)
        await pause(0.5)
        check("Deny answers it", clickSheetButton("Deny"))
        await eventually { contents(third) != nil }
        check("the program got only the empty reply", contents(third) == "\u{1b}]52;c;\u{1b}\\", contents(third)?.debugDescription ?? "no reply")
        await pause(1)
        check("the paste meanwhile was refused, not queued", window.attachedSheet == nil)

        // A paste with line breaks into a program without bracketed paste
        // (cat): Cancel pastes nothing, Paste hands it over.
        clipboard.clearContents()
        clipboard.setString("first line\nsecond line\n", forType: .string)
        let pasted = out("pasted")
        check("cat reads the terminal", await run("cat > \(pasted.path)") { self.terminal?.needsConfirmClose == true })
        terminal?.paste(nil)
        check("a paste that could run commands asks first", await eventually(5) { self.window.attachedSheet != nil })
        check("the sheet shows the paste", sheetPreview == "first line\nsecond line\n", sheetPreview?.debugDescription ?? "no preview")
        check("only a click pastes it, no key does", await onlyAClickPresses("Paste"), "\(sheetButtons)")
        if let png = ProcessInfo.processInfo.environment["TERMINUS_DUMP_PNG"], let sheet = window.attachedSheet {
            await pause(0.8)
            app.captureWindow(to: (png as NSString).deletingPathExtension + "-paste.png", window: sheet)
        }
        check("Cancel answers", clickSheetButton("Cancel"))
        await pause(0.5)
        check("Cancel pastes nothing", contents(pasted) == "", contents(pasted)?.debugDescription ?? "missing")
        terminal?.paste(nil)
        check("asked again", await eventually(5) { self.window.attachedSheet != nil })
        check("Paste answers", clickSheetButton("Paste"))
        check("the terminal has the keyboard back", await eventually(3) { self.window.firstResponder === self.terminal })
        await pause(0.3)
        key(kVK_ANSI_D, "\u{4}", modifiers: .control, ignoringModifiers: "d")
        check(
            "Paste hands it over", await eventually { contents(pasted) == "first line\nsecond line\n" },
            contents(pasted)?.debugDescription ?? "missing")

        // A program in a tab you aren't looking at is refused without a sheet.
        let background = out("background")
        check(
            "a reader waits in this tab",
            await run("sleep 2; python3 \(reader.path) \(background.path)") { self.terminal?.needsConfirmClose == true })
        app.newTab(nil)
        await eventually(15) { contents(background) != nil }
        check(
            "a background tab's read is refused without asking", window.attachedSheet == nil && contents(background) == "\u{1b}]52;c;\u{1b}\\",
            "sheet: \(window.attachedSheet != nil), reply: \(contents(background)?.debugDescription ?? "none")")
    }

    /// The attached sheet's preview: the text view in its accessory.
    private var sheetPreview: String? {
        Self.find(NSTextView.self, in: window.attachedSheet?.contentView, where: { _ in true })?.string
    }

    /// The attached sheet's buttons, each with the key that presses it ("" for none).
    private var sheetButtons: [(title: String, key: String)] {
        var found: [(title: String, key: String)] = []
        func walk(_ view: NSView) {
            if let button = view as? NSButton { found.append((button.title, button.keyEquivalent)) }
            view.subviews.forEach(walk)
        }
        window.attachedSheet?.contentView.map(walk)
        return found
    }

    /// Only a click presses the sheet's `title` button: it has no key, now
    /// or after AppKit has had a moment to hand keys out. Whether Return
    /// then refuses is AppKit's to decide — it drops the keys when the app
    /// isn't frontmost — and either way nothing is handed over.
    private func onlyAClickPresses(_ title: String) async -> Bool {
        await pause(0.5)
        return sheetButtons.contains { $0.title == title && $0.key.isEmpty }
    }

    /// Asks the terminal for the clipboard (OSC 52), as a remote editor
    /// does, and writes the reply as it came to argv[1].
    private static let osc52Reader = #"""
        import os, select, sys, termios, time, tty
        fd = os.open("/dev/tty", os.O_RDWR)
        saved = termios.tcgetattr(fd)
        tty.setraw(fd)
        reply = b""
        try:
            os.write(fd, b"\x1b]52;c;?\x07")
            deadline = time.time() + 30
            while time.time() < deadline and not reply.endswith((b"\x1b\\", b"\x07")):
                if select.select([fd], [], [], 0.2)[0]:
                    reply += os.read(fd, 4096)
        finally:
            termios.tcsetattr(fd, termios.TCSADRAIN, saved)
        open(sys.argv[1], "wb").write(reply)
        """#

    /// Opening a file outside Overterm (the file tree's double-click, the
    /// editor's ↗): the first time a sheet asks which app, the answer is
    /// remembered and later opens go straight there; Open With switches it;
    /// an app that is gone is asked about again. Nothing is launched — an
    /// isolated run's apps are stand-ins that only record.
    private func openWithScenario() async {
        guard let apps = app.opener.apps as? IsolatedApps else { return check("an isolated run has stand-in apps", false) }
        let alpha = ExternalApp(bundleID: "e2e.terminus.alpha", name: "Alpha", url: scratch.appendingPathComponent("Alpha.app"))
        let beta = ExternalApp(bundleID: "e2e.terminus.beta", name: "Beta", url: scratch.appendingPathComponent("Beta.app"))
        apps.installed = [alpha, beta]
        apps.defaultBundleID = beta.bundleID
        let file = out("notes.md")
        try? "# notes\n".write(to: file, atomically: true, encoding: .utf8)
        func remembered() -> String? { AppEnvironment.defaults.string(forKey: OpenWith.rememberedKey) }
        func opened(_ count: Int, with app: ExternalApp) async -> Bool {
            await eventually(3) { apps.opened.count == count } && apps.opened.last == .init(file: file, bundleID: app.bundleID)
        }

        // Nothing picked yet: the file tree's double-click asks.
        app.openExternally(file)
        check("with nothing remembered, opening a file asks which app", await eventually(3) { self.window.attachedSheet != nil })
        check("the sheet asks it", sheetTexts().contains(OpenWith.question), sheetTexts().joined(separator: " | "))
        let popup = Self.find(NSPopUpButton.self, in: window.attachedSheet?.contentView) { _ in true }
        check(
            "it offers the apps with their icons, the system's default marked, then Other…",
            popup?.itemTitles == ["Beta (default)", "Alpha", "", "Other…"] && popup?.itemArray.first?.image != nil,
            "\(popup?.itemTitles ?? [])")
        if let png = ProcessInfo.processInfo.environment["TERMINUS_DUMP_PNG"], let sheet = window.attachedSheet {
            await pause(0.8)
            app.captureWindow(to: png, window: sheet)
        }
        popup?.selectItem(withTitle: "Alpha")
        check("Open answers", clickSheetButton("Open"))
        check("the file opens in the chosen app", await opened(1, with: alpha), "\(apps.opened)")
        check("and the choice is remembered", remembered() == alpha.bundleID, remembered() ?? "nil")

        app.openExternally(file)
        check("opening again goes straight there, without asking", await opened(2, with: alpha) && window.attachedSheet == nil, "\(apps.opened)")

        // The editor's ↗ names the app; its right-click is Open With.
        app.openInEditor(file)
        await eventually(2) { self.app.editor?.document.url == file }
        guard let editor = app.editor, let reveal = Self.find(NSButton.self, in: editor.view, where: { $0.identifier?.rawValue == "openExternally" })
        else { return check("the editor header has ↗", false) }
        check("↗ says where it opens", reveal.toolTip == "Open in Alpha", reveal.toolTip ?? "nil")
        let rightClick = NSEvent.mouseEvent(
            with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        let menu = rightClick.flatMap { reveal.menu(for: $0) }
        check(
            "its Open With menu: the apps, the one in use ticked, then Other…",
            menu?.items.map(\.title) == ["Beta (default)", "Alpha", "", "Other…"] && menu?.items[1].state == .on && menu?.items[0].state == .off,
            "\(menu?.items.map { "\($0.title) \($0.state.rawValue)" } ?? [])")
        menu?.items.first { $0.title == "Beta (default)" }.map { item in _ = (item.target as? NSObject)?.perform(item.action, with: item) }
        check("choosing another app from Open With opens it there", await opened(3, with: beta), "\(apps.opened)")
        check(
            "and switches to it", remembered() == beta.bundleID && reveal.toolTip == "Open in Beta",
            "\(remembered() ?? "nil"), \(reveal.toolTip ?? "nil")")
        reveal.performClick(nil)
        check("↗ then goes to the new one, without asking", await opened(4, with: beta) && window.attachedSheet == nil, "\(apps.opened)")

        // The remembered app was uninstalled: ask again, never fall back.
        apps.installed = [alpha]
        reveal.performClick(nil)
        check("an app that is gone is asked about again", await eventually(3) { self.window.attachedSheet != nil })
        check("↗ no longer names it", reveal.toolTip == "Open With…", reveal.toolTip ?? "nil")
        check("Cancel answers", clickSheetButton("Cancel"))
        await pause(0.3)
        check("and opens nothing", apps.opened.count == 4 && window.attachedSheet == nil, "\(apps.opened)")
        check("no real app was launched", SystemApps.launched == 0)
    }

    // MARK: Dropping onto a terminal

    /// A 1×1 PNG: an image Claude Code would read.
    private static let tinyPNG = Data(
        base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==")!

    /// A drag of `objects` over a private pasteboard (never the system's
    /// drag pasteboard or clipboard).
    private func drag(_ objects: [NSPasteboardWriting]) -> E2EDraggingInfo {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("terminus-e2e-drag-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.writeObjects(objects)
        return E2EDraggingInfo(pasteboard: pasteboard, window: window)
    }

    /// Drops as AppKit calls a destination: entered, updated, prepare,
    /// perform, conclude, ended.
    @discardableResult
    private func drop(_ info: E2EDraggingInfo, on pane: TerminalView) -> Bool {
        guard pane.draggingEntered(info) != [], pane.draggingUpdated(info) != [], pane.prepareForDragOperation(info) else { return false }
        let performed = pane.performDragOperation(info)
        pane.concludeDragOperation(info)
        pane.draggingEnded(info)
        return performed
    }

    /// What the pane finds running in it, as a drop looks.
    private func program(of pane: TerminalView) async -> TerminalDrop.Program {
        await withCheckedContinuation { continuation in pane.lookAtProgram { continuation.resume(returning: $0) } }
    }

    private func controlD() {
        key(kVK_ANSI_D, "\u{4}", modifiers: .control, ignoringModifiers: "d")
    }

    /// Dragging files onto a terminal types in references to them, with a
    /// trailing space and no Return: shell-quoted paths in a shell;
    /// @-mentions and image paths where Claude Code runs (a stand-in, found
    /// as a real one is: by its process, per pane); plain paths with ⌥.
    /// Each drop goes through the pane's own NSDraggingDestination methods
    /// with a private pasteboard: nothing touches the system's drag.
    private func dropFilesScenario() async {
        let dir = scratch.appendingPathComponent("drops")
        let folder = dir.appendingPathComponent("folder")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let plain = dir.appendingPathComponent("plain.txt")
        let spaced = dir.appendingPathComponent("with space.md")
        let image = dir.appendingPathComponent("shot.png")
        try? "plain\n".write(to: plain, atomically: true, encoding: .utf8)
        try? "# spaced\n".write(to: spaced, atomically: true, encoding: .utf8)
        try? Self.tinyPNG.write(to: image)
        func quoted(_ url: URL) -> String { TerminalWindowController.shellQuoted(url.path) }

        app.newTab(in: dir)
        guard let tab = app.store.selected, let host = app.host(of: tab) else { return check("a tab", false) }
        let shell = tab.terminal
        await settledPrompt()
        let shellOut = out("shell-drop")
        check(
            "cat reads the shell pane",
            await run("cat > \(shellOut.path)") { shell.needsConfirmClose == true && FileManager.default.fileExists(atPath: shellOut.path) })

        // Over the pane: highlighted, saying what a drop does; gone when it leaves.
        let files = drag([plain as NSURL, spaced as NSURL, folder as NSURL])
        let firstResponder = window.firstResponder
        check("a drag of files is taken", shell.draggingEntered(files) == .copy)
        let highlight = shell.dropHighlight
        check("the pane is highlighted", highlight?.superview === host && highlight?.isHidden == false)
        check("saying what a drop does", await eventually(3) { highlight?.text == "Drop to insert 3 paths" }, highlight?.text ?? "nil")
        let clips: Bool = {
            guard let highlight else { return false }
            if #available(macOS 14, *) { return highlight.clipsToBounds }
            return highlight.layer?.masksToBounds == true
        }()
        check("drawn over the pane only", highlight?.frame == shell.frame && clips, "\(String(describing: highlight?.frame)) vs \(shell.frame)")
        check("it doesn't take the keyboard", window.firstResponder === firstResponder && !(highlight?.acceptsFirstResponder ?? true))
        shell.draggingExited(files)
        check("it goes when the drag leaves", shell.dropHighlight == nil && highlight?.superview == nil)

        // A shell: shell-quoted absolute paths, as Terminal writes them — typed
        // in, not run: cat gets them only at a Ctrl-D, without a newline.
        func contents(_ file: URL) -> String? { (try? Data(contentsOf: file)).map { String(decoding: $0, as: UTF8.self) } }
        check("the files are dropped", drop(files, on: shell))
        check("the highlight goes with the drop", shell.dropHighlight == nil && !host.subviews.contains { $0 is DropHighlightView })
        let shellFiles = "\(quoted(plain)) \(quoted(spaced)) \(quoted(folder)) "
        await eventually { !shell.hasPendingDrops }
        await pause(0.3)
        controlD()
        check(
            "the shell pane got exactly the quoted paths and a trailing space", await eventually { contents(shellOut) == shellFiles },
            (contents(shellOut) ?? "missing").debugDescription + " want " + shellFiles.debugDescription)

        // A promised file (Photos, Safari, the screenshot thumbnail): written
        // into the drops folder first. A real source writes it at the end of
        // its drag, which a run can't start: the stand-in does the same.
        let promise = E2EPromise(data: Self.tinyPNG)
        let provider = NSFilePromiseProvider(fileType: UTType.png.identifier, delegate: promise)
        TerminalDrop.keepPromise = { _, folder, arrived in
            let url = folder.appendingPathComponent(promise.filePromiseProvider(provider, fileNameForType: UTType.png.identifier))
            promise.filePromiseProvider(provider, writePromiseTo: url) { _ in arrived(url) }
        }
        let promised = drag([provider])
        _ = shell.draggingEntered(promised)
        check("a promise is taken, and counted", shell.dropHighlight?.text == "Drop to insert path", shell.dropHighlight?.text ?? "nil")
        shell.draggingExited(promised)
        check("the promise is dropped", drop(promised, on: shell))
        let received = await eventually(5) {
            ((try? FileManager.default.subpathsOfDirectory(atPath: AppEnvironment.dropsDirectory.path)) ?? []).contains { $0.hasSuffix("/promised.png") }
        }
        let receivedFile = ((try? FileManager.default.subpathsOfDirectory(atPath: AppEnvironment.dropsDirectory.path)) ?? [])
            .first { $0.hasSuffix("/promised.png") }.map { AppEnvironment.dropsDirectory.appendingPathComponent($0) }
        check(
            "the promised file is written into a folder of its own under the drops directory",
            received && receivedFile.flatMap { try? Data(contentsOf: $0) } == Self.tinyPNG, AppEnvironment.dropsDirectory.path)
        TerminalDrop.keepPromise = nil

        // A web link goes in as text.
        let link = drag([URL(string: "https://example.com/a?b=1")! as NSURL])
        _ = shell.draggingEntered(link)
        check("a link is taken as text", shell.dropHighlight?.text == "Drop to insert text", shell.dropHighlight?.text ?? "nil")
        shell.draggingExited(link)
        check("the link is dropped", drop(link, on: shell))

        let expectedShell = shellFiles + (receivedFile.map { quoted($0) + " " } ?? "promised? ") + "https://example.com/a?b=1 "
        await eventually { !shell.hasPendingDrops }
        await pause(0.3)
        controlD()
        check(
            "then the promised file's path and the link, in the order dropped", await eventually { contents(shellOut) == expectedShell },
            (contents(shellOut) ?? "missing").debugDescription + " want " + expectedShell.debugDescription)
        controlD()

        // Claude Code in the other pane of the tab: found by its process, in
        // that pane only.
        let claudeOut = out("claude-drop")
        let script = scratch.appendingPathComponent("claude.sh")
        try? "exec -a claude cat > '\(claudeOut.path)'\n".write(to: script, atomically: true, encoding: .utf8)
        app.splitRight(nil)
        let right = tab.terminals[1]
        check("a second pane", tab.terminals.count == 2 && tab.terminal === right)
        check(
            "the stand-in Claude Code runs there",
            await run("bash \(script.path)") { right.needsConfirmClose == true && FileManager.default.fileExists(atPath: claudeOut.path) })
        var seen: TerminalDrop.Program = .other
        for _ in 0..<40 {
            seen = await program(of: right)
            if case .claude = seen { break }
            await pause(0.25)
        }
        check("its pane finds Claude Code", { if case .claude = seen { return true } else { return false } }(), "\(seen)")
        check("the shell's pane doesn't", await program(of: shell) == .other)

        window.makeFirstResponder(shell)
        let mixed = drag([spaced as NSURL, image as NSURL, plain as NSURL, folder as NSURL])
        _ = right.draggingEntered(mixed)
        check(
            "over Claude Code, the label says @ references", await eventually(3) { right.dropHighlight?.text == "Drop to insert 4 @ references" },
            right.dropHighlight?.text ?? "nil")
        if let png = ProcessInfo.processInfo.environment["TERMINUS_DUMP_PNG"] {
            await pause(0.6)
            app.captureWindow(to: png)
        }
        right.draggingExited(mixed)
        check("dropped on Claude Code", drop(mixed, on: right))
        check("the drop gives that pane the keyboard", await eventually(2) { self.window.firstResponder === right && tab.terminal === right })
        let expectedClaude = " @\"with space.md\" @plain.txt @folder/ \(image.path) "

        // ⌥: plain quoted paths, Claude Code or not.
        TerminalView.dropModifierFlags = { .option }
        let optioned = drag([plain as NSURL, spaced as NSURL])
        _ = right.draggingEntered(optioned)
        check("with ⌥ the label says paths", await eventually(3) { right.dropHighlight?.text == "Drop to insert 2 paths" }, right.dropHighlight?.text ?? "nil")
        right.draggingExited(optioned)
        check("dropped with ⌥", drop(optioned, on: right))
        TerminalView.dropModifierFlags = { NSEvent.modifierFlags }
        let expectedOption = "\(quoted(plain)) \(quoted(spaced)) "

        await eventually { !right.hasPendingDrops }
        await pause(0.3)
        controlD()
        let expected = expectedClaude + expectedOption
        check(
            "Claude Code got the @-mentions, relative to where it works, the image's path, then ⌥'s plain paths",
            await eventually { contents(claudeOut) == expected },
            (contents(claudeOut) ?? "missing").debugDescription + " want " + expected.debugDescription)
        controlD()

        // The sidebar's rows are drag sources: a file URL, as Finder's.
        let item = FileTreeDrag.item(for: plain)
        check("a sidebar row drags a file URL", item.registeredTypeIdentifiers.contains(UTType.fileURL.identifier), "\(item.registeredTypeIdentifiers)")
        let dragged: URL? = await withCheckedContinuation { continuation in
            _ = item.loadObject(ofClass: NSURL.self) { object, _ in continuation.resume(returning: (object as? NSURL) as URL?) }
        }
        check("of that file", dragged?.standardizedFileURL == plain.standardizedFileURL, dragged?.path ?? "nil")

        // And the rows still click, double-click and have their menu: in-process
        // mouse events at the row, as the window dispatches them.
        guard let sidebar = app.sidebarItem?.viewController.view, app.sidebarItem?.isCollapsed == false else { return check("the sidebar shows", false) }
        let resolvedDir = dir.resolvingSymlinksInPath()
        let listed = await eventually {
            self.app.tree.root?.resolvingSymlinksInPath() == resolvedDir && self.app.tree.rows.map(\.entry.name) == ["folder", "plain.txt", "shot.png", "with space.md"]
        }
        check("the sidebar lists the folder", listed, app.tree.rows.map(\.entry.name).joined(separator: ", "))
        // Panel bar 40, divider 1, header 34, list padding 4, then 26 a row:
        // the middle of the second, plain.txt.
        let top: CGFloat = 40 + 1 + 34 + 4
        let rowCentre = sidebar.convert(NSPoint(x: 60, y: top + 26 + 13), to: nil)
        func mouse(_ type: NSEvent.EventType, clicks: Int) -> NSEvent {
            NSEvent.mouseEvent(
                with: type, location: rowCentre, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!
        }
        window.sendEvent(mouse(.leftMouseDown, clicks: 1))
        window.sendEvent(mouse(.leftMouseUp, clicks: 1))
        check(
            "a click on a row still opens it in the editor",
            await eventually(3) { self.app.editor?.document.url?.lastPathComponent == "plain.txt" },
            app.editor?.document.url?.path ?? "nothing open")
        await pause(0.3)
        window.sendEvent(mouse(.leftMouseDown, clicks: 1))
        window.sendEvent(mouse(.leftMouseUp, clicks: 1))
        window.sendEvent(mouse(.leftMouseDown, clicks: 2))
        window.sendEvent(mouse(.leftMouseUp, clicks: 2))
        // Six seconds, not three: the sheet is put up after an async look
        // at what can open the file, and under a full parallel run that
        // has gone past three.
        check("a double-click still opens it outside (asking which app first)", await eventually(6) { self.window.attachedSheet != nil })
        clickSheetButton("Cancel")
        let menu = sidebar.menu(for: mouse(.rightMouseDown, clicks: 1))
        check(
            "and its menu is still there", menu?.items.map(\.title).contains("Insert Path in Terminal") == true,
            menu.map { $0.items.map(\.title).joined(separator: ", ") } ?? "no menu")
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

/// A drag as AppKit hands one to a destination, over a private pasteboard.
/// The E2E drives a pane's NSDraggingDestination methods with it; nothing
/// goes through the system's drag machinery.
@MainActor
final class E2EDraggingInfo: NSObject, NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    let draggingDestinationWindow: NSWindow?
    let draggingSequenceNumber = Int.random(in: 1...1_000_000)
    var draggingSourceOperationMask: NSDragOperation { [.copy, .link, .generic] }
    var draggingLocation: NSPoint { .zero }
    var draggedImageLocation: NSPoint { .zero }
    nonisolated var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 0
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }

    init(pasteboard: NSPasteboard, window: NSWindow?) {
        draggingPasteboard = pasteboard
        draggingDestinationWindow = window
    }

    func slideDraggedImage(to screenPoint: NSPoint) {}
    func enumerateDraggingItems(
        options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?, classes classArray: [AnyClass],
        searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:], using block: @escaping (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
    ) {}
    func resetSpringLoading() {}
}

/// The source side of a file promise: names the file and writes it when
/// asked, as Photos or Safari do.
final class E2EPromise: NSObject, NSFilePromiseProviderDelegate {
    let data: Data

    init(data: Data) { self.data = data }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String { "promised.png" }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL, completionHandler: @escaping ((any Error)?) -> Void) {
        do {
            try data.write(to: url)
            completionHandler(nil)
        } catch {
            completionHandler(error)
        }
    }
}

/// The longest the main thread went without running a 50 ms timer.
@MainActor
private final class StallMeter {
    private var timer: Timer?
    private var last = Date()
    private(set) var worst: TimeInterval = 0

    init() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = Date()
                self.worst = max(self.worst, now.timeIntervalSince(self.last) - 0.05)
                self.last = now
            }
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    func reset() {
        worst = 0
        last = Date()
    }

    func stop() { timer?.invalidate() }
}
