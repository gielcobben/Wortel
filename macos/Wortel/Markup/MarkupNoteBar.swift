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
    private static let numberFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
    /// A chip names its mark, it does not quote it: the rest of a long
    /// name is in the copied text.
    private static let longest = 28

    /// What a chip says, cut to fit `width` points: a chip cannot wrap, and
    /// one wider than a narrow column's note would be cut off by its edge.
    static func title(of mark: Mark, fitting width: CGFloat = .greatestFiniteMagnitude) -> String {
        var name: String
        if case .area = mark.shape { name = "area" } else { name = mark.name }
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
        let title = title(of: mark, fitting: width - (7 + numberWidth + 5 + 8))
        let titleWidth = ceil((title as NSString).size(withAttributes: [.font: nameFont]).width)
        let size = NSSize(width: 7 + numberWidth + 5 + titleWidth + 8, height: height)
        let colour = MarkDrawing.color(mark.colour)

        let attachment = MarkChipAttachment(number: mark.number)
        // Drawn when it is shown, not once: the colours are the system's and
        // follow light and dark.
        attachment.image = NSImage(size: size, flipped: false) { rect in
            colour.withAlphaComponent(0.15).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
            let numberHeight = numberFont.ascender - numberFont.descender
            (number as NSString).draw(
                at: NSPoint(x: 7, y: (rect.height - numberHeight) / 2 - numberFont.descender - 3),
                withAttributes: [.font: numberFont, .foregroundColor: colour])
            let titleHeight = nameFont.ascender - nameFont.descender
            (title as NSString).draw(
                at: NSPoint(x: 7 + numberWidth + 5, y: (rect.height - titleHeight) / 2 - nameFont.descender - 3),
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
        attributes[.foregroundColor] = NSColor.tertiaryLabelColor
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
    static let widest: CGFloat = 560
    static let corner: CGFloat = 16
    private static let mostLines: CGFloat = 6
    private static let padding = NSSize(width: 14, height: 11)

    static var attributes: [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = lineHeight
        paragraph.maximumLineHeight = lineHeight
        return [.font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph]
    }

    private let session: MarkupSession
    private let material = NSVisualEffectView()
    private let edge = CAShapeLayer()
    private let scroll = NSScrollView()
    private let textLayout = NSLayoutManager()
    let textView: NoteTextView
    private let button = NSButton(title: "Copy", target: nil, action: nil)
    private let spinner = NSProgressIndicator()
    /// The bar grew or shrank a line: whoever places it lays out again.
    var onHeightChange: () -> Void = {}

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
        super.init(frame: .zero)

        wantsLayer = true
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.12
        layer?.shadowRadius = 12
        layer?.shadowOffset = CGSize(width: 0, height: -4)

        material.material = .popover
        material.blendingMode = .withinWindow
        material.state = .active
        material.maskImage = Self.mask(radius: Self.corner)
        addSubview(material)

        edge.fillColor = nil
        edge.lineWidth = 0.5
        layer?.addSublayer(edge)

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
        textView.setAccessibilityLabel("Note")

        scroll.documentView = textView
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        addSubview(scroll)

        button.bezelStyle = .push
        button.controlSize = .regular
        button.keyEquivalent = "\r"
        button.target = self
        button.action = #selector(copyNote)
        button.setAccessibilityLabel("Copy")
        addSubview(button)

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        addSubview(spinner)

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

    /// What the button says and whether it can be pressed.
    func update() {
        let copying = session.isCopying
        button.isEnabled = !session.marks.isEmpty && !copying
        button.title = copying ? "" : "Copy"
        if copying { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        needsLayout = true
    }

    /// Put a mark's chip where the cursor is, as an edit of its own: ⌘Z
    /// right after takes back that mark and nothing typed before it.
    func insert(_ mark: Mark) {
        textView.breakUndoCoalescing()
        // Before the bar has been laid out there is no width to fit to.
        let room = scroll.contentSize.width
        textView.insertText(MarkChip.string(for: mark, font: Self.font,
                                            fitting: room > 60 ? room : .greatestFiniteMagnitude),
                            replacementRange: textView.selectedRange())
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
        // Wide enough that the spinner has room where the word was.
        size.width = max(size.width, 64)
        return size
    }

    /// How tall the bar is at a width: its lines, up to six, and never less
    /// than a control's row.
    func height(forWidth width: CGFloat) -> CGFloat {
        let textWidth = max(width - Self.padding.width * 2 - buttonSize.width - 10, 40)
        guard let container = textView.textContainer else { return 44 }
        container.size = NSSize(width: textWidth, height: CGFloat.greatestFiniteMagnitude)
        textLayout.ensureLayout(for: container)
        var used = textLayout.usedRect(for: container).height
        // A line just begun by Return has no glyph yet, and still shows.
        if session.text.string.hasSuffix("\n") || session.text.length == 0 {
            used = max(used, textLayout.extraLineFragmentRect.maxY)
        }
        let lines = max(1, min(Self.mostLines, (used / Self.lineHeight).rounded(.up)))
        return lines * Self.lineHeight + Self.padding.height * 2
    }

    override func layout() {
        super.layout()
        material.frame = bounds
        let path = CGPath(roundedRect: bounds.insetBy(dx: 0.25, dy: 0.25),
                          cornerWidth: Self.corner, cornerHeight: Self.corner, transform: nil)
        edge.frame = bounds
        edge.path = path
        layer?.shadowPath = path
        let size = buttonSize
        button.frame = NSRect(x: bounds.width - Self.padding.width + 4 - size.width,
                              y: bounds.height - (44 - size.height) / 2 - size.height,
                              width: size.width, height: size.height)
        spinner.sizeToFit()
        spinner.frame.origin = NSPoint(x: button.frame.midX - spinner.frame.width / 2,
                                       y: button.frame.midY - spinner.frame.height / 2)
        scroll.frame = NSRect(x: Self.padding.width, y: Self.padding.height,
                              width: max(button.frame.minX - 10 - Self.padding.width, 40),
                              height: bounds.height - Self.padding.height * 2)
        textView.frame.size.width = scroll.contentSize.width
        colour()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        colour()
    }

    private func colour() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            edge.strokeColor = Chrome.hairlineStrong.cgColor
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
