const std = @import("std");
const epd2in9 = @import("waveshare_epd/epd2in9.zig");
const Frame = epd2in9.Frame;
const EpdConfig = @import("waveshare_epd/epdconfig.zig").EpdConfig;
const display_config = @import("display_config.zig");
const config = @import("config.zig");
const Graphics = @import("graphics.zig");
const Bitmap = Graphics.Bitmap;
const FontType = Graphics.Bitmap.FontType;
const BmpExporter = @import("bmp.zig").BmpExporter;

const log = std.log.scoped(.display);

/// Bytes per hardware row after the 90° rotation.
const hw_bytes_per_row = display_config.DISPLAY_HEIGHT / 8;

comptime {
    // The rotation below packs a whole hardware row from one logical column.
    std.debug.assert(display_config.DISPLAY_HEIGHT % 8 == 0);
    // Ties the layout constants to the driver: a mismatch would otherwise only
    // show up as a corrupted panel.
    std.debug.assert(@sizeOf(Frame) == hw_bytes_per_row * display_config.DISPLAY_WIDTH);
}

/// Drives the panel from a Bitmap, parameterised by the transport underneath so
/// tests can render and drive the whole state machine without hardware.
/// `DisplayRenderer` below is the production instance.
pub fn Renderer(comptime Transport: type) type {
    return struct {
        const Self = @This();
        /// Public so a caller that constructs a renderer at its final address can
        /// re-point `epd`, which holds a pointer to the transport.
        pub const EPD = epd2in9.Epd(Transport);

        bitmap: Bitmap,
        epd: EPD,
        epd_buffer: *Frame,
        last_epd_buffer: *Frame,
        /// Scratch buffer for BMP export, kept around so exporting does not allocate.
        bmp_buffer: []u8,
        has_last_epd_buffer: bool = false,
        /// True while the panel controller sits in deep sleep.
        panel_asleep: bool = false,
        /// Draws the status bar inverted, signalling a hardware fault. Driven by the
        /// daemon as the OR of every fault source (under-voltage, NVMe SMART), so
        /// the bar clears only when all of them have.
        warn_fault: bool = false,
        /// Set when an update failed partway through, leaving the panel content
        /// unknown. The next update must be a full refresh, because a partial one
        /// would diff against a reference that no longer matches the glass.
        panel_state_unknown: bool = false,
        allocator: std.mem.Allocator,
        io: std.Io,
        bmp_exporter: BmpExporter,
        grid_cached: bool = false,

        /// `transport` is borrowed, not owned: the caller outlives the renderer and
        /// is responsible for tearing it down. It used to be heap-allocated here
        /// purely because this function returns by value and EPD holds a pointer to
        /// it, which would have dangled.
        pub fn init(allocator: std.mem.Allocator, io: std.Io, transport: *Transport) !Self {
            var bitmap = try Bitmap.init(allocator, display_config.DISPLAY_WIDTH, display_config.DISPLAY_HEIGHT);
            errdefer bitmap.deinit();

            // Buffers for EPD (128x296 portrait = 4736 bytes each)
            const epd_buffer = try allocator.create(Frame);
            errdefer allocator.destroy(epd_buffer);
            const last_epd_buffer = try allocator.create(Frame);
            errdefer allocator.destroy(last_epd_buffer);

            const bmp_row_bytes = (display_config.DISPLAY_WIDTH + 7) / 8;
            const bmp_buffer = try allocator.alloc(u8, bmp_row_bytes * display_config.DISPLAY_HEIGHT);

            return .{
                .bitmap = bitmap,
                .epd = EPD.init(transport),
                .epd_buffer = epd_buffer,
                .last_epd_buffer = last_epd_buffer,
                .bmp_buffer = bmp_buffer,
                .allocator = allocator,
                .io = io,
                .bmp_exporter = BmpExporter.init(),
            };
        }

        pub fn deinit(self: *Self) void {
            self.bitmap.deinit();
            self.allocator.free(self.bmp_buffer);
            self.allocator.destroy(self.last_epd_buffer);
            self.allocator.destroy(self.epd_buffer);
        }

        /// Initialize display
        pub fn startup(self: *Self) !void {
            try self.epd.initDisplay();
            try self.epd.clear(0xFF);
        }

        /// Show a transient loading screen while metrics initialize
        pub fn showLoading(self: *Self) !void {
            self.drawSplash("Loading...", .White);

            self.convertTo1Bit(self.epd_buffer);
            try self.epd.display(self.epd_buffer);

            self.exportBmp() catch |err| {
                log.err("Failed to export loading BMP: {t}", .{err});
            };
        }

        /// Draw the full-screen splash used by the loading and sleep screens.
        /// `background` is the page colour; text and rules are drawn inverted to it.
        fn drawSplash(self: *Self, subtitle: []const u8, background: Graphics.Color) void {
            const ink: Graphics.Color = if (background == .White) .Black else .White;

            self.bitmap.clear(background);
            self.bitmap.fillRect(display_config.SLEEP_LINE_X, display_config.SLEEP_LINE_Y, display_config.SLEEP_LINE_W, display_config.SLEEP_LINE_H, ink);
            self.bitmap.drawTextFont(display_config.SLEEP_ICON_X, display_config.SLEEP_ICON_Y, display_config.ICON_SLEEP_NET, .Material50, ink);
            self.bitmap.drawTextFont(display_config.SLEEP_TITLE_X, display_config.SLEEP_TITLE_Y, "SysInk", .Ubuntu34, ink);
            self.bitmap.drawTextFont(display_config.SLEEP_SUBTITLE_X, display_config.SLEEP_SUBTITLE_Y, subtitle, .Ubuntu14, ink);
        }

        /// Render grid layout
        pub fn renderGrid(self: *Self) void {
            if (self.grid_cached) return;

            self.bitmap.clear(.White);

            // Draw vertical divider lines
            self.bitmap.drawLine(display_config.VERTICAL_LINE_1, display_config.CPU_LINE_Y, display_config.VERTICAL_LINE_1, display_config.HORIZONTAL_LINE_MAIN, .Black);
            self.bitmap.drawLine(display_config.VERTICAL_LINE_2, display_config.CPU_LINE_Y, display_config.VERTICAL_LINE_2, display_config.HORIZONTAL_LINE_MAIN, .Black);

            // Draw main horizontal divider
            self.bitmap.drawLine(0, display_config.HORIZONTAL_LINE_MAIN, display_config.DISPLAY_WIDTH, display_config.HORIZONTAL_LINE_MAIN, .Black);

            // CPU section
            self.bitmap.drawLine(26, display_config.CPU_LINE_Y, 99, display_config.CPU_LINE_Y, .Black);
            self.bitmap.drawTextFont(1, display_config.CPU_LABEL_Y, "cpu", .Ubuntu14, .Black);
            self.bitmap.drawTextFont(display_config.CPU_ICON_X, display_config.CPU_ICON_Y_LOAD, display_config.ICON_CPU, .Material24, .Black);
            self.bitmap.drawTextFont(display_config.CPU_ICON_X, display_config.CPU_ICON_Y_TEMP, display_config.ICON_TEMPERATURE, .Material24, .Black);

            // APT section
            self.bitmap.drawTextFont(display_config.APT_LABEL_X, display_config.APT_LABEL_Y, "apt", .Ubuntu14, .Black);
            self.bitmap.drawLine(226, display_config.APT_LINE_Y, 248, display_config.APT_LINE_Y, .Black);

            // NET section
            self.bitmap.drawTextFont(display_config.NET_LABEL_X, display_config.NET_LABEL_Y, "net", .Ubuntu14, .Black);
            self.bitmap.drawLine(display_config.NET_LINE_X, display_config.NET_LINE_Y, display_config.NET_LINE_X, display_config.HORIZONTAL_LINE_MAIN, .Black);
            self.bitmap.drawLine(272, display_config.NET_LINE_Y, display_config.DISPLAY_WIDTH, display_config.NET_LINE_Y, .Black);

            // MEM section
            self.bitmap.drawTextFont(display_config.MEM_LABEL_X, display_config.MEM_LABEL_Y, "mem", .Ubuntu14, .Black);
            self.bitmap.drawLine(38, display_config.MEM_LINE_Y, display_config.SECTION_CPU_RIGHT, display_config.MEM_LINE_Y, .Black);
            self.bitmap.drawTextFont(display_config.MEM_ICON_X, display_config.MEM_ICON_Y, display_config.ICON_MEMORY, .Material24, .Black);

            // Disk section
            self.bitmap.drawTextFont(display_config.DISK_LABEL_X, display_config.DISK_LABEL_Y, "disk", .Ubuntu14, .Black);
            self.bitmap.drawLine(130, display_config.DISK_LINE_Y, display_config.SECTION_DISK_RIGHT, display_config.DISK_LINE_Y, .Black);
            self.bitmap.drawTextFont(display_config.DISK_ICON_X, display_config.DISK_ICON_Y_DISK, display_config.ICON_HARD_DRIVE, .Material24, .Black);
            self.bitmap.drawTextFont(display_config.DISK_ICON_X, display_config.DISK_ICON_Y_TEMP, display_config.ICON_TEMPERATURE, .Material24, .Black);

            // FAN section
            self.bitmap.drawTextFont(display_config.FAN_LABEL_X, display_config.FAN_LABEL_Y, "fan", .Ubuntu14, .Black);
            self.bitmap.drawLine(124, display_config.FAN_LINE_Y, display_config.SECTION_DISK_RIGHT, display_config.FAN_LINE_Y, .Black);
            self.bitmap.drawTextFont(display_config.FAN_ICON_X, display_config.FAN_ICON_Y, display_config.ICON_FAN, .Material24, .Black);

            // Traffic section
            self.bitmap.drawTextFont(display_config.TRAFFIC_DOWN_LABEL_X, display_config.TRAFFIC_DOWN_LABEL_Y, "down", .Ubuntu14, .Black);
            self.bitmap.drawLine(242, display_config.TRAFFIC_DOWN_LINE_Y, 261, display_config.TRAFFIC_DOWN_LINE_Y, .Black);
            self.bitmap.drawTextFont(display_config.TRAFFIC_DOWN_ICON_X, display_config.TRAFFIC_DOWN_ICON_Y, display_config.ICON_DOWNLOAD, .Material24, .Black);

            self.bitmap.drawTextFont(display_config.TRAFFIC_UP_LABEL_X, display_config.TRAFFIC_UP_LABEL_Y, "up", .Ubuntu14, .Black);
            self.bitmap.drawLine(222, display_config.TRAFFIC_UP_LINE_Y, 261, display_config.TRAFFIC_UP_LINE_Y, .Black);
            self.bitmap.drawTextFont(display_config.TRAFFIC_UP_ICON_X, display_config.TRAFFIC_UP_ICON_Y, display_config.ICON_UPLOAD, .Material24, .Black);

            // Status bar icons
            self.bitmap.drawTextFont(display_config.IP_ICON_X, display_config.IP_ICON_Y, display_config.ICON_NETWORK, .Material14, .Black);
            self.bitmap.drawTextFont(display_config.UPTIME_ICON_X, display_config.UPTIME_ICON_Y, display_config.ICON_UPTIME, .Material14, .Black);

            self.grid_cached = true;
        }

        /// Simple unified text rendering in a defined area with optional inversion
        fn drawTextInArea(self: *Self, text: []const u8, font: FontType, text_x: i32, text_y: i32, area_x: i32, area_y: i32, area_w: u32, area_h: u32, invert: bool) void {
            // Clear the area
            self.bitmap.fillRect(area_x, area_y, area_w, area_h, .White);

            // Draw text
            self.bitmap.drawTextFont(text_x, text_y, text, font, .Black);

            // Invert if critical
            if (invert) {
                self.bitmap.invertRect(area_x, area_y, area_w, area_h);
            }
        }

        /// Show or clear the hardware-fault warning: the status bar is drawn inverted.
        pub fn setFaultWarning(self: *Self, active: bool) void {
            self.warn_fault = active;
        }

        fn invertStatusBar(self: *Self) void {
            self.bitmap.invertRect(0, display_config.STATUS_BAR_Y, display_config.DISPLAY_WIDTH, display_config.STATUS_BAR_H);
        }

        /// Toggle the fault overlay on the bitmap. Its own inverse, so a paired call
        /// restores the bitmap.
        ///
        /// Not drawn into the layout, because the status bar's three slots are each
        /// redrawn by their own scheduled task and any of them would erase part of it.
        /// Call it around everything that reads the bitmap — the panel conversion and
        /// the BMP export both — or the preview disagrees with the glass.
        fn toggleFaultOverlay(self: *Self) void {
            if (self.warn_fault) self.invertStatusBar();
        }

        /// The current frame packed to 1 bit, fault overlay included.
        ///
        /// For callers that want to show the frame rather than write it — the
        /// simulators — so they do not have to turn the BMP export on and read the
        /// file back just to get at the pixels. Borrowed: valid until the next
        /// render.
        pub fn packedFrame(self: *Self) []const u8 {
            self.toggleFaultOverlay();
            defer self.toggleFaultOverlay();

            self.packBmpBuffer();
            return self.bmp_buffer;
        }

        /// Push the first frame and establish the reference for later partial updates.
        pub fn showInitialFrame(self: *Self) !void {
            self.toggleFaultOverlay();
            defer self.toggleFaultOverlay();

            self.convertTo1Bit(self.epd_buffer);
            try self.epd.displayBase(self.epd_buffer);
            self.rememberCurrentFrame();
            self.parkPanel();

            self.exportBmp() catch |err| {
                log.err("Failed to export initial BMP: {t}", .{err});
            };
        }

        /// Update display
        pub fn updateDisplay(self: *Self, partial_requested: bool) !void {
            if (display_config.DEBUG_TEXT_AREAS) {
                self.drawTextAreaFrames();
            }

            // Held for the whole function, so the BMP export on every exit path below
            // sees the same overlay the panel does.
            self.toggleFaultOverlay();
            defer self.toggleFaultOverlay();

            // Convert Bitmap to 1-bit
            self.convertTo1Bit(self.epd_buffer);

            log.debug("updateDisplay: START (partial requested={})", .{partial_requested});

            // Skip unchanged frames only on partial updates. A full refresh must always go
            // through to clear ghosting/artifacts accumulated by partial updates, and so
            // must any update while the glass contents are in doubt.
            // A skipped frame also leaves a sleeping panel undisturbed.
            const unchanged = self.has_last_epd_buffer and std.mem.eql(u8, self.epd_buffer, self.last_epd_buffer);
            if (partial_requested and unchanged and !self.panel_state_unknown) {
                log.debug("updateDisplay: skipped unchanged partial frame", .{});
                self.exportBmp() catch |err| {
                    log.err("Failed to export BMP: {t}", .{err});
                };
                return;
            }

            try self.wakePanel();

            // Decided only after waking: restoring the reference frame can itself
            // fail, and that rules a partial update out.
            const partial = partial_requested and !self.panel_state_unknown;

            {
                // Any failure below leaves the glass in an unknown state.
                errdefer self.panel_state_unknown = true;

                if (partial) {
                    try self.epd.displayPartial(self.epd_buffer);
                } else {
                    // displayBase, not display: it refreshes fully *and* rewrites the
                    // reference RAM, keeping later partial updates diffing against
                    // what is actually on the glass.
                    try self.epd.displayBase(self.epd_buffer);
                }
            }

            self.rememberCurrentFrame();
            self.panel_state_unknown = false;
            self.parkPanel();

            log.debug("updateDisplay: EPD done (partial={})", .{partial});

            self.exportBmp() catch |err| {
                log.err("Failed to export BMP: {t}", .{err});
            };
        }

        /// Bring the controller out of deep sleep, if it is in it.
        ///
        /// Deep sleep drops the reference frame that partial updates diff against,
        /// so it has to be restored from the frame we know is on the glass — before
        /// the partial sequence powers the analog stage up, or the write is ignored.
        fn wakePanel(self: *Self) !void {
            if (!self.panel_asleep) return;

            log.debug("panel: waking from deep sleep", .{});
            try self.epd.reInit();
            if (self.has_last_epd_buffer) {
                self.epd.primeBase(self.last_epd_buffer) catch |err| {
                    // Without a reference a partial update would smear, so fall back
                    // to a full refresh instead.
                    log.warn("Failed to restore panel reference frame: {t}", .{err});
                    self.panel_state_unknown = true;
                };
            } else {
                self.panel_state_unknown = true;
            }

            self.panel_asleep = false;
        }

        /// Park the controller in deep sleep until the next visible update.
        fn parkPanel(self: *Self) void {
            if (!config.Config.panel_sleep or self.panel_asleep) return;

            self.epd.sleep() catch |err| {
                log.warn("Failed to park panel in deep sleep: {t}", .{err});
                return;
            };
            self.panel_asleep = true;
            log.debug("panel: parked in deep sleep", .{});
        }

        pub fn rememberCurrentFrame(self: *Self) void {
            @memcpy(self.last_epd_buffer, self.epd_buffer);
            self.has_last_epd_buffer = true;
        }

        fn drawTextAreaFrames(self: *Self) void {
            const color: Graphics.Color = .Black;

            // CPU
            self.bitmap.drawRect(display_config.CPU_AREA_X, display_config.CPU_AREA_Y_LOAD, display_config.TEXT_AREA_CPU.width, display_config.TEXT_AREA_CPU.height, color);
            self.bitmap.drawRect(display_config.CPU_AREA_X, display_config.CPU_AREA_Y_TEMP, display_config.TEXT_AREA_CPU.width, display_config.TEXT_AREA_CPU.height, color);

            // MEM
            self.bitmap.drawRect(display_config.MEM_AREA_X, display_config.MEM_AREA_Y, display_config.TEXT_AREA_MEM.width, display_config.TEXT_AREA_MEM.height, color);

            // Disk
            self.bitmap.drawRect(display_config.DISK_AREA_X, display_config.DISK_AREA_Y_DISK, display_config.TEXT_AREA_DISK.width, display_config.TEXT_AREA_DISK.height, color);
            self.bitmap.drawRect(display_config.DISK_AREA_X, display_config.DISK_AREA_Y_TEMP, display_config.TEXT_AREA_DISK.width, display_config.TEXT_AREA_DISK.height, color);

            // FAN
            const ascent_fan = self.bitmap.getFontAscent(.Ubuntu24);
            self.bitmap.drawRect(display_config.FAN_VALUE_X, display_config.FAN_VALUE_Y - ascent_fan, display_config.TEXT_AREA_FAN.width, display_config.TEXT_AREA_FAN.height, color);

            // APT
            const ascent_apt = self.bitmap.getFontAscent(.Ubuntu24);
            self.bitmap.drawRect(display_config.APT_VALUE_X, display_config.APT_VALUE_Y - ascent_apt, display_config.TEXT_AREA_APT.width, display_config.TEXT_AREA_APT.height, color);

            // NET icon/state
            const ascent_net = self.bitmap.getFontAscent(.Material24);
            self.bitmap.drawRect(display_config.NET_ICON_X, display_config.NET_ICON_Y - ascent_net, display_config.TEXT_AREA_NET.width, display_config.TEXT_AREA_NET.height, color);

            // IP
            self.bitmap.drawRect(display_config.IP_VALUE_X, display_config.IP_AREA_Y, display_config.TEXT_AREA_IP.width, display_config.TEXT_AREA_IP.height, color);

            // UPTIME
            self.bitmap.drawRect(display_config.UPTIME_VALUE_X, display_config.UPTIME_AREA_Y, display_config.TEXT_AREA_UPTIME.width, display_config.TEXT_AREA_UPTIME.height, color);

            // SIGNAL
            self.bitmap.drawRect(display_config.SIGNAL_AREA_X, display_config.SIGNAL_AREA_Y, display_config.TEXT_AREA_SIGNAL.width, display_config.TEXT_AREA_SIGNAL.height, color);

            // Traffic down
            self.bitmap.drawRect(display_config.TRAFFIC_DOWN_VALUE_X, display_config.TRAFFIC_DOWN_AREA_Y, display_config.TEXT_AREA_TRAFFIC_VALUE.width, display_config.TEXT_AREA_TRAFFIC_VALUE.height, color);
            self.bitmap.drawRect(display_config.TRAFFIC_DOWN_UNIT_X, display_config.TRAFFIC_DOWN_UNIT_AREA_Y, display_config.TEXT_AREA_TRAFFIC_UNIT.width, display_config.TEXT_AREA_TRAFFIC_UNIT.height, color);

            // Traffic up
            self.bitmap.drawRect(display_config.TRAFFIC_UP_VALUE_X, display_config.TRAFFIC_UP_AREA_Y, display_config.TEXT_AREA_TRAFFIC_VALUE.width, display_config.TEXT_AREA_TRAFFIC_VALUE.height, color);
            self.bitmap.drawRect(display_config.TRAFFIC_UP_UNIT_X, display_config.TRAFFIC_UP_UNIT_AREA_Y, display_config.TEXT_AREA_TRAFFIC_UNIT.width, display_config.TEXT_AREA_TRAFFIC_UNIT.height, color);
        }

        /// Convert the 8-bit bitmap to the panel's 1-bit packed format, rotating 90°
        /// clockwise. One hardware row comes from one logical column, so each output
        /// byte is assembled in a register and stored once.
        pub fn convertTo1Bit(self: *Self, output: *Frame) void {
            // One hardware row is packed from one logical column, so the panel's
            // short side has to be exactly the bitmap's height. `output` carries its
            // own length in its type.
            std.debug.assert(self.bitmap.height == hw_bytes_per_row * 8);

            const width = self.bitmap.width;

            var hw_y: u32 = 0;
            while (hw_y < width) : (hw_y += 1) {
                const src_x = (width - 1) - hw_y;
                const row = output[hw_y * hw_bytes_per_row ..][0..hw_bytes_per_row];

                for (row, 0..) |*out_byte, byte_idx| {
                    // 1 = white, 0 = black, MSB first.
                    var bits: u8 = 0;
                    for (0..8) |b| {
                        const src_y = byte_idx * 8 + b;
                        if (self.bitmap.data[src_y * self.bitmap.stride + src_x] >= 128) {
                            bits |= @as(u8, 0x80) >> @intCast(b);
                        }
                    }
                    out_byte.* = bits;
                }
            }
        }

        /// Export as BMP
        pub fn exportBmp(self: *Self) !void {
            if (!config.Config.export_bmp) return;

            self.packBmpBuffer();
            try self.bmp_exporter.save(self.io, self.bmp_buffer, self.bitmap.width, self.bitmap.height, config.Config.bmp_export_path);
        }

        /// Pack the bitmap into `bmp_buffer`, unrotated, 1 bit per pixel.
        fn packBmpBuffer(self: *Self) void {
            const width = self.bitmap.width;
            const height = self.bitmap.height;
            const row_bytes = (width + 7) / 8;

            // Pack to 1-bit without rotation, into the preallocated scratch buffer.
            var y: u32 = 0;
            while (y < height) : (y += 1) {
                const src_row = self.bitmap.data[y * self.bitmap.stride ..][0..width];
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

        /// Render CPU load and temperature
        pub fn renderCpuLoad(self: *Self, load: u8, temp: u32) void {
            const is_load_critical = load >= config.Config.threshold_cpu_critical;
            const is_temp_critical = temp >= config.Config.threshold_temp_critical;

            var buf1: [16]u8 = undefined;
            const load_text = std.fmt.bufPrint(&buf1, "{d}%", .{load}) catch "?";
            self.drawTextInArea(load_text, .Ubuntu26, display_config.CPU_VALUE_X, display_config.CPU_VALUE_Y_LOAD, display_config.CPU_AREA_X, display_config.CPU_AREA_Y_LOAD, display_config.TEXT_AREA_CPU.width, display_config.TEXT_AREA_CPU.height, is_load_critical);

            var buf2: [16]u8 = undefined;
            const temp_text = std.fmt.bufPrint(&buf2, "{d}°C", .{temp}) catch "?";
            self.drawTextInArea(temp_text, .Ubuntu26, display_config.CPU_VALUE_X, display_config.CPU_VALUE_Y_TEMP, display_config.CPU_AREA_X, display_config.CPU_AREA_Y_TEMP, display_config.TEXT_AREA_CPU.width, display_config.TEXT_AREA_CPU.height, is_temp_critical);
        }

        /// Render memory usage
        pub fn renderMemory(self: *Self, usage: u8) void {
            const is_critical = usage >= config.Config.threshold_mem_critical;

            var buf: [16]u8 = undefined;
            const text = std.fmt.bufPrint(&buf, "{d}%", .{usage}) catch "?";
            self.drawTextInArea(text, .Ubuntu26, display_config.MEM_VALUE_X, display_config.MEM_VALUE_Y, display_config.MEM_AREA_X, display_config.MEM_AREA_Y, display_config.TEXT_AREA_MEM.width, display_config.TEXT_AREA_MEM.height, is_critical);
        }

        /// Render disk stats
        pub fn renderDiskStats(self: *Self, usage: u8, temp: u32) void {
            const is_usage_critical = usage >= config.Config.threshold_disk_critical;
            const is_temp_critical = temp >= config.Config.threshold_temp_critical;

            var buf1: [16]u8 = undefined;
            const usage_text = std.fmt.bufPrint(&buf1, "{d}%", .{usage}) catch "?";
            self.drawTextInArea(usage_text, .Ubuntu26, display_config.DISK_VALUE_X, display_config.DISK_VALUE_Y_DISK, display_config.DISK_AREA_X, display_config.DISK_AREA_Y_DISK, display_config.TEXT_AREA_DISK.width, display_config.TEXT_AREA_DISK.height, is_usage_critical);

            var buf2: [16]u8 = undefined;
            const temp_text = std.fmt.bufPrint(&buf2, "{d}°C", .{temp}) catch "?";
            self.drawTextInArea(temp_text, .Ubuntu26, display_config.DISK_VALUE_X, display_config.DISK_VALUE_Y_TEMP, display_config.DISK_AREA_X, display_config.DISK_AREA_Y_TEMP, display_config.TEXT_AREA_DISK.width, display_config.TEXT_AREA_DISK.height, is_temp_critical);
        }

        /// Render fan speed
        pub fn renderFanSpeed(self: *Self, rpm: u32) void {
            const ascent = self.bitmap.getFontAscent(.Ubuntu24);
            self.bitmap.fillRect(display_config.FAN_VALUE_X, display_config.FAN_VALUE_Y - ascent, display_config.TEXT_AREA_FAN.width, display_config.TEXT_AREA_FAN.height, .White);

            var buf: [16]u8 = undefined;
            const text = std.fmt.bufPrint(&buf, "{d}", .{rpm}) catch "?";
            self.bitmap.drawTextFont(display_config.FAN_VALUE_X, display_config.FAN_VALUE_Y, text, .Ubuntu24, .Black);
        }

        /// Render IP address
        pub fn renderIpAddress(self: *Self, ip: []const u8) void {
            self.bitmap.fillRect(display_config.IP_VALUE_X, display_config.IP_AREA_Y, display_config.TEXT_AREA_IP.width, display_config.TEXT_AREA_IP.height, .White);

            const display_ip = if (ip.len > 15) ip[0..15] else ip;
            self.bitmap.drawTextFont(display_config.IP_VALUE_X, display_config.IP_VALUE_Y, display_ip, .Ubuntu14, .Black);
        }

        /// Render uptime.
        ///
        /// The slot runs to the right edge of the panel, where overflow is clipped
        /// mid-glyph, so pick the most detailed form that fits its 84px:
        /// "11d 12h 20m" (83px) up to 99 days, then the compact "123d 23:59" (70px),
        /// which still carries minutes. Only truly absurd uptimes lose them.
        pub fn renderUptime(self: *Self, days: u32, hours: u32, minutes: u32) void {
            self.bitmap.fillRect(display_config.UPTIME_VALUE_X, display_config.UPTIME_AREA_Y, display_config.TEXT_AREA_UPTIME.width, display_config.TEXT_AREA_UPTIME.height, .White);

            var buf = display_config.UptimeBuffers{};
            const candidates = display_config.uptimeCandidates(&buf, days, hours, minutes);

            const text = self.bitmap.fitText(&candidates, .Ubuntu14, display_config.TEXT_AREA_UPTIME.width);
            self.bitmap.drawTextFont(display_config.UPTIME_VALUE_X, display_config.UPTIME_VALUE_Y, text, .Ubuntu14, .Black);
        }

        /// Render signal strength.
        ///
        /// "-40 dBm" fits; the three-digit "-100 dBm" does not, so the unit is
        /// dropped at that end of the range rather than clipping the number. -100
        /// dBm is effectively no signal, where the exact unit matters least.
        pub fn renderSignalStrength(self: *Self, signal: ?i32) void {
            self.bitmap.fillRect(display_config.SIGNAL_AREA_X, display_config.SIGNAL_AREA_Y, display_config.TEXT_AREA_SIGNAL.width, display_config.TEXT_AREA_SIGNAL.height, .White);

            const icon = if (signal != null) display_config.ICON_WIFI_SIGNAL else display_config.ICON_WIFI_NO_SIGNAL;
            self.bitmap.drawTextFont(display_config.SIGNAL_ICON_X, display_config.SIGNAL_ICON_Y, icon, .Material14, .Black);

            var with_unit: [16]u8 = undefined;
            var bare: [16]u8 = undefined;

            const text = if (signal) |s| blk: {
                const candidates = [_][]const u8{
                    std.fmt.bufPrint(&with_unit, "{d} dBm", .{s}) catch "?",
                    std.fmt.bufPrint(&bare, "{d}", .{s}) catch "?",
                };
                break :blk self.bitmap.fitText(&candidates, .Ubuntu14, display_config.SIGNAL_VALUE_MAX_W);
            } else "N/A";

            self.bitmap.drawTextFont(display_config.SIGNAL_VALUE_X, display_config.SIGNAL_VALUE_Y, text, .Ubuntu14, .Black);
        }

        /// Render network traffic
        pub fn renderTraffic(self: *Self, download_speed: f64, download_unit: []const u8, upload_speed: f64, upload_unit: []const u8) void {
            self.renderTrafficRow(
                download_speed,
                download_unit,
                display_config.TRAFFIC_DOWN_VALUE_X,
                display_config.TRAFFIC_DOWN_VALUE_Y,
                display_config.TRAFFIC_DOWN_AREA_Y,
                display_config.TRAFFIC_DOWN_UNIT_X,
                display_config.TRAFFIC_DOWN_UNIT_Y,
                display_config.TRAFFIC_DOWN_UNIT_AREA_Y,
            );
            self.renderTrafficRow(
                upload_speed,
                upload_unit,
                display_config.TRAFFIC_UP_VALUE_X,
                display_config.TRAFFIC_UP_VALUE_Y,
                display_config.TRAFFIC_UP_AREA_Y,
                display_config.TRAFFIC_UP_UNIT_X,
                display_config.TRAFFIC_UP_UNIT_Y,
                display_config.TRAFFIC_UP_UNIT_AREA_Y,
            );
        }

        fn renderTrafficRow(
            self: *Self,
            speed: f64,
            unit: []const u8,
            value_x: i32,
            value_y: i32,
            value_area_y: i32,
            unit_x: i32,
            unit_y: i32,
            unit_area_y: i32,
        ) void {
            self.bitmap.fillRect(value_x, value_area_y, display_config.TEXT_AREA_TRAFFIC_VALUE.width, display_config.TEXT_AREA_TRAFFIC_VALUE.height, .White);
            self.bitmap.fillRect(unit_x, unit_area_y, display_config.TEXT_AREA_TRAFFIC_UNIT.width, display_config.TEXT_AREA_TRAFFIC_UNIT.height, .White);

            // scaleBytes keeps the value under 1000, so two decimals always fit.
            // The ladder is a guard against that changing, since this slot ends at
            // the right edge of the panel where overflow is clipped mid-glyph.
            var two_dp: [32]u8 = undefined;
            var one_dp: [32]u8 = undefined;
            var no_dp: [32]u8 = undefined;
            const candidates = [_][]const u8{
                std.fmt.bufPrint(&two_dp, "{d:.2}", .{speed}) catch "?",
                std.fmt.bufPrint(&one_dp, "{d:.1}", .{speed}) catch "?",
                std.fmt.bufPrint(&no_dp, "{d:.0}", .{speed}) catch "?",
            };
            const value_text = self.bitmap.fitText(&candidates, .Ubuntu20, display_config.TEXT_AREA_TRAFFIC_VALUE.width);
            self.bitmap.drawTextFont(value_x, value_y, value_text, .Ubuntu20, .Black);

            var unit_buf: [32]u8 = undefined;
            const unit_text = std.fmt.bufPrint(&unit_buf, "{s}/s", .{unit}) catch "?";
            self.bitmap.drawTextFont(unit_x, unit_y, unit_text, .Ubuntu14, .Black);
        }

        /// Render APT updates count. `null` means the background check has not
        /// reported yet — show a dash rather than the "all up to date" tick, which
        /// would claim more than is known.
        pub fn renderAptUpdates(self: *Self, count: ?u32) void {
            const ascent = self.bitmap.getFontAscent(.Ubuntu24);
            self.bitmap.fillRect(display_config.APT_VALUE_X, display_config.APT_VALUE_Y - ascent, display_config.TEXT_AREA_APT.width, display_config.TEXT_AREA_APT.height, .White);

            const known = count orelse {
                self.bitmap.drawTextFont(display_config.APT_VALUE_X, display_config.APT_VALUE_Y, "-", .Ubuntu24, .Black);
                return;
            };

            if (known == 0) {
                self.bitmap.drawTextFont(display_config.APT_VALUE_X, display_config.APT_VALUE_Y, display_config.ICON_CHECK, .Material24, .Black);
            } else {
                var buf: [16]u8 = undefined;
                const text = std.fmt.bufPrint(&buf, "{d}", .{known}) catch "?";
                self.bitmap.drawTextFont(display_config.APT_VALUE_X, display_config.APT_VALUE_Y, text, .Ubuntu24, .Black);
            }
        }

        /// Render internet connection status
        pub fn renderInternetStatus(self: *Self, connected: bool) void {
            const ascent = self.bitmap.getFontAscent(.Material24);
            self.bitmap.fillRect(display_config.NET_ICON_X, display_config.NET_ICON_Y - ascent, display_config.TEXT_AREA_NET.width, display_config.TEXT_AREA_NET.height, .White);

            const icon = if (connected) display_config.ICON_WIFI_OK else display_config.ICON_WIFI_OFF;
            self.bitmap.drawTextFont(display_config.NET_ICON_X, display_config.NET_ICON_Y, icon, .Material24, .Black);
        }

        /// Draw a fixed screen with hard-coded values, for the golden reference
        /// frame. Lives here rather than in the test so that `zig build golden` and
        /// the test that checks against its output cannot drift apart.
        pub fn drawReferenceScreen(self: *Self) void {
            self.renderGrid();
            self.renderCpuLoad(42, 51);
            self.renderMemory(28);
            self.renderDiskStats(84, 33);
            self.renderFanSpeed(543);
            self.renderTraffic(999.99, "kB", 3.01, "B");
            self.renderAptUpdates(35);
            self.renderInternetStatus(true);
            self.renderIpAddress("192.168.1.231");
            self.renderUptime(11, 22, 47);
            self.renderSignalStrength(null);
        }

        /// Draw the sleep screen, then park the panel in deep sleep.
        pub fn goToSleep(self: *Self) !void {
            log.info("Rendering sleep screen", .{});

            // Re-initialize display to ensure Full LUT is loaded (needed after partial
            // updates) and to wake the controller if it was parked between refreshes.
            self.epd.reInit() catch |err| {
                log.err("Failed to re-init display for sleep: {t}", .{err});
            };
            self.panel_asleep = false;

            self.drawSplash("Sleeping...", .Black);
            self.convertTo1Bit(self.epd_buffer);

            // displayBase also resets the base RAM used by partial updates.
            try self.epd.displayBase(self.epd_buffer);
            self.rememberCurrentFrame();

            // Unconditional, unlike parkPanel: Waveshare requires deep sleep before
            // power is cut, whatever PANEL_SLEEP is set to.
            self.epd.sleep() catch |err| {
                log.err("Failed to put panel into deep sleep: {t}", .{err});
            };
            self.panel_asleep = true;

            log.info("Display parked in deep sleep", .{});

            self.exportBmp() catch |err| {
                log.err("Failed to export sleep screen BMP: {t}", .{err});
            };
        }
    };
}

/// The renderer as used in production.
pub const DisplayRenderer = Renderer(EpdConfig);

// ----------------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------------

const testing = std.testing;
const FakeTransport = @import("waveshare_epd/fake_transport.zig").FakeTransport;

const TestRenderer = Renderer(FakeTransport);

/// Path of the reference frame, relative to this file.
const golden_path = "testdata/golden_main.bin";
const golden_frame = @embedFile(golden_path);

/// A renderer wired to a recorder instead of a panel.
const Harness = struct {
    transport: FakeTransport,
    renderer: TestRenderer,

    fn init() !Harness {
        var h: Harness = .{
            .transport = FakeTransport.init(testing.allocator),
            .renderer = undefined,
        };
        h.renderer = try TestRenderer.init(testing.allocator, undefined, &h.transport);
        return h;
    }

    /// Must be called on the final address; `renderer.epd` holds a pointer to
    /// `transport`, so the struct cannot be moved after this.
    fn wire(self: *Harness) void {
        self.renderer.epd = TestRenderer.EPD.init(&self.transport);
    }

    fn deinit(self: *Harness) void {
        self.renderer.deinit();
        self.transport.deinit();
    }

    fn drawReferenceScreen(self: *Harness) void {
        self.renderer.drawReferenceScreen();
    }
};

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
    var h = try Harness.init();
    h.wire();
    defer h.deinit();

    h.drawReferenceScreen();
    h.renderer.convertTo1Bit(h.renderer.epd_buffer);
    const actual: []const u8 = h.renderer.epd_buffer;

    if (!std.mem.eql(u8, golden_frame, actual)) {
        var differing_rows: usize = 0;
        var first_row: ?usize = null;
        var row: usize = 0;
        while (row < display_config.DISPLAY_WIDTH) : (row += 1) {
            const at = row * hw_bytes_per_row;
            if (!std.mem.eql(u8, golden_frame[at..][0..hw_bytes_per_row], actual[at..][0..hw_bytes_per_row])) {
                differing_rows += 1;
                if (first_row == null) first_row = row;
            }
        }
        std.debug.print(
            "\n  rendered frame differs from {s}: {d} of {d} hardware rows, first at {d}\n" ++
                "  run `zig build golden` to accept the new frame if this was intended\n",
            .{ golden_path, differing_rows, display_config.DISPLAY_WIDTH, first_row.? },
        );
        return error.GoldenFrameMismatch;
    }
}

test "rendering is deterministic" {
    // The golden test is only meaningful if the same inputs always produce the
    // same frame.
    var a = try Harness.init();
    a.wire();
    defer a.deinit();
    var b = try Harness.init();
    b.wire();
    defer b.deinit();

    a.drawReferenceScreen();
    b.drawReferenceScreen();
    a.renderer.convertTo1Bit(a.renderer.epd_buffer);
    b.renderer.convertTo1Bit(b.renderer.epd_buffer);

    try testing.expectEqualSlices(u8, a.renderer.epd_buffer, b.renderer.epd_buffer);
}

// --- under-voltage warning ---------------------------------------------------

/// Rows of the unrotated BMP buffer covering the status bar.
fn statusBarRows(r: *TestRenderer) []const u8 {
    const row_bytes = (display_config.DISPLAY_WIDTH + 7) / 8;
    return r.bmp_buffer[display_config.STATUS_BAR_Y * row_bytes ..];
}

test "the warning inverts the status bar in the frame sent to the panel" {
    var h = try Harness.init();
    h.wire();
    defer h.deinit();

    config.Config.panel_sleep = true;
    h.drawReferenceScreen();
    try h.renderer.showInitialFrame();
    const clean: Frame = h.renderer.epd_buffer.*;

    h.renderer.setFaultWarning(true);
    try h.renderer.updateDisplay(false);

    try testing.expect(!std.mem.eql(u8, &clean, h.renderer.epd_buffer));
}

test "the warning reaches the BMP preview too" {
    // Regression: the overlay used to be applied only around the panel
    // conversion, so the exported preview showed a clean status bar while the
    // glass showed an inverted one. A preview that disagrees with the device is
    // worse than no preview.
    var h = try Harness.init();
    h.wire();
    defer h.deinit();

    h.drawReferenceScreen();
    h.renderer.packBmpBuffer();
    const clean = try testing.allocator.dupe(u8, statusBarRows(&h.renderer));
    defer testing.allocator.free(clean);

    h.renderer.setFaultWarning(true);
    h.renderer.toggleFaultOverlay();
    h.renderer.packBmpBuffer();
    h.renderer.toggleFaultOverlay();

    const warned = statusBarRows(&h.renderer);
    try testing.expect(!std.mem.eql(u8, clean, warned));

    // Every bit of the bar flips, so the rows are the exact complement.
    for (clean, warned) |a, b| try testing.expectEqual(a, ~b);
}

test "the warning does not leak into the bitmap" {
    // The status bar's slots are each redrawn by their own task, so an inversion
    // left behind would be partially erased and the frame would come out half
    // inverted. toggleFaultOverlay relies on invertRect being its own inverse.
    var h = try Harness.init();
    h.wire();
    defer h.deinit();

    h.drawReferenceScreen();
    const pristine = try testing.allocator.dupe(u8, h.renderer.bitmap.data);
    defer testing.allocator.free(pristine);

    h.renderer.setFaultWarning(true);
    try h.renderer.showInitialFrame();

    try testing.expectEqualSlices(u8, pristine, h.renderer.bitmap.data);
}

test "repeated refreshes with the warning on are stable" {
    // An inversion that accumulated would alternate the bar between normal and
    // inverted on every refresh.
    var h = try Harness.init();
    h.wire();
    defer h.deinit();

    config.Config.panel_sleep = true;
    h.drawReferenceScreen();
    h.renderer.setFaultWarning(true);

    try h.renderer.showInitialFrame();
    const first: Frame = h.renderer.epd_buffer.*;
    try h.renderer.updateDisplay(false);

    try testing.expectEqualSlices(u8, &first, h.renderer.epd_buffer);
}

test "the warning leaves everything above the status bar alone" {
    var h = try Harness.init();
    h.wire();
    defer h.deinit();

    h.drawReferenceScreen();
    h.renderer.packBmpBuffer();
    const row_bytes = (display_config.DISPLAY_WIDTH + 7) / 8;
    const above_len = display_config.STATUS_BAR_Y * row_bytes;
    const clean_above = try testing.allocator.dupe(u8, h.renderer.bmp_buffer[0..above_len]);
    defer testing.allocator.free(clean_above);

    h.renderer.setFaultWarning(true);
    h.renderer.toggleFaultOverlay();
    h.renderer.packBmpBuffer();
    h.renderer.toggleFaultOverlay();

    try testing.expectEqualSlices(u8, clean_above, h.renderer.bmp_buffer[0..above_len]);
}

test "no warning means no overlay at all" {
    var h = try Harness.init();
    h.wire();
    defer h.deinit();

    h.drawReferenceScreen();
    h.renderer.packBmpBuffer();
    const clean = try testing.allocator.dupe(u8, h.renderer.bmp_buffer);
    defer testing.allocator.free(clean);

    h.renderer.setFaultWarning(false);
    h.renderer.toggleFaultOverlay();
    h.renderer.packBmpBuffer();
    h.renderer.toggleFaultOverlay();

    try testing.expectEqualSlices(u8, clean, h.renderer.bmp_buffer);
}

// --- panel power state machine ----------------------------------------------

test "an unchanged frame leaves a sleeping panel alone" {
    var h = try Harness.init();
    h.wire();
    defer h.deinit();

    config.Config.panel_sleep = true;
    h.drawReferenceScreen();
    try h.renderer.showInitialFrame();
    try testing.expect(h.renderer.panel_asleep);

    h.transport.resetLog();
    try h.renderer.updateDisplay(true);

    // The whole point of parking the panel: an idle cycle costs nothing.
    try testing.expectEqual(@as(usize, 0), h.transport.events.items.len);
    try testing.expect(h.renderer.panel_asleep);
}

test "a changed frame wakes the panel, restores the reference and parks it again" {
    var h = try Harness.init();
    h.wire();
    defer h.deinit();

    config.Config.panel_sleep = true;
    h.drawReferenceScreen();
    try h.renderer.showInitialFrame();

    h.transport.resetLog();
    h.renderer.renderCpuLoad(99, 60); // change the frame
    try h.renderer.updateDisplay(true);

    // Reference frame restored before the partial update, or it would smear.
    try testing.expect(h.transport.sentCommand(0x26));
    try testing.expect(h.transport.sentCommand(0x24));
    // Partial waveform, not the full one. The last 0x22 is the one that selects
    // it; the first powers the analog stage up.
    try testing.expectEqualSlices(u8, &.{0x0F}, h.transport.lastArgsAfter(0x22).?);
    // Deep sleep mode 1 on the way out.
    try testing.expectEqualSlices(u8, &.{0x01}, h.transport.argsAfter(0x10).?);
    try testing.expect(h.renderer.panel_asleep);
}

test "PANEL_SLEEP=false keeps the controller powered" {
    var h = try Harness.init();
    h.wire();
    defer h.deinit();

    config.Config.panel_sleep = false;
    defer config.Config.panel_sleep = true;

    h.drawReferenceScreen();
    try h.renderer.showInitialFrame();

    try testing.expect(!h.renderer.panel_asleep);
    try testing.expect(!h.transport.sentCommand(0x10)); // never told to sleep
}

test "a full refresh rewrites the reference bank" {
    var h = try Harness.init();
    h.wire();
    defer h.deinit();

    config.Config.panel_sleep = true;
    h.drawReferenceScreen();
    try h.renderer.showInitialFrame();

    h.transport.resetLog();
    h.renderer.renderCpuLoad(1, 2);
    try h.renderer.updateDisplay(false);

    // displayBase, not display: leaving the reference stale would make the
    // following partial updates diff against something that is not on the glass.
    try testing.expect(h.transport.sentCommand(0x26));
    try testing.expectEqualSlices(u8, &.{0xC7}, h.transport.argsAfter(0x22).?);
}

test "a failed update forces the next one to be a full refresh" {
    var h = try Harness.init();
    h.wire();
    defer h.deinit();

    // Awake throughout, so the failure lands in the update itself rather than in
    // the wake that precedes it.
    config.Config.panel_sleep = false;
    defer config.Config.panel_sleep = true;

    h.drawReferenceScreen();
    try h.renderer.showInitialFrame();

    // Panel stops releasing BUSY, so the update dies partway through and the
    // glass no longer matches the reference frame.
    h.transport.busy_reads_remaining = std.math.maxInt(u32);
    h.renderer.renderCpuLoad(50, 50);
    try testing.expectError(error.EpdBusyTimeout, h.renderer.updateDisplay(true));
    try testing.expect(h.renderer.panel_state_unknown);

    // A partial update would now smear, so it must be promoted to a full one.
    h.transport.busy_reads_remaining = 0;
    h.transport.resetLog();
    try h.renderer.updateDisplay(true);

    try testing.expectEqualSlices(u8, &.{0xC7}, h.transport.lastArgsAfter(0x22).?);
    try testing.expect(!h.renderer.panel_state_unknown);
}

test "a failed wake leaves the panel marked asleep and the glass trusted" {
    var h = try Harness.init();
    h.wire();
    defer h.deinit();

    config.Config.panel_sleep = true;
    h.drawReferenceScreen();
    try h.renderer.showInitialFrame();
    try testing.expect(h.renderer.panel_asleep);

    // reInit fails, so the wake never completes.
    h.transport.busy_reads_remaining = std.math.maxInt(u32);
    h.renderer.renderCpuLoad(50, 50);
    try testing.expectError(error.EpdBusyTimeout, h.renderer.updateDisplay(true));

    // reInit drives nothing, so the glass still matches the reference and the
    // next update may still be partial. The panel stays marked asleep, which is
    // what makes the next attempt retry the wake.
    try testing.expect(!h.renderer.panel_state_unknown);
    try testing.expect(h.renderer.panel_asleep);

    // And it does recover on its own once the panel responds again.
    h.transport.busy_reads_remaining = 0;
    h.transport.resetLog();
    try h.renderer.updateDisplay(true);
    try testing.expect(h.transport.sentCommand(0x26)); // reference restored
    try testing.expect(h.renderer.panel_asleep);
}
