import SwiftUI

/// The find bar: one look over a file and over a page.
///
/// What is searched differs (a file's lines, `PreviewFind`; a page,
/// `BrowserFind`), so the bar takes what it shows and what its buttons do
/// rather than either model.
struct FindBar: View {
    @Binding var query: String
    /// What the search has to say: "3 of 12", "No matches", "Not found".
    let summary: String
    /// Whether there is a match to step to.
    let canStep: Bool
    var focused: FocusState<Bool>.Binding
    let next: () -> Void
    let previous: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Find", text: $query)
                .textFieldStyle(.plain)
                .focused(focused)
                // Enter walks matches without leaving the field, the way
                // every find bar on the platform does.
                .onSubmit(next)
            Text(summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            HStack(spacing: 2) {
                Button(action: previous) { Image(systemName: "chevron.up") }
                    .accessibilityLabel("Find Previous")
                Button(action: next) { Image(systemName: "chevron.down") }
                    .accessibilityLabel("Find Next")
            }
            .buttonStyle(.borderless)
            .disabled(!canStep)
            Button("Done", action: dismiss)
                .buttonStyle(.borderless)
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
        .onExitCommand(perform: dismiss)
    }
}
