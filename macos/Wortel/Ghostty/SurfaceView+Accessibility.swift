// Portions of this file are ported from Ghostty.app (SurfaceView_AppKit.swift,
// Ghostty v1.3.1, https://github.com/ghostty-org/ghostty):
//
//     Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors
//     MIT License. The full notice is in THIRD-PARTY-NOTICES.md.
//
// Wortel's changes and additions are GPL-3.0-or-later, like the rest of
// Wortel (LICENSE).

import AppKit
import GhosttyKit
import os

/// The terminal as an accessibility text area, so a screen reader or a
/// read-aloud app can read it, follow its selection and find where a word sits
/// on screen, as they do in Terminal.app and iTerm2.
///
/// Follows Ghostty.app's `SurfaceView_AppKit` (role, value, selected text, a
/// debounced selection notification) but not its numbers: there the selection
/// range is libghostty's cell offsets against a value counted in Swift
/// characters, and there are no bounds. Here everything is UTF-16 into the
/// visible screen, and `TerminalAXText` maps it to cells. See
/// `docs/accessibility.md`.
///
/// Nothing is read until a client asks: the text is built on the first
/// attribute read after a change, the cell map of a row only when a bounds or
/// selection question touches it, and change notifications only start once
/// some client has asked this process anything.
extension SurfaceView {
    // MARK: - Element

    override func isAccessibilityElement() -> Bool { true }

    override func accessibilityRole() -> NSAccessibility.Role? {
        Self.noteAccessibilityClient()
        return .textArea
    }

    override func accessibilityHelp() -> String? { "Terminal content area" }

    override func accessibilityValue() -> Any? {
        accessibilitySnapshot()?.text.string ?? ""
    }

    override func accessibilityNumberOfCharacters() -> Int {
        accessibilitySnapshot()?.text.length ?? 0
    }

    /// The value is the visible screen, so all of it is visible.
    override func accessibilityVisibleCharacterRange() -> NSRange {
        NSRange(location: 0, length: accessibilitySnapshot()?.text.length ?? 0)
    }

    override func accessibilityString(for range: NSRange) -> String? {
        guard let text = accessibilitySnapshot()?.text, let range = text.clamped(range) else { return nil }
        return (text.string as NSString).substring(with: range)
    }

    override func accessibilityAttributedString(for range: NSRange) -> NSAttributedString? {
        guard let surface, let string = accessibilityString(for: range) else { return nil }
        var attributes: [NSAttributedString.Key: Any] = [:]
        // A copy of the primary font, released once the dictionary holds it
        // (as Ghostty.app's quickLook does).
        if let raw = ghostty_surface_quicklook_font(surface) {
            let font = Unmanaged<CTFont>.fromOpaque(raw)
            attributes[.font] = font.takeUnretainedValue()
            font.release()
        }
        return NSAttributedString(string: string, attributes: attributes)
    }

    override func accessibilityLine(for index: Int) -> Int {
        accessibilitySnapshot()?.text.row(containing: index) ?? 0
    }

    override func accessibilityRange(forLine line: Int) -> NSRange {
        accessibilitySnapshot()?.text.lineRange(line) ?? NSRange(location: NSNotFound, length: 0)
    }

    // MARK: Selection

