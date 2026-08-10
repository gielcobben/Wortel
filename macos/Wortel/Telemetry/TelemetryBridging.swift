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

extension CommandVerb {
    init(_ command: WortelCommand) {
        switch command {
        case .open: self = .open
        case .newSession: self = .new
        case .rename: self = .rename
        case .notify: self = .notify
        case .version: self = .version
        }
    }
}
