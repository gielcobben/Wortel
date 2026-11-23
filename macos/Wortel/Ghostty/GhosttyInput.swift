// Portions of this file are ported from Ghostty.app (Ghostty.Input.swift and
// NSEvent+Extension.swift, Ghostty v1.3.1, https://github.com/ghostty-org/ghostty):
//
//     Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors
//     MIT License. The full notice is in THIRD-PARTY-NOTICES.md.
//
// Wortel's changes and additions are GPL-3.0-or-later, like the rest of
// Wortel (LICENSE).

import AppKit
import Carbon
import GhosttyKit

// Input translation helpers, ported from Ghostty.app's Ghostty.Input.swift
// and NSEvent+Extension.swift (Ghostty v1.3.1). Ported mechanically — do not
// "improve": the odd-looking details are load-bearing for IME/dead keys.
// Fixes Ghostty.app made to its keyboard path since then are ported into
// `KeyInputText.swift` and `SurfaceView.keyDown`/`insertText`, not here.

enum GhosttyInput {
    /// Translate NSEvent modifier flags to the ghostty mods bitmask,
    /// including left/right side information.
    static func mods(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var mods: UInt32 = GHOSTTY_MODS_NONE.rawValue

        if flags.contains(.shift) { mods |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.control) { mods |= GHOSTTY_MODS_CTRL.rawValue }
        if flags.contains(.option) { mods |= GHOSTTY_MODS_ALT.rawValue }
        if flags.contains(.command) { mods |= GHOSTTY_MODS_SUPER.rawValue }
        if flags.contains(.capsLock) { mods |= GHOSTTY_MODS_CAPS.rawValue }

        let raw = flags.rawValue
        if raw & UInt(NX_DEVICERSHIFTKEYMASK) != 0 { mods |= GHOSTTY_MODS_SHIFT_RIGHT.rawValue }
        if raw & UInt(NX_DEVICERCTLKEYMASK) != 0 { mods |= GHOSTTY_MODS_CTRL_RIGHT.rawValue }
        if raw & UInt(NX_DEVICERALTKEYMASK) != 0 { mods |= GHOSTTY_MODS_ALT_RIGHT.rawValue }
        if raw & UInt(NX_DEVICERCMDKEYMASK) != 0 { mods |= GHOSTTY_MODS_SUPER_RIGHT.rawValue }

        return ghostty_input_mods_e(mods)
    }

    /// Inverse of `mods` for the four primary flags.
    static func eventModifierFlags(_ mods: ghostty_input_mods_e) -> NSEvent.ModifierFlags {
        var flags = NSEvent.ModifierFlags(rawValue: 0)
        if mods.rawValue & GHOSTTY_MODS_SHIFT.rawValue != 0 { flags.insert(.shift) }
        if mods.rawValue & GHOSTTY_MODS_CTRL.rawValue != 0 { flags.insert(.control) }
        if mods.rawValue & GHOSTTY_MODS_ALT.rawValue != 0 { flags.insert(.option) }
        if mods.rawValue & GHOSTTY_MODS_SUPER.rawValue != 0 { flags.insert(.command) }
        return flags
    }

    /// Pack precision/momentum into ghostty's scroll mods (packed struct on
    /// the Zig side: bit 0 precision, bits 1-3 momentum).
    static func scrollMods(precision: Bool, momentum: NSEvent.Phase) -> ghostty_input_scroll_mods_t {
        var value: Int32 = 0
        if precision { value |= 0b0000_0001 }
        value |= Int32(momentumValue(momentum)) << 1
        return ghostty_input_scroll_mods_t(value)
    }

    private static func momentumValue(_ phase: NSEvent.Phase) -> UInt8 {
        switch phase {
        case .began: return 1
        case .stationary: return 2
        case .changed: return 3
        case .ended: return 4
        case .cancelled: return 5
        case .mayBegin: return 6
        default: return 0
        }
    }

    /// Map an NSEvent otherMouse button number to ghostty's button enum.
    static func mouseButton(fromButtonNumber number: Int) -> ghostty_input_mouse_button_e {
        switch number {
        case 2: return GHOSTTY_MOUSE_MIDDLE
        case 3: return GHOSTTY_MOUSE_FOUR
        case 4: return GHOSTTY_MOUSE_FIVE
        case 5: return GHOSTTY_MOUSE_SIX
        case 6: return GHOSTTY_MOUSE_SEVEN
        case 7: return GHOSTTY_MOUSE_EIGHT
        case 8: return GHOSTTY_MOUSE_NINE
        case 9: return GHOSTTY_MOUSE_TEN
        case 10: return GHOSTTY_MOUSE_ELEVEN
        default: return GHOSTTY_MOUSE_UNKNOWN
        }
    }
}

extension NSEvent {
    /// Create a ghostty key event for a keyboard action. Does not set the
    /// "text" or "composing" fields; those can't be set safely here because
    /// text is a cString whose lifetime the caller must manage.
    func ghosttyKeyEvent(
        _ action: ghostty_input_action_e,
        translationMods: NSEvent.ModifierFlags? = nil
    ) -> ghostty_input_key_s {
        var keyEvent = ghostty_input_key_s()
        keyEvent.action = action
        keyEvent.keycode = UInt32(keyCode)
        keyEvent.text = nil
        keyEvent.composing = false

        // Heuristic from upstream: control and command never contribute to
        // text translation, assume everything else did.
        keyEvent.mods = GhosttyInput.mods(modifierFlags)
        keyEvent.consumed_mods = GhosttyInput.mods(
            (translationMods ?? modifierFlags).subtracting([.control, .command]))

        // Unshifted codepoint: translation with no modifiers applied.
        keyEvent.unshifted_codepoint = 0
        if type == .keyDown || type == .keyUp {
            if let chars = characters(byApplyingModifiers: []),
               let codepoint = chars.unicodeScalars.first {
                keyEvent.unshifted_codepoint = codepoint.value
            }
        }

        return keyEvent
    }

    /// The text to send to ghostty for a key event. Avoids control characters
    /// (ghostty encodes those itself) and PUA function-key codepoints.
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

enum KeyboardLayout {
    /// String ID of the current keyboard input source.
    static var id: String? {
        if let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
           let idPointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) {
            return unsafeBitCast(idPointer, to: CFString.self) as String
        }
        return nil
    }
}
