import XCTest

/// Which agents the Mac has, as the person's own shell answers it. The shell
/// runs their startup files first, and those print what they like: a banner,
/// a version manager's notice, a prompt theme's complaint. None of it may
/// reach the list.
final class AgentDiscoveryTests: XCTestCase {
    private let names = ["claude", "pi", "codex"]

    // MARK: - Reading the answer

    func testOnlyNamesBetweenTheSentinelsCount() {
        let output = """
            Welcome back! claude
            \(AgentDiscovery.opening)
            pi
            claude
            \(AgentDiscovery.closing)
            codex
            """
        XCTAssertEqual(AgentDiscovery.parse(output, names: names), ["claude", "pi"],
                       "in the known order, and nothing from outside the answer")
    }

    func testALineThatIsNotAKnownNameIsDropped() {
        let output = """
            \(AgentDiscovery.opening)
            claude: aliased to claude --model opus
            rm -rf
            pi
            \(AgentDiscovery.closing)
            """
        XCTAssertEqual(AgentDiscovery.parse(output, names: names), ["pi"])
    }

    func testNoneFoundIsAnAnswer() {
        XCTAssertEqual(AgentDiscovery.parse("\(AgentDiscovery.opening)\n\(AgentDiscovery.closing)\n",
                                            names: names), [])
    }

    /// Cut off by the timeout, or a shell that never ran the script: no
    /// answer, which is different from "none", so the folder scan gets a turn.
    func testAShellCutOffGivesNoAnswer() {
        XCTAssertNil(AgentDiscovery.parse("", names: names))
        XCTAssertNil(AgentDiscovery.parse("\(AgentDiscovery.opening)\nclaude\n", names: names))
        XCTAssertNil(AgentDiscovery.parse("claude\n\(AgentDiscovery.closing)\n", names: names))
    }

    /// An rc file that echoes the opening line itself must not start the
    /// answer early: the last opening line is the script's.
    func testTheLastOpeningLineIsTheOne() {
        let output = """
            \(AgentDiscovery.opening)
            codex
            \(AgentDiscovery.opening)
            pi
            \(AgentDiscovery.closing)
            """
        XCTAssertEqual(AgentDiscovery.parse(output, names: names), ["pi"])
    }

    // MARK: - Asking

    func testEachKnownShellIsAskedInItsOwnSyntax() {
        XCTAssertEqual(AgentDiscovery.script(for: .zsh, names: names),
                       AgentDiscovery.script(for: .bash, names: names))
        XCTAssertTrue(AgentDiscovery.script(for: .zsh, names: names)?.contains("command -v") ?? false)
        XCTAssertTrue(AgentDiscovery.script(for: .fish, names: names)?.contains("type -q") ?? false)
        XCTAssertNil(AgentDiscovery.script(for: .other, names: names), "an unknown shell isn't guessed at")
    }

    /// The script, run by the real zsh and bash against a folder holding one
    /// of the three.
    func testTheScriptFindsWhatIsOnThePath() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("wortel-agents-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let tool = folder.appendingPathComponent("pi")
        try "#!/bin/sh\n".write(to: tool, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)

        for (shell, flags) in [("/bin/zsh", ["-f"]), ("/bin/bash", ["--noprofile", "--norc"])] {
            let script = try XCTUnwrap(AgentDiscovery.script(for: ShellSpawn.Shell(path: shell), names: names))
            let process = Process()
            process.executableURL = URL(fileURLWithPath: shell)
            process.arguments = flags + ["-c", script]
            process.environment = ["PATH": "\(folder.path):/usr/bin:/bin"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            try process.run()
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            process.waitUntilExit()
            XCTAssertEqual(AgentDiscovery.parse(output, names: names), ["pi"], shell)
        }
    }

    // MARK: - The folder scan

    func testTheScanFindsABinaryInAUsualPlace() {
        let found = AgentDiscovery.scan(names: names, home: "/Users/someone") { path in
            path == "/Users/someone/.bun/bin/codex" || path == "/opt/homebrew/bin/claude"
        }
        XCTAssertEqual(found, ["claude", "codex"])
    }
}
