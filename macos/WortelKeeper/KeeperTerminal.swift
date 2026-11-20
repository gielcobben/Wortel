import Darwin
import Foundation
import GhosttyVt

/// One session's terminal, held by the keeper: a libghostty-vt terminal with
/// no renderer that parses every byte the program writes, at the size its pty
/// really has.
///
/// **It is the session's terminal.** The app's surface is a display of it:
/// seeded from `snapshot` (an exact copy, from the same Ghostty commit), then
/// fed the same bytes. So whatever happens to the app (a quit, an update, a
/// crash, a terminal dropped while out of sight), nothing here is rebuilt,
/// re-wrapped or asked to repaint. See `docs/architecture/keeper.md`.
///
/// **And it is the one that answers the program.** Cursor position, device
/// attributes, colours, light or dark, sizes: libghostty-vt answers them
/// through `reply`, with the app open or not. The app's surface is told to
/// stay quiet (`ghostty_surface_set_responds`), so nothing is answered twice.
///
/// **One thread at a time, and in stream order.** libghostty-vt is not
/// thread-safe per handle, and everything here also has to happen *between*
/// two reads of the pty: a resize between the bytes written before it and
/// those after, a snapshot at an exact byte. So every call is made on the
/// session's read queue (`PtyHost.enqueue`), and nothing here locks.
final class KeeperTerminal {
    typealias Appearance = KeeperAppearance

    /// The most bytes of an unfinished sequence a snapshot may carry. The
    /// app's restore accepts exactly this much (`Termio.snapshot_continuation_max_bytes`,
    /// Wortel's Ghostty patch).
    static let continuationLimit = 64 * 1024

    /// Bytes for the program: answers to what it asked. Called synchronously
    /// from inside `write` and `resize`, on the session's queue, and must not
    /// call back into this terminal.
    var reply: ((UnsafePointer<UInt8>, Int) -> Void)?

    private(set) var columns: UInt16
    private(set) var rows: UInt16
    private(set) var cellWidth: UInt32 = 0
    private(set) var cellHeight: UInt32 = 0
    private(set) var appearance: Appearance?

    private let handle: GhosttyTerminal
    /// XTVERSION's answer, the same the app's Ghostty gives: `ghostty <version>`.
    private let version: [UInt8]

    /// A new, empty terminal. nil when libghostty-vt could not make one
    /// (out of memory).
    convenience init?(columns: UInt16, rows: UInt16, scrollbackBytes: Int) {
        var created: GhosttyTerminal?
        let columns = max(columns, 1), rows = max(rows, 1)
        guard ghostty_terminal_new(nil, &created, columns, rows) == GHOSTTY_SUCCESS,
              let created else { return nil }
        self.init(handle: created, scrollbackBytes: scrollbackBytes)
    }

    /// A terminal decoded from a snapshot (`snapshot()`), exactly as it was:
    /// it goes on from the byte after the one the snapshot was taken at.
    /// nil when the bytes are not a whole snapshot from this Ghostty.
    convenience init?(snapshot: Data, scrollbackBytes: Int) {
        var decoder: GhosttySnapshotDecoder?
        let made = snapshot.withUnsafeBytes { raw in
            ghostty_snapshot_decoder_new_buf(
                nil, &decoder, raw.bindMemory(to: UInt8.self).baseAddress, raw.count)
        }
        guard made == GHOSTTY_SUCCESS, let decoder else { return nil }
        defer { ghostty_snapshot_decoder_free(decoder) }
        var limit = Self.continuationLimit
        var retain = true
        ghostty_snapshot_decoder_set(decoder, GHOSTTY_SNAPSHOT_DECODER_OPT_MAX_CONTINUATION_BYTES, &limit)
        ghostty_snapshot_decoder_set(decoder, GHOSTTY_SNAPSHOT_DECODER_OPT_RETAIN_CONTINUATION, &retain)
        var decoded: GhosttyTerminal?
        guard ghostty_snapshot_decoder_decode(decoder, &decoded) == GHOSTTY_SUCCESS,
              let decoded else { return nil }
        self.init(handle: decoded, scrollbackBytes: scrollbackBytes)
    }

