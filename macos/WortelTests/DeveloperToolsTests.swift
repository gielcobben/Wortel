import XCTest

/// Whether git can run, answered from the disk. On a Mac without Apple's
/// tools `/usr/bin/git` is a stub that raises macOS's installer, so a wrong
/// "yes" here is a system dialog nobody asked for, and a wrong "no" is a git
/// panel that says git is missing on a Mac that has it.
final class DeveloperToolsTests: XCTestCase {
    private let xcode = "/Applications/Xcode.app/Contents/Developer"
    private let tools = "/Library/Developer/CommandLineTools"

    private func git(selected: String? = nil, install: [String] = ["/opt/homebrew/bin", "/nix/bin"],
                     existing: Set<String>) -> DeveloperTools.Git {
        DeveloperTools.git(selected: selected, installDirectories: install, isExecutable: existing.contains)
    }

    func testANewMacHasNone() {
        XCTAssertEqual(git(existing: []), .missing)
        XCTAssertFalse(DeveloperTools.Git.missing.canRun)
    }

    func testTheCommandLineToolsAreEnough() {
        XCTAssertEqual(git(existing: ["\(tools)/usr/bin/git"]), .apple)
    }

    func testXcodeInApplicationsIsEnough() {
        XCTAssertEqual(git(existing: ["\(xcode)/usr/bin/git"]), .apple)
    }

    func testASelectedDirectoryIsTheOneAsked() {
        let beta = "/Applications/Xcode-beta.app/Contents/Developer"
        XCTAssertEqual(git(selected: beta, existing: ["\(beta)/usr/bin/git"]), .apple)
    }

    func testASelectionThatIsGoneIsNotRescuedByTheDefaults() {
        // An Xcode that was selected and then deleted: the stub fails on the
        // selection and never looks further, so neither does this.
        XCTAssertEqual(git(selected: "/Applications/Gone.app/Contents/Developer",
                           existing: ["\(tools)/usr/bin/git"]), .missing)
    }

    func testAGitOfTheirOwnRunsWithoutAppleTools() {
        XCTAssertEqual(git(existing: ["/nix/bin/git"]), .other(directory: "/nix/bin"),
                       "its folder, so it can be put before /usr/bin")
        XCTAssertTrue(DeveloperTools.Git.other(directory: "/nix/bin").canRun)
    }

    func testAppleGitWinsOverOneOfTheirOwn() {
        XCTAssertEqual(git(existing: ["\(tools)/usr/bin/git", "/opt/homebrew/bin/git"]), .apple,
                       "the git already run stays the one that runs")
    }

    func testThisMacAgreesWithItsOwnStub() {
        // The suite runs git for real elsewhere, so this Mac has one.
        XCTAssertTrue(DeveloperTools.current.canRun)
    }
}
