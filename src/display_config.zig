//! Where everything goes on the panel: 296x128 pixels, landscape.
//!
//! Each section of the dashboard keeps its coordinates together, in the terms
//! the renderer draws in: a heading, the icons that never change, and a slot
//! for each reading. The y of a piece of text is its baseline.
//!
//! The numbers are tuned by eye against the fonts in `font_data.zig`, and the
//! golden frame in `display_renderer.zig` pins every one of them: after moving
//! anything, look at `zig build sim` and then regenerate it.

const std = @import("std");
const Bitmap = @import("graphics.zig").Bitmap;
const FontType = Bitmap.FontType;

pub const display_width = 296;
pub const display_height = 128;

/// Draw a frame around the area each slot clears, to see what it covers.
pub const debug_text_areas = false;

pub const Point = struct { x: i32, y: i32 };

pub const Rect = struct {
    x: i32,
    y: i32,
    width: u32,
    height: u32,

    /// The first column past the right edge.
    pub fn right(self: Rect) i32 {
        return self.x + @as(i32, @intCast(self.width));
    }

    /// The first row below the bottom edge.
    pub fn bottom(self: Rect) i32 {
        return self.y + @as(i32, @intCast(self.height));
    }
};

/// A straight line, both ends included.
pub const Line = struct { from: Point, to: Point };

/// A glyph of the icon font at a fixed place.
pub const Icon = struct {
    glyph: []const u8,
    at: Point,
    font: FontType = .material24,
};

/// A section's heading: its name, and a rule running on from it.
pub const Header = struct {
    label: []const u8,
    at: Point,
    rule: Line,
};

/// How far above a heading's baseline its rule is drawn.
const rule_rise = 4;

/// The heading `label` at `x` on `baseline`, ruled from `rule_from` to `rule_to`.
fn heading(label: []const u8, x: i32, baseline: i32, rule_from: i32, rule_to: i32) Header {
    const rule_y = baseline - rule_rise;
    return .{
        .label = label,
        .at = .{ .x = x, .y = baseline },
        .rule = .{ .from = .{ .x = rule_from, .y = rule_y }, .to = .{ .x = rule_to, .y = rule_y } },
    };
}

/// Where one reading goes.
pub const Slot = struct {
    /// Cleared before every draw, so a reading leaves nothing of a wider one
    /// before it. Nothing else may be drawn inside it.
    area: Rect,
    /// Left end of the text's baseline.
    text: Point,
    font: FontType,

    /// A slot whose area starts level with the top of its text: the font's
    /// ascent above the baseline.
    fn hung(text: Point, font: FontType, width: u32, height: u32) Slot {
        return .{
            .area = .{ .x = text.x, .y = text.y - Bitmap.fontAscent(font), .width = width, .height = height },
            .text = text,
            .font = font,
        };
    }
};

/// Icon font codepoints, UTF-8 encoded.
pub const glyph = struct {
    pub const cpu = "\u{e30d}";
    pub const temperature = "\u{e1ff}";
    pub const memory = "\u{e322}";
    pub const hard_drive = "\u{f7a4}";
    pub const fan = "\u{f168}";
    pub const network = "\u{e80d}";
    pub const uptime = "\u{e923}";
    pub const download = "\u{f090}";
    pub const upload = "\u{f09b}";
    pub const check = "\u{e8e8}";
    pub const online = "\u{e2bf}";
    pub const offline = "\u{f1ca}";
    pub const wifi_signal = "\u{e63e}";
    pub const wifi_no_signal = "\u{e1da}";
    /// In the signal slot when the machine is on a cable, where a Wi-Fi
    /// reading has nothing to say, and as the splash screens' emblem.
    pub const ethernet = "\u{eb2f}";
};

// ----------------------------------------------------------------------------
// The dashboard
// ----------------------------------------------------------------------------
//
// Three columns over a status bar. The left one holds cpu above mem, the
// middle one disk above fan, and the right one the two traffic rows above apt
// and net side by side.

