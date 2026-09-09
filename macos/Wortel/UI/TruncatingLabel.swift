import AppKit
import SwiftUI

/// A one-line label that shows its full text the native way when it doesn't
/// fit: hover it and AppKit pops the whole string over the row, exactly as
/// Finder's sidebar and Mail's message list do, and only when the text is
/// actually cut off. SwiftUI's `Text` has no equivalent (`.help` is a tooltip
/// whether or not anything is hidden), so the label is an `NSTextField` with
/// `allowsExpansionToolTips` on, hosted inside the SwiftUI row.
///
/// Sized to give way: the field's horizontal compression resistance is low, so
/// in the row's HStack it truncates at the trailing slot instead of pushing
/// the status indicator off the edge.
struct TruncatingLabel: NSViewRepresentable {
    let text: String
    var font: NSFont = .systemFont(ofSize: NSFont.systemFontSize)
    var color: NSColor = .labelColor

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.lineBreakMode = .byTruncatingTail
        field.maximumNumberOfLines = 1
        field.allowsExpansionToolTips = true
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        if field.stringValue != text { field.stringValue = text }
        if field.font != font { field.font = font }
        if field.textColor != color { field.textColor = color }
    }
}
