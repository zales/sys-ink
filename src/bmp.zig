const std = @import("std");

const log = std.log.scoped(.bmp);

/// Largest row stride we will write, in bytes. 512 covers images up to 4096px
/// wide, well beyond any panel this drives.
const max_stride = 512;

pub const header_len = 62;

pub const BmpExporter = struct {
    last_hash: ?u64 = null,

    pub fn init() BmpExporter {
        return .{};
    }

    /// Export a 1-bit buffer to a BMP file.
    ///
    /// `buffer` is row-major, 8 pixels per byte, MSB first, 1 = white.
    /// Writes are skipped when the buffer is byte-identical to the last export.
    pub fn save(self: *BmpExporter, io: std.Io, buffer: []const u8, width: u32, height: u32, path: []const u8) !void {
        const hash = std.hash.Wyhash.hash(0, buffer);
        if (self.last_hash) |last| {
            if (hash == last) return;
        }

        const file = std.Io.Dir.createFileAbsolute(io, path, .{}) catch |err| blk: {
            // A read-only or missing directory is a common misconfiguration;
            // fall back to /tmp rather than losing the export entirely.
            if (std.mem.startsWith(u8, path, "/tmp")) return err;

            const fallback = "/tmp/sys-ink.bmp";
            log.warn("Failed to create {s}: {t}, falling back to {s}", .{ path, err, fallback });
            break :blk try std.Io.Dir.createFileAbsolute(io, fallback, .{});
        };
        defer file.close(io);

        try writeBmp(io, file, buffer, width, height);

        // Only remember the frame once it actually reached disk, so a failed
        // write does not suppress the next identical export.
        self.last_hash = hash;
        log.debug("BMP exported to {s}", .{path});
    }
};

/// Build the 62-byte BITMAPINFOHEADER BMP header for a 1-bit image.
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
    std.mem.writeInt(u16, h[28..30], 1, .little); // bits per pixel
    std.mem.writeInt(u32, h[30..34], 0, .little); // BI_RGB, no compression
    std.mem.writeInt(u32, h[34..38], image_size, .little);
    std.mem.writeInt(i32, h[38..42], 2835, .little); // ~72 DPI
    std.mem.writeInt(i32, h[42..46], 2835, .little);
    std.mem.writeInt(u32, h[46..50], 2, .little); // palette entries used
    std.mem.writeInt(u32, h[50..54], 2, .little); // palette entries required

    // Palette: index 0 = white, index 1 = black (BGRA)
    h[54] = 255;
    h[55] = 255;
    h[56] = 255;
    // h[57..62] stay zero: alpha of entry 0, then black entry 1

    return h;
}

/// BMP rows are padded to a 4-byte boundary.
pub fn rowStride(width: u32) u32 {
    return ((width + 31) / 32) * 4;
}

/// Bytes a serialised 1-bit BMP of these dimensions occupies.
pub fn byteSize(width: u32, height: u32) usize {
    return header_len + rowStride(width) * height;
}

/// One BMP row: `buffer` row `y`, inverted, padded out to the full stride.
///
/// The single place that knows the polarity and the padding; the streaming and
/// in-memory writers below differ only in where the row goes.
fn packRow(row: []u8, buffer: []const u8, y: usize, src_row_bytes: usize) void {
    @memset(row, 0);

    const src_offset = y * src_row_bytes;
    if (src_offset + src_row_bytes <= buffer.len) {
        // Our buffers use 1 = white; BMP palette index 0 is white, so invert.
        for (row[0..src_row_bytes], buffer[src_offset..][0..src_row_bytes]) |*dst, src| {
            dst.* = ~src;
        }
    }
}

