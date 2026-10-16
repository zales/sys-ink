const std = @import("std");
const font_data = @import("font_data.zig");

pub const Color = enum {
    white,
    black,
};

pub const Bitmap = struct {
    width: u32,
    height: u32,
    stride: u32,
    data: []u8,
    allocator: std.mem.Allocator,

    pub const FontType = enum {
        ubuntu14,
        ubuntu20,
        ubuntu24,
        ubuntu26,
        ubuntu34,
        material14,
        material24,
        material50,
    };

    /// Advance used for codepoints the font has no glyph for.
    const missing_glyph_advance = 10;

    pub fn init(allocator: std.mem.Allocator, width: u32, height: u32) !Bitmap {
        const stride = width;
        const data = try allocator.alloc(u8, stride * height);
        @memset(data, 255); // Clear to white

        return Bitmap{
            .width = width,
            .height = height,
            .stride = stride,
            .data = data,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Bitmap) void {
        self.allocator.free(self.data);
    }

    pub fn clear(self: *Bitmap, color: Color) void {
        @memset(self.data, colorValue(color));
    }

    fn colorValue(color: Color) u8 {
        return if (color == .white) 255 else 0;
    }

    const ClipRect = struct { x: usize, y: usize, w: usize, h: usize };

    /// Intersect a rectangle with the bitmap. Returns null if nothing is visible,
    /// which lets the fill/invert loops skip per-pixel bounds checks entirely.
    fn clipRect(self: *const Bitmap, x: i32, y: i32, w: u32, h: u32) ?ClipRect {
        const x0 = @max(@as(i64, x), 0);
        const y0 = @max(@as(i64, y), 0);
        const x1 = @min(@as(i64, x) + @as(i64, w), @as(i64, self.width));
        const y1 = @min(@as(i64, y) + @as(i64, h), @as(i64, self.height));
        if (x1 <= x0 or y1 <= y0) return null;
        return .{
            .x = @intCast(x0),
            .y = @intCast(y0),
            .w = @intCast(x1 - x0),
            .h = @intCast(y1 - y0),
        };
    }

    pub fn setPixel(self: *Bitmap, x: i32, y: i32, color: Color) void {
        if (x < 0 or y < 0) return;
        const ux: u32 = @intCast(x);
        const uy: u32 = @intCast(y);
        if (ux >= self.width or uy >= self.height) return;

        self.data[uy * self.stride + ux] = colorValue(color);
    }

    pub fn drawLine(self: *Bitmap, x0: i32, y0: i32, x1: i32, y1: i32, color: Color) void {
        // Axis-aligned lines are the common case here (grid dividers, rect edges),
        // and both reduce to a contiguous fill.
        if (y0 == y1) {
            const left = @min(x0, x1);
            const len: u32 = @intCast(@abs(x1 - x0) + 1);
            self.fillRect(left, y0, len, 1, color);
            return;
        }
        if (x0 == x1) {
            const top = @min(y0, y1);
            const len: u32 = @intCast(@abs(y1 - y0) + 1);
            self.fillRect(x0, top, 1, len, color);
            return;
        }

        var x = x0;
        var y = y0;
        const dx = @as(i32, @intCast(@abs(x1 - x0)));
        const dy = -@as(i32, @intCast(@abs(y1 - y0)));
        const sx: i32 = if (x0 < x1) 1 else -1;
        const sy: i32 = if (y0 < y1) 1 else -1;
        var err = dx + dy;

        while (true) {
            self.setPixel(x, y, color);
            if (x == x1 and y == y1) break;
            const e2 = 2 * err;
            if (e2 >= dy) {
                err += dy;
                x += sx;
            }
            if (e2 <= dx) {
                err += dx;
                y += sy;
            }
        }
    }

    pub fn drawRect(self: *Bitmap, x: i32, y: i32, w: u32, h: u32, color: Color) void {
        if (w == 0 or h == 0) return;
        const x2 = x + @as(i32, @intCast(w)) - 1;
        const y2 = y + @as(i32, @intCast(h)) - 1;
        self.drawLine(x, y, x2, y, color);
        self.drawLine(x2, y, x2, y2, color);
        self.drawLine(x2, y2, x, y2, color);
        self.drawLine(x, y2, x, y, color);
    }

    pub fn fillRect(self: *Bitmap, x: i32, y: i32, w: u32, h: u32, color: Color) void {
        const r = self.clipRect(x, y, w, h) orelse return;
        const val = colorValue(color);

        var py = r.y;
        while (py < r.y + r.h) : (py += 1) {
            @memset(self.data[py * self.stride + r.x ..][0..r.w], val);
        }
    }

    pub fn invertRect(self: *Bitmap, x: i32, y: i32, w: u32, h: u32) void {
        const r = self.clipRect(x, y, w, h) orelse return;

        var py = r.y;
        while (py < r.y + r.h) : (py += 1) {
            for (self.data[py * self.stride + r.x ..][0..r.w]) |*px| {
                px.* = 255 - px.*;
            }
        }
    }

    /// Fade whatever is drawn in the rectangle by turning every other pixel
    /// white, in a checkerboard. On a 1-bit panel that is as close to grey as
    /// it gets, and it reads the way greyed-out text does anywhere else: still
    /// legible, visibly not live.
    ///
    /// The pattern hangs off the bitmap's own coordinates, not the
    /// rectangle's, so fading the same area again changes nothing.
    pub fn fadeRect(self: *Bitmap, x: i32, y: i32, w: u32, h: u32) void {
        const r = self.clipRect(x, y, w, h) orelse return;
        const white = colorValue(.white);

        var py = r.y;
        while (py < r.y + r.h) : (py += 1) {
            for (self.data[py * self.stride + r.x ..][0..r.w], r.x..) |*px, px_x| {
                if ((px_x + py) & 1 == 1) px.* = white;
            }
        }
    }

    /// Widest picture `drawDithered` takes: wider than the panel, and what
    /// sizes the rows of error it carries on the stack.
    pub const max_dither_width = 512;

    /// What `drawDithered` draws with.
    pub const Shades = enum {
        /// Black and white.
        two,
        /// Black, white and the two greys between, at 85 and 170: what the
        /// panel shows by a grey refresh. Anything else reads them as black
        /// and white; see `bayer2`.
        four,

        fn nearest(self: Shades, value: i16) u8 {
            return switch (self) {
                .two => if (value < 128) 0 else 255,
                .four => @intCast(std.math.clamp(@divFloor(value + 42, 85), 0, 3) * 85),
            };
        }
    };

    /// Draw the greyscale picture `gray`, `w` by `h` row by row, in `shades`
    /// with its top left corner at `x`, `y`, as far as it falls inside.
    ///
    /// Atkinson's dithering: each pixel's error goes in eighths to six
    /// neighbours ahead of it, and the last quarter is dropped. Dropping it
    /// keeps the lightest and darkest areas solid instead of speckled, which
    /// on a panel this small matters more than holding every mid-tone.
    pub fn drawDithered(self: *Bitmap, x: i32, y: i32, w: u32, h: u32, gray: []const u8, shades: Shades) void {
        std.debug.assert(w <= max_dither_width);
        std.debug.assert(gray.len == @as(usize, w) * h);

        // The error owed to this row and the next two, each shifted one
        // place right so the neighbour behind the first pixel has a slot.
        var rows: [3][max_dither_width + 3]i16 = @splat(@splat(0));
        for (0..h) |py| {
            const here = &rows[py % 3];
            const below = &rows[(py + 1) % 3];
            const further = &rows[(py + 2) % 3];
            for (0..w) |px| {
                const i = px + 1;
                const value = @as(i16, gray[py * w + px]) + here[i];
                const level = shades.nearest(value);
                const share = @divTrunc(value - level, 8);
                here[i + 1] += share;
                here[i + 2] += share;
                below[i - 1] += share;
                below[i] += share;
                below[i + 1] += share;
                further[i] += share;
                self.setLevel(x + @as(i32, @intCast(px)), y + @as(i32, @intCast(py)), level);
            }
            // Two rows on, this one comes round again as the furthest ahead.
            @memset(here, 0);
        }
    }

    fn setLevel(self: *Bitmap, x: i32, y: i32, level: u8) void {
        if (x < 0 or y < 0) return;
        const ux: u32 = @intCast(x);
        const uy: u32 = @intCast(y);
        if (ux >= self.width or uy >= self.height) return;
        self.data[uy * self.stride + ux] = level;
    }

    /// How far the top of `font_type`'s text is above its baseline. Known at
    /// compile time, which is what lets the layout be derived from it.
    pub fn fontAscent(font_type: FontType) i32 {
        return getFont(font_type).ascent;
    }

    fn getFont(font_type: FontType) *const font_data.Font {
        return switch (font_type) {
            .ubuntu14 => &font_data.ubuntu_14,
            .ubuntu20 => &font_data.ubuntu_20,
            .ubuntu24 => &font_data.ubuntu_24,
            .ubuntu26 => &font_data.ubuntu_26,
            .ubuntu34 => &font_data.ubuntu_34,
            .material14 => &font_data.material_14,
            .material24 => &font_data.material_24,
            .material50 => &font_data.material_50,
        };
    }

    pub fn drawTextFont(self: *Bitmap, x: i32, y: i32, text: []const u8, font_type: FontType, color: Color) void {
        const font = getFont(font_type);
        var cursor_x = x;

        var it = CodepointIterator{ .text = text };
        while (it.next()) |cp| {
            const glyph = font.get(cp) orelse {
                cursor_x += missing_glyph_advance;
                continue;
            };

            // Each glyph is rendered at its own top-left [0,0] in fontgen.c.
            // bearing_y is how far the glyph's top sits from the baseline
            // (negative = above), so adding it to the baseline aligns all
            // glyphs on a common baseline.
            const draw_x = cursor_x + glyph.bearing_x;
            const draw_y = y + glyph.bearing_y;

            // Pixels are one continuous MSB-first bitstream with no per-row
            // padding, so the glyph needs ceil(w*h/8) bytes. The generator emits
            // exactly that, with no slack: assert it in safe builds and bound the
            // read anyway, because release builds have no bounds checks and an
            // overrun here would be silent.
            const bits_needed = @as(usize, glyph.width) * @as(usize, glyph.height);
            std.debug.assert(glyph.data.len >= @divCeil(bits_needed, 8));
            const available_bits = glyph.data.len * 8;

            var bit: usize = 0;
            var gy: u16 = 0;
            rows: while (gy < glyph.height) : (gy += 1) {
                var gx: u16 = 0;
                while (gx < glyph.width) : (gx += 1) {
                    if (bit >= available_bits) break :rows;

                    const byte = glyph.data[bit >> 3];
                    const shift: u3 = @intCast(7 - (bit & 7));
                    if ((byte >> shift) & 1 == 1) {
                        self.setPixel(draw_x + gx, draw_y + gy, color);
                    }
                    bit += 1;
                }
            }

            cursor_x += glyph.advance_x;
        }
    }

    /// Pick the first candidate that renders within `max_width`.
    ///
    /// Falls back to the last candidate when none fit, so callers should order
    /// them most to least detailed. Text areas here butt up against the panel
    /// edge, where overflow is clipped mid-glyph rather than wrapped.
    pub fn fitText(self: *Bitmap, candidates: []const []const u8, font_type: FontType, max_width: u32) []const u8 {
        std.debug.assert(candidates.len > 0);

        for (candidates) |candidate| {
            if (self.measureText(candidate, font_type) <= max_width) return candidate;
        }
        return candidates[candidates.len - 1];
    }

    /// Width in pixels the given text would occupy in the given font.
    pub fn measureText(_: *Bitmap, text: []const u8, font_type: FontType) u32 {
        const font = getFont(font_type);
        var width: u32 = 0;

        var it = CodepointIterator{ .text = text };
        while (it.next()) |cp| {
            width += advance(font, cp);
        }
        return width;
    }

    /// Distance between the baselines of consecutive lines.
    pub fn getLineHeight(_: *Bitmap, font_type: FontType) u32 {
        return getFont(font_type).height;
    }

    fn advance(font: *const font_data.Font, cp: u32) u32 {
        return if (font.get(cp)) |glyph| glyph.advance_x else missing_glyph_advance;
    }

    /// Break `text` into lines no wider than `max_width`, at spaces where it can
    /// and mid-word only for a word that is wider than a line on its own.
    ///
    /// Fills `lines` with slices of `text` as far as it goes and returns how many
    /// lines the whole text needs, which may be more than `lines` holds: a
    /// caller fitting text to a box can tell from that alone that it overflows.
    pub fn wrapText(_: *Bitmap, text: []const u8, font_type: FontType, max_width: u32, lines: [][]const u8) usize {
        const font = getFont(font_type);
        var count: usize = 0;

        var rest = std.mem.trim(u8, text, " ");
        while (rest.len > 0) {
            const end = lineEnd(font, rest, max_width);
            if (count < lines.len) lines[count] = std.mem.trimEnd(u8, rest[0..end], " ");
            count += 1;
            rest = std.mem.trimStart(u8, rest[end..], " ");
        }
        return count;
    }

    /// Bytes of `text` that go on its first line. Never zero, so wrapping
    /// always makes progress even when a single glyph is wider than the line.
    fn lineEnd(font: *const font_data.Font, text: []const u8, max_width: u32) usize {
        var width: u32 = 0;
        var last_space: ?usize = null;

        var it = CodepointIterator{ .text = text };
        while (true) {
            const start = it.i;
            const cp = it.next() orelse return text.len;
            if (cp == ' ') last_space = start;

            width += advance(font, cp);
            if (width <= max_width) continue;

            if (cp == ' ') return start;
            if (last_space) |space| return space;
            return if (start == 0) it.i else start;
        }
    }
};

/// Scale the greyscale picture `src`, `src_w` by `src_h`, to fill `dst`,
/// `dst_w` by `dst_h`: each pixel the average of the ones it covers, or the
/// one it falls on where the picture is enlarged.
pub fn scaleGray(src: []const u8, src_w: u32, src_h: u32, dst: []u8, dst_w: u32, dst_h: u32) void {
    std.debug.assert(src.len == @as(usize, src_w) * src_h and src_w > 0 and src_h > 0);
    std.debug.assert(dst.len == @as(usize, dst_w) * dst_h);

    for (0..dst_h) |dy| {
        const y0 = dy * src_h / dst_h;
        const y1 = @max(y0 + 1, (dy + 1) * src_h / dst_h);
        for (0..dst_w) |dx| {
            const x0 = dx * src_w / dst_w;
            const x1 = @max(x0 + 1, (dx + 1) * src_w / dst_w);
            var sum: u32 = 0;
            for (y0..y1) |sy| {
                for (src[sy * src_w + x0 .. sy * src_w + x1]) |px| sum += px;
            }
            const count: u32 = @intCast((y1 - y0) * (x1 - x0));
            dst[dy * dst_w + dx] = @intCast((sum + count / 2) / count);
        }
    }
}

/// Whether the pixel at `x`, `y` of level `level` is white in black and white.
///
/// Black and white stay as they are; the greys `Shades.four` draws come out
/// as a 2x2 pattern, a quarter or three quarters black, which is as near as
/// one bit gets to them. Everything that packs a bitmap to one bit goes by
/// this, so a grey picture reads right in the preview and on the panel alike.
pub fn bayer2(level: u8, x: usize, y: usize) bool {
    const thresholds = [2][2]u8{ .{ 32, 159 }, .{ 223, 96 } };
    return level >= thresholds[y & 1][x & 1];
}

/// Stretch the levels of `pixels` so the darkest hundredth of them comes out
/// black and the lightest hundredth white.
///
/// A cover is made to be seen in colour, and many lose everything to grey
/// once only their brightness is left; dithered, a picture with no black or
/// white in it is noise. One with little difference in it at all, a plain
/// cover, is left as it is rather than stretched into a pattern.
pub fn stretchContrast(pixels: []u8) void {
    if (pixels.len == 0) return;
    var histogram: [256]u32 = @splat(0);
    for (pixels) |px| histogram[px] += 1;

    const cut = pixels.len / 100;
    const low = levelAt(&histogram, cut);
    const high = levelAt(&histogram, pixels.len - 1 - cut);
    if (high - low < 16) return;

    for (pixels) |*px| {
        const clamped = std.math.clamp(px.*, low, high);
        px.* = @intCast((@as(u32, clamped - low) * 255 + (high - low) / 2) / (high - low));
    }
}

/// The level of the pixel at `rank` when they are put in order.
fn levelAt(histogram: *const [256]u32, rank: usize) u8 {
    var seen: usize = 0;
    for (histogram, 0..) |n, level| {
        seen += n;
        if (seen > rank) return @intCast(level);
    }
    return 255;
}

/// Decodes UTF-8, substituting '?' for malformed sequences.
///
/// An invalid lead byte is one '?', not the Latin-1 character with its value:
/// decoding it as a one-byte sequence turned a stray 0xFF into 'ÿ'. A sequence
/// cut short by the end of the text is a '?' too, rather than silently lost.
pub const CodepointIterator = struct {
    text: []const u8,
    i: usize = 0,

    pub fn next(self: *CodepointIterator) ?u32 {
        if (self.i >= self.text.len) return null;

        const len = std.unicode.utf8ByteSequenceLength(self.text[self.i]) catch {
            self.i += 1;
            return '?';
        };
        if (self.i + len > self.text.len) {
            self.i = self.text.len;
            return '?';
        }

        const cp = std.unicode.utf8Decode(self.text[self.i..][0..len]) catch '?';
        self.i += len;
        return cp;
    }
};

// ----------------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------------

const testing = std.testing;

fn testBitmap(width: u32, height: u32) !Bitmap {
    return Bitmap.init(testing.allocator, width, height);
}

fn countBlack(bmp: *const Bitmap) u32 {
    var n: u32 = 0;
    for (bmp.data) |px| {
        if (px == 0) n += 1;
    }
    return n;
}

test "wrapText breaks at spaces and keeps every line within the width" {
    var bmp = try testBitmap(1, 1);
    defer bmp.deinit();

    const text = "the quick brown fox jumps over the lazy dog";
    const max_width = bmp.measureText("the quick brown", .ubuntu14);

    var lines: [8][]const u8 = undefined;
    const n = bmp.wrapText(text, .ubuntu14, max_width, &lines);

    try testing.expectEqualStrings("the quick brown", lines[0]);
    for (lines[0..n]) |line| {
        try testing.expect(bmp.measureText(line, .ubuntu14) <= max_width);
        try testing.expect(line[0] != ' ' and line[line.len - 1] != ' ');
    }
    // Nothing lost: the lines joined by spaces are the text again.
    const joined = try std.mem.join(testing.allocator, " ", lines[0..n]);
    defer testing.allocator.free(joined);
    try testing.expectEqualStrings(text, joined);
}

test "wrapText splits a word too wide for any line" {
    var bmp = try testBitmap(1, 1);
    defer bmp.deinit();

    var lines: [8][]const u8 = undefined;
    const max_width = bmp.measureText("abcd", .ubuntu14);
    const n = bmp.wrapText("abcdefghij", .ubuntu14, max_width, &lines);

    try testing.expectEqual(@as(usize, 3), n);
    try testing.expectEqualStrings("abcd", lines[0]);
    try testing.expectEqualStrings("efgh", lines[1]);
    try testing.expectEqualStrings("ij", lines[2]);
}

test "wrapText counts the lines it had no room to return" {
    var bmp = try testBitmap(1, 1);
    defer bmp.deinit();

    var lines: [2][]const u8 = undefined;
    const max_width = bmp.measureText("aa", .ubuntu14);
    try testing.expectEqual(@as(usize, 4), bmp.wrapText("aa aa aa aa", .ubuntu14, max_width, &lines));
    try testing.expectEqualStrings("aa", lines[1]);
}

test "wrapText makes progress even when one glyph is wider than the line" {
    var bmp = try testBitmap(1, 1);
    defer bmp.deinit();

    var lines: [4][]const u8 = undefined;
    try testing.expectEqual(@as(usize, 2), bmp.wrapText("WW", .ubuntu34, 1, &lines));
    try testing.expectEqual(@as(usize, 0), bmp.wrapText("   ", .ubuntu14, 100, &lines));
}

test "malformed UTF-8 decodes to question marks, never to other letters" {
    var it = CodepointIterator{ .text = "a\xffb\xc4" };
    try testing.expectEqual(@as(?u32, 'a'), it.next());
    try testing.expectEqual(@as(?u32, '?'), it.next());
    try testing.expectEqual(@as(?u32, 'b'), it.next());
    try testing.expectEqual(@as(?u32, '?'), it.next());
    try testing.expectEqual(@as(?u32, null), it.next());
}

test "fillRect fills exactly the requested area" {
    var bmp = try testBitmap(10, 10);
    defer bmp.deinit();

    bmp.fillRect(2, 3, 4, 2, .black);
    try testing.expectEqual(@as(u32, 8), countBlack(&bmp));
    try testing.expectEqual(@as(u8, 0), bmp.data[3 * 10 + 2]);
    try testing.expectEqual(@as(u8, 0), bmp.data[4 * 10 + 5]);
    // Just outside the rect on every side.
    try testing.expectEqual(@as(u8, 255), bmp.data[2 * 10 + 2]);
    try testing.expectEqual(@as(u8, 255), bmp.data[3 * 10 + 1]);
    try testing.expectEqual(@as(u8, 255), bmp.data[3 * 10 + 6]);
    try testing.expectEqual(@as(u8, 255), bmp.data[5 * 10 + 2]);
}

test "fillRect clips against every edge" {
    var bmp = try testBitmap(10, 10);
    defer bmp.deinit();

    // Straddles the top-left corner: only the 2x2 overlap should land.
    bmp.fillRect(-3, -3, 5, 5, .black);
    try testing.expectEqual(@as(u32, 4), countBlack(&bmp));

    bmp.clear(.white);
    // Straddles the bottom-right corner.
    bmp.fillRect(8, 8, 5, 5, .black);
    try testing.expectEqual(@as(u32, 4), countBlack(&bmp));
}

test "fillRect ignores fully off-screen and empty rectangles" {
    var bmp = try testBitmap(10, 10);
    defer bmp.deinit();

    bmp.fillRect(-100, 0, 5, 5, .black);
    bmp.fillRect(100, 0, 5, 5, .black);
    bmp.fillRect(0, -100, 5, 5, .black);
    bmp.fillRect(0, 100, 5, 5, .black);
    bmp.fillRect(2, 2, 0, 5, .black);
    bmp.fillRect(2, 2, 5, 0, .black);

    try testing.expectEqual(@as(u32, 0), countBlack(&bmp));
}

test "invertRect flips only the clipped region" {
    var bmp = try testBitmap(10, 10);
    defer bmp.deinit();

    bmp.invertRect(-2, -2, 4, 4);
    try testing.expectEqual(@as(u32, 4), countBlack(&bmp));

    // Inverting twice restores the original.
    bmp.invertRect(-2, -2, 4, 4);
    try testing.expectEqual(@as(u32, 0), countBlack(&bmp));
}

test "fadeRect knocks out every other pixel and nothing outside the area" {
    var bmp = try testBitmap(6, 4);
    defer bmp.deinit();
    bmp.clear(.black);

    bmp.fadeRect(1, 1, 4, 2);

    for (0..4) |y| {
        for (0..6) |x| {
            const inside = x >= 1 and x < 5 and y >= 1 and y < 3;
            const faded = inside and (x + y) % 2 == 1;
            try testing.expectEqual(@as(u8, if (faded) 255 else 0), bmp.data[y * bmp.stride + x]);
        }
    }

    // Half of the area exactly, and a second pass finds nothing left to do.
    const once = try testing.allocator.dupe(u8, bmp.data);
    defer testing.allocator.free(once);
    bmp.fadeRect(1, 1, 4, 2);
    try testing.expectEqualSlices(u8, once, bmp.data);

    // Clipped like the other rectangle operations.
    bmp.fadeRect(-3, -3, 100, 100);
    bmp.fadeRect(50, 50, 4, 4);
}

test "drawLine handles horizontal, vertical and diagonal runs" {
    var bmp = try testBitmap(10, 10);
    defer bmp.deinit();

    bmp.drawLine(0, 0, 9, 0, .black);
    try testing.expectEqual(@as(u32, 10), countBlack(&bmp));

    bmp.clear(.white);
    bmp.drawLine(0, 0, 0, 9, .black);
    try testing.expectEqual(@as(u32, 10), countBlack(&bmp));

    bmp.clear(.white);
    bmp.drawLine(0, 0, 9, 9, .black);
    try testing.expectEqual(@as(u32, 10), countBlack(&bmp));
}

test "drawLine is direction-independent" {
    var forward = try testBitmap(10, 10);
    defer forward.deinit();
    var backward = try testBitmap(10, 10);
    defer backward.deinit();

    forward.drawLine(1, 4, 8, 4, .black);
    backward.drawLine(8, 4, 1, 4, .black);
    try testing.expectEqualSlices(u8, forward.data, backward.data);
}

test "drawLine clips off-screen endpoints" {
    var bmp = try testBitmap(10, 10);
    defer bmp.deinit();

    bmp.drawLine(-5, 5, 15, 5, .black);
    try testing.expectEqual(@as(u32, 10), countBlack(&bmp));
}

test "setPixel rejects out-of-bounds coordinates" {
    var bmp = try testBitmap(4, 4);
    defer bmp.deinit();

    bmp.setPixel(-1, 0, .black);
    bmp.setPixel(0, -1, .black);
    bmp.setPixel(4, 0, .black);
    bmp.setPixel(0, 4, .black);

    try testing.expectEqual(@as(u32, 0), countBlack(&bmp));
}

test "font lookup finds every glyph in the table" {
    for (font_data.ubuntu_14.glyphs) |glyph| {
        const found = font_data.ubuntu_14.get(glyph.codepoint) orelse return error.MissingGlyph;
        try testing.expectEqual(glyph.codepoint, found.codepoint);
    }
    for (font_data.material_50.glyphs) |glyph| {
        try testing.expect(font_data.material_50.get(glyph.codepoint) != null);
    }
}

test "font glyph tables are sorted for binary search" {
    const fonts = [_]*const font_data.Font{
        &font_data.ubuntu_14,   &font_data.ubuntu_20,   &font_data.ubuntu_24,
        &font_data.ubuntu_26,   &font_data.ubuntu_34,   &font_data.material_14,
        &font_data.material_24, &font_data.material_50,
    };
    for (fonts) |font| {
        try testing.expect(font.glyphs.len > 0);
        for (font.glyphs[1..], font.glyphs[0 .. font.glyphs.len - 1]) |next_glyph, prev| {
            try testing.expect(prev.codepoint < next_glyph.codepoint);
        }
    }
}

test "every glyph carries enough data for its own dimensions" {
    // drawTextFont walks width*height bits of glyph.data. Release builds do not
    // bounds check, so a generator that disagreed with its own metadata by a
    // single byte would read past the array and draw whatever followed it.
    // The generator leaves no slack, which makes this worth pinning down.
    const fonts = [_]*const font_data.Font{
        &font_data.ubuntu_14,   &font_data.ubuntu_20,   &font_data.ubuntu_24,
        &font_data.ubuntu_26,   &font_data.ubuntu_34,   &font_data.material_14,
        &font_data.material_24, &font_data.material_50,
    };

    var glyphs_checked: u32 = 0;
    for (fonts) |font| {
        for (font.glyphs) |glyph| {
            const bits = @as(usize, glyph.width) * @as(usize, glyph.height);
            try testing.expect(glyph.data.len >= @divCeil(bits, 8));
            glyphs_checked += 1;
        }
    }
    try testing.expectEqual(@as(u32, 1475), glyphs_checked);
}

test "every size of text has the same characters, the Latin letters with diacritics among them" {
    // notice.zig folds text to what ubuntu_14 has and trusts the rest to have it too.
    const sizes = [_]*const font_data.Font{ &font_data.ubuntu_20, &font_data.ubuntu_24, &font_data.ubuntu_26, &font_data.ubuntu_34 };
    for (sizes) |font| {
        try testing.expectEqual(font_data.ubuntu_14.glyphs.len, font.glyphs.len);
        for (font_data.ubuntu_14.glyphs, font.glyphs) |a, b| try testing.expectEqual(a.codepoint, b.codepoint);
    }
    for ([_]u32{ 'č', 'Ř', 'ů', 'Ž', 'ß', 'Ł', 'ő', 'Œ' }) |cp| {
        try testing.expect(font_data.ubuntu_14.get(cp) != null);
    }
}

test "font lookup misses return null" {
    try testing.expect(font_data.ubuntu_14.get(0) == null);
    try testing.expect(font_data.ubuntu_14.get(0x1F600) == null);
    // Beyond ASCII: the degree sign, and the Latin letters with diacritics.
    try testing.expect(font_data.ubuntu_14.get(0xB0) != null);
    try testing.expect(font_data.ubuntu_14.get(0x3A9) == null); // Ω
}

test "measureText sums advances and handles missing glyphs" {
    var bmp = try testBitmap(4, 4);
    defer bmp.deinit();

    try testing.expectEqual(@as(u32, 0), bmp.measureText("", .ubuntu14));

    const digit = font_data.ubuntu_14.get('0').?;
    try testing.expectEqual(digit.advance_x * 3, bmp.measureText("000", .ubuntu14));

    // An emoji has no glyph, so it falls back to the fixed advance.
    try testing.expectEqual(
        @as(u32, Bitmap.missing_glyph_advance),
        bmp.measureText("\u{1F600}", .ubuntu14),
    );
}

test "fitText picks the first candidate that fits" {
    var bmp = try testBitmap(4, 4);
    defer bmp.deinit();

    const wide = "11d 12h 20m";
    const medium = "11d 12h";
    const narrow = "11d";
    const candidates = [_][]const u8{ wide, medium, narrow };

    // Roomy: keep the most detailed form.
    try testing.expectEqualStrings(wide, bmp.fitText(&candidates, .ubuntu14, 200));
    // The real status-bar slot is 76px, where the full form overflows at 83px.
    try testing.expectEqualStrings(medium, bmp.fitText(&candidates, .ubuntu14, 76));
    // Tighter still.
    try testing.expectEqualStrings(narrow, bmp.fitText(&candidates, .ubuntu14, 30));
    // Nothing fits: fall back to the last, most compact candidate.
    try testing.expectEqualStrings(narrow, bmp.fitText(&candidates, .ubuntu14, 1));
}

test "drawTextFont stays inside the bitmap when drawn off-screen" {
    var bmp = try testBitmap(20, 20);
    defer bmp.deinit();

    // Far outside in both directions; must not touch memory or trap.
    bmp.drawTextFont(-500, -500, "123", .ubuntu26, .black);
    bmp.drawTextFont(500, 500, "123", .ubuntu26, .black);
    try testing.expectEqual(@as(u32, 0), countBlack(&bmp));
}

test "drawTextFont marks pixels and advances the cursor" {
    var one = try testBitmap(60, 40);
    defer one.deinit();
    var two = try testBitmap(60, 40);
    defer two.deinit();

    one.drawTextFont(2, 30, "8", .ubuntu14, .black);
    two.drawTextFont(2, 30, "88", .ubuntu14, .black);

    try testing.expect(countBlack(&one) > 0);
    // The second glyph must add ink rather than overprint the first.
    try testing.expectEqual(countBlack(&one) * 2, countBlack(&two));
}

test "malformed UTF-8 does not hang the decoder" {
    var bmp = try testBitmap(40, 40);
    defer bmp.deinit();

    // Truncated multi-byte sequence and a stray continuation byte.
    bmp.drawTextFont(0, 20, "\xC3", .ubuntu14, .black);
    bmp.drawTextFont(0, 20, "\x80\x80", .ubuntu14, .black);
    _ = bmp.measureText("\xF0\x9F", .ubuntu14);
}

test "scaleGray averages what each pixel covers when shrinking" {
    const src = [_]u8{
        0,   100, 200, 200,
        100, 0,   200, 200,
    };
    var dst: [2]u8 = undefined;
    scaleGray(&src, 4, 2, &dst, 2, 1);
    try testing.expectEqualSlices(u8, &.{ 50, 200 }, &dst);
}

test "scaleGray repeats pixels when enlarging" {
    const src = [_]u8{ 10, 250 };
    var dst: [4]u8 = undefined;
    scaleGray(&src, 2, 1, &dst, 4, 1);
    try testing.expectEqualSlices(u8, &.{ 10, 10, 250, 250 }, &dst);
}

test "stretchContrast spreads a washed-out picture over every level" {
    var pixels: [200]u8 = undefined;
    for (&pixels, 0..) |*px, i| px.* = @intCast(100 + i % 50);
    stretchContrast(&pixels);
    try testing.expectEqual(@as(u8, 0), std.mem.min(u8, &pixels));
    try testing.expectEqual(@as(u8, 255), std.mem.max(u8, &pixels));
}

test "stretchContrast leaves a nearly plain picture alone" {
    var pixels: [100]u8 = undefined;
    for (&pixels, 0..) |*px, i| px.* = @intCast(120 + i % 8);
    const before = pixels;
    stretchContrast(&pixels);
    try testing.expectEqualSlices(u8, &before, &pixels);
}

test "drawDithered keeps white white and black black, and turns mid-grey about half black" {
    var bmp = try testBitmap(48, 16);
    defer bmp.deinit();

    var gray: [48 * 16]u8 = undefined;
    for (0..16) |y| for (0..48) |x| {
        gray[y * 48 + x] = if (x < 16) 255 else if (x < 32) 0 else 128;
    };
    bmp.drawDithered(0, 0, 48, 16, &gray, .two);

    var black = [_]u32{ 0, 0, 0 };
    for (0..16) |y| for (0..48) |x| {
        if (bmp.data[y * bmp.stride + x] == 0) black[x / 16] += 1;
        try testing.expect(bmp.data[y * bmp.stride + x] == 0 or bmp.data[y * bmp.stride + x] == 255);
    };
    try testing.expectEqual(@as(u32, 0), black[0]);
    try testing.expectEqual(@as(u32, 256), black[1]);
    // Atkinson drops a quarter of the error, so mid-grey comes out a little
    // lighter than half; within a fifth of it either way.
    try testing.expect(black[2] > 128 - 51 and black[2] < 128 + 51);
}

test "drawDithered clips at the edges rather than writing past them" {
    var bmp = try testBitmap(8, 8);
    defer bmp.deinit();
    const gray: [16 * 16]u8 = @splat(0);
    bmp.drawDithered(-4, 4, 16, 16, &gray, .two);
    try testing.expectEqual(@as(u32, 8 * 4), countBlack(&bmp));
}

test "in four shades only the four levels come out, and a grey between two is a mix of them" {
    var bmp = try testBitmap(32, 32);
    defer bmp.deinit();

    var gray: [32 * 32]u8 = @splat(85);
    bmp.drawDithered(0, 0, 32, 32, &gray, .four);
    for (bmp.data) |px| try testing.expectEqual(@as(u8, 85), px);

    gray = @splat(128);
    bmp.drawDithered(0, 0, 32, 32, &gray, .four);
    var counts = [_]u32{ 0, 0, 0, 0 };
    for (bmp.data) |px| {
        try testing.expect(px % 85 == 0);
        counts[px / 85] += 1;
    }
    try testing.expectEqual(@as(u32, 0), counts[0] + counts[3]);
    try testing.expect(counts[1] > 0 and counts[2] > 0);
}

test "in one bit, black and white stay put and the greys become a quarter and three quarters black" {
    for (0..4) |i| {
        try testing.expect(!bayer2(0, i % 2, i / 2));
        try testing.expect(bayer2(255, i % 2, i / 2));
    }
    var dark: u32 = 0;
    var light: u32 = 0;
    for (0..4) |i| {
        dark += @intFromBool(!bayer2(85, i % 2, i / 2));
        light += @intFromBool(!bayer2(170, i % 2, i / 2));
    }
    try testing.expectEqual(@as(u32, 3), dark);
    try testing.expectEqual(@as(u32, 1), light);
}
