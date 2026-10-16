const std = @import("std");

const log = std.log.scoped(.bmp);

/// Largest row stride we will write, in bytes. 512 covers images up to 4096px
/// wide, well beyond any panel this drives.
const max_stride = 512;

/// File header, BITMAPINFOHEADER, and a palette of the four greys.
pub const header_len = 14 + 40 + 4 * 4;

/// What every BMP here is made from: the frame the right way up, row by row,
/// four pixels a byte, the first in the top two bits, each a grey from 0 for
/// black to 3 for white. The panel's four, as `Shades.four` draws them.
pub fn packedRowBytes(width: u32) u32 {
    return @divCeil(width, 4);
}

pub fn packedLen(width: u32, height: u32) usize {
    return @as(usize, packedRowBytes(width)) * height;
}

pub const BmpExporter = struct {
    last_hash: ?u64 = null,

    pub fn init() BmpExporter {
        return .{};
    }

    /// Export a packed frame (see `packedRowBytes`) to a BMP file.
    ///
    /// Writes are skipped when the buffer is byte-identical to the last export.
    pub fn save(self: *BmpExporter, io: std.Io, buffer: []const u8, width: u32, height: u32, path: []const u8) !void {
        const hash = std.hash.Wyhash.hash(0, buffer);
        if (self.last_hash) |last| {
            if (hash == last) return;
        }

        var written = path;
        writeFile(io, path, buffer, width, height) catch |err| {
            // A read-only or missing directory is a common misconfiguration;
            // fall back to /tmp rather than losing the export entirely.
            if (std.mem.startsWith(u8, path, "/tmp")) return err;

            const fallback = "/tmp/sys-ink.bmp";
            log.warn("Failed to write {s}: {t}, falling back to {s}", .{ path, err, fallback });
            try writeFile(io, fallback, buffer, width, height);
            written = fallback;
        };

        // Only remember the frame once it actually reached disk, so a failed
        // write does not suppress the next identical export.
        self.last_hash = hash;
        log.debug("BMP exported to {s}", .{written});
    }
};

/// Put the image at `path` so that a reader finds the old frame or the new
/// one, never part of one.
///
/// The export exists to be read by something else — a web server pointed at
/// its directory — and written in place it was empty for a moment and cut
/// short for another, every time the panel changed. Built beside the
/// destination under a name of its own and renamed over it, the file changes
/// in a single step.
///
/// That takes a directory the daemon may create in and a destination that can
/// be replaced, which a file bind-mounted into a container cannot. Where
/// either is missing the image is written in place, as it always was.
fn writeFile(io: std.Io, path: []const u8, buffer: []const u8, width: u32, height: u32) !void {
    replaceFile(io, path, buffer, width, height) catch |err| {
        log.debug("Cannot replace {s} in one step: {t}; writing in place", .{ path, err });

        const file = try std.Io.Dir.createFileAbsolute(io, path, .{});
        defer file.close(io);
        try writeBmp(io, file, buffer, width, height);
    };
}

fn replaceFile(io: std.Io, path: []const u8, buffer: []const u8, width: u32, height: u32) !void {
    var atomic = try std.Io.Dir.cwd().createFileAtomic(io, path, .{ .replace = true });
    // Removes the temporary file if the rename below was never reached.
    defer atomic.deinit(io);

    try writeBmp(io, atomic.file, buffer, width, height);
    try atomic.replace(io);
}

/// The BMP header for a four-bit image whose palette is the four greys, in
/// the packed frame's order: index 0 black, 3 white. Four bits rather than
/// two, which BMP has no place for; a nibble a pixel.
pub fn buildHeader(width: u32, height: u32) [header_len]u8 {
    const stride = rowStride(width);
    const image_size = stride * height;

    var h: [header_len]u8 = @splat(0);

    // File header
    h[0] = 'B';
    h[1] = 'M';
    std.mem.writeInt(u32, h[2..6], header_len + image_size, .little);
    // h[6..10] reserved, already zero
    std.mem.writeInt(u32, h[10..14], header_len, .little); // pixel data offset

    // DIB header (BITMAPINFOHEADER)
    std.mem.writeInt(u32, h[14..18], 40, .little); // header size
    std.mem.writeInt(i32, h[18..22], @intCast(width), .little);
    std.mem.writeInt(i32, h[22..26], -@as(i32, @intCast(height)), .little); // negative = top-down
    std.mem.writeInt(u16, h[26..28], 1, .little); // planes
    std.mem.writeInt(u16, h[28..30], 4, .little); // bits per pixel
    std.mem.writeInt(u32, h[30..34], 0, .little); // BI_RGB, no compression
    std.mem.writeInt(u32, h[34..38], image_size, .little);
    std.mem.writeInt(i32, h[38..42], 2835, .little); // ~72 DPI
    std.mem.writeInt(i32, h[42..46], 2835, .little);
    std.mem.writeInt(u32, h[46..50], 4, .little); // palette entries used
    std.mem.writeInt(u32, h[50..54], 4, .little); // palette entries required

    // Palette, BGR and a reserved byte: black, the two greys, white.
    for (0..4) |i| {
        const level: u8 = @intCast(i * 85);
        h[54 + 4 * i ..][0..4].* = .{ level, level, level, 0 };
    }

    return h;
}

