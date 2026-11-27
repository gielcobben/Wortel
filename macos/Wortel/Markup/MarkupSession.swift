import AppKit
import Observation

/// Mark-up for one preview: whether it is on, the marks, and the note.
///
/// One per page, file tab and preview window, beside its find. It holds no
/// view. The layer over the preview (`MarkupOverlayView`) comes and goes
/// with the tab; this stays, so a note is still there when the tab comes
/// back, and when mark-up is turned on again after Esc or a copy. It ends
/// when what it was made over goes elsewhere (`end`).
///
/// **The note's text is what says which marks exist.** A mark is a chip in
/// the text, so deleting the chip removes the mark, and undoing that brings
/// both back, with nothing kept in step by hand.
@Observable
@MainActor
final class MarkupSession: NSObject, NSTextStorageDelegate {
    private(set) var isOn = false
    /// The marks whose chips are in the note, in the order they were made.
    private(set) var marks: [Mark] = []
    /// The pictures and the details file are being written.
    private(set) var isCopying = false
    /// A copy just landed: the header's button says so for a moment.
    private(set) var justCopied = false

    /// The note: what was typed, with a chip per mark.
    @ObservationIgnored let text = NSTextStorage()
    /// The note's own undo stack. A text view left to find one takes the
    /// window's, which outlives it and crashed the app from the commit box
    /// (`CommitMessageEditor`).
    @ObservationIgnored let undo = UndoManager()

    /// The preview under the marks.
    @ObservationIgnored var surface: (any MarkupSurface)?
    /// A file's views, which register here as they are made (`MarkupViews`).
    @ObservationIgnored let views = MarkupViews()
    /// What is being marked up, asked when a note is copied.
    @ObservationIgnored var subject: () -> MarkupSubject = { .page("") }
    @ObservationIgnored var place = MarkupPlace.page
    /// Mark-up went on or off: what its owner does about it (a page stops
    /// taking the swipe back, and reloads what it put off).
    @ObservationIgnored var onChange: () -> Void = {}
    /// The layer the marks are drawn on, and tied and pictured through.
    /// A file's note can be on screen more than once (two windows, or two
    /// splits, showing the file), and then this is the layer last shown
    /// or used (`MarkupOverlayView.claim`).
    @ObservationIgnored weak var overlay: MarkupOverlayView?
    /// Every layer on the note now, `overlay` among them.
    @ObservationIgnored let layers = NSHashTable<MarkupOverlayView>.weakObjects()
    /// Where the pictures go and where the note is copied to: the app's
    /// own, unless something trying this out says otherwise.
    @ObservationIgnored var store = MarkupStore.shared
    @ObservationIgnored var pasteboard = NSPasteboard.general

    /// The tool in hand. Kept with the note: what you were drawing with is
    /// what you draw with when the tab comes back.
    @ObservationIgnored var tool = MarkupTool.box {
        didSet { if tool != oldValue { everyLayer { $0.toolChanged() } } }
    }

    /// Tell every layer on the note, the one in use last.
    private func everyLayer(_ tell: (MarkupOverlayView) -> Void) {
        for layer in layers.allObjects where layer !== overlay { tell(layer) }
        if let overlay { tell(overlay) }
    }

    /// Every mark made for this note, those whose chip was deleted too: an
    /// undo brings a chip back, and its mark with it.
    @ObservationIgnored private var known: [Int: Mark] = [:]
    @ObservationIgnored private var nextNumber = 1
    /// The count is starting over at 1 with no mark made yet: every chip
    /// was taken out, and a number was taken for a mark on its way. What
    /// the next number would have been, for when no mark comes of it.
    @ObservationIgnored private var restarting: Int?
    @ObservationIgnored private var folder: URL?
    @ObservationIgnored private var copies = 0
    @ObservationIgnored private var copiedFlash: DispatchWorkItem?
    /// The pictures' file names used in the note's folder. None is used
    /// twice: a path once copied may be pasted days later, and must still
    /// show what it showed.
    @ObservationIgnored private var pictureNames: Set<String> = []
    /// Which copy is the one that counts. `end` moves it on, so a copy
    /// still being made for a note that is gone lands nowhere, even after a
    /// newer copy has started.
    @ObservationIgnored private var copyNumber = 0
    /// Edits to the note, and how many of them the last copy had in it.
    @ObservationIgnored private var edits = 0
    @ObservationIgnored private var editsCopied = 0

