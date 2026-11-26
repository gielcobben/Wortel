import AppKit

/// A mark in the note: a small capsule in the mark's colour with its number
/// and what it points at, sitting in the sentence as a word does.
final class MarkChipAttachment: NSTextAttachment {
    let number: Int

    init(number: Int) {
        self.number = number
        super.init(data: nil, ofType: nil)
    }

    required init?(coder: NSCoder) {
        number = coder.decodeInteger(forKey: "markNumber")
        super.init(coder: coder)
    }

    override func encode(with coder: NSCoder) {
        super.encode(with: coder)
        coder.encode(number, forKey: "markNumber")
    }
}

@MainActor
enum MarkChip {
    static let height: CGFloat = 20
    private static let nameFont = NSFont.systemFont(ofSize: 12)
    private static let numberFont = NSFont.systemFont(ofSize: 12, weight: .semibold)
    /// Clear room either side of the capsule, part of the chip itself: two
    /// chips side by side, or a chip against a word, otherwise touch.
    private static let gap: CGFloat = 3
    /// A chip names its mark, it does not quote it: the rest of a long
    /// name is in the copied text.
    private static let longest = 28

    /// What a chip says, cut to fit `width` points: a chip cannot wrap, and
    /// one wider than a narrow column's note would be cut off by its edge.
    static func title(of mark: Mark, fitting width: CGFloat = .greatestFiniteMagnitude) -> String {
        var name: String
        if case .area = mark.shape { name = mark.pen.word } else { name = mark.name }
        if name.count > longest { name = name.prefix(longest - 1) + "\u{2026}" }
        func measured(_ text: String) -> CGFloat {
            ceil((text as NSString).size(withAttributes: [.font: nameFont]).width)
        }
        while name.count > 4, measured(name) > width {
            name = String(name.dropLast(2)).trimmingCharacters(in: .whitespaces) + "\u{2026}"
        }
        return name
    }

    /// The chip, as text to put in the note. `width` is the room a line of
    /// the note has.
    static func string(for mark: Mark, font: NSFont, fitting width: CGFloat = .greatestFiniteMagnitude) -> NSAttributedString {
        let number = String(mark.number)
        let numberWidth = ceil((number as NSString).size(withAttributes: [.font: numberFont]).width)
        let title = title(of: mark, fitting: width - (7 + numberWidth + 5 + 8) - gap * 2)
        let titleWidth = ceil((title as NSString).size(withAttributes: [.font: nameFont]).width)
        let size = NSSize(width: gap + 7 + numberWidth + 5 + titleWidth + 8 + gap, height: height)
        let colour = MarkDrawing.color(mark.colour)

        let attachment = MarkChipAttachment(number: mark.number)
        // Drawn when it is shown, not once: the colours are the system's and
        // follow light and dark.
        attachment.image = NSImage(size: size, flipped: false) { rect in
            colour.withAlphaComponent(0.15).setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: gap, dy: 0), xRadius: 6, yRadius: 6).fill()
            let numberHeight = numberFont.ascender - numberFont.descender
            (number as NSString).draw(
                at: NSPoint(x: gap + 7, y: (rect.height - numberHeight) / 2 - numberFont.descender - 3),
                withAttributes: [.font: numberFont, .foregroundColor: colour])
            let titleHeight = nameFont.ascender - nameFont.descender
            (title as NSString).draw(
                at: NSPoint(x: gap + 7 + numberWidth + 5, y: (rect.height - titleHeight) / 2 - nameFont.descender - 3),
                withAttributes: [.font: nameFont, .foregroundColor: NSColor.labelColor])
            return true
        }
        // Centred on the line's capitals, so a chip neither lifts its line
        // nor hangs below it.
        attachment.bounds = CGRect(x: 0, y: (font.capHeight - height) / 2, width: size.width, height: size.height)
        let string = NSMutableAttributedString(attachment: attachment)
        string.addAttributes(MarkupNoteBar.attributes, range: NSRange(location: 0, length: string.length))
        return string
    }

    /// The numbers of the marks whose chips are in a text, in its order.
    nonisolated static func numbers(in text: NSAttributedString) -> [Int] {
        var numbers: [Int] = []
        text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { value, _, _ in
            if let chip = value as? MarkChipAttachment { numbers.append(chip.number) }
        }
        return numbers
    }

    /// A text as what was typed and which marks, in order.
    nonisolated static func pieces(in text: NSAttributedString) -> [MarkupNote.Piece] {
        var pieces: [MarkupNote.Piece] = []
        let whole = text.string as NSString
        text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            if let chip = value as? MarkChipAttachment {
                pieces.append(.mark(chip.number))
            } else {
                // Any other attachment has no words to give.
                let typed = whole.substring(with: range).replacingOccurrences(of: "\u{FFFC}", with: "")
                if !typed.isEmpty { pieces.append(.text(typed)) }
            }
        }
        return pieces
    }
}

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
    private var hovered: Int?
    private var hoverArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow,
                                                         .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        hover(chip(at: convert(event.locationInWindow, from: nil)))
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

    /// A mark's chip was clicked: it is selected, and the layer brings its
    /// mark into view.
    var onPickMark: (Int) -> Void = { _ in }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let (number, index) = chipAndIndex(at: point) else { return super.mouseDown(with: event) }
        window?.makeFirstResponder(self)
        // Selected as one character is: ⌫ removes it, typing replaces it,
        // and the selection's colour shows through the chip.
        setSelectedRange(NSRange(location: index, length: 1))
        onPickMark(number)
    }

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

