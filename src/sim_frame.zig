//! Synthetic panel content shared by the simulators.
//!
//! Metrics are smooth functions of time rather than fixed values, so slots walk
//! through their own formatting without anyone driving them: traffic sweeps
//! several orders of magnitude to visit every unit, the signal reading crosses
//! the width where it drops its `dBm` suffix, the fault overlay flares
//! periodically so the inverted status bar can be checked too, a few readings
//! go stale now and then so the faded rendering can, notices of every length
//! come and go so each font step of their layout shows up, and so does the
//! music screen: playing, paused, and asking for its code; with a cover, a
//! poster, or a live stream with no length.

const std = @import("std");
const parse = @import("parse.zig");
const layout = @import("display_config.zig");
const Reading = @import("reading.zig").Reading;
const now_playing = @import("now_playing.zig");
pub const Renderer = @import("display_renderer.zig").Renderer;
const bmp = @import("bmp.zig");

pub const width = layout.display_width;
pub const height = layout.display_height;
/// Row stride of the renderer's packed frame, four greys a byte.
pub const row_bytes = bmp.packedRowBytes(width);

/// Fault overlay on for 6 s out of every 30.
pub fn faultActive(t: f64) bool {
    const phase = @mod(t, 30.0);
    return phase >= 20.0 and phase < 26.0;
}

/// Some readings stale for 6 s out of every 30, clear of the fault window so
/// each can be looked at alone.
pub fn staleActive(t: f64) bool {
    const phase = @mod(t, 30.0);
    return phase >= 8.0 and phase < 14.0;
}

/// `value` as a reading: current, or stale while `stale` holds.
fn reading(comptime T: type, value: T, stale: bool) Reading(T) {
    return if (stale) .staleOf(value) else .of(value);
}

/// Samples from one line up to one too long for the panel, with diacritics
/// the fonts have to draw.
const notice_samples = [_][]const u8{
    "Záloha dokončena",
    "Pračka doprala. Nezapomeň pověsit prádlo.",
    "V 18:00 máš call s týmem, potom vyzvednout balík na poště a cestou koupit mléko.",
    "Tohle je schválně dlouhá zpráva, která se na panel celá nevejde ani nejmenším písmem, " ++
        "takže poslední řádek musí skončit trojtečkou a nic nesmí přetéct přes okraj. " ++
        "Příliš žluťoučký kůň úpěl ďábelské ódy, a pořád ještě není konec, " ++
        "protože tahle věta je tu jen proto, aby se text opravdu nevešel.",
};

/// A notice for 8 s out of every 60, a different sample each time; null for the
/// rest. Starts at 40 s, clear of the first thirty seconds the frame test walks.
pub fn noticeAt(t: f64) ?[]const u8 {
    const phase = @mod(t, 60.0);
    if (phase < 40.0 or phase >= 48.0) return null;
    const round: usize = @intFromFloat(@floor(t / 60.0));
    return notice_samples[round % notice_samples.len];
}

/// Tracks from a title that fits one line of the largest font to one that
/// fits none, with diacritics to draw, and what Kodi plays: an episode beside
/// its poster, and a live stream. Made up.
const music_samples = [_]struct {
    artist: []const u8,
    title: []const u8,
    shape: now_playing.Shape = .square,
    live: bool = false,
}{
    .{ .artist = "Kapela bez jména", .title = "Jednou" },
    .{ .artist = "Žluťoučký kůň, Ďábelské ódy", .title = "Pět hospod, jedna ulice" },
    .{
        .artist = "Orchestr, který má tak dlouhé jméno, že se na řádek nevejde",
        .title = "Píseň, jejíž název je schválně tak dlouhý, že se nevejde ani nejmenším písmem a musí skončit trojtečkou",
    },
    .{ .artist = "Detektiv z Vinohrad S01E06", .title = "Případ skleněné sklenice", .shape = .poster },
    .{ .artist = "", .title = "Narozeninový stream", .live = true },
};

/// A picture to dither, in either shape: a gradient across, and rings,
/// which between them have every grey and edges in every direction.
fn syntheticPicture(comptime shape: now_playing.Shape) [now_playing.cover_len]u8 {
    @setEvalBranchQuota(200_000);
    const w = shape.rect().width;
    const h = shape.rect().height;
    var pixels: [now_playing.cover_len]u8 = @splat(0xFF);
    for (0..h) |y| {
        for (0..w) |x| {
            const dx = @as(i32, @intCast(x)) - w / 2;
            const dy = @as(i32, @intCast(y)) - h / 2;
            const ring = ((dx * dx + dy * dy) / 120) % 2 == 0;
            const ramp = (x + y) * 255 / (w + h - 2);
            pixels[y * w + x] = if (ring) @intCast(ramp) else @intCast(255 - ramp);
        }
    }
    return pixels;
}

