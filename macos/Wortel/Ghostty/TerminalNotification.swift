import Foundation

/// A notification a program asked its terminal to show: OSC 9 with text,
/// OSC 777 (`notify;title;body`) or kitty's OSC 99.
struct TerminalNotification: Equatable {
    var title: String
    var body: String
}

/// Reads those three sequences. One per terminal: kitty's arrives in chunks.
///
/// Wortel reads them off the pty itself (`ProgramSignalScanner`), where
/// libghostty would have. Its core allows one desktop notification a second
/// for the whole app, and drops one that says the same as the last inside
/// five seconds (`showDesktopNotification` in Ghostty's `Surface.zig`): right
/// for one terminal, and for a window of agents it means two that finish in
/// the same second are one notification, and the other is lost without a
/// trace. Measured here on 2026-11-19: three sessions sending "Approval
/// requested: npm test" a second apart, one arrival.
struct TerminalNotificationReader {
    /// Kitty notifications arrive in chunks keyed by id until one says done.
    private var kittyParts: [String: (title: String, body: String)] = [:]

    /// The notification an OSC `number` with `text` after it comes to. nil
    /// when it is something else (OSC 9 is also ConEmu's, whose subcommands
    /// are numbers: `9;4` is progress), or a kitty chunk with more to come.
    mutating func read(number: Int, text: String) -> TerminalNotification? {
        switch number {
        case 9:
            let first = text.split(separator: ";", omittingEmptySubsequences: false).first ?? ""
            if !first.isEmpty, first.allSatisfy({ $0.isASCII && $0.isNumber }) { return nil }
            return TerminalNotification(title: "", body: text)
        case 777:
            let parts = text.split(separator: ";", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count >= 2, parts[0] == "notify" else { return nil }
            return TerminalNotification(title: String(parts[1]), body: parts.count > 2 ? String(parts[2]) : "")
        case 99:
            return kitty(text)
        default:
            return nil
        }
    }

    /// Kitty's OSC 99: `key=value:key=value;payload`. `p` says whether the
    /// payload is the title (the default) or the body, `e=1` that it is
    /// base64, `d=0` that more is coming for the same `i`.
    private mutating func kitty(_ text: String) -> TerminalNotification? {
        guard let split = text.firstIndex(of: ";") else { return nil }
        var fields: [String: String] = [:]
        for pair in text[..<split].split(separator: ":") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            if kv.count == 2 { fields[String(kv[0])] = String(kv[1]) }
        }
        var payload = String(text[text.index(after: split)...])
        if fields["e"] == "1" {
            guard let data = Data(base64Encoded: payload),
                  let decoded = String(data: data, encoding: .utf8) else { return nil }
            payload = decoded
        }
        let id = fields["i"] ?? ""
        var parts = kittyParts[id] ?? (title: "", body: "")
        switch fields["p"] ?? "title" {
        case "title": parts.title += payload
        case "body": parts.body += payload
        default: return nil // icons, buttons, queries: nothing to show
        }
        if fields["d"] == "0" {
            kittyParts[id] = parts
            return nil
        }
        kittyParts[id] = nil
        return TerminalNotification(title: parts.title, body: parts.body)
    }
}
