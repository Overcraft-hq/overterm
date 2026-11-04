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
        useOurOwnResources()
        let ok = ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) == GHOSTTY_SUCCESS
        initialized.withLock { $0 = ok }
        return ok
    }

    /// libghostty's resources — the themes, the shell integration scripts,
    /// terminfo — come from `GHOSTTY_RESOURCES_DIR` when it is set, and
    /// every Ghostty-family terminal exports it to what it runs. Started
    /// from a terminal inside Ghostty, Overterm inherited *Ghostty's* copy:
    /// another build's shell integration, and `theme = "<name>"` looking for
    /// themes in Ghostty.app — so a theme we bundle was never found, and
    /// one Settings had just set quietly did nothing. Ours, always: they are
    /// the ones this libghostty was built with.
    ///
    /// Launched from the Dock there is no such variable and libghostty finds
    /// our bundle itself, by the terminfo beside it; this makes the two the
    /// same.
    private nonisolated static func useOurOwnResources() {
        guard let resources = Bundle.main.resourceURL?.appendingPathComponent("ghostty", isDirectory: true),
            FileManager.default.fileExists(atPath: resources.appendingPathComponent("themes").path)
        else { return }
        setenv("GHOSTTY_RESOURCES_DIR", resources.path, 1)
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
        // macOS switching between light and dark: the half of a
        // `theme = light:…,dark:…` in force changes with it. The system
        // tells every app through a distributed notification; NSApp's
        // effectiveAppearance is read when it arrives.
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"), object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { GhosttyRuntime.shared.setColorScheme() }
        }
    }

    /// Which way macOS is dressed, as libghostty counts it.
    var colorScheme: ghostty_color_scheme_e {
        NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT
    }

    /// Posted when it changes; each open surface takes the new one.
    static let colorSchemeChanged = Notification.Name("ColorSchemeChanged")

    /// Posted after the config is re-read, for the surfaces already open.
    static let configReloaded = Notification.Name("ConfigReloaded")

    /// Hands the config in force to one surface (`TerminalView`) — or, for
    /// a surface with a theme of its own (a group's, a folder's), the same
    /// config with that theme over it.
    func updateConfig(of surface: ghostty_surface_t, theme: String? = nil) {
        guard let config = theme.flatMap(themedConfig) ?? config else { return }
        ghostty_surface_update_config(surface, config)
    }

    /// The configs with a theme over the app's, by theme name — built once
    /// each, until the app's config is read again.
    private var themed: [String: ghostty_config_t] = [:]

    /// The app's config, then `theme = "<name>"` last, so it wins over the
    /// user's and Settings' themes and nothing else.
    private func themedConfig(_ name: String) -> ghostty_config_t? {
        if let cached = themed[name] { return cached }
        let directory = AppEnvironment.supportDirectory.appendingPathComponent("theme-overlays", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // The name is the user's: a file name of its hash, the name inside.
        let file = directory.appendingPathComponent("\(UInt32(truncatingIfNeeded: name.hashValue)).conf")
        guard (try? "theme = \"\(name)\"\n".write(to: file, atomically: true, encoding: .utf8)) != nil,
            let config = Self.makeConfig(overlay: file.path)
        else { return nil }
        themed[name] = config
        return config
    }

    /// Tells libghostty which way macOS is dressed. It assumes light until
    /// told, so a theme written as a light/dark pair came out light in the
    /// dark — and so does the `light:`/`dark:` in the user's own Ghostty
    /// config. The app takes it for the surfaces still to come; the ones
    /// already open are told one by one (`TerminalView`), as Ghostty's own
    /// app does.
    ///
    /// After the app is up, never during `ghostty_app_new`: the library is
    /// not ready for it there and the process dies without a word.
    func setColorScheme() {
        guard let app else { return }
        ghostty_app_set_color_scheme(app, colorScheme)
        NotificationCenter.default.post(name: Self.colorSchemeChanged, object: nil)
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
            read_clipboard_cb: { userdata, location, state, mimes, mimeCount, list in
                // The types asked for, read now: they only live for this call.
                var asked: [String] = []
                if let mimes { for i in 0..<mimeCount { if let mime = mimes[i] { asked.append(String(cString: mime)) } } }
                nonisolated(unsafe) let (userdata, state) = (userdata, state)
                return MainActor.assumeIsolated {
                    TerminalView.from(userdata: userdata)?.readClipboard(location, state: state, mimes: asked, list: list)
                        ?? GHOSTTY_CLIPBOARD_READ_UNSUPPORTED
                }
            },
            confirm_read_clipboard_cb: { userdata, confirm, state, request in
                // A paste that could run commands, or a program reading the
                // clipboard (OSC 52): the window asks. What it would get only
                // lives for this call: its text is read now, and the answer
                // hands over exactly that.
                let text = confirm.map { GhosttyRuntime.text(of: $0.pointee) } ?? ""
                nonisolated(unsafe) let (userdata, state) = (userdata, state)
                MainActor.assumeIsolated {
                    GhosttyRuntime.confirmClipboard(userdata: userdata, text: text, state: state, request: request)
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
    /// Overterm ▸ Settings overrides (Settings.ghosttyOverridesFile).
    private static func makeConfig(overrides: Bool = true, overlay: String? = nil) -> ghostty_config_t? {
        guard let config = ghostty_config_new() else {
            logger.critical("ghostty_config_new failed")
            return nil
        }
        ghostty_config_load_default_files(config)
        ghostty_config_load_recursive_files(config)
        let file = Settings.ghosttyOverridesFile.path
        if overrides, FileManager.default.fileExists(atPath: file) { ghostty_config_load_file(config, file) }
        if let overlay { ghostty_config_load_file(config, overlay) }
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
        // Themed ones are built again from it, as the surfaces ask. A surface
        // keeps a copy of the config it is given, so these can go.
        for old in themed.values { ghostty_config_free(old) }
        themed = [:]
        // The app's config is what a *new* surface is built from; the ones
        // already open each hold their own and have to be handed it, or a
        // theme picked in Settings showed up only in the next tab.
        NotificationCenter.default.post(name: Self.configReloaded, object: nil)
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
    var backgroundColor: NSColor { themeInForce?.background.nsColor ?? color("background") ?? .windowBackgroundColor }
    var foregroundColor: NSColor { themeInForce?.foreground.nsColor ?? color("foreground") ?? .labelColor }

    /// A single theme is resolved into the config and `color` reads it
    /// there. A pair (`theme = light:…,dark:…`) is not: libghostty resolves
    /// it per surface, and the config keeps the light half whatever macOS
    /// says — which would dress the window in daylight colours around a
    /// dark terminal. So for a pair, the theme file is read.
    private var themeInForce: TerminalTheme? {
        guard Settings.shared.followsSystemAppearance else { return nil }
        let name = Settings.shared.themeName(dark: colorScheme == GHOSTTY_COLOR_SCHEME_DARK)
        guard !name.isEmpty else { return nil }
        return ThemeCatalog.read(name)
    }

    /// An ANSI colour of the theme in force (0–15: the 16 a theme names).
    func paletteColor(_ index: Int) -> NSColor? {
        if let theme = themeInForce { return theme.ansi(index).nsColor }
        guard let config, (0..<256).contains(index) else { return nil }
        var palette = ghostty_config_palette_s()
        guard ghostty_config_get(config, &palette, "palette", UInt("palette".utf8.count)) else { return nil }
        return withUnsafeBytes(of: &palette.colors) { raw in
            let colour = raw.bindMemory(to: ghostty_config_color_s.self)[index]
            return NSColor(srgbRed: CGFloat(colour.r) / 255, green: CGFloat(colour.g) / 255, blue: CGFloat(colour.b) / 255, alpha: 1)
        }
    }

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
    /// those stay unhandled until Overterm has them.
    private func perform(target: ghostty_target_s, action: ghostty_action_s) -> Bool {
        let view: TerminalView? = target.tag == GHOSTTY_TARGET_SURFACE ? TerminalView.from(surface: target.target.surface) : nil
        let window = view?.window?.windowController as? TerminalWindowController

        switch action.tag {
        // Tabs are Overterm's, not Ghostty's — but the user's Ghostty keybinds
        // for them (cmd+t, cmd+shift+], goto_tab:N, ...) still drive ours.
        case GHOSTTY_ACTION_NEW_TAB:
            guard let window else { return false }
            window.newTab(from: view)
            return true

        // Splits are Overterm's too; Ghostty's keybinds (cmd+d, cmd+[, …) drive them.
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

        // Ghostty's ⌘, (open_config): Overterm's Settings, not a text file.
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

        // Where the viewport sits in the scrollback, pushed whenever it
        // moves. There is no way to ask — this action is the only one.
        case GHOSTTY_ACTION_SCROLLBAR:
            guard let view else { return false }
            let bar = action.action.scrollbar
            view.onEvent?(.scrolled(total: bar.total, offset: bar.offset, rows: bar.len))
            return true

        // The URL under the pointer, or nil when it leaves one. The action
        // carries no rectangle, so where it is on screen stays the pointer's
        // last position.
        case GHOSTTY_ACTION_MOUSE_OVER_LINK:
            guard let view else { return false }
            let link = action.action.mouse_over_link
            let url = link.url.flatMap { String(data: Data(bytes: $0, count: Int(link.len)), encoding: .utf8) }
            view.onEvent?(.linkHover(url?.isEmpty == true ? nil : url))
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
        // so select-to-copy / middle-click-paste work inside Overterm.
        case GHOSTTY_CLIPBOARD_SELECTION: NSPasteboard(name: .init("\(AppEnvironment.bundleIdentifier).selection"))
        default: nil
        }
    }

    private static let isolatedClipboard = NSPasteboard(name: .init("\(AppEnvironment.bundleIdentifier).isolated.clipboard"))

    /// A confirmation's text: its text/plain contents.
    nonisolated static func text(of confirm: ghostty_clipboard_confirm_s) -> String {
        guard let contents = confirm.contents else { return "" }
        for i in 0..<confirm.contents_len {
            let content = contents[i]
            guard let mime = content.mime, String(cString: mime) == "text/plain", let data = content.data else { continue }
            return String(decoding: UnsafeRawBufferPointer(start: data, count: content.len), as: UTF8.self)
        }
        return ""
    }

    /// A request libghostty wants confirmed (ClipboardConfirmation): the
    /// terminal's window asks. Allowed, it is completed confirmed with the
    /// text it showed; denied, it is denied — a denied OSC 52 read gets an
    /// empty reply from libghostty, a denied paste doesn't happen.
    /// (Before Ghostty 1.4 there was no deny: a denial was completed
    /// confirmed with nothing, or libghostty asked again, forever.)
    private static func confirmClipboard(
        userdata: UnsafeMutableRawPointer?, text: String, state: UnsafeMutableRawPointer?, request: ghostty_clipboard_request_e
    ) {
        guard let view = TerminalView.from(userdata: userdata), let surface = view.surface else { return }
        let confirmation = ClipboardConfirmation(request: request, text: text)
        let complete: @MainActor (Bool) -> Void = { [weak view] allowed in
            // The pane closed while the sheet was up: the request went with it.
            guard let view, view.surface == surface else { return }
            switch confirmation?.reply(allowed: allowed) ?? .deny {
            case .hand(let text): GhosttyRuntime.complete(surface, text: text, state: state, confirmed: true)
            case .deny: ghostty_surface_deny_clipboard_request(surface, state)
            }
        }
        guard let confirmation, let window = view.window?.windowController as? TerminalWindowController else { return complete(false) }
        window.confirmClipboard(confirmation, from: view, answer: complete)
    }

    /// Completes a request with `text` as its one text/plain contents, and
    /// says text/plain is what there is when it asked for a listing.
    static func complete(_ surface: ghostty_surface_t, text: String?, state: UnsafeMutableRawPointer?, confirmed: Bool, list: Bool = false) {
        "text/plain".withCString { mime in
            var available: [UnsafePointer<CChar>?] = list && text != nil ? [mime] : []
            let finish: (UnsafePointer<ghostty_clipboard_content_s>?, Int) -> Void = { contents, count in
                available.withUnsafeMutableBufferPointer { availableBuffer in
                    var complete = ghostty_clipboard_complete_s(
                        contents: contents, contents_len: count, available: UnsafePointer(availableBuffer.baseAddress), available_len: availableBuffer.count,
                        confirmed: confirmed, remember: false)
                    ghostty_surface_complete_clipboard_request(surface, &complete, state)
                }
            }
            guard let text else { return finish(nil, 0) }
            var bytes = Array(text.utf8)
            bytes.withUnsafeMutableBufferPointer { buffer in
                buffer.baseAddress!.withMemoryRebound(to: CChar.self, capacity: max(buffer.count, 1)) { data in
                    var content = ghostty_clipboard_content_s(mime: mime, data: data, len: buffer.count)
                    finish(&content, 1)
                }
            }
        }
    }

    private static func writeClipboard(_ location: ghostty_clipboard_e, content: UnsafePointer<ghostty_clipboard_content_s>?, count: Int) {
        guard let content, count > 0, let pasteboard = pasteboard(location) else { return }
        for i in 0..<count where content[i].mime != nil && content[i].data != nil {
            guard String(cString: content[i].mime) == "text/plain" else { continue }
            pasteboard.clearContents()
            // Its length is said (1.4): binary-safe, not NUL-terminated.
            pasteboard.setString(
                String(decoding: UnsafeRawBufferPointer(start: content[i].data, count: content[i].len), as: UTF8.self), forType: .string)
            return
        }
    }
}
