#!/bin/bash

set -euo pipefail

SOURCE_DIR="${1:?Usage: $0 <ghostty-source-dir>}"

# =============================================================================
# Wortel: the keeper owns the terminal, the surface shows it
# =============================================================================
#
# Wortel's keeper process holds a headless libghostty-vt terminal for every
# session and is the one thing that reads the pty. The app's surface is a
# display of that terminal: it is seeded with an exact snapshot of it, then
# fed the same bytes the keeper parsed. Two additions make that possible.
#
# ghostty_surface_restore_snapshot replaces the surface's terminal with one
# decoded from a libghostty-vt snapshot (both screens, all scrollback, modes,
# palette overrides, charsets, kitty keyboard, hyperlinks, title, and any
# sequence the parser was in the middle of). What belongs to this surface and
# not to the program is kept from its config: default colours and palette,
# cursor defaults, image limits. The result is resized to the surface's grid
# and redrawn in full. The snapshot must come from a libghostty-vt built from
# the same Ghostty commit: the format is not stable across versions.
#
# Decoding happens outside the terminal lock; only the swap holds it. Call it
# before the surface is first fed or shown: a selection or search started on
# the old terminal is not carried over.
#
# ghostty_surface_set_responds(surface, false) stops the reports termio makes
# by itself from reaching the program: the colour scheme report (mode 2031,
# sent on a config change) and the in-band size report (mode 2048, sent on a
# resize). The keeper answers those. Parser-originated replies are kept quiet
# by feeding the surface with ghostty_surface_write_buffer_replay (0011).
# Focus and visibility reports are input from this surface and still go.
#
# Additive edits only, every one an exact anchor (Script/support/anchored_edit.py).
# =============================================================================

PYTHONPATH="$(cd "$(dirname "$0")/../../Script/support" && pwd)" python3 - "$SOURCE_DIR" <<'PY'
import sys

from anchored_edit import Source

source_dir = sys.argv[1]

# --- C header ----------------------------------------------------------------

header = Source(source_dir, "include/ghostty.h")
header.insert_after(
    "GHOSTTY_API void ghostty_surface_write_buffer_replay(ghostty_surface_t, const uint8_t*, uintptr_t);\n",
    """// Wortel: seed a host-managed surface from a libghostty-vt snapshot, and
// leave answering the program to whoever owns the pty.
GHOSTTY_API bool ghostty_surface_restore_snapshot(ghostty_surface_t, const uint8_t*, uintptr_t);
GHOSTTY_API void ghostty_surface_set_responds(ghostty_surface_t, bool);
""",
)
header.save()

# --- Stream handler: forget half-received sequences --------------------------

handler = Source(source_dir, "src/termio/stream_handler.zig")
handler.insert_before(
    """    /// Drop any in-flight write transaction without responding.
    fn kittyClipboardWriteAbort(self: *StreamHandler) void {
""",
    """    /// Wortel: forget every multi-part sequence this handler was collecting
    /// (APC, DCS, a kitty clipboard write). Used when the terminal behind it
    /// is replaced by a snapshot, whose own continuation says what the
    /// parser was in the middle of.
    pub fn resetPartialSequences(self: *StreamHandler) void {
        self.apc.deinit();
        self.apc = .{};
        self.dcs.deinit();
        self.dcs = .{};
        self.kittyClipboardWriteAbort();
    }

""",
)
handler.save()

# --- Termio: the responds switch and the restore -----------------------------

