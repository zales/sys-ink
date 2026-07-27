//! Panel simulator served over HTTP, for hosts without a native window.
//!
//! Runs the exact rendering path the daemon runs — same renderer, same fonts,
//! same layout constants, same fault overlay — against the fake transport, and
//! serves the frame as a BMP with a small page that refreshes it. What gets
//! drawn lives in `sim_frame.zig`; on macOS `sim_native.zig` shows the same
//! thing in a real window.
//!
//!     zig build sim-web
//!     open http://127.0.0.1:8390

const std = @import("std");
const sim_frame = @import("sim_frame.zig");
const bmp = @import("bmp.zig");
const frame_server = @import("frame_server.zig");
const FakeTransport = @import("waveshare_epd/fake_transport.zig").FakeTransport;

const port = 8390;

pub fn main(init: std.process.Init) !u8 {
    const allocator = init.gpa;
    const io = init.io;

    var transport = FakeTransport.init(allocator);
    defer transport.deinit();

    var renderer = try sim_frame.SimRenderer.init(allocator, io, &transport);
    defer renderer.deinit();
    try renderer.startup();
    renderer.renderGrid();

    const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(port) };
    var server = try address.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);

    std.debug.print("sys-ink simulator: http://127.0.0.1:{d}\n", .{port});

    const started = std.Io.Timestamp.now(io, .awake).toSeconds();
    var request_buf: [1024]u8 = undefined;
    var image: [bmp.byteSize(sim_frame.width, sim_frame.height)]u8 = undefined;

    while (true) {
        const stream = server.accept(io) catch continue;
        defer stream.close(io);

        switch (frame_server.readRequest(stream, io, &request_buf) orelse continue) {
            .index => frame_server.respondPage(stream, io, "Simulator"),
            .frame => {
                const now = std.Io.Timestamp.now(io, .awake).toSeconds();
                sim_frame.draw(&renderer, @floatFromInt(now), @intCast(now - started));

                // The transport is a recorder with an unbounded log: without this
                // it keeps a heap copy of every frame ever sent.
                transport.resetLog();
                renderer.updateDisplay(true) catch {
                    frame_server.respond(stream, io, "500 Internal Server Error", "text/plain", "render failed\n");
                    continue;
                };

                // Straight from the renderer's packed frame: no file, no allocation.
                frame_server.respondFrame(stream, io, &image, renderer.packedFrame(), sim_frame.width, sim_frame.height);
            },
            .other => frame_server.respondNotFound(stream, io),
        }
    }
}
