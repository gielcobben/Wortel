import AppKit
import SwiftUI

/// Settings ▸ New sessions start with: a text field with a pull-down, the
/// Mac's own control for "type anything, or pick one of these". A real,
/// bordered input on purpose: a plain right-aligned value with a chevron was
/// tried for a day and read as a label, not as somewhere to type.
///
/// **Saved when you are done, never per keystroke**: on Return, on Tab, on
/// picking from the list, and when the window closes (which ends editing).
/// ⌘N pressed while the field still says `cla` must start what was last
/// saved, not half a word. A line that can't be typed into a shell is never
/// saved: the field keeps the text and `problem` says why.
struct CommandComboBox: NSViewRepresentable {
    /// The saved command (`AppSettings.newSessionCommand`).
    @Binding var command: String
    /// Agents found on this Mac, for the list.
    var suggestions: [String]
    /// What is wrong with the text in the field as it stands, if anything.
    @Binding var problem: NewSessionCommand.Problem?
    /// Bumped to put the cursor in the field: a click on the row's name.
    var focusRequest = 0

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSComboBox {
        let box = NSComboBox()
        box.usesDataSource = false
        // Offering `claude` for `c` would be this field deciding for you.
        box.completes = false
        box.placeholderString = "A command, like claude"
        // Something typed into a shell, so in the font of one.
        box.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        box.stringValue = command
        box.delegate = context.coordinator
        box.target = context.coordinator
        box.action = #selector(Coordinator.committed(_:))
        box.setAccessibilityLabel("New sessions start with")
        return box
    }

    func updateNSView(_ box: NSComboBox, context: Context) {
        let asked = focusRequest != context.coordinator.parent.focusRequest
        context.coordinator.parent = self
        if asked { box.window?.makeFirstResponder(box) }
        if box.objectValues as? [String] != suggestions {
            box.removeAllItems()
            box.addItems(withObjectValues: suggestions)
            box.numberOfVisibleItems = max(1, min(suggestions.count, 12))
        }
        // Only when it isn't being typed in: the saved value changing under
        // the cursor would undo what is being written.
        if box.currentEditor() == nil, box.stringValue != command {
            box.stringValue = command
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSComboBoxDelegate {
        var parent: CommandComboBox

        init(_ parent: CommandComboBox) { self.parent = parent }

        /// Return, or an item picked with the keyboard.
        @objc func committed(_ sender: NSComboBox) { save(sender.stringValue) }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard let box = notification.object as? NSComboBox else { return }
            save(box.stringValue)
        }

        /// The reason shows as it is typed; nothing is saved from here.
        func controlTextDidChange(_ notification: Notification) {
            guard let box = notification.object as? NSComboBox else { return }
            parent.problem = Self.problem(in: box.stringValue)
        }

        /// An item picked with the pointer. The field's own text has not
        /// caught up when this is sent, so the item is read instead.
        func comboBoxSelectionDidChange(_ notification: Notification) {
            guard let box = notification.object as? NSComboBox,
                  let picked = box.objectValueOfSelectedItem as? String else { return }
            save(picked)
        }

        private func save(_ text: String) {
            let problem = Self.problem(in: text)
            parent.problem = problem
            guard problem == nil else { return }
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if parent.command != trimmed { parent.command = trimmed }
        }

        private static func problem(in text: String) -> NewSessionCommand.Problem? {
            if case .failure(let problem) = NewSessionCommand.check(text) { return problem }
            return nil
        }
    }
}
