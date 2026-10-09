import AppKit
import SwiftUI

/// A forked session's page while git makes its worktree, in place of the
/// terminal that will be there: what's happening and that the rest of the app
/// is free meanwhile, or, once git has refused, git's own words and a way to
/// try again. A refusal used to be an alert, after up to a minute of nothing.
struct WorktreePreparingPage: View {
    let preparation: WorktreePreparation
    let retry: () -> Void
    let close: () -> Void

    var body: some View {
        ZStack {
            Color(nsColor: Chrome.content)
            if let failure = preparation.failure {
                failed(failure)
            } else {
                preparing
            }
        }
    }

    private var preparing: some View {
        VStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text("Preparing worktree")
                .font(.system(size: 13, weight: .semibold))
            Text(verbatim: preparation.branch)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
            Text("Checking out the files. Your other sessions work as usual meanwhile, and this one opens when it's ready.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
                .padding(.top, 2)
        }
        .padding(24)
    }

    private func failed(_ message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 22))
                .foregroundStyle(.orange)
            Text("Couldn't open a worktree for \u{201c}\(preparation.branch)\u{201d}")
                .font(.system(size: 13, weight: .semibold))
                .multilineTextAlignment(.center)
            // git's words, as it wrote them: they name the path or the ref
            // that's the problem, and can be selected and copied.
            Text(verbatim: message)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .textSelection(.enabled)
                .frame(maxWidth: 420, alignment: .leading)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: Chrome.hoverFill)))
            HStack(spacing: 8) {
                Button("Close Session", action: close)
                Button("Try Again", action: retry)
            }
            .controlSize(.regular)
            .padding(.top, 4)
        }
        .padding(24)
    }
}