pub const grid = struct {
    /// Where the column dividers start: level with the top row's rules.
    const top = 7;
    /// The rule that sets the status bar off, and where the dividers end.
    pub const bottom = 110;
    pub const left_divider = 100;
    pub const right_divider = 201;
    /// Between apt and net, from their rule down.
    const net_divider = 249;

    pub const lines = [_]Line{
        .{ .from = .{ .x = left_divider, .y = top }, .to = .{ .x = left_divider, .y = bottom } },
        .{ .from = .{ .x = right_divider, .y = top }, .to = .{ .x = right_divider, .y = bottom } },
        .{ .from = .{ .x = 0, .y = bottom }, .to = .{ .x = display_width - 1, .y = bottom } },
        .{ .from = .{ .x = net_divider, .y = net.header.rule.from.y }, .to = .{ .x = net_divider, .y = bottom } },
    };
};

pub const cpu = struct {
    pub const header = heading("cpu", 1, 11, 26, 99);
    pub const icons = [_]Icon{
        .{ .glyph = glyph.cpu, .at = .{ .x = 3, .y = 37 } },
        .{ .glyph = glyph.temperature, .at = .{ .x = 3, .y = 66 } },
    };
    pub const load: Slot = .{
        .area = .{ .x = 32, .y = 13, .width = 66, .height = 27 },
        .text = .{ .x = 34, .y = 35 },
        .font = .ubuntu26,
    };
    pub const temp: Slot = .{
        .area = .{ .x = 32, .y = 41, .width = 66, .height = 27 },
        .text = .{ .x = 34, .y = 63 },
        .font = .ubuntu26,
    };
};

pub const mem = struct {
    /// Ruled as far as the divider.
    pub const header = heading("mem", 1, 80, 38, grid.left_divider);
    pub const icons = [_]Icon{.{ .glyph = glyph.memory, .at = .{ .x = 3, .y = 105 } }};
    pub const usage: Slot = .{
        .area = .{ .x = 32, .y = 81, .width = 65, .height = 25 },
        .text = .{ .x = 34, .y = 102 },
        .font = .ubuntu26,
    };
};

pub const disk = struct {
    /// Ruled as far as the divider.
    pub const header = heading("disk", 102, 11, 130, grid.right_divider);
    pub const icons = [_]Icon{
        .{ .glyph = glyph.hard_drive, .at = .{ .x = 103, .y = 37 } },
        .{ .glyph = glyph.temperature, .at = .{ .x = 103, .y = 66 } },
    };
    pub const usage: Slot = .{
        .area = .{ .x = 130, .y = 13, .width = 70, .height = 27 },
        .text = .{ .x = 132, .y = 35 },
        .font = .ubuntu26,
    };
    pub const temp: Slot = .{
        .area = .{ .x = 130, .y = 42, .width = 70, .height = 27 },
        .text = .{ .x = 132, .y = 64 },
        .font = .ubuntu26,
    };
};

pub const fan = struct {
    /// The rule stops two pixels short of the unit, as the traffic ones do.
    pub const header = heading("fan", 102, 80, 124, unit_at.x - 2);
    /// "rpm" at the right of the header, as the traffic headers carry their
    /// unit: 26px wide, ending two pixels before the divider at 201.
    pub const unit_at: Point = .{ .x = 173, .y = 80 };
    pub const icons = [_]Icon{.{ .glyph = glyph.fan, .at = .{ .x = 103, .y = 105 } }};
    pub const speed: Slot = .hung(.{ .x = 133, .y = 102 }, .ubuntu24, 60, 27);
};

/// One direction of traffic: the rate in its slot, and the unit it is in up
/// beside the heading.
pub const TrafficRow = struct {
    header: Header,
    icon: Icon,
    value: Slot,
    unit: Slot,
};

