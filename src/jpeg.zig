//! Baseline JPEG, decoded to its luminance alone.
//!
//! The panel has two colours, so of a picture only the brightness is any use,
//! and that is the first component of a JPEG as it is written: Y in YCbCr, or
//! the only one of a greyscale image. The colour components are still read,
//! because their data is interleaved with it, but never transformed.
//!
//! Album covers come from Spotify's CDN as baseline JPEGs, which is all this
//! takes: 8-bit sequential DCT with Huffman coding, in one scan or several,
//! with or without restart markers. Progressive, lossless, 12-bit and
//! arithmetic-coded images are turned down as `error.Unsupported`.
//!
//! The data comes off the network into a process that runs as root, so every
//! length, index and table in it is checked before it is used: a malformed
//! image is an error or a picture of noise, never a read out of bounds.
//! Free of I/O; the caller hands over the bytes and an allocator for the
//! pixels.

const std = @import("std");

pub const Error = error{
    /// Does not start as a JPEG does.
    NotJpeg,
    /// Ends before the image does.
    Truncated,
    /// A JPEG, but not a baseline one.
    Unsupported,
    /// A JPEG that contradicts itself.
    Corrupt,
    /// Wider or taller than `max_side`.
    TooLarge,
    OutOfMemory,
};

/// Largest width or height taken. Spotify's covers are 64, 300 or 640 pixels
/// square; this bounds what a misbehaving server can make the daemon allocate.
pub const max_side = 1024;

/// An 8-bit greyscale image, row by row. Owned by the caller.
pub const Gray = struct {
    width: u32,
    height: u32,
    pixels: []u8,

    pub fn deinit(self: *Gray, gpa: std.mem.Allocator) void {
        gpa.free(self.pixels);
        self.* = undefined;
    }
};

/// The luminance of the baseline JPEG in `data`.
pub fn decodeLuma(gpa: std.mem.Allocator, data: []const u8) Error!Gray {
    var decoder: Decoder = .{ .data = data };
    return decoder.run(gpa);
}

// ----------------------------------------------------------------------------
// Markers and their segments
// ----------------------------------------------------------------------------

const Component = struct {
    id: u8,
    h: u8,
    v: u8,
    quant: u8,
    dc_table: u8 = 0,
    ac_table: u8 = 0,
    /// The DC value of the last block, which the next one is coded against.
    prediction: i32 = 0,
};

const Frame = struct {
    width: u32,
    height: u32,
    components: [max_components]Component,
    count: u8,
    h_max: u8,
    v_max: u8,

    /// MCUs across and down an interleaved scan.
    fn mcusAcross(self: *const Frame) u32 {
        return std.math.divCeil(u32, self.width, 8 * @as(u32, self.h_max)) catch unreachable;
    }

    fn mcusDown(self: *const Frame) u32 {
        return std.math.divCeil(u32, self.height, 8 * @as(u32, self.v_max)) catch unreachable;
    }

    /// Blocks across and down a component of its own: a scan with only it in
    /// does not round up to whole MCUs.
    fn blocksAcross(self: *const Frame, c: *const Component) u32 {
        const width = std.math.divCeil(u32, self.width * c.h, self.h_max) catch unreachable;
        return std.math.divCeil(u32, width, 8) catch unreachable;
    }

    fn blocksDown(self: *const Frame, c: *const Component) u32 {
        const height = std.math.divCeil(u32, self.height * c.v, self.v_max) catch unreachable;
        return std.math.divCeil(u32, height, 8) catch unreachable;
    }
};

/// Four is as many as the standard allows in a frame.
const max_components = 4;