/// BMP rows are padded to a 4-byte boundary.
pub fn rowStride(width: u32) u32 {
    return @divCeil(width * 4, 32) * 4;
}

/// Bytes a serialised BMP of these dimensions occupies.
pub fn byteSize(width: u32, height: u32) usize {
    return header_len + @as(usize, rowStride(width)) * height;
}

/// One BMP row: row `y` of the packed frame `buffer`, a nibble a pixel,
/// padded out to the full stride.
///
/// The single place that knows the layout and the padding; the streaming and
/// in-memory writers below differ only in where the row goes.
fn packRow(row: []u8, buffer: []const u8, y: usize, width: u32) void {
    @memset(row, 0);

    const src_row_bytes = packedRowBytes(width);
    const src_offset = y * src_row_bytes;
    if (src_offset + src_row_bytes > buffer.len) return;
    const src = buffer[src_offset..][0..src_row_bytes];

    for (0..width) |x| {
        const gray = (src[x / 4] >> @intCast(6 - 2 * (x % 4))) & 0b11;
        row[x / 2] |= if (x % 2 == 0) gray << 4 else gray;
    }
}

/// Serialise a packed frame (see `packedRowBytes`) as a BMP into `dest`,
/// returning the part written.
///
/// Exists so a caller that wants the bytes — a preview handing them straight
/// to a client — does not have to write a file and read it back.
pub fn serialize(dest: []u8, buffer: []const u8, width: u32, height: u32) error{ ImageTooWide, NoSpaceLeft }![]u8 {
    const stride = rowStride(width);
    if (stride > max_stride) return error.ImageTooWide;

    const total = byteSize(width, height);
    if (dest.len < total) return error.NoSpaceLeft;

    dest[0..header_len].* = buildHeader(width, height);

    for (0..height) |y| {
        packRow(dest[header_len + y * stride ..][0..stride], buffer, y, width);
    }

    return dest[0..total];
}

fn writeBmp(io: std.Io, file: std.Io.File, buffer: []const u8, width: u32, height: u32) !void {
    const stride = rowStride(width);
    if (stride > max_stride) return error.ImageTooWide;

    var write_buf: [4096]u8 = undefined;
    var writer = file.writer(io, &write_buf);
    const out = &writer.interface;

    try out.writeAll(&buildHeader(width, height));

    // Streamed a row at a time, so the file path needs no image-sized buffer.
    var row: [max_stride]u8 = undefined;
    for (0..height) |y| {
        packRow(row[0..stride], buffer, y, width);
        try out.writeAll(row[0..stride]);
    }

    try writer.flush();
}

// ----------------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------------

const testing = std.testing;

test "rowStride pads rows to 4 bytes" {
    try testing.expectEqual(@as(u32, 4), rowStride(1));
    try testing.expectEqual(@as(u32, 4), rowStride(8));
    try testing.expectEqual(@as(u32, 8), rowStride(9));
    // The 296px panel needs 148 bytes at a nibble a pixel: no padding.
    try testing.expectEqual(@as(u32, 148), rowStride(296));
}

test "buildHeader emits a valid four-bit BMP header" {
    const width = 296;
    const height = 128;
    const h = buildHeader(width, height);

    try testing.expectEqual(@as(u8, 'B'), h[0]);
    try testing.expectEqual(@as(u8, 'M'), h[1]);

    const image_size = rowStride(width) * height;
    try testing.expectEqual(header_len + image_size, std.mem.readInt(u32, h[2..6], .little));
    try testing.expectEqual(@as(u32, header_len), std.mem.readInt(u32, h[10..14], .little));
    try testing.expectEqual(@as(u32, 40), std.mem.readInt(u32, h[14..18], .little));
    try testing.expectEqual(@as(i32, width), std.mem.readInt(i32, h[18..22], .little));
    try testing.expectEqual(@as(u16, 4), std.mem.readInt(u16, h[28..30], .little));
    try testing.expectEqual(image_size, std.mem.readInt(u32, h[34..38], .little));
    try testing.expectEqual(@as(u32, 4), std.mem.readInt(u32, h[46..50], .little));
}

