import SwiftUI

/// The page of an empty tab: what it can become, one row each, with the key
/// that opens the same thing without asking.
///
/// A row's "+" opens one, and so do the titlebar's two split buttons, in the
/// split they make. The first click gives you the place and this page asks
/// what goes in it. The owner's words, of the Claude app's side panel, which
/// works this way: "it's still two clicks but since the panel already shows
/// on one click the one other click feels simpler". Before it the "+" was a
/// menu (two clicks, and nothing on screen in between), and for a few hours
/// Changes, History, Files and a browser were buttons in the titlebar, which
/// opened them in one place only and crowded the row under them.
struct NewTabPage: View {
    let git: GitPanelModel
    /// The empty tab this is the page of.
    let tab: SideTab
    let region: TabRegion

    @State private var highlighted: Int?
    @FocusState private var hasKeyboard: Bool

    private struct Row: Identifiable {
        let id: Int
        let title: String
        let symbol: String
        let shortcut: String
        let choice: GitPanelModel.NewTabChoice
        /// The key that picks it on this page: its first letter, which is
        /// also the letter of its shortcut.
        var letter: String { title.prefix(1).lowercased() }
    }

    private var rows: [Row] {
        var rows = [
            Row(id: 0, title: "Terminal", symbol: "apple.terminal", shortcut: "⌘T", choice: .terminal),
            Row(id: 1, title: "Browser", symbol: "globe", shortcut: "⇧⌘B", choice: .browser),
        ]
        // ⇧⌘ and the first letter, as the menus have them (`MainMenu`).
        for (index, pane) in InspectorPane.allCases.enumerated() {
            rows.append(Row(id: 2 + index, title: pane.title, symbol: pane.symbol,
                            shortcut: "⇧⌘" + pane.title.prefix(1), choice: .pane(pane)))
        }
        return rows
    }

    var body: some View {
        VStack(spacing: 2) {
            ForEach(rows) { row in
                Button {
                    git.fill(tab, with: row.choice)
                } label: {
                    label(for: row)
                }
                .buttonStyle(.plain)
                .onHover { inside in
                    if inside { highlighted = row.id } else if highlighted == row.id { highlighted = nil }
                }
            }
        }
        .frame(maxWidth: 320)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .focusable()
        .focusEffectDisabled()
        .focused($hasKeyboard)
        .onKeyPress(.downArrow) { step(1) }
        .onKeyPress(.upArrow) { step(-1) }
        .onKeyPress(.return) {
            guard let highlighted, let row = rows.first(where: { $0.id == highlighted }) else { return .ignored }
            git.fill(tab, with: row.choice)
            return .handled
        }
        .onKeyPress(.escape) {
            git.dismissBlank(tab)
            return .handled
        }
        // A row's first letter, alone: T, B, C, H, F. The page is a list of
        // five things with five different first letters, and the same
        // letters are their keys everywhere else (with ⇧⌘, or ⌘ for the
        // terminal), so here, where nothing can be typed, the letter is
        // enough. With ⌘, ⌃ or ⌥ held it is somebody else's key.
        .onKeyPress(characters: .letters) { press in
            guard press.modifiers.isDisjoint(with: [.command, .control, .option]),
                  let row = rows.first(where: { $0.letter == press.characters.lowercased() })
            else { return .ignored }
            git.fill(tab, with: row.choice)
            return .handled
        }
        // The keyboard, when this is the split you are in: the terminal the
        // tab now covers must not keep it. On appearing, on being come to
        // from another split, and on a click in the page.
        .onAppear { if git.lastRegion == region { hasKeyboard = true } }
        .onChange(of: git.newTabFocusRequest) { if git.lastRegion == region { hasKeyboard = true } }
        .simultaneousGesture(TapGesture().onEnded { hasKeyboard = true })
    }

    private func step(_ offset: Int) -> KeyPress.Result {
        let count = rows.count
        highlighted = highlighted.map { ($0 + offset + count) % count } ?? (offset > 0 ? 0 : count - 1)
        return .handled
    }

    private func label(for row: Row) -> some View {
        HStack(spacing: 10) {
            Image(systemName: row.symbol)
                .font(.system(size: 14))
                .frame(width: 20)
            Text(row.title)
                .font(.system(size: 14))
                .lineLimit(1)
            // How much is waiting in Changes, as its tab's menu item said it.
            if case .pane(.changes) = row.choice, let count = git.repo?.status.changes.count, count > 0 {
                Text("\(count)")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            // Dropped when the split is too narrow for both.
            ViewThatFits(in: .horizontal) {
                Text(row.shortcut)
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .fixedSize()
                Color.clear.frame(width: 0, height: 0)
            }
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 10)
        .frame(height: 34)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: Chrome.controlRadius, style: .continuous)
                .fill(Color(nsColor: highlighted == row.id ? Chrome.hoverFill : .clear))
        )
        .contentShape(Rectangle())
    }
}