/// A Huffman table as F.2.2.3 of the standard decodes with: for each code
/// length, the largest code of that length and where its values start.
const Huffman = struct {
    defined: bool = false,
    /// Largest code of each length 1...16, or -1 for none of that length.
    max_code: [17]i32 = @splat(-1),
    /// Smallest code of each length.
    min_code: [17]i32 = @splat(0),
    /// Index in `values` of the smallest code of each length.
    first: [17]u16 = @splat(0),
    values: [256]u8 = @splat(0),
    count: u16 = 0,

    fn build(counts: *const [16]u8, values: []const u8) Error!Huffman {
        var table: Huffman = .{ .defined = true, .count = @intCast(values.len) };
        @memcpy(table.values[0..values.len], values);

        var code: i32 = 0;
        var index: u16 = 0;
        for (counts, 1..) |n, length| {
            table.first[length] = index;
            table.min_code[length] = code;
            code += n;
            index += n;
            // Codes of a length must fit in it: more of them than that is a
            // table no encoder could have written.
            if (code > @as(i32, 1) << @intCast(length)) return error.Corrupt;
            table.max_code[length] = if (n > 0) code - 1 else -1;
            code <<= 1;
        }
        return table;
    }
};

/// The order coefficients are stored in, as indices into the 8x8 block.
const zigzag = [64]u8{
    0,  1,  8,  16, 9,  2,  3,  10,
    17, 24, 32, 25, 18, 11, 4,  5,
    12, 19, 26, 33, 40, 48, 41, 34,
    27, 20, 13, 6,  7,  14, 21, 28,
    35, 42, 49, 56, 57, 50, 43, 36,
    29, 22, 15, 23, 30, 37, 44, 51,
    58, 59, 52, 45, 38, 31, 39, 46,
    53, 60, 61, 54, 47, 55, 62, 63,
};

