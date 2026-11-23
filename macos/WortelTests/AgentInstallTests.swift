import XCTest

/// The install lines Wortel types for someone, which makes each of them a
/// thing a person is about to run on Wortel's word. They are typed, never
/// run: a newline in one would run it.
final class AgentInstallTests: XCTestCase {
    func testALineIsTypedAndNeverRun() {
        for agent in AgentInstall.offered {
            XCTAssertFalse(agent.line.contains(where: \.isNewline), "\(agent.name): a newline would press Return")
            XCTAssertNil(agent.line.unicodeScalars.first { $0.value < 0x20 || $0.value == 0x7F },
                         "\(agent.name): no control character reaches the prompt")
        }
    }

    func testEachIsTheAgentsOwnInstallerOverHTTPS() {
        // One download, piped to a shell, from the agent's own address: the
        // shape each of the three sites gives. Anything else (a second
        // command, a redirect to a file, sudo) was not read off a page.
        let hosts = ["claude": "claude.ai", "codex": "chatgpt.com", "pi": "pi.dev"]
        for agent in AgentInstall.offered {
            let words = agent.line.split(separator: " ").map(String.init)
            XCTAssertEqual(words.count, 5, agent.name)
            XCTAssertEqual(Array(words.prefix(2)), ["curl", "-fsSL"], agent.name)
            XCTAssertEqual(words[3], "|", agent.name)
            XCTAssertTrue(["sh", "bash"].contains(words[4]), agent.name)
            let url = URL(string: words[2])
            XCTAssertEqual(url?.scheme, "https", agent.name)
            XCTAssertEqual(url?.host, hosts[agent.command], agent.name)
        }
    }

    func testOnlyAgentsWortelKnowsAreOffered() {
        for agent in AgentInstall.offered {
            XCTAssertTrue(AgentCommands.offered.contains(agent.command),
                          "\(agent.name) must be one the lookup can find afterwards, or its row never goes")
        }
        XCTAssertEqual(Set(AgentInstall.offered.map(\.command)).count, AgentInstall.offered.count)
    }
}
