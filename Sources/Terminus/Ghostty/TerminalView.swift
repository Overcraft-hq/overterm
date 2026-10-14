import AppKit
import GhosttyKit

/// One terminal: an NSView that owns a libghostty surface (a pty + its
/// renderer) and feeds it keyboard, IME, mouse, focus and size.
///
/// Input handling is ported from Ghostty's SurfaceView_AppKit.swift — the
/// AppKit key path (performKeyEquivalent → keyDown → interpretKeyEvents →
/// NSTextInputClient) has enough traps that we follow the reference closely
/// rather than simplify it.
@MainActor
final class TerminalView: NSView {
    private(set) var surface: ghostty_surface_t?

    /// Find-in-terminal (⌘F) for this terminal.
    private(set) lazy var search = TerminalSearch(terminal: self)

    /// Put in the shell's environment as TERMINUS_TAB_ID; every process
    /// started from this terminal inherits it, which is how Tab Info finds
    /// them (ProcessInspector).
    let processTag = UUID().uuidString

    /// Last directory the shell reported (OSC 7 via shell integration);
    /// the starting directory until it reports one.
    var workingDirectory: String? {
        didSet {
            if let workingDirectory, workingDirectory != oldValue { onWorkingDirectoryChange?(workingDirectory) }
        }
    }
    /// The shell has reported a directory at least once: its integration is
    /// loaded and it drew a prompt. Keys typed before that can be lost.
    private(set) var shellReported = false
    /// When it first did.
    private(set) var shellReportedAt: Date?
    func markShellReported() {
        if !shellReported { shellReportedAt = Date() }
        shellReported = true
    }

    var onTitleChange: ((String) -> Void)?
    /// What the shell last set as the title (OSC 0/2).
    var title: String?
    /// It took the keyboard: in a split, it is now the focused pane.
    var onFocus: (() -> Void)?
    var onWorkingDirectoryChange: ((String) -> Void)?
    /// ⌘F (Ghostty's start_search), with any needle it carries. The window
    /// answers with its search overlay; unset, the compact bar opens.
    var onSearchRequest: ((String?) -> Void)?
    /// A ⌘-clicked link, as libghostty matched it; true when handled (a
    /// file opened in the editor), else it goes to the system opener.
    var onOpenLink: ((String) -> Bool)?
    /// Bell, desktop notification, progress, long command finished.
    var onEvent: ((TerminalEvent) -> Void)?
    /// Called when the surface asks to close — the process exited, or the user
    /// pressed a close binding. The argument is whether the process is alive.
    var onClose: ((Bool) -> Void)?

    private var focused = false
    private var markedText = NSMutableAttributedString()
    /// Non-nil only while inside keyDown: text produced by interpretKeyEvents
    /// is collected here and sent as that key's text, not as a paste.
    private var keyTextAccumulator: [String]?
    /// See performKeyEquivalent: identifies a command/control event we let
    /// AppKit look at first and must route back to keyDown if nobody took it.
    private var lastPerformKeyEvent: TimeInterval?
    private var cursorShape: NSCursor = .iBeam

    /// Over the pane while something is dragged onto it.
    private(set) var dropHighlight: DropHighlightView?
    /// What the drag hovering over the pane carries.
    private var dropPayload: TerminalDrop.Payload?
    /// What runs in the pane, as last looked at: the highlight's label
    /// follows it. A drop looks again.
    private(set) var dropProgram: TerminalDrop.Program = .other
    /// Drops not typed in yet, in the order they came. Each waits for a
    /// look at the pane, or for its promised files: none may overtake one
    /// before it.
    private var pendingDrops: [(id: Int, text: String?)] = []
    private var lastDropID = 0
    /// A drop is still to be typed in.
    var hasPendingDrops: Bool { !pendingDrops.isEmpty }
    /// The modifier keys, read when a drag moves and at the drop (⌥: plain
    /// paths). An E2E run stands in for the keyboard.
    static var dropModifierFlags: () -> NSEvent.ModifierFlags = { NSEvent.modifierFlags }
    /// Where panes look at what runs in them: one scan at a time, so the
    /// answers come back in the order asked.
    private static let programQueue = DispatchQueue(label: "\(AppEnvironment.bundleIdentifier).pane-program", qos: .userInitiated)

