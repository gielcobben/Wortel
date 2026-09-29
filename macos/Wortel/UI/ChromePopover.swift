import AppKit
import SwiftUI

/// A card that hangs from a titlebar button: the ChatGPT app's popovers, not
/// the system's. No arrow, a rounded card with a hairline and a soft shadow, and
/// aligned to the button's trailing edge so it opens *into* the window rather
/// than off its side, which is where a menu popped at the button's origin went.
///
/// A borderless child panel rather than an NSPopover (which always draws its
/// arrow and centres on the anchor) or an NSMenu (which can't hold grouped rows
/// with icons, secondary text and a shortcut column the way this wants to). It
/// takes key while open so the keyboard works in it, and closes when it loses
/// key, which covers a click anywhere else.
@MainActor
final class ChromePopover: NSPanel {
    private static weak var current: ChromePopover?

    /// Show `content` under `anchor`, trailing edges aligned. Closes whichever
    /// card was open before it.
    static func present<Content: View>(_ content: Content, from anchor: NSView) {
        current?.dismiss()
        guard let parent = anchor.window else { return }
        let host = NSHostingView(rootView: content)
        let size = host.fittingSize
        let anchorRect = anchor.convert(anchor.bounds, to: nil)
        let onScreen = parent.convertToScreen(anchorRect)
        let frame = NSRect(x: onScreen.maxX - size.width, y: onScreen.minY - 6 - size.height,
                           width: size.width, height: size.height)
        let panel = ChromePopover(contentRect: frame, host: host)
        parent.addChildWindow(panel, ordered: .above)
        current = panel
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 1
        }
    }

    static func dismissCurrent() { current?.dismiss() }

    private init(contentRect: NSRect, host: NSView) {
        super.init(contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .popUpMenu
        isReleasedWhenClosed = false
        hidesOnDeactivate = true
        contentView = host
    }

    override var canBecomeKey: Bool { true }

    override func resignKey() {
        super.resignKey()
        dismiss()
    }

    override func cancelOperation(_ sender: Any?) { dismiss() }

    private var dismissing = false

    func dismiss() {
        guard !dismissing else { return }
        dismissing = true
        let parent = self.parent
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.08
            animator().alphaValue = 0
        } completionHandler: {
            MainActor.assumeIsolated {
                parent?.removeChildWindow(self)
                self.orderOut(nil)
                // Back to the window it hung from, so the terminal gets its
                // keyboard back without a click.
                parent?.makeKey()
            }
        }
    }
}

/// The card's own chrome: material, radius, hairline. Rows go inside.
struct ChromeCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(6)
            .frame(width: 272)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

// MARK: - The new-tab card

/// What "+" offers: a terminal, the panes, and what the session is serving.
///
/// Grouped the way ChatGPT's new-tab page is (Tools, Recents), with a glyph on
/// every row and the shortcut where a menu would put it. A pane that is already
/// open says so instead of wearing a checkmark: choosing it still does the
/// useful thing, which is bring that tab to the front.
struct NewTabCard: View {
    struct Row: Identifiable {
        let id: String
        let symbol: String
        let title: String
        var detail: String? = nil
        var trailing: String? = nil
        let action: () -> Void
    }

    struct Section: Identifiable {
        let id: String
        let title: String
        let rows: [Row]
    }

    let sections: [Section]
    let dismiss: () -> Void

    @State private var highlighted: String?
    @FocusState private var focused: Bool

    private var rows: [Row] { sections.flatMap(\.rows) }

    var body: some View {
        ChromeCard {
            ForEach(sections) { section in
                Text(section.title)
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 10)
                    .padding(.top, section.id == sections.first?.id ? 6 : 10)
                    .padding(.bottom, 4)
                ForEach(section.rows) { row in
                    rowView(row)
                }
            }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear {
            focused = true
            highlighted = rows.first?.id
        }
        .onKeyPress(.downArrow) { move(1); return .handled }
        .onKeyPress(.upArrow) { move(-1); return .handled }
        .onKeyPress(.return) {
            if let row = rows.first(where: { $0.id == highlighted }) { choose(row) }
            return .handled
        }
        .onKeyPress(.escape) { dismiss(); return .handled }
    }

    private func rowView(_ row: Row) -> some View {
        HStack(spacing: 10) {
            Image(systemName: row.symbol)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.title)
                    .font(.system(size: 13))
                    .lineLimit(1)
                if let detail = row.detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if let trailing = row.trailing {
                Text(trailing)
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 10)
        .frame(minHeight: row.detail == nil ? 32 : 40)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(highlighted == row.id ? 0.07 : 0)))
        .contentShape(Rectangle())
        .onHover { if $0 { highlighted = row.id } }
        .onTapGesture { choose(row) }
    }

    private func move(_ offset: Int) {
        guard !rows.isEmpty else { return }
        let index = rows.firstIndex { $0.id == highlighted } ?? -offset
        highlighted = rows[(index + offset + rows.count) % rows.count].id
    }

    private func choose(_ row: Row) {
        dismiss()
        row.action()
    }
}
