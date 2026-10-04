//! Regenerates the golden reference frame used by the renderer's layout test.
//!
//! Run through `zig build golden` from the repository root, then review the diff
//! before committing: the whole point of the file is that it only changes when a
//! layout change is intended.

const std = @import("std");
const Renderer = @import("display_renderer.zig").Renderer;

const output_path = "src/testdata/golden_main.bin";

pub fn main(init: std.process.Init) !u8 {
    const allocator = init.gpa;
    const io = init.io;

    var renderer = try Renderer.init(allocator);
    defer renderer.deinit();

    renderer.drawReferenceScreen();
    const frame = renderer.panelFrame();

    var dir = try std.Io.Dir.cwd().openDir(io, "src/testdata", .{});
    defer dir.close(io);
    try dir.writeFile(io, .{ .sub_path = "golden_main.bin", .data = frame });

    std.debug.print("wrote {s} ({d} bytes)\n", .{ output_path, frame.len });
    return 0;
}