    /// - Parameters:
    ///   - workingDirectory: where the shell starts; home when nil.
    ///   - initialInput: typed into the shell once it starts (e.g.
    ///     `claude\n`). The shell stays when that program exits, unlike
    ///     running it as the surface's command.
    ///   - fontSize: carry a tab's zoom level over to its sibling; config
    ///     default when nil.
    ///   - restoring: a pane's saved text (Scrollback) to print before the
    ///     shell starts; ignored for a shell the launcher can't front.
    init(workingDirectory: String? = nil, initialInput: String? = nil, fontSize: Float? = nil, restoring: URL? = nil) {
        // A non-zero initial frame so the renderer's layer has real bounds
        // before the first layout pass.
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        registerForDraggedTypes(TerminalDrop.draggedTypes)
        // Tab peek's three fingers. Trackpad touches are routed like mouse
        // events, so the pane under the pointer is where a swipe begins.
        allowedTouchTypes = [.indirect]

        let cwd = workingDirectory ?? FileManager.default.homeDirectoryForCurrentUser.path
        self.workingDirectory = cwd
        guard let app = GhosttyRuntime.shared.app else { return }
        var config = ghostty_surface_config_new()
        config.platform_tag = GHOSTTY_PLATFORM_MACOS
        config.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(nsview: Unmanaged.passUnretained(self).toOpaque()))
        config.userdata = Unmanaged.passUnretained(self).toOpaque()
        config.scale_factor = Double(NSScreen.main?.backingScaleFactor ?? 2)
        config.context = GHOSTTY_SURFACE_CONTEXT_TAB
        if let fontSize { config.font_size = fontSize }

        // The C strings only need to outlive ghostty_surface_new, which
        // copies them.
        let cwdC = strdup(cwd)
        let inputC = initialInput.map { strdup($0) }
        defer {
            free(cwdC)
            inputC.map { free($0) }
        }
        config.working_directory = UnsafePointer(cwdC)
        config.initial_input = inputC.flatMap { UnsafePointer($0) }
        let tagKey = strdup(ProcessInspector.tagVariable)
        let tagValue = strdup(processTag)
        defer {
            free(tagKey)
            free(tagValue)
        }
        var env = [ghostty_env_var_s(key: tagKey, value: tagValue)]
        // A restored pane runs the launcher (named after the shell) instead.
        let launcher = restoring.flatMap { _ in Scrollback.launcher() }
        let commandC = launcher.map { strdup($0) }
        let restoreKey = strdup(Scrollback.fileVariable)
        let restoreValue = restoring.map { strdup($0.path) }
        defer {
            commandC.map { free($0) }
            free(restoreKey)
            restoreValue.map { free($0) }
        }
        if let commandC, let restoreValue {
            config.command = UnsafePointer(commandC)
            env.append(ghostty_env_var_s(key: restoreKey, value: restoreValue))
        }
        surface = env.withUnsafeMutableBufferPointer { buffer in
            config.env_vars = buffer.baseAddress
            config.env_var_count = buffer.count
            return ghostty_surface_new(app, &config)
        }
        if surface == nil {
            GhosttyRuntime.logger.error("ghostty_surface_new failed")
        } else {
            SurfaceProcesses.shared.register(self)
            applyColorScheme()
            NotificationCenter.default.addObserver(
                self, selector: #selector(applyColorScheme), name: GhosttyRuntime.colorSchemeChanged, object: nil)
        }
        updateTrackingAreas()
    }

