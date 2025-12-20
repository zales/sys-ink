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
    fonts: FontSet,

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

    pub const FontSet = struct {
        ubuntu14: font_data.Font,
        ubuntu20: font_data.Font,
        ubuntu24: font_data.Font,
        ubuntu26: font_data.Font,
        ubuntu34: font_data.Font,
        material14: font_data.Font,
        material24: font_data.Font,
        material50: font_data.Font,

        pub fn init(allocator: std.mem.Allocator) !FontSet {
            return FontSet{
                .ubuntu14 = try font_data.init_ubuntu_14(allocator),
                .ubuntu20 = try font_data.init_ubuntu_20(allocator),
                .ubuntu24 = try font_data.init_ubuntu_24(allocator),
                .ubuntu26 = try font_data.init_ubuntu_26(allocator),
                .ubuntu34 = try font_data.init_ubuntu_34(allocator),
                .material14 = try font_data.init_material_14(allocator),
                .material24 = try font_data.init_material_24(allocator),
                .material50 = try font_data.init_material_50(allocator),
            };
        }

        pub fn deinit(self: *FontSet) void {
            self.ubuntu14.glyphs.deinit();
            self.ubuntu20.glyphs.deinit();
            self.ubuntu24.glyphs.deinit();
            self.ubuntu26.glyphs.deinit();
            self.ubuntu34.glyphs.deinit();
            self.material14.glyphs.deinit();
            self.material24.glyphs.deinit();
            self.material50.glyphs.deinit();
        }
    };

    pub fn init(allocator: std.mem.Allocator, width: u32, height: u32) !Bitmap {
        const stride = width;
        const size = stride * height;
        const data = try allocator.alloc(u8, size);
        @memset(data, 255); // Clear to white

        const fonts = try FontSet.init(allocator);

        return Bitmap{
            .width = width,
            .height = height,
            .stride = stride,
            .data = data,
            .allocator = allocator,
            .fonts = fonts,
        };
    }

    pub fn deinit(self: *Bitmap) void {
        self.fonts.deinit();
        self.allocator.free(self.data);
    }

    pub fn clear(self: *Bitmap, color: Color) void {
        const val: u8 = if (color == .White) 255 else 0;
        @memset(self.data, val);
    }

    pub fn setPixel(self: *Bitmap, x: i32, y: i32, color: Color) void {
        if (x < 0 or x >= self.width or y < 0 or y >= self.height) return;

        const val: u8 = if (color == .White) 255 else 0;
        const idx = @as(usize, @intCast(y)) * self.stride + @as(usize, @intCast(x));
        self.data[idx] = val;
    }

    pub fn drawLine(self: *Bitmap, x0: i32, y0: i32, x1: i32, y1: i32, color: Color) void {
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
        const x2 = x + @as(i32, @intCast(w)) - 1;
        const y2 = y + @as(i32, @intCast(h)) - 1;
        self.drawLine(x, y, x2, y, color);
        self.drawLine(x2, y, x2, y2, color);
        self.drawLine(x2, y2, x, y2, color);
        self.drawLine(x, y2, x, y, color);
    }

    pub fn fillRect(self: *Bitmap, x: i32, y: i32, w: u32, h: u32, color: Color) void {
        var i: i32 = 0;
        while (i < h) : (i += 1) {
            self.drawLine(x, y + i, x + @as(i32, @intCast(w)) - 1, y + i, color);
        }
    }

    pub fn invertRect(self: *Bitmap, x: i32, y: i32, w: u32, h: u32) void {
        var py: i32 = 0;
        while (py < h) : (py += 1) {
            var px: i32 = 0;
            while (px < w) : (px += 1) {
                const px_abs = x + px;
                const py_abs = y + py;
                if (px_abs >= 0 and px_abs < self.width and py_abs >= 0 and py_abs < self.height) {
                    const idx = @as(usize, @intCast(py_abs)) * self.stride + @as(usize, @intCast(px_abs));
                    self.data[idx] = 255 - self.data[idx];
                }
            }
        }
    }

    pub fn getFontAscent(self: *Bitmap, font_type: FontType) i32 {
        const font = self.getFont(font_type);
        return @intCast(font.ascent);
    }

    fn getFont(self: *Bitmap, font_type: FontType) *font_data.Font {
        return switch (font_type) {
            .Ubuntu14 => &self.fonts.ubuntu14,
            .Ubuntu20 => &self.fonts.ubuntu20,
            .Ubuntu24 => &self.fonts.ubuntu24,
            .Ubuntu26 => &self.fonts.ubuntu26,
            .Ubuntu34 => &self.fonts.ubuntu34,
            .Material14 => &self.fonts.material14,
            .Material24 => &self.fonts.material24,
            .Material50 => &self.fonts.material50,
        };
    }

    pub fn drawTextFont(self: *Bitmap, x: i32, y: i32, text: []const u8, font_type: FontType, color: Color) void {
        const font = self.getFont(font_type);
        var cursor_x = x;

        // Iterate over UTF-8 characters
        var i: usize = 0;
        while (i < text.len) {
            const cp_len = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
            if (i + cp_len > text.len) break;
            const cp = std.unicode.utf8Decode(text[i .. i + cp_len]) catch '?';
            i += cp_len;

            if (font.glyphs.get(cp)) |glyph| {
                // Draw glyph
                var bit_idx: usize = 0;
                var byte_idx: usize = 0;

                // Position calculation:
                // Each glyph is rendered at its own top-left [0,0] in fontgen.c
                // bearing_y tells us how far this glyph's top is from baseline (negative = above)
                // To align all glyphs on a common baseline:
                // baseline_y = y
                // glyph_top_y = baseline_y + bearing_y (bearing_y is negative, so this moves up)

                const baseline_y = y;
                const draw_x = cursor_x + glyph.bearing_x;
                const draw_y = baseline_y + glyph.bearing_y;

                var gy: u16 = 0;
                while (gy < glyph.height) : (gy += 1) {
                    var gx: u16 = 0;
                    while (gx < glyph.width) : (gx += 1) {
                        const byte = glyph.data[byte_idx];
                        const bit = (byte >> @intCast(7 - bit_idx)) & 1;

                        if (bit == 1) {
                            self.setPixel(draw_x + gx, draw_y + gy, color);
                        }

                        bit_idx += 1;
                        if (bit_idx == 8) {
                            bit_idx = 0;
                            byte_idx += 1;
                        }
                    }
                }

                cursor_x += glyph.advance_x;
            } else {
                // Missing glyph
                cursor_x += 10;
            }
        }
    }

    pub fn measureText(self: *Bitmap, text: []const u8, font_type: FontType) u32 {
        const font = self.getFont(font_type);
        var width: u32 = 0;
        var i: usize = 0;
        while (i < text.len) {
            const cp_len = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
            if (i + cp_len > text.len) break;
            const cp = std.unicode.utf8Decode(text[i .. i + cp_len]) catch '?';
            i += cp_len;

            if (font.glyphs.get(cp)) |glyph| {
                width += glyph.advance_x;
            } else {
                width += 10;
            }
        }
        return width;
    }
};
