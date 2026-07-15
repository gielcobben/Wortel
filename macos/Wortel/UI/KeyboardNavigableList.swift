import SwiftUI

/// Shared focus + ↑/↓ behaviour for the source-control panel's lists.
///
/// A list claims the keyboard only once it is explicitly focused — by a click on
/// one of its rows, or by the Focus List command — because the terminal is where
/// typing normally goes and it keeps its arrow keys until you ask otherwise.
/// That's also why the system focus ring is replaced by a border around the
/// whole list: the row pill is accent-filled whether or not the list has focus,
/// so it can't be the thing that tells you where the arrows will land.
struct KeyboardNavigableList: ViewModifier {
    @FocusState.Binding var focused: Bool
    /// Called with -1 for up, +1 for down.
    let move: (Int) -> Void

    func body(content: Content) -> some View {
        content
            .focusable()
            .focused($focused)
            .focusEffectDisabled()
            .onKeyPress(.upArrow) { move(-1); return .handled }
            .onKeyPress(.downArrow) { move(1); return .handled }
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
        focused: FocusState<Bool>.Binding, move: @escaping (Int) -> Void
    ) -> some View {
        modifier(KeyboardNavigableList(focused: focused, move: move))
    }
}