const Decoder = struct {
    data: []const u8,
    pos: usize = 0,
    /// Quantisation tables, in the order the coefficients come in.
    quant: [4][64]u16 = @splat(@splat(1)),
    quant_defined: [4]bool = @splat(false),
    dc: [4]Huffman = @splat(.{}),
    ac: [4]Huffman = @splat(.{}),
    frame: ?Frame = null,
    /// MCUs between restart markers; 0 for none.
    restart_interval: u16 = 0,
    out: ?Gray = null,

    fn run(self: *Decoder, gpa: std.mem.Allocator) Error!Gray {
        errdefer if (self.out) |*out| out.deinit(gpa);

        if (self.data.len < 2 or self.data[0] != 0xFF or self.data[1] != 0xD8) return error.NotJpeg;
        self.pos = 2;

        var scanned = false;
        while (true) {
            const marker = self.nextMarker() orelse {
                // Some encoders leave the end marker off; an image whose scans
                // have all been read is whole without it.
                if (scanned) break;
                return error.Truncated;
            };
            switch (marker) {
                0xD9 => break, // EOI
                0xC0, 0xC1 => try self.readFrame(gpa, try self.segment()),
                // Every other start of frame is a process this does not do.
                0xC2...0xC3, 0xC5...0xC7, 0xC9...0xCB, 0xCD...0xCF => return error.Unsupported,
                0xC4 => try self.readHuffman(try self.segment()),
                0xDB => try self.readQuant(try self.segment()),
                0xDD => try self.readRestartInterval(try self.segment()),
                0xDA => {
                    try self.readScan(try self.segment());
                    scanned = true;
                },
                // Restart markers belong inside a scan; one outside is noise.
                0xD0...0xD7, 0x01 => {},
                // APPn, COM and the rest: skipped by their length.
                else => _ = try self.segment(),
            }
        }

        if (!scanned) return error.Truncated;
        const out = self.out.?;
        self.out = null;
        return out;
    }

    /// The next marker's code, past any fill bytes; null at the end of data.
    fn nextMarker(self: *Decoder) ?u8 {
        while (self.pos + 1 < self.data.len) {
            if (self.data[self.pos] != 0xFF) {
                self.pos += 1;
                continue;
            }
            const code = self.data[self.pos + 1];
            if (code == 0xFF) {
                self.pos += 1;
                continue;
            }
            self.pos += 2;
            // A stuffed zero is data, not a marker.
            if (code == 0x00) continue;
            return code;
        }
        self.pos = self.data.len;
        return null;
    }

    /// The segment that follows a marker, without its length.
    fn segment(self: *Decoder) Error![]const u8 {
        if (self.pos + 2 > self.data.len) return error.Truncated;
        const len = std.mem.readInt(u16, self.data[self.pos..][0..2], .big);
        if (len < 2) return error.Corrupt;
        if (self.pos + len > self.data.len) return error.Truncated;
        const body = self.data[self.pos + 2 .. self.pos + len];
        self.pos += len;
        return body;
    }

    fn readFrame(self: *Decoder, gpa: std.mem.Allocator, s: []const u8) Error!void {
        if (self.frame != null) return error.Corrupt;
        if (s.len < 6) return error.Corrupt;
        if (s[0] != 8) return error.Unsupported;

        const height = std.mem.readInt(u16, s[1..3], .big);
        const width = std.mem.readInt(u16, s[3..5], .big);
        const count = s[5];
        // Zero height means the height comes later, in a DNL segment, which
        // no encoder of covers writes.
        if (width == 0 or height == 0) return error.Unsupported;
        if (width > max_side or height > max_side) return error.TooLarge;
        if (count != 1 and count != 3) return error.Unsupported;
        if (s.len != 6 + 3 * @as(usize, count)) return error.Corrupt;

        var frame: Frame = .{
            .width = width,
            .height = height,
            .components = undefined,
            .count = count,
            .h_max = 1,
            .v_max = 1,
        };
        for (0..count) |i| {
            const c = s[6 + 3 * i ..][0..3];
            const h = c[1] >> 4;
            const v = c[1] & 0x0F;
            if (h < 1 or h > 4 or v < 1 or v > 4 or c[2] > 3) return error.Corrupt;
            frame.components[i] = .{ .id = c[0], .h = h, .v = v, .quant = c[2] };
            frame.h_max = @max(frame.h_max, h);
            frame.v_max = @max(frame.v_max, v);
        }
        // An MCU of more than ten blocks is outside the standard (B.2.3).
        var blocks: u32 = 0;
        for (frame.components[0..count]) |c| blocks += @as(u32, c.h) * c.v;
        if (count > 1 and blocks > 10) return error.Corrupt;

        self.frame = frame;
        const pixels = try gpa.alloc(u8, @as(usize, width) * height);
        @memset(pixels, 0);
        self.out = .{ .width = width, .height = height, .pixels = pixels };
    }

    fn readQuant(self: *Decoder, s: []const u8) Error!void {
        var rest = s;
        while (rest.len > 0) {
            const precision = rest[0] >> 4;
            const id = rest[0] & 0x0F;
            if (id > 3 or precision > 1) return error.Corrupt;
            const size: usize = if (precision == 0) 64 else 128;
            if (rest.len < 1 + size) return error.Corrupt;
            const table = &self.quant[id];
            for (table, 0..) |*q, k| {
                q.* = if (precision == 0) rest[1 + k] else std.mem.readInt(u16, rest[1 + 2 * k ..][0..2], .big);
            }
            self.quant_defined[id] = true;
            rest = rest[1 + size ..];
        }
    }

    fn readHuffman(self: *Decoder, s: []const u8) Error!void {
        var rest = s;
        while (rest.len > 0) {
            if (rest.len < 17) return error.Corrupt;
            const class = rest[0] >> 4;
            const id = rest[0] & 0x0F;
            if (class > 1 or id > 3) return error.Corrupt;
            const counts = rest[1..17];
            var total: usize = 0;
            for (counts) |n| total += n;
            if (total > 256 or rest.len < 17 + total) return error.Corrupt;

            const table = try Huffman.build(counts, rest[17 .. 17 + total]);
            if (class == 0) self.dc[id] = table else self.ac[id] = table;
            rest = rest[17 + total ..];
        }
    }

    fn readRestartInterval(self: *Decoder, s: []const u8) Error!void {
        if (s.len != 2) return error.Corrupt;
        self.restart_interval = std.mem.readInt(u16, s[0..2], .big);
    }

    // ------------------------------------------------------------------------
    // Scans
    // ------------------------------------------------------------------------

    fn readScan(self: *Decoder, s: []const u8) Error!void {
        const frame = if (self.frame) |*f| f else return error.Corrupt;
        if (s.len < 1) return error.Corrupt;
        const count = s[0];
        if (count < 1 or count > frame.count or s.len != 1 + 2 * @as(usize, count) + 3) return error.Corrupt;
        // Spectral selection and successive approximation are fixed in a
        // sequential scan; anything else is a progressive image mislabelled.
        const tail = s[1 + 2 * @as(usize, count) ..][0..3];
        if (tail[0] != 0 or tail[1] != 63 or tail[2] != 0) return error.Unsupported;

        var in_scan: [max_components]*Component = undefined;
        for (0..count) |i| {
            const id = s[1 + 2 * i];
            const tables = s[2 + 2 * i];
            const c = findComponent(frame, id) orelse return error.Corrupt;
            for (in_scan[0..i]) |other| if (other == c) return error.Corrupt;
            c.dc_table = tables >> 4;
            c.ac_table = tables & 0x0F;
            if (c.dc_table > 3 or c.ac_table > 3) return error.Corrupt;
            if (!self.dc[c.dc_table].defined or !self.ac[c.ac_table].defined) return error.Corrupt;
            if (!self.quant_defined[c.quant]) return error.Corrupt;
            c.prediction = 0;
            in_scan[i] = c;
        }
        const scan = in_scan[0..count];
        const luma = &frame.components[0];

        var bits: BitReader = .{ .data = self.data, .pos = self.pos };

        // One component alone is coded block by block over that component's
        // own size; several are interleaved MCU by MCU over the frame's.
        const across = if (count == 1) frame.blocksAcross(scan[0]) else frame.mcusAcross();
        const down = if (count == 1) frame.blocksDown(scan[0]) else frame.mcusDown();
        const total = across * down;

        var coefficients: [64]f32 = undefined;
        var done: u32 = 0;
        while (done < total) : (done += 1) {
            if (self.restart_interval > 0 and done > 0 and done % self.restart_interval == 0) {
                bits.restart();
                for (scan) |c| c.prediction = 0;
            }

            const mcu_x = done % across;
            const mcu_y = done / across;
            for (scan) |c| {
                const h: u32 = if (count == 1) 1 else c.h;
                const v: u32 = if (count == 1) 1 else c.v;
                for (0..v) |by| {
                    for (0..h) |bx| {
                        try self.decodeBlock(&bits, c, &coefficients);
                        if (c != luma) continue;
                        const block_x = mcu_x * h + @as(u32, @intCast(bx));
                        const block_y = mcu_y * v + @as(u32, @intCast(by));
                        self.storeBlock(&coefficients, block_x, block_y);
                    }
                }
            }
        }

        // Past the scan's data, so the next marker is found from there.
        self.pos = bits.pos;
    }

    fn findComponent(frame: *Frame, id: u8) ?*Component {
        for (frame.components[0..frame.count]) |*c| {
            if (c.id == id) return c;
        }
        return null;
    }

    /// Read one block's coefficients, dequantised, in natural order.
    fn decodeBlock(self: *Decoder, bits: *BitReader, c: *Component, out: *[64]f32) Error!void {
        const quant = &self.quant[c.quant];
        @memset(out, 0);

        const size = try bits.decode(&self.dc[c.dc_table]);
        if (size > 11) return error.Corrupt;
        const diff = extend(bits.read(@intCast(size)), @intCast(size));
        // Clamped: a run of corrupt differences would otherwise overflow it.
        c.prediction = std.math.clamp(c.prediction + diff, -(1 << 16), 1 << 16);
        out[0] = @as(f32, @floatFromInt(c.prediction)) * @as(f32, @floatFromInt(quant[0]));

        var k: usize = 1;
        while (k < 64) {
            const symbol = try bits.decode(&self.ac[c.ac_table]);
            const zeros = symbol >> 4;
            const ac_size = symbol & 0x0F;
            if (ac_size == 0) {
                // End of block, or sixteen zeros.
                if (zeros != 15) break;
                k += 16;
                continue;
            }
            k += zeros;
            if (k > 63) return error.Corrupt;
            const value = extend(bits.read(@intCast(ac_size)), @intCast(ac_size));
            out[zigzag[k]] = @as(f32, @floatFromInt(value)) * @as(f32, @floatFromInt(quant[k]));
            k += 1;
        }
    }

    /// The block's pixels into the image, as far as they fall inside it.
    fn storeBlock(self: *Decoder, coefficients: *const [64]f32, block_x: u32, block_y: u32) void {
        const out = &self.out.?;
        var pixels: [64]u8 = undefined;
        inverseDct(coefficients, &pixels);

        const x0 = block_x * 8;
        const y0 = block_y * 8;
        if (x0 >= out.width or y0 >= out.height) return;
        const w = @min(8, out.width - x0);
        const h = @min(8, out.height - y0);
        for (0..h) |y| {
            const row = out.pixels[(y0 + y) * out.width + x0 ..][0..w];
            @memcpy(row, pixels[y * 8 ..][0..w]);
        }
    }
};

