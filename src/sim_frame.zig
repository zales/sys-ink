//! Synthetic panel content shared by the simulators.
//!
//! Metrics are smooth functions of time rather than fixed values, so slots walk
//! through their own formatting without anyone driving them: traffic sweeps
//! several orders of magnitude to visit every unit, the signal reading crosses
//! the width where it drops its `dBm` suffix, and the fault overlay flares
//! periodically so the inverted status bar can be checked too.

const std = @import("std");
const parse = @import("parse.zig");
const display_config = @import("display_config.zig");
const Renderer = @import("display_renderer.zig").Renderer;
const FakeTransport = @import("waveshare_epd/fake_transport.zig").FakeTransport;

/// The renderer as the simulators use it: the real one, on a recorder.
pub const SimRenderer = Renderer(FakeTransport);

pub const width = display_config.DISPLAY_WIDTH;
pub const height = display_config.DISPLAY_HEIGHT;
/// Row stride of the renderer's 1-bit frame, matching `packBmpBuffer`.
pub const row_bytes = (width + 7) / 8;

/// Fault overlay on for 6 s out of every 30.
pub fn faultActive(t: f64) bool {
    const phase = @mod(t, 30.0);
    return phase >= 20.0 and phase < 26.0;
}

fn wave(t: f64, period: f64) f64 {
    return @abs(@sin(t * std.math.tau / period));
}

/// Draw one frame's worth of synthetic metrics.
///
/// Leaves the renderer ready for `updateDisplay`, which is what applies the
/// fault overlay and packs the frame.
pub fn draw(renderer: *SimRenderer, t: f64, uptime_s: u64) void {
    renderer.renderCpuLoad(
        @intFromFloat(15.0 + 70.0 * wave(t, 47.0)),
        @intFromFloat(42.0 + 12.0 * wave(t, 61.0)),
    );
    renderer.renderMemory(@intFromFloat(35.0 + 25.0 * wave(t, 83.0)));
    renderer.renderDiskStats(29, 36);
    renderer.renderFanSpeed(@intFromFloat(400.0 + 900.0 * wave(t, 53.0)));
    renderer.renderIpAddress("192.168.1.231");
    renderer.renderSignalStrength(@intFromFloat(-40.0 - 55.0 * wave(t, 71.0)));

    renderer.renderUptime(
        @intCast(uptime_s / 86_400),
        @intCast(uptime_s / 3600 % 24),
        @intCast(uptime_s / 60 % 60),
    );

    const down = parse.scaleBytes(2_000.0 * std.math.pow(f64, 10.0, 5.0 * wave(t, 97.0)));
    const up = parse.scaleBytes(1_000.0 * std.math.pow(f64, 10.0, 4.0 * wave(t, 89.0)));
    renderer.renderTraffic(down.value, down.unit, up.value, up.unit);

    renderer.renderAptUpdates(@intFromFloat(7.0 * wave(t, 131.0)));
    renderer.renderInternetStatus(wave(t, 149.0) > 0.05);
    renderer.setFaultWarning(faultActive(t));
}

/// Expand the renderer's packed 1-bit frame into 8-bit greyscale, magnified by
/// an integer factor with no interpolation.
///
/// `dest` must hold `width * scale * height * scale` bytes. Scaling here rather
/// than in the window keeps pixel edges hard, which is the point of previewing
/// a 296x128 panel on a high-density display.
pub fn expand(packed_frame: []const u8, dest: []u8, comptime scale: u32) void {
    const dest_width = width * scale;
    std.debug.assert(dest.len >= dest_width * height * scale);

    for (0..height) |y| {
        const src_row = packed_frame[y * row_bytes ..][0..row_bytes];

        // Build one magnified row, then replicate it `scale` times.
        const first = (y * scale) * dest_width;
        const row_out = dest[first..][0..dest_width];
        for (0..width) |x| {
            // 1 = white, MSB first.
            const on = (src_row[x >> 3] >> @intCast(7 - (x & 7))) & 1 == 1;
            @memset(row_out[x * scale ..][0..scale], if (on) 255 else 0);
        }

        for (1..scale) |dup| {
            const line = (y * scale + dup) * dest_width;
            @memcpy(dest[line..][0..dest_width], row_out);
        }
    }
}

test "expand magnifies without smearing neighbouring pixels" {
    const testing = std.testing;
    const scale = 3;

    // A frame with a single black pixel at (1,0), everything else white.
    var frame: [row_bytes * height]u8 = @splat(0xFF);
    frame[0] = 0b1011_1111;

    var out: [width * scale * height * scale]u8 = undefined;
    expand(&frame, &out, scale);

    const dest_width = width * scale;
    // The black pixel becomes a solid 3x3 block at (3..6, 0..3).
    for (0..scale) |dy| {
        for (0..scale) |dx| {
            try testing.expectEqual(@as(u8, 0), out[dy * dest_width + scale + dx]);
        }
    }
    // Its neighbours stay white.
    try testing.expectEqual(@as(u8, 255), out[0]);
    try testing.expectEqual(@as(u8, 255), out[scale * 2]);
    try testing.expectEqual(@as(u8, 255), out[scale * dest_width + scale]);
}