    /// The selection's text, all of it, also the part scrolled out of view
    /// (Ghostty.app's answer). nil without one.
    override func accessibilitySelectedText() -> String? {
        Self.noteAccessibilityClient()
        guard let surface else { return nil }
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text) else { return nil }
        defer { ghosttyFreeText(&text) }
        guard let pointer = text.text, text.text_len > 0 else { return nil }
        return String(decoding: UnsafeRawBufferPointer(start: pointer, count: Int(text.text_len)),
                      as: UTF8.self)
    }

    /// The selection in the value: its visible part. {0, 0} when there is
    /// none, or none on screen.
    ///
    /// libghostty gives the selection's corners as cells counted from the
    /// viewport's top left (`y * cols + x`, the end cell included), clamped to
    /// the viewport, and `tl_px_x` of -1 when none of it is on screen.
    override func accessibilitySelectedTextRange() -> NSRange {
        let none = NSRange(location: 0, length: 0)
        guard let surface, let snapshot = accessibilitySnapshot(), snapshot.columns > 0 else { return none }
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text) else { return none }
        let start = Int(text.offset_start), length = Int(text.offset_len), visible = text.tl_px_x >= 0
        ghosttyFreeText(&text)
        guard visible else { return none }
        let end = start + length
        let columns = snapshot.columns
        return snapshot.text.range(fromCell: (start / columns, start % columns),
                                   toCell: (end / columns, end % columns),
                                   cells: { self.accessibilityCells(row: $0, in: snapshot) }) ?? none
    }

    // MARK: Where text sits

    /// AXBoundsForRange: the cells `range` covers, in screen coordinates (AppKit
    /// turns them into the top-left global space a client sees, which is what
    /// makes a second display work). A range over several rows is the rectangle
    /// around all of them, as NSTextView answers.
    override func accessibilityFrame(for range: NSRange) -> NSRect {
        guard let snapshot = accessibilitySnapshot(), let window else { return .zero }
        let segments = snapshot.text.segments(
            for: range, cells: { self.accessibilityCells(row: $0, in: snapshot) })
        var union: NSRect?
        for segment in segments {
            let rect = viewRect(of: segment, in: snapshot)
            union = union.map { $0.union(rect) } ?? rect
        }
        guard let union else { return .zero }
        return window.convertToScreen(convert(union, to: nil))
    }

    /// One row's cells in view coordinates. libghostty lays the grid out from
    /// the top left (padding, then whole cells), and the view isn't flipped.
    /// Measured from the top, this also holds while a resize is held and the
    /// last frame is shown pinned top left at its old size.
    private func viewRect(of segment: TerminalAXText.Segment, in snapshot: AccessibilitySnapshot) -> NSRect {
        let x = snapshot.paddingLeft + CGFloat(segment.startColumn) * snapshot.cellWidth
        let top = snapshot.paddingTop + CGFloat(segment.row) * snapshot.cellHeight
        return NSRect(x: x, y: bounds.height - top - snapshot.cellHeight,
                      width: CGFloat(segment.endColumn - segment.startColumn) * snapshot.cellWidth,
                      height: snapshot.cellHeight)
    }

    // MARK: - The text

    /// The visible screen's text, read once per change and kept until output,
    /// a scroll or a resize could have changed it. Every text attribute comes
    /// through here, which is what makes any of them switch notifications on.
    private func accessibilitySnapshot() -> AccessibilitySnapshot? {
        Self.noteAccessibilityClient()
        guard let surface else { return nil }
        let size = ghostty_surface_size(surface)
        let key = AccessibilitySnapshot.Key(
            columns: Int(size.columns), rows: Int(size.rows),
            output: outputGeneration,
            scroll: accessibilityWatch.scrollPosition)
        if let snapshot = accessibilityWatch.snapshot, snapshot.isCurrent(for: key) { return snapshot }
        let snapshot = readAccessibilitySnapshot(surface: surface, size: size, key: key)
        accessibilityWatch.snapshot = snapshot
        return snapshot
    }

    private func readAccessibilitySnapshot(surface: ghostty_surface_t, size: ghostty_surface_size_s,
                                           key: AccessibilitySnapshot.Key) -> AccessibilitySnapshot {
        let columns = Int(size.columns), rows = Int(size.rows)
        var texts: [String] = []
        texts.reserveCapacity(rows)
        var paddingLeft: CGFloat?
        for row in 0..<rows {
            let read = readViewport(surface, from: (0, row), to: (columns - 1, row))
            texts.append(read?.text ?? "")
            if paddingLeft == nil, let x = read?.x, x >= 0 { paddingLeft = x }
        }
        // A row runs on into the next only when the two read together have no
        // newline between them. An empty row ends its line, and so does the
        // row before an empty one (a wrap always carries a character over).
        var endsLine = [Bool](repeating: true, count: rows)
        for row in 0..<max(0, rows - 1) where !texts[row].isEmpty && !texts[row + 1].isEmpty {
            if let both = readViewport(surface, from: (0, row), to: (columns - 1, row + 1)) {
                endsLine[row] = both.text.contains("\n")
            }
        }

        let scale = window?.backingScaleFactor ?? layer?.contentsScale ?? 2
        let cellWidth = CGFloat(size.cell_width_px) / scale
        let cellHeight = CGFloat(size.cell_height_px) / scale
        // The left padding is where column 0 starts (`tl_px_x`, already in
        // points). The top has no such answer, but the IME point is the bottom
        // of the cursor's cell, so it is the top padding plus whole cells.
        var x = 0.0, y = 0.0, w = 0.0, h = 0.0
        ghostty_surface_ime_point(surface, &x, &y, &w, &h)
        let paddingTop = cellHeight > 0 ? CGFloat(y).truncatingRemainder(dividingBy: cellHeight) : 0

        return AccessibilitySnapshot(
            text: TerminalAXText(rows: texts, endsLine: endsLine),
            key: key,
            cellWidth: cellWidth, cellHeight: cellHeight,
            paddingLeft: paddingLeft ?? 0, paddingTop: paddingTop)
    }

    /// Where each character of a row sits, read the first time it's needed.
    private func accessibilityCells(row: Int, in snapshot: AccessibilitySnapshot) -> RowCells? {
        if let cells = snapshot.cells[row] { return cells }
        guard let surface, snapshot.text.rowStarts.indices.contains(row) else { return nil }
        let start = snapshot.text.rowStarts[row]
        let rowText = (snapshot.text.string as NSString)
            .substring(with: NSRange(location: start, length: snapshot.text.rowLengths[row]))
        let cells = RowCells.build(
            text: rowText, columns: snapshot.columns,
            prefix: { self.readViewport(surface, from: (0, row), to: ($0, row))?.text },
            cell: { self.readViewport(surface, from: ($0, row), to: ($0, row))?.text })
        // nil: the screen moved under us. The next change drops the snapshot.
        if let cells { snapshot.cells[row] = cells }
        return cells
    }

    /// A region of the viewport, both corners included, and where its first
    /// cell starts (`tl_px_x`, -1 when off screen).
    private func readViewport(_ surface: ghostty_surface_t,
                              from start: (x: Int, y: Int), to end: (x: Int, y: Int)) -> (text: String, x: Double)? {
        func point(_ p: (x: Int, y: Int)) -> ghostty_point_s {
            ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_EXACT,
                            x: UInt32(max(0, p.x)), y: UInt32(max(0, p.y)))
        }
        let region = ghostty_selection_s(top_left: point(start), bottom_right: point(end), rectangle: false)
        var text = ghostty_text_s()
        guard ghostty_surface_read_text(surface, region, &text) else { return nil }
        defer { ghosttyFreeText(&text) }
        let string = text.text.map {
            String(decoding: UnsafeRawBufferPointer(start: $0, count: Int(text.text_len)), as: UTF8.self)
        } ?? ""
        return (string, text.tl_px_x)
    }

    // MARK: - Notifications

    /// Some accessibility client has asked about a terminal. Until then
    /// nothing is posted and output costs one lock take.
    static func noteAccessibilityClient() {
        SurfaceAccessibilityWatch.clientSeen.withLock { $0 = true }
    }

    /// Output, a scroll or a resize changed (or may have changed) the screen,
    /// at most every quarter second: forget the text, tell whoever listens.
    /// A terminal not on screen says so when it's shown again.
    func accessibilityScreenChanged() {
        accessibilityWatch.snapshot = nil
        guard window != nil, !isHiddenOrHasHiddenAncestor else {
            accessibilityWatch.missedChange = true
            return
        }
        accessibilityWatch.missedChange = false
        NSAccessibility.post(element: self, notification: .valueChanged)
        // Not the selection: only a click, a drag or a key changes that, and
        // reading it formats all of its text, which after a Select All over
        // the scrollback is megabytes four times a second.
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        accessibilityChangeMissedWhileAway()
    }

    /// Shown again (unhidden, or put in a window): say what changed meanwhile.
    func accessibilityChangeMissedWhileAway() {
        if accessibilityWatch.missedChange { accessibilityScreenChanged() }
    }

    /// A click, a drag or a key may have changed the selection. Looked at a
    /// tenth of a second after the first of a run of them (Ghostty.app's
    /// debounce), and posted only when it really changed.
    func accessibilitySelectionMayHaveChanged() {
        guard SurfaceAccessibilityWatch.clientSeen.withLock({ $0 }),
              !accessibilityWatch.selectionCheckScheduled else { return }
        accessibilityWatch.selectionCheckScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.accessibilityWatch.selectionCheckScheduled = false
                let digest = self.selectionDigest()
                guard digest != self.accessibilityWatch.selectionDigest else { return }
                self.accessibilityWatch.selectionDigest = digest
                guard self.window != nil, !self.isHiddenOrHasHiddenAncestor else { return }
                NSAccessibility.post(element: self, notification: .selectedTextChanged)
            }
        }
    }

    private func selectionDigest() -> SurfaceAccessibilityWatch.SelectionDigest? {
        guard let surface, ghostty_surface_has_selection(surface) else { return nil }
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text) else { return nil }
        defer { ghosttyFreeText(&text) }
        return .init(start: text.offset_start, length: text.offset_len,
                     visible: text.tl_px_x >= 0, textLength: Int(text.text_len))
    }
}

