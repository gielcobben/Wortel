import SwiftUI

/// Shared focus + ↑/↓ behaviour for the source-control panel's lists.
///
/// A list claims the keyboard only once it is explicitly focused — by a click on
/// one of its rows, or by the Focus List command — because the terminal is where
/// typing normally goes and it keeps its arrow keys until you ask otherwise.
/// That's also why the system focus ring is replaced by a border around the
/// whole list: the row pill is accent-filled whether or not the list has focus,
/// so it can't be the thing that tells you where the arrows will land.
///
/// `extendMove` and `selectAll` are optional because only a list that *has* a
/// multi-row selection has anything to say about ⇧↑/⇧↓ and ⌘A; History's rows
/// are one commit at a time and pass neither.
struct KeyboardNavigableList: ViewModifier {
    @FocusState.Binding var focused: Bool
    /// Called with -1 for up, +1 for down.
    let move: (Int) -> Void
    /// ⇧↑/⇧↓: same movement, dragging the selection along behind it.
    let extendMove: ((Int) -> Void)?
    /// ⌘A. Free to take here: the menu bar's Select All sits on ⌘⇧A precisely so
    /// plain ⌘A can reach whoever has focus (see `MainMenu.syncSelectAll`), and
    /// the terminal's own claim on it only applies while the terminal is what has
    /// focus, which it isn't when this list does.
    let selectAll: (() -> Void)?

    func body(content: Content) -> some View {
        content
            .focusable()
            .focused($focused)
            .focusEffectDisabled()
            .onKeyPress(keys: [.upArrow, .downArrow]) { press in
                let delta = press.key == .upArrow ? -1 : 1
                if press.modifiers.contains(.shift), let extendMove {
                    extendMove(delta)
                } else {
                    move(delta)
                }
                return .handled
            }
            .onKeyPress(keys: ["a"]) { press in
                guard press.modifiers.contains(.command), let selectAll else { return .ignored }
                selectAll()
                return .handled
            }
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(
                        focused ? Color.accentColor.opacity(0.6) : .clear, lineWidth: 2))
            .background(.clear)
    }
}

extension View {
    /// Make a list focusable and walk its selection with ↑/↓. `move` receives -1
    /// or +1 and is expected to clamp at the ends.
    func keyboardNavigableList(
        focused: FocusState<Bool>.Binding,
        move: @escaping (Int) -> Void,
        extendMove: ((Int) -> Void)? = nil,
        selectAll: (() -> Void)? = nil
    ) -> some View {
        modifier(KeyboardNavigableList(
            focused: focused, move: move, extendMove: extendMove, selectAll: selectAll))
    }
}