/// Serialise a 1-bit buffer as a BMP into `dest`, returning the part written.
///
/// `buffer` is row-major, 8 pixels per byte, MSB first, 1 = white. Exists so a
/// caller that wants the bytes — a preview handing them straight to a client —
/// does not have to write a file and read it back.
pub fn serialize(dest: []u8, buffer: []const u8, width: u32, height: u32) error{ ImageTooWide, NoSpaceLeft }![]u8 {
    const stride = rowStride(width);
    if (stride > max_stride) return error.ImageTooWide;

    const total = byteSize(width, height);
    if (dest.len < total) return error.NoSpaceLeft;

    dest[0..header_len].* = buildHeader(width, height);

    const src_row_bytes = (width + 7) / 8;
    for (0..height) |y| {
        packRow(dest[header_len + y * stride ..][0..stride], buffer, y, src_row_bytes);
    }

    return dest[0..total];
}

fn writeBmp(io: std.Io, file: std.Io.File, buffer: []const u8, width: u32, height: u32) !void {
    const stride = rowStride(width);
    if (stride > max_stride) return error.ImageTooWide;

    const src_row_bytes = (width + 7) / 8;

    var write_buf: [4096]u8 = undefined;
    var writer = file.writer(io, &write_buf);
    const out = &writer.interface;

    try out.writeAll(&buildHeader(width, height));

    // Streamed a row at a time, so the file path needs no image-sized buffer.
    var row: [max_stride]u8 = undefined;
    for (0..height) |y| {
        packRow(row[0..stride], buffer, y, src_row_bytes);
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
    try testing.expectEqual(@as(u32, 4), rowStride(32));
    try testing.expectEqual(@as(u32, 8), rowStride(33));
    // The 296px panel needs 37 bytes, padded up to 40.
    try testing.expectEqual(@as(u32, 40), rowStride(296));
}

test "buildHeader emits a valid 1-bit BMP header" {
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
    try testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, h[28..30], .little));
    try testing.expectEqual(image_size, std.mem.readInt(u32, h[34..38], .little));
}

test "buildHeader stores height negative for top-down rows" {
    const h = buildHeader(8, 16);
    try testing.expectEqual(@as(i32, -16), std.mem.readInt(i32, h[22..26], .little));
}

test "buildHeader palette maps index 0 to white and 1 to black" {
    const h = buildHeader(8, 8);
    try testing.expectEqualSlices(u8, &.{ 255, 255, 255, 0 }, h[54..58]);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, h[58..62]);
}

test "serialize matches what the file writer produces" {
    // Both go through packRow, and this is what pins them together: if either
    // path grows its own idea of polarity or padding, the bytes diverge.
    const width = 296;
    const height = 128;
    const src_row_bytes = (width + 7) / 8;

    var frame: [src_row_bytes * height]u8 = undefined;
    for (&frame, 0..) |*b, i| b.* = @truncate(i * 31 + 7);

    var buf: [byteSize(width, height)]u8 = undefined;
    const bytes = try serialize(&buf, &frame, width, height);
    try testing.expectEqual(byteSize(width, height), bytes.len);
    try testing.expectEqualSlices(u8, &buildHeader(width, height), bytes[0..header_len]);

    // Rebuild the same rows the streaming writer would emit.
    const stride = rowStride(width);
    var row: [max_stride]u8 = undefined;
    for (0..height) |y| {
        packRow(row[0..stride], &frame, y, src_row_bytes);
        try testing.expectEqualSlices(u8, row[0..stride], bytes[header_len + y * stride ..][0..stride]);
    }
}

test "serialize rejects a destination that is too small" {
    var frame: [37 * 128]u8 = @splat(0xFF);
    var small: [100]u8 = undefined;
    try testing.expectError(error.NoSpaceLeft, serialize(&small, &frame, 296, 128));
}

test "the padding bytes of each row are zero" {
    // 296 pixels need 37 bytes, padded to 40; the last three must not carry
    // image data, or viewers show noise down the right edge.
    const width = 296;
    var frame: [37 * 4]u8 = @splat(0xAA);
    var buf: [byteSize(width, 4)]u8 = undefined;
    const bytes = try serialize(&buf, &frame, width, 4);

    const stride = rowStride(width);
    for (0..4) |y| {
        const row = bytes[header_len + y * stride ..][0..stride];
        try testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 0 }, row[37..40]);
    }
}