    /// Which half of a `light:…,dark:…` theme this surface shows. A
    /// surface keeps its own colour scheme, so it is told even though the
    /// app has been (`GhosttyRuntime.setColorScheme`).
    @objc private func applyColorScheme() {
        guard let surface else { return }
        ghostty_surface_set_color_scheme(surface, GhosttyRuntime.shared.colorScheme)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Frees the surface, which also ends its pty. Call before dropping the
    /// view; libghostty holds a raw pointer to it until then.
    func close() {
        guard let surface else { return }
        self.surface = nil
        ghostty_surface_free(surface)
    }

    /// What a new tab opened from this one should start with: the shell's
    /// current directory and this tab's font size.
    func inheritedSettings() -> (workingDirectory: String?, fontSize: Float?) {
        guard let surface else { return (workingDirectory, nil) }
        let config = ghostty_surface_inherited_config(surface, GHOSTTY_SURFACE_CONTEXT_TAB)
        let cwd = config.working_directory.map { String(cString: $0) } ?? workingDirectory
        return (cwd, config.font_size > 0 ? config.font_size : nil)
    }

    /// Types `text` into the terminal as if pasted (bracketed-paste aware),
    /// without pressing return.
    func insertText(_ text: String) {
        guard let surface else { return }
        text.withCString { ptr in
            ghostty_surface_text(surface, ptr, UInt(text.utf8.count))
        }
    }

    /// Presses Return. Needed to run something typed with insertText: with
    /// bracketed paste on, a newline inside the pasted text is literal.
    func pressReturn() {
        guard let surface else { return }
        var ev = ghostty_input_key_s()
        ev.keycode = 0x24  // kVK_Return
        ev.mods = GHOSTTY_MODS_NONE
        ev.consumed_mods = GHOSTTY_MODS_NONE
        ev.unshifted_codepoint = 0x0D
        ev.action = GHOSTTY_ACTION_PRESS
        _ = ghostty_surface_key(surface, ev)
        ev.action = GHOSTTY_ACTION_RELEASE
        _ = ghostty_surface_key(surface, ev)
    }

    /// Hidden tabs stop rendering; libghostty keeps the pty running.
    /// Becoming visible draws a frame at once, so nothing stale is shown.
    func setVisible(_ visible: Bool) {
        isHidden = !visible
        if let surface { ghostty_surface_set_occlusion(surface, visible) }
    }

    /// Shown, but still occluded: the renderer thread stays asleep and
    /// whoever asked for this draws the pane itself (`drawNow`). Tab peek
    /// uses it past its live limit, so twenty previews don't all run at
    /// full rate.
    func setPreviewing(_ previewing: Bool) {
        isHidden = !previewing
    }

    /// One frame, now, on this thread — the only way to refresh an occluded
    /// surface (libghostty's renderer skips the draw while it is hidden).
    func drawNow() {
        guard let surface, !frame.isEmpty else { return }
        ghostty_surface_draw(surface)
    }

    /// Whether the shell/command has exited (as opposed to a close being
    /// requested while it runs).
    var processExited: Bool {
        guard let surface else { return true }
        return ghostty_surface_process_exited(surface)
    }

    /// Whether closing now would kill a running process (per the user's
    /// confirm-close-surface config).
    var needsConfirmClose: Bool {
        guard let surface else { return false }
        return ghostty_surface_needs_confirm_quit(surface)
    }

    static func from(userdata: UnsafeMutableRawPointer?) -> TerminalView? {
        guard let userdata else { return nil }
        return Unmanaged<TerminalView>.fromOpaque(userdata).takeUnretainedValue()
    }

    static func from(surface: ghostty_surface_t?) -> TerminalView? {
        guard let surface else { return nil }
        return from(userdata: ghostty_surface_userdata(surface))
    }

    // MARK: Focus and size

    override var acceptsFirstResponder: Bool { true }

    /// The window is full-size-content; a click in the terminal must never
    /// start a window drag.
    override var mouseDownCanMoveWindow: Bool { false }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result {
            setFocused(true)
            onFocus?()
        }
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result { setFocused(false) }
        return result
    }

    private func setFocused(_ value: Bool) {
        guard focused != value, let surface else { return }
        focused = value
        ghostty_surface_set_focus(surface, value)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateSurfaceSize()
        dropHighlight?.frame = frame
    }

    override func setFrameOrigin(_ newOrigin: NSPoint) {
        super.setFrameOrigin(newOrigin)
        dropHighlight?.frame = frame
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if let window {
            // We scale the framebuffer ourselves; stop the compositor from also
            // scaling (and animating) the layer contents.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer?.contentsScale = window.backingScaleFactor
            CATransaction.commit()
        }
        guard let surface, frame.width > 0, frame.height > 0 else { return }
        let backing = convertToBacking(frame)
        ghostty_surface_set_content_scale(surface, backing.width / frame.width, backing.height / frame.height)
        updateSurfaceSize()
    }