/// One reading of the visible screen and the grid it sits in.
final class AccessibilitySnapshot {
    /// What it was read against: any change means read again.
    struct Key: Equatable {
        let columns: Int
        let rows: Int
        /// `PtyHost.outputGeneration`; nil on the exec backend, which has none.
        let output: UInt64?
        let scroll: SurfaceAccessibilityWatch.ScrollPosition?
    }

    let text: TerminalAXText
    let key: Key
    var columns: Int { key.columns }
    let cellWidth: CGFloat
    let cellHeight: CGFloat
    let paddingLeft: CGFloat
    let paddingTop: CGFloat
    let taken = Date()
    /// Rows' cell maps, filled in as bounds and selection questions need them.
    var cells: [Int: RowCells] = [:]

    init(text: TerminalAXText, key: Key, cellWidth: CGFloat, cellHeight: CGFloat,
         paddingLeft: CGFloat, paddingTop: CGFloat) {
        self.text = text
        self.key = key
        self.cellWidth = cellWidth
        self.cellHeight = cellHeight
        self.paddingLeft = paddingLeft
        self.paddingTop = paddingTop
    }

    /// Without an output count (the exec backend) a reading is trusted for a
    /// quarter second, as Ghostty.app caches its own; with one, for a second
    /// as a backstop, since the count moves just after libghostty is handed
    /// the bytes, not after it has drawn them.
    func isCurrent(for key: Key) -> Bool {
        guard key == self.key else { return false }
        return Date().timeIntervalSince(taken) < (key.output == nil ? 0.25 : 1)
    }
}