/// The note bar: where the sentence is written, floating at the bottom of
/// the preview.
///
/// It is the command palette's card (the `.popover` material, 16pt corners,
/// a hairline, a soft shadow) holding a text view and the system's default
/// button. It talks to nobody and sends nothing: Return puts text on the
/// clipboard, which is what keeps it on the right side of "no AI chat box
/// of its own" (docs/decisions.md, 2026-11-25).
@MainActor
final class MarkupNoteBar: NSView, NSTextViewDelegate {
    static let font = NSFont.systemFont(ofSize: 13)
    /// Every line the same height, one that has room for a chip.
    static let lineHeight: CGFloat = 22
    static let widest: CGFloat = 640
    static let corner: CGFloat = 16
    /// How far the bar floats from the preview's edges.
    static let margin: CGFloat = 16
    private static let mostLines: CGFloat = 6
    private static let padding = NSSize(width: inset, height: 14)

    static var attributes: [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = lineHeight
        paragraph.maximumLineHeight = lineHeight
        // A line is taller than its text, to hold a chip. Left alone the
        // text sits at the bottom of the line and the caret, which is as
        // tall as the line, stands well above it. Lifted to the middle,
        // the caret is as far over the text as under it.
        let natural = ceil(font.ascender - font.descender + font.leading)
        return [.font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph,
                .baselineOffset: ((lineHeight - natural) / 2).rounded(.down)]
    }