    private func updateSurfaceSize() {
        guard let surface else { return }
        let backing = convertToBacking(bounds.size)
        guard backing.width > 0, backing.height > 0 else { return }
        ghostty_surface_set_size(surface, UInt32(backing.width), UInt32(backing.height))
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(
            NSTrackingArea(
                rect: frame,
                options: [.mouseEnteredAndExited, .mouseMoved, .inVisibleRect, .activeAlways],
                owner: self,
                userInfo: nil))
        super.updateTrackingAreas()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: cursorShape)
    }

    func setMouseShape(_ shape: ghostty_action_mouse_shape_e) {
        switch shape {
        case GHOSTTY_MOUSE_SHAPE_POINTER: cursorShape = .pointingHand
        case GHOSTTY_MOUSE_SHAPE_TEXT: cursorShape = .iBeam
        default: cursorShape = .arrow
        }
        window?.invalidateCursorRects(for: self)
    }

    override func mouseDown(with event: NSEvent) {
        if !focused { window?.makeFirstResponder(self) }
        sendMouseButton(GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, event)
    }

    override func mouseUp(with event: NSEvent) {
        sendMouseButton(GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, event)
        if let surface { ghostty_surface_mouse_pressure(surface, 0, 0) }
        // After libghostty has seen the release, so the selection it
        // reports is the finished one.
        DispatchQueue.main.async { [weak self] in self?.onSelectionChanged?() }
    }

    override func rightMouseDown(with event: NSEvent) {
        if !sendMouseButton(GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT, event) { super.rightMouseDown(with: event) }
    }

    override func rightMouseUp(with event: NSEvent) {
        if !sendMouseButton(GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_RIGHT, event) { super.rightMouseUp(with: event) }
    }

    override func otherMouseDown(with event: NSEvent) {
        sendMouseButton(GHOSTTY_MOUSE_PRESS, GhosttyInput.mouseButton(event.buttonNumber), event)
    }

    override func otherMouseUp(with event: NSEvent) {
        sendMouseButton(GHOSTTY_MOUSE_RELEASE, GhosttyInput.mouseButton(event.buttonNumber), event)
    }

    @discardableResult
    private func sendMouseButton(_ state: ghostty_input_mouse_state_e, _ button: ghostty_input_mouse_button_e, _ event: NSEvent) -> Bool {
        guard let surface else { return false }
        return ghostty_surface_mouse_button(surface, state, button, GhosttyInput.mods(event.modifierFlags))
    }

    override func mouseMoved(with event: NSEvent) {
        guard let surface else { return }
        // AppKit is bottom-left origin; libghostty is top-left.
        let pos = convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(surface, pos.x, frame.height - pos.y, GhosttyInput.mods(event.modifierFlags))
    }

    override func mouseDragged(with event: NSEvent) { mouseMoved(with: event) }
    override func rightMouseDragged(with event: NSEvent) { mouseMoved(with: event) }
    override func otherMouseDragged(with event: NSEvent) { mouseMoved(with: event) }
    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }

    override func mouseExited(with event: NSEvent) {
        // Keep reporting while a drag leaves the view (selection).
        guard let surface, NSEvent.pressedMouseButtons == 0 else { return }
        ghostty_surface_mouse_pos(surface, -1, -1, GhosttyInput.mods(event.modifierFlags))
    }

    // MARK: The trackpad

    /// Tab peek watches the trackpad through here: `(fingers, averageY,
    /// ended)`. It answers whether the swipe was its own, which is only ever
    /// true for the configured finger count — two-finger scrolling is a
    /// scroll event and never reaches this at all.
    var onTouches: ((Int, CGFloat, Bool) -> Bool)?

    override func touchesBegan(with event: NSEvent) {
        if !report(event, ended: false) { super.touchesBegan(with: event) }
    }
    override func touchesMoved(with event: NSEvent) {
        if !report(event, ended: false) { super.touchesMoved(with: event) }
    }
    override func touchesEnded(with event: NSEvent) {
        if !report(event, ended: true) { super.touchesEnded(with: event) }
    }
    override func touchesCancelled(with event: NSEvent) {
        if !report(event, ended: true) { super.touchesCancelled(with: event) }
    }

    private func report(_ event: NSEvent, ended: Bool) -> Bool {
        guard let onTouches else { return false }
        let touches = event.touches(matching: .touching, in: self)
        return onTouches(touches.count, TabPeekTouches.averageY(touches), ended)
    }

    override func scrollWheel(with event: NSEvent) {
        guard let surface else { return }
        var x = event.scrollingDeltaX
        var y = event.scrollingDeltaY
        if event.hasPreciseScrollingDeltas {
            // Ghostty's own 2x for trackpads; 1x feels sluggish.
            x *= 2
            y *= 2
        }
        ghostty_surface_mouse_scroll(surface, x, y, GhosttyInput.scrollMods(event))
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        guard let surface else {
            interpretKeyEvents([event])
            return
        }

        // Apply the surface's translation mods (e.g. macos-option-as-alt) to
        // the event we hand to the input method. The original event must be
        // reused when nothing changed — Korean IME depends on identity.
        let translated = GhosttyInput.modifierFlags(ghostty_surface_key_translation_mods(surface, GhosttyInput.mods(event.modifierFlags)))
        var translationMods = event.modifierFlags
        for flag in [NSEvent.ModifierFlags.shift, .control, .option, .command] {
            if translated.contains(flag) { translationMods.insert(flag) } else { translationMods.remove(flag) }
        }
        let translationEvent: NSEvent
        if translationMods == event.modifierFlags {
            translationEvent = event
        } else {
            translationEvent =
                NSEvent.keyEvent(
                    with: event.type,
                    location: event.locationInWindow,
                    modifierFlags: translationMods,
                    timestamp: event.timestamp,
                    windowNumber: event.windowNumber,
                    context: nil,
                    characters: event.characters(byApplyingModifiers: translationMods) ?? "",
                    charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
                    isARepeat: event.isARepeat,
                    keyCode: event.keyCode
                ) ?? event
        }

        let action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS
        keyTextAccumulator = []
        defer { keyTextAccumulator = nil }
        let markedTextBefore = markedText.length > 0
        lastPerformKeyEvent = nil

        interpretKeyEvents([translationEvent])
        syncPreedit(clearIfNeeded: markedTextBefore)

        if let texts = keyTextAccumulator, !texts.isEmpty {
            for text in texts {
                sendKey(action, event: event, translationEvent: translationEvent, text: text)
            }
        } else {
            sendKey(
                action, event: event, translationEvent: translationEvent,
                text: translationEvent.ghosttyCharacters,
                // Also composing when preedit was just cleared (e.g. backspace
                // cancelling a Japanese composition must not delete a char).
                composing: markedText.length > 0 || markedTextBefore)
        }
    }

    override func keyUp(with event: NSEvent) {
        sendKey(GHOSTTY_ACTION_RELEASE, event: event)
    }

    override func flagsChanged(with event: NSEvent) {
        let mod: UInt32
        switch event.keyCode {
        case 0x39: mod = GHOSTTY_MODS_CAPS.rawValue
        case 0x38, 0x3C: mod = GHOSTTY_MODS_SHIFT.rawValue
        case 0x3B, 0x3E: mod = GHOSTTY_MODS_CTRL.rawValue
        case 0x3A, 0x3D: mod = GHOSTTY_MODS_ALT.rawValue
        case 0x37, 0x36: mod = GHOSTTY_MODS_SUPER.rawValue
        default: return
        }
        if hasMarkedText() { return }

        var action = GHOSTTY_ACTION_RELEASE
        if GhosttyInput.mods(event.modifierFlags).rawValue & mod != 0 {
            // A press only if the side that changed is the one now held.
            let raw = event.modifierFlags.rawValue
            let sidePressed: Bool =
                switch event.keyCode {
                case 0x3C: raw & UInt(NX_DEVICERSHIFTKEYMASK) != 0
                case 0x3E: raw & UInt(NX_DEVICERCTLKEYMASK) != 0
                case 0x3D: raw & UInt(NX_DEVICERALTKEYMASK) != 0
                case 0x36: raw & UInt(NX_DEVICERCMDKEYMASK) != 0
                default: true
                }
            if sidePressed { action = GHOSTTY_ACTION_PRESS }
        }
        sendKey(action, event: event)
    }

    /// Command/control keys reach us here before the menu and before keyDown.
    /// A Ghostty binding (copy, paste, font size, ...) is handled right away.
    /// Anything else goes to the menu first; if nothing takes it, AppKit
    /// comes back via doCommand and we route it to keyDown by timestamp.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, focused, let surface else { return false }

        var isBinding = false
        var ghosttyEvent = event.ghosttyKeyEvent(GHOSTTY_ACTION_PRESS)
        (event.characters ?? "").withCString { ptr in
            ghosttyEvent.text = ptr
            var flags = ghostty_binding_flags_e(0)
            isBinding = ghostty_surface_key_is_binding(surface, ghosttyEvent, &flags)
        }
        if isBinding {
            keyDown(with: event)
            return true
        }

        let equivalent: String
        switch event.charactersIgnoringModifiers {
        case "\r":
            // ctrl+return goes to the terminal verbatim, not to a menu default.
            guard event.modifierFlags.contains(.control) else { return false }
            equivalent = "\r"
        case "/":
            // ctrl+/ is ctrl+_ (and would otherwise beep).
            guard event.modifierFlags.contains(.control),
                event.modifierFlags.isDisjoint(with: [.shift, .command, .option])
            else { return false }
            equivalent = "_"
        default:
            // Synthetic events (zero timestamp) come from AppKit itself.
            if event.timestamp == 0 { return false }
            if !event.modifierFlags.contains(.command) && !event.modifierFlags.contains(.control) {
                lastPerformKeyEvent = nil
                return false
            }
            if let last = lastPerformKeyEvent {
                lastPerformKeyEvent = nil
                if last == event.timestamp {
                    equivalent = event.characters ?? ""
                    break
                }
            }
            lastPerformKeyEvent = event.timestamp
            return false
        }

        guard
            let final = NSEvent.keyEvent(
                with: .keyDown,
                location: event.locationInWindow,
                modifierFlags: event.modifierFlags,
                timestamp: event.timestamp,
                windowNumber: event.windowNumber,
                context: nil,
                characters: equivalent,
                charactersIgnoringModifiers: equivalent,
                isARepeat: event.isARepeat,
                keyCode: event.keyCode)
        else { return false }
        keyDown(with: final)
        return true
    }

    private func sendKey(
        _ action: ghostty_input_action_e, event: NSEvent, translationEvent: NSEvent? = nil,
        text: String? = nil, composing: Bool = false
    ) {
        guard let surface else { return }
        var ev = event.ghosttyKeyEvent(action, translationMods: translationEvent?.modifierFlags)
        ev.composing = composing
        // Control characters are encoded by libghostty, never sent as text —
        // otherwise ctrl+enter and friends come out wrong.
        if let text, let first = text.utf8.first, first >= 0x20 {
            text.withCString { ptr in
                ev.text = ptr
                _ = ghostty_surface_key(surface, ev)
            }
        } else {
            _ = ghostty_surface_key(surface, ev)
        }
    }

    private func syncPreedit(clearIfNeeded: Bool = true) {
        guard let surface else { return }
        if markedText.length > 0 {
            let string = markedText.string
            string.withCString { ptr in
                ghostty_surface_preedit(surface, ptr, UInt(string.utf8.count))
            }
        } else if clearIfNeeded {
            ghostty_surface_preedit(surface, nil, 0)
        }
    }

    // MARK: Edit menu

    @objc func copy(_ sender: Any?) { performBinding("copy_to_clipboard") }
    @objc func paste(_ sender: Any?) { performBinding("paste_from_clipboard") }
    @objc override func selectAll(_ sender: Any?) { performBinding("select_all") }

    /// Runs a Ghostty binding action by name (`copy_to_clipboard`,
    /// `search:foo`, `navigate_search:next`, …).
    func perform(binding action: String) {
        guard let surface else { return }
        _ = ghostty_surface_binding_action(surface, action, UInt(action.utf8.count))
    }

    private func performBinding(_ action: String) { perform(binding: action) }

    /// The text on screen now (the viewport), one line per row.
    var visibleText: String? { text(of: GHOSTTY_POINT_VIEWPORT) }

    /// Everything the pane holds: scrollback and screen.
    var scrollbackText: String? { text(of: GHOSTTY_POINT_SCREEN) }

    private func text(of region: ghostty_point_tag_e) -> String? {
        guard let surface else { return nil }
        let selection = ghostty_selection_s(
            top_left: ghostty_point_s(tag: region, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0),
            bottom_right: ghostty_point_s(tag: region, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0),
            rectangle: false)
        var text = ghostty_text_s()
        guard ghostty_surface_read_text(surface, selection, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }
        guard let bytes = text.text else { return "" }
        return String(decoding: UnsafeRawBufferPointer(start: bytes, count: Int(text.text_len)), as: UTF8.self)
    }

    // There is no reading an arbitrary row range: `ghostty_selection_s`
    // takes exact points, and libghostty clamps their y to the *active*
    // screen's height before resolving them (`embedded.zig`,
    // `Point.pin`) — so a scrollback row simply cannot be addressed, and
    // asking for rows 27…130 of a 27-row screen reads one row twice.
    // Whole regions are still readable (`scrollbackText`), which is how a
    // command's output is found: by its own prompt line.

    /// What is selected right now, or nil if nothing is. The selection
    /// lives in libghostty — Terminus never had a reason to read it before
    /// (copy goes through Ghostty's own binding).
    var selectionText: String? { selection?.text }

    /// What is selected, and where its top-left corner is in this view.
    ///
    /// The position is the one thing libghostty does give a rectangle for
    /// (`ghostty_text_s.tl_px_x/y`), and only while the selection is on
    /// screen — scrolled out of view it reports (-1, -1), and then there
    /// is nowhere to put a toolbar.
    var selection: (text: String, origin: CGPoint)? {
        guard let surface, ghostty_surface_has_selection(surface) else { return nil }
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }
        guard let bytes = text.text, text.text_len > 0 else { return nil }
        let string = String(decoding: UnsafeRawBufferPointer(start: bytes, count: Int(text.text_len)), as: UTF8.self)
        guard text.tl_px_x >= 0, text.tl_px_y >= 0 else { return (string, .zero) }
        let scale = window?.backingScaleFactor ?? 2
        return (string, CGPoint(x: text.tl_px_x / scale, y: text.tl_px_y / scale))
    }

    /// Called when a drag or a click may have changed the selection.
    var onSelectionChanged: (() -> Void)?

    var hasSelection: Bool {
        guard let surface else { return false }
        return ghostty_surface_has_selection(surface)
    }

    /// One cell, in points. Everything that draws *over* the grid — a block's
    /// frame, the scroll map's marks — turns a row number into a y with it.
    var cellSize: CGSize {
        guard let surface else { return .zero }
        let size = ghostty_surface_size(surface)
        let scale = window?.backingScaleFactor ?? 2
        return CGSize(width: CGFloat(size.cell_width_px) / scale, height: CGFloat(size.cell_height_px) / scale)
    }

    /// How many rows fit on screen, which is what the viewport's height is
    /// measured in.
    var rowCount: Int {
        guard let surface else { return 0 }
        return Int(ghostty_surface_size(surface).rows)
    }

    // MARK: Clipboard

    /// Files paste as their paths, which is what an agent prompt wants when
    /// you paste a screenshot in — quoted as a drop's are: a file named
    /// `x;$(…)` must not become a command once Return is pressed.
    nonisolated static func pastedPaths(_ urls: [URL]) -> String {
        urls.map { TerminalWindowController.shellQuoted($0.path) }.joined(separator: " ")
    }

    func readClipboard(_ location: ghostty_clipboard_e, state: UnsafeMutableRawPointer?) -> Bool {
        guard let surface, let pasteboard = GhosttyRuntime.pasteboard(location) else { return false }
        let string: String
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            string = Self.pastedPaths(urls)
        } else if let text = pasteboard.string(forType: .string) {
            string = text
        } else {
            return false
        }
        string.withCString { ptr in
            ghostty_surface_complete_clipboard_request(surface, ptr, state, false)
        }
        return true
    }
}

