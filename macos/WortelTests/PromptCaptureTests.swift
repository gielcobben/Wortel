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

    func testStateSurvivesSplitReads() {
        var builder = TypedLineBuilder()
        let input = Array("split \u{1B}[200~across\r reads\u{1B}[201~ here\r".utf8)
        var out: [String] = []
        for byte in input { out += builder.feed([byte]) }
        XCTAssertEqual(out, ["split across\n reads here"])
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
}
