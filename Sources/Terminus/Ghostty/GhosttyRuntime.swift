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
    static let logger = Logger(subsystem: "ai.promptrails.terminus", category: "ghostty")

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

    private init() {
        guard Self.initialized.withLock({ $0 }) else { return }
        // The user's regular Ghostty config (~/.config/ghostty/config) applies
        // as-is: font, theme, keybinds all carry over.
        guard let config = ghostty_config_new() else {
            Self.logger.critical("ghostty_config_new failed")
            return
        }
        ghostty_config_load_default_files(config)
        ghostty_config_load_recursive_files(config)
        ghostty_config_finalize(config)
        for i in 0..<ghostty_config_diagnostics_count(config) {
            let diag = ghostty_config_get_diagnostic(config, i)
            if let message = diag.message {
                Self.logger.warning("config: \(String(cString: message), privacy: .public)")
            }
        }
        self.config = config

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
            confirm_read_clipboard_cb: { userdata, string, state, _ in
                // Paste-safety and OSC 52 read confirmations. Until there is a
                // confirmation UI, answer them unconfirmed rather than silently
                // allowing: libghostty then refuses the unsafe case.
                nonisolated(unsafe) let (userdata, string, state) = (userdata, string, state)
                MainActor.assumeIsolated {
                    guard let view = TerminalView.from(userdata: userdata), let surface = view.surface, let string else { return }
                    ghostty_surface_complete_clipboard_request(surface, string, state, false)
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

        case GHOSTTY_ACTION_CLOSE_TAB:
            guard let window, let view else { return false }
            window.closeTabs(of: view, mode: action.action.close_tab_mode)
            return true

        case GHOSTTY_ACTION_GOTO_TAB:
            guard let window else { return false }
            return window.gotoTab(action.action.goto_tab.rawValue)

        // Ghostty's default ⇧⌘W / ⌥⇧⌘W: bound, so they never reach our menu —
        // unhandled they did nothing at all.
        case GHOSTTY_ACTION_CLOSE_WINDOW, GHOSTTY_ACTION_CLOSE_ALL_WINDOWS:
            guard let window = window?.window else { return false }
            window.performClose(nil)
            return true

        // Ghostty's ⇧⌘P opens our palette rather than its own (which we
        // don't have).
        case GHOSTTY_ACTION_TOGGLE_COMMAND_PALETTE:
            guard let window else { return false }
            window.showPalette(nil)
            return true

        case GHOSTTY_ACTION_MOVE_TAB:
            guard let window, let view else { return false }
            window.moveTab(of: view, by: action.action.move_tab.amount)
            return true

        case GHOSTTY_ACTION_QUIT:
            NSApp.terminate(nil)
            return true

        case GHOSTTY_ACTION_SET_TITLE:
            guard let view, let title = action.action.set_title.title else { return false }
            view.onTitleChange?(String(cString: title))
            return true

        case GHOSTTY_ACTION_PWD:
            guard let view, let pwd = action.action.pwd.pwd else { return false }
            view.workingDirectory = String(cString: pwd)
            return true

        case GHOSTTY_ACTION_MOUSE_SHAPE:
            view?.setMouseShape(action.action.mouse_shape)
            return true

        case GHOSTTY_ACTION_OPEN_URL:
            let open = action.action.open_url
            guard let raw = open.url else { return false }
            let data = Data(bytes: raw, count: Int(open.len))
            guard let string = String(data: data, encoding: .utf8) else { return false }
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
        case GHOSTTY_CLIPBOARD_STANDARD: .general
        // macOS has no primary selection; a private named pasteboard stands in
        // so select-to-copy / middle-click-paste work inside Terminus.
        case GHOSTTY_CLIPBOARD_SELECTION: NSPasteboard(name: .init("ai.promptrails.terminus.selection"))
        default: nil
        }
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