    /// The folders of notes that are still open, which the sweep leaves.
    private static var open: Set<String> = []

    override init() {
        super.init()
        text.delegate = self
    }

    /// Whether there is anything to come back to.
    var hasNote: Bool { !marks.isEmpty || text.length > 0 }

    /// The note has words or marks that were never copied: a reload nobody
    /// asked for waits for them (`BrowserPage.holdsReload`).
    var hasUncopied: Bool { hasNote && edits != editsCopied }

    // MARK: - On, off, gone

    func toggle() {
        if isOn { turnOff() } else { turnOn() }
    }

    func turnOn() {
        guard !isOn else { return }
        isOn = true
        justCopied = false
        Telemetry.capture(.markupStarted(where: place))
        onChange()
    }

    /// Esc, the header's button, or a copy: out of mark-up, the note kept.
    func turnOff() {
        guard isOn else { return }
        isOn = false
        onChange()
    }

    /// Esc. What is in hand is let go first, then a selection is dropped;
    /// only with neither does it leave mark-up (`MarkupOverlayView.stepBack`).
    func escape() {
        if overlay?.stepBack() == true { return }
        turnOff()
    }

    /// What was marked up went elsewhere: a new address, a reload, another
    /// view of the file, a closed tab. The marks would point at nothing, so
    /// they go, and the note with them. cmux does the same; a lock on the
    /// header was weighed and left out (docs/decisions.md, 2026-11-25).
    func end() {
        let wasOn = isOn
        guard wasOn || hasNote || !known.isEmpty else { return }
        isOn = false
        isCopying = false
        copyNumber += 1
        known = [:]
        nextNumber = 1
        restarting = nil
        copies = 0
        tool = .box
        if let folder { Self.open.remove(folder.path) }
        folder = nil
        pictureNames = []
        undo.removeAllActions()
        text.setAttributedString(NSAttributedString())
        edits = 0
        editsCopied = 0
        marks = []
        everyLayer { $0.marksChanged() }
        surface?.deactivate(forgetting: true)
        if wasOn { onChange() }
    }

    // MARK: - Marks

    /// The number the next mark takes. With no chip left in the note the
    /// count starts over at 1, but the cleared marks are let go only once
    /// a mark is made (`add`): until then an undo can still bring them
    /// back. Letting go here, before the preview had said whether a click
    /// made anything, meant one click on nothing after Clear took the
    /// note's whole undo with it (found in review, 2026-11-27).
    func takeNumber() -> Int {
        if marks.isEmpty, !known.isEmpty, restarting == nil {
            restarting = nextNumber
            nextNumber = 1
        }
        defer { nextNumber += 1 }
        return nextNumber
    }

    /// The number the next mark will take, without taking it: what colour
    /// a stroke is while it is still being drawn.
    var upcomingNumber: Int { marks.isEmpty && !known.isEmpty && restarting == nil ? 1 : nextNumber }

    /// A number taken for a mark that was not made after all (a click on
    /// nothing): given back, so the marks that are made count 1, 2, 3.
    func giveBack(_ number: Int) {
        if let was = restarting {
            // Every mark in `known` is from before the count started over.
            if number == nextNumber - 1 { nextNumber = number }
            // Nothing taken since is still on its way: the count goes on
            // where it was, as if it had never started over.
            if nextNumber == 1 {
                nextNumber = was
                restarting = nil
            }
            return
        }
        if number == nextNumber - 1, known[number] == nil { nextNumber = number }
    }

    /// A mark was made: its chip goes into the note where the cursor is.
    func add(_ mark: Mark) {
        if restarting != nil {
            // The first mark since the count started over: the cleared ones
            // cannot come back now, or there would be two of a number. One
            // taken again since is a new mark's on the preview, tied over
            // the old one; those not taken again are let go.
            for number in known.keys where number >= nextNumber { surface?.forget(number) }
            known = [:]
            restarting = nil
            undo.removeAllActions()
        }
        known[mark.number] = mark
        if let overlay {
            overlay.insertChip(for: mark)
        } else {
            text.append(MarkChip.string(for: mark))
        }
    }