// MARK: - NSTextInputClient

extension TerminalView: @preconcurrency NSTextInputClient {
    func hasMarkedText() -> Bool { markedText.length > 0 }

    func markedRange() -> NSRange {
        markedText.length > 0 ? NSRange(location: 0, length: markedText.length) : NSRange()
    }

    func selectedRange() -> NSRange { NSRange() }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        switch string {
        case let v as NSAttributedString: markedText = NSMutableAttributedString(attributedString: v)
        case let v as String: markedText = NSMutableAttributedString(string: v)
        default: return
        }
        // Outside keyDown (e.g. a layout switch mid-composition), push now.
        if keyTextAccumulator == nil { syncPreedit() }
    }

    func unmarkText() {
        guard markedText.length > 0 else { return }
        markedText.mutableString.setString("")
        syncPreedit()
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }

    func characterIndex(for point: NSPoint) -> Int { 0 }

    /// Where the IME candidate window goes: at the terminal cursor.
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let surface else { return .zero }
        var x = 0.0, y = 0.0, width = 0.0, height = 0.0
        ghostty_surface_ime_point(surface, &x, &y, &width, &height)
        let viewRect = NSRect(x: x, y: frame.height - y, width: width, height: height)
        let windowRect = convert(viewRect, to: nil)
        return window?.convertToScreen(windowRect) ?? windowRect
    }

    func insertText(_ string: Any, replacementRange: NSRange) {
        guard NSApp.currentEvent != nil, let surface else { return }
        let chars: String
        switch string {
        case let v as NSAttributedString: chars = v.string
        case let v as String: chars = v
        default: return
        }
        unmarkText()
        if keyTextAccumulator != nil {
            keyTextAccumulator?.append(chars)
            return
        }
        chars.withCString { ptr in
            ghostty_surface_text(surface, ptr, UInt(chars.utf8.count))
        }
    }

    /// Swallows AppKit's default selectors (no beep). If the event was a
    /// command/control key AppKit bounced back from performKeyEquivalent,
    /// re-dispatch it so keyDown encodes it for the terminal.
    override func doCommand(by selector: Selector) {
        if let last = lastPerformKeyEvent, let current = NSApp.currentEvent, last == current.timestamp {
            NSApp.sendEvent(current)
        }
    }
}

