import SwiftUI
import AppKit

/// A native `NSTextView`-backed commit message box.
///
/// SwiftUI's `TextField` can't give a full field-editor experience here because
/// the terminal claims the two most important editing shortcuts globally —
/// `cmd+a` (clear line) and `cmd+z` (readline undo) are `wortel.conf` keybinds,
/// so they can't live on the main menu without being stolen from the surface.
/// A real text view sidesteps that: it handles ⌘A / ⌘Z / ⌘⇧Z / ⌘X / ⌘C / ⌘V and
/// ⌘⏎ itself, but only while it is the focused first responder — so the terminal
/// keeps those keys everywhere else. It also brings native undo and internal
/// scrolling for free.
struct CommitMessageEditor: NSViewRepresentable {
    @Binding var text: String
    /// Grow-to-fit height, clamped by the caller; bumped as the text reflows.
    @Binding var height: CGFloat
    let placeholder: String
    let minHeight: CGFloat
    let maxHeight: CGFloat
    /// Called as the editor gains/loses focus, so the box can draw its border.
    let onFocusChange: (Bool) -> Void
    /// ⌘⏎ while focused.
    let onCommit: () -> Void
    /// Monotonic token: a change means "take focus" (drives tap-to-focus on the
    /// surrounding padding).
    let focusRequest: Int

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = CommitTextView.scrollableTextView()
        let textView = scroll.documentView as! CommitTextView
        textView.delegate = context.coordinator
        textView.onCommit = onCommit
        textView.onFocusChange = onFocusChange
        textView.allowsUndo = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.smartInsertDeleteEnabled = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.font = .preferredFont(forTextStyle: .body)
        textView.textColor = .labelColor
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 2, height: 3)
        textView.placeholder = placeholder
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        context.coordinator.textView = textView
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? CommitTextView else { return }
        context.coordinator.parent = self
        textView.onCommit = onCommit
        textView.onFocusChange = onFocusChange
        // Only overwrite when the model diverges (an external set: generated
        // message, post-commit clear) — never mid-edit, which would fight typing
        // and reset the insertion point.
        if textView.string != text {
            textView.string = text
            context.coordinator.recomputeHeight()
        }
        // The floor moved (the box opening up as you start writing, or back
        // to a line): eased, and after this update, since it sets state.
        if context.coordinator.lastMinHeight != minHeight {
            context.coordinator.lastMinHeight = minHeight
            DispatchQueue.main.async {
                withAnimation(.easeOut(duration: 0.15)) { context.coordinator.recomputeHeight() }
            }
        }
        // Honour a tap-to-focus request from the surrounding padding.
        if context.coordinator.lastFocusRequest != focusRequest {
            context.coordinator.lastFocusRequest = focusRequest
            DispatchQueue.main.async {
                textView.window?.makeFirstResponder(textView)
            }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CommitMessageEditor
        weak var textView: CommitTextView?
        var lastFocusRequest: Int
        var lastMinHeight: CGFloat
        /// This editor's own undo stack, and the reason it exists is a crash.
        ///
        /// `NSResponder.undoManager` walks to the *window's* manager, so with
        /// `allowsUndo` every keystroke here used to register an undo action on a
        /// manager that outlives this view by the life of the app. `NSUndoManager`
        /// does not retain its targets, and nothing unregisters when SwiftUI tears
        /// the editor down (panel hidden, session switched, pane swapped), so the
        /// stack kept entries pointing at a freed text view. Then ⌘Z with the
        /// *terminal* focused reached the Edit menu's `undo:`, found the window's
        /// non-empty manager, and `-[_NSUndoStack popAndInvoke]` messaged freed
        /// memory. Reported from the field: a five-day-old window, SIGSEGV.
        ///
        /// Owning the manager here fixes both halves. It dies with the coordinator,
        /// so there is no stack to go stale; and the window's manager stays empty,
        /// which is what the Edit menu already assumed (see `MainMenu`) — Undo
        /// stays disabled with the terminal focused, so ⌘Z falls through to
        /// ghostty's `cmd+z` keybind again instead of being eaten here.
        let undo = UndoManager()

        /// `NSTextView` asks its delegate before falling back to the responder
        /// chain, so this is the whole redirection.
        func undoManager(for view: NSTextView) -> UndoManager? { undo }

        init(_ parent: CommitMessageEditor) {
            self.parent = parent
            self.lastFocusRequest = parent.focusRequest
            self.lastMinHeight = parent.minHeight
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            parent.text = textView.string
            recomputeHeight()
        }

        /// Size the box to its content, clamped to [min, max]; past that the
        /// text view scrolls internally.
        func recomputeHeight() {
            guard let textView,
                  let container = textView.textContainer,
                  let layoutManager = textView.layoutManager else { return }
            layoutManager.ensureLayout(for: container)
            let used = layoutManager.usedRect(for: container).height
            let inset = textView.textContainerInset.height * 2
            let clamped = min(max(used + inset, parent.minHeight), parent.maxHeight)
            if abs(clamped - parent.height) > 0.5 { parent.height = clamped }
        }
    }
}

/// Text view that handles the standard ⌘ editing shortcuts itself — but only
/// while focused, so it never shadows the terminal's `cmd+a` / `cmd+z` keybinds.
/// Also draws a placeholder and reports focus changes.
final class CommitTextView: NSTextView {
    var onCommit: (() -> Void)?
    var onFocusChange: ((Bool) -> Void)?
    var placeholder: String = "" { didSet { needsDisplay = true } }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Only act as the focused editor; otherwise this view (which lives in the
        // hierarchy even when the terminal is up) would swallow ⌘A / ⌘Z globally.
        guard window?.firstResponder === self else {
            return super.performKeyEquivalent(with: event)
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command {
            switch event.charactersIgnoringModifiers {
            case "\r": onCommit?(); return true
            case "a": selectAll(nil); return true
            case "c": copy(nil); return true
            case "v": paste(nil); return true
            case "x": cut(nil); return true
            case "z": undoManager?.undo(); return true
            default: break
            }
        } else if flags == [.command, .shift],
                  event.charactersIgnoringModifiers?.lowercased() == "z" {
            undoManager?.redo()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { onFocusChange?(true) }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok { onFocusChange?(false) }
        return ok
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.placeholderTextColor,
            .font: font ?? .preferredFont(forTextStyle: .body),
        ]
        // Line-fragment padding (5) + the container inset put the caret's origin;
        // match it so the placeholder sits exactly where typed text will.
        let origin = NSPoint(x: textContainerInset.width + (textContainer?.lineFragmentPadding ?? 5),
                             y: textContainerInset.height)
        placeholder.draw(at: origin, withAttributes: attrs)
    }
}