    private let session: MarkupSession
    /// What the bar is made of: the popover material, a ground over it for
    /// the words, one hairline for an edge and a shadow under it. It was
    /// the system's glass for a day (docs/decisions.md, 2026-11-25): its
    /// rim is soft by design, and the owner wanted an edge.
    private let material = NSVisualEffectView()
    /// The card: what is cut to the bar's shape, and carries its edge.
    private let card = FlippedView()
    /// Everything in the bar.
    private let content = FlippedView()
    /// What the words are read against: the page's raised colour, nearly
    /// opaque. A material alone lets a page's text through as a smear
    /// behind the note's own; this keeps the sentence legible over
    /// anything, and lets a little of the page through to say it floats.
    private let ground = FilledView(color: Chrome.raised.withAlphaComponent(MarkupNoteBar.groundAlpha))
    private static let groundAlpha: CGFloat = 0.86
    /// The edge: black or white at 16%, a step past the chrome's strongest
    /// hairline (12%), because this line is the only thing that says where
    /// the bar ends over a page of any colour.
    private static let edge = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor.white.withAlphaComponent(0.16) : NSColor.black.withAlphaComponent(0.16)
    }
    /// The bar's own padding either side of its words.
    static let inset: CGFloat = 16
    private let clear = HoverFillButton.glyph("trash", "Clear Note")
    private let scroll = NSScrollView()
    private let textLayout = NSLayoutManager()
    let textView: NoteTextView
    private let button = NSButton(title: "Copy", target: nil, action: nil)
    /// The tools, in a row under the text with Copy at its other end, as a
    /// chat composer has it: the words get the bar's whole width, which is
    /// what a narrow column has least of. The chrome's own glyph buttons
    /// (28pt, 8pt corners, a 14pt glyph), the one in hand lit.
    private var tools: [(tool: MarkupTool, button: HoverFillButton)] = []
    private let divider = ToolbarDivider()
    private static let toolRow: CGFloat = Chrome.controlSize
    private static let toolGap: CGFloat = 8
    private let spinner = NSProgressIndicator()
    /// The bar grew or shrank a line: whoever places it lays out again.
    var onHeightChange: () -> Void = {}
    /// The pointer is on a mark's chip, or on none.
    var onHoverMark: (Int?) -> Void = { _ in }
    /// A mark's chip was clicked.
    var onPickMark: (Int) -> Void = { _ in }

    init(session: MarkupSession, placeholders: [String]) {
        self.session = session
        // An explicit TextKit 1 stack on the session's text, so the note
        // outlives this view and a chip is a plain attachment.
        let container = NSTextContainer(size: NSSize(width: 200, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        textLayout.addTextContainer(container)
        session.text.addLayoutManager(textLayout)
        textView = NoteTextView(frame: .zero, textContainer: container)
        material.material = .popover
        material.blendingMode = .withinWindow
        material.state = .active
        super.init(frame: .zero)

        wantsLayer = true
        // Through the view, not the layer: AppKit owns a view's layer and
        // sets its shadow back to none. The first bar had its shadow on
        // the layer, and so no shadow at all.
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
        shadow.shadowBlurRadius = 20
        shadow.shadowOffset = NSSize(width: 0, height: -6)
        self.shadow = shadow

        // One shape cuts everything in the card and carries its edge, so
        // the material, the ground and the line all end on the same pixel.
        card.wantsLayer = true
        card.layer?.cornerRadius = Self.corner
        card.layer?.cornerCurve = .continuous
        card.layer?.masksToBounds = true
        addSubview(card)
        card.addSubview(material)
        card.addSubview(ground)
        card.addSubview(content)

        textView.delegate = self
        textView.placeholders = placeholders
        textView.isRichText = true
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.font = Self.font
        textView.textColor = .labelColor
        textView.typingAttributes = Self.attributes
        textView.insertionPointColor = .controlAccentColor
        textView.textContainerInset = .zero
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.smartInsertDeleteEnabled = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.usesFontPanel = false
        textView.usesRuler = false
        if #available(macOS 15.0, *) {
            // They rewrite the text and would drop the chips.
            textView.writingToolsBehavior = .none
        }
        textView.onReturn = { [weak session] in session?.copyNote() }
        textView.onEscape = { [weak session] in session?.escape() }
        textView.nameOfMark = { [weak session] in session?.mark($0)?.reference }
        textView.onHoverMark = { [weak self] in self?.onHoverMark($0) }
        textView.onPickMark = { [weak self] in self?.onPickMark($0) }
        textView.setAccessibilityLabel("Note")
        // At the end of a note that is come back to. A text view made anew
        // has its caret at the start, and the next mark's chip goes where
        // the caret is: after Esc and back, every new mark landed before
        // the sentence (found by a run over a page, an image and Markdown,
        // 2026-11-25).
        textView.setSelectedRange(NSRange(location: session.text.length, length: 0))

        scroll.documentView = textView
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        content.addSubview(scroll)

        button.bezelStyle = .push
        button.controlSize = .regular
        button.keyEquivalent = "\r"
        button.target = self
        button.action = #selector(copyNote)
        button.setAccessibilityLabel("Copy")
        button.toolTip = "Copy the note (\u{21A9})"
        content.addSubview(button)

        for tool in MarkupTool.allCases {
            let button = HoverFillButton.glyph(tool.symbol, tool.name)
            button.translatesAutoresizingMaskIntoConstraints = true
            button.target = self
            button.action = #selector(pickTool(_:))
            button.tag = tools.count
            content.addSubview(button)
            tools.append((tool, button))
        }
        divider.translatesAutoresizingMaskIntoConstraints = true
        content.addSubview(divider)

        // Only while there is something to clear: absent, not greyed.
        clear.translatesAutoresizingMaskIntoConstraints = true
        clear.target = self
        clear.action = #selector(clearNote)
        content.addSubview(clear)

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        content.addSubview(spinner)

        update()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    /// The view is leaving: the note stays, its text view does not.
    func detach() {
        session.text.removeLayoutManager(textLayout)
        // The undo stack points into the text view that is going.
        session.undo.removeAllActions()
    }

    func undoManager(for view: NSTextView) -> UndoManager? { session.undo }

    func textDidChange(_ notification: Notification) {
        update()
        onHeightChange()
    }

    @objc private func copyNote() { session.copyNote() }

    /// The whole note, marks and words. An edit of the text like any
    /// other, so ⌘Z brings it all back.
    @objc private func clearNote() {
        textView.breakUndoCoalescing()
        textView.insertText("", replacementRange: NSRange(location: 0, length: session.text.length))
        textView.breakUndoCoalescing()
        update()
        onHeightChange()
        focus()
    }

    /// The arrow over the bar and its buttons. The preview around it has
    /// the crosshair, and a button has no pointer of its own to put back.
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }

    /// A press on the bar itself, beside the text: the keyboard to the note.
    override func mouseDown(with event: NSEvent) {
        focus()
    }

    @objc private func pickTool(_ sender: NSButton) {
        guard tools.indices.contains(sender.tag) else { return }
        session.tool = tools[sender.tag].tool
        update()
        // The keyboard stays in the note: a tool is taken up mid-sentence.
        focus()
    }

    /// What the button says and whether it can be pressed.
    func update() {
        let copying = session.isCopying
        button.isEnabled = !session.marks.isEmpty && !copying
        button.title = copying ? "" : "Copy"
        if copying { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        for (tool, button) in tools { button.isSelected = tool == session.tool }
        needsLayout = true
    }

    /// Put a mark's chip where the cursor is, as an edit of its own: ⌘Z
    /// right after takes back that mark and nothing typed before it.
    func insert(_ mark: Mark) {
        textView.breakUndoCoalescing()
        // Before the bar has been laid out there is no width to fit to.
        let room = scroll.contentSize.width
        // After what is selected, never in place of it. A drawing is not
        // typing: with a chip selected (it was just clicked), a new mark
        // put in its place would delete the mark that chip stood for.
        let selection = textView.selectedRange()
        textView.insertText(MarkChip.string(for: mark, font: Self.font,
                                            fitting: room > 60 ? room : .greatestFiniteMagnitude),
                            replacementRange: NSRange(location: NSMaxRange(selection), length: 0))
        textView.breakUndoCoalescing()
        textView.typingAttributes = Self.attributes
        update()
        onHeightChange()
    }

    func focus() {
        window?.makeFirstResponder(textView)
    }

    private var buttonSize: NSSize {
        var size = button.intrinsicContentSize
        // Wide enough that the spinner has room where the word was, and no
        // wider: in a 260pt column the five tools and Copy share 236pt.
        size.width = max(size.width, 56)
        return size
    }

    /// How tall the bar is at a width: its lines, up to six, and never less
    /// than a control's row.
    func height(forWidth width: CGFloat) -> CGFloat {
        let textWidth = max(width - Self.padding.width * 2, 40)
        guard let container = textView.textContainer else { return 44 }
        container.size = NSSize(width: textWidth, height: CGFloat.greatestFiniteMagnitude)
        textLayout.ensureLayout(for: container)
        var used = textLayout.usedRect(for: container).height
        // A line just begun by Return has no glyph yet, and still shows.
        if session.text.string.hasSuffix("\n") || session.text.length == 0 {
            used = max(used, textLayout.extraLineFragmentRect.maxY)
        }
        let lines = max(1, min(Self.mostLines, (used / Self.lineHeight).rounded(.up)))
        return lines * Self.lineHeight + Self.padding.height + Self.toolGap + Self.toolRow + 10
    }

    override func layout() {
        super.layout()
        card.frame = bounds
        material.frame = bounds
        ground.frame = bounds
        content.frame = bounds
        // One pixel of the screen it is on, whatever its scale: a line of
        // one point is two pixels on most Macs, and reads as soft.
        card.layer?.borderWidth = 1 / (window?.backingScaleFactor ?? 2)
        // The row of tools along the bottom, Copy at its far end.
        let row = NSRect(x: 0, y: bounds.height - 10 - Self.toolRow, width: bounds.width, height: Self.toolRow)
        let size = buttonSize
        button.frame = NSRect(x: bounds.width - 12 - size.width, y: row.midY - size.height / 2,
                              width: size.width, height: size.height)
        clear.frame = NSRect(x: button.frame.minX - 6 - Self.toolRow, y: row.minY,
                             width: Self.toolRow, height: Self.toolRow)
        spinner.sizeToFit()
        spinner.frame.origin = NSPoint(x: button.frame.midX - spinner.frame.width / 2,
                                       y: button.frame.midY - spinner.frame.height / 2)
        var x: CGFloat = 10
        for (tool, toolButton) in tools {
            if tool == .move {
                // Apart from the pens: it draws nothing.
                divider.frame = NSRect(x: x + 4, y: row.midY - 8, width: 1, height: 16)
                x += 9
            }
            toolButton.frame = NSRect(x: x, y: row.minY, width: Self.toolRow, height: Self.toolRow)
            x += Self.toolRow + 2
        }
        // There while there is something to clear and room to stand apart
        // from the tools: in the narrowest column the tools and Copy have
        // the row to themselves, and ⌘A then ⌫ clears.
        clear.isHidden = session.text.length == 0 || clear.frame.minX < x + 6
        scroll.frame = NSRect(x: Self.padding.width, y: Self.padding.height,
                              width: max(bounds.width - Self.padding.width * 2, 40),
                              height: max(row.minY - Self.toolGap - Self.padding.height, Self.lineHeight))
        textView.frame.size.width = scroll.contentSize.width
        colour()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        colour()
    }

    private func colour() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            card.layer?.borderColor = Self.edge.cgColor
        }
    }

    /// A rounded shape that stretches: what the material is cut to.
    private static func mask(radius: CGFloat) -> NSImage {
        let side = radius * 2 + 1
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

/// A view that counts from its top-left, to lay the bar's parts out in.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
