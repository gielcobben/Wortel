import XCTest

/// Typed input read back as lines, and what counts as a first prompt. Every
/// failure here is silent: the wrong line names a session after an escape
/// sequence, a pasted paragraph, or the "y" typed at a trust dialog.
final class PromptCaptureTests: XCTestCase {
    private func lines(_ text: String) -> [String] {
        var builder = TypedLineBuilder()
        return builder.feed(Array(text.utf8))
    }

    // MARK: - Reconstruction

    func testPlainTypingCompletesOnEnter() {
        XCTAssertEqual(lines("fix the login bug\r"), ["fix the login bug"])
        XCTAssertEqual(lines("half a line"), [], "nothing until Enter")
    }

    func testBackspaceRemovesOneCharacterEvenWhenMultibyte() {
        XCTAssertEqual(lines("fixx\u{7F} it\r"), ["fix it"])
        XCTAssertEqual(lines("café\u{7F}e\r"), ["cafe"])
        XCTAssertEqual(lines("\u{7F}\u{7F}ok\r"), ["ok"], "backspace on an empty line is nothing")
    }

    func testLineEditingKeys() {
        XCTAssertEqual(lines("wrong thing\u{15}right thing\r"), ["right thing"], "ctrl-U clears")
        XCTAssertEqual(lines("delete this word\u{17}line\r"), ["delete this line"], "ctrl-W")
        XCTAssertEqual(lines("abandoned\u{03}kept\r"), ["kept"], "ctrl-C clears")
    }

    /// Arrow keys, function keys, and the terminal's replies to the program's
    /// queries all arrive as escape sequences on the same stream.
    func testEscapeSequencesAreDropped() {
        XCTAssertEqual(lines("\u{1B}[A\u{1B}[Bup and down\u{1B}[3~\r"), ["up and down"])
        XCTAssertEqual(lines("\u{1B}[12;40Rtyped\r"), ["typed"], "cursor position report")
        XCTAssertEqual(lines("\u{1B}OPtyped\r"), ["typed"], "SS3 function key")
        XCTAssertEqual(lines("\u{1B}xtyped\r"), ["typed"], "alt+key")
    }

    /// The replies that are strings rather than one CSI: Claude asks for the
    /// background colour at launch, and the answer used to become the first
    /// prompt, so sessions were named "Extract hex color values". Each is a
    /// write of its own, between the keys typed around it.
    func testStringRepliesAreDropped() {
        XCTAssertEqual(writes(["\u{1B}]11;rgb:1e1e/1e1e/1e1e\u{1B}\\", "\r"]), [""], "OSC, ended by ST")
        XCTAssertEqual(writes(["\u{1B}]10;rgb:d8d8/d8d8/d8d8\u{07}"] + keys("typed\r")), ["typed"],
                       "OSC, ended by BEL")
        XCTAssertEqual(writes(["\u{1B}P>|ghostty 1.2.0\u{1B}\\"] + keys("typed\r")), ["typed"],
                       "DCS (XTVERSION)")
        XCTAssertEqual(writes(["\u{1B}_Gi=1;OK\u{1B}\\"] + keys("typed\r")), ["typed"], "APC (kitty graphics)")
        XCTAssertEqual(writes(keys("fix ") + ["\u{1B}]11;rgb:0/0/0\u{1B}\\"] + keys("it\r")), ["fix it"],
                       "mid-line")
    }

    /// libghostty hands each reply over whole, but one cut in two must not
    /// leak its second half into the line; a misread stops at the next
    /// control key.
    func testAReplyCutInTwoIsStillAReply() {
        XCTAssertEqual(writes(["\u{1B}]11;rgb:1e1e/", "1e1e/1e1e\u{1B}\\"] + keys("typed\r")), ["typed"])
        XCTAssertEqual(writes(["\u{1B}]11;rgb:1e1e/1e1e/1e1e\u{1B}", "\\"] + keys("typed\r")), ["typed"],
                       "cut inside its ST")
        XCTAssertEqual(writes(["\u{1B}[12;", "40R"] + keys("typed\r")), ["typed"], "a CSI reply too")
        XCTAssertEqual(writes(["\u{1B}]1"] + keys("lost\r") + keys("next\r")), ["", "next"])
        XCTAssertEqual(writes(["\u{1B}["] + keys("x\r")), ["x"], "alt+[ is the key alone")
    }

    /// Within one write a control byte or an ESC still ends a string or a
    /// CSI, so a paste that only looks like one costs little.
    func testSequencesEndAtAControlByte() {
        XCTAssertEqual(lines("\u{1B}]11;rgb\u{1B}[Atyped\r"), ["typed"], "ESC starts a new sequence")
        XCTAssertEqual(lines("\u{1B}P1 lost\rnext\r"), ["", "next"], "Enter ends a string")
        XCTAssertEqual(lines("half\u{1B}[1\rnext\r"), ["half", "next"], "and a CSI")
        XCTAssertEqual(lines("\u{1B}[12\u{03}kept\r"), ["kept"], "ctrl-C too")
    }