// Both of a row's slots run to the right edge of the panel: the value from
// x=233 and the unit from x=263. They used to be declared 75 and 35 wide, which
// claimed 308 and 298 on a 296-pixel panel — fillRect clipped the excess, but
// the numbers were a lie and the text drawn into them was cut off.
pub const traffic = struct {
    pub const down: TrafficRow = .{
        .header = heading("down", 203, 11, 242, 261),
        .icon = .{ .glyph = glyph.download, .at = .{ .x = 208, .y = 35 } },
        .value = .{
            .area = .{ .x = 233, .y = 12, .width = 63, .height = 20 }, // baseline(30) - ascent(18)
            .text = .{ .x = 233, .y = 30 },
            .font = .ubuntu20,
        },
        .unit = .{
            .area = .{ .x = 263, .y = 0, .width = 33, .height = 14 }, // baseline(11) - ascent(11)
            .text = .{ .x = 263, .y = 11 },
            .font = .ubuntu14,
        },
    };
    pub const up: TrafficRow = .{
        .header = heading("up", 203, 45, 222, 261),
        .icon = .{ .glyph = glyph.upload, .at = .{ .x = 208, .y = 70 } },
        .value = .{
            .area = .{ .x = 233, .y = 47, .width = 63, .height = 20 }, // baseline(65) - ascent(18)
            .text = .{ .x = 233, .y = 65 },
            .font = .ubuntu20,
        },
        .unit = .{
            .area = .{ .x = 263, .y = 34, .width = 33, .height = 14 }, // baseline(45) - ascent(11)
            .text = .{ .x = 263, .y = 45 },
            .font = .ubuntu14,
        },
    };
};

pub const apt = struct {
    pub const header = heading("apt", 203, 80, 226, 248);
    /// The count, in this font or a smaller one on the same baseline, or the
    /// tick that stands for none.
    pub const count: Slot = .hung(.{ .x = 214, .y = 105 }, .ubuntu24, 35, 24);
};

pub const net = struct {
    /// Ruled to the right edge of the panel.
    pub const header = heading("net", 250, 80, 272, display_width - 1);
    /// One glyph: whether the internet is reachable.
    pub const status: Slot = .hung(.{ .x = 260, .y = 105 }, .material24, 35, 24);
};

/// The bottom status bar as a whole, inverted to signal a hardware fault.
pub const status_bar: Rect = .{ .x = 0, .y = 113, .width = display_width, .height = display_height - 113 };

// The three slots of the status bar. Their areas start a pixel above the top
// of the text: baseline(125) - ascent(11) - 1 = 113.

pub const ip = struct {
    pub const icon: Icon = .{ .glyph = glyph.network, .at = .{ .x = 0, .y = 127 }, .font = .material14 };
    pub const address: Slot = .{
        .area = .{ .x = 15, .y = 113, .width = 105, .height = 14 },
        .text = .{ .x = 15, .y = 125 },
        .font = .ubuntu14,
    };
};

// The signal reading needs 54px for the common "-40 dBm"; the old 80px slot was
// mostly dead space. Reclaiming it lets uptime show minutes spelled out.
pub const signal = struct {
    /// Covers the icon as well as the reading, since the icon changes with
    /// it: 120 + 75 = 195, leaving a gap before the uptime icon at 197.
    pub const reading: Slot = .{
        .area = .{ .x = 120, .y = 113, .width = 75, .height = 14 },
        .text = .{ .x = 137, .y = 125 },
        .font = .ubuntu14,
    };
    pub const icon_at: Point = .{ .x = 122, .y = 127 };
    /// Room for the reading itself: the area ends at 195, the text starts at 137.
    pub const text_max_width = 58;
};

pub const uptime = struct {
    pub const icon: Icon = .{ .glyph = glyph.uptime, .at = .{ .x = 197, .y = 127 }, .font = .material14 };
    /// Runs to the right edge of the panel: 212 + 84 = 296.
    pub const elapsed: Slot = .{
        .area = .{ .x = 212, .y = 113, .width = 84, .height = 14 },
        .text = .{ .x = 212, .y = 125 },
        .font = .ubuntu14,
    };
};

/// Every heading of the dashboard, drawn once with the grid.
pub const headers = [_]Header{
    cpu.header,          mem.header,        disk.header, fan.header,
    traffic.down.header, traffic.up.header, apt.header,  net.header,
};

/// Every icon that never changes, drawn once with the grid.
pub const icons = cpu.icons ++ mem.icons ++ disk.icons ++ fan.icons ++
    [_]Icon{ traffic.down.icon, traffic.up.icon, ip.icon, uptime.icon };

pub const NamedArea = struct { name: []const u8, area: Rect };

