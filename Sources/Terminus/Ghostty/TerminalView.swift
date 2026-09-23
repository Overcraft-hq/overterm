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

    /// Last directory the shell reported (OSC 7 via shell integration);
    /// the starting directory until it reports one.
    var workingDirectory: String?

    var onTitleChange: ((String) -> Void)?
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

    /// - Parameters:
    ///   - workingDirectory: where the shell starts; home when nil.
    ///   - command: run instead of the login shell (e.g. `claude`).
    ///   - fontSize: carry a tab's zoom level over to its sibling; config
    ///     default when nil.
    init(workingDirectory: String? = nil, command: String? = nil, fontSize: Float? = nil) {
        // A non-zero initial frame so the renderer's layer has real bounds
        // before the first layout pass.
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))

        guard let app = GhosttyRuntime.shared.app else { return }
        var config = ghostty_surface_config_new()
        config.platform_tag = GHOSTTY_PLATFORM_MACOS
        config.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(nsview: Unmanaged.passUnretained(self).toOpaque()))
        config.userdata = Unmanaged.passUnretained(self).toOpaque()
        config.scale_factor = Double(NSScreen.main?.backingScaleFactor ?? 2)
        config.context = GHOSTTY_SURFACE_CONTEXT_TAB
        if let fontSize { config.font_size = fontSize }

        let cwd = workingDirectory ?? FileManager.default.homeDirectoryForCurrentUser.path
        self.workingDirectory = cwd
        surface = cwd.withCString { cwdPtr in
            config.working_directory = cwdPtr
            guard let command else { return ghostty_surface_new(app, &config) }
            return command.withCString { cmdPtr in
                config.command = cmdPtr
                return ghostty_surface_new(app, &config)
            }
        }
        if surface == nil {
            GhosttyRuntime.logger.error("ghostty_surface_new failed")
        }
        updateTrackingAreas()
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

    /// Hidden tabs stop rendering; libghostty keeps the pty running.
    func setVisible(_ visible: Bool) {
        isHidden = !visible
        if let surface { ghostty_surface_set_occlusion(surface, visible) }
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
        if result { setFocused(true) }
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

    private func performBinding(_ action: String) {
        guard let surface else { return }
        _ = ghostty_surface_binding_action(surface, action, UInt(action.utf8.count))
    }

    // MARK: Clipboard

    func readClipboard(_ location: ghostty_clipboard_e, state: UnsafeMutableRawPointer?) -> Bool {
        guard let surface, let pasteboard = GhosttyRuntime.pasteboard(location) else { return false }
        // Files paste as their (shell-escaped) paths, which is what an agent
        // prompt wants when you drop a screenshot in.
        let string: String
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            string = urls.map { $0.path.replacingOccurrences(of: " ", with: "\\ ") }.joined(separator: " ")
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