    func mark(_ number: Int) -> Mark? { known[number] }

    /// A drawing was moved or resized: it is the same mark, with the same
    /// number and chip, somewhere else. Its picture is taken again by
    /// whoever moved it.
    func replace(_ mark: Mark) {
        guard known[mark.number] != nil else { return }
        var moved = mark
        moved.picture = known[mark.number]?.picture
        known[mark.number] = moved
        edits += 1
        if let index = marks.firstIndex(where: { $0.number == mark.number }) { marks[index] = moved }
        everyLayer { $0.marksChanged() }
    }

    /// A mark's picture, taken when it is made and written at once: what
    /// a note holds while it waits is a path, not a bitmap.
    func keep(_ picture: CGImage, for number: Int) {
        guard known[number] != nil, let folder = noteFolder() else { return }
        var name = "\(number).png", again = 1
        while pictureNames.contains(name) {
            again += 1
            name = "\(number)-\(again).png"
        }
        pictureNames.insert(name)
        let url = folder.appendingPathComponent(name)
        MarkupStore.queue.async { MarkupStore.write(picture, to: url) }
        known[number]?.picture = name
        if let index = marks.firstIndex(where: { $0.number == number }) { marks[index].picture = name }
    }

    private func noteFolder() -> URL? {
        if let folder { return folder }
        guard let made = store.newFolder() else { return nil }
        folder = made
        Self.open.insert(made.path)
        // A new folder is also when old ones go: an app left running for
        // weeks has no launch to sweep at.
        let keeping = Self.open, store = store
        MarkupStore.queue.async { store.sweep(keeping: keeping) }
        return made
    }

    // The note's text changed: the marks are the chips in it.
    nonisolated func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
                                 range editedRange: NSRange, changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters) else { return }
        MainActor.assumeIsolated {
            edits += 1
            let present = Set(MarkChip.numbers(in: textStorage))
            let now = known.values.filter { present.contains($0.number) }.sorted { $0.number < $1.number }
            guard now != marks else { return }
            marks = now
            everyLayer { $0.marksChanged() }
        }
    }

    // MARK: - Copy

    /// Return: the pictures and the details file are written, and the note
    /// goes on the clipboard as plain text with their paths. Nothing is
    /// typed into a terminal and nothing is sent.
    func copyNote() {
        guard isOn, !isCopying, !marks.isEmpty else { return }
        isCopying = true
        copyNumber += 1
        let number = copyNumber, edits = edits
        let marks = marks
        let pieces = MarkChip.pieces(in: text)
        let subject = subject()
        let folder = noteFolder()
        copies += 1
        let suffix = copies > 1 ? "-\(copies)" : ""
        let appearance = overlay?.effectiveAppearance ?? NSApp.effectiveAppearance
        let colours = marks.reduce(into: [Int: CGColor]()) {
            $0[$1.number] = MarkDrawing.resolved($1.colour, in: appearance)
        }

        let finish: (MarkupWhole?) -> Void = { [weak self] whole in
            MarkupStore.queue.async {
                var wholePicture: MarkupNote.Whole?
                var detailsPath: String?
                if let folder {
                    if let whole, let picture = MarkupPicture.whole(whole, marks: marks, colours: colours) {
                        let url = folder.appendingPathComponent("whole\(suffix).png")
                        if MarkupStore.write(picture.image, to: url) {
                            wholePicture = .init(path: url.path, kind: picture.kind, missing: picture.missing)
                        }
                    }
                    let details = MarkupDetailsFile(
                        subject: subject, whole: wholePicture?.path,
                        marks: marks.map { mark in
                            var details = mark.details
                            details.number = mark.number
                            details.colour = mark.colour.name
                            details.name = mark.reference
                            details.picture = mark.picture.map { folder.appendingPathComponent($0).path }
                            if let placement = whole?.placements[mark.number] {
                                let box = placement.box(of: mark.shape)
                                details.bounds = [box.minX, box.minY, box.width, box.height]
                                    .map { (Double($0) * 10).rounded() / 10 }
                            }
                            return details
                        })
                    let url = folder.appendingPathComponent("details\(suffix).json")
                    if (try? details.encoded().write(to: url, options: .atomic)) != nil { detailsPath = url.path }
                }
                var references: [Int: MarkupNote.Reference] = [:]
                for mark in marks {
                    references[mark.number] = .init(
                        text: mark.reference,
                        picture: mark.picture.flatMap { name in folder?.appendingPathComponent(name).path })
                }
                let copied = MarkupNote.copied(pieces: pieces, marks: references, subject: subject,
                                               whole: wholePicture, details: detailsPath)
                DispatchQueue.main.async { self?.finishCopy(copied, marks: marks, number: number, edits: edits) }
            }
        }
        if let surface { surface.whole(marks, reply: finish) } else { finish(nil) }
    }

    private func finishCopy(_ copied: String, marks: [Mark], number: Int, edits: Int) {
        // Ended while the pictures were written: there is no note to copy,
        // and the clipboard may hold a newer one by now.
        guard isCopying, number == copyNumber else { return }
        isCopying = false
        // What was typed while the pictures were written is not in this copy.
        editsCopied = edits
        pasteboard.clearContents()
        pasteboard.setString(copied, forType: .string)
        Telemetry.capture(.markupCopied(where: place, marks: CountBucket(marks.count),
                                        picked: marks.contains { $0.shape == .thing }))
        turnOff()
        justCopied = true
        copiedFlash?.cancel()
        let flash = DispatchWorkItem { [weak self] in self?.justCopied = false }
        copiedFlash = flash
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4, execute: flash)
    }
}

