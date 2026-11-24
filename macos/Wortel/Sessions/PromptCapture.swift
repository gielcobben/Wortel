import Foundation

/// The bytes a terminal sends to a program, read back as the lines the user
/// typed. This is how a session learns its first prompt without any agent's
/// help: Wortel owns the pty, every keystroke passes through it on the way to
/// the agent, and the first substantial line after an agent launches is the
/// prompt every AI app names its conversations from.
///
/// Reconstruction, not recording. The stream carries editing (backspace,
/// ctrl-U, ctrl-W), key escape sequences (arrows, function keys, the kitty
/// keyboard protocol's `CSI … u`), bracketed-paste markers, and the terminal's
/// own replies to the program's queries (cursor position, background colour,
/// version); a prompt is what is left once those have been applied or dropped.
/// It is deliberately approximate: the model that turns a prompt into a title
/// forgives a stray character, and the alternative, a terminal emulator's
/// worth of input handling, would be a second parser for a problem that only
/// needs the gist.
///
/// **One `feed` is one write**, and that is what keeps the replies out.
/// libghostty queues every key press as one message and every reply as
/// another, and its IO thread hands each to `PtyHost.write` whole (a paste is
/// three: the opening marker, the text, the closing marker). So a sequence
/// is normally whole in its write: a reply (`ESC ] 11;rgb:…`, which Claude
/// asks for at launch) is skipped to its end and can't run into the next key,
/// and an ESC alone in its write is the Esc key. Before this, the colour reply became the first "prompt" the next Enter
/// completed, and sessions were named after hex colours. Should a reply ever
/// arrive cut in two, the part already inside it carries on into the next
/// write.
///
/// **A reply can still arrive cut right after its opening.** A session on
/// 2026.47.3 was named `>|ghostty 1.3.1Gi=31;O…`: Claude's XTVERSION and
/// kitty graphics answers, with `ESC P` and `ESC _` each read as a key of its
/// own (Alt+P, Alt+_) and the rest as typing. Fed exactly that split, this
/// builder gave the same line; fed whole, just the prompt. So an opening
/// alone in its write (`ESC P`, or an Esc followed by a write starting with
/// `P`) is *held*: what follows is kept aside until it ends. Ended by
/// anything but BEL or ST (Enter, backspace, an arrow), it was a key and
/// typing after it, and all of it is put back. Ended by BEL or ST, it was a
/// reply, and only what came a character to a write, the way keys come, is
/// put back: so a key pressed in the middle of a reply survives it, and so
/// does typing after Alt+P that ends in ctrl-G (BEL, Claude's editor key).
///
/// Pure and Foundation-only so `PromptCaptureTests` can pin it: every failure
/// here is silent, and the worst of them names a session after an escape
/// sequence.
struct TypedLineBuilder {
    private enum State {
        case normal, escape, csi, ss3
        /// The body of an OSC, DCS, APC, PM or SOS string, which runs to a BEL
        /// or an ST (`ESC \`) rather than to one final byte, and the ESC
        /// inside it.
        case string, stringEscape
    }

    private var line: [UInt8] = []
    private var state: State = .normal
    private var csi: [UInt8] = []
    /// How far into the current string; zero is `ESC ]` and nothing yet.
    private var stringLength = 0
    /// Spans writes, unlike `state`: a paste's markers are writes of their own.
    private var inPaste = false
    /// Esc presses in a row. Two clear an agent's input box (Claude's Esc
    /// Esc), so the line being rebuilt here goes too.
    private var escapes = 0
    /// Non-nil while the string being read began alone in its write, so may be
    /// a key and typing rather than a reply: the text it would put back.
    private var held: [UInt8]?
    /// The part of `held` that came one character to a write: typing, even
    /// if the string turns out to be a reply.
    private var heldTyping: [UInt8] = []
    /// The write being read is one character and nothing else: a key.
    private var writeIsKey = false
    /// The last write ended in an ESC on its own: the Esc key, or a reply's
    /// first byte.
    private var endedInEscape = false

    init() {}

