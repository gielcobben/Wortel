import AppKit
import Observation
import WebKit

/// ⌘F over a page: Safari's keys (⌘F, ⌘G, ⇧⌘G, ⌘E) on WebKit's own find.
///
/// Only the public call (`WKWebView.find`). It selects the next match, marks
/// it with the yellow indicator Safari uses, scrolls to it, and answers with
/// one fact: found or not. So this bar says "Not found" where a file's says
/// "3 of 12". The count, and every match lit at once, are behind private
/// calls, which the browser tab stays away from where it can.
///
/// The public call always looks *after* the selection, and the last match is
/// the selection. Typed as is, "a", "ab", "abc" would hop to a later match on
/// each letter. So before a search that typing started, the selection is
/// collapsed to its start, and the longer query matches from where the
/// shorter one did (measured off screen 2026-11-25: "a" at 0, "ab" at 6,
/// "abc" at 13 in "alpha abacus abc", none skipped).
@Observable
@MainActor
final class BrowserFind {
    private(set) var isPresented = false
    var query = "" {
        didSet { if query != oldValue { search(.typed) } }
    }
    /// The last search found nothing.
    private(set) var notFound = false
    /// Bumped to put the keyboard in the bar's field: ⌘F, again too.
    private(set) var focusRequest = 0

    @ObservationIgnored weak var webView: WKWebView?
    /// The latest search: an answer to an older one is dropped.
    @ObservationIgnored private var generation = 0

    var summary: String { notFound && !query.isEmpty ? "Not found" : "" }

    /// Whether ⌘G has anything to look for.
    var canStep: Bool { !query.isEmpty && !notFound }

    /// ⌘F: the bar, with the keyboard in it.
    func present() {
        isPresented = true
        focusRequest += 1
    }

    /// ⌘G / ⇧⌘G. They work with the bar away (after ⌘E), and bring it back
    /// without the keyboard, so what is being looked for is on screen.
    func next() { step(.next) }
    func previous() { step(.previous) }

    /// Esc or Done: the bar goes, the match stays selected, and the keyboard
    /// is the page's again.
    func dismiss() {
        isPresented = false
        webView?.window?.makeFirstResponder(webView)
    }

    /// ⌘E: what is selected in the page becomes what is looked for, here and
    /// (through the system's find pasteboard) in every other app's find.
    func useSelection() {
        webView?.evaluateJavaScript("window.getSelection().toString()") { [weak self] value, _ in
            MainActor.assumeIsolated {
                guard let self, let text = BrowserAddress.searchable(value as? String) else { return }
                let pasteboard = NSPasteboard(name: .find)
                pasteboard.clearContents()
                pasteboard.setString(text, forType: .string)
                // The same text again still marks it: the selection is the match.
                if self.query == text { self.search(.typed) } else { self.query = text }
            }
        }
    }

    private enum Step { case typed, next, previous }

    private func step(_ step: Step) {
        guard !query.isEmpty else { return }
        if !isPresented { isPresented = true }
        search(step)
    }

    private static let collapseSelection =
        "(function(){var s=window.getSelection();if(s&&s.rangeCount)s.collapseToStart()})()"

    private func search(_ step: Step) {
        generation += 1
        let generation = generation
        guard let webView, !query.isEmpty else {
            notFound = false
            return
        }
        let query = query
        let configuration = WKFindConfiguration()
        configuration.backwards = step == .previous
        configuration.wraps = true
        let find = { [weak self, weak webView] in
            webView?.find(query, configuration: configuration) { result in
                MainActor.assumeIsolated {
                    guard let self, generation == self.generation else { return }
                    self.notFound = !result.matchFound
                }
            }
        }
        if step == .typed {
            webView.evaluateJavaScript(Self.collapseSelection) { _, _ in
                MainActor.assumeIsolated { _ = find() }
            }
        } else {
            find()
        }
    }
}
