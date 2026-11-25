#!/bin/bash

set -euo pipefail

SOURCE_DIR="${1:?Usage: $0 <ghostty-source-dir>}"

# =============================================================================
# Wortel: `font-family = system-mono` is the Mac's own monospaced font
# =============================================================================
#
# macOS ships SF Mono, but only as a system UI font: its family is hidden
# (".SF NS Mono") and CoreText will not hand it out by name. Measured on
# macOS 27.0.1 (2026-11-24):
#
#   - A family search for ".SF NS Mono" with a style ("Medium") ignores the
#     family and returns every Medium font on the system; Ghostty's ranking
#     does not look at the family, so it would pick one of those at random.
#     Without a style it returns nothing.
#   - CTFontCreateWithName(".SFNSMono-Medium") returns Times New Roman, and
#     CoreText logs that system UI fonts must be reached through their APIs.
#   - "SF Mono" by name is found only when Apple's separate SF Mono download
#     is installed in /Library/Fonts. Without it, Ghostty fell back to its
#     embedded JetBrains Mono, so most people never saw the font Wortel names.
#
# The supported way in is +[NSFont monospacedSystemFontOfSize:weight:], which
# every Mac answers with SF Mono (".AppleSystemUIFontMonospaced", a variable
# font). This patch makes the family name `system-mono` mean exactly that, on
# macOS, in CoreText discovery:
#
#   - weight from the descriptor's style name (`font-style = Medium` is
#     NSFontWeightMedium), else bold for the bold slot, else regular;
#   - italic from the italic slot, or "Italic"/"Oblique" in the style name;
#   - `font-variation*` still applied on top, as for any face.
#
# The font's own descriptor round-trips through Ghostty's iterator, size
# changes and variation changes (all of them copy the CTFont, none looks it up
# by name again), so the face stays the system font. When AppKit is not loaded
# the name is simply not found, and Ghostty goes on to the next font-family.
#
# Additive edits only, every one an exact anchor (Script/support/anchored_edit.py).
# =============================================================================

PYTHONPATH="$(cd "$(dirname "$0")/../../Script/support" && pwd)" python3 - "$SOURCE_DIR" <<'PY'
import sys

from anchored_edit import Source

source_dir = sys.argv[1]

discovery = Source(source_dir, "src/font/discovery.zig")

discovery.insert_after(
    'const macos = @import("macos");\n',
    'const objc = @import("objc");\n',
)

discovery.replace(
    """    pub fn discover(self: *const CoreText, alloc: Allocator, desc: Descriptor) !DiscoverIterator {
        _ = self;
""",
    """    pub fn discover(self: *const CoreText, alloc: Allocator, desc: Descriptor) !DiscoverIterator {
        _ = self;

        // Wortel: the Mac's own monospaced font, reached by API, not by name.
        if (desc.family) |family| {
            if (std.mem.eql(u8, family, system_mono_family)) {
                return try discoverSystemMono(alloc, desc);
            }
        }
""",
    marker="                return try discoverSystemMono(alloc, desc);\n",
)

discovery.insert_before(
    "    /// Discover a font by its exact name (family, full, or PostScript\n",
    """    /// Wortel: the family name that means the Mac's own monospaced font.
    pub const system_mono_family = "system-mono";

    /// Wortel: `system-mono` as +[NSFont monospacedSystemFontOfSize:weight:]
    /// returns it, styled for the descriptor. An empty iterator (not found)
    /// off macOS, without AppKit, or when the system has no such font.
    fn discoverSystemMono(alloc: Allocator, desc: Descriptor) !DiscoverIterator {
        var result: DiscoverIterator = .{
            .alloc = alloc,
            .list = &.{},
            .variations = desc.variations,
            .i = 0,
        };
        if (comptime builtin.os.tag != .macos) return result;
        const NSFont = objc.getClass("NSFont") orelse return result;

        const style: []const u8 = desc.style orelse "";
        const italic = desc.italic or
            std.ascii.findIgnoreCase(style, "italic") != null or
            std.ascii.findIgnoreCase(style, "oblique") != null;
        const size: f64 = if (desc.size > 0) desc.size else 12;

        const pool = objc.AutoreleasePool.init();
        defer pool.deinit();

        // Autoreleased: kept only long enough to copy what we need from it.
        const raw = NSFont.msgSend(
            ?*anyopaque,
            objc.sel("monospacedSystemFontOfSize:weight:"),
            .{ size, systemMonoWeight(style, desc.bold) },
        ) orelse return result;
        const base: *macos.text.Font = @ptrCast(raw);

        const styled: *macos.text.Font = if (!italic) base else italic: {
            const copy = macos.c.CTFontCreateCopyWithSymbolicTraits(
                @ptrCast(base),
                0,
                null,
                macos.c.kCTFontTraitItalic,
                macos.c.kCTFontTraitItalic,
            ) orelse return result;
            break :italic @ptrFromInt(@intFromPtr(copy));
        };
        defer if (styled != base) styled.release();

        const list = try alloc.alloc(*macos.text.FontDescriptor, 1);
        list[0] = styled.copyDescriptor();
        result.list = list;
        return result;
    }

    /// Wortel: an NSFontWeight for a style name such as "Medium" or
    /// "Semibold Italic". Longer names are checked before the names inside
    /// them ("semibold" before "bold", "ultralight" before "light").
    fn systemMonoWeight(style: []const u8, bold: bool) f64 {
        const weights = [_]struct { []const u8, f64 }{
            .{ "ultralight", -0.8 },
            .{ "thin", -0.6 },
            .{ "light", -0.4 },
            .{ "semibold", 0.3 },
            .{ "bold", 0.4 },
            .{ "medium", 0.23 },
            .{ "heavy", 0.56 },
            .{ "black", 0.62 },
        };
        for (weights) |w| {
            if (std.ascii.findIgnoreCase(style, w[0]) != null) return w[1];
        }
        return if (bold) 0.4 else 0;
    }

""",
    marker='    pub const system_mono_family = "system-mono";\n',
)

discovery.save()
PY
