import AppKit

/// The note's text view.
///
/// A real text view, so undo, spelling, dictation and input methods are the
/// system's. It takes the editing keys itself while it has the keyboard:
/// ⌘A and ⌘Z are the terminal's in `wortel.conf` and so are not on the menu
/// (`CommitTextView` has the same reason and the same handling).
final class NoteTextView: NSTextView {
    var onReturn: () -> Void = {}
    var onEscape: () -> Void = {}
    /// What an empty note says, longest first: the first that fits is shown.
    var placeholders: [String] = [] { didSet { needsDisplay = true } }
    /// What a chip is called when the note's own text is copied out of it.
    var nameOfMark: (Int) -> String? = { _ in nil }
    /// The pointer came to rest on a mark's chip, or left it: the layer
    /// shows which mark that is.
    var onHoverMark: (Int?) -> Void = { _ in }
    /// A mark's chip was clicked: it is selected, and the layer brings its
    /// mark into view.
    var onPickMark: (Int) -> Void = { _ in }
    private var hovered: Int?
    private var hoverArea: NSTrackingArea?

    // MARK: - The pointer and a chip

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow,
                                                         .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let number = chip(at: point)
        // The text view's own handling of a move is left out over a chip:
        // it is what puts the I-beam back, and the pointer would flicker
        // between the two on every move along a chip.
        if number == nil { super.mouseMoved(with: event) }
        // Set on a chip, and once more on the way off one: the I-beam's
        // cursor rect is entered only at the view's edge, so nothing else
        // puts it back.
        if number != nil || hovered != nil { cursor(at: point).set() }
        hover(number)
    }

    /// The pointer for a point of the view: the arrow on a chip, which is
    /// clicked and not typed into, and the I-beam on the words and between
    /// them.
    func cursor(at point: NSPoint) -> NSCursor {
        chip(at: point) == nil ? .iBeam : .arrow
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        hover(nil)
    }

    private func hover(_ number: Int?) {
        guard number != hovered else { return }
        hovered = number
        onHoverMark(number)
    }

    /// The mark whose chip is under a point of the view, if one is.
    private func chip(at point: NSPoint) -> Int? { chipAndIndex(at: point)?.number }

    private func chipAndIndex(at point: NSPoint) -> (number: Int, index: Int)? {
        guard let layoutManager, let textContainer, let textStorage, textStorage.length > 0 else { return nil }
        let inContainer = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        let glyph = layoutManager.glyphIndex(for: inContainer, in: textContainer)
        // The nearest glyph is not the one under the pointer when the
        // pointer is past the end of a line.
        guard layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer)
            .contains(inContainer) else { return nil }
        let index = layoutManager.characterIndexForGlyph(at: glyph)
        guard index < textStorage.length else { return nil }
        guard let chip = textStorage.attribute(.attachment, at: index, effectiveRange: nil) as? MarkChipAttachment
        else { return nil }
        return (chip.number, index)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let (number, index) = chipAndIndex(at: point) else { return super.mouseDown(with: event) }
        window?.makeFirstResponder(self)
        // Selected as one character is: ⌫ removes it, typing replaces it.
        // It draws itself selected (`MarkChipCell`).
        setSelectedRange(NSRange(location: index, length: 1))
        onPickMark(number)
    }

    /// Where a mark's chip is in the text, if it is there.
    func range(ofChip number: Int) -> NSRange? {
        guard let textStorage else { return nil }
        var found: NSRange?
        textStorage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: textStorage.length)) {
            value, range, stop in
            if (value as? MarkChipAttachment)?.number == number {
                found = range
                stop.pointee = true
            }
        }
        return found
    }

    // MARK: - A chip selected

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        let before = selectedRanges
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        redrawChips { index in
            Self.holds(before, index) != Self.holds(self.selectedRanges, index)
        }
    }

    // Whether typing would go here decides how strongly a selected chip is
    // drawn, as it does the system's own selection.
    override func becomeFirstResponder() -> Bool {
        defer { redrawChips { Self.holds(self.selectedRanges, $0) } }
        return super.becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        defer { redrawChips { Self.holds(self.selectedRanges, $0) } }
        return super.resignFirstResponder()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            NotificationCenter.default.removeObserver(self, name: name, object: nil)
            if let newWindow {
                NotificationCenter.default.addObserver(self, selector: #selector(keyChanged), name: name,
                                                       object: newWindow)
            }
        }
    }

    @objc private func keyChanged() {
        redrawChips { Self.holds(self.selectedRanges, $0) }
    }

    private static func holds(_ ranges: [NSValue], _ index: Int) -> Bool {
        ranges.contains { NSLocationInRange(index, $0.rangeValue) }
    }

    /// Draw again the chips at the indexes `which` picks. A chip is a cell,
    /// drawn again only when its rect is, and a change of selection alone
    /// redraws the selection's background and not what is on it.
    private func redrawChips(_ which: (Int) -> Bool) {
        guard let textStorage, let layoutManager else { return }
        textStorage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: textStorage.length)) {
            value, range, _ in
            guard value is MarkChipAttachment, which(range.location) else { return }
            layoutManager.invalidateDisplay(forCharacterRange: range)
        }
    }

    // MARK: - Keys

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command {
            switch event.charactersIgnoringModifiers {
            case "a": selectAll(nil); return true
            case "c": copy(nil); return true
            case "v": paste(nil); return true
            case "x": cut(nil); return true
            case "z": undoManager?.undo(); return true
            default: break
            }
        } else if flags == [.command, .shift], event.charactersIgnoringModifiers?.lowercased() == "z" {
            undoManager?.redo()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func doCommand(by selector: Selector) {
        switch selector {
        case #selector(insertNewline(_:)):
            // A Return that confirms an input method's candidates never
            // gets here; one with text still being composed is not a copy.
            if hasMarkedText() { return super.doCommand(by: selector) }
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                insertNewlineIgnoringFieldEditor(nil)
            } else {
                onReturn()
            }
        case #selector(insertLineBreak(_:)):
            // A plain new line, not the line separator this would insert,
            // which would travel into whatever the note is pasted into.
            insertNewlineIgnoringFieldEditor(nil)
        case #selector(cancelOperation(_:)):
            onEscape()
        case #selector(insertTab(_:)), #selector(insertBacktab(_:)):
            break
        default:
            super.doCommand(by: selector)
        }
    }

    // MARK: - Typing, copying and pasting

    // What is typed takes the note's own font and colour: after a chip the
    // text view would otherwise go on in the attachment's attributes.
    override func insertText(_ string: Any, replacementRange: NSRange) {
        if let plain = string as? String {
            super.insertText(NSAttributedString(string: plain, attributes: MarkupNoteBar.attributes),
                             replacementRange: replacementRange)
        } else {
            super.insertText(string, replacementRange: replacementRange)
        }
    }

    override func didChangeText() {
        super.didChangeText()
        typingAttributes = MarkupNoteBar.attributes
    }

    // Words only, in and out. A chip pasted back from the clipboard would
    // be a picture with no mark behind it.
    override func paste(_ sender: Any?) { pasteAsPlainText(sender) }

    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] { [.string] }

    override func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        let range = selectedRange()
        guard range.length > 0, let storage = textStorage else { return false }
        var out = ""
        for piece in MarkChip.pieces(in: storage.attributedSubstring(from: range)) {
            switch piece {
            case .text(let text): out += text
            case .mark(let number): out += nameOfMark(number) ?? ""
            }
        }
        pboard.clearContents()
        pboard.setString(out, forType: .string)
        return true
    }

    // MARK: - Drawing

    // The caret as tall as the text and not as the line. A text view draws
    // its own this way when a subclass draws it, which this does only to
    // say how tall.
    private func caret(in rect: NSRect) -> NSRect {
        let height = ceil(MarkupNoteBar.font.ascender - MarkupNoteBar.font.descender) + 2
        guard rect.height > height else { return rect }
        return NSRect(x: rect.minX, y: rect.midY - height / 2, width: rect.width, height: height)
    }

    override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn flag: Bool) {
        super.drawInsertionPoint(in: caret(in: rect), color: color, turnedOn: flag)
    }

    override func setNeedsDisplay(_ rect: NSRect, avoidAdditionalLayout flag: Bool) {
        // The whole of the line's rect is redrawn, so a caret drawn shorter
        // is still wiped when it blinks off.
        super.setNeedsDisplay(rect, avoidAdditionalLayout: flag)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard (textStorage?.length ?? 0) == 0 else { return }
        var attributes = MarkupNoteBar.attributes
        attributes[.foregroundColor] = NSColor.placeholderTextColor
        let room = bounds.width - textContainerInset.width * 2
        // The longest that fits on the one line: half a hint cut off by the
        // button reads as a mistake.
        guard let text = placeholders.first(where: {
            ($0 as NSString).size(withAttributes: attributes).width <= room
        }) ?? placeholders.last else { return }
        // With the note's own line height, so it sits where typing will.
        text.draw(at: NSPoint(x: textContainerInset.width + (textContainer?.lineFragmentPadding ?? 0),
                              y: textContainerInset.height),
                  withAttributes: attributes)
    }
}

