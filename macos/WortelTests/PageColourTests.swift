import AppKit
import XCTest

/// The page behind a terminal is drawn twice: by AppKit (`Chrome.content`)
/// around the terminal, and by libghostty under its text, in the theme's
/// `background`. Two colours there are a seam at the terminal's edge and in
/// the strip a resize leaves uncovered, and a program asking for the
/// background (OSC 11) is told a colour nobody sees. So they are one colour,
/// and this is what keeps them one (`docs/appearance.md`).
@MainActor
final class PageColourTests: XCTestCase {

    private static let resources = URL(fileURLWithPath: #filePath)   // …/macos/WortelTests/PageColourTests.swift
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Resources")

    /// `key = value` lines of a ghostty config, last one wins.
    private func settings(_ url: URL) throws -> [String: String] {
        var out: [String: String] = [:]
        for line in try String(contentsOf: url, encoding: .utf8).split(separator: "\n") {
            let text = line.trimmingCharacters(in: .whitespaces)
            guard !text.hasPrefix("#"), let eq = text.firstIndex(of: "=") else { continue }
            out[text[..<eq].trimmingCharacters(in: .whitespaces)] =
                text[text.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        }
        return out
    }

    private func hex(_ color: NSColor, dark: Bool) -> String {
        var resolved = color
        NSAppearance(named: dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance {
            resolved = color.usingColorSpace(.sRGB)!
        }
        let c = [resolved.redComponent, resolved.greenComponent, resolved.blueComponent]
        return "#" + c.map { String(format: "%02x", Int(($0 * 255).rounded())) }.joined()
    }

    func testEachThemeBackgroundIsThePage() throws {
        let conf = try settings(Self.resources.appendingPathComponent("wortel.conf"))
        // `light:Name,dark:Name`
        var themes: [String: String] = [:]
        for part in try XCTUnwrap(conf["theme"]).split(separator: ",") {
            let pair = part.split(separator: ":", maxSplits: 1).map(String.init)
            themes[pair[0]] = pair[1]
        }
        for (side, dark) in [("light", false), ("dark", true)] {
            let name = try XCTUnwrap(themes[side], "no \(side) theme")
            let theme = try settings(Self.resources.appendingPathComponent("ghostty/themes/\(name)"))
            XCTAssertEqual(theme["background"]?.lowercased(), hex(Chrome.content, dark: dark),
                           "\(name)'s background is not the \(side) page")
        }
    }

    /// The floor measures text against the terminal's own background times
    /// its opacity. Below 1 that is darker than the page (at 0, black), and
    /// the light theme's ordinary text was redrawn white on the white page
    /// (2026-11-19). The floor is only safe over an opaque background.
    func testTheContrastFloorIsMeasuredAgainstAnOpaquePage() throws {
        let conf = try settings(Self.resources.appendingPathComponent("wortel.conf"))
        let floor = Double(conf["minimum-contrast"] ?? "1") ?? 1
        guard floor > 1 else { return }
        XCTAssertEqual(Double(conf["background-opacity"] ?? "1"), 1)
        // The faintest colours meant to be seen measure 1.99 (GitHub Dark's
        // black on the dark page) and 2.04 (Claude Code's `subtle`); above
        // them the floor starts redrawing colours somebody chose.
        XCTAssertLessThan(floor, 1.99)
    }
}