/// The area of every slot there is, named after where it is declared:
/// `cpu.load`, `traffic.down.unit`.
///
/// Found rather than listed. Every `Slot` a section above declares is here,
/// and both of each `TrafficRow`'s, so a slot added to the layout cannot be
/// left out of the tests that hold each one to the panel's edges and to its
/// neighbours, nor of the frames `debug_text_areas` draws.
pub const areas = findAreas();

fn findAreas() []const NamedArea {
    comptime {
        const file = @This();
        var found: []const NamedArea = &.{};

        for (@typeInfo(file).@"struct".decl_names) |section_name| {
            // Itself, which is being worked out here.
            if (std.mem.eql(u8, section_name, "areas")) continue;

            const section = @field(file, section_name);
            if (@TypeOf(section) != type or !isSection(section)) continue;

            for (@typeInfo(section).@"struct".decl_names) |name| {
                const declared = @field(section, name);
                const path = section_name ++ "." ++ name;
                found = found ++ switch (@TypeOf(declared)) {
                    Slot => [_]NamedArea{.{ .name = path, .area = declared.area }},
                    TrafficRow => [_]NamedArea{
                        .{ .name = path ++ ".value", .area = declared.value.area },
                        .{ .name = path ++ ".unit", .area = declared.unit.area },
                    },
                    else => [_]NamedArea{},
                };
            }
        }
        return found;
    }
}

/// A namespace: a struct with declarations and no fields.
fn isSection(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct" => |info| info.field_names.len == 0,
        else => false,
    };
}

// ----------------------------------------------------------------------------
// The other screens
// ----------------------------------------------------------------------------

/// The loading and sleep screens: an emblem, a bar, and two lines of text.
pub const splash = struct {
    pub const emblem: Icon = .{ .glyph = glyph.ethernet, .at = .{ .x = 50, .y = 82 }, .font = .material50 };
    pub const bar: Rect = .{ .x = 124, .y = 15, .width = 3, .height = 95 };
    pub const title_at: Point = .{ .x = 155, .y = 60 };
    pub const subtitle_at: Point = .{ .x = 155, .y = 82 };
};

/// The notice screen: a heading in the style of the dashboard's, and the
/// message below it in the largest font that fits.
pub const notice = struct {
    pub const label = "message";
    pub const label_at: Point = .{ .x = 1, .y = 11 };
    /// The rule runs from this far past the label to the right edge.
    pub const rule_gap = 3;
    pub const rule_y = label_at.y - rule_rise;
    pub const body: Rect = .{ .x = 4, .y = 16, .width = display_width - 2 * 4, .height = display_height - 16 - 2 };
    /// Largest first. Six lines of the smallest is as many as the body holds.
    pub const fonts = [_]FontType{ .ubuntu34, .ubuntu26, .ubuntu20, .ubuntu14 };
    pub const max_lines = 6;
};

/// The music screen: the cover down the left, and beside it who, what, and
/// how far into it.
pub const music = struct {
    /// An album's cover: square, the height of the panel.
    pub const cover: Rect = .{ .x = 0, .y = 0, .width = display_height, .height = display_height };
    /// A film's or a series' poster: two by three, the height of the panel.
    pub const poster: Rect = .{ .x = 0, .y = 0, .width = display_height * 2 / 3, .height = display_height };
    /// The text runs from beside the picture to here.
    pub const right = display_width - 3;

    pub const artist_font: FontType = .ubuntu14;
    pub const title_fonts = [_]FontType{ .ubuntu24, .ubuntu20, .ubuntu14 };
    /// Four lines of the smallest is as many as a column's `title` holds.
    pub const max_title_lines = 4;
    /// Time played at the left end of a column, the length at the right.
    pub const time_baseline = 126;
    pub const time_font: FontType = .ubuntu14;
    /// In place of the length, for what has none: a live stream.
    pub const live_label = "LIVE";

    /// Where the text goes beside a picture.
    pub const Column = struct {
        left: i32,
        width: u32,
        artist_at: Point,
        /// The title, top-aligned in the largest of `title_fonts` that
        /// holds it.
        title: Rect,
        /// The progress bar: an outline, filled from the left as the track
        /// plays.
        bar: Rect,
        /// Two upright bars between the times while paused.
        pause_mark: Rect,
    };

    /// The column beside `picture`, which sits at the panel's left edge.
    pub fn column(picture: Rect) Column {
        const left = picture.right() + 8;
        const width: u32 = @intCast(right - left);
        return .{
            .left = left,
            .width = width,
            .artist_at = .{ .x = left, .y = 14 },
            .title = .{ .x = left, .y = 20, .width = width, .height = 74 },
            .bar = .{ .x = left, .y = 99, .width = width, .height = 9 },
            .pause_mark = .{ .x = left + @as(i32, @intCast(width / 2)) - 4, .y = 114, .width = 9, .height = 11 },
        };
    }
};

