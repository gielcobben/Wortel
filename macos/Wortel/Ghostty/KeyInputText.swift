import AppKit

// The parts of the keyboard path (`SurfaceView.keyDown`, `insertText`) that
// decide what text goes with a key, pulled out of the view so they can be
// tested without an app, a surface or an input method. Each is a port of a
// fix Ghostty.app made in its Swift layer after v1.3.1, the version
// `GhosttyInput.swift` was ported from; the commit is named on each.

enum KeyInputText {
    /// `text` as the text of a key event for libghostty, or nil when there is
    /// none to send: empty, or starting with an ASCII control character. Those
    /// libghostty encodes itself from the key and its modifiers, which is what
    /// keeps them reportable to a program using the kitty keyboard protocol
    /// (an agent does): sent as text, ⌃↩ did the wrong thing. DEL (0x7F) is
    /// one of them, and only C0 was checked, so a key whose characters were
    /// DEL went to libghostty as text instead of as the key (Ghostty
    /// f4309055f, issue 13869).
    static func keyEventText(_ text: String?) -> String? {
        guard let text, !text.isEmpty, !startsWithControlCharacter(text) else { return nil }
        return text
    }

    /// True when the first scalar is C0 (below 0x20) or DEL.
    static func startsWithControlCharacter(_ text: String) -> Bool {
        guard let scalar = text.unicodeScalars.first else { return false }
        return scalar.value < 0x20 || scalar.value == 0x7F
    }

    /// True when `text` is one C0 control character and an input method is
    /// composing (or just stopped, with this key). The key is the input
    /// method's: Japanese input uses ⌃H, ⌃J, ⌃M and ⌃N to edit and convert
    /// what is being composed, and each one also reached the program as a
    /// backspace, a line feed or a Return (Ghostty a43cc02eb). DEL is not
    /// included, as upstream: ⌫ while composing already reaches libghostty
    /// marked as composing and is not encoded.
    static func isComposingControl(_ text: String?, composing: Bool) -> Bool {
        guard composing, let text else { return false }
        let scalars = text.unicodeScalars
        guard let scalar = scalars.first,
              scalars.index(after: scalars.startIndex) == scalars.endIndex
        else { return false }
        return scalar.value < 0x20
    }

    /// Whether the key that made an input method commit what it was
    /// composing should still reach the program after the committed text.
    /// Only the arrows: a Korean input method commits the syllable on an
    /// arrow and the cursor should then move (Ghostty fa141a726). Every
    /// other key that commits (Return, ⌃J or a space in Japanese input) was
    /// the input method's, and replayed it sent the program a Return or a
    /// line feed after the text (Ghostty d60a16c14). A plain ← is not
    /// replayed either: AppKit leaves the caret where it was after a Korean
    /// commit, and replayed it stepped back over the syllable just typed.
    static func replaysKeyAfterCommit(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
        switch keyCode {
        case 0x7C, 0x7D, 0x7E: // kVK_RightArrow, kVK_DownArrow, kVK_UpArrow
            return true
        case 0x7B: // kVK_LeftArrow
            return !modifiers.isDisjoint(with: [.shift, .control, .option, .command])
        default:
            return false
        }
    }
}

/// Joins a character beyond the Basic Multilingual Plane that an input method
/// hands over in two halves. Unicode Hex Input does: ⌥ with D83D, then ⌥ with
/// DE00, arrive as two `insertText` calls of one UTF-16 surrogate each, and
/// each half alone became U+FFFD in the terminal instead of 😀 (Ghostty
/// f0e3be3ee). A trail with no lead before it is dropped, as Terminal.app
/// does; any other text forgets a waiting lead.
struct SurrogatePairing {
    private var lead: UTF16.CodeUnit?

    /// The text to insert for `string`: "" while a lead waits for its trail.
    mutating func text(for string: NSString) -> String {
        if string.length == 1 {
            let unit = string.character(at: 0)
            if UTF16.isLeadSurrogate(unit) {
                lead = unit
                return ""
            }
            if UTF16.isTrailSurrogate(unit) {
                defer { lead = nil }
                guard let lead else { return "" }
                return String(decoding: [lead, unit], as: UTF16.self)
            }
        }
        lead = nil
        return string as String
    }
}