termio = Source(source_dir, "src/termio/Termio.zig")
termio.insert_after(
    "last_cursor_reset: ?std.Io.Timestamp = null,\n",
    """
/// Wortel: false when another process owns answering the program. Termio then
/// sends no report of its own making (colour scheme, in-band size). Changed
/// only under the terminal-state mutex.
responds: bool = true,
""",
)
termio.insert_after(
    "fn sizeReportLocked(self: *Termio, td: *ThreadData, style: termio.Message.SizeReport) !void {\n",
    "    if (!self.responds) return;\n",
)
termio.insert_after(
    "pub fn colorSchemeReportLocked(self: *Termio, td: *ThreadData, force: bool) !void {\n",
    "    if (!self.responds) return;\n",
)
termio.insert_before(
    """/// Resize the terminal.
pub fn resize(
""",
    """/// Wortel: the most bytes of an unfinished sequence a snapshot may carry.
/// The keeper tracks the same amount.
pub const snapshot_continuation_max_bytes: usize = 64 * 1024;

/// Wortel: decode a libghostty-vt snapshot. Allocates and may take a while
/// for a long scrollback, so it is done without the terminal lock; the
/// result is applied with `restoreSnapshotLocked`.
pub fn decodeSnapshot(
    self: *Termio,
    bytes: []const u8,
) !terminalpkg.snapshot.Decoded {
    var reader: std.Io.Reader = .fixed(bytes);
    return terminalpkg.snapshot.decodeExact(self.alloc, global.io(), &reader, .{
        .max_continuation_bytes = snapshot_continuation_max_bytes,
    });
}

/// Wortel: replace this terminal with a decoded snapshot. The caller holds
/// the terminal-state mutex, has released anything that points into the old
/// terminal's pages (a selection gesture), and still owns `decoded`, whose
/// continuation is replayed here.
///
/// What the program set comes from the snapshot. What this surface is
/// configured with (default colours and palette, cursor defaults, image
/// limits) is applied again over it, the way a config change would. The
/// terminal is then resized to this surface's grid and redrawn in full.
pub fn restoreSnapshotLocked(
    self: *Termio,
    decoded: *terminalpkg.snapshot.Decoded,
) !void {
    var next = decoded.toOwned();
    {
        errdefer next.deinit(self.alloc);
        try next.colors.palette.changeDefault(self.alloc, self.config.palette);
    }
    next.colors.background.default = self.config.background.toTerminalRGB();
    next.colors.foreground.default = self.config.foreground.toTerminalRGB();
    next.colors.cursor.default = cursor: {
        const color = self.config.cursor_color orelse break :cursor null;
        break :cursor color.toTerminalRGB() orelse break :cursor null;
    };
    next.setKittyGraphicsSizeLimit(self.alloc, self.config.image_storage_limit);
    next.setKittyGraphicsLoadingLimits(.allWithTempDir(global.tmpDirPath()));
    next.setDefaultCursorStyle(self.config.cursor_style);
    next.setDefaultCursorBlink(self.config.cursor_blink);
    next.setDefaultXtChecksum(self.config.xt_checksum_extension);

    // The swap. The stream handler and the render state point at
    // `self.terminal` itself, so the address they hold stays right.
    self.terminal.deinit(self.alloc);
    self.terminal = next;

    // A fresh parser at ground, then the snapshot's unfinished sequence, if
    // any, fed once. Its replies were the keeper's to give.
    const stream = &self.terminal_stream;
    stream.parser.deinit();
    stream.parser = .init();
    stream.parser.osc_parser.alloc = self.alloc;
    stream.utf8decoder = .{};
    stream.handler.resetPartialSequences();
    switch (decoded.continuation) {
        .ground => {},
        .bytes => |bytes| {
            const previous = stream.handler.suppress_terminal_responses;
            stream.handler.suppress_terminal_responses = true;
            defer stream.handler.suppress_terminal_responses = previous;
            stream.nextSlice(bytes);
        },
    }

    // The snapshot is at the keeper's size; this surface may be another.
    // A failure here leaves a whole terminal at the snapshot's size, which
    // the next resize corrects, so it is logged rather than returned.
    const grid_size = self.size.grid();
    self.terminal.resize(self.alloc, .{
        .cols = grid_size.columns,
        .rows = grid_size.rows,
        .cell_size_px = .{
            .width = self.size.cell.width,
            .height = self.size.cell.height,
        },
    }) catch |err| log.warn("resize after snapshot restore failed err={}", .{err});

    self.terminal.flags.dirty.clear = true;
    self.terminal.flags.dirty.palette = true;
    stream.handler.queueRender() catch {};
}

""",
)
termio.save()

# --- C API -------------------------------------------------------------------

src = Source(source_dir, "src/apprt/embedded.zig")
src.insert_after(
    """    export fn ghostty_surface_write_buffer_replay(
        surface: *Surface,
        ptr: [*]const u8,
        len: usize,
    ) void {
        if (len == 0) return;
        surface.core_surface.io.processOutputSuppressingResponses(ptr[0..len]);
    }
""",
    """
    /// Wortel: replace the surface's terminal with a libghostty-vt snapshot
    /// from the same Ghostty commit. False, with the terminal untouched, when
    /// the bytes do not decode. Call before the surface is fed or shown.
    export fn ghostty_surface_restore_snapshot(
        surface: *Surface,
        ptr: [*]const u8,
        len: usize,
    ) bool {
        if (len == 0) return false;
        const core = &surface.core_surface;
        const io = &core.io;

        var decoded = io.decodeSnapshot(ptr[0..len]) catch |err| {
            log.warn("snapshot decode failed err={}", .{err});
            return false;
        };
        defer decoded.deinit(io.alloc);

        core.renderer_state.mutex.lockUncancelable(global.io());
        defer core.renderer_state.mutex.unlock(global.io());
        core.mouse.selection_gesture.reset(&io.terminal);
        io.restoreSnapshotLocked(&decoded) catch |err| {
            log.warn("snapshot restore failed err={}", .{err});
            return false;
        };
        return true;
    }

    /// Wortel: false leaves answering the program to the pty's owner.
    export fn ghostty_surface_set_responds(surface: *Surface, responds: bool) void {
        const core = &surface.core_surface;
        core.renderer_state.mutex.lockUncancelable(global.io());
        defer core.renderer_state.mutex.unlock(global.io());
        core.io.responds = responds;
    }
""",
)
src.save()
PY