/// The screen that asks for the code linking the panel to Spotify: where to
/// go, and the code, large.
pub const pairing = struct {
    pub const label = "spotify";
    pub const label_at: Point = notice.label_at;
    pub const prompt = "Link at spotify.com/pair";
    pub const prompt_at: Point = .{ .x = 4, .y = 42 };
    pub const prompt_font: FontType = .ubuntu20;
    pub const code_at: Point = .{ .x = 4, .y = 88 };
    pub const code_font: FontType = .ubuntu34;
    pub const hint = "Enter this code there";
    pub const hint_at: Point = .{ .x = 4, .y = 120 };
};

// ----------------------------------------------------------------------------
// Text that has to be fitted to a slot
// ----------------------------------------------------------------------------

pub const UptimeBuffers = struct {
    full: [32]u8 = undefined,
    compact: [32]u8 = undefined,
    hours: [32]u8 = undefined,
    days: [32]u8 = undefined,
};

/// Uptime renderings from most to least detailed, for `Bitmap.fitText`.
///
/// The slot runs to the right edge of the panel, so the caller picks the first
/// that fits rather than letting a long string clip mid-glyph.
pub fn uptimeCandidates(buf: *UptimeBuffers, days: u32, hours: u32, minutes: u32) [4][]const u8 {
    // Under a day the day counter is noise: "5h 3m" beats "0d 5h 3m".
    const full = if (days == 0)
        std.mem.print(&buf.full, "{d}h {d}m", .{ hours, minutes }) catch "?"
    else
        std.mem.print(&buf.full, "{d}d {d}h {d}m", .{ days, hours, minutes }) catch "?";

    return .{
        full,
        std.mem.print(&buf.compact, "{d}d {d}:{d:0>2}", .{ days, hours, minutes }) catch "?",
        std.mem.print(&buf.hours, "{d}d {d}h", .{ days, hours }) catch "?",
        std.mem.print(&buf.days, "{d}d", .{days}) catch "?",
    };
}

// ----------------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------------
//
// What the layout promises, checked against the fonts: that every slot is on
// the panel, that none runs into its neighbour, and that the widest thing a
// slot is ever given still fits it.

const testing = std.testing;

fn measure(text: []const u8, font: FontType) !u32 {
    var bmp = try Bitmap.init(testing.allocator, 4, 4);
    defer bmp.deinit();
    return bmp.measureText(text, font);
}

fn fit(candidates: []const []const u8, font: FontType, max_width: u32) ![]const u8 {
    var bmp = try Bitmap.init(testing.allocator, 4, 4);
    defer bmp.deinit();
    return bmp.fitText(candidates, font, max_width);
}

fn areaNamed(name: []const u8) ?Rect {
    for (areas) |named| if (std.mem.eql(u8, named.name, name)) return named.area;
    return null;
}

test "every slot is found, wherever it is declared" {
    // One of each kind of place a slot can be: in a section, in a section
    // that hangs it from its baseline, and inside a traffic row. Were the
    // search to miss one, the tests below would pass by checking nothing.
    try testing.expectEqual(cpu.load.area, areaNamed("cpu.load").?);
    try testing.expectEqual(net.status.area, areaNamed("net.status").?);
    try testing.expectEqual(uptime.elapsed.area, areaNamed("uptime.elapsed").?);
    try testing.expectEqual(traffic.down.value.area, areaNamed("traffic.down.value").?);
    try testing.expectEqual(traffic.up.unit.area, areaNamed("traffic.up.unit").?);

    // And nothing that is not a slot: the notice's body and the splash's bar
    // are rectangles too.
    for (areas) |named| {
        try testing.expect(!std.mem.startsWith(u8, named.name, "notice."));
        try testing.expect(!std.mem.startsWith(u8, named.name, "splash."));
    }
}

