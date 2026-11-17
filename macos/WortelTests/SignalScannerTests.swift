import XCTest

/// While a session is hibernated this is the only thing reading its signals,
/// and the bytes it lets through are written into a terminal later. A signal
/// missed is a dot that never lights; one let through is raised twice.
final class SignalScannerTests: XCTestCase {

    private func scan(_ chunks: [String], scanner: inout SignalScanner,
                      times: [UInt64]? = nil) -> (signals: [SignalScanner.Signal], output: String) {
        var signals: [SignalScanner.Signal] = []
        var output: [UInt8] = []
        for (index, chunk) in chunks.enumerated() {
            let bytes = Array(chunk.utf8)
            bytes.withUnsafeBufferPointer { raw in
                signals += scanner.scan(raw, now: times?[index] ?? 0, output: &output)
            }
        }
        return (signals, String(decoding: output, as: UTF8.self))
    }

    private func scan(_ chunks: String...) -> (signals: [SignalScanner.Signal], output: String) {
        var scanner = SignalScanner()
        return scan(chunks, scanner: &scanner)
    }

    func testPlainOutputPassesThrough() {
        let text = "hello \u{1B}[31mred\u{1B}[0m\r\n\u{1B}[?2004h"
        let result = scan(text)
        XCTAssertEqual(result.signals, [])
        XCTAssertEqual(result.output, text)
    }

    func testTitlesWithEitherTerminator() {
        let result = scan("a\u{1B}]0;one\u{07}b\u{1B}]2;two\u{1B}\\c")
        XCTAssertEqual(result.signals, [.title("one"), .title("two")])
        XCTAssertEqual(result.output, "abc")
    }

    func testIconNameIsTakenOutButSaysNothing() {
        let result = scan("\u{1B}]1;icon\u{07}x")
        XCTAssertEqual(result.signals, [])
        XCTAssertEqual(result.output, "x")
    }

    func testBellOutsideASequence() {
        XCTAssertEqual(scan("a\u{07}b").signals, [.bell])
        XCTAssertEqual(scan("a\u{07}b").output, "ab")
    }

    func testBellInsideAStringIsNotABell() {
        let dcs = "\u{1B}P1$r\u{07}\u{1B}\\"
        let result = scan(dcs)
        XCTAssertEqual(result.signals, [])
        XCTAssertEqual(result.output, dcs)
    }

    func testProgressStates() {
        let result = scan("\u{1B}]9;4;3\u{07}\u{1B}]9;4;1;40\u{07}\u{1B}]9;4;2\u{07}\u{1B}]9;4;4\u{07}\u{1B}]9;4;0\u{07}")
        XCTAssertEqual(result.signals, [
            .progress(active: true, errored: false),
            .progress(active: true, errored: false),
            .progress(active: true, errored: true),
            .progress(active: false, errored: false),
            .progress(active: false, errored: false),
        ])
        XCTAssertEqual(result.output, "")
    }

    func testOSC9TextIsANotificationAndOtherSubcommandsAreNot() {
        XCTAssertEqual(scan("\u{1B}]9;Claude needs your permission\u{07}").signals,
                       [.notification(title: "", body: "Claude needs your permission")])
        XCTAssertEqual(scan("\u{1B}]9;1;500\u{07}").signals, [])
    }

    func testRxvtNotification() {
        XCTAssertEqual(scan("\u{1B}]777;notify;Amp;Agent is ready; really\u{07}").signals,
                       [.notification(title: "Amp", body: "Agent is ready; really")])
    }

    func testKittyNotificationInChunks() {
        let result = scan("\u{1B}]99;i=1:d=0;crush\u{1B}\\", "\u{1B}]99;i=1:p=body;Permission needed\u{1B}\\")
        XCTAssertEqual(result.signals, [.notification(title: "crush", body: "Permission needed")])
    }

    func testKittyBase64() {
        let encoded = Data("Done".utf8).base64EncodedString()
        XCTAssertEqual(scan("\u{1B}]99;e=1;\(encoded)\u{07}").signals,
                       [.notification(title: "Done", body: "")])
    }

