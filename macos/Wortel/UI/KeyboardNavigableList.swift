import SwiftUI

/// Shared focus + ↑/↓ behaviour for the source-control panel's lists.
///
/// A list claims the keyboard only once it is explicitly focused — by a click on
/// one of its rows, or by the Focus List command — because the terminal is where
/// typing normally goes and it keeps its arrow keys until you ask otherwise.
///
/// Where the arrows will land is said the Mac's way, by the selection: blue
/// while the list has the keyboard, grey while it doesn't, as in Finder and
/// Mail (rows read `listHasFocus`). It used to be a blue border around the
/// whole list, the only such border in the app; that the keyboard just moved
/// is the focus blink's job (FocusBlink), for every area alike.
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
    /// Space, as in Finder: the selected file in the preview tab, or the
    /// preview closed when it's what is in front.
    let space: (() -> Void)?

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
            .onKeyPress(keys: [.space]) { press in
                guard press.modifiers.isEmpty, let space else { return .ignored }
                space()
                return .handled
            }
            .onKeyPress(keys: ["a"]) { press in
                guard press.modifiers.contains(.command), let selectAll else { return .ignored }
                selectAll()
                return .handled
            }
            .environment(\.listHasFocus, focused)
    }
}

extension EnvironmentValues {
    /// Whether the list a row is in has the keyboard: its selection is drawn
    /// on the accent then, and in grey otherwise.
    @Entry var listHasFocus = true
}

extension View {
    /// Make a list focusable and walk its selection with ↑/↓. `move` receives -1
    /// or +1 and is expected to clamp at the ends.
    func keyboardNavigableList(
        focused: FocusState<Bool>.Binding,
        move: @escaping (Int) -> Void,
        extendMove: ((Int) -> Void)? = nil,
        selectAll: (() -> Void)? = nil,
        space: (() -> Void)? = nil
    ) -> some View {
        modifier(KeyboardNavigableList(
            focused: focused, move: move, extendMove: extendMove, selectAll: selectAll,
            space: space))
    }
}