/// A coefficient's value from its `size` bits as coded (F.2.2.1).
fn extend(bits: u16, size: u4) i32 {
    if (size == 0) return 0;
    const value: i32 = bits;
    const half = @as(i32, 1) << (size - 1);
    return if (value < half) value - (@as(i32, 1) << size) + 1 else value;
}

/// The entropy-coded data of a scan, a bit at a time, with the stuffed zero
/// after each 0xFF taken out. At a marker it gives zeros rather than reading
/// into it, which is what the standard has a decoder do with a scan that ends
/// early.
const BitReader = struct {
    data: []const u8,
    pos: usize,
    acc: u32 = 0,
    count: u6 = 0,
    at_marker: bool = false,

    fn fill(self: *BitReader) void {
        while (self.count <= 24) {
            self.acc |= @as(u32, self.nextByte()) << @intCast(24 - self.count);
            self.count += 8;
        }
    }

    fn nextByte(self: *BitReader) u8 {
        if (self.at_marker or self.pos >= self.data.len) return 0;
        const byte = self.data[self.pos];
        if (byte != 0xFF) {
            self.pos += 1;
            return byte;
        }
        if (self.pos + 1 < self.data.len and self.data[self.pos + 1] == 0x00) {
            self.pos += 2;
            return 0xFF;
        }
        self.at_marker = true;
        return 0;
    }

    fn bit(self: *BitReader) u1 {
        if (self.count == 0) self.fill();
        const b: u1 = @intCast(self.acc >> 31);
        self.acc <<= 1;
        self.count -= 1;
        return b;
    }

    fn read(self: *BitReader, n: u5) u16 {
        if (n == 0) return 0;
        if (self.count < n) self.fill();
        const value: u16 = @intCast(self.acc >> @intCast(32 - @as(u6, n)));
        self.acc <<= n;
        self.count -= n;
        return value;
    }

    fn decode(self: *BitReader, table: *const Huffman) Error!u8 {
        var code: i32 = 0;
        for (1..17) |length| {
            code = (code << 1) | self.bit();
            if (code <= table.max_code[length]) {
                const index = @as(i32, table.first[length]) + code - table.min_code[length];
                if (index < 0 or index >= table.count) return error.Corrupt;
                return table.values[@intCast(index)];
            }
        }
        return error.Corrupt;
    }

    /// At a restart interval: drop what is left of the byte, and step over
    /// the RSTn marker that should be next.
    fn restart(self: *BitReader) void {
        self.acc = 0;
        self.count = 0;
        self.at_marker = false;
        while (self.pos + 1 < self.data.len and self.data[self.pos] == 0xFF and self.data[self.pos + 1] == 0xFF) self.pos += 1;
        if (self.pos + 1 < self.data.len and self.data[self.pos] == 0xFF and
            self.data[self.pos + 1] >= 0xD0 and self.data[self.pos + 1] <= 0xD7)
        {
            self.pos += 2;
        }
    }
};

