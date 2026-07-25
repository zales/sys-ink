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

fn writeBmp(io: std.Io, file: std.Io.File, buffer: []const u8, width: u32, height: u32) !void {
    const stride = rowStride(width);
    if (stride > max_stride) return error.ImageTooWide;

    const src_row_bytes = (width + 7) / 8;

    var write_buf: [4096]u8 = undefined;
    var writer = file.writer(io, &write_buf);
    const out = &writer.interface;

    try out.writeAll(&buildHeader(width, height));

    var row: [max_stride]u8 = undefined;
    var y: u32 = 0;
    while (y < height) : (y += 1) {
        @memset(row[0..stride], 0);

        const src_offset = y * src_row_bytes;
        if (src_offset + src_row_bytes <= buffer.len) {
            // Our buffers use 1 = white; BMP palette index 0 is white, so invert.
            for (row[0..src_row_bytes], buffer[src_offset..][0..src_row_bytes]) |*dst, src| {
                dst.* = ~src;
            }
        }

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
