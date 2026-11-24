import AppKit
import GhosttyKit

/// A ⌘-click, kept from the release until libghostty has said whether it was
/// on a link. See `SurfaceView.mouseUp` and `TerminalLinkClick`.
extension SurfaceView {
    /// Two points within half a cell of each other: a press and release that
    /// make a click rather than a drag.
    func sameCell(_ a: NSPoint, _ b: NSPoint) -> Bool {
        abs(a.x - b.x) < cellSize.width / 2 && abs(a.y - b.y) < cellSize.height / 2
    }
    /// The rows around `point` (in this view) and the character under it, or
    /// nil when the point is on no character. Read once per ⌘-click: a dozen
    /// reads of one row each.
    func linkClick(at point: NSPoint) -> TerminalLinkClick? {
        guard let surface else { return nil }
        let size = ghostty_surface_size(surface)
        let columns = Int(size.columns), rows = Int(size.rows)
        let scale = window?.backingScaleFactor ?? layer?.contentsScale ?? 2
        let cellWidth = CGFloat(size.cell_width_px) / scale
        let cellHeight = CGFloat(size.cell_height_px) / scale
        guard columns > 0, rows > 0, cellWidth > 0, cellHeight > 0 else { return nil }

        // Where the grid starts, as the accessibility text works it out: the
        // IME point is the bottom of the cursor's cell, so the top padding
        // plus whole cells; column 0 is where a row's read says it starts.
        var x = 0.0, y = 0.0, w = 0.0, h = 0.0
        ghostty_surface_ime_point(surface, &x, &y, &w, &h)
        let paddingTop = CGFloat(y).truncatingRemainder(dividingBy: cellHeight)
        let fromTop = bounds.height - point.y - paddingTop
        guard fromTop >= 0 else { return nil }
        let row = Int(fromTop / cellHeight)
        guard row < rows else { return nil }

        let first = max(0, row - TerminalLink.wrapReach)
        let last = min(rows - 1, row + TerminalLink.wrapReach)
        var texts: [String] = []
        var paddingLeft: CGFloat?
        for r in first...last {
            let read = readViewport(surface, from: (0, r), to: (columns - 1, r))
            texts.append(read?.text ?? "")
            if r == row, let x = read?.x, x >= 0 { paddingLeft = CGFloat(x) }
        }
        guard let paddingLeft, point.x >= paddingLeft else { return nil }
        let column = Int((point.x - paddingLeft) / cellWidth)
        guard column < columns else { return nil }

        // The clicked character's place in its row: the row read up to the
        // click ends with it (`RowCells.build` has why), and the cell read
        // alone is it, or nothing for an empty cell.
        guard let cell = readViewport(surface, from: (column, row), to: (column, row))?.text,
              let character = cell.first, !character.isWhitespace,
              let prefix = readViewport(surface, from: (0, row), to: (column, row))?.text,
              prefix.last == character else { return nil }
        return TerminalLinkClick(rows: texts, row: row - first, index: prefix.count - 1, columns: columns)
    }
}