test "no slot extends past the panel" {
    // The bug this catches shipped: the traffic slots claimed 308 and 298
    // columns on a 296-pixel panel. fillRect clips, so nothing corrupted memory
    // — the text drawn into them was simply cut off at the edge, which only
    // showed up once a value happened to be wide enough.
    for (areas) |named| {
        const area = named.area;
        if (area.x < 0 or area.y < 0 or area.right() > display_width or area.bottom() > display_height) {
            std.debug.print(
                "\n  '{s}' spans {d}..{d} x {d}..{d}, panel is {d}x{d}\n",
                .{ named.name, area.x, area.right(), area.y, area.bottom(), display_width, display_height },
            );
            return error.SlotOutsidePanel;
        }
    }
}

/// A traffic row's two areas are cleared together before either is drawn, so
/// they alone may overlap: the unit's descenders reach into the value's top.
fn drawnTogether(a: NamedArea, b: NamedArea) bool {
    for ([_][]const u8{ "traffic.down.", "traffic.up." }) |row| {
        if (std.mem.startsWith(u8, a.name, row) and std.mem.startsWith(u8, b.name, row)) return true;
    }
    return false;
}

test "no two slots overlap" {
    // Each clears its own area before drawing, so one overlapping another
    // would erase part of its neighbour's reading every cycle.
    for (areas, 0..) |a, i| {
        for (areas[i + 1 ..]) |b| {
            if (drawnTogether(a, b)) continue;
            const apart = a.area.right() <= b.area.x or b.area.right() <= a.area.x or
                a.area.bottom() <= b.area.y or b.area.bottom() <= a.area.y;
            if (!apart) {
                std.debug.print("\n  '{s}' and '{s}' overlap\n", .{ a.name, b.name });
                return error.SlotsOverlap;
            }
        }
    }
}

test "a slot hung from its baseline starts at the top of its text" {
    try testing.expectEqual(fan.speed.text.y - Bitmap.fontAscent(.ubuntu24), fan.speed.area.y);
    try testing.expectEqual(apt.count.text.y - Bitmap.fontAscent(.ubuntu24), apt.count.area.y);
    try testing.expectEqual(net.status.text.y - Bitmap.fontAscent(.material24), net.status.area.y);
    try testing.expectEqual(fan.speed.text.x, fan.speed.area.x);
}

test "every heading is ruled level, left to right, starting past its label" {
    for (headers) |header| {
        try testing.expectEqual(header.rule.from.y, header.rule.to.y);
        try testing.expect(header.rule.from.x < header.rule.to.x);
        try testing.expect(header.rule.to.x < display_width);

        // The label's advance may end exactly where the rule begins, as
        // "net" does: its last glyph stops short of its own advance.
        const label_end = header.at.x + @as(i32, @intCast(try measure(header.label, .ubuntu14)));
        try testing.expect(label_end <= header.rule.from.x);
    }
}

test "uptime keeps its minutes across realistic values" {
    const slot = uptime.elapsed.area.width;

    for ([_][3]u32{
        .{ 0, 0, 0 },
        .{ 0, 5, 3 },
        .{ 9, 23, 59 },
        .{ 11, 12, 20 }, // was clipped to "11d 12h 20r" on the panel
        .{ 99, 23, 59 },
        .{ 123, 23, 59 },
        .{ 999, 23, 59 },
    }) |v| {
        var buf = UptimeBuffers{};
        const candidates = uptimeCandidates(&buf, v[0], v[1], v[2]);
        const chosen = try fit(&candidates, .ubuntu14, slot);

        try testing.expect(try measure(chosen, .ubuntu14) <= slot);
        // Whichever form is chosen, it must still carry minutes.
        try testing.expect(chosen.ptr == candidates[0].ptr or chosen.ptr == candidates[1].ptr);
    }
}

test "uptime spells out minutes up to 99 days" {
    var buf = UptimeBuffers{};
    const c = uptimeCandidates(&buf, 11, 12, 20);
    try testing.expectEqualStrings("11d 12h 20m", c[0]);
    try testing.expectEqualStrings("11d 12h 20m", try fit(&c, .ubuntu14, uptime.elapsed.area.width));
}

