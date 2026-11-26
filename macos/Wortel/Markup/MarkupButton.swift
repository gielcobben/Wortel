import AppKit
import SwiftUI

/// The button that turns mark-up on, in the bar each preview already has.
/// The system's own Markup glyph, drawn as the header's other buttons are,
/// and lit while mark-up is on.
struct MarkupButton: View {
    let session: MarkupSession
    var size: CGFloat = 24
    /// Get the session ready for what is shown now, and say whether there
    /// is anything to mark. A page is always ready.
    var prepare: () -> Bool = { true }

    var body: some View {
        Button {
            if session.isOn || prepare() { session.toggle() }
        } label: {
            Image(systemName: session.justCopied ? "checkmark" : "pencil.tip.crop.circle")
                .font(.system(size: 13))
                .frame(width: size, height: size)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color(nsColor: session.isOn ? Chrome.selectedFill : .clear)))
                .contentShape(Rectangle())
        }
        .buttonStyle(HoverFillStyle())
        .foregroundStyle(.secondary)
        .help(session.justCopied ? "Copied" : "Mark Up (\u{21E7}\u{2318}M)")
        .accessibilityLabel("Mark Up")
    }
}
