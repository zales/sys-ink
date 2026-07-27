//! Desktop panel simulator: the real renderer in a browser window.
//!
//! Runs the exact rendering path the daemon runs — same renderer, same fonts,
//! same layout constants, same fault overlay — against the fake transport, and
//! serves the frame as a BMP over HTTP with a small page that refreshes it.
//! Metrics are synthesized as smooth functions of time so every slot exercises
//! its formatting, including the fault overlay, which flares periodically.
//!
//!     zig build sim
//!     open http://127.0.0.1:8390
//!
//! No dependencies, no window toolkit: the "window" is a browser tab. Layout
//! changes can be judged here before a binary ever reaches the hardware.

const std = @import("std");
const config = @import("config.zig");
const parse = @import("parse.zig");
const Renderer = @import("display_renderer.zig").Renderer;
const FakeTransport = @import("waveshare_epd/fake_transport.zig").FakeTransport;

const port = 8390;
const bmp_path = "/tmp/sys-ink-sim.bmp";

/// How the synthetic day goes: fault overlay on for 6 s out of every 30.
fn faultActive(t: f64) bool {
    const phase = @mod(t, 30.0);
    return phase >= 20.0 and phase < 26.0;
}

fn renderFrame(renderer: *Renderer(FakeTransport), t: f64, uptime_s: u64) void {
    const wave = struct {
        fn of(time: f64, period: f64) f64 {
            return @abs(@sin(time * std.math.tau / period));
        }
    }.of;

    const cpu: u8 = @intFromFloat(15.0 + 70.0 * wave(t, 47.0));
    const cpu_temp: u32 = @intFromFloat(42.0 + 12.0 * wave(t, 61.0));
    const mem: u8 = @intFromFloat(35.0 + 25.0 * wave(t, 83.0));
    const fan: u32 = @intFromFloat(400.0 + 900.0 * wave(t, 53.0));

    renderer.renderCpuLoad(cpu, cpu_temp);
    renderer.renderMemory(mem);
    renderer.renderDiskStats(29, 36);
    renderer.renderFanSpeed(fan);
    renderer.renderIpAddress("192.168.1.231");
    renderer.renderSignalStrength(@as(i32, @intFromFloat(-40.0 - 55.0 * wave(t, 71.0))));

    const days: u32 = @intCast(uptime_s / 86_400);
    const hours: u32 = @intCast(uptime_s / 3600 % 24);
    const minutes: u32 = @intCast(uptime_s / 60 % 60);
    renderer.renderUptime(days, hours, minutes);

    // Sweep several orders of magnitude so every unit shows up.
    const down = parse.scaleBytes(2_000.0 * std.math.pow(f64, 10.0, 5.0 * wave(t, 97.0)));
    const up = parse.scaleBytes(1_000.0 * std.math.pow(f64, 10.0, 4.0 * wave(t, 89.0)));
    renderer.renderTraffic(down.value, down.unit, up.value, up.unit);

    renderer.renderAptUpdates(@intFromFloat(7.0 * wave(t, 131.0)));
    renderer.renderInternetStatus(wave(t, 149.0) > 0.05);
    renderer.setFaultWarning(faultActive(t));
}

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

    var renderer = try Renderer(FakeTransport).init(allocator, io, &transport);
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
            renderFrame(&renderer, @floatFromInt(now), @intCast(now - started));

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
