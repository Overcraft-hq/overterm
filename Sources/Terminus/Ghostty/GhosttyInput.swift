import AppKit
import GhosttyKit

/// Translation between AppKit input and libghostty's input structs. Ported
/// from Ghostty's own macOS app (Ghostty.Input.swift, NSEvent+Extension.swift),
/// which is the reference for how libghostty expects to be fed.
enum GhosttyInput {
    static func mods(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var mods = GHOSTTY_MODS_NONE.rawValue
        if flags.contains(.shift) { mods |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.control) { mods |= GHOSTTY_MODS_CTRL.rawValue }
        if flags.contains(.option) { mods |= GHOSTTY_MODS_ALT.rawValue }
        if flags.contains(.command) { mods |= GHOSTTY_MODS_SUPER.rawValue }
        if flags.contains(.capsLock) { mods |= GHOSTTY_MODS_CAPS.rawValue }

        // Sided modifiers, so bindings like right-option-as-alt work.
        let raw = flags.rawValue
        if raw & UInt(NX_DEVICERSHIFTKEYMASK) != 0 { mods |= GHOSTTY_MODS_SHIFT_RIGHT.rawValue }
        if raw & UInt(NX_DEVICERCTLKEYMASK) != 0 { mods |= GHOSTTY_MODS_CTRL_RIGHT.rawValue }
        if raw & UInt(NX_DEVICERALTKEYMASK) != 0 { mods |= GHOSTTY_MODS_ALT_RIGHT.rawValue }
        if raw & UInt(NX_DEVICERCMDKEYMASK) != 0 { mods |= GHOSTTY_MODS_SUPER_RIGHT.rawValue }
        return ghostty_input_mods_e(mods)
    }

    static func modifierFlags(_ mods: ghostty_input_mods_e) -> NSEvent.ModifierFlags {
        var flags = NSEvent.ModifierFlags()
        if mods.rawValue & GHOSTTY_MODS_SHIFT.rawValue != 0 { flags.insert(.shift) }
        if mods.rawValue & GHOSTTY_MODS_CTRL.rawValue != 0 { flags.insert(.control) }
        if mods.rawValue & GHOSTTY_MODS_ALT.rawValue != 0 { flags.insert(.option) }
        if mods.rawValue & GHOSTTY_MODS_SUPER.rawValue != 0 { flags.insert(.command) }
        return flags
    }

    /// Packed scroll mods: bit 0 = precise (trackpad), bits 1-3 = momentum phase.
    static func scrollMods(_ event: NSEvent) -> ghostty_input_scroll_mods_t {
        var value: Int32 = event.hasPreciseScrollingDeltas ? 1 : 0
        let momentum: ghostty_input_mouse_momentum_e
        switch event.momentumPhase {
        case .began: momentum = GHOSTTY_MOUSE_MOMENTUM_BEGAN
        case .stationary: momentum = GHOSTTY_MOUSE_MOMENTUM_STATIONARY
        case .changed: momentum = GHOSTTY_MOUSE_MOMENTUM_CHANGED
        case .ended: momentum = GHOSTTY_MOUSE_MOMENTUM_ENDED
        case .cancelled: momentum = GHOSTTY_MOUSE_MOMENTUM_CANCELLED
        case .mayBegin: momentum = GHOSTTY_MOUSE_MOMENTUM_MAY_BEGIN
        default: momentum = GHOSTTY_MOUSE_MOMENTUM_NONE
        }
        value |= Int32(momentum.rawValue) << 1
        return ghostty_input_scroll_mods_t(value)
    }

    static func mouseButton(_ buttonNumber: Int) -> ghostty_input_mouse_button_e {
        switch buttonNumber {
        case 0: GHOSTTY_MOUSE_LEFT
        case 1: GHOSTTY_MOUSE_RIGHT
        case 2: GHOSTTY_MOUSE_MIDDLE
        default: GHOSTTY_MOUSE_UNKNOWN
        }
    }
}

extension NSEvent {
    /// A libghostty key event without `text`/`composing` — the caller sets
    /// those, since `text` is a C string whose lifetime it has to own.
    func ghosttyKeyEvent(_ action: ghostty_input_action_e, translationMods: NSEvent.ModifierFlags? = nil) -> ghostty_input_key_s {
        var ev = ghostty_input_key_s()
        ev.action = action
        ev.keycode = UInt32(keyCode)
        ev.text = nil
        ev.composing = false
        ev.mods = GhosttyInput.mods(modifierFlags)
        // Control and command never contribute to text translation; assume the
        // rest did. Ghostty's heuristic, not ours.
        ev.consumed_mods = GhosttyInput.mods((translationMods ?? modifierFlags).subtracting([.control, .command]))
        ev.unshifted_codepoint = 0
        if type == .keyDown || type == .keyUp,
            let chars = characters(byApplyingModifiers: []),
            let scalar = chars.unicodeScalars.first
        {
            ev.unshifted_codepoint = scalar.value
        }
        return ev
    }

    /// The text to send with a key event. Control characters are encoded by
    /// libghostty itself, and function keys arrive in the private-use area, so
    /// neither is passed through as text.
    var ghosttyCharacters: String? {
        guard let characters else { return nil }
        if characters.count == 1, let scalar = characters.unicodeScalars.first {
            if scalar.value < 0x20 {
                return self.characters(byApplyingModifiers: modifierFlags.subtracting(.control))
            }
            if scalar.value >= 0xF700 && scalar.value <= 0xF8FF {
                return nil
            }
        }
        return characters
    }
}