/// The note's layout: no selection is painted behind a chip. A selected chip
/// shows it itself (`MarkChipCell`); the system's rectangle around it was
/// the line's height and the chip's width with its gaps, and the capsule
/// floated in it. Words keep the system's selection.
final class NoteLayoutManager: NSLayoutManager {
    private let lines = NoteLines()

    override init() {
        super.init()
        delegate = lines
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        delegate = lines
    }

    override func fillBackgroundRectArray(_ rectArray: UnsafePointer<NSRect>, count rectCount: Int,
                                          forCharacterRange charRange: NSRange, color: NSColor) {
        // Copied before anything else is asked of the layout: the array is
        // the layout manager's own scratch space, and the next rect it works
        // out for anyone is written over it. Asked for a chip's rect first,
        // the selection was then filled over that chip alone.
        let rects = (0..<rectCount).map { rectArray[$0] }
        let chips = chipRects(in: charRange)
        guard !chips.isEmpty, let context = NSGraphicsContext.current?.cgContext else {
            return super.fillBackgroundRectArray(rects, count: rects.count, forCharacterRange: charRange, color: color)
        }
        // Everything the selection covers but the chips: each chip's rect is
        // a hole by the even-odd rule, and chips never overlap one another.
        let all = rects.reduce(CGRect.null) { $0.union($1) }
        let kept = CGMutablePath()
        kept.addRect(all)
        for chip in chips { kept.addRect(chip.intersection(all)) }
        context.saveGState()
        context.addPath(kept)
        context.clip(using: .evenOdd)
        super.fillBackgroundRectArray(rects, count: rects.count, forCharacterRange: charRange, color: color)
        context.restoreGState()
    }