    /// In legacy mode Esc is a lone ESC in its own write. What follows it is
    /// typing, whatever its first letter, and a reply right behind it is
    /// still a reply, not a second Esc.
    func testALegacyEscIsItsOwnWrite() {
        XCTAssertEqual(writes(["\u{1B}"] + keys("Please fix the login bug\r")), ["Please fix the login bug"])
        XCTAssertEqual(writes(["\u{1B}"] + keys("]then typed\r")), ["]then typed"])
        XCTAssertEqual(writes(["\u{1B}]"] + keys("then typed\r")), ["then typed"], "alt+] is the key alone")
        XCTAssertTrue(draft(writes: ["kept", "\u{1B}", "\u{1B}]11;rgb:0/0/0\u{1B}\\"]), "Esc, then a reply")
        XCTAssertFalse(draft(writes: ["gone", "\u{1B}", "\u{1B}"]), "Esc Esc clears")
        XCTAssertEqual(writes(["half", "\u{1B}", "\u{1B}"] + keys("new\r")), ["new"],
                       "and the next key is typing, not alt+key")
    }

    /// A reply between two Escs doesn't break the pair, however it ends.
    func testAReplyBetweenTwoEscapesStillClears() {
        for reply in ["\u{1B}]11;rgb:0/0/0\u{1B}\\", "\u{1B}]11;rgb:0/0/0\u{07}"] {
            XCTAssertFalse(draft(writes: ["gone", "\u{1B}[27u", reply, "\u{1B}[27u"]), "kitty")
            XCTAssertFalse(draft(writes: ["gone", "\u{1B}", reply, "\u{1B}"]), "legacy")
        }
        XCTAssertTrue(draft(writes: ["kept", "\u{1B}]11;rgb:0/0/0\u{1B}\\"]), "a reply alone is no Esc")
        for reply in ["\u{1B}[12;40R", "\u{1B}[?62;22c", "\u{1B}[?1u", "\u{1B}[0n"] {
            XCTAssertFalse(draft(writes: ["gone", "\u{1B}", reply, "\u{1B}"]), "nor a CSI reply \(reply)")
        }
    }

    /// Any other key between two Escs breaks the pair, as it does in the agent.
    func testAKeyBetweenTwoEscapesClearsNothing() {
        for key in ["\u{1B}[A", "\u{1B}OA", "\u{1B}[3~", "\u{1B}[1;2D", "\u{1B}[97u", "\u{1B}[Z",
                    "\u{1B}[1;2P", "\u{1B}[", "\u{1B}]", "x"] {
            XCTAssertTrue(draft(writes: ["kept", "\u{1B}", key, "\u{1B}"]), key)
            XCTAssertTrue(draft(writes: ["kept", "\u{1B}[27u", key, "\u{1B}[27u"]), key)
        }
    }

    /// With kitty's event types on, every key is also released; the release
    /// is not a second press.
    func testKittyReleasesAreNotKeys() {
        XCTAssertTrue(draft(writes: ["kept", "\u{1B}[27u", "\u{1B}[27;1:3u"]), "Esc pressed and released once")
        XCTAssertEqual(writes(["abc", "\u{1B}[127u", "\u{1B}[127;1:3u", "\u{1B}[13u", "\u{1B}[13;1:3u"]),
                       ["ab"], "one backspace, one Enter")
        XCTAssertEqual(writes(["abc", "\u{1B}[127;1:2u", "\u{1B}[13u"]), ["ab"], "a repeat is a press")
    }

    /// A pasted paragraph is one prompt: the newlines inside a bracketed paste
    /// never submit, and the markers are not text.
    func testBracketedPasteIsOneLine() {
        let pasted = "\u{1B}[200~first line\rsecond line\u{1B}[201~\r"
        XCTAssertEqual(lines(pasted), ["first line\nsecond line"])
    }

    /// Claude Code's own multi-line convention, and the kitty keyboard
    /// protocol's Enter, shift+Enter and backspace.
    func testContinuationsAndKittyKeys() {
        XCTAssertEqual(lines("line one\\\rline two\r"), ["line one\nline two"], "backslash-Enter")
        XCTAssertEqual(lines("kitty enter\u{1B}[13u"), ["kitty enter"])
        XCTAssertEqual(lines("one\u{1B}[13;2utwo\u{1B}[13u"), ["one\ntwo"], "shift+Enter is a newline")
        XCTAssertEqual(lines("abc\u{1B}[127u\r"), ["ab"], "kitty backspace")
    }

