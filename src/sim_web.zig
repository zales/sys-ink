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
const config = @import("config.zig");
const sim_frame = @import("sim_frame.zig");
const FakeTransport = @import("waveshare_epd/fake_transport.zig").FakeTransport;

const port = 8390;
const bmp_path = "/tmp/sys-ink-sim.bmp";

// ----------------------------------------------------------------------------
// A deliberately minimal HTTP server: one connection at a time, one request
// each. Enough for a preview that a single browser tab polls.
// ----------------------------------------------------------------------------

fn respond(
    stream: std.Io.net.Stream,
    io: std.Io,
    status: []const u8,
    content_type: []const u8,
    body: []const u8,
) void {
    var out_buf: [1024]u8 = undefined;
    var writer = stream.writer(io, &out_buf);
    const w = &writer.interface;

    w.print("HTTP/1.1 {s}\r\n" ++
        "Content-Type: {s}\r\n" ++
        "Content-Length: {d}\r\n" ++
        "Cache-Control: no-store\r\n" ++
        "Connection: close\r\n\r\n", .{ status, content_type, body.len }) catch return;
    w.writeAll(body) catch return;
    w.flush() catch return;
}

const page = @embedFile("sim_page.html");

pub fn main(init: std.process.Init) !u8 {
    const allocator = init.gpa;
    const io = init.io;

    // Route the renderer's own BMP exporter to our file; the export happens
    // inside the fault-overlay window, so the served frame matches the glass.
    config.Config.export_bmp = true;
    config.Config.bmp_export_path = bmp_path;

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

    while (true) {
        const stream = server.accept(io) catch continue;
        defer stream.close(io);

        var in_buf: [1024]u8 = undefined;
        var reader = stream.reader(io, &in_buf);
        // Only the request line matters here; headers are ignored.
        const line = reader.interface.takeDelimiterExclusive('\n') catch continue;

        if (std.mem.startsWith(u8, line, "GET /frame.bmp")) {
            const now = std.Io.Timestamp.now(io, .awake).toSeconds();
            sim_frame.draw(&renderer, @floatFromInt(now), @intCast(now - started));

            // The full daemon path, including the BMP export.
            renderer.updateDisplay(true) catch {
                respond(stream, io, "500 Internal Server Error", "text/plain", "render failed\n");
                continue;
            };

            const bmp = std.Io.Dir.cwd().readFileAlloc(io, bmp_path, allocator, .limited(64 * 1024)) catch {
                respond(stream, io, "503 Service Unavailable", "text/plain", "no frame yet\n");
                continue;
            };
            defer allocator.free(bmp);

            respond(stream, io, "200 OK", "image/bmp", bmp);
        } else if (std.mem.startsWith(u8, line, "GET / ")) {
            respond(stream, io, "200 OK", "text/html; charset=utf-8", page);
        } else {
            respond(stream, io, "404 Not Found", "text/plain", "not found\n");
        }
    }
}