    private init(handle: GhosttyTerminal, scrollbackBytes: Int) {
        self.handle = handle
        var columns: UInt16 = 0, rows: UInt16 = 0
        ghostty_terminal_get(handle, GHOSTTY_TERMINAL_DATA_COLS, &columns)
        ghostty_terminal_get(handle, GHOSTTY_TERMINAL_DATA_ROWS, &rows)
        self.columns = columns
        self.rows = rows
        version = Array("ghostty \(Self.libraryVersion)".utf8)

        var limit = scrollbackBytes
        ghostty_terminal_set(handle, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES, &limit)
        // Without it, a snapshot taken while the program is in the middle of
        // a sequence (a read can end anywhere) is refused.
        var continuation = Self.continuationLimit
        ghostty_terminal_set(handle, GHOSTTY_TERMINAL_OPT_CONTINUATION_MAX_BYTES, &continuation)
        installCallbacks()
    }

    deinit { ghostty_terminal_free(handle) }

    // MARK: - The stream

    /// Parse what the program wrote. Never fails: malformed input is the
    /// program's, and libghostty-vt keeps the terminal consistent through it.
    func write(_ bytes: UnsafePointer<UInt8>, count: Int) {
        ghostty_terminal_vt_write(handle, bytes, count)
    }

    /// The pty's new size, applied at this point in the stream. Re-wraps the
    /// primary screen, as the app's terminal does, and sends the in-band size
    /// report (`?2048`) if the program asked for one.
    @discardableResult
    func resize(columns: UInt16, rows: UInt16, cellWidth: UInt32, cellHeight: UInt32) -> Bool {
        let columns = max(columns, 1), rows = max(rows, 1)
        guard ghostty_terminal_resize(handle, columns, rows, cellWidth, cellHeight) == GHOSTTY_SUCCESS
        else { return false }
        self.columns = columns
        self.rows = rows
        self.cellWidth = cellWidth
        self.cellHeight = cellHeight
        return true
    }

    /// The whole terminal as a libghostty-vt snapshot: both screens, all of
    /// the scrollback, the modes, the palette the program changed, the title,
    /// and whatever sequence the program is in the middle of. Handed to
    /// `sink` in pieces as it is encoded; a `false` from it stops the encode.
    ///
    /// Only meaningful to a Ghostty built from the same commit.
    func snapshot(into sink: (UnsafeRawBufferPointer) -> Bool) -> Bool {
        withoutActuallyEscaping(sink) { sink in
            var context = sink
            return withUnsafeMutablePointer(to: &context) { pointer in
                let writer = GhosttyWriter(
                    write: { userdata, data, length in
                        guard let userdata else { return false }
                        let sink = userdata.assumingMemoryBound(
                            to: ((UnsafeRawBufferPointer) -> Bool).self).pointee
                        return sink(UnsafeRawBufferPointer(start: data, count: length))
                    },
                    userdata: UnsafeMutableRawPointer(pointer))
                return ghostty_snapshot_encode(handle, writer) == GHOSTTY_SUCCESS
            }
        }
    }

    /// The snapshot as one buffer. For tests and small terminals; the keeper
    /// streams it (`snapshot(into:)`).
    func snapshot() -> Data? {
        var data = Data()
        let done = snapshot { piece in
            data.append(contentsOf: piece)
            return true
        }
        return done ? data : nil
    }

    // MARK: - What the app tells it

    /// The app's colours and light or dark. A change of light or dark is
    /// reported to a program that subscribed to it (`?2031`), which is how an
    /// agent repaints in the new theme: while the app is gone too.
    func setAppearance(_ new: Appearance) {
        let schemeChanged = appearance.map { $0.dark != new.dark } ?? false
        appearance = new

        var foreground = Self.rgb(new.foreground)
        var background = Self.rgb(new.background)
        ghostty_terminal_set(handle, GHOSTTY_TERMINAL_OPT_COLOR_FOREGROUND, &foreground)
        ghostty_terminal_set(handle, GHOSTTY_TERMINAL_OPT_COLOR_BACKGROUND, &background)
        if let cursor = new.cursor {
            var value = Self.rgb(cursor)
            ghostty_terminal_set(handle, GHOSTTY_TERMINAL_OPT_COLOR_CURSOR, &value)
        } else {
            ghostty_terminal_set(handle, GHOSTTY_TERMINAL_OPT_COLOR_CURSOR, nil)
        }
        if new.palette.count == 256 {
            var palette = new.palette.map(Self.rgb)
            palette.withUnsafeMutableBufferPointer {
                _ = ghostty_terminal_set(handle, GHOSTTY_TERMINAL_OPT_COLOR_PALETTE, $0.baseAddress)
            }
        } else {
            ghostty_terminal_set(handle, GHOSTTY_TERMINAL_OPT_COLOR_PALETTE, nil)
        }

        if schemeChanged, mode(2031) { sendColorSchemeReport(dark: new.dark) }
    }

