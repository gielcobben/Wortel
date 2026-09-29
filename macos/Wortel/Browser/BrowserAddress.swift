import Foundation

/// Addresses as a browser tab reads and writes them. Pure, so the rules for
/// what a typed address means have tests of their own (BrowserAddressTests).
enum BrowserAddress {
    /// `localhost:5173`, `localhost:5173/docs`, `wortel.sh`: what a tab and
    /// the address field call an address. The scheme is noise.
    static func short(_ url: URL) -> String {
        guard let host = url.host() else { return url.absoluteString }
        var text = host
        if let port = url.port { text += ":\(port)" }
        let path = url.path()
        if !path.isEmpty, path != "/" { text += path }
        if let query = url.query() { text += "?" + query }
        return text
    }

    /// What was typed, as somewhere to go. A port alone is a local server
    /// (`3000`, `:3000`); a local name without a scheme is http, anything else
    /// https.
    static func url(from typed: String) -> URL? {
        var text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(" ") else { return nil }
        if text.hasPrefix(":") { text.removeFirst() }
        if Int(text) != nil { text = "localhost:" + text }
        if !text.contains("://") {
            let host = text.split(whereSeparator: { ":/?".contains($0) }).first.map(String.init) ?? text
            text = (isLocalHost(host) ? "http://" : "https://") + text
        }
        guard let url = URL(string: text), url.host() != nil else { return nil }
        return url
    }

    static func isLocalHost(_ host: String) -> Bool {
        let host = host.lowercased()
        return host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]"
            || host == "0.0.0.0" || host.hasSuffix(".localhost") || host.hasSuffix(".local")
    }
}
