import Foundation

// ==========================================================================
// App types -> reportable values.
//
// TelemetryEvent deliberately mirrors these enums instead of importing them,
// so the git panel cannot change what this app reports by renaming one of its
// own cases, and so the reportable vocabulary is a decision rather than a
// side effect. The cost of that choice is exactly this file, and it is worth
// paying in one place.
//
// EVERY SWITCH HERE IS EXHAUSTIVE ON PURPOSE. No `default:` anywhere. Adding a
// case to AttentionKind, InspectorPane, PreviewMode or WortelCommand then fails
// the build right here, which is a five-second fix, instead of silently
// reporting the new thing as nothing at all: a state that would be missing from
// the numbers with no error anywhere to say so, and which nobody would notice
// until they wondered why a feature they shipped looks unused.
// ==========================================================================

extension AttentionCause {
    init(_ kind: AttentionKind) {
        switch kind {
        case .needsInput: self = .needsInput
        case .failed: self = .failed
        case .turnDone: self = .turnDone
        case .finished: self = .finished
        }
    }
}

extension InspectorPaneKind {
    init(_ pane: InspectorPane) {
        switch pane {
        case .changes: self = .changes
        case .history: self = .history
        case .files: self = .files
        }
    }
}

extension PreviewKind {
    init(_ mode: PreviewMode) {
        switch mode {
        case .source: self = .source
        case .diff: self = .diff
        case .rendered: self = .rendered
        }
    }
}

extension TabOpenedKind {
    /// nil for the session's own terminal, which is never opened as a tab.
    init?(_ tab: SideTab) {
        switch tab {
        case .terminal: self = .terminal
        case .browser: self = .browser
        case .file: self = .file
        case .pane: self = .pane
        case .session: return nil
        }
    }
}

extension TabArea {
    init(_ region: TabRegion) {
        switch region {
        case .main: self = .main
        case .side: self = .side
        case .bottom: self = .bottom
        }
    }
}

extension CommandVerb {
    init(_ command: WortelCommand) {
        switch command {
        case .open: self = .open
        case .newSession, .newFromPullRequest, .newWorktree, .newRunning: self = .new
        case .rename: self = .rename
        case .notify: self = .notify
        case .mark: self = .mark
        case .remind: self = .remind
        case .list: self = .list
        case .read: self = .read
        case .send: self = .send
        case .wait: self = .wait
        case .version: self = .version
        }
    }
}

extension AgentName {
    /// The one place a command name becomes reportable, and it can only come
    /// out as a case of the list: an agent the integration starts detecting
    /// later reports as `other` until someone adds it here on purpose. nil is
    /// a session with no agent running.
    init(command: String?) {
        guard let command else { self = .noAgent; return }
        switch command {
        case "claude": self = .claude
        case "codex": self = .codex
        case "pi": self = .pi
        case "gemini": self = .gemini
        case "opencode": self = .opencode
        case "goose": self = .goose
        case "aider": self = .aider
        case "amp": self = .amp
        case "crush": self = .crush
        case "cline": self = .cline
        case "ollama": self = .ollama
        case "llm": self = .llm
        case "cursor-agent": self = .cursor
        default: self = .other
        }
    }
}
