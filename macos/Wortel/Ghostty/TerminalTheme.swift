import Foundation

/// The colours terminals are shown in, read from the same files libghostty
/// reads them from: `wortel.conf`'s `theme = light:…,dark:…` and the bundled
/// theme it names. For the keeper, which answers programs that ask about them
/// (OSC 10, 11, 12, 4; light or dark) with or without the app, and so has to
/// be told what the app shows (`KeeperAppearance`).
enum TerminalTheme {
    /// nil when the bundle does not hold what `wortel.conf` names, which is a
    /// broken build (`PageColourTests` keeps it from shipping).
    static func appearance(dark: Bool, resources: URL? = Bundle.main.resourceURL) -> KeeperAppearance? {
        guard let resources,
              let conf = settings(at: resources.appendingPathComponent("wortel.conf")),
              let name = themeName(conf["theme"]?.first, dark: dark),
              let theme = settings(at: resources.appendingPathComponent("ghostty/themes/\(name)")),
              let background = theme["background"]?.last.flatMap(rgb),
              let foreground = theme["foreground"]?.last.flatMap(rgb)
        else { return nil }

        var palette = xtermPalette
        for entry in theme["palette"] ?? [] {
            let parts = entry.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2, let index = Int(parts[0]), palette.indices.contains(index),
                  let color = rgb(parts[1]) else { continue }
            palette[index] = color
        }
        return KeeperAppearance(dark: dark, foreground: foreground, background: background,
                                cursor: theme["cursor-color"]?.last.flatMap(rgb), palette: palette)
    }

    /// `light:A,dark:B`, or one name for both.
    static func themeName(_ value: String?, dark: Bool) -> String? {
        guard let value else { return nil }
        let parts = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        let wanted = dark ? "dark:" : "light:"
        if let match = parts.first(where: { $0.hasPrefix(wanted) }) { return String(match.dropFirst(wanted.count)) }
        return parts.count == 1 && !parts[0].contains(":") ? parts[0] : nil
    }

    /// Ghostty's config format: `key = value` a line, `#` comments, a key
    /// that repeats (`palette`) keeping every value in order.
    static func settings(at url: URL) -> [String: [String]]? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var result: [String: [String]] = [:]
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"),
                  let equals = trimmed.firstIndex(of: "=") else { continue }
            let key = trimmed[..<equals].trimmingCharacters(in: .whitespaces)
            let value = trimmed[trimmed.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            result[key, default: []].append(value)
        }
        return result
    }

    /// `#rrggbb` or `rrggbb` as 0xRRGGBB.
    static func rgb(_ value: String) -> UInt32? {
        let hex = value.hasPrefix("#") ? String(value.dropFirst()) : value
        guard hex.count == 6 else { return nil }
        return UInt32(hex, radix: 16)
    }

    /// The xterm 256-colour palette, which is libghostty's default: the 16
    /// a theme sets, a 6x6x6 cube, and 24 greys.
    static let xtermPalette: [UInt32] = {
        let base: [UInt32] = [
            0x000000, 0xCD0000, 0x00CD00, 0xCDCD00, 0x0000EE, 0xCD00CD, 0x00CDCD, 0xE5E5E5,
            0x7F7F7F, 0xFF0000, 0x00FF00, 0xFFFF00, 0x5C5CFF, 0xFF00FF, 0x00FFFF, 0xFFFFFF,
        ]
        let levels: [UInt32] = [0, 95, 135, 175, 215, 255]
        var cube: [UInt32] = []
        for r in levels { for g in levels { for b in levels { cube.append(r << 16 | g << 8 | b) } } }
        let greys: [UInt32] = (0..<24).map { let v = UInt32(8 + 10 * $0); return v << 16 | v << 8 | v }
        return base + cube + greys
    }()
}
