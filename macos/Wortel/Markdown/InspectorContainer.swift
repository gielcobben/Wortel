import SwiftUI

/// What the right inspector column shows: the file tree on the Files pane,
/// otherwise the source-control panel.
///
/// It used to be three, with the Markdown preview taking the whole column when a
/// `.md` was opened — a compromise the doc admitted, because a terminal with two
/// right columns gets cramped. Markdown opens in a preview window now, so the
/// column belongs to its panes outright and the sharing apparatus that went with
/// it is gone: no occupant to reclaim, no visibility to arbitrate.
struct InspectorContainer: View {
    @Bindable var git: GitPanelModel
    @Bindable var files: FileTreeModel

    var body: some View {
        if git.pane == .files {
            FileTreePanel(model: files, focusRequest: git.listFocusRequest)
        } else {
            SourceControlPanel(panel: git)
        }
    }
}