test "uptime falls back to the compact form past 99 days" {
    var buf = UptimeBuffers{};
    const c = uptimeCandidates(&buf, 123, 23, 59);
    try testing.expectEqualStrings("123d 23:59", try fit(&c, .ubuntu14, uptime.elapsed.area.width));
}

test "uptime formats zero days and pads minutes" {
    var buf = UptimeBuffers{};
    try testing.expectEqualStrings("5h 3m", uptimeCandidates(&buf, 0, 5, 3)[0]);
    // Zero-padded so the colon form never reads as "9:5".
    try testing.expectEqualStrings("3d 9:05", uptimeCandidates(&buf, 3, 9, 5)[1]);
}

test "uptime degrades instead of clipping at absurd values" {
    var buf = UptimeBuffers{};
    const slot = uptime.elapsed.area.width;

    // ~27 years still keeps its minutes via the compact form.
    const long = uptimeCandidates(&buf, 9999, 23, 59);
    try testing.expectEqualStrings("9999d 23:59", try fit(&long, .ubuntu14, slot));

    // Past that the ladder drops units rather than clipping.
    const absurd = uptimeCandidates(&buf, 999_999, 23, 59);
    try testing.expect(try measure(try fit(&absurd, .ubuntu14, slot), .ubuntu14) <= slot);
}

test "signal reading fits its slot across the whole dBm range" {
    var s: i32 = -20;
    while (s >= -120) : (s -= 1) {
        var with_unit: [16]u8 = undefined;
        var bare: [16]u8 = undefined;
        const candidates = [_][]const u8{
            try std.mem.print(&with_unit, "{d} dBm", .{s}),
            try std.mem.print(&bare, "{d}", .{s}),
        };
        const chosen = try fit(&candidates, .ubuntu14, signal.text_max_width);
        try testing.expect(try measure(chosen, .ubuntu14) <= signal.text_max_width);
    }

    // Two-digit readings keep the unit; only the three-digit extreme drops it.
    const normal = [_][]const u8{ "-40 dBm", "-40" };
    try testing.expectEqualStrings("-40 dBm", try fit(&normal, .ubuntu14, signal.text_max_width));
}

test "traffic values fit their slot across the whole range" {
    const parse = @import("parse.zig");
    const slot = traffic.down.value.area.width;
    try testing.expectEqual(slot, traffic.up.value.area.width);

    // Step through rates spanning every unit, including the 1000..1023 window
    // that used to clip with a 1024 divisor.
    var rate: f64 = 0;
    while (rate < 2_000_000_000) : (rate = rate * 1.7 + 13) {
        const scaled = parse.scaleBytes(rate);

        var buf: [32]u8 = undefined;
        const text = try std.mem.print(&buf, "{d:.2}", .{scaled.value});
        try testing.expect(try measure(text, traffic.down.value.font) <= slot);

        var unit_buf: [32]u8 = undefined;
        const unit = try std.mem.print(&unit_buf, "{s}/s", .{scaled.unit});
        try testing.expect(try measure(unit, traffic.down.unit.font) <= traffic.down.unit.area.width);
    }
}

test "the traffic slots stay clear of their icons, right of the divider" {
    for ([_]TrafficRow{ traffic.down, traffic.up }) |row| {
        const icon_end = row.icon.at.x + @as(i32, @intCast(try measure(row.icon.glyph, row.icon.font)));
        try testing.expect(icon_end <= row.value.area.x);
        try testing.expect(row.icon.at.x > grid.right_divider);
    }
}

test "the fan slot ends before the divider" {
    try testing.expect(fan.speed.area.right() <= grid.right_divider);
}

test "the fan header fits its label, rule and unit" {
    const unit_end = fan.unit_at.x + @as(i32, @intCast(try measure("rpm", .ubuntu14)));

    try testing.expect(fan.header.rule.to.x < fan.unit_at.x);
    try testing.expect(unit_end < grid.right_divider);
}