    func testCommandFinishedTimesFromStart() {
        var scanner = SignalScanner()
        let result = scan(["\u{1B}]133;C\u{07}", "out", "\u{1B}]133;D;2\u{07}"],
                          scanner: &scanner, times: [1_000, 2_000, 12_000_001_000])
        XCTAssertEqual(result.signals, [.commandFinished(exitCode: 2, durationNs: 12_000_000_000)])
        XCTAssertEqual(result.output, "\u{1B}]133;C\u{07}out")
    }

    func testCommandFinishedWithoutExitCode() {
        XCTAssertEqual(scan("\u{1B}]133;D\u{07}").signals, [.commandFinished(exitCode: -1, durationNs: 0)])
    }

    func testPromptMarksStayButACommandEndGoes() {
        let marks = "\u{1B}]133;A\u{07}$ \u{1B}]133;B\u{1B}\\ls\u{1B}]133;C\u{07}"
        let result = scan(marks + "out\u{1B}]133;D;0\u{07}")
        XCTAssertEqual(result.signals, [.commandFinished(exitCode: 0, durationNs: 0)])
        XCTAssertEqual(result.output, marks + "out")
    }

    func testCwdFromThisMachineOnly() {
        XCTAssertEqual(scan("\u{1B}]7;file://localhost/Users/me/My%20Code\u{07}").signals,
                       [.pwd("/Users/me/My Code")])
        XCTAssertEqual(scan("\u{1B}]7;file://some-other-box.example/tmp\u{07}").signals, [])
        XCTAssertEqual(scan("\u{1B}]7;https://localhost/tmp\u{07}").signals, [])
    }

    func testOtherOSCsPassThroughWhole() {
        let link = "\u{1B}]8;;https://wortel.sh\u{1B}\\site\u{1B}]8;;\u{1B}\\"
        let colour = "\u{1B}]11;?\u{07}"
        let result = scan(link + colour)
        XCTAssertEqual(result.signals, [])
        XCTAssertEqual(result.output, link + colour)
    }

    func testSplitAcrossReadsAnywhere() {
        let whole = "x\u{1B}]0;spinner ⠋ working\u{1B}\\y\u{1B}]9;4;3\u{07}z\u{1B}]8;;u\u{07}"
        let bytes = Array(whole.utf8)
        for cut in 1..<bytes.count {
            var scanner = SignalScanner()
            var output: [UInt8] = []
            var signals: [SignalScanner.Signal] = []
            for part in [Array(bytes[..<cut]), Array(bytes[cut...])] {
                part.withUnsafeBufferPointer { signals += scanner.scan($0, now: 0, output: &output) }
            }
            XCTAssertEqual(signals, [.title("spinner ⠋ working"), .progress(active: true, errored: false)],
                           "cut at \(cut)")
            XCTAssertEqual(String(decoding: output, as: UTF8.self), "xyz\u{1B}]8;;u\u{07}", "cut at \(cut)")
        }
    }

    func testAnOpenSequenceIsHandedOverWhole() {
        var scanner = SignalScanner()
        let first = scan(["ok\u{1B}]0;half a ti"], scanner: &scanner)
        XCTAssertEqual(first.signals, [])
        XCTAssertEqual(first.output, "ok")
        XCTAssertEqual(String(decoding: scanner.unfinished, as: UTF8.self), "\u{1B}]0;half a ti")

        var passing = SignalScanner()
        _ = scan(["\u{1B}]8;;https://x\u{1B}"], scanner: &passing)
        XCTAssertEqual(passing.unfinished, [0x1B])
        XCTAssertEqual(SignalScanner().unfinished, [])
    }

    func testTooLongIsIgnoredLikeTheTerminal() {
        let long = String(repeating: "a", count: SignalScanner.maximumLength + 10)
        let result = scan("\u{1B}]0;\(long)\u{07}after")
        XCTAssertEqual(result.signals, [])
        XCTAssertEqual(result.output, "after")
    }

    func testCancelledOSCSaysNothing() {
        let result = scan("\u{1B}]0;half\u{18}rest")
        XCTAssertEqual(result.signals, [])
        XCTAssertEqual(result.output, "\u{18}rest")
    }

    func testEscapeThatCutsAnOSCShortStartsTheNextSequence() {
        let result = scan("\u{1B}]0;half\u{1B}[31mred")
        XCTAssertEqual(result.signals, [])
        XCTAssertEqual(result.output, "\u{1B}[31mred")
    }
}