/// `cos((2x + 1) u pi / 16)`, with the normalising factors folded in: half of
/// it for each pass, and `1 / sqrt 2` more for `u = 0`.
const idct_table: [8][8]f32 = blk: {
    @setEvalBranchQuota(10_000);
    var table: [8][8]f32 = undefined;
    for (0..8) |x| {
        for (0..8) |u| {
            const scale: f32 = if (u == 0) 1.0 / @sqrt(2.0) else 1.0;
            const angle = @as(f32, @floatFromInt((2 * x + 1) * u)) * std.math.pi / 16.0;
            table[x][u] = 0.5 * scale * @cos(angle);
        }
    }
    break :blk table;
};

/// The 8x8 inverse DCT of `in`, levelled and clamped to a byte.
fn inverseDct(in: *const [64]f32, out: *[64]u8) void {
    var rows: [64]f32 = undefined;
    for (0..8) |y| {
        for (0..8) |x| {
            var sum: f32 = 0;
            for (0..8) |u| sum += idct_table[x][u] * in[y * 8 + u];
            rows[y * 8 + x] = sum;
        }
    }
    for (0..8) |x| {
        for (0..8) |y| {
            var sum: f32 = 0;
            for (0..8) |v| sum += idct_table[y][v] * rows[v * 8 + x];
            out[y * 8 + x] = @intFromFloat(std.math.clamp(@round(sum + 128.0), 0.0, 255.0));
        }
    }
}

