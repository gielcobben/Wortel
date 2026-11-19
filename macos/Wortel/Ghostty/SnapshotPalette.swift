import Foundation

/// Keeps a hibernated screen's colours tied to the theme instead of frozen in
/// the one it was saved under.
///
/// A terminal's cells hold two kinds of colour: a place in the palette ("ANSI
/// green"), which follows light and dark, and a fixed 24-bit colour a program
/// chose. libghostty's screen dump (`write_screen_file:copy,vt`) is always
/// written with the palette resolved, so every palette cell comes out as the
/// 24-bit value it had at that moment (`Surface.writeScreenFile` passes the
/// palette to the formatter, and the binding gives no way not to; Ghostty
/// 1.3.1). Written back into a new terminal, those cells are fixed colours
/// for good: a prompt saved in dark stays GitHub Dark's green in light, and
/// keeps it through every later change. GitHub Dark's white on a white page
/// is text nobody can read.
///
/// So the palette is swapped for marker colours for the moment of the dump,
/// one per index, and the markers are turned back into palette indices before
/// the dump is used. A cell that was "palette 2" is "palette 2" again.
///
/// The one way this is wrong: a program that painted with exactly one of the
/// 256 marker values gets a palette colour back instead. They are picked to be
/// nobody's colour (165 and 90 are in neither the xterm colour cube nor its
/// greys, nor in either bundled theme), and the cost of a hit is one cell in
/// a slightly different colour.
enum SnapshotPalette {
    /// The marker for a palette index: red and green fixed, the index in blue.
    static let red: UInt8 = 165
    static let green: UInt8 = 90

    /// Written into a terminal just before its screen is dumped: every palette
    /// entry set to its marker (`OSC 4`). Only ever on the pty's queue, like
    /// any write into a terminal: each entry is a message to the main thread.
    static let install: [UInt8] = {
        var out = ""
        out.reserveCapacity(256 * 24)
        let r = String(red, radix: 16), g = String(green, radix: 16)
        for index in 0..<256 {
            let b = String(index, radix: 16)
            out += "\u{1B}]4;\(index);rgb:\(r)/\(g)/\(b.count == 1 ? "0" + b : b)\u{1B}\\"
        }
        return Array(out.utf8)
    }()

    /// Puts the palette back to the theme's (`OSC 104`), for a terminal that
    /// turned out not to hibernate after all.
    static let remove: [UInt8] = Array("\u{1B}]104\u{1B}\\".utf8)

    /// The dump with every marker colour turned back into its palette index:
    /// `ESC[38;2;165;90;Nm` becomes `ESC[38;5;Nm`, and the same for a
    /// background (`48`) and an underline colour (`58`).
    ///
    /// Exactly the shape the formatter writes and no other (`Style.VTFormatter`
    /// emits one sequence per colour, semicolons, decimal). Anything else is
    /// passed through untouched, including a program's own 24-bit colours.
    static func restoringIndices(_ dump: Data) -> Data {
        var restored = 0
        return restoringIndices(dump, restored: &restored)
    }

    /// The same, saying how many colours it turned back.
    static func restoringIndices(_ dump: Data, restored: inout Int) -> Data {
        let esc: UInt8 = 0x1B
        let markerTail = Array(";2;\(red);\(green);".utf8)
        var out = Data()
        out.reserveCapacity(dump.count)
        dump.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let bytes = raw.bindMemory(to: UInt8.self)
            let count = bytes.count
            var copiedTo = 0
            var i = 0
            while i < count {
                // ESC [ 3|4|5 8 ; 2 ; R ; G ; <index> m
                guard bytes[i] == esc, i + 3 < count, bytes[i + 1] == UInt8(ascii: "["),
                      bytes[i + 3] == UInt8(ascii: "8"),
                      bytes[i + 2] == UInt8(ascii: "3") || bytes[i + 2] == UInt8(ascii: "4")
                        || bytes[i + 2] == UInt8(ascii: "5")
                else {
                    i += 1
                    continue
                }
                var j = i + 4
                var matches = j + markerTail.count <= count
                if matches {
                    for (offset, byte) in markerTail.enumerated() where bytes[j + offset] != byte {
                        matches = false
                        break
                    }
                }
                guard matches else {
                    i += 1
                    continue
                }
                j += markerTail.count
                let digits = j
                var index = 0
                while j < count, j - digits < 3, bytes[j] >= UInt8(ascii: "0"), bytes[j] <= UInt8(ascii: "9") {
                    index = index * 10 + Int(bytes[j] - UInt8(ascii: "0"))
                    j += 1
                }
                guard j > digits, j < count, bytes[j] == UInt8(ascii: "m"), index < 256 else {
                    i += 1
                    continue
                }
                out.append(UnsafeBufferPointer(rebasing: bytes[copiedTo..<i]))
                out.append(contentsOf: [esc, UInt8(ascii: "["), bytes[i + 2], UInt8(ascii: "8")])
                out.append(contentsOf: Array(";5;\(index)m".utf8))
                restored += 1
                i = j + 1
                copiedTo = i
            }
            out.append(UnsafeBufferPointer(rebasing: bytes[copiedTo..<count]))
        }
        return out
    }
}
