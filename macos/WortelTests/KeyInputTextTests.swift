import AppKit
import Testing

struct KeyInputTextTests {
    // MARK: keyEventText (Ghostty f4309055f)

    @Test(arguments: [
        ("a", "a"),
        ("é", "é"),
        (" ", " "),
        ("日本", "日本"),
        ("\u{1F600}", "\u{1F600}"),
    ])
    func printableTextIsKeyText(text: String, expected: String) {
        #expect(KeyInputText.keyEventText(text) == expected)
    }

    @Test(arguments: ["", "\u{0}", "\u{8}", "\r", "\u{1B}", "\u{1F}", "\u{7F}", "\u{7F}x", "\u{1B}[A"])
    func controlTextIsNotKeyText(text: String) {
        #expect(KeyInputText.keyEventText(text) == nil)
    }

    @Test func missingTextIsNotKeyText() {
        #expect(KeyInputText.keyEventText(nil) == nil)
    }

    @Test func onlyTheFirstScalarDecides() {
        #expect(KeyInputText.keyEventText("x\u{7F}") == "x\u{7F}")
    }

    // MARK: isComposingControl (Ghostty a43cc02eb)

    @Test(arguments: [
        ("\u{8}", true),
        ("\n", true),
        ("\r", true),
        ("\u{1F}", true),
        ("\u{7F}", false),
        (" ", false),
        ("h", false),
        ("", false),
        ("\u{9}x", false),
        ("\u{9}\u{9}", false),
    ])
    func onlyOneC0CharacterWhileComposingIsTheInputMethods(text: String, expected: Bool) {
        #expect(KeyInputText.isComposingControl(text, composing: true) == expected)
    }

    @Test func controlTextWithoutCompositionGoesToTheProgram() {
        #expect(!KeyInputText.isComposingControl("\u{8}", composing: false))
        #expect(!KeyInputText.isComposingControl(nil, composing: true))
    }

    // MARK: replaysKeyAfterCommit (Ghostty fa141a726, d60a16c14)

    @Test(arguments: [UInt16(0x7C), 0x7D, 0x7E])
    func arrowsOtherThanLeftAreReplayed(keyCode: UInt16) {
        #expect(KeyInputText.replaysKeyAfterCommit(keyCode: keyCode, modifiers: []))
        #expect(KeyInputText.replaysKeyAfterCommit(keyCode: keyCode, modifiers: [.shift]))
    }

    @Test func plainLeftArrowIsNotReplayed() {
        #expect(!KeyInputText.replaysKeyAfterCommit(keyCode: 0x7B, modifiers: []))
        // Caps Lock and the function-key flag an arrow always has are not
        // modifiers a person chose.
        #expect(!KeyInputText.replaysKeyAfterCommit(keyCode: 0x7B, modifiers: [.capsLock, .function, .numericPad]))
    }

    @Test(arguments: [NSEvent.ModifierFlags.shift, .control, .option, .command])
    func modifiedLeftArrowIsReplayed(modifier: NSEvent.ModifierFlags) {
        #expect(KeyInputText.replaysKeyAfterCommit(keyCode: 0x7B, modifiers: [modifier, .function]))
    }

    @Test(arguments: [
        UInt16(0x24), // Return
        0x4C, // keypad Enter
        0x31, // space
        0x26, // J (⌃J)
        0x04, // H (⌃H)
        0x30, // Tab
        0x33, // Delete
    ])
    func otherKeysThatCommitAreNotReplayed(keyCode: UInt16) {
        #expect(!KeyInputText.replaysKeyAfterCommit(keyCode: keyCode, modifiers: []))
        #expect(!KeyInputText.replaysKeyAfterCommit(keyCode: keyCode, modifiers: [.control]))
    }

    // MARK: SurrogatePairing (Ghostty f0e3be3ee)

    private func half(_ unit: UInt16) -> NSString {
        NSString(characters: [unit], length: 1)
    }

    @Test func aLeadThenATrailIsOneCharacter() {
        var pairing = SurrogatePairing()
        #expect(pairing.text(for: half(0xD83D)) == "")
        #expect(pairing.text(for: half(0xDE00)) == "\u{1F600}")
    }

    @Test func aTrailWithoutALeadIsDropped() {
        var pairing = SurrogatePairing()
        #expect(pairing.text(for: half(0xDE00)) == "")
    }

    @Test func otherTextForgetsAWaitingLead() {
        var pairing = SurrogatePairing()
        _ = pairing.text(for: half(0xD83D))
        #expect(pairing.text(for: "a") == "a")
        #expect(pairing.text(for: half(0xDE00)) == "")
    }

    @Test func aTrailIsUsedOnce() {
        var pairing = SurrogatePairing()
        _ = pairing.text(for: half(0xD83D))
        _ = pairing.text(for: half(0xDE00))
        #expect(pairing.text(for: half(0xDE00)) == "")
    }

    @Test func ordinaryTextPassesThrough() {
        var pairing = SurrogatePairing()
        #expect(pairing.text(for: "hello") == "hello")
        #expect(pairing.text(for: "\u{1F600}") == "\u{1F600}")
        #expect(pairing.text(for: "") == "")
    }
}