    /// A paste arrives as three writes, its markers apart from its text, so
    /// being inside one is the state that spans writes.
    func testAPasteSpansItsWrites() {
        let parts = keys("split ") + ["\u{1B}[200~", "across\r lines", "\u{1B}[201~"] + keys(" here\r")
        XCTAssertEqual(writes(parts), ["split across\n lines here"])
    }

    // MARK: - What counts as a prompt

    func testDialogAnswersAndCommandsAreNotPrompts() {
        XCTAssertNil(FirstPrompt.accept(""))
        XCTAssertNil(FirstPrompt.accept("y"))
        XCTAssertNil(FirstPrompt.accept("1"))
        XCTAssertNil(FirstPrompt.accept("yes please"))
        XCTAssertNil(FirstPrompt.accept("/model opus"))
        XCTAssertNil(FirstPrompt.accept("/clear and start over"))
        XCTAssertNil(FirstPrompt.accept("!git status --short"))
    }

    func testPromptsAreCollapsedToOneLine() {
        XCTAssertEqual(FirstPrompt.accept("  fix the   login\nredirect loop  "),
                       "fix the login redirect loop")
    }

    /// `claude "fix the login bug"` needs no waiting at all.
    func testPromptOnTheCommandLine() {
        XCTAssertEqual(FirstPrompt.fromCommandLine(#"claude --model opus "fix the login redirect loop""#),
                       "fix the login redirect loop")
        XCTAssertEqual(FirstPrompt.fromCommandLine("codex 'add a changelog page to the website'"),
                       "add a changelog page to the website")
        XCTAssertNil(FirstPrompt.fromCommandLine("claude --model opus"))
        XCTAssertNil(FirstPrompt.fromCommandLine(#"claude -p "hi""#), "too short to be a prompt")
    }

    func testResumeLaunchesAreRecognised() {
        XCTAssertTrue(FirstPrompt.isResume("claude --continue"))
        XCTAssertTrue(FirstPrompt.isResume("claude -c"))
        XCTAssertTrue(FirstPrompt.isResume("codex resume --last"))
        XCTAssertTrue(FirstPrompt.isResume("pi -c"))
        XCTAssertFalse(FirstPrompt.isResume("claude --model opus"))
        XCTAssertFalse(FirstPrompt.isResume("claude 'continue the migration'"), "a word inside a prompt is not a flag")
    }

    // MARK: - The no-model fallback

    func testFallbackTitleIsTheFirstSentenceCutAtAWord() {
        XCTAssertEqual(FirstPrompt.fallbackTitle("fix the login redirect loop. It happens after logout"),
                       "Fix the login redirect loop")
        XCTAssertEqual(FirstPrompt.fallbackTitle("can we make the auto names of the sessions way better for agents"),
                       "Can we make the auto names of the sessions way")
        XCTAssertEqual(FirstPrompt.fallbackTitle("why does this fail?"), "Why does this fail")
        XCTAssertEqual(FirstPrompt.fallbackTitle("e.g. handle the edge case in parsing"),
                       "E.g. handle the edge case in parsing", "a stop inside the first 12 characters is not a sentence end")
    }

    // MARK: - A draft (`wortel cd` waits on one)

    /// Separate writes, as libghostty delivers them: one per key press, one
    /// per reply.
    private func writes(_ parts: [String]) -> [String] {
        var builder = TypedLineBuilder()
        return parts.flatMap { builder.feed(Array($0.utf8)) }
    }

    private func keys(_ text: String) -> [String] { text.map(String.init) }

    private func draft(writes parts: [String]) -> Bool {
        var builder = TypedLineBuilder()
        for part in parts { _ = builder.feed(Array(part.utf8)) }
        return builder.hasDraft
    }

    private func draft(_ text: String) -> Bool {
        var builder = TypedLineBuilder()
        _ = builder.feed(Array(text.utf8))
        return builder.hasDraft
    }

    /// Something typed and not sent is a draft, until it's sent or cleared.
    func testATypedLineIsADraftUntilSentOrCleared() {
        XCTAssertFalse(draft(""))
        XCTAssertTrue(draft("half a thought"))
        XCTAssertFalse(draft("sent\r"))
        XCTAssertFalse(draft("gone\u{15}"), "ctrl-U")
        XCTAssertFalse(draft("gone\u{03}"), "ctrl-C")
    }

    /// Esc Esc clears Claude's input box, in either keyboard protocol; one
    /// Esc alone doesn't, so neither does it here.
    func testEscapeTwiceClearsTheDraft() {
        XCTAssertFalse(draft("gone\u{1B}[27u\u{1B}[27u"), "kitty")
        XCTAssertTrue(draft("kept\u{1B}[27u"), "one Esc")
        XCTAssertTrue(draft("kept\u{1B}[27ux"), "Esc, then typing")
        XCTAssertFalse(draft("gone\u{1B}\u{1B}"), "legacy")
    }
}
