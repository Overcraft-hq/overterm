import AppKit
import GhosttyKit
import os

/// The single libghostty app instance and the runtime callbacks it drives.
///
/// libghostty owns terminal state, the pty, and rendering (Metal, on its own
/// thread). We own the event loop: `wakeup_cb` fires from any thread and asks
/// us to call `ghostty_app_tick` on the main thread, where every other callback
/// then runs.
@MainActor
final class GhosttyRuntime {
    static let logger = Logger(subsystem: AppEnvironment.bundleIdentifier, category: "ghostty")

    /// Process-wide libghostty init. Must run before anything else touches the
    /// library, so main.swift calls it first.
    nonisolated static func initialize() -> Bool {
        let ok = ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) == GHOSTTY_SUCCESS
        initialized.withLock { $0 = ok }
        return ok
    }

    /// Whether `initialize()` ran. Without it there is no app and every
    /// TerminalView is surfaceless — which is what unit tests of tab logic
    /// want: real Tabs, no ptys.
    private nonisolated static let initialized = OSAllocatedUnfairLock(initialState: false)

    static let shared = GhosttyRuntime()

    private(set) var app: ghostty_app_t?
    private var config: ghostty_config_t?
    /// The user's config without Settings' overrides: what a key is bound
    /// to before Keyboard Shortcuts changes it (KeyCombo defaults).
    private var baseConfig: ghostty_config_t?

    private init() {
        guard Self.initialized.withLock({ $0 }) else { return }
        guard let config = Self.makeConfig() else { return }
        self.config = config
        baseConfig = Self.makeConfig(overrides: false)

        var runtime = Self.runtimeConfig()
        guard let app = ghostty_app_new(&runtime, config) else {
            Self.logger.critical("ghostty_app_new failed")
            return
        }
        self.app = app
        ghostty_app_set_focus(app, NSApp.isActive)

        let center = NotificationCenter.default
        center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { GhosttyRuntime.shared.setFocus(true) }
        }
        center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { GhosttyRuntime.shared.setFocus(false) }
        }
        center.addObserver(forName: NSTextInputContext.keyboardSelectionDidChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                if let app = GhosttyRuntime.shared.app { ghostty_app_keyboard_changed(app) }
            }
        }
    }

    /// The C callbacks. Built in a nonisolated context on purpose: a closure
    /// written inside this @MainActor class is inferred main-actor isolated
    /// and Swift 6 traps when libghostty calls it from its renderer or io
    /// thread (wakeup_cb does exactly that). Only wakeup is cross-thread; the
    /// rest run inside ghostty_app_tick or a surface call, on main, so handing
    /// their raw pointers across with nonisolated(unsafe) is sound.
    private nonisolated static func runtimeConfig() -> ghostty_runtime_config_s {
        ghostty_runtime_config_s(
            userdata: nil,
            supports_selection_clipboard: true,
            wakeup_cb: { _ in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { GhosttyRuntime.shared.tick() }
                }
            },
            action_cb: { _, target, action in
                MainActor.assumeIsolated { GhosttyRuntime.shared.perform(target: target, action: action) }
            },
            read_clipboard_cb: { userdata, location, state in
                nonisolated(unsafe) let (userdata, state) = (userdata, state)
                return MainActor.assumeIsolated { TerminalView.from(userdata: userdata)?.readClipboard(location, state: state) ?? false }
            },
            confirm_read_clipboard_cb: { userdata, string, state, request in
                // A paste that could run commands, or a program reading the
                // clipboard (OSC 52): the window asks. The string only lives
                // for this call.
                nonisolated(unsafe) let (userdata, string, state) = (userdata, string, state)
                MainActor.assumeIsolated {
                    GhosttyRuntime.confirmClipboard(userdata: userdata, text: string.map { String(cString: $0) } ?? "", state: state, request: request)
                }
            },
            write_clipboard_cb: { _, location, content, count, confirm in
                // `confirm` means the config asks for a prompt (clipboard-write =
                // ask). No prompt UI yet, so that write is dropped, not allowed.
                guard !confirm else { return }
                nonisolated(unsafe) let content = content
                MainActor.assumeIsolated { GhosttyRuntime.writeClipboard(location, content: content, count: count) }
            },
            close_surface_cb: { userdata, processAlive in
                nonisolated(unsafe) let userdata = userdata
                MainActor.assumeIsolated { TerminalView.from(userdata: userdata)?.onClose?(processAlive) }
            }
        )
    }

    /// The user's regular Ghostty config (~/.config/ghostty/config) applies
    /// as-is — font, theme, keybinds all carry over — and then what
    /// Terminus ▸ Settings overrides (Settings.ghosttyOverridesFile).
    private static func makeConfig(overrides: Bool = true) -> ghostty_config_t? {
        guard let config = ghostty_config_new() else {
            logger.critical("ghostty_config_new failed")
            return nil
        }
        ghostty_config_load_default_files(config)
        ghostty_config_load_recursive_files(config)
        let file = Settings.ghosttyOverridesFile.path
        if overrides, FileManager.default.fileExists(atPath: file) { ghostty_config_load_file(config, file) }
        ghostty_config_finalize(config)
        for i in 0..<ghostty_config_diagnostics_count(config) {
            let diag = ghostty_config_get_diagnostic(config, i)
            if let message = diag.message {
                logger.warning("config: \(String(cString: message), privacy: .public)")
            }
        }
        return config
    }

    /// Re-reads the config (the user's and Settings' overrides) and hands it
    /// to every terminal: font, theme, padding and cursor change in place.
    func reloadConfig() {
        guard let app, let fresh = Self.makeConfig() else { return }
        ghostty_app_update_config(app, fresh)
        if let old = config { ghostty_config_free(old) }
        config = fresh
        // The user's own config may have changed its keybinds too.
        if let old = baseConfig { ghostty_config_free(old) }
        baseConfig = Self.makeConfig(overrides: false)
    }

    /// What `action` is bound to without Settings' changes: Ghostty's
    /// default, or the user's Ghostty config's.
    func defaultTrigger(for action: String) -> ghostty_input_trigger_s? {
        guard let baseConfig else { return nil }
        let trigger = ghostty_config_trigger(baseConfig, action, UInt(action.utf8.count))
        return trigger.tag == GHOSTTY_TRIGGER_UNICODE && trigger.key.unicode == 0 ? nil : trigger
    }

    /// Problems Ghostty found in the config it runs (Settings shows them).
    var configDiagnostics: [String] {
        guard let config else { return [] }
        return (0..<ghostty_config_diagnostics_count(config)).compactMap { i in
            ghostty_config_get_diagnostic(config, i).message.map { String(cString: $0) }
        }
    }

    /// A number the config holds (e.g. "font-size"): what Settings shows as
    /// the current value when it overrides nothing.
    func configNumber(_ key: String) -> Double? {
        guard let config else { return nil }
        var value: Float = 0
        guard ghostty_config_get(config, &value, key, UInt(key.utf8.count)) else { return nil }
        return Double(value)
    }

    /// The key the config binds to a Ghostty action ("new_split:right");
    /// Settings ▸ Keyboard Shortcuts lists them.
    func trigger(for action: String) -> ghostty_input_trigger_s? {
        guard let config else { return nil }
        return ghostty_config_trigger(config, action, UInt(action.utf8.count))
    }

    /// The terminal theme's background and foreground, so the chrome around
    /// the terminal can match it.
    var backgroundColor: NSColor { color("background") ?? .windowBackgroundColor }
    var foregroundColor: NSColor { color("foreground") ?? .labelColor }

    private func color(_ key: String) -> NSColor? {
        guard let config else { return nil }
        var c = ghostty_config_color_s()
        guard ghostty_config_get(config, &c, key, UInt(key.utf8.count)) else { return nil }
        return NSColor(srgbRed: CGFloat(c.r) / 255, green: CGFloat(c.g) / 255, blue: CGFloat(c.b) / 255, alpha: 1)
    }

    func tick() {
        guard let app else { return }
        ghostty_app_tick(app)
    }

    private func setFocus(_ focused: Bool) {
        guard let app else { return }
        ghostty_app_set_focus(app, focused)
    }

    // MARK: Actions

    /// Actions libghostty asks the host to carry out. Returning false tells it
    /// the action is unhandled; splits and extra windows are ours to build, so
    /// those stay unhandled until Terminus has them.
    private func perform(target: ghostty_target_s, action: ghostty_action_s) -> Bool {
        let view: TerminalView? = target.tag == GHOSTTY_TARGET_SURFACE ? TerminalView.from(surface: target.target.surface) : nil
        let window = view?.window?.windowController as? TerminalWindowController

        switch action.tag {
        // Tabs are Terminus's, not Ghostty's — but the user's Ghostty keybinds
        // for them (cmd+t, cmd+shift+], goto_tab:N, ...) still drive ours.
        case GHOSTTY_ACTION_NEW_TAB:
            guard let window else { return false }
            window.newTab(from: view)
            return true

        // Splits are Terminus's too; Ghostty's keybinds (cmd+d, cmd+[, …) drive them.
        case GHOSTTY_ACTION_NEW_SPLIT:
            guard let window else { return false }
            let direction: SplitTree<TerminalView>.Direction =
                switch action.action.new_split {
                case GHOSTTY_SPLIT_DIRECTION_DOWN: .down
                case GHOSTTY_SPLIT_DIRECTION_LEFT: .left
                case GHOSTTY_SPLIT_DIRECTION_UP: .up
                default: .right
                }
            window.split(view, direction)
            return true

        case GHOSTTY_ACTION_GOTO_SPLIT:
            guard let window else { return false }
            let focus: SplitTree<TerminalView>.Focus =
                switch action.action.goto_split {
                case GHOSTTY_GOTO_SPLIT_PREVIOUS: .previous
                case GHOSTTY_GOTO_SPLIT_UP: .up
                case GHOSTTY_GOTO_SPLIT_LEFT: .left
                case GHOSTTY_GOTO_SPLIT_DOWN: .down
                case GHOSTTY_GOTO_SPLIT_RIGHT: .right
                default: .next
                }
            return window.focusSplit(from: view, focus)

        case GHOSTTY_ACTION_RESIZE_SPLIT:
            guard let window else { return false }
            let resize = action.action.resize_split
            let direction: SplitTree<TerminalView>.Direction =
                switch resize.direction {
                case GHOSTTY_RESIZE_SPLIT_UP: .up
                case GHOSTTY_RESIZE_SPLIT_DOWN: .down
                case GHOSTTY_RESIZE_SPLIT_LEFT: .left
                default: .right
                }
            window.resizeSplit(view, toward: direction, points: Double(resize.amount))
            return true

        case GHOSTTY_ACTION_EQUALIZE_SPLITS:
            window?.equalizeSplits(view)
            return window != nil

        case GHOSTTY_ACTION_TOGGLE_SPLIT_ZOOM:
            window?.toggleSplitZoom(view)
            return window != nil

        // Closing frees surfaces — this one included, whose key handler we are
        // still inside. Deferred to the next turn of the run loop: with
        // Settings' "only when something runs" and an idle shell nothing asks
        // first, and freeing here was a use-after-free.
        case GHOSTTY_ACTION_CLOSE_TAB:
            guard let window, let view else { return false }
            let mode = action.action.close_tab_mode
            DispatchQueue.main.async { [weak window, weak view] in
                guard let window, let view else { return }
                window.closeTabs(of: view, mode: mode)
            }
            return true

        case GHOSTTY_ACTION_GOTO_TAB:
            guard let window else { return false }
            return window.gotoTab(action.action.goto_tab.rawValue)

        // Ghostty's default ⇧⌘W / ⌥⇧⌘W: bound, so they never reach our menu —
        // unhandled they did nothing at all.
        case GHOSTTY_ACTION_CLOSE_WINDOW, GHOSTTY_ACTION_CLOSE_ALL_WINDOWS:
            guard let window = window?.window else { return false }
            DispatchQueue.main.async { [weak window] in window?.performClose(nil) }
            return true

        // Ghostty's ⇧⌘P opens our palette rather than its own (which we
        // don't have).
        case GHOSTTY_ACTION_TOGGLE_COMMAND_PALETTE:
            guard let window else { return false }
            window.showPalette(nil)
            return true

        // Find in terminal: libghostty searches; we show the bar.
        case GHOSTTY_ACTION_START_SEARCH:
            guard let view else { return false }
            let needle = action.action.start_search.needle.map { String(cString: $0) }
            if let request = view.onSearchRequest {
                request(needle)
            } else {
                view.search.begin(needle: needle)
                view.search.showBar()
            }
            return true

        case GHOSTTY_ACTION_END_SEARCH:
            view?.search.end()
            return true

        case GHOSTTY_ACTION_SEARCH_TOTAL:
            let total = action.action.search_total.total
            view?.search.update(total: total >= 0 ? Int(total) : nil)
            return true

        case GHOSTTY_ACTION_SEARCH_SELECTED:
            let selected = action.action.search_selected.selected
            view?.search.update(selected: selected >= 0 ? Int(selected) : nil)
            return true

        case GHOSTTY_ACTION_MOVE_TAB:
            guard let window, let view else { return false }
            window.moveTab(of: view, by: action.action.move_tab.amount)
            return true

        case GHOSTTY_ACTION_QUIT:
            DispatchQueue.main.async { NSApp.terminate(nil) }
            return true

        case GHOSTTY_ACTION_SET_TITLE:
            guard let view, let title = action.action.set_title.title else { return false }
            view.title = String(cString: title)
            view.onTitleChange?(String(cString: title))
            return true

        case GHOSTTY_ACTION_PWD:
            guard let view, let pwd = action.action.pwd.pwd else { return false }
            view.workingDirectory = String(cString: pwd)
            view.markShellReported()
            return true

        case GHOSTTY_ACTION_MOUSE_SHAPE:
            view?.setMouseShape(action.action.mouse_shape)
            return true

        // mouse-hide-while-typing (Settings ▸ Terminal): hidden until it moves.
        case GHOSTTY_ACTION_MOUSE_VISIBILITY:
            NSCursor.setHiddenUntilMouseMoves(action.action.mouse_visibility == GHOSTTY_MOUSE_HIDDEN)
            return true

        // Ghostty's ⌘, (open_config): Terminus's Settings, not a text file.
        case GHOSTTY_ACTION_OPEN_CONFIG:
            DispatchQueue.main.async { (NSApp.delegate as? AppDelegate)?.showSettings(nil) }
            return true

        case GHOSTTY_ACTION_OPEN_URL:
            let open = action.action.open_url
            guard let raw = open.url else { return false }
            let data = Data(bytes: raw, count: Int(open.len))
            guard let string = String(data: data, encoding: .utf8) else { return false }
            if view?.onOpenLink?(string) == true { return true }
            let url = URL(string: string) ?? URL(fileURLWithPath: string)
            NSWorkspace.shared.open(url)
            return true

        // Signals that a tab may want you; the window decides whether that
        // is news (see TabActivity).
        case GHOSTTY_ACTION_RING_BELL:
            guard let view else { return false }
            view.onEvent?(.bell)
            return true

        case GHOSTTY_ACTION_DESKTOP_NOTIFICATION:
            guard let view else { return false }
            let n = action.action.desktop_notification
            view.onEvent?(.notification(title: n.title.map { String(cString: $0) } ?? "", body: n.body.map { String(cString: $0) } ?? ""))
            return true

        case GHOSTTY_ACTION_PROGRESS_REPORT:
            guard let view else { return false }
            let state = action.action.progress_report.state
            view.onEvent?(.progress(active: state != GHOSTTY_PROGRESS_STATE_REMOVE && state != GHOSTTY_PROGRESS_STATE_ERROR, failed: state == GHOSTTY_PROGRESS_STATE_ERROR))
            return true

        case GHOSTTY_ACTION_COMMAND_FINISHED:
            guard let view else { return false }
            let finished = action.action.command_finished
            view.onEvent?(.commandFinished(exitCode: finished.exit_code < 0 ? nil : Int(finished.exit_code), seconds: Double(finished.duration) / 1e9))
            return true

        default:
            return false
        }
    }

    // MARK: Clipboard

    static func pasteboard(_ location: ghostty_clipboard_e) -> NSPasteboard? {
        switch location {
        // An isolated run (AppEnvironment) has a clipboard of its own: the
        // E2E scenarios put text on it and must never touch the user's.
        case GHOSTTY_CLIPBOARD_STANDARD: AppEnvironment.isIsolated ? isolatedClipboard : .general
        // macOS has no primary selection; a private named pasteboard stands in
        // so select-to-copy / middle-click-paste work inside Terminus.
        case GHOSTTY_CLIPBOARD_SELECTION: NSPasteboard(name: .init("\(AppEnvironment.bundleIdentifier).selection"))
        default: nil
        }
    }

    private static let isolatedClipboard = NSPasteboard(name: .init("\(AppEnvironment.bundleIdentifier).isolated.clipboard"))

    /// A request libghostty wants confirmed (ClipboardConfirmation): the
    /// terminal's window asks, and the request is completed confirmed either
    /// way — unconfirmed, libghostty asks again, forever.
    private static func confirmClipboard(
        userdata: UnsafeMutableRawPointer?, text: String, state: UnsafeMutableRawPointer?, request: ghostty_clipboard_request_e
    ) {
        guard let view = TerminalView.from(userdata: userdata), let surface = view.surface else { return }
        let confirmation = ClipboardConfirmation(request: request, text: text)
        let complete: @MainActor (Bool) -> Void = { [weak view] allowed in
            // The pane closed while the sheet was up: the request went with it.
            guard let view, view.surface == surface else { return }
            let reply = confirmation?.reply(allowed: allowed) ?? ClipboardConfirmation.Reply(text: "", confirmed: true)
            reply.text.withCString { ghostty_surface_complete_clipboard_request(surface, $0, state, reply.confirmed) }
        }
        guard let confirmation, let window = view.window?.windowController as? TerminalWindowController else { return complete(false) }
        window.confirmClipboard(confirmation, from: view, answer: complete)
    }

    private static func writeClipboard(_ location: ghostty_clipboard_e, content: UnsafePointer<ghostty_clipboard_content_s>?, count: Int) {
        guard let content, count > 0, let pasteboard = pasteboard(location) else { return }
        for i in 0..<count where content[i].mime != nil && content[i].data != nil {
            guard String(cString: content[i].mime) == "text/plain" else { continue }
            pasteboard.clearContents()
            pasteboard.setString(String(cString: content[i].data), forType: .string)
            return
        }
    }
}
