import AppKit
import SwiftUI

/// A one-line label whose full text is a tooltip, but only while the row has
/// had to cut it short. Hover a truncated name and the ordinary tooltip
/// appears by the pointer after the usual delay; a name that fits shows
/// nothing, so a sidebar of short names stays quiet.
///
/// An `NSTextField` rather than SwiftUI's `Text` because deciding "is this
/// truncated?" needs the field's measured width against the width it was
/// given, and AppKit's `layout()` is where both are known. SwiftUI's `.help`
/// shows whether or not anything is hidden, and AppKit's own expansion
/// tooltip (the text popping over the row in place) was tried and felt like a
/// Finder quirk rather than a tooltip.
///
/// Sized to give way: low horizontal compression resistance, so in the row's
/// HStack it truncates at the trailing slot instead of pushing the status
/// indicator off the edge.
struct TruncatingLabel: NSViewRepresentable {
    let text: String
    var font: NSFont = .systemFont(ofSize: NSFont.systemFontSize)
    var color: NSColor = .labelColor

    func makeNSView(context: Context) -> TruncationAwareField {
        let field = TruncationAwareField(labelWithString: text)
        field.lineBreakMode = .byTruncatingTail
        field.maximumNumberOfLines = 1
        field.allowsExpansionToolTips = false
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: TruncationAwareField, context: Context) {
        if field.stringValue != text { field.stringValue = text }
        if field.font != font { field.font = font }
        if field.textColor != color { field.textColor = color }
        field.refreshToolTip()
    }
}

/// The label itself: re-decides its tooltip whenever it is laid out, since a
/// sidebar resize is what turns a name that fit into one that doesn't.
final class TruncationAwareField: NSTextField {
    /// Drawn in its own colour, not blended with the glass: the sidebar's fade
    /// mask (`SidebarScrollView`) takes vibrancy away, and a label that relied
    /// on it went dark on dark beside a glyph that didn't.
    override var allowsVibrancy: Bool { false }

    override func layout() {
        super.layout()
        refreshToolTip()
    }

    func refreshToolTip() {
        let needed = cell?.cellSize.width ?? 0
        let wanted: String? = needed > bounds.width + 0.5 ? stringValue : nil
        if toolTip != wanted { toolTip = wanted }
    }
}
