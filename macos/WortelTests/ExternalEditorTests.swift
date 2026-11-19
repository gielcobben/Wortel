import XCTest

/// How each editor is told a line. The shapes are the editors' own
/// documented ones; a wrong one opens the file at the top, or not at all.
final class ExternalEditorTests: XCTestCase {
    private let file = URL(fileURLWithPath: "/tmp/a b/App.swift")
    private let app = URL(fileURLWithPath: "/Applications/Some.app")

    func testURLSchemes() {
        XCTAssertEqual(ExternalEditor.launch(file, line: 42, bundleID: "com.microsoft.VSCode", appURL: app),
                       .url(URL(string: "vscode://file/tmp/a%20b/App.swift:42:1")!))
        XCTAssertEqual(ExternalEditor.launch(file, line: 7, bundleID: "com.todesktop.230313mzl4w4u92", appURL: app),
                       .url(URL(string: "cursor://file/tmp/a%20b/App.swift:7:1")!))
    }

    func testBundledCommands() throws {
        let fake = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wortel-editor-" + UUID().uuidString + "/Zed.app")
        let cli = fake.appendingPathComponent("Contents/MacOS/cli")
        try FileManager.default.createDirectory(at: cli.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: cli.path, contents: Data("#!/bin/sh\n".utf8),
                                       attributes: [.posixPermissions: 0o755])
        defer { try? FileManager.default.removeItem(at: fake.deletingLastPathComponent()) }
        XCTAssertEqual(ExternalEditor.launch(file, line: 3, bundleID: "dev.zed.Zed", appURL: fake),
                       .command(cli, ["/tmp/a b/App.swift:3"]))
        // An app without its tool still opens the file, without the line.
        XCTAssertNil(ExternalEditor.launch(file, line: 3, bundleID: "dev.zed.Zed", appURL: app))
    }

    func testAnAppWithNoWayToBeToldIsNil() {
        XCTAssertNil(ExternalEditor.launch(file, line: 3, bundleID: "com.apple.TextEdit", appURL: app))
        XCTAssertNil(ExternalEditor.launch(file, line: 3, bundleID: nil, appURL: app))
    }

    /// What an app other than a known editor is trusted with.
    func testDocumentsAreTextImagesAndPDFsButNotScripts() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wortel-documents-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        func file(_ name: String) throws -> URL {
            let url = dir.appendingPathComponent(name)
            try Data("x".utf8).write(to: url)
            return url
        }
        for name in ["notes.md", "notes.txt", "data.json", "shot.png", "doc.pdf"] {
            XCTAssertTrue(ExternalEditor.isDocument(try file(name)), name)
        }
        for name in ["deploy.py", "run.sh", "go.command", "site.webloc"] {
            XCTAssertFalse(ExternalEditor.isDocument(try file(name)), name)
        }
    }
}
