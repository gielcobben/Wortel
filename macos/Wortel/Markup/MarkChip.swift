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

/// A chip as it is drawn in the note.
///
/// It asks the text view it is drawn in whether it is selected, and if so
/// draws itself solid in its mark's colour (`MarkDrawing.chip`): a chip is
/// selected as a token is, not as a character. The note's layout paints no
/// selection behind it (`NoteLayoutManager`), and the text view redraws a
/// chip whose selection changed (`NoteTextView.setSelectedRanges`), since
/// nothing else would: a cell is drawn again only when its rect is.
final class MarkChipCell: NSTextAttachmentCell {
    private let number: String
    private let numberWidth: CGFloat
    private let name: String
    private let colour: MarkColour
    private let layout: NSRect

    init(number: String, numberWidth: CGFloat, name: String, colour: MarkColour, layout: NSRect) {
        self.number = number
        self.numberWidth = numberWidth
        self.name = name
        self.colour = colour
        self.layout = layout
        super.init(imageCell: nil)
    }

    @available(*, unavailable) required init(coder: NSCoder) { fatalError() }

    override func cellSize() -> NSSize { layout.size }
    override func cellBaselineOffset() -> NSPoint { layout.origin }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        draw(cellFrame, look: MarkDrawing.chip(colour, selected: false, emphasised: false))
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?, characterIndex charIndex: Int,
                       layoutManager: NSLayoutManager) {
        guard let text = controlView as? NSTextView else { return draw(withFrame: cellFrame, in: controlView) }
        let selected = text.selectedRanges.contains { NSLocationInRange(charIndex, $0.rangeValue) }
        // As the system's own selection: in its colour only where typing
        // would go, otherwise dimmed.
        let emphasised = text.window?.isKeyWindow == true && text.window?.firstResponder === text
        draw(cellFrame, look: MarkDrawing.chip(colour, selected: selected, emphasised: emphasised))
    }

    private func draw(_ cellFrame: NSRect, look: MarkDrawing.Chip) {
        // Through an image counted from its bottom-left, in whatever the
        // text view is: the chip's measures were made that way up.
        let (number, numberWidth, name) = (number, numberWidth, name)
        let image = NSImage(size: cellFrame.size, flipped: false) { rect in
            MainActor.assumeIsolated {
                MarkChip.draw(number: number, numberWidth: numberWidth, name: name, look: look, in: rect)
            }
            return true
        }
        image.draw(in: cellFrame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
}

/// A chip's measures and its text: what it says, how it is made into a
/// character of the note, and how a note is read back as words and marks.
@MainActor
enum MarkChip {
    static let height: CGFloat = 20
    private static let nameFont = NSFont.systemFont(ofSize: 12)
    private static let numberFont = NSFont.systemFont(ofSize: 12, weight: .semibold)
    /// Clear room either side of the capsule, part of the chip itself: two
    /// chips side by side, or a chip against a word, otherwise touch.
    private static let gap: CGFloat = 3
    /// Inside the capsule: before the number, between it and the name, and
    /// after the name.
    private static let lead: CGFloat = 7
    private static let between: CGFloat = 5
    private static let trail: CGFloat = 8
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
    static func string(for mark: Mark, fitting width: CGFloat = .greatestFiniteMagnitude) -> NSAttributedString {
        let number = String(mark.number)
        let numberWidth = ceil((number as NSString).size(withAttributes: [.font: numberFont]).width)
        let title = title(of: mark, fitting: width - (lead + numberWidth + between + trail) - gap * 2)
        let titleWidth = ceil((title as NSString).size(withAttributes: [.font: nameFont]).width)
        let size = NSSize(width: gap + lead + numberWidth + between + titleWidth + trail + gap, height: height)

        let attachment = MarkChipAttachment(number: mark.number)
        // Centred on the line's capitals, so a chip neither lifts its line
        // nor hangs below it.
        attachment.bounds = CGRect(x: 0, y: (MarkupNoteBar.font.capHeight - height) / 2,
                                   width: size.width, height: size.height)
        attachment.attachmentCell = MarkChipCell(number: number, numberWidth: numberWidth, name: title,
                                                 colour: mark.colour, layout: attachment.bounds)
        let string = NSMutableAttributedString(attachment: attachment)
        string.addAttributes(MarkupNoteBar.attributes, range: NSRange(location: 0, length: string.length))
        return string
    }

    /// Draw a chip into `rect`, counted from its bottom-left.
    fileprivate static func draw(number: String, numberWidth: CGFloat, name: String, look: MarkDrawing.Chip,
                                 in rect: NSRect) {
        look.fill.setFill()
        NSBezierPath(roundedRect: rect.insetBy(dx: gap, dy: 0), xRadius: 6, yRadius: 6).fill()
        let numberHeight = numberFont.ascender - numberFont.descender
        (number as NSString).draw(
            at: NSPoint(x: rect.minX + gap + lead,
                        y: rect.minY + (rect.height - numberHeight) / 2 - numberFont.descender - 3),
            withAttributes: [.font: numberFont, .foregroundColor: look.number])
        let titleHeight = nameFont.ascender - nameFont.descender
        (name as NSString).draw(
            at: NSPoint(x: rect.minX + gap + lead + numberWidth + between,
                        y: rect.minY + (rect.height - titleHeight) / 2 - nameFont.descender - 3),
            withAttributes: [.font: nameFont, .foregroundColor: look.name])
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
