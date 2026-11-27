import AppKit

/// The note bar: where the sentence is written, floating at the bottom of
/// the preview.
///
/// It is the command palette's card (the `.popover` material, 16pt corners,
/// a hairline, a soft shadow) holding a text view, the tools and the system's
/// default button. It talks to nobody and sends nothing: Return puts text on
/// the clipboard, which is what keeps it on the right side of "no AI chat box
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
    /// The bar's own padding either side of its words.
    static let inset: CGFloat = 16
    private static let mostLines: CGFloat = 6
    private static let padding = NSSize(width: inset, height: 14)
    private static let toolRow: CGFloat = Chrome.controlSize
    private static let toolGap: CGFloat = 8
    private static let groundAlpha: CGFloat = 0.86
    /// The edge: black or white at 16%, a step past the chrome's strongest
    /// hairline (12%), because this line is the only thing that says where
    /// the bar ends over a page of any colour.
    private static let edge = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor.white.withAlphaComponent(0.16) : NSColor.black.withAlphaComponent(0.16)
    }

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
    private let scroll = NSScrollView()
    private let textLayout = NoteLayoutManager()
    let textView: NoteTextView
    /// The tools, in a row under the text with Copy at its other end, as a
    /// chat composer has it: the words get the bar's whole width, which is
    /// what a narrow column has least of. The chrome's own glyph buttons
    /// (28pt, 8pt corners, a 14pt glyph), the one in hand lit.
    private var tools: [(tool: MarkupTool, button: HoverFillButton)] = []
    private let divider = ToolbarDivider()
    private let clear = HoverFillButton.glyph("trash", "Clear Note")
    private let button = CopyButton(title: "Copy", target: nil, action: nil)
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

    /// The view is back: its text view shows the note again, the caret at
    /// its end, where the next chip goes.
    func attach() {
        guard !session.text.layoutManagers.contains(textLayout) else { return }
        session.text.addLayoutManager(textLayout)
        textView.setSelectedRange(NSRange(location: session.text.length, length: 0))
        textView.typingAttributes = Self.attributes
        update()
        onHeightChange()
    }

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
        textView.insertText(MarkChip.string(for: mark, fitting: room > 60 ? room : .greatestFiniteMagnitude),
                            replacementRange: NSRange(location: NSMaxRange(selection), length: 0))
        textView.breakUndoCoalescing()
        textView.typingAttributes = Self.attributes
        update()
        onHeightChange()
    }

    /// Select a mark's chip, as a click on it does, and scroll the note to
    /// it if the note is long. Nothing else: the mark is where it is.
    func selectChip(_ number: Int) {
        guard let range = textView.range(ofChip: number) else { return }
        focus()
        textView.setSelectedRange(range)
        textView.scrollRangeToVisible(range)
    }

    func focus() {
        window?.makeFirstResponder(textView)
    }

    // MARK: - Layout

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
}

/// Copy: drawn as the default button, and never pressed by a key.
///
/// The look is Return's: a push button is the default one while Return is
/// its key equivalent. The key itself is the note's (`NoteTextView` copies
/// on Return, and leaves ⇧Return, ⌥Return and an input method's Return to
/// the text). Left to the button, Return anywhere in the window copied: the
/// key window offers every key to its views before the first responder,
/// and a key that climbs the responder chain to the window presses its
/// default button, so the address field, the find field and a terminal in
/// another split lost their Return to a copy.
private final class CopyButton: NSButton {
    override func performKeyEquivalent(with event: NSEvent) -> Bool { false }
}

/// A view that counts from its top-left, to lay the bar's parts out in.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