const synthetic_cover = syntheticPicture(.square);
const synthetic_poster = syntheticPicture(.poster);

/// The music screen for 12 s out of every 60, clear of the notices, the stale
/// readings and the fault: playing for nine, then paused. Every third time
/// round, the code to link with instead. Null for the rest.
pub fn musicAt(t: f64) ?now_playing.View {
    const phase = @mod(t, 60.0);
    if (phase < 26.0 or phase >= 38.0) return null;
    const round: usize = @intFromFloat(@floor(t / 60.0));
    if (round % 3 == 2) return .{ .pairing = .{ .code = "AB12CD" } };

    // Counted over the rounds that show a track, so every sample comes round.
    const sample = music_samples[(round - round / 3) % music_samples.len];
    const elapsed: u32 = @intFromFloat(@min(phase, 35.0) - 26.0 + 40.0);
    const picture = if (sample.shape == .poster) &synthetic_poster else &synthetic_cover;
    return .{ .track = .{
        .title = sample.title,
        .artist = sample.artist,
        .elapsed_s = elapsed,
        .duration_s = if (sample.live) 0 else 232,
        .playing = phase < 35.0,
        .cover = if (round % 2 == 0) picture else null,
        .shape = sample.shape,
        .live = sample.live,
    } };
}

fn wave(t: f64, period: f64) f64 {
    return @abs(@sin(t * std.math.tau / period));
}

/// Draw one frame's worth of synthetic metrics.
///
/// Leaves the renderer ready for `packedFrame`, which is what applies the fault
/// overlay and packs the frame.
pub fn draw(renderer: *Renderer, t: f64, uptime_s: u64) void {
    // One slot of each size the panel fades a reading in goes stale
    // together: the large digits, the traffic rate and the APT count.
    const stale = staleActive(t);

    renderer.renderCpuLoad(.of(@intFromFloat(15.0 + 70.0 * wave(t, 47.0))));
    renderer.renderCpuTemp(.of(@intFromFloat(42.0 + 12.0 * wave(t, 61.0))));
    renderer.renderMemory(.of(@intFromFloat(35.0 + 25.0 * wave(t, 83.0))));
    renderer.renderDiskUsage(.of(29));
    renderer.renderDiskTemp(reading(u32, 36, stale));
    renderer.renderFanSpeed(.of(@intFromFloat(400.0 + 900.0 * wave(t, 53.0))));
    renderer.renderIpAddress("192.168.1.231");
    renderer.renderSignalStrength(@intFromFloat(-40.0 - 55.0 * wave(t, 71.0)));

    renderer.renderUptime(.{
        .days = @intCast(uptime_s / 86_400),
        .hours = @intCast(uptime_s / 3600 % 24),
        .minutes = @intCast(uptime_s / 60 % 60),
    });

    renderer.renderTraffic(reading(parse.NetRates, .{
        .rx_bytes_per_sec = 2_000.0 * std.math.pow(f64, 10.0, 5.0 * wave(t, 97.0)),
        .tx_bytes_per_sec = 1_000.0 * std.math.pow(f64, 10.0, 4.0 * wave(t, 89.0)),
    }, stale));

    renderer.renderAptUpdates(reading(u32, @intFromFloat(7.0 * wave(t, 131.0)), stale));
    renderer.renderInternetStatus(wave(t, 149.0) > 0.05);
    renderer.setFaultWarning(faultActive(t));

    if (noticeAt(t)) |text| renderer.showNotice(text) else renderer.clearNotice();
    if (musicAt(t)) |view| renderer.showMusic(view) else renderer.clearMusic();
}

/// Expand the renderer's packed frame into 8-bit greyscale, magnified by an
/// integer factor with no interpolation.
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
            // A grey from 0, black, to 3, white; the first pixel highest.
            const shade = (src_row[x / 4] >> @intCast(6 - 2 * (x % 4))) & 0b11;
            @memset(row_out[x * scale ..][0..scale], shade * 85);
        }

        for (1..scale) |dup| {
            const line = (y * scale + dup) * dest_width;
            @memcpy(dest[line..][0..dest_width], row_out);
        }
    }
}