test "status bar slots do not overlap or run off the panel" {
    try testing.expect(ip.address.area.right() <= signal.reading.area.x);
    try testing.expect(signal.reading.area.right() <= uptime.icon.at.x);
    try testing.expectEqual(@as(i32, display_width), uptime.elapsed.area.right());

    // The signal icon and reading sit inside the area that clears them.
    try testing.expect(signal.icon_at.x >= signal.reading.area.x);
    try testing.expect(signal.reading.text.x + signal.text_max_width <= signal.reading.area.right());
    // The widest IPv4 address must still fit.
    try testing.expect(try measure("255.255.255.255", .ubuntu14) <= ip.address.area.width);

    // And all three lie within the bar a fault inverts.
    for ([_]Rect{ ip.address.area, signal.reading.area, uptime.elapsed.area }) |area| {
        try testing.expect(area.y >= status_bar.y and area.bottom() <= status_bar.y + @as(i32, status_bar.height));
    }
}

test "the notice body holds as many lines of the smallest font as it promises" {
    var bmp = try Bitmap.init(testing.allocator, 4, 4);
    defer bmp.deinit();

    const smallest = notice.fonts[notice.fonts.len - 1];
    try testing.expectEqual(@as(u32, notice.max_lines), notice.body.height / bmp.getLineHeight(smallest));
    try testing.expect(notice.body.right() <= display_width and notice.body.bottom() <= display_height);
}

test "the music screen's title box holds as many lines of the smallest font as it promises" {
    var bmp = try Bitmap.init(testing.allocator, 4, 4);
    defer bmp.deinit();

    const smallest = music.title_fonts[music.title_fonts.len - 1];
    for ([_]Rect{ music.cover, music.poster }) |picture| {
        const title = music.column(picture).title;
        try testing.expectEqual(@as(u32, music.max_title_lines), title.height / bmp.getLineHeight(smallest));
    }
}

test "everything on the music screen stays on the panel, right of the picture, one part above the next" {
    var bmp = try Bitmap.init(testing.allocator, 4, 4);
    defer bmp.deinit();

    const m = music;
    try testing.expect(m.right <= display_width);
    // A poster has the panel's height, and the shape of one: two by three
    // to within a pixel.
    try testing.expectEqual(display_height, m.poster.height);
    try testing.expect(@abs(@as(i32, @intCast(m.poster.width * 3)) - @as(i32, @intCast(m.poster.height * 2))) < 3);

    for ([_]Rect{ m.cover, m.poster }) |picture| {
        const c = m.column(picture);
        try testing.expect(picture.right() <= c.left);
        // The artist's line ends above the title, the title above the bar,
        // and the bar above the times and the pause mark.
        const below_baseline = @as(i32, @intCast(bmp.getLineHeight(m.artist_font))) - Bitmap.fontAscent(m.artist_font);
        try testing.expect(c.artist_at.y + below_baseline <= c.title.y);
        try testing.expect(c.title.bottom() <= c.bar.y);
        try testing.expect(c.bar.bottom() < m.time_baseline - Bitmap.fontAscent(m.time_font) + 3);
        try testing.expect(c.bar.bottom() <= c.pause_mark.y);
        try testing.expect(c.pause_mark.bottom() <= display_height);
        try testing.expect(m.time_baseline <= display_height);
        // A time as long as a film's on the left and the live mark on the
        // right each fit their side of the pause mark.
        try testing.expect(c.left + @as(i32, @intCast(bmp.measureText("2:59:59", m.time_font))) < c.pause_mark.x);
        try testing.expect(c.pause_mark.right() + @as(i32, @intCast(bmp.measureText(m.live_label, m.time_font))) < m.right);
    }
}

test "the pairing screen's lines fit across the panel" {
    var bmp = try Bitmap.init(testing.allocator, 4, 4);
    defer bmp.deinit();

    const p = pairing;
    try testing.expect(p.prompt_at.x + @as(i32, @intCast(bmp.measureText(p.prompt, p.prompt_font))) <= display_width);
    try testing.expect(p.hint_at.x + @as(i32, @intCast(bmp.measureText(p.hint, .ubuntu14))) <= display_width);
    // A code as Spotify gives one: six letters and digits, the widest.
    try testing.expect(p.code_at.x + @as(i32, @intCast(bmp.measureText("WWWWWW", p.code_font))) <= display_width);
}