test "buildHeader stores height negative for top-down rows" {
    const h = buildHeader(8, 16);
    try testing.expectEqual(@as(i32, -16), std.mem.readInt(i32, h[22..26], .little));
}

test "the palette runs from black through the two greys to white" {
    const h = buildHeader(8, 8);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, h[54..58]);
    try testing.expectEqualSlices(u8, &.{ 85, 85, 85, 0 }, h[58..62]);
    try testing.expectEqualSlices(u8, &.{ 170, 170, 170, 0 }, h[62..66]);
    try testing.expectEqualSlices(u8, &.{ 255, 255, 255, 0 }, h[66..70]);
}

test "each pixel's grey becomes its nibble, left pixel high" {
    // One row of eight: black, dark, light, white, then white, light, dark, black.
    const frame = [_]u8{ 0b00_01_10_11, 0b11_10_01_00 };
    var buf: [byteSize(8, 1)]u8 = undefined;
    const bytes = try serialize(&buf, &frame, 8, 1);
    try testing.expectEqualSlices(u8, &.{ 0x01, 0x23, 0x32, 0x10 }, bytes[header_len..][0..4]);
}

test "serialize matches what the file writer produces" {
    // Both go through packRow, and this is what pins them together: if either
    // path grows its own idea of layout or padding, the bytes diverge.
    const width = 296;
    const height = 128;

    var frame: [packedLen(width, height)]u8 = undefined;
    for (&frame, 0..) |*b, i| b.* = @truncate(i * 31 + 7);

    var buf: [byteSize(width, height)]u8 = undefined;
    const bytes = try serialize(&buf, &frame, width, height);
    try testing.expectEqual(byteSize(width, height), bytes.len);
    try testing.expectEqualSlices(u8, &buildHeader(width, height), bytes[0..header_len]);

    // Rebuild the same rows the streaming writer would emit.
    const stride = rowStride(width);
    var row: [max_stride]u8 = undefined;
    for (0..height) |y| {
        packRow(row[0..stride], &frame, y, width);
        try testing.expectEqualSlices(u8, row[0..stride], bytes[header_len + y * stride ..][0..stride]);
    }
}

test "an export replaces the file instead of rewriting it" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var dir_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(testing.io, &dir_buf);
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try std.mem.print(&path_buf, "{s}/panel.bmp", .{dir_buf[0..dir_len]});

    const width = 16;
    const height = 2;
    const first: [packedLen(width, height)]u8 = @splat(0xFF);
    const second: [packedLen(width, height)]u8 = @splat(0x00);

    var exporter = BmpExporter.init();
    try exporter.save(testing.io, &first, width, height, path);

    // Someone reading the export, caught with it open as the next frame lands.
    const reader = try tmp.dir.openFile(testing.io, "panel.bmp", .{});
    defer reader.close(testing.io);

    try exporter.save(testing.io, &second, width, height, path);

    // Written in place, the file under the reader would by now be the second
    // frame, and for a moment before that an empty one.
    var expected_buf: [byteSize(width, height)]u8 = undefined;
    var held: [byteSize(width, height) + 1]u8 = undefined;
    const held_len = try reader.readPositionalAll(testing.io, &held, 0);
    try testing.expectEqualSlices(u8, try serialize(&expected_buf, &first, width, height), held[0..held_len]);

    // The name leads to the new frame.
    var current: [byteSize(width, height) + 1]u8 = undefined;
    const now = try tmp.dir.readFile(testing.io, "panel.bmp", &current);
    try testing.expectEqualSlices(u8, try serialize(&expected_buf, &second, width, height), now);

    // And the file it was built in is gone.
    var entries: usize = 0;
    var it = tmp.dir.iterate();
    while (try it.next(testing.io)) |_| entries += 1;
    try testing.expectEqual(@as(usize, 1), entries);
}

test "serialize rejects a destination that is too small" {
    var frame: [packedLen(296, 128)]u8 = @splat(0xFF);
    var small: [100]u8 = undefined;
    try testing.expectError(error.NoSpaceLeft, serialize(&small, &frame, 296, 128));
}

test "the padding bytes of each row are zero" {
    // 300 pixels need 150 bytes, padded to 152; the last two must not carry
    // image data, or viewers show noise down the right edge.
    const width = 300;
    var frame: [packedLen(width, 4)]u8 = @splat(0xAA);
    var buf: [byteSize(width, 4)]u8 = undefined;
    const bytes = try serialize(&buf, &frame, width, 4);

    const stride = rowStride(width);
    try testing.expectEqual(@as(u32, 152), stride);
    for (0..4) |y| {
        const row = bytes[header_len + y * stride ..][0..stride];
        try testing.expectEqualSlices(u8, &[_]u8{ 0, 0 }, row[150..152]);
    }
}