    /// Whether something has been typed that hasn't been sent: the line so
    /// far, or typing held behind an opening, isn't empty. The tests read it
    /// to pin what clears a line.
    var hasDraft: Bool { !line.isEmpty || !heldTyping.isEmpty }

    /// Feed one write to the pty; returns every line completed by it, in order.
    mutating func feed(_ bytes: UnsafeBufferPointer<UInt8>) -> [String] {
        var completed: [String] = []
        var rest = bytes[...]
        writeIsKey = Self.isOneCharacter(bytes)
        // A held string whose last write ended in ESC: the first half of its
        // ST, or the Esc key, which the next byte decides.
        if state == .stringEscape, held != nil, let first = rest.first, first != 0x5C {
            putBackHeld()
            pressedEscape()
            state = .normal
            endedInEscape = true
        }
        // An Esc, then a write that opens a string: perhaps a reply whose ESC
        // came alone. Held, with its letter, which is typing if it was a key.
        if endedInEscape, state == .normal, let first = rest.first, Self.opensString(first) {
            if escapes > 0 { escapes -= 1 }
            state = .string
            stringLength = 1
            held = [first]
            heldTyping = writeIsKey ? [first] : []
            rest = rest.dropFirst()
        }
        endedInEscape = false
        for byte in rest { step(byte, into: &completed) }
        // The write is over, and so is any key in it. An ESC still waiting
        // for a second byte had none coming: it was the Esc key. A string
        // introducer with nothing after it is Alt and a key or a reply's
        // opening, and what follows is held until it says which. A CSI or
        // SS3 introducer alone was Alt and that key, which like any key ends
        // a run of Escs. A reply already under way continues in the next write.
        switch state {
        case .escape:
            pressedEscape()
            state = .normal
            endedInEscape = true
        case .string where stringLength == 0 && held == nil:
            // Alt and a key, or a reply's opening: hold what follows.
            held = []
        case .csi where csi.isEmpty, .ss3:
            state = .normal
            escapes = 0
        default: break
        }
        return completed
    }

    /// `]`, `P`, `_`, `^`, `X`: after an ESC, the start of a string.
    private static func opensString(_ byte: UInt8) -> Bool {
        [0x5D, 0x50, 0x5F, 0x5E, 0x58].contains(byte)
    }

    /// One UTF-8 character that isn't a control byte: how a key's text comes.
    private static func isOneCharacter(_ bytes: UnsafeBufferPointer<UInt8>) -> Bool {
        guard let first = bytes.first, first >= 0x20, first != 0x7F, bytes.count <= 4 else { return false }
        let length = first < 0x80 ? 1 : first >= 0xF0 ? 4 : first >= 0xE0 ? 3 : first >= 0xC0 ? 2 : 0
        return length == bytes.count
    }

    /// A held string was a key after all: what was typed behind it is typing.
    private mutating func putBackHeld() {
        guard let text = held else { return }
        held = nil
        heldTyping = []
        line.append(contentsOf: text)
        escapes = 0
    }

    /// A string ended by BEL or ST: a reply, or the end of one. What was held
    /// of it goes, except what came the way keys do.
    private mutating func endString() {
        state = .normal
        guard held != nil else { return }
        held = nil
        if !heldTyping.isEmpty {
            line.append(contentsOf: heldTyping)
            heldTyping = []
            escapes = 0
        }
    }

