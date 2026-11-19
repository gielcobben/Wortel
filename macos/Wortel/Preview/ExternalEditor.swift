import AppKit
import UniformTypeIdentifiers

/// The app a previewed file opens in outside Wortel, and how to tell it the
/// line.
///
/// No setting: the editor is the file's default app, which is already where
/// the Mac sends it when you double-click it in Finder. What Wortel adds is the
/// line. Each editor takes it its own way, and the ones that can't be told
/// still open the file.
///
/// Not every default app is an editor, and some run what they are handed
/// (a terminal, Python Launcher, the Installer). So the button is offered
/// when the app is a known editor, or when the file is something to look
/// at (text, an image, a PDF) and not a script: never a list of apps to
/// avoid, which is only as good as the apps somebody thought of.
enum ExternalEditor {
    struct App: Equatable {
        let url: URL
        let name: String
        let bundleID: String?
    }

    /// How to open a file at a line in one editor.
    enum Launch: Equatable {
        /// A URL the editor registered (`vscode://file/…:42:1`).
        case url(URL)
        /// A command the editor ships (`zed file:42`, `xed --line 42 file`).
        case command(URL, [String])
    }

    /// Apps that open a file to edit it, whatever the file is.
    static let editors: Set<String> = [
        "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.todesktop.230313mzl4w4u92",
        "dev.zed.Zed", "dev.zed.Zed-Preview", "com.sublimetext.4", "com.sublimetext.3",
        "com.apple.dt.Xcode", "com.apple.TextEdit", "com.barebones.bbedit", "com.panic.Nova",
        "com.coteditor.CotEditor",
    ]

    /// Something to look at whichever app opens it: text, an image, a PDF.
    /// Not a script (a `.py` or a `.command` is text that an app may run),
    /// not an executable, and not a link file (`.webloc`), which is none of
    /// these.
    static func isDocument(_ file: URL) -> Bool {
        guard let type = (try? file.resourceValues(forKeys: [.contentTypeKey]))?.contentType
        else { return false }
        if type.conforms(to: .script) || type.conforms(to: .executable) { return false }
        return type.conforms(to: .text) || type.conforms(to: .image) || type.conforms(to: .pdf)
    }

    /// The file's default app, when it is one to offer.
    @MainActor
    static func app(for file: URL) -> App? {
        guard let appURL = NSWorkspace.shared.urlForApplication(toOpen: file) else { return nil }
        let bundleID = Bundle(url: appURL)?.bundleIdentifier
        guard bundleID != Bundle.main.bundleIdentifier else { return nil }
        guard bundleID.map(editors.contains) == true || isDocument(file) else { return nil }
        return App(url: appURL, name: appURL.deletingPathExtension().lastPathComponent, bundleID: bundleID)
    }

    /// Open `file` in `app`, at `line` when the app can be told it.
    @MainActor
    static func open(_ file: URL, line: Int?, in app: App) {
        if let line, let launch = launch(file, line: line, bundleID: app.bundleID, appURL: app.url) {
            switch launch {
            case .url(let url):
                if NSWorkspace.shared.open(url) { return }
            case .command(let executable, let arguments):
                if (try? Process.run(executable, arguments: arguments)) != nil { return }
            }
        }
        NSWorkspace.shared.open([file], withApplicationAt: app.url,
                                configuration: NSWorkspace.OpenConfiguration())
    }

    /// How `bundleID` is told a line, or nil for an app that has no way.
    /// Pure, so the shapes are tested; each is the form the editor's own
    /// documentation gives.
    static func launch(_ file: URL, line: Int, bundleID: String?, appURL: URL) -> Launch? {
        let path = file.path
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        func scheme(_ name: String) -> Launch? {
            URL(string: "\(name)://file\(encoded):\(line):1").map(Launch.url)
        }
        func bundled(_ relative: String, _ arguments: [String]) -> Launch? {
            let tool = appURL.appendingPathComponent(relative)
            guard FileManager.default.isExecutableFile(atPath: tool.path) else { return nil }
            return .command(tool, arguments)
        }
        switch bundleID {
        case "com.microsoft.VSCode": return scheme("vscode")
        case "com.microsoft.VSCodeInsiders": return scheme("vscode-insiders")
        case "com.todesktop.230313mzl4w4u92": return scheme("cursor")
        case "dev.zed.Zed", "dev.zed.Zed-Preview":
            return bundled("Contents/MacOS/cli", ["\(path):\(line)"])
        case "com.sublimetext.4", "com.sublimetext.3":
            return bundled("Contents/SharedSupport/bin/subl", ["\(path):\(line)"])
        case "com.apple.dt.Xcode":
            // `xed` is Xcode's own, and opens in the Xcode it ships with.
            return bundled("Contents/Developer/usr/bin/xed", ["--line", String(line), path])
        default:
            return nil
        }
    }
}