    // MARK: - Reading it

    /// Whether a DEC private mode (or an ANSI one) is set.
    func mode(_ number: UInt16, ansi: Bool = false) -> Bool {
        var query = GhosttyTerminalModeConfig(mode: ghostty_mode_new(number, ansi), value: false)
        guard ghostty_terminal_get(handle, GHOSTTY_TERMINAL_DATA_MODE, &query) == GHOSTTY_SUCCESS
        else { return false }
        return query.value
    }

    /// The text of the active screen and its scrollback, a line the program
    /// wrote once per line however it wrapped, trailing blanks trimmed.
    func text() -> String {
        var formatter: GhosttyFormatter?
        guard ghostty_formatter_terminal_new(nil, &formatter, handle) == GHOSTTY_SUCCESS,
              let formatter else { return "" }
        defer { ghostty_formatter_free(formatter) }
        var unwrap = true
        ghostty_formatter_set(formatter, GHOSTTY_FORMATTER_OPT_UNWRAP, &unwrap)
        var bytes: UnsafeMutablePointer<UInt8>?
        var length = 0
        guard ghostty_formatter_format_alloc(formatter, nil, &bytes, &length) == GHOSTTY_SUCCESS,
              let bytes else { return "" }
        defer { ghostty_free(nil, bytes, length) }
        return String(decoding: UnsafeBufferPointer(start: bytes, count: length), as: UTF8.self)
    }

    /// Bytes this terminal holds in memory, scrollback and images included.
    var residentBytes: UInt64 {
        var usage = GhosttyTerminalMemoryUsage()
        usage.size = MemoryLayout<GhosttyTerminalMemoryUsage>.size
        guard ghostty_terminal_get(handle, GHOSTTY_TERMINAL_DATA_MEMORY_USAGE, &usage) == GHOSTTY_SUCCESS
        else { return 0 }
        return usage.primary_resident_bytes + usage.primary_image_bytes
            + usage.alternate_resident_bytes + usage.alternate_image_bytes
    }

    /// Changes whenever the terminal does anything that compression would
    /// have to start over for. Compared with an earlier value only.
    var activity: UInt64 {
        var token: UInt64 = 0
        ghostty_terminal_compression_activity(handle, &token)
        return token
    }

    /// One bounded step of compressing scrollback nobody is looking at.
    /// True while there is more to do.
    func compressStep() -> Bool {
        var result = GHOSTTY_TERMINAL_COMPRESSION_RESULT_COMPLETE
        guard ghostty_terminal_compress(handle, GHOSTTY_TERMINAL_COMPRESSION_MODE_INCREMENTAL, &result)
            == GHOSTTY_SUCCESS else { return false }
        return result == GHOSTTY_TERMINAL_COMPRESSION_RESULT_PENDING
    }

    // MARK: - Answers

