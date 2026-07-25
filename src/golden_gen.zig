//! Regenerates the golden reference frame used by the renderer's layout test.
//!
//! Run through `zig build golden` from the repository root, then review the diff
//! before committing: the whole point of the file is that it only changes when a
//! layout change is intended.

const std = @import("std");
const Renderer = @import("display_renderer.zig").Renderer;
const FakeTransport = @import("waveshare_epd/fake_transport.zig").FakeTransport;

const output_path = "src/testdata/golden_main.bin";

pub fn main(init: std.process.Init) !u8 {
    const allocator = init.gpa;
    const io = init.io;

    var transport = FakeTransport.init(allocator);
    defer transport.deinit();

    var renderer = try Renderer(FakeTransport).init(allocator, io, &transport);
    defer renderer.deinit();

    renderer.drawReferenceScreen();
    renderer.convertTo1Bit(renderer.epd_buffer);

    var dir = try std.Io.Dir.cwd().openDir(io, "src/testdata", .{});
    defer dir.close(io);
    try dir.writeFile(io, .{ .sub_path = "golden_main.bin", .data = renderer.epd_buffer });

    std.debug.print("wrote {s} ({d} bytes)\n", .{ output_path, renderer.epd_buffer.len });
    return 0;
}
