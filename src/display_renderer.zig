const std = @import("std");
const Frame = @import("waveshare_epd/epd2in9.zig").Frame;
const layout = @import("display_config.zig");
const Thresholds = @import("config.zig").Thresholds;
const parse = @import("parse.zig");
const Reading = @import("reading.zig").Reading;
const Graphics = @import("graphics.zig");
const Bitmap = Graphics.Bitmap;
const FontType = Graphics.Bitmap.FontType;
const notice_text = @import("notice.zig");

/// Bytes per hardware row after the 90° rotation.
const hw_bytes_per_row = layout.display_height / 8;

comptime {
    // The rotation below packs a whole hardware row from one logical column.
    std.debug.assert(layout.display_height % 8 == 0);
    // Ties the layout constants to the driver: a mismatch would otherwise only
    // show up as a corrupted panel.
    std.debug.assert(@sizeOf(Frame) == hw_bytes_per_row * layout.display_width);
}

/// Draws what the panel shows and hands it over as a frame.
///
/// It knows nothing of the panel beyond the format of that frame: no transport
/// and no I/O. Getting the frame onto the glass is `panel.zig`'s business, which
/// is what lets the tests, the golden frame and the simulators run this on any
/// host with nothing standing in for the hardware.
///
/// Where things go is `display_config.zig`'s business, imported as `layout`:
/// this file says what is drawn and in which order, in the layout's own terms.
pub const Renderer = struct {
    const Self = @This();

    pub const Options = struct {
        /// Readings at or above these are drawn inverted.
        thresholds: Thresholds = .{},
    };

    bitmap: Bitmap,
    /// The notice screen, drawn apart from the dashboard so that the
    /// dashboard's slots keep updating underneath it and reappear intact
    /// once it is dismissed.
    notice: Bitmap,
    /// Whether the panel shows `notice` rather than `bitmap`.
    notice_shown: bool = false,
    /// The frame as `panelFrame` hands it over: 128x296 portrait, 4736 bytes.
    panel_buffer: *Frame,
    /// The frame as `packedFrame` hands it over. Both are kept around so
    /// that producing a frame does not allocate.
    bmp_buffer: []u8,
    thresholds: Thresholds,
    /// Draws the status bar inverted, signalling a hardware fault. Driven by the
    /// daemon as the OR of every fault source (under-voltage, NVMe SMART), so
    /// the bar clears only when all of them have.
    warn_fault: bool = false,
    allocator: std.mem.Allocator,
    grid_cached: bool = false,

    pub fn init(allocator: std.mem.Allocator, options: Options) !Self {
        var bitmap = try Bitmap.init(allocator, layout.display_width, layout.display_height);
        errdefer bitmap.deinit();
        var notice = try Bitmap.init(allocator, layout.display_width, layout.display_height);
        errdefer notice.deinit();

        const panel_buffer = try allocator.create(Frame);
        errdefer allocator.destroy(panel_buffer);

        const bmp_row_bytes = @divCeil(layout.display_width, 8);
        const bmp_buffer = try allocator.alloc(u8, bmp_row_bytes * layout.display_height);

        return .{
            .bitmap = bitmap,
            .notice = notice,
            .panel_buffer = panel_buffer,
            .bmp_buffer = bmp_buffer,
            .thresholds = options.thresholds,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.bitmap.deinit();
        self.notice.deinit();
        self.allocator.free(self.bmp_buffer);
        self.allocator.destroy(self.panel_buffer);
    }

    // ------------------------------------------------------------------------
    // Drawing on the dashboard, in the layout's terms
    // ------------------------------------------------------------------------

    fn drawText(self: *Self, at: layout.Point, text: []const u8, font: FontType) void {
        self.bitmap.drawTextFont(at.x, at.y, text, font, .black);
    }

    fn drawIcon(self: *Self, icon: layout.Icon) void {
        self.drawText(icon.at, icon.glyph, icon.font);
    }

    fn drawRule(self: *Self, rule: layout.Line) void {
        self.bitmap.drawLine(rule.from.x, rule.from.y, rule.to.x, rule.to.y, .black);
    }

    fn clearArea(self: *Self, area: layout.Rect) void {
        self.bitmap.fillRect(area.x, area.y, area.width, area.height, .white);
    }

    /// Replace what `slot` shows with `text`, in the slot's own font.
    fn fillSlot(self: *Self, slot: layout.Slot, text: []const u8) void {
        self.clearArea(slot.area);
        self.drawText(slot.text, text, slot.font);
    }

    fn fadeArea(self: *Self, area: layout.Rect) void {
        self.bitmap.fadeRect(area.x, area.y, area.width, area.height);
    }

    /// How a reading is marked, besides what it says.
    const Marks = struct {
        /// At or over its threshold: the whole slot is inverted.
        critical: bool = false,
        /// The latest attempt to take it failed: the slot is faded.
        stale: bool = false,
    };

    /// As `fillSlot`, marked as `marks` says.
    fn fillReading(self: *Self, slot: layout.Slot, text: []const u8, marks: Marks) void {
        self.fillSlot(slot, text);
        // Before the inversion, so a critical value that has gone stale is
        // faded white-on-black rather than having its background eaten into.
        if (marks.stale) self.fadeArea(slot.area);
        if (marks.critical) self.bitmap.invertRect(slot.area.x, slot.area.y, slot.area.width, slot.area.height);
    }

    /// What a slot says: the value through `fmt`, or a dash where there is
    /// none — "0%" for a reading nobody took would claim one.
    fn slotText(buf: []u8, comptime fmt: []const u8, value: anytype) []const u8 {
        const known = value orelse return "-";
        return std.mem.print(buf, fmt, .{known}) catch "?";
    }

    /// A reading that has a threshold, in its slot: inverted at or over it,
    /// for as long as the last value known is.
    fn renderGauge(self: *Self, slot: layout.Slot, comptime fmt: []const u8, reading: anytype, threshold: u8) void {
        var buf: [16]u8 = undefined;
        self.fillReading(slot, slotText(&buf, fmt, reading.value), .{
            .critical = if (reading.value) |value| value >= threshold else false,
            .stale = reading.isStale(),
        });
    }

    // ------------------------------------------------------------------------
    // Whole screens
    // ------------------------------------------------------------------------

    /// Draw the transient loading screen, shown while metrics initialize.
    pub fn drawLoadingScreen(self: *Self) void {
        self.drawSplash("Loading...", .white);
    }

    /// Draw the sleep screen, the last thing the panel shows.
    pub fn drawSleepScreen(self: *Self) void {
        self.drawSplash("Sleeping...", .black);
    }

    /// Draw the full-screen splash used by the loading and sleep screens.
    /// `background` is the page colour; text and rules are drawn inverted to it.
    ///
    /// A splash takes over the whole screen. It comes up in place of a
    /// notice, and it has no status bar, so the fault warning is dropped
    /// along with it; the daemon sets that again with its next reading.
    fn drawSplash(self: *Self, subtitle: []const u8, background: Graphics.Color) void {
        const ink: Graphics.Color = if (background == .white) .black else .white;
        const splash = layout.splash;
        const b = &self.bitmap;

        self.notice_shown = false;
        self.warn_fault = false;

        b.clear(background);
        b.fillRect(splash.bar.x, splash.bar.y, splash.bar.width, splash.bar.height, ink);
        b.drawTextFont(splash.emblem.at.x, splash.emblem.at.y, splash.emblem.glyph, splash.emblem.font, ink);
        b.drawTextFont(splash.title_at.x, splash.title_at.y, "SysInk", .ubuntu34, ink);
        b.drawTextFont(splash.subtitle_at.x, splash.subtitle_at.y, subtitle, .ubuntu14, ink);
    }

    /// Draw everything on the dashboard that never changes: the dividers, the
    /// headings and the fixed icons.
    pub fn renderGrid(self: *Self) void {
        if (self.grid_cached) return;

        self.bitmap.clear(.white);

        for (layout.grid.lines) |divider| self.drawRule(divider);
        for (layout.headers) |header| {
            self.drawText(header.at, header.label, .ubuntu14);
            self.drawRule(header.rule);
        }
        for (layout.icons) |icon| self.drawIcon(icon);

        self.grid_cached = true;
    }

    /// Show or clear the hardware-fault warning: the status bar is drawn inverted.
    pub fn setFaultWarning(self: *Self, active: bool) void {
        self.warn_fault = active;
    }

    /// Put a notice on the panel in place of the dashboard, from the next
    /// update until `clearNotice`.
    ///
    /// The fonts cover ASCII only, so the text is folded to it first, and it
    /// is set in the largest font it fits. What does not fit even the
    /// smallest is cut off with an ellipsis.
    pub fn showNotice(self: *Self, text: []const u8) void {
        const b = &self.notice;
        const page = layout.notice;
        b.clear(.white);

        b.drawTextFont(page.label_at.x, page.label_at.y, page.label, .ubuntu14, .black);
        const label_width: i32 = @intCast(b.measureText(page.label, .ubuntu14));
        const rule_x = page.label_at.x + label_width + page.rule_gap;
        b.drawLine(rule_x, page.rule_y, layout.display_width - 1, page.rule_y, .black);

        var folded_buf: [notice_text.max_len]u8 = undefined;
        const folded = notice_text.foldToAscii(&folded_buf, text);

        var lines: [page.max_lines][]const u8 = undefined;
        var last_buf: [notice_text.max_len + 3]u8 = undefined;
        const fitted = self.layoutNotice(folded, &lines, &last_buf);

        // The block is centred vertically in the body, left-aligned.
        const line_h = b.getLineHeight(fitted.font);
        const block_h = line_h * @as(u32, @intCast(fitted.count));
        var baseline: i32 = page.body.y +
            @as(i32, @intCast((page.body.height - block_h) / 2)) +
            Bitmap.fontAscent(fitted.font);

        for (lines[0..fitted.count]) |line| {
            b.drawTextFont(page.body.x, baseline, line, fitted.font, .black);
            baseline += @intCast(line_h);
        }

        self.notice_shown = true;
    }

    /// Go back to the dashboard.
    pub fn clearNotice(self: *Self) void {
        self.notice_shown = false;
    }

    const NoticeLayout = struct {
        font: FontType,
        count: usize,
    };

    /// Wrap `text` into `lines` in the largest notice font that holds all of
    /// it. Failing that, the smallest font's lines as far as they go, the last
    /// rebuilt in `last_buf` to end in an ellipsis.
    fn layoutNotice(
        self: *Self,
        text: []const u8,
        lines: *[layout.notice.max_lines][]const u8,
        last_buf: []u8,
    ) NoticeLayout {
        const b = &self.notice;
        const body = layout.notice.body;
        const fonts = layout.notice.fonts;

        var max: usize = 0;
        for (fonts) |font| {
            max = @min(lines.len, body.height / b.getLineHeight(font));
            const needed = b.wrapText(text, font, body.width, lines[0..max]);
            if (needed <= max) return .{ .font = font, .count = needed };
        }

        // The loop left the smallest font's lines in place.
        const font = fonts[fonts.len - 1];
        const ellipsis = "...";

        var last = lines[max - 1];
        while (true) {
            last = std.mem.trimEnd(u8, last, " ");
            if (last.len == 0 or b.measureText(last, font) + b.measureText(ellipsis, font) <= body.width) break;
            // A whole codepoint at a time: the degree sign survives folding
            // and is two bytes, and half of it would eat the ellipsis.
            var cut = last.len - 1;
            while (cut > 0 and last[cut] & 0xC0 == 0x80) cut -= 1;
            last = last[0..cut];
        }
        @memcpy(last_buf[0..last.len], last);
        @memcpy(last_buf[last.len..][0..ellipsis.len], ellipsis);
        lines[max - 1] = last_buf[0 .. last.len + ellipsis.len];

        return .{ .font = font, .count = max };
    }

    // ------------------------------------------------------------------------
    // Handing the frame over
    // ------------------------------------------------------------------------

    /// What the panel shows: the notice while there is one, else the dashboard.
    fn frameBitmap(self: *Self) *Bitmap {
        return if (self.notice_shown) &self.notice else &self.bitmap;
    }

    /// On whatever is shown: a notice can stay up for a day, and a hardware
    /// fault must not wait that long to be seen.
    fn invertStatusBar(self: *Self) void {
        const bar = layout.status_bar;
        self.frameBitmap().invertRect(bar.x, bar.y, bar.width, bar.height);
    }

    /// Toggle the fault overlay on the frame being shown. Its own inverse, so a
    /// paired call restores it.
    ///
    /// Not drawn into the layout, because the status bar's three slots are each
    /// redrawn by their own scheduled task and any of them would erase part of it.
    /// Call it around everything that reads the bitmap — the panel's frame and
    /// the unrotated one both — or the preview disagrees with the glass.
    fn toggleFaultOverlay(self: *Self) void {
        if (self.warn_fault) self.invertStatusBar();
    }

    /// The current frame in the panel's own format, fault overlay included:
    /// rotated 90° and packed to 1 bit. Borrowed: valid until the next call.
    pub fn panelFrame(self: *Self) *const Frame {
        if (layout.debug_text_areas) self.drawTextAreaFrames();

        self.toggleFaultOverlay();
        defer self.toggleFaultOverlay();

        self.convertTo1Bit(self.panel_buffer);
        return self.panel_buffer;
    }

    /// The same frame the right way up, for whoever shows it rather than
    /// sending it to the panel: the web preview, the BMP export and the
    /// simulators. Borrowed: valid until the next call.
    pub fn packedFrame(self: *Self) []const u8 {
        if (layout.debug_text_areas) self.drawTextAreaFrames();

        self.toggleFaultOverlay();
        defer self.toggleFaultOverlay();

        self.packBmpBuffer();
        return self.bmp_buffer;
    }

    fn drawTextAreaFrames(self: *Self) void {
        for (layout.areas) |named| {
            const area = named.area;
            self.bitmap.drawRect(area.x, area.y, area.width, area.height, .black);
        }
    }

    /// Convert the 8-bit bitmap to the panel's 1-bit packed format, rotating 90°
    /// clockwise. One hardware row comes from one logical column, so each output
    /// byte is assembled in a register and stored once.
    fn convertTo1Bit(self: *Self, output: *Frame) void {
        // One hardware row is packed from one logical column, so the panel's
        // short side has to be exactly the bitmap's height. `output` carries its
        // own length in its type.
        const src = self.frameBitmap();
        std.debug.assert(src.height == hw_bytes_per_row * 8);

        const width = src.width;

        var hw_y: u32 = 0;
        while (hw_y < width) : (hw_y += 1) {
            const src_x = (width - 1) - hw_y;
            const row = output[hw_y * hw_bytes_per_row ..][0..hw_bytes_per_row];

            for (row, 0..) |*out_byte, byte_idx| {
                // 1 = white, 0 = black, MSB first.
                var bits: u8 = 0;
                for (0..8) |b| {
                    const src_y = byte_idx * 8 + b;
                    if (src.data[src_y * src.stride + src_x] >= 128) {
                        bits |= @as(u8, 0x80) >> @intCast(b);
                    }
                }
                out_byte.* = bits;
            }
        }
    }

    /// Pack the bitmap into `bmp_buffer`, unrotated, 1 bit per pixel.
    fn packBmpBuffer(self: *Self) void {
        const src = self.frameBitmap();
        const width = src.width;
        const height = src.height;
        const row_bytes = @divCeil(width, 8);

        // Pack to 1-bit without rotation, into the preallocated scratch buffer.
        var y: u32 = 0;
        while (y < height) : (y += 1) {
            const src_row = src.data[y * src.stride ..][0..width];
            const dst_row = self.bmp_buffer[y * row_bytes ..][0..row_bytes];

            for (dst_row, 0..) |*out_byte, byte_idx| {
                var bits: u8 = 0;
                for (0..8) |b| {
                    const x = byte_idx * 8 + b;
                    if (x >= width or src_row[x] >= 128) {
                        bits |= @as(u8, 0x80) >> @intCast(b);
                    }
                }
                out_byte.* = bits;
            }
        }
    }

    // ------------------------------------------------------------------------
    // Readings
    // ------------------------------------------------------------------------
    //
    // Each reading has a slot of its own, drawn by its own call, so a sensor
    // that fails leaves only its own slot stale. Load and temperature used to
    // be drawn together, and a machine without a thermal zone never showed its
    // load at all.
    //
    // A slot is drawn from the reading rather than from a bare value, so it
    // can show which of three things it has: a current value as it always
    // was, a stale one — the last value, when the latest attempt to take it
    // failed — faded, and no value at all as a dash. A slot whose reading
    // failed used to keep what it showed, indistinguishable from a live one.

    /// Render CPU load
    pub fn renderCpuLoad(self: *Self, load: Reading(u8)) void {
        self.renderGauge(layout.cpu.load, "{d}%", load, self.thresholds.cpu);
    }

    /// Render CPU temperature
    pub fn renderCpuTemp(self: *Self, temp: Reading(u32)) void {
        self.renderGauge(layout.cpu.temp, "{d}°C", temp, self.thresholds.temp);
    }

    /// Render memory usage
    pub fn renderMemory(self: *Self, usage: Reading(u8)) void {
        self.renderGauge(layout.mem.usage, "{d}%", usage, self.thresholds.mem);
    }

    /// Render root filesystem usage
    pub fn renderDiskUsage(self: *Self, usage: Reading(u8)) void {
        self.renderGauge(layout.disk.usage, "{d}%", usage, self.thresholds.disk);
    }

    /// Render disk temperature. Unavailable means the hardware has no sensor,
    /// shown as a dash: "0°C" claimed a reading nobody took.
    pub fn renderDiskTemp(self: *Self, temp: Reading(u32)) void {
        self.renderGauge(layout.disk.temp, "{d}°C", temp, self.thresholds.temp);
    }

    /// Render fan speed. Unavailable means there is no fan, shown as a dash;
    /// a fan that is present and stopped still reads 0. The unit is in the
    /// header.
    pub fn renderFanSpeed(self: *Self, rpm: Reading(u32)) void {
        var buf: [16]u8 = undefined;
        self.fillSlot(layout.fan.speed, slotText(&buf, "{d}", rpm.value));
        // Before the unit goes on: it is a label, and no less true for the
        // reading under it being old.
        if (rpm.isStale()) self.fadeArea(layout.fan.speed.area);

        // The unit sits in the header, as it does for traffic, and is drawn
        // here rather than with the grid for the same reason traffic's is:
        // the "p" descends into the value's clear area, which erases it.
        self.drawText(layout.fan.unit_at, "rpm", .ubuntu14);
    }

    /// Render IP address
    pub fn renderIpAddress(self: *Self, ip: []const u8) void {
        self.fillSlot(layout.ip.address, if (ip.len > 15) ip[0..15] else ip);
    }

    /// Render uptime.
    ///
    /// The slot runs to the right edge of the panel, where overflow is clipped
    /// mid-glyph, so pick the most detailed form that fits its 84px:
    /// "11d 12h 20m" (83px) up to 99 days, then the compact "123d 23:59" (70px),
    /// which still carries minutes. Only truly absurd uptimes lose them.
    ///
    /// Null, an uptime that could not be read, is a dash. There is no stale
    /// form: the status bar's small print does not survive being faded, and an
    /// uptime that has stopped counting would only be a wrong one.
    pub fn renderUptime(self: *Self, uptime: ?parse.Uptime) void {
        const slot = layout.uptime.elapsed;
        const known = uptime orelse return self.fillSlot(slot, "-");

        var buf = layout.UptimeBuffers{};
        const candidates = layout.uptimeCandidates(&buf, known.days, known.hours, known.minutes);
        self.fillSlot(slot, self.bitmap.fitText(&candidates, slot.font, slot.area.width));
    }

    /// Render signal strength.
    ///
    /// "-40 dBm" fits; the three-digit "-100 dBm" does not, so the unit is
    /// dropped at that end of the range rather than clipping the number. -100
    /// dBm is effectively no signal, where the exact unit matters least.
    pub fn renderSignalStrength(self: *Self, signal: ?i32) void {
        var with_unit: [16]u8 = undefined;
        var bare: [16]u8 = undefined;

        const known = signal orelse return self.fillSignalSlot(layout.glyph.wifi_no_signal, "N/A");
        const candidates = [_][]const u8{
            std.mem.print(&with_unit, "{d} dBm", .{known}) catch "?",
            std.mem.print(&bare, "{d}", .{known}) catch "?",
        };
        const text = self.bitmap.fitText(&candidates, layout.signal.reading.font, layout.signal.text_max_width);
        self.fillSignalSlot(layout.glyph.wifi_signal, text);
    }

    /// Show the machine as wired in the signal slot.
    ///
    /// On a cable there is no Wi-Fi reading, and the crossed-out Wi-Fi icon
    /// with "N/A" that used to fill the slot read as a fault.
    pub fn renderWired(self: *Self) void {
        self.fillSignalSlot(layout.glyph.ethernet, "LAN");
    }

    /// The signal slot holds an icon that changes with what is beside it.
    fn fillSignalSlot(self: *Self, glyph: []const u8, text: []const u8) void {
        self.clearArea(layout.signal.reading.area);
        self.drawText(layout.signal.icon_at, glyph, .material14);
        self.drawText(layout.signal.reading.text, text, layout.signal.reading.font);
    }

    /// Render network traffic, from rates in bytes per second.
    pub fn renderTraffic(self: *Self, rates: Reading(parse.NetRates)) void {
        const down: ?parse.Scaled = if (rates.value) |r| parse.scaleBytes(r.rx_bytes_per_sec) else null;
        const up: ?parse.Scaled = if (rates.value) |r| parse.scaleBytes(r.tx_bytes_per_sec) else null;

        self.renderTrafficRow(layout.traffic.down, down, rates.isStale());
        self.renderTrafficRow(layout.traffic.up, up, rates.isStale());
    }

    /// One direction's rate. With no rate there is no unit to put on it
    /// either, so the value is a dash and the unit's place stays empty.
    fn renderTrafficRow(self: *Self, row: layout.TrafficRow, rate: ?parse.Scaled, stale: bool) void {
        self.clearArea(row.value.area);
        self.clearArea(row.unit.area);

        const known = rate orelse return self.drawText(row.value.text, "-", row.value.font);

        // scaleBytes keeps the value under 1000, so two decimals always fit.
        // The ladder is a guard against that changing, since this slot ends at
        // the right edge of the panel where overflow is clipped mid-glyph.
        var two_dp: [32]u8 = undefined;
        var one_dp: [32]u8 = undefined;
        var no_dp: [32]u8 = undefined;
        const candidates = [_][]const u8{
            std.mem.print(&two_dp, "{d:.2}", .{known.value}) catch "?",
            std.mem.print(&one_dp, "{d:.1}", .{known.value}) catch "?",
            std.mem.print(&no_dp, "{d:.0}", .{known.value}) catch "?",
        };
        const value = self.bitmap.fitText(&candidates, row.value.font, row.value.area.width);
        self.drawText(row.value.text, value, row.value.font);

        var unit_buf: [32]u8 = undefined;
        const unit = std.mem.print(&unit_buf, "{s}/s", .{known.unit}) catch "?";
        self.drawText(row.unit.text, unit, row.unit.font);

        // The value only. The unit is in the header's small print, which
        // does not survive fading, and the number is no use without it.
        if (stale) self.fadeArea(row.value.area);
    }

    /// Render APT updates count. Unavailable means the background check has
    /// not reported yet — show a dash rather than the "all up to date" tick,
    /// which would claim more than is known. Stale means the latest check
    /// failed and the count is an earlier one's, which at the slow interval
    /// makes it hours old at the least.
    pub fn renderAptUpdates(self: *Self, count: Reading(u32)) void {
        const slot = layout.apt.count;
        self.clearArea(slot.area);
        defer if (count.isStale()) self.fadeArea(slot.area);

        const known = count.value orelse return self.drawText(slot.text, "-", slot.font);
        if (known == 0) return self.drawText(slot.text, layout.glyph.check, .material24);

        var buf: [16]u8 = undefined;
        const label = self.aptLabel(&buf, known);
        self.drawText(slot.text, label.text, label.font);
    }

    /// Fonts the APT count steps down through, largest first.
    ///
    /// Three digits are 42px at the size one and two use, against a 35px
    /// slot, and a freshly flashed image is routinely hundreds of packages
    /// behind. The overflow crossed the divider at x=249 and, lying outside
    /// the area this slot clears, stayed on the panel after the count shrank.
    const apt_fonts = [_]FontType{ layout.apt.count.font, .ubuntu20, .ubuntu14 };

    const AptLabel = struct { text: []const u8, font: FontType };

    /// The count in the largest font it fits, or a capped "999+" once no
    /// font holds it. Same baseline in every font, so smaller ones sit on
    /// the same line.
    fn aptLabel(self: *Self, buf: []u8, count: u32) AptLabel {
        const width = layout.apt.count.area.width;
        const text = std.mem.print(buf, "{d}", .{count}) catch "?";

        for (apt_fonts) |font| {
            if (self.bitmap.measureText(text, font) <= width) return .{ .text = text, .font = font };
        }
        return .{ .text = "999+", .font = .ubuntu14 };
    }

    /// Render internet connection status
    pub fn renderInternetStatus(self: *Self, connected: bool) void {
        self.fillSlot(layout.net.status, if (connected) layout.glyph.online else layout.glyph.offline);
    }

    /// Draw a fixed screen with hard-coded values, for the golden reference
    /// frame. Lives here rather than in the test so that `zig build golden` and
    /// the test that checks against its output cannot drift apart.
    pub fn drawReferenceScreen(self: *Self) void {
        self.renderGrid();
        self.renderCpuLoad(.of(42));
        self.renderCpuTemp(.of(51));
        self.renderMemory(.of(28));
        self.renderDiskUsage(.of(84));
        self.renderDiskTemp(.of(33));
        self.renderFanSpeed(.of(543));
        self.renderTraffic(.of(.{ .rx_bytes_per_sec = 999_990, .tx_bytes_per_sec = 3.01 }));
        self.renderAptUpdates(.of(35));
        self.renderInternetStatus(true);
        self.renderIpAddress("192.168.1.231");
        self.renderUptime(.{ .days = 11, .hours = 22, .minutes = 47 });
        self.renderWired();
    }
};

// ----------------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------------

const testing = std.testing;

/// Path of the reference frame, relative to this file.
const golden_path = "testdata/golden_main.bin";
const golden_frame = @embedFile(golden_path);

test "the rendered screen matches the checked-in reference" {
    // A golden-image test: it pins the entire layout at once, so a coordinate,
    // a font metric or a format string that shifts anything fails here rather
    // than being noticed on the panel weeks later. Both layout bugs found by
    // eye during development — clipped uptime, clipped traffic rate — would
    // have changed this frame.
    //
    // To regenerate after an intentional layout change:
    //     zig build golden
    // then look at the diff before committing it.
    var r = try Renderer.init(testing.allocator, .{});
    defer r.deinit();

    r.drawReferenceScreen();
    const actual: []const u8 = r.panelFrame();

    if (!std.mem.eql(u8, golden_frame, actual)) {
        var differing_rows: usize = 0;
        var first_row: ?usize = null;
        var row: usize = 0;
        while (row < layout.display_width) : (row += 1) {
            const at = row * hw_bytes_per_row;
            if (!std.mem.eql(u8, golden_frame[at..][0..hw_bytes_per_row], actual[at..][0..hw_bytes_per_row])) {
                differing_rows += 1;
                if (first_row == null) first_row = row;
            }
        }
        std.debug.print(
            "\n  rendered frame differs from {s}: {d} of {d} hardware rows, first at {d}\n" ++
                "  run `zig build golden` to accept the new frame if this was intended\n",
            .{ golden_path, differing_rows, layout.display_width, first_row.? },
        );
        return error.GoldenFrameMismatch;
    }
}

test "rendering is deterministic" {
    // The golden test is only meaningful if the same inputs always produce the
    // same frame.
    var a = try Renderer.init(testing.allocator, .{});
    defer a.deinit();
    var b = try Renderer.init(testing.allocator, .{});
    defer b.deinit();

    a.drawReferenceScreen();
    b.drawReferenceScreen();

    try testing.expectEqualSlices(u8, a.panelFrame(), b.panelFrame());
}

test "the APT count fits its slot however large it gets" {
    var r = try Renderer.init(testing.allocator, .{});
    defer r.deinit();

    const width = layout.apt.count.area.width;
    var count: u32 = 1;
    while (count < 200_000) : (count = count * 3 / 2 + 1) {
        var buf: [16]u8 = undefined;
        const label = r.aptLabel(&buf, count);
        try testing.expect(r.bitmap.measureText(label.text, label.font) <= width);
    }

    // Two digits keep the size they always had, which is what the golden frame
    // pins; three step down rather than crossing the divider.
    var buf: [16]u8 = undefined;
    try testing.expectEqual(FontType.ubuntu24, r.aptLabel(&buf, 99).font);
    try testing.expect(r.aptLabel(&buf, 150).font != .ubuntu24);
    try testing.expectEqualStrings("150", r.aptLabel(&buf, 150).text);
}

test "a shrinking APT count leaves nothing behind outside its slot" {
    // The visible form of the overflow: pixels right of the slot that the
    // three-digit count drew and the two-digit one never cleared.
    var r = try Renderer.init(testing.allocator, .{});
    defer r.deinit();

    r.drawReferenceScreen();
    const before = try testing.allocator.dupe(u8, r.bitmap.data);
    defer testing.allocator.free(before);

    r.renderAptUpdates(.of(888));
    r.renderAptUpdates(.of(35));

    try testing.expectEqualSlices(u8, before, r.bitmap.data);
}

test "shrinking traffic and fan readings leave nothing behind" {
    // Every slot a reading draws into must be cleared in full before the next
    // one, or a wider reading leaves pixels behind a narrower one.
    var r = try Renderer.init(testing.allocator, .{});
    defer r.deinit();

    r.drawReferenceScreen();
    const before = try testing.allocator.dupe(u8, r.bitmap.data);
    defer testing.allocator.free(before);

    r.renderTraffic(.of(.{ .rx_bytes_per_sec = 7_180_000, .tx_bytes_per_sec = 118_000_000 }));
    r.renderFanSpeed(.of(8200));
    r.renderTraffic(.of(.{ .rx_bytes_per_sec = 999_990, .tx_bytes_per_sec = 3.01 }));
    r.renderFanSpeed(.of(543));

    try testing.expectEqualSlices(u8, before, r.bitmap.data);
}

test "a missing sensor is drawn as a dash, not as zero" {
    var r = try Renderer.init(testing.allocator, .{});
    defer r.deinit();

    r.renderDiskTemp(.of(0));
    r.renderFanSpeed(.of(0));
    const zero = try testing.allocator.dupe(u8, r.bitmap.data);
    defer testing.allocator.free(zero);

    r.renderDiskTemp(.{});
    r.renderFanSpeed(.{});
    try testing.expect(!std.mem.eql(u8, zero, r.bitmap.data));

    // And the dash is exactly what it says, drawn where the reading would be.
    var expected = try Renderer.init(testing.allocator, .{});
    defer expected.deinit();
    expected.renderDiskTemp(.of(0));
    expected.renderFanSpeed(.of(0));
    expected.fillSlot(layout.disk.temp, "-");
    expected.fillSlot(layout.fan.speed, "-");
    expected.drawText(layout.fan.unit_at, "rpm", .ubuntu14);
    try testing.expectEqualSlices(u8, expected.bitmap.data, r.bitmap.data);
}

// --- stale and unavailable readings --------------------------------------------

// The three states, in the one shape `drawEverySlot` takes them in.

fn staleReading(comptime T: type, value: T) Reading(T) {
    return .staleOf(value);
}

fn currentReading(comptime T: type, value: T) Reading(T) {
    return .of(value);
}

fn noReading(comptime T: type, value: T) Reading(T) {
    _ = value;
    return .{};
}

fn countBlack(r: *const Renderer) usize {
    var n: usize = 0;
    for (r.bitmap.data) |px| {
        if (px < 128) n += 1;
    }
    return n;
}

/// Every slot that takes a reading, drawn from the reference screen's values
/// as readings in the state `make` puts them in.
fn drawEverySlot(r: *Renderer, comptime make: anytype) void {
    r.renderCpuLoad(make(u8, 42));
    r.renderCpuTemp(make(u32, 51));
    r.renderMemory(make(u8, 28));
    r.renderDiskUsage(make(u8, 84));
    r.renderDiskTemp(make(u32, 33));
    r.renderFanSpeed(make(u32, 543));
    r.renderTraffic(make(parse.NetRates, .{ .rx_bytes_per_sec = 999_990, .tx_bytes_per_sec = 3.01 }));
    r.renderAptUpdates(make(u32, 35));
}

test "a stale reading is drawn faded: the same value with pixels taken out" {
    // The regression this pins: a slot whose reading had failed looked exactly
    // like one that was live.
    var live = try Renderer.init(testing.allocator, .{});
    defer live.deinit();
    live.drawReferenceScreen();
    const reference = try testing.allocator.dupe(u8, live.bitmap.data);
    defer testing.allocator.free(reference);

    // The helper draws what the reference screen does, or the comparison
    // below would be between two different screens.
    drawEverySlot(&live, currentReading);
    try testing.expectEqualSlices(u8, reference, live.bitmap.data);

    var stale = try Renderer.init(testing.allocator, .{});
    defer stale.deinit();
    stale.drawReferenceScreen();
    drawEverySlot(&stale, staleReading);

    try testing.expect(!std.mem.eql(u8, live.bitmap.data, stale.bitmap.data));

    // Fading only ever removes ink, and only from the live rendering: nothing
    // is black in the stale frame that is not black in the live one.
    for (live.bitmap.data, stale.bitmap.data) |was, is| {
        if (is < 128) try testing.expect(was < 128);
    }
    try testing.expect(countBlack(&stale) < countBlack(&live));
}

test "each slot fades on its own and comes back whole" {
    var r = try Renderer.init(testing.allocator, .{});
    defer r.deinit();
    r.drawReferenceScreen();
    const live = try testing.allocator.dupe(u8, r.bitmap.data);
    defer testing.allocator.free(live);

    r.renderDiskTemp(.staleOf(33));
    try testing.expect(!std.mem.eql(u8, live, r.bitmap.data));

    // Only the disk temperature's own area changed.
    const area = layout.disk.temp.area;
    for (0..layout.display_height) |y| {
        for (0..layout.display_width) |x| {
            const inside = x >= area.x and x < area.right() and y >= area.y and y < area.bottom();
            if (inside) continue;
            const at = y * r.bitmap.stride + x;
            try testing.expectEqual(live[at], r.bitmap.data[at]);
        }
    }

    // The next good reading leaves no trace of it.
    r.renderDiskTemp(.of(33));
    try testing.expectEqualSlices(u8, live, r.bitmap.data);
}

test "a stale fan reading keeps its unit whole" {
    var live = try Renderer.init(testing.allocator, .{});
    defer live.deinit();
    live.renderFanSpeed(.of(543));

    var stale = try Renderer.init(testing.allocator, .{});
    defer stale.deinit();
    stale.renderFanSpeed(.staleOf(543));

    try testing.expect(!std.mem.eql(u8, live.bitmap.data, stale.bitmap.data));

    // The header row the unit is drawn on, from the unit to the divider.
    const unit = layout.fan.unit_at;
    const left: usize = @intCast(unit.x);
    const right: usize = layout.grid.right_divider;
    const top: usize = @intCast(unit.y - Bitmap.fontAscent(.ubuntu14));
    const bottom: usize = @intCast(unit.y + 4);
    for (top..bottom) |y| {
        const row = y * live.bitmap.stride;
        try testing.expectEqualSlices(u8, live.bitmap.data[row + left .. row + right], stale.bitmap.data[row + left .. row + right]);
    }
}

test "a stale critical value stays inverted" {
    // Last known to be over the threshold is still worth the alarm.
    var r = try Renderer.init(testing.allocator, .{});
    defer r.deinit();
    r.bitmap.clear(.white);

    r.renderCpuLoad(.staleOf(100));
    const stale_black = countBlack(&r);
    r.renderCpuLoad(.of(100));
    const live_black = countBlack(&r);

    // Inverted, the slot is mostly black either way; faded, the text in it is
    // dimmer, which on a black ground means more black, not less.
    const area = layout.cpu.load.area.width * layout.cpu.load.area.height;
    try testing.expect(live_black > area / 2);
    try testing.expect(stale_black > live_black);
}

test "a reading with no value is a dash in every slot" {
    var r = try Renderer.init(testing.allocator, .{});
    defer r.deinit();
    r.drawReferenceScreen();
    drawEverySlot(&r, noReading);
    r.renderUptime(null);

    // The same screen with each of those slots cleared and a dash put in it
    // by hand, in the slot's own font.
    var expected = try Renderer.init(testing.allocator, .{});
    defer expected.deinit();
    expected.drawReferenceScreen();

    for ([_]layout.Slot{
        layout.cpu.load,  layout.cpu.temp,  layout.mem.usage, layout.disk.usage,
        layout.disk.temp, layout.fan.speed, layout.apt.count, layout.uptime.elapsed,
    }) |slot| {
        expected.clearArea(slot.area);
        expected.drawText(slot.text, "-", slot.font);
    }
    // The fan's unit is a label, and stays.
    expected.drawText(layout.fan.unit_at, "rpm", .ubuntu14);

    // A rate that is not known has no unit either.
    for ([_]layout.TrafficRow{ layout.traffic.down, layout.traffic.up }) |row| {
        expected.clearArea(row.value.area);
        expected.clearArea(row.unit.area);
        expected.drawText(row.value.text, "-", row.value.font);
    }

    try testing.expectEqualSlices(u8, expected.bitmap.data, r.bitmap.data);
}

test "the thresholds the renderer is given are the ones it inverts at" {
    var r = try Renderer.init(testing.allocator, .{ .thresholds = .{ .cpu = 50, .temp = 60 } });
    defer r.deinit();
    r.bitmap.clear(.white);
    const area = layout.cpu.load.area.width * layout.cpu.load.area.height;

    // Under it the slot is mostly white, at it mostly black.
    r.renderCpuLoad(.of(49));
    try testing.expect(countBlack(&r) < area / 2);
    r.renderCpuLoad(.of(50));
    try testing.expect(countBlack(&r) > area / 2);

    // A reading with no value is over no threshold.
    r.renderCpuLoad(.{});
    try testing.expect(countBlack(&r) < area / 2);
}

// --- under-voltage warning ---------------------------------------------------

/// Rows of the unrotated BMP buffer covering the status bar.
fn statusBarRows(r: *Renderer) []const u8 {
    const row_bytes = @divCeil(layout.display_width, 8);
    return r.bmp_buffer[layout.status_bar.y * row_bytes ..];
}

test "the warning inverts the status bar in the frame sent to the panel" {
    var r = try Renderer.init(testing.allocator, .{});
    defer r.deinit();

    r.drawReferenceScreen();
    const clean: Frame = r.panelFrame().*;

    r.setFaultWarning(true);
    try testing.expect(!std.mem.eql(u8, &clean, r.panelFrame()));
}

test "the warning reaches the BMP preview too" {
    // Regression: the overlay used to be applied only around the panel
    // conversion, so the exported preview showed a clean status bar while the
    // glass showed an inverted one. A preview that disagrees with the device is
    // worse than no preview.
    var r = try Renderer.init(testing.allocator, .{});
    defer r.deinit();

    r.drawReferenceScreen();
    r.packBmpBuffer();
    const clean = try testing.allocator.dupe(u8, statusBarRows(&r));
    defer testing.allocator.free(clean);

    r.setFaultWarning(true);
    r.toggleFaultOverlay();
    r.packBmpBuffer();
    r.toggleFaultOverlay();

    const warned = statusBarRows(&r);
    try testing.expect(!std.mem.eql(u8, clean, warned));

    // Every bit of the bar flips, so the rows are the exact complement.
    for (clean, warned) |a, b| try testing.expectEqual(a, ~b);
}

test "the warning does not leak into the bitmap" {
    // The status bar's slots are each redrawn by their own task, so an inversion
    // left behind would be partially erased and the frame would come out half
    // inverted. toggleFaultOverlay relies on invertRect being its own inverse.
    var r = try Renderer.init(testing.allocator, .{});
    defer r.deinit();

    r.drawReferenceScreen();
    const pristine = try testing.allocator.dupe(u8, r.bitmap.data);
    defer testing.allocator.free(pristine);

    r.setFaultWarning(true);
    _ = r.panelFrame();
    _ = r.packedFrame();

    try testing.expectEqualSlices(u8, pristine, r.bitmap.data);
}

test "repeated refreshes with the warning on are stable" {
    // An inversion that accumulated would alternate the bar between normal and
    // inverted on every refresh.
    var r = try Renderer.init(testing.allocator, .{});
    defer r.deinit();

    r.drawReferenceScreen();
    r.setFaultWarning(true);

    const first: Frame = r.panelFrame().*;
    try testing.expectEqualSlices(u8, &first, r.panelFrame());
}

test "the warning leaves everything above the status bar alone" {
    var r = try Renderer.init(testing.allocator, .{});
    defer r.deinit();

    r.drawReferenceScreen();
    r.packBmpBuffer();
    const row_bytes = @divCeil(layout.display_width, 8);
    const above_len = layout.status_bar.y * row_bytes;
    const clean_above = try testing.allocator.dupe(u8, r.bmp_buffer[0..above_len]);
    defer testing.allocator.free(clean_above);

    r.setFaultWarning(true);
    r.toggleFaultOverlay();
    r.packBmpBuffer();
    r.toggleFaultOverlay();

    try testing.expectEqualSlices(u8, clean_above, r.bmp_buffer[0..above_len]);
}

test "a notice replaces the dashboard and clearing it brings the dashboard back intact" {
    var r = try Renderer.init(testing.allocator, .{});
    defer r.deinit();

    r.drawReferenceScreen();
    const dashboard = try testing.allocator.dupe(u8, r.packedFrame());
    defer testing.allocator.free(dashboard);

    r.showNotice("Pračka dokončila praní");
    try testing.expect(!std.mem.eql(u8, dashboard, r.packedFrame()));

    r.clearNotice();
    try testing.expectEqualSlices(u8, dashboard, r.packedFrame());
}

test "the dashboard keeps updating underneath a notice" {
    var r = try Renderer.init(testing.allocator, .{});
    defer r.deinit();

    r.drawReferenceScreen();
    r.showNotice("hello");
    const shown = try testing.allocator.dupe(u8, r.packedFrame());
    defer testing.allocator.free(shown);

    // A reading lands while the notice is up: the panel does not change...
    r.renderCpuLoad(.of(99));
    try testing.expectEqualSlices(u8, shown, r.packedFrame());

    // ...and the dashboard it returns to has it.
    r.clearNotice();
    var expected = try Renderer.init(testing.allocator, .{});
    defer expected.deinit();
    expected.drawReferenceScreen();
    expected.renderCpuLoad(.of(99));
    try testing.expectEqualSlices(u8, expected.packedFrame(), r.packedFrame());
}

test "a notice reaches the panel's frame, and holds still while it is up" {
    var r = try Renderer.init(testing.allocator, .{});
    defer r.deinit();

    r.drawReferenceScreen();
    const dashboard: Frame = r.panelFrame().*;

    r.showNotice("hello");
    const shown: Frame = r.panelFrame().*;
    try testing.expect(!std.mem.eql(u8, &dashboard, &shown));

    // Unchanged while it stays up, which is what lets the panel skip idle ticks.
    try testing.expectEqualSlices(u8, &shown, r.panelFrame());
}

test "a hardware fault shows over a notice too" {
    var r = try Renderer.init(testing.allocator, .{});
    defer r.deinit();

    r.drawReferenceScreen();
    r.showNotice("Deploy running");
    const quiet = try testing.allocator.dupe(u8, r.packedFrame());
    defer testing.allocator.free(quiet);

    r.setFaultWarning(true);
    const faulted = r.packedFrame();

    // The status bar rows are inverted on the notice, and only they are.
    const row_bytes = @divCeil(layout.display_width, 8);
    const bar_start = layout.status_bar.y * row_bytes;
    try testing.expectEqualSlices(u8, quiet[0..bar_start], faulted[0..bar_start]);
    for (quiet[bar_start..], faulted[bar_start..]) |q, f| try testing.expectEqual(~q, f);

    // And the overlay is not left behind in the notice itself.
    r.setFaultWarning(false);
    try testing.expectEqualSlices(u8, quiet, r.packedFrame());
}

test "the ellipsis never splits the degree sign" {
    var r = try Renderer.init(testing.allocator, .{});
    defer r.deinit();

    var lines: [layout.notice.max_lines][]const u8 = undefined;
    var last_buf: [notice_text.max_len + 3]u8 = undefined;
    // Folded text keeps the degree sign as two bytes. Shifting the text a
    // character at a time moves the cut across it, whatever the font metrics.
    const body: *const [640 * 2]u8 = comptime body: {
        const signs: [640][2]u8 = @splat("\u{B0}".*);
        break :body @ptrCast(&signs);
    };
    var buf: [8 + body.len]u8 = undefined;
    for (0..8) |shift| {
        @memset(buf[0..shift], 'x');
        @memcpy(buf[shift..][0..body.len], body);
        const fitted = r.layoutNotice(buf[0 .. shift + body.len], &lines, &last_buf);

        const last = lines[fitted.count - 1];
        try testing.expect(std.mem.endsWith(u8, last, "..."));
        try testing.expect(std.unicode.utf8ValidateSlice(last));
    }
}

test "the sleep screen takes over from a notice" {
    var r = try Renderer.init(testing.allocator, .{});
    defer r.deinit();

    r.drawReferenceScreen();
    r.showNotice("hello");
    r.drawSleepScreen();

    try testing.expect(!r.notice_shown);
    // The splash is drawn white on black: a notice would be mostly white.
    var black: usize = 0;
    for (r.bitmap.data) |px| black += @intFromBool(px == 0);
    try testing.expect(black > r.bitmap.data.len / 2);
}

test "the sleep screen carries no fault overlay" {
    // It has no status bar to invert: the overlay would cut a white strip
    // across the bottom of a black page.
    var r = try Renderer.init(testing.allocator, .{});
    defer r.deinit();

    r.drawReferenceScreen();
    r.setFaultWarning(true);
    r.drawSleepScreen();

    var expected = try Renderer.init(testing.allocator, .{});
    defer expected.deinit();
    expected.drawSleepScreen();

    try testing.expectEqualSlices(u8, expected.panelFrame(), r.panelFrame());
    try testing.expectEqualSlices(u8, expected.packedFrame(), r.packedFrame());
}

test "a short notice gets the largest font, a longer one steps down" {
    var r = try Renderer.init(testing.allocator, .{});
    defer r.deinit();

    var lines: [layout.notice.max_lines][]const u8 = undefined;
    var last_buf: [notice_text.max_len + 3]u8 = undefined;

    const short = r.layoutNotice("Backup done", &lines, &last_buf);
    try testing.expectEqual(FontType.ubuntu34, short.font);
    try testing.expectEqual(@as(usize, 1), short.count);

    const longer = r.layoutNotice(
        "The nightly backup finished in 14 minutes and copied 2.3 GB to the NAS",
        &lines,
        &last_buf,
    );
    try testing.expect(longer.font != .ubuntu34);
    for (lines[0..longer.count]) |line| {
        try testing.expect(r.notice.measureText(line, longer.font) <= layout.notice.body.width);
    }
}

test "the lengths the Hermes skill promises hold" {
    // examples/hermes/sysink-panel/SKILL.md tells an agent what fits; keep it true.
    var r = try Renderer.init(testing.allocator, .{});
    defer r.deinit();

    var lines: [layout.notice.max_lines][]const u8 = undefined;
    var last_buf: [notice_text.max_len + 3]u8 = undefined;

    // About 30 characters: the largest font.
    try testing.expectEqual(FontType.ubuntu34, r.layoutNotice("Backup finished, disk is fine.", &lines, &last_buf).font);

    // About 250: all of it, in the smallest.
    const sentence = "Nightly backup of the NAS finished with warnings. ";
    const long: *const [6 * sentence.len]u8 = comptime long: {
        const copies: [6][sentence.len]u8 = @splat(sentence.*);
        break :long @ptrCast(&copies);
    };
    const fitted = r.layoutNotice(long[0..250], &lines, &last_buf);
    try testing.expect(!std.mem.endsWith(u8, lines[fitted.count - 1], "..."));
}

test "a notice too long for the smallest font ends in an ellipsis within the body" {
    var r = try Renderer.init(testing.allocator, .{});
    defer r.deinit();

    const long: *const [100 * 5]u8 = comptime long: {
        const words: [100][5]u8 = @splat("word ".*);
        break :long @ptrCast(&words);
    };
    var lines: [layout.notice.max_lines][]const u8 = undefined;
    var last_buf: [notice_text.max_len + 3]u8 = undefined;
    const fitted = r.layoutNotice(long, &lines, &last_buf);

    try testing.expectEqual(FontType.ubuntu14, fitted.font);
    const last = lines[fitted.count - 1];
    try testing.expect(std.mem.endsWith(u8, last, "..."));
    try testing.expect(r.notice.measureText(last, .ubuntu14) <= layout.notice.body.width);
    // And the block fits the body height.
    try testing.expect(fitted.count * r.notice.getLineHeight(.ubuntu14) <= layout.notice.body.height);
}

test "no warning means no overlay at all" {
    var r = try Renderer.init(testing.allocator, .{});
    defer r.deinit();

    r.drawReferenceScreen();
    r.packBmpBuffer();
    const clean = try testing.allocator.dupe(u8, r.bmp_buffer);
    defer testing.allocator.free(clean);

    r.setFaultWarning(false);
    r.toggleFaultOverlay();
    r.packBmpBuffer();
    r.toggleFaultOverlay();

    try testing.expectEqualSlices(u8, clean, r.bmp_buffer);
}