    private mutating func step(_ byte: UInt8, into completed: inout [String]) {
        switch state {
        case .escape:
            switch byte {
            case 0x5B: state = .csi; csi = []              // [
            case 0x4F: state = .ss3                         // O
            case 0x5D, 0x50, 0x5F, 0x5E, 0x58:              // ] P _ ^ X
                state = .string
                stringLength = 0
            case 0x1B: pressedEscape()                      // Esc, and another ESC
            default: state = .normal; escapes = 0           // alt+key
            }
        case .string:
            switch byte {
            case 0x07: endString()                          // BEL ends it
            case 0x1B: state = .stringEscape
            // No reply carries a control byte, so this is a key in a paste
            // that only looked like a string: end it and let the key act.
            // A held string was typing, and is put back first.
            case 0x00..<0x20, 0x7F where held != nil:
                putBackHeld()
                state = .normal
                step(byte, into: &completed)
            default:
                stringLength += 1
                if held != nil {
                    held!.append(byte)
                    if writeIsKey { heldTyping.append(byte) }
                }
            }
        case .stringEscape:
            if byte == 0x5C {                               // ST ends it
                endString()
            } else {                                        // or a new sequence starts
                putBackHeld()
                state = .escape
                step(byte, into: &completed)
            }
        case .csi:
            if (0x40...0x7E).contains(byte) {
                state = .normal
                apply(csi: csi, final: byte, into: &completed)
            } else if byte < 0x20 {                         // not a sequence after all
                state = .normal
                step(byte, into: &completed)
            } else {
                csi.append(byte)
            }
        case .ss3:
            state = .normal                                 // one byte of key code
            escapes = 0
            if byte < 0x20 { step(byte, into: &completed) }
        case .normal:
            if byte != 0x1B { escapes = 0 }
            switch byte {
            case 0x1B: state = .escape
            case 0x0D:                                      // Enter
                if inPaste {
                    line.append(0x0A)
                } else if line.last == 0x5C {               // "\" + Enter continues the line
                    line.removeLast()
                    line.append(0x0A)
                } else {
                    complete(into: &completed)
                }
            case 0x0A: line.append(0x0A)                    // ctrl-J, or a pasted newline
            case 0x7F, 0x08: deleteLastCharacter()          // backspace
            case 0x15, 0x03: line.removeAll()               // ctrl-U, ctrl-C
            case 0x17: deleteLastWord()                     // ctrl-W
            case 0x09: line.append(0x20)                    // tab
            case 0x00..<0x20: break                         // other control keys
            default: line.append(byte)
            }
        }
    }

    mutating func feed(_ bytes: [UInt8]) -> [String] {
        bytes.withUnsafeBufferPointer { feed($0) }
    }

    /// A CSI sequence ended. The three that matter: bracketed paste on/off,
    /// and the kitty keyboard protocol's Enter (`CSI 13 u`, or `CSI 13;2 u`
    /// for shift+Enter, which inserts a newline). Everything else is a key or a
    /// terminal reply and is dropped, though a key still ends a run of Escs:
    /// Esc, an arrow, Esc clears nothing in an agent. A reply doesn't, since
    /// it arrives between keys on its own: a private `?` or `>` (`CSI ? 1 u`,
    /// `CSI ? 62;22 c`) or a report's final (`CSI 12;40 R`, `CSI 0 n`).
    private mutating func apply(csi params: [UInt8], final: UInt8, into completed: inout [String]) {
        let text = String(decoding: params, as: UTF8.self)
        let isReply: Bool
        switch (params.first, final) {
        case (0x3F, _), (0x3E, _), (_, 0x52), (_, 0x6E), (_, 0x63), (_, 0x74), (_, 0x79): // ? > R n c t y
            isReply = true
        default:
            isReply = false
        }
        if !isReply, final != 0x75 { escapes = 0 }
        switch final {
        case 0x7E where text == "200": inPaste = true      // ~
        case 0x7E where text == "201": inPaste = false
        case 0x75:                                          // u
            let fields = text.split(separator: ";", omittingEmptySubsequences: false)
            guard let code = fields.first.flatMap({ Int($0.split(separator: ":").first ?? "") })
            else { return }
            let modifierField = fields.count > 1 ? fields[1].split(separator: ":") : []
            let modifiers = modifierField.first.flatMap { Int($0) } ?? 1
            // An agent asking for event types (kitty flag 2) gets each key's
            // release as well, `CSI 27;1:3 u`; only the press is typing.
            if modifierField.count > 1, modifierField[1] == "3" { return }
            if code != 27 { escapes = 0 }
            switch code {
            case 13 where (modifiers - 1) & 0b101 != 0:     // shift or alt: newline
                line.append(0x0A)
            case 13: complete(into: &completed)
            case 27 where modifiers == 1: pressedEscape()   // Esc, kitty's way
            case 127: deleteLastCharacter()
            default: break
            }
        default: break
        }
    }

