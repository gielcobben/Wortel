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
/// own replies to the program's queries (cursor position reports); a prompt is
/// what is left once those have been applied or dropped. It is deliberately
/// approximate: the model that turns a prompt into a title forgives a stray
/// character, and the alternative, a terminal emulator's worth of input
/// handling, would be a second parser for a problem that only needs the gist.
///
/// Pure and Foundation-only so `PromptCaptureTests` can pin it: every failure
/// here is silent, and the worst of them names a session after an escape
/// sequence.
struct TypedLineBuilder {
    private enum State { case normal, escape, csi, ss3 }

    private var line: [UInt8] = []
    private var state: State = .normal
    private var csi: [UInt8] = []
    private var inPaste = false

    init() {}

    /// Feed raw input bytes; returns every line completed by them, in order.
    mutating func feed(_ bytes: UnsafeBufferPointer<UInt8>) -> [String] {
        var completed: [String] = []
        for byte in bytes {
            switch state {
            case .escape:
                switch byte {
                case 0x5B: state = .csi; csi = []          // [
                case 0x4F: state = .ss3                     // O
                default: state = .normal                    // alt+key, or a bare ESC
                }
            case .csi:
                if (0x40...0x7E).contains(byte) {
                    state = .normal
                    apply(csi: csi, final: byte, into: &completed)
                } else {
                    csi.append(byte)
                }
            case .ss3:
                state = .normal                             // one byte of key code
            case .normal:
                switch byte {
                case 0x1B: state = .escape
                case 0x0D:                                  // Enter
                    if inPaste {
                        line.append(0x0A)
                    } else if line.last == 0x5C {           // "\" + Enter continues the line
                        line.removeLast()
                        line.append(0x0A)
                    } else {
                        complete(into: &completed)
                    }
                case 0x0A: line.append(0x0A)                // ctrl-J, or a pasted newline
                case 0x7F, 0x08: deleteLastCharacter()      // backspace
                case 0x15, 0x03: line.removeAll()           // ctrl-U, ctrl-C
                case 0x17: deleteLastWord()                 // ctrl-W
                case 0x09: line.append(0x20)                // tab
                case 0x00..<0x20: break                     // other control keys
                default: line.append(byte)
                }
            }
        }
        return completed
    }

    mutating func feed(_ bytes: [UInt8]) -> [String] {
        bytes.withUnsafeBufferPointer { feed($0) }
    }

    /// A CSI sequence ended. The three that matter: bracketed paste on/off,
    /// and the kitty keyboard protocol's Enter (`CSI 13 u`, or `CSI 13;2 u`
    /// for shift+Enter, which inserts a newline). Everything else is a key or a
    /// terminal reply and is dropped.
    private mutating func apply(csi params: [UInt8], final: UInt8, into completed: inout [String]) {
        let text = String(decoding: params, as: UTF8.self)
        switch final {
        case 0x7E where text == "200": inPaste = true      // ~
        case 0x7E where text == "201": inPaste = false
        case 0x75:                                          // u
            let fields = text.split(separator: ";", omittingEmptySubsequences: false)
            guard let code = fields.first.flatMap({ Int($0.split(separator: ":").first ?? "") })
            else { return }
            let modifiers = fields.count > 1
                ? Int(fields[1].split(separator: ":").first ?? "") ?? 1 : 1
            switch code {
            case 13 where (modifiers - 1) & 0b101 != 0:     // shift or alt: newline
                line.append(0x0A)
            case 13: complete(into: &completed)
            case 127: deleteLastCharacter()
            default: break
            }
        default: break
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