test "successive frames differ" {
    // The window once sat on its first frame for minutes while everything
    // upstream worked: the preview was handing Cocoa an image it had already
    // cached. Nothing catches a frozen window from here, but this does pin the
    // half that is testable — that the content offered up actually varies, so a
    // future change cannot quietly make every frame identical.
    const testing = std.testing;

    var renderer = try Renderer.init(testing.allocator, .{});
    defer renderer.deinit();
    renderer.renderGrid();

    var seen = std.AutoHashMap(u64, void).init(testing.allocator);
    defer seen.deinit();

    var previous: ?u64 = null;
    for (0..30) |t| {
        draw(&renderer, @floatFromInt(t), t);

        const hash = std.hash.Wyhash.hash(0, renderer.packedFrame());
        try seen.put(hash, {});

        // Consecutive seconds must not render identically.
        if (previous) |prev| try testing.expect(hash != prev);
        previous = hash;
    }
    try testing.expectEqual(@as(u32, 30), seen.count());
}

test "the fault overlay is part of the frame it hands over" {
    const testing = std.testing;

    var renderer = try Renderer.init(testing.allocator, .{});
    defer renderer.deinit();
    renderer.renderGrid();

    // A moment inside the fault window and one outside, with the same metrics.
    var quiet: [row_bytes * height]u8 = undefined;
    draw(&renderer, 0, 0);
    renderer.setFaultWarning(false);
    @memcpy(&quiet, renderer.packedFrame());

    renderer.setFaultWarning(true);
    const faulted = renderer.packedFrame();

    try testing.expect(!std.mem.eql(u8, &quiet, faulted));
    // Only the status bar moves: rows above it are untouched.
    const bar_start = 113 * row_bytes;
    try testing.expectEqualSlices(u8, quiet[0..bar_start], faulted[0..bar_start]);
}

test "every notice sample comes round, and the dashboard in between" {
    const testing = std.testing;
    var seen: [notice_samples.len]bool = @splat(false);
    var quiet = false;
    for (0..60 * notice_samples.len) |t| {
        const text = noticeAt(@floatFromInt(t)) orelse {
            quiet = true;
            continue;
        };
        for (notice_samples, 0..) |sample, i| {
            if (sample.ptr == text.ptr) seen[i] = true;
        }
    }
    try testing.expect(quiet);
    for (seen) |s| try testing.expect(s);
}

test "every music sample comes round, paused and playing, and the code to link with too" {
    const testing = std.testing;
    var titles: [music_samples.len]bool = @splat(false);
    var paused = false;
    var pairing = false;
    for (0..60 * 3 * music_samples.len) |t| {
        const view = musicAt(@floatFromInt(t)) orelse continue;
        switch (view) {
            .pairing => pairing = true,
            .track => |track| {
                if (!track.playing) paused = true;
                for (music_samples, 0..) |sample, i| {
                    if (sample.title.ptr == track.title.ptr) titles[i] = true;
                }
            },
        }
        // Never at the same time as a notice or a fault, so each is seen alone.
        try testing.expect(noticeAt(@floatFromInt(t)) == null);
        try testing.expect(!faultActive(@floatFromInt(t)));
    }
    try testing.expect(paused and pairing);
    for (titles) |seen| try testing.expect(seen);
}

test "expand magnifies without smearing neighbouring pixels" {
    const testing = std.testing;
    const scale = 3;

    // A frame with a single black pixel at (1,0) and a dark grey one at
    // (3,0), everything else white.
    var frame: [row_bytes * height]u8 = @splat(0xFF);
    frame[0] = 0b11_00_11_01;

    var out: [width * scale * height * scale]u8 = undefined;
    expand(&frame, &out, scale);

    const dest_width = width * scale;
    // The black pixel becomes a solid 3x3 block at (3..6, 0..3).
    for (0..scale) |dy| {
        for (0..scale) |dx| {
            try testing.expectEqual(@as(u8, 0), out[dy * dest_width + scale + dx]);
        }
    }
    // The grey one is grey.
    try testing.expectEqual(@as(u8, 85), out[3 * scale]);
    // Its neighbours stay white.
    try testing.expectEqual(@as(u8, 255), out[0]);
    try testing.expectEqual(@as(u8, 255), out[scale * 2]);
    try testing.expectEqual(@as(u8, 255), out[scale * dest_width + scale]);
}
