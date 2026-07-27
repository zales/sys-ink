const std = @import("std");
const font_data = @import("font_data.zig");

pub const Color = enum {
    White,
    Black,
};

pub const Bitmap = struct {
    width: u32,
    height: u32,
    stride: u32,
    data: []u8,
    allocator: std.mem.Allocator,

    pub const FontType = enum {
        Ubuntu14,
        Ubuntu20,
        Ubuntu24,
        Ubuntu26,
        Ubuntu34,
        Material14,
        Material24,
        Material50,
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
        return if (color == .White) 255 else 0;
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

    pub fn getFontAscent(_: *Bitmap, font_type: FontType) i32 {
        return @intCast(getFont(font_type).ascent);
    }

    fn getFont(font_type: FontType) *const font_data.Font {
        return switch (font_type) {
            .Ubuntu14 => &font_data.ubuntu_14,
            .Ubuntu20 => &font_data.ubuntu_20,
            .Ubuntu24 => &font_data.ubuntu_24,
            .Ubuntu26 => &font_data.ubuntu_26,
            .Ubuntu34 => &font_data.ubuntu_34,
            .Material14 => &font_data.material_14,
            .Material24 => &font_data.material_24,
            .Material50 => &font_data.material_50,
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
            std.debug.assert(glyph.data.len >= (bits_needed + 7) / 8);
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
            width += if (font.get(cp)) |glyph| glyph.advance_x else missing_glyph_advance;
        }
        return width;
    }
};

/// Decodes UTF-8, substituting '?' for malformed sequences.
const CodepointIterator = struct {
    text: []const u8,
    i: usize = 0,

    fn next(self: *CodepointIterator) ?u32 {
        if (self.i >= self.text.len) return null;

        const len = std.unicode.utf8ByteSequenceLength(self.text[self.i]) catch 1;
        if (self.i + len > self.text.len) {
            self.i = self.text.len;
            return null;
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
const dc = @import("display_config.zig");

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

test "fillRect fills exactly the requested area" {
    var bmp = try testBitmap(10, 10);
    defer bmp.deinit();

    bmp.fillRect(2, 3, 4, 2, .Black);
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
    bmp.fillRect(-3, -3, 5, 5, .Black);
    try testing.expectEqual(@as(u32, 4), countBlack(&bmp));

    bmp.clear(.White);
    // Straddles the bottom-right corner.
    bmp.fillRect(8, 8, 5, 5, .Black);
    try testing.expectEqual(@as(u32, 4), countBlack(&bmp));
}

test "fillRect ignores fully off-screen and empty rectangles" {
    var bmp = try testBitmap(10, 10);
    defer bmp.deinit();

    bmp.fillRect(-100, 0, 5, 5, .Black);
    bmp.fillRect(100, 0, 5, 5, .Black);
    bmp.fillRect(0, -100, 5, 5, .Black);
    bmp.fillRect(0, 100, 5, 5, .Black);
    bmp.fillRect(2, 2, 0, 5, .Black);
    bmp.fillRect(2, 2, 5, 0, .Black);

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

test "drawLine handles horizontal, vertical and diagonal runs" {
    var bmp = try testBitmap(10, 10);
    defer bmp.deinit();

    bmp.drawLine(0, 0, 9, 0, .Black);
    try testing.expectEqual(@as(u32, 10), countBlack(&bmp));

    bmp.clear(.White);
    bmp.drawLine(0, 0, 0, 9, .Black);
    try testing.expectEqual(@as(u32, 10), countBlack(&bmp));

    bmp.clear(.White);
    bmp.drawLine(0, 0, 9, 9, .Black);
    try testing.expectEqual(@as(u32, 10), countBlack(&bmp));
}

test "drawLine is direction-independent" {
    var forward = try testBitmap(10, 10);
    defer forward.deinit();
    var backward = try testBitmap(10, 10);
    defer backward.deinit();

    forward.drawLine(1, 4, 8, 4, .Black);
    backward.drawLine(8, 4, 1, 4, .Black);
    try testing.expectEqualSlices(u8, forward.data, backward.data);
}

test "drawLine clips off-screen endpoints" {
    var bmp = try testBitmap(10, 10);
    defer bmp.deinit();

    bmp.drawLine(-5, 5, 15, 5, .Black);
    try testing.expectEqual(@as(u32, 10), countBlack(&bmp));
}

test "setPixel rejects out-of-bounds coordinates" {
    var bmp = try testBitmap(4, 4);
    defer bmp.deinit();

    bmp.setPixel(-1, 0, .Black);
    bmp.setPixel(0, -1, .Black);
    bmp.setPixel(4, 0, .Black);
    bmp.setPixel(0, 4, .Black);

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
            try testing.expect(glyph.data.len >= (bits + 7) / 8);
            glyphs_checked += 1;
        }
    }
    try testing.expectEqual(@as(u32, 525), glyphs_checked);
}

test "font lookup misses return null" {
    try testing.expect(font_data.ubuntu_14.get(0) == null);
    try testing.expect(font_data.ubuntu_14.get(0x1F600) == null);
    // Degree sign is the one non-ASCII codepoint the Ubuntu faces carry.
    try testing.expect(font_data.ubuntu_14.get(0xB0) != null);
}

test "measureText sums advances and handles missing glyphs" {
    var bmp = try testBitmap(4, 4);
    defer bmp.deinit();

    try testing.expectEqual(@as(u32, 0), bmp.measureText("", .Ubuntu14));

    const digit = font_data.ubuntu_14.get('0').?;
    try testing.expectEqual(digit.advance_x * 3, bmp.measureText("000", .Ubuntu14));

    // An emoji has no glyph, so it falls back to the fixed advance.
    try testing.expectEqual(
        @as(u32, Bitmap.missing_glyph_advance),
        bmp.measureText("\u{1F600}", .Ubuntu14),
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
    try testing.expectEqualStrings(wide, bmp.fitText(&candidates, .Ubuntu14, 200));
    // The real status-bar slot is 76px, where the full form overflows at 83px.
    try testing.expectEqualStrings(medium, bmp.fitText(&candidates, .Ubuntu14, 76));
    // Tighter still.
    try testing.expectEqualStrings(narrow, bmp.fitText(&candidates, .Ubuntu14, 30));
    // Nothing fits: fall back to the last, most compact candidate.
    try testing.expectEqualStrings(narrow, bmp.fitText(&candidates, .Ubuntu14, 1));
}

test "uptime keeps its minutes across realistic values" {
    var bmp = try testBitmap(4, 4);
    defer bmp.deinit();

    const slot = dc.TEXT_AREA_UPTIME.width;

    for ([_][3]u32{
        .{ 0, 0, 0 },
        .{ 0, 5, 3 },
        .{ 9, 23, 59 },
        .{ 11, 12, 20 }, // was clipped to "11d 12h 20r" on the panel
        .{ 99, 23, 59 },
        .{ 123, 23, 59 },
        .{ 999, 23, 59 },
    }) |v| {
        var buf = dc.UptimeBuffers{};
        const candidates = dc.uptimeCandidates(&buf, v[0], v[1], v[2]);
        const chosen = bmp.fitText(&candidates, .Ubuntu14, slot);

        try testing.expect(bmp.measureText(chosen, .Ubuntu14) <= slot);
        // Whichever form is chosen, it must still carry minutes.
        try testing.expect(chosen.ptr == candidates[0].ptr or chosen.ptr == candidates[1].ptr);
    }
}

test "uptime spells out minutes up to 99 days" {
    var bmp = try testBitmap(4, 4);
    defer bmp.deinit();

    var buf = dc.UptimeBuffers{};
    const c = dc.uptimeCandidates(&buf, 11, 12, 20);
    try testing.expectEqualStrings("11d 12h 20m", c[0]);
    try testing.expectEqualStrings("11d 12h 20m", bmp.fitText(&c, .Ubuntu14, dc.TEXT_AREA_UPTIME.width));
}

test "uptime falls back to the compact form past 99 days" {
    var bmp = try testBitmap(4, 4);
    defer bmp.deinit();

    var buf = dc.UptimeBuffers{};
    const c = dc.uptimeCandidates(&buf, 123, 23, 59);
    try testing.expectEqualStrings("123d 23:59", bmp.fitText(&c, .Ubuntu14, dc.TEXT_AREA_UPTIME.width));
}

test "uptime formats zero days and pads minutes" {
    var buf = dc.UptimeBuffers{};
    try testing.expectEqualStrings("5h 3m", dc.uptimeCandidates(&buf, 0, 5, 3)[0]);
    // Zero-padded so the colon form never reads as "9:5".
    try testing.expectEqualStrings("3d 9:05", dc.uptimeCandidates(&buf, 3, 9, 5)[1]);
}

test "uptime degrades instead of clipping at absurd values" {
    var bmp = try testBitmap(4, 4);
    defer bmp.deinit();

    var buf = dc.UptimeBuffers{};

    // ~27 years still keeps its minutes via the compact form.
    const long = dc.uptimeCandidates(&buf, 9999, 23, 59);
    try testing.expectEqualStrings("9999d 23:59", bmp.fitText(&long, .Ubuntu14, dc.TEXT_AREA_UPTIME.width));

    // Past that the ladder drops units rather than clipping.
    const absurd = dc.uptimeCandidates(&buf, 999_999, 23, 59);
    const chosen = bmp.fitText(&absurd, .Ubuntu14, dc.TEXT_AREA_UPTIME.width);
    try testing.expect(bmp.measureText(chosen, .Ubuntu14) <= dc.TEXT_AREA_UPTIME.width);
}

test "signal reading fits its slot across the whole dBm range" {
    var bmp = try testBitmap(4, 4);
    defer bmp.deinit();

    var s: i32 = -20;
    while (s >= -120) : (s -= 1) {
        var with_unit: [16]u8 = undefined;
        var bare: [16]u8 = undefined;
        const candidates = [_][]const u8{
            try std.fmt.bufPrint(&with_unit, "{d} dBm", .{s}),
            try std.fmt.bufPrint(&bare, "{d}", .{s}),
        };
        const chosen = bmp.fitText(&candidates, .Ubuntu14, dc.SIGNAL_VALUE_MAX_W);
        try testing.expect(bmp.measureText(chosen, .Ubuntu14) <= dc.SIGNAL_VALUE_MAX_W);
    }

    // Two-digit readings keep the unit; only the three-digit extreme drops it.
    var b1: [16]u8 = undefined;
    var b2: [16]u8 = undefined;
    const normal = [_][]const u8{ try std.fmt.bufPrint(&b1, "{d} dBm", .{@as(i32, -40)}), try std.fmt.bufPrint(&b2, "{d}", .{@as(i32, -40)}) };
    try testing.expectEqualStrings("-40 dBm", bmp.fitText(&normal, .Ubuntu14, dc.SIGNAL_VALUE_MAX_W));
}

test "no declared text area extends past the panel" {
    // The bug this catches shipped: the traffic slots claimed 308 and 298
    // columns on a 296-pixel panel. fillRect clips, so nothing corrupted memory
    // — the text drawn into them was simply cut off at the edge, which only
    // showed up once a value happened to be wide enough.
    //
    // Adding a text area means adding it here.
    const areas = [_]struct { name: []const u8, x: i32, y: i32, w: u32, h: u32 }{
        .{ .name = "cpu load", .x = dc.CPU_AREA_X, .y = dc.CPU_AREA_Y_LOAD, .w = dc.TEXT_AREA_CPU.width, .h = dc.TEXT_AREA_CPU.height },
        .{ .name = "cpu temp", .x = dc.CPU_AREA_X, .y = dc.CPU_AREA_Y_TEMP, .w = dc.TEXT_AREA_CPU.width, .h = dc.TEXT_AREA_CPU.height },
        .{ .name = "mem", .x = dc.MEM_AREA_X, .y = dc.MEM_AREA_Y, .w = dc.TEXT_AREA_MEM.width, .h = dc.TEXT_AREA_MEM.height },
        .{ .name = "disk usage", .x = dc.DISK_AREA_X, .y = dc.DISK_AREA_Y_DISK, .w = dc.TEXT_AREA_DISK.width, .h = dc.TEXT_AREA_DISK.height },
        .{ .name = "disk temp", .x = dc.DISK_AREA_X, .y = dc.DISK_AREA_Y_TEMP, .w = dc.TEXT_AREA_DISK.width, .h = dc.TEXT_AREA_DISK.height },
        .{ .name = "fan", .x = dc.FAN_VALUE_X, .y = dc.FAN_VALUE_Y - 21, .w = dc.TEXT_AREA_FAN.width, .h = dc.TEXT_AREA_FAN.height },
        .{ .name = "apt", .x = dc.APT_VALUE_X, .y = dc.APT_VALUE_Y - 21, .w = dc.TEXT_AREA_APT.width, .h = dc.TEXT_AREA_APT.height },
        .{ .name = "net", .x = dc.NET_ICON_X, .y = dc.NET_ICON_Y - 21, .w = dc.TEXT_AREA_NET.width, .h = dc.TEXT_AREA_NET.height },
        .{ .name = "traffic down value", .x = dc.TRAFFIC_DOWN_VALUE_X, .y = dc.TRAFFIC_DOWN_AREA_Y, .w = dc.TEXT_AREA_TRAFFIC_VALUE.width, .h = dc.TEXT_AREA_TRAFFIC_VALUE.height },
        .{ .name = "traffic down unit", .x = dc.TRAFFIC_DOWN_UNIT_X, .y = dc.TRAFFIC_DOWN_UNIT_AREA_Y, .w = dc.TEXT_AREA_TRAFFIC_UNIT.width, .h = dc.TEXT_AREA_TRAFFIC_UNIT.height },
        .{ .name = "traffic up value", .x = dc.TRAFFIC_UP_VALUE_X, .y = dc.TRAFFIC_UP_AREA_Y, .w = dc.TEXT_AREA_TRAFFIC_VALUE.width, .h = dc.TEXT_AREA_TRAFFIC_VALUE.height },
        .{ .name = "traffic up unit", .x = dc.TRAFFIC_UP_UNIT_X, .y = dc.TRAFFIC_UP_UNIT_AREA_Y, .w = dc.TEXT_AREA_TRAFFIC_UNIT.width, .h = dc.TEXT_AREA_TRAFFIC_UNIT.height },
        .{ .name = "ip", .x = dc.IP_VALUE_X, .y = dc.IP_AREA_Y, .w = dc.TEXT_AREA_IP.width, .h = dc.TEXT_AREA_IP.height },
        .{ .name = "signal", .x = dc.SIGNAL_AREA_X, .y = dc.SIGNAL_AREA_Y, .w = dc.TEXT_AREA_SIGNAL.width, .h = dc.TEXT_AREA_SIGNAL.height },
        .{ .name = "uptime", .x = dc.UPTIME_VALUE_X, .y = dc.UPTIME_AREA_Y, .w = dc.TEXT_AREA_UPTIME.width, .h = dc.TEXT_AREA_UPTIME.height },
    };

    for (areas) |area| {
        const right = area.x + @as(i32, @intCast(area.w));
        const bottom = area.y + @as(i32, @intCast(area.h));

        if (area.x < 0 or area.y < 0 or right > dc.DISPLAY_WIDTH or bottom > dc.DISPLAY_HEIGHT) {
            std.debug.print(
                "\n  '{s}' spans {d}..{d} x {d}..{d}, panel is {d}x{d}\n",
                .{ area.name, area.x, right, area.y, bottom, dc.DISPLAY_WIDTH, dc.DISPLAY_HEIGHT },
            );
            return error.TextAreaOutsidePanel;
        }
    }
}

test "traffic values fit their slot across the whole range" {
    var bmp = try testBitmap(4, 4);
    defer bmp.deinit();

    const parse = @import("parse.zig");
    const slot = dc.TEXT_AREA_TRAFFIC_VALUE.width;

    // Step through rates spanning every unit, including the 1000..1023 window
    // that used to clip with a 1024 divisor.
    var rate: f64 = 0;
    while (rate < 2_000_000_000) : (rate = rate * 1.7 + 13) {
        const scaled = parse.scaleBytes(rate);

        var buf: [32]u8 = undefined;
        const text = try std.fmt.bufPrint(&buf, "{d:.2}", .{scaled.value});
        try testing.expect(bmp.measureText(text, .Ubuntu20) <= slot);

        var unit_buf: [32]u8 = undefined;
        const unit = try std.fmt.bufPrint(&unit_buf, "{s}/s", .{scaled.unit});
        try testing.expect(bmp.measureText(unit, .Ubuntu14) <= dc.TEXT_AREA_TRAFFIC_UNIT.width);
    }
}

test "bottom bar slots do not overlap or run off the panel" {
    var bmp = try testBitmap(4, 4);
    defer bmp.deinit();

    const ip_end = dc.IP_VALUE_X + @as(i32, dc.TEXT_AREA_IP.width);
    const signal_end = dc.SIGNAL_AREA_X + @as(i32, dc.TEXT_AREA_SIGNAL.width);
    const uptime_end = dc.UPTIME_VALUE_X + @as(i32, dc.TEXT_AREA_UPTIME.width);

    try testing.expect(ip_end <= dc.SIGNAL_AREA_X);
    try testing.expect(signal_end <= dc.UPTIME_ICON_X);
    try testing.expectEqual(@as(i32, dc.DISPLAY_WIDTH), uptime_end);

    // Icons sit inside their own clear areas.
    try testing.expect(dc.SIGNAL_ICON_X >= dc.SIGNAL_AREA_X);
    try testing.expect(dc.SIGNAL_VALUE_X + @as(i32, dc.SIGNAL_VALUE_MAX_W) <= signal_end);
    // The widest IPv4 address must still fit.
    try testing.expect(bmp.measureText("255.255.255.255", .Ubuntu14) <= dc.TEXT_AREA_IP.width);
}

test "drawTextFont stays inside the bitmap when drawn off-screen" {
    var bmp = try testBitmap(20, 20);
    defer bmp.deinit();

    // Far outside in both directions; must not touch memory or trap.
    bmp.drawTextFont(-500, -500, "123", .Ubuntu26, .Black);
    bmp.drawTextFont(500, 500, "123", .Ubuntu26, .Black);
    try testing.expectEqual(@as(u32, 0), countBlack(&bmp));
}

test "drawTextFont marks pixels and advances the cursor" {
    var one = try testBitmap(60, 40);
    defer one.deinit();
    var two = try testBitmap(60, 40);
    defer two.deinit();

    one.drawTextFont(2, 30, "8", .Ubuntu14, .Black);
    two.drawTextFont(2, 30, "88", .Ubuntu14, .Black);

    try testing.expect(countBlack(&one) > 0);
    // The second glyph must add ink rather than overprint the first.
    try testing.expectEqual(countBlack(&one) * 2, countBlack(&two));
}

test "malformed UTF-8 does not hang the decoder" {
    var bmp = try testBitmap(40, 40);
    defer bmp.deinit();

    // Truncated multi-byte sequence and a stray continuation byte.
    bmp.drawTextFont(0, 20, "\xC3", .Ubuntu14, .Black);
    bmp.drawTextFont(0, 20, "\x80\x80", .Ubuntu14, .Black);
    _ = bmp.measureText("\xF0\x9F", .Ubuntu14);
}