// MARK: - Dropping files and text (NSDraggingDestination)

extension TerminalView {
    /// A drag comes over the pane: highlight it, saying what a drop does —
    /// and look at what runs here, which decides that.
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let payload = TerminalDrop.payload(from: sender.draggingPasteboard) else { return [] }
        dropPayload = payload
        showDropHighlight()
        lookAtProgram { [weak self] program in
            guard let self, self.dropPayload != nil else { return }
            self.dropProgram = program
            self.updateDropHighlight()
        }
        return Self.dropOperation(sender)
    }

    /// ⌥ may have been pressed or let go.
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard dropPayload != nil else { return [] }
        updateDropHighlight()
        return Self.dropOperation(sender)
    }

    /// A drop only reads the drag: a copy, where the source allows one.
    private static func dropOperation(_ sender: NSDraggingInfo) -> NSDragOperation {
        let allowed = sender.draggingSourceOperationMask
        return [NSDragOperation.copy, .generic, .link].first { allowed.contains($0) } ?? .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        endDropHover()
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dropPayload != nil
    }

    /// Types the drop's references in, with the keyboard in this pane.
    /// Promised files are written into a drops folder first.
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let plain = Self.dropModifierFlags().contains(.option)
        endDropHover()
        guard surface != nil, let payload = TerminalDrop.payload(from: sender.draggingPasteboard) else { return false }
        window?.makeFirstResponder(self)
        switch payload {
        case .items(let items):
            insertDrop(items, plainPaths: plain, at: reserveDrop())
        case .promises(let promises):
            guard let folder = try? TerminalDrop.newDropFolder() else { return false }
            let place = reserveDrop()
            TerminalDrop.receive(promises, into: folder) { [weak self] files in
                self?.insertDrop(files.map { .file($0, isDirectory: false) }, plainPaths: plain, at: place)
            }
        }
        return true
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        endDropHover()
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        endDropHover()
    }

    /// What runs in the pane now: a scan of its processes off the main
    /// thread, the answer back on it.
    func lookAtProgram(_ done: @escaping @MainActor (TerminalDrop.Program) -> Void) {
        if let login = SurfaceProcesses.shared.pairedLoginPID(of: self) { return Self.scanProgram(login: login, done) }
        // Not paired with its login yet: that lists the app's children, a
        // scan too — made here, off the main thread; the pairing is quick.
        Self.programQueue.async { [weak self] in
            let children = ProcessInspector.children(of: getpid())
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    Self.scanProgram(login: SurfaceProcesses.shared.loginPID(of: self, children: children), done)
                }
            }
        }
    }

    private static func scanProgram(login: pid_t?, _ done: @escaping @MainActor (TerminalDrop.Program) -> Void) {
        programQueue.async {
            let program = TerminalDrop.program(login: login)
            DispatchQueue.main.async { MainActor.assumeIsolated { done(program) } }
        }
    }

    /// Files are written for what runs here, looked at afresh; text and ⌥
    /// need no look.
    private func insertDrop(_ items: [TerminalDrop.Item], plainPaths: Bool, at place: Int) {
        let files = items.contains { if case .file = $0 { true } else { false } }
        guard files, !plainPaths else { return fillDrop(place, TerminalDrop.insertion(items, for: .other, plainPaths: plainPaths)) }
        lookAtProgram { [weak self] program in
            guard let self else { return }
            // Where Claude works, else where the shell last said it is.
            let seen = program == .claude(directory: nil) ? .claude(directory: self.workingDirectory) : program
            self.fillDrop(place, TerminalDrop.insertion(items, for: seen))
        }
    }

    /// Holds a drop's place in the order drops came.
    private func reserveDrop() -> Int {
        lastDropID += 1
        pendingDrops.append((lastDropID, nil))
        return lastDropID
    }

    /// A drop's text is ready: types in every ready one at the front.
    private func fillDrop(_ place: Int, _ text: String) {
        guard let index = pendingDrops.firstIndex(where: { $0.id == place }) else { return }
        pendingDrops[index].text = text
        while let first = pendingDrops.first, let text = first.text {
            pendingDrops.removeFirst()
            if !text.isEmpty { insertText(text) }
        }
    }

    private func showDropHighlight() {
        guard let superview else { return }
        let highlight = dropHighlight ?? DropHighlightView()
        highlight.frame = frame
        // Above the dims of a split's other panes too.
        superview.addSubview(highlight, positioned: .above, relativeTo: nil)
        dropHighlight = highlight
        updateDropHighlight()
    }

    private func updateDropHighlight() {
        guard let dropPayload, let dropHighlight else { return }
        dropHighlight.text = TerminalDrop.label(
            TerminalDrop.labelItems(dropPayload), for: dropProgram, plainPaths: Self.dropModifierFlags().contains(.option))
    }

    private func endDropHover() {
        dropPayload = nil
        dropHighlight?.removeFromSuperview()
        dropHighlight = nil
    }
}