extension PreviewDocument {
    /// What mark-up would be over, as the file is shown now, or nil where
    /// there is nothing to mark: a Quick Look preview (which is closed to
    /// the app), an empty file, a diff with no changes.
    var markupPlace: MarkupPlace? {
        guard let view = markupView else { return nil }
        switch view {
        case .source: return sourceLines.isEmpty ? nil : view
        case .diff: return diffLoaded && !diffIsBinary && !diffLines.isEmpty ? view : nil
        case .rendered: return blocks.isEmpty ? nil : view
        case .image, .page: return view
        }
    }

    /// The view of the file that is showing, with something in it to mark
    /// or not: a diff the agent has emptied is still the diff, and so is
    /// one being loaded again after the file was rewritten.
    var markupView: MarkupPlace? {
        if isBinary { return PreviewMode.isImage(url) ? .image : nil }
        switch mode {
        case .source: return .source
        case .diff: return .diff
        case .rendered: return PreviewMode.isSVG(url) ? .image : .rendered
        }
    }
}

extension MarkupSession {
    /// Get ready to mark up a file as it is shown now: the adapter for
    /// that view of it, and what the note will say was marked up. False
    /// where there is nothing to mark.
    ///
    /// Another view of the file than last time is another thing to mark
    /// up: the marks on the old one would point at nothing, so they go
    /// (`end`), as they do when a page goes elsewhere.
    @discardableResult
    func prepare(for document: PreviewDocument) -> Bool {
        guard let place = document.markupPlace else { return false }
        if surface == nil || self.place != place {
            end()
            switch place {
            case .source, .diff: surface = LinesMarkupSurface(views: views)
            case .rendered: surface = BlocksMarkupSurface(views: views)
            case .image: surface = ImageMarkupSurface(views: views)
            case .page: return false
            }
            self.place = place
        }
        let path = document.url.path
        let view: String? = place == .image ? nil : document.mode.title
        subject = { .file(path: path, view: view) }
        return true
    }

    /// Whether the layer lies over the file as it is shown now: while on,
    /// over the view it was turned on in, also once that view has nothing
    /// left to mark. A file rewritten under its marks is not elsewhere, so
    /// a diff the agent emptied keeps the note in sight, its marks with no
    /// place, as a deleted line's mark has none (docs/decisions.md,
    /// 2026-11-26).
    func isShown(over document: PreviewDocument) -> Bool {
        isOn && surface != nil && document.markupView == place
    }

    /// Whether a file's header offers the button: where there is something
    /// to mark, and wherever mark-up is on, so it can be turned off where
    /// it is.
    func isOffered(over document: PreviewDocument) -> Bool {
        isOn || document.markupPlace != nil
    }
}
