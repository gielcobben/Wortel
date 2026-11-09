import XCTest

/// The agent marker (`<data>/agents/<session>`) is a contract between the shell
/// integrations and `AgentResumeStore` that nothing checks at compile time: the
/// shell writes it when an agent CLI launches and removes it at the next prompt,
/// and the app reads it to show the running agent and to resume it after a
/// relaunch. Every way it goes wrong is silent. A marker that is never written
/// is an agent the app doesn't know about; one written for a remote or a
/// multiplexed agent is a resume typed into the wrong shell; one cleared while
/// the agent is only stopped is an agent untracked for the rest of its life.
///
/// These drive the real scripts in real shells, the way
/// `ShellIntegrationPwdTests` does: `-i -c` under `script(1)` for a pty, the
/// hook functions called by hand, a throwaway HOME and data folder. fish runs
/// only where it is installed.
final class ShellIntegrationAgentMarkerTests: XCTestCase {

    private static var ghosttyResources: URL {
        URL(fileURLWithPath: #filePath)     // …/macos/WortelTests/ShellIntegrationAgentMarkerTests.swift
            .deletingLastPathComponent()    // …/macos/WortelTests
            .deletingLastPathComponent()    // …/macos
            .appendingPathComponent("Resources/ghostty")
    }

    private static let fish = ["/opt/homebrew/bin/fish", "/usr/local/bin/fish"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }

    // MARK: - Detection

    /// (command line, agent, model, cwd, argv). An empty agent is "no marker";
    /// a nil cwd is the directory the shell is in; a nil argv is the line.
    private static let cases: [(String, String, String, String?, String?)] = [
        ("claude --model opus", "claude", "opus", nil, nil),
        ("FOO=1 claude", "claude", "", nil, nil),
        ("exec claude", "claude", "", nil, nil),
        ("command claude", "claude", "", nil, nil),
        ("nohup claude", "claude", "", nil, nil),
        // The package a runner fetches is the agent it runs.
        ("npx -y @anthropic-ai/claude-code@latest", "claude", "", nil, nil),
        ("bunx @mariozechner/pi-coding-agent", "pi", "", nil, nil),
        ("uvx --from aider-chat aider", "aider", "", nil, nil),
        ("devx pi", "pi", "", nil, nil),
        // A resume by transcript path, run where the shell now is.
        ("claude --resume /Users/x/.claude/projects/-Users-x-a/5131fb0c-345b-4a6c-9d49-49084d92b570.jsonl --model opus",
         "claude", "opus", nil, nil),
        // Somewhere else: nothing here to resume.
        ("ssh box claude", "", "", nil, nil),
        ("mosh box claude", "", "", nil, nil),
        ("et -c claude box", "", "", nil, nil),
        ("tmux new claude", "", "", nil, nil),
        ("screen claude", "", "", nil, nil),
        ("zellij run -- claude", "", "", nil, nil),
        ("docker exec -it box claude", "", "", nil, nil),
        ("kubectl exec -it pod -- claude", "", "", nil, nil),
        // Not launching an agent.
        ("rg claude src", "", "", nil, nil),
        ("git log claude", "", "", nil, nil),
        // A leading cd is followed when its end is visible, and only then.
        ("cd /usr && claude --model x", "claude", "x", "/usr", "claude --model x"),
        ("cd /usr; cd ../etc && claude", "claude", "", "/etc", "claude"),
        ("cd /nonexistent-wortel && claude", "", "", nil, nil),
        ("cd /usr || claude", "", "", nil, nil),
        ("z proj && claude", "", "", nil, nil),
        ("make && claude", "", "", nil, nil),
    ]

    func testZshDetection() throws { try assertDetection("zsh") }
    func testBashDetection() throws { try assertDetection("bash") }
    func testFishDetection() throws {
        guard Self.fish != nil else { throw XCTSkip("fish is not installed") }
        try assertDetection("fish")
    }

    private func assertDetection(_ shell: String) throws {
        let body: String
        switch shell {
        case "zsh":
            body = """
                while IFS= read -r line; do
                  reply=(); _ghostty_wortel_agent "$line"
                  print -r -- "${reply[1]-}\t${reply[2]-}\t${reply[3]-}\t${reply[4]-}"
                done < "$WT_IN" > "$WT_OUT"
                """
        case "bash":
            body = """
                while IFS= read -r line; do
                  __ghostty_wortel_agent "$line"
                  printf '%s\\t%s\\t%s\\t%s\\n' "${_ghostty_wortel_found[0]-}" "${_ghostty_wortel_found[1]-}" \
                    "${_ghostty_wortel_found[2]-}" "${_ghostty_wortel_found[3]-}"
                done < "$WT_IN" > "$WT_OUT"
                """
        default:
            body = """
                while read -l line
                  set -l r (__ghostty_wortel_agent $line)
                  printf '%s\\t%s\\t%s\\t%s\\n' "$r[1]" "$r[2]" "$r[3]" "$r[4]"
                end < $WT_IN > $WT_OUT
                """
        }
        let run = try runShell(shell, body, input: Self.cases.map(\.0).joined(separator: "\n") + "\n")
        let rows = run.out.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        for (index, (line, agent, model, cwd, argv)) in Self.cases.enumerated() {
            let got = index < rows.count ? rows[index].components(separatedBy: "\t") : []
            let expected = agent.isEmpty
                ? ["", "", "", ""]
                : [agent, model, cwd ?? run.home.path, argv ?? line]
            XCTAssertEqual(got, expected, "\(shell): `\(line)`")
        }
    }

    // MARK: - The marker's life

    /// zsh hands preexec the text that runs as `$3`, aliases expanded. Reading
    /// the line as typed (`cc`) named no agent, so an aliased agent was never
    /// recorded, and the flags a resume is rebuilt from were lost with it.
    func testZshRecordsAnAliasedAgentAsItRuns() throws {
        let expanded = "claude --dangerously-skip-permissions --model opus"
        let run = try runShell("zsh", """
            _ghostty_preexec 'cc --model opus' '\(expanded)' '\(expanded)' >/dev/null
            cat "$WT_DATA/agents/S" > "$WT_OUT"
            """)
        let marker = Self.fields(run.out)
        XCTAssertEqual(marker["agent"], "claude")
        XCTAssertEqual(marker["model"], "opus")
        XCTAssertEqual(marker["argv"], expanded)
    }

    func testZshMarkerIsWrittenWholeAndClearedOnce() throws {
        try assertLifecycle("zsh", write: "_ghostty_preexec claude claude claude >/dev/null",
                            clear: "_ghostty_wortel_clear_agent")
    }

    func testBashMarkerIsWrittenWholeAndClearedOnce() throws {
        try assertLifecycle("bash", write: "__ghostty_preexec claude >/dev/null",
                            clear: "__ghostty_wortel_clear_agent")
    }

    /// Written by a rename (no dot-file left behind), complete, and at the next
    /// prompt logged exactly once with the status the agent ended with.
    private func assertLifecycle(_ shell: String, write: String, clear: String) throws {
        let run = try runShell(shell, """
            \(write)
            cat "$WT_DATA/agents/S" > "$WT_OUT"
            ls -a "$WT_DATA/agents" > "$WT_OUT.ls"
            \(clear) 3 >/dev/null
            \(clear) 0 >/dev/null
            """)
        let marker = Self.fields(run.out)
        XCTAssertEqual(marker["agent"], "claude", shell)
        XCTAssertEqual(marker["argv"], "claude", shell)
        XCTAssertEqual(marker["cwd"], run.home.path, shell)
        XCTAssertNotNil(marker["shellpid"].flatMap(Int32.init), shell)
        let started = try XCTUnwrap(marker["startedat"].flatMap(TimeInterval.init), shell)
        XCTAssertLessThan(abs(started - Date().timeIntervalSince1970), 60, shell)

        let listing = try String(contentsOfFile: run.outPath + ".ls", encoding: .utf8)
            .split(separator: "\n").map(String.init)
        XCTAssertEqual(listing.filter { $0.hasPrefix(".") && $0 != "." && $0 != ".." }, [],
                       "\(shell): a dot-file was left behind")

        XCTAssertFalse(FileManager.default.fileExists(atPath: run.data.appendingPathComponent("agents/S").path),
                       "\(shell): the marker outlived the prompt")
        let log = try String(contentsOf: run.data.appendingPathComponent("agents/exits.log"), encoding: .utf8)
            .split(separator: "\n")
        XCTAssertEqual(log.count, 1, "\(shell): \(log)")
        XCTAssertTrue(log.first?.contains("agent=claude status=3 ") == true, "\(shell): \(log)")
    }

    /// Ctrl-Z comes back to a prompt with the agent alive as a stopped job, and
    /// `fg` launches nothing, so a marker cleared there was gone for the rest of
    /// the agent's life. A real stopped job stands in for the agent here (the
    /// stop status alone is not enough, and neither is a job: it takes both).
    func testZshKeepsAStoppedAgentsMarker() throws {
        try assertStop("zsh", write: "_ghostty_preexec claude claude claude >/dev/null",
                       clear: "_ghostty_wortel_clear_agent",
                       waitForStop: #"for k in {1..20}; do [[ ${(v)jobstates} == suspended:* ]] && break; sleep 0.1; done"#)
    }

    func testBashKeepsAStoppedAgentsMarker() throws {
        try assertStop("bash", write: "__ghostty_preexec claude >/dev/null",
                       clear: "__ghostty_wortel_clear_agent", waitForStop: "sleep 0.3")
    }

    private func assertStop(_ shell: String, write: String, clear: String, waitForStop: String) throws {
        let run = try runShell(shell, """
            m="$WT_DATA/agents/S"
            \(write)
            \(clear) 146 >/dev/null
            [ -f "$m" ] || echo "cleared by a stop status with no stopped job" >> "$WT_OUT"
            \(write)
            sleep 30 &
            kill -STOP $!
            \(waitForStop)
            \(clear) 146 >/dev/null
            [ -f "$m" ] && echo "kept at the stop" >> "$WT_OUT"
            \(clear) 0 >/dev/null
            [ -f "$m" ] && echo "kept while it lives" >> "$WT_OUT"
            kill -KILL $!
            wait 2>/dev/null
            sleep 0.2
            \(clear) 0 >/dev/null
            [ -f "$m" ] || echo "cleared once it is gone" >> "$WT_OUT"
            """)
        XCTAssertEqual(run.out.split(separator: "\n").map(String.init), [
            "cleared by a stop status with no stopped job",
            "kept at the stop",
            "kept while it lives",
            "cleared once it is gone",
        ], shell)
        let log = try String(contentsOf: run.data.appendingPathComponent("agents/exits.log"), encoding: .utf8)
            .split(separator: "\n")
        XCTAssertEqual(log.count, 2, "\(shell): one exit per agent, none for the stop: \(log)")
    }

    /// The hooks run inside the user's own shell, options and all. Under `set
    /// -u` an unguarded expansion ends the hook halfway: no prompt mark, no
    /// marker cleared, and on bash 4.4+ no preexec at all.
    func testBashHooksRunUnderNounset() throws {
        let run = try runShell("bash", """
            set -u
            __ghostty_precmd 0 >/dev/null
            __ghostty_preexec 'cd /usr && claude --model x' >/dev/null
            cat "$WT_DATA/agents/S" > "$WT_OUT"
            __ghostty_precmd 0 >/dev/null
            __ghostty_preexec '' >/dev/null
            echo "still here" >> "$WT_OUT"
            """)
        XCTAssertFalse(run.terminal.contains("unbound variable"), run.terminal)
        XCTAssertEqual(Self.fields(run.out)["cwd"], "/usr")
        XCTAssertTrue(run.out.hasSuffix("still here\n"), run.out)
    }

    // MARK: - Harness

    private struct Run {
        let home: URL
        let outPath: String
        let out: String
        /// Everything the shell wrote to its terminal.
        let terminal: String
        var data: URL { home.appendingPathComponent("data") }
    }

    private static func fields(_ marker: String) -> [String: String] {
        var fields: [String: String] = [:]
        for line in marker.split(separator: "\n") {
            guard let eq = line.firstIndex(of: "=") else { continue }
            fields[String(line[..<eq])] = String(line[line.index(after: eq)...])
        }
        return fields
    }

    /// Run `body` in an interactive `shell` with the bundled integration loaded,
    /// session `S`, and a data folder of its own. `$WT_OUT` is where the body
    /// reports, `$WT_IN` holds `input`, `$WT_DATA` is the data folder.
    private func runShell(_ shell: String, _ body: String, input: String = "") throws -> Run {
        let created = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wortel-agentmarker-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: created, withIntermediateDirectories: true)
        // realpath(3), not `resolvingSymlinksInPath`, which strips the /private
        // a shell started in the temp directory reports in $PWD.
        let resolved = try XCTUnwrap(realpath(created.path, nil))
        let home = URL(fileURLWithPath: String(cString: resolved))
        free(resolved)
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        let outPath = home.appendingPathComponent("out").path
        let inPath = home.appendingPathComponent("in").path
        try input.write(toFile: inPath, atomically: true, encoding: .utf8)
        FileManager.default.createFile(atPath: outPath, contents: nil)

        let resources = Self.ghosttyResources
        var environment = [
            "PATH": "/usr/bin:/bin",
            "TERM": "xterm-256color",
            "HOME": home.path,
            "GHOSTTY_RESOURCES_DIR": resources.path,
            "GHOSTTY_SHELL_FEATURES": "title",
            "WORTEL_SESSION_ID": "S",
            "WORTEL_DATA_DIR": home.appendingPathComponent("data").path,
            "WT_OUT": outPath,
            "WT_IN": inPath,
            "WT_DATA": home.appendingPathComponent("data").path,
        ]
        var arguments = ["-q", "/dev/null"]
        switch shell {
        case "zsh":
            environment["ZDOTDIR"] = resources.appendingPathComponent("shell-integration/zsh").path
            arguments += ["/bin/zsh", "-i", "-c", "_ghostty_deferred_init >/dev/null 2>&1\n" + body]
        case "bash":
            let rc = home.appendingPathComponent(".bashrc")
            try "source '\(resources.path)/shell-integration/bash/ghostty.bash'\n"
                .write(to: rc, atomically: true, encoding: .utf8)
            arguments += ["/bin/bash", "--rcfile", rc.path, "-i", "-c", body]
        default:
            environment["XDG_DATA_DIRS"] = resources.appendingPathComponent("shell-integration").path
            environment["GHOSTTY_SHELL_INTEGRATION_XDG_DIR"] = environment["XDG_DATA_DIRS"]
            arguments += [try XCTUnwrap(Self.fish), "-i", "-c", "emit fish_prompt\n" + body]
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = home
        process.standardInput = FileHandle.nullDevice
        let terminal = Pipe()
        process.standardOutput = terminal
        process.standardError = terminal
        try process.run()
        // Read before waiting: a full pipe buffer would deadlock the child.
        let output = terminal.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Run(home: home, outPath: outPath,
                   out: (try? String(contentsOfFile: outPath, encoding: .utf8)) ?? "",
                   terminal: String(decoding: output, as: UTF8.self))
    }
}