/// A terminal's accessibility state, and the one part of it that output on
/// the pty's queue touches. Owned by its `SurfaceView` and created before its
/// surface, so the pty's output handler can hold it.
final class SurfaceAccessibilityWatch: @unchecked Sendable {
    /// Some client has asked; process-wide, never reset.
    static let clientSeen = OSAllocatedUnfairLock(initialState: false)

    struct ScrollPosition: Equatable {
        let total: UInt64
        let offset: UInt64
    }

    struct SelectionDigest: Equatable {
        let start: UInt32
        let length: UInt32
        let visible: Bool
        let textLength: Int
    }

    private struct Shared {
        var pending = false
        var scroll: ScrollPosition?
    }

    private let shared = OSAllocatedUnfairLock(initialState: Shared())

    /// Called on the main thread, at most every `interval` while the screen
    /// keeps changing. Set once by the view.
    var onChange: (() -> Void)?
    private let interval: TimeInterval = 0.25

    // Main thread only.
    var snapshot: AccessibilitySnapshot?
    var missedChange = false
    var selectionCheckScheduled = false
    var selectionDigest: SelectionDigest?

    var scrollPosition: ScrollPosition? { shared.withLock { $0.scroll } }

    /// The program wrote to the terminal. Any thread; one or two lock takes.
    func outputArrived() {
        guard Self.clientSeen.withLock({ $0 }) else { return }
        let schedule = shared.withLock { state -> Bool in
            guard !state.pending else { return false }
            state.pending = true
            return true
        }
        guard schedule else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + interval) { [self] in
            shared.withLock { $0.pending = false }
            MainActor.assumeIsolated { onChange?() }
        }
    }

    /// libghostty's scrollbar moved: the viewport scrolled, or the history
    /// grew under it. Any thread.
    func scrolled(total: UInt64, offset: UInt64) {
        shared.withLock { $0.scroll = ScrollPosition(total: total, offset: offset) }
        outputArrived()
    }
}
