import Foundation
import os

/// Whether git can run on this Mac, asked without running it.
///
/// `/usr/bin/git` is always there, and on a Mac without Xcode or Apple's
/// command line tools it is a stub: started, it runs nothing and macOS puts
/// up its own "install the command line developer tools" dialog. Wortel runs
/// git by itself (a row's branch, the Changes pane), so on a new Mac that
/// dialog would arrive at a moment nobody chose, about a command nobody
/// typed. So the question is answered from the disk first, and git is only
/// started when the answer is yes.
///
/// Read the way `xcode-select` resolves a developer directory: the one that
/// was selected if there is one, and otherwise Xcode in Applications, then
/// the command line tools.
enum DeveloperTools {
    /// Where `xcode-select --switch` (and an install) records its choice.
    static let selectionLink = "/var/db/xcode_select_link"

    /// Where one is looked for when nothing was selected.
    static let defaultDirectories = [
        "/Applications/Xcode.app/Contents/Developer",
        "/Library/Developer/CommandLineTools",
    ]

    enum Git: Equatable {
        /// Apple's, through `/usr/bin/git`.
        case apple
        /// No developer tools, but a git of someone's own (Nix, MacPorts) in
        /// this folder, which has to come before `/usr/bin` to be the one run.
        case other(directory: String)
        /// Apple's tools are on the disk, and macOS was pointed
        /// (`xcode-select --switch`) at a developer directory that has since
        /// gone, usually an Xcode that was deleted. `/usr/bin/git` fails on
        /// the selection and looks no further, and the installer has nothing
        /// to install. `resetLine` is what puts it right.
        case misdirected
        /// None. Starting `/usr/bin/git` would raise macOS's installer.
        case missing

        var canRun: Bool { self != .missing && self != .misdirected }
    }

    /// The git this Mac has. `selected` is where the selection link points,
    /// nil when there is none.
    static func git(
        selected: String? = try? FileManager.default.destinationOfSymbolicLink(atPath: selectionLink),
        installDirectories: [String] = GitService.installDirectories,
        isExecutable: (String) -> Bool = FileManager.default.isExecutableFile(atPath:)
    ) -> Git {
        // A selection decides alone: when it points at an Xcode that has
        // since been deleted, the stub fails rather than falling back.
        let hasGit = { (developer: String) in isExecutable("\(developer)/usr/bin/git") }
        if (selected.map { [$0] } ?? defaultDirectories).contains(where: hasGit) { return .apple }
        if let directory = installDirectories.first(where: { isExecutable("\($0)/git") }) {
            return .other(directory: directory)
        }
        // Only reached with a selection that holds no git.
        return defaultDirectories.contains(where: hasGit) ? .misdirected : .missing
    }

    /// The answer for this run of the app. A yes is kept: tools that are
    /// there stay there. A no is asked again each time, a few `stat`s, so
    /// git starts working the moment the install finishes.
    static var current: Git {
        if let known = found.withLock({ $0 }) { return known }
        let answer = git()
        if answer.canRun { found.withLock { $0 = answer } }
        return answer
    }

    private static let found = OSAllocatedUnfairLock<Git?>(initialState: nil)

    /// What a git command that was never started says went wrong.
    static func message(for git: Git = current) -> String {
        git == .misdirected
            ? "Git cannot run: macOS is pointed at developer tools that are gone. Run \(resetLine) in a terminal."
            : "Git is not installed. It comes with Apple's command line developer tools."
    }

    /// Forgets the selection, so macOS finds the tools where they are. It
    /// needs an administrator, so it is never run from here: it is typed on
    /// a prompt for the person to run (`Permissions.fixDeveloperTools`).
    static let resetLine = "sudo xcode-select --reset"

    /// Apple's own installer, the same dialog a `git` typed in a shell would
    /// raise, here because someone pressed a button for it.
    static func install() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        process.arguments = ["--install"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }
}
