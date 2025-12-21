const std = @import("std");

const log = std.log.scoped(.bmp);

pub const BmpExporter = struct {
    allocator: std.mem.Allocator,
    last_hash: u64 = 0,

    pub fn init(allocator: std.mem.Allocator) BmpExporter {
        return .{
            .allocator = allocator,
        };
    }

    /// Export 1-bit buffer to BMP file
    /// buffer: 1-bit pixel data (row-major, 8 pixels per byte)
    /// width: image width in pixels
    /// height: image height in pixels
    /// path: output file path
    pub fn save(self: *BmpExporter, buffer: []const u8, width: u32, height: u32, path: []const u8) !void {
        // Calculate hash to detect changes (skip export if unchanged)
        const hash = std.hash.Wyhash.hash(0, buffer);
        if (hash == self.last_hash) {
            return;
        }
        self.last_hash = hash;

        const file = std.fs.createFileAbsolute(path, .{}) catch |err| {
            // If primary path fails, try fallback to /tmp
            if (!std.mem.startsWith(u8, path, "/tmp")) {
                const fallback_path = "/tmp/sys-ink.bmp";
                log.warn("Failed to create {s}: {}, trying {s}", .{ path, err, fallback_path });
                return self.saveInternal(buffer, width, height, fallback_path);
            }
            return err;
        };
        defer file.close();

        try self.writeBmp(file, buffer, width, height);
        log.info("BMP exported to {s}", .{path});
    }

    fn saveInternal(self: *BmpExporter, buffer: []const u8, width: u32, height: u32, path: []const u8) !void {
        const file = try std.fs.createFileAbsolute(path, .{});
        defer file.close();
        try self.writeBmp(file, buffer, width, height);
        log.info("BMP exported to {s}", .{path});
    }

    fn writeBmp(self: *BmpExporter, file: std.fs.File, buffer: []const u8, width: u32, height: u32) !void {
        const bmp_stride = ((width + 31) / 32) * 4;
        const image_size = bmp_stride * height;
        const file_size = 62 + image_size;

        var header: [62]u8 = undefined;
        var idx: usize = 0;

        // BMP Header
        header[idx] = 'B';
        idx += 1;
        header[idx] = 'M';
        idx += 1;
        std.mem.writeInt(u32, header[idx..][0..4], file_size, .little);
        idx += 4;
        std.mem.writeInt(u16, header[idx..][0..2], 0, .little);
        idx += 2;
        std.mem.writeInt(u16, header[idx..][0..2], 0, .little);
        idx += 2;
        std.mem.writeInt(u32, header[idx..][0..4], 62, .little);
        idx += 4;

        // DIB Header
        std.mem.writeInt(u32, header[idx..][0..4], 40, .little);
        idx += 4;
        std.mem.writeInt(i32, header[idx..][0..4], @intCast(width), .little);
        idx += 4;
        std.mem.writeInt(i32, header[idx..][0..4], -@as(i32, @intCast(height)), .little);
        idx += 4;
        std.mem.writeInt(u16, header[idx..][0..2], 1, .little);
        idx += 2;
        std.mem.writeInt(u16, header[idx..][0..2], 1, .little);
        idx += 2;
        std.mem.writeInt(u32, header[idx..][0..4], 0, .little);
        idx += 4;
        std.mem.writeInt(u32, header[idx..][0..4], image_size, .little);
        idx += 4;
        std.mem.writeInt(i32, header[idx..][0..4], 2835, .little);
        idx += 4;
        std.mem.writeInt(i32, header[idx..][0..4], 2835, .little);
        idx += 4;
        std.mem.writeInt(u32, header[idx..][0..4], 2, .little);
        idx += 4;
        std.mem.writeInt(u32, header[idx..][0..4], 2, .little);
        idx += 4;

        // Color Table (Black/White)
        header[idx] = 255;
        idx += 1;
        header[idx] = 255;
        idx += 1;
        header[idx] = 255;
        idx += 1;
        header[idx] = 0;
        idx += 1;
        header[idx] = 0;
        idx += 1;
        header[idx] = 0;
        idx += 1;
        header[idx] = 0;
        idx += 1;
        header[idx] = 0;
        idx += 1;

        try file.writeAll(&header);

        var row_buffer = try self.allocator.alloc(u8, bmp_stride);
        defer self.allocator.free(row_buffer);

        var y: u16 = 0;
        while (y < height) : (y += 1) {
            @memset(row_buffer, 0);
            const src_offset = @as(usize, y) * ((width + 7) / 8);
            const copy_bytes = (width + 7) / 8;

            // Ensure we don't read past buffer end
            if (src_offset + copy_bytes <= buffer.len) {
                @memcpy(row_buffer[0..copy_bytes], buffer[src_offset..][0..copy_bytes]);
            }

            // Invert colors (0=black, 1=white in BMP 1-bit)
            for (row_buffer[0..copy_bytes]) |*byte| {
                byte.* = ~byte.*;
            }

            try file.writeAll(row_buffer);
        }
    }
};
