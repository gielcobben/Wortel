import AppKit
import SwiftUI
import WebKit

/// The Browser pane in the trailing inspector: an address bar over a `WKWebView`.
/// Shares the column — and the toolbar's segmented control — with Changes and
/// History. Unlike those two it doesn't need a git repo, so it renders whatever
/// the selected session's cwd is.
struct BrowserPane: View {
    @Bindable var model: BrowserModel
    @FocusState private var addressFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // First view in the pane so it runs up under the titlebar and picks up
            // the system material, same as the changes/history lists.
            addressBar
            Divider()
            WebViewHost(model: model)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // While the address field holds focus, ⌘A means select-all here (not the
        // terminal's clear-line keybind) — same field-editing flip the sidebar
        // rename uses. The onDisappear is a backstop if the pane is torn out while
        // the field is still first responder.
        .onChange(of: addressFocused) { _, focused in MainMenu.setTextEditing(focused) }
        .onDisappear { MainMenu.setTextEditing(false) }
    }

    private var addressBar: some View {
        HStack(spacing: 6) {
            navButton("chevron.left", enabled: model.canGoBack, help: "Back", action: model.goBack)
            navButton("chevron.right", enabled: model.canGoForward, help: "Forward", action: model.goForward)
            navButton(
                model.isLoading ? "xmark" : "arrow.clockwise",
                enabled: true,
                help: model.isLoading ? "Stop" : "Reload",
                action: model.reloadOrStop)

            TextField("Enter a URL (e.g. localhost:3000)", text: $model.address)
                .textFieldStyle(.plain)
                .font(.callout)
                .lineLimit(1)
                .focused($addressFocused)
                .onSubmit(model.submitAddress)
                .padding(.leading, 8)
                .padding(.trailing, 4)
                .padding(.vertical, 4)
                .overlay(alignment: .trailing) {
                    // Clear (empty the browser): blank page, empty field, no
                    // history. Only worth offering when there's something to clear.
                    if !model.address.isEmpty {
                        Button(action: clear) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(.tertiary)
                                .padding(.trailing, 6)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Clear the browser")
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color(nsColor: .textBackgroundColor)))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(addressFocused
                            ? Color.accentColor.opacity(0.5)
                            : Color(nsColor: .separatorColor)))

            // Detach: hand the current page to the system default browser.
            navButton(
                "arrow.up.forward.app",
                enabled: !model.address.isEmpty,
                help: "Open in default browser",
                action: model.openInDefaultBrowser)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private func clear() {
        model.clear()
        addressFocused = false
    }

    private func navButton(
        _ symbol: String, enabled: Bool, help: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
        .disabled(!enabled)
        .help(help)
    }
}

/// Hosts the model-owned `WKWebView` inside a container. The web view is created
/// and retained by `BrowserModel`, not here, so navigating panes or sessions
/// never rebuilds it — and when `clear()` swaps in a fresh instance, the
/// container re-installs whatever the model currently holds.
private struct WebViewHost: NSViewRepresentable {
    let model: BrowserModel

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        model.ensureWebView()
        install(in: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        model.ensureWebView()
        install(in: container)
    }

    /// Put the model's current web view in the container, replacing a stale one
    /// (after `clear()`). A no-op when the right view is already installed.
    private func install(in container: NSView) {
        guard let web = model.webView else { return }
        if web.superview === container { return }
        container.subviews.forEach { $0.removeFromSuperview() }
        web.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(web)
        NSLayoutConstraint.activate([
            web.topAnchor.constraint(equalTo: container.topAnchor),
            web.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            web.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            web.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
    }
}