    private func installCallbacks() {
        let me = Unmanaged.passUnretained(self).toOpaque()
        ghostty_terminal_set(handle, GHOSTTY_TERMINAL_OPT_USERDATA, me)

        let writePty: GhosttyTerminalWritePtyFn = { _, userdata, data, length in
            guard let userdata, let data, length > 0 else { return }
            Unmanaged<KeeperTerminal>.fromOpaque(userdata).takeUnretainedValue().reply?(data, length)
        }
        ghostty_terminal_set(handle, GHOSTTY_TERMINAL_OPT_WRITE_PTY, unsafeBitCast(writePty, to: UnsafeRawPointer.self))

        // What Ghostty's own terminal says it is (`StreamHandler.deviceAttributes`):
        // a VT220 level 2 with colour and clipboard access, firmware 10.
        let deviceAttributes: GhosttyTerminalDeviceAttributesFn = { _, _, attributes in
            guard let attributes else { return false }
            attributes.pointee.primary.conformance_level = 62
            attributes.pointee.primary.features.0 = 22
            attributes.pointee.primary.features.1 = 52
            attributes.pointee.primary.num_features = 2
            attributes.pointee.secondary.device_type = 1
            attributes.pointee.secondary.firmware_version = 10
            attributes.pointee.secondary.rom_cartridge = 0
            return true
        }
        ghostty_terminal_set(handle, GHOSTTY_TERMINAL_OPT_DEVICE_ATTRIBUTES,
                             unsafeBitCast(deviceAttributes, to: UnsafeRawPointer.self))

        let xtversion: GhosttyTerminalXtversionFn = { _, userdata in
            guard let userdata else { return GhosttyString(ptr: nil, len: 0) }
            let terminal = Unmanaged<KeeperTerminal>.fromOpaque(userdata).takeUnretainedValue()
            // Borrowed for the length of the callback; `version` lives as
            // long as the terminal.
            return terminal.version.withUnsafeBufferPointer {
                GhosttyString(ptr: $0.baseAddress, len: $0.count)
            }
        }
        ghostty_terminal_set(handle, GHOSTTY_TERMINAL_OPT_XTVERSION, unsafeBitCast(xtversion, to: UnsafeRawPointer.self))

        let size: GhosttyTerminalSizeFn = { _, userdata, out in
            guard let userdata, let out else { return false }
            let terminal = Unmanaged<KeeperTerminal>.fromOpaque(userdata).takeUnretainedValue()
            // No cell size yet means no app has told one: a size report in
            // pixels would be a lie, so it is not given.
            guard terminal.cellWidth > 0, terminal.cellHeight > 0 else { return false }
            out.pointee = GhosttySizeReportSize(
                rows: terminal.rows, columns: terminal.columns,
                cell_width: terminal.cellWidth, cell_height: terminal.cellHeight)
            return true
        }
        ghostty_terminal_set(handle, GHOSTTY_TERMINAL_OPT_SIZE, unsafeBitCast(size, to: UnsafeRawPointer.self))

        let colorScheme: GhosttyTerminalColorSchemeFn = { _, userdata, out in
            guard let userdata, let out else { return false }
            let terminal = Unmanaged<KeeperTerminal>.fromOpaque(userdata).takeUnretainedValue()
            // Not known until the app has said; the question then goes
            // unanswered rather than answered wrong.
            guard let appearance = terminal.appearance else { return false }
            out.pointee = appearance.dark ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT
            return true
        }
        ghostty_terminal_set(handle, GHOSTTY_TERMINAL_OPT_COLOR_SCHEME, unsafeBitCast(colorScheme, to: UnsafeRawPointer.self))
    }

    private func sendColorSchemeReport(dark: Bool) {
        var buffer = [UInt8](repeating: 0, count: 32)
        var written = 0
        let result = buffer.withUnsafeMutableBufferPointer {
            ghostty_color_scheme_report_encode(
                dark ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT,
                $0.baseAddress, $0.count, &written)
        }
        guard result == GHOSTTY_SUCCESS, written > 0 else { return }
        buffer.withUnsafeBufferPointer { reply?($0.baseAddress!, written) }
    }

    // MARK: - Helpers

    private static func rgb(_ value: UInt32) -> GhosttyColorRgb {
        GhosttyColorRgb(r: UInt8((value >> 16) & 0xFF), g: UInt8((value >> 8) & 0xFF), b: UInt8(value & 0xFF))
    }

    /// The version libghostty-vt was built as, which is the app's Ghostty's.
    private static let libraryVersion: String = {
        var string = GhosttyString(ptr: nil, len: 0)
        guard ghostty_build_info(GHOSTTY_BUILD_INFO_VERSION_STRING, &string) == GHOSTTY_SUCCESS,
              let pointer = string.ptr, string.len > 0
        else { return "unknown" }
        return String(decoding: UnsafeBufferPointer(start: pointer, count: string.len), as: UTF8.self)
    }()
}