// ----------------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------------
//
// The images are 37x21, which is no multiple of a block or an MCU, made by
// libjpeg's cjpeg; what each should decode to is libjpeg's djpeg -grayscale.
// Its IDCT is integer and this one is not, so a pixel may differ by a level
// or two.

const testing = std.testing;

fn expectLuma(jpeg: []const u8, expected: []const u8) !void {
    var image = try decodeLuma(testing.allocator, jpeg);
    defer image.deinit(testing.allocator);

    try testing.expectEqual(@as(u32, 37), image.width);
    try testing.expectEqual(@as(u32, 21), image.height);
    try testing.expectEqual(expected.len, image.pixels.len);
    for (image.pixels, expected) |got, want| {
        try testing.expect(@abs(@as(i16, got) - want) <= 2);
    }
}

test "a colour image subsampled 4:2:0 decodes to the luminance libjpeg gets" {
    try expectLuma(@embedFile("testdata/jpeg/color420.jpg"), @embedFile("testdata/jpeg/color420.luma"));
}

test "an image with restart markers between its blocks decodes as libjpeg decodes it" {
    try expectLuma(@embedFile("testdata/jpeg/color444_restart.jpg"), @embedFile("testdata/jpeg/color444_restart.luma"));
}

test "a greyscale image decodes as libjpeg decodes it" {
    try expectLuma(@embedFile("testdata/jpeg/gray.jpg"), @embedFile("testdata/jpeg/gray.luma"));
}

test "a progressive image is turned down rather than misread" {
    try testing.expectError(error.Unsupported, decodeLuma(testing.allocator, @embedFile("testdata/jpeg/progressive.jpg")));
}

test "something that is not a JPEG is said to be so" {
    try testing.expectError(error.NotJpeg, decodeLuma(testing.allocator, "<html>Not found</html>"));
    try testing.expectError(error.NotJpeg, decodeLuma(testing.allocator, ""));
}

test "an image cut short anywhere is an error or a picture, never a crash" {
    const whole = @embedFile("testdata/jpeg/color420.jpg");
    for (0..whole.len) |len| {
        if (decodeLuma(testing.allocator, whole[0..len])) |image| {
            var owned = image;
            owned.deinit(testing.allocator);
        } else |_| {}
    }
}

test "an image with bytes flipped anywhere is an error or a picture, never a crash" {
    const whole = @embedFile("testdata/jpeg/color444_restart.jpg");
    var copy: [whole.len]u8 = whole.*;
    for (0..copy.len) |i| {
        for ([_]u8{ 0x00, 0xFF, copy[i] ^ 0x55 }) |replacement| {
            const saved = copy[i];
            copy[i] = replacement;
            defer copy[i] = saved;
            if (decodeLuma(testing.allocator, &copy)) |image| {
                var owned = image;
                owned.deinit(testing.allocator);
            } else |_| {}
        }
    }
}

test "an image larger than the cap is turned down before anything is allocated for it" {
    const header = [_]u8{
        0xFF, 0xD8, // SOI
        0xFF, 0xC0, 0x00, 0x0B, 0x08, // SOF0, length 11, 8-bit
        0x10, 0x00, 0x10, 0x00, // 4096 x 4096
        0x01, 0x01, 0x11, 0x00, // one component
    };
    try testing.expectError(error.TooLarge, decodeLuma(testing.failing_allocator, &header));
}
