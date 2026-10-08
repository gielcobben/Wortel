import SwiftUI

/// Something git refused, said in a sentence (`GitMessage`) and given room:
/// a warning glyph, the text in the normal colour at full length, and a soft
/// fill. It replaced red caption text cut off at three or four lines, which
/// was hard to read and usually cut exactly where the reason was.
struct GitNotice: View {
    let message: String
    /// A close button, where the notice outlives the action that caused it.
    var dismiss: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let dismiss {
                Button(action: dismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Dismiss")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.orange.opacity(0.10)))
    }
}