    /// Where the chips in a range of the text are, in the text view: each
    /// chip's width and its whole line's height, which is what the
    /// selection would fill there.
    private func chipRects(in range: NSRange) -> [CGRect] {
        guard let textStorage, let container = textContainers.first, let view = container.textView else { return [] }
        var chips: [CGRect] = []
        let within = NSIntersectionRange(range, NSRange(location: 0, length: textStorage.length))
        textStorage.enumerateAttribute(.attachment, in: within) { value, range, _ in
            guard value is MarkChipAttachment else { return }
            let glyphs = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            guard glyphs.length > 0 else { return }
            var rect = boundingRect(forGlyphRange: glyphs, in: container)
            let line = lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
            rect.origin.y = line.minY
            rect.size.height = line.height
            // Out to whole points: a chip's edges fall between pixels where
            // the selection's do not, and that left a hairline of it.
            chips.append(rect.offsetBy(dx: view.textContainerOrigin.x, dy: view.textContainerOrigin.y).integral)
        }
        return chips
    }
}

/// Every line of the note has its baseline where a line of words has it.
///
/// A line is a fixed 22pt either way, but a chip on it counted as taller
/// than the words, and the typesetter put that line's baseline 3pt higher
/// (16 from its top, not 19). Its words rose with it, so two lines of words
/// with a chip between them were 25pt apart and the next pair 19, and the
/// chip touched the line above. Held at the words' baseline, the chip,
/// centred on their capitals, sits inside its own line.
private final class NoteLines: NSObject, NSLayoutManagerDelegate {
    func layoutManager(_ layoutManager: NSLayoutManager,
                       shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<NSRect>,
                       lineFragmentUsedRect: UnsafeMutablePointer<NSRect>, baselineOffset: UnsafeMutablePointer<CGFloat>,
                       in textContainer: NSTextContainer, forGlyphRange glyphRange: NSRange) -> Bool {
        // Where the typesetter puts it for words alone: the room a line has
        // over the font's own height goes above them.
        let words = MainActor.assumeIsolated {
            (MarkupNoteBar.lineHeight + MarkupNoteBar.font.descender).rounded()
        }
        guard baselineOffset.pointee != words else { return false }
        baselineOffset.pointee = words
        return true
    }
}
