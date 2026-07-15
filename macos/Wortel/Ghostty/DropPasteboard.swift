import AppKit

/// Turns pasteboard contents (from a drag-drop or a Cmd-V paste) into
/// shell-ready file paths to inject at the prompt. This is the mechanism
/// agents (Claude Code et al.) use to receive images: the terminal inserts
/// the path, the agent reads the file. Real files are used as-is; raw image
/// bytes (a screenshot on the clipboard, an image dragged from a browser)
/// are spilled to a temp file first.
enum DropPasteboard {
    /// Shell-escape a path so paths with spaces/quotes survive at the prompt.
    /// Left bare when it contains only unambiguously safe characters.
    static func shellEscape(_ path: String) -> String {
        if path.range(of: "[^A-Za-z0-9._/-]", options: .regularExpression) == nil {
            return path
        }
        return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Shell-escaped paths for anything insertable on the pasteboard, or `[]`.
    /// Prefers real file URLs; otherwise writes raw image data to a temp file.
    static func insertablePaths(from pb: NSPasteboard) -> [String] {
        let opts: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: opts) as? [URL],
           !urls.isEmpty {
            return urls.map { shellEscape($0.path) }
        }
        if let url = writeTempImage(from: pb) {
            return [shellEscape(url.path)]
        }
        return []
    }

    /// True if the pasteboard holds a file or image we can insert. Cheap
    /// enough to call from `draggingEntered`/`draggingUpdated` — the class
    /// checks inspect declared types without decoding the image.
    static func hasInsertableContent(_ pb: NSPasteboard) -> Bool {
        let fileOpts: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        return pb.canReadObject(forClasses: [NSURL.self], options: fileOpts)
            || pb.canReadObject(forClasses: [NSImage.self], options: nil)
    }

    /// Spill pasteboard image bytes to a temp PNG. Goes through NSImage so it
    /// accepts any format the pasteboard offers (PNG, TIFF, JPEG, PDF, …),
    /// not just the few raw types. Returns nil when there's no image.
    private static func writeTempImage(from pb: NSPasteboard) -> URL? {
        guard let image = NSImage(pasteboard: pb),
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wortel-\(UUID().uuidString).png")
        do {
            try png.write(to: url)
            return url
        } catch {
            return nil
        }
    }
}