    private mutating func pressedEscape() {
        escapes += 1
        if escapes >= 2 {
            line.removeAll()
            escapes = 0
        }
    }

    private mutating func complete(into completed: inout [String]) {
        completed.append(String(decoding: line, as: UTF8.self))
        line.removeAll()
    }

    private mutating func deleteLastCharacter() {
        // Walk back over UTF-8 continuation bytes so a backspace removes one
        // character, not one byte of a multi-byte one.
        while let last = line.last, (0x80...0xBF).contains(last) { line.removeLast() }
        if !line.isEmpty { line.removeLast() }
    }

    private mutating func deleteLastWord() {
        while let last = line.last, last == 0x20 { line.removeLast() }
        while let last = line.last, last != 0x20 { line.removeLast() }
    }
}

/// What counts as a first prompt, where else one might come from, and what to
/// call a session when no model is there to say.
enum FirstPrompt {
    /// Shorter than this is an answer to a dialog ("y", "1", an Enter to
    /// dismiss a trust prompt), not a prompt.
    static let minimumLength = 12

    /// The prompt in a typed line, or nil to keep waiting. Whitespace is
    /// collapsed (a pasted paragraph is one prompt). Slash commands, shell
    /// escapes and dialog answers are not prompts.
    static func accept(_ line: String) -> String? {
        let text = line.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard text.count >= minimumLength else { return nil }
        guard let first = text.first, !"/!:".contains(first) else { return nil }
        return text
    }

    /// A prompt given on the agent's own command line (`claude "fix the login
    /// bug"`), so there is nothing to wait for. The longest quoted argument
    /// long enough to be a prompt; unquoted words are flags and paths.
    static func fromCommandLine(_ argv: String) -> String? {
        var best: String?
        for quote in ["\"", "'"] {
            var rest = argv[...]
            while let open = rest.firstIndex(of: Character(quote)) {
                let afterOpen = rest.index(after: open)
                guard let close = rest[afterOpen...].firstIndex(of: Character(quote)) else { break }
                if let candidate = accept(String(rest[afterOpen..<close])),
                   candidate.count > (best?.count ?? 0) {
                    best = candidate
                }
                rest = rest[rest.index(after: close)...]
            }
        }
        return best
    }

    /// A launch that picks up an earlier conversation. Its first typed line is
    /// a follow-up, so it may only name a session that has no name yet.
    static func isResume(_ argv: String) -> Bool {
        let flags: Set<String> = ["--continue", "-c", "--resume", "-r", "resume", "--last",
                                  "--restore-chat-history", "continue"]
        return argv.split(whereSeparator: \.isWhitespace).contains { flags.contains(String($0)) }
    }

    /// A title straight from the prompt, for a Mac without the on-device model:
    /// the first sentence, cut at a word boundary, which is what Cursor and
    /// Codex show and still says what the session is for.
    static func fallbackTitle(_ prompt: String, limit: Int = 48) -> String {
        var text = prompt
        // The first sentence end past the minimum length; a stop inside the
        // first few characters ("e.g. …") is not one.
        var index = text.index(text.startIndex, offsetBy: min(minimumLength, text.count))
        while index < text.endIndex {
            if ".?!;:".contains(text[index]), text.index(after: index) < text.endIndex,
               text[text.index(after: index)] == " " {
                text = String(text[..<index])
                break
            }
            index = text.index(after: index)
        }
        if text.count > limit {
            let cut = text.prefix(limit)
            text = cut.lastIndex(of: " ").map { String(cut[..<$0]) } ?? String(cut)
        }
        while let last = text.last, ".!?,;:".contains(last) { text.removeLast() }
        text = text.trimmingCharacters(in: .whitespaces)
        guard let first = text.first else { return text }
        return first.uppercased() + text.dropFirst()
    }
}
